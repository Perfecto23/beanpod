import AVFoundation
import AppKit
import BeanKit
import Foundation
import Observation

@Observable
final class BeanStore {
    // 连接
    var link: BLEClient.Link = .idle
    var found: [FoundDevice] = []
    var deviceName = "录音豆"
    /// 界面上显示的名字：用户起过名就用用户的。
    var displayDeviceName: String { settings.deviceAlias.isEmpty ? deviceName : settings.deviceAlias }
    /// 这次录音是什么时候开始的，用来显示已录时长。
    var recordingSince: Date?
    var elapsedBase: TimeInterval = 0
    /// 设备上有一条开着的录音（正在录，或暂停着还没结束）。
    var sessionOpen = false
    @ObservationIgnored var pullWhenListed = false

    /// 语音输入时的实时收音：录音豆边录边把音频传过来。
    struct LiveCapture {
        var fileID: UInt32?
        var decryptor: FileDecryptor?
        /// 按序号存每一帧。实时传输是从请求那一刻开始的，开头的几帧要事后单独补。
        var frames: [UInt32: [UInt8]] = [:]
        var lastActivity = Date()
        var packets = 0
        /// 正在补开头：补到这个序号为止。
        var fillUntil: UInt32?
        /// 语音输入用的是临时录音，用完要删；实时转写录的是正式录音，不能删。
        var scratch = true

        var firstSequence: UInt32? { frames.keys.min() }

        /// 从 0 号帧开始、连续不断的那一段。
        var contiguous: Data {
            var out = Data()
            var n: UInt32 = 0
            while let f = frames[n] { out.append(contentsOf: f); n += 1 }
            return out
        }
    }
    @ObservationIgnored var live: LiveCapture?

    // 实时转写
    var liveActive = false
    var liveSegments: [Segment] = []
    /// 还没出字的那一小段已经攒了多少秒声音。
    var livePending: TimeInterval = 0
    var liveNote: String?
    @ObservationIgnored var liveTask: Task<Void, Never>?
    /// 暂停时把还没出字的那一小段立刻转出来，不等下一个停顿。
    @ObservationIgnored var liveFlush = false
    /// 实时音量，每 0.1 秒一格，给录音条上的波形用。
    var liveLevels: [Float] = []
    /// 回听的速度。
    var playRate: Float = { let r = UserDefaults.standard.float(forKey: "playRate"); return r > 0 ? r : 1 }()
    /// 这次录音一共算出过多少个音量值。liveLevels 只留最后一段，靠这个数知道它们各自是第几个。
    var liveLevelTotal = 0
    @ObservationIgnored var meterTask: Task<Void, Never>?
    /// 这次录音里打过的重点标记（秒）。
    var liveMarks: [TimeInterval] = []
    /// 这条录音是什么时候点的开始，用来把豆仓里点的标记对回下载下来的那条录音。
    @ObservationIgnored private var sessionStart: Date?
    /// 在豆仓里点的标记，等这条录音下载下来再写进去。
    @ObservationIgnored private var pendingMarks: [(start: Date, file: UInt32, marks: [TimeInterval])] = []
    var rewriting: Set<UInt32> = []

    /// 用户刚手动改了一个词，问他要不要全部替换并记住。
    var pendingFix: PendingFix?
    struct PendingFix: Equatable { var recording: UInt32; var wrong: String; var right: String }
    /// 语音输入用完要从设备上清掉的临时录音。
    /// 记在本机，下次连上还认得；设备不肯删「当前文件」，要等它不再是当前文件时再删。
    @ObservationIgnored var scratchFiles: Set<UInt32> = Set((UserDefaults.standard.array(forKey: "scratchFiles") as? [NSNumber] ?? []).map(\.uint32Value)) {
        didSet { UserDefaults.standard.set(scratchFiles.map { NSNumber(value: $0) }, forKey: "scratchFiles") }
    }
    @ObservationIgnored var scratchTried: Set<UInt32> = []
    var info: DeviceInfo?
    var encryptionReady = false

    // 录音
    var recordings: [Recording] = []
    var loadingList = false
    var pull: PullProgress?
    var queue: [UInt32] = []
    /// 每条录音当前处在流水线的哪一步；不在表里就是空闲。
    var stages: [UInt32: Stage] = [:]
    var modelDownload: Double?
    var llmDownload: Double?
    var localLLMReady = false
    var asrAvailable = false

    // 知识库问答
    var answer: String?
    var answerSources: [UInt32] = []
    var asking = false

    let settings = AppSettings()

    enum Stage: Equatable { case queued, transcribing(Double), analyzing }

    // 播放
    var playingID: UInt32?
    var isPlaying = false
    var playhead: TimeInterval = 0

    /// 出了问题时弹出来的说明：发生了什么、为什么、下一步能做什么。
    struct Problem: Equatable {
        var title: String
        var detail = ""
        var action: Action?
        enum Action: Equatable {
            case settings, device, download(UInt32), process(UInt32)
            var label: String {
                switch self {
                case .settings: "打开设置"
                case .device: "去设备页"
                case .download: "重新下载"
                case .process: "再试一次"
                }
            }
        }
    }
    var problem: Problem?
    /// 只有一句话的提示。
    var notice: String? {
        get { problem?.title }
        set { problem = newValue.map { Problem(title: $0) } }
    }
    /// 窗口顶部滑出来的一条轻提示，几秒后自己消失。
    var banner: Banner?
    struct Banner: Equatable { var icon: String; var text: String; var id = UUID() }

    /// 照着提示里给的办法去做。
    func resolve(_ action: Problem.Action) {
        switch action {
        case .download(let id): download(id)
        case .process(let id): process(id)
        case .settings, .device: break      // 这两个要换页面，由界面自己处理
        }
    }

    func toast(_ icon: String, _ text: String) {
        let b = Banner(icon: icon, text: text)
        banner = b
        Task { try? await Task.sleep(for: .seconds(3.5)); if banner == b { banner = nil } }
    }

    /// 录音豆是不是在充电盒里（在盒里时它在充电）。
    var inCase: Bool { info?.micCharging == true }
    /// 从菜单「小豆」里临时指定一个样子来看效果；nil 表示跟着真实状态走
    var mascotPreview: (mood: MascotMood, power: MascotPower)?
    /// 小豆该摆出哪种电量状态
    var mascotPower: MascotPower {
        if let mascotPreview { return mascotPreview.power }
        guard link == .ready, let info else { return .unknown }
        return MascotPower(battery: info.micBattery, charging: info.micCharging)
    }
    var log: [String] = []

    @ObservationIgnored private let ble = BLEClient()
    @ObservationIgnored private var crypto = CryptoSession()
    @ObservationIgnored private var job: PullJob?
    @ObservationIgnored private var listPages: [RemoteFile] = []
    @ObservationIgnored private var listPage = 0
    @ObservationIgnored private var activeFileID: UInt32 = 0
    /// 设备眼里的「当前录音」：暂停不算结束，再开始会接着往这条里录。0 表示没有。
    @ObservationIgnored var currentDeviceFile: UInt32 = 0
    @ObservationIgnored private var listToken = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored var worker: Task<Void, Never>?
    @ObservationIgnored var workQueue: [UInt32] = []

    private struct PullJob {
        let id: UInt32
        var expected: Int
        var decryptor: FileDecryptor?
        var encrypted = false
        var data = Data()
        var packets = 0
        var lastActivity = Date()
        /// 续传了几次，以及上次续传时已经收到多少，用来判断续传还有没有进展。
        var resumes = 0
        var sizeAtResume = 0
        /// 带标记的切片序号：录音时在录音豆上按过标记键的位置。
        var marks: Set<UInt32> = []
    }

    let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BeanPod/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadLibrary()
        refreshASRAvailability()
        watchInbox()
        startMCPServer()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.settings.autoProcess == true { self?.upgradeRoughNotes() }
        }
        ble.onLink = { [weak self] in self?.linkChanged($0) }
        ble.onFound = { [weak self] in self?.found = $0; self?.autoConnectIfObvious() }
        ble.onPacket = { [weak self] in self?.handle($0) }
        ble.onLog = { [weak self] in self?.addLog($0) }
        ble.start()
        // 没有记住的设备时，一打开就开始找，不用先点进设备页
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if let self, self.link == .idle { self.scan() }
        }
        addLog("豆仓启动，本地录音 \(recordings.count) 条")
    }

    // MARK: 连接

    func scan() { ble.scan() }

    /// 附近只有一颗录音豆时，不用再点一下，直接连。用户主动断开过就不自动连，免得刚断开又连上。
    @ObservationIgnored var autoConnectAllowed = true
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?

    private func autoConnectIfObvious() {
        guard autoConnectAllowed, link == .scanning, autoConnectTask == nil else { return }
        guard found.filter(\.isBean).count == 1 else { return }
        autoConnectTask = Task { [weak self] in
            // 等一秒多，确认附近真的只有这一颗
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self else { return }
            self.autoConnectTask = nil
            let beans = self.found.filter(\.isBean)
            if self.link == .scanning, beans.count == 1, let only = beans.first { self.connect(only) }
        }
    }
    func stopScan() { ble.stopScan() }
    func connect(_ device: FoundDevice) { deviceName = device.name; ble.connect(device.id) }
    func disconnect(forget: Bool = true) { autoConnectAllowed = false; ble.disconnect(forget: forget) }
    var waitingForKnownDevice: Bool { link == .connecting && ble.hasRememberedDevice }

    private func linkChanged(_ new: BLEClient.Link) {
        let old = link
        link = new
        if new == .ready, old != .ready { toast("checkmark.circle.fill", "录音豆已连接"); NSSound(named: "Glass")?.play() }
        if old == .ready, new != .ready { toast("wifi.slash", "录音豆已断开") }
        poller?.cancel()
        guard new == .ready else {
            if let job { failPull(job.id, "连接断开，下载中断") }
            queue.removeAll()
            info = nil; encryptionReady = false; loadingList = false
            for i in recordings.indices { recordings[i].onDevice = false }
            recordings.removeAll { !$0.downloaded }
            return
        }
        if let name = ble.connectedName, !name.isEmpty { deviceName = name }
        crypto = CryptoSession()
        scratchTried = []
        currentDeviceFile = 0
        sessionOpen = false; elapsedBase = 0; recordingSince = nil
        Task {
            // 设备处理命令需要一点间隔，挨个发
            ble.send(Command.deviceInfo())
            try? await Task.sleep(for: .milliseconds(400))
            ble.send(Command.syncTime())
            try? await Task.sleep(for: .milliseconds(300))
            ble.send(Command.keyExchange(publicKey: crypto.publicKey))
            try? await Task.sleep(for: .milliseconds(400))
            refreshFiles()
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled, self.link == .ready, self.job == nil else { continue }
                self.ble.send(Command.deviceInfo())
            }
        }
    }

    // MARK: 设备操作

    var isRecording: Bool { macRec == .recording || (link == .ready && info?.recording == true) }

    /// 用这台 Mac 的麦克风录音时的状态。
    var macRec: MacRec = .off
    @ObservationIgnored var macRecorder: AVAudioRecorder?
    @ObservationIgnored var macMeter: Task<Void, Never>?
    /// 现在这条是不是用 Mac 的麦克风在录。
    var recordingOnMac: Bool { macRec != .off }

    enum RecState { case idle, recording, paused }

    /// 录音豆现在的状态：没在录、正在录、录到一半暂停着。
    var recState: RecState {
        if macRec != .off { return macRec == .recording ? .recording : .paused }
        guard link == .ready else { return .idle }
        if info?.recording == true { return .recording }
        return sessionOpen ? .paused : .idle
    }

    /// 已经录了多久（暂停的时间不算）。
    func elapsed(at now: Date = .now) -> TimeInterval {
        elapsedBase + (recordingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func startRecording() {
        // 录音豆没连上：直接用这台 Mac 的麦克风录
        if link != .ready, recState == .idle { startMacRecording(); return }
        guard link == .ready, recState == .idle else { return }
        ble.send(Command.startRecording())
        info?.recording = true          // 先把界面切过去，不等设备回话
        sessionOpen = true
        elapsedBase = 0
        recordingSince = .now
        liveMarks = []
        sessionStart = .now
        beginLiveTranscript(reset: true)
        confirmSoon()
    }

    func pauseRecording() {
        if macRec != .off { pauseMacRecording(); return }
        guard recState == .recording else { return }
        ble.send(Command.pauseRecording())
        elapsedBase = elapsed()
        recordingSince = nil
        info?.recording = false
        liveFlush = true
        confirmSoon()
    }

    func resumeRecording() {
        if macRec != .off { resumeMacRecording(); return }
        guard recState == .paused else { return }
        ble.send(Command.startRecording())
        info?.recording = true
        recordingSince = .now
        // 接着录：实时声音也接着要
        if live == nil { beginLiveTranscript(reset: false) }
        else if currentDeviceFile != 0 { ble.send(Command.pullFile(currentDeviceFile, offset: 0, realtime: true)) }
        confirmSoon()
    }

    /// 结束这条录音。结束后设备才把它当成一条完整的录音，才能下载；下次再录是新的一条。
    func finishRecording() {
        if macRec != .off { finishMacRecording(); return }
        guard link == .ready, recState != .idle else { return }
        ble.send(Command.stopRecording())
        if !liveMarks.isEmpty, let since = sessionStart {
            pendingMarks.append((since, currentDeviceFile, liveMarks))
        }
        elapsedBase = 0
        recordingSince = nil
        info?.recording = false
        sessionOpen = false
        Task {
            await endLiveTranscript()
            try? await Task.sleep(for: .seconds(1))
            ble.send(Command.deviceInfo())
            try? await Task.sleep(for: .seconds(1))
            pullWhenListed = settings.autoDownload
            refreshFiles()
        }
    }

    /// 在现在这个时刻打一个重点标记。
    func markNow() {
        guard recState == .recording else { return }
        addMark(elapsed())
        toast("flag.fill", "标记了 \(clock(elapsed()))")
    }

    /// 相隔不到两秒的标记算同一个：按一下标记键，设备会连着标好几个切片。
    private func addMark(_ t: TimeInterval) {
        guard !liveMarks.contains(where: { abs($0 - t) < 2 }) else { return }
        liveMarks.append(t)
    }

    /// 把一串标记时刻合并成干净的列表：排好序，挨得太近的只留一个。
    nonisolated static func mergeMarks(_ times: [TimeInterval]) -> [TimeInterval] {
        var out: [TimeInterval] = []
        for t in times.sorted() where out.last.map({ t - $0 >= 2 }) ?? true { out.append(t) }
        return out
    }

    /// 一个键的开关：没在录就开始，在录或暂停着就结束。
    func toggleRecording() {
        if recState == .idle { startRecording() } else { finishRecording() }
    }

    private func confirmSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            ble.send(Command.deviceInfo())
        }
    }

    func refreshFiles() {
        guard link == .ready, job == nil else { return }
        listToken += 1
        let token = listToken
        listPages = []; listPage = 0; activeFileID = 0; loadingList = true
        ble.send(Command.listFiles(page: 0))
        Task {
            try? await Task.sleep(for: .seconds(8))
            if token == listToken, loadingList { finishList() }
        }
    }

    func send(_ frame: Data) { ble.send(frame) }

    /// 录音豆放回充电盒、或从盒里取出来。放回去的时候顺手把还没下载的录音同步下来。
    private func caseChanged(from old: Bool?, to new: Bool) {
        guard let old, old != new else { return }
        if new {
            let pending = recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.count
            toast("battery.100percent.bolt", pending > 0 && settings.autoDownload ? "已放回充电盒，开始同步 \(pending) 条录音" : "已放回充电盒，正在充电")
            if settings.autoDownload { pullWhenListed = true; refreshFiles() }
        } else {
            toast("mic.fill", "录音豆已取出，可以开始录音")
        }
    }

    func deleteFromDevice(_ id: UInt32) {
        guard link == .ready else { return }
        ble.send(Command.deleteFile(id))
    }

    // MARK: 收包

    private func handle(_ p: Packet) {
        let isSlice = p.matches(0x1A, 0x08) || p.matches(0x1A, 0x12)
        if !isSlice { addLog("← \(p.raw.prefix(96).hex)\(p.raw.count > 96 ? " …(\(p.raw.count) 字节)" : "")") }

        switch (p.type, p.id) {
        case (0x01, 0x01):
            if let parsed = DeviceInfo(packet: p) {
                let wasInCase = info?.micCharging
                info = parsed
                caseChanged(from: wasInCase, to: parsed.micCharging)
                if parsed.recording, recordingSince == nil { recordingSince = .now; sessionOpen = true }
                if !parsed.recording, let since = recordingSince { elapsedBase += Date.now.timeIntervalSince(since); recordingSince = nil }
            }
        case (0x01, 0x03):
            let b = Array(p.payload)
            if b.count >= 2 {
                info?.micBattery = DeviceInfo.batteryPercent(b[0])
                info?.caseBattery = DeviceInfo.batteryPercent(b[1])
            }
        case (0x01, 0x04):
            let b = Array(p.payload)
            if b.count >= 2 {
                let wasInCase = info?.micCharging
                info?.micCharging = b[0] == 1; info?.caseCharging = b[1] == 1
                caseChanged(from: wasInCase, to: b[0] == 1)
            }
        case (0x18, 0x82):
            // 设备会把指令原样回显：01 是开始了，02 是暂停了。以它为准更新状态，
            // 否则语音输入松手后界面还以为在录，下一次按键会被当成「设备正忙」
            if p.isSuccess, let op = p.payload.first {
                switch op {
                case 1:
                    info?.recording = true; sessionOpen = true
                    if recordingSince == nil { recordingSince = .now }
                case 2:
                    if let since = recordingSince { elapsedBase += Date.now.timeIntervalSince(since) }
                    info?.recording = false; recordingSince = nil
                case 0:
                    info?.recording = false; recordingSince = nil; elapsedBase = 0
                    sessionOpen = false; currentDeviceFile = 0
                default: break
                }
            } else if live == nil {
                problem = Problem(title: "录音豆没有开始录音", detail: "它可能正在传文件，或者电量太低。等几秒再点一次；还不行就把它放回充电盒再拿出来。")
            }
        case (0x2E, 0x01):
            encryptionReady = crypto.completeHandshake(p)
            addLog(encryptionReady ? "密钥协商成功" : "密钥协商失败")
        case (0x1B, 0x0E), (0x1A, 0x0E):
            guard loadingList, let page = FileListPage(packet: p) else { return }
            listPages += page.files
            if page.activeFileID != 0 { activeFileID = page.activeFileID }
            if page.hasMore, listPage < 200 {
                listPage += 1
                listToken += 1
                let token = listToken
                ble.send(Command.listFiles(page: listPage))
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    if token == listToken, loadingList { finishList() }
                }
            } else {
                finishList()
            }
        case (0x1A, 0x10):
            addLog(p.isSuccess ? "设备已删除一条录音" : "设备拒绝删除")
            if p.isSuccess { refreshFiles() } else if scratchFiles.isEmpty { problem = Problem(title: "录音豆没有删掉这条录音", detail: "它可能还在录这一条，或者正在传文件。结束录音、等传完再删。") }
        case (0x1A, 0x06):
            if info?.recording == false { info?.recording = true }
            // 语音输入：设备报出新录音的 id，立刻要求它边录边传
            let b = Array(p.payload)
            if live != nil, live?.fileID == nil, b.count >= 4 {
                let fid = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                if fid != 0 {
                    currentDeviceFile = fid
                    live?.fileID = fid
                    if live?.scratch == true { scratchFiles.insert(fid) }
                    ble.send(Command.pullFile(fid, offset: 0, realtime: true))
                }
            }
        case (0x1A, 0x07) where live != nil && job == nil:
            if let head = FileHead(packet: p) { live?.decryptor = crypto.fileDecryptor(head: head) }
            live?.lastActivity = .now
        case (0x1A, 0x08) where live != nil && job == nil, (0x1A, 0x12) where live != nil && job == nil:
            guard var l = live else { return }
            l.packets += 1
            if l.packets <= 2 { addLog("← 实时切片 #\(l.packets) 长 \(p.raw.count)：\(p.raw.prefix(24).hex)") }
            for s in Slice.parse(p) where l.frames[s.sequence] == nil && s.sequence < 400_000 {
                l.frames[s.sequence] = l.decryptor?.decrypt(s.data, sequence: s.sequence) ?? s.data
                if s.marked, !l.scratch { addMark(Double(s.sequence) * 0.02) }
            }
            l.lastActivity = .now
            // 开头补齐了就叫停，不用把整段再传一遍
            if let until = l.fillUntil, (0..<until).allSatisfy({ l.frames[$0] != nil }) {
                l.fillUntil = nil
                ble.send(Command.stopTransfer())
            }
            live = l
        case (0x1A, 0x07):
            guard var j = job else { return }
            j.lastActivity = .now
            if let head = FileHead(packet: p) {
                if let bytes = head.audioBytes { j.expected = bytes }
                j.encrypted = true
                j.decryptor = crypto.fileDecryptor(head: head)
            }
            job = j
            if j.encrypted, j.decryptor == nil { failPull(j.id, "这条录音是加密的，但密钥没协商成功。请断开重连后再试。") }
        case (0x1A, 0x08), (0x1A, 0x12):
            guard var j = job else { return }
            j.packets += 1
            if j.packets <= 3 || j.packets % 100 == 0 {
                addLog("← 切片包 #\(j.packets) 长 \(p.raw.count)：\(p.raw.prefix(40).hex)")
            }
            for s in Slice.parse(p) {
                if s.marked { j.marks.insert(s.sequence) }
                let plain = j.decryptor?.decrypt(s.data, sequence: s.sequence) ?? s.data
                // 按序号落位：丢包处留空，重传的覆盖原位置
                guard s.offset < 512 * 1024 * 1024 else { continue }
                if s.offset > j.data.count { j.data.append(Data(count: s.offset - j.data.count)) }
                if s.offset == j.data.count { j.data.append(contentsOf: plain) }
                else { j.data.replaceSubrange(s.offset..<min(s.offset + plain.count, j.data.count), with: plain.prefix(j.data.count - s.offset)) }
            }
            j.lastActivity = .now
            job = j
            pull = PullProgress(id: j.id, received: j.data.count, expected: j.expected)
            if j.expected > 0, j.data.count >= j.expected { finishPull() }
        case (0x1A, 0x0A):
            guard var j = job else { return }
            // 中途暂停过的录音，设备传到一段的结尾就会报「传完了」。没拿全就从断点接着要，
            // 直到拿全，或者续传也不再有新数据为止。
            if j.expected > 0, Double(j.data.count) < Double(j.expected) * 0.98, j.data.count > j.sizeAtResume, j.resumes < 200 {
                j.resumes += 1
                j.sizeAtResume = j.data.count
                j.lastActivity = .now
                job = j
                addLog("录音还没传全（\(j.data.count) / \(j.expected)），第 \(j.resumes) 次续传")
                ble.send(Command.pullFile(j.id, offset: UInt32(j.data.count / 160 * 166)))
            } else {
                finishPull()
            }
        default:
            break
        }
    }

    private func finishList() {
        loadingList = false
        listToken += 1
        let remote = Dictionary(listPages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        currentDeviceFile = activeFileID
        // 一连上就发现设备上有条没结束的录音（比如在设备上按键录的）：界面上也要显示成暂停中
        if activeFileID != 0, !scratchFiles.contains(activeFileID) { sessionOpen = true }
        else if info?.recording != true { sessionOpen = false }
        let growing: UInt32? = info?.recording == true && activeFileID != 0 ? activeFileID : nil
        var merged: [Recording] = []
        for var r in recordings.filter(\.downloaded) {
            r.onDevice = remote[r.id] != nil
            r.inProgress = false
            // 本地这份比设备上的短（下载时还在录）：标成没下载，等录完重新下。
            // 旧文件先留着不删，新的下载成功后会自然覆盖它。
            if let f = remote[r.id], f.duration > r.duration + 1 {
                addLog("本地副本比设备上的短（\(Int(r.duration)) 秒 / \(Int(f.duration)) 秒），标记为待重新下载：\(r.id)")
                if playingID == r.id { stop() }
                var fresh = Recording(id: r.id, size: UInt32(f.audioBytes), date: f.startDate, duration: f.duration,
                                      onDevice: true, inProgress: f.id == growing)
                fresh.title = r.title; fresh.starred = r.starred
                merged.append(fresh)
                continue
            }
            merged.append(r)
        }
        let known = Set(merged.map(\.id))
        for f in remote.values where !known.contains(f.id) && !scratchFiles.contains(f.id) {
            merged.append(Recording(id: f.id, size: UInt32(f.audioBytes), date: f.startDate, duration: f.duration,
                                    onDevice: true, inProgress: f.id == growing))
        }
        saveLibrary()
        recordings = merged.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
        // 正在录的那条，开始时间就是它的 id
        if pullWhenListed { pullWhenListed = false; downloadAll() }
        sweepScratch(remote: Set(remote.keys))
    }

    /// 清掉语音输入留在设备上的临时录音。每条每次连接只试一回，避免删不掉时反复重试。
    private func sweepScratch(remote: Set<UInt32>) {
        scratchFiles.formIntersection(remote)          // 设备上已经没有的，不用再记
        guard live == nil, job == nil else { return }
        guard let next = scratchFiles.first(where: { !scratchTried.contains($0) && $0 != activeFileID }) else { return }
        scratchTried.insert(next)
        addLog("清理语音输入的临时录音 \(next)")
        ble.send(Command.deleteFile(next))
    }

    // MARK: 下载

    func download(_ id: UInt32) {
        guard link == .ready, !queue.contains(id), job?.id != id,
              recordings.contains(where: { $0.id == id && $0.onDevice && !$0.downloaded && !$0.inProgress }) else { return }
        queue.append(id)
        startNextPull()
    }

    func downloadAll() { recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.forEach { download($0.id) } }

    func cancelDownloads() {
        queue.removeAll()
        if let job { failPull(job.id, nil) }
    }

    private func startNextPull() {
        guard job == nil, link == .ready, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let rec = recordings.first(where: { $0.id == id }) else { return startNextPull() }
        job = PullJob(id: id, expected: Int(rec.size))
        pull = PullProgress(id: id, received: 0, expected: Int(rec.size))
        ble.send(Command.pullFile(id))
        Task { [weak self] in
            // 20 秒没有任何数据就判定失败，不限制总时长
            while let self, let j = self.job, j.id == id {
                if !j.data.isEmpty, Date.now.timeIntervalSince(j.lastActivity) > 3 {
                    self.addLog("3 秒没有新数据，按传完处理")
                    self.finishPull()
                    return
                }
                if Date.now.timeIntervalSince(j.lastActivity) > 20 {
                    self.failPull(id, j.data.isEmpty ? "设备没有回传数据。把录音豆靠近电脑再试一次。" : "传输中途停了，请重试。")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finishPull() {
        guard let j = job else { return }
        job = nil; pull = nil
        defer { startNextPull() }
        let usable = j.data.count / OggOpus.frameSize * OggOpus.frameSize
        guard usable > 0 else { problem = Problem(title: "这条录音是空的", detail: "录音豆里这一条没有声音数据，可能刚开始就结束了。"); return }
        addLog("下载结束：\(j.packets) 个切片包，\(j.data.count) / \(j.expected) 字节")
        if j.expected > 0, Double(j.data.count) < Double(j.expected) * 0.95 {
            problem = Problem(title: "这条录音没传完整", detail: "蓝牙中途断了一下，只收到 \(j.expected > 0 ? j.data.count * 100 / j.expected : 0)%。录音还在录音豆里，没有丢。", action: .download(j.id))
            return
        }
        let packets = OggOpus.frames(fromRaw: j.data.prefix(usable))
        do {
            try OggOpus.mux(packets: packets).write(to: oggURL(j.id), options: .atomic)
            let seconds = try OpusDecoder.writeWAV(packets: packets, to: wavURL(j.id))
            if let i = recordings.firstIndex(where: { $0.id == j.id }) {
                recordings[i].downloaded = true
                recordings[i].duration = seconds
                // 重点标记：设备上按的（切片里带着）加上在豆仓里点的
                var marks = j.marks.map { Double($0) * 0.02 }
                if let k = pendingMarks.firstIndex(where: { m in
                    m.file == j.id || recordings[i].date.map { abs($0.timeIntervalSince(m.start)) < 15 } ?? false
                }) {
                    marks += pendingMarks.remove(at: k).marks
                }
                recordings[i].marks = Self.mergeMarks(marks.filter { $0 <= seconds + 1 })
                if !recordings[i].marks.isEmpty { addLog("这条录音有 \(recordings[i].marks.count) 个重点标记") }
            }
            saveLibrary()
            if settings.autoProcess { process(j.id) }
        } catch {
            addLog("保存失败，清掉半成品文件 \(j.id)：\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: oggURL(j.id))
            try? FileManager.default.removeItem(at: wavURL(j.id))
            problem = Problem(title: "录音没能存到这台 Mac", detail: "\(error.localizedDescription)\n看看磁盘是不是满了。录音还在录音豆里，腾出空间后可以重新下载。", action: .download(j.id))
        }
    }

    private func failPull(_ id: UInt32, _ message: String?) {
        guard job?.id == id else { return }
        job = nil; pull = nil
        if let message { problem = Problem(title: "这条录音没下载下来", detail: message, action: .device) }
        startNextPull()
    }

    // MARK: 本地库

    func oggURL(_ id: UInt32) -> URL { folder.appendingPathComponent("\(id).ogg") }
    func wavURL(_ id: UInt32) -> URL { folder.appendingPathComponent("\(id).wav") }
    private var libraryURL: URL { folder.appendingPathComponent("library.json") }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              var list = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        let missing = list.filter { !$0.textOnly && !FileManager.default.fileExists(atPath: wavURL($0.id).path) }
        if !missing.isEmpty { addLog("记录里有 \(missing.count) 条录音的音频文件不在了：\(missing.map(\.id))") }
        list.removeAll { !$0.textOnly && !FileManager.default.fileExists(atPath: wavURL($0.id).path) }
        for i in list.indices { list[i].onDevice = false; list[i].downloaded = true; list[i].inProgress = false }
        recordings = list.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }

    func saveLibrary() {
        let data = try? JSONEncoder().encode(recordings.filter(\.downloaded))
        try? data?.write(to: libraryURL, options: .atomic)
    }

    func rename(_ id: UInt32, to title: String) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].title = title.trimmingCharacters(in: .whitespaces)
        recordings[i].titleEdited = !(recordings[i].title ?? "").isEmpty
        saveLibrary()
    }

    func removeLocal(_ id: UInt32) {
        addLog("用户从本机删除录音 \(id)")
        if playingID == id { stop() }
        try? FileManager.default.removeItem(at: oggURL(id))
        try? FileManager.default.removeItem(at: wavURL(id))
        if let i = recordings.firstIndex(where: { $0.id == id }) {
            if recordings[i].onDevice { recordings[i] = Recording(id: id, size: recordings[i].size, date: recordings[i].date, duration: recordings[i].duration, onDevice: true) }
            else { recordings.remove(at: i) }
        }
        saveLibrary()
    }

    func reveal(_ id: UInt32) { NSWorkspace.shared.activateFileViewerSelecting([oggURL(id)]) }

    // MARK: 播放

    func togglePlay(_ id: UInt32) {
        if playingID == id, let player {
            if player.isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true; tick() }
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: wavURL(id)) else { problem = Problem(title: "这条录音打不开", detail: "这台 Mac 上的音频文件可能坏了。如果录音豆里还有这一条，删掉本地副本再重新下载就好。"); return }
        p.enableRate = true; p.rate = playRate
        player = p; playingID = id; playhead = 0
        p.play(); isPlaying = true
        tick()
    }

    func seek(_ time: TimeInterval) { player?.currentTime = time; playhead = time }

    /// 往前或往后跳几秒。
    func skip(_ id: UInt32, by delta: TimeInterval) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let from = playingID == id ? playhead : 0
        play(id, at: max(0, min(r.duration - 0.2, from + delta)))
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    func setRate(_ rate: Float) {
        playRate = rate
        player?.rate = rate
        UserDefaults.standard.set(rate, forKey: "playRate")
    }

    /// 跳到上一个或下一个重点标记。
    func jumpToMark(_ id: UInt32, forward: Bool) {
        guard let r = recordings.first(where: { $0.id == id }), !r.marks.isEmpty else { return }
        let now = playingID == id ? playhead : 0
        // 往回跳时留三秒余量：刚跳到一个标记，再按一次应该去更前面那个
        let target = forward ? r.marks.first { $0 - 2 > now + 0.5 } : r.marks.last { $0 - 2 < now - 3 }
        if let target { play(id, at: max(0, target - 2)) }
    }

    /// 回听时补一个重点标记，或者把已有的去掉。
    func addMark(_ id: UInt32, at time: TimeInterval) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].marks = Self.mergeMarks(recordings[i].marks + [time])
        saveLibrary()
    }

    func removeMark(_ id: UInt32, _ time: TimeInterval) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].marks.removeAll { $0 == time }
        saveLibrary()
    }

    /// 把录音另存成别的软件能打开的音频文件。
    func exportAudio(_ id: UInt32, m4a: Bool) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        let day = r.date.map { $0.formatted(.iso8601.year().month().day()) + " " } ?? ""
        let safe = String((day + r.displayTitle).map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 })
        panel.nameFieldStringValue = safe + (m4a ? ".m4a" : ".wav")
        panel.allowedContentTypes = [m4a ? .mpeg4Audio : .wav]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = wavURL(id)
        Task {
            do {
                try? FileManager.default.removeItem(at: target)
                if m4a {
                    guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try await session.export(to: target, as: .m4a)
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                }
                toast("checkmark.circle.fill", "已导出到「\(target.lastPathComponent)」")
                addLog("导出音频：\(target.path)")
            } catch {
                problem = Problem(title: "音频没导出成功", detail: error.localizedDescription + "\n换一个文件夹再试试。")
            }
        }
    }

    /// 从文字稿的某一句开始播。
    func play(_ id: UInt32, at time: TimeInterval) {
        if playingID != id { togglePlay(id) }
        seek(time)
        if !isPlaying { player?.play(); isPlaying = true; tick() }
    }

    func stop() {
        ticker?.cancel(); player?.stop(); player = nil
        playingID = nil; isPlaying = false; playhead = 0
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, let self, let player = self.player {
                self.playhead = player.currentTime
                if !player.isPlaying {
                    if self.isPlaying { self.isPlaying = false; self.playhead = 0 }  // 自然播完
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @ObservationIgnored private let logFile: FileHandle? = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/BeanPod.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    func addLog(_ line: String) {
        let stamped = "\(Date.now.formatted(date: .omitted, time: .standard))  \(line)"
        logFile?.write(Data((stamped + "\n").utf8))
        log.append(stamped)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
