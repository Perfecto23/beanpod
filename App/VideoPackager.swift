import AppKit
@preconcurrency import AVFoundation
import QuartzCore

/// 数字人各段生成好之后的「剪辑包装」：在这台 Mac 上做，不再花积分。
///
/// 1. 对字幕：字幕用稿子原文（不会有错别字），时间按每段的说话声音来对——找到开口、收口和句间停顿，
///    把稿子按标点切成短句，按字数分时间，再把边界吸到最近的停顿上。
/// 2. 设计包装：让分析模型挑开场标题、每句要强调的词、三到五个要点卡（这条片子的 B-roll）。
///    没有设置模型时只做字幕，数字自动强调。
/// 3. 渲染：开场标题卡、要点卡出现时数字人让到一边，底部字幕带强调色，顶部细进度条，角上「AI 生成」标注。
@MainActor
enum VideoPackager {
    /// 一段数字人视频和它念的那句话。
    struct Part: Codable { var file: String; var line: String }
    /// 存在「<视频名>.parts」文件夹里，重新包装时用。
    struct Manifest: Codable { var title: String; var parts: [Part] }

    struct Caption { var text: String; var start: Double; var end: Double; var highlight: String? }
    struct Card { var label: String; var big: String; var small: String; var start: Double; var end: Double }
    struct Plan { var hook: String; var captions: [Caption]; var cards: [Card] }

    static func partsFolder(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("parts")
    }

    /// 把一套分段做成包装好的成片。progress 报告（这一步叫什么，0…1）。
    static func run(folder: URL, out: URL, store: BeanStore, progress: @escaping (String, Double) -> Void) async throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !manifest.parts.isEmpty else { throw PackError.empty }

        // 1. 读每段的时长和说话声音
        progress("对字幕", 0.02)
        var assets: [AVURLAsset] = []
        var lengths: [Double] = []
        var captions: [Caption] = []
        var offset = 0.0
        for (n, part) in manifest.parts.enumerated() {
            let url = folder.appendingPathComponent(part.file)
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration).seconds
            let envelope = await Task.detached { Self.envelope(url) }.value
            captions += Self.captions(for: part.line, envelope: envelope, length: length).map {
                Caption(text: $0.text, start: $0.start + offset, end: $0.end + offset, highlight: nil)
            }
            assets.append(asset); lengths.append(length); offset += length
            progress("对字幕", 0.02 + 0.18 * Double(n + 1) / Double(manifest.parts.count))
        }
        let total = offset

        // 2. 包装方案
        progress("设计包装", 0.22)
        var plan = Plan(hook: String(manifest.title.prefix(14)), captions: captions, cards: [])
        if store.analysisAvailable {
            do { plan = try await design(captions: captions, title: manifest.title, store: store) }
            catch { store.addLog("包装方案没拿到，只做字幕：\(error.localizedDescription)") }
        }
        if plan.captions.allSatisfy({ $0.highlight == nil }) {
            // 没有模型：句子里的数字自动强调
            for i in plan.captions.indices {
                if let r = plan.captions[i].text.range(of: #"[0-9一二三四五六七八九十百千万]+[个条段秒天年倍%％]?"#, options: .regularExpression) {
                    plan.captions[i].highlight = String(plan.captions[i].text[r])
                }
            }
        }
        progress("设计包装", 0.3)

        // 3. 拼时间线 + 叠包装层 + 导出
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw PackError.empty }
        var cursor = CMTime.zero
        var natural = CGSize(width: 1280, height: 720)
        var transform = CGAffineTransform.identity
        var frameRate: Float = 24
        for (n, asset) in assets.enumerated() {
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: lengths[n], preferredTimescale: 600))
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try vTrack.insertTimeRange(range, of: v, at: cursor)
                if n == 0 {
                    natural = try await v.load(.naturalSize)
                    transform = try await v.load(.preferredTransform)
                    frameRate = try await v.load(.nominalFrameRate)
                }
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                let aRange = try await a.load(.timeRange)
                try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: min(range.duration, aRange.duration)), of: a, at: cursor)
            }
            cursor = cursor + range.duration
        }
        let size = natural.applying(transform)
        let render = CGSize(width: abs(size.width), height: abs(size.height))
        let background = await Self.backgroundColor(assets[0])

        let video = AVMutableVideoComposition()
        video.renderSize = render
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate > 1 ? frameRate.rounded() : 24))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        video.instructions = [instruction]
        let (parent, videoLayer) = Self.layers(plan: plan, size: render, total: total, background: background)
        video.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        try? FileManager.default.removeItem(at: out)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw PackError.export("导出器没建成") }
        exporter.videoComposition = video
        exporter.shouldOptimizeForNetworkUse = true
        let watch = Task { @MainActor in
            for await state in exporter.states(updateInterval: 0.3) {
                if case .exporting(let p) = state { progress("渲染成片", 0.3 + 0.7 * p.fractionCompleted) }
            }
        }
        defer { watch.cancel() }
        try await exporter.export(to: out, as: .mp4)
        progress("渲染成片", 1)
        store.addLog("包装好了：\(out.lastPathComponent)，字幕 \(plan.captions.count) 句，要点卡 \(plan.cards.count) 张")
    }

    enum PackError: LocalizedError {
        case empty, export(String)
        var errorDescription: String? {
            switch self {
            case .empty: "没有可以包装的分段。"
            case .export(let why): "成片没导出来：\(why)"
            }
        }
    }

    // MARK: 对字幕

    /// 每 10 毫秒一个音量值（分贝）。
    nonisolated static func envelope(_ url: URL) -> [Float] {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        asset.loadTracks(withMediaType: .audio) { tracks, _ in track = tracks?.first; semaphore.signal() }
        semaphore.wait()
        guard let track, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 16000,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        return stride(from: 0, to: samples.count, by: 160).map { i in
            let end = min(i + 160, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            return 10 * log10(max(sum / Float(end - i), 1e-10))
        }
    }

    /// 稿子切成短句，按说话声音分时间。返回的时间相对这一段的开头。
    static func captions(for line: String, envelope: [Float], length: Double) -> [(text: String, start: Double, end: Double)] {
        let phrases = Self.phrases(line)
        guard !phrases.isEmpty else { return [] }
        // 找开口和收口：比底噪高 12 分贝以上算在说话
        let floor = envelope.sorted().dropFirst(envelope.count / 20).first ?? -60
        let threshold = max(floor + 12, -48)
        let speaking = envelope.map { $0 > threshold }
        let first = speaking.firstIndex(of: true) ?? 0
        let last = speaking.lastIndex(of: true) ?? max(envelope.count - 1, 0)
        var start = Double(first) / 100, end = min(Double(last + 1) / 100 + 0.15, length)
        if envelope.isEmpty || end - start < 1 { start = 0.2; end = max(length - 0.3, 0.5) }
        // 句间停顿：说话中间 0.15 秒以上的安静
        var pauses: [Double] = []
        var run = 0
        for i in first...max(first, last) where i < speaking.count {
            if !speaking[i] { run += 1 } else {
                if run >= 15 { pauses.append(Double(i) / 100 - Double(run) / 200) }
                run = 0
            }
        }
        let weights = phrases.map(Self.weight)
        let sum = weights.reduce(0, +)
        var bounds: [Double] = [start]
        var acc = 0.0
        for w in weights.dropLast() {
            acc += w
            var t = start + (end - start) * acc / sum
            if let near = pauses.min(by: { abs($0 - t) < abs($1 - t) }), abs(near - t) < 0.6 { t = near }
            bounds.append(max(t, (bounds.last ?? 0) + 0.4))
        }
        bounds.append(max(end, (bounds.last ?? 0) + 0.4))
        return phrases.indices.map { (phrases[$0], bounds[$0], bounds[$0 + 1]) }
    }

    /// 按标点切短句，一句最多 16 个字；标点只留问号和感叹号。
    static func phrases(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in line {
            if "，。！？；：、,.!?;:".contains(ch) {
                if "！？!?".contains(ch) { current.append(ch) }
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
            } else { current.append(ch) }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        // 太长的切成差不多长的几截：按显示宽度算（英文字母算半个字），英文单词不劈开
        var split: [String] = []
        for p in out {
            if Self.width(p) <= 16 { split.append(p); continue }
            let tokens = Self.tokens(p)
            let pieces = Int((Self.width(p) / 15).rounded(.up))
            let target = Self.width(p) / Double(pieces)
            var current = ""
            for t in tokens {
                if !current.isEmpty, Self.width(current) + Self.width(t) / 2 > target, split.count < pieces * 10 {
                    split.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                }
                current += t
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { split.append(current.trimmingCharacters(in: .whitespaces)) }
        }
        var merged: [String] = []
        for p in split where !p.isEmpty {
            if let lastPhrase = merged.last, Self.width(lastPhrase) < 4, Self.width(lastPhrase) + Self.width(p) <= 16 {
                merged[merged.count - 1] = lastPhrase + " " + p
            } else { merged.append(p) }
        }
        return merged.map { $0.replacingOccurrences(of: #"(?<=[\p{Han}]) (?=[\p{Han}])"#, with: "", options: .regularExpression) }
    }

    /// 显示宽度：汉字 1，英文字母、数字、空格约半个字。
    static func width(_ s: String) -> Double {
        s.reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1) }
    }

    /// 切成可以断开的小块：汉字一个一块，英文单词连着后面的空格算一块。
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in s {
            if ch.isASCII, !ch.isWhitespace { word.append(ch); continue }
            if ch.isWhitespace { word.append(ch); out.append(word); word = ""; continue }
            if !word.isEmpty { out.append(word); word = "" }
            out.append(String(ch))
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// 念这句大概要多久的相对值：汉字 1，英文字母约半个字。
    static func weight(_ s: String) -> Double {
        s.reduce(0.0) { sum, ch in
            if ch.isWhitespace || ch.isPunctuation { return sum }
            if ch.isASCII { return sum + (ch.isNumber ? 0.6 : 0.42) }
            return sum + 1
        } + 0.3
    }

    // MARK: 包装方案

    private struct Design: Decodable {
        struct Mark: Decodable { var i: Int; var word: String }
        struct CardSpec: Decodable { var i: Int; var label: String?; var big: String; var small: String? }
        var hook: String?
        var highlights: [Mark]?
        var cards: [CardSpec]?
    }

    static func design(captions: [Caption], title: String, store: BeanStore) async throws -> Plan {
        let numbered = captions.enumerated().map { String(format: "%d [%.1fs] %@", $0.offset, $0.element.start, $0.element.text) }.joined(separator: "\n")
        let system = """
        你是短视频口播的剪辑包装师。下面是一条数字人口播的字幕，每行是「序号 [开始秒] 字幕」。请给出包装方案，只回 JSON：
        {"hook": "开场大标题，8 到 14 个字，抓人、说清这条讲什么，不用标点",
         "highlights": [{"i": 序号, "word": "这句里要变色强调的词，必须原样出现在这句字幕里，2 到 6 个字"}],
         "cards": [{"i": 序号, "label": "卡片角标，2 到 5 个字，比如 第一步 / 关键 / 妙招", "big": "卡片大字，2 到 8 个字", "small": "一句补充，8 到 18 个字"}]}
        要求：highlights 挑最关键的名词、数字、结论，大约三句挑一句，不要每句都有；
        cards 是这条视频的要点卡（画面会切到卡片），挑 3 到 5 个真正的要点或步骤，放在讲到这个要点的那一句上，
        第一张不早于 4 秒，两张之间至少隔 6 秒，最后一张不晚于倒数第 2 句；卡片文字不能编造稿子里没有的事实。
        """
        let user = "视频标题：\(title)\n\n\(numbered)"
        let reply = try await store.withLLM { config in
            try await Analyzer.chat(config, system: system, user: user, json: true)
        }
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let d = try? JSONDecoder().decode(Design.self, from: Data(reply[start...end].utf8)) else { throw PackError.export("模型回的不是 JSON") }

        var out = captions
        for m in d.highlights ?? [] where out.indices.contains(m.i) {
            let w = m.word.trimmingCharacters(in: .whitespaces)
            if w.count >= 1, out[m.i].text.contains(w) { out[m.i].highlight = w }
        }
        // 卡片：从那一句开始，至少 2.6 秒、最多 4.2 秒，彼此不重叠
        var cards: [Card] = []
        let total = captions.last?.end ?? 0
        for c in (d.cards ?? []).sorted(by: { $0.i < $1.i }) where captions.indices.contains(c.i) {
            let start = captions[c.i].start
            guard start >= 3.2, start < total - 3, start >= (cards.last?.end ?? 0) + 2 else { continue }
            let nextEnd = captions.indices.contains(c.i + 1) ? captions[c.i + 1].end : captions[c.i].end
            let end = min(max(start + 2.6, min(nextEnd, start + 4.2)), total - 0.5)
            cards.append(Card(label: String((c.label ?? "要点").prefix(6)), big: String(c.big.prefix(10)), small: String((c.small ?? "").prefix(22)), start: start, end: end))
            if cards.count == 5 { break }
        }
        let hook = (d.hook ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        return Plan(hook: String((hook.isEmpty ? title : hook).prefix(16)), captions: out, cards: cards)
    }

    // MARK: 画面

    /// 数字人背景的颜色：要点卡出现时人往旁边让，让出来的地方用同样的颜色补上，看不出接缝。
    static func backgroundColor(_ asset: AVURLAsset) async -> CGColor {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else {
            return CGColor(gray: 0.75, alpha: 1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for (x, y) in [(0.97, 0.15), (0.97, 0.5), (0.97, 0.85), (0.92, 0.3), (0.92, 0.7)] {
            if let c = rep.colorAt(x: Int(Double(rep.pixelsWide) * x), y: Int(Double(rep.pixelsHigh) * y))?.usingColorSpace(.sRGB) {
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
        }
        guard n > 0 else { return CGColor(gray: 0.75, alpha: 1) }
        return CGColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
    }

    static let accent = NSColor(srgbRed: 0.957, green: 0.247, blue: 0.369, alpha: 1)     // 豆仓的玫瑰红
    static let highlight = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.24, alpha: 1)       // 字幕强调的暖黄

    static func layers(plan: Plan, size: CGSize, total: Double, background: CGColor) -> (CALayer, CALayer) {
        let w = size.width, h = size.height
        let portrait = h > w
        let unit = min(w, h) / 720      // 按 720p 设计，别的尺寸等比放大缩小
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.backgroundColor = background
        parent.isGeometryFlipped = false
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        // 开场标题卡也算一张卡：前 3 秒
        var cards = plan.cards
        cards.insert(Card(label: "今天聊", big: plan.hook, small: "", start: 0.15, end: min(3.0, total * 0.3)), at: 0)

        // 要点卡：横屏时人往左让三分之一，卡片从右边滑进来；竖屏时卡片放在人胸口下面
        let shift = portrait ? 0 : -w * 0.17
        for (n, card) in cards.enumerated() {
            let image = Self.cardImage(card, hook: n == 0, maxWidth: portrait ? w * 0.84 : (n == 0 ? w * 0.4 : w * 0.36), unit: unit)
            let layer = CALayer()
            let cw = CGFloat(image.width) / 2, ch = CGFloat(image.height) / 2
            let x = portrait ? (w - cw) / 2 : min(w * 0.585, w - cw + 24 * unit - 40 * unit)     // 图里四周留了 24 的阴影位，卡片本体离右边 40
            let y = portrait ? h * 0.30 : (h - ch) / 2 + 20 * unit
            layer.frame = CGRect(x: x, y: y, width: cw, height: ch)
            layer.contents = image
            layer.opacity = 0
            let fade = keyframes("opacity", [0, 1, 1, 0], card, edge: 0.3)
            let slide = keyframes("position.x", [layer.position.x + 60 * unit, layer.position.x, layer.position.x, layer.position.x + 30 * unit], card, edge: 0.35)
            layer.add(fade, forKey: "fade"); layer.add(slide, forKey: "slide")
            parent.addSublayer(layer)
            if shift != 0 {
                let x0 = videoLayer.position.x
                videoLayer.add(keyframes("position.x", [x0, x0 + shift, x0 + shift, x0], card, edge: 0.35), forKey: "make-room-\(n)")
                // 人让开之后画面右边缘会露出一条接缝：贴一条从透明到背景色的渐变，跟着画面一起走
                let seam = CAGradientLayer()
                seam.startPoint = CGPoint(x: 0, y: 0.5); seam.endPoint = CGPoint(x: 1, y: 0.5)
                seam.colors = [background.copy(alpha: 0)!, background, background]
                seam.locations = [0, NSNumber(value: Double(180 * unit / (180 * unit - shift))), 1]     // 渐变刚好在画面边缘变实
                seam.frame = CGRect(x: w - 180 * unit, y: 0, width: 180 * unit - shift, height: h)
                seam.opacity = 0
                let sx = seam.position.x
                seam.add(keyframes("position.x", [sx, sx + shift, sx + shift, sx], card, edge: 0.35), forKey: "follow")
                seam.add(keyframes("opacity", [0, 1, 1, 0], card, edge: 0.35), forKey: "fade")
                parent.insertSublayer(seam, above: videoLayer)
            }
        }

        // 底部字幕
        for c in plan.captions where c.end > c.start {
            let image = Self.captionImage(c, width: w * 0.86, unit: unit)
            let layer = CALayer()
            let cw = CGFloat(image.width) / 2, ch = CGFloat(image.height) / 2
            layer.frame = CGRect(x: (w - cw) / 2, y: portrait ? h * 0.17 : 34 * unit, width: cw, height: ch)
            layer.contents = image
            layer.opacity = 0
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [1, 1]
            a.beginTime = AVCoreAnimationBeginTimeAtZero + c.start
            a.duration = max(c.end - c.start - 0.02, 0.1)
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "show")
            parent.addSublayer(layer)
        }

        // 顶部细进度条
        let track = CALayer()
        track.frame = CGRect(x: 0, y: h - 6 * unit, width: w, height: 6 * unit)
        track.backgroundColor = CGColor(gray: 1, alpha: 0.28)
        parent.addSublayer(track)
        let bar = CALayer()
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.frame = track.frame
        bar.backgroundColor = accent.cgColor
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0; grow.toValue = w
        grow.beginTime = AVCoreAnimationBeginTimeAtZero; grow.duration = total
        grow.isRemovedOnCompletion = false; grow.fillMode = .both
        bar.add(grow, forKey: "grow")
        parent.addSublayer(bar)

        // AI 生成标注
        let tag = Self.tagImage("AI 生成", unit: unit)
        let tagLayer = CALayer()
        tagLayer.frame = CGRect(x: w - CGFloat(tag.width) / 2 - 22 * unit, y: h - CGFloat(tag.height) / 2 - 22 * unit, width: CGFloat(tag.width) / 2, height: CGFloat(tag.height) / 2)
        tagLayer.contents = tag
        parent.addSublayer(tagLayer)
        return (parent, videoLayer)
    }

    private static func keyframes(_ path: String, _ values: [CGFloat], _ card: Card, edge: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        let d = max(card.end - card.start, edge * 2 + 0.1)
        a.values = values
        a.keyTimes = [0, NSNumber(value: edge / d), NSNumber(value: 1 - edge / d), 1]
        a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        a.beginTime = AVCoreAnimationBeginTimeAtZero + card.start
        a.duration = d
        a.isRemovedOnCompletion = false
        return a
    }

    // MARK: 画字（按两倍分辨率画成图，放进图层）

    private static func font(_ size: CGFloat, _ weight: String = "Semibold") -> NSFont {
        NSFont(name: "PingFangSC-\(weight)", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    private static func draw(_ size: CGSize, _ body: (CGContext) -> Void) -> CGImage {
        let scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func captionImage(_ c: Caption, width: CGFloat, unit: CGFloat) -> CGImage {
        var size = 44 * unit
        func text(_ stroke: Bool) -> NSAttributedString {
            let s = NSMutableAttributedString(string: c.text, attributes: [
                .font: font(size), .foregroundColor: stroke ? NSColor.black.withAlphaComponent(0.85) : NSColor.white,
                .strokeColor: NSColor.black.withAlphaComponent(0.85), .strokeWidth: stroke ? 14 : 0, .kern: 1 * unit,
            ])
            if !stroke, let word = c.highlight, let r = c.text.range(of: word) {
                s.addAttribute(.foregroundColor, value: highlight, range: NSRange(r, in: c.text))
            }
            return s
        }
        while text(false).size().width > width - 20 * unit, size > 26 * unit { size -= 2 * unit }
        let fill = text(false), outline = text(true)
        let box = CGSize(width: ceil(fill.size().width + 24 * unit), height: ceil(fill.size().height + 18 * unit))
        return draw(box) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 8 * unit
            shadow.shadowOffset = NSSize(width: 0, height: -2 * unit)
            shadow.set()
            outline.draw(at: CGPoint(x: 12 * unit, y: 9 * unit))
            NSShadow().set()
            fill.draw(at: CGPoint(x: 12 * unit, y: 9 * unit))
        }
    }

    static func cardImage(_ card: Card, hook: Bool, maxWidth: CGFloat, unit: CGFloat) -> CGImage {
        let pad = 30 * unit
        let inner = maxWidth - pad * 2
        var bigSize = (hook ? 58 : 66) * unit
        var bigString = card.big
        func big() -> NSAttributedString {
            let p = NSMutableParagraphStyle(); p.lineSpacing = 4 * unit; p.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: bigString, attributes: [.font: font(bigSize), .foregroundColor: NSColor(white: 0.08, alpha: 1), .paragraphStyle: p, .kern: -0.5 * unit])
        }
        // 卡片大字：先试一行（字可以缩到 46），放不下就从中间断成差不多长的两行，不留单个字孤零零一行
        while big().size().width > inner, bigSize > 46 * unit { bigSize -= 2 * unit }
        if big().size().width > inner {
            bigSize = (hook ? 58 : 66) * unit
            let tokens = Self.tokens(card.big)
            let half = Self.width(card.big) / 2
            var first = ""
            for t in tokens where Self.width(first) + Self.width(t) / 2 <= half { first += t }
            let rest = String(card.big.dropFirst(first.count))
            bigString = first.trimmingCharacters(in: .whitespaces) + "\n" + rest.trimmingCharacters(in: .whitespaces)
            while big().size().width > inner, bigSize > 30 * unit { bigSize -= 2 * unit }
        }
        let bigText = big()
        let bigRect = bigText.boundingRect(with: CGSize(width: inner, height: 1000), options: [.usesLineFragmentOrigin])
        let label = NSAttributedString(string: card.label, attributes: [.font: font(20 * unit), .foregroundColor: NSColor.white, .kern: 1 * unit])
        let smallP = NSMutableParagraphStyle(); smallP.lineSpacing = 3 * unit
        let small = NSAttributedString(string: card.small, attributes: [.font: font(26 * unit, "Medium"), .foregroundColor: NSColor(white: 0.36, alpha: 1), .paragraphStyle: smallP])
        let smallRect = card.small.isEmpty ? .zero : small.boundingRect(with: CGSize(width: inner, height: 400), options: [.usesLineFragmentOrigin])
        let labelSize = label.size()
        let pill = CGSize(width: labelSize.width + 24 * unit, height: labelSize.height + 10 * unit)
        let width = maxWidth
        let height = pad + pill.height + 18 * unit + ceil(bigRect.height) + (card.small.isEmpty ? 0 : 14 * unit + ceil(smallRect.height)) + pad
        let shadowRoom = 24 * unit
        let box = CGSize(width: width + shadowRoom * 2, height: height + shadowRoom * 2)
        return draw(box) { ctx in
            let rect = CGRect(x: shadowRoom, y: shadowRoom, width: width, height: height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 26 * unit, yRadius: 26 * unit)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 22 * unit
            shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
            shadow.set()
            NSColor(srgbRed: 1, green: 0.995, blue: 0.985, alpha: 0.97).setFill()
            shape.fill()
            NSShadow().set()
            // 左侧一条玫瑰红
            ctx.saveGState()
            shape.addClip()
            accent.setFill()
            NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: 8 * unit, height: rect.height)).fill()
            ctx.restoreGState()
            var y = rect.maxY - pad - pill.height
            let pillRect = CGRect(x: rect.minX + pad, y: y, width: pill.width, height: pill.height)
            accent.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pillRect.minX + 12 * unit, y: pillRect.minY + 5 * unit))
            y -= 18 * unit + ceil(bigRect.height)
            bigText.draw(with: CGRect(x: rect.minX + pad, y: y, width: inner, height: ceil(bigRect.height)), options: [.usesLineFragmentOrigin])
            if !card.small.isEmpty {
                y -= 14 * unit + ceil(smallRect.height)
                small.draw(with: CGRect(x: rect.minX + pad, y: y, width: inner, height: ceil(smallRect.height)), options: [.usesLineFragmentOrigin])
            }
        }
    }

    static func tagImage(_ text: String, unit: CGFloat) -> CGImage {
        let s = NSAttributedString(string: text, attributes: [.font: font(17 * unit, "Medium"), .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
        let t = s.size()
        let box = CGSize(width: ceil(t.width + 22 * unit), height: ceil(t.height + 10 * unit))
        return draw(box) { _ in
            NSColor.black.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: box), xRadius: box.height / 2, yRadius: box.height / 2).fill()
            s.draw(at: CGPoint(x: 11 * unit, y: 5 * unit))
        }
    }
}
