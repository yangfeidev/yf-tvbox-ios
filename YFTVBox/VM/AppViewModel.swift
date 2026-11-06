import Foundation
import Observation

/// 添加订阅的结果，用于区分「成功 / 需要选子仓库 / 失败」
enum AddResult {
    case success
    case needWarehouse([WarehouseEntry])
    case failure(String)
}

/**
 全局状态。

 对应 Android 版 `vm/AppViewModel.kt`：只用一个 ViewModel，
 订阅 → 源站 → 内容、收藏 / 历史 / 设置全部在这里聚合，不做过早分层。

 约定：所有 async 方法内部捕获异常并写进 `error`，视图只读状态，不写 do/catch。
 */
@Observable
@MainActor
final class AppViewModel {

    // MARK: 状态

    var settings = AppSettings()
    var subscriptions: [Subscription] = []
    var document: SubscriptionDocument?
    var currentSite: Site?
    var loading = false
    var initializing = true
    var refreshingSubscriptionId: String?
    var error: String?
    var favorites: [LibraryEntry] = []
    var history: [LibraryEntry] = []
    var pinnedSites: Set<String> = []
    var searchHistory: [String] = []

    var usableSites: [Site] { document?.usableSites ?? [] }
    var hasSubscription: Bool { !subscriptions.isEmpty }
    /// 因缺少运行时被跳过的源数量（spider 类），设置页展示
    var skippedSiteCount: Int { document?.skippedCount ?? 0 }

    // MARK: 内部

    private let store = LocalStore()
    private var pendingAdds: [String: Task<AddResult, Never>] = [:]
    private var didBootstrap = false

    private static let liveCacheTTL: TimeInterval = 2 * 60 * 60

    // MARK: - 启动

    func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        settings = store.loadSettings()
        subscriptions = store.loadSubscriptions()
        favorites = store.loadFavorites()
        history = store.loadHistory()
        pinnedSites = store.loadPinnedSites()
        searchHistory = store.loadSearchHistory()

        if settings.liveUrl.isEmpty {
            setLiveURL(DefaultSources.live)
        }

        let active = subscriptions.first { $0.id == settings.activeSubscriptionId } ?? subscriptions.first

        if let active {
            if settings.activeSubscriptionId != active.id {
                activateLocally(active.id)
            }
            if let raw = store.readSubscriptionCache(active.id),
               let cached = try? SubscriptionApi.parse(raw) {
                applyDocument(cached)
            }
            initializing = false
            if settings.autoUpdateOnLaunch {
                await refreshSubscription(id: active.id, silent: true)
            }
        } else if settings.autoAddDefault {
            // 没有任何订阅时静默导入内置单仓；失败不打扰用户，设置页会显示错误
            _ = await addSubscription(DefaultSources.box, name: "默认单仓")
            initializing = false
        } else {
            initializing = false
        }
    }

    // MARK: - 订阅

    func addSubscription(_ rawURL: String, name: String = "") async -> AddResult {
        let url = SubscriptionApi.normalizeURL(rawURL)
        guard !url.isEmpty else { return .failure("请输入订阅地址") }

        // 同一地址并发添加只跑一次，避免重复请求与重复入库
        if let pending = pendingAdds[url] { return await pending.value }
        let task = Task { await performAdd(url, name: name) }
        pendingAdds[url] = task
        let result = await task.value
        pendingAdds[url] = nil
        return result
    }

    private func performAdd(_ url: String, name: String) async -> AddResult {
        loading = true
        error = nil
        defer { loading = false }

        do {
            let raw = try await SubscriptionApi.fetchRaw(url)
            let document = try SubscriptionApi.parse(raw)
            if document.isWarehouse {
                return .needWarehouse(document.warehouse)
            }

            let id = LocalStore.stableHash(url)
            let now = Int64(Date().timeIntervalSince1970)
            let host = url.components(separatedBy: "://").last?
                .components(separatedBy: "/").first ?? url
            let subscription = Subscription(
                id: id,
                url: url,
                name: name.isEmpty ? host : name,
                addedAt: now,
                updatedAt: now,
                siteCount: document.sites.count
            )

            var next = subscriptions.filter { $0.id != id }
            next.append(subscription)
            subscriptions = next
            store.saveSubscriptions(next)
            store.writeSubscriptionCache(id, raw: raw)
            activateLocally(id)
            applyDocument(document)
            return .success
        } catch {
            let message = (error as? SourceError)?.message ?? error.localizedDescription
            self.error = message
            return .failure(message)
        }
    }

    func removeSubscription(_ id: String) {
        let next = subscriptions.filter { $0.id != id }
        subscriptions = next
        store.saveSubscriptions(next)

        guard settings.activeSubscriptionId == id || next.isEmpty else { return }

        if let first = next.first {
            activateLocally(first.id)
            if let raw = store.readSubscriptionCache(first.id),
               let cached = try? SubscriptionApi.parse(raw) {
                applyDocument(cached)
            }
            Task { await refreshSubscription(id: first.id) }
        } else {
            activateLocally("")
            document = nil
            currentSite = nil
        }
    }

    func activateSubscription(_ id: String) {
        guard settings.activeSubscriptionId != id else { return }
        activateLocally(id)
        document = nil
        currentSite = nil

        Task {
            if let raw = store.readSubscriptionCache(id),
               let cached = try? SubscriptionApi.parse(raw) {
                applyDocument(cached)
            } else {
                await refreshSubscription(id: id)
            }
        }
    }

    func refreshActive() async {
        await refreshSubscription(id: nil)
    }

    func refreshSubscription(id: String?, silent: Bool = false) async {
        let targetId = id ?? settings.activeSubscriptionId
        guard let active = subscriptions.first(where: { $0.id == targetId }) else { return }

        if !silent {
            loading = true
            refreshingSubscriptionId = active.id
            error = nil
        }

        do {
            let raw = try await SubscriptionApi.fetchRaw(active.url)
            let document = try SubscriptionApi.parse(raw)
            if document.isWarehouse {
                throw SourceError("该地址已变成多仓订阅，请重新添加子仓库")
            }
            store.writeSubscriptionCache(active.id, raw: raw)

            let now = Int64(Date().timeIntervalSince1970)
            subscriptions = subscriptions.map { sub in
                guard sub.id == active.id else { return sub }
                var copy = sub
                copy.updatedAt = now
                copy.siteCount = document.sites.count
                return copy
            }
            store.saveSubscriptions(subscriptions)

            if settings.activeSubscriptionId == active.id {
                applyDocument(document)
            }
            if !silent {
                loading = false
                refreshingSubscriptionId = nil
            }
        } catch {
            guard !Http.isCancellation(error) else { return }
            if !silent {
                loading = false
                refreshingSubscriptionId = nil
                self.error = (error as? SourceError)?.message ?? error.localizedDescription
            }
        }
    }

    private func applyDocument(_ document: SubscriptionDocument) {
        let usable = document.usableSites
        let savedKey = settings.currentSiteKey
        let site = usable.first { $0.key == savedKey } ?? usable.first
        if let site { store.currentSiteKey = site.key }

        self.document = document
        currentSite = site
        settings.currentSiteKey = site?.key ?? ""
        store.saveSettings(settings)
    }

    func selectSite(_ site: Site) {
        currentSite = site
        settings.currentSiteKey = site.key
        store.currentSiteKey = site.key
        store.saveSettings(settings)
    }

    func togglePinnedSite(_ site: Site) {
        let key = "\(settings.activeSubscriptionId)::\(site.key)"
        if pinnedSites.contains(key) {
            pinnedSites.remove(key)
        } else {
            pinnedSites.insert(key)
        }
        store.savePinnedSites(pinnedSites)
    }

    func isPinned(_ site: Site) -> Bool {
        pinnedSites.contains("\(settings.activeSubscriptionId)::\(site.key)")
    }

    private func activateLocally(_ id: String) {
        store.activeSubscriptionId = id
        settings.activeSubscriptionId = id
        store.saveSettings(settings)
    }

    // MARK: - 直播

    /**
     直播列表加载，三级缓存：内存 → 本地文件 → 网络。
     网络失败时退回过期缓存：有旧数据总比一片空白强。
     */
    func loadLive(forceRefresh: Bool = false) async throws -> [ChannelGroup] {
        let url = settings.liveUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return [] }

        if !forceRefresh {
            if let cached = LiveCache.shared.get(url) { return cached }
            if let raw = store.readLiveCache(url, ttl: Self.liveCacheTTL) {
                let groups = LiveParser.parse(raw)
                if !groups.isEmpty {
                    LiveCache.shared.put(url, groups: groups)
                    return groups
                }
            }
        }

        do {
            let raw = try await Http.get(url, timeoutSeconds: 45, readTimeoutSeconds: 45)
            let groups = LiveParser.parse(raw)
            if !groups.isEmpty {
                LiveCache.shared.put(url, groups: groups)
                store.writeLiveCache(url, raw: raw)
            }
            return groups
        } catch {
            if let stale = store.readLiveCache(url, ttl: .greatestFiniteMagnitude) {
                let groups = LiveParser.parse(stale)
                if !groups.isEmpty { return groups }
            }
            throw error
        }
    }

    // MARK: - 收藏与历史

    func isFavorite(_ item: MediaItem, siteKey: String) -> Bool {
        favorites.contains { $0.uniqueKey == "\(siteKey)::\(item.id)" }
    }

    func toggleFavorite(_ item: MediaItem, site: Site) {
        let key = "\(site.key)::\(item.id)"
        if let index = favorites.firstIndex(where: { $0.uniqueKey == key }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(
                LibraryEntry(
                    siteKey: site.key,
                    mediaId: item.id,
                    name: item.name,
                    poster: item.poster,
                    remarks: item.remarks,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                ),
                at: 0
            )
        }
        store.saveFavorites(favorites)
    }

    func recordHistory(
        item: MediaItem,
        site: Site,
        sourceName: String,
        episodeName: String,
        progress: Float
    ) {
        let key = "\(site.key)::\(item.id)"
        let entry = LibraryEntry(
            siteKey: site.key,
            mediaId: item.id,
            name: item.name,
            poster: item.poster,
            remarks: item.remarks,
            episodeName: episodeName,
            sourceName: sourceName,
            progress: min(max(progress, 0), 1),
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
        history = ([entry] + history.filter { $0.uniqueKey != key }).prefix(200).map { $0 }
        store.saveHistory(history)
    }

    func historyEntry(siteKey: String, mediaId: String) -> LibraryEntry? {
        history.first { $0.uniqueKey == "\(siteKey)::\(mediaId)" }
    }

    func removeHistory(_ entry: LibraryEntry) {
        history.removeAll { $0.uniqueKey == entry.uniqueKey }
        store.saveHistory(history)
    }

    func clearHistory() {
        history = []
        store.saveHistory(history)
    }

    // MARK: - 搜索历史

    func recordSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory = ([trimmed] + searchHistory.filter { $0 != trimmed }).prefix(10).map { $0 }
        store.saveSearchHistory(searchHistory)
    }

    func clearSearchHistory() {
        searchHistory = []
        store.saveSearchHistory(searchHistory)
    }

    // MARK: - 设置

    func setAutoUpdate(_ value: Bool) {
        settings.autoUpdateOnLaunch = value
        store.saveSettings(settings)
    }

    func setLiveURL(_ value: String) {
        settings.liveUrl = value
        store.saveSettings(settings)
    }

    func clearError() {
        error = nil
    }
}
