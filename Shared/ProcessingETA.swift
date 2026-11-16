import Foundation

/// 「正在处理」的进度：每条在哪一步、用了多久、还要多久、整批什么时候做完（设计稿 design/ui/ui_progress.png）。
///
/// 怎么估：
/// - 转写：进度过了 8% 就按「已用时 ÷ 进度」往后推；刚开始时按这台 Mac 以前的速度（每秒能转几秒音频）估。
/// - 整理纪要：模型不报进度，按以前整理一条平均用多久估。
/// - 排队的：前面的都做完才轮到它，所以「多久后开始」是前面所有剩余时间加起来。
/// 速度和平均用时每做完一条就更新一次（指数平均），存在 UserDefaults 里，越用越准。
extension BeanStore {
    struct ETA: Identifiable, Equatable {
        let id: UInt32
        var stage: Stage
        /// 这一步已经用了多久
        var elapsed: TimeInterval
        /// 这一条还要多久做完
        var remaining: TimeInterval
        /// 排队的：多久后轮到它
        var startsIn: TimeInterval?
        /// 转写进度（0…1），整理和排队时为空
        var fraction: Double?
    }

    /// 每秒能转写几秒音频（本机模型通常十几倍速）。没测过时先按 8 倍估。
    var asrSpeed: Double { let v = UserDefaults.standard.double(forKey: "etaASRSpeed"); return v > 0 ? v : 8 }
    /// 整理一条纪要平均几秒。没测过时先按 25 秒估。
    var analysisSeconds: Double { let v = UserDefaults.standard.double(forKey: "etaAnalysisSeconds"); return v > 0 ? v : 25 }

    /// stages 变了：记下每一步开始的时间；一步做完时用实际耗时更新速度。
    func trackStages(from old: [UInt32: Stage]) {
        let now = Date.now
        for (id, new) in stages where old[id]?.kind != new.kind {
            if let prev = old[id], let since = stageSince[id] { learn(prev, id: id, took: now.timeIntervalSince(since)) }
            stageSince[id] = now
        }
        for (id, prev) in old where stages[id] == nil {
            if let since = stageSince[id] { learn(prev, id: id, took: now.timeIntervalSince(since)) }
            stageSince[id] = nil
        }
        if stages.isEmpty { batchSince = nil } else if batchSince == nil { batchSince = now }
    }

    private func learn(_ stage: Stage, id: UInt32, took: TimeInterval) {
        guard took > 1, let r = recordings.first(where: { $0.id == id }) else { return }
        let d = UserDefaults.standard
        switch stage {
        case .transcribing:
            // 转失败了（没有文字稿）不算
            guard !r.segments.isEmpty, r.duration > 5 else { return }
            let speed = r.duration / took
            d.set(d.double(forKey: "etaASRSpeed") > 0 ? asrSpeed * 0.6 + speed * 0.4 : speed, forKey: "etaASRSpeed")
        case .analyzing:
            guard r.isAnalyzed else { return }
            d.set(d.double(forKey: "etaAnalysisSeconds") > 0 ? analysisSeconds * 0.6 + took * 0.4 : took, forKey: "etaAnalysisSeconds")
        case .queued:
            break
        }
    }

    /// 还要转写的话要多久（按以前的速度）
    private func transcribeEstimate(_ r: Recording) -> TimeInterval {
        let needs = (r.transcript ?? "").isEmpty || retranscribing.contains(r.id)
        return needs ? max(5, r.duration / asrSpeed) : 0
    }

    /// 现在这一批的进度：正在做的在前，排队的按顺序在后。
    func processingPlan(now: Date = .now) -> (items: [ETA], total: TimeInterval) {
        var items: [ETA] = []
        var ahead: TimeInterval = 0
        let running = stages.filter { $0.value != .queued }.keys.sorted()
        for id in running {
            guard let stage = stages[id], let r = recordings.first(where: { $0.id == id }) else { continue }
            let elapsed = now.timeIntervalSince(stageSince[id] ?? now)
            var remaining: TimeInterval
            var fraction: Double?
            switch stage {
            case .transcribing(let f):
                fraction = f
                remaining = f > 0.08 ? elapsed * (1 - f) / f : max(3, transcribeEstimate(r) - elapsed)
                remaining += analysisSeconds
            case .analyzing:
                remaining = max(3, analysisSeconds - elapsed)
            case .queued:
                remaining = 0
            }
            items.append(ETA(id: id, stage: stage, elapsed: elapsed, remaining: remaining, fraction: fraction))
            ahead += remaining
        }
        for id in workQueue where stages[id] == .queued {
            guard let r = recordings.first(where: { $0.id == id }) else { continue }
            let own = transcribeEstimate(r) + analysisSeconds
            items.append(ETA(id: id, stage: .queued, elapsed: 0, remaining: ahead + own, startsIn: ahead))
            ahead += own
        }
        return (items, ahead)
    }

    /// 「1 分 30 秒」「约 4 分钟」「20 秒」这样的说法
    /// approx：粗略说法前面要不要带「约」（只说音频多长时不带）
    nonisolated static func spokenSpan(_ t: TimeInterval, rough: Bool = false, approx: Bool = true) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return rough ? String(localized: "\(max(5, (s + 4) / 5 * 5)) 秒") : String(localized: "\(s) 秒") }
        if s < 3600 {
            let m = s / 60, sec = s % 60
            if rough { let r = sec >= 30 ? m + 1 : m; return approx ? String(localized: "约 \(r) 分钟") : String(localized: "\(r) 分钟") }
            return sec == 0 ? String(localized: "\(m) 分钟") : String(localized: "\(m) 分 \(sec) 秒")
        }
        return approx ? String(localized: "约 \(s / 3600) 小时 \(s % 3600 / 60) 分钟") : String(localized: "\(s / 3600) 小时 \(s % 3600 / 60) 分钟")
    }
}

extension BeanStore.Stage {
    /// 只看是哪一步，不管转写进度的数字
    var kind: Int {
        switch self { case .queued: 0; case .transcribing: 1; case .analyzing: 2 }
    }
}
