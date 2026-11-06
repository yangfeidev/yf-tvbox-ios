# 飞哥影视仓 · iOS

TVBox 类壳应用的 iOS 版，SwiftUI 重写。**iPhone / iPad 双端，不含投屏、不含 tvOS。**

> 本应用不内置任何内容源。所有内容均来自使用者自行添加的订阅地址。

## 现在能做什么

- **订阅**：标准 TVBox JSON / 多仓（导入时选子仓库）/ 裸地址；多订阅并存、点按切换、左滑删除、本地缓存、启动静默刷新
- **站点**：可用站点列表、置顶、跳过来源说明（spider 源 iOS 上跑不了，明确告知数量而不是静默丢弃）
- **首页**：分类胶囊 + 焦点推荐 + 多行横轨；父分类没内容时自动回退到子分类
- **分类**：网格 + 滚动翻页
- **详情**：线路切换、剧集网格、收藏、续播（记住线路与集数）
- **搜索**：当前站点搜索 + 搜索历史
- **直播**：M3U / TXT、按 group-title 分组、三级缓存（内存 10 分钟 / 磁盘 2 小时 / 网络 45 秒超时）、网络失败回退过期缓存
- **播放**：AVPlayer、自绘控制层（4 秒自动隐藏、双击播放暂停、±10 秒、拖动进度、倍速、画面比例、选集、播完自动下一集、失败换线路、30 秒起播看门狗）、锁屏信息与耳机线控
- **我的**：收藏与历史、观看进度、清空历史、检查更新（引导下载，iOS 不能自装）

## 与 Android 版的关系

不是移植，是重写。数据层与解析逻辑按 Kotlin 版逐行对照实现，UI 全部重做：

| Android（Compose） | iOS（SwiftUI） | 说明 |
|---|---|---|
| `data/model/Models.kt` | `Data/Models.swift` | 结构一一对应 |
| `data/net/Http.kt` | `Data/Net/Http.swift` | URLSession；额外处理 GBK / GB18030 编码 |
| `data/net/VodParser.kt` | `Data/Net/VodParser.swift` | JSON 走 JSONSerialization，XML 走 XMLParser |
| `data/net/VodApi.kt` | `Data/Net/VodApi.swift` | 分类 / 列表 / 搜索 / 详情 / 子分类合并 |
| `data/net/SubscriptionApi.kt` | `Data/Net/SubscriptionApi.swift` | 三种订阅形态 |
| `data/net/LiveParser.kt` | `Data/Net/LiveParser.swift` | m3u + txt，同样的过滤规则 |
| `data/LocalStore.kt` | `Data/LocalStore.swift` | UserDefaults + Application Support |
| `vm/AppViewModel.kt` | `VM/AppViewModel.swift` | `@Observable` + `@MainActor` |
| `ui/player`（ExoPlayer） | `Player/`（AVPlayer） | 抽了 `PlayerEngine` 协议 |
| `ui/update` | `Data/Net/UpdateApi.swift` | iOS 改为"查版本 → 打开下载页" |
| `cast/Dlna.kt` | — | iOS 版不做投屏 |

## 工程结构

```
YFTVBox/
├── App/                入口、根视图（自绘底部栏，首次访问才构建、之后保活）
├── Core/               设计令牌、形态判定、默认源地址
├── Data/
│   ├── Models.swift
│   ├── LocalStore.swift
│   └── Net/            Http / VodParser / VodApi / LiveParser / LiveCache / SubscriptionApi / UpdateApi
├── Player/
│   ├── PlayerEngine.swift   播放内核协议 + 会话 + 格式预检
│   ├── AVPlayerEngine.swift AVPlayer 实现 + 可观测包装 + 看门狗
│   └── PlayerScreen.swift   播放页
├── VM/AppViewModel.swift
├── UI/                 Home / Category / Detail / Search / Library / Live / Settings / Components
└── Resources/          Assets.xcassets（App 图标 + 强调色）
YFTVBoxTests/           解析层单元测试（24 个用例）
YFTVBoxUITests/         逐页走查（截图挂进测试报告）
```

## 构建

工程由 XcodeGen 生成，`.xcodeproj` 不入库：

```bash
brew install xcodegen
xcodegen generate
open YFTVBox.xcodeproj
```

命令行构建 / 测试（**必须带 `-disable-sandbox`**）：

```bash
xcodebuild -project YFTVBox.xcodeproj -scheme YFTVBox \
  -destination 'id=<模拟器 UDID>' \
  -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  CODE_SIGNING_ALLOWED=NO build

# 单元测试 + UI 走查
xcodebuild test -project YFTVBox.xcodeproj -scheme YFTVBox \
  -destination 'id=<模拟器 UDID>' -resultBundlePath /tmp/walk.xcresult \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' CODE_SIGNING_ALLOWED=NO
```

> `-disable-sandbox` 是环境要求，不是工程问题：本机命令行进程本身已在沙箱内，
> Swift 编译器再调 `sandbox-exec` 启动宏插件宿主会失败，报错形如
> `external macro implementation type 'ObservationMacros.ObservableMacro' could not be found`。
> Xcode 图形界面构建没有这个问题。

最低支持 **iOS 17.0**（用到 `@Observable`）。

## 出安装包

```bash
./scripts/build-ipa.sh          # 产出 build/YFTVBox-<版本>-<build>.ipa
./scripts/build-ipa.sh --install # 出包并装到已连接设备
```

脚本做的事：生成工程 → Release 归档（自动管理签名，`DEVELOPMENT_TEAM` 可用环境变量覆盖）→ 校验签名与描述文件 → 打包 ipa。

当前包信息：`me.bsdnme.tvbox`、team `X3T54D57W9`、`iOS Team Provisioning Profile: *`、development 签名，描述文件内含 13 台设备（含 Neymar / iPhone 16 Pro）。

安装方式：

1. 插线后用 Xcode：Window → Devices，把 ipa 拖到设备上
2. `xcrun devicectl device install app --device <UDID> build/YFTVBox.xcarchive/Products/Applications/YFTVBox.app`
3. Apple Configurator / Sideloadly / iMazing 拖入 ipa

注意：development 签名约一年有效期；包内描述文件只认列表里的设备 UDID，换机要重新注册并出包。

## 播放内核

AVPlayer 只吃 HLS（m3u8）与 mp4 / mov。源站里大量 `.flv` / `.mkv` / `.ts` / `.mpd` 在 iOS 上无法解码。

因此：

1. 播放器抽象成协议，`AVPlayerEngine` 是当前唯一实现；接 VLCKit 只需新增 `VLCPlayerEngine: PlayerEngine`，播放页与业务层不用改
2. `.flv / .mkv / .avi / .wmv / .rmvb / .mpd` 在起播前直接判掉并给出结论，不让用户对着黑屏等 15 秒（`.ts` 放行，少数源的 ts 直链系统能解）
3. 失败界面提供「换一条线路」，多线路源一键切下一条
4. 30 秒无画面判定为起播失败（慢速 CDN 首帧常要 15~20 秒，20 秒会误杀）

源站格式构成可以用 Android 仓库里的探针脚本量化：

```bash
python3 ../yf-tvbox/scripts/probe_formats.py <订阅地址>
```

### 检查更新的清单

iOS 用独立清单（Android 的 `apkUrl` 在这里没意义），托管在 R2 的 `feige-yingshicang-ios/` 目录：

```json
{
  "build": 2,
  "version": "1.0.1",
  "minBuild": 1,
  "url": "https://dl.bsdnme.me/feige-yingshicang-ios/YFTVBox-1.0.1.ipa",
  "changelog": "修复xxx；新增xxx",
  "force": false
}
```

- 比较依据：`build` 与 Bundle 的 `CFBundleVersion`
- 清单不存在（404）视为"没有更新"，不报错
- 发现新版只弹窗展示 changelog + 「去下载」，装包动作由 Sideloadly / Xcode / Apple Configurator 完成

## 测试

- `YFTVBoxTests`（24 个用例）：VodParser 的 JSON/XML、三层分隔符、脏数据降级；LiveParser 的 m3u/txt、组播与 IPv6 过滤、伪频道过滤；SubscriptionApi 的三种形态与异常；格式预检；续播定位
- `YFTVBoxUITests`：走查首页 → 详情 → 播放 → 直播 → 搜索 → 我的 → 订阅管理，每页截图挂进 `xcresult`，用 `xcrun xcresulttool export attachments` 导出逐张看

## 未实现 / 已知限制

- Web 解析播放（`parses`）与 spider（`jar`）源不支持；设置页会显示"N 个源在 iOS 上不可用"
- EPG 节目单、跨源搜索（Android 版也没有）
- 不做投屏（AirPlay / DLNA），不做 tvOS
- 部分图床在弱网下首屏无图（有占位与重试，没有本地缓存落盘）
- 真机上的解码与直播表现只做过模拟器验证，需要你在手机上再看一遍

## 分发

这种"空壳 + 用户自填源"的形态在 App Store 过审概率极低，实际路线只有 TestFlight / Ad-hoc / 自签。
`Info.plist` 已放开明文 HTTP（源站大量是 `http://`），自签与 TestFlight 下必需；若将来要上架，这一条会被审核追问。
