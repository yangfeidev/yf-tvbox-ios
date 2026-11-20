import Foundation
import Observation
import Network
import CryptoKit
import UIKit

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
    var familyMode = true
    let familyContent = FamilyContent()

    var visibleHistory: [LibraryEntry] {
        familyMode ? history.filter { entry in familyContent.libraryVisible(entry, site: usableSites.first { $0.key == entry.siteKey }) } : history
    }
    var visibleFavorites: [LibraryEntry] {
        familyMode ? favorites.filter { entry in familyContent.libraryVisible(entry, site: usableSites.first { $0.key == entry.siteKey }) } : favorites
    }
    var contentAuthorized: Bool { store.contentAuthorized }

    func setFamilyMode(_ enabled: Bool) {
        guard enabled || store.contentAuthorized else { return }
        store.familyMode = enabled
        familyMode = enabled
    }

    func authorizeContent(_ code: String) -> String? {
        if let error = store.authorizeContent(code) { return error }
        setFamilyMode(false)
        return nil
    }
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
    var checkingSources = false
    var sourceCheckResults: [String: Bool] = [:]
    var sourceCheckCompleted = 0
    var sourceCheckStale = false
    var sourceCheckMessage: String?
    var sourceCheckUpdateReady = false
    var showAllSources = false
    private var settingsVisible = false
    private var pendingSourceSnapshot: SourceCheckSnapshot?
    private var displayedSourceSnapshot: SourceCheckSnapshot?
    private var sourceCheckTask: Task<Void, Never>?
    private var sourceCheckGeneration = 0
    private var networkKey = UUID().uuidString
    private var networkOnline = false
    private var appForeground = true
    @ObservationIgnored private let networkMonitor = NWPathMonitor()
    @ObservationIgnored private let networkQueue = DispatchQueue(label: "feige.source-network")

    var displayedSites: [Site] {
        guard !showAllSources, displayedSourceSnapshot != nil else { return usableSites }
        return usableSites.filter { sourceCheckResults[$0.key] == true || $0.key == currentSite?.key }
    }

    private func sourceIdentity(_ site: Site) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(site)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func setSourceSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        if !visible { applySourceCheckUpdate() }
    }

    func setForeground(_ active: Bool) {
        appForeground = active
        if active { startSourceChecks() }
        else { sourceCheckGeneration += 1; sourceCheckTask?.cancel(); checkingSources = false }
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networkKey = UUID().uuidString
                self.networkOnline = online
                self.sourceCheckGeneration += 1
                self.sourceCheckTask?.cancel()
                self.checkingSources = false
                self.pendingSourceSnapshot = nil
                self.sourceCheckUpdateReady = false
                self.sourceCheckStale = self.displayedSourceSnapshot != nil
                self.sourceCheckMessage = online ? nil : "当前网络不可用，保留上次检测结果"
                if online { self.startSourceChecks() }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    /// 检查更新：有新版时由根视图统一弹窗，手动检查的结果用 updateMessage 提示
    var pendingUpdate: UpdateInfo?
    var checkingUpdate = false
    var updateMessage: String?

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

        #if DEBUG
        if ProcessInfo.processInfo.environment["DEBUG_HOME_HIT_TEST"] == "1" {
            currentSite = Site(key: "hit-test", name: "测试站点", api: "http://127.0.0.1:1", type: 1)
            initializing = false
            return
        }
        #endif

        familyMode = store.familyMode
        startNetworkMonitor()
        #if !DEBUG
        Task { await reportInstallation() }
        #endif
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
            if settings.autoUpdateOnLaunch || active.url == DefaultSources.legacyBox {
                await refreshSubscription(id: active.id, silent: true)
            }
        } else if settings.autoAddDefault {
            // 没有任何订阅时静默导入内置单仓；失败不打扰用户，设置页会显示错误
            _ = await addSubscription(DefaultSources.box, name: "默认影视源")
            initializing = false
        } else {
            initializing = false
        }

        if settings.autoCheckUpdate {
            Task { await checkUpdate() }
        }
    }

    /// Installation reporting mirrors Android; an installation ID is excluded from backups.
    private func reportInstallation() async {
        guard let id = store.installationID(),
              let url = URL(string: "https://analytics.bsdnme.me/v1/installations") else { return }
        let device = UIDevice.current
        let payload: [String: String] = [
            "id": id, "manufacturer": "Apple", "model": device.model,
            "deviceType": device.userInterfaceIdiom == .pad ? "tablet" : "phone",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - 检查更新

    /**
     iOS 不能自更新，这里只负责"发现新版并引导下载"。
     启动时的检查是静默的：没更新、失败都不打扰；手动检查才回显结果。
     */
    func checkUpdate(manual: Bool = false) async {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        if manual { updateMessage = nil }
        defer { checkingUpdate = false }

        do {
            if let info = try await UpdateApi.check() {
                pendingUpdate = info
            } else if manual {
                updateMessage = "已是最新版本 \(UpdateApi.currentVersion)（build \(UpdateApi.currentBuild)）"
            }
        } catch {
            guard !Http.isCancellation(error) else { return }
            if manual {
                updateMessage = (error as? SourceError)?.message ?? error.localizedDescription
            }
        }
    }

    func dismissUpdate() {
        pendingUpdate = nil
    }

    // MARK: - 订阅

    func addSubscription(_ rawURL: String, name: String = "") async -> AddResult {
        let url = SubscriptionApi.normalizeURL(rawURL)
        guard !url.isEmpty else { return .failure("请输入订阅地址") }

        if let existing = subscriptions.first(where: { $0.url == url }) {
            activateSubscription(existing.id)
            return .success
        }
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
        document = nil
        currentSite = nil

        if let first = next.first {
            activateLocally(first.id)
            if let raw = store.readSubscriptionCache(first.id),
               let cached = try? SubscriptionApi.parse(raw) {
                applyDocument(cached)
            }
            Task { await refreshSubscription(id: first.id) }
        } else {
            settings.autoAddDefault = false
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
            guard settings.activeSubscriptionId == id else { return }
            if let raw = store.readSubscriptionCache(id),
               let cached = try? SubscriptionApi.parse(raw) {
                applyDocument(cached)
            }
            if self.document == nil || self.subscriptions.first(where: { $0.id == id })?.url == DefaultSources.legacyBox {
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

        defer {
            if !silent, refreshingSubscriptionId == active.id {
                loading = false
                refreshingSubscriptionId = nil
            }
        }

        do {
            let targetURL = active.url == DefaultSources.legacyBox ? DefaultSources.box : active.url
            var raw = try await SubscriptionApi.fetchRaw(targetURL)
            var document = try SubscriptionApi.parse(raw)
            if document.isWarehouse {
                throw SourceError("该地址已变成多仓订阅，请重新添加子仓库")
            }
            guard subscriptions.contains(where: { $0.id == active.id && $0.url == active.url }) else { return }
            if targetURL == DefaultSources.box {
                let previous = store.readSubscriptionCache(active.id).flatMap { try? SubscriptionApi.parse($0) }
                var keys = store.loadSourceKeys(active.id)
                raw = try SubscriptionApi.preservingSourceKeys(raw, previous: previous, keys: &keys)
                document = try SubscriptionApi.parse(raw)
                store.saveSourceKeys(keys, id: active.id)
            }
            store.writeSubscriptionCache(active.id, raw: raw)

            let now = Int64(Date().timeIntervalSince1970)
            subscriptions = subscriptions.map { sub in
                guard sub.id == active.id else { return sub }
                var copy = sub
                copy.url = targetURL
                if sub.url == DefaultSources.legacyBox && sub.name == "默认单仓" { copy.name = "默认影视源" }
                copy.updatedAt = now
                copy.siteCount = document.sites.count
                return copy
            }
            store.saveSubscriptions(subscriptions)

            if settings.activeSubscriptionId == active.id {
                applyDocument(document)
            }
        } catch {
            guard !Http.isCancellation(error) else { return }
            if !silent {
                self.error = (error as? SourceError)?.message ?? error.localizedDescription
            }
        }
    }

    private func applyDocument(_ document: SubscriptionDocument) {
        sourceCheckGeneration += 1
        sourceCheckTask?.cancel()
        checkingSources = false
        pendingSourceSnapshot = nil
        sourceCheckUpdateReady = false
        displayedSourceSnapshot = nil
        sourceCheckResults = [:]
        let usable = document.usableSites
        let savedKey = settings.currentSiteKey
        let site = usable.first { $0.key == savedKey } ?? usable.first
        if let site { store.currentSiteKey = site.key }

        self.document = document
        currentSite = site
        settings.currentSiteKey = site?.key ?? ""
        store.saveSettings(settings)
        let snapshots = store.loadSourceSnapshots(settings.activeSubscriptionId)
        if let previous = snapshots.first(where: { $0.network == networkKey }) ?? snapshots.max(by: { $0.checkedAt < $1.checkedAt }) {
            applySourceSnapshot(previous)
        }
        startSourceChecks()
    }

    private func applySourceSnapshot(_ snapshot: SourceCheckSnapshot) {
        displayedSourceSnapshot = snapshot
        pendingSourceSnapshot = nil
        sourceCheckUpdateReady = false
        sourceCheckResults = usableSites.reduce(into: [:]) { results, site in
            if let entry = snapshot.entries[sourceIdentity(site)] { results[site.key] = entry.available }
        }
        let identities = Set(usableSites.map(sourceIdentity))
        sourceCheckStale = snapshot.network != networkKey || !snapshot.isFresh()
            || !identities.isSubset(of: Set(snapshot.entries.keys))
    }

    func applySourceCheckUpdate() {
        guard let snapshot = pendingSourceSnapshot, snapshot.network == networkKey else { return }
        applySourceSnapshot(snapshot)
    }

    func checkSources() async { startSourceChecks(force: true) }

    private func startSourceChecks(force: Bool = false) {
        let sites = usableSites
        let subscriptionId = settings.activeSubscriptionId
        guard appForeground, networkOnline, !subscriptionId.isEmpty, !sites.isEmpty else { return }
        let ids = Set(sites.map(sourceIdentity))
        let previous = store.loadSourceSnapshots(subscriptionId).first { $0.network == networkKey }
        if !force, let previous, previous.isFresh(), ids.isSubset(of: Set(previous.entries.keys)) { return }
        sourceCheckGeneration += 1
        let generation = sourceCheckGeneration
        let network = networkKey
        sourceCheckTask?.cancel()
        checkingSources = true
        sourceCheckCompleted = 0
        sourceCheckMessage = nil
        sourceCheckTask = Task { [weak self] in
            guard let self else { return }
            var results: [String: Bool] = [:]
            for start in stride(from: 0, to: sites.count, by: 6) {
                let batch = sites[start..<min(start + 6, sites.count)]
                let checked = await withTaskGroup(of: (Site, Bool).self) { group in
                    for site in batch {
                        group.addTask {
                            do { return (site, !(try await VodApi.list(site: site, timeout: 8)).items.isEmpty) }
                            catch { return (site, false) }
                        }
                    }
                    var values: [(Site, Bool)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                guard !Task.isCancelled, generation == self.sourceCheckGeneration,
                      self.settings.activeSubscriptionId == subscriptionId, self.networkKey == network else { return }
                for (site, available) in checked { results[self.sourceIdentity(site)] = available }
                self.sourceCheckCompleted += checked.count
            }
            let hasSuccess = results.values.contains(true)
            if !hasSuccess && (previous ?? self.displayedSourceSnapshot)?.entries.values.contains(where: { $0.available }) == true {
                self.checkingSources = false
                self.sourceCheckStale = true
                self.sourceCheckMessage = "本轮未检测到可用源，保留上次结果"
                return
            }
            let snapshot = SourceCheckSnapshot.merging(results, previous: previous, network: network)
            self.store.saveSourceSnapshot(snapshot, id: subscriptionId)
            self.checkingSources = false
            self.sourceCheckMessage = hasSuccess ? nil : "本轮未检测到可用源，请检查网络或稍后重试"
            if self.settingsVisible {
                self.pendingSourceSnapshot = snapshot
                self.sourceCheckUpdateReady = true
            } else { self.applySourceSnapshot(snapshot) }
        }
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
                    typeId: item.typeId, categoryName: item.categoryName,
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
            typeId: item.typeId, categoryName: item.categoryName,
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

    func removeFavorite(_ entry: LibraryEntry) {
        favorites.removeAll { $0.uniqueKey == entry.uniqueKey }
        store.saveFavorites(favorites)
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

    func setAutoCheckUpdate(_ value: Bool) {
        settings.autoCheckUpdate = value
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
