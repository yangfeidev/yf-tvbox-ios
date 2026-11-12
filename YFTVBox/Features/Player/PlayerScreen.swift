import SwiftUI
import UIKit

/**
 播放页。

 布局沿用 Android 版的控制层思路：画面全屏铺底，控制浮层在 4 秒无操作后自动隐藏，
 点击画面切换显隐、双击播放/暂停。

 与 Android 的差别只有一处：这里只有 HLS / MP4 能播，
 遇到 .flv / .mkv / .ts 会给出明确提示，并提供「换一条线路」而不是让用户干等。
 */
struct PlayerScreen: View {

    @State private var session: PlaybackSession
    @State private var model = PlaybackModel()
    @State private var controlsVisible = true
    @State private var showEpisodes = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var dragStart: Double?
    @State private var dragTarget: Double?
    @State private var draggingSeek = false
    @State private var seekPreviewTask: Task<Void, Never>?
    @State private var autoHideTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?
    @State private var attemptedSources: Set<Int> = []
    @State private var requestedLandscape = false
    @State private var holdSeekTask: Task<Void, Never>?
    @State private var backgroundPauseTask: Task<Void, Never>?
    @AppStorage("pictureInPictureEnabled") private var pictureInPictureEnabled = true

    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    init(session: PlaybackSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        ZStack {
            XColors.videoBackground.ignoresSafeArea()
            GeometryReader { geometry in
                PlayerSurface(model: model, onHold: { position, width in
                    guard !session.isLive, model.failureMessage == nil, model.duration > 0 else { return }
                    holdSeekTask?.cancel()
                    let delta: Double = position < width / 2 ? -10 : 10
                    holdSeekTask = Task { @MainActor in
                        while !Task.isCancelled {
                            model.skip(delta)
                            saveProgress()
                            revealControls()
                            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                        }
                    }
                }, onHoldEnd: { holdSeekTask?.cancel(); holdSeekTask = nil })
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.togglePlay()
                        revealControls()
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                        if controlsVisible { scheduleAutoHide() } else { autoHideTask?.cancel() }
                    }
                    .gesture(DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            guard !session.isLive, model.failureMessage == nil, model.duration > 0,
                                  abs(value.translation.width) > abs(value.translation.height) else { return }
                            if !draggingSeek {
                                draggingSeek = true
                                seekPreviewTask?.cancel()
                                dragStart = model.currentTime
                                autoHideTask?.cancel()
                            }
                            dragTarget = swipeSeekTarget(start: dragStart ?? 0, translation: value.translation.width, width: geometry.size.width, duration: model.duration)
                        }
                        .onEnded { _ in
                            if let target = dragTarget, model.duration > 0 {
                                model.seek(toProgress: target / model.duration)
                                saveProgress()
                                revealControls()
                            }
                            draggingSeek = false
                            seekPreviewTask?.cancel()
                            seekPreviewTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_300_000_000)
                                guard !Task.isCancelled else { return }
                                dragStart = nil; dragTarget = nil
                            }
                        })
            }.ignoresSafeArea()

            if controlsVisible, model.failureMessage == nil {
                controlLayer.transition(.opacity)
            }

            if let target = dragTarget, let start = dragStart {
                VStack(spacing: 8) {
                    let delta = Int(target - start)
                    Text(delta >= 0 ? "快进 +\(delta)秒" : "快退 \(-delta)秒")
                        .font(XFont.title()).foregroundStyle(XColors.textPrimary)
                    Text("\(format(target)) / \(format(model.duration))")
                        .font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary).monospacedDigit()
                }
                .padding(20).background(XColors.scrim, in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }

            // 失败态必须在控制层之上：否则错误文案会被播放/快进按钮压住，根本看不清
            if let message = model.failureMessage {
                failureView(message)
                // 失败时控制层整块隐藏，但返回必须留着——否则播放页成了死胡同
                VStack {
                    topBar
                    Spacer()
                    HStack {
                        Spacer()
                        orientationButton
                    }
                    .padding(.horizontal, XSpacing.lg)
                    .padding(.bottom, XSpacing.lg)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // 上一集可能是从列表中直接点进来的，补齐副标题
            if session.subtitle.isEmpty, let episode = session.currentEpisode {
                session.subtitle = episode.name
            }
            attemptedSources = [session.sourceIndex]
            loadEpisode()
            scheduleAutoHide()
        }
        .onDisappear {
            autoHideTask?.cancel()
            seekPreviewTask?.cancel()
            loadTask?.cancel()
            holdSeekTask?.cancel()
            backgroundPauseTask?.cancel()
            saveProgress()
            model.invalidate()
            if requestedLandscape { requestOrientation(.portrait) }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                if model.isPlaying { saveProgress() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
            backgroundPauseTask?.cancel()
            if phase == .active {
                model.resumeFromBackground()
            } else if phase == .background {
                if !pictureInPictureEnabled {
                    model.suspendForBackground()
                } else {
                    backgroundPauseTask = Task { @MainActor in
                        // Give the system time to complete an automatic PiP transition.
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                        if !model.pictureInPictureActive { saveProgress(); model.suspendForBackground() }
                    }
                }
            }
        }
        .onChange(of: pictureInPictureEnabled) { _, enabled in model.setPictureInPictureEnabled(enabled) }
        .onChange(of: model.pictureInPictureActive) { _, active in
            if !active && scenePhase == .background { saveProgress(); model.suspendForBackground() }
        }
        .onChange(of: model.status) { _, newValue in
            switch newValue {
            case .ended:
                saveProgress(finished: true)
                advanceToNextEpisode()
            case .paused:
                saveProgress()
                scheduleAutoHide()
            case .playing:
                scheduleAutoHide()
            case .failed:
                switchToNextSource(automatically: true)
            default:
                break
            }
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
            .ignoresSafeArea().allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: XSpacing.md) {
            Button {
                if requestedLandscape || currentScene?.interfaceOrientation.isLandscape == true {
                    requestedLandscape = false
                    requestOrientation(.portrait)
                    revealControls()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(XColors.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(XColors.surface.opacity(0.7), in: Circle())
            }
            .accessibilityIdentifier("player-back")

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
            if pictureInPictureEnabled && model.pictureInPicturePossible {
                Button { model.startPictureInPicture() } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 20))
                        .foregroundStyle(XColors.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("进入画中画")
            }
        }
        .padding(.horizontal, XSpacing.lg)
        .padding(.top, XSpacing.sm)
    }

    private var orientationButton: some View {
        Button {
            requestedLandscape = !(currentScene?.interfaceOrientation.isLandscape ?? requestedLandscape)
            requestOrientation(requestedLandscape ? .landscapeRight : .portrait)
            revealControls()
        } label: {
            Label(requestedLandscape ? "竖屏" : "横屏", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(XFont.bodySmall())
                .foregroundStyle(XColors.textPrimary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("player-orientation")
    }

    private var centerControls: some View {
        HStack(spacing: 48) {
            Button { model.skip(-10); saveProgress() } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 26))
                    .foregroundStyle(XColors.textPrimary)
            }

            Button { model.togglePlay() } label: {
                ZStack {
                    Circle().fill(XColors.accent)
                    if model.status == .buffering {
                        ProgressView()
                            .tint(XColors.onAccent)
                            .scaleEffect(1.1)
                    } else {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(XColors.onAccent)
                    }
                }
                .frame(width: 64, height: 64)
            }

            Button { model.skip(10); saveProgress() } label: {
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
                    Text(format(displayTime))
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                        .monospacedDigit()

                    FineSeekBar(
                        value: Binding(
                            get: { scrubbing ? scrubValue : model.progress },
                            set: { scrubValue = $0 }
                        ),
                        enabled: model.duration > 0 && model.failureMessage == nil,
                        onEditingChanged: { editing in
                            if editing {
                                scrubbing = true
                                autoHideTask?.cancel()
                            } else {
                                scrubbing = false
                                model.seek(toProgress: scrubValue)
                                saveProgress()
                                scheduleAutoHide()
                            }
                        }
                    )

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

                if !session.isLive {
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
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
                }

                Spacer(minLength: XSpacing.sm)
                orientationButton
            }
        }
        .padding(.horizontal, XSpacing.lg)
        .padding(.bottom, XSpacing.lg)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: XSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(XColors.danger)
            Text(message)
                .font(XFont.body())
                .foregroundStyle(XColors.textPrimary)
                .multilineTextAlignment(.center)
            Text("部分 .flv / .mkv / .ts 源在 iOS 上无法解码。换一条线路通常能解决。")
                .font(XFont.caption())
                .foregroundStyle(XColors.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: XSpacing.md) {
                Button("重试") {
                    attemptedSources = [session.sourceIndex]
                    loadEpisode()
                }
                    .buttonStyle(.bordered)
                    .tint(XColors.textSecondary)

                if hasAnotherSource {
                    Button("换一条线路") { switchToNextSource(automatically: false) }
                        .buttonStyle(.borderedProminent)
                        .tint(XColors.accent)
                }
            }
            .padding(.top, XSpacing.sm)
        }
        .padding(XSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(XColors.videoBackground.opacity(0.92).ignoresSafeArea())
    }

    // MARK: - 派生

    private var displayTime: Double {
        scrubbing ? model.duration * scrubValue : model.currentTime
    }

    private var hasAnotherSource: Bool {
        session.sources.count > 1
    }

    // MARK: - 行为

    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleAutoHide()
    }

    private func switchEpisode(sourceIndex: Int, episodeIndex: Int) {
        let matchingIndex = session.sources.indices.contains(sourceIndex)
            ? session.currentEpisode.flatMap {
                matchingEpisodeIndex(name: $0.name, index: session.episodeIndex, in: session.sources[sourceIndex])
            } : nil
        let sameEpisode = sourceIndex != session.sourceIndex && matchingIndex == episodeIndex
        let fraction = sameEpisode ? (model.duration > 0 ? model.progress : session.resumeFraction) : 0
        if model.status != .ended { saveProgress() }
        attemptedSources = [sourceIndex]
        session.sourceIndex = sourceIndex
        session.episodeIndex = episodeIndex
        session.resumeFraction = fraction
        session.subtitle = session.currentEpisode?.name ?? ""
        loadEpisode()
        revealControls()
    }

    private func loadEpisode() {
        loadTask?.cancel()
        model.prepareForLoad()
        let requested = session
        loadTask = Task { @MainActor in
            do {
                // 先展示加载状态，让连续的格式预检失败也能触发下一次换线。
                try await Task.sleep(nanoseconds: 150_000_000)
                var resolved = requested
                if let site = requested.librarySite, site.type == 4,
                   let episode = requested.currentEpisode {
                    let playback = try await VodApi.resolvePlayback(
                        site: site, flag: requested.currentSourceName, id: episode.url
                    )
                    guard !Task.isCancelled else { return }
                    resolved.sources[resolved.sourceIndex].episodes[resolved.episodeIndex].url = playback.url
                    resolved.headers = playback.headers
                }
                guard !Task.isCancelled else { return }
                model.load(session: resolved)
            } catch {
                guard !Task.isCancelled, !Http.isCancellation(error) else { return }
                model.fail(error.localizedDescription)
            }
        }
    }

    /// 播完自动下一集；已是最后一集就停在结束态
    private func advanceToNextEpisode() {
        guard !session.isLive, session.sources.indices.contains(session.sourceIndex) else { return }
        let episodes = session.sources[session.sourceIndex].episodes
        guard session.episodeIndex + 1 < episodes.count else {
            revealControls()
            return
        }
        switchEpisode(sourceIndex: session.sourceIndex, episodeIndex: session.episodeIndex + 1)
    }

    /// 依次尝试包含同一集的线路，每轮每条只尝试一次。
    private func switchToNextSource(automatically: Bool) {
        guard !session.isLive, let current = session.currentEpisode else { return }
        if !automatically { attemptedSources = [session.sourceIndex] }
        guard let next = nextPlaybackSource(sources: session.sources, current: session.sourceIndex,
                                            episodeName: current.name, episodeIndex: session.episodeIndex,
                                            attempted: attemptedSources) else { return }
        let fraction = model.duration > 0 ? model.progress : session.resumeFraction
        saveProgress()
        attemptedSources.insert(next.source)
        session.sourceIndex = next.source
        session.episodeIndex = next.episode
        session.resumeFraction = fraction
        session.subtitle = session.currentEpisode?.name ?? ""
        loadEpisode()
        revealControls()
    }

    private func requestOrientation(_ orientation: UIInterfaceOrientationMask) {
        currentScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }

    private var currentScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
    }

    private func saveProgress(finished: Bool = false) {
        guard !session.isLive,
              let item = session.libraryItem,
              let site = session.librarySite,
              let episode = session.currentEpisode else { return }

        let progress: Float
        if finished {
            progress = 1
        } else if let current = model.progressForSaving {
            progress = current
        } else {
            return
        }
        app.recordHistory(
            item: item,
            site: site,
            sourceName: session.currentSourceName,
            episodeName: episode.name,
            progress: progress
        )
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard controlsVisible else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, model.isPlaying, !scrubbing, !draggingSeek else { return }
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

/// The visible track stays slim while the full 32-point area accepts touches.
private struct FineSeekBar: View {
    @Binding var value: Double
    let enabled: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 10, 0)
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(XColors.textTertiary.opacity(0.45)).frame(width: width, height: 3).offset(x: 5)
                Capsule().fill(XColors.accent).frame(width: width * fraction, height: 3).offset(x: 5)
                Circle().fill(XColors.accent).frame(width: 10, height: 10).offset(x: width * fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard enabled, width > 0 else { return }
                if !editing { editing = true; onEditingChanged(true) }
                value = min(max((gesture.location.x - 5) / width, 0), 1)
            }.onEnded { _ in
                guard editing else { return }
                editing = false
                onEditingChanged(false)
            })
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int(fraction * 100))%")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                switch direction {
                case .increment: value = min(value + 0.05, 1)
                case .decrement: value = max(value - 0.05, 0)
                @unknown default: return
                }
                onEditingChanged(false)
            }
        }
        .frame(height: 32)
        .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: - 画面容器

private struct PlayerSurface: UIViewRepresentable {
    let model: PlaybackModel
    let onHold: (CGFloat, CGFloat) -> Void
    let onHoldEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHold: onHold, onHoldEnd: onHoldEnd) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.5
        hold.cancelsTouchesInView = false
        hold.delegate = context.coordinator
        container.addGestureRecognizer(hold)
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

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onHold = onHold
        context.coordinator.onHoldEnd = onHoldEnd
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onHold: (CGFloat, CGFloat) -> Void
        var onHoldEnd: () -> Void
        init(onHold: @escaping (CGFloat, CGFloat) -> Void, onHoldEnd: @escaping () -> Void) {
            self.onHold = onHold
            self.onHoldEnd = onHoldEnd
        }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began: onHold(recognizer.location(in: view).x, view.bounds.width)
            case .ended, .cancelled, .failed: onHoldEnd()
            default: break
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
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
                                    .background(
                                        selected ? XColors.accent : XColors.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: XRadii.sm)
                                    )
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

/// Matches Android's full-width swipe range and clamps to the media duration.
func swipeSeekTarget(start: Double, translation: CGFloat, width: CGFloat, duration: Double) -> Double {
    guard width > 0, duration > 0, duration.isFinite else { return max(start, 0) }
    let range = min(max(duration / 3, 60), 600)
    return min(max(start + Double(translation / width) * range, 0), duration)
}
