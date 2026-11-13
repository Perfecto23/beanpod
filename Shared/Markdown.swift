import SwiftUI

/// 把模型写出来的 Markdown 排成能读的样子：标题、列表、表格、引用、分隔线、加粗。
/// 模型生成的改写稿和知识库回答都是 Markdown，原样当纯文字显示会满屏符号。
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet([String])
        case numbered([(String, String)])
        case quote(String)
        case code(String)
        case table(header: [String], rows: [[String]])
        case rule

        static func == (a: Block, b: Block) -> Bool { String(describing: a) == String(describing: b) }
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(Self.inline(s))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let s):
            Text(Self.inline(s)).lineSpacing(5)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -3)
                        Text(Self.inline(item)).lineSpacing(4)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.0 + ".").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                        Text(Self.inline(item.1)).lineSpacing(4)
                    }
                }
            }
        case .quote(let s):
            Text(Self.inline(s)).lineSpacing(5).foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 3) }
        case .code(let s):
            Text(s).font(.callout.monospaced()).lineSpacing(3)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            table(header, rows)
        }
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        // 只有序号、一两个词的列收窄，把宽度让给正文多的列
        let narrow = (0..<columns).map { c in
            ([header] + rows).map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 <= 6
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    Text(Self.inline(c < header.count ? header[c] : "")).font(.callout.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: narrow[c] ? nil : .infinity, alignment: .leading)
                        .fixedSize(horizontal: narrow[c], vertical: false)
                }
            }
            .background(Theme.accent.opacity(0.14))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(Self.inline(c < row.count ? row[c] : "")).font(.callout).lineSpacing(3)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: narrow[c] ? nil : .infinity, alignment: .leading)
                            .fixedSize(horizontal: narrow[c], vertical: false)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    // MARK: 解析

    /// 加粗、斜体、行内代码、链接。可以是多行（段落里的换行原样保留）。
    ///
    /// 加粗自己来配对，不交给系统的 Markdown 解析：模型写的加粗经常不合规范，系统会原样吐出星号。
    /// 常见的两种：「**标题: **」星号里面带空格；「**画面：**电脑」结尾星号前是标点、后面紧跟文字。
    /// 做法是一行一行看，按出现顺序把 ** 两两配成一对，中间的就是加粗。绝不跨行配对。
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        func parse(_ t: String) -> AttributedString { (try? AttributedString(markdown: t, options: options)) ?? AttributedString(t) }
        var out = AttributedString()
        for (n, line) in s.components(separatedBy: "\n").enumerated() {
            if n > 0 { out += AttributedString("\n") }
            let parts = line.components(separatedBy: "**")
            // 星号不成对、三连星号（加粗套斜体）、带行内代码的行：交回系统解析，不乱动
            guard parts.count >= 3, parts.count % 2 == 1, !line.contains("***"), !line.contains("`") else {
                out += parse(line)
                continue
            }
            for (i, part) in parts.enumerated() where !part.isEmpty {
                var piece = parse(part)
                if i % 2 == 1 {
                    for range in piece.runs.map(\.range) {
                        piece[range].inlinePresentationIntent = (piece[range].inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                    }
                }
                out += piece
            }
        }
        return out
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func numberedItem(_ t: String) -> (String, String)? {
        guard let m = t.firstMatch(of: /^(\d{1,3})[.)、]\s+(.+)$/) else { return nil }
        return (String(m.1), String(m.2))
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); i += 1; continue }

            if t.hasPrefix("```") {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                out.append(.code(body.joined(separator: "\n")))
                i += 1
                continue
            }
            if t.count >= 3, t.allSatisfy({ $0 == "-" || $0 == " " }) || t.allSatisfy({ $0 == "*" || $0 == " " }) || t.allSatisfy({ $0 == "_" }) {
                flush(); out.append(.rule); i += 1; continue
            }
            if let m = t.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flush(); out.append(.heading(m.1.count, String(m.2))); i += 1; continue
            }
            // 表格：一行表头，下一行是 |---|---| 这样的分隔
            if t.hasPrefix("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
                flush()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if t.hasPrefix(">") {
                flush()
                var body: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    body.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.quote(body.joined(separator: "\n")))
                continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                flush()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") else { break }
                    items.append(String(l.dropFirst(2))); i += 1
                }
                out.append(.bullet(items))
                continue
            }
            if numberedItem(t) != nil {
                flush()
                var items: [(String, String)] = []
                while i < lines.count, let item = numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) { items.append(item); i += 1 }
                out.append(.numbered(items))
                continue
            }
            paragraph.append(t)
            i += 1
        }
        flush()
        return out
    }
}
