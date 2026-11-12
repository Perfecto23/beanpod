import Foundation

public struct DeviceInfo: Sendable, Equatable {
    public var micBattery = 0          // 百分比
    public var micCharging = false
    public var firmware = ""
    public var serial = ""
    public var totalKB: UInt32 = 0
    public var freeKB: UInt32 = 0
    public var caseCharging = false
    public var caseFirmware = ""
    public var caseBattery = 0
    public var recording = false

    public var usedKB: UInt32 { totalKB >= freeKB ? totalKB - freeKB : 0 }

    /// 设备上报 0…9 的电量档位，显示为 (档位+1)×10%；大于 9 时按百分比原样处理。
    public static func batteryPercent(_ wire: UInt8) -> Int {
        wire <= 9 ? (Int(wire) + 1) * 10 : min(Int(wire), 100)
    }

    /// 字段按顺序排列，固件版本不同时末尾字段可能缺失，所以读到哪算哪。
    public init?(packet: Packet) {
        var r = Reader(packet.payload)
        guard r.remaining >= 32 else { return nil }
        _ = r.byte()                                   // connectStatus
        micBattery = Self.batteryPercent(r.byte())
        micCharging = r.byte() == 1
        firmware = r.ascii(5)
        serial = r.ascii(16).lowercased()
        totalKB = r.u32()
        freeKB = r.u32()
        guard r.remaining >= 7 else { return }
        caseCharging = r.byte() == 1
        caseFirmware = r.ascii(5)
        caseBattery = Self.batteryPercent(r.byte())
        guard r.remaining >= 11 else { return }
        r.skip(6)                                      // 充电盒 MAC
        r.skip(4)                                      // 颜色、自动关机开关/档位、拾音指示灯
        guard r.remaining >= 2 else { return }
        r.skip(1)                                      // 充电盒指示灯
        recording = r.byte() == 1
    }

    public init() {}
}

public struct RemoteFile: Sendable, Equatable, Identifiable, Hashable {
    public let id: UInt32
    /// 列表里报的是时长（毫秒），不是字节数。实测：25.72 秒的录音报 25720。
    public let durationMs: UInt32

    public init(id: UInt32, durationMs: UInt32) {
        self.id = id; self.durationMs = durationMs
    }

    public var duration: TimeInterval { Double(durationMs) / 1000 }

    /// 每 20 ms 一帧、每帧 160 字节，所以音频字节数 = 毫秒 × 8。
    public var audioBytes: Int { Int(durationMs) / 20 * 160 }

    /// fileId 就是开始录音时的 Unix 秒。
    public var startDate: Date? {
        id > 1_500_000_000 ? Date(timeIntervalSince1970: TimeInterval(id)) : nil
    }
}

public struct FileListPage: Sendable, Equatable {
    public static let pageSize = 10
    public let files: [RemoteFile]
    /// 列表末尾带的「当前文件」：正在录音时就是还在增长的那一条，空闲时为 0。
    public let activeFileID: UInt32
    public var hasMore: Bool { files.count >= Self.pageSize }

    /// 0x1B/0x0E：数量 u16，然后每条 12 字节 = fileId u32 | 结束时间 u32（刚录完时实测为 0）| 时长毫秒 u32。
    /// 0x1A/0x0E 是旧格式，每条 8 字节，没有中间那个字段。
    public init?(packet: Packet) {
        let entry: Int
        if packet.matches(0x1B, 0x0E) { entry = 12 }
        else if packet.matches(0x1A, 0x0E) { entry = 8 }
        else { return nil }
        var r = Reader(packet.payload)
        guard r.remaining >= 2 else { return nil }
        let count = r.u16()
        var list: [RemoteFile] = []
        for _ in 0..<count where r.remaining >= entry {
            let id = r.u32()
            if entry == 12 { r.skip(4) }
            list.append(RemoteFile(id: id, durationMs: r.u32()))
        }
        files = list
        activeFileID = r.remaining >= 4 ? r.u32() : 0
    }
}

struct Reader {
    private let bytes: ArraySlice<UInt8>
    private var pos: Int

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes; pos = bytes.startIndex }

    var remaining: Int { bytes.endIndex - pos }

    mutating func byte() -> UInt8 { defer { pos += 1 }; return bytes[pos] }
    mutating func skip(_ n: Int) { pos += n }
    mutating func u16() -> Int { defer { pos += 2 }; return Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) }
    mutating func u32() -> UInt32 {
        defer { pos += 4 }
        return UInt32(bytes[pos]) | (UInt32(bytes[pos + 1]) << 8) | (UInt32(bytes[pos + 2]) << 16) | (UInt32(bytes[pos + 3]) << 24)
    }
    mutating func ascii(_ n: Int) -> String {
        defer { pos += n }
        let chars = bytes[pos..<(pos + n)].filter { $0 >= 0x20 && $0 < 0x7F }
        return String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
