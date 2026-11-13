import Foundation

/// 「从链接导入」用到的两样纯文字活：从一段分享口令里找出链接、认出是哪个平台；把平台字幕读成一句一句的。
public enum LinkTools {
    /// 从粘贴的文字里找出所有链接。分享口令里链接前后常常紧贴着中文和标点，要切干净。
    public static func urls(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#) else { return [] }
        var seen = Set<String>(), out: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            var url = String(text[range])
            while let last = url.last, ".,;!?)]'\"".contains(last) { url.removeLast() }
            guard URL(string: url)?.host != nil, seen.insert(url).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// 这条链接是哪个平台的。认不出来的统称「网页视频」。
    public static func platform(of url: String) -> String {
        let host = (URL(string: url)?.host ?? "").lowercased()
        let table: [(String, String)] = [
            ("douyin.com", "抖音"), ("iesdouyin.com", "抖音"),
            ("tiktok.com", "TikTok"),
            ("xiaohongshu.com", "小红书"), ("xhslink.com", "小红书"),
            ("bilibili.com", "B 站"), ("b23.tv", "B 站"),
            ("youtube.com", "YouTube"), ("youtu.be", "YouTube"),
            ("twitter.com", "X"), ("x.com", "X"), ("t.co", "X"),
            ("instagram.com", "Instagram"),
            ("kuaishou.com", "快手"), ("chenzhongtech.com", "快手"),
            ("channels.weixin.qq.com", "视频号"), ("weixin.qq.com", "视频号"),
            ("weibo.com", "微博"), ("weibo.cn", "微博"),
            ("ximalaya.com", "喜马拉雅"), ("xiaoyuzhoufm.com", "小宇宙"),
            ("podcasts.apple.com", "播客"), ("vimeo.com", "Vimeo"),
        ]
        for (suffix, name) in table where host == suffix || host.hasSuffix("." + suffix) { return name }
        return "网页视频"
    }
}

public enum SubtitleParser {
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var text: String
        public init(start: Double, text: String) { self.start = start; self.text = text }
    }

    /// 读 WebVTT 或 SRT 字幕。去掉样式标记；平台的滚动字幕会把同一句话重复好几遍，这里合并掉。
    public static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        var start: Double?
        var lines: [String] = []
        func flush() {
            defer { start = nil; lines = [] }
            guard let s = start else { return }
            let joined = clean(lines.joined(separator: " "))
            guard !joined.isEmpty else { return }
            if let last = cues.last {
                if last.text == joined { return }                                   // 一模一样：重复
                if joined.hasPrefix(last.text) { cues[cues.count - 1].text = joined; return }   // 滚动字幕：越滚越长
                if last.text.hasSuffix(joined) { return }
            }
            cues.append(Cue(start: s, text: joined))
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let arrow = line.range(of: "-->") {
                flush()
                start = seconds(String(line[..<arrow.lowerBound]))
            } else if line.isEmpty {
                flush()
            } else if start != nil {
                lines.append(line)
            }
        }
        flush()
        return cues
    }

    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
