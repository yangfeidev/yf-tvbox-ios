import Foundation

/**
 本地持久化。

 对应 Android 版 `data/LocalStore.kt`：
 - 订阅列表、收藏、历史、设置 → UserDefaults（体积小、读频繁）
 - 订阅原文缓存 → Application Support 下的文件（单个订阅 JSON 可达数百 KB）
 - 直播列表缓存 → 文件，用修改时间做 TTL

 缓存目录：`Application Support/feigemedia/subscriptions/<id>.json`
 目的：源站临时不可达时，仍能用上次拉到的配置进入 App，不至于白屏。
 */
final class LocalStore {

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let cacheDir: URL

    private enum Key {
        static let subscriptions = "feige.subscriptions"
        static let favorites = "feige.favorites"
        static let history = "feige.history"
        static let activeSubscription = "feige.active_subscription"
        static let currentSite = "feige.current_site"
        static let pinnedSites = "feige.pinned_sites"
        static let searchHistory = "feige.search_history"
        static let settings = "feige.settings"
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("feigemedia/subscriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - 订阅

    func loadSubscriptions() -> [Subscription] {
        decode([Subscription].self, key: Key.subscriptions) ?? []
    }

    func saveSubscriptions(_ list: [Subscription]) {
        encode(list, key: Key.subscriptions)
    }

    var activeSubscriptionId: String {
        get { defaults.string(forKey: Key.activeSubscription) ?? "" }
        set { defaults.set(newValue, forKey: Key.activeSubscription) }
    }

    var currentSiteKey: String {
        get { defaults.string(forKey: Key.currentSite) ?? "" }
        set { defaults.set(newValue, forKey: Key.currentSite) }
    }

    // MARK: - 订阅原文缓存

    func readSubscriptionCache(_ id: String) -> String? {
        let file = cacheDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    func writeSubscriptionCache(_ id: String, raw: String) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? raw.write(to: cacheDir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }

    // MARK: - 直播列表缓存

    /**
     直播聚合地址每次现场探测上游要几十秒，必须落盘缓存。
     用文件修改时间做 TTL，超过 ttl 视为过期。
     */
    func readLiveCache(_ url: String, ttl: TimeInterval) -> String? {
        let file = liveFile(url)
        guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        guard Date().timeIntervalSince(modified) <= ttl else { return nil }
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    func writeLiveCache(_ url: String, raw: String) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? raw.write(to: liveFile(url), atomically: true, encoding: .utf8)
    }

    private func liveFile(_ url: String) -> URL {
        cacheDir.appendingPathComponent("live_\(LocalStore.stableHash(url)).m3u")
    }

    /**
     Swift 的 hashValue 每次进程启动都会变，不能拿来当文件名。
     用 djb2 做稳定散列，保证冷启动还能命中上次的缓存。
     */
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    // MARK: - 收藏与历史

    func loadFavorites() -> [LibraryEntry] {
        decode([LibraryEntry].self, key: Key.favorites) ?? []
    }

    func saveFavorites(_ list: [LibraryEntry]) {
        encode(list, key: Key.favorites)
    }

    func loadHistory() -> [LibraryEntry] {
        decode([LibraryEntry].self, key: Key.history) ?? []
    }

    func saveHistory(_ list: [LibraryEntry]) {
        encode(list, key: Key.history)
    }

    // MARK: - 站点置顶与搜索历史

    func loadPinnedSites() -> Set<String> {
        Set(defaults.stringArray(forKey: Key.pinnedSites) ?? [])
    }

    func savePinnedSites(_ keys: Set<String>) {
        defaults.set(Array(keys), forKey: Key.pinnedSites)
    }

    func loadSearchHistory() -> [String] {
        (defaults.stringArray(forKey: Key.searchHistory) ?? []).filter { !$0.isEmpty }
    }

    func saveSearchHistory(_ list: [String]) {
        defaults.set(list, forKey: Key.searchHistory)
    }

    // MARK: - 设置

    func loadSettings() -> AppSettings {
        var settings = decode(AppSettings.self, key: Key.settings) ?? AppSettings()
        // 三个主键也单独存一份：设置整体损坏时至少不会丢当前订阅与站点
        let active = activeSubscriptionId
        if !active.isEmpty { settings.activeSubscriptionId = active }
        let site = currentSiteKey
        if !site.isEmpty { settings.currentSiteKey = site }
        return settings
    }

    func saveSettings(_ settings: AppSettings) {
        encode(settings, key: Key.settings)
    }

    // MARK: - 编解码

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
