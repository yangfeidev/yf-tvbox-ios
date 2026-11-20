import XCTest
import UIKit
@testable import YFTVBox

/**
 直播列表解析与订阅解析。

 这两块都是"文本/结构脏数据多"的地方，规则一旦回退就是成片黑屏或分组错乱，
 所以用固定样本把行为锁住。
 */
final class LiveAndSubscriptionTests: XCTestCase {

    func testUnifiedSourcesPreserveKeysAndAvoidCollisions() throws {
        let previous = SubscriptionDocument(sites: [
            Site(key: "old", name: "原源", api: "https://example.com/api", type: 1),
        ])
        let raw = """
        {"sites":[{"key":"new","name":"原源","api":"https://example.com/api","type":1},
                  {"key":"other","name":"其他","api":"https://other.example/api","type":1}]}
        """
        var keys: [String: String] = [:]
        let migrated = try SubscriptionApi.preservingSourceKeys(raw, previous: previous, keys: &keys)
        XCTAssertEqual(try SubscriptionApi.parse(migrated).sites.map(\.key), ["old", "other"])
        let again = try SubscriptionApi.preservingSourceKeys(raw, previous: nil, keys: &keys)
        XCTAssertEqual(try SubscriptionApi.parse(again).sites.map(\.key), ["old", "other"])

        let collision = """
        {"sites":[{"key":"new","name":"原源","api":"https://example.com/api","type":1},
                  {"key":"old","name":"其他","api":"https://other.example/api","type":1}]}
        """
        let safe = try SubscriptionApi.preservingSourceKeys(collision, previous: previous, keys: &keys)
        XCTAssertEqual(try SubscriptionApi.parse(safe).sites.map(\.key), ["new", "other"])
    }

    @MainActor func testFamilyClassificationAndLegacyLibrarySafety() throws {
        let categories = [Category(typeId: "1", name: "伦理"), Category(typeId: "2", name: "子分类", parentId: "1"), Category(typeId: "3", name: "电影")]
        XCTAssertEqual(FamilyContent.restrictedIDs(categories), Set(["1", "2"]))
        XCTAssertFalse(FamilyContent.visible(MediaItem(id: "a", name: "影片", typeId: "2"), categories: categories))
        XCTAssertFalse(FamilyContent.visible(MediaItem(id: "b", name: "18+内容"), categories: categories))
        XCTAssertTrue(FamilyContent.visible(MediaItem(id: "c", name: "电影", typeId: "3"), categories: categories))
        let old = try JSONDecoder().decode(LibraryEntry.self, from: Data("{\"siteKey\":\"s\",\"mediaId\":\"m\",\"name\":\"旧记录\",\"poster\":\"\",\"remarks\":\"\",\"episodeName\":\"\",\"sourceName\":\"\",\"progress\":0,\"updatedAt\":0}".utf8))
        XCTAssertFalse(FamilyContent().libraryVisible(old, site: nil))
    }

    func testContentAuthorizationAndLockout() throws {
        let suite = "test.authorization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
        let store = LocalStore(defaults: defaults, baseDirectory: base)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(store.familyMode)
        for _ in 0..<5 { XCTAssertNotNil(store.authorizeContent("00000000", now: now)) }
        XCTAssertNotNil(store.authorizeContent("08160219", now: now.addingTimeInterval(29)))
        XCTAssertFalse(store.contentAuthorized)
        XCTAssertNil(store.authorizeContent("08160219", now: now.addingTimeInterval(31)))
        XCTAssertTrue(store.contentAuthorized)
        store.familyMode = false
        XCTAssertFalse(store.familyMode)
        try FileManager.default.removeItem(at: base.appendingPathComponent("feigemedia/authorization/authorized"))
        XCTAssertTrue(store.familyMode)
    }

    func testSourceCheckRequiresTwoFailuresAndExpires() {
        let now = Date(timeIntervalSince1970: 1000)
        let success = SourceCheckSnapshot.merging(["a": true], previous: nil, network: "n", now: now)
        let first = SourceCheckSnapshot.merging(["a": false], previous: success, network: "n", now: now)
        XCTAssertEqual(first.entries["a"], SourceCheckEntry(available: true, failures: 1))
        let second = SourceCheckSnapshot.merging(["a": false], previous: first, network: "n", now: now)
        XCTAssertEqual(second.entries["a"], SourceCheckEntry(available: false, failures: 2))
        let changed = SourceCheckSnapshot.merging(["a": false], previous: success, network: "other", now: now)
        XCTAssertEqual(changed.entries["a"], SourceCheckEntry(available: false, failures: 1))
        XCTAssertTrue(success.isFresh(now: now.addingTimeInterval(1799)))
        XCTAssertFalse(success.isFresh(now: now.addingTimeInterval(1800)))
    }

    // MARK: - M3U

    func testM3UParsesAttributesAndHeaders() {
        let raw = """
        #EXTM3U x-tvg-url="https://epg/e.xml"
        #EXTINF:-1 tvg-id="CCTV1" tvg-logo="https://img/cctv1.png" group-title="央视频道",CCTV-1 综合
        #EXTVLCOPT:http-user-agent=Mozilla/5.0 Test
        #EXTVLCOPT:http-referrer=https://ref.example/
        https://host/cctv1.m3u8
        #EXTINF:-1 group-title="卫视频道",湖南卫视
        https://host/hunan.m3u8
        """

        let groups = LiveParser.parse(raw)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "央视频道")
        XCTAssertEqual(groups[0].channels.count, 1)

        let first = groups[0].channels[0]
        XCTAssertEqual(first.name, "CCTV-1 综合")
        XCTAssertEqual(first.logo, "https://img/cctv1.png")
        XCTAssertEqual(first.tvgId, "CCTV1")
        XCTAssertEqual(first.headers["User-Agent"], "Mozilla/5.0 Test")
        XCTAssertEqual(first.headers["Referer"], "https://ref.example/")

        XCTAssertEqual(groups[1].name, "卫视频道")
    }

    func testM3USkipsMulticastAndIPv6() {
        let raw = """
        #EXTM3U
        #EXTINF:-1,组播
        rtp://239.1.1.1:5000
        #EXTINF:-1,UDP源
        udp://239.1.1.2:5000
        #EXTINF:-1,IPv6直连
        http://[2409:8087::1]/live.m3u8
        #EXTINF:-1,正常
        http://host/ok.m3u8
        """

        let groups = LiveParser.parse(raw)
        let all = groups.flatMap(\.channels)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].name, "正常")
    }

    func testM3UFiltersFakeChannels() {
        let raw = """
        #EXTM3U
        #EXTINF:-1,更新时间
        http://host/a.m3u8
        #EXTINF:-1,关于本源
        http://host/b.m3u8
        #EXTINF:-1,真频道
        http://host/c.m3u8
        """

        let channels = LiveParser.parse(raw).flatMap(\.channels)
        XCTAssertEqual(channels.map(\.name), ["真频道"])
    }

    func testM3UWithoutExtinfFallsBackToURL() {
        let raw = """
        #EXTM3U
        http://host/lonely.m3u8
        """
        let channels = LiveParser.parse(raw).flatMap(\.channels)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].url, "http://host/lonely.m3u8")
    }

    // MARK: - TXT

    func testTXTParsesGenres() {
        let raw = """
        央视频道,#genre#
        CCTV-1,http://host/cctv1.m3u8
        CCTV-2,http://host/cctv2.m3u8
        卫视频道,#genre#
        湖南卫视,http://host/hunan.m3u8
        """

        let groups = LiveParser.parse(raw)
        XCTAssertEqual(groups.map(\.name), ["央视频道", "卫视频道"])
        XCTAssertEqual(groups[0].channels.count, 2)
        XCTAssertEqual(groups[1].channels[0].name, "湖南卫视")
    }

    func testTXTWithoutGenreUsesDefaultGroup() {
        let raw = "CCTV-1,http://host/cctv1.m3u8"
        let groups = LiveParser.parse(raw)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "未分组")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(LiveParser.parse("").isEmpty)
        XCTAssertTrue(LiveParser.parse("   \n  ").isEmpty)
    }

    // MARK: - 订阅：标准形态

    func testStandardSubscription() throws {
        let raw = """
        {
          "sites": [
            {"key": "csp_A", "name": "源A", "type": 1, "api": "https://a/api.php/provide/vod",
             "searchable": 1, "quickSearch": 1, "ext": ""},
            {"key": "csp_B", "name": "源B", "type": 3, "api": "csp_B"},
            {"name": "源C", "type": 0, "api": "https://c/api.php/provide/vod"}
          ],
          "lives": [{"name": "直播一", "url": "https://live/1.m3u", "group": "默认"}],
          "parses": [{"name": "解析", "url": "https://jx/1"}]
        }
        """

        let document = try SubscriptionApi.parse(raw)

        XCTAssertEqual(document.sites.count, 3)
        XCTAssertEqual(document.usableSites.count, 2)   // type 3 不可用
        XCTAssertEqual(document.skippedCount, 1)
        XCTAssertEqual(document.liveSources.count, 1)
        XCTAssertEqual(document.parses.count, 1)
        XCTAssertFalse(document.isWarehouse)

        let spider = document.sites[1]
        XCTAssertTrue(spider.isSpider)
        XCTAssertNotNil(spider.unavailableReason)
    }

    // MARK: - 订阅：多仓

    func testWarehouseSubscription() throws {
        let raw = """
        {"urls": [
          {"name": "仓库A", "url": "https://a/index.json"},
          {"name": "", "url": "https://b/index.json"}
        ]}
        """

        let document = try SubscriptionApi.parse(raw)
        XCTAssertTrue(document.isWarehouse)
        XCTAssertEqual(document.warehouse.count, 2)
        XCTAssertEqual(document.warehouse[1].name, "https://b/index.json")  // 空名字降级成 url
        XCTAssertTrue(document.sites.isEmpty)
    }

    // MARK: - 订阅：裸地址

    func testBareAddressSubscription() throws {
        let document = try SubscriptionApi.parse("https://cms.example.com/api.php/provide/vod?ac=list")
        XCTAssertEqual(document.sites.count, 1)
        XCTAssertEqual(document.sites[0].key, "direct")
        XCTAssertEqual(document.sites[0].name, "cms.example.com")
        XCTAssertTrue(document.sites[0].usable)
    }

    // MARK: - 订阅：异常

    func testInvalidSubscriptionThrows() {
        XCTAssertThrowsError(try SubscriptionApi.parse(""))
        XCTAssertThrowsError(try SubscriptionApi.parse("<html>404</html>"))
        XCTAssertThrowsError(try SubscriptionApi.parse(#"{"foo": 1}"#))
    }

    func testNormalizeURL() {
        XCTAssertEqual(SubscriptionApi.normalizeURL(" tv.bsdnme.me/box "), "https://tv.bsdnme.me/box")
        XCTAssertEqual(SubscriptionApi.normalizeURL("http://a/b"), "http://a/b")
        XCTAssertEqual(SubscriptionApi.normalizeURL("   "), "")
    }

    // MARK: - 播放格式预检

    func testUnsupportedContainers() {
        XCTAssertNotNil(PlaybackFormat.unsupportedReason(for: "https://a/b.mkv"))
        XCTAssertNotNil(PlaybackFormat.unsupportedReason(for: "https://a/b.FLV?token=1"))
        XCTAssertNil(PlaybackFormat.unsupportedReason(for: "https://a/b.m3u8"))
        XCTAssertNil(PlaybackFormat.unsupportedReason(for: "https://a/b.mp4"))
        // ts 不拦，交给 AVPlayer 自己试
        XCTAssertNil(PlaybackFormat.unsupportedReason(for: "https://a/b.ts"))
        XCTAssertNil(PlaybackFormat.unsupportedReason(for: "https://mkv.example/video.m3u8?next=film.flv"))
    }

    // MARK: - 续播定位

    func testFindResumeTarget() {
        let sources = [
            PlaySource(name: "线路一", episodes: [
                Episode(name: "第1集", url: "https://a/1.m3u8"),
                Episode(name: "第2集", url: "https://a/2.m3u8"),
            ]),
            PlaySource(name: "线路二", episodes: [
                Episode(name: "第1集", url: "https://b/1.m3u8"),
                Episode(name: "第2集", url: "https://b/2.m3u8"),
            ]),
        ]

        let history = LibraryEntry(
            siteKey: "s", mediaId: "1", name: "x",
            episodeName: "第2集", sourceName: "线路二", progress: 0.5
        )
        let target = findResumeTarget(sources: sources, history: history)
        XCTAssertEqual(target?.sourceIndex, 1)
        XCTAssertEqual(target?.episodeIndex, 1)

        // 线路名对不上时，跨线路按集名找
        var noSource = history
        noSource.sourceName = "已删除的线路"
        XCTAssertEqual(findResumeTarget(sources: sources, history: noSource)?.sourceIndex, 0)

        // 很早的播放进度也可以续播；从头和基本看完不续播
        var tiny = history
        tiny.progress = 0.01
        XCTAssertNotNil(findResumeTarget(sources: sources, history: tiny))
        tiny.progress = 0
        XCTAssertNil(findResumeTarget(sources: sources, history: tiny))

        var done = history
        done.progress = 0.99
        XCTAssertNil(findResumeTarget(sources: sources, history: done))

        XCTAssertNil(findResumeTarget(sources: sources, history: nil))
    }
}


@MainActor
private final class TestPlayerEngine: PlayerEngine {
    var onStatus: ((PlayerEngineStatus) -> Void)?
    var onProgress: ((Double, Double) -> Void)?
    var loadedURLs: [String] = []
    var pauseCount = 0
    var playCount = 0
    var seekTargets: [Double] = []
    func load(url: String, headers: [String: String], startAt: Double) { loadedURLs.append(url) }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func stop() { pauseCount += 1 }
    func seek(to seconds: Double) { seekTargets.append(seconds) }
    func setRate(_ rate: Float) {}
    func setAspectFill(_ fill: Bool) {}
    func makeSurface() -> UIView { UIView() }
    func invalidate() {}
}

final class PlaybackRegressionTests: XCTestCase {
    @MainActor
    func testBackgroundSuspensionPreservesPlaybackIntent() {
        let engine = TestPlayerEngine()
        let model = PlaybackModel(engine: engine)
        model.play()
        model.suspendForBackground()
        model.resumeFromBackground()
        XCTAssertEqual(engine.playCount, 2)
        model.pause()
        model.suspendForBackground()
        model.resumeFromBackground()
        XCTAssertEqual(engine.playCount, 2)
        model.invalidate()
    }

    @MainActor
    func testLoadingInBackgroundWaitsUntilForeground() {
        let engine = TestPlayerEngine()
        let model = PlaybackModel(engine: engine)
        model.suspendForBackground()
        let session = PlaybackSession(title: "测试", sources: [PlaySource(name: "线路", episodes: [
            Episode(name: "1", url: "https://example.com/1.m3u8")
        ])], sourceIndex: 0, episodeIndex: 0)
        model.load(session: session)
        XCTAssertEqual(engine.playCount, 0)
        model.resumeFromBackground()
        XCTAssertEqual(engine.playCount, 1)
        model.invalidate()
    }

    @MainActor
    func testResumeDoesNotOverwriteHistoryBeforeSeekCompletes() {
        let engine = TestPlayerEngine()
        let model = PlaybackModel(engine: engine)
        let session = PlaybackSession(title: "测试", sources: [PlaySource(name: "线路", episodes: [
            Episode(name: "1", url: "https://example.com/1.m3u8")
        ])], sourceIndex: 0, episodeIndex: 0, resumeFraction: 0.001)
        model.load(session: session)
        engine.onProgress?(0, 1000)
        XCTAssertEqual(engine.seekTargets.last, 1)
        XCTAssertNil(model.progressForSaving)
        engine.onProgress?(0, 1000)
        XCTAssertNil(model.progressForSaving)
        engine.onProgress?(1, 1000)
        XCTAssertEqual(model.progressForSaving ?? -1, 0.001, accuracy: 0.0001)
        model.seek(toProgress: 0)
        XCTAssertEqual(model.progressForSaving, 0)
        model.invalidate()
    }

    func testSwitchSourceMatchesEpisodeAndStopsAfterEachSource() {
        let sources = [
            PlaySource(name: "一", episodes: [Episode(name: "第1集", url: "a"), Episode(name: "第2集", url: "b")]),
            PlaySource(name: "二", episodes: [Episode(name: "第2集", url: "c"), Episode(name: "第1集", url: "d")]),
            PlaySource(name: "三", episodes: [Episode(name: "第一集", url: "e"), Episode(name: "第二集", url: "f")]),
            PlaySource(name: "四", episodes: []),
        ]
        let first = nextPlaybackSource(sources: sources, current: 0, episodeName: "第2集", episodeIndex: 1, attempted: [0])
        XCTAssertEqual(first?.source, 1)
        XCTAssertEqual(first?.episode, 0)
        let second = nextPlaybackSource(sources: sources, current: 1, episodeName: "第2集", episodeIndex: 1, attempted: [0, 1])
        XCTAssertEqual(second?.source, 2)
        XCTAssertEqual(second?.episode, 1)
        XCTAssertNil(nextPlaybackSource(sources: sources, current: 2, episodeName: "第2集", episodeIndex: 1, attempted: [0, 1, 2]))
    }

    @MainActor
    func testUnsupportedNextEpisodeStopsPreviousPlayback() {
        let engine = TestPlayerEngine()
        let model = PlaybackModel(engine: engine)
        var session = PlaybackSession(title: "测试", sources: [PlaySource(name: "线路", episodes: [
            Episode(name: "1", url: "https://example.com/1.m3u8"),
            Episode(name: "2", url: "https://example.com/2.mkv")
        ])], sourceIndex: 0, episodeIndex: 0)
        model.load(session: session)
        let pauses = engine.pauseCount
        session.episodeIndex = 1
        model.load(session: session)
        XCTAssertGreaterThan(engine.pauseCount, pauses)
        XCTAssertNotNil(model.failureMessage)
        XCTAssertEqual(engine.loadedURLs, ["https://example.com/1.m3u8"])
        engine.onStatus?(.paused)
        XCTAssertNotNil(model.failureMessage)
        model.invalidate()
    }
}

final class SwipeSeekTests: XCTestCase {
    func testSwipeRangeAndBounds() {
        XCTAssertEqual(swipeSeekTarget(start: 120, translation: 200, width: 400, duration: 1800), 420, accuracy: 0.001)
        XCTAssertEqual(swipeSeekTarget(start: 5, translation: -400, width: 400, duration: 30), 0, accuracy: 0.001)
        XCTAssertEqual(swipeSeekTarget(start: 1790, translation: 400, width: 400, duration: 1800), 1800, accuracy: 0.001)
        XCTAssertEqual(swipeSeekTarget(start: 50, translation: 400, width: 0, duration: 1800), 50, accuracy: 0.001)
    }
}
