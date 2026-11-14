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

    /// 查重用的「作品键」：同一条作品的不同写法算成同一个键。
    /// 认得出作品号的平台用「平台:作品号」（不管带没带分享参数、是网页版还是手机版、小红书的 token 换没换）；
    /// 认不出的（短链、别的网站）用去掉分享追踪参数的地址。短链要等下载时解析出作品页，再按作品页查一次。
    public static func contentKey(of url: String) -> String? {
        guard var parts = URLComponents(string: url), let host = parts.host?.lowercased() else { return nil }
        let items = parts.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: url) else { return nil }
            return String(url[r])
        }
        let platform = platform(of: url)
        var id: String?
        switch platform {
        case "抖音": id = capture(#"/(?:video|note)/(\d{12,})"#) ?? query("modal_id") ?? query("aweme_id")
        case "TikTok": id = capture(#"/(?:video|photo)/(\d{12,})"#)
        case "视频号": id = capture(#"/sph/([A-Za-z0-9]+)"#) ?? (url.contains("pages/sph") ? query("id") : nil)
        case "小红书": id = capture(#"/(?:explore|discovery/item|red_video|item)/([0-9a-f]{24})"#)
        case "B 站":
            if let bv = capture(#"(BV[0-9A-Za-z]{10})"#) ?? capture(#"/video/(av\d+)"#) {
                // 分 P 的视频每一 P 算一条
                let p = Int(query("p") ?? "") ?? 1
                id = p > 1 ? "\(bv)?p=\(p)" : bv
            }
        case "YouTube": id = query("v") ?? capture(#"(?:youtu\.be/|/shorts/|/live/|/embed/)([A-Za-z0-9_-]{11})"#)
        case "X": id = capture(#"/status(?:es)?/(\d+)"#)
        case "快手": id = capture(#"/(?:short-video|photo|fw/photo)/([0-9A-Za-z]+)"#)
        case "喜马拉雅": id = capture(#"/sound/(\d+)"#)
        case "小宇宙": id = capture(#"/episode/([0-9a-f]{24})"#)
        default: break
        }
        if let id { return "\(platform):\(id)" }
        // 认不出作品号：去掉分享、追踪用的参数和末尾的斜杠
        let tracking: Set = ["si", "spm", "from", "source", "share_source", "share_medium", "share_plat", "share_session_id",
                             "share_tag", "share_from", "timestamp", "unique_k", "vd_source", "xsec_source", "xhsshare", "feature"]
        let kept = items.filter { !tracking.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
            .sorted { $0.name < $1.name }
        parts.queryItems = kept.isEmpty ? nil : kept
        parts.fragment = nil
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare + path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
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
