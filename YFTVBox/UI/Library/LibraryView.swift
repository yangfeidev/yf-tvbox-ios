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

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: form.spacing), count: form.gridColumns)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("收藏 \(app.favorites.count)").tag(0)
                Text("历史 \(app.history.count)").tag(1)
            }
            .pickerStyle(.segmented)
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
        .navigationTitle("我的影视")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pendingItem) { item in
            DetailView(item: item)
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
            if app.favorites.isEmpty {
                EmptyBlock(icon: "heart", title: "还没有收藏", message: "在详情页点右上角的心形即可收藏")
            } else {
                LazyVGrid(columns: columns, spacing: form.spacing) {
                    ForEach(app.favorites) { entry in
                        Button {
                            open(entry)
                        } label: {
                            PosterGridCell(item: entry.toMediaItem())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                if let site = app.usableSites.first(where: { $0.key == entry.siteKey }) {
                                    app.toggleFavorite(entry.toMediaItem(), site: site)
                                }
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
            if app.history.isEmpty {
                EmptyBlock(icon: "clock", title: "还没有观看记录")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(app.history) { entry in
                        Button {
                            open(entry)
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                app.removeHistory(entry)
                            } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        }

                        Divider().overlay(XColors.divider)
                            .padding(.leading, form.horizontalPadding + 64)
                    }
                }
                .padding(.top, XSpacing.sm)
            }
        }
    }

    private func open(_ entry: LibraryEntry) {
        if let site = app.usableSites.first(where: { $0.key == entry.siteKey }),
           site.key != app.currentSite?.key {
            app.selectSite(site)
        }
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
