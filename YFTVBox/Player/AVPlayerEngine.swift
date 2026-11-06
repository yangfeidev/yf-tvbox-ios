import AVFoundation
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
                guard let self else { return }
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
            Task { @MainActor in self?.onStatus?(.ended) }
        }
    }

    func play() {
        player.play()
        onStatus?(.playing)
    }

    func pause() {
        player.pause()
        onStatus?(.paused)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Float) {
        player.rate = rate
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
        return view
    }

    func invalidate() {
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

    var isPlaying: Bool { status == .playing }
    var isLive: Bool { duration <= 0 }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var failureMessage: String? {
        if case let .failed(message) = status { return message }
        return nil
    }

    @ObservationIgnored private var engine: PlayerEngine
    @ObservationIgnored private var lastURLLoaded: String?
    /// 等拿到真实时长后再按比例跳转，避免对直播（时长无穷）做无意义 seek
    @ObservationIgnored private var pendingFraction: Double?

    init(engine: PlayerEngine? = nil) {
        // 默认参数不能直接写 AVPlayerEngine()：默认值在非隔离上下文求值，
        // 而本类与引擎都是 @MainActor。这里在初始化体内构造，等价且不会报隔离错误。
        let resolved = engine ?? AVPlayerEngine()
        self.engine = resolved
        resolved.onStatus = { [weak self] status in
            self?.status = status
        }
        resolved.onProgress = { [weak self] time, duration in
            guard let self else { return }
            self.currentTime = time
            self.duration = duration
            if let fraction = self.pendingFraction, duration > 1 {
                self.pendingFraction = nil
                self.engine.seek(to: duration * fraction)
            }
        }
    }

    func load(session: PlaybackSession) {
        guard let episode = session.currentEpisode else {
            status = .failed("这一集没有可用的播放地址")
            return
        }
        lastURLLoaded = episode.url
        currentTime = 0
        duration = 0
        status = .buffering
        pendingFraction = (session.resumeFraction > 0.02 && session.resumeFraction < 0.98)
            ? session.resumeFraction
            : nil
        engine.load(url: episode.url, headers: session.headers, startAt: 0)
        engine.play()
    }

    func togglePlay() {
        if isPlaying { engine.pause() } else { engine.play() }
    }

    func pauseIfPlaying() {
        if isPlaying { engine.pause() }
    }

    func skip(_ delta: Double) {
        let target = currentTime + delta
        engine.seek(to: max(0, duration > 0 ? min(target, duration - 1) : target))
        currentTime = max(0, target)
    }

    func seek(toProgress value: Double) {
        guard duration > 0 else { return }
        engine.seek(to: duration * value)
    }

    func setSpeed(_ value: Float) {
        speed = value
        engine.setRate(value)
    }

    func toggleAspect() {
        aspectFill.toggle()
        engine.setAspectFill(aspectFill)
    }

    func makeSurface() -> UIView { engine.makeSurface() }

    func invalidate() { engine.invalidate() }
}
