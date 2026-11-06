import SwiftUI

/**
 分类列表。

 分页在滚动到底部时触发；`pageCount` 由源站返回，不自己猜。
 */
struct CategoryView: View {

    let category: Category

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
        .navigationTitle(category.name)
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
            let result = try await VodApi.list(site: site, typeId: category.typeId, page: target)
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
