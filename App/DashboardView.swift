import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    private var week: [Recording] {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        return store.recordings.filter { ($0.date ?? .distantPast) >= from }
    }

    private struct Day: Identifiable { let date: Date; let minutes: Double; var id: Date { date } }

    private var days: [Day] {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        return (0..<14).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let total = store.recordings.filter { $0.date.map { cal.isDate($0, inSameDayAs: day) } ?? false }.reduce(0) { $0 + $1.duration }
            return Day(date: day, minutes: total / 60)
        }
    }

    private var sceneCounts: [(scene: Scene, count: Int, duration: TimeInterval)] {
        Scene.allCases.compactMap { s in
            let items = store.recordings.filter { $0.scene == s }
            return items.isEmpty ? nil : (s, items.count, items.reduce(0) { $0 + $1.duration })
        }.sorted { $0.count > $1.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Hero()

                pending

                recentAndTodos

                // 数字和图表收在最下面，想看再展开：首页先回答「现在该做什么」
                if !store.recordings.isEmpty {
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 1)) { showStats.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(showStats ? 90 : 0))
                            Text("\(store.recordings.count) 条录音 · \(hours(store.recordings.reduce(0) { $0 + $1.duration })) · 近 7 天 \(week.count) 条")
                                .monospacedDigit()
                        }
                        .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .help(showStats ? "收起统计" : "展开统计")
                }

                if showStats {
                HStack(alignment: .top, spacing: 12) {
                    Card(title: "近 14 天录音时长") {
                        if store.recordings.isEmpty {
                            Text("有了录音之后，这里会显示每天录了多久。").font(.callout).foregroundStyle(.secondary).frame(height: 150)
                        } else {
                            Chart(days) { d in
                                BarMark(x: .value("日期", d.date, unit: .day), y: .value("分钟", d.minutes))
                                    .foregroundStyle(Theme.amber.gradient).cornerRadius(3)
                            }
                            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()); AxisGridLine() } }
                            .chartYAxis { AxisMarks { v in AxisValueLabel { if let m = v.as(Double.self) { Text(m < 10 && m != m.rounded() ? String(format: "%.1f 分", m) : "\(Int(m)) 分") } }; AxisGridLine() } }
                            .frame(height: 150)
                        }
                    }
                    Card(title: "场景分布") {
                        if sceneCounts.isEmpty {
                            Text("录音整理之后会自动归类到会议、访谈、销售等场景。").font(.callout).foregroundStyle(.secondary).frame(height: 150, alignment: .top)
                        } else {
                            VStack(spacing: 8) {
                                let top = sceneCounts.map(\.count).max() ?? 1
                                ForEach(sceneCounts, id: \.scene) { item in
                                    Button { nav.route = .scene(item.scene) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: item.scene.icon).foregroundStyle(.secondary).frame(width: 18)
                                            Text(item.scene.name).frame(width: 44, alignment: .leading)
                                            GeometryReader { geo in
                                                Capsule().fill(Theme.amber.gradient)
                                                    .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                                                    .frame(maxHeight: .infinity, alignment: .center)
                                            }
                                            .frame(height: 10)
                                            Text("\(item.count) 条 · \(spokenDuration(item.duration))").font(.caption).foregroundStyle(.secondary)
                                                .monospacedDigit().frame(width: 110, alignment: .trailing)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(minHeight: 150, alignment: .top)
                        }
                    }
                }
                }

                if showStats, !store.allTags.isEmpty {
                    Card(title: "常出现的话题") {
                        FlowLayout(spacing: 6) {
                            ForEach(store.allTags.prefix(24), id: \.tag) { item in
                                Text("\(item.tag)  \(item.count)").font(.callout)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("总览")
        .navigationSubtitle("职业：\(store.settings.profession.name)")
    }

    @AppStorage("dashShowStats") private var showStats = false

    private var recentAndTodos: some View {
                HStack(alignment: .top, spacing: 12) {
                    Card(title: "待办") {
                        let todos = store.openTodos
                        if todos.isEmpty {
                            Text("没有未完成的待办。").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(todos.prefix(8), id: \.todo.id) { item in
                            HStack(alignment: .firstTextBaseline) {
                                Toggle(isOn: Binding(get: { false }, set: { _ in store.toggleTodo(item.recording.id, item.todo.id) })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.todo.text).lineLimit(2)
                                        Button(item.recording.displayTitle) { nav.open(item.recording.id) }
                                            .buttonStyle(.plain).foregroundStyle(Theme.amber).font(.caption)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        if todos.count > 8 { Text("还有 \(todos.count - 8) 项").font(.caption).foregroundStyle(.secondary) }
                    }
                    Card(title: "最近的录音") {
                        if store.recordings.isEmpty {
                            Text("连接录音豆，把录音下载下来。").font(.callout).foregroundStyle(.secondary)
                            Button("去连接") { nav.route = .device }
                        }
                        ForEach(store.recordings.prefix(6)) { r in
                            Button { nav.open(r.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: (r.scene ?? .other).icon).foregroundStyle(.secondary).frame(width: 18)
                                    Text(r.displayTitle).lineLimit(1)
                                    Spacer()
                                    Text(clock(r.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

    }

    /// 还有事情没做完时才出现的一栏。
    @ViewBuilder private var pending: some View {
        let toDownload = store.recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.count
        let toProcess = store.recordings.filter { $0.downloaded && !$0.isAnalyzed && store.stages[$0.id] == nil }.count
        let working = store.stages.count
        let rough = store.roughCount
        if toDownload > 0 || toProcess > 0 || working > 0 || !store.analysisAvailable || rough > 0 {
            Card {
                if toDownload > 0 {
                    HStack {
                        Label("录音豆里有 \(toDownload) 条录音还没下载", systemImage: "icloud.and.arrow.down")
                        Spacer()
                        Button("全部下载") { store.downloadAll() }.disabled(store.pull != nil || !store.encryptionReady)
                    }
                }
                if toProcess > 0 {
                    HStack {
                        Label("\(toProcess) 条录音还没转写整理", systemImage: "sparkles")
                        Spacer()
                        Button("全部处理") { store.processAllPending() }
                    }
                }
                if rough > 0, store.analysisAvailable, working == 0 {
                    HStack {
                        Label("\(rough) 条录音只有粗略分类，还没出完整纪要", systemImage: "sparkles")
                        Spacer()
                        Button("全部整理") { store.upgradeRoughNotes() }
                    }
                }
                if working > 0 {
                    Label("正在处理 \(working) 条录音", systemImage: "gearshape.2").foregroundStyle(.secondary)
                }
                if !store.analysisAvailable {
                    HStack {
                        Label("还没设置分析模型，暂时只能按关键词粗略分类，出不了完整纪要", systemImage: "exclamationmark.circle")
                        Spacer()
                        SettingsLink { Text("去设置") }
                    }
                }
            }
        }
    }

    private func hours(_ t: TimeInterval) -> String {
        t >= 3600 ? String(format: "%.1f 小时", t / 3600) : "\(Int(t / 60)) 分钟"
    }
}

struct Stat: View {
    let title: String, value: String, unit: String, icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// 一行放不下就换行的标签排布。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowHeight = max(rowHeight, s.height)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(y: CGFloat, height: CGFloat, width: CGFloat)] {
        var rows: [(y: CGFloat, height: CGFloat, width: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { rows.append((y, h, x)); y += h + spacing; x = 0; h = 0 }
            x += s.width + spacing; h = max(h, s.height)
        }
        rows.append((y, h, x))
        return rows
    }
}

/// 首页最上面：小豆和它说的话，旁边是最常用的那个按钮——录音。
struct Hero: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var cheering = false
    @State private var working = 0

    private var mood: MascotMood {
        if let preview = store.mascotPreview { return preview.mood }
        if cheering { return .happy }
        if store.link != .ready { return .sleeping }
        if store.isRecording { return .listening }
        if !store.stages.isEmpty { return .thinking }
        return .idle
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        default: "晚上好"
        }
    }

    private var line: String {
        if store.link != .ready { return "我先眯一会儿。把录音豆拿出来，我就醒。" }
        if store.isRecording { return "在听，你说。" }
        if store.recState == .paused { return "先歇一下。想接着录就点继续，录完了点结束。" }
        if cheering, store.stages.isEmpty { return "连上啦，随时可以开始。" }
        if let stage = store.stages.values.first {
            switch stage {
            case .transcribing: return "正在把录音变成文字…"
            case .analyzing: return "正在想这是什么场合、该记哪些重点…"
            case .queued: return "马上就来。"
            }
        }
        if store.pull != nil { return "正在从录音豆里往外搬录音…" }
        switch store.mascotPower {
        case .charging(let level): return level >= 95 ? "充满了，拿出来就能录。" : "在充电盒里充电，现在 \(level)%。"
        case .low: return "录音豆快没电了，放回充电盒歇一会儿吧。"
        default: break
        }
        let todos = store.openTodos.count
        if todos > 0 { return "有 \(todos) 件待办还没做完，别忘了。" }
        return store.recordings.isEmpty ? "录一段试试？我来帮你整理。" : "随时可以开始，我都记着。"
    }

    var body: some View {
        HStack(spacing: 8) {
            MascotView(mood: mood, power: store.mascotPower)
                .frame(width: 170, height: 170)
                .help("点我一下")
                .accessibilityElement().accessibilityLabel("小豆").accessibilityValue(line)
            VStack(alignment: .leading, spacing: 10) {
                Text(greeting).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(line).font(.title3).foregroundStyle(.secondary)
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.3), value: line)
                HStack(spacing: 10) {
                    if store.link == .ready {
                        RecordControls(size: .extraLarge)
                    } else {
                        Button { nav.route = .device } label: { Label("连接录音豆", systemImage: "antenna.radiowaves.left.and.right").padding(.horizontal, 8) }
                            .buttonStyle(.glassProminent).controlSize(.extraLarge)
                    }
                    Button { store.chooseFilesToImport() } label: { Label("导入录音", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.glass).controlSize(.extraLarge)
                    if store.recordings.contains(where: \.isAnalyzed) {
                        Button { nav.route = .knowledge } label: { Label("问问知识库", systemImage: "sparkles") }
                            .buttonStyle(.glass).controlSize(.extraLarge)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: store.stages.count) { old, new in
            // 手头的活全干完了，小豆高兴一下
            if old > 0, new == 0 {
                cheering = true
                Task { try? await Task.sleep(for: .seconds(1.8)); cheering = false }
            }
        }
        .onChange(of: store.link == .ready) { _, ready in
            // 刚连上录音豆，蹦两下庆祝
            guard ready else { return }
            cheering = true
            Task { try? await Task.sleep(for: .seconds(2.2)); cheering = false }
        }
    }
}
