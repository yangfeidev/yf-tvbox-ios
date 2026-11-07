import SwiftUI

/**
 搜索。

 只搜当前站点——跨源搜索需要遍历所有源的接口，代价与失败率都高，
 Android 版也还没做，这里保持一致。
 */
struct SearchView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var hasSearched = false
    @State private var searchGeneration = 0
    @State private var didFocusOnEntry = false
    @FocusState private var focused: Bool

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: form.spacing), count: form.gridColumns)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if let errorText {
                ErrorBanner(message: errorText) { self.errorText = nil }
                    .padding(.horizontal, form.horizontalPadding)
                    .padding(.top, XSpacing.sm)
            }

            ScrollView {
                if loading {
                    LoadingBlock(text: "搜索中")
                } else if hasSearched {
                    if results.isEmpty {
                        EmptyBlock(icon: "magnifyingglass", title: "没有找到相关影片")
                    } else {
                        LazyVGrid(columns: columns, spacing: form.spacing) {
                            ForEach(results) { item in
                                NavigationLink(value: item) {
                                    PosterGridCell(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, form.horizontalPadding)
                        .padding(.top, XSpacing.md)
                    }
                } else {
                    idleState
                }
            }
        }
        .background(XColors.background)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didFocusOnEntry else { return }
            // 等导航转场完成后再请求焦点，避免键盘被转场吞掉。
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            didFocusOnEntry = true
            focused = true
        }
        .onChange(of: app.currentSite) { _, _ in
            searchGeneration += 1
            loading = false
            results = []
            hasSearched = false
            errorText = nil
        }
        .navigationDestination(for: MediaItem.self) { item in
            DetailView(item: item)
        }
    }

    private var searchBar: some View {
        HStack(spacing: XSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(XColors.textTertiary)
                TextField("搜索影片、剧集", text: $query)
                    .font(XFont.body())
                    .foregroundStyle(XColors.textPrimary)
                    .focused($focused)
                    .accessibilityIdentifier("search-query")
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await search() } }
                if !query.isEmpty {
                    Button {
                        searchGeneration += 1
                        loading = false
                        errorText = nil
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(XColors.textTertiary)
                    }
                }
            }
            .padding(.horizontal, XSpacing.md)
            .padding(.vertical, 10)
            .background(XColors.surfaceRaised, in: Capsule())

            Button("搜索") { Task { await search() } }
                .font(XFont.bodySmall())
                .foregroundStyle(XColors.accent)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, form.horizontalPadding)
        .padding(.vertical, XSpacing.sm)
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: XSpacing.md) {
            if !app.searchHistory.isEmpty {
                HStack {
                    Text("最近搜索")
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textSecondary)
                    Spacer()
                    Button("清空") { app.clearSearchHistory() }
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                }

                FlowChips(items: app.searchHistory) { keyword in
                    query = keyword
                    Task { await search() }
                }
            } else {
                EmptyBlock(
                    icon: "text.magnifyingglass",
                    title: "搜点什么",
                    message: app.currentSite.map { "当前站点：\($0.name)" } ?? "还没有选择站点"
                )
            }
        }
        .padding(.horizontal, form.horizontalPadding)
        .padding(.top, XSpacing.md)
    }

    private func search() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        guard let site = app.currentSite else {
            errorText = "还没有选择站点"
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        focused = false
        loading = true
        errorText = nil
        hasSearched = true
        defer { if generation == searchGeneration { loading = false } }

        do {
            let page = try await VodApi.search(site: site, keyword: keyword)
            guard generation == searchGeneration else { return }
            results = page.items
            app.recordSearch(keyword)
        } catch {
            guard generation == searchGeneration, !Http.isCancellation(error) else { return }
            errorText = (error as? SourceError)?.message ?? error.localizedDescription
            results = []
        }
    }
}

/// 自动换行的胶囊列表（搜索历史）
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        SearchHistoryLayout(spacing: XSpacing.sm) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, XSpacing.md)
                        .padding(.vertical, 7)
                        .background(XColors.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 按内容宽度排列，过长的关键词限制在可用宽度内并自动换行。
private struct SearchHistoryLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(subviews, width: proposal.width ?? .greatestFiniteMagnitude).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(subviews, width: bounds.width)
        for (index, entry) in layout.entries.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + entry.origin.x, y: bounds.minY + entry.origin.y),
                                  proposal: ProposedViewSize(width: entry.width, height: nil))
        }
    }

    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, entries: [(origin: CGPoint, width: CGFloat)]) {
        let availableWidth = max(0, width)
        var entries: [(origin: CGPoint, width: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let idealWidth = subview.sizeThatFits(.unspecified).width
            let itemWidth = min(idealWidth, availableWidth)
            let size = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            if x > 0 && x + size.width > availableWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            entries.append((CGPoint(x: x, y: y), itemWidth))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), entries)
    }
}
