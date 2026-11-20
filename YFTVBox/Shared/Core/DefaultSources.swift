import Foundation

/**
 内置默认源地址。

 与 Android 版一致，全部指向使用者自己的 Cloudflare Worker（tv-source-switcher）：
 - box：经过筛选的影视源列表，标准 TVBox JSON
 - dc：多仓订阅，导入时需选择子仓库
 - live：直播列表，Worker 已过滤掉 rtp 组播，只留公网可播的 http(s) 流

 首次启动会自动导入 box 并写入 live，旧 /box 地址刷新成功后迁移到 /sources；地址均可在设置页改掉。
 */
enum DefaultSources {
    static let box = "https://tv.bsdnme.me/sources"
    static let legacyBox = "https://tv.bsdnme.me/box"
    static let warehouse = "https://tv.bsdnme.me/dc"
    static let live = "https://tv.bsdnme.me/live"
}
