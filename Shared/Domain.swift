import Foundation
import SwiftUI

// MARK: - 场景

/// 录音的类型。每种场景有自己关心的内容，整理出来的纪要栏目也不同。
nonisolated enum Scene: String, CaseIterable, Codable, Identifiable {
    case meeting, interview, sales, talk, call, media, conference, lesson, memo, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .meeting: "会议"
        case .interview: "访谈"
        case .sales: "销售"
        case .talk: "沟通"
        case .call: "电话"
        case .media: "自媒体"
        case .conference: "大会"
        case .lesson: "课程"
        case .memo: "灵感"
        case .other: "其他"
        }
    }

    var icon: String {
        switch self {
        case .meeting: "person.3.fill"
        case .interview: "mic.fill"
        case .sales: "chart.line.uptrend.xyaxis"
        case .talk: "bubble.left.and.bubble.right.fill"
        case .call: "phone.fill"
        case .media: "play.rectangle.fill"
        case .conference: "building.columns.fill"
        case .lesson: "graduationcap.fill"
        case .memo: "lightbulb.fill"
        case .other: "waveform"
        }
    }

    /// 场景不再各用一种颜色。整套界面只有一个强调色，场景靠图标区分；
    /// 这里给的是同一色相下的深浅，只在图表里用来区分相邻的条。
    var color: Color {
        let order = Scene.allCases.firstIndex(of: self) ?? 0
        return Theme.amber.opacity(1.0 - Double(order) * 0.07)
    }

    /// 给模型看的一句话定义。
    var definition: String {
        switch self {
        case .meeting: "多人围绕议题讨论并形成决定的内部会议、例会、评审"
        case .interview: "一方提问一方回答：采访、用户访谈、面试、调研"
        case .sales: "向客户介绍产品、谈价格、处理异议、推进成交"
        case .talk: "两三个人之间的交流：一对一、汇报、谈心、协商"
        case .call: "电话或语音通话，通常较短、目的单一"
        case .media: "为发布内容而录：口播、选题讨论、脚本、播客录制"
        case .conference: "一人对多人的公开演讲：发布会、论坛、行业大会"
        case .lesson: "讲课、培训、讲座、读书分享等教学内容"
        case .memo: "一个人自言自语记想法、备忘、灵感"
        case .other: "以上都不像"
        }
    }

    /// 这种场景整理时要抽出来的栏目。
    var headings: [String] {
        switch self {
        case .meeting: ["结论与决定", "讨论要点", "分歧与风险"]
        case .interview: ["核心观点", "原话金句", "值得追问"]
        case .sales: ["客户需求", "顾虑与异议", "预算与决策人", "下一步"]
        case .talk: ["达成的共识", "没谈拢的地方", "对方的诉求"]
        case .call: ["来电目的", "说定的事"]
        case .media: ["选题与角度", "可用金句", "可剪片段"]
        case .conference: ["演讲主题", "核心观点", "数据与案例"]
        case .lesson: ["知识点", "例子与方法", "没讲透的地方"]
        case .memo: ["想法", "可以怎么做"]
        case .other: ["要点"]
        }
    }

    /// 没有分析模型时，用这些词做粗分类。
    var keywords: [String] {
        switch self {
        case .meeting: ["会议", "议题", "同步一下", "各位", "排期", "评审", "周会", "对齐", "散会"]
        case .interview: ["采访", "访谈", "请问您", "能不能分享", "您怎么看", "面试", "自我介绍"]
        case .sales: ["报价", "价格", "合同", "折扣", "预算", "试用", "签约", "席位", "客户", "优惠", "采购"]
        case .talk: ["我觉得", "你怎么想", "聊一下", "反馈", "沟通一下"]
        case .call: ["喂", "您好我是", "电话", "回头打给", "挂了", "拜拜"]
        case .media: ["口播", "选题", "脚本", "粉丝", "这期视频", "播放量", "封面", "大家好我是", "点赞", "关注"]
        case .conference: ["各位来宾", "发布会", "大会", "今天很荣幸", "演讲", "论坛", "嘉宾"]
        case .lesson: ["同学们", "这节课", "知识点", "作业", "考试", "讲到", "课程", "培训"]
        case .memo: ["记一下", "备忘", "突然想到", "提醒自己", "想法是"]
        case .other: []
        }
    }
}

// MARK: - 职业

/// 使用者的职业。决定整理纪要时更看重什么。
nonisolated enum Profession: String, CaseIterable, Identifiable {
    case general, sales, creator, product, founder, consultant, researcher, teacher, lawyer, doctor, student

    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: "通用"
        case .sales: "销售与商务"
        case .creator: "自媒体创作者"
        case .product: "产品与运营"
        case .founder: "创业者与管理者"
        case .consultant: "咨询顾问"
        case .researcher: "记者与研究员"
        case .teacher: "教师与培训师"
        case .lawyer: "律师"
        case .doctor: "医生"
        case .student: "学生"
        }
    }

    var focus: String {
        switch self {
        case .general: "抓住结论、事实和后续要做的事。"
        case .sales: "格外留意客户的真实需求、预算、决策链、异议和下一步动作；金额、日期、人名要原样记下。"
        case .creator: "格外留意能做成选题的观点、可直接引用的金句、有故事性的片段和具体数据。"
        case .product: "格外留意用户问题、需求优先级、方案取舍、排期和负责人。"
        case .founder: "格外留意决策、资源分配、风险、人事和需要亲自跟进的事。"
        case .consultant: "格外留意客户现状、痛点、假设、需要验证的数据和交付物。"
        case .researcher: "格外留意可引用的原话、事实与来源、前后矛盾之处和值得追问的线索。"
        case .teacher: "格外留意知识结构、例子、学员的疑问和需要补讲的地方。"
        case .lawyer: "格外留意事实经过、时间点、各方主张、证据线索和承诺；不做法律判断，只记录。"
        case .doctor: "格外留意主诉、病史、用药、检查和医嘱；不做诊断，只记录原话。"
        case .student: "格外留意知识点、考点、老师强调的内容和作业要求。"
        }
    }
}

// MARK: - 录音

nonisolated struct Segment: Codable, Equatable, Identifiable {
    var start: TimeInterval
    /// 原文：模型听到什么就是什么，语气词、重复都在。
    var text: String
    /// 润色版：去掉语气词和重复、理顺了的同一句话。没润色过就是空。
    var clean: String?
    /// 第几位说话人（从 0 起）。没标记就是空。
    var speaker: Int?
    var id: TimeInterval { start }

    init(start: TimeInterval, text: String, clean: String? = nil, speaker: Int? = nil) {
        self.start = start; self.text = text; self.clean = clean; self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey { case start, text, clean, speaker }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(TimeInterval.self, forKey: .start)
        text = try c.decode(String.self, forKey: .text)
        clean = try c.decodeIfPresent(String.self, forKey: .clean)
        speaker = try c.decodeIfPresent(Int.self, forKey: .speaker)
    }
}

/// 用规则去掉最常见的语气词和结巴，不依赖模型，实时字幕用它。
/// 只动把握大的：单独出现的「呃、嗯、额」，句首的「然后呢、就是说」，以及「我我我」这类重复。
nonisolated func stripFillers(_ text: String) -> String {
    var s = text
    for pattern in [
        "[呃嗯额]+[，,、。]?",                         // 呃，  嗯。
        "(?<=^|[，。！？,.!?\\s])[啊哎唉哦噢]+[，,、]",   // 句首的 啊，
        "(?<=^|[，。！？,.!?\\s])(然后呢|就是说|怎么说呢)[，,、]?",
        "(对应的)?就是(?=[，,、])[，,、]",              // 就是，
    ] {
        s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    // 结巴：同一个字连说三遍以上，一定是结巴，收成一个
    s = s.replacingOccurrences(of: "([\\p{Han}])\\1{2,}", with: "$1", options: .regularExpression)
    // 连说两遍的，只处理「我我」「就就」这类代词和虚词；「谢谢」「天天」「妈妈」这种正常的叠字不能动
    s = s.replacingOccurrences(of: "([我你他她它这那就去把给要会能])\\1(?=[\\p{Han}])", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "^[，,、。\\s]+", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "[，,]{2,}", with: "，", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 把录音内容改写成另一种东西：口播稿、文章、邮件……
nonisolated struct Rewrite: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var date = Date()
}

/// 用这条录音的稿子做出来的视频。文件和录音放在同一个文件夹里。
nonisolated struct VideoClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String
    var host: String
    var seconds: Int
    var credits: Int
    var date = Date()
}

nonisolated enum RewriteTemplate: String, CaseIterable, Identifiable {
    case voiceover, shortVideo, thread, article, email, teardown, imitate, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .voiceover: "口播稿"
        case .shortVideo: "短视频脚本"
        case .thread: "社交媒体长帖"
        case .article: "公众号文章"
        case .email: "会后邮件"
        case .teardown: "拆解写法"
        case .imitate: "照结构仿写"
        case .custom: "自定义"
        }
    }

    var instruction: String {
        switch self {
        case .voiceover: "改写成一篇可以直接对着镜头念的口播稿：第一人称，口语但干净利落，开头三句内抛出最抓人的点，短句为主，每段不超过三句，结尾有一句收束。不要小标题，不要表情符号。"
        case .shortVideo: "改写成一条 60 秒左右的短视频脚本：先给一句钩子，然后按「画面 / 口播」两栏逐镜头写，5 到 8 个镜头，最后给一句行动号召。"
        case .thread: "改写成一条适合发在社交媒体上的长帖：开头一句话点明观点，中间分 3 到 5 个要点，每点两三句，语气直接，有具体细节和数字，结尾一句总结。"
        case .article: "改写成一篇公众号文章：有标题，有 3 到 4 个小标题分段，开头用一个场景或问题引入，行文连贯，保留原话里的具体例子。"
        case .email: "改写成一封会后跟进邮件：称呼、一句话说明来意、分点列出达成的结论和各自的待办（带负责人和时间）、礼貌收尾。简洁。"
        case .teardown: "把这段内容当作一条别人发布的视频文案来拆解，目的是学它的写法，不是复述内容。按这几部分写：① 开头钩子：原话是什么，用了什么手法；② 结构：按先后顺序列出每一段在做什么（抛问题、讲故事、给数据、反转、收束），每段一句话；③ 金句：摘出 3 到 5 句最值得学的原话；④ 节奏和语气：句子长短、用第几人称、有什么口头禅；⑤ 结尾怎么引导互动；⑥ 可以直接借用的写法 3 条。只依据文字稿来写，不要猜测播放量之类文字稿里没有的东西。"
        case .imitate: "先用三四行总结这条内容的结构（钩子、怎么展开、怎么收束），然后严格照这个结构和节奏，用「补充要求」里给的选题写一条新的口播稿：结构和手法学它，内容、例子、观点必须是新的，不要照搬原文的句子。如果补充要求里没有给选题，就先列出 3 个适合套用这个结构的选题，再用第一个来写。"
        case .custom: ""
        }
    }
}

/// 一条链接要登录才能下：等用户在登录窗口里登录好，再接着导入。
nonisolated struct LinkLoginRequest: Identifiable, Equatable {
    let id = UUID()
    var platform: String
    var url: String
}

/// 一条正在从链接导入的内容，给界面显示进度用。
nonisolated struct LinkJob: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var platform: String
    var title: String?
    /// 0…1；还不知道就是 nil。
    var progress: Double?
    var working = false
}

nonisolated struct NoteSection: Codable, Equatable, Identifiable {
    var heading: String
    var items: [String]
    var id: String { heading }
}

nonisolated struct Todo: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
}

nonisolated struct Recording: Identifiable, Equatable, Codable {
    let id: UInt32
    var size: UInt32
    var date: Date?
    var duration: TimeInterval
    var title: String?
    /// 标题是用户自己改过的，整理时不再覆盖。
    var titleEdited = false
    var downloaded = false
    var onDevice = false
    /// 设备还在往这条里录，现在下载只能拿到一半。运行时状态，不存盘。
    var inProgress = false

    // 转写
    var transcript: String?
    var segments: [Segment] = []
    var transcribedBy: String?
    /// 说话人的名字，下标对应 Segment.speaker。
    var speakers: [String] = []
    var rewrites: [Rewrite] = []

    // 整理
    var scene: Scene?
    /// 场景是用户手动改的，重新整理时不再让模型改。
    var sceneLocked = false
    var summary: String?
    var sections: [NoteSection] = []
    var todos: [Todo] = []
    var tags: [String] = []
    var people: [String] = []
    var analyzedBy: String?
    var starred = false
    /// 不是从录音豆来的：外部导入的音频，或者只有文字的笔记。
    var origin: String?
    /// 从链接导入的：原来的网址。
    var source: String?
    var textOnly = false
    /// 重点标记：录音时在录音豆上按过标记键、或在豆仓里点过「标重点」的时刻（秒）。
    var marks: [TimeInterval] = []
    var videos: [VideoClip] = []

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        guard let date else { return "录音 \(id)" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    var isAnalyzed: Bool { summary != nil }

    init(id: UInt32, size: UInt32, date: Date?, duration: TimeInterval, onDevice: Bool = false, inProgress: Bool = false) {
        self.id = id; self.size = size; self.date = date; self.duration = duration
        self.onDevice = onDevice; self.inProgress = inProgress
    }

    private enum CodingKeys: String, CodingKey {
        case id, size, date, duration, title, titleEdited, downloaded, onDevice, transcript, segments, transcribedBy, speakers, rewrites
        case scene, sceneLocked, summary, sections, todos, tags, people, analyzedBy, starred, origin, source, textOnly, marks, videos
    }

    /// 每个字段都容错读取：以后加字段，旧的记录文件照样能打开。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        size = try c.decodeIfPresent(UInt32.self, forKey: .size) ?? 0
        date = try c.decodeIfPresent(Date.self, forKey: .date)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        titleEdited = try c.decodeIfPresent(Bool.self, forKey: .titleEdited) ?? false
        downloaded = try c.decodeIfPresent(Bool.self, forKey: .downloaded) ?? false
        onDevice = try c.decodeIfPresent(Bool.self, forKey: .onDevice) ?? false
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        segments = (try? c.decodeIfPresent([Segment].self, forKey: .segments)) ?? []
        transcribedBy = try c.decodeIfPresent(String.self, forKey: .transcribedBy)
        speakers = (try? c.decodeIfPresent([String].self, forKey: .speakers)) ?? []
        rewrites = (try? c.decodeIfPresent([Rewrite].self, forKey: .rewrites)) ?? []
        scene = try? c.decodeIfPresent(Scene.self, forKey: .scene)
        sceneLocked = try c.decodeIfPresent(Bool.self, forKey: .sceneLocked) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        sections = (try? c.decodeIfPresent([NoteSection].self, forKey: .sections)) ?? []
        todos = (try? c.decodeIfPresent([Todo].self, forKey: .todos)) ?? []
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        people = (try? c.decodeIfPresent([String].self, forKey: .people)) ?? []
        analyzedBy = try c.decodeIfPresent(String.self, forKey: .analyzedBy)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        textOnly = try c.decodeIfPresent(Bool.self, forKey: .textOnly) ?? false
        marks = (try? c.decodeIfPresent([TimeInterval].self, forKey: .marks)) ?? []
        videos = (try? c.decodeIfPresent([VideoClip].self, forKey: .videos)) ?? []
    }
}

nonisolated struct PullProgress: Equatable {
    var id: UInt32
    var received: Int
    var expected: Int
    var fraction: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
}

nonisolated func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

nonisolated func spokenDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    if m >= 60 { return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分" }
    return m >= 1 ? "\(m) 分钟" : "\(Int(t)) 秒"
}

/// 一次 Wi‑Fi 快传的进度，给界面看的。
nonisolated struct WiFiSync: Equatable {
    enum Phase: Equatable { case opening, joining, connecting, transferring, closing }
    var phase: Phase = .opening
    var total: Int
    /// 正在传第几条（从 1 数）。
    var index = 0
    /// 这一次里还没轮到的录音。
    var waiting: [UInt32]

    var text: String {
        switch phase {
        case .opening: "正在让录音豆打开 Wi‑Fi…"
        case .joining: "正在连到录音豆上…"
        case .connecting: "连上了，马上开始传…"
        case .transferring: total > 1 ? "Wi‑Fi 快传 · 第 \(index) / \(total) 条" : "Wi‑Fi 快传中…"
        case .closing: "传完了，正在连回原来的 Wi‑Fi…"
        }
    }
}
