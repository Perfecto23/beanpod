import AppKit
import SwiftUI

/// 把一篇口播稿做成带完整包装的数字人口播视频。
///
/// 豆仓自己不剪，也不在后台跑模型：整条片子交给 Claude 桌面版——在里面新开一个 Claude Code 会话（工作目录就是这条视频的
/// 工程文件夹，提示词已经填好），由它按 Renoise MCP 上托管的两个 skill 做：
/// ai-avatar（写稿、分镜、生成数字人出镜段、检查、拼成 A-roll）→ talking-head-editor（在 Renoise 云端沙盒里
/// 粗剪、字幕花字、信息卡、画中画、B-roll、音效音乐、渲染质检）。报价和确认都在 Claude 对话里，用的是用户桌面版的账号。
/// 豆仓负责三件事：让用户选风格和主播、把任务交过去、盯着工程文件夹里的 quote/progress/result 把进度和成片接回来。
@Observable
final class VideoMaker {
    /// 出镜的人：存在 Renoise 里的人像素材（编号来自数字人形象配置 persona.json）。
    struct Host: Identifiable, Hashable {
        var id: String            // persona.json 里的键：default / me / cat / dog …
        var name: String
        var ratio: String
        var material: String
    }

    /// talking-head-editor 的包装风格。
    enum Style: String, CaseIterable, Identifiable {
        case premium, restrained, variety
        var id: String { rawValue }
        var name: String {
            switch self {
            case .premium: "高级 · 网感"
            case .restrained: "高级 · 克制"
            case .variety: "综艺花字"
            }
        }
        var fits: String {
            switch self {
            case .premium: "节奏快、信息密：打字机字、标签卡、闪切、关键词大字。大多数口播用这个"
            case .restrained: "同样的高级包装，收着用：适合财经、医疗、品牌这类严肃内容"
            case .variety: "综艺感花字、表情和音效更热闹：适合吐槽、生活建议、娱乐向人设"
            }
        }
        /// 写进 brief 给剪辑 skill 的说法
        var brief: String {
            switch self {
            case .premium: "premium, web-native intensity"
            case .restrained: "premium, restrained intensity"
            case .variety: "variety"
            }
        }
    }

    struct Quote: Equatable {
        var credits: Double
        var balance: Double?
        var segments: Int
        var seconds: Int
        var items: [Item]
        var plan: String
        var notes: [String]
        struct Item: Equatable { var name: String; var detail: String }
    }

    /// 出片这一轮的几步，和 TASK.md 里约定的步骤名一致。
    static let steps = ["生成口播", "检查拼接", "剪辑规划", "包装配乐", "渲染质检", "下载交付"]

    /// waiting：已交给 Claude 桌面版，等它规划报价；quoted：报价出来了，等用户在 Claude 里确认；producing：确认后在出片。
    enum Phase: Equatable { case idle, choosing, waiting, quoted, producing, finished(URL), failed(String) }

    static let persona = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/digital-human-koubo/persona.json")
    static let renoiseMCP = "https://renoise.ai/api/public/mcp"

    var hosts: [Host] = []
    var host: Host?
    var style: Style = .premium
    var ratio = "9:16"
    var model = "wan3.0-video"
    var phase: Phase = .idle
    var quote: Quote?
    var stepIndex = 0
    var stepDetail = ""
    var started: Date?
    var claudeAppMissing = false
    var renoiseMCPMissing = false
    var setupNote = ""

    var recording: UInt32 = 0
    var title = ""
    private var script = ""
    private(set) var job: URL?
    private var watching = false

    var busy: Bool { phase == .waiting || phase == .quoted || phase == .producing }

    /// 录音页上那一行的说明
    var statusLine: String {
        switch phase {
        case .waiting: "已交给 Claude 桌面版，等它规划报价…"
        case .quoted: "报价出来了，在 Claude 里回复确认就开始"
        case .producing: "正在做视频：\(stepIndex > 0 ? Self.steps[min(stepIndex, Self.steps.count) - 1] : "准备")…"
        default: ""
        }
    }

    // MARK: 准备

    /// 打开「做成视频」时调用：读主播、按稿子推荐风格、看看 Claude 桌面版和 Renoise MCP 在不在。
    func prepare(text: String, recording: UInt32, title: String, template: String) {
        guard !busy else { return }
        self.recording = recording
        self.title = title
        script = text
        quote = nil; job = nil; stepIndex = 0; stepDetail = ""; setupNote = ""
        loadHosts()
        checkSetup()
        style = template.contains("吐槽") ? .variety : .premium
        ratio = "9:16"
        phase = .choosing
    }

    func checkSetup() {
        claudeAppMissing = Self.claudeApp == nil
        renoiseMCPMissing = !Self.renoiseMCPConfigured
    }

    private func loadHosts() {
        var out: [Host] = []
        if let data = try? Data(contentsOf: Self.persona),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func material(_ d: [String: Any]) -> String? {
                (d["reference_material"] as? String ?? (d["renoise"] as? [String: Any])?["reference_material"] as? String)?
                    .replacingOccurrences(of: "material:", with: "")
            }
            if let m = material(root) {
                out.append(Host(id: "default", name: root["name"] as? String ?? "数字人", ratio: (root["model"] as? [String: Any])?["ratio"] as? String ?? "9:16", material: m))
            }
            for (key, value) in (root["other_hosts"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let d = value as? [String: Any], let m = material(d) else { continue }
                out.append(Host(id: key, name: d["name"] as? String ?? key, ratio: d["ratio"] as? String ?? "16:9", material: m))
            }
        }
        hosts = out
        if host == nil || !out.contains(where: { $0.id == host?.id }) { host = out.first }
    }

    // MARK: 交给 Claude 桌面版

    /// 建工程文件夹、写好任务说明，然后在 Claude 桌面版里新开一个会话。不花积分：报价出来后要用户在 Claude 里点头才生成。
    func start(store: BeanStore) {
        guard let host, !busy else { return }
        checkSetup()
        guard !claudeAppMissing else { return }
        let stamp = Int(Date.now.timeIntervalSince1970)
        let folder = Self.jobsRoot(store).appendingPathComponent("\(recording)-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        job = folder
        try? script.write(to: folder.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let brief: [String: Any] = [
            "deliverable": "finished MP4 with full packaging", "edit_style": style.brief, "aspect_ratio": ratio,
            "model": model, "host": ["name": host.name, "reference": "material:\(host.material)", "native_ratio": host.ratio],
            "language": "zh", "market": "China", "platform": ratio == "9:16" ? "抖音 / 视频号 / 小红书" : "B 站",
            "title": title, "music": "pick a royalty-free track that fits; no audition round",
            "sandbox_project": "~/projects/\(day)-beanpod-\(recording)",
        ]
        Self.write(brief, to: folder.appendingPathComponent("brief.json"))
        Self.write(["recording": Int(recording), "title": title, "style": style.name, "host": host.name, "ratio": ratio, "model": model, "started": stamp],
                   to: folder.appendingPathComponent("job.json"))
        try? Self.task.write(to: folder.appendingPathComponent("TASK.md"), atomically: true, encoding: .utf8)
        store.addLog("做视频：交给 Claude 桌面版（\(style.name) · \(ratio) · \(host.name) · \(model)），工程在 \(folder.path)")
        phase = .waiting
        started = .now
        openSession()
        Task { await watch(store) }
    }

    /// 在 Claude 桌面版里新开 Claude Code 会话：工作目录是工程文件夹，提示词填好，用户按发送开始。
    func openSession() {
        guard let job else { return }
        var c = URLComponents()
        c.scheme = "claude"; c.host = "code"; c.path = "/new"
        c.queryItems = [URLQueryItem(name: "folder", value: job.path), URLQueryItem(name: "q", value: Self.prompt)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// 切回 Claude 桌面版（报价确认、看它在做什么）。
    func showClaude() {
        if let app = Self.claudeApp { NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
    }

    /// 不再跟这一条：Claude 里那个会话要在 Claude 里自己停。
    func abandon(store: BeanStore) {
        if let job { FileManager.default.createFile(atPath: job.appendingPathComponent(".closed").path, contents: nil) }
        store.addLog("做视频：豆仓不再跟进 \(job?.lastPathComponent ?? "")")
        job = nil
        phase = .choosing
    }

    func showProject() {
        if let job { NSWorkspace.shared.activateFileViewerSelecting([job]) }
    }

    /// 给 Claude Code 加上 Renoise MCP（用户范围）。只加地址，不放任何密钥：第一次用时用户在 Claude 里 /mcp 自己登录。
    func connectRenoiseMCP() async {
        guard let claude = Self.claudePath else {
            setupNote = "没找到命令行版 claude，没法自动加。可以在 Claude 桌面版里自己加 MCP：\(Self.renoiseMCP)"
            return
        }
        let r = await Self.shell("'\(claude)' mcp add --transport http --scope user renoise \(Self.renoiseMCP)")
        checkSetup()
        setupNote = renoiseMCPMissing ? "没加上：" + Self.tail(r.output) : "加好了。第一次用时 Claude 会让你输入 /mcp 登录 Renoise。"
    }

    // MARK: 跟进度

    /// 一直看着工程文件夹：报价、进度、成片。App 重开后也接着跟最近没做完的那条，成片出来就挂到录音下面。
    func watch(_ store: BeanStore) async {
        guard !watching else { return }
        watching = true
        defer { watching = false }
        if job == nil, let latest = activeJobs(store).last { adopt(latest) }
        while true {
            scan(store)
            if activeJobs(store).isEmpty && !busy { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 还没交付、豆仓也没放弃的工程（三天内开的）
    private func activeJobs(_ store: BeanStore) -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: Self.jobsRoot(store), includingPropertiesForKeys: nil)) ?? []
        let cutoff = Date.now.timeIntervalSince1970 - 3 * 86_400
        return all.filter { folder in
            guard fm.fileExists(atPath: folder.appendingPathComponent("TASK.md").path),
                  !fm.fileExists(atPath: folder.appendingPathComponent(".done").path),
                  !fm.fileExists(atPath: folder.appendingPathComponent(".closed").path),
                  let stamp = Double(folder.lastPathComponent.split(separator: "-").last ?? ""), stamp > cutoff else { return false }
            return true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// App 重开时把最近那条接回界面
    private func adopt(_ folder: URL) {
        guard let info = Self.readJSON(folder.appendingPathComponent("job.json")) else { return }
        job = folder
        recording = UInt32(Self.number(info["recording"]) ?? 0)
        title = info["title"] as? String ?? ""
        ratio = info["ratio"] as? String ?? ratio
        style = Style.allCases.first { $0.name == info["style"] as? String } ?? style
        started = Self.number(info["started"]).map { Date(timeIntervalSince1970: $0) }
        phase = .waiting
    }

    private func scan(_ store: BeanStore) {
        for folder in activeJobs(store) {
            let current = folder == job
            if let r = Self.readJSON(folder.appendingPathComponent("result.json")) {
                deliver(folder, r, store: store, current: current)
                continue
            }
            guard current, busy else { continue }
            if let p = Self.readJSON(folder.appendingPathComponent("progress.json")) {
                if phase != .producing { phase = .producing; started = .now }
                stepIndex = Int(Self.number(p["index"]) ?? Double(stepIndex))
                stepDetail = p["detail"] as? String ?? p["step"] as? String ?? stepDetail
            } else if phase == .waiting, let q = Self.readJSON(folder.appendingPathComponent("quote.json")) {
                if let error = q["error"] as? String { phase = .failed(error); continue }
                quote = Self.parseQuote(q)
                phase = .quoted
                store.addLog("做视频：报价 \(Int(quote?.credits ?? 0)) 积分，\(quote?.segments ?? 0) 段 \(quote?.seconds ?? 0) 秒，等用户在 Claude 里确认")
            }
        }
    }

    /// 成片出来了：拷进录音库，挂到那条录音下面。出错也记一笔，之后不再看这个文件夹。
    private func deliver(_ folder: URL, _ r: [String: Any], store: BeanStore, current: Bool) {
        let info = Self.readJSON(folder.appendingPathComponent("job.json")) ?? [:]
        let fm = FileManager.default
        func close(_ failure: String?) {
            fm.createFile(atPath: folder.appendingPathComponent(".done").path, contents: nil)
            if let failure {
                store.addLog("做视频：\(folder.lastPathComponent) 没做成：\(failure)")
                if current { phase = .failed(failure) }
            }
        }
        if let error = r["error"] as? String { close(error); return }
        let local = (r["video"] as? String).map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : folder.appendingPathComponent($0) }
        guard let local, fm.fileExists(atPath: local.path) else {
            // 文件可能还在写，先不收尾；result.json 写了但成片迟迟不在就等下一轮
            if let mtime = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent("result.json").path))?[.modificationDate] as? Date,
               mtime.timeIntervalSinceNow < -120 {
                close("result.json 里写的成片在本机找不到。")
            }
            return
        }
        let rec = UInt32(Self.number(info["recording"]) ?? Double(recording))
        let name = "\(rec)-video-\(Int(Date.now.timeIntervalSince1970)).mp4"
        let out = store.folder.appendingPathComponent(name)
        do { try fm.copyItem(at: local, to: out) } catch { close("成片拷不进录音库：\(error.localizedDescription)"); return }
        let quote = Self.readJSON(folder.appendingPathComponent("quote.json")).map(Self.parseQuote)
        let spent = Int(Self.number(r["credits_spent"]) ?? quote?.credits ?? 0)
        let seconds = Int(Self.number(r["seconds"]) ?? Double(quote?.seconds ?? 0))
        store.addVideo(rec, file: name, host: "\(info["style"] as? String ?? "口播") · \(info["host"] as? String ?? "数字人")", seconds: seconds, credits: spent)
        store.addLog("做视频：交付 \(name)，花了 \(spent) 积分。\(r["summary"] as? String ?? "")")
        store.toast("checkmark.circle.fill", "视频做好了：\(info["title"] as? String ?? "")")
        close(nil)
        if current { phase = .finished(out) }
    }

    nonisolated static func parseQuote(_ q: [String: Any]) -> Quote {
        let items = (q["items"] as? [[String: Any]] ?? []).map { item -> Quote.Item in
            let credits = number(item["credits"]).map { "\(Int($0.rounded())) 积分" } ?? ""
            let count = number(item["count"]).map { " × \(Int($0))" } ?? ""
            return Quote.Item(name: (item["name"] as? String ?? "") + count, detail: credits)
        }
        return Quote(credits: number(q["credits"]) ?? 0, balance: number(q["balance"]),
                     segments: Int(number(q["segments"]) ?? 0), seconds: Int(number(q["seconds"]) ?? 0),
                     items: items, plan: q["plan"] as? String ?? "", notes: q["notes"] as? [String] ?? [])
    }

    // MARK: 环境

    static func jobsRoot(_ store: BeanStore) -> URL {
        store.folder.deletingLastPathComponent().appendingPathComponent("Videos", isDirectory: true)
    }

    static var claudeApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
            ?? (FileManager.default.fileExists(atPath: "/Applications/Claude.app") ? URL(fileURLWithPath: "/Applications/Claude.app") : nil)
    }

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Claude Code 的用户配置里有没有接 Renoise MCP（任意名字，只看地址）
    static var renoiseMCPConfigured: Bool {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let servers = readJSON(config)?["mcpServers"] as? [String: Any] else { return false }
        return servers.values.contains { ($0 as? [String: Any])?["url"] as? String == renoiseMCP }
    }

    // MARK: 给 Claude 的话

    /// 填进 Claude 输入框的那句话（用户看得到，按发送才开始）
    private static let prompt = "这是豆仓发来的视频任务：照这个文件夹里的 TASK.md，用 Renoise MCP 的 ai-avatar 和 talking-head-editor 两个 skill，把 source.md 这篇口播稿做成带完整包装的数字人口播视频。先规划报价，我确认了再花积分。"

    private static let task = """
    # BeanPod video job

    This job was started from the BeanPod app (豆仓). The user is in this conversation: talk to them in Simplified Chinese, briefly.

    Goal: turn the Chinese talking-head script in ./source.md into a finished, fully packaged AI-avatar talking-head video, using the Renoise MCP tools and the Renoise hosted skills:
    ai-avatar (script and performance, takes, generate, check, join the A-roll) → talking-head-editor (rough cut, sentence-by-sentence edit plan, captions and keyword big text, info cards, picture-in-picture, B-roll, sound effects, music, render, QA, in the Renoise cloud sandbox).
    ./brief.json holds what the user already chose in BeanPod: edit style, aspect ratio, model, host reference material, platform, sandbox project folder. Those are the answers to the skills' clarifying questions; do not ask them again.
    BeanPod watches this folder for ./quote.json, ./progress.json and ./result.json, so always write them exactly as below.

    ## 0. Renoise MCP
    Use the Renoise MCP tools (mcp__renoise__*). If they are not available or the server needs sign-in, tell the user in one line: 输入 /mcp，选 renoise 登录授权，好了回我一句。 Then wait. Never ask for or use API keys yourself.

    ## 1. Plan and quote (no credits)
    get_account. load_skill ai-avatar, then the files it tells you to read for planning, and load_skill talking-head-editor so the plan covers the edit.
    Following ai-avatar steps 0–2: write the script and performance as script.json (keep the content of source.md; you may tighten it for speech and add a hook, but do not invent facts), cut it into takes, and price every take with estimate_cost using the chosen model and host reference. Plan and price any Renoise-generated B-roll the edit would want. Say whether the edit itself (the sandbox engineer) is free on this account's plan.
    Keep script.json in the sandbox project folder from brief.json (create it with the sandbox tool in command mode) and save a copy here.
    Write ./quote.json (UTF-8, Chinese text):
    {"segments": takes, "seconds": total seconds, "credits": total credits, "balance": balance,
     "items": [{"name": "数字人出镜（模型名）", "count": takes, "credits": n}, {"name": "B-roll …", "count": n, "credits": n}],
     "plan": "两三句中文：开场怎么抓人、怎么剪、用哪些包装",
     "notes": ["给用户的提醒，比如稿子里要核实的说法"]}
    Then show the user the quote in chat and ask for a yes. Do not call create_tasks, start a sandbox task, or spend anything before they say yes.
    If something blocks the plan, write ./quote.json {"error": "一句中文原因"} and tell the user.

    ## 2. Produce (only after the user's yes)
    Budget: the quoted credits + 10%. Never exceed it; if you would, stop, tell the user, and write ./result.json {"error": "中文原因，已花多少积分"}.
    - ai-avatar steps 3–5: generate the takes with create_tasks, wait, check speech and frames, reshoot only a broken take (within budget), join the A-roll in the sandbox project.
    - ai-avatar step 6 → talking-head-editor: the full edit in the style from brief.json: rough cut, edit plan, captions and keyword big text, info cards, picture-in-picture, B-roll (generate the planned shots only within budget), sound effects, music (choose a fitting royalty-free track; no audition round), render, final QA. Deliver the finished cut, not a draft.
    - Deliver: upload_files the finished video (deliver: true), then download it into ./out/final.mp4 here.
    Each time you start a stage, overwrite ./progress.json with {"index": n, "total": 6, "step": "<name>", "detail": "<one short Chinese sentence>"}.
    Stages in order: 1 生成口播, 2 检查拼接, 3 剪辑规划, 4 包装配乐, 5 渲染质检, 6 下载交付.
    While the sandbox engineer works, check its PROGRESS.md at least every 5 minutes (the sandbox pauses after 15 idle minutes) and keep progress.json current.
    When done, write ./result.json: {"video": "out/final.mp4", "seconds": n, "material": "Renoise material id of the final cut", "credits_spent": n, "summary": "一两句中文：用了哪些包装", "checks": "一句中文：质检结果"}, and tell the user it is in BeanPod.
    On any blocker, write ./result.json {"error": "一句中文原因"}; never stop silently.
    """

    // MARK: 小工具

    /// 在登录 shell 里跑一行命令（Renoise 设置页也用它）。
    nonisolated static func shell(_ command: String) async -> (ok: Bool, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (false, "命令没能运行") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    nonisolated static func tail(_ output: String) -> String {
        String((output.split(separator: "\n").last.map(String.init) ?? "没有给出原因").prefix(140))
    }

    nonisolated static func object(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    nonisolated static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func write(_ object: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: url)
        }
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// 「做成视频」：选风格和主播 → 交给 Claude 桌面版（报价、确认都在那边）→ 这里跟进度，成片自动回来。
struct VideoSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(VideoMaker.self) private var maker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MascotView(mood: maker.busy ? .writing : .idle, power: .mid).frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("做成数字人口播").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("交给 Claude 桌面版，用 Renoise 的数字人和口播剪辑 skill 一条龙做：写稿、生成出镜、在 Renoise 云端剪辑包装（字幕花字、信息卡、B-roll、音乐），成片自动回到这里。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            switch maker.phase {
            case .idle, .choosing: choosing
            case .waiting: waiting
            case .quoted: quoted
            case .producing: producing
            case .finished(let url): finished(url)
            case .failed(let why): failed(why)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    // 选风格、主播
    @ViewBuilder private var choosing: some View {
        @Bindable var maker = maker
        VStack(alignment: .leading, spacing: 8) {
            Text("包装风格").font(.headline)
            HStack(spacing: 8) {
                ForEach(VideoMaker.Style.allCases) { s in styleCard(s) }
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("比例").foregroundStyle(.secondary)
                Picker("比例", selection: $maker.ratio) { Text("9:16 竖屏").tag("9:16"); Text("16:9 横屏").tag("16:9") }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
            }
            GridRow {
                Text("主播").foregroundStyle(.secondary)
                if maker.hosts.isEmpty {
                    Text("没有找到存好的数字人形象。").foregroundStyle(.secondary)
                } else {
                    Picker("主播", selection: $maker.host) { ForEach(maker.hosts) { h in Text(h.name).tag(Optional(h)) } }
                        .labelsHidden().frame(width: 260)
                }
            }
            GridRow {
                Text("出镜模型").foregroundStyle(.secondary)
                Picker("出镜模型", selection: $maker.model) {
                    Text("Wan 3.0（推荐，长镜头更稳）").tag("wan3.0-video")
                    Text("Grok Video 1.5（自拍随手感）").tag("grok-video-1.5")
                }
                .labelsHidden().frame(width: 260)
            }
        }
        if maker.claudeAppMissing {
            Label("这台 Mac 上没装 Claude 桌面版，做视频要靠它。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        } else if maker.renoiseMCPMissing {
            HStack {
                Label("Claude 里还没接 Renoise MCP。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                Spacer()
                Button("接上 Renoise MCP") { Task { await maker.connectRenoiseMCP() } }
            }
        }
        if !maker.setupNote.isEmpty { Text(maker.setupNote).font(.callout).foregroundStyle(.secondary) }
        HStack {
            Text("会在 Claude 桌面版新开一个会话，话已经填好，按发送开始。报价出来后在 Claude 里确认才花积分。")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("先不做") { dismiss() }
            Button("交给 Claude 做") { maker.start(store: store) }
                .buttonStyle(.glassProminent).disabled(maker.host == nil || maker.claudeAppMissing)
        }
        .controlSize(.large)
    }

    private func styleCard(_ s: VideoMaker.Style) -> some View {
        let picked = maker.style == s
        return Button { maker.style = s } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.callout.weight(.semibold))
                Text(s.fits).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(10)
            .background(picked ? Theme.accent.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.25), lineWidth: picked ? 1.5 : 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("已交给 Claude 桌面版").font(.headline)
                Spacer()
                if let start = maker.started { Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                step(1, "在 Claude 里按发送。")
                step(2, "第一次用会让你输入 /mcp 登录 Renoise，登好回它一句。")
                step(3, "它写稿、逐项核价，报价会同时显示在这里，不花积分。")
            }
            .padding(12).panel(radius: 12)
            footer(stop: true)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent)
            Text(text).font(.callout)
        }
    }

    @ViewBuilder private var quoted: some View {
        if let q = maker.quote {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("这条要花").foregroundStyle(.secondary)
                    Text("\(Int(q.credits.rounded()))").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("积分").foregroundStyle(.secondary)
                    if let b = q.balance { Text("· 账户里还有 \(Int(b))").font(.callout).foregroundStyle(.tertiary) }
                    Spacer()
                    Text("\(maker.style.name) · \(maker.ratio) · \(q.segments) 段 · 约 \(q.seconds) 秒").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(q.items.enumerated()), id: \.offset) { _, item in
                        HStack { Text(item.name); Spacer(); Text(item.detail).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
                    }
                    if !q.plan.isEmpty {
                        Divider()
                        Text(q.plan).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).panel(radius: 12)
                ForEach(q.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                }
                Label("要做就在 Claude 对话里回复确认，它按这个报价加 10% 余量封顶。豆仓会自动跟进度。", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("视频由 AI 生成，出镜的是数字人。发出去之前请自己看一遍，并按平台要求标明「内容由 AI 生成」。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                footer(stop: true)
            }
        }
    }

    private var producing: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                ForEach(Array(VideoMaker.steps.enumerated()), id: \.offset) { n, name in
                    stepView(n, name)
                }
            }
            Text(maker.stepDetail.isEmpty ? "准备中…" : maker.stepDetail).font(.callout.weight(.medium))
            HStack {
                if let start = maker.started {
                    Label { Text(start, style: .timer).monospacedDigit() } icon: { Image(systemName: "clock") }.font(.caption).foregroundStyle(.secondary)
                }
                Text("一般要二三十分钟，可以关掉这个窗口，做好了会提醒。").font(.caption).foregroundStyle(.tertiary)
            }
            footer(stop: false)
        }
    }

    private func footer(stop: Bool) -> some View {
        HStack {
            Button("工程目录") { maker.showProject() }.buttonStyle(.borderless)
            if stop {
                Button("不跟这条了") { maker.abandon(store: store) }.buttonStyle(.borderless)
                    .help("豆仓不再跟进这条。Claude 里那个会话要在 Claude 里停")
            }
            Spacer()
            if maker.phase == .waiting { Button("没打开？再开一次") { maker.openSession() } }
            Button("回到 Claude") { maker.showClaude() }
            Button("关闭") { dismiss() }.buttonStyle(.glassProminent)
        }
        .controlSize(.large)
    }

    private func stepView(_ n: Int, _ name: String) -> some View {
        let state = n + 1 < maker.stepIndex ? 2 : (n + 1 == maker.stepIndex ? 1 : 0)
        return VStack(spacing: 5) {
            ZStack {
                Circle().fill(state == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Theme.accent)).frame(width: 20, height: 20)
                if state == 2 { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else if state == 1 { ProgressView().controlSize(.mini).tint(.white) }
                else { Text("\(n + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Text(name).font(.caption.weight(state == 1 ? .semibold : .regular)).foregroundStyle(state == 0 ? .tertiary : .primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func finished(_ url: URL) -> some View {
        HStack {
            Label("做好了，带包装，已经放到这条录音的「改写」下面。", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            Spacer()
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("打开") { NSWorkspace.shared.open(url); dismiss() }.buttonStyle(.glassProminent)
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(why, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("工程目录") { maker.showProject() }.buttonStyle(.borderless)
                Spacer()
                Button("重新选") { maker.phase = .choosing }
                Button("关闭") { dismiss() }
            }
        }
    }
}
