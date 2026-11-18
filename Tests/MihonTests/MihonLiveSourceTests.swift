import XCTest
import ImageIO
@testable import MihonDomain
@testable import MihonData

/// Built-in live sources: parsing runs on recorded API responses (`Fixtures/<source>/*.json`); the end-to-end
/// test talks to the real site and skips itself when the network is unavailable.
final class MihonLiveSourceTests: XCTestCase {

    private func fixture<T: Decodable>(_ name: String, as type: T.Type, source: String = "zaimanhua") throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(source)"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - 再漫画 (offline)

    func testZaimanhuaListsMapToMangas() throws {
        let engine = ZaimanhuaLiveEngine()
        let items = try fixture("rank", as: ZMResponse<[ZMListItem]>.self).data ?? []
        let rank = engine.mangasPage(items)
        XCTAssertEqual(rank.mangas.map(\.url), ["87148", "19526", "20844"])
        XCTAssertTrue(rank.hasNextPage)
        XCTAssertEqual(rank.mangas[0].title, "我们的葬礼")
        XCTAssertEqual(rank.mangas[0].status, .completed)
        XCTAssertEqual(rank.mangas[0].thumbnailUrl, "https://images.zaimanhua.com/img/webpic/5/2858451782738468.jpg")
        XCTAssertEqual(rank.mangas[1].genre, ["历史", "职场", "搞笑"], "comma-separated tags")
        XCTAssertEqual(rank.mangas[2].genre, ["搞笑", "仙侠", "颜艺"], "slash-separated tags")
        XCTAssertEqual(rank.mangas[2].status, .ongoing)

        // Update lists send `id: 0` next to the real `comic_id`, search results the other way round.
        let latest = engine.mangasPage(try fixture("latest", as: ZMResponse<[ZMListItem]>.self).data ?? [])
        XCTAssertEqual(latest.mangas.map(\.url), ["69741", "89071"])
        let search = try XCTUnwrap(try fixture("search", as: ZMResponse<ZMSearchPage>.self).data)
        XCTAssertEqual(search.list?.compactMap(\.smanga).map(\.url), ["87297", "56793"])
        XCTAssertEqual(search.total, 16)

        XCTAssertFalse(engine.mangasPage([]).hasNextPage, "an empty page ends the list")

        let dmzj = ZaimanhuaLiveEngine(usesDmzjURLs: true)
        let oldBook = dmzj.mangasPage(items).mangas[1]
        XCTAssertEqual(oldBook.url, "/comic/comic_19526.json?version=2.7.019")
        XCTAssertEqual(dmzj.mangaWebUrl(manga: oldBook), engine.mangaWebUrl(manga: rank.mangas[1]))
    }

    func testZaimanhuaDetailsAndChapters() throws {
        let comic = try ZaimanhuaLiveEngine.unwrap(try fixture("detail", as: ZMResponse<ZMWrapper<ZMComic>>.self))
        let manga = comic.smanga
        XCTAssertEqual(manga.url, "64645")
        XCTAssertEqual(manga.title, "北地之龙")
        XCTAssertEqual(manga.author, "潇洒的转转笔")
        XCTAssertEqual(manga.genre, ["冒险", "魔法", "奇幻"])
        XCTAssertEqual(manga.status, .ongoing)
        XCTAssertEqual(manga.updateStrategy, .alwaysUpdate)
        XCTAssertTrue(manga.initialized)

        let chapters = try comic.chapters()
        // Newest first; the chapter that needs an account and the paid one are left out.
        XCTAssertEqual(chapters.map(\.url), ["64645/195409", "64645/195346", "64645/195187", "64645/128172", "64645/999001"])
        XCTAssertEqual(chapters.map(\.name), ["回归平常", "灾业龙纳尔菲洛", "小白？大白！", "人物设定", "第12.5话"])
        XCTAssertEqual(chapters.map(\.scanlator), ["连载", "连载", "连载", "连载", "番外"])
        XCTAssertEqual(chapters[0].dateUpload, Date(timeIntervalSince1970: 1_792_938_876))
        XCTAssertEqual(chapters.map(\.chapterNumber), Array(repeating: -1, count: 5), "numbers come from ChapterRecognition")
    }

    /// The API stamps some chapters with the time of the request. No chapter is newer than the comic's last update:
    /// the latest one takes that time, any other is undated (upstream: 0) and keeps the date already saved.
    @MainActor
    func testZaimanhuaChaptersStampedWithNowAreUndated() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "detail", withExtension: "json", subdirectory: "Fixtures/zaimanhua"))
        let json = try String(contentsOf: url, encoding: .utf8)
            // The chapters' own key only; `"last_updatetime"` (the comic's) has the same value as the latest chapter.
            .replacingOccurrences(of: #""updatetime": 1792938876"#, with: #""updatetime": 1799999999"#)   // latest (195409)
            .replacingOccurrences(of: #""updatetime": 1792770535"#, with: #""updatetime": 1799999999"#)   // older (195346)
        let comic = try ZaimanhuaLiveEngine.unwrap(try JSONDecoder().decode(ZMResponse<ZMWrapper<ZMComic>>.self, from: Data(json.utf8)))
        let chapters = try comic.chapters()
        XCTAssertEqual(chapters[0].dateUpload, Date(timeIntervalSince1970: 1_792_938_876), "the comic's last update")
        XCTAssertEqual(chapters[1].dateUpload, SChapter.undatedUpload)

        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        store.chaptersByManga[manga.id] = [Chapter(id: 9_100_001, mangaId: manga.id, url: chapters[1].url, name: chapters[1].name,
                                                   dateUpload: Date(timeIntervalSince1970: 1_792_770_535))]
        store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: Array(chapters.prefix(2)))
        XCTAssertEqual(store.chaptersByManga[manga.id]?.first { $0.url == chapters[1].url }?.dateUpload,
                       Date(timeIntervalSince1970: 1_792_770_535), "the known date stays")
    }

    func testZaimanhuaPCDetailAndPages() throws {
        // The PC API (hidden chapter lists) wraps the comic in `comicInfo` and uses camelCase keys.
        let pc = try ZaimanhuaLiveEngine.unwrap(try fixture("detail_pc", as: ZMResponse<ZMWrapper<ZMComic>>.self))
        XCTAssertEqual(pc.lastUpdateChapterId, 195409)
        XCTAssertEqual(try pc.chapters().map(\.url), ["64645/195409", "64645/195346"])

        let pages = try ZaimanhuaLiveEngine.unwrap(try fixture("pages", as: ZMResponse<ZMWrapper<ZMChapterImages>>.self))
        XCTAssertTrue(pages.canRead)
        XCTAssertEqual(pages.pageUrlHd.count, 3)
        XCTAssertTrue(pages.pageUrlHd[0].hasPrefix("https://images.zaimanhua.com/img/chapterpic%2F"))

        let locked = try ZaimanhuaLiveEngine.unwrap(try fixture("pages_locked", as: ZMResponse<ZMWrapper<ZMChapterImages>>.self))
        XCTAssertFalse(locked.canRead)
        XCTAssertTrue(locked.pageUrlHd.isEmpty)
    }

    func testZaimanhuaChapterNames() {
        XCTAssertEqual(ZaimanhuaLiveEngine.chapterName("12"), "第12话")
        XCTAssertEqual(ZaimanhuaLiveEngine.chapterName("连载12.5"), "第12.5话")
        XCTAssertEqual(ZaimanhuaLiveEngine.chapterName("连载版3卷"), "第3卷")
        XCTAssertEqual(ZaimanhuaLiveEngine.chapterName("人物设定"), "人物设定")
        XCTAssertEqual(ZaimanhuaLiveEngine.chapterName("第5话"), "第5话")
    }

    func testSignedImageUrlsShareOneCacheKey() {
        let a = "https://images.zaimanhua.com/img/chapterpic%2F38857%2F142281%2F1.jpg?sign=35ed&t=1793109646"
        let b = "https://images.zaimanhua.com/img/chapterpic%2F38857%2F142281%2F1.jpg?sign=99aa&t=1793200000"
        XCTAssertEqual(MihonLiveSources.stableImageKey(a), MihonLiveSources.stableImageKey(b))
        XCTAssertNotEqual(MihonLiveSources.stableImageKey(a), MihonLiveSources.stableImageKey(a.replacingOccurrences(of: "1.jpg", with: "2.jpg")))
        let other = "https://uploads.mangadex.org/covers/x/y.jpg?t=1"
        XCTAssertEqual(MihonLiveSources.stableImageKey(other), other, "other hosts keep their query")
        XCTAssertEqual(MihonTwoTierImageCache.shared.cacheKey(for: a), MihonTwoTierImageCache.shared.cacheKey(for: b))
    }

    // MARK: - HTML parser

    func testHTMLParserToleratesRealWorldMarkup() {
        let html = """
        <!DOCTYPE html><html><head><title>A &amp; B</title><style>p { color: red }</style>
        <script>var s = "<div class='fake'>";</script></head>
        <BODY><div id="list" class="cards wide">
          <ul><li class="item"><a href="//cdn.example.com/1?a=1&amp;b=2"><p class=subj>One&nbsp;&#x4E00;</p></a>
              <li class="item"><a href="/two"><p class="subj">Two</p><img src="t.jpg" alt="Representative image"></a>
              <li class="item hot"><a href="three"><p class="subj">Three <b>bold</b></p><img src='/3.jpg'/></a>
          </ul>
          <p>first<p>second <!-- a comment --> paragraph
          <div class="paginate"><a href="#" onclick="return false;">1</a><a href="?page=2">2</a></div>
          </span></div>
        </BODY></html>
        """
        let document = HTMLDocument(html: html, baseURL: URL(string: "https://example.com/dir/page"))
        XCTAssertEqual(document.selectFirst("title")?.text, "A & B")
        XCTAssertTrue(document.select("div.fake").isEmpty, "script content is not markup")
        XCTAssertEqual(document.select("#list li.item").count, 3, "unclosed <li> close each other")
        XCTAssertEqual(document.select("div#list > ul > li > a p.subj").map(\.text), ["One 一", "Two", "Three bold"])
        XCTAssertEqual(document.selectFirst("li.hot p.subj")?.ownText, "Three")
        XCTAssertEqual(document.select("li a").map { $0.absUrl("href") },
                       ["https://cdn.example.com/1?a=1&b=2", "https://example.com/two", "https://example.com/dir/three"])
        XCTAssertEqual(document.selectFirst("li:nth-of-type(3) img")?.attr("abs:src"), "https://example.com/3.jpg")
        XCTAssertEqual(document.select("img:not([alt='representative IMAGE'])").count, 1, "attribute values match case-insensitively")
        XCTAssertEqual(document.select("li:has(img)").count, 2)
        XCTAssertEqual(document.select("p:contains(second)").count, 1)
        XCTAssertEqual(document.select("#list > p").map(\.text), ["first", "second paragraph"], "<p> ends at the next <p>")
        XCTAssertEqual(document.selectFirst("div.paginate a[onclick] + a")?.absUrl("href"), "https://example.com/dir/page?page=2")
        XCTAssertEqual(document.select("li.item ~ li").count, 2)
        XCTAssertEqual(document.select("ul li:first-child p.subj, ul li:last-child p.subj").map(\.text), ["One 一", "Three bold"])
        XCTAssertEqual(document.select("div.cards.wide").count, 1)
        XCTAssertEqual(document.select("[class~=hot]").count, 1)
        XCTAssertEqual(document.select("a[href^=//cdn]").count, 1)
    }

    func testHTMLParserMatchesJsoupOnEdgeCases() {
        let html = """
        <div id=a class="Card"><!--><p class=x>one</p><!---><p>two</p>
        <script>if (a </scripts> b) {}</script><p data-n="item-12">three</p>
        <a href="/x"><span>link</span></a></div>
        """
        let document = HTMLDocument(html: html, baseURL: URL(string: "https://example.com/"))
        XCTAssertEqual(document.select("#a > p").map(\.text), ["one", "two", "three"], "empty comments end at once")
        XCTAssertTrue(document.select("script p").isEmpty, "`</scripts` does not end a script")
        XCTAssertEqual(document.select("div.card").count, 1, "class names match case-insensitively")
        XCTAssertEqual(document.select("p[data-n~=item-\\d+]").map(\.text), ["three"], "`~=` is a regex, as in jsoup")
        XCTAssertEqual(document.select("#a > p[class!=x]").map(\.text), ["two", "three"])
        XCTAssertEqual(document.select("#a > p:eq(1)").map(\.text), ["two"])
        XCTAssertEqual(document.select("#a > p:lt(1)").map(\.text), ["one"])
        XCTAssertEqual(document.select("#a > p:gt(1)").map(\.text), ["three"])
        let link = document.selectFirst("a")
        XCTAssertEqual(link?.selectFirst("a")?.attr("href"), "/x", "select includes the element itself, as jsoup's")
        XCTAssertTrue(document.select("p:nth-child(2n+1)").isEmpty, "unsupported selectors match nothing instead of trapping")
    }

    /// Unclosed tags nest deeper than the call stack, and stray end tags under them stay linear.
    func testHTMLParserSurvivesPathologicalNesting() {
        let deep = "<p class=summary>" + String(repeating: "<b>", count: 20_000) + "deep" + "</p>"
        XCTAssertEqual(HTMLDocument(html: deep).selectFirst("p.summary")?.text, "deep")

        let stray = String(repeating: "<div>", count: 5_000) + String(repeating: "</span>", count: 20_000) + "<p>end</p>"
        let start = Date()
        XCTAssertEqual(HTMLDocument(html: stray).selectFirst("p")?.text, "end")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: - 咚漫 (offline)

    private func dongmanPage(_ name: String) throws -> HTMLDocument {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures/dongman"))
        return HTMLDocument(html: try String(contentsOf: url, encoding: .utf8), baseURL: URL(string: DongmanLiveEngine.siteBase + "/dailySchedule"))
    }

    func testDongmanScheduleAndSearch() throws {
        let daily = try dongmanPage("daily")
        let popular = DongmanLiveEngine.titles(in: daily, "div#dailyList .daily_section li a, div.daily_lst.comp li a")
        XCTAssertEqual(popular.count, 16)
        XCTAssertEqual(popular[1].title, "我们公会的爱豆")
        XCTAssertEqual(popular[1].url, "/episodeList?titleNo=2793", "one URL form per title (the schedule links another)")
        XCTAssertEqual(popular[1].thumbnailUrl?.hasPrefix("https://cdn.dongmanmanhua.cn/8b929957-"), true)
        XCTAssertEqual(Set(popular.map(\.url)).count, popular.count, "titles listed on several days appear once")
        XCTAssertEqual(DongmanLiveEngine.titles(in: daily, "div#dailyList > div._list_MONDAY li > a").map(\.title), ["如出一辙的女儿", "我们公会的爱豆"])

        let search = DongmanLiveEngine.searchPage(try dongmanPage("search"))
        XCTAssertEqual(search.mangas.map(\.title), ["恋爱星群", "谢绝职场恋爱！", "猪猪女孩恋爱告急"])
        XCTAssertEqual(search.mangas[0].url, "/episodeList?titleNo=1403", "redirects to the title's list page")
        XCTAssertFalse(search.hasNextPage)
    }

    /// 咚漫 draws its search pager with a script (`createPagination({ recordCount, currentPage })`, 18 titles a
    /// page): more pages follow while the full pages so far cover less than the count.
    func testDongmanSearchPagesByTheScriptsCount() {
        func page(_ current: Int, listing count: Int, of total: Int) -> HTMLDocument {
            let items = (0..<count).map { #"<li><a href="/episodeList?titleNo=\#($0 + 100)"><p class="subj">作品\#($0)</p></a></li>"# }
            let html = """
            <div id="content"><div class="card_wrap search"><ul>\(items.joined())</ul></div></div>
            <script>createPagination({
                recordCount: \(total),
                currentPage: \(current),
            });</script>
            """
            return HTMLDocument(html: html, baseURL: URL(string: DongmanLiveEngine.siteBase))
        }
        XCTAssertEqual(DongmanLiveEngine.searchPage(page(1, listing: 18, of: 344)).mangas.count, 18)
        XCTAssertTrue(DongmanLiveEngine.searchPage(page(1, listing: 18, of: 344)).hasNextPage)
        XCTAssertTrue(DongmanLiveEngine.searchPage(page(19, listing: 18, of: 344)).hasNextPage)
        XCTAssertFalse(DongmanLiveEngine.searchPage(page(20, listing: 2, of: 344)).hasNextPage)
        XCTAssertFalse(DongmanLiveEngine.searchPage(page(1, listing: 3, of: 3)).hasNextPage)
    }

    /// Script content is data, not text (jsoup `data()` / `text()`).
    func testScriptContentIsDataNotText() {
        let document = HTMLDocument(html: "<div><script>if (a < b) { go(); }</script><p>可见</p></div>")
        XCTAssertEqual(document.selectFirst("script")?.data, "if (a < b) { go(); }")
        XCTAssertEqual(document.selectFirst("div")?.text, "可见")
    }

    func testDongmanTitlePageAndViewer() throws {
        let title = try dongmanPage("title")
        let details = DongmanLiveEngine.details(title)
        XCTAssertEqual(details.title, "我们公会的爱豆")
        XCTAssertEqual(details.author, "KKOBO")
        XCTAssertEqual(details.genre, ["恋爱", "都市"])
        XCTAssertEqual(details.status, .ongoing)
        XCTAssertEqual(details.description?.hasPrefix("女扮男装遇上伪装女神"), true)
        XCTAssertEqual(details.thumbnailUrl?.hasPrefix("https://cdn.dongmanmanhua.cn/"), true)

        let chapters = DongmanLiveEngine.chapters(in: title)
        XCTAssertEqual(chapters.map(\.name), ["【免费】第1季 后记", "第10话", "第9话"])
        XCTAssertEqual(chapters[1].url, "/LOVE/womengonghuideaidou/%E7%AC%AC10%E8%AF%9D/viewer?title_no=2793&episode_no=10")
        XCTAssertEqual(chapters[0].dateUpload, DongmanLiveEngine.date("2025-11-16"))
        XCTAssertEqual(DongmanLiveEngine.date("2025-11-16"), Date(timeIntervalSince1970: 1_763_222_400), "midnight in China")
        XCTAssertEqual(title.selectFirst("div.paginate a[onclick] + a")?.absUrl("href"),
                       "https://www.dongmanmanhua.cn/LOVE/womengonghuideaidou/list?title_no=2793&page=2")

        let pages = DongmanLiveEngine.pages(in: try dongmanPage("viewer"), chapter: chapters[1])
        XCTAssertEqual(pages.count, 4)
        XCTAssertEqual(pages[0].imageUrl, "https://cdn.dongmanmanhua.cn/1751959098652279310.jpg?x-oss-process=image/quality,q_90")
        XCTAssertEqual(pages.map(\.index), [0, 1, 2, 3])
    }

    func testDongmanTitleUrlsHaveOneForm() {
        XCTAssertEqual(DongmanLiveEngine.canonicalTitleUrl("/FANTASY/feirenzai/list?title_no=1804"), "/episodeList?titleNo=1804")
        XCTAssertEqual(DongmanLiveEngine.canonicalTitleUrl("/episodeList?titleNo=1403"), "/episodeList?titleNo=1403")
        XCTAssertEqual(DongmanLiveEngine.canonicalTitleUrl("/LOVE/x/%E7%AC%AC10%E8%AF%9D/viewer?title_no=2793&episode_no=10"),
                       "/LOVE/x/%E7%AC%AC10%E8%AF%9D/viewer?title_no=2793&episode_no=10", "episode URLs are left alone")
    }

    /// Libraries saved before version 5 move their 咚漫 titles to the canonical URL, without duplicating seeds.
    @MainActor
    func testDongmanUrlsAreMigrated() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = store.mangas
        let seededCategories = store.mangaCategories
        let index = try XCTUnwrap(store.mangas.firstIndex { $0.title == "非人哉" })
        store.mangas[index].url = "/FANTASY/feirenzai/list?title_no=1804"
        store.migrateRestoredLibrary(fromSeedVersion: 4, seeded: seeded, seededCategories: seededCategories)
        XCTAssertEqual(store.mangas[index].url, "/episodeList?titleNo=1804")
        XCTAssertEqual(store.mangas.filter { $0.title == "非人哉" }.count, 1)
    }

    /// A 咚漫 title saved under both URL forms: the library entry gets the canonical URL (lists and search match by
    /// URL), the other entry takes its old one.
    @MainActor
    func testDongmanMigrationGivesTheCanonicalUrlToTheLibraryEntry() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = store.mangas
        let seededCategories = store.mangaCategories
        let index = try XCTUnwrap(store.mangas.firstIndex { $0.title == "非人哉" })
        XCTAssertTrue(store.mangas[index].favorite)
        store.mangas[index].url = "/FANTASY/feirenzai/list?title_no=1804"
        var browsed = store.mangas[index]
        browsed.id = 99_001
        browsed.favorite = false
        browsed.url = "/episodeList?titleNo=1804"
        store.mangas.append(browsed)

        store.migrateRestoredLibrary(fromSeedVersion: 4, seeded: seeded, seededCategories: seededCategories)
        XCTAssertEqual(store.mangas[index].url, "/episodeList?titleNo=1804")
        XCTAssertEqual(store.mangas.first { $0.id == 99_001 }?.url, "/FANTASY/feirenzai/list?title_no=1804")
    }

    func testDongmanWeekdayUsesChinaTime() {
        // Monday 2026-10-26 23:30 UTC is already Tuesday 07:30 in China.
        XCTAssertEqual(DongmanLiveEngine.weekday(of: Date(timeIntervalSince1970: 1_793_057_400)), "TUESDAY")
    }

    // MARK: - Registry

    @MainActor
    func testTesterStoreOffersZaimanhuaAsLiveSource() async {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let id = MihonSeedData.zaimanhuaSourceId
        XCTAssertTrue(store.isLiveSource(id))
        XCTAssertTrue(store.activeCatalogueSources().contains { $0.id == id && $0.isLive })
        XCTAssertTrue(store.isLiveSource(MihonSeedData.dongmanSourceId))
        await store.bootstrapInstalledAPKSources()
        XCTAssertTrue(store.isLiveSource(id), "APK synthesis must keep the live descriptor")
        XCTAssertTrue(store.isLiveSource(MihonSeedData.dongmanSourceId))
        XCTAssertTrue(store.activeCatalogueSources().allSatisfy(\.isLive))

        // A webtoon source's titles open in the vertical reader.
        let webtoon = store.upsertCatalogMangaToStore(SManga(url: "/x/y/list?title_no=1", title: "条漫"), sourceId: MihonSeedData.dongmanSourceId)
        XCTAssertEqual(webtoon.readingModeOverride, .webtoon)
        let manga = store.upsertCatalogMangaToStore(SManga(url: "1", title: "漫画"), sourceId: id)
        XCTAssertEqual(manga.readingModeOverride, .defaultMode)
    }

    /// A library update fetches the titles of every source (one queue per source).
    @MainActor
    func testLiveLibraryUpdateFetchesEverySource() async throws {
        guard (try? await ZaimanhuaLiveEngine().popularManga(page: 1)) != nil else {
            throw XCTSkip("Network unavailable")
        }
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let picks = [
            store.mangas.first { $0.source == MihonSeedData.zaimanhuaSourceId }?.id,
            store.mangas.first { $0.source == MihonSeedData.dongmanSourceId && $0.title == "地堡的白昼" }?.id,
            store.mangas.first { $0.title == "終末的女武神" }?.id
        ].compactMap { $0 }
        XCTAssertEqual(picks.count, 3)
        for index in store.mangas.indices where !picks.contains(store.mangas[index].id) {
            store.mangas[index].favorite = false
        }
        // About the queues: 智能更新 could skip a completed pick.
        store.libraryUpdateMangaRestrictions = []
        await store.refreshLibraryUpdates()
        for id in picks {
            XCTAssertFalse(store.chaptersByManga[id]?.isEmpty ?? true, "no chapters for \(store.manga(id: id)?.title ?? "\(id)")")
        }
        XCTAssertEqual(store.libraryUpdateProgress, 1, accuracy: 0.001)
    }

    /// Downloading a chapter keeps its page list and every page on disk, so it reads without the network.
    @MainActor
    func testLiveDownloadKeepsChapterOnDisk() async throws {
        guard (try? await ZaimanhuaLiveEngine().popularManga(page: 1)) != nil else {
            throw XCTSkip("Network unavailable")
        }
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first { $0.source == MihonSeedData.zaimanhuaSourceId })
        await store.refreshMangaFromSource(mangaId: manga.id)
        let chapter = try XCTUnwrap(store.chaptersByManga[manga.id]?.max { $0.sourceOrder < $1.sourceOrder }, "oldest chapter")
        store.enqueueChapterDownload(manga: manga, chapter: chapter)
        for _ in 0..<240 where !store.downloadedChapterIds.contains(chapter.id) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        defer { store.removeChapterDownload(chapterId: chapter.id) }
        XCTAssertTrue(store.downloadedChapterIds.contains(chapter.id))
        let saved = try XCTUnwrap(MihonTwoTierImageCache.shared.downloadedPageList(chapterId: chapter.id))
        XCTAssertFalse(saved.isEmpty)
        XCTAssertTrue(saved.allSatisfy { MihonTwoTierImageCache.shared.hasDiskEntry(for: $0) })
    }

    // MARK: - 咚漫 (live, skipped offline)

    func testLiveDongmanEndToEnd() async throws {
        let engine = DongmanLiveEngine()
        let popular: MangasPage
        do {
            popular = try await engine.popularManga(page: 1)
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        XCTAssertGreaterThan(popular.mangas.count, 50)
        let title = try XCTUnwrap(popular.mangas.first)
        let details = try await engine.mangaDetails(manga: title)
        XCTAssertFalse(details.title.isEmpty)
        let chapters = try await engine.chapterList(manga: title)
        let first = try XCTUnwrap(chapters.last)
        let pages = try await engine.pageList(chapter: first)
        let imageUrl = try XCTUnwrap(pages.first?.imageUrl.flatMap(URL.init(string:)))
        let image = try await MihonNetworkClient.shared.fetchAsset(url: imageUrl)
        XCTAssertGreaterThan(CGImageSourceCreateWithData(image as CFData, nil).map(CGImageSourceGetCount) ?? 0, 0)
        let search = try await engine.searchManga(page: 1, query: "恋爱", filters: [])
        XCTAssertFalse(search.mangas.isEmpty)
    }

    /// A long title's episode list (非人哉, 1 271 episodes over 128 pages) comes back whole, newest first, with no
    /// episode twice — and fetched block by block it takes seconds, not minutes.
    func testLiveDongmanLongEpisodeList() async throws {
        let engine = DongmanLiveEngine()
        let started = Date()
        let chapters: [SChapter]
        do {
            chapters = try await engine.chapterList(manga: SManga(url: "/episodeList?titleNo=1804", title: "非人哉"))
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        XCTAssertGreaterThanOrEqual(chapters.count, 1_200)
        XCTAssertEqual(Set(chapters.map(\.url)).count, chapters.count)
        let numbers = chapters.compactMap { $0.url.firstMatch(of: #/episode_no=(\d+)/#).flatMap { Int($0.1) } }
        XCTAssertEqual(numbers, numbers.sorted(by: >), "newest first")
        XCTAssertLessThan(Date().timeIntervalSince(started), 90)
    }

    // MARK: - 再漫画 (live, skipped offline)

    func testLiveZaimanhuaEndToEnd() async throws {
        let engine = ZaimanhuaLiveEngine()
        let popular: MangasPage
        do {
            popular = try await engine.popularManga(page: 1)
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        XCTAssertFalse(popular.mangas.isEmpty)
        // A title can need an account; take the first of the top five that opens.
        for candidate in popular.mangas.prefix(5) {
            guard let chapters = try? await engine.chapterList(manga: candidate), let first = chapters.last else { continue }
            let details = try await engine.mangaDetails(manga: candidate)
            XCTAssertEqual(details.url, candidate.url)
            XCTAssertFalse(details.title.isEmpty)
            let pages = try await engine.pageList(chapter: first)
            let imageUrl = try XCTUnwrap(pages.first?.imageUrl.flatMap(URL.init(string:)))
            let image = try await MihonNetworkClient.shared.fetchAsset(url: imageUrl)
            let decoded = CGImageSourceCreateWithData(image as CFData, nil).map(CGImageSourceGetCount) ?? 0
            XCTAssertGreaterThan(decoded, 0, "page 1 of \(details.title) is not an image")
            let latest = try await engine.latestUpdates(page: 1)
            XCTAssertFalse(latest.mangas.isEmpty)
            let search = try await engine.searchManga(page: 1, query: details.title, filters: [])
            XCTAssertFalse(search.mangas.isEmpty)
            return
        }
        XCTFail("none of the five most popular titles could be read")
    }
}
