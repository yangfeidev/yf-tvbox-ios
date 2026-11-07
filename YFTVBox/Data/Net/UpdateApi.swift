import Foundation

/**
 检查更新。

 与 Android 版最大的差别：iOS 不允许应用自己下载并安装 ipa。
 所以这里只做「查版本 → 展示更新说明 → 打开下载页」，
 真正的安装由使用者用 Sideloadly / AltStore / Xcode 完成。

 清单沿用 Android 的托管方式（Cloudflare R2，按 App 全拼分目录）：
 `https://dl.bsdnme.me/feige-yingshicang-ios/update.json`
 */
struct UpdateInfo: Decodable, Identifiable {
    /// 整数版本号，用来比较；对应 Bundle 的 CFBundleVersion
    var build: Int
    /// 展示用版本号，如 "1.0.1"
    var version: String
    /// 低于这个 build 的已装版本视为必须更新
    var minBuild: Int?
    /// 下载页（ipa 直链或一个落地页）
    var url: String
    var changelog: String?
    var force: Bool?

    var id: String { "\(version)-\(build)" }

    var isMandatory: Bool {
        force == true || (minBuild.map { UpdateApi.currentBuild < $0 } ?? false)
    }
}

enum UpdateApi {

    static let manifestURL = "https://dl.bsdnme.me/feige-yingshicang-ios/update.json"

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /**
     返回 nil 表示已是最新（或清单尚未发布）。
     首次发版时清单不存在，接口会 404——这不算错误，按"没有更新"处理。
     */
    static func check() async throws -> UpdateInfo? {
        let body: String
        do {
            body = try await Http.get(manifestURL, timeoutSeconds: 12, readTimeoutSeconds: 12)
        } catch let error as SourceError where error.message.contains("404") {
            return nil
        }

        guard let data = body.data(using: .utf8),
              let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else {
            throw SourceError("更新信息格式不正确")
        }
        guard !info.url.isEmpty else { return nil }
        guard info.build > currentBuild else { return nil }
        return info
    }
}
