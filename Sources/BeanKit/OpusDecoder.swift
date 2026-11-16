@preconcurrency import AVFoundation
import Foundation

public enum AudioError: LocalizedError {
    case noAudio, decoderUnavailable, decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio: "没有音频数据"
        case .decoderUnavailable: "系统 Opus 解码器不可用"
        case .decodeFailed(let why): "解码失败：\(why)"
        }
    }
}

/// 用系统自带的 Opus 解码器把裸帧转成 16 kHz 单声道 WAV（播放和语音识别都用它）。
public enum OpusDecoder {
    public static func opusFormat(framesPerPacket: UInt32 = 960) -> AVAudioFormat? {
        var desc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &desc)
    }

    @discardableResult
    /// `framesPerPacket`：每个包在 48 kHz 下的采样数。录音豆固定 960（20 ms）；
    /// 别的来源（录音卡是设备上的 FFmpeg 编的）按第一个包的 TOC 字节算，见 `OggOpus.samplesPerPacket`。
    public static func writeWAV(packets: [Data], to url: URL, sampleRate: Double = 16000, framesPerPacket: UInt32 = 960) throws -> TimeInterval {
        guard !packets.isEmpty else { throw AudioError.noAudio }
        guard let input = opusFormat(framesPerPacket: framesPerPacket),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: pcm) else { throw AudioError.decoderUnavailable }

        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let resampler = AVAudioConverter(from: pcm, to: file.processingFormat) else { throw AudioError.decoderUnavailable }

        var total: AVAudioFramePosition = 0
        let batch = 250 // 5 秒一批
        var index = 0
        while index < packets.count {
            let group = Array(packets[index..<min(index + batch, packets.count)])
            index += group.count
            let bytes = group.reduce(0) { $0 + $1.count }
            let inBuf = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(group.count), maximumPacketSize: bytes)
            var offset = 0
            for (n, p) in group.enumerated() {
                p.copyBytes(to: inBuf.data.assumingMemoryBound(to: UInt8.self).advanced(by: offset), count: p.count)
                inBuf.packetDescriptions?[n] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                                            mDataByteSize: UInt32(p.count))
                offset += p.count
            }
            inBuf.packetCount = AVAudioPacketCount(group.count)
            inBuf.byteLength = UInt32(bytes)

            guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(group.count * Int(framesPerPacket) + 4096)) else {
                throw AudioError.decodeFailed("内存不足")
            }
            nonisolated(unsafe) var pending: AVAudioCompressedBuffer? = inBuf
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if let buf = pending { pending = nil; outStatus.pointee = .haveData; return buf }
                outStatus.pointee = .noDataNow
                return nil
            }
            if status == .error { throw AudioError.decodeFailed(error?.localizedDescription ?? "未知错误") }
            guard outBuf.frameLength > 0 else { continue }

            let ratio = file.processingFormat.sampleRate / pcm.sampleRate
            guard let resampled = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(Double(outBuf.frameLength) * ratio) + 1024) else {
                throw AudioError.decodeFailed("内存不足")
            }
            nonisolated(unsafe) var pendingPCM: AVAudioPCMBuffer? = outBuf
            let s2 = resampler.convert(to: resampled, error: &error) { _, outStatus in
                if let buf = pendingPCM { pendingPCM = nil; outStatus.pointee = .haveData; return buf }
                outStatus.pointee = .noDataNow
                return nil
            }
            if s2 == .error { throw AudioError.decodeFailed(error?.localizedDescription ?? "重采样失败") }
            if resampled.frameLength > 0 {
                try file.write(from: resampled)
                total += AVAudioFramePosition(resampled.frameLength)
            }
        }
        guard total > 0 else { throw AudioError.decodeFailed("没有解出任何声音") }
        return Double(total) / file.processingFormat.sampleRate
    }
}
