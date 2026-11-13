import AppKit
import SwiftUI

/// 把一篇口播稿做成带完整包装的数字人口播视频。
///
/// 豆仓自己不剪：整条片子交给 Claude Code 按 digital-human-koubo 这套 skill 来做——
/// 写稿、切段、Renoise 生成、回听拼接、对齐、按风格剪辑包装（景深字、要点组件、B-roll、音效、BGM）、封面首帧。
/// 豆仓负责三件事：让用户选风格和主播、把报价摆出来等用户点头、把进度和成片接回来。
/// 分两轮跑：第一轮只规划和报价，不花积分；用户确认后接着同一个会话跑第二轮出片。
@Observable
final class VideoMaker {
    /// 出镜的人，来自 skill 的 persona.json。
    struct Host: Identifiable, Hashable {
        var id: String            // persona.json 里的键：default / me / cat / dog …
        var name: String
        var ratio: String
        var material: String
    }

    enum Style: String, CaseIterable, Identifiable {
        case A, B, C, D, E
        var id: String { rawValue }
        var name: String {
            switch self {
            case .A: "小林式解说"
            case .B: "网红花字口播"
            case .C: "发布解读"
            case .D: "保姆级教程"
            case .E: "多主播接力"
            }
        }
        var fits: String {
            switch self {
            case .A: "把一件事讲透：图表、证据、B-roll 轮着上，主播在小窗和全屏之间切"
            case .B: "竖屏安利、种草、观点：逐字花字、关键词放大、表情、跳切推近"
            case .C: "新品新功能快讯：主播侧边讲，右边参数卡、官网截图、对比"
            case .D: "几步做出来：顶部步骤条、界面演示、圈出按钮"
            case .E: "多语言、多场景、几位主播接力"
            }
        }
        var ratio: String { self == .B ? "9:16" : "16:9" }
        var preview: URL? {
            let file = ["A": "A_xiaolin_explainer", "B": "B_huazi_koubo", "C": "C_launch_side", "D": "D_tutorial", "E": "E_multi_host"][rawValue]!
            let url = VideoMaker.skill.appendingPathComponent("assets/styles/\(file).jpg")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    /// 出片这一轮的七步，和提示词里约定的步骤名一致。
    static let steps = ["生成口播", "下载", "回听拼接", "对齐字幕", "剪辑包装", "混音导出", "封面首帧"]

    enum Phase: Equatable { case idle, choosing, planning, quoted, producing, finished(URL), failed(String) }

    static let skill = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/digital-human-koubo")

    var hosts: [Host] = []
    var host: Host?
    var style: Style = .B
    var ratio = "9:16"
    var huazi = "标准"
    var cloneVoice = false
    var phase: Phase = .idle
    var quote: Quote?
    var stepIndex = 0
    var stepDetail = ""
    /// Claude 正在做的事（取自它最近一次调用工具时写的说明）
    var activity = ""
    var started: Date?
    var claudeMissing = false
    var skillMissing = false

    var recording: UInt32 = 0
    var title = ""
    private var script = ""
    private var job: URL?
    private var session: String?
    private var process: Process?

    var busy: Bool { phase == .planning || phase == .producing }

    // MARK: 准备

    /// 打开「做成视频」时调用：读主播、按稿子推荐风格。不花积分，也还不调 Claude。
    func prepare(text: String, recording: UInt32, title: String, template: String) {
        guard !busy else { return }
        self.recording = recording
        self.title = title
        script = text
        quote = nil; session = nil; job = nil; activity = ""; stepIndex = 0; stepDetail = ""
        loadHosts()
        claudeMissing = Self.claudePath == nil
        skillMissing = !FileManager.default.fileExists(atPath: Self.skill.appendingPathComponent("SKILL.md").path)
        // 推荐：口播稿、短视频脚本走竖屏花字；拆解、文章走小林式解说；教程走保姆级
        style = template.contains("教程") ? .D : (template.contains("拆解") || template.contains("文章") ? .A : .B)
        ratio = style.ratio
        phase = .choosing
    }

    private func loadHosts() {
        var out: [Host] = []
        if let data = try? Data(contentsOf: Self.skill.appendingPathComponent("persona.json")),
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
        let folder = store.folder.deletingLastPathComponent().appendingPathComponent("Videos/\(recording)-\(Int(Date.now.timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        job = folder
        session = nil
        try? script.write(to: folder.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
        let brief: [String: Any] = [
            "style": style.rawValue, "ratio": ratio, "huazi": huazi, "host": [host.id], "host_name": host.name,
            "voice": cloneVoice && host.id == "me" ? "本人克隆声" : "Grok 原生声", "languages": ["zh"],
            "platform": ratio == "9:16" ? "抖音 / 视频号 / 小红书" : "B 站 / YouTube", "title": title,
            "notes": "从豆仓发起的后台任务，用户已在豆仓里选好以上各项",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: brief, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("brief.json"))
        }
        store.addLog("做视频：开始规划报价（\(style.name) · \(ratio) · \(host.name)），工程在 \(folder.path)")
        phase = .planning
        started = .now
        activity = ""
        let ok = await runClaude(Self.planPrompt, in: folder, store: store)
        guard phase == .planning else { return }      // 中途被停下了
        guard let q = Self.readJSON(folder.appendingPathComponent("quote.json")) else {
            phase = .failed(ok ? "没拿到报价。工程目录里有这一轮的记录。" : "规划没做完：\(activity)")
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
            phase = .failed(ok ? "片子没交付出来。生成过的段都在工程目录里，不会重复花积分。" : "做到一半停了：\(activity)")
            return
        }
        if let error = r["error"] as? String { phase = .failed(error); return }
        guard let path = r["video"] as? String, FileManager.default.fileExists(atPath: path) else {
            phase = .failed("result.json 里写的成片找不到。"); return
        }
        // 成片拷进录音库，挂在这条录音下面
        let name = "\(recording)-video-\(Int(Date.now.timeIntervalSince1970)).mp4"
        let out = store.folder.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: out)
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
        phase = wasProducing ? .failed("已经停下。已提交的生成任务照常扣积分，生成好的段留在工程目录里。") : .choosing
    }

    func showProject() {
        if let job { NSWorkspace.shared.activateFileViewerSelecting([job]) }
    }

    // MARK: 调 Claude Code

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 在工程目录里跑一轮 claude -p，边跑边读它的输出更新「正在做什么」。返回这一轮是否正常结束。
    private func runClaude(_ prompt: String, in folder: URL, store: BeanStore, resume: String? = nil) async -> Bool {
        guard let claude = Self.claudePath else { phase = .failed("这台 Mac 上没找到 Claude Code（claude 命令）。"); return false }
        let promptFile = folder.appendingPathComponent(resume == nil ? "prompt-plan.txt" : "prompt-produce.txt")
        try? prompt.write(to: promptFile, atomically: true, encoding: .utf8)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                    "--allowedTools", "Bash", "Read", "Write", "Edit", "Glob", "Grep", "Skill", "TodoWrite",
                    "--add-dir", "\(home)/.claude/skills", "--add-dir", store.folder.path]
        if let resume { args += ["--resume", resume] }
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // 走登录 shell：拿到终端里那套 PATH 和模型设置；提示词从文件喂进去
        let command = "cd '\(folder.path)' && '\(claude)' \(quoted) < '\(promptFile.path)'"
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
        do { try p.run() } catch { phase = .failed("Claude Code 没能启动：\(error.localizedDescription)"); return false }
        var success = false
        for await line in lines {
            guard let event = Self.object(line) else { continue }
            switch event["type"] as? String {
            case "system":
                if let id = event["session_id"] as? String { session = id }
            case "assistant":
                for block in (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                    if block["type"] as? String == "tool_use", let input = block["input"] as? [String: Any] {
                        let what = input["description"] as? String ?? (block["name"] as? String ?? "")
                        if !what.isEmpty { activity = what }
                    } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        activity = String(String(text.split(separator: "\n").first ?? "").prefix(80))
                    }
                }
            case "result":
                if let id = event["session_id"] as? String { session = id }
                success = (event["subtype"] as? String) == "success" && (event["is_error"] as? Bool) != true
                if !success || (event["result"] as? String ?? "").contains("API Error") {
                    let raw = event["result"] as? String ?? "Claude 报错"
                    success = false
                    activity = raw.contains("401") || raw.contains("authenticate")
                        ? "后台的 Claude Code 没登录上（~/.claude/settings.json 里配的模型接口返回 401，密钥可能过期了）。豆仓本身没事，换个能用的登录方式就能接着做。"
                        : String(raw.prefix(160))
                }
            default: break
            }
        }
        p.waitUntilExit()
        try? log?.close()
        process = nil
        return success && p.terminationStatus == 0
    }

    // MARK: 提示词

    private static let planPrompt = """
    你在替「豆仓」App 跑一个后台任务，用户不在对话里，**不能提问**（不要用 AskUserQuestion，也不要等回复）。
    用 digital-human-koubo skill（\(skill.path)/SKILL.md，先完整读一遍）把当前目录 source.md 里的稿子做成数字人口播视频。当前目录就是这条片子的工程目录。

    **这一轮只做规划和报价，绝对不要创建任何会花积分的任务。**
    1. 读 brief.json：风格、比例、花字强度、主播、声音，用户已经在豆仓里选好了，第 0 步的「让用户选」直接用它。
    2. 按 skill 的「准备」检查环境。没有 Renoise MCP 时用 renoise 命令行（`renoise account --json` 看余额，`renoise task cost … --json` 核价），写法见 skill 和 renoise-cli 的说明。
    3. 按选定风格的写法把 source.md 写成 script.json：内容以 source.md 为准，可以按风格调整口语、钩子和切段，不要编造稿子里没有的事实。
    4. 切段并估价：口播段，加上这个风格默认包装要用到的 B-roll、配图、贴纸等所有会花积分的项，逐项用 Renoise 核价。剪辑、包装、音效、封面在本机做，不花积分。
    5. 写 quote.json（UTF-8）：
    {"style": "…", "ratio": "…", "segments": 口播段数, "seconds": 口播总秒数, "credits": 总积分, "balance": 余额,
     "items": [{"name": "口播 720p", "count": 段数, "credits": 积分}, {"name": "B-roll", "count": …, "credits": …}],
     "plan": "两三句话：这条片子怎么剪、开场怎么抓人、用哪些包装组件",
     "notes": ["要提醒用户的风险，比如余额不够、稿子里有要核实的说法"]}
    出了解决不了的问题就写 {"error": "一句话原因"}。
    写完 quote.json 就结束，最后只回复「报价完成」。
    """

    private static func producePrompt(budget: Int) -> String {
        """
        用户已经在豆仓里看过报价并确认：**这条片子最多花 \(budget) 积分**（报价加 10% 余量）。
        现在按 digital-human-koubo skill 把第 3 步到第 7 步全部做完，交付一条**带完整包装**的成片：
        生成口播 → 下载 → 回听 + 抽帧 + 拼接 → 对齐 → 按 brief.json 的风格剪辑和包装（packaging-presets.json 里这个风格的默认包装、B-roll、音效、BGM、混音）→ 封面并接成首帧。
        也要做 skill 里的鱼鳞纹自检和语速测算。

        规则：
        - 仍然不能提问。skill 里「先拍第 1 段给用户确认」改成：你自己检查第 1 段（音色、口型、有没有自己烧字幕），没问题就批量；有问题重拍那一段。
        - 累计花费不能超过 \(budget) 积分。要超了就停下，写 result.json {"error": "原因，已花多少"}。
        - 每进入一个大步骤，覆盖写 progress.json：{"index": 第几步(1-7), "total": 7, "step": "步骤名", "detail": "正在做什么，一句话"}。
          步骤名固定用：生成口播、下载、回听拼接、对齐字幕、剪辑包装、混音导出、封面首帧。
        - 全部做完写 result.json：{"video": "交付成片的绝对路径（带封面首帧那一版）", "cover": "封面图绝对路径", "credits_spent": 实际花的积分,
          "summary": "一两句：用了哪些包装", "checks": "鱼鳞纹和语速自检结果，一句话"}。
        - 出了解决不了的问题也写 result.json {"error": "…"}，别让它悄悄结束。
        最后只回复「交付完成」或错误原因。
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
                    Text("按「数字人口播」skill 一条龙做：写稿、生成、剪辑包装、封面，交付的就是能直接发的成片。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if maker.claudeMissing || maker.skillMissing {
                Label(maker.claudeMissing ? "做视频要用 Claude Code，这台 Mac 上没找到 claude 命令。" : "没找到「数字人口播」skill（~/.claude/skills/digital-human-koubo）。",
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
        .frame(width: 640)
        .interactiveDismissDisabled(maker.phase == .planning)
    }

    // 选风格、主播
    @ViewBuilder private var choosing: some View {
        @Bindable var maker = maker
        VStack(alignment: .leading, spacing: 8) {
            Text("剪辑风格").font(.headline)
            HStack(spacing: 8) {
                ForEach(VideoMaker.Style.allCases) { s in styleCard(s) }
            }
            Text(maker.style.fits).font(.caption).foregroundStyle(.secondary)
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("比例").foregroundStyle(.secondary)
                Picker("比例", selection: $maker.ratio) { Text("9:16 竖屏").tag("9:16"); Text("16:9 横屏").tag("16:9") }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
            }
            if maker.style == .B {
                GridRow {
                    Text("花字").foregroundStyle(.secondary)
                    Picker("花字", selection: $maker.huazi) { ForEach(["克制", "标准", "热闹"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
            }
            GridRow {
                Text("主播").foregroundStyle(.secondary)
                if maker.hosts.isEmpty {
                    Text("persona.json 里没有能用的形象。").foregroundStyle(.secondary)
                } else {
                    Picker("主播", selection: $maker.host) { ForEach(maker.hosts) { h in Text(h.name).tag(Optional(h)) } }
                        .labelsHidden().frame(width: 260)
                }
            }
            if maker.host?.id == "me" {
                GridRow {
                    Text("声音").foregroundStyle(.secondary)
                    Picker("声音", selection: $maker.cloneVoice) { Text("Grok 原生声（更快）").tag(false); Text("本人克隆声").tag(true) }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                }
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
        return Button { maker.style = s; maker.ratio = s.ratio } label: {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let url = s.preview, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else { Rectangle().fill(.quaternary) }
                }
                .frame(width: 102, height: 60).clipShape(.rect(cornerRadius: 7))
                Text("\(s.rawValue) · \(s.name)").font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(5)
            .background(picked ? Theme.accent.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.25), lineWidth: picked ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .help(s.fits)
    }

    private var planning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在规划和报价（不花积分）").font(.headline)
                Spacer()
                if let start = maker.started { Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
            }
            Text(maker.activity.isEmpty ? "Claude 在读稿子、按风格写分段、逐项核价，一般几分钟。" : "正在：\(maker.activity)")
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
            Label("做好了，带包装和封面，已经放到这条录音的「改写」下面。", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
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
