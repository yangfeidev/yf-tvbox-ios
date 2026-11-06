import Foundation

/**
 CMS 响应解析器。

 对应 Android 版 `data/net/VodParser.kt`，同时支持两类源站返回：
 - JSON（type 1）：苹果CMS v10 `api.php/provide/vod/?ac=...&at=json`
 - XML（type 0）：`api.php/provide/vod/?ac=...`（默认 XML）

 播放地址的三层分隔符（TVBox 约定）：
 ```
 线路一$$$线路二                  ← 线路之间用 $$$
 第1集$url#第2集$url             ← 集数之间用 #
 第1集$http://.../1.m3u8        ← 名称与地址之间用 $
 ```

 容错原则：单个字段缺失一律降级为空值，绝不打断整页渲染；
 只有根节点完全无法识别时才抛 SourceError。
 */
enum VodParser {

    private static let sourceSeparator = "$$$"
    private static let episodeSeparator = "#"
    private static let fieldSeparator = "$"

    // MARK: - 列表

    static func parseList(_ body: String, isJSON: Bool) throws -> PagedMedia {
        isJSON ? try parseJSONList(body) : try parseXMLList(body)
    }

    private static func parseJSONList(_ body: String) throws -> PagedMedia {
        guard let root = jsonObject(body) else {
            throw SourceError("返回内容不是合法 JSON，可能接口地址已失效")
        }
        var items: [MediaItem] = []
        if let array = root["list"] as? [Any] {
            for node in array {
                guard let dict = node as? [String: Any], let item = toItem(dict) else { continue }
                items.append(item)
            }
        }
        return PagedMedia(
            items: items,
            page: intValue(root["page"], default: 1),
            pageCount: max(1, intValue(root["pagecount"], default: 1)),
            total: intValue(root["total"], default: items.count),
            categories: parseCategories(root["class"])
        )
    }

    private static func parseXMLList(_ body: String) throws -> PagedMedia {
        let delegate = ListXMLDelegate()
        let parser = XMLParser(data: Data(body.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()

        if delegate.items.isEmpty, delegate.categories.isEmpty, !delegate.sawList {
            throw SourceError("XML 中没有可识别的内容，可能接口返回了错误页")
        }
        return PagedMedia(
            items: delegate.items,
            page: delegate.page,
            pageCount: max(1, delegate.pageCount),
            total: delegate.total,
            categories: delegate.categories
        )
    }

    // MARK: - 详情

    static func parseDetail(_ body: String, isJSON: Bool, fallbackId: String) throws -> MediaDetail {
        isJSON ? try parseJSONDetail(body, fallbackId: fallbackId) : try parseXMLDetail(body, fallbackId: fallbackId)
    }

    private static func parseJSONDetail(_ body: String, fallbackId: String) throws -> MediaDetail {
        guard let root = jsonObject(body) else {
            throw SourceError("详情返回的不是合法 JSON")
        }
        guard let array = root["list"] as? [Any], !array.isEmpty,
              let node = array[0] as? [String: Any] else {
            throw SourceError("未取到详情数据")
        }
        return MediaDetail(
            item: toItem(node) ?? MediaItem(id: fallbackId, name: ""),
            content: cleanHTML(str(node, "vod_content")),
            actor: str(node, "vod_actor"),
            director: str(node, "vod_director"),
            playSources: buildPlaySources(from: str(node, "vod_play_from"), url: str(node, "vod_play_url"))
        )
    }

    private static func parseXMLDetail(_ body: String, fallbackId: String) throws -> MediaDetail {
        let delegate = DetailXMLDelegate()
        let parser = XMLParser(data: Data(body.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()

        let name = delegate.fields["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else {
            throw SourceError("详情中没有找到影片信息")
        }
        let id = delegate.fields["id"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return MediaDetail(
            item: MediaItem(
                id: id.isEmpty ? fallbackId : id,
                name: name,
                poster: trim(delegate.fields["pic"]),
                remarks: trim(delegate.fields["note"]),
                typeId: trim(delegate.fields["tid"]),
                year: trim(delegate.fields["year"]),
                area: trim(delegate.fields["area"]),
                categoryName: trim(delegate.fields["type"])
            ),
            content: cleanHTML(trim(delegate.fields["des"])),
            actor: trim(delegate.fields["actor"]),
            director: trim(delegate.fields["director"]),
            playSources: delegate.sources
        )
    }

    // MARK: - 工具

    static func buildPlaySources(from: String, url: String) -> [PlaySource] {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let names = from.isEmpty ? [] : from.components(separatedBy: sourceSeparator)
        let groups = trimmed.components(separatedBy: sourceSeparator)

        var sources: [PlaySource] = []
        for (index, group) in groups.enumerated() {
            let episodes = splitEpisodes(group)
            guard !episodes.isEmpty else { continue }
            let candidate = index < names.count ? names[index].trimmingCharacters(in: .whitespaces) : ""
            let name = candidate.isEmpty ? "线路 \(sources.count + 1)" : candidate
            sources.append(PlaySource(name: name, episodes: episodes))
        }
        return sources
    }

    static func splitEpisodes(_ raw: String) -> [Episode] {
        var episodes: [Episode] = []
        for segment in raw.components(separatedBy: episodeSeparator) {
            let entry = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            guard let range = entry.range(of: fieldSeparator) else {
                // 没有「名称$地址」结构时按裸地址处理
                if entry.hasPrefix("http") {
                    episodes.append(Episode(name: "第 \(episodes.count + 1) 集", url: entry))
                }
                continue
            }
            let name = String(entry[entry.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let url = String(entry[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { continue }
            episodes.append(Episode(name: name.isEmpty ? "第 \(episodes.count + 1) 集" : name, url: url))
        }
        return episodes
    }

    private static func toItem(_ node: [String: Any]) -> MediaItem? {
        let name = str(node, "vod_name")
        guard !name.isEmpty else { return nil }
        return MediaItem(
            id: str(node, "vod_id"),
            name: name,
            poster: str(node, "vod_pic"),
            remarks: str(node, "vod_remarks"),
            typeId: str(node, "type_id"),
            year: str(node, "vod_year"),
            area: str(node, "vod_area"),
            categoryName: str(node, "type_name")
        )
    }

    private static func parseCategories(_ raw: Any?) -> [Category] {
        guard let array = raw as? [Any] else { return [] }
        var result: [Category] = []
        for node in array {
            guard let dict = node as? [String: Any] else { continue }
            let id = str(dict, "type_id")
            let name = str(dict, "type_name")
            if !id.isEmpty, !name.isEmpty {
                result.append(Category(typeId: id, name: name, parentId: str(dict, "type_pid")))
            }
        }
        return result
    }

    // MARK: - JSON 取值

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 对齐 Android 的 `optString`：null / 缺字段返回空串，数字转成文本
    static func str(_ node: [String: Any], _ key: String) -> String {
        guard let value = node[key], !(value is NSNull) else { return "" }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "null" ? "" : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func intValue(_ raw: Any?, default fallback: Int) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String, let parsed = Int(text) { return parsed }
        return fallback
    }

    private static func trim(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func cleanHTML(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        var text = input
        text = text.replacingOccurrences(
            of: "<br\\s*/?>", with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - XML：列表

private final class ListXMLDelegate: NSObject, XMLParserDelegate {
    var items: [MediaItem] = []
    var categories: [Category] = []
    var page = 1
    var pageCount = 1
    var total = 0
    var sawList = false

    private var current: [String: String]?
    private var currentTag = ""
    private var inClass = false
    private var tyId: String?
    private var tyParentId = ""
    private var tyText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        switch tag {
        case "list":
            sawList = true
            page = Int(attributeDict["page"] ?? "") ?? 1
            pageCount = Int(attributeDict["pagecount"] ?? "") ?? 1
            total = Int(attributeDict["recordcount"] ?? "") ?? 0
            currentTag = ""
        case "video":
            current = [:]
            currentTag = ""
        case "class":
            inClass = true
            currentTag = ""
        case "ty":
            tyId = attributeDict["id"]
            tyParentId = attributeDict["pid"] ?? ""
            tyText = ""
            currentTag = "ty"
        default:
            currentTag = tag
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inClass {
            if currentTag == "ty" { tyText += string }
        } else if var map = current, !currentTag.isEmpty {
            map[currentTag, default: ""] += string
            current = map
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = elementName.lowercased()
        switch tag {
        case "video":
            if let map = current {
                let name = text(map["name"])
                if !name.isEmpty {
                    items.append(MediaItem(
                        id: text(map["id"]),
                        name: name,
                        poster: text(map["pic"]),
                        remarks: text(map["note"]),
                        typeId: text(map["tid"]),
                        year: text(map["year"]),
                        area: text(map["area"]),
                        categoryName: text(map["type"])
                    ))
                }
            }
            current = nil
            currentTag = ""
        case "class":
            inClass = false
            currentTag = ""
        case "ty":
            let label = tyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = tyId, !id.isEmpty, !label.isEmpty {
                categories.append(Category(typeId: id, name: label, parentId: tyParentId))
            }
            tyId = nil
            currentTag = ""
        default:
            if currentTag == tag { currentTag = "" }
        }
    }

    private func text(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - XML：详情

private final class DetailXMLDelegate: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    var sources: [PlaySource] = []

    private var currentTag = ""
    private var ddFlag = ""
    private var ddText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        if tag == "dd" {
            ddFlag = attributeDict["flag"] ?? "线路 \(sources.count + 1)"
            ddText = ""
            currentTag = "dd"
        } else {
            currentTag = tag
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentTag == "dd" {
            ddText += string
        } else if !currentTag.isEmpty {
            fields[currentTag, default: ""] += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = elementName.lowercased()
        if tag == "dd" {
            let episodes = VodParser.splitEpisodes(ddText)
            if !episodes.isEmpty {
                let flag = ddFlag.trimmingCharacters(in: .whitespaces)
                sources.append(PlaySource(name: flag.isEmpty ? "线路 \(sources.count + 1)" : flag, episodes: episodes))
            }
            currentTag = ""
        } else if currentTag == tag {
            currentTag = ""
        }
    }
}
