import SwiftUI

/**
 设计令牌 —— 颜色。

 与 Android 版 `core/theme/Color.kt` 一一对应，保证两端观感一致：
 背景三层（Background / Surface / SurfaceRaised）、分隔两层（Divider / Bar）、
 语义色（Accent / Info / Success / Danger）、文本三级。

 约束沿用原稿：全局只有一个强调色，不用渐变、不用投影。
 */
enum XColors {
    static let background = Color(hex: 0x0A0D14)
    static let surface = Color(hex: 0x171D29)
    static let surfaceRaised = Color(hex: 0x1E2637)
    static let railBackground = Color(hex: 0x0D121C)
    static let posterPlaceholder = Color(hex: 0x232C40)
    static let posterHighlight = Color(hex: 0x2C3752)

    static let divider = Color(hex: 0x2A3446)
    static let bar = Color(hex: 0x3A465C)

    static let accent = Color(hex: 0xFFB43C)
    static let info = Color(hex: 0x4C9AFF)
    static let success = Color(hex: 0x5AD18B)
    static let danger = Color(hex: 0xFF5C5C)

    static let textPrimary = Color(hex: 0xEDF1F7)
    static let textSecondary = Color(hex: 0x9AA8BC)
    static let textTertiary = Color(hex: 0x758299)

    static let onAccent = Color(hex: 0x0A0D14)
    static let videoBackground = Color(hex: 0x05070C)
    static let scrim = Color(hex: 0x0B0E14).opacity(0.9)
}

extension Color {
    /// 便于按设计稿的 0xRRGGBB 直接写色值。
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
