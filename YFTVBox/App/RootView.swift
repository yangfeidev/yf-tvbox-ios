import SwiftUI

/**
 根视图。

 四个 Tab：首页 / 直播 / 搜索 / 我的。
 Android 版手机端是五栏（首页、分类、直播、搜索、收藏），
 iOS 版把「分类」收进首页的横向入口（分类本质是首页内容的纵向延伸），
 收藏与历史合并进「我的」，五栏压到四栏。

 为什么自绘底部栏：新版系统在宽屏 iPhone 上会把 TabView 渲染成右侧悬浮竖栏，
 直接压住海报墙。这里把系统栏隐藏，用设计令牌自己画一条，
 保证手机/平板观感一致，也顺便保住设计稿的「底部 5 栏」语言。
 */
struct RootView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var selection = 0
    /// 访问过的 Tab 才真正构建：直播页首次加载要 30~45 秒，
    /// 不能在启动时就把四个页面全建出来。建过之后保活，切回来不重载。
    @State private var visited: Set<Int> = [0]
    #if DEBUG
    @State private var debugSession: PlaybackSession?
    #endif

    var body: some View {
        ZStack {
            XColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    page(0) { HomeView() }
                    page(1) { LiveView() }
                    page(2) { SearchView() }
                    page(3) { SettingsView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                BottomBar(selection: $selection)
            }
        }
        .tint(XColors.accent)
        .task {
            await app.bootstrapIfNeeded()
        }
        .onChange(of: selection) { _, newValue in
            visited.insert(newValue)
        }
        #if DEBUG
        // 调试用：SIMCTL_CHILD_DEBUG_PLAY_URL=<m3u8> 启动后直接进播放页
        // 只用来验证解码与渲染，Release 构建里不存在
        .onAppear {
            guard debugSession == nil,
                  let url = ProcessInfo.processInfo.environment["DEBUG_PLAY_URL"],
                  !url.isEmpty else { return }
            debugSession = PlaybackSession(
                title: "调试播放",
                subtitle: url,
                sources: [PlaySource(name: "调试", episodes: [Episode(name: "调试", url: url)])],
                sourceIndex: 0,
                episodeIndex: 0,
                isLive: false
            )
        }
        .fullScreenCover(item: $debugSession) { session in
            PlayerScreen(session: session).environment(app)
        }
        #endif
        .alert(
            Text("发现新版本 \(app.pendingUpdate?.version ?? "")"),
            isPresented: Binding(
                get: { app.pendingUpdate != nil },
                set: { if !$0 { app.dismissUpdate() } }
            ),
            presenting: app.pendingUpdate
        ) { info in
            Button("稍后", role: .cancel) { app.dismissUpdate() }
            Button("去下载") {
                if let url = URL(string: info.url) {
                    openURL(url)
                }
                app.dismissUpdate()
            }
        } message: { info in
            Text(info.changelog ?? "建议更新到最新版本。")
        }
    }

    @ViewBuilder
    private func page<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(index) {
            NavigationStack {
                content()
            }
            .opacity(selection == index ? 1 : 0)
            .allowsHitTesting(selection == index)
        }
    }
}

private struct BottomBar: View {

    @Binding var selection: Int

    private let items: [(icon: String, title: String)] = [
        ("house.fill", "首页"),
        ("tv.fill", "直播"),
        ("magnifyingglass", "搜索"),
        ("person.crop.circle.fill", "我的"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    selection = index
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .medium))
                        Text(item.title)
                            .font(XFont.caption(0).weight(.medium))
                    }
                    .foregroundStyle(selection == index ? XColors.accent : XColors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(index)")
            }
        }
        .background(
            XColors.background
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(XColors.divider)
                        .frame(height: 0.5)
                }
        )
    }
}

#Preview {
    RootView()
        .environment(AppViewModel())
        .preferredColorScheme(.dark)
}
