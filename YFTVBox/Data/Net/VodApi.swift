import Foundation

/**
 源站 API 访问层。

 只负责「拼 URL → 发请求 → 交给 VodParser 解析」，不含任何 UI 状态。

 参数约定（苹果CMS v10）：
 - 分类列表 `ac=list`
 - 列表 `ac=videolist&t=<分类>&pg=<页码>`
 - 搜索 `ac=videolist&wd=<关键词>&pg=<页码>`
 - 详情 `ac=videolist&ids=<id>`，部分源只认 `ac=detail`，失败后自动重试

 分类必须单独请求：`ac=videolist` 不返回 class 节点，只有 `ac=list` 才带分类表。
 */
enum VodApi {

    struct Playback {
        var url: String
        var headers: [String: String]
    }

    // MARK: - 分类

    static func categories(site: Site) async throws -> [Category] {
        if site.type == 4 {
            let body = try await Http.get(try buildURL(site.api, ["filter": "true", "extend": site.ext]))
            return try VodParser.parseList(body, isJSON: true).categories
        }
        var params = baseParams(site)
        params["ac"] = "list"
        let body = try await Http.get(try buildURL(site.api, params))
        return try VodParser.parseList(body, isJSON: site.isJSONAPI).categories
    }

    // MARK: - 列表

    static func list(site: Site, typeId: String = "", page: Int = 1) async throws -> PagedMedia {
        if site.type == 4 {
            let params: [String: String] = typeId.isEmpty
                ? ["filter": "true", "extend": site.ext]
                : ["ac": "detail", "filter": "true", "t": typeId, "pg": String(page), "ext": ""]
            let body = try await Http.get(try buildURL(site.api, params))
            let result = normalizeImages(site, try VodParser.parseList(body, isJSON: true))
            if typeId.isEmpty, result.items.isEmpty, let first = result.categories.first {
                let fallback = try await list(site: site, typeId: first.typeId, page: 1)
                var merged = fallback
                merged.categories = result.categories
                return merged
            }
            return result
        }
        var params = baseParams(site)
        params["ac"] = site.isJSONAPI ? "detail" : "videolist"
        params["pg"] = String(page)
        if !typeId.isEmpty { params["t"] = typeId }
        let body = try await Http.get(try buildURL(site.api, params))
        return normalizeImages(site, try VodParser.parseList(body, isJSON: site.isJSONAPI))
    }

    /**
     有些 CMS 的父分类不含视频，只有子分类有内容。
     并发拉子分类再合并，iOS 用 task group，语义与 Android 的 async/awaitAll 一致。
     */
    static func listChildren(site: Site, parentId: String, categories: [Category], page: Int) async throws -> PagedMedia {
        var descendants: [Category] = []
        var visited: Set<String> = [parentId]

        func collect(_ id: String) {
            for category in categories where category.parentId == id {
                guard visited.insert(category.typeId).inserted else { continue }
                descendants.append(category)
                collect(category.typeId)
            }
        }
        collect(parentId)

        guard !descendants.isEmpty else { return PagedMedia(page: page) }

        // 用非 throwing 的 group：子分类里只要有一个接口 404 / 超时，
        // throwing 版本会取消其余任务并整体抛错，导致整条横轨消失
        let pages = await withTaskGroup(of: PagedMedia?.self) { group -> [PagedMedia] in
            for category in descendants.prefix(8) {
                group.addTask {
                    try? await list(site: site, typeId: category.typeId, page: page)
                }
            }
            var results: [PagedMedia] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        var seen: Set<String> = []
        var merged: [MediaItem] = []
        for page in pages {
            for item in page.items where seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return PagedMedia(
            items: merged,
            page: page,
            pageCount: pages.map(\.pageCount).max() ?? 1,
            total: pages.reduce(0) { $0 + $1.total }
        )
    }

    // MARK: - 搜索

    static func search(site: Site, keyword: String, page: Int = 1) async throws -> PagedMedia {
        if site.type == 4 {
            let body = try await Http.get(try buildURL(site.api, [
                "ac": "detail", "wd": keyword, "quick": "false", "pg": String(page),
            ]))
            return normalizeImages(site, try VodParser.parseList(body, isJSON: true))
        }
        var params = baseParams(site)
        params["ac"] = site.isJSONAPI ? "detail" : "videolist"
        params["wd"] = keyword
        params["pg"] = String(page)
        let body = try await Http.get(try buildURL(site.api, params))
        return normalizeImages(site, try VodParser.parseList(body, isJSON: site.isJSONAPI))
    }

    // MARK: - 详情

    static func detail(site: Site, vodId: String) async throws -> MediaDetail {
        if site.type == 4 {
            let body = try await Http.get(try buildURL(site.api, [
                "ac": "detail", "ids": vodId, "extend": site.ext,
            ]))
            var detail = try VodParser.parseDetail(body, isJSON: true, fallbackId: vodId)
            detail.item = normalizeImage(site, detail.item)
            return detail
        }

        var lastError: Error?
        for action in ["videolist", "detail"] {
            do {
                var params = baseParams(site)
                params["ac"] = action
                params["ids"] = vodId
                let body = try await Http.get(try buildURL(site.api, params))
                var detail = try VodParser.parseDetail(body, isJSON: site.isJSONAPI, fallbackId: vodId)
                if !detail.item.name.isEmpty {
                    detail.item = normalizeImage(site, detail.item)
                    return detail
                }
            } catch {
                lastError = error
            }
        }
        throw SourceError("详情加载失败：\(lastError?.localizedDescription ?? "接口无返回")")
    }

    // MARK: - 播放地址

    static func resolvePlayback(site: Site, flag: String, id: String) async throws -> Playback {
        let body = try await Http.get(try buildURL(site.api, ["play": id, "flag": flag, "extend": site.ext]))
        guard let data = body.data(using: .utf8),
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SourceError("播放接口返回的不是有效 JSON")
        }
        let url = VodParser.str(result, "url")
        let parse = (result["parse"] as? NSNumber)?.intValue ?? 0
        if parse != 0 || !VodParser.str(result, "playUrl").isEmpty {
            throw SourceError("此线路需要额外的网页解析，当前版本暂不支持")
        }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            throw SourceError("播放接口没有返回可用的视频地址")
        }

        var headers: [String: String] = [:]
        if let dict = result["header"] as? [String: Any] {
            for (key, value) in dict {
                if let text = value as? String { headers[key] = text }
            }
        } else if let raw = result["header"] as? String,
                  let data = raw.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in dict {
                if let text = value as? String { headers[key] = text }
            }
        }
        return Playback(url: url, headers: headers)
    }

    // MARK: - 工具

    private static func baseParams(_ site: Site) -> [String: String] {
        site.isJSONAPI ? ["at": "json"] : [:]
    }

    /**
     在保留 api 原有 query 的前提下追加参数。
     有些订阅的 api 自带 token 或固定参数，整体覆盖会导致 401。
     */
    static func buildURL(_ base: String, _ params: [String: String]) throws -> String {
        guard var components = URLComponents(string: base), components.scheme != nil else {
            throw SourceError("接口地址不合法：\(base)")
        }
        var items = components.queryItems ?? []
        for (key, value) in params {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw SourceError("接口地址不合法：\(base)")
        }
        return url.absoluteString
    }

    private static func normalizeImage(_ site: Site, _ item: MediaItem) -> MediaItem {
        let poster = item.poster.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !poster.isEmpty else { return item }
        var copy = item
        let lower = poster.lowercased()
        if lower.hasPrefix("http") {
            copy.poster = poster
        } else if poster.hasPrefix("//") {
            copy.poster = "https:" + poster
        } else if let base = URL(string: site.api) {
            copy.poster = URL(string: poster, relativeTo: base.deletingLastPathComponent())?.absoluteString ?? poster
        }
        return copy
    }

    private static func normalizeImages(_ site: Site, _ page: PagedMedia) -> PagedMedia {
        var copy = page
        copy.items = page.items.map { normalizeImage(site, $0) }
        return copy
    }
}
