import BeanKit
import SwiftUI

// MARK: - 导航

enum Route: Hashable {
    case dashboard, all, starred, scene(Scene), knowledge, device
}

@Observable
final class Navigator {
    var route: Route = .dashboard
    var selection: UInt32?
    /// 录音舞台是不是铺开着。录音一开始就铺开，可以收起来接着用豆仓。
    var stageOpen = false
    /// 上手引导是不是开着。
    var welcomeOpen = false
    /// 正在问「真的要删吗」。放在这里，工具栏按钮和菜单栏命令都能触发同一个确认框。
    var confirmDeviceDelete = false
    var confirmWiFiSync = false
    /// 正在给哪条录音改名（弹窗挂在录音页上）。
    var renaming: UInt32?
    var confirmLocalDelete = false

    func open(_ id: UInt32) { route = .all; selection = id }
}

struct RootView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch nav.route {
            case .dashboard: DashboardView().background(Backdrop())
            case .knowledge: KnowledgeView().background(Backdrop())
            case .device: DeviceView().background(Backdrop())
            case .all, .starred, .scene: RecordingsView().background(Backdrop())
            }
        }
        .accessibilityHidden(nav.stageOpen && store.recState != .idle)
        .preferredColorScheme(store.settings.appearance.scheme)
        .onChange(of: store.recState != .idle) { _, recording in nav.stageOpen = recording }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach { store.importFile($0, consume: false) }
            if !urls.isEmpty { nav.route = .all }
            return !urls.isEmpty
        }
        .overlay(alignment: .bottom) { if !nav.stageOpen { RecordDock().padding(.bottom, 16) } }
        .overlay {
            if nav.stageOpen, store.recState != .idle {
                RecordStage().transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 1), value: nav.stageOpen)
        // 舞台铺开时，窗口顶上那排工具按钮也收起来，不然会浮在舞台上面
        .toolbar(nav.stageOpen && store.recState != .idle ? .hidden : .automatic, for: .windowToolbar)
        .overlay(alignment: .top) {
            if let banner = store.banner {
                Label(banner.text, systemImage: banner.icon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.banner)
        .overlay(alignment: .top) {
            // Wi‑Fi 快传期间一直挂着：这一分钟电脑不在原来的网络上，得让人随时知道进行到哪了
            if let wifi = store.wifi {
                HStack(spacing: 10) {
                    Image(systemName: "wifi").foregroundStyle(Theme.amber).symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(wifi.text).font(.callout.weight(.medium)).monospacedDigit()
                    if wifi.phase == .transferring, let pull = store.pull {
                        ProgressView(value: pull.fraction).frame(width: 90).tint(Theme.amber)
                        Text("\(Int(pull.fraction * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, store.banner == nil ? 10 : 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.wifi?.phase)
        .overlay(alignment: .top) {
            if let just = store.justRecorded, !(nav.stageOpen && store.recState != .idle) {
                KeepCard(just: just)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.justRecorded?.id)
        .alert("用 Wi‑Fi 快传？", isPresented: Bindable(nav).confirmWiFiSync) {
            Button("开始快传") { store.startWiFiSync() }
            Button("还是用蓝牙", role: .cancel) {}
        } message: {
            Text(store.wifiSyncEstimate + "\n\n快传时这台 Mac 会离开现在的 Wi‑Fi、连到录音豆上，大约一分钟上不了网，传完自动连回来。")
        }
        .alert(store.problem?.title ?? "", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } }), presenting: store.problem) { p in
            if let action = p.action {
                Button(action.label) {
                    switch action {
                    case .settings: SettingsView.open(.models, with: openSettings)
                    case .device: nav.route = .device
                    default: store.resolve(action)
                    }
                }
                Button("先不管", role: .cancel) {}
            } else {
                Button("好") {}
            }
        } message: { p in
            Text(p.detail)
        }
        .sheet(isPresented: $nav.welcomeOpen) { WelcomeView() }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "welcomed"), store.recordings.isEmpty { nav.welcomeOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.open)) { note in
            if let id = note.object as? UInt32 { nav.stageOpen = false; nav.open(id) }
        }
    }
}

/// 窗口最上面的录音控制，哪个页面都能点到。
struct RecordButton: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        RecordControls(size: .regular)
    }
}

/// 录音的三个动作：开始、暂停/继续、结束。没在录时只有一个「录音」；录起来后显示已录时长、暂停键和结束键。
struct RecordControls: View {
    @Environment(BeanStore.self) private var store
    var size: ControlSize

    var body: some View {
        switch store.recState {
        case .idle:
            Button { store.startRecording() } label: {
                Label(size == .regular ? "录音" : "开始录音", systemImage: "record.circle.fill").labelStyle(.titleAndIcon).fixedSize()
                    .padding(.horizontal, size == .regular ? 0 : 8)
            }
            .buttonStyle(size == .regular ? AnyButtonStyle(.glass) : AnyButtonStyle(.glassProminent))
            .tint(Theme.rec).controlSize(size)
            .help("开始录音，声音来自：\(store.sourceName)（⌘R）")
        case .recording, .paused:
            let paused = store.recState == .paused
            HStack(spacing: size == .regular ? 6 : 10) {
                HStack(spacing: 6) {
                    Circle().fill(paused ? Theme.amber : Theme.rec).frame(width: 8, height: 8)
                        .opacity(paused ? 1 : 0.9)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(clock(store.elapsed(at: context.date))).monospacedDigit()
                    }
                    if paused { Text("已暂停").foregroundStyle(.secondary).fixedSize() }
                }
                .font(size == .regular ? .callout.weight(.medium) : .title3.weight(.medium))
                .padding(.horizontal, 8)

                Button { paused ? store.resumeRecording() : store.pauseRecording() } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                        .labelStyle(size == .regular ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .buttonStyle(size == .regular ? AnyButtonStyle(.borderless) : AnyButtonStyle(.glass)).controlSize(size)
                .help(paused ? "继续录（⌘R）" : "暂停，稍后可以接着录进同一条（⌘R）")

                Button { store.finishRecording() } label: {
                    Label("结束", systemImage: "stop.fill")
                        .labelStyle(size == .regular ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .buttonStyle(size == .regular ? AnyButtonStyle(.borderless) : AnyButtonStyle(.glassProminent))
                .tint(Theme.rec).foregroundStyle(size == .regular ? AnyShapeStyle(Theme.rec) : AnyShapeStyle(.white)).controlSize(size)
                    .help("结束这条录音（⌘.）。结束后会自动下载并整理成纪要。")
            }
        }
    }
}

/// 选声音从哪来：录音豆、这台 Mac 的麦克风、电脑里的声音，或者后两样一起。就放在录音按钮旁边。
struct SourceMenu: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        Menu {
            if store.link == .ready {
                Button { store.preferMac = false } label: { Label(store.displayDeviceName + (store.preferMac ? "" : "　✓"), systemImage: "dot.radiowaves.left.and.right") }
                Divider()
            }
            Section("用这台 Mac 录") {
                ForEach(BeanStore.MacSource.allCases) { source in
                    let on = (store.link != .ready || store.preferMac) && store.macSource == source
                    Button { store.macSource = source; store.preferMac = true } label: {
                        Label(source.name + (on ? "　✓" : ""), systemImage: source.icon)
                    }
                    .help(source.hint)
                }
            }
        } label: {
            Label(store.sourceName, systemImage: store.sourceIcon).labelStyle(.titleAndIcon).lineLimit(1)
        }
        .menuStyle(.button).buttonStyle(.glass).controlSize(.extraLarge).fixedSize()
        .help("声音从哪来。点一下可以换")
        .accessibilityLabel("声音来源").accessibilityValue(store.sourceName)
    }
}

/// 让同一个按钮在不同场合用不同的按钮样式。
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { configuration in AnyView(Button(configuration).buttonStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 让同一个按钮在不同场合用不同的标签样式。
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) {
        make = { configuration in AnyView(Label { configuration.title } icon: { configuration.icon }.labelStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct Sidebar: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    /// 侧栏只有三个去处。录音页里的场景筛选、星标都算「录音」。
    private var section: Int {
        switch nav.route {
        case .dashboard: 0
        case .all, .starred, .scene: 1
        case .knowledge: 2
        case .device: -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 品牌：图标和名字
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("豆仓").font(.system(size: 19, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
            .accessibilityElement(children: .combine)

            SidebarRecord().padding(.bottom, 12)

            item("总览", "house", 0) { nav.route = .dashboard }
            item("录音", "waveform", 1, count: store.recordings.count) { nav.route = .all }
            item("知识库", "square.stack.3d.up", 2) { nav.route = .knowledge }
            Spacer(minLength: 0)
            DeviceChip()
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func item(_ title: String, _ icon: String, _ index: Int, count: Int = 0, action: @escaping () -> Void) -> some View {
        let on = section == index
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: on ? .semibold : .regular)).frame(width: 22)
                Text(title).font(.system(size: 14.5, weight: on ? .semibold : .regular))
                Spacer()
                if count > 0 { Text("\(count)").font(.callout).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .foregroundStyle(on ? Theme.amber : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? Theme.amber.opacity(0.16) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 整个应用里唯一的录音按钮，固定在侧栏顶上：哪一页都在同一个位置、同一个大小、同一个形状。
struct SidebarRecord: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        VStack(spacing: 6) {
            if store.recState == .idle {
                Button { store.startRecording() } label: {
                    Label("开始录音", systemImage: "record.circle.fill").font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .foregroundStyle(.white)
                        .background(Theme.rec, in: .capsule)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("开始录音，声音来自：\(store.sourceName)（⌘R）")
                SourceLine()
            } else {
                let paused = store.recState == .paused
                // 录音中：同一个位置换成计时，点一下回到录音舞台
                Button { nav.stageOpen = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(paused ? Theme.amber : Theme.rec).frame(width: 8, height: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(store.elapsed(at: context.date))).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        Text(paused ? "已暂停" : "录音中").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(Theme.rec.opacity(0.12), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).help("回到录音舞台（⌘L）")
            }
        }
    }
}

/// 录音按钮下面的一行小字：声音从哪来，点一下可以换。
struct SourceLine: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        Menu {
            if store.link == .ready {
                Button { store.preferMac = false } label: { Label(store.displayDeviceName + (store.preferMac ? "" : "　✓"), systemImage: "dot.radiowaves.left.and.right") }
                Divider()
            }
            Section("用这台 Mac 录") {
                ForEach(BeanStore.MacSource.allCases) { source in
                    let on = (store.link != .ready || store.preferMac) && store.macSource == source
                    Button { store.macSource = source; store.preferMac = true } label: {
                        Label(source.name + (on ? "　✓" : ""), systemImage: source.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.sourceIcon)
                Text(store.sourceName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("声音从哪来。点一下可以换")
        .accessibilityLabel("声音来源").accessibilityValue(store.sourceName)
    }
}

/// 侧栏底部的设备卡，点一下进设备页。
struct DeviceChip: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        let on = nav.route == .device
        Button { nav.route = .device } label: {
            HStack(spacing: 10) {
                Image(systemName: store.link == .ready ? "earbuds" : "earbuds.case")
                    .font(.system(size: 17)).foregroundStyle(store.link == .ready ? Theme.amber : .secondary)
                    .frame(width: 34, height: 34).background(Theme.amber.opacity(store.link == .ready ? 0.14 : 0.05), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.link == .ready ? store.displayDeviceName : "录音豆").font(.callout.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let pull = store.pull { ProgressView(value: pull.fraction).progressViewStyle(.circular).controlSize(.small) }
            }
            .padding(10)
            .panel(radius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.amber.opacity(on ? 0.7 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设备：电量、存储和连接")
    }

    private var status: String {
        if store.wifi != nil { return "Wi‑Fi 快传中" }
        switch store.link {
        case .ready:
            if store.recState == .recording { return "录音中" }
            if store.recState == .paused { return "录音已暂停" }
            return store.info.map { "已连接 · \($0.micBattery)%" } ?? "已连接"
        case .connecting: return "正在连接…"
        case .scanning: return "正在搜索…"
        case .off: return "蓝牙未打开"
        case .unauthorized: return "没有蓝牙权限"
        case .idle: return "未连接"
        }
    }

    private var statusColor: Color {
        if store.wifi != nil { return Theme.amber }
        if store.link == .ready { return store.info?.recording == true ? Theme.rec : Theme.ok }
        return .secondary.opacity(0.5)
    }
}

// MARK: - 小组件

struct ScenePill: View {
    let scene: Scene
    var body: some View {
        Label(scene.name, systemImage: scene.icon)
            .font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.amber) }
                    Text(title).font(.headline)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

extension View {
    /// 放内容的底板：一块半透明的实底加一圈细线。玻璃只留给浮在内容上面的控件。
    func panel(radius: CGFloat = 16) -> some View {
        modifier(Panel(radius: radius))
    }
}

/// 底板的样子跟着深浅色走：深色是比底色亮一级的石墨，上沿一道极细的亮边；浅色是白纸加很轻的影子。
struct Panel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.86), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(LinearGradient(colors: scheme == .dark ? [.white.opacity(0.14), .white.opacity(0.03)] : [.black.opacity(0.05), .black.opacity(0.09)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 8, y: 3)
    }
}

/// 内容区的底。深色是石墨黑，浅色是暖白纸；左上角一团很淡的琥珀色光，像仪器面板上的一盏灯。
/// 不透出桌面：桌面是什么颜色，豆仓就跟着变灰变花，没有自己的样子。
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(colors: [Color(red: 0.085, green: 0.083, blue: 0.082), Color(red: 0.05, green: 0.05, blue: 0.055)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(red: 0.975, green: 0.965, blue: 0.945), Color(red: 0.945, green: 0.93, blue: 0.905)],
                               startPoint: .top, endPoint: .bottom)
            }
            RadialGradient(colors: [Theme.amber.opacity(scheme == .dark ? 0.13 : 0.16), .clear],
                           center: .init(x: 0.12, y: 0.0), startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// 让窗口透出后面的桌面。
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .underWindowBackground
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct StageBadge: View {
    let stage: BeanStore.Stage
    var body: some View {
        HStack(spacing: 6) {
            switch stage {
            case .queued:
                Image(systemName: "clock"); Text("排队中")
            case .transcribing(let f):
                ProgressView(value: f).progressViewStyle(.circular).controlSize(.small); Text("转写 \(Int(f * 100))%")
            case .analyzing:
                ProgressView().controlSize(.small); Text("整理中")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - 录音列表

struct RecordingsView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var quick: Quick = .all
    @State private var renameText = ""

    /// 列表头上的快速筛选。星标以前是侧栏里单独的一页，没有星标时整页是空的，所以收进这里。
    enum Quick: String, CaseIterable, Identifiable {
        case all = "全部", starred = "星标", todos = "有待办", marked = "有重点"
        var id: String { rawValue }
        var emptyHint: String {
            switch self {
            case .all: ""
            case .starred: "还没有星标的录音。打开一条录音，点右上角的星，它就会出现在这里。"
            case .todos: "没有还没做完的待办。"
            case .marked: "还没有打过重点标记的录音。录音时按 ⌘D，或者按录音豆上的标记键。"
            }
        }
    }

    private var scoped: [Recording] {
        var base: [Recording]
        switch nav.route {
        case .starred: base = store.recordings.filter(\.starred)
        case .scene(let s): base = store.recordings.filter { $0.scene == s }
        default: base = store.recordings
        }
        switch quick {
        case .all: break
        case .starred: base = base.filter(\.starred)
        case .todos: base = base.filter { r in r.todos.contains { !$0.done } }
        case .marked: base = base.filter { !$0.marks.isEmpty }
        }
        return base
    }

    private var narrowed: Bool { quick != .all || !query.isEmpty || { if case .scene = nav.route { return true }; return false }() }

    private func showAll() { quick = .all; query = ""; nav.route = .all }

    /// 搜索：标题、摘要、文字稿、话题里有这个词就算。
    private var items: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scoped }
        return scoped.filter { r in
            r.displayTitle.lowercased().contains(q) || (r.summary ?? "").lowercased().contains(q)
                || (r.transcript ?? "").lowercased().contains(q) || r.tags.contains { $0.lowercased().contains(q) }
        }
    }

    /// 按天分组：今天、昨天、更早的写日期。
    private var days: [(label: String, items: [Recording])] {
        let cal = Calendar.current
        var out: [(String, [Recording])] = []
        for r in items {
            let label: String
            if let d = r.date {
                if cal.isDateInToday(d) { label = "今天" }
                else if cal.isDateInYesterday(d) { label = "昨天" }
                else { label = d.formatted(.dateTime.month().day().weekday(.abbreviated)) }
            } else { label = "没有日期" }
            if out.last?.0 == label { out[out.count - 1].1.append(r) } else { out.append((label, [r])) }
        }
        return out
    }

    private var title: String {
        switch nav.route {
        case .starred: "星标"
        case .scene(let s): s.name
        default: "全部录音"
        }
    }

    var body: some View {
        @Bindable var nav = nav
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // 搜索就放在列表头上：在哪找，就在哪输
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜标题、内容、话题", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).help("清空").accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 9))
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

                Picker("筛选", selection: $quick) {
                    ForEach(Quick.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .padding(.horizontal, 12).padding(.bottom, 4)

                List(selection: $nav.selection) {
                    ForEach(days, id: \.label) { day in
                        Section {
                            ForEach(day.items) { rec in
                                RecordingRow(recording: rec).tag(rec.id)
                                    .contextMenu { rowMenu(rec) }
                            }
                        } header: {
                            HStack {
                                Text(day.label)
                                Spacer()
                                Text("\(day.items.count) 条 · \(spokenDuration(day.items.reduce(0) { $0 + $1.duration }))").monospacedDigit()
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
                .overlay {
                    // 列表空的时候这里只留一句小字；要说的话放在右边，一个页面只出现一个空状态
                    if items.isEmpty {
                        if store.loadingList { ProgressView("正在读取录音列表…") }
                        else { Text(store.recordings.isEmpty ? "还没有录音" : "这个条件下没有录音").font(.callout).foregroundStyle(.tertiary) }
                    }
                }
            }
            .frame(width: 330)

            Divider()
            Group {
                if let id = nav.selection, let rec = store.recordings.first(where: { $0.id == id }) {
                    RecordingDetail(recording: rec).id(rec.id)
                } else if !store.recordings.isEmpty {
                    // 有录音，只是这个筛选条件下没有：说清为什么，给一个回去的按钮
                    VStack(spacing: 12) {
                        Image(systemName: quick == .starred ? "star" : "line.3.horizontal.decrease.circle").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text(!query.isEmpty ? "没找到「\(query)」" : quick != .all ? "「\(quick.rawValue)」里现在是空的" : "这个场景下还没有录音").font(.title3.weight(.semibold))
                        Text(!query.isEmpty ? "换个词试试，或者到知识库里直接提问。" : quick != .all ? quick.emptyHint : "整理过的录音会自动归到对应的场景。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        Button("看全部录音") { showAll() }.buttonStyle(.glass).controlSize(.large).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 只有一条录音都没有的时候才会到这里：给一个能直接动手的开始
                    VStack(spacing: 14) {
                        MascotView(mood: .idle, power: store.mascotPower).frame(width: 130, height: 130).accessibilityHidden(true)
                        Text("录下第一段").font(.title2.bold())
                        Text("点左上角的「开始录音」。录完会自动转成文字，再整理成摘要、待办和重点。").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationSubtitle(items.isEmpty ? "" : "\(items.count) 条")
        // 不留空白：没选中任何一条时，自动打开最新的那条
        .onAppear { pickFirstIfNeeded() }
        .onChange(of: nav.renaming) { _, id in
            if let id { renameText = store.recordings.first { $0.id == id }?.title ?? "" }
        }
        .alert("重命名", isPresented: Binding(get: { nav.renaming != nil }, set: { if !$0 { nav.renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("好") { if let id = nav.renaming { store.rename(id, to: renameText) }; nav.renaming = nil }
            Button("取消", role: .cancel) { nav.renaming = nil }
        } message: {
            Text("留空的话，下次整理时会让 AI 重新起一个。")
        }
        .onChange(of: items.map(\.id)) { pickFirstIfNeeded() }
        .onChange(of: nav.route) { if nav.route == .starred { nav.route = .all; quick = .starred } }
        .toolbar {
            ToolbarItemGroup {
                Picker("场景", selection: Binding(get: { () -> Scene? in if case .scene(let s) = nav.route { return s }; return nil },
                                                 set: { nav.route = $0.map { .scene($0) } ?? .all })) {
                    Text("全部场景").tag(Scene?.none)
                    ForEach(Scene.allCases.filter { s in store.recordings.contains { $0.scene == s } }) { s in
                        Label(s.name, systemImage: s.icon).tag(Scene?.some(s))
                    }
                }
                .help("按场景筛选")
                if store.wifiSyncWorthOffering {
                    Button("Wi‑Fi 快传", systemImage: "wifi") { nav.confirmWiFiSync = true }
                        .help("让录音豆开一个 Wi‑Fi，把长录音一口气拉下来，比蓝牙快十倍左右")
                }
                if store.wifi != nil {
                    // 快传自己会收尾，不给取消，免得网络停在半路
                } else if store.pull != nil || !store.queue.isEmpty {
                    Button("取消下载", systemImage: "xmark.circle") { store.cancelDownloads() }
                } else if store.recordings.contains(where: { $0.onDevice && !$0.downloaded && !$0.inProgress }) {
                    // 只有录音豆里真有没下载的，才摆出这个按钮
                    Button("全部下载", systemImage: "arrow.down.circle") { store.downloadAll() }
                        .disabled(!store.encryptionReady)
                        .help("把录音豆里还没下载的录音都下到这台 Mac")
                }
                Button("刷新", systemImage: "arrow.clockwise") { store.refreshFiles() }
                    .disabled(store.link != .ready || store.loadingList || store.pull != nil)
                    .help("重新读取录音豆里的录音列表")
                Button("导入", systemImage: "square.and.arrow.down") { store.chooseFilesToImport() }
                    .help("导入电脑上的录音或文字文件。也可以直接把文件拖进窗口")
            }
        }
    }

    /// 右键一行：不用先点开，就能改名、打星、删掉。
    @ViewBuilder private func rowMenu(_ rec: Recording) -> some View {
        Button("重命名…") { nav.renaming = rec.id }
        if rec.transcript != nil {
            Button("让 AI 重新起标题") { store.retitle(rec.id) }
                .disabled(!store.analysisAvailable || store.retitling.contains(rec.id))
        }
        Button(rec.starred ? "取消星标" : "标为星标") { store.toggleStar(rec.id) }
        if let text = rec.transcript, !text.isEmpty {
            Button("拷贝文字稿") { copy(text) }
        }
        if rec.downloaded || (rec.onDevice && store.link == .ready) {
            Divider()
            // 删除要再确认一次，确认框挂在详情页上，所以先选中这一条
            if rec.downloaded {
                Button("从这台 Mac 删除…", role: .destructive) { nav.selection = rec.id; Task { nav.confirmLocalDelete = true } }
            }
            if rec.onDevice, store.link == .ready, !rec.inProgress {
                Button("从录音豆删除…", role: .destructive) { nav.selection = rec.id; Task { nav.confirmDeviceDelete = true } }
            }
        }
    }

    private func pickFirstIfNeeded() {
        if let id = nav.selection, items.contains(where: { $0.id == id }) { return }
        nav.selection = items.first?.id
    }
}

/// 列表里的一行：左边一个场景色块，右边两层——AI 起的标题，和一行小信息（时间、时长、场合、关键词、待办和重点的个数）。
struct RecordingRow: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 场景：一个带颜色的小方块，扫一眼就知道这条是什么场合
            Image(systemName: (recording.scene ?? .other).icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(recording.isAnalyzed ? Theme.amber : Color.secondary)
                .frame(width: 34, height: 34)
                .background((recording.isAnalyzed ? Theme.amber : Color.secondary).opacity(0.14), in: .rect(cornerRadius: 9))
                .help((recording.scene ?? .other).name)
            // 标题下面只放小信息：几点、多长、什么场合、两个关键词。不放摘要句子，那是点开之后看的
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(recording.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                    if store.retitling.contains(recording.id) { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 4)
                    if recording.starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.amber).accessibilityLabel("星标") }
                    trailing
                }
                HStack(spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        infoLine(tags: 2)
                        infoLine(tags: 1)
                        infoLine(tags: 0)
                    }
                    Spacer(minLength: 2)
                    let todo = recording.todos.filter { !$0.done }.count
                    if todo > 0 { Label("\(todo)", systemImage: "square").labelStyle(.titleAndIcon).help("\(todo) 件待办没做完") }
                    if !recording.marks.isEmpty {
                        Label("\(recording.marks.count)", systemImage: "flag").labelStyle(.titleAndIcon).help("\(recording.marks.count) 个重点标记")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 5)
    }

    private func infoLine(tags count: Int) -> some View {
        HStack(spacing: 6) {
            Text(meta).lineLimit(1).fixedSize()
            ForEach(Array(shortTags.prefix(count)), id: \.self) { tag in
                Text(tag).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .foregroundStyle(Theme.amber)
                    .background(Theme.amber.opacity(0.14), in: .capsule)
            }
        }
    }

    /// 关键词：去掉井号，太长的不要（放不下，也说明它不是个词）。
    private var shortTags: [String] {
        recording.tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty && $0.count <= 6 }
    }

    /// 日期已经写在分组标题上了，这里只写几点、多长、什么场合。
    private var meta: String {
        var parts: [String] = []
        if let d = recording.date { parts.append(d.formatted(.dateTime.hour().minute())) }
        parts.append(recording.textOnly ? "文字" : clock(recording.duration))
        if let scene = recording.scene { parts.append(scene.name) }
        else if !recording.downloaded { parts.append("还在录音豆里") }
        else if recording.transcript == nil { parts.append("还没转成文字") }
        else if !recording.isAnalyzed { parts.append("还没整理") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        if recording.inProgress {
            Image(systemName: "record.circle").foregroundStyle(Theme.rec).help("正在录音")
        } else if let pull = store.pull, pull.id == recording.id {
            ProgressView(value: pull.fraction).progressViewStyle(.circular).controlSize(.small)
        } else if store.isQueued(recording.id) {
            Image(systemName: "clock").foregroundStyle(.secondary).help("排队下载")
        } else if let stage = store.stages[recording.id] {
            StageBadge(stage: stage)
        } else if !recording.downloaded {
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).help("还在录音豆里，没下载")
        }
    }
}

// MARK: - 录音详情

struct RecordingDetail: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    let recording: Recording
    @State private var title = ""
    @State private var tab = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if recording.downloaded {
                    if let stage = store.stages[recording.id] { processing(stage) }
                    if recording.transcript != nil {
                        Picker("", selection: $tab) {
                            Text("纪要").tag(0)
                            Text("文字稿").tag(1)
                            Text("改写").tag(2)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                        switch tab {
                        case 0: NotesView(recording: recording)
                        case 1: TranscriptView(recording: recording)
                        default: RewriteView(recording: recording)
                        }
                    } else if store.stages[recording.id] == nil {
                        notProcessed
                    }
                } else {
                    notDownloaded
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { title = recording.title ?? "" }
        // 播放条浮在内容上面，文字稿从它底下滚过去
        .safeAreaInset(edge: .bottom) {
            if recording.downloaded, !recording.textOnly, store.recState == .idle {
                VStack(spacing: 8) {
                    if !recording.marks.isEmpty {
                        // 重点标记：点一个就从那一刻前两秒开始放
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recording.marks, id: \.self) { m in
                                    Button { store.play(recording.id, at: max(0, m - 2)) } label: {
                                        Label(clock(m), systemImage: "flag.fill").font(.callout.monospacedDigit())
                                    }
                                    .buttonStyle(.glass).tint(Theme.amber)
                                    .help("跳到这个重点标记。右键可以删掉")
                                    .accessibilityLabel("重点标记 \(clock(m))")
                                    .contextMenu { Button("删掉这个标记", role: .destructive) { store.removeMark(recording.id, m) } }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .frame(maxWidth: 620)
                    }
                    PlayerBar(recording: recording).frame(maxWidth: 680)
                }
                .padding(.horizontal, 24).padding(.bottom, 14)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(recording.starred ? "取消星标" : "星标", systemImage: recording.starred ? "star.fill" : "star") {
                    store.toggleStar(recording.id)
                }
                if recording.downloaded, recording.transcript != nil {
                    Button("整理", systemImage: "sparkles") { store.process(recording.id) }
                        .disabled(store.stages[recording.id] != nil)
                        .help("用分析模型重新判断场景、整理纪要")
                }
                if recording.downloaded {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("重新整理纪要") { store.process(recording.id) }.disabled(recording.transcript == nil)
                        Button("重新转写") { store.process(recording.id, retranscribe: true) }.disabled(recording.textOnly)
                        Divider()
                        Button("导出为 Markdown…") { store.exportMarkdown([recording]) }.disabled(!recording.isAnalyzed)
                        if !recording.textOnly {
                            Button("导出音频（M4A，体积小）…") { store.exportAudio(recording.id, m4a: true) }
                            Button("导出音频（WAV，无损）…") { store.exportAudio(recording.id, m4a: false) }
                        }
                        Button("拷贝文字稿") { copy(recording.transcript ?? "") }.disabled(recording.transcript == nil)
                        if recording.origin == nil { Button("在访达中显示音频") { store.reveal(recording.id) } }
                    }
                    .disabled(store.stages[recording.id] != nil)
                }
                Menu("删除", systemImage: "trash") {
                    if recording.downloaded { Button("从这台 Mac 删除…") { nav.confirmLocalDelete = true } }
                    if recording.onDevice { Button("从录音豆删除…") { nav.confirmDeviceDelete = true } }
                }
            }
        }
        .confirmationDialog("从录音豆里删除这条录音？", isPresented: Bindable(nav).confirmDeviceDelete) {
            Button("删除", role: .destructive) { store.deleteFromDevice(recording.id) }
        } message: {
            Text(recording.downloaded ? "这台 Mac 上已下载的副本会保留。" : "这条录音还没下载，删除后无法找回。")
        }
        .confirmationDialog("从这台 Mac 删除这条录音？", isPresented: Bindable(nav).confirmLocalDelete) {
            Button("删除", role: .destructive) { store.removeLocal(recording.id) }
        } message: {
            Text(recording.onDevice ? "文字稿和纪要会一起删除。录音豆里的原件还在，可以再下载。" : "录音豆里已经没有这条了，删除后无法找回。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Scene.allCases) { s in
                        Button { store.setScene(recording.id, s) } label: { Label(s.name, systemImage: s.icon) }
                    }
                } label: {
                    if let scene = recording.scene { ScenePill(scene: scene) }
                    else { Label("未分类", systemImage: "tag").font(.caption).foregroundStyle(.secondary) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("场景是自动判断的，判断错了可以在这里改")
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            TextField("标题", text: $title, prompt: Text(recording.displayTitle))
                .textFieldStyle(.plain).font(.title.bold())
                .onSubmit { store.rename(recording.id, to: title) }
                .disabled(!recording.downloaded)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let o = recording.origin { parts.append(o) }
        if let d = recording.date { parts.append(d.formatted(date: .long, time: .shortened)) }
        if !recording.textOnly { parts.append(spokenDuration(recording.duration)) }
        return parts.joined(separator: " · ")
    }

    private func processing(_ stage: BeanStore.Stage) -> some View {
        HStack(spacing: 10) {
            switch stage {
            case .queued:
                Image(systemName: "clock"); Text("排队中，等前面的处理完")
            case .transcribing(let f):
                ProgressView(value: f).frame(width: 140); Text("正在本机转写 \(Int(f * 100))%")
            case .analyzing:
                ProgressView().controlSize(.small); Text("正在判断场景、整理纪要…")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    private var notProcessed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这条录音还没转写。").foregroundStyle(.secondary)
            Button("转写并整理", systemImage: "sparkles") { store.process(recording.id) }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var notDownloaded: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recording.inProgress {
                Label("这条还在录。暂停录音后才能下载完整的。", systemImage: "record.circle").foregroundStyle(.secondary)
            } else if let pull = store.pull, pull.id == recording.id {
                if store.wifi != nil {
                    ProgressView(value: pull.fraction) { Text("正在通过 Wi‑Fi 快传 \(Int(pull.fraction * 100))%") }
                } else {
                    ProgressView(value: pull.fraction) { Text("正在通过蓝牙下载 \(Int(pull.fraction * 100))%") }
                    Text("蓝牙比较慢，长录音要等几分钟。期间请让录音豆留在电脑旁边。").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("取消") { store.cancelDownloads() }
                        if store.wifiSyncWorthOffering { Button("改用 Wi‑Fi 快传…") { nav.confirmWiFiSync = true } }
                    }
                }
            } else if store.isQueued(recording.id) {
                Label("排队中，等前面的下载完", systemImage: "clock").foregroundStyle(.secondary)
            } else {
                Text("这条录音还在录音豆里。下载后会自动转写并整理。").foregroundStyle(.secondary)
                Button("下载到这台 Mac", systemImage: "arrow.down.circle") { store.download(recording.id) }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(store.link != .ready || !store.encryptionReady)
            }
        }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct PlayerBar: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    @State private var bars: [Float] = []
    /// 播放条太窄：把前后跳的按钮收起来（菜单和快捷键还在），先保住时间轴的长度。
    @State private var compact = false

    var body: some View {
        let active = store.playingID == recording.id
        HStack(spacing: compact ? 10 : 14) {
            Button { store.togglePlay(recording.id) } label: {
                Image(systemName: active && store.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.amber)
            .keyboardShortcut(.space, modifiers: [])
            .help(active && store.isPlaying ? "暂停（空格）" : "播放（空格）")
            .accessibilityLabel(active && store.isPlaying ? "暂停" : "播放")
            if !compact {
                Button { store.skip(recording.id, by: -15) } label: { Image(systemName: "gobackward.15").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("往回 15 秒（⌥⌘←）")
                    .accessibilityLabel("往回 15 秒")
                Button { store.skip(recording.id, by: 15) } label: { Image(systemName: "goforward.15").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("往后 15 秒（⌥⌘→）")
                    .accessibilityLabel("往后 15 秒")
            }
            Timeline(bars: bars, duration: recording.duration, playhead: active ? store.playhead : 0,
                     marks: recording.segments.map(\.start), flags: recording.marks) { time in
                store.play(recording.id, at: time)
            }
            .frame(height: 34)
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(clock(active ? store.playhead : 0))，共 \(clock(recording.duration))" + (recording.marks.isEmpty ? "" : "，\(recording.marks.count) 个重点标记"))
            .accessibilityAdjustableAction { direction in
                store.skip(recording.id, by: direction == .increment ? 15 : -15)
            }
            Text(compact ? clock(active ? store.playhead : 0) : "\(clock(active ? store.playhead : 0)) / \(clock(recording.duration))")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            // 点一下换下一档速度
            Button {
                let i = BeanStore.rates.firstIndex(of: store.playRate) ?? 1
                store.setRate(BeanStore.rates[(i + 1) % BeanStore.rates.count])
            } label: {
                Text(rateLabel(store.playRate)).font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(store.playRate == 1 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.amber))
                    .frame(width: 44)
            }
            .buttonStyle(.plain).help("播放速度，点一下换一档（⌘] 加快，⌘[ 放慢）")
            .accessibilityLabel("播放速度").accessibilityValue("\(rateLabel(store.playRate).dropLast()) 倍")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onGeometryChange(for: Bool.self) { $0.size.width < 520 } action: { compact = $0 }
        .task(id: recording.id) {
            let url = store.wavURL(recording.id)
            bars = await Task.detached { BeanStore.waveform(of: url) }.value
        }
    }
}

func rateLabel(_ rate: Float) -> String {
    rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
}

/// 录音的时间轴：一条波形，播过的部分着色，每句话开头有个小刻度。点一下或拖动就跳到那里。
struct Timeline: View {
    let bars: [Float]
    let duration: TimeInterval
    let playhead: TimeInterval
    let marks: [TimeInterval]
    var flags: [TimeInterval] = []
    let seek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let progress = duration > 0 ? CGFloat(min(1, playhead / duration)) : 0
            Canvas { context, size in
                let count = max(bars.count, 1)
                let step = size.width / CGFloat(count)
                for (i, level) in (bars.isEmpty ? [Float](repeating: 0.08, count: 80) : bars).enumerated() {
                    let x = CGFloat(i) * (bars.isEmpty ? size.width / 80 : step)
                    let barH = max(2, CGFloat(level) * size.height)
                    let rect = CGRect(x: x, y: (size.height - barH) / 2, width: max(1.5, (bars.isEmpty ? size.width / 80 : step) * 0.6), height: barH)
                    let played = x <= size.width * progress
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(played ? Theme.amber : .secondary.opacity(0.45)))
                }
                // 每句话开头的刻度
                if duration > 0 {
                    for m in marks {
                        let x = size.width * CGFloat(m / duration)
                        context.fill(Path(CGRect(x: x, y: size.height - 3, width: 1, height: 3)), with: .color(.secondary.opacity(0.7)))
                    }
                    // 重点标记：琥珀色的一根线，顶上一个点
                    for f in flags {
                        let x = size.width * CGFloat(min(1, f / duration))
                        context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.amber))
                        context.fill(Path(ellipseIn: CGRect(x: x - 3, y: 0, width: 6, height: 6)), with: .color(Theme.amber))
                    }
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                seek(duration * Double(max(0, min(1, value.location.x / w))))
            })
        }
        .help("点一下或拖动，跳到那里")
    }
}

/// 窗口底部的录音条。录音时显示实时波形、已录时长、暂停和结束；没在录时是一颗开始按钮。
struct RecordDock: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    /// 没在录的时候，首页和录音页自己有开始按钮和播放条，就不再多摆一颗。
    private var hiddenWhenIdle: Bool {
        true
    }

    var body: some View {
        Group {
            if store.recState == .idle {
                if !hiddenWhenIdle {
                    Button { store.startRecording() } label: {
                        Label(store.link == .ready ? "开始录音" : "用 Mac 录音", systemImage: "record.circle.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.rec).controlSize(.extraLarge)
                            .help(store.link == .ready ? "让录音豆开始录音（⌘R）" : "录音豆没连上，用这台 Mac 的麦克风录（⌘R）")
                }
            } else {
                active
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.recState)
    }

    private var active: some View {
        let paused = store.recState == .paused
        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(paused ? Theme.amber : Theme.rec).frame(width: 9, height: 9)
                    .symbolEffect(.pulse, isActive: !paused)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(store.elapsed(at: context.date)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            Button { nav.stageOpen = true } label: {
                FlowWave(levels: store.liveLevels, total: store.liveLevelTotal, marks: store.liveMarks,
                         elapsed: { store.elapsed(at: $0) }, paused: paused, color: .primary)
                    .frame(width: 220, height: 30)
            }
            .buttonStyle(.plain)
            .help("回到录音舞台")
            if paused { Text("已暂停").font(.callout).foregroundStyle(.secondary) }

            Button { paused ? store.resumeRecording() : store.pauseRecording() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass).controlSize(.large)
            .help(paused ? "继续录（⌘R）" : "暂停，稍后可以接着录进同一条（⌘R）")

            Button { store.finishRecording() } label: {
                Label("结束", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent).tint(Theme.rec).controlSize(.large)
            .help("结束这条录音（⌘.）。结束后会自动下载并整理成纪要。")
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 把录音改写成别的东西：口播稿、文章、邮件，或者自己写要求。
struct RewriteView: View {
    @Environment(BeanStore.self) private var store
    @Environment(VideoMaker.self) private var maker
    @State private var makingVideo = false
    let recording: Recording
    @State private var template: RewriteTemplate = .voiceover
    @State private var extra = ""

    var body: some View {
        let busy = store.rewriting.contains(recording.id)
        VStack(alignment: .leading, spacing: 14) {
            Card {
                Picker("改成", selection: $template) {
                    ForEach(RewriteTemplate.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if template != .custom {
                    Text(template.instruction).font(.callout).foregroundStyle(.secondary)
                }
                TextField(template == .custom ? "写下你想把它改成什么样，比如：改成给投资人的三句话电梯演讲" : "补充要求（可不填），比如：控制在 200 字以内、语气再轻松一点",
                          text: $extra, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button { store.rewrite(recording.id, template: template, extra: extra) } label: {
                        Label(busy ? "正在写…" : "生成", systemImage: "sparkles")
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(busy || !store.analysisAvailable || (template == .custom && extra.trimmingCharacters(in: .whitespaces).isEmpty))
                    if busy { ProgressView().controlSize(.small) }
                    if !store.analysisAvailable {
                        Text("需要先设置分析模型。").font(.callout).foregroundStyle(.secondary)
                        ModelSettingsLink()
                    }
                }
            }
            // 用这条录音做出来的视频
            ForEach(recording.videos) { clip in
                let url = store.folder.appendingPathComponent(clip.file)
                HStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Theme.amber)
                        .frame(width: 44, height: 44).background(Theme.amber.opacity(0.14), in: .rect(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("数字人口播 · \(clip.host)").font(.body.weight(.semibold))
                        Text(clip.date.formatted(date: .abbreviated, time: .shortened) + (clip.seconds > 0 ? " · 约 \(clip.seconds) 秒" : "") + " · \(clip.credits) 积分")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开") { NSWorkspace.shared.open(url) }.buttonStyle(.glassProminent)
                    Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    Button("删除", systemImage: "trash") { store.deleteVideo(recording.id, clip.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("把这条视频移到废纸篓")
                }
                .padding(14).panel(radius: 14)
            }
            ForEach(recording.rewrites) { item in
                Card {
                    HStack {
                        Text(item.name).font(.headline)
                        Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            makingVideo = true
                            Task { await maker.prepare(text: item.text, recording: recording.id, title: recording.displayTitle) }
                        } label: { Label("做成视频", systemImage: "play.rectangle.on.rectangle") }
                            .buttonStyle(.glass).tint(Theme.amber)
                            .disabled(maker.phase == .running || maker.phase == .joining)
                            .help("用 Renoise 把这篇稿子做成数字人口播。会先报价，确认了才开始")
                        Button("拷贝", systemImage: "doc.on.doc") { copy(item.text); store.toast("doc.on.doc", "已拷贝") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                        Button("删除", systemImage: "trash") { store.deleteRewrite(recording.id, item.id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    MarkdownView(text: item.text)
                }
            }
            if maker.recording == recording.id, maker.phase == .running || maker.phase == .joining {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在做视频，做好 \(maker.done) / \(maker.segments.count) 段…").foregroundStyle(.secondary)
                    Spacer()
                    Button("看进度") { makingVideo = true }
                }
                .padding(12).panel(radius: 12)
            }
            if recording.rewrites.isEmpty {
                Text("改写会按你在设置里选的职业来把握语气。结果由模型生成，发出去之前请自己过一遍。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $makingVideo) { VideoSheet() }
    }
}

struct NotesView: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = recording.summary {
                Card(title: "摘要", icon: "text.alignleft") {
                    Text(MarkdownView.inline(summary)).textSelection(.enabled).lineSpacing(4)
                }
            }
            ForEach(recording.sections) { section in
                Card(title: section.heading, icon: "list.bullet") {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.amber).frame(width: 5, height: 5).offset(y: -3)
                            Text(MarkdownView.inline(item)).textSelection(.enabled).lineSpacing(3)
                        }
                    }
                }
            }
            if !recording.todos.isEmpty {
                Card(title: "待办", icon: "checkmark.square") {
                    ForEach(recording.todos) { todo in
                        Toggle(isOn: Binding(get: { todo.done }, set: { _ in store.toggleTodo(recording.id, todo.id) })) {
                            Text(todo.text).strikethrough(todo.done).foregroundStyle(todo.done ? .secondary : .primary)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if !recording.tags.isEmpty || !recording.people.isEmpty {
                HStack(spacing: 6) {
                    ForEach(recording.people, id: \.self) { p in chip(p, "person.fill") }
                    ForEach(recording.tags, id: \.self) { t in chip(t, "number") }
                }
            }
            if recording.analyzedBy == "关键词规则" {
                Card {
                    Label("这条只按关键词粗略分了类，还没有完整纪要。", systemImage: "info.circle").foregroundStyle(.secondary)
                    if store.analysisAvailable {
                        Button("用分析模型整理", systemImage: "sparkles") { store.process(recording.id) }
                            .buttonStyle(.glassProminent).controlSize(.large)
                            .disabled(store.stages[recording.id] != nil)
                    } else {
                        Text("先在设置里配置云端模型，或下载本机模型。").font(.callout).foregroundStyle(.secondary)
                        ModelSettingsLink(title: "打开设置")
                    }
                }
            }
            Text(credits).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private var credits: String {
        var parts: [String] = []
        if let t = recording.transcribedBy { parts.append("转写：\(t)") }
        if let a = recording.analyzedBy, a != "—" { parts.append("整理：\(a)") }
        parts.append("内容由模型生成，重要信息请对照录音核实")
        return parts.joined(separator: " · ")
    }
}

struct TranscriptView: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    @State private var showClean = true
    @State private var editing = false
    @State private var replacing = false
    @State private var wrong = ""
    @State private var right = ""
    @State private var remember = true
    @State private var everywhere = false
    @State private var renaming: Int?
    @State private var newName = ""

    private var hasClean: Bool { recording.segments.contains { $0.clean != nil } }
    private let palette: [Color] = Theme.speakers

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let fix = store.pendingFix, fix.recording == recording.id { fixBar(fix) }
            if recording.segments.isEmpty {
                Text(recording.transcript ?? "").textSelection(.enabled).lineSpacing(5)
            }
            ForEach(recording.segments) { seg in row(seg) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("给这位说话人起个名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("好") { if let r = renaming { store.renameSpeaker(recording.id, r, to: newName) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if hasClean {
                Picker("", selection: $showClean) {
                    Text("润色版").tag(true)
                    Text("原文").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .help("润色版去掉了语气词和重复；原文是模型听到的原话")
            }
            Toggle(isOn: $editing) { Label("修改", systemImage: "pencil") }
                .toggleStyle(.button)
                .help("打开后可以直接改每一句的文字")
            Button { replacing.toggle() } label: { Label("替换词语", systemImage: "arrow.left.arrow.right") }
                .popover(isPresented: $replacing, arrowEdge: .bottom) { replaceForm }
            Spacer()
        }
    }

    private var replaceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把听错的词全部改掉").font(.headline)
            TextField("听错成了", text: $wrong).frame(width: 240)
            TextField("应该是", text: $right).frame(width: 240)
            Toggle("记住，以后转写时自动改", isOn: $remember)
            Toggle("所有录音都改，不只这一条", isOn: $everywhere)
            HStack {
                Spacer()
                Button("替换") {
                    let n = store.replaceWord(wrong, with: right, in: recording.id, everywhere: everywhere, remember: remember)
                    store.toast("checkmark.circle.fill", n > 0 ? "改了 \(n) 处" : (remember ? "这里没有这个词，已记进词库" : "这里没有这个词"))
                    wrong = ""; right = ""; replacing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(wrong.isEmpty || wrong == right)
            }
        }
        .padding(16)
    }

    private func fixBar(_ fix: BeanStore.PendingFix) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.amber)
            Text("你把「\(fix.wrong)」改成了「\(fix.right)」。").lineLimit(1)
            Spacer()
            Button("全部替换并记住") {
                let n = store.replaceWord(fix.wrong, with: fix.right, in: recording.id, everywhere: true, remember: true)
                store.toast("checkmark.circle.fill", "又改了 \(n) 处，以后会自动改")
                store.pendingFix = nil
            }
            .buttonStyle(.borderedProminent)
            Button("只改这一处") { store.pendingFix = nil }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func row(_ seg: Segment) -> some View {
        let useClean = showClean && seg.clean != nil
        let marked = isMarked(seg)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(clock(seg.start)) { store.play(recording.id, at: seg.start) }
                .buttonStyle(.plain).foregroundStyle(Theme.amber).font(.callout.monospacedDigit())
                .frame(width: 46, alignment: .leading)
                .help("从这里开始播放")
                .overlay(alignment: .leading) {
                    if marked { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Theme.amber).offset(x: -16).help("这句标了重点") }
                }
            speakerMenu(seg)
            if editing {
                SegmentEditor(text: useClean ? (seg.clean ?? seg.text) : seg.text) { new in
                    store.editSegment(recording.id, start: seg.start, to: new, clean: useClean)
                }
            } else {
                Text(useClean ? (seg.clean ?? seg.text) : seg.text).textSelection(.enabled).lineSpacing(5)
                    .foregroundStyle(isCurrent(seg) ? .primary : .secondary)
            }
        }
        .padding(.vertical, marked ? 6 : 0).padding(.horizontal, marked ? 8 : 0)
        .background(marked ? Theme.amber.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, marked ? -8 : 0)
        .contextMenu {
            if marked {
                Button("取消重点标记") { for m in marksIn(seg) { store.removeMark(recording.id, m) } }
            } else {
                Button("标为重点") { store.addMark(recording.id, at: seg.start + 0.5) }
            }
            Button("从这里开始播放") { store.play(recording.id, at: seg.start) }
        }
    }

    /// 落在这句话里的重点标记。
    private func marksIn(_ seg: Segment) -> [TimeInterval] {
        let next = recording.segments.first { $0.start > seg.start }?.start ?? .infinity
        let first = recording.segments.first?.start == seg.start
        return recording.marks.filter { ($0 >= seg.start || first) && $0 < next }
    }

    private func isMarked(_ seg: Segment) -> Bool { !recording.marks.isEmpty && !marksIn(seg).isEmpty }

    /// 每句前面的小标签：点一下选这句是谁说的。
    private func speakerMenu(_ seg: Segment) -> some View {
        Menu {
            ForEach(Array(recording.speakers.enumerated()), id: \.offset) { n, name in
                Button(name) { store.setSpeaker(recording.id, start: seg.start, to: n) }
            }
            Button("新增说话人") { store.addSpeaker(recording.id, start: seg.start) }
            if let n = seg.speaker, recording.speakers.indices.contains(n) {
                Divider()
                Button("改名…") { newName = recording.speakers[n]; renaming = n }
                Button("不标记") { store.setSpeaker(recording.id, start: seg.start, to: nil) }
            }
        } label: {
            if let n = seg.speaker, recording.speakers.indices.contains(n) {
                Text(recording.speakers[n]).font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(palette[n % palette.count])
                    .background(palette[n % palette.count].opacity(0.14), in: Capsule())
            } else {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("标记这句是谁说的")
    }

    private func isCurrent(_ seg: Segment) -> Bool {
        guard store.playingID == recording.id else { return true }
        let next = recording.segments.first { $0.start > seg.start }?.start ?? .infinity
        return store.playhead >= seg.start && store.playhead < next
    }
}

/// 一句话的编辑框：改完按回车或点到别处才提交。
struct SegmentEditor: View {
    @State private var draft: String
    @FocusState private var focused: Bool
    let commit: (String) -> Void

    init(text: String, commit: @escaping (String) -> Void) {
        _draft = State(initialValue: text)
        self.commit = commit
    }

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain).lineSpacing(5)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, now in if !now { commit(draft) } }
    }
}

// MARK: - 设备

struct DeviceView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var justPaired = false

    var body: some View {
        // 这一页内容不多：摆在页面正中间，不贴着左上角留一大片空
        GeometryReader { page in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch store.link {
                case .ready: connected
                case .off: ContentUnavailableView("蓝牙没打开", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text("请在菜单栏或系统设置里打开蓝牙。"))
                case .unauthorized: ContentUnavailableView("没有蓝牙权限", systemImage: "lock", description: Text("请到 系统设置 → 隐私与安全性 → 蓝牙 里允许「豆仓」。"))
                case .connecting: connecting
                case .idle, .scanning: scanner
                }
                Button("诊断日志") { openWindow(id: "log") }.buttonStyle(.plain).foregroundStyle(.tertiary).font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: page.size.height, alignment: .center)
        }
        }
        .navigationTitle("设备")
    }

    private var connecting: some View {
        Card {
            VStack(spacing: 14) {
                Radar(active: true, found: true)
                Text(store.waitingForKnownDevice ? "正在等「\(store.displayDeviceName)」出现" : "正在连接…").font(.headline)
                Text("把录音豆从充电盒里取出来，放在电脑旁边。\n手机连着它的话，先关掉手机蓝牙。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("取消") { store.disconnect() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var scanner: some View {
        Card {
            let beans = store.found.filter(\.isBean)
            VStack(spacing: 14) {
                Radar(active: store.link == .scanning, found: !beans.isEmpty)
                Text(beans.isEmpty ? (store.link == .scanning ? "正在找附近的录音豆" : "连接录音豆") : (beans.count == 1 ? "找到了，正在连接…" : "找到 \(beans.count) 颗，选一颗"))
                    .font(.headline)
                    .contentTransition(.opacity)
                if beans.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        step("1", "把录音豆从充电盒里取出来")
                        step("2", "放在电脑旁边")
                        step("3", "手机连着它的话，先关掉手机蓝牙")
                    }
                    .padding(.top, 2)
                }
                ForEach(beans) { device in
                    Button { store.autoConnectAllowed = true; store.connect(device) } label: {
                        HStack {
                            Image(systemName: "mic.circle.fill").font(.title2).foregroundStyle(Theme.amber)
                            Text(device.name).fontWeight(.medium)
                            Spacer()
                            Text("连接").foregroundStyle(Theme.amber)
                        }
                        .padding(10).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                Button(store.link == .scanning ? "停止搜索" : "开始搜索") {
                    if store.link == .scanning { store.stopScan() } else { store.autoConnectAllowed = true; store.scan() }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: beans.count)
        }
        .onAppear { if store.link == .idle, store.autoConnectAllowed { store.scan() } }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(n).font(.caption.bold()).frame(width: 20, height: 20).background(.quaternary, in: Circle())
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 已连接：小豆坐在充电仓里当主视觉，三个圆环说清电量和空间，其余参数排成一张表。
    @ViewBuilder private var connected: some View {
        VStack(spacing: 22) {
            HStack(spacing: 28) {
                MascotView(mood: justPaired ? .happy : .idle, power: store.mascotPower, inPod: true)
                    .frame(width: 230, height: 230)
                    .task {
                        try? await Task.sleep(for: .seconds(0.3))
                        justPaired = true
                        try? await Task.sleep(for: .seconds(2.2))
                        justPaired = false
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("给它起个名字", text: Bindable(store.settings).deviceAlias, prompt: Text(store.deviceName))
                        .textFieldStyle(.plain).font(.system(size: 34, weight: .bold, design: .rounded))
                        .help("点这里改名。名字只存在这台 Mac 上")
                    HStack(spacing: 7) {
                        Circle().fill(Theme.ok).frame(width: 9, height: 9)
                        Text(store.recState == .recording ? "已连接 · 正在录音" : store.inCase ? "已连接 · 正在充电盒里充电" : "已连接").font(.title3).foregroundStyle(.secondary)
                    }
                    Button("断开连接") { store.disconnect() }.buttonStyle(.glass).controlSize(.large)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)

            if let info = store.info {
                HStack(spacing: 18) {
                    ring("录音豆", "\(info.micBattery)%", Double(info.micBattery) / 100, note: info.micCharging ? "充电中" : nil, warn: info.micBattery < 20)
                    ring("充电盒", "\(info.caseBattery)%", Double(info.caseBattery) / 100, note: info.caseCharging ? "充电中" : nil, warn: info.caseBattery < 20)
                    if info.totalKB > 0 {
                        ring("已用空间", size(info.usedKB), max(0.004, Double(info.usedKB) / Double(info.totalKB)), note: "共 " + size(info.totalKB), warn: false)
                    }
                }

                let onDevice = store.recordings.filter(\.onDevice)
                let waiting = onDevice.filter { !$0.downloaded }.count
                // 每秒 8 KB：160 字节一帧、每秒 50 帧
                let hoursLeft = Double(info.freeKB) / 8 / 3600
                Card {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 11) {
                        GridRow {
                            fact("录音豆里的录音", "\(onDevice.count) 条" + (waiting > 0 ? "，\(waiting) 条没下载" : "，都已下载"))
                            fact("还能录", hoursLeft >= 100 ? "约 \(Int(hoursLeft)) 小时" : String(format: "约 %.1f 小时", hoursLeft))
                        }
                        GridRow {
                            fact("录音豆固件", info.firmware)
                            fact("充电盒固件", info.caseFirmware.isEmpty ? "—" : info.caseFirmware)
                        }
                        GridRow {
                            fact("下载加密", store.encryptionReady ? "密钥已协商" : "还没协商好，暂时不能下载", warn: !store.encryptionReady)
                            fact("序列号", info.serial.uppercased())
                        }
                    }
                    if waiting > 0 {
                        Divider()
                        HStack {
                            Text("有 \(waiting) 条录音还在录音豆里。").foregroundStyle(.secondary)
                            Spacer()
                            if store.wifiSyncWorthOffering { Button("Wi‑Fi 快传…") { nav.confirmWiFiSync = true } }
                            Button("全部下载") { store.downloadAll() }.disabled(store.pull != nil || !store.encryptionReady)
                        }
                    }
                }
            } else {
                ProgressView("正在读取设备信息…").controlSize(.small)
            }
        }
    }

    private func ring(_ title: String, _ value: String, _ fraction: Double, note: String?, warn: Bool) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(width: 132, height: 132)
        .background {
            ZStack {
                Circle().stroke(Theme.amber.opacity(0.15), lineWidth: 7)
                Circle().trim(from: 0, to: min(1, fraction)).stroke(warn ? Theme.rec : Theme.amber, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.8, dampingFraction: 1), value: fraction)
            }
        }
        .padding(6)
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).foregroundStyle(warn ? Theme.amber : Color.primary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func size(_ kb: UInt32) -> String { ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory) }
}

struct BatteryRow: View {
    let title: String
    let percent: Int
    let charging: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if charging { Image(systemName: "bolt.fill").foregroundStyle(Theme.ok).font(.caption) }
            Text("\(percent)%").monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: icon).foregroundStyle(percent <= 20 ? AnyShapeStyle(Theme.rec) : AnyShapeStyle(.secondary))
        }
    }

    private var icon: String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - 诊断日志

struct LogView: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .onChange(of: store.log.count) { proxy.scrollTo(store.log.count - 1, anchor: .bottom) }
        }
        .toolbar {
            Button("拷贝全部", systemImage: "doc.on.doc") { copy(store.log.joined(separator: "\n")) }
        }
    }
}

/// 搜索时的雷达波纹：一圈圈往外扩，找到设备后中间的图标亮起来。
struct Radar: View {
    var active: Bool
    var found: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { i in
                            let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                            Circle().strokeBorder(Theme.amber.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                                .scaleEffect(0.35 + phase * 0.65)
                        }
                    }
                }
            }
            Image(systemName: found ? "mic.circle.fill" : "mic.circle")
                .font(.system(size: 44))
                .foregroundStyle(found ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: found)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 150, height: 150)
    }
}

// MARK: - 录好了：留着还是不要

/// 录完一条之后浮出来的小卡片。十秒不理它就默认留着；点了「不要这条」还有五秒可以反悔。
struct KeepCard: View {
    @Environment(BeanStore.self) private var store
    let just: JustRecorded

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: just.discardAt == nil ? "waveform" : "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(just.discardAt == nil ? Theme.amber : Theme.rec)
                    .frame(width: 46, height: 46)
                    .background((just.discardAt == nil ? Theme.amber : Theme.rec).opacity(0.14), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(just.discardAt == nil ? "录好了" : "这条不要了").font(.title3.weight(.semibold))
                    Text("\(clock(just.seconds)) · 来自 \(just.from)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(just.discardAt == nil
                 ? (store.settings.autoProcess ? "留着的话，会自动转成文字并整理成纪要。" : "留着的话，它会出现在录音列表里。")
                 : (just.onMac ? "马上从这台 Mac 上删掉，删了找不回来。" : "马上从录音豆里删掉，删了找不回来。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if just.discardAt == nil {
                HStack(spacing: 10) {
                    Button("不要这条") { store.discardJustRecorded() }
                        .buttonStyle(.plain).foregroundStyle(Theme.rec).fontWeight(.medium)
                        .frame(maxWidth: .infinity, minHeight: 34).contentShape(.rect)
                    Button { store.keepJustRecorded() } label: { Text("留着").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 22) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button { store.undoDiscard() } label: { Text("撤销，还是留着").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 22) }
                    .buttonStyle(.glass).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }

            // 倒计时：一条越走越短的细线，旁边一句话说到点会怎样
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let end = just.discardAt ?? just.deadline
                let total = just.discardAt == nil ? JustRecorded.patience : JustRecorded.regret
                let left = max(0, end.timeIntervalSince(context.date))
                VStack(alignment: .leading, spacing: 6) {
                    Text(just.discardAt == nil ? "\(Int(left.rounded(.up))) 秒后自动留着" : "\(Int(left.rounded(.up))) 秒后删除")
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    GeometryReader { geo in
                        Capsule().fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule().fill(just.discardAt == nil ? Theme.amber : Theme.rec)
                                    .frame(width: geo.size.width * left / total)
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(.ultraThickMaterial, in: .rect(cornerRadius: 20))   // 要厚：后面是正文，透出来会跟卡片上的字打架
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: just.discardAt != nil)
    }
}
