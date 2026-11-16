import AppKit
import SwiftUI

/// 「做成视频」交回来的成片（设计稿 design/ui/ui_video_result.png）：
/// 左边封面（点一下播放），右边风格画幅、时长积分、用了哪些包装、质检；下面能展开成片里实际念的口播稿。
/// 没做成的那条也留在这里，写明原因和已经花的积分。
struct VideoResultCard: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    let clip: VideoClip
    @State private var showScript = false
    @State private var confirmDelete = false

    private var url: URL { store.folder.appendingPathComponent(clip.file) }
    private var vertical: Bool { (clip.ratio ?? "9:16") == "9:16" || clip.ratio == "3:4" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if clip.failed { failedRow } else { finishedRow }
            if let script = clip.script, !clip.failed {
                Divider().opacity(0.6)
                DisclosureGroup(isExpanded: $showScript) {
                    // 一段一行，前面带序号（和 Claude 那边 script.json 的 s01、s02 对得上）
                    let lines = script.split(separator: "\n").map(String.init)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            if i > 0 { Divider().opacity(0.5) }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(format: "s%02d", i + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.chip))
                                Text(line).font(.callout).foregroundStyle(Theme.warm800).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 7)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("成片口播稿 · \(script.split(separator: "\n").count) 段").font(.callout.weight(.medium))
                }
            }
        }
        .padding(16).panel(radius: Theme.Radius.panel)
        .task(id: clip.id) { await fillCover() }
        .confirmationDialog("删掉这条视频？", isPresented: $confirmDelete) {
            Button("删掉", role: .destructive) { store.deleteVideo(recording.id, clip.id) }
        } message: {
            Text(clip.failed ? "只删这条记录。" : "成片会移到废纸篓，口播稿和说明一起删掉。Renoise 里的成片不受影响。")
        }
    }

    private var finishedRow: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { NSWorkspace.shared.open(url) } label: { cover }
                .buttonStyle(.plain).help("播放成片").accessibilityLabel("播放成片")
            VStack(alignment: .leading, spacing: 8) {
                Text(heading).font(.headline).foregroundStyle(Theme.warm900)
                Text(meta).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let summary = clip.summary {
                    Text(summary).font(.callout).foregroundStyle(Theme.warm700).fixedSize(horizontal: false, vertical: true)
                }
                if let checks = clip.checks {
                    Label(checks, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons; Spacer(minLength: 8); trash }
                    FlowLayout(spacing: 8) { buttons; trash }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { NSWorkspace.shared.open(url) } label: { Label("播放", systemImage: "play.fill") }
            .buttonStyle(.glassProminent).fixedSize()
        Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(.glass).fixedSize()
        if let script = clip.script {
            Button("拷贝口播稿", systemImage: "doc.on.doc") { copyText(script); store.toast("doc.on.doc", String(localized: "口播稿已拷贝")) }
                .buttonStyle(.glass).fixedSize()
        }
        if let material = clip.material {
            Button("拷贝素材编号", systemImage: "number") { copyText(material); store.toast("number", String(localized: "Renoise 素材编号已拷贝")) }
                .buttonStyle(.glass).fixedSize()
                .help("Renoise 里成片的素材编号：\(material)")
        }
    }

    private var trash: some View {
        Button("删除", systemImage: "trash") { confirmDelete = true }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help("删掉这条视频")
    }

    private var failedRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(Theme.amber)
                .frame(width: 44, height: 44).background(Theme.amber.opacity(0.14), in: .rect(cornerRadius: Theme.Radius.card))
            VStack(alignment: .leading, spacing: 4) {
                Text("没做成 · \(heading)").font(.headline)
                Text(clip.error ?? "").font(.callout).foregroundStyle(Theme.warm700).fixedSize(horizontal: false, vertical: true)
                Text(clip.date.formatted(date: .abbreviated, time: .shortened) + (clip.credits > 0 ? String(localized: " · 已花 \(clip.credits) 积分") : String(localized: " · 没花积分")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("删除", systemImage: "trash") { confirmDelete = true }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    private var cover: some View {
        let size = vertical ? CGSize(width: 120, height: 213) : CGSize(width: 200, height: 113)
        return ZStack {
            if let name = clip.cover, let image = NSImage(contentsOf: store.folder.appendingPathComponent(name)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.warm100
                Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(Theme.warm400)
            }
            Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(.black.opacity(0.35), in: .circle)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: Theme.Radius.card))
    }

    /// 旧版把「风格 · 主播」拼在 host 里，没有单独的 style：拆开显示。
    private var legacy: Bool { clip.style == nil && clip.host.contains(" · ") }
    private var style: String? { clip.style ?? (legacy ? clip.host.components(separatedBy: " · ").first : nil) }
    private var host: String { legacy ? clip.host.components(separatedBy: " · ").dropFirst().joined(separator: " · ") : clip.host }

    private var heading: String {
        // 风格存的是中文名（VideoMaker.Style.name），显示时换成当前语言
        let shown = style.map { s in VideoMaker.Style.allCases.first { $0.name == s }?.label ?? s }
        return ([String(localized: "数字人口播"), shown, clip.ratio].compactMap { $0 }).joined(separator: " · ")
    }

    /// 没有封面（旧版交付的）：从成片里取一帧补上。
    private func fillCover() async {
        guard clip.cover == nil, !clip.failed, !clip.file.isEmpty else { return }
        let video = url
        let name = (clip.file as NSString).deletingPathExtension + ".jpg"
        let out = store.folder.appendingPathComponent(name)
        let ok = await Task.detached { VideoMaker.writeFrame(of: video, to: out) }.value
        if ok { store.setVideoCover(recording.id, clip.id, cover: name) }
    }

    private var meta: String {
        var parts = [clip.date.formatted(date: .abbreviated, time: .shortened)]
        if clip.seconds > 0 { parts.append(clip.seconds >= 60 ? String(localized: "\(clip.seconds / 60) 分 \(clip.seconds % 60) 秒") : String(localized: "\(clip.seconds) 秒")) }
        parts.append(String(localized: "主播 \(host)"))
        if clip.credits > 0 { parts.append(String(localized: "花了 \(clip.credits.formatted()) 积分")) }
        return parts.joined(separator: " · ")
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
