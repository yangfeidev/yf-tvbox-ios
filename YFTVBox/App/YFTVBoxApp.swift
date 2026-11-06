import SwiftUI
import UIKit

@main
struct YFTVBoxApp: App {

    @State private var app = AppViewModel()

    init() {
        Self.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(\.formFactor, DeviceForm.current)
                .preferredColorScheme(.dark)
                .tint(XColors.accent)
        }
    }

    /// 系统控件默认是浅色材质，这里统一压成设计稿的深色三层
    private static func configureAppearance() {
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(XColors.background)
        tabBar.shadowColor = UIColor(XColors.divider)
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = UIColor(XColors.background)
        navigation.shadowColor = UIColor(XColors.divider)
        navigation.titleTextAttributes = [.foregroundColor: UIColor(XColors.textPrimary)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(XColors.textPrimary)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
    }
}
