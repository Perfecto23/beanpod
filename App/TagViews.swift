import SwiftUI

// 标签的界面（设计稿 design/ui/ui_tags_list.png、ui_tags_edit.png）。

/// 侧栏的「标签」分组：每个标签一行，右边是条数；点一下列出带这个标签的录音和素材。右键能改名、删掉。
struct SidebarTags: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        let tags = store.allTags
        VStack(alignment: .leading, spacing: 6) {
            Text("标签").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warm500).padding(.horizontal, 12)
            if tags.isEmpty {
                Text("整理过的录音会自动打上标签，也可以在录音页自己加。")
                    .font(.system(size: 11)).foregroundStyle(Theme.warm400).lineLimit(2).padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tags, id: \.tag) { t in
                            let on = nav.route == .tag(t.tag)
                            Button { nav.route = .tag(t.tag) } label: {
                                HStack(spacing: 8) {
                                    Text("#").font(.system(size: 13, weight: .semibold)).frame(width: 20)
                                        .foregroundStyle(on ? Theme.accent : Theme.warm400)
                                    Text(t.tag).font(.system(size: 13, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? Theme.accent : Theme.warm700).lineLimit(1)
                                    Spacer()
                                    Text("\(t.count)").font(.system(size: 11)).monospacedDigit()
                                        .foregroundStyle(on ? Theme.accent : Theme.warm400)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(on ? Theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("标签 \(t.tag)，\(t.count) 条")
                            .contextMenu {
                                Button("改名…") { newName = t.tag; renaming = t.tag }
                                Button("从所有录音去掉…", role: .destructive) { deleting = t.tag }
                            }
                        }
                    }
                }
                // 只占实际需要的高度，标签多了才滚
                .frame(height: min(204, CGFloat(tags.count) * 31))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .alert("给标签改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("新名字", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("改名") {
                if let old = renaming {
                    store.renameTag(old, to: newName)
                    if nav.route == .tag(old) { nav.route = .tag(BeanStore.cleanTag(newName)) }
                }
                renaming = nil
            }
        } message: {
            Text("用到这个标签的录音会一起改。改成已有的标签名，就是把两个合在一起。")
        }
        .confirmationDialog("从所有录音上去掉标签「\(deleting ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("去掉", role: .destructive) {
                if let t = deleting { store.deleteTag(t); if nav.route == .tag(t) { nav.route = .all } }
                deleting = nil
            }
        } message: {
            Text("只去掉标签，录音本身不受影响。")
        }
    }
}

/// 录音详情标题下面那一排：标签胶囊（悬停出现 ×）+ 「＋ 标签」。
struct TagBar: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    let recording: Recording
    @State private var editing = false

    private var tags: [String] {
        var seen = Set<String>()
        return recording.tags.map(BeanStore.cleanTag).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { t in
                TagChip(name: t, highlighted: nav.route == .tag(t),
                        open: { nav.route = .tag(t) },
                        remove: { store.removeTag(recording.id, t) })
            }
            Button { editing = true } label: {
                Label("标签", systemImage: "plus").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(Theme.warm500)
                    .overlay(Capsule().strokeBorder(Theme.warm300, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("加标签，或者改 AI 打的标签")
            .popover(isPresented: $editing, arrowEdge: .bottom) { TagEditor(recording: recording) }
        }
    }
}

/// 一个标签胶囊：点名字跳到这个标签的列表；悬停时右边出现 ×。
struct TagChip: View {
    let name: String
    var highlighted = false
    var open: () -> Void
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                Text("# \(name)").font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("看所有带「\(name)」的录音")
            if hover {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).help("去掉这个标签").accessibilityLabel("去掉标签 \(name)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .foregroundStyle(highlighted ? Theme.accent : Theme.warm700)
        .background(highlighted ? Theme.accent.opacity(0.12) : Theme.warm100, in: .capsule)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "去掉标签", remove)
    }
}

/// 「＋ 标签」弹出的小浮层：已有的标签（可删）、输入框、按输入提示已有的标签和条数、新建。
struct TagEditor: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    @State private var text = ""
    @FocusState private var focused: Bool

    private var current: [String] {
        let r = store.recordings.first { $0.id == recording.id } ?? recording
        var seen = Set<String>()
        return r.tags.map(BeanStore.cleanTag).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var query: String { BeanStore.cleanTag(text) }

    private var suggestions: [(tag: String, count: Int)] {
        let have = Set(current)
        let all = store.allTags.filter { !have.contains($0.tag) }
        guard !query.isEmpty else { return Array(all.prefix(6)) }
        let starts = all.filter { $0.tag.hasPrefix(query) }
        let contains = all.filter { !$0.tag.hasPrefix(query) && $0.tag.contains(query) }
        return Array((starts + contains).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这条\(recording.isMaterial ? "素材" : "录音")的标签").font(.callout).foregroundStyle(.secondary)
            if current.isEmpty {
                Text("还没有标签").font(.callout).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(current, id: \.self) { t in
                        HStack(spacing: 4) {
                            Text(t).font(.system(size: 12, weight: .medium))
                            Button { store.removeTag(recording.id, t) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.plain).accessibilityLabel("去掉标签 \(t)")
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(Theme.warm700)
                        .background(Theme.warm100, in: .capsule)
                    }
                }
            }
            TextField("输入标签", text: $text)
                .textFieldStyle(.plain).font(.body)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(focused ? Theme.accent : Theme.warm300, lineWidth: focused ? 1.5 : 1))
                .focused($focused)
                .onSubmit { add(suggestions.first(where: { $0.tag == query })?.tag ?? (query.isEmpty ? suggestions.first?.tag : query)) }
            if !suggestions.isEmpty || !query.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.tag) { i, s in
                        Button { add(s.tag) } label: {
                            HStack {
                                Text(s.tag).foregroundStyle(i == 0 && !query.isEmpty ? Theme.accent : Theme.warm800)
                                Spacer()
                                Text("\(s.count) 条").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(i == 0 && !query.isEmpty ? Theme.accent.opacity(0.1) : .clear, in: .rect(cornerRadius: Theme.Radius.chip))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !query.isEmpty, !store.allTags.contains(where: { $0.tag == query }) {
                        Divider().padding(.vertical, 2)
                        Button { add(query) } label: {
                            Label("新建标签「\(query)」", systemImage: "plus").foregroundStyle(Theme.warm800)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider()
            Text("回车添加。AI 整理出的标签也可以在这里删改，改过之后重新整理不会把它换掉。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func add(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        store.addTag(recording.id, name)
        text = ""
    }
}
