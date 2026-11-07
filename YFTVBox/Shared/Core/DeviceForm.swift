import UIKit

/**
 形态判定。

 Android 版靠 `UiModeManager` 与 `FEATURE_LEANBACK` 判定电视；
 iOS 端没有电视形态，只看 iPad / iPhone。

 不用「最短边 ≥ 600」推平板：iPhone 横屏宽度也能超过 600，
 用 idiom 才是唯一准确依据。
 */
enum DeviceForm {
    static var current: FormFactor {
        UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
    }
}
