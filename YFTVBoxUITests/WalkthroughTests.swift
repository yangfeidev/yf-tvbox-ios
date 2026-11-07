import XCTest

/**
 逐页走查。

 不是断言"长什么样"，而是把每个关键页面渲染出来挂进测试报告，
 方便逐张看布局：重叠、裁切、空态缺失、字号溢出这些自动化断言抓不到。

 跑法：
 xcodebuild test -project YFTVBox.xcodeproj -scheme YFTVBox \
   -destination 'id=<模拟器>' -only-testing:YFTVBoxUITests \
   -resultBundlePath /tmp/walkthrough.xcresult
 */
final class WalkthroughTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testSearchAutomaticallyFocuses() throws {
        tapTab(1)
        let search = app.buttons["搜索"]
        XCTAssertTrue(search.waitForExistence(timeout: 45))
        search.tap()
        let field = app.textFields["search-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "进入搜索页后键盘没有弹出")
        field.typeText("test")
        XCTAssertEqual(field.value as? String, "test")
    }

    func testPlayerOrientationButton() throws {
        app.terminate()
        app.launchEnvironment["DEBUG_PLAY_URL"] = "http://127.0.0.1:9999/video.m3u8"
        app.launch()
        let orientation = app.buttons["player-orientation"]
        XCTAssertTrue(orientation.waitForExistence(timeout: 10))
        orientation.tap()
        XCTAssertTrue(app.buttons["player-orientation"].label.contains("竖屏"))
        app.buttons["player-back"].tap()
        XCTAssertTrue(app.buttons["player-orientation"].label.contains("横屏"))
        XCTAssertTrue(app.buttons["player-back"].exists)
        app.buttons["player-back"].tap()
        XCTAssertFalse(app.buttons["player-back"].waitForExistence(timeout: 3))
    }

    func testWalkthrough() throws {
        // 1. 首页：等订阅 + 分类 + 6 个列表都拉完
        let firstPoster = element(prefix: "poster-")
        XCTAssertTrue(firstPoster.waitForExistence(timeout: 90), "首页没有加载出内容")
        sleep(3)
        snapshot("01-home")

        // 2. 详情：点第一张海报
        firstPoster.tap()
        let playButton = app.buttons["detail-play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 30), "详情页没打开")
        sleep(3)
        snapshot("02-detail")

        // 3. 播放页
        playButton.tap()
        sleep(8)
        snapshot("03-player")
        let dismiss = app.buttons["player-back"]
        if dismiss.waitForExistence(timeout: 5) {
            dismiss.tap()
            sleep(2)
        }

        // 详情页还有返回按钮，回到首页再切 Tab
        goBack()
        sleep(1)

        // 4. 直播
        tapTab(1)
        XCTAssertTrue(app.buttons["全部"].waitForExistence(timeout: 15))
        snapshot("04-category")
        let categoryTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "category-tab-")).firstMatch
        if categoryTab.waitForExistence(timeout: 15) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to)
            let selected = NSPredicate(format: "value == %@", "已选择")
            expectation(for: selected, evaluatedWith: categoryTab)
            waitForExpectations(timeout: 10)
        }
        tapTab(2)
        sleep(12)
        snapshot("04-live")

        // 5. 搜索（空态 + 搜索历史）
        tapTab(0)
        let search = app.buttons["首页搜索"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        XCTAssertTrue(app.textFields["search-query"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "进入搜索页后键盘没有弹出")
        snapshot("05-search")
        goBack()

        // 6. 我的
        tapTab(3)
        sleep(2)
        snapshot("06-library")
        tapTab(4)
        sleep(2)
        snapshot("06-settings")

        // 7. 设置页直接提供订阅和站点操作
        XCTAssertTrue(app.textFields["settings-subscription-url"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings-add-subscription"].exists)
        XCTAssertTrue(app.buttons["多仓 /dc"].exists)
        app.buttons["多仓 /dc"].tap()
        XCTAssertEqual(app.textFields["settings-subscription-url"].value as? String, "https://tv.bsdnme.me/dc")
        app.buttons["单仓 /box"].tap()
        snapshot("07-subscriptions")
    }

    // MARK: - 工具

    private func element(prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    private func tapTab(_ index: Int) {
        let tab = app.buttons["tab-\(index)"]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            XCTFail("找不到底部 Tab \(index)")
        }
    }

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable {
            back.tap()
        }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
