import SwiftUI

/// 实时转写：开会、访谈时边录边出字。字大、自动往下滚，适合投在屏幕上给大家看。
struct LiveView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        @Bindable var settings = store.settings
        VStack(spacing: 0) {
            if store.liveSegments.isEmpty && !store.liveActive {
                idle
            } else {
                transcript
            }
        }
        .navigationTitle("实时转写")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $settings.liveTidy) { Label("去语气词", systemImage: "wand.and.stars") }
                    .help("在字幕里去掉「呃」「嗯」和结巴重复")
                Button("字小一点", systemImage: "textformat.size.smaller") { settings.liveFontSize = max(14, settings.liveFontSize - 2) }
                Button("字大一点", systemImage: "textformat.size.larger") { settings.liveFontSize = min(48, settings.liveFontSize + 2) }
                Button("拷贝全部", systemImage: "doc.on.doc") { copy(store.liveSegments.map { store.settings.liveTidy ? stripFillers($0.text) : $0.text }.joined(separator: "\n")) }
                    .disabled(store.liveSegments.isEmpty)
            }
        }
    }

    private var subtitle: String {
        if store.recState == .paused { return "已暂停" }
        if store.liveActive { return "正在录音" }
        return store.liveSegments.isEmpty ? "" : "已结束，共 \(store.liveSegments.count) 段"
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("边录边出字").font(.title2.bold())
            Text("开始录音后，录音豆听到的话会一段一段出现在这里。\n适合开会、访谈时投在屏幕上。录音结束后，完整的录音还会再整体转写、整理成纪要。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Toggle("录音时自动实时转写", isOn: Bindable(store.settings).liveTranscribe).toggleStyle(.switch).fixedSize()
            if let note = store.liveNote { Text(note).font(.callout).foregroundStyle(Theme.amber) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: store.settings.liveFontSize * 0.7) {
                    ForEach(store.liveSegments) { seg in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(clock(seg.start)).font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                                .frame(width: 48, alignment: .trailing)
                            Text(store.settings.liveTidy ? stripFillers(seg.text) : seg.text)
                                .font(.system(size: store.settings.liveFontSize, weight: .medium))
                                .lineSpacing(store.settings.liveFontSize * 0.35)
                                .textSelection(.enabled)
                                .foregroundStyle(seg.id == store.liveSegments.last?.id && store.liveActive ? .primary : .secondary)
                        }
                        .id(seg.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if store.liveActive {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: store.livePending > 0)
                                .foregroundStyle(Theme.rec)
                            Text(store.recState == .paused ? "已暂停" : (store.liveSegments.isEmpty && store.livePending == 0 ? "等录音豆把声音传过来…" : "在听…"))
                                .foregroundStyle(.secondary)
                        }
                        .font(.title3).padding(.leading, 64).id("tail")
                    } else if !store.liveSegments.isEmpty {
                        Text("录音已结束。完整录音下载后会再整体转写并整理成纪要，在「全部录音」里查看。")
                            .font(.callout).foregroundStyle(.secondary).padding(.leading, 64).id("tail")
                    }
                }
                .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 110)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.25), value: store.liveSegments.count)
            }
            .onChange(of: store.liveSegments.count) { withAnimation { proxy.scrollTo("tail", anchor: .bottom) } }
            .onChange(of: store.liveActive) { withAnimation { proxy.scrollTo("tail", anchor: .bottom) } }
        }
    }
}
