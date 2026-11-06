import XCTest
@testable import YFTVBox

/**
 直播列表解析与订阅解析。

 这两块都是"文本/结构脏数据多"的地方，规则一旦回退就是成片黑屏或分组错乱，
 所以用固定样本把行为锁住。
 */
final class LiveAndSubscriptionTests: XCTestCase {

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

        // 进度太小或基本看完，视为不需要续播
        var tiny = history
        tiny.progress = 0.01
        XCTAssertNil(findResumeTarget(sources: sources, history: tiny))

        var done = history
        done.progress = 0.99
        XCTAssertNil(findResumeTarget(sources: sources, history: done))

        XCTAssertNil(findResumeTarget(sources: sources, history: nil))
    }
}
