import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import BeanKit

/// 造一个设备回包：09 FF 00 00 | 状态 | type | id | 长度 | 载荷 | 校验和
func reply(_ type: UInt8, _ id: UInt8, status: UInt8 = 1, _ payload: [UInt8] = []) -> [UInt8] {
    let total = 10 + payload.count
    var b: [UInt8] = [0x09, 0xFF, 0, 0, status, type, id, UInt8(total & 0xFF), UInt8(total >> 8)] + payload
    b.append(Frame.checksum(b[...]))
    return b
}

@Test func encodesCommandsWithLengthAndChecksum() {
    #expect(Array(Command.deviceInfo()) == [0x08, 0xEE, 0, 0, 0, 0x01, 0x01, 0x0A, 0x00, 0x02])
    let rec = Array(Command.startRecording())
    #expect(rec == [0x08, 0xEE, 0, 0, 0, 0x18, 0x82, 0x0B, 0x00, 0x01, 0x9C])
    let pull = Array(Command.pullFile(0x6601_0203, offset: 320))
    #expect(pull.count == 19)
    #expect(Array(pull[9..<18]) == [0x40, 0x01, 0, 0, 0x03, 0x02, 0x01, 0x66, 0])
}

@Test func syncTimeCarriesTimestampAndZone() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let f = Array(Command.syncTime(date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!))
    #expect(f[9..<13].u32(0) == 1_800_000_000)
    #expect(f[13] == 40)   // (12 + 8) × 2
    let india = Array(Command.syncTime(date, timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!))
    #expect(india[13] == 35)
    let la = Array(Command.syncTime(date, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!))
    #expect(la[13] == 8)
}

@Test func reassemblesSplitAndCoalescedNotifications() {
    let a = reply(0x01, 0x03, [5, 9])
    let b = reply(0x1A, 0x10)
    var r = Reassembler()
    let stream = [0x00, 0x11] + a + b   // 前面带两个垃圾字节
    var got: [Packet] = []
    for chunk in stride(from: 0, to: stream.count, by: 7) {
        got += r.feed(Data(stream[chunk..<min(chunk + 7, stream.count)]))
    }
    #expect(got.count == 2)
    #expect(got[0].matches(0x01, 0x03) && Array(got[0].payload) == [5, 9])
    #expect(got[1].matches(0x1A, 0x10) && got[1].isSuccess)
}

@Test func skipsCorruptFrameAndResyncs() {
    var bad = reply(0x01, 0x03, [1, 2])
    bad[bad.count - 1] ^= 0xFF
    var r = Reassembler()
    let got = r.feed(Data(bad + reply(0x0B, 0x87)))
    #expect(got.count == 1 && got[0].matches(0x0B, 0x87))
}

@Test func parsesDeviceInfo() {
    var p: [UInt8] = [1, 6, 1]                               // 已连接、电量档位 6、充电中
    p += Array("04.92".utf8)
    p += Array("007F1D04CCA3".utf8) + [0, 0, 0, 0]           // 序列号 16 字节
    p += le32(7_000_000) + le32(5_000_000)
    p += [0] + Array("01.10".utf8) + [9]                     // 充电盒：未充电、固件、档位 9
    p += [1, 2, 3, 4, 5, 6] + [0, 1, 2, 1] + [1, 1]          // MAC、杂项、盒灯、录音中
    let info = DeviceInfo(packet: Packet(raw: reply(0x01, 0x01, p)))!
    #expect(info.micBattery == 70 && info.micCharging)
    #expect(info.firmware == "04.92" && info.serial == "007f1d04cca3")
    #expect(info.usedKB == 2_000_000)
    #expect(info.caseBattery == 100 && info.caseFirmware == "01.10" && !info.caseCharging)
    #expect(info.recording)
}

/// 这一帧是从真机上抓到的原始回包。
@Test func parsesFileListCapturedFromDevice() {
    let raw: [UInt8] = [0x09, 0xFF, 0, 0, 0x01, 0x1B, 0x0E, 0x20, 0x00, 0x01, 0x00, 0xD4, 0x1F, 0xF5, 0x6A, 0, 0, 0, 0,
                        0x78, 0x64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x81]
    var r = Reassembler()
    let packet = r.feed(Data(raw)).first!
    let page = FileListPage(packet: packet)!
    #expect(page.files == [RemoteFile(id: 1_794_449_364, durationMs: 25720)] && !page.hasMore)
    #expect(page.activeFileID == 0)
    #expect(page.files[0].duration == 25.72)
    #expect(page.files[0].audioBytes == 205_760)          // 实际下载到的字节数
    #expect(page.files[0].startDate == Date(timeIntervalSince1970: 1_794_449_364))
}

@Test func aesCTRMatchesNISTVector() {
    // NIST SP 800‑38A F.5.5 CTR‑AES256
    func h(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! } }
    let out = aesCTR(key: h("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
                     iv: h("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
                     data: h("6bc1bee22e409f96e93d7e117393172a"))
    #expect(out == h("601ec313775789a5b7a7f504bbf3d228"))
}

/// 用一台"假设备"走完整个流程：握手 → 文件头 → 加密切片 → 解密。
@Test func fullPullAndDecryptRoundTrip() throws {
    let app = CryptoSession()
    let device = P256.KeyAgreement.PrivateKey()
    let appPub = try P256.KeyAgreement.PublicKey(x963Representation: app.publicKey)
    let shared = try device.sharedSecretFromKeyAgreement(with: appPub).withUnsafeBytes { Array($0) }
    #expect(app.publicKey.count == 65)

    let hs = Packet(raw: reply(0x2E, 0x01, Array(device.publicKey.x963Representation) + shared))
    #expect(app.completeHandshake(hs))

    let sessionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: Data([1, 2, 3]),
                                            info: Data([1, 2, 3]), outputByteCount: 32).withUnsafeBytes { Array($0) }
    let fileKey = (0..<32).map { UInt8($0 * 7 + 1) }
    let nonce = (0..<16).map { UInt8(0xA0 + $0) }
    let sessionNonce = (0..<16).map { UInt8(0x10 + $0) }
    let wrapped = aesCTR(key: sessionKey, iv: sessionNonce, data: Array("soundcored3200".utf8) + fileKey)!
    #expect(wrapped.count == 46)

    let plain = (0..<480).map { UInt8(truncatingIfNeeded: $0 * 3) }
    let headPayload = le32(1_790_000_000) + le32(480) + nonce + wrapped + sessionNonce + [0]
    let head = FileHead(packet: Packet(raw: reply(0x1A, 0x07, headPayload)))!
    #expect(head.fileID == 1_790_000_000 && head.size == 480)
    #expect(head.audioBytes == 320)   // 480 / 166 向下取整 × 160
    let dec = try #require(app.fileDecryptor(head: head))

    var slicePayload: [UInt8] = []
    for seq in 0..<3 {
        let c = UInt32(seq * 10)
        let iv = Array(nonce.prefix(12)) + [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        let enc = aesCTR(key: fileKey, iv: iv, data: Array(plain[(seq * 160)..<(seq * 160 + 160)]))!
        slicePayload += le32(UInt32(seq)) + [0] + enc + (seq < 2 ? [0] : [])   // 最后一个单元没有填充字节
    }
    let slices = Slice.parse(Packet(raw: reply(0x1A, 0x08, slicePayload)))
    #expect(slices.map(\.sequence) == [0, 1, 2] && slices.map(\.offset) == [0, 160, 320])
    #expect(slices.flatMap { dec.decrypt($0.data, sequence: $0.sequence) } == plain)
}

@Test func handshakeRejectsMismatchedSecret() {
    let app = CryptoSession()
    let device = P256.KeyAgreement.PrivateKey()
    #expect(!app.completeHandshake(devicePublicKey: device.publicKey.x963Representation, deviceShared: Data(count: 32)))
    #expect(!app.isReady)
}

@Test func oggPagesHaveValidStructure() {
    #expect(OggOpus.crc32(Array("123456789".utf8)) == 0x89A1_897F)   // 多项式 04C11DB7、初值 0、不取反时 "123456789" 的校验值
    let raw = Data((0..<(160 * 120 + 30)).map { UInt8(truncatingIfNeeded: $0) })
    let ogg = Array(OggOpus.mux(raw: raw))
    var pages = 0, pos = 0, lastFlags: UInt8 = 0, packets = 0
    while pos < ogg.count {
        #expect(Array(ogg[pos..<(pos + 4)]) == Array("OggS".utf8))
        let nseg = Int(ogg[pos + 26])
        let lacing = ogg[(pos + 27)..<(pos + 27 + nseg)]
        let size = 27 + nseg + lacing.reduce(0) { $0 + Int($1) }
        var page = Array(ogg[pos..<(pos + size)])
        let stored = page.u32(22)
        page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        #expect(OggOpus.crc32(page) == stored)
        if pages >= 2 { packets += lacing.filter { $0 < 255 }.count }
        lastFlags = ogg[pos + 5]
        pages += 1; pos += size
    }
    #expect(pages == 2 + 3 && packets == 120 && lastFlags == 0x04)
}

/// 用系统编码器造真实的 Opus 帧，再走我们的解码路径，确认时长和音量都对。
@Test func decodesRealOpusPacketsToWAV() throws {
    let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    let opus = try #require(OpusDecoder.opusFormat())
    let encoder = try #require(AVAudioConverter(from: pcm, to: opus))
    let seconds = 2
    let src = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(48000 * seconds))!
    src.frameLength = src.frameCapacity
    for i in 0..<Int(src.frameLength) { src.floatChannelData![0][i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / 48000) }

    var packets: [Data] = []
    nonisolated(unsafe) var pending: AVAudioPCMBuffer? = src
    while true {
        let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 8, maximumPacketSize: 1500)
        var err: NSError?
        let status = encoder.convert(to: out, error: &err) { _, st in
            if let b = pending { pending = nil; st.pointee = .haveData; return b }
            st.pointee = .endOfStream; return nil
        }
        for n in 0..<Int(out.packetCount) {
            let d = out.packetDescriptions![n]
            packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
        }
        if status != .haveData { break }
    }
    #expect(packets.count >= 95)

    if let out = ProcessInfo.processInfo.environment["BEAN_OGG_OUT"] {
        try OggOpus.mux(packets: packets).write(to: URL(fileURLWithPath: out))
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beankit-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let duration = try OpusDecoder.writeWAV(packets: packets, to: url)
    #expect(abs(duration - Double(seconds)) < 0.15)

    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == 16000)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let samples = UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
    let rms = sqrt(samples.dropFirst(1600).reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count - 1600))
    #expect(rms > 0.25 && rms < 0.45)   // 0.5 振幅正弦波的有效值约 0.354
}

// MARK: - Wi‑Fi 快传

@Test func wifiCommandsMatchOfficialClient() {
    // 开热点：长度 + 热点名 + 长度 + 密码
    let config = Array(Command.wifiConfig(ssid: "WiFi-1", password: "12345678"))
    #expect(Array(config[5...8]) == [0x1A, 0x05, UInt8(config.count), 0])
    #expect(Array(config[9..<(config.count - 1)]) == [6] + Array("WiFi-1".utf8) + [8] + Array("12345678".utf8))
    // 要文件：十六进制文本，偏移在前、文件编号在后，末尾写死 1b
    #expect(Command.wifiPullText(0x6AF5_1234, offset: 166) == "08ee0000001a071200" + "a6000000" + "3412f56a" + "1b")
    // 确认收完
    #expect(Command.wifiDoneText() == "08ee0000001a0a0b000126")
}

@Test func wifiSplitterHandlesBatchedAndPartialFrames() {
    let a = reply(0x1A, 0x08, Array(repeating: 7, count: 166))
    let b = reply(0x1A, 0x0A)
    // 一条消息里连着两帧，后面跟着半帧
    var buffer = a + b + Array(a.prefix(40))
    let first = WiFiFrame.split(&buffer)
    #expect(first.map(\.id) == [0x08, 0x0A])
    #expect(buffer.count == 40)
    // 下一条消息把剩下的补齐
    buffer += a.dropFirst(40)
    let second = WiFiFrame.split(&buffer)
    #expect(second.count == 1 && second[0].raw == a)
    #expect(buffer.isEmpty)
    // 校验和不对也照收（官方客户端不校验）
    var bad = b; bad[bad.count - 1] ^= 0xFF
    var buffer2 = [0x00, 0x01] + bad
    #expect(WiFiFrame.split(&buffer2).count == 1)
}

// MARK: - 从链接导入

@Test func findsLinksInsideShareText() {
    let text = "7.43 复制打开抖音，看看【某某的作品】三分钟讲清楚复利… https://v.douyin.com/iABcd12/ 快来看！\nhttps://www.bilibili.com/video/BV1xx411c7mD?t=3。还有（https://youtu.be/abc_DEF-1）"
    let urls = LinkTools.urls(in: text)
    #expect(urls == ["https://v.douyin.com/iABcd12/", "https://www.bilibili.com/video/BV1xx411c7mD?t=3", "https://youtu.be/abc_DEF-1"])
    #expect(urls.map(LinkTools.platform(of:)) == ["抖音", "B 站", "YouTube"])
    #expect(LinkTools.platform(of: "https://example.org/v/1") == "网页视频")
    #expect(LinkTools.urls(in: "没有链接的一句话").isEmpty)
    // 同一条贴两遍只算一条
    #expect(LinkTools.urls(in: "https://x.com/a/status/1 https://x.com/a/status/1").count == 1)
}

@Test func parsesSubtitlesAndMergesRollingLines() {
    let vtt = """
    WEBVTT
    Kind: captions

    00:00:01.000 --> 00:00:03.000
    大家好

    00:00:03.000 --> 00:00:05.000 align:start
    大家好 <c>今天聊复利</c>

    00:00:05.000 --> 00:00:07.000
    大家好 今天聊复利

    1
    00:01:02,500 --> 00:01:04,000
    A &amp; B

    """
    let cues = SubtitleParser.parse(vtt)
    #expect(cues.map(\.text) == ["大家好 今天聊复利", "A & B"])
    #expect(cues.map(\.start) == [1, 62.5])
}
