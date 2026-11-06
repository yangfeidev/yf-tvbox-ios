import Foundation

/**
 直播列表的内存缓存。

 对应 Android 版 `data/net/LiveCache.kt`，两级结构：
 - 内存（本文件）：切 Tab 不重复解析，10 分钟过期
 - 磁盘（LocalStore）：冷启动不空等，2 小时过期

 为什么必须缓存：直播聚合地址要为每个上游源现场探测，稳态 30~45 秒。
 */
final class LiveCache {

    static let shared = LiveCache()

    private struct Entry {
        var groups: [ChannelGroup]
        var storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 10 * 60

    func get(_ url: String) -> [ChannelGroup]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[url] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) <= ttl else {
            entries[url] = nil
            return nil
        }
        return entry.groups
    }

    func put(_ url: String, groups: [ChannelGroup]) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = Entry(groups: groups, storedAt: Date())
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
