import SwiftUI

/// 小豆。形象是 Codex 画的毛绒仓鼠，每种状态一张图；动起来靠呼吸、点头、歪头这些轻微的位移。
/// （原来的 3D 模型还留在 Mascot.swift 里，叫 Mascot3DView，现在没有地方用它。）
struct MascotView: View {
    var mood: MascotMood
    var power: MascotPower = .unknown
    /// 现在的音量（0…1）。录音时小豆会跟着声音轻轻起伏。
    var level: Float?
    /// 不管什么状态都待在充电仓里（设备页的主视觉用）。
    var inPod = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swing = false
    @State private var hop: CGFloat = 0

    /// 这个状态用哪张图。
    private var art: String {
        if mood == .sleeping { return "sleeping" }
        if inPod { return "charging" }
        switch mood {
        case .happy: return "happy"
        case .listening: return "listening"
        case .writing: return "writing"
        case .thinking: return "thinking"
        case .sleeping: return "sleeping"
        case .idle:
            switch power {
            case .charging: return "charging"
            case .low: return "low"
            default: return "idle"
            }
        }
    }

    /// 每种状态自己的动法：幅度（上下、缩放、歪头的角度）和一个来回多久。
    private var motion: (bob: CGFloat, scale: CGFloat, tilt: Double, period: Double) {
        switch art {
        case "writing": (2.5, 0.006, 1.2, 0.36)      // 埋头写：小幅快速点动
        case "thinking": (1.5, 0.008, 4.5, 2.6)      // 歪头想：慢慢左右歪
        case "listening": (1.0, 0.010, 2.0, 1.8)     // 侧耳听：轻轻晃
        case "happy": (4.0, 0.020, 3.0, 0.5)
        case "sleeping": (0.5, 0.022, 0, 4.2)        // 睡着：很慢很深的呼吸
        case "low": (0.5, 0.010, 0, 4.5)
        default: (1.2, 0.016, 0, 3.2)                // 待着：平稳呼吸
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let m = motion
            let loud = CGFloat(min(1, max(0, level ?? 0)))
            ZStack {
                // 脚下的影子，窝在充电仓里的时候不要
                if art != "sleeping", art != "charging" {
                    Ellipse().fill(.black.opacity(0.10)).frame(width: side * 0.5, height: side * 0.07)
                        .blur(radius: side * 0.025).offset(y: side * 0.44)
                        .scaleEffect(1 - hop / (side * 0.9))
                }
                Self.image(art)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: side * 0.94, height: side * 0.94)
                    // 呼吸和点动：以脚底为轴，身子鼓起来再落回去
                    .scaleEffect(x: 1 - (swing ? m.scale * 0.5 : 0), y: 1 + (swing ? m.scale : 0) + loud * 0.03, anchor: .bottom)
                    .rotationEffect(.degrees(swing ? m.tilt : -m.tilt), anchor: .bottom)
                    .offset(y: (swing ? -m.bob : m.bob) - hop)
                    .id(art)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: art)
            .animation(.easeOut(duration: 0.25), value: loud)
            .contentShape(Rectangle())
            .onTapGesture { jump(side) }
            .task(id: art) {
                // 换了状态，按新状态的节奏重新动起来
                swing = false
                guard !reduceMotion else { return }
                if art == "happy" { jump(side); try? await Task.sleep(for: .seconds(0.55)); jump(side) }
                withAnimation(.easeInOut(duration: m.period / 2).repeatForever(autoreverses: true)) { swing = true }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 图是散放在 App 包里的 PNG，按名字读出来，读过的留着不重复读。
    #if os(macOS)
    private typealias Picture = NSImage
    #else
    private typealias Picture = UIImage
    #endif
    private static var cache: [String: Picture] = [:]
    private static func picture(_ name: String) -> Picture {
        if let hit = cache[name] { return hit }
        let image = Bundle.main.url(forResource: "xiaodou_" + name, withExtension: "png").flatMap { Picture(contentsOfFile: $0.path) } ?? Picture()
        cache[name] = image
        return image
    }
    private static func image(_ name: String) -> Image {
        #if os(macOS)
        Image(nsImage: picture(name))
        #else
        Image(uiImage: picture(name))
        #endif
    }

    /// 点一下，或者高兴的时候：蹦一下。
    private func jump(_ side: CGFloat) {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { hop = side * 0.10 }
        Task {
            try? await Task.sleep(for: .seconds(0.2))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { hop = 0 }
        }
    }
}
