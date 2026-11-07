import SwiftUI

/**
 订阅管理：多订阅并存，只有一个是"当前激活"的。
 激活时会先用本地缓存把界面顶起来，再后台刷新，避免一片空白。
 */
struct SubscriptionListView: View {

    @Environment(AppViewModel.self) private var app
    @State private var showAdd = false

    var body: some View {
        List {
            if app.subscriptions.isEmpty {
                EmptyBlock(
                    icon: "arrow.down.circle",
                    title: "还没有订阅",
                    message: "点右上角 + 添加一个 TVBox 订阅地址"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(app.subscriptions) { subscription in
                Button {
                    app.activateSubscription(subscription.id)
                } label: {
                    HStack(spacing: XSpacing.md) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(subscription.name)
                                .font(XFont.body())
                                .foregroundStyle(XColors.textPrimary)
                                .lineLimit(1)
                            Text("\(subscription.siteCount) 个源 · \(host(subscription.url))")
                                .font(XFont.caption())
                                .foregroundStyle(XColors.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if subscription.id == app.settings.activeSubscriptionId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(XColors.accent)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                let ids = indexSet.map { app.subscriptions[$0].id }
                for id in ids { app.removeSubscription(id) }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !app.subscriptions.isEmpty {
                Text("点按切换当前订阅，左滑删除。切换后会优先使用本地缓存。")
                    .font(XFont.caption())
                    .foregroundStyle(XColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, XSpacing.lg)
                    .padding(.bottom, XSpacing.sm)
            }
        }
        .scrollContentBackground(.hidden)
        .background(XColors.background)
        .navigationTitle("订阅管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddSubscriptionSheet()
        }
    }

    private func host(_ url: String) -> String {
        url.components(separatedBy: "://").last?
            .components(separatedBy: "/").first ?? url
    }
}

// MARK: - 添加订阅

struct AddSubscriptionSheet: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var warehouse: [WarehouseEntry] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $url, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(XFont.body())
                    TextField("备注名（可留空）", text: $name)
                        .font(XFont.body())
                } header: {
                    Text("订阅地址")
                } footer: {
                    Text("支持标准 TVBox 订阅、多仓订阅，以及直接返回 CMS 接口的裸地址。只支持 JSON / XML 源站，spider（jar）源无法使用。")
                        .font(XFont.caption())
                }

                Section("快捷地址") {
                    shortcut("默认单仓", DefaultSources.box, name: "默认单仓")
                    shortcut("多仓订阅", DefaultSources.warehouse, name: "多仓")
                }

                if !warehouse.isEmpty {
                    Section("选择子仓库") {
                        ForEach(warehouse) { entry in
                            Button {
                                Task { await submit(entry.url, name: entry.name) }
                            } label: {
                                HStack {
                                    Text(entry.name)
                                        .font(XFont.bodySmall())
                                        .foregroundStyle(XColors.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(XColors.textTertiary)
                                }
                            }
                            .disabled(working)
                        }
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(XFont.caption())
                            .foregroundStyle(XColors.danger)
                    }
                }

                Section {
                    Button {
                        Task { await submit(url, name: name) }
                    } label: {
                        HStack {
                            Spacer()
                            if working {
                                ProgressView().tint(XColors.accent)
                            } else {
                                Text("添加")
                                    .font(XFont.title())
                                    .foregroundStyle(XColors.accent)
                            }
                            Spacer()
                        }
                    }
                    .disabled(working || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(XColors.background)
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func shortcut(_ title: String, _ address: String, name: String) -> some View {
        Button {
            url = address
            self.name = name
        } label: {
            HStack {
                Text(title)
                    .font(XFont.bodySmall())
                    .foregroundStyle(XColors.textPrimary)
                Spacer()
                Text(address)
                    .font(XFont.caption())
                    .foregroundStyle(XColors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func submit(_ target: String, name: String) async {
        guard !working else { return }
        working = true
        errorText = nil
        defer { working = false }

        let result = await app.addSubscription(target, name: name)
        switch result {
        case .success:
            dismiss()
        case let .needWarehouse(entries):
            warehouse = entries
        case let .failure(message):
            errorText = message
        }
    }
}

// MARK: - 站点选择

struct SiteListView: View {

    @Environment(AppViewModel.self) private var app

    var body: some View {
        List {
            Section {
                if app.usableSites.isEmpty {
                    Text("当前订阅没有可用站点")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.textTertiary)
                }
                ForEach(app.usableSites) { site in
                    HStack(spacing: XSpacing.md) {
                        Button {
                            app.selectSite(site)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(site.name)
                                        .font(XFont.body())
                                        .foregroundStyle(XColors.textPrimary)
                                        .lineLimit(1)
                                    Text("type \(site.type) · \(apiHost(site.api))")
                                        .font(XFont.caption())
                                        .foregroundStyle(XColors.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if site.key == app.currentSite?.key {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(XColors.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            app.togglePinnedSite(site)
                        } label: {
                            Image(systemName: app.isPinned(site) ? "pin.fill" : "pin")
                                .font(.system(size: 13))
                                .foregroundStyle(app.isPinned(site) ? XColors.accent : XColors.textTertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(app.isPinned(site) ? "取消置顶" : "置顶") \(site.name)")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("可用站点 \(app.usableSites.count)")
            } footer: {
                if app.skippedSiteCount > 0 {
                    Text("另有 \(app.skippedSiteCount) 个源被跳过：spider（jar）源需要 JVM 运行时，iOS 无法执行；网页解析源当前版本也不支持。")
                        .font(XFont.caption())
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(XColors.background)
        .navigationTitle("站点")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func apiHost(_ api: String) -> String {
        api.components(separatedBy: "://").last?
            .components(separatedBy: "/").first ?? api
    }
}

// MARK: - 直播源

struct LiveSourceView: View {

    @Environment(AppViewModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("m3u / txt 地址", text: $draft, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(XFont.body())
            } header: {
                Text("直播源地址")
            } footer: {
                Text("支持 M3U 与 TVBox 的 txt 格式。rtp / udp 组播地址会被自动丢弃——公网设备连不上。")
                    .font(XFont.caption())
            }

            Section {
                Button {
                    app.setLiveURL(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                    LiveCache.shared.clear()
                    saved = true
                } label: {
                    Text("保存并清空缓存")
                        .font(XFont.body())
                        .foregroundStyle(XColors.accent)
                }

                Button {
                    draft = DefaultSources.live
                    app.setLiveURL(DefaultSources.live)
                    LiveCache.shared.clear()
                    saved = true
                } label: {
                    Text("恢复默认地址")
                        .font(XFont.body())
                        .foregroundStyle(XColors.textSecondary)
                }
            }

            if saved {
                Section {
                    Text("已保存，切到「直播」会自动重新加载。")
                        .font(XFont.caption())
                        .foregroundStyle(XColors.success)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(XColors.background)
        .navigationTitle("直播源")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if draft.isEmpty { draft = app.settings.liveUrl }
        }
    }
}
