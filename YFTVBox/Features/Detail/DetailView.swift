import SwiftUI

/**
 详情页。

 结构对齐 Android 版：海报头图 + 基本信息 + 收藏/播放 + 简介 + 线路切换 + 剧集网格。
 进页面先找上次看到哪一集，命中就把「继续观看」提到主按钮位置。
 */
struct DetailView: View {

    let item: MediaItem
    var autoResume = false

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var detail: MediaDetail?
    @State private var loading = true
    @State private var errorText: String?
    @State private var sourceIndex = 0
    @State private var session: PlaybackSession?
    @State private var descExpanded = false

    private var site: Site? { app.currentSite }
    private var posterWidth: CGFloat { form.isTablet ? 168 : 108 }
    private var episodeColumns: Int { form.isTablet ? 8 : 4 }
    private var sources: [PlaySource] { detail?.usableSources ?? [] }
    private var resume: ResumeTarget? {
        guard let site else { return nil }
        return findResumeTarget(
            sources: sources,
            history: app.historyEntry(siteKey: site.key, mediaId: item.id)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: XSpacing.lg) {
                if let errorText {
                    ErrorBanner(message: errorText) { self.errorText = nil }
                }

                if !app.familyMode || detail != nil {
                    header
                    actionRow
                }

                if let detail, !detail.content.isEmpty {
                    synopsis(detail.content)
                }

                if !sources.isEmpty {
                    sourcePicker
                    episodeGrid
                } else if !loading && detail != nil {
                    EmptyBlock(
                        icon: "link.badge.plus",
                        title: "没有可播放的直链",
                        message: "这个源只提供网页播放地址，iOS 版暂不支持网页解析"
                    )
                }

                if loading {
                    LoadingBlock()
                }
            }
            .padding(.horizontal, form.horizontalPadding)
            .padding(.bottom, XSpacing.xxl)
            // 平板上不限宽的话正文会拉到 720pt，一行几十个字根本没法读
            .frame(maxWidth: form.isTablet ? 760 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(XColors.background)
        .navigationTitle(app.familyMode && detail == nil ? "详情" : (detail?.item.name ?? item.name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $session) { session in
            PlayerScreen(session: session)
                .environment(app)
                .environment(\.formFactor, form)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: XSpacing.lg) {
            RemoteImage(url: detail?.item.poster ?? item.poster)
                .frame(width: posterWidth, height: posterWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: XRadii.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: XRadii.md, style: .continuous)
                        .stroke(XColors.divider, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(detail?.item.name ?? item.name)
                    .font(XFont.headline())
                    .foregroundStyle(XColors.textPrimary)
                    .lineLimit(2)

                let meta = detail?.metaLine ?? item.remarks
                if !meta.isEmpty {
                    Text(meta)
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textSecondary)
                        .lineLimit(2)
                }

                if let actor = detail?.actor, !actor.isEmpty {
                    Text("主演：\(actor)")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                        .lineLimit(2)
                }

                if let director = detail?.director, !director.isEmpty {
                    Text("导演：\(director)")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, XSpacing.md)
    }

    private var actionRow: some View {
        HStack(spacing: XSpacing.md) {
            Button {
                playPrimary()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(primaryTitle)
                        .font(XFont.title())
                }
                .foregroundStyle(XColors.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(XColors.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sources.isEmpty)
            .accessibilityIdentifier("detail-play")

            Button {
                if let site { app.toggleFavorite(detail?.item ?? item, site: site) }
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isFavorited ? XColors.danger : XColors.textSecondary)
                    .frame(width: 46, height: 46)
                    .background(XColors.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail-favorite")
        }
    }

    private var isFavorited: Bool {
        guard let site else { return false }
        return app.isFavorite(detail?.item ?? item, siteKey: site.key)
    }

    private var primaryTitle: String {
        guard let resume, sources.indices.contains(resume.sourceIndex) else { return "立即播放" }
        let episode = sources[resume.sourceIndex].episodes[resume.episodeIndex]
        return "继续 \(episode.name)"
    }

    private func synopsis(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.sm) {
            Text("简介")
                .font(XFont.section())
                .foregroundStyle(XColors.textPrimary)
            Text(content)
                .font(XFont.body())
                .foregroundStyle(XColors.textSecondary)
                .lineLimit(descExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            // 短简介撑不到 4 行，给个"展开"按钮反而像没做完
            if content.count > 60 {
                Button(descExpanded ? "收起" : "展开") {
                    withAnimation { descExpanded.toggle() }
                }
                .font(XFont.caption())
                .foregroundStyle(XColors.accent)
            }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: XSpacing.sm) {
            Text("线路")
                .font(XFont.section())
                .foregroundStyle(XColors.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: XSpacing.sm) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        Chip(
                            title: "\(source.name)（\(source.episodes.count)）",
                            selected: index == sourceIndex
                        ) {
                            sourceIndex = index
                        }
                    }
                }
            }
        }
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: XSpacing.sm) {
            Text("选集")
                .font(XFont.section())
                .foregroundStyle(XColors.textPrimary)

            // 固定 4 列：自适应列在只有 1 集时会把按钮拉成一条很宽的长条
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: XSpacing.sm), count: episodeColumns),
                spacing: XSpacing.sm
            ) {
                ForEach(Array(currentEpisodes.enumerated()), id: \.offset) { index, episode in
                    Button {
                        start(sourceIndex: sourceIndex, episodeIndex: index)
                    } label: {
                        Text(episode.name)
                            .font(XFont.bodySmall())
                            .foregroundStyle(isCurrent(episode: episode) ? XColors.onAccent : XColors.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                isCurrent(episode: episode) ? XColors.accent : XColors.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: XRadii.sm, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var currentEpisodes: [Episode] {
        sources.indices.contains(sourceIndex) ? sources[sourceIndex].episodes : []
    }

    private func isCurrent(episode: Episode) -> Bool {
        guard let resume, sources.indices.contains(resume.sourceIndex) else { return false }
        return resume.episodeIndex == currentEpisodes.firstIndex(where: { $0.id == episode.id })
            && resume.sourceIndex == sourceIndex
    }

    // MARK: - 行为

    private func load() async {
        guard let site else {
            loading = false
            errorText = "没有选中的站点"
            return
        }
        loading = true
        defer { loading = false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DEBUG_HOME_HIT_TEST"] == "1" {
            detail = MediaDetail(item: item, playSources: [PlaySource(name: "测试", episodes: [Episode(name: "测试", url: "http://127.0.0.1/video.m3u8")])])
            return
        }
        #endif
        do {
            let result = try await app.familyContent.detail(site: site, id: item.id, family: app.familyMode)
            detail = result
            errorText = nil
            if let resume = findResumeTarget(
                sources: result.usableSources,
                history: app.historyEntry(siteKey: site.key, mediaId: item.id)
            ) {
                sourceIndex = resume.sourceIndex
            } else {
                // 默认使用“换一条线路”切换到的下一条；只有一条时仍用第一条。
                sourceIndex = result.usableSources.count > 1 ? 1 : 0
            }
            if autoResume { playPrimary() }
        } catch {
            guard !Http.isCancellation(error) else { return }
            errorText = (error as? SourceError)?.message ?? error.localizedDescription
            if detail == nil && !app.familyMode {
                detail = MediaDetail(item: item)
            }
        }
    }

    private func playPrimary() {
        if let resume {
            guard sources.indices.contains(sourceIndex),
                  let episode = matchingEpisodeIndex(
                    name: sources[resume.sourceIndex].episodes[resume.episodeIndex].name,
                    index: resume.episodeIndex, in: sources[sourceIndex]
                  ) else {
                start(sourceIndex: sourceIndex, episodeIndex: 0)
                return
            }
            start(
                sourceIndex: sourceIndex,
                episodeIndex: episode,
                resumeFraction: Double(resume.progress)
            )
        } else {
            start(sourceIndex: sourceIndex, episodeIndex: 0)
        }
    }

    private func start(sourceIndex: Int, episodeIndex: Int, resumeFraction: Double = 0) {
        guard sources.indices.contains(sourceIndex) else { return }
        let episodes = sources[sourceIndex].episodes
        guard episodes.indices.contains(episodeIndex) else { return }

        session = PlaybackSession(
            title: detail?.item.name ?? item.name,
            subtitle: episodes[episodeIndex].name,
            sources: sources,
            sourceIndex: sourceIndex,
            episodeIndex: episodeIndex,
            headers: [:],
            isLive: false,
            libraryItem: detail?.item ?? item,
            librarySite: site,
            resumeFraction: resumeFraction
        )
    }
}
