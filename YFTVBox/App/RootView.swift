import SwiftUI

/// Android 风格的五个导航入口：手机底栏，平板侧栏。
/// 已访问的页面保留状态，避免切换时重复加载。
struct RootView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.formFactor) private var form
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    /// 访问过的 Tab 才真正构建：直播页首次加载要 30~45 秒，
    /// 不能在启动时就把所有页面全建出来。建过之后保活，切回来不重载。
    @State private var visited: Set<Int> = [0]
    #if DEBUG
    @State private var debugSession: PlaybackSession?
    #endif

    var body: some View {
        ZStack {
            XColors.background.ignoresSafeArea()

            if form.isTablet {
                HStack(spacing: 0) {
                    Sidebar(selection: $selection)
                    pages
                }
            } else {
                VStack(spacing: 0) {
                    pages
                    BottomBar(selection: $selection)
                }
            }
        }
        .tint(XColors.accent)
        .task {
            await app.bootstrapIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in app.setForeground(phase == .active) }
        .onChange(of: selection) { _, newValue in
            visited.insert(newValue)
            app.setSourceSettingsVisible(newValue == 4)
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

    private var pages: some View {
        ZStack {
            page(0) { HomeView() }
            page(1) { CategoryBrowserView() }
            page(2) { LiveView() }
            page(3) { LibraryView() }
            page(4) { SettingsView(onSiteChanged: { selection = 0 }) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func page<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(index) {
            NavigationStack {
                content()
            }
            .id(index == 4 ? "settings" : "\(index)-\(app.familyMode)")
            .opacity(selection == index ? 1 : 0)
            .allowsHitTesting(selection == index)
        }
    }
}

private struct BottomBar: View {

    @Binding var selection: Int

    private let items: [(icon: String, title: String)] = [
        ("home", "首页"),
        ("category", "分类"),
        ("live", "直播"),
        ("library", "我的"),
        ("settings", "设置"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    selection = index
                } label: {
                    VStack(spacing: 3) {
                        NavigationIcon(name: item.icon)
                            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .frame(width: 21, height: 21)
                        Text(item.title)
                            .font(XFont.caption(0).weight(.medium))
                    }
                    .foregroundStyle(selection == index ? Color(hex: 0x2FE0D2) : XColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(index)")
            }
        }
        .background(
            XColors.railBackground
        )
    }
}

#Preview {
    RootView()
        .environment(AppViewModel())
        .preferredColorScheme(.dark)
}

private struct Sidebar: View {
    @Binding var selection: Int
    private let items = [("home", "首页"), ("category", "分类"), ("live", "直播"), ("library", "我的"), ("settings", "设置")]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image("AndroidBrand").resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9))
                Text("飞哥影视仓").font(XFont.title()).foregroundStyle(XColors.textPrimary)
            }.padding(.horizontal, 16).padding(.vertical, 20)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button { selection = index } label: {
                    HStack(spacing: 14) {
                        NavigationIcon(name: item.0).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 21, height: 21)
                        Text(item.1).font(XFont.bodySmall())
                        Spacer()
                    }.foregroundStyle(selection == index ? Color(hex: 0x2FE0D2) : XColors.textSecondary)
                        .padding(.horizontal, 14).frame(height: 48)
                        .background(selection == index ? Color(hex: 0x2FE0D2).opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityIdentifier("tab-\(index)")
            }.padding(.horizontal, 12)
            Spacer()
        }.frame(width: 200).frame(maxHeight: .infinity).background(XColors.railBackground)
    }
}

// The same 24×24 line drawings used by Android's navigation resources.
private struct NavigationIcon: Shape {
    let name: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
            if close { p.closeSubpath() }
        }
        switch name {
        case "home":
            line([(3.5,10.5),(12,3.5),(20.5,10.5)])
            line([(5.5,9.5),(5.5,20),(10,20),(10,14.5),(14,14.5),(14,20),(18.5,20),(18.5,9.5)])
        case "category":
            for x in [CGFloat(4),14] { for y in [CGFloat(4),14] { p.addRect(CGRect(x:x,y:y,width:6,height:6)) } }
        case "live":
            line([(7,3),(12,7),(17,3)])
            p.addRoundedRect(in: CGRect(x:3,y:7,width:18,height:13), cornerSize: CGSize(width:2,height:2))
            line([(10,10.5),(15,13.5),(10,16.5)], close:true)
        case "library":
            line([(5,5),(5,20),(12,16),(19,20),(19,5),(18,4),(6,4),(5,5)])
            line([(9,8),(15,8)])
        default:
            line([(4,6),(20,6)]); line([(4,12),(20,12)]); line([(4,18),(20,18)])
            line([(8,4),(8,8)]); line([(16,10),(16,14)]); line([(9,16),(9,20)])
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
