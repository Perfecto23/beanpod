import SwiftUI

/// 设置窗口。分成五个页签，每页一屏放完：以前是一条很长的表单，找一个选项要滚半天，
/// 而且把「llama-server」这种只有开发者认识的词直接摆在用户面前。
struct SettingsView: View {
    enum Pane: String { case general, dictation, models, vocabulary, connect }

    @Environment(BeanStore.self) private var store
    @AppStorage("settingsPane") private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("通用", systemImage: "gearshape", value: Pane.general) { GeneralPane() }
            Tab("语音输入", systemImage: "mic", value: Pane.dictation) { DictationPane() }
            Tab("模型", systemImage: "cpu", value: Pane.models) { ModelsPane() }
            Tab("词库", systemImage: "character.book.closed", value: Pane.vocabulary) { VocabularyPane() }
            Tab("连接", systemImage: "link", value: Pane.connect) { ConnectPane() }
        }
        .preferredColorScheme(store.settings.appearance.scheme)
        .onAppear { store.refreshASRAvailability() }
    }
}

/// 「去设置」按钮：直接打开设置里的模型页。全应用里叫用户去设置的地方，缺的都是模型。
struct ModelSettingsLink: View {
    @Environment(\.openSettings) private var openSettings
    var title = "去设置"

    var body: some View {
        Button(title) { SettingsView.open(.models, with: openSettings) }
    }
}

extension SettingsView {
    static func open(_ pane: Pane, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        openSettings()
    }
}

// MARK: 搭页面用的零件

/// 一页设置的外框：固定宽度，高度跟着内容走，窗口会自己变高变矮。
private struct PaneFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 26)
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .background(Backdrop())
    }
}

/// 一组设置：小标题、一张卡片、卡片下面的说明。卡片里每一行之间自动加分隔线。
private struct SettingsGroup<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title { Text(title).font(.headline) }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { sub in
                        sub.padding(.horizontal, 16).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if sub.id != subviews.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
            .panel(radius: 14)
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// 一行设置：左边可选的小图标、标题和一行说明，右边是控件。
private struct SettingRow<Trailing: View>: View {
    var icon: String?
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// 「已就绪」「还差一步」这种状态小牌子。
private struct StatusPill: View {
    var ok: Bool
    var text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? Theme.ok : Theme.amber)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background((ok ? Theme.ok : Theme.amber).opacity(0.14), in: .capsule)
    }
}

// MARK: 通用

private struct GeneralPane: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        PaneFrame {
            SettingsGroup("外观") {
                HStack(spacing: 12) {
                    ForEach(AppSettings.Appearance.allCases) { mode in
                        AppearanceTile(mode: mode, selected: settings.appearance == mode) { settings.appearance = mode }
                    }
                }
                .padding(.vertical, 5)
            }

            SettingsGroup("我是做什么的", footer: "职业决定整理纪要时更看重什么。场景（会议、访谈、销售……）是每条录音自动判断的，判断错了可以在录音页面改。") {
                SettingRow(icon: "person.crop.circle", title: "我的职业", detail: settings.profession.focus) {
                    Picker("我的职业", selection: $settings.profession) {
                        ForEach(Profession.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsGroup("录音的时候和录完之后") {
                SettingRow(icon: "captions.bubble", title: "边录边出字", detail: "录音时在舞台上实时显示文字。") {
                    Toggle("边录边出字", isOn: $settings.liveTranscribe).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "questionmark.bubble", title: "录完先问一句留不留", detail: "录完弹一张小卡片，不要的话当场删掉，哪里都不留。十秒不理它就默认留着。") {
                    Toggle("录完先问一句留不留", isOn: $settings.askKeep).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "arrow.down.circle", title: "自动从录音豆下载", detail: "录完一条、或者重新连上录音豆时，把还没下载的拉到这台 Mac 上。") {
                    Toggle("自动从录音豆下载", isOn: $settings.autoDownload).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "wand.and.sparkles", title: "自动转写并整理", detail: "下载后直接出文字稿、纪要和待办。") {
                    Toggle("自动转写并整理", isOn: $settings.autoProcess).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

/// 外观的一个选项：一张小窗口缩略图加名字，选中的有琥珀色描边。
private struct AppearanceTile: View {
    var mode: AppSettings.Appearance
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.tertiary))
                    Text(mode.name).fontWeight(selected ? .semibold : .regular)
                }
                .font(.callout)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.background.opacity(selected ? 0.9 : 0.4), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 0.5))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            // 左半浅、右半深：跟着系统走
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true).mask(alignment: .trailing) {
                    GeometryReader { geo in Rectangle().frame(width: geo.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing) }
                }
            }
        }
    }
}

/// 豆仓窗口的缩略图：左边侧栏、红色录音键、右边几条内容。
private struct MiniWindow: View {
    var dark: Bool

    var body: some View {
        let ink = dark ? Color.white : Color.black
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Theme.rec).frame(width: 30, height: 7)
                ForEach(0..<3, id: \.self) { _ in Capsule().fill(ink.opacity(0.22)).frame(width: 24, height: 4) }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(ink.opacity(0.06))
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(ink.opacity(0.75)).frame(width: 52, height: 6)
                RoundedRectangle(cornerRadius: 4).fill(ink.opacity(0.1)).frame(height: 16)
                RoundedRectangle(cornerRadius: 4).fill(Theme.amber.opacity(0.55)).frame(width: 60, height: 16)
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(dark ? Theme.graphite : Theme.paper)
    }
}

// MARK: 语音输入

private struct DictationPane: View {
    @Environment(BeanStore.self) private var store
    @Environment(Dictation.self) private var dictation
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        @Bindable var settings = store.settings
        let on = settings.dictationEnabled
        PaneFrame {
            SettingsGroup(footer: "把录音豆当随身麦克风：在任何 App 里按住你选的那个键，对着录音豆说话，松开后文字出现在光标处。") {
                SettingRow(icon: "mic.fill", title: "按住按键说话，松开输入文字", detail: on ? "已打开。按住「\(Dictation.name(of: settings.dictationKey))」试试。" : "关着的时候，豆仓不会监听任何按键。") {
                    Toggle("语音输入", isOn: Binding(get: { settings.dictationEnabled }, set: {
                        settings.dictationEnabled = $0
                        dictation.refresh()
                        if $0, !AXIsProcessTrusted() { dictation.requestAccessibility() }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup("怎么用") {
                SettingRow(icon: "keyboard", title: "按住这个键", detail: dictation.recordingKey ? "现在按下你想用的那个键…" : nil) {
                    Picker("按住这个键", selection: $settings.dictationKey) {
                        ForEach(Dictation.keys, id: \.code) { Text($0.name).tag($0.code) }
                        if !Dictation.keys.contains(where: { $0.code == settings.dictationKey }) {
                            Text(Dictation.name(of: settings.dictationKey)).tag(settings.dictationKey)
                        }
                    }
                    .labelsHidden().fixedSize()
                    Button(dictation.recordingKey ? "取消" : "换一个键…") {
                        dictation.recordingKey.toggle()
                        dictation.refresh()
                    }
                    .help("点一下，然后按下你想用的修饰键")
                }
                SettingRow(icon: "text.badge.checkmark", title: "把口语理顺再输入", detail: "去掉嗯啊和重复，句子更通顺。要多等几秒。") {
                    Toggle("把口语理顺再输入", isOn: $settings.dictationPolish).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(icon: "play.circle", title: "先试一次", detail: "录 5 秒，只显示识别结果，不会打进别的 App。") {
                    Button("试一次") { dictation.tryOnce() }
                }
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.5)

            SettingsGroup("权限", footer: "豆仓要靠「辅助功能」权限来听到这个按键、把文字打进其他 App。没有权限时，文字只会放进剪贴板。") {
                SettingRow(icon: "hand.raised", title: "辅助功能") {
                    if trusted {
                        StatusPill(ok: true, text: "已允许")
                    } else {
                        StatusPill(ok: false, text: "未允许")
                        Button("去授权") { dictation.requestAccessibility() }
                        Button("重新检查") { trusted = AXIsProcessTrusted(); dictation.refresh() }
                    }
                }
            }
        }
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}

// MARK: 模型

/// 模型页的一张大卡片：卡片里面顶上是图标、标题和状态牌子。
private struct ModelCard<Content: View>: View {
    var icon: String
    var title: String
    var ok: Bool
    var status: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26).accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                StatusPill(ok: ok, text: status)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 16)
    }
}

private struct ModelsPane: View {
    @Environment(BeanStore.self) private var store
    @State private var advanced = false
    @State private var cloudSheet = false

    var body: some View {
        @Bindable var settings = store.settings
        let asrOK = store.asrAvailable || settings.engine == .apple
        PaneFrame {
            ModelCard(icon: "waveform", title: "转写：把声音变成文字", ok: asrOK, status: asrOK ? "已就绪" : "还差模型") {
                line("引擎") {
                    Picker("引擎", selection: $settings.engine) {
                        ForEach(AppSettings.Engine.available) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                if settings.engine == .qwen {
                    line("模型") {
                        if let progress = store.modelDownload {
                            ProgressView(value: progress).frame(width: 130)
                            Text("\(Int(progress * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        } else if QwenASR.locateModel() != nil {
                            Text("\(QwenASR.displayName) · 已下载").foregroundStyle(.secondary)
                        } else {
                            Button("下载（约 1 GB）") { store.downloadASRModel() }
                        }
                    }
                    if !store.asrAvailable {
                        Text("还没准备好之前，暂时用系统语音识别顶上。").font(.callout).foregroundStyle(Theme.amber)
                    }
                } else {
                    line("语言") {
                        Picker("语言", selection: $settings.language) {
                            ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Text("两种引擎都在这台 Mac 上运行，录音不会上传。").font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("高级", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        line("本机推理程序") { Button("重新检查") { store.refreshASRAvailability() } }
                        Text(QwenASR.locateServer(custom: settings.llamaServerPath)?.path ?? "没找到。本机转写和本机模型都靠它运行。")
                            .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        TextField("自己指定它的位置（可不填）", text: $settings.llamaServerPath).textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 8)
                }
            }

            ModelCard(icon: "doc.text", title: "整理：写纪要、回答提问", ok: store.analysisAvailable, status: store.analysisAvailable ? "已就绪" : "还没选模型") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("用哪边的模型", selection: $settings.analysisMode) {
                        Text("云端优先").tag(AppSettings.AnalysisMode.auto)
                        Text("只用云端").tag(AppSettings.AnalysisMode.cloud)
                        Text("只用本机").tag(AppSettings.AnalysisMode.local)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    Text(modeHint(settings.analysisMode)).font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 18) {
                    half("本机模型", dim: settings.analysisMode == .cloud) {
                        if let progress = store.llmDownload {
                            Text("正在下载 \(Int(progress * 100))%").font(.body.weight(.medium)).monospacedDigit()
                            ProgressView(value: progress)
                        } else if store.localLLMReady {
                            Text(LocalLLM.modelLabel).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Button("打开模型文件夹", action: openFolder)
                        } else {
                            Text("还没下载").font(.body.weight(.medium))
                            HStack {
                                Button("下载（约 2.5 GB）") { store.downloadLocalLLM() }
                                Button("打开模型文件夹", action: openFolder)
                            }
                        }
                    }
                    Divider()
                    half("云端或自建服务", dim: settings.analysisMode == .local) {
                        Text(cloudSummary).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Button(settings.llmConfigured ? "更改…" : "设置…") { cloudSheet = true }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("本机模型不联网，文字稿不出这台电脑。云端纪要质量更高，但文字稿会发给服务商，录音本身不会。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $cloudSheet) { CloudServiceSheet() }
    }

    private func line<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func half<Content: View>(_ title: String, dim: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim ? 0.45 : 1)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: LocalLLM.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LocalLLM.folder)
    }

    private func modeHint(_ mode: AppSettings.AnalysisMode) -> String {
        switch mode {
        case .auto: "平时用云端，连不上的时候自动换成本机。"
        case .cloud: "只用云端。连不上的时候不整理，等能连上再说。"
        case .local: "只用本机。文字稿不会离开这台电脑。"
        }
    }

    private var cloudSummary: String {
        let s = store.settings
        guard s.llmConfigured else { return "还没设置" }
        let name = AppSettings.presets.first { $0.url == s.llmBaseURL }?.name ?? "自定义服务"
        return "\(name) · \(s.llmModel)"
    }
}

/// 云端或自建服务的填写单。平时用不到这几个框，所以从模型页里拿出来，要改的时候再弹。
private struct CloudServiceSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = store.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端或自建服务").font(.title3.bold())
                Text("任何兼容 OpenAI 接口的服务都行。密钥只存在这台 Mac 上。").font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("服务").gridColumnAlignment(.trailing)
                    Picker("服务", selection: Binding(get: { settings.llmBaseURL }, set: { settings.llmBaseURL = $0; models = []; testResult = nil })) {
                        Text("未设置").tag("")
                        ForEach(AppSettings.presets, id: \.url) { Text($0.name).tag($0.url) }
                        if !settings.llmBaseURL.isEmpty, !AppSettings.presets.contains(where: { $0.url == settings.llmBaseURL }) {
                            Text("自定义").tag(settings.llmBaseURL)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("接口地址")
                    TextField("接口地址", text: $settings.llmBaseURL, prompt: Text("https://api.deepseek.com/v1")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("模型名")
                    HStack {
                        TextField("模型名", text: $settings.llmModel).textFieldStyle(.roundedBorder)
                        Menu("从列表里选") {
                            ForEach(models, id: \.self) { m in Button(m) { settings.llmModel = m } }
                            if models.isEmpty { Text("正在获取，或这个服务不提供列表") }
                        }
                        .fixedSize()
                        .disabled(settings.llmBaseURL.isEmpty)
                    }
                }
                if !settings.llmIsLocal {
                    GridRow {
                        Text("密钥")
                        SecureField("API Key", text: $settings.llmKey).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if let testResult {
                Text(testResult).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("测试一下") { test() }.disabled(!settings.llmConfigured || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: settings.llmBaseURL + settings.llmKey) {
            guard !settings.llmBaseURL.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            models = await Analyzer.listModels(baseURL: settings.llmBaseURL, key: settings.llmKey)
        }
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

// MARK: 词库

private struct VocabularyPane: View {
    @Environment(BeanStore.self) private var store
    @State private var wrong = ""
    @State private var right = ""
    @FocusState private var focus: Field?
    private enum Field { case wrong, right }

    private var canAdd: Bool {
        !wrong.trimmingCharacters(in: .whitespaces).isEmpty && !right.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        let settings = store.settings
        PaneFrame {
            SettingsGroup("纠错词库", footer: "模型老是听错的人名、产品名、术语记在这里，以后转写出来会自动改成正确的写法。在文字稿里改一个词，也会记到这里。") {
                HStack(spacing: 10) {
                    TextField("听成了", text: $wrong, prompt: Text("听成了，比如：豆苍")).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .wrong).onSubmit { focus = .right }
                    Image(systemName: "arrow.right").font(.callout).foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("应该是", text: $right, prompt: Text("应该是，比如：豆仓")).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .right).onSubmit(add)
                    Button("记住", action: add).disabled(!canAdd)
                }
                if settings.vocabulary.isEmpty {
                    Text("还没有记住任何词。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(settings.vocabulary) { entry in
                                HStack(spacing: 10) {
                                    Text(entry.wrong).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                                    Text(entry.right)
                                    Spacer()
                                    Button("删除「\(entry.wrong)」", systemImage: "minus.circle") { settings.vocabulary.removeAll { $0 == entry } }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                                .padding(.vertical, 7)
                                if entry != settings.vocabulary.last { Divider() }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(settings.vocabulary.count) * 36, 288))
                }
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        let w = wrong.trimmingCharacters(in: .whitespaces), r = right.trimmingCharacters(in: .whitespaces)
        store.settings.vocabulary.removeAll { $0.wrong == w }
        store.settings.vocabulary.insert(.init(wrong: w, right: r), at: 0)
        wrong = ""; right = ""
        focus = .wrong
    }
}

// MARK: 连接

private struct ConnectPane: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Connector.self) private var connector
    @State private var copied = false

    var body: some View {
        PaneFrame {
            SettingsGroup("AI 助手", footer: "连上之后，在它们那边就能直接查你的录音、纪要和待办，也能把文字和音频存进豆仓。") {
                SettingRow(icon: "link", title: "Claude、Codex、OpenClaw、Grok Bot",
                           detail: connector.connectedCount > 0 ? "已经连上 \(connector.connectedCount) 个。" : "还没有连上任何一个。") {
                    Button("打开连接页面…") { openWindow(id: "connect") }
                }
                SettingRow(icon: "film", title: "Renoise（做视频）", detail: "把改写好的稿子做成口播视频要用它。安装和登录也在连接页面里。") {
                    Button("去看看…") { openWindow(id: "connect") }
                }
            }

            LoginsGroup()

            SettingsGroup("给其他工具用", footer: "这个地址只在这台电脑上能访问，而且只有豆仓开着的时候才通。") {
                SettingRow(icon: "network", title: "接入地址") {
                    Text(BeanStore.mcpAddress).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(copied ? "已拷贝" : "拷贝") {
                        copy(BeanStore.mcpAddress)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                SettingRow(icon: "terminal", title: "命令行", detail: "在终端里也能查录音、存内容。") {
                    Text("beanpod").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .task { await connector.refresh() }
    }
}

/// 从链接导入时登录过的平台。登录状态只存在这台 Mac 上，这里可以一个个清掉。
private struct LoginsGroup: View {
    @Environment(BeanStore.self) private var store
    @State private var refresh = 0

    var body: some View {
        let list = store.loggedInPlatforms
        let _ = refresh
        SettingsGroup("从链接导入时登录过的平台", footer: "导入要登录才能看的内容时，豆仓会弹出登录窗口让你自己登录。登录状态只存在这台 Mac 上。") {
            if list.isEmpty {
                Text("还没有登录过任何平台。").foregroundStyle(.secondary)
            }
            ForEach(list, id: \.self) { platform in
                SettingRow(icon: "person.crop.circle.badge.checkmark", title: platform) {
                    Button("退出登录") { store.forgetLogin(platform); refresh += 1 }
                }
            }
        }
    }
}
