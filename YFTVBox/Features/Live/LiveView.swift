import SwiftUI

/**
 直播。

 直播源只有一个地址（可在「我的 → 直播源」改），
 拉回来按 group-title 分组；聚合地址首次要 30~45 秒，所以有磁盘缓存。
 */
struct LiveView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var groups: [ChannelGroup] = []
    @State private var selectedGroup = ""
    @State private var loading = false
    @State private var errorText: String?
    @State private var session: PlaybackSession?
    @State private var loadGeneration = 0

    private var currentGroup: ChannelGroup? {
        groups.first { $0.name == selectedGroup } ?? groups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if !groups.isEmpty {
                groupPicker
            }

            if loading, groups.isEmpty {
                LoadingBlock(text: "正在加载直播源")
            } else if let errorText, groups.isEmpty {
                VStack(spacing: XSpacing.md) {
                    ErrorBanner(message: errorText)
                    Button("重试") { Task { await load(force: true) } }
                        .buttonStyle(.borderedProminent)
                        .tint(XColors.accent)
                    NavigationLink("去设置直播源") { LiveSourceView() }
                        .font(XFont.caption())
                        .foregroundStyle(XColors.accent)
                }
                .padding(form.horizontalPadding)
            } else if groups.isEmpty {
                EmptyBlock(
                    icon: "tv",
                    title: "没有直播源",
                    message: "在「我的 → 直播源」里填一个 m3u 或 txt 地址"
                )
            } else {
                channelGrid
            }
        }
        .background(XColors.background)
        .navigationTitle("直播")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load(force: true) }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(XColors.textSecondary)
                    }
                }
                .disabled(loading)
            }
        }
        .task(id: app.settings.liveUrl) {
            groups = []
            selectedGroup = ""
            await load()
        }
        .fullScreenCover(item: $session) { session in
            PlayerScreen(session: session)
                .environment(app)
                .environment(\.formFactor, form)
        }
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: XSpacing.sm) {
                ForEach(groups) { group in
                    Chip(
                        title: "\(group.name) \(group.channels.count)",
                        selected: group.name == currentGroup?.name
                    ) {
                        selectedGroup = group.name
                    }
                }
            }
            .padding(.horizontal, form.horizontalPadding)
            .padding(.vertical, XSpacing.sm)
        }
    }

    private var channelGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: form.isTablet ? 140 : 104), spacing: XSpacing.sm)],
                spacing: XSpacing.sm
            ) {
                ForEach(currentGroup?.channels ?? []) { channel in
                    Button {
                        play(channel)
                    } label: {
                        ChannelCell(channel: channel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("channel-\(channel.id)")
                }
            }
            .padding(.horizontal, form.horizontalPadding)
            .padding(.vertical, XSpacing.sm)
        }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        errorText = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            let result = try await app.loadLive(forceRefresh: force)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            groups = result
            if selectedGroup.isEmpty { selectedGroup = result.first?.name ?? "" }
        } catch {
            guard generation == loadGeneration, !Http.isCancellation(error) else { return }
            errorText = (error as? SourceError)?.message ?? error.localizedDescription
        }
    }

    private func play(_ channel: Channel) {
        let episode = Episode(name: channel.name, url: channel.url)
        session = PlaybackSession(
            title: channel.name,
            subtitle: currentGroup?.name ?? "",
            sources: [PlaySource(name: "直播", episodes: [episode])],
            sourceIndex: 0,
            episodeIndex: 0,
            headers: channel.headers,
            isLive: true
        )
    }
}

private struct ChannelCell: View {
    let channel: Channel

    var body: some View {
        VStack(spacing: 4) {
            RemoteImage(url: channel.logo, fit: true)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: XRadii.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: XRadii.sm, style: .continuous)
                        .stroke(XColors.divider, lineWidth: 0.5)
                )

            Text(channel.name)
                .font(XFont.caption())
                .foregroundStyle(XColors.textSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
