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

@MainActor
protocol PlayerEngine: AnyObject {
    var onStatus: ((PlayerEngineStatus) -> Void)? { get set }
    var onProgress: ((_ time: Double, _ duration: Double) -> Void)? { get set }

    func load(url: String, headers: [String: String], startAt: Double)
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double)
    func setRate(_ rate: Float)
    func setAspectFill(_ fill: Bool)
    /// 返回可直接塞进 SwiftUI 的画面视图（AVPlayerLayer / VLC 的 video view）
    func makeSurface() -> UIView
    func invalidate()
}

/// 一次播放会话：点播的某一集，或一个直播频道。
struct PlaybackSession: Identifiable {    var id = UUID()
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

/// 跨线路优先按集名匹配，再按集数位置匹配；没有对应集时不跳到其他内容。
func matchingEpisodeIndex(name: String, index: Int, in source: PlaySource) -> Int? {
    if let match = source.episodes.firstIndex(where: { $0.name == name }) { return match }
    return source.episodes.indices.contains(index) ? index : nil
}

func nextPlaybackSource(sources: [PlaySource], current: Int, episodeName: String,
                        episodeIndex: Int, attempted: Set<Int>) -> (source: Int, episode: Int)? {
    guard sources.count > 1 else { return nil }
    for offset in 1..<sources.count {
        let index = (current + offset) % sources.count
        guard !attempted.contains(index),
              let episode = matchingEpisodeIndex(name: episodeName, index: episodeIndex, in: sources[index]) else { continue }
        return (index, episode)
    }
    return nil
}

/**
 格式预检。

 AVPlayer 遇到 .flv / .mkv 这类容器不会立刻报错，而是先拉流、再超时，
 用户看到的是长时间转圈。这里提前判断并直接给结论，比等 15 秒友好。
 `.ts` 不拦：少数源的 ts 直链能被系统解出来，交给 AVPlayer 自己试。
 */
enum PlaybackFormat {
    private static let unsupported: [(ext: String, label: String)] = [
        (".flv", "FLV"),
        (".mkv", "MKV"),
        (".avi", "AVI"),
        (".wmv", "WMV"),
        (".rmvb", "RMVB"),
        (".rm", "RM"),
        (".f4v", "F4V"),
        (".mpd", "DASH/MPD"),
    ]

    static func unsupportedReason(for url: String) -> String? {
        let path = URLComponents(string: url)?.path.lowercased() ?? ""
        for item in unsupported where path.hasSuffix(item.ext) {
            return "这是一条 \(item.label) 直链，iOS 系统解码器不支持这种封装格式"
        }
        return nil
    }
}
