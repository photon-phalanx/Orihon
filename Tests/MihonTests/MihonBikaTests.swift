import XCTest
import WebKit
import MihonDomain
@testable import MihonData

@MainActor
final class MihonBikaTests: XCTestCase {
    func testAccountSourceRegistrationAndWebLinks() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let id = BikaWebsite.sourceId
        XCTAssertFalse(store.activeCatalogueSources().contains { $0.id == id })
        store.showNsfwSources = true
        let source = try XCTUnwrap(store.activeCatalogueSources().first { $0.id == id })
        XCTAssertTrue(source.isLive && source.supportsLatest && source.isNsfw)
        let path = "/comic/reader/5822a6e3ad7ede654696e482/1"
        XCTAssertEqual(store.websiteURL(sourceId: id, path: path)?.absoluteString, "https://manhuabika.com" + path)
        XCTAssertNil(store.websiteURL(sourceId: id, path: "//another.example/comic"))
    }

    /// Exercise the same WebKit scripts as the source without a network request or a user account.
    private func snapshot(_ document: BikaDocument, html: String, baseURL: URL = BikaWebsite.origin, script: String? = nil) async throws -> [String: Any]? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"></head><body id='fixture'>" + html + "</body></html>",
                           baseURL: baseURL)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(40))
            if try await web.evaluateJavaScript("document.body?.id === 'fixture'") as? Bool == true {
                return try await web.callAsyncJavaScript(script ?? document.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
            }
        }
        throw URLError(.timedOut)
    }

    func testLoginAndEmptySearchAreDistinctFromLoading() async throws {
        func catalogue(_ contents: String) -> String {
            "<section aria-labelledby='catalog-heading'>" + contents + "<div id='catalog-pagination'></div></section>"
        }
        let loading = try await snapshot(.catalogue, html: catalogue("<a href='/comics/search'>搜索</a>"))
        XCTAssertNil(loading)
        let login = try await snapshot(.catalogue, html: catalogue("<div role='alert'><a href='/account/login'>登录</a></div>"))
        XCTAssertEqual(login?["checkAccount"] as? Bool, true)
        XCTAssertNil(login?["login"])
        let result = try await snapshot(.catalogue, html: catalogue("<div role='status'><a href='/comics/search'>清除筛选</a></div>"))
        let json = try XCTUnwrap(result?["json"] as? String)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((list["items"] as? [Any])?.count, 0)
        XCTAssertEqual(list["more"] as? Bool, false)
    }

    func testFilteredCatalogueKeepsSortAndSelectionOnEveryPage() throws {
        let categories = ["嗶咔漢化", "A+B & C"]
        for (order, code) in [(BikaCatalogueFilter.Order.newest, "dd"), (.oldest, "da"), (.likes, "ld"), (.views, "vd")] {
            for page in 1...2 {
                let url = try BikaWebsite.catalogueURL(page: page, filter: .init(selection: .categories(categories), order: order))
                let route = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(route.path, "/comics/search")
                XCTAssertEqual(route.queryItems?.map(\.name), ["s", "page", "c", "c"])
                XCTAssertEqual(route.queryItems?.compactMap(\.value), [code, String(page)] + categories)
                XCTAssertTrue(url.absoluteString.contains("A%2BB"))
            }
        }
        let tag = try BikaWebsite.catalogueURL(page: 2, filter: .init(selection: .tag("3D/A+B?#%"), order: .likes))
        XCTAssertEqual(tag.absoluteString, "https://manhuabika.com/comics/tag/3D%2FA+B%3F%23%25?s=ld&page=2")
        let reset = try BikaWebsite.catalogueURL(page: 1, filter: .init())
        XCTAssertEqual(reset.absoluteString, "https://manhuabika.com/comics?s=dd&page=1")
        let keyword = try BikaWebsite.catalogueURL(page: 1, filter: .init(), query: "A+B")
        XCTAssertEqual(keyword.absoluteString, "https://manhuabika.com/comics/search?s=dd&page=1&q=A%2BB")
        XCTAssertThrowsError(try BikaWebsite.catalogueURL(page: 0, filter: .init()))
    }

    func testLilyGardenAndDefaultRoutesUseNewest() throws {
        for page in [1, 2] {
            let garden = try BikaWebsite.catalogueURL(page: page, filter: .init(selection: .category(BikaWebsite.lilyGarden)))
            let route = try XCTUnwrap(URLComponents(url: garden, resolvingAgainstBaseURL: false))
            XCTAssertEqual(route.path, "/comics/category/百合花園")
            XCTAssertEqual(route.query, "s=dd&page=\(page)")
            for filter in [BikaCatalogueFilter(), .init(selection: .tag("3D")), .init(selection: .categories(["全彩"]))] {
                let url = try BikaWebsite.catalogueURL(page: page, filter: filter)
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "dd")
            }
        }
        XCTAssertEqual(BikaWebsite.model.sources.first?.popularPath, "/comics/category/百合花園?s=dd")
    }

    func testPrefetchIsSharedAndAccountChangeDiscardsOldRequests() async throws {
        let cache = BikaBrowseResource<Int>(lifetime: .seconds(60))
        var pending: CheckedContinuation<Int, Never>?
        XCTAssertTrue(cache.prefetch { await withCheckedContinuation { pending = $0 } })
        XCTAssertFalse(cache.prefetch { XCTFail("duplicate prefetch"); return -1 })
        while pending == nil { await Task.yield() }
        let reader = Task { try await cache.value { XCTFail("duplicate fetch"); return -1 } }
        await Task.yield()
        pending?.resume(returning: 36)
        let joined = try await reader.value
        let cached = try await cache.value { XCTFail("should be cached"); return -1 }
        XCTAssertEqual(joined, 36)
        XCTAssertEqual(cached, 36)

        cache.clear()
        pending = nil
        let old = Task { try await cache.value { await withCheckedContinuation { pending = $0 } } }
        while pending == nil { await Task.yield() }
        cache.clear()
        let current = try await cache.value { 15 }
        pending?.resume(returning: 99)
        do { _ = try await old.value; XCTFail("returned data from previous account") } catch is CancellationError {}
        let stillCurrent = try await cache.value { XCTFail("stale request evicted current value"); return -1 }
        XCTAssertEqual(current, 15)
        XCTAssertEqual(stillCurrent, 15)
    }

    func testBrowseCacheRetriesErrorsAndExpires() async throws {
        let cache = BikaBrowseResource<Int>(lifetime: .zero)
        do { _ = try await cache.value { throw URLError(.timedOut) }; XCTFail("expected failure") } catch is URLError {}
        let retry = try await cache.value { 1 }
        let refreshed = try await cache.value { 2 }
        XCTAssertEqual(retry, 1)
        XCTAssertEqual(refreshed, 2)
    }

    func testLandingArchiveSurvivesRelaunchAndSeparatesAccountsAndTabs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = BikaLandingArchive(directory: dir)
        let session = UUID(), nextSession = UUID()
        let garden = MangasPage(mangas: [SManga(url: "/garden", title: "分类首页")], hasNextPage: true)
        let latest = MangasPage(mangas: [SManga(url: "/latest", title: "全站首页")], hasNextPage: false)
        await first.save(garden, listing: .popular, session: session)
        await first.save(latest, listing: .latest, session: session)
        let directory = BikaFilterOptions(categories: [.init(value: "A", label: "类别")], tags: ["标签"])
        await first.saveOptions(directory, session: session)
        let reopened = BikaLandingArchive(directory: dir)
        let savedGarden = await reopened.read(.popular, session: session)
        let savedLatest = await reopened.read(.latest, session: session)
        let otherAccount = await reopened.read(.popular, session: nextSession)
        XCTAssertEqual(savedGarden, garden)
        XCTAssertEqual(savedLatest, latest)
        XCTAssertNil(otherAccount)
        let savedDirectory = await reopened.readOptions(session: session)
        let otherDirectory = await reopened.readOptions(session: nextSession)
        XCTAssertEqual(savedDirectory?.categories.first?.label, "类别")
        XCTAssertEqual(savedDirectory?.tags, ["标签"])
        XCTAssertNil(otherDirectory)
        await reopened.save(latest, listing: .popular, session: nextSession)
        await reopened.remove(session: session)
        let removed = await reopened.read(.latest, session: session)
        let remaining = await reopened.read(.popular, session: nextSession)
        XCTAssertNil(removed)
        XCTAssertEqual(remaining, latest)
        let removedDirectory = await reopened.readOptions(session: session)
        XCTAssertNil(removedDirectory)
    }

    func testLandingArchiveRejectsExpiredCorruptAndEmptyPages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BikaLandingArchive(directory: dir)
        let session = UUID(), now = Date()
        let page = MangasPage(mangas: [SManga(url: "/item", title: "测试")], hasNextPage: true)
        await cache.save(page, listing: .popular, session: session, now: now.addingTimeInterval(-8 * 86400))
        let expired = await cache.read(.popular, session: session, now: now)
        XCTAssertNil(expired)
        await cache.save(page, listing: .popular, session: session)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        try Data("truncated".utf8).write(to: XCTUnwrap(files.first))
        let corrupt = await cache.read(.popular, session: session)
        XCTAssertNil(corrupt)
        await cache.save(page, listing: .latest, session: session)
        await cache.save(MangasPage(mangas: [], hasNextPage: false), listing: .latest, session: session)
        let empty = await cache.read(.latest, session: session)
        XCTAssertNil(empty)
        await cache.save(page, listing: .search, session: session)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testFilterDirectoryUsesCanonicalCategoriesAndTheSitesHotTags() async throws {
        let html = """
            <main data-category-directory><div data-keyword-list>
            <a href="/comics/tag/AI%E4%BD%9C%E7%95%AB">#AI作畫</a><a href="/comics/tag/AI作畫">重复</a></div>
            <section aria-labelledby="category-directory-heading" aria-busy="false"><div data-category-grid>
            <a href="/comics/category/嗶咔漢化" aria-label="哔咔汉化"></a>
            <a href="/comics/category/大家都在看">推荐入口</a><a href="/comics/leaderboard">排行榜</a>
            <button data-category-ad>广告</button></div></section>
            <aside><a href="/comics/tag/其他">自定义标签</a></aside></main>
            """
        let result = try await snapshot(.filterOptions, html: html)
        let json = try XCTUnwrap(result?["json"] as? String)
        let options = try JSONDecoder().decode(BikaFilterOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.categories.map(\.value), ["嗶咔漢化"])
        XCTAssertEqual(options.categories.map(\.label), ["哔咔汉化"])
        XCTAssertEqual(options.tags, ["AI作畫"])
        let loading = try await snapshot(.filterOptions, html: html.replacingOccurrences(of: "aria-busy=\"false\"", with: "aria-busy=\"true\""))
        XCTAssertNil(loading)
        let loadingTags = try await snapshot(.filterOptions, html: html.replacingOccurrences(of: "data-keyword-list", with: "class='_keywordsSkeleton_test'"))
        XCTAssertNil(loadingTags)
        let error = try await snapshot(.filterOptions, html: html.replacingOccurrences(of: "<aside>", with: "<aside role='alert'>"))
        XCTAssertEqual(error?["checkAccount"] as? Bool, true)
    }

    func testInlineRetryOnlyClicksTheRequestedSitesErrorControls() async throws {
        let html = """
            <aside role="alert"><button>其他</button></aside>
            <section aria-labelledby="catalog-heading"><div role="alert"><button>目录</button></div></section>
            <main data-category-directory><div role="alert"><button>分类</button></div></main>
            """
        for (document, name) in [(BikaDocument.catalogue, "目录"), (.filterOptions, "分类")] {
            let retry = try XCTUnwrap(document.retryScript)
            let script = """
                const clicked = [];
                document.addEventListener('click', e => clicked.push(e.target.textContent));
                const retried = (() => { \(retry) })();
                return {retried, clicked};
                """
            let result = try await snapshot(document, html: html, script: script)
            XCTAssertEqual(result?["retried"] as? Bool, true)
            XCTAssertEqual(result?["clicked"] as? [String], [name])
            let missing = try await snapshot(document, html: "<aside role='alert'><button>其他</button></aside>", script: script)
            XCTAssertEqual(missing?["retried"] as? Bool, false)
            XCTAssertEqual(missing?["clicked"] as? [String], [])
        }
    }

    func testOnlyTheProtectedAccountPageConfirmsAuthentication() async throws {
        let guest = try await snapshot(.account, html: "<main><input type='password'></main>", baseURL: BikaWebsite.loginURL)
        XCTAssertEqual(guest?["json"] as? String, "false")
        let restoring = try await snapshot(.account, html: "<main>加载中</main>", baseURL: BikaWebsite.accountURL)
        XCTAssertNil(restoring)
        let account = try await snapshot(.account, html: "<main><button>退出登录</button></main>", baseURL: BikaWebsite.accountURL)
        XCTAssertEqual(account?["json"] as? String, "true")
        let catalogue = try await snapshot(.catalogue, html: """
            <section aria-labelledby="catalog-heading"><aside><div role="alert">
            <a href="/account/login">登录</a></div></aside>
            <article data-card-layout><a href="/comic/abc" title="漫画"></a></article>
            <div id="catalog-pagination"><div class="_pagination_test"></div></div></section>
            """)
        XCTAssertNotNil(catalogue?["json"])
        XCTAssertNil(catalogue?["checkAccount"])
    }

    func testPartialManifestsAreNotReturnedAsComplete() async throws {
        let directory = try await snapshot(.episodes, html: """
            <div id="comic-chapters"><p class="_chapterLoaded_fixture">已加载 1 / 2 话</p>
            <a href="/comic/reader/book/1"><strong>第一话</strong></a></div>
            """)
        XCTAssertEqual(directory?["progress"] as? Int, 1)
        let reader = try await snapshot(.reader, html: """
            <span class="_pageCount_fixture">1 / 3</span><div data-reader-column>
            <figure data-page="1"><img src="https://media.example/1"></figure>
            <aside><img src="https://media.example/ad"></aside>
            <figure data-page="2"></figure><figure data-page="3"></figure></div>
            """)
        XCTAssertEqual(reader?["progress"] as? Int, 1)
        XCTAssertNil(reader?["json"])
    }
}
