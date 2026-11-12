import AppKit
import SwiftUI

/// 把一篇口播稿或短视频脚本交给 Renoise，做成数字人口播视频。
/// 流程：挑出要念的话 → 按十几秒一段切开 → 报价 → 用户确认 → 逐段生成 → 下载 → 拼成一条。
/// 花积分的事一定先报价、等用户点头，这里不会自己开始。
@Observable
final class VideoMaker {
    /// 出镜的人。来自数字人口播那套流程存下的形象（~/.claude/skills/digital-human-koubo/persona.json），也可以手填素材编号。
    struct Host: Identifiable, Hashable {
        var id: String            // 素材编号
        var name: String
        var ratio: String
        /// 提示词模板，里面有 {line} 等占位。
        var template: String
        var voice: String
        var language = "Mandarin Chinese"
    }

    struct Segment: Identifiable, Equatable {
        let id = UUID()
        var line: String
        var seconds: Int
        var task: String?
        var state: State = .waiting
        enum State: Equatable { case waiting, generating, downloading, done, failed(String) }
    }

    enum Phase: Equatable { case idle, quoting, ready, running, joining, finished(URL), failed(String) }

    var hosts: [Host] = []
    var host: Host?
    var customMaterial = ""
    var resolution = "720p"
    var segments: [Segment] = []
    var credits: Double?
    var balance: Double?
    var phase: Phase = .idle
    var cliMissing = false
    /// 这次是给哪条录音的哪篇改写做的。
    var recording: UInt32 = 0
    var title = ""

    private static let genericTemplate = """
    The person in the reference image talks straight to the camera, same framing, outfit, background and lighting as the reference, like a friendly creator sharing a short talk: warm eye contact, expressive face, natural small hand gestures. Locked-off camera, no zoom. They speak {language}, clearly lip-synced, in a natural, clear voice at a natural pace:
    “{line}”
    Sound: only the voice and quiet room tone, no music, no subtitles, no captions, no on-screen text of any kind.
    """

    var totalSeconds: Int { segments.reduce(0) { $0 + $1.seconds } }
    /// 稿子里留着「待核实」「【】」这类占位：念出来会很怪，要先回去改稿。
    var placeholders: Bool { segments.contains { $0.line.contains("待核实") || $0.line.contains("【") || $0.line.contains("XX") } }
    var done: Int { segments.filter { $0.state == .done }.count }

    // MARK: 准备

    /// 打开「做成视频」时调用：读形象、切段、问价。
    func prepare(text: String, recording: UInt32, title: String) async {
        self.recording = recording
        self.title = title
        phase = .quoting
        credits = nil
        loadHosts()
        segments = Self.split(Self.spoken(text))
        let found = await Self.shell("command -v renoise >/dev/null 2>&1 && echo yes")
        cliMissing = !found.output.contains("yes")
        guard !cliMissing, !segments.isEmpty else { phase = .ready; return }
        await quote()
    }

    private func loadHosts() {
        var out: [Host] = []
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/digital-human-koubo/persona.json")
        if let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let act = (root["acts"] as? [String: Any])?["full"] as? String ?? "warm eye contact, natural hand gestures"
            func material(_ d: [String: Any]) -> String? {
                let direct = d["reference_material"] as? String ?? (d["renoise"] as? [String: Any])?["reference_material"] as? String
                return direct.map { $0.replacingOccurrences(of: "material:", with: "") }
            }
            func voice(_ d: [String: Any]) -> String {
                (d["voice"] as? [String: Any])?["desc"] as? String ?? d["voice"] as? String ?? "natural, clear voice at a natural pace"
            }
            func fill(_ template: String) -> String {
                template.replacingOccurrences(of: "{ref}", with: "the reference image")
                    .replacingOccurrences(of: "{purpose}", with: "sharing a short talk")
                    .replacingOccurrences(of: "{act}", with: act)
            }
            if let id = material(root), let template = root["prompt_template"] as? String {
                out.append(Host(id: id, name: root["name"] as? String ?? "数字人", ratio: (root["model"] as? [String: Any])?["ratio"] as? String ?? "9:16",
                                template: fill(template), voice: voice(root)))
            }
            for (_, value) in (root["other_hosts"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let d = value as? [String: Any], let id = material(d) else { continue }
                out.append(Host(id: id, name: d["name"] as? String ?? "数字人", ratio: d["ratio"] as? String ?? "16:9",
                                template: fill(d["prompt_template"] as? String ?? Self.genericTemplate), voice: voice(d)))
            }
        }
        hosts = out
        if host == nil || !out.contains(where: { $0.id == host?.id }) { host = out.first }
    }

    /// 现在选的出镜人；手填了素材编号就用手填的。
    var chosen: Host? {
        let custom = customMaterial.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "material:", with: "")
        if !custom.isEmpty, custom.allSatisfy(\.isNumber) {
            return Host(id: custom, name: "素材 \(custom)", ratio: host?.ratio ?? "9:16", template: Self.genericTemplate, voice: "natural, clear voice")
        }
        return host
    }

    /// 从改写稿里挑出要念出来的话：有「口播」那一栏的表格就取那一栏，否则取正文；标题、符号、画面说明都不念。
    nonisolated static func spoken(_ text: String) -> String {
        var lines: [String] = []
        var column: Int?
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("|") {
                var cells = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }      // 表头下面那行横线
                if let i = cells.firstIndex(where: { $0.contains("口播") || $0.contains("台词") || $0.contains("旁白") }), column == nil { column = i; continue }
                if let c = column, c < cells.count, !cells[c].isEmpty { lines.append(cells[c]) }
                continue
            }
            if t.hasPrefix("#") || t.allSatisfy({ "-*_ ".contains($0) }) { continue }
            // 「**钩子（前 3 秒）：**」这种小标题本身不念，冒号后面有话就念后面的
            var s = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("> ") { s.removeFirst(2) }
            if let colon = s.firstIndex(where: { $0 == "：" || $0 == ":" }), s.distance(from: s.startIndex, to: colon) <= 14 {
                s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            if !s.isEmpty { lines.append(s) }
        }
        return lines.joined(separator: "\n")
    }

    /// 按句子切段：每段不超过 15 秒（中文按每秒 5.4 个字算），太短的并到一起。
    nonisolated static func split(_ text: String) -> [Segment] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            if ch == "\n" { if !current.isEmpty { sentences.append(current); current = "" }; continue }
            current.append(ch)
            if "。！？!?；".contains(ch) { sentences.append(current); current = "" }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        var out: [Segment] = []
        var chunk = ""
        func flush() {
            let line = chunk.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            out.append(Segment(line: line, seconds: seconds(for: line)))
            chunk = ""
        }
        // 脚本里开头的钩子常常和第一个镜头的口播是同一句话：说过的不再说第二遍
        func bare(_ s: String) -> String { String(s.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }) }
        var said = ""
        for s in sentences.map({ $0.trimmingCharacters(in: .whitespaces) }) where !s.isEmpty {
            let key = bare(s)
            if key.count >= 6, said.contains(key) { continue }
            said += key + "\n"
            if (chunk + s).count > 70, !chunk.isEmpty { flush() }
            chunk += s
            if chunk.count >= 45 { flush() }
        }
        flush()
        return out
    }

    nonisolated static func seconds(for line: String) -> Int {
        let chars = line.filter { !$0.isPunctuation && !$0.isWhitespace }.count
        return max(4, min(15, Int((Double(chars) / 5.4).rounded(.up)) + 1))
    }

    /// 问 Renoise 这些段一共要多少积分。只问价，不生成。
    func quote() async {
        phase = .quoting
        var total = 0.0
        var cache: [Int: Double] = [:]
        for s in segments {
            if cache[s.seconds] == nil {
                let r = await Self.shell("renoise task cost grok-video-1.5 --duration \(s.seconds) --resolution \(resolution) --json")
                guard let obj = Self.object(r.output), let c = obj["estimatedCredit"] as? Double else {
                    phase = .failed("没问到价格：" + Self.tail(r.output)); return
                }
                cache[s.seconds] = c
                balance = obj["balance"] as? Double ?? balance
            }
            total += cache[s.seconds] ?? 0
        }
        credits = total
        phase = .ready
    }

    // MARK: 生成

    /// 用户点了确认之后才会走到这里。
    func generate(store: BeanStore) async {
        guard let host = chosen, phase == .ready, !segments.isEmpty else { return }
        phase = .running
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-video-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store.addLog("开始做视频：\(segments.count) 段，\(totalSeconds) 秒，预计 \(Int(credits ?? 0)) 积分，出镜：\(host.name)")

        // 先把每一段的任务都建好，再一段一段等：这样几段是同时在生成的
        for i in segments.indices {
            let prompt = host.template.replacingOccurrences(of: "{line}", with: segments[i].line)
                .replacingOccurrences(of: "{voice}", with: host.voice).replacingOccurrences(of: "{language}", with: host.language)
            let file = work.appendingPathComponent("p\(i).txt")
            try? prompt.write(to: file, atomically: true, encoding: .utf8)
            let r = await Self.shell("renoise task create grok-video-1.5 --type video --prompt-file '\(file.path)' --materials \(host.id):reference_image --duration \(segments[i].seconds) --ratio \(host.ratio) --resolution \(resolution) --tags beanpod --json")
            if let id = Self.taskID(r.output) {
                segments[i].task = id; segments[i].state = .generating
            } else {
                segments[i].state = .failed(Self.tail(r.output))
                store.addLog("第 \(i + 1) 段没建成：\(Self.tail(r.output))")
            }
        }
        var files: [URL] = []
        for i in segments.indices {
            guard let id = segments[i].task else { continue }
            let waited = await Self.shell("renoise task wait \(id) --timeout 20m --json")
            let result = await Self.shell("renoise task result \(id) --json")
            guard let link = Self.object(result.output)?["videoUrl"] as? String else {
                segments[i].state = .failed(Self.tail(waited.output + "\n" + result.output)); continue
            }
            segments[i].state = .downloading
            let target = work.appendingPathComponent(String(format: "s%02d.mp4", i))
            let got = await Self.shell("curl -L -s --retry 5 --retry-delay 2 -C - -o '\(target.path)' '\(link)'")
            if got.ok, (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0 > 10_000 {
                segments[i].state = .done; files.append(target)
            } else {
                segments[i].state = .failed("下载没成功")
            }
        }
        guard !files.isEmpty else { phase = .failed("一段都没有生成出来。积分只会按实际生成的段扣。"); return }

        // 拼成一条：统一成同样的画面和声音格式再接起来，避免有的段接不上
        phase = .joining
        let list = work.appendingPathComponent("list.txt")
        try? files.map { "file '\($0.path)'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let name = "\(recording)-video-\(Int(Date.now.timeIntervalSince1970)).mp4"
        let out = store.folder.appendingPathComponent(name)
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let ffmpeg, files.count > 1 {
            let r = await Self.shell("'\(ffmpeg)' -v error -y -f concat -safe 0 -i '\(list.path)' -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart '\(out.path)'")
            guard r.ok else { phase = .failed("拼接没成功：" + Self.tail(r.output)); return }
        } else {
            // 只有一段，或者这台电脑没有 ffmpeg：先给第一段
            try? FileManager.default.removeItem(at: out)
            guard (try? FileManager.default.copyItem(at: files[0], to: out)) != nil else { phase = .failed("视频没能存下来。"); return }
        }
        store.addVideo(recording, file: name, host: host.name, seconds: files.count == segments.count ? totalSeconds : 0, credits: Int(credits ?? 0))
        store.addLog("视频做好了：\(out.lastPathComponent)（\(files.count)/\(segments.count) 段）")
        phase = .finished(out)
    }

    // MARK: 小工具

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

    /// 命令输出里可能夹着别的提示行，找到第一个 JSON 对象来读。
    nonisolated static func object(_ output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))) as? [String: Any]
    }

    nonisolated static func taskID(_ output: String) -> String? {
        guard let obj = object(output) else { return nil }
        let inner = (obj["task"] as? [String: Any]) ?? (obj["tasks"] as? [[String: Any]])?.first ?? obj
        for key in ["taskId", "id"] {
            if let n = inner[key] as? Int { return String(n) }
            if let s = inner[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    nonisolated static func tail(_ output: String) -> String {
        String((output.split(separator: "\n").last.map(String.init) ?? "没有给出原因").prefix(140))
    }
}

/// 「做成视频」的确认单：谁出镜、分几段、多长、要多少积分。点了确认才开始生成。
struct VideoSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(VideoMaker.self) private var maker
    @Environment(RenoiseSetup.self) private var renoise
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var maker = maker
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MascotView(mood: running ? .writing : .idle, power: .mid).frame(width: 76, height: 76).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("做成数字人口播").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("用 Renoise 生成：一个数字人对着镜头把这篇稿子念出来。先报价，你确认了才开始。").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if maker.cliMissing || (!renoise.checking && !renoise.loggedIn) {
                // 还没装好 Renoise：说清楚差哪一步，给一个直达安装页面的按钮
                VStack(alignment: .leading, spacing: 10) {
                    Label(maker.cliMissing ? "做视频要用 Renoise，这台 Mac 上还没装。" : "Renoise 装好了，但还没登录账户。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber)
                    Text("安装和登录各点一下就行，装好回来再点「做成视频」。").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("先不做") { dismiss() }
                        Button(maker.cliMissing ? "去安装 Renoise" : "去登录 Renoise") { openWindow(id: "connect"); dismiss() }.buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                }
                .task { await renoise.refresh() }
            } else if maker.segments.isEmpty {
                Label("这篇稿子里没找到能念出来的句子。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            } else {
                // 谁出镜
                VStack(alignment: .leading, spacing: 8) {
                    Text("谁出镜").font(.headline)
                    if maker.hosts.isEmpty {
                        Text("没有找到存好的数字人形象。到 Renoise 里上传一张人像，把素材编号填在下面。").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Picker("形象", selection: $maker.host) {
                            ForEach(maker.hosts) { h in Text("\(h.name) · \(h.ratio)").tag(Optional(h)) }
                        }
                        .labelsHidden().pickerStyle(.radioGroup).disabled(running)
                    }
                    HStack {
                        TextField("或者填别的素材编号（Renoise 里的人像）", text: $maker.customMaterial).textFieldStyle(.roundedBorder).frame(width: 300)
                        Picker("清晰度", selection: $maker.resolution) { Text("720p").tag("720p"); Text("480p（便宜）").tag("480p") }
                            .labelsHidden().fixedSize()
                            .onChange(of: maker.resolution) { Task { await maker.quote() } }
                    }
                    .disabled(running)
                }

                // 分几段
                VStack(alignment: .leading, spacing: 6) {
                    Text("要念的内容 · \(maker.segments.count) 段 · 约 \(maker.totalSeconds) 秒").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(maker.segments.enumerated()), id: \.element.id) { n, s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    stateIcon(s.state).frame(width: 18)
                                    Text("\(n + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 16, alignment: .trailing)
                                    Text(s.line).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Text("\(s.seconds) 秒").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 200)
                    .panel(radius: 12)
                }

                if maker.placeholders, maker.phase == .ready {
                    Label("稿子里还留着「待核实」这样的占位，数字人会照着念出来。建议先回去把稿子改好再做。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                }

                footer
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(running)
    }

    private var running: Bool { maker.phase == .running || maker.phase == .joining }

    @ViewBuilder private var footer: some View {
        switch maker.phase {
        case .quoting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在问价…").foregroundStyle(.secondary); Spacer(); Button("取消") { dismiss() } }
        case .failed(let why):
            HStack {
                Label(why, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("关闭") { dismiss() }
            }
        case .running, .joining:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(maker.phase == .joining ? "正在把各段拼成一条…" : "正在生成，做好 \(maker.done) / \(maker.segments.count) 段。一段一般要几分钟，可以先去做别的。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .finished(let url):
            HStack {
                Label("做好了，已经放到这条录音的「改写」下面。", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("打开") { NSWorkspace.shared.open(url); dismiss() }.buttonStyle(.glassProminent)
            }
        case .ready, .idle:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("这次要花").foregroundStyle(.secondary)
                    Text(maker.credits.map { "\(Int($0.rounded()))" } ?? "—").font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("积分").foregroundStyle(.secondary)
                    if let b = maker.balance { Text("· 账户里还有 \(Int(b))").font(.callout).foregroundStyle(.tertiary) }
                }
                Text("视频由 AI 生成，出镜的是数字人。发出去之前请自己看一遍，并按平台要求标明「内容由 AI 生成」。用别人的形象要先得到本人同意。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("先不做") { dismiss() }
                    Button("花 \(maker.credits.map { "\(Int($0.rounded()))" } ?? "—") 积分生成") { Task { await maker.generate(store: store) } }
                        .buttonStyle(.glassProminent)
                        .disabled(maker.chosen == nil || maker.credits == nil || (maker.balance ?? .infinity) < (maker.credits ?? 0))
                }
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder private func stateIcon(_ s: VideoMaker.Segment.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .generating, .downloading: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.rec)
        }
    }
}
