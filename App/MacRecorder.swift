import AVFoundation
import AppKit

/// 不连录音豆也能录：用这台 Mac。可以录麦克风（外界的声音）、录电脑里播放的声音，或者两路一起录。
/// 录完和录音豆的录音走同一条路——转写、整理、进知识库。
extension BeanStore {
    enum MacRec { case off, recording, paused }

    /// 用 Mac 录音时录哪一路。
    enum MacSource: String, CaseIterable, Identifiable {
        case mic, system, both
        var id: String { rawValue }
        var name: String {
            switch self {
            case .mic: "麦克风"
            case .system: "电脑里的声音"
            case .both: "麦克风 + 电脑里的声音"
            }
        }
        var hint: String {
            switch self {
            case .mic: "外界的声音：面对面开会、自己口述"
            case .system: "电脑里播放的声音：视频、播客、网课"
            case .both: "你说的话加对方的声音：线上会议、语音通话"
            }
        }
        var usesMic: Bool { self != .system }
        var usesSystem: Bool { self != .mic }
    }

    func startMacRecording(_ source: MacSource? = nil) {
        guard macRec == .off, !macStarting else { return }
        let source = source ?? macSource
        macSource = source
        macStarting = true
        Task {
            defer { macStarting = false }
            var recorder: AVAudioRecorder?
            var tap: SystemAudioTap?
            if source.usesMic {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    problem = Problem(title: "豆仓用不了这台 Mac 的麦克风",
                                      detail: "到「系统设置 → 隐私与安全性 → 麦克风」里把豆仓打开，再点一次录音。", action: .micPermission)
                    return
                }
            }
            if source.usesSystem {
                let t = SystemAudioTap()
                do { try await t.start() } catch {
                    problem = Problem(title: "豆仓还不能录电脑里的声音",
                                      detail: "系统要你亲自允许一次：到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」里把豆仓打开，然后退出豆仓再重新打开。\n豆仓只取其中的声音，不会保存屏幕画面。", action: .screenPermission)
                    addLog("系统声音没开始：\(error.localizedDescription)")
                    return
                }
                tap = t
            }
            if source.usesMic {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-mac-\(UUID().uuidString).wav")
                let format: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ]
                guard let r = try? AVAudioRecorder(url: url, settings: format), r.record() else {
                    await tap?.stop()
                    problem = Problem(title: "这台 Mac 的麦克风没有开始录音", detail: "可能有别的软件正占着麦克风，或者没有接入任何麦克风。")
                    return
                }
                r.isMeteringEnabled = true
                recorder = r
                macMicStarted = .now
            }
            macRecorder = recorder
            macTap = tap
            macRec = .recording
            elapsedBase = 0
            recordingSince = .now
            liveMarks = []; liveSegments = []; liveLevels = []; liveLevelTotal = 0
            liveNote = nil
            addLog("开始用 Mac 录音：\(source.name)")
            macMeter?.cancel()
            macMeter = Task { [weak self] in
                while let self, !Task.isCancelled, self.macRec != .off {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard self.macRec == .recording else { continue }
                    var level: Float = 0.02
                    if let r = self.macRecorder {
                        r.updateMeters()
                        // 分贝换成 0…1：-50 dB 以下当作安静，-5 dB 算顶
                        level = max(level, min(1, (r.averagePower(forChannel: 0) + 50) / 45))
                    }
                    if let t = self.macTap { level = max(level, t.takeLevel()) }
                    self.liveLevels = Array((self.liveLevels + [level]).suffix(240))
                    self.liveLevelTotal += 1
                }
            }
        }
    }

    func pauseMacRecording() {
        guard macRec == .recording else { return }
        macRecorder?.pause()
        macTap?.setPaused(true)
        elapsedBase = elapsed(); recordingSince = nil
        macRec = .paused
    }

    func resumeMacRecording() {
        guard macRec == .paused else { return }
        macRecorder?.record()
        macTap?.setPaused(false)
        recordingSince = .now
        macRec = .recording
    }

    func finishMacRecording() {
        guard macRec != .off else { return }
        let marks = Self.mergeMarks(liveMarks)
        let recorder = macRecorder, tap = macTap, source = macSource, micStarted = macMicStarted
        recorder?.stop()
        macMeter?.cancel(); macMeter = nil
        macRecorder = nil; macTap = nil
        macRec = .off
        elapsedBase = 0; recordingSince = nil
        Task {
            await tap?.stop()
            if let reason = tap?.error { addLog("系统声音采集中途报错：\(reason)") }
            // 把两路声音合成一个文件：各自解成 16 kHz 单声道，按开始时间对齐后相加
            let micURL = recorder?.url, systemURL = tap?.url, systemStarted = tap?.startedAt
            let mixed: URL? = await Task.detached {
                let mic = micURL.flatMap { Self.decodeAnyAudio($0) } ?? []
                var system = systemURL.flatMap { Self.decodeAnyAudio($0) } ?? []
                if let a = micStarted, let b = systemStarted, !mic.isEmpty, !system.isEmpty {
                    // 系统那一路开始得晚就在前面补静音，开始得早就把多出来的头去掉
                    let offset = Int(b.timeIntervalSince(a) * 16000)
                    if offset > 0 { system = [Float](repeating: 0, count: offset) + system }
                    else if offset < 0 { system = Array(system.dropFirst(min(-offset, system.count))) }
                }
                let count = max(mic.count, system.count)
                guard count > 1600 else { return nil }
                var out = [Float](repeating: 0, count: count)
                for i in 0..<mic.count { out[i] += mic[i] }
                for i in 0..<system.count { out[i] += system[i] }
                if !mic.isEmpty, !system.isEmpty { for i in 0..<count { out[i] = max(-1, min(1, out[i])) } }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-mac-\(UUID().uuidString).wav")
                return (try? QwenASR.wav(out).write(to: url, options: .atomic)) != nil ? url : nil
            }.value
            for u in [micURL, systemURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
            guard let mixed else {
                problem = Problem(title: "这次没有录到声音",
                                  detail: source.usesSystem ? "电脑里这段时间没有播放任何声音，或者系统没有把声音交给豆仓。" : "麦克风没有录到内容。")
                return
            }
            let before = Set(recordings.map(\.id))
            importFile(mixed, consume: true)
            // 刚导进来的那一条：标上来源和重点标记，标题留空（先显示时间，整理完会自动起名）
            if let i = recordings.firstIndex(where: { !before.contains($0.id) }) {
                recordings[i].origin = "Mac · " + source.name
                recordings[i].title = nil
                recordings[i].marks = marks.filter { $0 <= recordings[i].duration + 1 }
                saveLibrary()
                addLog("Mac 录音结束（\(source.name)）：\(Int(recordings[i].duration)) 秒，\(marks.count) 个标记")
            }
        }
    }
}
