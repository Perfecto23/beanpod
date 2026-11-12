import Foundation

/// 手机 → 设备：08 EE 00 00 00 | type | id | 总长 u16 LE | 载荷 | 校验和
/// 设备 → 手机：09 FF 00 00 | 状态 | type | id | 总长 u16 LE | 载荷 | 校验和
/// 校验和 = 前面所有字节相加取低 8 位。
public enum Frame {
    public static let minLength = 10

    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    public static func encode(type: UInt8, id: UInt8, payload: [UInt8] = []) -> Data {
        let total = 9 + payload.count + 1
        var out: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00, type, id,
                            UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF)]
        out += payload
        out.append(checksum(out[...]))
        return Data(out)
    }
}

public struct Packet: Sendable, Equatable {
    public let raw: [UInt8]
    public var status: UInt8 { raw[4] }
    public var type: UInt8 { raw[5] }
    public var id: UInt8 { raw[6] }
    public var payload: ArraySlice<UInt8> { raw[9..<(raw.count - 1)] }
    public var isSuccess: Bool { status & 0x0F == 1 }

    public func matches(_ type: UInt8, _ id: UInt8) -> Bool { self.type == type && self.id == id }
}

/// 蓝牙通知是按 MTU 切碎的字节流，这里负责拼回完整的帧。
public struct Reassembler: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    public mutating func feed(_ data: Data) -> [Packet] {
        buffer.append(contentsOf: data)
        var packets: [Packet] = []
        var i = 0
        while true {
            // 找帧头 09 FF
            var start = -1
            var j = i
            while j + 1 < buffer.count {
                if buffer[j] == 0x09 && buffer[j + 1] == 0xFF { start = j; break }
                j += 1
            }
            if start < 0 {
                // 没有帧头：只保留最后一个字节（可能是下一包帧头的前半）
                i = max(i, buffer.count - 1)
                break
            }
            i = start
            guard buffer.count - i >= 9 else { break }
            let total = Int(buffer[i + 7]) | (Int(buffer[i + 8]) << 8)
            if total < Frame.minLength { i += 1; continue }
            guard buffer.count - i >= total else { break }
            let slice = buffer[i..<(i + total)]
            if Frame.checksum(slice.dropLast()) == slice.last! {
                packets.append(Packet(raw: Array(slice)))
                i += total
            } else {
                i += 1 // 校验失败，往后挪一位重新对齐
            }
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
        return packets
    }
}

// MARK: - 小端读写

extension Collection where Element == UInt8, Index == Int {
    func u16(_ offset: Int) -> Int {
        let b = startIndex + offset
        return Int(self[b]) | (Int(self[b + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        let b = startIndex + offset
        return UInt32(self[b]) | (UInt32(self[b + 1]) << 8) | (UInt32(self[b + 2]) << 16) | (UInt32(self[b + 3]) << 24)
    }
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

public extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
