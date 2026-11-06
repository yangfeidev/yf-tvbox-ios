import Foundation

/**
 直播列表解析器。

 支持两种格式，靠首行自动识别：

 **M3U**（主流，带台标与 EPG）：
 ```
 #EXTM3U x-tvg-url="http://epg.example/e.xml"
 #EXTINF:-1 tvg-id="CCTV1" tvg-logo="http://.../cctv1.png" group-title="央视频道",CCTV-1 综合
 http://host/cctv1.m3u8
 ```

 **TXT**（TVBox 传统格式）：
 ```
 央视频道,#genre#
 CCTV-1,http://host/cctv1.m3u8
 ```

 过滤规则：
 - 只保留 http(s)，rtp / udp / rtsp 组播在公网设备上播不了，直接丢弃
 - IPv6 直连地址（`http://[2409:...]`）是运营商内网单播，普通网络必然连不上
 - 「更新时间」「关于本源」这类伪频道不是真频道
 */
enum LiveParser {

    private static let attrRegex = try! NSRegularExpression(pattern: "([\\w-]+)=\"([^\"]*)\"")
    private static let fakeKeywords = ["更新时间", "关于本源", "更新时间：", "免责"]

    static func parse(_ raw: String) -> [ChannelGroup] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.isEmpty else { return [] }

        let channels = text.uppercased().hasPrefix("#EXTM3U") ? parseM3U(text) : parseTXT(text)
        return group(channels)
    }

    // MARK: - M3U

    private struct ExtInfo {
        var name: String
        var group: String
        var logo: String
        var tvgId: String
        var catchup: String?
        var headers: [String: String]
    }

    private static func parseM3U(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        var pending: ExtInfo?
        var headers: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                let info = parseExtInf(line)
                pending = info
                headers = info.headers
            } else if line.uppercased().hasPrefix("#EXTVLCOPT:http-") {
                // 与 Android 版一致：取第一个冒号之后、再去掉开头的 "http-"
                var option = String(line.drop(while: { $0 != ":" }).dropFirst())
                if option.hasPrefix("http-") { option.removeFirst("http-".count) }
                let key = option.components(separatedBy: "=").first?.lowercased() ?? ""
                let value = option.components(separatedBy: "=").dropFirst().joined(separator: "=")
                    .trimmingCharacters(in: .whitespaces)
                let header: String?
                switch key {
                case "user-agent": header = "User-Agent"
                case "referrer", "referer": header = "Referer"
                case "origin": header = "Origin"
                default: header = nil
                }
                if let header, !value.isEmpty { headers[header] = value }
            } else if line.hasPrefix("#") {
                continue
            } else if line.contains("://") {
                let playable = isPlayable(line)
                if let info = pending, playable {
                    if !isFake(info.name) {
                        channels.append(Channel(
                            name: info.name,
                            url: line,
                            logo: info.logo,
                            group: info.group,
                            tvgId: info.tvgId,
                            catchup: info.catchup,
                            headers: headers
                        ))
                    }
                } else if pending == nil, playable {
                    channels.append(Channel(name: line, url: line))
                }
                pending = nil
            }
        }
        return channels
    }

    private static func parseExtInf(_ line: String) -> ExtInfo {
        var attrs: [String: String] = [:]
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in attrRegex.matches(in: line, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            attrs[String(line[keyRange]).lowercased()] = String(line[valueRange])
        }

        let commaIndex = line.lastIndex(of: ",")
        let name = commaIndex.map { String(line[line.index(after: $0)...]) }?
            .trimmingCharacters(in: .whitespaces) ?? "未命名频道"
        let group = attrs["group-title"]?.trimmingCharacters(in: .whitespaces) ?? ""

        var headers: [String: String] = [:]
        for (key, header) in [
            ("http-user-agent", "User-Agent"),
            ("http-referrer", "Referer"),
            ("http-referer", "Referer"),
            ("http-origin", "Origin"),
        ] {
            if let value = attrs[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                headers[header] = value
            }
        }

        let catchup = attrs["catchup-source"]?.trimmingCharacters(in: .whitespaces)

        return ExtInfo(
            name: name.isEmpty ? "未命名频道" : name,
            group: group.isEmpty ? "未分组" : group,
            logo: attrs["tvg-logo"]?.trimmingCharacters(in: .whitespaces) ?? "",
            tvgId: attrs["tvg-id"]?.trimmingCharacters(in: .whitespaces) ?? "",
            catchup: (catchup?.isEmpty ?? true) ? nil : catchup,
            headers: headers
        )
    }

    // MARK: - TXT

    private static func parseTXT(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        var currentGroup = "未分组"

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasSuffix("#genre#") {
                var label = String(line.dropLast("#genre#".count))
                    .trimmingCharacters(in: .whitespaces)
                while label.hasSuffix(",") { label.removeLast() }
                label = label.trimmingCharacters(in: .whitespaces)
                currentGroup = label.isEmpty ? "未分组" : label
                continue
            }

            guard let comma = line.firstIndex(of: ",") else { continue }
            let name = String(line[line.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
            let url = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, isPlayable(url), !isFake(name) else { continue }
            channels.append(Channel(name: name, url: url, group: currentGroup))
        }
        return channels
    }

    // MARK: - 公共

    private static func isPlayable(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.hasPrefix("http://[") || lower.hasPrefix("https://[") { return false }
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func isFake(_ name: String) -> Bool {
        fakeKeywords.contains { name.contains($0) }
    }

    private static func group(_ channels: [Channel]) -> [ChannelGroup] {
        var order: [String: [Channel]] = [:]
        var names: [String] = []
        for channel in channels {
            if order[channel.group] == nil { names.append(channel.group) }
            order[channel.group, default: []].append(channel)
        }
        return names.map { ChannelGroup(name: $0, channels: order[$0] ?? []) }
    }
}
