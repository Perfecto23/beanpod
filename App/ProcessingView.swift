import SwiftUI

/// 总览里「正在处理」的进度（设计稿 design/ui/ui_progress.png）：
/// 顶上一行是这一批已经用了多久、预计几点全部做完；下面每条一行：在哪一步、进度条、还要多久。估法见 ProcessingETA.swift。
struct ProcessingList: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    /// 默认只摊开前 4 条，多的折起来
    @State private var showAll = false

    var body: some View {
        // 每秒刷新一次：已用时、还要多久都在走
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let plan = store.processingPlan(now: context.date)
            VStack(alignment: .leading, spacing: 0) {
                header(plan.total, now: context.date)
                    .padding(.bottom, 10)
                let shown = showAll ? plan.items : Array(plan.items.prefix(4))
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    Divider().overlay(Theme.warm200.opacity(0.6))
                    row(item, position: i)
                }
                if plan.items.count > 4 {
                    Divider().overlay(Theme.warm200.opacity(0.6))
                    Button(showAll ? "收起" : "还有 \(plan.items.count - 4) 条在排队") { showAll.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent).padding(.top, 8)
                }
            }
        }
    }

    private func header(_ total: TimeInterval, now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { title; Spacer(minLength: 12); summary(total, now: now) }
            VStack(alignment: .leading, spacing: 4) { title; summary(total, now: now) }
        }
    }

    private var title: some View {
        Label("正在处理 \(store.stages.count) 条录音", systemImage: "gearshape.2")
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.warm900)
    }

    private func summary(_ total: TimeInterval, now: Date) -> some View {
        var parts: [String] = []
        if let since = store.batchSince { parts.append(String(localized: "已用 \(BeanStore.spokenSpan(now.timeIntervalSince(since)))")) }
        let done = now.addingTimeInterval(total)
        parts.append(String(localized: "预计 \(done.formatted(date: .omitted, time: .shortened)) 全部完成（还要\(BeanStore.spokenSpan(total, rough: true))）"))
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func row(_ item: BeanStore.ETA, position: Int) -> some View {
        let r = store.recordings.first { $0.id == item.id }
        return Button {
            nav.route = (r?.isMaterial ?? false) ? .materials : .all
            nav.selection = item.id
        } label: {
            HStack(spacing: 14) {
                Image(systemName: r?.scene?.icon ?? (r?.isMaterial == true ? "play.rectangle" : "waveform"))
                    .font(.system(size: 15)).foregroundStyle(Theme.warm600)
                    .frame(width: 34, height: 34).background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
                VStack(alignment: .leading, spacing: 3) {
                    Text(r?.displayTitle ?? String(localized: "录音")).font(.body.weight(.medium)).foregroundStyle(Theme.warm900).lineLimit(1)
                    Text(step(item, r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        bar(item).frame(height: 5)
                        Text(item.fraction.map { "\(Int($0 * 100))%" } ?? "").font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(Theme.warm700).frame(width: 34, alignment: .trailing)
                    }
                    Text(eta(item, position: position)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .frame(width: 240)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(r?.displayTitle ?? String(localized: "录音"))，\(step(item, r))，\(eta(item, position: position))")
    }

    private func step(_ item: BeanStore.ETA, _ r: Recording?) -> String {
        switch item.stage {
        case .transcribing:
            let len = r.map { BeanStore.spokenSpan($0.duration, rough: true, approx: false) } ?? ""
            return len.isEmpty ? String(localized: "把录音变成文字") : String(localized: "把录音变成文字 · \(len)的音频")
        case .analyzing: return String(localized: "整理纪要中 · 已用 \(BeanStore.spokenSpan(item.elapsed))")
        case .queued: return String(localized: "排队中")
        }
    }

    private func eta(_ item: BeanStore.ETA, position: Int) -> String {
        switch item.stage {
        case .transcribing: return String(localized: "还要\(BeanStore.spokenSpan(item.remaining, rough: true))（含整理纪要）")
        case .analyzing: return item.elapsed < store.analysisSeconds ? String(localized: "通常 \(BeanStore.spokenSpan(store.analysisSeconds, rough: true)) 左右") : String(localized: "快好了，比平时久一点")
        case .queued:
            return String(localized: "排在第 \(position + 1) 个 · 预计\(BeanStore.spokenSpan(item.startsIn ?? 0, rough: true))后开始")
        }
    }

    /// 转写：按进度填满；整理：一段来回流动的条（模型不报进度）；排队：空条
    @ViewBuilder private func bar(_ item: BeanStore.ETA) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.warm200.opacity(0.8))
                switch item.stage {
                case .transcribing(let f):
                    Capsule().fill(Theme.accent).frame(width: max(5, g.size.width * f))
                case .analyzing:
                    let w = g.size.width * 0.28
                    let t = item.elapsed.truncatingRemainder(dividingBy: 2) / 2          // 每 2 秒走一个来回
                    let x = (t < 0.5 ? t * 2 : (1 - t) * 2) * (g.size.width - w)
                    Capsule().fill(LinearGradient(colors: [Theme.accent.opacity(0.15), Theme.accent, Theme.accent.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w).offset(x: x)
                        .animation(.linear(duration: 1), value: x)
                case .queued:
                    EmptyView()
                }
            }
        }
    }
}
