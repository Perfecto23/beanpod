import Foundation
import Speech

nonisolated enum TranscribeError: LocalizedError {
    case denied, unsupported(String), failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "没有语音识别权限，请到 系统设置 → 隐私与安全性 → 语音识别 里打开。")
        case .unsupported(let lang): String(localized: "这台 Mac 不支持「\(lang)」的本机识别。")
        case .failed(let why): String(localized: "转写失败：\(why)")
        }
    }
}

/// 用系统自带的语音识别在本机转写，录音不出这台电脑。
nonisolated enum Transcriber {
    static let languages: [(id: String, name: String)] = [
        ("zh-CN", "普通话"), ("zh-TW", "國語（繁體）"), ("yue-CN", "粤语"), ("en-US", "English"), ("ja-JP", "日本語"),
    ]

    static func transcribe(_ url: URL, language: String) async throws -> String {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscribeError.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw TranscribeError.unsupported(language) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var finished = false
            recognizer.recognitionTask(with: request) { @Sendable result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    finished = true
                    continuation.resume(throwing: TranscribeError.failed(error.localizedDescription))
                }
            }
        }
    }
}
