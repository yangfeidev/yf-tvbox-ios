import Foundation

/**
 数据模型。

 结构（对应 Android 版 `data/model/Models.kt`）：
 - Subscription：用户添加的订阅记录
 - Site：订阅里的单个源站（TVBox JSON 的 sites 数组）
 - WarehouseEntry：多仓订阅里的子仓库
 - LiveSourceEntry：订阅里的 lives 数组，指向外部 m3u / txt
 - MediaItem / MediaDetail / PlaySource / Episode：点播内容
 - Channel / ChannelGroup：直播频道与分组
 - LibraryEntry：收藏与历史

 源站类型：
 - 0 = 苹果CMS XML 接口，可直接请求
 - 1 = 苹果CMS JSON 接口，可直接请求
 - 3 = Spider（jar 内类名），需要 JVM 运行时，iOS 无法支持
 - 4 = 远程 Spider HTTP 接口
 */

struct Subscription: Identifiable, Hashable, Codable {
    var id: String
    var url: String
    var name: String
    var addedAt: Int64
    var updatedAt: Int64?
    var siteCount: Int

    init(id: String, url: String, name: String, addedAt: Int64, updatedAt: Int64? = nil, siteCount: Int = 0) {
        self.id = id
        self.url = url
        self.name = name
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.siteCount = siteCount
    }
}

struct Site: Identifiable, Hashable, Codable {
    var key: String
    var name: String
    var api: String
    var type: Int
    var searchable: Bool
    var quickSearch: Bool
    var ext: String

    var id: String { key }

    init(
        key: String,
        name: String,
        api: String,
        type: Int,
        searchable: Bool = true,
        quickSearch: Bool = false,
        ext: String = ""
    ) {
        self.key = key
        self.name = name
        self.api = api
        self.type = type
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.ext = ext
    }

    /// type 1 / 4 走 JSON，type 0 走 XML
    var isJSONAPI: Bool { type == 1 || type == 4 }

    /// 只有 0 / 1 / 4 且 api 是网址时才可用
    var usable: Bool {
        api.hasPrefix("http") && (type == 0 || type == 1 || type == 4)
    }

    var isSpider: Bool { type == 3 }

    var unavailableReason: String? {
        if usable { return nil }
        if isSpider { return "需要 spider 运行时，iOS 版不支持" }
        if api.trimmingCharacters(in: .whitespaces).isEmpty { return "缺少接口地址" }
        return "未知源类型 type=\(type)"
    }
}

struct WarehouseEntry: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { url }
}

struct LiveSourceEntry: Identifiable, Hashable {
    var name: String
    var url: String
    var group: String = ""
    var id: String { url }
}

struct SubscriptionDocument {
    var sites: [Site] = []
    var warehouse: [WarehouseEntry] = []
    var liveSources: [LiveSourceEntry] = []
    var parses: [String] = []

    var usableSites: [Site] { sites.filter(\.usable) }
    var isWarehouse: Bool { !warehouse.isEmpty }
    /// 因缺少运行时被跳过的源数量，设置页要展示出来
    var skippedCount: Int { sites.count - usableSites.count }
}

struct Category: Identifiable, Hashable {
    var typeId: String
    var name: String
    var parentId: String = ""
    var id: String { typeId }
}

struct MediaItem: Identifiable, Hashable {
    var id: String
    var name: String
    var poster: String = ""
    var remarks: String = ""
    var typeId: String = ""
    var year: String = ""
    var area: String = ""
    var categoryName: String = ""

    var hasPoster: Bool { !poster.isEmpty }
}

struct Episode: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { "\(name)|\(url)" }

    /**
     是否直链。CMS 返回的播放地址可能是网页地址，需要 parses 接口解析；
     当前版本只播直链，非直链在播放器里给出明确提示而不是黑屏。
     */
    var isPlayable: Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http") else { return false }
        return [".m3u8", ".mp4", ".flv", ".mkv", ".ts"].contains { lower.contains($0) }
    }
}

struct PlaySource: Identifiable, Hashable {
    var name: String
    var episodes: [Episode]
    var id: String { name }
}

struct MediaDetail {
    var item: MediaItem
    var content: String = ""
    var actor: String = ""
    var director: String = ""
    var playSources: [PlaySource] = []

    var usableSources: [PlaySource] { playSources.filter { !$0.episodes.isEmpty } }

    var metaLine: String {
        [item.year, item.area, item.categoryName, item.remarks]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct PagedMedia {
    var items: [MediaItem] = []
    var page: Int = 1
    var pageCount: Int = 1
    var total: Int = 0
    var categories: [Category] = []

    var hasMore: Bool { page < pageCount }
}

struct Channel: Identifiable, Hashable {
    var name: String
    var url: String
    var logo: String = ""
    var group: String = "未分组"
    var tvgId: String = ""
    var catchup: String?
    var headers: [String: String] = [:]

    var id: String { "\(name)|\(url)" }
}

struct ChannelGroup: Identifiable, Hashable {
    var name: String
    var channels: [Channel]
    var id: String { name }
}

/// 收藏 / 历史条目
struct LibraryEntry: Identifiable, Hashable, Codable {
    var siteKey: String
    var mediaId: String
    var name: String
    var poster: String = ""
    var remarks: String = ""
    var episodeName: String = ""
    var sourceName: String = ""
    var progress: Float = 0
    var updatedAt: Int64 = 0

    var id: String { uniqueKey }
    var uniqueKey: String { "\(siteKey)::\(mediaId)" }

    func toMediaItem() -> MediaItem {
        MediaItem(
            id: mediaId,
            name: name,
            poster: poster,
            remarks: episodeName.isEmpty ? remarks : episodeName
        )
    }
}

struct ResumeTarget {
    var sourceIndex: Int
    var episodeIndex: Int
    var progress: Float
}

/**
 上次看到哪一集。

 优先按历史里记录过的线路名定位，找不到再跨线路按集名找。
 进度 <2% 或 >98% 视为不需要续播（刚点开 / 已经看完）——
 阈值与播放页的应用条件保持一致，否则会出现"续播按钮在，但播放器不跳"。
 */
func findResumeTarget(sources: [PlaySource], history: LibraryEntry?) -> ResumeTarget? {
    guard let history, !history.episodeName.isEmpty,
          history.progress > 0.02, history.progress < 0.98 else { return nil }

    if !history.sourceName.isEmpty,
       let sourceIndex = sources.firstIndex(where: { $0.name == history.sourceName }),
       let episodeIndex = sources[sourceIndex].episodes.firstIndex(where: { $0.name == history.episodeName }) {
        return ResumeTarget(sourceIndex: sourceIndex, episodeIndex: episodeIndex, progress: history.progress)
    }

    for (sourceIndex, source) in sources.enumerated() {
        if let episodeIndex = source.episodes.firstIndex(where: { $0.name == history.episodeName }) {
            return ResumeTarget(sourceIndex: sourceIndex, episodeIndex: episodeIndex, progress: history.progress)
        }
    }
    return nil
}

struct AppSettings: Codable {
    var autoUpdateOnLaunch: Bool = true
    var autoCheckUpdate: Bool = true
    var activeSubscriptionId: String = ""
    var currentSiteKey: String = ""
    /// 自定义直播源（m3u / txt）。为空时使用订阅里自带的 lives
    var liveUrl: String = ""
    /// 首次启动自动导入内置单仓订阅
    var autoAddDefault: Bool = true

    init() {}

    /**
     手写解码：这几个键都是"后加的"，
     合成解码遇到缺字段会整条失败（用户升级后会丢全部设置），所以逐项带了默认值。
     */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoUpdateOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateOnLaunch) ?? true
        autoCheckUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdate) ?? true
        activeSubscriptionId = try container.decodeIfPresent(String.self, forKey: .activeSubscriptionId) ?? ""
        currentSiteKey = try container.decodeIfPresent(String.self, forKey: .currentSiteKey) ?? ""
        liveUrl = try container.decodeIfPresent(String.self, forKey: .liveUrl) ?? ""
        autoAddDefault = try container.decodeIfPresent(Bool.self, forKey: .autoAddDefault) ?? true
    }
}
