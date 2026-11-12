import Foundation

public enum Command {
    public static func deviceInfo() -> Data { Frame.encode(type: 0x01, id: 0x01) }

    /// 时区字节 = (12 + 相对 UTC 的小时数) × 2，半小时时区也能表示。UTC+8 → 40。
    public static func syncTime(_ date: Date = .now, timeZone: TimeZone = .current) -> Data {
        let halfHours = Int((Double(timeZone.secondsFromGMT(for: date)) / 1800).rounded())
        return Frame.encode(type: 0x01, id: 0xA6,
                            payload: le32(UInt32(date.timeIntervalSince1970)) + [UInt8(truncatingIfNeeded: 24 + halfHours)])
    }

    /// 录音控制 0x18/0x82 的参数：1 开始或继续，2 暂停，0 结束。
    /// 官方客户端只用到 1 和 2；0 是在真机上试出来的：设备回成功，录音有了结束时间，「当前文件」清空。
    public static func startRecording() -> Data { Frame.encode(type: 0x18, id: 0x82, payload: [0x01]) }
    public static func pauseRecording() -> Data { Frame.encode(type: 0x18, id: 0x82, payload: [0x02]) }
    public static func stopRecording() -> Data { Frame.encode(type: 0x18, id: 0x82, payload: [0x00]) }

    /// 带结束时间的录音列表，每页最多 10 条。
    public static func listFiles(page: Int) -> Data { Frame.encode(type: 0x1B, id: 0x0E, payload: le16(page)) }

    public static func deleteFile(_ fileID: UInt32) -> Data { Frame.encode(type: 0x1A, id: 0x10, payload: le32(fileID)) }

    public static func pullFile(_ fileID: UInt32, offset: UInt32 = 0, realtime: Bool = false) -> Data {
        Frame.encode(type: 0x1A, id: 0x07, payload: le32(offset) + le32(fileID) + [realtime ? 1 : 0])
    }

    /// 中止正在进行的离线传输。
    public static func stopTransfer() -> Data { Frame.encode(type: 0x1A, id: 0xA9) }

    public static func keyExchange(publicKey: Data) -> Data { Frame.encode(type: 0x2E, id: 0x01, payload: Array(publicKey)) }

    public static func bind() -> Data { Frame.encode(type: 0x0B, id: 0x87, payload: [0x01]) }
    public static func unbind() -> Data { Frame.encode(type: 0x0B, id: 0x87, payload: [0x00]) }
}

/// 设备回包的 (type, id)。
public enum Reply {
    public static let deviceInfo: (UInt8, UInt8) = (0x01, 0x01)
    public static let battery: (UInt8, UInt8) = (0x01, 0x03)
    public static let charging: (UInt8, UInt8) = (0x01, 0x04)
    public static let syncTime: (UInt8, UInt8) = (0x01, 0xA6)
    public static let recordControl: (UInt8, UInt8) = (0x18, 0x82)
    public static let recordStatus: (UInt8, UInt8) = (0x1A, 0x06)
    public static let fileHead: (UInt8, UInt8) = (0x1A, 0x07)
    public static let fileSlice: (UInt8, UInt8) = (0x1A, 0x08)
    public static let fileSliceAlt: (UInt8, UInt8) = (0x1A, 0x12)
    public static let fileDone: (UInt8, UInt8) = (0x1A, 0x0A)
    public static let fileList: (UInt8, UInt8) = (0x1A, 0x0E)
    public static let fileListWithEnd: (UInt8, UInt8) = (0x1B, 0x0E)
    public static let deleteFile: (UInt8, UInt8) = (0x1A, 0x10)
    public static let bind: (UInt8, UInt8) = (0x0B, 0x87)
    public static let keyExchange: (UInt8, UInt8) = (0x2E, 0x01)
}

public enum BLEID {
    public static let service = "020CF5DA-0000-1000-8000-00805F9B34FB"
    public static let write = "7777"
    public static let notify = "8888"
}
