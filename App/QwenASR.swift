@preconcurrency import AVFoundation
import Foundation

nonisolated enum ASRError: LocalizedError {
    case noServer, noModel, startFailed(String), http(Int, String), badAudio

    var errorDescription: String? {
        switch self {
        case .noServer: "没找到 llama-server。请安装 llama.cpp（brew install llama.cpp），或在设置里指定它的位置。"
        case .noModel: "没找到 Qwen3‑ASR 模型文件。请在设置里下载。"
        case .startFailed(let why): "本机转写服务没启动起来：\(why)"
        case .http(let code, let body): "转写服务返回错误 \(code)：\(body.prefix(160))"
        case .badAudio: "这条录音读不出来"
        }
    }
}

/// 用 llama.cpp 在本机跑 Qwen3‑ASR。录音不出这台电脑。
/// 做法：起一个只监听本机的 llama-server，把录音切成不超过 28 秒的小段逐段送进去。
actor QwenASR {
    static let shared = QwenASR()

    static let modelName = "Qwen3-ASR-0.6B-Q8_0.gguf"
    static let projectorName = "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"
    static let displayName = "Qwen3‑ASR 0.6B"

    nonisolated static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Models/qwen3-asr-0.6b", isDirectory: true)
    }

    nonisolated static func locateServer(custom: String) -> URL? {
        let candidates = [custom, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                          "/Applications/Capwise.app/Contents/Helpers/llama-server/llama-server"]
        return candidates.filter { !$0.isEmpty }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func locateModel() -> (model: URL, projector: URL)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [modelFolder, home.appendingPathComponent("Library/Application Support/so.cap.desktop/transcription_models/qwen3-asr-0.6b")]
        for f in folders {
            let m = f.appendingPathComponent(modelName), p = f.appendingPathComponent(projectorName)
            if FileManager.default.fileExists(atPath: m.path), FileManager.default.fileExists(atPath: p.path) { return (m, p) }
        }
        return nil
    }

    private var process: Process?
    private var port = 0

    // MARK: 服务

    private func ensureRunning(serverPath: String) async throws -> Int {
        if let process, process.isRunning { return port }
        guard let server = Self.locateServer(custom: serverPath) else { throw ASRError.noServer }
        guard let files = Self.locateModel() else { throw ASRError.noModel }

        port = Int.random(in: 39000...39900)
        let p = Process()
        // 用一层 sh 盯着豆仓的进程：豆仓退出（哪怕是崩溃），转写服务也跟着退，不留孤儿进程
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"parent=$1; shift; "$@" & child=$!; while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null"#,
                       "beanpod-asr", String(ProcessInfo.processInfo.processIdentifier), server.path,
                       "-m", files.model.path, "--mmproj", files.projector.path,
                       "--host", "127.0.0.1", "--port", String(port), "-c", "4096", "-np", "1", "--log-disable"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ASRError.startFailed(error.localizedDescription) }
        process = p

        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            if !p.isRunning { process = nil; throw ASRError.startFailed("进程退出了，可能是模型文件损坏或内存不够") }
            if let (_, r) = try? await URLSession.shared.data(from: health), (r as? HTTPURLResponse)?.statusCode == 200 { return port }
        }
        stop()
        throw ASRError.startFailed("等了一分钟还没就绪")
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    // MARK: 转写

    /// 提前把模型装进内存。语音输入在按下按键时调用，松手时就不用等加载了。
    func warmUp(serverPath: String) async { _ = try? await ensureRunning(serverPath: serverPath) }

    /// 转一小段已经在内存里的声音（16 kHz 单声道），用于语音输入。
    func transcribe(samples: [Float], serverPath: String) async throws -> String {
        let port = try await ensureRunning(serverPath: serverPath)
        var parts: [String] = []
        for c in Self.chunk(samples) {
            let piece = Array(samples[c])
            guard Self.rms(piece) > 0.0015 else { continue }
            let text = try await recognize(Self.wav(piece), port: port)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined()
    }

    func transcribe(_ url: URL, serverPath: String, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        let port = try await ensureRunning(serverPath: serverPath)
        let samples = try Self.loadMono16k(url)
        // 按停顿切成一句一句的，每句都有自己的时间，方便点着听、标说话人
        let chunks = Self.sentenceChunks(samples)
        var out: [Segment] = []
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(Double(i) / Double(chunks.count))
            let piece = Array(samples[c])
            // 几乎没有声音的片段直接跳过，模型在静音上容易凭空编字
            guard BeanStore.hasSpeech(piece) else { continue }
            let text = try await recognize(Self.wav(piece), port: port)
            if !text.isEmpty, !BeanStore.isFiller(text) { out.append(Segment(start: Double(c.lowerBound) / 16000, text: text)) }
        }
        progress(1)
        return out
    }

    private func recognize(_ wav: Data, port: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "temperature": 0, "max_tokens": 512,
            "messages": [["role": "user", "content": [["type": "input_audio",
                                                        "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]]]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ASRError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        return Self.clean(content)
    }

    /// 模型的原始输出形如「language Chinese<asr_text>正文</asr_text>」，只留正文。
    nonisolated static func clean(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "<asr_text>") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "</asr_text>") { s = String(s[..<r.lowerBound]) }
        return s.replacingOccurrences(of: "<|im_end|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 音频处理

    nonisolated static func loadMono16k(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ASRError.badAudio
        }
        try file.read(into: input)
        if file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, let d = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: d[0], count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / file.processingFormat.sampleRate) + 1024) else {
            throw ASRError.badAudio
        }
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if let b = pending { pending = nil; status.pointee = .haveData; return b }
            status.pointee = .endOfStream; return nil
        }
        guard error == nil, let d = output.floatChannelData else { throw ASRError.badAudio }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(output.frameLength)))
    }

    /// 切成不超过 28 秒的段，切点选在 20–28 秒之间最安静的地方，尽量不把一句话拦腰切断。
    nonisolated static func chunk(_ samples: [Float], rate: Int = 16000) -> [Range<Int>] {
        let maxLen = 28 * rate, minLen = 20 * rate, window = rate / 5
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLen {
            var best = start + maxLen, bestEnergy = Float.greatestFiniteMagnitude
            var i = start + minLen
            while i + window <= start + maxLen {
                var e: Float = 0
                for j in stride(from: i, to: i + window, by: 4) { e += samples[j] * samples[j] }
                if e < bestEnergy { bestEnergy = e; best = i + window / 2 }
                i += window / 2
            }
            ranges.append(start..<best)
            start = best
        }
        if samples.count - start > rate / 4 { ranges.append(start..<samples.count) }
        return ranges
    }

    /// 沿着停顿把整段声音切成句子：每段最长 15 秒，切点落在停顿上。
    nonisolated static func sentenceChunks(_ samples: [Float], rate: Int = 16000) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        let longest = 15 * rate
        while samples.count - start > longest {
            let window = Array(samples[start..<(start + longest)])
            let frames = BeanStore.lastPause(in: window, forced: true) ?? (longest / 320)
            let cut = max(rate * 3 / 2, min(frames * 320, longest))
            ranges.append(start..<(start + cut))
            start += cut
        }
        if samples.count - start > rate / 4 { ranges.append(start..<samples.count) }
        return ranges
    }

    nonisolated static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var e: Float = 0
        for v in s { e += v * v }
        return (e / Float(s.count)).squareRoot()
    }

    nonisolated static func wav(_ samples: [Float], rate: Int = 16000) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        for s in samples {
            withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
