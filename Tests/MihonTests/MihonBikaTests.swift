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
    private func snapshot(_ document: BikaDocument, html: String) async throws -> [String: Any]? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"></head><body id='fixture'>" + html + "</body></html>",
                           baseURL: BikaWebsite.origin)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(40))
            if try await web.evaluateJavaScript("document.body?.id === 'fixture'") as? Bool == true {
                return try await web.callAsyncJavaScript(document.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
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
        XCTAssertEqual(login?["login"] as? Bool, true)
        let result = try await snapshot(.catalogue, html: catalogue("<div role='status'><a href='/comics/search'>清除筛选</a></div>"))
        let json = try XCTUnwrap(result?["json"] as? String)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((list["items"] as? [Any])?.count, 0)
        XCTAssertEqual(list["more"] as? Bool, false)
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
