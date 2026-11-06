import XCTest
@testable import YFTVBox

/**
 点播解析。样本尽量贴近真实 CMS 返回，包括：
 - 苹果CMS v10 的 JSON / XML 两种形态
 - 三层分隔符（$$$ 线路 / # 集数 / $ 名称与地址）
 - 字段缺失、null、数字 id 这类常见脏数据
 */
final class VodParserTests: XCTestCase {

    // MARK: - JSON 列表

    func testJSONListParsesItemsAndCategories() throws {
        let body = """
        {
          "code": 1,
          "page": 2,
          "pagecount": 7,
          "total": 128,
          "list": [
            {"vod_id": 1024, "vod_name": "测试影片", "vod_pic": "https://img/a.jpg",
             "vod_remarks": "更新至 12 集", "type_id": 6, "vod_year": "2026",
             "vod_area": "大陆", "type_name": "国产剧"},
            {"vod_id": 1025, "vod_name": "第二部", "vod_pic": null}
          ],
          "class": [
            {"type_id": 6, "type_name": "国产剧", "type_pid": 0},
            {"type_id": 7, "type_name": "港台剧"}
          ]
        }
        """

        let page = try VodParser.parseList(body, isJSON: true)

        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.pageCount, 7)
        XCTAssertEqual(page.total, 128)
        XCTAssertTrue(page.hasMore)

        let first = page.items[0]
        XCTAssertEqual(first.id, "1024")          // 数字 id 要转成字符串
        XCTAssertEqual(first.name, "测试影片")
        XCTAssertEqual(first.remarks, "更新至 12 集")
        XCTAssertEqual(first.categoryName, "国产剧")

        let second = page.items[1]
        XCTAssertEqual(second.poster, "")          // null 降级为空串，不能崩
        XCTAssertEqual(page.categories.count, 2)
        XCTAssertEqual(page.categories[0].parentId, "0")
    }

    func testJSONListWithGarbageThrows() {
        XCTAssertThrowsError(try VodParser.parseList("<html>403</html>", isJSON: true))
    }

    // MARK: - JSON 详情

    func testJSONDetailSplitsSourcesAndEpisodes() throws {
        let body = """
        {
          "list": [{
            "vod_id": 88,
            "vod_name": "多线路影片",
            "vod_content": "<p>第一段<br/>第二段&nbsp;结尾</p>",
            "vod_actor": "张三,李四",
            "vod_director": "王五",
            "vod_play_from": "线路一$$$线路二",
            "vod_play_url": "第1集$https://a/1.m3u8#第2集$https://a/2.m3u8$$$第1集$https://b/1.mp4"
          }]
        }
        """

        let detail = try VodParser.parseDetail(body, isJSON: true, fallbackId: "88")

        XCTAssertEqual(detail.item.name, "多线路影片")
        XCTAssertEqual(detail.actor, "张三,李四")
        XCTAssertEqual(detail.director, "王五")
        XCTAssertEqual(detail.content, "第一段\n第二段 结尾")

        XCTAssertEqual(detail.playSources.count, 2)
        XCTAssertEqual(detail.playSources[0].name, "线路一")
        XCTAssertEqual(detail.playSources[0].episodes.count, 2)
        XCTAssertEqual(detail.playSources[0].episodes[0].name, "第1集")
        XCTAssertEqual(detail.playSources[0].episodes[0].url, "https://a/1.m3u8")
        XCTAssertEqual(detail.playSources[1].name, "线路二")
        XCTAssertEqual(detail.playSources[1].episodes.count, 1)
        XCTAssertEqual(detail.usableSources.count, 2)
    }

    func testJSONDetailWithoutPlayURL() throws {
        let body = #"{"list":[{"vod_id":1,"vod_name":"无播放源"}]}"#
        let detail = try VodParser.parseDetail(body, isJSON: true, fallbackId: "1")
        XCTAssertEqual(detail.item.name, "无播放源")
        XCTAssertTrue(detail.playSources.isEmpty)
        XCTAssertTrue(detail.usableSources.isEmpty)
    }

    // MARK: - XML 列表

    func testXMLListParsesItemsAndCategories() throws {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="5.1">
        <list page="1" pagecount="4" pagesize="20" recordcount="75">
          <video>
            <id>521</id>
            <tid>3</tid>
            <name>XML 影片</name>
            <type>动作片</type>
            <pic>https://img/x.jpg</pic>
            <year>2025</year>
            <area>美国</area>
            <note>HD</note>
          </video>
        </list>
        <class>
          <ty id="3">动作片</ty>
          <ty id="4" pid="3">枪战</ty>
        </class>
        </rss>
        """

        let page = try VodParser.parseList(body, isJSON: false)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.pageCount, 4)
        XCTAssertEqual(page.total, 75)
        XCTAssertEqual(page.items[0].id, "521")
        XCTAssertEqual(page.items[0].name, "XML 影片")
        XCTAssertEqual(page.items[0].area, "美国")
        XCTAssertEqual(page.categories.count, 2)
        XCTAssertEqual(page.categories[1].parentId, "3")
    }

    func testXMLListWithoutRecognizableContentThrows() {
        XCTAssertThrowsError(try VodParser.parseList("<rss><error>bad</error></rss>", isJSON: false))
    }

    // MARK: - XML 详情

    func testXMLDetailParsesDashedEpisodes() throws {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="5.1">
        <list>
          <video>
            <id>77</id>
            <name>XML 详情</name>
            <pic>https://img/y.jpg</pic>
            <des>简介&lt;br/&gt;第二行</des>
            <dl>
              <dd flag="线路一">第1集$https://a/1.m3u8#第2集$https://a/2.m3u8</dd>
              <dd flag="线路二">https://b/direct.m3u8</dd>
            </dl>
          </video>
        </list>
        </rss>
        """

        let detail = try VodParser.parseDetail(body, isJSON: false, fallbackId: "77")

        XCTAssertEqual(detail.item.name, "XML 详情")
        XCTAssertEqual(detail.playSources.count, 2)
        XCTAssertEqual(detail.playSources[0].name, "线路一")
        XCTAssertEqual(detail.playSources[0].episodes.count, 2)
        // 裸地址也要能生成一条「第 N 集」
        XCTAssertEqual(detail.playSources[1].episodes.count, 1)
        XCTAssertEqual(detail.playSources[1].episodes[0].url, "https://b/direct.m3u8")
        XCTAssertEqual(detail.playSources[1].episodes[0].name, "第 1 集")
    }

    // MARK: - 工具

    func testSplitEpisodesHandlesWeirdInput() {
        XCTAssertEqual(VodParser.splitEpisodes("").count, 0)
        // 没有 $ 的裸地址
        XCTAssertEqual(VodParser.splitEpisodes("https://a/1.m3u8").first?.url, "https://a/1.m3u8")
        // 名称为空时补默认集名
        let episodes = VodParser.splitEpisodes("$https://a/1.m3u8#第2集$https://a/2.m3u8")
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].name, "第 1 集")
        // 地址为空的条目要丢掉
        XCTAssertEqual(VodParser.splitEpisodes("第1集$#第2集$https://a/2.m3u8").count, 1)
    }

    func testCleanHTML() {
        XCTAssertEqual(VodParser.cleanHTML(""), "")
        XCTAssertEqual(
            VodParser.cleanHTML("<p>a<br/>b<br>c</p>"),
            "a\nb\nc"
        )
        // 结尾的 &nbsp; 会变成空格，最后统一 trim 掉
        XCTAssertEqual(VodParser.cleanHTML("&amp;&lt;&gt;&nbsp;"), "&<>")
    }

    func testEpisodePlayable() {
        XCTAssertTrue(Episode(name: "1", url: "https://a/1.m3u8").isPlayable)
        XCTAssertTrue(Episode(name: "1", url: "HTTP://A/1.MP4").isPlayable)
        XCTAssertFalse(Episode(name: "1", url: "ftp://a/1.m3u8").isPlayable)
        XCTAssertFalse(Episode(name: "1", url: "https://a/detail/123.html").isPlayable)
    }
}
