import SwiftUI
import UniformTypeIdentifiers

/// 录音：列表在外面，点一条进去看详情。
struct RecordingsScreen: View {
    @Environment(BeanStore.self) private var store
    /// 别的页面要打开哪一条（打开后清空）。
    @Binding var opening: UInt32?
    @State private var path: [UInt32] = []
    @State private var query = ""
    @State private var quick = Quick.all
    @State private var renaming: UInt32?
    @State private var renameText = ""
    @State private var deleting: Recording?
    @State private var importing = false

    enum Quick: String, CaseIterable, Identifiable {
        case all = "全部", starred = "星标", todos = "有待办", marked = "有重点"
        var id: String { rawValue }
    }

    private var items: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.recordings.filter { r in
            switch quick {
            case .all: true
            case .starred: r.starred
            case .todos: r.todos.contains { !$0.done }
            case .marked: !r.marks.isEmpty
            }
        }.filter { r in
            q.isEmpty || r.displayTitle.lowercased().contains(q) || (r.summary ?? "").lowercased().contains(q)
                || (r.transcript ?? "").lowercased().contains(q) || r.tags.contains { $0.lowercased().contains(q) }
        }
    }

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

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Quick.allCases) { q in
                                Button(q.rawValue) { quick = q }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .foregroundStyle(quick == q ? Color.white : Color.primary)
                                    .background(quick == q ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if items.isEmpty {
                    Section {
                        Text(store.recordings.isEmpty ? "还没有录音。点底部中间的红色按钮开始录第一条。" : "没有符合条件的录音。")
                            .foregroundStyle(.secondary).listRowBackground(Color.clear)
                    }
                }
                ForEach(days, id: \.label) { day in
                    Section(day.label) {
                        ForEach(day.items) { rec in
                            NavigationLink(value: rec.id) { RecordingRow(recording: rec) }
                                .swipeActions(edge: .leading) {
                                    Button { store.toggleStar(rec.id) } label: { Label(rec.starred ? "取消星标" : "星标", systemImage: rec.starred ? "star.slash" : "star") }
                                        .tint(Theme.accent)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button { deleting = rec } label: { Label("删除", systemImage: "trash") }.tint(Theme.rec)
                                }
                                .contextMenu { menu(rec) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .paper()
            .navigationTitle("录音")
            .searchable(text: $query, prompt: "搜标题、内容、话题")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入录音或文字文件", systemImage: "square.and.arrow.down") { importing = true }
                        if store.link == .ready {
                            Button("重新读取录音豆", systemImage: "arrow.clockwise") { store.refreshFiles() }
                            if store.recordings.contains(where: { $0.onDevice && !$0.downloaded && !$0.inProgress }) {
                                Button("全部下载", systemImage: "arrow.down.circle") { store.downloadAll() }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationDestination(for: UInt32.self) { id in RecordingDetailScreen(id: id) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .plainText, .text], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    store.importFile(url, consume: false)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
            }
            .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("标题", text: $renameText)
                Button("好") { if let id = renaming { store.rename(id, to: renameText) }; renaming = nil }
                Button("取消", role: .cancel) { renaming = nil }
            } message: {
                Text("留空的话，下次整理时会让 AI 重新起一个。")
            }
            .confirmationDialog("删除这条录音？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { rec in
                if rec.downloaded { Button("从这台 iPhone 删除", role: .destructive) { store.removeLocal(rec.id) } }
                if rec.onDevice, store.link == .ready, !rec.inProgress {
                    Button("从录音豆删除", role: .destructive) { store.deleteFromDevice(rec.id) }
                }
            } message: { rec in
                Text(rec.onDevice ? "从手机删除后，录音豆里的原件还在，可以再下载；从录音豆删除后找不回来。" : "录音豆里已经没有这条了，删除后找不回来。")
            }
        }
        // initial：这一页是第一次露面时才建出来的，那时 opening 可能已经有值了
        .onChange(of: opening, initial: true) { _, id in
            if let id { path = [id]; opening = nil }
        }
    }

    @ViewBuilder private func menu(_ rec: Recording) -> some View {
        Button("重命名…", systemImage: "pencil") { renameText = rec.title ?? ""; renaming = rec.id }
        if rec.transcript != nil {
            Button("让 AI 重新起标题", systemImage: "sparkles") { store.retitle(rec.id) }.disabled(!store.analysisAvailable)
        }
        Button(rec.starred ? "取消星标" : "标为星标", systemImage: rec.starred ? "star.slash" : "star") { store.toggleStar(rec.id) }
        if let text = rec.transcript, !text.isEmpty {
            Button("拷贝文字稿", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        Divider()
        Button("删除…", systemImage: "trash", role: .destructive) { deleting = rec }
    }
}

// MARK: - 一条录音

struct RecordingDetailScreen: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UInt32
    @State private var pane = Pane(rawValue: UserDefaults.standard.string(forKey: "startPane") ?? "") ?? .notes
    @State private var renaming = false
    @State private var renameText = ""
    @State private var deleting = false
    @State private var template = RewriteTemplate.allCases[0]
    @State private var extra = ""

    enum Pane: String, CaseIterable, Identifiable {
        case notes = "纪要", transcript = "文字稿", rewrite = "改写"
        var id: String { rawValue }
    }

    private var recording: Recording? { store.recordings.first { $0.id == id } }

    var body: some View {
        Group {
            if let recording {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(recording)
                        Picker("内容", selection: $pane) {
                            ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        switch pane {
                        case .notes: notes(recording)
                        case .transcript: transcript(recording)
                        case .rewrite: rewrite(recording)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .safeAreaInset(edge: .bottom) {
                    if recording.downloaded, !recording.textOnly {
                        PlayerBar(recording: recording).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("重命名…", systemImage: "pencil") { renameText = recording.title ?? ""; renaming = true }
                            if recording.transcript != nil {
                                Button("让 AI 重新起标题", systemImage: "sparkles") { store.retitle(id) }.disabled(!store.analysisAvailable)
                                Button("重新整理纪要", systemImage: "arrow.triangle.2.circlepath") { store.process(id) }.disabled(store.stages[id] != nil)
                            }
                            Button(recording.starred ? "取消星标" : "标为星标", systemImage: recording.starred ? "star.slash" : "star") { store.toggleStar(id) }
                            if let text = recording.transcript, !text.isEmpty {
                                ShareLink(item: store.markdown(recording)) { Label("分享纪要和文字稿", systemImage: "square.and.arrow.up") }
                                Button("拷贝文字稿", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                            }
                            Divider()
                            Button("删除…", systemImage: "trash", role: .destructive) { deleting = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .alert("重命名", isPresented: $renaming) {
                    TextField("标题", text: $renameText)
                    Button("好") { store.rename(id, to: renameText) }
                    Button("取消", role: .cancel) {}
                }
                .confirmationDialog("删除这条录音？", isPresented: $deleting, titleVisibility: .visible) {
                    if recording.downloaded { Button("从这台 iPhone 删除", role: .destructive) { store.removeLocal(id); dismiss() } }
                    if recording.onDevice, store.link == .ready, !recording.inProgress {
                        Button("从录音豆删除", role: .destructive) { store.deleteFromDevice(id) }
                    }
                }
            } else {
                ContentUnavailableView("这条录音不在了", systemImage: "waveform.slash")
            }
        }
        .paper()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.displayTitle).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let d = r.date { Text(d.formatted(.dateTime.month().day().hour().minute())) }
                Text("·")
                Text(r.textOnly ? "文字" : clock(r.duration))
                if let scene = r.scene { Text("·"); Text(scene.name) }
                if r.starred { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
            }
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: 纪要

    @ViewBuilder private func notes(_ r: Recording) -> some View {
        if !r.downloaded {
            notDownloaded(r)
        } else if let stage = store.stages[id] {
            working(stage)
        } else if !r.isAnalyzed {
            VStack(alignment: .leading, spacing: 10) {
                Text(r.transcript == nil ? "这条还没转成文字。" : "这条还没整理成纪要。").foregroundStyle(.secondary)
                Button(r.transcript == nil ? "转写并整理" : "整理纪要") { store.process(id) }.buttonStyle(.borderedProminent)
                if !store.analysisAvailable {
                    Text("还没设置云端模型，出不了完整纪要。到「设备」页右上角的设置里填一下。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .card()
        } else {
            if let summary = r.summary {
                block("摘要", icon: "text.alignleft") { Text(summary).lineSpacing(4) }
            }
            ForEach(r.sections) { section in
                block(section.heading, icon: "list.bullet") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(section.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(y: -2)
                                Text(MarkdownView.inline(item)).lineSpacing(3)
                            }
                        }
                    }
                }
            }
            if !r.todos.isEmpty {
                block("待办", icon: "checklist") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(r.todos) { todo in
                            Button { store.toggleTodo(id, todo.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: todo.done ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(todo.done ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                                    Text(todo.text).strikethrough(todo.done).foregroundStyle(todo.done ? .secondary : .primary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !r.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(r.tags, id: \.self) { tag in
                            Text("# " + tag.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).font(.footnote)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                        }
                    }
                }
            }
            if let by = r.analyzedBy {
                Text("转写：\(r.transcribedBy ?? "—") · 整理：\(by) · 内容由模型生成，重要信息请对照录音核实").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func block<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline).labelStyle(.titleAndIcon)
            content()
        }
        .card()
    }

    private func notDownloaded(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if r.inProgress {
                Label("这条还在录。结束录音后才能下载完整的。", systemImage: "record.circle").foregroundStyle(.secondary)
            } else if let pull = store.pull, pull.id == id {
                ProgressView(value: pull.fraction) { Text("正在通过蓝牙下载 \(Int(pull.fraction * 100))%") }
                Text("蓝牙比较慢，长录音要等几分钟。期间请让录音豆留在手机旁边。").font(.footnote).foregroundStyle(.secondary)
                Button("取消") { store.cancelDownloads() }
            } else if store.isQueued(id) {
                Label("排队中，等前面的下载完", systemImage: "clock").foregroundStyle(.secondary)
            } else {
                Text("这条录音还在录音豆里。").foregroundStyle(.secondary)
                Button("下载到这台 iPhone") { store.download(id) }.buttonStyle(.borderedProminent)
                    .disabled(store.link != .ready || !store.encryptionReady)
            }
        }
        .card()
    }

    private func working(_ stage: BeanStore.Stage) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            switch stage {
            case .queued: Text("排队中…")
            case .transcribing(let f): Text(f > 0 ? "正在转成文字 \(Int(f * 100))%" : "正在转成文字…")
            case .analyzing: Text("正在整理纪要…")
            }
        }
        .foregroundStyle(.secondary).card()
    }

    // MARK: 文字稿

    @ViewBuilder private func transcript(_ r: Recording) -> some View {
        if r.segments.isEmpty {
            if let text = r.transcript, !text.isEmpty {
                Text(text).lineSpacing(5).textSelection(.enabled).card()
            } else {
                Text(r.downloaded ? "还没有文字稿。到「纪要」里点「转写并整理」。" : "先把录音下载下来。").foregroundStyle(.secondary).card()
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(r.segments) { seg in
                    let marked = r.marks.contains { $0 >= seg.start - 0.5 && $0 < seg.start + 8 }
                    Button { if r.downloaded, !r.textOnly { store.play(id, at: seg.start) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(clock(seg.start)).font(.caption).monospacedDigit().foregroundStyle(marked ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                                .frame(width: 40, alignment: .leading)
                            Text(seg.clean ?? seg.text).lineSpacing(4).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
            Text("点一句话，从那里开始播。").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: 改写

    @ViewBuilder private func rewrite(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("改成什么", selection: $template) {
                ForEach(RewriteTemplate.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            Text(template.instruction).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("补充要求（可不填）", text: $extra, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                Button { store.rewrite(id, template: template, extra: extra) } label: { Label("生成", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.rewriting.contains(id) || !store.analysisAvailable || r.transcript == nil)
                if store.rewriting.contains(id) { ProgressView() }
            }
            if !store.analysisAvailable { Text("需要先设置云端模型。").font(.footnote).foregroundStyle(.secondary) }
        }
        .card()
        ForEach(r.rewrites.reversed()) { item in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.name).font(.headline)
                    Text(item.date.formatted(.dateTime.hour().minute())).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { UIPasteboard.general.string = item.text } label: { Image(systemName: "doc.on.doc") }
                    Button(role: .destructive) { store.deleteRewrite(id, item.id) } label: { Image(systemName: "trash") }
                }
                MarkdownView(text: item.text)
            }
            .card()
        }
    }
}

/// 播放条：一粒胶囊，琥珀色的播放键、能拖的进度、倍速。
struct PlayerBar: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording

    var body: some View {
        let mine = store.playingID == recording.id
        let position = mine ? store.playhead : 0
        HStack(spacing: 10) {
            Button { store.togglePlay(recording.id) } label: {
                Image(systemName: mine && store.isPlaying ? "pause.fill" : "play.fill").font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Theme.accent, in: .circle)
            }
            Slider(value: Binding(get: { position }, set: { t in
                if !mine { store.togglePlay(recording.id) }
                store.seek(t)
            }), in: 0...max(1, recording.duration))
            Text(clock(mine ? position : recording.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 36)
            Button {
                let steps: [Float] = [1, 1.25, 1.5, 2]
                let next = steps[((steps.firstIndex(of: store.playRate) ?? 0) + 1) % steps.count]
                store.setRate(next)
            } label: {
                Text(store.playRate == 1 ? "1×" : String(format: "%g×", store.playRate)).font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
