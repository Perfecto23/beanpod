import BeanKit
import Foundation

// 手机上没有的几样东西的替身。
//
// 核心代码（BeanStore、Pipeline）是 Mac 和 iPhone 共用的，里面会问「本机转写模型在不在」「本机分析模型在不在」。
// 手机上跑不动这些模型，所以这里给出同名的类型，一律回答「没有」，转写和整理都走云端。

/// 本机转写（Mac 上是 llama.cpp 跑 Qwen3‑ASR）。手机上没有。
actor QwenASR {
    static let shared = QwenASR()
    static let modelName = ""
    static let projectorName = ""
    static let displayName = "Qwen3‑ASR"
    nonisolated static var modelFolder: URL { FileManager.default.temporaryDirectory }
    nonisolated static func locateServer(custom: String) -> URL? { nil }
    nonisolated static func locateModel() -> (model: URL, projector: URL)? { nil }
    func stop() {}
    func warmUp(serverPath: String) async {}
    func transcribe(samples: [Float], serverPath: String) async throws -> String { throw ASRError.noModel }
    func transcribe(_ url: URL, serverPath: String, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] { throw ASRError.noModel }
}

/// 本机分析模型（Mac 上是 llama.cpp 跑 Qwen3‑4B）。手机上没有。
actor LocalLLM {
    static let shared = LocalLLM()
    static let fileName = ""
    static let displayName = "本机模型"
    static let downloadBase = ""
    static let downloadSize = 1.0
    nonisolated static var folder: URL { FileManager.default.temporaryDirectory }
    nonisolated static var modelURL: URL? { nil }
    nonisolated static var modelLabel: String { displayName }
    func ensureRunning(serverPath: String) async throws -> LLMConfig { throw AnalyzerError.notConfigured }
    func stop() {}
}

/// 录「电脑里播放的声音」（Mac 上用 ScreenCaptureKit）。手机上系统不让应用这么做。
nonisolated final class SystemAudioTap: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-unused.caf")
    var startedAt: Date? { nil }
    var error: String? { nil }
    func start() async throws { throw ASRError.badAudio }
    func setPaused(_ on: Bool) {}
    func takeLevel() -> Float { 0 }
    func stop() async {}
}
