import SwiftUI

/// 与 Android 一致的单页订阅、源站和偏好设置。
struct SettingsView: View {
    var onSiteChanged: () -> Void = {}
    var showsNavigationBar = false

    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var app
    @Environment(\.formFactor) private var form
    @Environment(\.openURL) private var openURL
    @State private var url = DefaultSources.box
    @State private var name = ""
    @State private var liveURL = ""
    @State private var siteQuery = ""
    @State private var submitting = false
    @State private var warehouse: [WarehouseEntry] = []
    @State private var showWarehouse = false
    @State private var message: String?
    @State private var liveMessage: String?
    @State private var showClearConfirm = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(short) (\(build))"
    }

    private var visibleSites: [Site] {
        let query = siteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.usableSites.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .enumerated().sorted { left, right in
                let a = app.isPinned(left.element), b = app.isPinned(right.element)
                return a == b ? left.offset < right.offset : a && !b
            }.map(\.element)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("订阅与设置").font(XFont.headline()).foregroundStyle(XColors.textPrimary)
                    Text("订阅地址决定你能看到什么内容，源站不可用时先换源再排查")
                        .font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary)
                }
                addCard
                heading("已添加的订阅", subtitle: "共 \(app.subscriptions.count) 个")
                if !app.subscriptions.contains(where: { $0.url == DefaultSources.box }) {
                    Button { Task { await submit(DefaultSources.box, name: "默认单仓") } } label: {
                        Text(submitting ? "正在恢复默认订阅，可能需要几十秒" : "恢复默认订阅")
                            .font(XFont.title()).foregroundStyle(XColors.textPrimary)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(XColors.surfaceRaised, in: RoundedRectangle(cornerRadius: XRadii.md))
                    }.buttonStyle(.plain).disabled(submitting)
                    Text("内置单仓（tv.bsdnme.me/box）不在列表里，点按钮一键恢复")
                        .font(XFont.bodySmall()).foregroundStyle(XColors.textTertiary)
                }
                if let error = app.error { notice(error, danger: true) }
                if app.subscriptions.isEmpty {
                    Text("还没有订阅，先在上面添加一个").font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary)
                } else {
                    ForEach(app.subscriptions) { subscription in subscriptionCard(subscription) }
                }
                heading("源站", subtitle: app.skippedSiteCount > 0 ? "\(app.skippedSiteCount) 个源在 iOS 上暂不支持" : "点击切换当前源")
                    .padding(.top, 8)
                field("搜索源站名称", text: $siteQuery)
                    .accessibilityIdentifier("settings-site-search")
                if visibleSites.isEmpty && !siteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("没有找到匹配的源站").font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary)
                } else if app.usableSites.isEmpty {
                    notice("当前订阅没有支持的源站（type 0 / 1 / 4）")
                } else {
                    ForEach(Array(visibleSites.chunked(into: 12).enumerated()), id: \.offset) { _, sites in
                        SettingsFlowLayout(spacing: 8) {
                            ForEach(sites) { site in
                                HStack(spacing: 2) {
                                    pill(site.name, selected: app.currentSite?.key == site.key) {
                                        if app.currentSite?.key != site.key {
                                            app.selectSite(site)
                                            onSiteChanged()
                                            if showsNavigationBar { dismiss() }
                                        }
                                    }
                                    pill(app.isPinned(site) ? "★" : "☆", selected: app.isPinned(site)) {
                                        app.togglePinnedSite(site)
                                    }.accessibilityLabel("\(app.isPinned(site) ? "取消置顶" : "置顶") \(site.name)")
                                }
                            }
                        }
                    }
                }
                heading("直播源", subtitle: "支持 m3u / txt；留空则不使用自定义直播源")
                    .padding(.top, 8)
                field("输入直播源地址", text: $liveURL, isURL: true)
                    .accessibilityIdentifier("settings-live-url")
                pill("保存直播源") {
                    let value = liveURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    app.setLiveURL(value)
                    LiveCache.shared.clear()
                    liveMessage = "已保存直播源"
                }
                if let liveMessage { Text(liveMessage).font(XFont.caption()).foregroundStyle(XColors.success) }
                if let count = app.document?.liveSources.count, count > 0 {
                    Text("订阅内包含 \(count) 个直播源，iOS 暂未接入").font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary)
                }
                heading("偏好设置").padding(.top, 8)
                preference("启动时自动更新订阅", description: "每次打开 App 拉取一次最新配置", value: Binding(get: { app.settings.autoUpdateOnLaunch }, set: { app.setAutoUpdate($0) }))
                preference("启动时检查更新", description: "启动时检查 iOS 版本", value: Binding(get: { app.settings.autoCheckUpdate }, set: { app.setAutoCheckUpdate($0) }))
                heading("关于").padding(.top, 8)
                aboutCard
                maintenance
            }
            .padding(.horizontal, form.horizontalPadding)
            .padding(.vertical, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: form.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(XColors.background)
        .navigationTitle("订阅与设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        .onAppear { liveURL = app.settings.liveUrl.isEmpty ? DefaultSources.live : app.settings.liveUrl }
        .onChange(of: app.settings.liveUrl) { _, value in liveURL = value }
        .confirmationDialog("这是多仓订阅，请选择一个子仓库导入", isPresented: $showWarehouse, titleVisibility: .visible) {
            ForEach(warehouse) { entry in
                Button(entry.name) { Task { await submit(entry.url, name: entry.name) } }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("清空观看历史？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { app.clearHistory() }
        } message: { Text("收藏不受影响。") }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加订阅").font(XFont.title()).foregroundStyle(XColors.textPrimary)
            field("输入订阅地址", text: $url, isURL: true).accessibilityIdentifier("settings-subscription-url")
            (Text("巴萨的内马尔").foregroundColor(XColors.accent) + Text(" · 链接标识 bsdnme 取自名字的拼音首字母").foregroundColor(XColors.textSecondary))
                .font(XFont.caption())
            field("备注名称（可留空）", text: $name)
            SettingsFlowLayout(spacing: 8) {
                pill("单仓 /box", selected: url == DefaultSources.box) { url = DefaultSources.box }
                pill("多仓 /dc", selected: url == DefaultSources.warehouse) { url = DefaultSources.warehouse }
                pill("直播 /live", selected: liveURL == DefaultSources.live) {
                    liveURL = DefaultSources.live
                    app.setLiveURL(DefaultSources.live)
                    LiveCache.shared.clear()
                    liveMessage = "已保存直播源"
                }
            }
            Button { Task { await submit(url, name: name) } } label: {
                HStack(spacing: 8) {
                    if submitting { ProgressView().tint(XColors.onAccent) }
                    Text(submitting ? "正在加载订阅，可能需要几十秒" : "添加并加载")
                }
                .font(XFont.title()).foregroundStyle(XColors.onAccent)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(XColors.accent, in: RoundedRectangle(cornerRadius: XRadii.md))
            }.buttonStyle(.plain).disabled(submitting || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings-add-subscription")
            if let message { notice(message, danger: app.error != nil) }
        }
        .padding(16).background(XColors.surface, in: RoundedRectangle(cornerRadius: XRadii.lg))
    }

    private func subscriptionCard(_ subscription: Subscription) -> some View {
        let active = subscription.id == app.settings.activeSubscriptionId
        let refreshing = subscription.id == app.refreshingSubscriptionId
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(active ? XColors.success : XColors.textTertiary).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.name).font(XFont.title()).foregroundStyle(XColors.textPrimary).lineLimit(1)
                    Text(subscription.url).font(XFont.bodySmall()).foregroundStyle(XColors.textTertiary).lineLimit(1)
                    Text("\(subscription.siteCount) 个源 · \(relativeTime(subscription.updatedAt))")
                        .font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if !active { pill("启用") { app.activateSubscription(subscription.id) } }
                pill(refreshing ? "更新中…" : "更新") { Task { await app.refreshSubscription(id: subscription.id) } }
                    .disabled(app.loading)
                pill("删除") { app.removeSubscription(subscription.id) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(XColors.surface, in: RoundedRectangle(cornerRadius: XRadii.md))
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("AndroidBrand").resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("飞哥影视仓").font(XFont.title()).foregroundStyle(XColors.textPrimary)
                    (Text("由 ").foregroundColor(XColors.textSecondary) + Text("巴萨的内马尔").foregroundColor(XColors.accent) + Text(" 打造").foregroundColor(XColors.textSecondary)).font(XFont.caption())
                }
                Spacer(minLength: 4)
                Text(version).font(XFont.caption()).foregroundStyle(XColors.textSecondary)
            }
            Rectangle().fill(XColors.divider).frame(height: 1)
            SettingsFlowLayout(spacing: 10) {
                Button { Task { await app.checkUpdate(manual: true) } } label: {
                    Text(app.checkingUpdate ? "检查中…" : "检查更新").font(XFont.caption()).foregroundStyle(XColors.onAccent)
                        .padding(.horizontal, 14).frame(height: 32).background(XColors.accent, in: RoundedRectangle(cornerRadius: XRadii.md))
                }.buttonStyle(.plain).disabled(app.checkingUpdate)
                Button { if let url = URL(string: "https://bsdnme.me/") { openURL(url) } } label: {
                    Text("个人网站 bsdnme.me").font(XFont.caption()).foregroundStyle(XColors.textPrimary)
                        .padding(.horizontal, 14).frame(height: 32).background(XColors.surfaceRaised, in: RoundedRectangle(cornerRadius: XRadii.md))
                }.buttonStyle(.plain)
            }
            if let message = app.updateMessage { Text(message).font(XFont.caption()).foregroundStyle(XColors.textSecondary) }
            Text("内容来自订阅地址，播放格式支持情况取决于 iOS 和媒体编码。")
                .font(XFont.bodySmall()).foregroundStyle(XColors.textTertiary)
        }.padding(16).background(XColors.surface, in: RoundedRectangle(cornerRadius: XRadii.lg))
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("维护")
            SettingsFlowLayout(spacing: 8) {
                pill("清空观看历史") { showClearConfirm = true }
                pill("清空缓存与搜索记录") { LiveCache.shared.clear(); app.clearSearchHistory() }
            }
        }.padding(.top, 8)
    }

    private func heading(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(XFont.section()).foregroundStyle(XColors.textPrimary)
            if let subtitle { Text(subtitle).font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary) }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, isURL: Bool = false) -> some View {
        TextField(placeholder, text: text).font(XFont.body()).foregroundStyle(XColors.textPrimary)
            .textInputAutocapitalization(isURL ? .never : .sentences).autocorrectionDisabled(isURL)
            .keyboardType(isURL ? .URL : .default).padding(.horizontal, 16).frame(height: 52)
            .background(XColors.surfaceRaised, in: Capsule()).tint(XColors.accent)
    }

    private func pill(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(XFont.bodySmall()).foregroundStyle(selected ? XColors.onAccent : XColors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? XColors.accent : XColors.surfaceRaised, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func preference(_ title: String, description: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(XFont.title()).foregroundStyle(XColors.textPrimary)
                Text(description).font(XFont.bodySmall()).foregroundStyle(XColors.textSecondary)
            }
        }.tint(XColors.accent).padding(.vertical, 8)
    }

    private func notice(_ text: String, danger: Bool = false) -> some View {
        Text(text).font(XFont.bodySmall()).foregroundStyle(danger ? XColors.danger : XColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit(_ address: String, name: String) async {
        guard !submitting else { return }
        submitting = true; message = nil
        defer { submitting = false }
        switch await app.addSubscription(address, name: name.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .success: message = "订阅已添加"; self.name = ""; siteQuery = ""
        case let .needWarehouse(entries): warehouse = entries; showWarehouse = true
        case let .failure(error): message = error
        }
    }

    private func relativeTime(_ timestamp: Int64?) -> String {
        guard let timestamp, timestamp > 0 else { return "未更新" }
        let minutes = max(0, Int(Date().timeIntervalSince1970 - Double(timestamp)) / 60)
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        if minutes < 1440 { return "\(minutes / 60) 小时前更新" }
        return "\(minutes / 1440) 天前更新"
    }
}

/// Wraps chips using their measured widths, matching Android's FlowRow.
private struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews: subviews, width: proposal.width ?? .greatestFiniteMagnitude).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews: subviews, width: bounds.width)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxWidth = max(maxWidth, x - spacing)
        }
        return (CGSize(width: min(maxWidth, width), height: y + rowHeight), points)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// Used by the existing subscription and live-source detail views.
struct LabeledRow: View {
    let icon: String
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(spacing: XSpacing.md) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(XColors.accent).frame(width: 22)
            Text(title).font(XFont.body()).foregroundStyle(XColors.textPrimary)
            Spacer(minLength: XSpacing.sm)
            if !detail.isEmpty { Text(detail).font(XFont.caption()).foregroundStyle(XColors.textTertiary).lineLimit(1) }
        }
    }
}
