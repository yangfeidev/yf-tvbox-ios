import SwiftUI

/**
 设计令牌 —— 圆角、间距、字号与形态下发。

 对应 Android 版 `core/theme/Theme.kt`。差别只有一处：
 Android 版是三形态（手机 / 平板 / 电视），iOS 版只保留手机与平板，
 电视形态在 iOS 上不成立（Apple TV 国行不销售、tvOS 商店中国区不可用）。
 */
enum XRadii {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 16
    static let pill: CGFloat = 999
}

enum XSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum XFont {
    static func display(_ boost: CGFloat = 0) -> Font { .system(size: 24 + boost, weight: .semibold) }
    static func headline(_ boost: CGFloat = 0) -> Font { .system(size: 20 + boost, weight: .semibold) }
    static func section(_ boost: CGFloat = 0) -> Font { .system(size: 17 + boost, weight: .semibold) }
    static func title(_ boost: CGFloat = 0) -> Font { .system(size: 15 + boost, weight: .medium) }
    static func body(_ boost: CGFloat = 0) -> Font { .system(size: 14 + boost) }
    static func bodySmall(_ boost: CGFloat = 0) -> Font { .system(size: 13 + boost) }
    static func caption(_ boost: CGFloat = 0) -> Font { .system(size: 11 + boost) }
}

/** 设备形态：手机 3 列、平板 5 列，触摸交互统一。 */
enum FormFactor {
    case phone
    case tablet

    var isTablet: Bool { self == .tablet }

    var gridColumns: Int { isTablet ? 5 : 3 }

    var horizontalPadding: CGFloat { isTablet ? 24 : 16 }

    /// 海报卡宽度，按可用宽度反推，保证一行正好放下 [gridColumns] 张。
    func posterWidth(containerWidth: CGFloat) -> CGFloat {
        let total = CGFloat(gridColumns)
        let gaps = spacing * (total - 1)
        return max(80, (containerWidth - horizontalPadding * 2 - gaps) / total)
    }

    var spacing: CGFloat { isTablet ? 12 : 8 }

    var maxContentWidth: CGFloat { isTablet ? 1000 : .infinity }
}

private struct FormFactorKey: EnvironmentKey {
    static let defaultValue: FormFactor = .phone
}

extension EnvironmentValues {
    var formFactor: FormFactor {
        get { self[FormFactorKey.self] }
        set { self[FormFactorKey.self] = newValue }
    }
}
