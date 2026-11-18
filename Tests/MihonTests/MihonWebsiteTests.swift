import XCTest
import ImageIO
import MihonDomain
@testable import MihonData

final class MihonWebsiteTests: XCTestCase {
    @MainActor
    func testImportUpdateAndRemove() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        var rule = BundledWebsite.baozi.rule
        rule.baseUrl = "https://EXAMPLE.org/"
        try store.importHTMLSource(JSONEncoder().encode(rule))
        let source = try XCTUnwrap(store.importedSourceDescriptors.first)
        XCTAssertEqual(source.baseUrl, "https://example.org")
        XCTAssertTrue(store.activeCatalogueSources().contains { $0.id == source.id && $0.isLive })
        rule.name = "更新后的名称"
        try store.importHTMLSource(JSONEncoder().encode(rule))
        XCTAssertEqual(store.importedSourceDescriptors.count, 1)
        XCTAssertEqual(store.sourceDescriptor(for: source.id)?.name, rule.name)
        XCTAssertNil(store.websiteURL(sourceId: source.id, path: "//other.example/test"))
        rule.images = "a["
        XCTAssertThrowsError(try store.importHTMLSource(JSONEncoder().encode(rule)))
        XCTAssertTrue(store.isLiveSource(source.id))
        store.removeHTMLSource(id: source.id)
        XCTAssertNil(store.catalogueSource(for: source.id))
        for site in BundledWebsite.allCases {
            XCTAssertTrue(store.isLiveSource(site.sourceId))
            XCTAssertNoThrow(try site.rule.validated())
        }
        XCTAssertFalse(store.activeCatalogueSources().contains { $0.id == BundledWebsite.copy.sourceId })
        store.showNsfwSources = true
        XCTAssertTrue(store.activeCatalogueSources().contains { $0.id == BundledWebsite.copy.sourceId })
    }

    func testRuleSelectsLinksAndDeduplicates() {
        let rule = BundledWebsite.baozi.rule
        let engine = HTMLRuleEngine(rule: rule, site: .baozi)
        let doc = HTMLDocument(html: """
            <div class='comics-card'><a href='/comic/book'><amp-img src='/cover.jpg'></amp-img></a>
            <b class='comics-card__title'>题名</b></div>
            <div id='chapter-items'><div class='comics-chapters'>
            <a href='/chap/one'>第一话</a><a href='/chap/one'>重复</a>
            <a href='/chap/two'>第二话</a><a href='https://other.example/'>无关链接</a></div></div>
            """, baseURL: URL(string: rule.baseUrl))
        XCTAssertEqual(engine.cards(in: doc).map(\.url), ["/comic/book"])
        XCTAssertEqual(engine.cards(in: doc).first?.thumbnailUrl, rule.baseUrl + "/cover.jpg")
        XCTAssertEqual(engine.chapters(in: doc).map(\.name), ["第二话", "第一话"])
    }

    func testVomicChapterOrder() {
        let rule = BundledWebsite.vomic.rule
        let doc = HTMLDocument(html: """
            <a class="chapter" href="/chapter/48835/63619">00 初章</a>
            <a class="chapter" href="/chapter/48835/63617">1话</a>
            <a class="chapter" href="/chapter/48835/63616">2话</a>
            """, baseURL: URL(string: rule.baseUrl))
        let engine = HTMLRuleEngine(rule: rule, site: .vomic)
        XCTAssertEqual(engine.chapters(in: doc).map(\.name), ["2话", "1话", "00 初章"])
    }

    @MainActor
    func testSinglePageCatalogueRule() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let data = try Data(contentsOf: Self.exampleRule)
        try store.importHTMLSource(data)
        let id = try XCTUnwrap(store.importedSourceDescriptors.first?.id)
        let source = try XCTUnwrap(store.catalogueSource(for: id))
        XCTAssertFalse(source.supportsLatest)

        // An unpaginated directory can be searched in full on the phone.
        var rule = try JSONDecoder().decode(HTMLSourceRule.self, from: data)
        rule.popular += "?page={page}"
        XCTAssertThrowsError(try rule.validated())
    }

    private static var exampleRule: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Examples/Sources/peppercarrot-zh.json")
    }

    @MainActor
    func testLiveImportedPepperCarrot() async throws {
        guard ProcessInfo.processInfo.environment["ORIHON_TEST_WEBSITE"] == "peppercarrot" else {
            throw XCTSkip("Set ORIHON_TEST_WEBSITE=peppercarrot to check the downloadable rule")
        }
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        try store.importHTMLSource(Data(contentsOf: Self.exampleRule))
        let id = try XCTUnwrap(store.importedSourceDescriptors.first?.id)
        let source = try XCTUnwrap(store.activeCatalogueSources().first { $0.id == id })
        let catalogue = try await source.getPopularManga(page: 1)
        let results = try await source.getSearchManga(page: 1, query: "萝卜", filters: [])
        let book = try XCTUnwrap(results.mangas.first)
        XCTAssertEqual(catalogue.mangas.first?.url, book.url)
        let missing = try await source.getSearchManga(page: 1, query: "没有这本书123", filters: [])
        XCTAssertTrue(missing.mangas.isEmpty)
        let details = try await source.getMangaDetails(manga: book)
        let chapters = try await source.getChapterList(manga: details)
        let first = try XCTUnwrap(chapters.first { $0.name.contains("飞行魔药") })
        let pages = try await source.getPageList(chapter: first)
        XCTAssertEqual(pages.count, 4)
        for page in pages {
            let url = try XCTUnwrap(page.imageUrl.flatMap(URL.init(string:)))
            let data = try await MihonNetworkClient.shared.fetchAsset(url: url)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(image, 0, nil))
        }
        print("Imported \(details.title): \(chapters.count) chapters, \(pages.count) decoded pages in \(first.name)")
    }

    @MainActor
    func testDmzjViaZaimanhua() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let source = try XCTUnwrap(store.activeCatalogueSources().first { $0.id == 2_884_190_037_559_093_788 })
        XCTAssertTrue(source.isLive)
        guard ProcessInfo.processInfo.environment["ORIHON_TEST_WEBSITE"] == "dmzj" else {
            throw XCTSkip("Set ORIHON_TEST_WEBSITE=dmzj to verify legacy Android URLs online")
        }
        let oldURL = "/comic/comic_19526.json?version=2.7.019"
        let oldBook = Manga(id: 1, source: source.id, url: oldURL, title: "大理寺日志", favorite: true)
        let oldChapter = Chapter(id: 2, mangaId: 1, url: "19526/84800", name: "第1话",
                                 bookmark: true, lastPageRead: 1, totalPages: 2)
        let payload = MihonBackupPayload(backupManga: [oldBook], backupCategories: [], mangaCategoriesMap: [:],
            backupChapters: [oldChapter], backupHistory: [], backupTracks: [], backupExtensionRepos: [])
        try store.restoreFromBackup(TachiyomiBackupEncoder.encode(payload, sourceNames: [source.id: "动漫之家"]))
        let restored = try XCTUnwrap(store.mangas.first { $0.source == source.id && $0.url == oldURL })

        let popular = try await source.getPopularManga(page: 1)
        let latest = try await source.getLatestUpdates(page: 1)
        XCTAssertTrue(popular.mangas.first?.url.hasPrefix("/comic/comic_") == true)
        XCTAssertTrue(latest.mangas.first?.url.hasPrefix("/comic/comic_") == true)
        let result = try await source.getSearchManga(page: 1, query: "大理寺日志", filters: [])
        let book = try XCTUnwrap(result.mangas.first { $0.url == oldURL })
        XCTAssertEqual(store.upsertCatalogMangaToStore(book, sourceId: source.id).id, restored.id)
        let refreshed = await store.refreshMangaFromSource(mangaId: restored.id, force: true)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.manga(id: restored.id)?.title, "大理寺日志")
        let chapters = try XCTUnwrap(store.chaptersByManga[restored.id])
        let chapter = try XCTUnwrap(chapters.first { $0.url == oldChapter.url })
        XCTAssertTrue(chapter.bookmark)
        XCTAssertEqual(chapter.lastPageRead, 1)
        let pages = try await store.pageList(for: restored, chapter: chapter)
        let url = try XCTUnwrap(pages.first?.imageUrl.flatMap(URL.init(string:)))
        let image = try await MihonNetworkClient.shared.fetchAsset(url: url)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(image as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        print("DMZJ \(restored.title): \(chapters.count) chapters, \(pages.count) pages in \(chapter.name), \(image.count) bytes decoded")
    }

    @MainActor
    func testLiveWebsites() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["ORIHON_TEST_WEBSITE"], let site = BundledWebsite(rawValue: name) else {
            throw XCTSkip("Set ORIHON_TEST_WEBSITE to run a live site check")
        }
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.showNsfwSources = true
        let engine = try XCTUnwrap(store.activeCatalogueSources().first { $0.id == site.sourceId })
        let popular = try await engine.getPopularManga(page: 1)
        XCTAssertFalse(popular.mangas.isEmpty)
        if engine.supportsLatest {
            let latest = try await engine.getLatestUpdates(page: 1)
            XCTAssertFalse(latest.mangas.isEmpty)
        }
        let pick: (String, String) = switch site {
        case .baozi: ("/comic/yirenzhixia-dongmantang", "一人")
        case .goda: ("/manga/manhua-qingmeimeizhuzhuma", "青梅")
        case .manhuaren: ("/manhua-bailianchengshen2/", "百炼")
        case .copy: ("/comic/bluelock", "監獄")
        case .vomic: ("/detail/56539", "日常")
        }
        let search = try await engine.getSearchManga(page: 1, query: pick.1, filters: [])
        XCTAssertFalse(search.mangas.isEmpty, "search")
        let title = try await engine.getMangaDetails(manga: SManga(url: pick.0, title: ""))
        let chapters = try await engine.getChapterList(manga: title)
        let chapter = try XCTUnwrap(chapters.last)
        print("LIVE \(site) popular=\(popular.mangas.count) search=\(search.mangas.count) title=\(title.title) chapters=\(chapters.count) chapter=\(chapter.name)")
        let pages: [Page]
        do { pages = try await engine.getPageList(chapter: chapter) }
        catch HTMLSourceError.loginRequired where site == .vomic { return }
        let url = try XCTUnwrap(pages.first?.imageUrl.flatMap(URL.init(string:)))
        let image = try await MihonNetworkClient.shared.fetchAsset(url: url)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(image as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        print("LIVE \(site) pages=\(pages.count) imageBytes=\(image.count)")
    }
}
