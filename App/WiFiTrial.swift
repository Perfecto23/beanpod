import BeanKit
import Foundation
import Network

/// Wi‑Fi 快传的真机试验。还不是正式功能：只从录音豆拉一条**已经下载过**的录音，
/// 拉回来的东西放在单独的文件夹里跟本地那份比对，不动录音库。
///
/// 试验期间这台 Mac 会离开原来的 Wi‑Fi、连到录音豆的热点上（断网一分钟左右），
/// 所以整套流程必须自己跑完，并且不管中间哪一步失败，最后都要把 Wi‑Fi 和蓝牙恢复回来。
/// 每一步都写进 `WiFiTrial/trial.log`，跑完后写一个 `done` 文件。
extension BeanStore {
    static var wifiTrialFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/WiFiTrial", isDirectory: true)
    }

    func startWifiTrial() {
        guard !wifiTrialRunning else { return }
        Task { await runWifiTrial() }
    }

    private func runWifiTrial() async {
        wifiTrialRunning = true
        defer { wifiTrialRunning = false }

        let fm = FileManager.default
        let folder = Self.wifiTrialFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let logURL = folder.appendingPathComponent("trial.log")
        let doneURL = folder.appendingPathComponent("done")
        try? fm.removeItem(at: doneURL)
        try? Data().write(to: logURL)
        let started = Date.now
        func note(_ s: String) {
            let line = String(format: "%7.2f  %@\n", Date.now.timeIntervalSince(started), s)
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            addLog("[Wi‑Fi 试验] \(s)")
        }
        var verdict = "没跑完"
        defer { try? Data(verdict.utf8).write(to: doneURL) }

        // 0. 前提
        guard link == .ready, encryptionReady, recState == .idle, macRec == .off, !transferBusy else {
            verdict = "前提不满足：录音豆要连着、密钥协商完成、没在录音、没在下载"
            note(verdict); return
        }
        guard let target = recordings.filter({ $0.onDevice && $0.downloaded && !$0.inProgress && !$0.textOnly })
            .max(by: { $0.duration < $1.duration }) else {
            verdict = "录音豆里没有已下载过的录音可以拿来比对"
            note(verdict); return
        }
        note("目标：录音 \(target.id)，\(Int(target.duration)) 秒")
        toast("wifi", "Wi‑Fi 快传试验 15 秒后开始，电脑会断网约一分钟")
        try? await Task.sleep(for: .seconds(15))

        let dev = await Self.wifiDevice()
        let routerBefore = await Self.router(dev)
        note("Wi‑Fi 接口 \(dev)，现在的网关 \(routerBefore.isEmpty ? "（读不到）" : routerBefore)")

        // 1. 蓝牙：让录音豆开热点
        let ms = Int(Date.now.timeIntervalSince1970 * 1000)
        let ssid = "WiFi-\(ms)", password = "\(ms)"
        wifiReply = nil
        send(Command.wifiConfig(ssid: ssid, password: password))
        note("已发 1A 05，热点名 \(ssid)")
        var waited = 0.0
        while wifiReply == nil, waited < 30, link == .ready { try? await Task.sleep(for: .milliseconds(100)); waited += 0.1 }
        guard let reply = wifiReply else {
            verdict = "录音豆没有回 1A 05（等了 \(Int(waited)) 秒）。Wi‑Fi 和蓝牙都没动。"
            note(verdict); return
        }
        note("1A 05 回包：\(reply.raw.hex)")
        guard reply.raw[4] & 0x0F == 1, reply.raw.count >= 15 else {
            verdict = "录音豆拒绝开热点，状态字节 \(reply.raw[4] & 0x0F)，回包长 \(reply.raw.count)。Wi‑Fi 和蓝牙都没动。"
            note(verdict); return
        }
        let r = reply.raw
        let ip = "\(r[12]).\(r[11]).\(r[10]).\(r[9])"
        let port = Int(r[13]) | (Int(r[14]) << 8)
        note("录音豆给的地址 \(ip):\(port)")

        // 从这里开始动了网络：后面无论如何都要走到「恢复」
        let session = sessionCrypto          // 断开蓝牙后密钥还要用
        dropBLEForWiFi()
        note("已断开蓝牙，等 8 秒让热点起来")
        try? await Task.sleep(for: .seconds(8))

        // 2. 加入热点
        var joined = false
        for attempt in 1...8 {
            let (code, out) = await Self.run("/usr/sbin/networksetup", ["-setairportnetwork", dev, ssid, password], timeout: 25)
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            note("第 \(attempt) 次加入热点：退出码 \(code)\(text.isEmpty ? "" : "，\(text)")")
            if code == 0, text.isEmpty { joined = true; break }
            try? await Task.sleep(for: .seconds(3))
        }
        var result = "没连上热点"
        if joined {
            var addr = ""
            for _ in 0..<20 {
                addr = await Self.run("/usr/sbin/ipconfig", ["getifaddr", dev]).1.trimmingCharacters(in: .whitespacesAndNewlines)
                let gw = await Self.router(dev)
                if !addr.isEmpty, gw != routerBefore || routerBefore.isEmpty { note("已在热点上：本机 \(addr)，网关 \(gw)"); break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            result = await pullOverWiFi(ip: ip, port: port, target: target, session: session, folder: folder, note: note)
        }

        // 3. 恢复 Wi‑Fi 和蓝牙
        let back = await restoreWiFi(dev: dev, routerBefore: routerBefore, note: note)
        let forget = await Self.run("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", dev, ssid])
        note("从记住的网络里去掉试验热点：\(forget.1.trimmingCharacters(in: .whitespacesAndNewlines))")
        resumeBLEAfterWiFi()
        note("已让蓝牙重新去找录音豆")
        verdict = "\(result)｜\(back ? "已连回原来的 Wi‑Fi" : "没能确认连回原来的 Wi‑Fi，请手动检查")"
        note("结束：\(verdict)")
        toast(back ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", "Wi‑Fi 快传试验结束")
    }

    /// 连上热点之后的部分：WebSocket、要文件、收切片、解密、比对、收尾。返回一句结论。
    private func pullOverWiFi(ip: String, port: Int, target: Recording, session: CryptoSession,
                              folder: URL, note: (String) -> Void) async -> String {
        var socket = WiFiSocket()
        var tls = false
        var err = await socket.connect(host: ip, port: port, tls: false, timeout: 10)
        if let e = err {
            note("ws:// 没连上（\(e)），改试 wss://")
            socket.close()
            socket = WiFiSocket()
            tls = true
            err = await socket.connect(host: ip, port: port, tls: true, timeout: 10)
        }
        if let e = err { socket.close(); return "WebSocket 没连上：\(e)" }
        note("WebSocket 已连上（\(tls ? "wss" : "ws")）")

        let request = Command.wifiPullText(target.id)
        socket.sendText(request)
        note("已要文件：\(request)")
        socket.setIdleLimit(10)

        var buffer: [UInt8] = []
        var data = Data()
        var decryptor: FileDecryptor?
        var expected = 0
        var slices = 0, messages = 0, frames = 0, marks = 0
        var firstData: Date?
        var outcome = "没等到「传完」"
        let t0 = Date.now

        var incoming = socket.events.makeAsyncIterator()
        loop: while let event = await incoming.next() {
            switch event {
            case .text(let s):
                note("收到文本：\(s.prefix(80))")
            case .closed(let why):
                outcome = "连接断了：\(why)"
                break loop
            case .binary(let chunk):
                messages += 1
                buffer.append(contentsOf: chunk)
                for p in WiFiFrame.split(&buffer) {
                    frames += 1
                    switch (p.type, p.id) {
                    case (0x1A, 0x07):
                        let code = p.raw.count > 95 ? Int(p.raw[95]) : -1
                        if let head = FileHead(packet: p) {
                            expected = head.audioBytes ?? 0
                            decryptor = session.fileDecryptor(head: head)
                        }
                        note("文件头：长 \(p.raw.count)，状态 \(p.raw[4] & 0x0F)，结果码 \(code)，音频 \(expected) 字节，密钥\(decryptor == nil ? "没解开" : "已解开")")
                    case (0x1A, 0x08), (0x1A, 0x12):
                        if firstData == nil { firstData = .now; note("第一批切片到了，这条消息 \(chunk.count) 字节") }
                        for s in Slice.parse(p) {
                            slices += 1
                            if s.marked { marks += 1 }
                            let plain = decryptor?.decrypt(s.data, sequence: s.sequence) ?? s.data
                            guard s.offset < 512 * 1024 * 1024 else { continue }
                            if s.offset > data.count { data.append(Data(count: s.offset - data.count)) }
                            if s.offset == data.count { data.append(contentsOf: plain) }
                            else { data.replaceSubrange(s.offset..<min(s.offset + plain.count, data.count), with: plain.prefix(data.count - s.offset)) }
                        }
                    case (0x1A, 0x0A):
                        outcome = "传完"
                        socket.sendText(Command.wifiDoneText())
                        break loop
                    case (0x1A, 0x06):
                        outcome = "录音豆说它开始录音了，要求退回蓝牙"
                        break loop
                    default:
                        note("其他帧 \(String(format: "%02X %02X", p.type, p.id))，长 \(p.raw.count)：\(p.raw.prefix(16).hex)")
                    }
                }
            }
        }
        let seconds = Date.now.timeIntervalSince(t0)
        note("\(outcome)。\(messages) 条消息、\(frames) 帧、\(slices) 个切片、\(data.count) / \(expected) 字节，用时 \(String(format: "%.2f", seconds)) 秒，带标记的切片 \(marks) 个")

        // 和本地那份比对
        var compare = "没有数据可比"
        let usable = data.count / OggOpus.frameSize * OggOpus.frameSize
        if usable > 0 {
            let ogg = OggOpus.mux(packets: OggOpus.frames(fromRaw: data.prefix(usable)))
            try? ogg.write(to: folder.appendingPathComponent("\(target.id).ogg"), options: .atomic)
            if let local = try? Data(contentsOf: oggURL(target.id)) {
                compare = local == ogg ? "和蓝牙下载的那份逐字节一致" : "和蓝牙下载的那份不一样（本地 \(local.count) 字节，这次 \(ogg.count) 字节）"
            } else { compare = "本地那份读不到" }
            note("比对：\(compare)")
        }

        // 收尾：告诉录音豆传完了，等它应一声
        try? await Task.sleep(for: .milliseconds(300))
        socket.sendText("FINISH")
        socket.setIdleLimit(2)
        var ack = "没等到应答"
        wait: while let event = await incoming.next() {
            switch event {
            case .text(let s): ack = "应答 \(s.prefix(20))"; break wait
            case .closed(let why): ack = "连接结束（\(why)）"; break wait
            case .binary(let d): note("FINISH 之后还收到 \(d.count) 字节")
            }
        }
        note("FINISH：\(ack)")
        socket.close()

        let speed = seconds > 0 ? Double(data.count) / 160 * 0.02 / seconds : 0
        return "\(outcome)，\(slices) 个切片，\(String(format: "%.1f", seconds)) 秒（约 \(Int(speed)) 倍速），\(compare)，FINISH \(ack)"
    }

    /// 回到原来的 Wi‑Fi。先等系统自己连回去；不行就把 Wi‑Fi 关了再开，让系统重新选网络。
    private func restoreWiFi(dev: String, routerBefore: String, note: (String) -> Void) async -> Bool {
        func isBack() async -> Bool {
            let gw = await Self.router(dev)
            return !gw.isEmpty && (routerBefore.isEmpty || gw == routerBefore)
        }
        for _ in 0..<12 {
            if await isBack() { note("系统已自己连回原来的 Wi‑Fi"); return true }
            try? await Task.sleep(for: .seconds(1))
        }
        note("12 秒没连回去，把 Wi‑Fi 关了再开")
        _ = await Self.run("/usr/sbin/networksetup", ["-setairportpower", dev, "off"])
        try? await Task.sleep(for: .seconds(2))
        _ = await Self.run("/usr/sbin/networksetup", ["-setairportpower", dev, "on"])
        for _ in 0..<40 {
            if await isBack() { note("重开 Wi‑Fi 后连回去了"); return true }
            try? await Task.sleep(for: .seconds(1))
        }
        note("没能确认连回原来的 Wi‑Fi，现在的网关：\(await Self.router(dev))")
        return false
    }

    // MARK: 小工具

    nonisolated static func run(_ path: String, _ args: [String], timeout: Double = 15) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            return (p.terminationStatus, String(decoding: out, as: UTF8.self))
        }.value
    }

    nonisolated static func wifiDevice() async -> String {
        let out = await run("/usr/sbin/networksetup", ["-listallhardwareports"]).1
        let lines = out.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.contains("Hardware Port: Wi-Fi") }), i + 1 < lines.count,
           let name = lines[i + 1].components(separatedBy: ": ").last, !name.isEmpty { return name }
        return "en0"
    }

    nonisolated static func router(_ dev: String) async -> String {
        await run("/usr/sbin/ipconfig", ["getoption", dev, "router"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 一条到录音豆热点的 WebSocket。只走 Wi‑Fi 接口、不走系统代理。
nonisolated final class WiFiSocket: @unchecked Sendable {
    enum Event: Sendable { case text(String), binary(Data), closed(String) }

    let events: AsyncStream<Event>
    private let feed: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "beanpod.wifi-socket")
    private var conn: NWConnection?
    private var lastActivity = Date()
    private var idleLimit: Double = 0
    private var timer: DispatchSourceTimer?
    private var answered = false

    init() { (events, feed) = AsyncStream.makeStream(of: Event.self) }

    /// 连上返回 nil，连不上返回原因。
    func connect(host: String, port: Int, tls: Bool, timeout: Double) async -> String? {
        guard let url = URL(string: "\(tls ? "wss" : "ws")://\(host):\(port)/") else { return "地址不对" }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        let params: NWParameters
        if tls {
            // 录音豆的证书是自签的，官方客户端也不校验
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, done in done(true) }, queue)
            params = NWParameters(tls: options)
        } else {
            params = .tcp
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .wifi
        params.preferNoProxies = true
        let c = NWConnection(to: .url(url), using: params)
        return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            queue.async {
                self.conn = c
                let answer: (String?) -> Void = { r in
                    guard !self.answered else { return }
                    self.answered = true
                    k.resume(returning: r)
                }
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.lastActivity = .now
                        answer(nil)
                        self.receive(c)
                    case .failed(let e):
                        answer(e.localizedDescription)
                        self.feed.yield(.closed(e.localizedDescription))
                    case .cancelled:
                        answer("已取消")
                        self.feed.yield(.closed("已关闭"))
                        self.feed.finish()
                    default: break
                    }
                }
                c.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { answer("\(Int(timeout)) 秒没连上") }
            }
        }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error { self.feed.yield(.closed(error.localizedDescription)); return }
            self.lastActivity = .now
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text: self.feed.yield(.text(String(decoding: data ?? Data(), as: UTF8.self)))
                case .binary: self.feed.yield(.binary(data ?? Data()))
                case .close: self.feed.yield(.closed("录音豆关了连接")); return
                default: break
                }
            }
            self.receive(c)
        }
    }

    func sendText(_ text: String) {
        queue.async {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            self.conn?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    /// 超过这么多秒没有任何数据，就当连接断了。
    func setIdleLimit(_ seconds: Double) {
        queue.async {
            self.idleLimit = seconds
            self.lastActivity = .now
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler {
                if self.idleLimit > 0, Date.now.timeIntervalSince(self.lastActivity) > self.idleLimit {
                    self.lastActivity = .now
                    self.feed.yield(.closed("\(Int(self.idleLimit)) 秒没有数据"))
                }
            }
            t.resume()
            self.timer = t
        }
    }

    func close() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel()
        }
    }
}
