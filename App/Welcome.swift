import SwiftUI

/// 上手引导：第一次打开时出现，把要准备的三样东西摆在一页上。做完一样勾一样，随时可以先跳过。
struct WelcomeView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(Connector.self) private var connector

    private var connected: Bool { store.link == .ready }
    private var ready: Bool { connected && store.asrAvailable }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MascotView(mood: ready ? .happy : .idle, power: .mid).frame(width: 92, height: 92).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("欢迎来到豆仓").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("录音豆负责听，豆仓负责把它变成文字和纪要。\n先准备三样东西，几分钟就好。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 18)

            VStack(spacing: 10) {
                step(1, "连接录音豆", connected ? "\(store.displayDeviceName) 已连接" : "把录音豆从充电盒里拿出来，放在 Mac 旁边。", done: connected) {
                    Button("去连接") { nav.route = .device; dismiss() }
                }
                step(2, "下载转写模型", store.asrAvailable ? "已就绪。转写在这台 Mac 上完成，录音不上传。" : "约 1 GB，下一次就一直能用。转写在这台 Mac 上完成，录音不上传。", done: store.asrAvailable) {
                    if let progress = store.modelDownload {
                        ProgressView(value: progress).frame(width: 110)
                        Text("\(Int(progress * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Button("下载") { store.downloadASRModel() }
                    }
                }
                step(3, "选一个整理纪要的模型", store.analysisAvailable ? "已就绪。" : "把文字稿整理成摘要、待办和重点。可以用本机模型，也可以填自己的云端模型。这一步可以以后再做。", done: store.analysisAvailable) {
                    if let progress = store.llmDownload {
                        ProgressView(value: progress).frame(width: 110)
                        Text("\(Int(progress * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Button("打开设置") { openSettings() }
                    }
                }
                step(4, "连上你常用的 AI 助手（可选）",
                     connector.connectedCount > 0 ? "已经连上 \(connector.connectedCount) 个。在它们那边就能直接问豆仓里的内容。"
                        : "Claude、Codex、OpenClaw、Grok Bot 都可以。连上之后，在它们那边就能直接问豆仓里的录音和待办。",
                     done: connector.connectedCount > 0) {
                    Button("去连接") { openWindow(id: "connect") }
                }
            }
            .task { await connector.refresh() }

            HStack {
                Text("以后想再看这一页：菜单栏「帮助」→「上手引导」。").font(.callout).foregroundStyle(.tertiary)
                Spacer()
                Button(ready ? "开始使用" : "先逛逛") {
                    UserDefaults.standard.set(true, forKey: "welcomed")
                    dismiss()
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 600)
        .onAppear { store.refreshASRAvailability() }
        .animation(.spring(response: 0.4, dampingFraction: 1), value: connected)
        .animation(.spring(response: 0.4, dampingFraction: 1), value: store.asrAvailable)
    }

    private func step<Trailing: View>(_ number: Int, _ title: String, _ detail: String, done: Bool,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.quaternary)).frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done { HStack(spacing: 8) { trailing() } }
        }
        .padding(14)
        .panel(radius: 14)
    }
}
