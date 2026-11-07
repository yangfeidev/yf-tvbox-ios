import Foundation

/**
 内置默认源地址。

 与 Android 版一致，全部指向使用者自己的 Cloudflare Worker（tv-source-switcher）：
 - box：单仓订阅，标准 TVBox JSON
 - dc：多仓订阅，导入时需选择子仓库
 - live：直播列表，Worker 已过滤掉 rtp 组播，只留公网可播的 http(s) 流

 首次启动会自动导入 box 并写入 live；地址均可在设置页改掉。
 */
enum DefaultSources {
    static let box = "https://tv.bsdnme.me/box"
    static let warehouse = "https://tv.bsdnme.me/dc"
    static let live = "https://tv.bsdnme.me/live"
}
