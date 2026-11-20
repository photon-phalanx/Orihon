import CryptoKit
import XCTest
import WebKit
import MihonDomain
@testable import MihonData

@MainActor
final class MihonBikaTests: XCTestCase {
    func testHMACMatchesRFC4231() {
        // RFC 4231 cases 1 and 3 cover text and non-UTF-8 input.
        XCTAssertEqual(BikaWebsite.hmacSHA256(for: Data("Hi There".utf8),
            using: SymmetricKey(data: Data(repeating: 0x0b, count: 20))),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(BikaWebsite.hmacSHA256(for: Data(repeating: 0xdd, count: 50),
            using: SymmetricKey(data: Data(repeating: 0xaa, count: 20))),
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
    }

    func testNativePageBatchesStayInOrderAcrossRetriesAndChapters() throws {
        let id = "5822a6e3ad7ede654696e482"
        let reader = try XCTUnwrap(BikaReaderPages(readerURL: BikaWebsite.origin.appendingPathComponent("comic/reader/\(id)/1/waterfall")))
        func deliver(_ n: Int, _ paths: [String], order: Int = 1) throws {
            let docs = paths.map { ["media": ["fileServer": "https://media.example", "path": $0]] }
            let json = try JSONSerialization.data(withJSONObject: ["data": ["pages": [
                "page": String(n), "pages": 2, "limit": "2", "total": 3, "docs": docs
            ]]])
            let endpoint = try XCTUnwrap(URL(string: "https://picaapi.part26.art/comics/\(id)/order/\(order)/pages?page=\(n)"))
            reader.receive(body: json, from: endpoint)
        }
        try deliver(2, ["other.jpg"], order: 2)
        try deliver(2, ["last.jpg"])
        XCTAssertTrue(reader.images.isEmpty)
        XCTAssertNil(reader.complete)
        try deliver(1, ["a/first image.jpg", "b/second.jpg"])
        try deliver(1, ["a/first image.jpg", "b/second.jpg"])
        XCTAssertEqual(reader.complete, ["https://media.example/static/a/first%20image.jpg",
                                         "https://media.example/static/b/second.jpg", "https://media.example/static/last.jpg"])
        try deliver(2, ["../wrong.jpg"])
        XCTAssertNil(reader.complete)
    }

    func testNativeReaderRejectsIncompleteOrInconsistentPageCounts() throws {
        let id = "5822a6e3ad7ede654696e482"
        let reader = try XCTUnwrap(BikaReaderPages(readerURL: BikaWebsite.origin.appendingPathComponent("comic/reader/\(id)/1/waterfall")))
        XCTAssertNil(BikaReaderPages(readerURL: BikaWebsite.accountURL))
        let endpoint = try XCTUnwrap(URL(string: "https://picaapi.picacomic.com/comics/\(id)/order/1/pages?page=1"))
        let response = #"{"data":{"pages":{"page":"1","limit":40,"total":230,"pages":6,"docs":[]}}}"#
        reader.receive(body: Data(response.utf8), from: endpoint)
        XCTAssertNil(reader.complete)
        XCTAssertTrue(reader.images.isEmpty)
    }

    func testWebKitPassesOnlySuccessfulIOSPageResponsesToNativeReader() async throws {
        let id = "5822a6e3ad7ede654696e482"
        let url = BikaWebsite.origin.appendingPathComponent("comic/reader/\(id)/1/waterfall")
        let reader = try XCTUnwrap(BikaReaderPages(readerURL: url))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let stub = #"""
            window.clonedEndpoints = [];
            window.fetch = async (endpoint, {ok}) => ({ url: endpoint, ok, clone() {
                window.clonedEndpoints.push(endpoint);
                return { text: async () => JSON.stringify({data: {pages: {page: 1, pages: 1, total: 1, limit: 40,
                    docs: [{media: {fileServer: 'https://media.example', path: 'first.jpg'}}]}}}) };
            }});
            """#
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: stub, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        reader.install(in: controller)
        let view = WKWebView(frame: .zero, configuration: config)
        view.loadHTMLString("<title>Fixture</title>", baseURL: url)
        for _ in 0..<100 {
            if try await view.evaluateJavaScript("document.title === 'Fixture'") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let path = "/comics/\(id)/order/1/pages?page=1"
        let accepted = "https://api.tipatipa.xyz" + path
        let cloned = try await view.callAsyncJavaScript("""
            await fetch(accepted, {ok: false});
            await fetch('https://chat.tipatipa.xyz' + path, {ok: true});
            await fetch('https://api.tipatipa.xyz:8443' + path, {ok: true});
            await fetch(accepted, {ok: true});
            return window.clonedEndpoints;
            """, arguments: ["path": path, "accepted": accepted], in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(cloned, [accepted])
        for _ in 0..<100 where reader.complete == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(reader.complete, ["https://media.example/static/first.jpg"])
    }

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

    func testAdFilterHidesPlacementsAndDismissesOnlyTheBikaAdDialog() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let rules = await BikaAdFilter.ruleList.value
        XCTAssertNotNil(rules)
        await BikaAdFilter.install(in: config.userContentController)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        let html = """
            <section data-banner-motion><div data-home-banner-slide>Banner</div></section>
            <button data-category-ad>Ad</button><aside data-detail-advertisement>Ad</aside>
            <aside data-waterfall-ad>Ad</aside><aside data-chapter-end-ad>Ad</aside>
            <div data-reader-ad-group>Ad</div>
            <a id="category" href="/comics">Category</a><figure id="page" data-page>Page</figure>
            <dialog id="normal"><button aria-label="关闭广告">Continue</button></dialog>
            <dialog id="ad"><section data-home-popup-panel><button aria-label="关闭广告"
                onclick="this.closest('dialog').close()">Close</button><div data-home-popup-ads></div></section></dialog>
            """
        for domain in ["manhuabika.com", "example.org"] {
            view.loadHTMLString(html, baseURL: try XCTUnwrap(URL(string: "https://" + domain + "/")))
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                let ready = try await view.callAsyncJavaScript("return location.host === domain && !!document.querySelector('#ad')",
                    arguments: ["domain": domain], in: nil, contentWorld: .defaultClient) as? Bool
                if ready == true { break }
            }
            let result = try await view.callAsyncJavaScript("""
                const normal = document.querySelector('#normal'), ad = document.querySelector('#ad');
                normal.showModal(); ad.showModal();
                await new Promise(resolve => setTimeout(resolve, 40));
                const visible = e => getComputedStyle(e).display !== 'none';
                const slots = document.querySelectorAll('body > section, body > button, body > aside, body > div');
                return [slots.length, [...slots].filter(visible).length, Number(ad.open), Number(normal.open),
                        Number(visible(document.querySelector('#category')) && visible(document.querySelector('#page')))];
                """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [Int]
            XCTAssertEqual(result, domain == "manhuabika.com" ? [6, 0, 0, 1, 1] : [6, 6, 1, 1, 1])
        }
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

}
