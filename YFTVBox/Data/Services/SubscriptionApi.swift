import Foundation

/**
 订阅拉取与解析。

 支持三种形态：
 1. 标准订阅：`{"sites":[...],"lives":[...],"parses":[...]}`
 2. 多仓订阅：`{"urls":[{"name":"仓库A","url":"https://..."}]}`，需用户选择子仓库
 3. 裸地址：直接返回一个 CMS 接口地址字符串，生成单一源站

 容错：sites 里 type 3 的 spider 源会被保留但标记为不可用，不静默丢弃——
 设置页要能告诉用户「有多少个源在 iOS 上用不了」。
 */
enum SubscriptionApi {

    /// 直播聚合地址可能几十秒才返回，订阅拉取给 45 秒
    static let timeoutSeconds: TimeInterval = 45

    static func normalizeURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    static func fetchRaw(_ url: String) async throws -> String {
        let normalized = normalizeURL(url)
        let requestURL = normalized == DefaultSources.box ? normalized + "?include_candidates=1" : normalized
        return try await Http.get(
            requestURL,
            timeoutSeconds: timeoutSeconds,
            readTimeoutSeconds: timeoutSeconds
        )
    }

    static func fetch(_ url: String) async throws -> SubscriptionDocument {
        try parse(try await fetchRaw(url))
    }

    static func parse(_ raw: String) throws -> SubscriptionDocument {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SourceError("订阅内容为空") }

        // 裸地址：整段内容就是一个 CMS 接口
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            let api = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? text
            let host = api.components(separatedBy: "://").last?
                .components(separatedBy: "/").first ?? api
            return SubscriptionDocument(sites: [
                Site(key: "direct", name: host, api: api, type: 1, searchable: true, quickSearch: true),
            ])
        }

        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SourceError("订阅内容不是合法 JSON，可能地址已失效或返回了网页")
        }

        if let urls = root["urls"] as? [Any], !urls.isEmpty {
            var entries: [WarehouseEntry] = []
            for node in urls {
                guard let dict = node as? [String: Any] else { continue }
                let url = VodParser.str(dict, "url")
                guard !url.isEmpty else { continue }
                let name = VodParser.str(dict, "name")
                entries.append(WarehouseEntry(name: name.isEmpty ? url : name, url: url))
            }
            guard !entries.isEmpty else { throw SourceError("多仓订阅里没有可用的子仓库地址") }
            return SubscriptionDocument(warehouse: entries)
        }

        guard let sitesArray = root["sites"] as? [Any] else {
            throw SourceError("订阅里没有 sites 节点，可能不是 TVBox 格式")
        }

        var sites: [Site] = []
        for node in sitesArray {
            guard let dict = node as? [String: Any] else { continue }
            let name = VodParser.str(dict, "name")
            guard !name.isEmpty else { continue }
            var api = VodParser.str(dict, "api")
            if api.isEmpty { api = VodParser.str(dict, "api_") }
            let key = VodParser.str(dict, "key")
            sites.append(Site(
                key: key.isEmpty ? name : key,
                name: name,
                api: api,
                type: intValue(dict["type"], default: 1),
                searchable: intValue(dict["searchable"], default: 1) != 0,
                quickSearch: intValue(dict["quickSearch"], default: 0) != 0,
                ext: VodParser.str(dict, "ext")
            ))
        }
        guard !sites.isEmpty else { throw SourceError("订阅中的 sites 全部缺少名称") }

        var liveSources: [LiveSourceEntry] = []
        if let lives = root["lives"] as? [Any] {
            for (index, node) in lives.enumerated() {
                guard let dict = node as? [String: Any] else { continue }
                let url = VodParser.str(dict, "url")
                guard !url.isEmpty else { continue }
                let name = VodParser.str(dict, "name")
                liveSources.append(LiveSourceEntry(
                    name: name.isEmpty ? "直播源 \(index + 1)" : name,
                    url: url,
                    group: VodParser.str(dict, "group")
                ))
            }
        }

        var parses: [String] = []
        if let array = root["parses"] as? [Any] {
            for node in array {
                guard let dict = node as? [String: Any] else { continue }
                let url = VodParser.str(dict, "url")
                if !url.isEmpty { parses.append(url) }
            }
        }

        return SubscriptionDocument(sites: sites, liveSources: liveSources, parses: parses)
    }

    /// Keep stable source keys when the unified list changes its server-generated keys.
    static func preservingSourceKeys(_ raw: String, previous: SubscriptionDocument?, keys: inout [String: String]) throws -> String {
        guard let data = raw.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var nodes = root["sites"] as? [[String: Any]] else { return raw }
        func identity(_ site: Site) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [site.type, site.api, site.ext])
            return String(decoding: data, as: UTF8.self)
        }
        let old = previous?.sites ?? []
        let counts = Dictionary(grouping: old, by: \.key).mapValues(\.count)
        for site in old where counts[site.key] == 1 && !site.key.isEmpty {
            if keys[identity(site)] == nil { keys[identity(site)] = site.key }
        }
        let parsed = try parse(raw).sites
        var occupied = Set(parsed.map(\.key))
        for index in nodes.indices {
            let original = VodParser.str(nodes[index], "key").isEmpty ? VodParser.str(nodes[index], "name") : VodParser.str(nodes[index], "key")
            guard let site = parsed.first(where: { $0.key == original }) else { continue }
            let id = identity(site)
            if let oldKey = keys[id], oldKey == original || !occupied.contains(oldKey) {
                occupied.remove(original)
                occupied.insert(oldKey)
                nodes[index]["key"] = oldKey
            } else {
                keys[id] = original
            }
        }
        root["sites"] = nodes
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    private static func intValue(_ raw: Any?, default fallback: Int) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String, let parsed = Int(text) { return parsed }
        return fallback
    }
}
