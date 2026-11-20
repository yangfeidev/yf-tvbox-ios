import SwiftUI

/**
 收藏与历史。

 历史点开时如果记录来自别的站点，先切站点再进详情——
 同一部片在不同源里的 id 不通用，不切站点会打不开。
 */
struct LibraryView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var tab = 0
    @State private var pendingItem: MediaItem?
    @State private var missingSite = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: form.spacing), count: form.gridColumns)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                libraryTab("收藏 \(app.visibleFavorites.count)", index: 0)
                libraryTab("历史 \(app.visibleHistory.count)", index: 1)
                Spacer()
            }
            .padding(.horizontal, form.horizontalPadding)
            .padding(.vertical, XSpacing.sm)

            ScrollView {
                if tab == 0 {
                    favoritesGrid
                } else {
                    historyList
                }
            }
        }
        .background(XColors.background)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pendingItem) { item in
            DetailView(item: item)
        }
        .alert("找不到原站点", isPresented: $missingSite) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请切换到包含该站点的订阅后重试。")
        }
        .toolbar {
            if tab == 1, !app.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { app.clearHistory() }
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                }
            }
        }
    }

    private var favoritesGrid: some View {
        Group {
            if app.visibleFavorites.isEmpty {
                EmptyBlock(icon: "heart", title: "还没有收藏", message: "在详情页点右上角的心形即可收藏")
            } else {
                LazyVGrid(columns: columns, spacing: form.spacing) {
                    ForEach(app.visibleFavorites) { entry in
                        Button {
                            open(entry)
                        } label: {
                            PosterGridCell(item: entry.toMediaItem())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                app.removeFavorite(entry)
                            } label: {
                                Label("取消收藏", systemImage: "heart.slash")
                            }
                        }
                    }
                }
                .padding(.horizontal, form.horizontalPadding)
                .padding(.top, XSpacing.md)
            }
        }
    }

    private var historyList: some View {
        Group {
            if app.visibleHistory.isEmpty {
                EmptyBlock(icon: "clock", title: "还没有观看记录")
            } else {
                LazyVGrid(columns: columns, spacing: form.spacing) {
                    ForEach(app.visibleHistory) { entry in
                        VStack(spacing: 6) {
                            Button { open(entry) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    PosterGridCell(item: entry.toMediaItem())
                                    if entry.progress > 0 {
                                        ProgressView(value: Double(entry.progress)).tint(XColors.accent)
                                    }
                                }
                            }.buttonStyle(.plain)
                            Button("删除记录") { app.removeHistory(entry) }
                                .font(XFont.caption()).foregroundStyle(XColors.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(XColors.surfaceRaised, in: Capsule())
                        }
                    }
                }.padding(.horizontal, form.horizontalPadding).padding(.top, XSpacing.md)
            }
        }
    }

    private func libraryTab(_ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            Text(title).font(XFont.bodySmall())
                .foregroundStyle(tab == index ? XColors.onAccent : XColors.textSecondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(tab == index ? XColors.accent : XColors.surfaceRaised, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func open(_ entry: LibraryEntry) {
        guard let site = app.usableSites.first(where: { $0.key == entry.siteKey }) else {
            missingSite = true
            return
        }
        if site.key != app.currentSite?.key { app.selectSite(site) }
        pendingItem = entry.toMediaItem()
    }
}

private struct HistoryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: XSpacing.md) {
            RemoteImage(url: entry.poster)
                .frame(width: 52, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: XRadii.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(XFont.body())
                    .foregroundStyle(XColors.textPrimary)
                    .lineLimit(1)

                if !entry.episodeName.isEmpty {
                    Text(entry.episodeName)
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(XColors.bar)
                        Capsule()
                            .fill(XColors.accent)
                            .frame(width: geo.size.width * CGFloat(min(max(entry.progress, 0), 1)))
                    }
                }
                .frame(height: 3)
                .frame(width: 140)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(Int(min(max(entry.progress, 0), 1) * 100))%")
                .font(XFont.caption())
                .foregroundStyle(XColors.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, XSpacing.sm)
        .contentShape(Rectangle())
    }
}
