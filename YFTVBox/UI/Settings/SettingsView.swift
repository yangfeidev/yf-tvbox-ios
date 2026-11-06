import SwiftUI

/**
 我的（设置）。

 这一栏承担 Android 版里「收藏 + 订阅 + 站点 + 直播源 + 设置」的全部入口。
 */
struct SettingsView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form

    @State private var showClearConfirm = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SubscriptionListView()
                } label: {
                    LabeledRow(icon: "arrow.down.circle", title: "订阅管理", detail: "\(app.subscriptions.count) 个")
                }
                .accessibilityIdentifier("settings-subscriptions")

                if let site = app.currentSite {
                    NavigationLink {
                        SiteListView()
                    } label: {
                        LabeledRow(icon: "rectangle.stack", title: "当前站点", detail: site.name)
                    }
                }

                Button {
                    Task { await app.refreshActive() }
                } label: {
                    LabeledRow(
                        icon: "arrow.clockwise",
                        title: app.loading ? "刷新中…" : "刷新订阅"
                    )
                }
                .disabled(app.loading || app.subscriptions.isEmpty)

                if app.skippedSiteCount > 0 {
                    NavigationLink {
                        SiteListView()
                    } label: {
                        HStack(spacing: XSpacing.md) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 14))
                                .foregroundStyle(XColors.info)
                                .frame(width: 22)
                            Text("\(app.skippedSiteCount) 个源在 iOS 上不可用")
                                .font(XFont.bodySmall())
                                .foregroundStyle(XColors.textSecondary)
                            Spacer(minLength: XSpacing.sm)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundStyle(XColors.textTertiary)
                        }
                    }
                }
            } header: {
                Text("内容源")
            }
            .listRowBackground(XColors.surface)

            Section {
                NavigationLink {
                    LibraryView()
                } label: {
                    LabeledRow(
                        icon: "heart",
                        title: "收藏与历史",
                        detail: "\(app.favorites.count) / \(app.history.count)"
                    )
                }
            } header: {
                Text("我的")
            }
            .listRowBackground(XColors.surface)

            Section {
                NavigationLink {
                    LiveSourceView()
                } label: {
                    LabeledRow(icon: "tv", title: "直播源", detail: liveHost)
                }
                .accessibilityIdentifier("settings-live")
            } header: {
                Text("直播")
            }
            .listRowBackground(XColors.surface)

            Section {
                Toggle(isOn: Binding(
                    get: { app.settings.autoUpdateOnLaunch },
                    set: { app.setAutoUpdate($0) }
                )) {
                    Text("启动时刷新订阅")
                        .font(XFont.body())
                        .foregroundStyle(XColors.textPrimary)
                }
                .tint(XColors.accent)

                Toggle(isOn: Binding(
                    get: { app.settings.autoCheckUpdate },
                    set: { app.setAutoCheckUpdate($0) }
                )) {
                    Text("启动时检查更新")
                        .font(XFont.body())
                        .foregroundStyle(XColors.textPrimary)
                }
                .tint(XColors.accent)
            } header: {
                Text("设置")
            } footer: {
                Text("每次冷启动会拉一次最新订阅，保证源站列表不过期。")
                    .font(XFont.caption())
            }
            .listRowBackground(XColors.surface)

            Section {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("清空观看历史")
                        .font(XFont.body())
                }

                Button {
                    LiveCache.shared.clear()
                    app.clearSearchHistory()
                } label: {
                    Text("清空缓存与搜索记录")
                        .font(XFont.body())
                        .foregroundStyle(XColors.textPrimary)
                }
            } header: {
                Text("维护")
            }
            .listRowBackground(XColors.surface)

            Section {
                HStack {
                    Text("版本").font(XFont.body()).foregroundStyle(XColors.textPrimary)
                    Spacer()
                    Text(version)
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textTertiary)
                        .monospacedDigit()
                }

                Button {
                    Task { await app.checkUpdate(manual: true) }
                } label: {
                    HStack {
                        Text("检查更新")
                            .font(XFont.body())
                            .foregroundStyle(XColors.accent)
                        Spacer()
                        if app.checkingUpdate {
                            ProgressView().tint(XColors.accent)
                        }
                    }
                }
                .disabled(app.checkingUpdate)

                if let message = app.updateMessage {
                    Text(message)
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("关于播放格式")
                        .font(XFont.bodySmall())
                        .foregroundStyle(XColors.textSecondary)
                    Text("iOS 播放内核只支持 HLS 与 MP4。遇到 .flv / .mkv / .ts 直链会提示无法解码，换一条线路即可。")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("关于")
            }
            .listRowBackground(XColors.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(XColors.background)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清空观看历史？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { app.clearHistory() }
        } message: {
            Text("收藏不受影响。")
        }
    }

    private var liveHost: String {
        let url = app.settings.liveUrl
        guard !url.isEmpty else { return "未设置" }
        return url.components(separatedBy: "://").last?
            .components(separatedBy: "/").first ?? url
    }
}

struct LabeledRow: View {
    let icon: String
    let title: String
    var detail: String = ""

    var body: some View {
        HStack(spacing: XSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(XColors.accent)
                .frame(width: 22)

            Text(title)
                .font(XFont.body())
                .foregroundStyle(XColors.textPrimary)

            Spacer(minLength: XSpacing.sm)

            if !detail.isEmpty {
                Text(detail)
                    .font(XFont.caption())
                    .foregroundStyle(XColors.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}
