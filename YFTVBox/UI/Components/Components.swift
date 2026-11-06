import SwiftUI
import UIKit

/**
 共用组件。

 对应 Android 版 `ui/component/`：海报卡、远程图片、加载态、空态、错误条、胶囊。
 图片没有用 AsyncImage——网格滚动时它会反复重建请求，
 这里用一层 NSCache + URLSession，滚动回来直接命中内存。
 */

// MARK: - 远程图片

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        cache.countLimit = 300
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func load(_ url: String, completion: @escaping (UIImage?) -> Void) {
        if let hit = cached(url) {
            completion(hit)
            return
        }
        guard let requestURL = URL(string: url), !url.isEmpty else {
            completion(nil)
            return
        }
        var request = URLRequest(url: requestURL)
        request.setValue(Http.defaultUA, forHTTPHeaderField: "User-Agent")
        if let referer = URL(string: url)?.scheme {
            // 很多图床对空 Referer 更宽松，这里不带 Referer，只带 UA
            _ = referer
        }
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self?.cache.setObject(image, forKey: url as NSString)
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}

struct RemoteImage: View {
    let url: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            XColors.posterPlaceholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(XColors.textTertiary)
            } else {
                ProgressView().tint(XColors.textTertiary)
            }
        }
        .clipped()
        .task(id: url) {
            failed = false
            image = ImageCache.shared.cached(url)
            guard image == nil else { return }
            ImageCache.shared.load(url) { loaded in
                if let loaded {
                    image = loaded
                } else {
                    failed = true
                }
            }
        }
    }
}

// MARK: - 海报卡

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 112
    var showRemarks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.poster)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: XRadii.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: XRadii.md, style: .continuous)
                        .stroke(XColors.divider, lineWidth: 0.5)
                )

            Text(item.name)
                .font(XFont.bodySmall())
                .foregroundStyle(XColors.textPrimary)
                .lineLimit(1)

            if showRemarks, !item.remarks.isEmpty {
                Text(item.remarks)
                    .font(XFont.caption())
                    .foregroundStyle(XColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 网格单元里的海报卡，宽度由外层列宽决定
struct PosterGridCell: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.poster)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: XRadii.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: XRadii.md, style: .continuous)
                        .stroke(XColors.divider, lineWidth: 0.5)
                )

            Text(item.name)
                .font(XFont.bodySmall())
                .foregroundStyle(XColors.textPrimary)
                .lineLimit(1)

            Text(item.remarks)
                .font(XFont.caption())
                .foregroundStyle(XColors.textTertiary)
                .lineLimit(1)
                .opacity(item.remarks.isEmpty ? 0 : 1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 状态视图

struct LoadingBlock: View {
    var text: String = "加载中"

    var body: some View {
        VStack(spacing: XSpacing.md) {
            ProgressView().tint(XColors.accent)
            Text(text)
                .font(XFont.caption())
                .foregroundStyle(XColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(XSpacing.xxl)
    }
}

struct EmptyBlock: View {
    var icon: String = "tray"
    var title: String
    var message: String = ""
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: XSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(XColors.textTertiary)
            Text(title)
                .font(XFont.title())
                .foregroundStyle(XColors.textSecondary)
            if !message.isEmpty {
                Text(message)
                    .font(XFont.caption())
                    .foregroundStyle(XColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(XColors.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(XSpacing.xxl)
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: XSpacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(XColors.danger)
            Text(message)
                .font(XFont.caption())
                .foregroundStyle(XColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(XColors.textSecondary)
                }
            }
        }
        .padding(XSpacing.md)
        .background(XColors.surfaceRaised, in: RoundedRectangle(cornerRadius: XRadii.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: XRadii.md, style: .continuous)
                .stroke(XColors.danger.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - 小组件

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(XFont.section())
                .foregroundStyle(XColors.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(XFont.caption())
                    .foregroundStyle(XColors.textTertiary)
            }
        }
    }
}

struct Chip: View {
    let title: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(XFont.bodySmall())
                .foregroundStyle(selected ? XColors.onAccent : XColors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, XSpacing.md)
                .padding(.vertical, 7)
                .background(selected ? XColors.accent : XColors.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 一行横向滚动的海报，首页与分类页共用
struct PosterRail: View {
    let items: [MediaItem]
    var cardWidth: CGFloat = 112

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: XSpacing.md) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCard(item: item, width: cardWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, XSpacing.lg)
        }
    }
}
