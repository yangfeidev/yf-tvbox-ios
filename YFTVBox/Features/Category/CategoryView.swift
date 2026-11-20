import SwiftUI

/**
 分类列表。

 分页在滚动到底部时触发；`pageCount` 由源站返回，不自己猜。
 */
struct CategoryView: View {

    let category: Category?
    var categories: [Category] = []

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var items: [MediaItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var errorText: String?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: form.spacing), count: form.gridColumns)
    }

    var body: some View {
        ScrollView {
            if let errorText {
                ErrorBanner(message: errorText) { self.errorText = nil }
                    .padding(XSpacing.lg)
            }

            LazyVGrid(columns: columns, spacing: form.spacing) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterGridCell(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == items.last?.id {
                            Task { await loadPage(page + 1) }
                        }
                    }
                }
            }
            .padding(.horizontal, form.horizontalPadding)

            if loading {
                LoadingBlock()
            } else if items.isEmpty, errorText == nil {
                EmptyBlock(icon: "film", title: "这个分类没有内容")
            }
        }
        .background(XColors.background)
        .navigationTitle(category?.name ?? "全部")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if items.isEmpty { await loadPage(1) }
        }
        .refreshable {
            await loadPage(1, reset: true)
        }
    }

    private func loadPage(_ target: Int, reset: Bool = false) async {
        guard let site = app.currentSite, !loading else { return }
        if !reset, target > pageCount { return }
        loading = true
        defer { loading = false }

        do {
            var result = try await app.familyContent.list(site: site, typeId: category?.typeId ?? "", page: target, family: app.familyMode)
            if let category, categories.contains(where: { $0.parentId == category.typeId }) {
                let children = try await app.familyContent.listChildren(site: site, parentId: category.typeId, categories: categories, page: target, family: app.familyMode)
                let existing = Set(result.items.map(\.id))
                result.items += children.items.filter { !existing.contains($0.id) }
                result.pageCount = max(result.pageCount, children.pageCount)
            }
            if reset {
                items = result.items
            } else {
                let existing = Set(items.map(\.id))
                items += result.items.filter { !existing.contains($0.id) }
            }
            page = target
            pageCount = result.pageCount
            errorText = nil
        } catch {
            guard !Http.isCancellation(error) else { return }
            errorText = (error as? SourceError)?.message ?? error.localizedDescription
        }
    }
}


/// Android 的分类页：顶部标签与横向分页保持同步，页面不进入导航栈。
struct CategoryBrowserView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form
    @State private var categories: [Category] = []
    @State private var selection = ""
    @State private var categoriesError = false
    @State private var reload = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分类").font(XFont.headline()).foregroundStyle(XColors.textPrimary)
                Spacer()
                Button { reload += 1 } label: { headerIcon("arrow.clockwise") }
                    .accessibilityLabel("刷新")
                NavigationLink { SearchView() } label: { headerIcon("magnifyingglass") }
                    .accessibilityLabel("搜索")
            }
            .padding(.horizontal, form.horizontalPadding)
            .padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryTab("全部", id: "")
                        ForEach(categories) { category in categoryTab(category.name, id: category.typeId) }
                    }.padding(.horizontal, form.horizontalPadding).padding(.vertical, 4)
                }
                .onChange(of: selection) { _, value in
                    withAnimation { proxy.scrollTo(value, anchor: .center) }
                }
            }
            if categoriesError {
                Text("分类加载失败，刷新重试").font(XFont.caption()).foregroundStyle(XColors.textSecondary)
                    .padding(.horizontal, form.horizontalPadding)
            }
            if app.currentSite != nil {
                TabView(selection: $selection) {
                    CategoryView(category: nil, categories: categories).tag("")
                    ForEach(categories) { category in
                        CategoryView(category: category, categories: categories).tag(category.typeId)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .id("\(app.currentSite?.key ?? "")-\(reload)")
            } else {
                EmptyBlock(icon: "tray", title: "暂无可用源站", message: "请先在设置里添加订阅")
            }
        }
        .background(XColors.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        .task(id: "\(app.currentSite?.api ?? "")-\(reload)") {
            guard let site = app.currentSite else { categories = []; selection = ""; return }
            do {
                let loaded = try await app.familyContent.categories(site: site, family: app.familyMode)
                guard !Task.isCancelled else { return }
                var ids = Set<String>()
                categories = loaded.filter { !$0.typeId.isEmpty && ids.insert($0.typeId).inserted }
                if !categories.contains(where: { $0.typeId == selection }) { selection = "" }
                categoriesError = false
            } catch {
                guard !Http.isCancellation(error) else { return }
                categoriesError = true
            }
        }
        .onChange(of: app.currentSite) { _, _ in selection = ""; categories = [] }
    }

    private func categoryTab(_ title: String, id: String) -> some View {
        Button { withAnimation { selection = id } } label: {
            Text(title).font(XFont.bodySmall())
                .foregroundStyle(selection == id ? XColors.onAccent : XColors.textSecondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(selection == id ? XColors.accent : XColors.surfaceRaised, in: Capsule())
        }.buttonStyle(.plain).id(id)
            .accessibilityIdentifier(id.isEmpty ? "category-all" : "category-tab-\(id)")
            .accessibilityValue(selection == id ? "已选择" : "未选择")
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17))
            .foregroundStyle(XColors.textSecondary).frame(width: 40, height: 40)
            .background(XColors.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
