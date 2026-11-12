import AVFoundation
import AppKit

/// 不连录音豆也能录：用这台 Mac 的麦克风。录完和录音豆的录音走同一条路——转写、整理、进知识库。
extension BeanStore {
    enum MacRec { case off, recording, paused }

    func startMacRecording() {
        guard macRec == .off else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = Problem(title: "豆仓用不了这台 Mac 的麦克风",
                                  detail: "到「系统设置 → 隐私与安全性 → 麦克风」里把豆仓打开，再点一次录音。")
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-mac-\(UUID().uuidString).wav")
            let format: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            guard let recorder = try? AVAudioRecorder(url: url, settings: format), recorder.record() else {
                problem = Problem(title: "这台 Mac 的麦克风没有开始录音", detail: "可能有别的软件正占着麦克风，或者没有接入任何麦克风。")
                return
            }
            recorder.isMeteringEnabled = true
            macRecorder = recorder
            macRec = .recording
            elapsedBase = 0
            recordingSince = .now
            liveMarks = []; liveSegments = []; liveLevels = []; liveLevelTotal = 0
            liveNote = nil
            addLog("开始用 Mac 麦克风录音")
            macMeter?.cancel()
            macMeter = Task { [weak self] in
                while let self, !Task.isCancelled, self.macRec != .off {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard self.macRec == .recording, let r = self.macRecorder else { continue }
                    r.updateMeters()
                    // 分贝换成 0…1：-50 dB 以下当作安静，-5 dB 算顶
                    let db = r.averagePower(forChannel: 0)
                    let level = max(0.02, min(1, (db + 50) / 45))
                    self.liveLevels = Array((self.liveLevels + [level]).suffix(240))
                    self.liveLevelTotal += 1
                }
            }
        }
    }

    func pauseMacRecording() {
        guard macRec == .recording else { return }
        macRecorder?.pause()
        elapsedBase = elapsed(); recordingSince = nil
        macRec = .paused
    }

    func resumeMacRecording() {
        guard macRec == .paused else { return }
        macRecorder?.record()
        recordingSince = .now
        macRec = .recording
    }

    func finishMacRecording() {
        guard macRec != .off, let recorder = macRecorder else { return }
        let marks = Self.mergeMarks(liveMarks)
        recorder.stop()
        macMeter?.cancel(); macMeter = nil
        macRecorder = nil
        macRec = .off
        elapsedBase = 0; recordingSince = nil
        let before = Set(recordings.map(\.id))
        importFile(recorder.url, consume: true)
        // 刚导进来的那一条：标上来源和重点标记，标题留空（先显示时间，整理完会自动起名）
        if let i = recordings.firstIndex(where: { !before.contains($0.id) }) {
            recordings[i].origin = "Mac 麦克风"
            recordings[i].title = nil
            recordings[i].marks = marks.filter { $0 <= recordings[i].duration + 1 }
            saveLibrary()
            addLog("Mac 录音结束：\(Int(recordings[i].duration)) 秒，\(marks.count) 个标记")
        }
    }
}
