import SwiftUI

/// 豆仓的颜色：石墨底、暖白字，琥珀色是唯一的强调色；红色只留给「正在录音」。不用蓝和紫。
nonisolated enum Theme {
    static let amber = Color("AccentColor")
    static let rec = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let graphite = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let paper = Color(red: 0.96, green: 0.93, blue: 0.87)
    /// 「没问题」的颜色：一种不扎眼的绿，只用在已连接、已就绪这类状态上。
    static let ok = Color(red: 0.42, green: 0.72, blue: 0.47)
    /// 区分说话人用的一组颜色：都在暖色和中性色里选。
    static let speakers: [Color] = [
        Color(red: 0.93, green: 0.62, blue: 0.16),   // 琥珀
        Color(red: 0.86, green: 0.38, blue: 0.30),   // 珊瑚
        Color(red: 0.42, green: 0.62, blue: 0.40),   // 鼠尾草绿
        Color(red: 0.66, green: 0.54, blue: 0.38),   // 沙
        Color(red: 0.70, green: 0.36, blue: 0.20),   // 赭
        Color(red: 0.52, green: 0.50, blue: 0.47),   // 暖灰
    ]
}

/// 录音舞台：录音时盖住整个窗口。只留四样东西——时间、声音、刚说的那句话、三个按钮。
struct RecordStage: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var paused: Bool { store.recState == .paused }
    private var level: Float { paused ? 0 : (store.liveLevels.suffix(3).max() ?? 0) }

    var body: some View {
        ZStack {
            Theme.graphite.ignoresSafeArea()
            // 一团跟着音量亮暗的暖光，垫在波形后面
            RadialGradient(colors: [(paused ? Theme.paper : Theme.rec).opacity(0.10 + 0.16 * Double(level)), .clear],
                           center: .init(x: 0.82, y: 0.55), startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.3), value: level)

            VStack(spacing: 0) {
                top
                Spacer(minLength: 12)
                timer
                FlowWave(levels: store.liveLevels, total: store.liveLevelTotal, marks: store.liveMarks,
                         elapsed: { store.elapsed(at: $0) }, paused: paused, still: reduceMotion)
                    .frame(height: 170)
                    .padding(.top, 18)
                caption
                Spacer(minLength: 12)
                controls
            }
            .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 30)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Theme.paper)
    }

    private var top: some View {
        HStack(spacing: 10) {
            Circle().fill(paused ? Theme.amber : Theme.rec).frame(width: 9, height: 9)
                .opacity(paused ? 1 : 0.55 + 0.45 * Double(level))
                .animation(.easeOut(duration: 0.25), value: level)
            Text(paused ? "已暂停" : "正在录音").font(.callout.weight(.semibold)).tracking(1.5)
            Text(store.recordingOnMac ? "这台 Mac 的麦克风" : store.displayDeviceName + (store.info.map { " · \($0.micBattery)%" } ?? ""))
                .font(.callout).foregroundStyle(Theme.paper.opacity(0.45))
            Spacer()
            Button { nav.stageOpen = false } label: {
                Label("收起", systemImage: "chevron.down").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .help("收起舞台，回到豆仓。录音不会停（Esc）")
        }
    }

    private var timer: some View {
        HStack(alignment: .center, spacing: 22) {
            MascotView(mood: paused ? .idle : .listening, power: .mid, level: paused ? nil : level)
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let t = store.elapsed(at: context.date)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(clock(t.rounded(.down)))
                        .font(.system(size: 104, weight: .ultraLight, design: .rounded)).monospacedDigit()
                    Text(String(format: ".%d", Int(t * 10) % 10))
                        .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.paper.opacity(0.4))
                }
                .opacity(paused ? 0.55 : 1)
                .accessibilityElement().accessibilityLabel("已录时长").accessibilityValue(spokenDuration(t))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var caption: some View {
        Group {
            if let last = store.liveSegments.last {
                Text(store.settings.liveTidy ? stripFillers(last.text) : last.text)
                    .font(.title2).lineLimit(2).multilineTextAlignment(.center)
                    .id(last.id).transition(.opacity.combined(with: .offset(y: 8)))
            } else if let note = store.liveNote {
                Text(note).font(.title3).foregroundStyle(Theme.amber)
            } else if store.recordingOnMac {
                Text("用 Mac 的麦克风录音时暂时不出实时字幕。录完会完整转写、整理成纪要。").font(.title3).foregroundStyle(Theme.paper.opacity(0.45))
            } else if !store.liveActive {
                Text("没开实时转写，这里不出字，声音也画不出来。录音照常在录。").font(.title3).foregroundStyle(Theme.paper.opacity(0.45))
            } else {
                Text(store.liveLevelTotal == 0 ? "等录音豆把声音传过来…" : "在听…").font(.title3).foregroundStyle(Theme.paper.opacity(0.45))
            }
        }
        .frame(maxWidth: 760, minHeight: 64, alignment: .top).frame(maxWidth: .infinity)
        .padding(.top, 20)
        .animation(.easeOut(duration: 0.3), value: store.liveSegments.last?.id)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { store.markNow() } label: {
                Label(store.liveMarks.isEmpty ? "标重点" : "标重点 · \(store.liveMarks.count)", systemImage: "flag.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.glass).tint(Theme.amber).controlSize(.extraLarge)
            .disabled(paused)
            .help("这句话很重要：打个标记，回听时一点就到（⌘D）。在录音豆上按标记键也一样")

            Button { paused ? store.resumeRecording() : store.pauseRecording() } label: {
                Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill").padding(.horizontal, 10)
            }
            .buttonStyle(.glass).controlSize(.extraLarge)
            .help(paused ? "接着录进同一条（⌘R）" : "先停一下，稍后接着录进同一条（⌘R）")

            Spacer()

            Button { nav.route = .live; nav.stageOpen = false } label: {
                Label("全部文字", systemImage: "text.alignleft")
            }
            .buttonStyle(.glass).controlSize(.extraLarge)
            .disabled(store.liveSegments.isEmpty)

            Button { store.finishRecording() } label: {
                Label("结束", systemImage: "stop.fill").padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent).tint(Theme.rec).controlSize(.extraLarge)
            .help("结束这条录音（⌘.）。结束后会自动下载并整理成纪要")
        }
    }
}

/// 流动的声音：细密的竖线从右边长出来，匀速往左流走。
/// 音量每 0.2 秒才到一批，这里自己按时间匀速往前走，所以看上去是连续的，不会一顿一顿。
struct FlowWave: View {
    let levels: [Float]
    let total: Int
    let marks: [TimeInterval]
    let elapsed: (Date) -> TimeInterval
    let paused: Bool
    var still = false
    var color: Color = Theme.paper
    var head: Color = Theme.rec

    /// 画到哪了。放在引用类型里，每一帧接着上一帧往前走。
    private final class Playhead { var position: Double = 0; var last: Date? }
    @State private var playhead = Playhead()

    private let perLevel = 2.0          // 每个音量值画两根线
    private let pitch: CGFloat = 4      // 线和线的间距

    var body: some View {
        TimelineView(.animation(minimumInterval: still ? 0.5 : 1 / 60, paused: false)) { context in
            Canvas { ctx, size in
                let p = advance(to: context.date)
                let mid = size.height / 2
                let right = size.width - 14
                let count = Int(right / pitch) + 2
                let firstIndex = total - levels.count
                let lead = p * perLevel                       // 最右边那根线对应的位置
                let whole = lead.rounded(.down)
                let shift = CGFloat(lead - whole) * pitch     // 不足一根线的那一点位移，流动感就靠它

                for i in 0..<count {
                    let k = whole - Double(i)                 // 这根线在整条声音里是第几根
                    let x = right - CGFloat(i) * pitch - shift
                    guard x > -2 else { break }
                    let at = k / perLevel
                    var amp = CGFloat(level(at, firstIndex))
                    if total == 0 { amp = 0.05 + 0.035 * CGFloat(sin(context.date.timeIntervalSinceReferenceDate * 2 + k * 0.22)) }
                    let h = max(2, amp * size.height * 0.92)
                    let fade = min(1, x / (size.width * 0.35))          // 越往左越淡
                    let fresh = max(0, 1 - CGFloat(i) / 10)             // 刚长出来的几根带一点红
                    let rect = CGRect(x: x - 1, y: mid - h / 2, width: 2, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(Double(fade) * (paused ? 0.35 : 0.9))))
                    if fresh > 0, !paused, total > 0 {
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(head.opacity(Double(fresh) * 0.85)))
                    }
                }

                // 重点标记：一根琥珀色的细线，跟着声音一起往左流
                let now = elapsed(context.date)
                let pxPerSecond = pitch * CGFloat(perLevel) * 10
                for m in marks {
                    let x = right - CGFloat(now - m) * pxPerSecond
                    guard x > 0, x <= right else { continue }
                    ctx.fill(Path(CGRect(x: x - 0.75, y: 6, width: 1.5, height: size.height - 12)), with: .color(Theme.amber))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 2, width: 8, height: 8)), with: .color(Theme.amber))
                }

                // 最右边的一点：声音从这里进来
                let dot = CGRect(x: right + 4, y: mid - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: dot), with: .color((paused ? color.opacity(0.4) : head)))
            }
        }
        .accessibilityLabel(paused ? "录音已暂停" : "正在录音的声音波形")
    }

    /// 匀速往前走，每秒 10 个音量值；落后多了就稍微加快追上，永远不超过已经到手的数据。
    private func advance(to date: Date) -> Double {
        let dt = playhead.last.map { min(0.25, max(0, date.timeIntervalSince($0))) } ?? 0
        playhead.last = date
        let target = Double(total)
        if playhead.position > target || target - playhead.position > 40 { playhead.position = max(0, target - 3) }
        guard !paused else { return playhead.position }
        let lag = target - playhead.position
        let rate = 10 * (lag > 5 ? 1 + min(1.5, (lag - 5) / 6) : (lag < 1.5 ? max(0.25, lag / 1.5) : 1))
        playhead.position = min(target, playhead.position + dt * rate)
        return playhead.position
    }

    /// 第 at 个音量值（可以是小数：在相邻两个之间平滑过渡）。
    private func level(_ at: Double, _ firstIndex: Int) -> Float {
        let i = Int(at.rounded(.down)) - firstIndex
        guard i >= 0, i < levels.count else { return 0.02 }
        let a = levels[i], b = i + 1 < levels.count ? levels[i + 1] : a
        let f = Float(at - at.rounded(.down))
        let s = f * f * (3 - 2 * f)
        return max(0.02, a + (b - a) * s)
    }
}
