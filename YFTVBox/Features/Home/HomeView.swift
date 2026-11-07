import SwiftUI

/// 最新上线、继续观看和分类横轨，对应 Android 首页。
struct HomeView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var categories: [Category] = []
    @State private var rails: [HomeRail] = []
    @State private var latest: [MediaItem] = []
    @State private var featured: MediaItem?
    @State private var historyItem: MediaItem?
    @State private var loading = false
    @State private var errorText: String?
    @State private var loadedSiteKey = ""
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if app.initializing {
                LoadingBlock(text: "正在读取订阅")
            } else if app.currentSite == nil {
                onboarding
            } else {
                content
            }
        }
        .background(XColors.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
        .navigationDestination(for: Category.self) { category in
            CategoryView(category: category)
        }
        .navigationDestination(item: $historyItem) { DetailView(item: $0, autoResume: true) }
        .task(id: app.currentSite) { await load() }
    }

    /// 标题固定用应用名：用站点名会让返回按钮变成"烂大街!"这种源站标题
    private var navigationTitle: String { "飞哥影视仓" }

    // MARK: - 主体

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: XSpacing.xl) {
                if let errorText {
                    ErrorBanner(message: errorText) {
                        self.errorText = nil
                    }
                    .padding(.horizontal, XSpacing.lg)
                }

                if let site = app.currentSite {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image("AndroidBrand").resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("飞哥影视仓").font(XFont.title()).foregroundStyle(XColors.textPrimary)
                                    (Text("由 ").foregroundColor(XColors.textSecondary) + Text("巴萨的内马尔").foregroundColor(XColors.accent) + Text(" 打造").foregroundColor(XColors.textSecondary)).font(XFont.caption())
                                }
                            }
                            Text("当前片源 · \(site.name)").font(XFont.caption()).foregroundStyle(XColors.textSecondary)
                        }
                        Spacer()
                        Button { Task { await load(force: true) } } label: { homeAction("arrow.clockwise") }
                        NavigationLink { SearchView() } label: { homeAction("magnifyingglass") }.accessibilityLabel("首页搜索")
                        NavigationLink { SettingsView(showsNavigationBar: true) } label: { homeAction("slider.horizontal.3") }
                    }.padding(.horizontal, XSpacing.lg)
                }

                if let featured {
                    NavigationLink(value: featured) {
                        FeaturedCard(item: featured).padding(.horizontal, XSpacing.lg)
                    }.buttonStyle(.plain)
                }

                let history = Array(app.history.filter { entry in app.usableSites.contains { $0.key == entry.siteKey } }.prefix(10))
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: XSpacing.md) {
                        Text("继续观看").font(XFont.section()).foregroundStyle(XColors.textPrimary)
                            .padding(.horizontal, XSpacing.lg)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(history) { entry in
                                    Button {
                                        if let site = app.usableSites.first(where: { $0.key == entry.siteKey }) {
                                            if site.key != app.currentSite?.key { app.selectSite(site) }
                                            historyItem = entry.toMediaItem()
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            PosterGridCell(item: entry.toMediaItem()).frame(width: cardWidth)
                                            if let site = app.usableSites.first(where: { $0.key == entry.siteKey }) {
                                                Text("片源 · \(site.name)").font(XFont.caption()).foregroundStyle(XColors.textSecondary).lineLimit(1)
                                            }
                                        }.frame(width: cardWidth)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, XSpacing.lg)
                        }
                    }
                }

                if !latest.isEmpty {
                    VStack(alignment: .leading, spacing: XSpacing.md) {
                        Text("最近更新").font(XFont.section()).foregroundStyle(XColors.textPrimary)
                            .padding(.horizontal, XSpacing.lg)
                        PosterRail(items: latest, cardWidth: cardWidth)
                    }
                }

                ForEach(rails) { rail in
                    VStack(alignment: .leading, spacing: XSpacing.md) {
                        HStack {
                            Text(rail.category.name)
                                .font(XFont.section())
                                .foregroundStyle(XColors.textPrimary)
                            Spacer()
                            NavigationLink(value: rail.category) {
                                Text("更多")
                                    .font(XFont.caption())
                                    .foregroundStyle(XColors.textTertiary)
                            }
                        }
                        .padding(.horizontal, XSpacing.lg)

                        PosterRail(items: rail.items, cardWidth: cardWidth)
                    }
                }

                if loading {
                    LoadingBlock(text: "加载中")
                        .frame(height: 120)
                }

                if !loading, latest.isEmpty, rails.isEmpty, errorText == nil {
                    EmptyBlock(
                        icon: "film",
                        title: "这个源暂时没有内容",
                        message: "换一个站点，或在「我的」里刷新订阅"
                    )
                }
            }
            .padding(.vertical, XSpacing.md)
            .frame(maxWidth: form.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load(force: true) }
    }

    private func homeAction(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(XColors.textSecondary)
            .frame(width: 40, height: 40).background(XColors.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var cardWidth: CGFloat {
        form.isTablet ? 148 : 112
    }

    // MARK: - 未添加订阅

    private var onboarding: some View {
        ScrollView {
            VStack(spacing: XSpacing.xl) {
                VStack(spacing: XSpacing.sm) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 44))
                        .foregroundStyle(XColors.accent)
                    Text("飞哥影视仓")
                        .font(XFont.display())
                        .foregroundStyle(XColors.textPrimary)
                    Text("iOS 版 · 手机与 iPad")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                }
                .padding(.top, XSpacing.xxl)

                VStack(alignment: .leading, spacing: XSpacing.md) {
                    Text("还没有订阅")
                        .font(XFont.section())
                        .foregroundStyle(XColors.textPrimary)
                    Text("添加订阅地址，或使用默认订阅地址后即可浏览。")
                        .font(XFont.body())
                        .foregroundStyle(XColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    NavigationLink {
                        SubscriptionListView()
                    } label: {
                        Text("去添加订阅")
                            .font(XFont.title())
                            .foregroundStyle(XColors.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(XColors.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            loading = true
                            _ = await app.addSubscription(DefaultSources.box, name: "默认单仓")
                            loading = false
                        }
                    } label: {
                        Text("使用默认订阅地址")
                            .font(XFont.bodySmall())
                            .foregroundStyle(XColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(XColors.surfaceRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(XSpacing.lg)
                .background(XColors.surface, in: RoundedRectangle(cornerRadius: XRadii.lg, style: .continuous))
            }
            .padding(.horizontal, XSpacing.lg)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !app.usableSites.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(app.usableSites) { site in
                        Button {
                            app.selectSite(site)
                        } label: {
                            if site.key == app.currentSite?.key {
                                Label(site.name, systemImage: "checkmark")
                            } else {
                                Text(site.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(app.currentSite?.name ?? "站点")
                            .font(XFont.caption())
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(XColors.textPrimary)
                }
            }
        }
    }

    // MARK: - 加载

    private func load(force: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let site = app.currentSite else {
            categories = []; rails = []; latest = []; featured = nil; loadedSiteKey = ""; loading = false
            return
        }
        let siteIdentity = "\(app.settings.activeSubscriptionId)::\(site.key)::\(site.api)"
        if !force, loadedSiteKey == siteIdentity, !rails.isEmpty { return }
        if loadedSiteKey != siteIdentity { categories = []; rails = []; latest = []; featured = nil }

        loading = true
        errorText = nil
        defer { if generation == loadGeneration { loading = false } }

        do {
            let latestPage = try await VodApi.list(site: site)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            latest = latestPage.items
            featured = latest.first
            let allCategories = (try? await VodApi.categories(site: site)) ?? []
            guard generation == loadGeneration, !Task.isCancelled else { return }
            categories = Array(allCategories.prefix(12))

            let picked = Array(allCategories.filter { $0.parentId.isEmpty || $0.parentId == "0" }.prefix(4))
            let targets = picked.isEmpty ? Array(allCategories.prefix(4)) : picked

            // 非 throwing：某个分类挂了只让那一条横轨空着，不能让整页变成错误页
            let results = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
                for (index, category) in targets.enumerated() {
                    group.addTask {
                        // 请求失败就直接空着：再打一轮子分类只会把首屏拖得更慢
                        guard let page = try? await VodApi.list(site: site, typeId: category.typeId, page: 1) else {
                            return (index, [])
                        }
                        if !page.items.isEmpty { return (index, page.items) }

                        // 成功但为空，才可能撞上"父分类没内容、视频挂子分类"，且只给前两条兜底
                        guard index < 2 else { return (index, []) }
                        if let children = try? await VodApi.listChildren(
                            site: site,
                            parentId: category.typeId,
                            categories: allCategories,
                            page: 1
                        ) {
                            return (index, children.items)
                        }
                        return (index, [])
                    }
                }
                var buffer: [Int: [MediaItem]] = [:]
                for await (index, items) in group {
                    buffer[index] = items
                }
                return buffer
            }

            guard generation == loadGeneration, !Task.isCancelled else { return }
            rails = targets.enumerated().compactMap { index, category in
                guard let items = results[index], !items.isEmpty else { return nil }
                return HomeRail(category: category, items: items)
            }
            if latest.isEmpty { latest = rails.first?.items ?? [] }
            featured = latest.first
            loadedSiteKey = siteIdentity
        } catch {
            guard generation == loadGeneration, !Http.isCancellation(error) else { return }
            errorText = (error as? SourceError)?.message ?? error.localizedDescription
        }
    }
}

private struct HomeRail: Identifiable {
    let category: Category
    let items: [MediaItem]
    var id: String { category.id }
}

private struct FeaturedCard: View {
    let item: MediaItem
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.poster).frame(maxWidth: .infinity).frame(height: 204).clipped()
            LinearGradient(colors: [XColors.background.opacity(0.2), XColors.background.opacity(0.55), XColors.background.opacity(0.95)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text("最新上线").font(XFont.caption()).foregroundStyle(XColors.accent)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(XColors.background.opacity(0.65), in: Capsule())
                Text(item.name).font(XFont.headline()).foregroundStyle(XColors.textPrimary).lineLimit(2)
                let meta = [item.year, item.area, item.categoryName, item.remarks].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary).lineLimit(1) }
                HStack(spacing: 10) {
                    Text("立即播放").foregroundStyle(XColors.onAccent).padding(.horizontal, 22).padding(.vertical, 10).background(XColors.accent, in: Capsule())
                    Text("详情").foregroundStyle(XColors.textPrimary).padding(.horizontal, 20).padding(.vertical, 10).background(XColors.surfaceRaised, in: Capsule())
                }.font(XFont.bodySmall()).padding(.top, 8)
            }.padding(20)
        }.frame(height: 204).clipShape(RoundedRectangle(cornerRadius: XRadii.lg))
    }
}
