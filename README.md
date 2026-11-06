# 飞哥影视仓 · iOS

TVBox 类壳应用的 iOS 版，SwiftUI 重写。**iPhone / iPad 双端，不含投屏、不含 tvOS。**

> 本应用不内置任何内容源。所有内容均来自使用者自行添加的订阅地址。

## 与 Android 版的关系

不是移植，是重写。数据层与解析逻辑按 Kotlin 版逐行对照实现，UI 全部重做：

| Android（Compose） | iOS（SwiftUI） | 说明 |
|---|---|---|
| `data/model/Models.kt` | `Data/Models.swift` | 结构一一对应 |
| `data/net/Http.kt` | `Data/Net/Http.swift` | URLSession；额外处理了 GBK/GB18030 编码 |
| `data/net/VodParser.kt` | `Data/Net/VodParser.swift` | JSON 走 JSONSerialization，XML 走 XMLParser |
| `data/net/VodApi.kt` | `Data/Net/VodApi.swift` | 分类 / 列表 / 搜索 / 详情 / 播放地址 |
| `data/net/SubscriptionApi.kt` | `Data/Net/SubscriptionApi.swift` | 标准订阅 / 多仓 / 裸地址 |
| `data/net/LiveParser.kt` | `Data/Net/LiveParser.swift` | m3u + txt，同样的过滤规则 |
| `data/LocalStore.kt` | `Data/LocalStore.swift` | UserDefaults + Application Support |
| `vm/AppViewModel.kt` | `VM/AppViewModel.swift` | `@Observable` + `@MainActor` |
| `ui/player`（ExoPlayer） | `Player/`（AVPlayer） | 抽了 `PlayerEngine` 协议，见下 |
| `cast/Dlna.kt` | — | iOS 版不做投屏 |
| `ui/update` | — | iOS 无法自更新，整块删除 |

## 工程结构

```
YFTVBox/
├── App/                入口、根视图（自绘底部栏）
├── Core/               设计令牌、形态判定、默认源地址
├── Data/
│   ├── Models.swift    全部数据模型
│   ├── LocalStore.swift 订阅 / 收藏 / 历史 / 设置持久化
│   └── Net/            Http / VodParser / VodApi / LiveParser / LiveCache / SubscriptionApi
├── Player/
│   ├── PlayerEngine.swift   播放内核协议 + 播放会话
│   ├── AVPlayerEngine.swift AVPlayer 实现 + 可观测包装
│   └── PlayerScreen.swift   播放页（自绘控制层）
├── VM/AppViewModel.swift
└── UI/                 Home / Category / Detail / Search / Library / Live / Settings / Components
```

## 构建

工程由 XcodeGen 生成，`.xcodeproj` 不入库：

```bash
brew install xcodegen        # 若未安装
xcodegen generate
open YFTVBox.xcodeproj
```

命令行验证编译（**必须带 `-disable-sandbox`**）：

```bash
xcodebuild -project YFTVBox.xcodeproj -scheme YFTVBox \
  -destination 'id=<模拟器 UDID>' \
  -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  CODE_SIGNING_ALLOWED=NO build
```

> `-disable-sandbox` 是环境要求，不是工程问题：本机命令行进程本身已在沙箱内，
> Swift 编译器再调 `sandbox-exec` 启动宏插件宿主会失败，
> 报错形如 `external macro implementation type 'ObservationMacros.ObservableMacro' could not be found`。
> 在 Xcode 图形界面里构建没有这个问题。

真机 / 自签需要 developer team：在 `project.yml` 里补 `DEVELOPMENT_TEAM`，或在 Xcode 的 Signing 里选团队。

最低支持 iOS 17.0（用到 `@Observable`）。

## 播放内核

AVPlayer 只吃 HLS（m3u8）与 mp4 / mov。源站里大量 `.flv` / `.mkv` / `.ts` / `.mpd` 在 iOS 上无法解码。

因此播放器抽象成协议：

```swift
protocol PlayerEngine {
    func load(url: String, headers: [String: String], startAt: Double)
    func play(); func pause(); func seek(to seconds: Double)
    func makeSurface() -> UIView
}
```

`AVPlayerEngine` 是当前唯一实现。若后续实测发现 HLS 占比过低，
新增一个 `VLCPlayerEngine: PlayerEngine` 即可，播放页与业务层不用改。

源站的格式构成可以用 Android 仓库里的探针脚本量化：

```bash
python3 ../yf-tvbox/scripts/probe_formats.py <订阅地址>
```

## 已实现

- 订阅：标准 / 多仓（选子仓库）/ 裸地址；多订阅并存与切换、本地缓存、启动静默刷新
- 站点：可用站点列表、置顶、跳过来源说明（spider 源不可用）
- 首页：分类入口 + 焦点推荐 + 多个分类横轨
- 分类：网格 + 翻页
- 详情：线路切换、剧集网格、收藏、续播
- 搜索：当前站点搜索 + 搜索历史
- 直播：m3u / txt、分组、三级缓存（内存 10 分钟 / 磁盘 2 小时 / 网络）
- 收藏与历史、观看进度、清空历史
- 播放：AVPlayer、自绘控制层、±10s、倍速、画面比例、选集、续播

## 未实现 / 已知问题

- Web 解析播放（`parses`）与 spider（`jar`）源：iOS 不支持，设置页会明确显示跳过数量
- EPG 节目单、跨源搜索（Android 版也没有）
- App 图标与启动图（默认空白）
- 检查更新：iOS 不能自更新，需按分发方式单独设计（TestFlight / 自签源）
- 直播、播放页尚未在真机上验证过网络与解码表现

## 分发

这种「空壳 + 用户自填源」的形态在 App Store 过审概率极低，实际路线只有：

- **TestFlight**：外部测试仍需审核，90 天过期要重发
- **Ad-hoc**：付费账号，限 100 台 UDID，一年重签
- **自签**（SideStore / AltStore）：免费账号 7 天续签

`NSAppTransportSecurity` 里已放开任意明文加载（源站大量是 `http://`），
自签或 TestFlight 分发下必需；若将来要上架，这一条会被审核追问。
