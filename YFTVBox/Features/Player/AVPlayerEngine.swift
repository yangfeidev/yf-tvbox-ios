import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

/**
 AVPlayer 版播放内核。

 覆盖 HLS（m3u8）与 mp4 / mov，也就是源站里绝大多数可播内容。
 自定义请求头通过 AVURLAsset 的 HTTPHeaderFields 选项透传——
 这是 App Store 上大量播放器在用的事实标准写法，虽然 Apple 没公开文档。
 */
@MainActor
final class AVPlayerEngine: NSObject, PlayerEngine {

    var onStatus: ((PlayerEngineStatus) -> Void)?
    var onProgress: ((Double, Double) -> Void)?

    private let player = AVPlayer()
    private var surface: PlayerLayerView?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pendingStart: Double = 0
    private var didApplyStart = false
    private var pictureInPictureController: AVPictureInPictureController?
    var onPictureInPictureChange: ((Bool) -> Void)?
    var onPictureInPictureAvailability: ((Bool) -> Void)?
    private var pipObservation: NSKeyValueObservation?

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        addTimeObserver()
        observeTimeControl()
    }

    // MARK: - PlayerEngine

    func load(url: String, headers: [String: String], startAt: Double) {
        guard let requestURL = URL(string: url) else {
            onStatus?(.failed("播放地址不合法"))
            return
        }

        removeItemObservers()
        pendingStart = startAt
        didApplyStart = false

        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: requestURL)
        } else {
            asset = AVURLAsset(url: requestURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        player.replaceCurrentItem(with: item)
        surface?.playerLayer.player = player

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.applyPendingStartIfNeeded()
                    self.onStatus?(self.player.timeControlStatus == .playing ? .playing : .paused)
                    self.pushProgress()
                case .failed:
                    let message = item.error?.localizedDescription ?? "无法播放该地址"
                    self.onStatus?(.failed(message))
                default:
                    self.onStatus?(.buffering)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.onStatus?(.ended)
            }
        }
    }

    func play() {
        player.playImmediately(atRate: desiredRate)
    }

    func pause() {
        player.pause()
        onStatus?(.paused)
    }

    func stop() {
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func currentPosition() -> Double? {
        let time = player.currentTime().seconds
        return time.isFinite && time >= 0 ? time : nil
    }

    private var desiredRate: Float = 1

    func setRate(_ rate: Float) {
        desiredRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    func setAspectFill(_ fill: Bool) {
        surface?.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func makeSurface() -> UIView {
        if let surface { return surface }
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.backgroundColor = UIColor.black.cgColor
        surface = view
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let controller = AVPictureInPictureController(playerLayer: view.playerLayer) {
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = UserDefaults.standard.object(forKey: "pictureInPictureEnabled") as? Bool ?? true
            pictureInPictureController = controller
            pipObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                Task { @MainActor in self?.onPictureInPictureAvailability?(controller.isPictureInPicturePossible) }
            }
        }
        return view
    }

    func setPictureInPictureEnabled(_ enabled: Bool) {
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func startPictureInPicture() {
        guard let controller = pictureInPictureController, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    func invalidate() {
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController?.delegate = nil
        pipObservation = nil
        pictureInPictureController = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - 内部

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushProgress() }
        }
    }

    private func observeTimeControl() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing: self.onStatus?(.playing)
                case .waitingToPlayAtSpecifiedRate: self.onStatus?(.buffering)
                case .paused: self.onStatus?(.paused)
                @unknown default: break
                }
            }
        }
    }

    private func pushProgress() {
        let time = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        onProgress?(time.isFinite ? time : 0, duration.isFinite ? duration : 0)
    }

    private func applyPendingStartIfNeeded() {
        guard !didApplyStart, pendingStart > 1 else { return }
        didApplyStart = true
        seek(to: pendingStart)
    }

    private func removeItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

extension AVPlayerEngine: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onPictureInPictureChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onPictureInPictureChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

/// 用 AVPlayerLayer 当 backing layer，省掉一层 UIView 嵌套。
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已固定，这里的强转是安全的
        layer as! AVPlayerLayer
    }
}

/**
 播放页的可观测包装。

 视图只认这个对象：状态、进度、错误都在这里，
 换内核（VLCKit）时它一行不用改。
 */
@Observable
@MainActor
final class PlaybackModel {

    var status: PlayerEngineStatus = .idle
    var currentTime: Double = 0
    var duration: Double = 0
    var aspectFill = false
    var speed: Float = 1.0
    var pictureInPictureActive = false
    var pictureInPicturePossible = false

    var isPlaying: Bool { status == .playing }
    /// 直播与否由会话决定，不能看 duration：
    /// 点播刚起播、时长还没解析出来时 duration 也是 0，会被误判成直播（控制层显示成"直播"）
    var isLive: Bool { sessionIsLive }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var failureMessage: String? {
        if case let .failed(message) = status { return message }
        return nil
    }

    @ObservationIgnored private var engine: PlayerEngine
    /// 等拿到真实时长后再按比例跳转，避免对直播（时长无穷）做无意义 seek
    @ObservationIgnored private var pendingFraction: Double?
    @ObservationIgnored private var pendingSeekTarget: Double?
    @ObservationIgnored private var restoringProgress = false
    @ObservationIgnored private var hasPlaybackProgress = false
    @ObservationIgnored private var playbackRequested = true
    @ObservationIgnored private var suspendedForBackground = false
    @ObservationIgnored private var nowPlayingActive = false
    @ObservationIgnored private var sessionIsLive = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    init(engine: PlayerEngine? = nil) {
        // 默认参数不能直接写 AVPlayerEngine()：默认值在非隔离上下文求值，
        // 而本类与引擎都是 @MainActor。这里在初始化体内构造，等价且不会报隔离错误。
        let resolved = engine ?? AVPlayerEngine()
        self.engine = resolved
        if let player = resolved as? AVPlayerEngine {
            player.onPictureInPictureChange = { [weak self] active in self?.pictureInPictureActive = active }
            player.onPictureInPictureAvailability = { [weak self] possible in self?.pictureInPicturePossible = possible }
        }
        resolved.onStatus = { [weak self] status in
            guard let self else { return }
            if case .failed = self.status { return }
            self.status = status
            if case .failed = status { self.cancelWatchdog() }
            if status == .ended { self.cancelWatchdog() }
            self.refreshNowPlayingRate()
        }
        resolved.onProgress = { [weak self] time, duration in
            guard let self else { return }
            self.duration = duration
            if let fraction = self.pendingFraction, duration > 1 {
                let target = duration * fraction
                self.pendingFraction = nil
                self.pendingSeekTarget = target
                self.restoringProgress = true
                self.currentTime = target
                self.engine.seek(to: target)
                return
            }
            if let target = self.pendingSeekTarget {
                let tolerance = min(2, max(target / 2, 0.05))
                guard abs(time - target) < tolerance else { return }
                self.pendingSeekTarget = nil
                self.restoringProgress = false
            }
            self.currentTime = time
            if time > 0 { self.hasPlaybackProgress = true }
            // 只要有进度就说明已经出画面了，看门狗立即失效
            if time > 0.5 { self.cancelWatchdog() }
            self.refreshNowPlayingTime()
        }
    }

    func prepareForLoad() {
        cancelWatchdog()
        engine.stop()
        pendingFraction = nil
        pendingSeekTarget = nil
        restoringProgress = false
        hasPlaybackProgress = false
        currentTime = 0
        duration = 0
        status = .buffering
    }

    func fail(_ message: String) {
        cancelWatchdog()
        engine.pause()
        status = .failed(message)
    }

    func load(session: PlaybackSession) {
        prepareForLoad()
        guard let episode = session.currentEpisode else {
            status = .failed("这一集没有可用的播放地址")
            return
        }

        // 直播标记要在格式预检之前落位：否则直播包是 mkv 时会被当成点播，显示出 00:00 的进度条
        sessionIsLive = session.isLive

        // 编码格式先过一遍，别让用户对着转圈等 15 秒
        if let reason = PlaybackFormat.unsupportedReason(for: episode.url) {
            status = .failed(reason)
            return
        }

        currentTime = 0
        duration = 0
        status = .buffering
        pendingFraction = (session.resumeFraction > 0 && session.resumeFraction < 0.98)
            ? session.resumeFraction
            : nil

        activateAudioSession()
        updateNowPlaying(session: session)

        engine.setRate(speed)
        engine.load(url: episode.url, headers: session.headers, startAt: 0)
        if !suspendedForBackground {
            playbackRequested = true
            engine.play()
            startBufferingWatchdog()
        }
    }

    /**
     起播看门狗。
     AVPlayer 对失效源经常既不报错也不出画面，一直停在 buffering；
     设个上限，30 秒还没有任何进展就当作失败，把「换一条线路」的按钮亮出来。
     */
    private func startBufferingWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            // 30 秒：慢速 CDN 首帧经常要 15~20 秒，20 秒会误杀
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            if self.status == .buffering || self.status == .playing {
                self.engine.pause()
                self.status = .failed("加载超时：30 秒没有画面。这个源可能已失效，换一条线路试试")
            }
        }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() { playbackRequested = true; engine.play() }

    func pause() { playbackRequested = false; engine.pause() }

    func suspendForBackground() {
        guard !suspendedForBackground else { return }
        suspendedForBackground = true
        cancelWatchdog()
        engine.pause()
    }

    func resumeFromBackground() {
        guard suspendedForBackground else { return }
        suspendedForBackground = false
        if playbackRequested { engine.play() }
    }

    var progressForSaving: Float? {
        guard pendingFraction == nil, !restoringProgress, hasPlaybackProgress, duration > 0 else { return nil }
        let time = pendingSeekTarget ?? engine.currentPosition() ?? currentTime
        guard time.isFinite else { return nil }
        return Float(min(max(time / duration, 0), 1))
    }

    func skip(_ delta: Double) {
        let target = currentTime + delta
        let clamped = max(0, duration > 0 ? min(target, duration - 1) : target)
        engine.seek(to: clamped)
        currentTime = clamped
        pendingSeekTarget = clamped
        restoringProgress = false
        pendingFraction = nil
        hasPlaybackProgress = true
    }

    func seek(toProgress value: Double) {
        guard duration > 0 else { return }
        let target = duration * min(max(value, 0), 1)
        engine.seek(to: target)
        currentTime = target
        pendingSeekTarget = target
        restoringProgress = false
        pendingFraction = nil
        hasPlaybackProgress = true
    }

    func setSpeed(_ value: Float) {
        speed = value
        engine.setRate(value)
        refreshNowPlayingRate()
    }

    func toggleAspect() {
        aspectFill.toggle()
        engine.setAspectFill(aspectFill)
    }

    func makeSurface() -> UIView { engine.makeSurface() }

    func setPictureInPictureEnabled(_ enabled: Bool) {
        (engine as? AVPlayerEngine)?.setPictureInPictureEnabled(enabled)
    }

    func startPictureInPicture() { (engine as? AVPlayerEngine)?.startPictureInPicture() }

    func invalidate() {
        cancelWatchdog()
        engine.invalidate()
        deactivateNowPlaying()
    }

    // MARK: - 音频会话与锁屏信息

    /**
     视频 App 用 .playback：静音开关拨下也有声音，这是用户预期。
     后台音频能力用于系统画中画。
     */
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    private func updateNowPlaying(session: PlaybackSession) {
        let center = MPNowPlayingInfoCenter.default()
        guard !session.isLive else {
            center.nowPlayingInfo = nil
            nowPlayingActive = false
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = session.title
        if !session.subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = session.subtitle
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        center.nowPlayingInfo = info
        nowPlayingActive = true
        registerRemoteCommands()
    }

    private func refreshNowPlayingTime() {
        guard nowPlayingActive, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingRate() {
        guard nowPlayingActive, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speed) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
    }

    private func deactivateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlayingActive = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
