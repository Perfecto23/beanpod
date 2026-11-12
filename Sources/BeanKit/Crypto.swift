import CommonCrypto
import CryptoKit
import Foundation

/// 录音在设备上是加密的。流程：
/// 1. App 生成 P‑256 密钥对，把公钥（65 字节）发给设备；
/// 2. 设备回它的公钥和它算出的共享密钥，两边一致才继续；
/// 3. 会话密钥 = HKDF‑SHA256(共享密钥, salt={1,2,3}, info={1,2,3}, 32 字节)；
/// 4. 每个文件头里带一把用会话密钥加密的文件密钥，解开后以 "soundcored3200" 开头；
/// 5. 每 160 字节一块，用 AES‑CTR 解密，计数器 = nonce 前 12 字节 ‖ 大端(序号×10)。
public final class CryptoSession: @unchecked Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private var sessionKey: [UInt8]?

    public init(privateKey: P256.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

    public var publicKey: Data { privateKey.publicKey.x963Representation }
    public var isReady: Bool { sessionKey != nil }

    /// 处理 0x2E/0x01 回包。
    @discardableResult
    public func completeHandshake(_ packet: Packet) -> Bool {
        let p = Array(packet.payload)
        guard p.count >= 97 else { return false }
        return completeHandshake(devicePublicKey: Data(p[0..<65]), deviceShared: Data(p[65..<97]))
    }

    @discardableResult
    public func completeHandshake(devicePublicKey: Data, deviceShared: Data) -> Bool {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: devicePublicKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return false }
        let shared = secret.withUnsafeBytes { Data($0) }
        guard shared == deviceShared else { return false }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared),
                                         salt: Data([1, 2, 3]), info: Data([1, 2, 3]), outputByteCount: 32)
        sessionKey = key.withUnsafeBytes { Array($0) }
        return true
    }

    /// 从文件头回包（0x1A/0x07）里解出这份录音的解密器；没加密或握手未完成时返回 nil。
    public func fileDecryptor(head: FileHead) -> FileDecryptor? {
        guard let sessionKey,
              let plain = aesCTR(key: sessionKey, iv: head.sessionNonce, data: head.encryptedKey),
              plain.count >= 46, plain.prefix(14).elementsEqual(Array("soundcored3200".utf8)) else { return nil }
        return FileDecryptor(key: Array(plain[14..<46]), nonce: head.nonce)
    }
}

public struct FileHead: Sendable, Equatable {
    public let fileID: UInt32
    /// 传输总字节数，按 166 字节一个单元计（其中 160 是音频）。未知时设备报 0xFFFFFFFF。
    public let size: UInt32
    public let nonce: [UInt8]
    public let encryptedKey: [UInt8]
    public let sessionNonce: [UInt8]

    public var audioBytes: Int? {
        size == 0 || size == .max ? nil : Int(size) / 166 * 160
    }

    public init?(packet: Packet) {
        let raw = packet.raw
        guard raw.count >= 97 else { return nil }
        fileID = raw.u32(9)
        size = raw.u32(13)
        nonce = Array(raw[17..<33])
        encryptedKey = Array(raw[33..<79])
        sessionNonce = Array(raw[79..<95])
    }
}

public struct FileDecryptor: Sendable {
    let key: [UInt8]
    let nonce: [UInt8]

    public func decrypt(_ chunk: [UInt8], sequence: UInt32) -> [UInt8] {
        let counter = sequence &* 10
        let iv = Array(nonce.prefix(12)) + [UInt8(counter >> 24), UInt8((counter >> 16) & 0xFF),
                                            UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)]
        return aesCTR(key: key, iv: iv, data: chunk) ?? chunk
    }
}

func aesCTR(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
    guard iv.count == 16, [16, 24, 32].contains(key.count) else { return nil }
    var cryptor: CCCryptorRef?
    guard CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                  CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                  CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess,
          let cryptor else { return nil }
    defer { CCCryptorRelease(cryptor) }
    var out = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    guard CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved) == kCCSuccess, moved == data.count else { return nil }
    return out
}

/// 切片回包（0x1A/0x08 或 0x1A/0x12）里是若干个 166 字节的单元：
/// 序号 u32 | 标志 u8 | 160 字节数据 | 1 字节。实测每包一个单元，最后一个单元的尾字节可能被校验和占掉。
public struct Slice: Sendable, Equatable {
    public let sequence: UInt32
    /// 标志最低位为 1 表示录音时在这里按过标记键。
    public let marked: Bool
    public let data: [UInt8]

    public static let dataSize = 160

    /// 这一片在整段音频里的字节位置。按位置写入，丢包或重传都不会错位。
    public var offset: Int { Int(sequence) * Self.dataSize }

    public static func parse(_ packet: Packet) -> [Slice] {
        let body = packet.payload
        var out: [Slice] = []
        var i = body.startIndex
        while body.endIndex - i >= 5 + dataSize {
            let start = i + 5
            out.append(Slice(sequence: body[i...].u32(0), marked: body[i + 4] & 1 != 0,
                             data: Array(body[start..<(start + dataSize)])))
            i = start + dataSize + 1
        }
        return out
    }
}
