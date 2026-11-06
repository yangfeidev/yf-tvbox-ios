import SwiftUI

/**
 首页。

 数据来源：当前站点的分类表 + 前几个分类的第一页内容。
 分类请求和列表请求分开打（`ac=list` 才带分类表），
 拿到分类后并发拉前 6 个分类，拼成"焦点 + 横轨"的结构。
 */
struct HomeView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var categories: [Category] = []
    @State private var rails: [HomeRail] = []
    @State private var featured: MediaItem?
    @State private var loading = false
    @State private var errorText: String?
    @State private var loadedSiteKey = ""

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
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
        .navigationDestination(for: Category.self) { category in
            CategoryView(category: category)
        }
        .task(id: app.currentSite?.key) { await load() }
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

                if !categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: XSpacing.sm) {
                            ForEach(categories) { category in
                                NavigationLink(value: category) {
                                    Text(category.name)
                                        .font(XFont.bodySmall())
                                        .foregroundStyle(XColors.textSecondary)
                                        .padding(.horizontal, XSpacing.md)
                                        .padding(.vertical, 7)
                                        .background(XColors.surfaceRaised, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, XSpacing.lg)
                        .padding(.trailing, XSpacing.lg)
                    }
                }

                if let featured {
                    SectionHeader(title: "焦点推荐")
                        .padding(.horizontal, XSpacing.lg)
                    NavigationLink(value: featured) {
                        FeaturedCard(item: featured)
                            .padding(.horizontal, XSpacing.lg)
                    }
                    .buttonStyle(.plain)
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

                if !loading, rails.isEmpty, errorText == nil {
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
                    Text("本应用不内置任何内容源。添加你自己的订阅地址后即可浏览。")
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
        guard let site = app.currentSite else { return }
        if !force, loadedSiteKey == site.key, !rails.isEmpty { return }

        loading = true
        errorText = nil
        defer { loading = false }

        do {
            let allCategories = try await VodApi.categories(site: site)
            categories = Array(allCategories.prefix(12))

            let picked = Array(allCategories.filter { $0.parentId.isEmpty || $0.parentId == "0" }.prefix(6))
            let targets = picked.isEmpty ? Array(allCategories.prefix(6)) : picked

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

            rails = targets.enumerated().compactMap { index, category in
                guard let items = results[index], !items.isEmpty else { return nil }
                return HomeRail(category: category, items: items)
            }
            featured = rails.first?.items.first
            loadedSiteKey = site.key
        } catch {
            guard !Http.isCancellation(error) else { return }
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
        HStack(alignment: .top, spacing: XSpacing.md) {
            RemoteImage(url: item.poster)
                .frame(width: 104, height: 156)
                .clipShape(RoundedRectangle(cornerRadius: XRadii.md, style: .continuous))

            VStack(alignment: .leading, spacing: XSpacing.sm) {
                Text(item.name)
                    .font(XFont.headline())
                    .foregroundStyle(XColors.textPrimary)
                    .lineLimit(2)

                let meta = [item.year, item.area, item.categoryName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                }

                if !item.remarks.isEmpty {
                    Text(item.remarks)
                        .font(XFont.caption())
                        .foregroundStyle(XColors.accent)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("查看详情")
                        .font(XFont.caption())
                }
                .foregroundStyle(XColors.onAccent)
                .padding(.horizontal, XSpacing.md)
                .padding(.vertical, 7)
                .background(XColors.accent, in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(XSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(XColors.surface, in: RoundedRectangle(cornerRadius: XRadii.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: XRadii.lg, style: .continuous)
                .stroke(XColors.divider, lineWidth: 0.5)
        )
    }
}
