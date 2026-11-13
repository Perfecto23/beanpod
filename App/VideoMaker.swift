import AppKit
import SwiftUI

/// 把一篇口播稿做成带完整包装的数字人口播视频。
///
/// 豆仓自己不剪：整条片子交给 Renoise MCP 上托管的两个 skill——
/// ai-avatar（写稿、分镜、生成数字人出镜段、检查、拼成 A-roll）→ talking-head-editor（在 Renoise 云端沙盒里
/// 粗剪、字幕花字、信息卡、画中画、B-roll、音效音乐、渲染质检）。按这两个 skill 一步步执行的是后台的 Claude Code（用户的 Claude 账号），
/// 它通过 Renoise 命令行已登录的凭据连 Renoise MCP。
/// 豆仓负责三件事：让用户选风格和主播、把报价摆出来等用户点头、把进度和成片接回来。
/// 分两轮跑：第一轮只规划和报价，不花积分；用户确认后接着同一个会话跑第二轮出片。
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

    /// 出片这一轮的几步，和提示词里约定的步骤名一致。
    static let steps = ["生成口播", "检查拼接", "剪辑规划", "包装配乐", "渲染质检", "下载交付"]

    enum Phase: Equatable { case idle, choosing, planning, quoted, producing, finished(URL), failed(String) }

    static let persona = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/digital-human-koubo/persona.json")

    var hosts: [Host] = []
    var host: Host?
    var style: Style = .premium
    var ratio = "9:16"
    var model = "wan3.0-video"
    var phase: Phase = .idle
    var quote: Quote?
    var stepIndex = 0
    var stepDetail = ""
    /// 后台正在做的事（取自它最近一次调用工具时写的说明）
    var activity = ""
    var started: Date?
    var claudeMissing = false
    var renoiseMissing = false

    var recording: UInt32 = 0
    var title = ""
    private var script = ""
    private var job: URL?
    private var session: String?
    private var process: Process?

    var busy: Bool { phase == .planning || phase == .producing }

    // MARK: 准备

    /// 打开「做成视频」时调用：读主播、按稿子推荐风格。不花积分，也还不调后台。
    func prepare(text: String, recording: UInt32, title: String, template: String) {
        guard !busy else { return }
        self.recording = recording
        self.title = title
        script = text
        quote = nil; session = nil; job = nil; activity = ""; stepIndex = 0; stepDetail = ""
        loadHosts()
        claudeMissing = Self.claudePath == nil
        renoiseMissing = Self.renoisePath == nil
        style = template.contains("吐槽") ? .variety : .premium
        ratio = "9:16"
        phase = .choosing
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

    // MARK: 第一轮：规划和报价（不花积分）

    func plan(store: BeanStore) async {
        guard let host, !busy else { return }
        let stamp = Int(Date.now.timeIntervalSince1970)
        let folder = store.folder.deletingLastPathComponent().appendingPathComponent("Videos/\(recording)-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        job = folder
        session = nil
        try? script.write(to: folder.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
        let day = Date.now.formatted(.iso8601.year().month().day())
        let brief: [String: Any] = [
            "deliverable": "finished MP4 with full packaging", "edit_style": style.brief, "aspect_ratio": ratio,
            "model": model, "host": ["name": host.name, "reference": "material:\(host.material)", "native_ratio": host.ratio],
            "language": "zh", "market": "China", "platform": ratio == "9:16" ? "抖音 / 视频号 / 小红书" : "B 站",
            "title": title, "music": "pick a royalty-free track that fits; no audition round",
            "sandbox_project": "~/projects/\(day)-beanpod-\(recording)",
            "notes": "Started from the BeanPod app. The user already chose every option above in the app and cannot answer questions mid-run.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: brief, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("brief.json"))
        }
        let mcp = #"{"mcpServers":{"renoise":{"type":"http","url":"https://renoise.ai/api/public/mcp","headers":{"Authorization":"Bearer ${RENOISE_API_KEY}"}}}}"#
        try? mcp.write(to: folder.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        store.addLog("做视频：开始规划报价（\(style.name) · \(ratio) · \(host.name) · \(model)），工程在 \(folder.path)")
        phase = .planning
        started = .now
        activity = ""
        let ok = await runClaude(Self.planPrompt, in: folder, store: store)
        guard phase == .planning else { return }      // 中途被停下了
        guard let q = Self.readJSON(folder.appendingPathComponent("quote.json")) else {
            phase = .failed(ok ? "没拿到报价。工程目录里有这一轮的记录。" : activity)
            return
        }
        if let error = q["error"] as? String { phase = .failed(error); return }
        let items = (q["items"] as? [[String: Any]] ?? []).map { item -> Quote.Item in
            let credits = Self.number(item["credits"]).map { "\(Int($0.rounded())) 积分" } ?? ""
            let count = Self.number(item["count"]).map { " × \(Int($0))" } ?? ""
            return Quote.Item(name: (item["name"] as? String ?? "") + count, detail: credits)
        }
        quote = Quote(credits: Self.number(q["credits"]) ?? 0, balance: Self.number(q["balance"]),
                      segments: Int(Self.number(q["segments"]) ?? 0), seconds: Int(Self.number(q["seconds"]) ?? 0),
                      items: items, plan: q["plan"] as? String ?? "", notes: q["notes"] as? [String] ?? [])
        phase = .quoted
        store.addLog("做视频：报价 \(Int(quote?.credits ?? 0)) 积分，\(quote?.segments ?? 0) 段 \(quote?.seconds ?? 0) 秒")
    }

    // MARK: 第二轮：生成到出片（用户点了确认才会走到这里）

    func produce(store: BeanStore) async {
        guard let job, let quote, phase == .quoted else { return }
        let budget = Int((quote.credits * 1.1).rounded(.up))
        store.addLog("做视频：用户确认，预算上限 \(budget) 积分，开始生成和剪辑")
        phase = .producing
        started = .now
        activity = ""
        stepIndex = 0; stepDetail = "准备生成"
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let p = Self.readJSON(job.appendingPathComponent("progress.json")) else { continue }
                self.stepIndex = Int(Self.number(p["index"]) ?? Double(self.stepIndex))
                self.stepDetail = p["detail"] as? String ?? p["step"] as? String ?? self.stepDetail
            }
        }
        defer { poll.cancel() }
        let ok = await runClaude(Self.producePrompt(budget: budget), in: job, store: store, resume: session)
        guard phase == .producing else { return }
        guard let r = Self.readJSON(job.appendingPathComponent("result.json")) else {
            phase = .failed(ok ? "片子没交付出来。已经生成的段在 Renoise 里，不会重复花积分。" : "做到一半停了：\(activity)")
            return
        }
        if let error = r["error"] as? String { phase = .failed(error); return }
        let local = (r["video"] as? String).map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : job.appendingPathComponent($0) }
        guard let local, FileManager.default.fileExists(atPath: local.path) else {
            phase = .failed("result.json 里写的成片在本机找不到。"); return
        }
        // 成片拷进录音库，挂在这条录音下面
        let name = "\(recording)-video-\(Int(Date.now.timeIntervalSince1970)).mp4"
        let out = store.folder.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: local, to: out)
        let spent = Int(Self.number(r["credits_spent"]) ?? quote.credits)
        store.addVideo(recording, file: name, host: "\(style.name) · \(host?.name ?? "数字人")", seconds: quote.seconds, credits: spent)
        store.addLog("做视频：交付 \(name)，花了 \(spent) 积分。\(r["summary"] as? String ?? "")")
        store.toast("checkmark.circle.fill", "视频做好了")
        phase = .finished(out)
    }

    /// 停下后台任务。已经提交给 Renoise 的段照样会扣积分。
    func stop(store: BeanStore) {
        let wasProducing = phase == .producing
        process?.terminate()
        process = nil
        store.addLog("做视频：用户停下了")
        phase = wasProducing ? .failed("已经停下。已提交的生成任务照常扣积分，生成好的段留在 Renoise 里。") : .choosing
    }

    func showProject() {
        if let job { NSWorkspace.shared.activateFileViewerSelecting([job]) }
    }

    // MARK: 调后台

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var renoisePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/renoise", "/opt/homebrew/bin/renoise", "/usr/local/bin/renoise"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 后台只用 Claude 账号：盖掉 settings.json 里把 Claude Code 指到别的接口的设置（不改那个文件，只对这次生效）。
    private static let claudeAccountSettings = #"{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_AUTH_TOKEN":"","ANTHROPIC_MODEL":"claude-opus-5-5","ANTHROPIC_DEFAULT_OPUS_MODEL":"claude-opus-5-5","ANTHROPIC_DEFAULT_SONNET_MODEL":"claude-sonnet-5-5","ANTHROPIC_DEFAULT_HAIKU_MODEL":"claude-haiku-5-5","ANTHROPIC_DEFAULT_FABLE_MODEL":"claude-fable-5-2"}}"#

    /// 在工程目录里跑一轮 claude -p，边跑边读它的输出更新「正在做什么」。返回这一轮是否正常结束。
    private func runClaude(_ prompt: String, in folder: URL, store: BeanStore, resume: String? = nil) async -> Bool {
        guard let claude = Self.claudePath else { phase = .failed("这台 Mac 上没找到 Claude Code（claude 命令）。"); return false }
        guard let renoise = Self.renoisePath else { phase = .failed("这台 Mac 上没找到 Renoise 命令行，到设置的「连接」里装上并登录。"); return false }
        let promptFile = folder.appendingPathComponent(resume == nil ? "prompt-plan.txt" : "prompt-produce.txt")
        try? prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--settings", Self.claudeAccountSettings, "--model", "claude-opus-5-5",
                    "--mcp-config", folder.appendingPathComponent("mcp.json").path, "--strict-mcp-config",
                    "--permission-mode", "acceptEdits",
                    "--allowedTools", "mcp__renoise", "Bash", "Read", "Write", "Edit", "Glob", "Grep", "TodoWrite"]
        if let resume { args += ["--resume", resume] }
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // renoise auth exec 把已登录的 Renoise 凭据放进环境变量，mcp.json 里引用它；凭据不落进任何文件
        let command = "cd '\(folder.path)' && '\(renoise)' auth exec '\(claude)' \(quoted) < '\(promptFile.path)'"
        let logFile = folder.appendingPathComponent(resume == nil ? "claude-plan.jsonl" : "claude-produce.jsonl")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        process = p
        let lines = AsyncStream<String> { continuation in
            let reader = LineReader()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { continuation.finish(); handle.readabilityHandler = nil; return }
                log?.write(chunk)
                for line in reader.feed(chunk) { continuation.yield(line) }
            }
        }
        do { try p.run() } catch { phase = .failed("后台没能启动：\(error.localizedDescription)"); return false }
        var success = false
        var sawResult = false
        for await line in lines {
            guard let event = Self.object(line) else {
                if !line.isEmpty, !sawResult { activity = String(line.prefix(160)) }
                continue
            }
            switch event["type"] as? String {
            case "system":
                if let id = event["session_id"] as? String { session = id }
            case "assistant":
                for block in (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                    if block["type"] as? String == "tool_use" {
                        let input = block["input"] as? [String: Any] ?? [:]
                        let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__renoise__", with: "Renoise ")
                        let what = input["description"] as? String ?? name
                        if !what.isEmpty { activity = what }
                    } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        activity = String(String(text.split(separator: "\n").first ?? "").prefix(80))
                    }
                }
            case "result":
                sawResult = true
                if let id = event["session_id"] as? String { session = id }
                let raw = event["result"] as? String ?? ""
                success = (event["subtype"] as? String) == "success" && (event["is_error"] as? Bool) != true && !raw.contains("API Error") && !raw.contains("Not logged in")
                if !success { activity = Self.explain(raw) }
            default: break
            }
        }
        p.waitUntilExit()
        try? log?.close()
        process = nil
        if !sawResult, activity.isEmpty { activity = "后台没有正常结束（退出码 \(p.terminationStatus)）。" }
        else if !sawResult { activity = Self.explain(activity) }
        return success && p.terminationStatus == 0
    }

    /// 把后台常见的报错换成人话。
    nonisolated static func explain(_ raw: String) -> String {
        if raw.contains("Not logged in") || raw.contains("/login") {
            return "后台要用你的 Claude 账号，但命令行版 Claude Code 还没登录。在终端里运行 claude，输入 /login 登录一次 Claude 账号，再回来点一次。"
        }
        if raw.contains("401") || raw.contains("authenticate") {
            return "Claude 账号的登录过期了。在终端里运行 claude，输入 /login 重新登录一次。"
        }
        if raw.lowercased().contains("renoise") && (raw.contains("not signed") || raw.contains("no credential") || raw.contains("auth login")) {
            return "Renoise 命令行没登录。到设置的「连接」里登录 Renoise。"
        }
        return raw.isEmpty ? "后台出错了，没有给出原因。" : String(raw.prefix(200))
    }

    // MARK: 提示词

    private static let planPrompt = """
    You are running a background job for the BeanPod app. The user is not in this conversation and cannot answer: never ask questions or wait for replies.
    Goal: turn the Chinese talking-head script in ./source.md into a finished, fully packaged AI-avatar talking-head video, using the Renoise MCP tools and the Renoise hosted skills.
    The current directory is this job's local folder. ./brief.json holds every choice the user already made in the app (edit style, aspect ratio, model, host reference material, platform). Treat them as the user's answers to the skills' clarifying questions.

    THIS ROUND: PLAN AND QUOTE ONLY. Do not call create_tasks or anything else that spends credits. Do not start a sandbox task.
    1. get_account. load_skill ai-avatar, then the files it tells you to read for planning (model-routing, its style menu and performance references), and load_skill talking-head-editor so the plan covers the edit.
    2. Following ai-avatar steps 0–2: write the script and performance as script.json (keep the content of source.md; you may tighten it for speech and add a hook, but do not invent facts), cut it into takes, and price every take with estimate_cost using the chosen model and host reference.
       Also plan any Renoise-generated B-roll the edit would want, and price it too. The edit itself (talking-head-editor in the sandbox) is free on this account's plan; say so if get_account confirms it.
       Keep script.json and the plan in the sandbox project folder named in brief.json (create it with the sandbox tool in command mode) and also save a copy of script.json here.
    3. Write ./quote.json (UTF-8, Chinese text for the user):
    {"segments": number of takes, "seconds": total seconds of takes, "credits": total credits, "balance": balance,
     "items": [{"name": "数字人出镜（模型名）", "count": takes, "credits": n}, {"name": "B-roll …", "count": n, "credits": n}],
     "plan": "两三句中文：开场怎么抓人、怎么剪、用哪些包装（字幕花字、信息卡、画中画、B-roll、音乐）",
     "notes": ["给用户的提醒，中文，比如稿子里要核实的说法"]}
    If something blocks you, write {"error": "一句中文原因"} instead.
    End with only the words: 报价完成
    """

    private static func producePrompt(budget: Int) -> String {
        """
        The user saw the quote in BeanPod and approved it: you may spend at most \(budget) credits in total (quote + 10%). That approval is the "yes" the ai-avatar skill asks for; the user still cannot answer questions.
        Now make the finished video, following the Renoise hosted skills end to end:
        - ai-avatar steps 3–5: generate the takes with create_tasks, wait, check speech and frames, reshoot only a broken take (within budget), join the A-roll in the sandbox project.
        - ai-avatar step 6 → talking-head-editor: the full edit in the sandbox, in the style from brief.json: rough cut, sentence-by-sentence edit plan, captions and keyword big text, info cards, picture-in-picture, B-roll (generate the planned shots only if they fit the budget), sound effects, music (choose a fitting royalty-free track yourself; no audition round), render, final QA. No drafts: deliver the finished cut.
        - Deliver: upload_files the finished video (deliver: true), then download_results / curl it into ./out/final.mp4 on this machine.

        Rules:
        - Never exceed \(budget) credits. If you would, stop and write ./result.json {"error": "中文原因，已花多少积分"}.
        - Each time you start one of these stages, overwrite ./progress.json with {"index": n, "total": 6, "step": "<name>", "detail": "<one short Chinese sentence on what you are doing>"}.
          Stages, in order: 1 生成口播, 2 检查拼接, 3 剪辑规划, 4 包装配乐, 5 渲染质检, 6 下载交付.
        - While the sandbox engineer works, check PROGRESS.md at least every 5 minutes (the sandbox pauses after 15 idle minutes) and keep progress.json current.
        - When done, write ./result.json: {"video": "out/final.mp4", "material": "Renoise material id of the final cut", "credits_spent": n, "summary": "一两句中文：用了哪些包装", "checks": "一句中文：质检结果"}.
        - On any blocker, write ./result.json {"error": "一句中文原因"}; never end silently.
        End with only: 交付完成, or the error.
        """
    }

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

    nonisolated static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// 把管道里读到的一块块字节拼成一行行。
private nonisolated final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func feed(_ chunk: Data) -> [String] {
        lock.withLock {
            buffer.append(chunk)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
    }
}

/// 「做成视频」：选风格和主播 → 规划报价（不花积分）→ 确认 → 后台出片，看进度。
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
                    Text("用 Renoise 的数字人和口播剪辑 skill 一条龙做：写稿、生成出镜、在 Renoise 云端剪辑包装（字幕花字、信息卡、B-roll、音乐），交付能直接发的成片。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if maker.claudeMissing || maker.renoiseMissing {
                Label(maker.claudeMissing ? "做视频要用 Claude Code，这台 Mac 上没找到 claude 命令。" : "没找到 Renoise 命令行，到设置的「连接」里装上并登录。",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                HStack { Spacer(); Button("关闭") { dismiss() } }
            } else {
                switch maker.phase {
                case .idle, .choosing: choosing
                case .planning: planning
                case .quoted: quoted
                case .producing: producing
                case .finished(let url): finished(url)
                case .failed(let why): failed(why)
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(maker.phase == .planning)
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
        HStack {
            Text("先规划和报价，这一步不花积分；看过报价点确认才开始生成。").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("先不做") { dismiss() }
            Button("规划并报价") { Task { await maker.plan(store: store) } }
                .buttonStyle(.glassProminent).disabled(maker.host == nil)
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

    private var planning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在规划和报价（不花积分）").font(.headline)
                Spacer()
                if let start = maker.started { Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
            }
            Text(maker.activity.isEmpty ? "正在读稿子、按风格写分镜、逐项核价，一般几分钟。" : "正在：\(maker.activity)")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack { Spacer(); Button("停下") { maker.stop(store: store) } }
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
                Text("视频由 AI 生成，出镜的是数字人。发出去之前请自己看一遍，并按平台要求标明「内容由 AI 生成」。确认后按这个报价加 10% 余量封顶，要超了就停。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("工程目录") { maker.showProject() }.buttonStyle(.borderless)
                    Spacer()
                    Button("重新选") { maker.phase = .choosing }
                    Button("花 \(Int(q.credits.rounded())) 积分开始做") { Task { await maker.produce(store: store) } }
                        .buttonStyle(.glassProminent)
                        .disabled((q.balance ?? .infinity) < q.credits)
                }
                .controlSize(.large)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(maker.stepDetail.isEmpty ? "准备中…" : maker.stepDetail).font(.callout.weight(.medium))
                if !maker.activity.isEmpty { Text("正在：\(maker.activity)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            HStack {
                if let start = maker.started {
                    Label { Text(start, style: .timer).monospacedDigit() } icon: { Image(systemName: "clock") }.font(.caption).foregroundStyle(.secondary)
                }
                Text("一般要二三十分钟，可以关掉这个窗口去做别的。").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("工程目录") { maker.showProject() }.buttonStyle(.borderless)
                Button("停下") { maker.stop(store: store) }
                Button("关闭") { dismiss() }.buttonStyle(.glassProminent)
            }
        }
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
