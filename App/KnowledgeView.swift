import SwiftUI

/// 知识库：所有录音里整理出来的要点汇在一起，可以搜、可以按话题看、可以直接提问。
struct KnowledgeView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var tag: String?
    @State private var scene: Scene?
    @State private var question = ""
    @State private var filter = BeanStore.SearchFilter()

    private var items: [BeanStore.KnowledgeItem] {
        store.knowledge.filter { (tag == nil || $0.tags.contains(tag!)) && (scene == nil || $0.scene == scene) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                askBox

                if !query.isEmpty || !filter.isEmpty {
                    searchFilters
                    results
                } else if store.knowledge.isEmpty {
                    ContentUnavailableView("知识库还是空的", systemImage: "books.vertical",
                                           description: Text("录音转写整理之后，里面的要点会自动汇总到这里，不用手动添加。"))
                        .padding(.top, 40)
                } else {
                    searchFilters
                    filters
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            Button { nav.open(item.recordingID) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.text).lineSpacing(3).multilineTextAlignment(.leading)
                                    HStack(spacing: 8) {
                                        ScenePill(scene: item.scene)
                                        Text(item.heading).font(.caption).foregroundStyle(.secondary)
                                        Text("·").foregroundStyle(.tertiary)
                                        Text(item.title + (item.date.map { "  " + $0.formatted(.dateTime.month().day()) } ?? ""))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .panel(radius: 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("知识库")
        .navigationSubtitle(store.knowledge.isEmpty ? "" : "\(store.knowledge.count) 条要点，来自 \(store.recordings.filter(\.isAnalyzed).count) 条录音")
        .searchable(text: $query, prompt: "搜索标题、要点和文字稿")
        .toolbar {
            Button("导出 Markdown", systemImage: "square.and.arrow.up") { store.exportMarkdown(store.recordings.filter(\.isAnalyzed)) }
                .disabled(!store.recordings.contains(where: \.isAnalyzed))
                .help("每条录音导出成一个 Markdown 文件，可以放进 Obsidian 等笔记库")
        }
    }

    @ViewBuilder private var askBox: some View {
        Card {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Theme.amber)
                TextField("问问你的录音，比如「上周和王总谈的价格是多少」", text: $question)
                    .textFieldStyle(.plain)
                    .onSubmit { store.ask(question) }
                    .disabled(!store.analysisAvailable)
                if store.asking { ProgressView().controlSize(.small) }
                else { Button("提问") { store.ask(question) }.disabled(question.isEmpty || !store.analysisAvailable) }
            }
            if !store.analysisAvailable {
                HStack {
                    Text("提问需要先设置分析模型。").font(.callout).foregroundStyle(.secondary)
                    SettingsLink { Text("去设置") }
                }
            }
            if let answer = store.answer {
                Divider()
                MarkdownView(text: answer)
                if !store.answerSources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("依据").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(store.answerSources.enumerated()), id: \.offset) { n, id in
                            if let r = store.recordings.first(where: { $0.id == id }) {
                                Button("[\(n + 1)] \(r.displayTitle)") { nav.open(id) }.buttonStyle(.plain).foregroundStyle(Theme.amber).font(.callout)
                            }
                        }
                    }
                }
                Text("回答由模型根据上面的录音生成，可能有错，请点开原录音核实。").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// 搜索时的收窄条件：时间、场景、人物。
    private var searchFilters: some View {
        HStack(spacing: 10) {
            Picker("时间", selection: $filter.days) {
                Text("全部时间").tag(Int?.none)
                Text("今天").tag(Int?.some(0))
                Text("近 7 天").tag(Int?.some(7))
                Text("近 30 天").tag(Int?.some(30))
                Text("近 90 天").tag(Int?.some(90))
            }
            Picker("场景", selection: $filter.scene) {
                Text("全部场景").tag(Scene?.none)
                ForEach(Scene.allCases) { Text($0.name).tag(Scene?.some($0)) }
            }
            Picker("人物", selection: $filter.person) {
                Text("全部人物").tag(String?.none)
                ForEach(store.allPeople, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .disabled(store.allPeople.isEmpty)
            if !filter.isEmpty { Button("清除") { filter = .init() }.buttonStyle(.plain).foregroundStyle(Theme.amber) }
            Spacer()
        }
        .labelsHidden().fixedSize(horizontal: false, vertical: true)
    }

    private var filters: some View {
        FlowLayout(spacing: 6) {
            chip("全部", selected: tag == nil && scene == nil) { tag = nil; scene = nil }
            ForEach(Scene.allCases.filter { s in store.knowledge.contains { $0.scene == s } }) { s in
                chip(s.name, selected: scene == s) { scene = scene == s ? nil : s }
            }
            ForEach(store.allTags.prefix(16), id: \.tag) { item in
                chip("# \(item.tag)", selected: tag == item.tag) { tag = tag == item.tag ? nil : item.tag }
            }
        }
    }

    private func chip(_ text: String, selected: Bool, color: Color = Theme.amber, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(selected ? .white : .primary)
                .glassEffect(selected ? .regular.tint(color).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var results: some View {
        let hits = store.search(query, filter: filter)
        if hits.isEmpty {
            ContentUnavailableView("没有符合条件的录音", systemImage: "magnifyingglass", description: Text("换个关键词，或者放宽时间、场景、人物的筛选。"))
        }
        ForEach(hits.prefix(80)) { hit in
            Button {
                nav.open(hit.recordingID)
                if let t = hit.time { store.play(hit.recordingID, at: t) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(hit.snippet).multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        ScenePill(scene: hit.scene)
                        Text(hit.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let t = hit.time { Label(clock(t), systemImage: "play.fill").font(.caption).foregroundStyle(Theme.amber) }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
