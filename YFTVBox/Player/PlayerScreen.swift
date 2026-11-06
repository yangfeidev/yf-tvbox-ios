import SwiftUI
import UIKit

/**
 播放页。

 布局沿用 Android 版的控制层思路：画面全屏铺底，控制层浮在上面，
 4 秒无操作自动隐藏；点击画面切换显隐。
 与 Android 的差别只有一处——这里只有 HLS / MP4 能播，
 遇到 .flv / .mkv / .ts 会明确提示而不是黑屏干等。
 */
struct PlayerScreen: View {

    @State private var session: PlaybackSession
    @State private var model = PlaybackModel()
    @State private var controlsVisible = true
    @State private var showEpisodes = false
    @State private var showSpeedMenu = false

    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var app

    init(session: PlaybackSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        ZStack {
            XColors.videoBackground.ignoresSafeArea()
            PlayerSurface(model: model).ignoresSafeArea()

            if case .failed = model.status {
                failureView
            }

            if model.status == .buffering {
                ProgressView().tint(XColors.accent).scaleEffect(1.4)
            }

            if controlsVisible {
                controlLayer.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
            if controlsVisible { scheduleAutoHide() }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.load(session: session)
            scheduleAutoHide()
        }
        .onDisappear {
            saveProgress()
            model.invalidate()
        }
        .onChange(of: model.status) { _, newValue in
            if newValue == .ended { saveProgress(finished: true) }
            scheduleAutoHide()
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodePickerSheet(session: session) { sourceIndex, episodeIndex in
                switchEpisode(sourceIndex: sourceIndex, episodeIndex: episodeIndex)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(XColors.surface)
        }
    }

    // MARK: - 控制层

    private var controlLayer: some View {
        VStack {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .background(
            LinearGradient(
                colors: [XColors.videoBackground.opacity(0.85), .clear, XColors.videoBackground.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack(spacing: XSpacing.md) {
            Button {
                saveProgress()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(XColors.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(XColors.surface.opacity(0.7), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(XFont.title())
                    .foregroundStyle(XColors.textPrimary)
                    .lineLimit(1)
                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, XSpacing.lg)
        .padding(.top, XSpacing.sm)
    }

    private var centerControls: some View {
        HStack(spacing: 48) {
            Button { model.skip(-10) } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 26))
                    .foregroundStyle(XColors.textPrimary)
            }

            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(XColors.onAccent)
                    .frame(width: 64, height: 64)
                    .background(XColors.accent, in: Circle())
            }

            Button { model.skip(10) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 26))
                    .foregroundStyle(XColors.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: XSpacing.sm) {
            if !model.isLive {
                HStack(spacing: XSpacing.md) {
                    Text(format(model.currentTime))
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                        .monospacedDigit()

                    Slider(
                        value: Binding(
                            get: { model.progress },
                            set: { model.seek(toProgress: $0) }
                        ),
                        in: 0...1
                    )
                    .tint(XColors.accent)

                    Text(format(model.duration))
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                        .monospacedDigit()
                }
            } else {
                HStack {
                    Label("直播", systemImage: "dot.radiowaves.left.and.right")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.danger)
                    Spacer()
                }
            }

            HStack(spacing: XSpacing.lg) {
                if !session.sources.isEmpty, !session.isLive {
                    Button { showEpisodes = true } label: {
                        Label("选集", systemImage: "list.bullet.rectangle")
                            .font(XFont.bodySmall())
                            .foregroundStyle(XColors.textPrimary)
                    }
                }

                Button { model.toggleAspect() } label: {
                    Label(model.aspectFill ? "铺满" : "适应", systemImage: "rectangle.arrowtriangle.2.outward")
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textPrimary)
                }

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            model.setSpeed(Float(value))
                        } label: {
                            HStack {
                                Text("\(value, specifier: "%g")x")
                                if model.speed == Float(value) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label("\(String(format: "%g", model.speed))x", systemImage: "speedometer")
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textPrimary)
                }

                Spacer()
            }
        }
        .padding(.horizontal, XSpacing.lg)
        .padding(.bottom, XSpacing.lg)
    }

    private var failureView: some View {
        VStack(spacing: XSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(XColors.danger)
            Text(model.failureMessage ?? "播放失败")
                .font(XFont.body())
                .foregroundStyle(XColors.textPrimary)
                .multilineTextAlignment(.center)
            Text("部分 .flv / .mkv / .ts 源在 iOS 上无法解码，换一条线路试试。")
                .font(XFont.caption())
                .foregroundStyle(XColors.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { model.load(session: session) }
                .buttonStyle(.borderedProminent)
                .tint(XColors.accent)
        }
        .padding(XSpacing.xl)
    }

    // MARK: - 行为

    private func switchEpisode(sourceIndex: Int, episodeIndex: Int) {
        saveProgress()
        session.sourceIndex = sourceIndex
        session.episodeIndex = episodeIndex
        session.resumeFraction = 0
        if let episode = session.currentEpisode {
            session.subtitle = episode.name
        }
        model.load(session: session)
        scheduleAutoHide()
    }

    private func saveProgress(finished: Bool = false) {
        guard !session.isLive,
              let item = session.libraryItem,
              let site = session.librarySite,
              let episode = session.currentEpisode else { return }

        // 直播 / 刚打开都不记；看完标记 100%
        let progress: Float
        if finished {
            progress = 1
        } else if model.duration > 0 {
            progress = Float(model.currentTime / model.duration)
        } else {
            return
        }
        guard progress > 0.01 || finished else { return }

        app.recordHistory(
            item: item,
            site: site,
            sourceName: session.currentSourceName,
            episodeName: episode.name,
            progress: progress
        )
    }

    private func scheduleAutoHide() {
        guard controlsVisible else { return }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - 画面容器

private struct PlayerSurface: UIViewRepresentable {
    let model: PlaybackModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let surface = model.makeSurface()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 选集

private struct EpisodePickerSheet: View {
    let session: PlaybackSession
    let onSelect: (Int, Int) -> Void

    @State private var sourceIndex: Int
    @Environment(\.dismiss) private var dismiss

    init(session: PlaybackSession, onSelect: @escaping (Int, Int) -> Void) {
        self.session = session
        self.onSelect = onSelect
        _sourceIndex = State(initialValue: session.sourceIndex)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.sources.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: XSpacing.sm) {
                            ForEach(Array(session.sources.enumerated()), id: \.offset) { index, source in
                                Button {
                                    sourceIndex = index
                                } label: {
                                    Text(source.name)
                                        .font(XFont.bodySmall())
                                        .foregroundStyle(sourceIndex == index ? XColors.onAccent : XColors.textSecondary)
                                        .padding(.horizontal, XSpacing.md)
                                        .padding(.vertical, 6)
                                        .background(
                                            sourceIndex == index ? XColors.accent : XColors.surfaceRaised,
                                            in: Capsule()
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, XSpacing.lg)
                        .padding(.vertical, XSpacing.sm)
                    }
                }

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 84), spacing: XSpacing.sm)],
                        spacing: XSpacing.sm
                    ) {
                        ForEach(Array(session.sources[sourceIndex].episodes.enumerated()), id: \.offset) { index, episode in
                            let selected = sourceIndex == session.sourceIndex && index == session.episodeIndex
                            Button {
                                onSelect(sourceIndex, index)
                                dismiss()
                            } label: {
                                Text(episode.name)
                                    .font(XFont.bodySmall())
                                    .foregroundStyle(selected ? XColors.onAccent : XColors.textPrimary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(selected ? XColors.accent : XColors.surfaceRaised, in: RoundedRectangle(cornerRadius: XRadii.sm))
                            }
                        }
                    }
                    .padding(XSpacing.lg)
                }
            }
            .background(XColors.background)
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
