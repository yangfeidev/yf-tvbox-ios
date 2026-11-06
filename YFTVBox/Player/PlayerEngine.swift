import AVFoundation
import UIKit

/**
 播放内核抽象。

 为什么要这一层：AVPlayer 只吃 mp4 / mov / HLS，源站里大量 .flv / .mkv / .ts / .mpd
 在 iOS 上会直接黑屏。是否引入 VLCKit 取决于实际源的格式构成，
 在没测出比例之前不拍板——UI 只依赖这个协议，换内核只改一处工厂。

 后续接 VLCKit 时新增一个 `VLCPlayerEngine: PlayerEngine` 即可，
 播放页、进度、手势、续播逻辑一行都不用动。
 */
enum PlayerEngineStatus: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case ended
    case failed(String)
}

protocol PlayerEngine: AnyObject {
    var onStatus: ((PlayerEngineStatus) -> Void)? { get set }
    var onProgress: ((_ time: Double, _ duration: Double) -> Void)? { get set }

    func load(url: String, headers: [String: String], startAt: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Float)
    func setAspectFill(_ fill: Bool)
    /// 返回可直接塞进 SwiftUI 的画面视图（AVPlayerLayer / VLC 的 video view）
    func makeSurface() -> UIView
    func invalidate()
}

/// 一次播放会话：点播的某一集，或一个直播频道。
struct PlaybackSession: Identifiable {
    var id = UUID()
    var title: String
    var subtitle: String = ""
    var sources: [PlaySource]
    var sourceIndex: Int
    var episodeIndex: Int
    var headers: [String: String] = [:]
    /// 直播为 true：不显示进度条、不记历史
    var isLive: Bool = false
    /// 用于写历史；直播时传 nil
    var libraryItem: MediaItem?
    var librarySite: Site?
    /// 续播位置（0~1）。为什么不存秒：历史里只有比例，时长要等播放器就绪才知道
    var resumeFraction: Double = 0

    var currentEpisode: Episode? {
        guard sources.indices.contains(sourceIndex) else { return nil }
        let episodes = sources[sourceIndex].episodes
        guard episodes.indices.contains(episodeIndex) else { return nil }
        return episodes[episodeIndex]
    }

    var currentSourceName: String {
        sources.indices.contains(sourceIndex) ? sources[sourceIndex].name : ""
    }
}
