import SwiftUI

/// 纪要页顶上的「英语学习模式」勾选框：英文为主的录音才出现。勾上就整理学习笔记、纪要页换成学习视图。
struct StudyToggle: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { recording.studyMode }, set: { store.setStudyMode(recording.id, $0) })) {
                Text("英语学习模式").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warm900)
            }
            .toggleStyle(.checkbox).tint(Theme.accent).fixedSize()
            Divider().frame(height: 26)
            Text("按学英语的需要整理：单词分级、短语、难句。不勾就是普通纪要。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if store.studying.contains(recording.id) {
                ProgressView().controlSize(.small)
                Text("正在整理…").font(.caption).foregroundStyle(.secondary).fixedSize()
            } else if recording.studyMode {
                Button { store.study(recording.id) } label: { Label("重新整理", systemImage: "arrow.clockwise") }
                    .buttonStyle(.glass).controlSize(.small).fixedSize()
                    .help("让模型重新挑单词和难句")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.warm200.opacity(0.7), lineWidth: 1))
    }
}

/// 学习笔记（设计稿 design/ui/ui_study.png）：难度概览、重点单词（可按等级筛）、短语搭配、难句解析。
/// 带时间的例句点「听原句」就跳回音频那里播（开着单句循环的话会循环那句）。
struct StudyView: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    let study: Study
    enum Filter: String, CaseIterable { case all = "全部", b2 = "B2 及以上", c = "C1–C2" }
    @State private var filter: Filter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            overview
            if !study.words.isEmpty { words }
            if !study.phrases.isEmpty { phrases }
            if !study.sentences.isEmpty { sentences }
            Text("等级和解析由模型（\(study.model)）给出，仅供参考。")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: 难度概览

    private var overview: some View {
        Card(title: "难度概览", icon: "chart.bar.xaxis") {
            Text(headline).font(.system(size: 14)).foregroundStyle(Theme.warm700)
            let total = max(1, Study.levelBands.reduce(0) { $0 + (study.levels[$1] ?? 0) })
            if study.levels.values.contains(where: { $0 > 0 }) {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Array(Study.levelBands.enumerated()), id: \.offset) { i, band in
                            let share = (study.levels[band] ?? 0) / total
                            if share > 0 {
                                Rectangle().fill(bandColor(i)).frame(width: max(2, g.size.width * share - 2))
                            }
                        }
                    }
                    .clipShape(.capsule)
                }
                .frame(height: 10)
                HStack(spacing: 20) {
                    ForEach(Array(Study.levelBands.enumerated()), id: \.offset) { i, band in
                        HStack(spacing: 6) {
                            Circle().fill(bandColor(i)).frame(width: 8, height: 8)
                            Text(band).font(.caption.weight(.medium)).foregroundStyle(Theme.warm700)
                            Text("\(Int(((study.levels[band] ?? 0) / total * 100).rounded()))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var headline: String {
        var parts: [String] = []
        if !study.overall.isEmpty { parts.append("整体 \(study.overall)\(Self.levelName(study.overall))") }
        if let wpm = study.wordsPerMinute { parts.append("语速约 \(wpm) 词/分") }
        if !study.note.isEmpty { parts.append(study.note) }
        return parts.joined(separator: " · ")
    }

    static func levelName(_ l: String) -> String {
        switch l.prefix(1) { case "A": " 初级"; case "B": l.hasPrefix("B2") ? " 中高级" : " 中级"; case "C": " 高级"; default: "" }
    }

    /// 暖灰 → 玫瑰红：越难越红
    private func bandColor(_ i: Int) -> Color {
        [Theme.warm300, Theme.accent.opacity(0.35), Theme.accent.opacity(0.6), Theme.accent][min(i, 3)]
    }

    // MARK: 重点单词

    private var shownWords: [Study.Word] {
        switch filter {
        case .all: study.words
        case .b2: study.words.filter { ["B2", "C1", "C2"].contains($0.level) }
        case .c: study.words.filter { ["C1", "C2"].contains($0.level) }
        }
    }

    private var words: some View {
        Card(title: "重点单词 · \(study.words.count) 个", icon: "book.closed") {
            HStack(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button { filter = f } label: {
                        Text(f.rawValue).font(.system(size: 12, weight: filter == f ? .medium : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .foregroundStyle(filter == f ? Theme.accent : Theme.warm700)
                            .background(filter == f ? Theme.accent.opacity(0.12) : Theme.warm100, in: .rect(cornerRadius: Theme.Radius.chip))
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(shownWords.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { Divider().overlay(Theme.warm200.opacity(0.5)) }
                    // 左：单词，下面一行音标和词性；中：等级；右：释义和整句原句（原句里把这个词标出来）
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(w.word).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.warm900).textSelection(.enabled)
                            HStack(spacing: 6) {
                                if !w.phonetic.isEmpty { Text(w.phonetic).font(.system(size: 12)).foregroundStyle(.secondary) }
                                if !w.pos.isEmpty { Text(w.pos).font(.system(size: 12).italic()).foregroundStyle(.tertiary) }
                            }
                            .lineLimit(1)
                        }
                        .frame(width: 150, alignment: .leading)
                        levelChip(w.level).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w.meaning).font(.system(size: 14)).foregroundStyle(Theme.warm800).textSelection(.enabled)
                            if let ex = w.example {
                                Text(Self.marked(ex, w.word)).font(.system(size: 13)).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        listen(w.time, label: "听原句").padding(.top, 2)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func levelChip(_ level: String) -> some View {
        let strength: Double = level.hasPrefix("C") ? 1 : level == "B2" ? 0.6 : level == "B1" ? 0.35 : 0.18
        return Text(level.isEmpty ? "—" : level).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(level.hasPrefix("C") ? .white : Theme.warm800)
            .frame(width: 34).padding(.vertical, 2)
            .background(Theme.accent.opacity(strength), in: .rect(cornerRadius: Theme.Radius.chip))
    }

    // MARK: 短语、难句

    private var phrases: some View {
        Card(title: "短语搭配 · \(study.phrases.count) 个", icon: "text.quote") {
            ForEach(study.phrases) { p in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        (Text(p.phrase).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.warm900)
                         + Text("  —  \(p.meaning)").font(.system(size: 14)).foregroundColor(Theme.warm700))
                            .textSelection(.enabled)
                        if let ex = p.example {
                            Text(Self.marked(ex, p.phrase)).font(.system(size: 13)).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    listen(p.time, label: "听原句")
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var sentences: some View {
        Card(title: "难句解析 · \(study.sentences.count) 句", icon: "text.magnifyingglass") {
            ForEach(study.sentences) { s in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if let t = s.time {
                            Text(clock(t)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.warm600)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.chip))
                        }
                        Text(s.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.warm900).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        listen(s.time, label: "听这句")
                    }
                    if !s.translation.isEmpty { Text(s.translation).font(.system(size: 14)).foregroundStyle(Theme.warm700).textSelection(.enabled) }
                    if !s.structure.isEmpty || !s.points.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if !s.structure.isEmpty { Text("结构：\(s.structure)") }
                            if !s.points.isEmpty { Text("要点：\(s.points)") }
                        }
                        .font(.system(size: 13)).foregroundStyle(Theme.warm700).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// 原句：灰色，里面的这个词 / 短语加粗、玫瑰红。找不到原样的（变了形，比如 learned / learning）就按词根前几个字母找。
    static func marked(_ sentence: String, _ target: String) -> AttributedString {
        var a = AttributedString(sentence)
        a.foregroundColor = Theme.warm500
        let lower = sentence.lowercased()
        let t = target.lowercased()
        var range = lower.range(of: t)
        if range == nil, t.count >= 5, !t.contains(" ") {
            let stem = String(t.prefix(t.count - 2))
            if let r = lower.range(of: stem) {
                // 延伸到这个词结尾
                var end = r.upperBound
                while end < lower.endIndex, lower[end].isLetter { end = lower.index(after: end) }
                range = r.lowerBound..<end
            }
        }
        if let range,
           let lo = AttributedString.Index(range.lowerBound, within: a), let hi = AttributedString.Index(range.upperBound, within: a) {
            a[lo..<hi].foregroundColor = Theme.accent
            a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }

    /// 「▶ 听原句」：跳到那一句播完这句停（开着单句循环就循环）
    @ViewBuilder private func listen(_ time: TimeInterval?, label: String) -> some View {
        if let time, !recording.textOnly {
            Button {
                let segs = recording.segments
                let next = segs.first { $0.start > time + 0.01 }?.start ?? recording.duration
                let loop = UserDefaults.standard.bool(forKey: "sentenceLoop")
                store.playSpan(recording.id, time...max(time + 0.5, next), loop: loop)
            } label: { Label(label, systemImage: "play.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.accent).fixedSize()
                .help("跳到音频里这一句")
        }
    }
}
