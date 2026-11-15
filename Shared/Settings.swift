import Foundation
import Observation

/// 用户可调的选项，存在 UserDefaults 里。
@Observable
final class AppSettings {
    enum Engine: String, CaseIterable, Identifiable {
        case qwen, apple, cloud
        var id: String { rawValue }
        var name: String {
            switch self {
            case .qwen: "Qwen3‑ASR（本机）"
            case .apple: "系统语音识别"
            case .cloud: "云端转写"
            }
        }
        /// 这台机器上能选的引擎。手机上跑不动本机模型。
        static var available: [Engine] {
            #if os(macOS)
            [.qwen, .apple, .cloud]
            #else
            [.cloud, .apple]
            #endif
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var name: String { self == .system ? "跟随系统" : self == .light ? "浅色" : "深色" }
    }

    /// 整理纪要用哪边的模型。
    enum AnalysisMode: String, CaseIterable, Identifiable {
        case auto, cloud, local
        var id: String { rawValue }
        var name: String {
            switch self {
            case .auto: "云端优先，连不上时用本机"
            case .cloud: "只用云端"
            case .local: "只用本机"
            }
        }
    }

    var analysisMode: AnalysisMode { didSet { save("analysisMode", analysisMode.rawValue) } }
    var appearance: Appearance { didSet { save("appearance", appearance.rawValue) } }
    var profession: Profession { didSet { save("profession", profession.rawValue) } }
    var engine: Engine { didSet { save("engine", engine.rawValue) } }
    var language: String { didSet { save("language", language) } }
    var autoProcess: Bool { didSet { save("autoProcess", autoProcess) } }
    /// 录完一条就自动从录音豆下载。
    var autoDownload: Bool { didSet { save("autoDownload", autoDownload) } }
    /// 录完一条先问一句「留着还是不要」。
    var askKeep: Bool { didSet { save("askKeep", askKeep) } }
    /// 录音时边录边出字。
    var liveTranscribe: Bool { didSet { save("liveTranscribe", liveTranscribe) } }
    /// 纠错词库：模型老是听错的词 → 正确的写法。转写出来之后自动替换。
    var vocabulary: [VocabEntry] { didSet { UserDefaults.standard.set(vocabulary.map { ["wrong": $0.wrong, "right": $0.right] }, forKey: "vocabulary") } }
    struct VocabEntry: Identifiable, Equatable { var wrong: String; var right: String; var id: String { wrong } }
    /// 实时字幕里去掉语气词。
    var liveTidy: Bool { didSet { save("liveTidy", liveTidy) } }
    var liveFontSize: Double { didSet { save("liveFontSize", liveFontSize) } }
    /// 语音输入：按住右 Option 说话，松开把文字打进当前 App。
    var dictationEnabled: Bool { didSet { save("dictationEnabled", dictationEnabled) } }
    /// 语音输入时用分析模型把口语理顺。更通顺，但要多等几秒。
    /// 按住哪个键说话。存的是按键码，默认右 Option（61）。
    var dictationKey: Int { didSet { save("dictationKey", dictationKey) } }
    var dictationPolish: Bool { didSet { save("dictationPolish", dictationPolish) } }
    /// 给录音豆起的名字。只存在这台 Mac 上，设备本身不支持改名。
    var deviceAlias: String { didSet { save("deviceAlias", deviceAlias) } }

    /// 分析模型：任何兼容 OpenAI 接口的服务，本机的 Ollama、LM Studio 或云端都行。
    var llmBaseURL: String { didSet { save("llmBaseURL", llmBaseURL) } }
    var llmModel: String { didSet { save("llmModel", llmModel) } }
    /// 密钥存在钥匙串里（Keychain.swift），不进 UserDefaults。
    var llmKey: String { didSet { Keychain.set(llmKey, for: "llmKey") } }

    /// 翻译：译成什么语言、默认用哪种风格、自定义风格的提示词、外语素材导入后要不要自动翻译。
    var translateTo: String { didSet { save("translateTo", translateTo) } }
    var translateStyle: TranslateStyle { didSet { save("translateStyle", translateStyle.rawValue) } }
    var translatePrompt: String { didSet { save("translatePrompt", translatePrompt) } }
    var autoTranslate: Bool { didSet { save("autoTranslate", autoTranslate) } }
    /// 剪贴板里出现视频链接时提示导入。
    var watchClipboard: Bool { didSet { save("watchClipboard", watchClipboard) } }

    /// 云端转写：任何兼容 OpenAI「/audio/transcriptions」接口的服务。
    var asrBaseURL: String { didSet { save("asrBaseURL", asrBaseURL) } }
    var asrModel: String { didSet { save("asrModel", asrModel) } }
    var asrKey: String { didSet { Keychain.set(asrKey, for: "asrKey") } }
    var asrConfig: ASRConfig? {
        asrBaseURL.isEmpty || asrModel.isEmpty ? nil : ASRConfig(baseURL: asrBaseURL, model: asrModel, key: asrKey)
    }

    var llamaServerPath: String { didSet { save("llamaServerPath", llamaServerPath) } }
    var exportFolder: String { didSet { save("exportFolder", exportFolder) } }

    var llmConfigured: Bool { !llmBaseURL.isEmpty && !llmModel.isEmpty }
    var llmIsLocal: Bool { llmBaseURL.contains("127.0.0.1") || llmBaseURL.contains("localhost") }

    init() {
        let d = UserDefaults.standard
        analysisMode = AnalysisMode(rawValue: d.string(forKey: "analysisMode") ?? "") ?? .auto
        #if os(macOS)
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        #else
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        #endif
        profession = Profession(rawValue: d.string(forKey: "profession") ?? "") ?? .general
        #if os(macOS)
        engine = Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .qwen
        #else
        engine = Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .cloud
        #endif
        language = d.string(forKey: "language") ?? "zh-CN"
        autoProcess = d.object(forKey: "autoProcess") as? Bool ?? true
        autoDownload = d.object(forKey: "autoDownload") as? Bool ?? true
        liveTranscribe = d.object(forKey: "liveTranscribe") as? Bool ?? true
        askKeep = d.object(forKey: "askKeep") as? Bool ?? true
        liveFontSize = d.object(forKey: "liveFontSize") as? Double ?? 22
        liveTidy = d.object(forKey: "liveTidy") as? Bool ?? true
        vocabulary = (d.array(forKey: "vocabulary") as? [[String: String]] ?? []).compactMap { e in
            guard let w = e["wrong"], let r = e["right"], !w.isEmpty else { return nil }
            return VocabEntry(wrong: w, right: r)
        }
        dictationEnabled = d.object(forKey: "dictationEnabled") as? Bool ?? false
        dictationPolish = d.object(forKey: "dictationPolish") as? Bool ?? false
        dictationKey = d.object(forKey: "dictationKey") as? Int ?? 61
        deviceAlias = d.string(forKey: "deviceAlias") ?? ""
        llmBaseURL = d.string(forKey: "llmBaseURL") ?? ""
        llmModel = d.string(forKey: "llmModel") ?? ""
        llmKey = Keychain.migrate("llmKey")
        translateTo = d.string(forKey: "translateTo") ?? "简体中文"
        translateStyle = TranslateStyle(rawValue: d.string(forKey: "translateStyle") ?? "") ?? .general
        translatePrompt = d.string(forKey: "translatePrompt") ?? ""
        autoTranslate = d.object(forKey: "autoTranslate") as? Bool ?? true
        watchClipboard = d.object(forKey: "watchClipboard") as? Bool ?? true
        asrBaseURL = d.string(forKey: "asrBaseURL") ?? ""
        asrModel = d.string(forKey: "asrModel") ?? ""
        asrKey = Keychain.migrate("asrKey")
        llamaServerPath = d.string(forKey: "llamaServerPath") ?? ""
        exportFolder = d.string(forKey: "exportFolder") ?? ""
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    /// 整理用的云端服务预设。都是兼容 OpenAI 接口的地址（11-15 逐个探测过：不带密钥时都回 401，地址是对的）。
    /// model 是选了这家之后先填上的模型，空着就让用户从列表里挑；keyPage 是「去获取密钥」打开的页面。
    struct Provider: Identifiable, Hashable {
        var name: String
        var url: String
        var model = ""
        var keyPage = ""
        var local = false
        var id: String { url }
        var badge: String { String(name.first(where: { $0.isLetter && $0.isASCII }) ?? name.first ?? "?").uppercased() }
    }

    static let presets: [Provider] = [
        Provider(name: "小米 MiMo", url: "https://api.xiaomimimo.com/v1", model: "mimo-v2.6-pro", keyPage: "https://platform.xiaomimimo.com"),
        Provider(name: "DeepSeek", url: "https://api.deepseek.com/v1", model: "deepseek-chat", keyPage: "https://platform.deepseek.com/api_keys"),
        Provider(name: "通义千问", url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", keyPage: "https://bailian.console.aliyun.com"),
        Provider(name: "Kimi", url: "https://api.moonshot.cn/v1", keyPage: "https://platform.moonshot.cn/console/api-keys"),
        Provider(name: "豆包", url: "https://ark.cn-beijing.volces.com/api/v3", keyPage: "https://console.volcengine.com/ark"),
        Provider(name: "智谱 GLM", url: "https://open.bigmodel.cn/api/paas/v4", keyPage: "https://open.bigmodel.cn"),
        Provider(name: "MiniMax", url: "https://api.minimaxi.com/v1", keyPage: "https://platform.minimaxi.com"),
        Provider(name: "硅基流动", url: "https://api.siliconflow.cn/v1", keyPage: "https://cloud.siliconflow.cn/account/ak"),
        Provider(name: "OpenRouter", url: "https://openrouter.ai/api/v1", keyPage: "https://openrouter.ai/keys"),
        Provider(name: "Gemini", url: "https://generativelanguage.googleapis.com/v1beta/openai", keyPage: "https://aistudio.google.com/apikey"),
        Provider(name: "Claude", url: "https://api.anthropic.com/v1", keyPage: "https://console.anthropic.com/settings/keys"),
        Provider(name: "OpenAI", url: "https://api.openai.com/v1", keyPage: "https://platform.openai.com/api-keys"),
        Provider(name: "本机 Ollama", url: "http://127.0.0.1:11434/v1", local: true),
        Provider(name: "本机 LM Studio", url: "http://127.0.0.1:1234/v1", local: true),
    ]
}
