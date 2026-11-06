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
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await search() } }
                if !query.isEmpty {
                    Button {
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

        focused = false
        loading = true
        errorText = nil
        hasSearched = true
        defer { loading = false }

        do {
            let page = try await VodApi.search(site: site, keyword: keyword)
            results = page.items
            app.recordSearch(keyword)
        } catch {
            guard !Http.isCancellation(error) else { return }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), alignment: .leading)], alignment: .leading, spacing: XSpacing.sm) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, XSpacing.md)
                        .padding(.vertical, 7)
                        .background(XColors.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
