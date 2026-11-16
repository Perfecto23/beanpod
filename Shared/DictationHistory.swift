import Foundation

/// 语音输入记下的话（侧栏「语音输入」）：像输入法的历史，不进录音列表、不做 AI 整理。
extension BeanStore {
    /// 原声到期就删掉声音、留下文字（设置里能改天数，0 = 一直留着）。
    func purgeDictationAudio() {
        let days = settings.dictationAudioDays
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        var cleaned = 0
        for i in recordings.indices where recordings[i].isDictation && !recordings[i].textOnly && (recordings[i].date ?? .now) < cutoff {
            if playingID == recordings[i].id { stop() }
            try? FileManager.default.removeItem(at: wavURL(recordings[i].id))
            try? FileManager.default.removeItem(at: oggURL(recordings[i].id))
            recordings[i].textOnly = true
            cleaned += 1
        }
        if cleaned > 0 { saveLibrary(); addLog("语音输入：\(cleaned) 条的原声放满 \(days) 天，已清理（文字还在）") }
    }

    /// 这句其实很重要：挪进录音列表，照常转写整理。
    func convertDictationToRecording(_ id: UInt32) {
        guard let i = recordings.firstIndex(where: { $0.id == id }), recordings[i].isDictation else { return }
        recordings[i].origin = nil
        recordings[i].title = nil
        saveLibrary()
        addLog("语音输入转成录音：\(id)")
        process(id)
    }
}
