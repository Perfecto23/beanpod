import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(BeanStore.self) private var store
    @Environment(Dictation.self) private var dictation
    @State private var trusted = AXIsProcessTrusted()
    @State private var models: [String] = []
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("外观") {
                Picker("模式", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("我的职业", selection: $settings.profession) {
                    ForEach(Profession.allCases) { Text($0.name).tag($0) }
                }
                Text(settings.profession.focus).font(.callout).foregroundStyle(.secondary)
                Toggle("录音时实时转写（边录边出字）", isOn: $settings.liveTranscribe)
                Toggle("录完自动从录音豆下载", isOn: $settings.autoDownload)
                Toggle("下载后自动转写并整理", isOn: $settings.autoProcess)
            } header: { Text("整理方式") } footer: {
                Text("职业决定整理纪要时更看重什么。场景（会议、访谈、销售……）是每条录音自动判断的，判断错了可以在录音页面改。")
            }

            Section {
                Toggle("按住按键说话，松开输入文字", isOn: Binding(get: { settings.dictationEnabled },
                                                              set: { settings.dictationEnabled = $0; dictation.refresh(); if $0, !AXIsProcessTrusted() { dictation.requestAccessibility() } }))
                if settings.dictationEnabled {
                    HStack {
                        Picker("按住这个键", selection: $settings.dictationKey) {
                            ForEach(Dictation.keys, id: \.code) { Text($0.name).tag($0.code) }
                            if !Dictation.keys.contains(where: { $0.code == settings.dictationKey }) {
                                Text(Dictation.name(of: settings.dictationKey)).tag(settings.dictationKey)
                            }
                        }
                        Button(dictation.recordingKey ? "请按下想用的键…" : "录制") {
                            dictation.recordingKey.toggle()
                            dictation.refresh()
                        }
                        .help("点一下，然后按下你想用的修饰键")
                    }
                    Toggle("用分析模型把口语理顺（多等几秒）", isOn: $settings.dictationPolish)
                    Button("试一次（录 5 秒，只显示结果）") { dictation.tryOnce() }
                    LabeledContent("辅助功能权限") {
                        if trusted {
                            Label("已允许", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        } else {
                            HStack {
                                Text("未允许").foregroundStyle(Theme.amber)
                                Button("去授权") { dictation.requestAccessibility() }
                                Button("重新检查") { trusted = AXIsProcessTrusted(); dictation.refresh() }
                            }
                        }
                    }
                }
            } header: { Text("语音输入") } footer: {
                Text("把录音豆当随身麦克风：在任何 App 里按住你选的那个键，对着录音豆说话，松开后文字出现在光标处。需要「辅助功能」权限来监听这个按键并把文字打进其他 App；没有权限时文字只会放进剪贴板。")
            }

            Section("转写") {
                Picker("引擎", selection: $settings.engine) {
                    ForEach(AppSettings.Engine.allCases) { Text($0.name).tag($0) }
                }
                if settings.engine == .qwen {
                    LabeledContent("llama-server") {
                        Text(QwenASR.locateServer(custom: settings.llamaServerPath)?.path ?? "没找到").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    TextField("自定义 llama-server 位置（可不填）", text: $settings.llamaServerPath)
                    LabeledContent("模型") {
                        if let progress = store.modelDownload {
                            ProgressView(value: progress) { Text("正在下载 \(Int(progress * 100))%") }.frame(width: 200)
                        } else if QwenASR.locateModel() != nil {
                            Label("\(QwenASR.displayName) 已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        } else {
                            Button("下载 \(QwenASR.displayName)（约 1 GB）") { store.downloadASRModel() }
                        }
                    }
                    if !store.asrAvailable {
                        Text("Qwen3‑ASR 还不能用，暂时会改用系统语音识别。").font(.callout).foregroundStyle(Theme.amber)
                    }
                } else {
                    Picker("语言", selection: $settings.language) {
                        ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Text("两种引擎都在这台 Mac 上运行，录音不会上传。").font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Picker("用哪边", selection: $settings.analysisMode) {
                    ForEach(AppSettings.AnalysisMode.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("本机模型") {
                    if let progress = store.llmDownload {
                        ProgressView(value: progress) { Text("正在下载 \(Int(progress * 100))%") }.frame(width: 200)
                    } else if store.localLLMReady {
                        Label("\(LocalLLM.modelLabel) 已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    } else {
                        Button("下载 \(LocalLLM.displayName)（约 2.5 GB）") { store.downloadLocalLLM() }
                    }
                }
                HStack {
                    Text("也可以自己下载任意 GGUF 模型，放进模型文件夹。").font(.callout).foregroundStyle(.secondary)
                    Button("打开文件夹") {
                        try? FileManager.default.createDirectory(at: LocalLLM.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LocalLLM.folder)
                    }
                    Button("重新检查") { store.refreshASRAvailability() }
                }
            } header: { Text("分析模型") } footer: {
                Text("用来判断场景、写纪要、回答知识库提问。本机模型不联网，文字稿不出这台电脑；云端模型纪要质量更高，但文字稿会发给服务商（录音本身不会）。")
            }

            Section {
                Picker("服务", selection: Binding(get: { settings.llmBaseURL }, set: { settings.llmBaseURL = $0; models = []; testResult = nil })) {
                    Text("未设置").tag("")
                    ForEach(AppSettings.presets, id: \.url) { Text($0.name).tag($0.url) }
                    if !settings.llmBaseURL.isEmpty, !AppSettings.presets.contains(where: { $0.url == settings.llmBaseURL }) {
                        Text("自定义").tag(settings.llmBaseURL)
                    }
                }
                TextField("接口地址", text: $settings.llmBaseURL, prompt: Text("https://api.deepseek.com/v1"))
                HStack {
                    TextField("模型名", text: $settings.llmModel)
                    Menu("选择") {
                        ForEach(models, id: \.self) { m in Button(m) { settings.llmModel = m } }
                        if models.isEmpty { Text("先点「获取列表」") }
                    }
                    .fixedSize()
                    Button("获取列表") { Task { models = await Analyzer.listModels(baseURL: settings.llmBaseURL, key: settings.llmKey) } }
                        .disabled(settings.llmBaseURL.isEmpty)
                }
                if !settings.llmIsLocal { SecureField("API Key", text: $settings.llmKey) }
                HStack {
                    Button("测试") { test() }.disabled(!settings.llmConfigured || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
            } header: { Text("云端或自建服务") } footer: {
                Text("任何兼容 OpenAI 接口的服务都行。API Key 只存在这台 Mac 上。")
            }
            Section {
                if settings.vocabulary.isEmpty {
                    Text("还没有记住任何词。在文字稿里改一个词，或点「替换词语」，就可以把它记到这里。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(settings.vocabulary) { entry in
                    HStack {
                        Text(entry.wrong).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(entry.right)
                        Spacer()
                        Button("删除", systemImage: "minus.circle") { settings.vocabulary.removeAll { $0 == entry } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            } header: { Text("纠错词库") } footer: {
                Text("模型老是听错的人名、产品名、术语记在这里，以后转写出来会自动改成正确的写法。")
            }

            Section {
                LabeledContent("Claude、Codex、OpenClaw、Grok Bot") {
                    Button("打开连接页面…") { openWindow(id: "connect") }
                }
                LabeledContent("MCP 地址") {
                    HStack {
                        Text(BeanStore.mcpAddress).textSelection(.enabled).font(.callout.monospaced())
                        Button("拷贝") { copy(BeanStore.mcpAddress) }
                    }
                }
                LabeledContent("命令行") { Text("beanpod").font(.callout.monospaced()).textSelection(.enabled) }
            } header: { Text("连接 AI 助手") } footer: {
                Text("豆仓开着时，Claude、Grok、OpenClaw 等工具可以通过这个地址或命令行查你的录音、纪要和待办，也能把文字和音频存进来。地址只在这台电脑上能访问。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 780)
        .preferredColorScheme(settings.appearance.scheme)
        .onAppear { store.refreshASRAvailability() }
    }

    private func test() {
        guard let config = store.cloudConfig else { return }
        testing = true; testResult = nil
        Task {
            defer { testing = false }
            do {
                let a = try await Analyzer.analyze(
                    transcript: "王总您好，我是小李。这套系统年费三万八，含五个席位。您说预算三万以内，我申请到这个月签可以三万二，再送两个月服务。除了您还要财务张姐确认对吧？我周四把合同发您邮箱，周五再给您打电话。",
                    duration: 40, profession: store.settings.profession, fixedScene: nil, config: config)
                store.upgradeRoughNotes()
                testResult = a.scene == .sales || a.scene == .call
                    ? "可用。把一段销售通话判成了「\(a.scene.name)」，标题：\(a.title)"
                    : "能连上，但把一段销售通话判成了「\(a.scene.name)」，这个模型可能偏弱。"
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
