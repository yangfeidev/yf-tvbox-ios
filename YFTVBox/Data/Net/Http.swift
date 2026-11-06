import Foundation

/**
 数据层统一异常，UI 直接把 message 展示给用户。
 */
struct SourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

/**
 网络层。

 只做 GET，不做缓存与重试——源站本身就不稳定，重试只会把等待时间成倍放大，
 不如让用户手动换源。

 两点与 Android 版对齐：
 1. UA 伪装成移动浏览器：部分 CMS 会拒绝 URLSession 默认 UA。
 2. 编码不是想当然的 UTF-8：国内 CMS 大量返回 GBK / GB18030，
    Android 的 `body.string()` 会读 Content-Type 里的 charset，
    这里也必须照做，否则中文片名全变乱码。
 */
enum Http {

    static let defaultUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// 按需放宽超时用的独立 session（直播聚合地址要 45 秒）
    private static var relaxedSessions: [TimeInterval: URLSession] = [:]
    private static let lock = NSLock()

    private static func session(readTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        if readTimeout == 15 && resourceTimeout == 15 { return sharedSession }
        lock.lock()
        defer { lock.unlock() }
        if let existing = relaxedSessions[resourceTimeout] { return existing }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = readTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let created = URLSession(configuration: config)
        relaxedSessions[resourceTimeout] = created
        return created
    }

    static func get(
        _ url: String,
        headers: [String: String] = [:],
        timeoutSeconds: TimeInterval = 15,
        readTimeoutSeconds: TimeInterval = 15
    ) async throws -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceError("地址为空") }
        guard let requestURL = URL(string: trimmed), requestURL.scheme != nil else {
            throw SourceError("地址格式不正确")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = readTimeoutSeconds
        request.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let client = session(readTimeout: readTimeoutSeconds, resourceTimeout: timeoutSeconds)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch let error as URLError {
            throw SourceError("网络请求失败：\(describe(error))")
        } catch {
            throw SourceError("网络请求失败：\(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourceError("HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else { throw SourceError("响应内容为空") }

        let text = decode(data, contentType: response.mimeType, response: response) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError("响应内容为空")
        }
        return text
    }

    // MARK: - 编码

    private static func decode(_ data: Data, contentType: String?, response: URLResponse) -> String? {
        // 1. Content-Type 里显式声明了 charset，照它解
        if let http = response as? HTTPURLResponse,
           let raw = http.value(forHTTPHeaderField: "Content-Type"),
           let charset = charsetName(in: raw),
           let encoding = encoding(for: charset) {
            return String(data: data, encoding: encoding)
        }
        // 2. 严格 UTF-8（invalid 字节会让整段返回 nil，不会像 lossy 那样把乱码当成功）
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // 3. 国内 CMS 常见 GBK，用 GB18030 兼容超集兜底
        if let gb = String(data: data, encoding: gb18030) { return gb }
        return String(data: data, encoding: .isoLatin1)
    }

    private static var gb18030: String.Encoding {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String.Encoding(rawValue: cf)
    }

    private static func charsetName(in contentType: String) -> String? {
        for part in contentType.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix("charset=") else { continue }
            return String(piece.dropFirst("charset=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                .lowercased()
        }
        return nil
    }

    private static func encoding(for charset: String) -> String.Encoding? {
        switch charset {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030", "cp936": return gb18030
        default:
            let cf = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringConvertIANACharSetNameToEncoding(charset as CFString))
            )
            return cf == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: cf)
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "连接或读取超时，请检查网络后重试"
        case .cannotFindHost, .cannotConnectToHost: return "无法连接到服务器"
        case .notConnectedToInternet: return "设备未联网"
        case .networkConnectionLost: return "网络连接中断"
        case .appTransportSecurityRequiresSecureConnection: return "系统拦截了明文 HTTP 请求"
        case .unsupportedURL: return "地址格式不正确"
        default: return error.localizedDescription
        }
    }

    /**
     请求被取消不是错误。

     视图重建（切 Tab、重新进页面）会让 in-flight 的 task 取消，
     源站错误直接弹「网络请求失败：cancelled」既误导又难看，统一在这里识别掉。
     */
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let source = error as? SourceError {
            return source.message.contains("cancelled") || source.message.contains("已取消")
        }
        return false
    }
}
