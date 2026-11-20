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

    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let supportDir: URL

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

    init(defaults: UserDefaults = .standard, baseDirectory: URL? = nil) {
        self.defaults = defaults
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        supportDir = base
        cacheDir = base.appendingPathComponent("feigemedia/subscriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private var authorizationDirectory: URL {
        let dir = supportDir.appendingPathComponent("feigemedia/authorization", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        var excluded = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return dir
    }

    func installationID() -> String? {
        let file = authorizationDirectory.appendingPathComponent("installation-id")
        if let existing = try? String(contentsOf: file, encoding: .utf8), UUID(uuidString: existing) != nil { return existing }
        let id = UUID().uuidString.lowercased()
        do { try id.write(to: file, atomically: true, encoding: .utf8); return id }
        catch { return nil }
    }

    var contentAuthorized: Bool {
        fileManager.fileExists(atPath: authorizationDirectory.appendingPathComponent("authorized").path)
    }

    var familyMode: Bool {
        get { !contentAuthorized || (defaults.object(forKey: "feige.family_mode") as? Bool ?? true) }
        set { defaults.set(newValue, forKey: "feige.family_mode") }
    }

    func authorizeContent(_ code: String, now: Date = Date()) -> String? {
        let locked = defaults.double(forKey: "feige.authorization_locked_until")
        if now.timeIntervalSince1970 < locked { return "尝试次数过多，请 30 秒后再试" }
        guard code.count == 8 && code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "请输入 8 位数字授权码" }
        if code == "08160219" {
            do {
                try Data("authorized".utf8).write(to: authorizationDirectory.appendingPathComponent("authorized"), options: .atomic)
                defaults.removeObject(forKey: "feige.authorization_failures")
                defaults.removeObject(forKey: "feige.authorization_locked_until")
                return nil
            } catch { return "无法保存授权，请重试" }
        }
        let failures = defaults.integer(forKey: "feige.authorization_failures") + 1
        defaults.set(failures >= 5 ? 0 : failures, forKey: "feige.authorization_failures")
        if failures >= 5 {
            defaults.set(now.timeIntervalSince1970 + 30, forKey: "feige.authorization_locked_until")
            return "尝试次数过多，请 30 秒后再试"
        }
        return "授权码不正确"
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

    func loadSourceKeys(_ id: String) -> [String: String] {
        defaults.dictionary(forKey: "feige.source_keys.\(id)") as? [String: String] ?? [:]
    }

    func saveSourceKeys(_ keys: [String: String], id: String) {
        defaults.set(keys, forKey: "feige.source_keys.\(id)")
    }

    func loadSourceSnapshots(_ id: String) -> [SourceCheckSnapshot] {
        decode([SourceCheckSnapshot].self, key: "feige.source_checks.\(id)") ?? []
    }

    func saveSourceSnapshot(_ snapshot: SourceCheckSnapshot, id: String) {
        let previous = loadSourceSnapshots(id).filter { $0.network != snapshot.network }
        encode(Array(([snapshot] + previous).prefix(5)), key: "feige.source_checks.\(id)")
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
