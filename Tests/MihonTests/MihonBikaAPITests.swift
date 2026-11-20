import Foundation
import XCTest
import MihonDomain
@testable import MihonData

@MainActor final class MihonBikaAPITests: XCTestCase {
    private let id = "5822a6e3ad7ede654696e482"

    private func client(token: String? = "test-token", handler: @escaping (URLRequest) throws -> (Int, [String: Any])) -> BikaAPI {
        BikaStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BikaStub.self]
        return BikaAPI(session: URLSession(configuration: config), token: token)
    }

    func testIOSDocumentVectorAndEncodedQuerySignature() throws {
        XCTAssertEqual(BikaAPI.signature(path: "/auth/register", method: "POST", time: "1700000000", nonce: String(repeating: "0", count: 32)),
                       "fcba281837e0efa05493447bedfbe19bd145d2db1755198c25a62a96540875df")
        let a = BikaAPI.signature(path: "/comics?page=2&t=A%2BB", method: "GET", time: "1700000000", nonce: "abc")
        XCTAssertNotEqual(a, BikaAPI.signature(path: "/comics?t=A%2BB&page=2", method: "GET", time: "1700000000", nonce: "abc"))
        XCTAssertNotEqual(a, BikaAPI.signature(path: "/comics?page=2&t=A+B", method: "GET", time: "1700000000", nonce: "abc"))
        XCTAssertEqual(String(data: BikaAPI.form([("email", "a+b@x.test"), ("password", "a&= +%"), ("categories[]", "A"), ("categories[]", "B")]), encoding: .utf8),
                       "email=a%2Bb%40x.test&password=a%26%3D%20%2B%25&categories%5B%5D=A&categories%5B%5D=B")
    }

    func testRoutesPreserveAllFiltersAndSortOnLaterPages() throws {
        for order in BikaCatalogueFilter.Order.allCases {
            let garden = try BikaWebsite.catalogueRequest(page: 3, filter: .init(selection: .category(BikaWebsite.lilyGarden), order: order))
            XCTAssertEqual(garden.path, "/comics?page=3&c=%E7%99%BE%E5%90%88%E8%8A%B1%E5%9C%92&s=" + order.rawValue)
            XCTAssertNil(garden.form)
            let multi = try BikaWebsite.catalogueRequest(page: 2, filter: .init(selection: .categories(["A", "B"]), order: order), query: "A+B")
            XCTAssertEqual(multi.path, "/comics/advanced-search?page=2")
            XCTAssertEqual(multi.form?.map(\.0), ["categories[]", "categories[]", "keyword", "sort"])
            XCTAssertEqual(multi.form?.map(\.1), ["A", "B", "A+B", order.rawValue])
        }
        let tag = try BikaWebsite.catalogueRequest(page: 2, filter: .init(selection: .tag("3D/A+B?#%"), order: .likes))
        XCTAssertEqual(tag.path, "/comics?page=2&s=ld&t=3D%2FA%2BB%3F%23%25")
        XCTAssertThrowsError(try BikaWebsite.catalogueRequest(page: 0, filter: .init()))
    }

    func testLoginUsesFormAndSignedIOSHeadersThenRawTokenAndLogout() async throws {
        var paths: [String] = []
        let api = client(token: nil) { request in
            let path = request.url!.path
            paths.append(path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "app-platform"), "ios")
            XCTAssertEqual(request.value(forHTTPHeaderField: "app-version"), "2.1.2.5")
            XCTAssertEqual(request.value(forHTTPHeaderField: "app-build-version"), "34")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BikaAPI.userAgent)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "image-quality"))
            let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "nonce"))
            XCTAssertEqual(nonce.count, 32)
            let time = try XCTUnwrap(request.value(forHTTPHeaderField: "time"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "signature"), BikaAPI.signature(path: path, method: request.httpMethod!, time: time, nonce: nonce))
            if path == "/auth/sign-in" {
                XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertEqual(BikaStub.body(request), "email=a%2Bb&password=p%26%3D%20%2B")
                return (200, ["token": "issued-token"])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "issued-token")
            return (200, ["prodUrl": "https://api.tipatipa.xyz", "prodChat": "https://chat.tipatipa.xyz"])
        }
        try await api.login(account: "a+b", password: "p&= +")
        _ = try await api.sources()
        await api.logout()
        do { _ = try await api.sources(); XCTFail("logged-out request sent") } catch { XCTAssertEqual(error as? BikaReadError, .login) }
        XCTAssertEqual(paths, ["/auth/sign-in", "/sources"])
    }

    func testExpiredTokenAndLoginFailureStayDistinct() async throws {
        let api = client { _ in (401, [:]) }
        do { _ = try await api.profile(); XCTFail("expected expiry") } catch { XCTAssertEqual(error as? BikaReadError, .login) }
        let loggedIn = await api.isLoggedIn
        XCTAssertFalse(loggedIn)
        do { try await api.login(account: "test", password: "invalid"); XCTFail("expected rejection") }
        catch { guard case BikaAPIError.authentication = error else { return XCTFail("wrong error: \(error)") } }
    }

    func testAllChapterPagesAndSavedReadingPositionLoadWithoutWebKit() async throws {
        var requested: [Int] = []
        let api = client { request in
            XCTAssertEqual(request.url?.path, "/comics/5822a6e3ad7ede654696e482/order/2/pages")
            let number = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)!
            requested.append(number)
            let names = number == 1 ? ["1.jpg", "2.jpg"] : number == 2 ? ["3.jpg", "4.jpg"] : ["5.jpg"]
            return (200, ["pages": ["page": String(number), "pages": 3, "total": 5, "limit": 2,
                                   "docs": names.map { ["media": ["fileServer": "https://media.example", "path": $0]] }]])
        }
        let engine = BikaWebsite(api: api)
        var preview: Page?
        let result = try await engine.pageList(chapter: .init(url: "/comic/reader/\(id)/2", name: "第二话"), openingAt: 4) { page, total in
            XCTAssertEqual(total, 5)
            XCTAssertEqual(requested, [1, 3])
            preview = page
        }
        XCTAssertEqual(requested, [1, 3, 2])
        XCTAssertEqual(preview?.index, 4)
        XCTAssertEqual(result.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(result.map(\.imageUrl), (1...5).map { "https://media.example/static/\($0).jpg" })
    }

    func testIncompleteSecondPageIsNeverReturnedAsWholeChapter() async throws {
        let api = client { request in
            let first = request.url!.query == "page=1"
            return (200, ["pages": ["page": first ? 1 : 2, "pages": 2, "total": 3, "limit": 2,
                                   "docs": first ? ["1.jpg", "2.jpg"].map { ["media": ["fileServer": "https://media.example", "path": $0]] } : []]])
        }
        do { _ = try await BikaWebsite(api: api).pageList(chapter: .init(url: "/comic/reader/\(id)/1", name: "chapter")); XCTFail("accepted partial chapter") }
        catch { XCTAssertEqual(error as? BikaReadError, .unavailable) }
    }

    func testEpisodePaginationPreservesLegacyURLsAndSortsNewestFirst() async throws {
        let api = client { request in
            let page = request.url!.query == "page=1" ? 1 : 2
            return (200, ["eps": ["page": page, "pages": 2, "total": 2, "limit": 1,
                                 "docs": [["order": page, "title": "Episode \(page)", "updated_at": "2026-11-20T10:00:00.000Z"]]]])
        }
        let chapters = try await BikaWebsite(api: api).chapterList(manga: .init(url: "/comic/\(id)", title: "test"))
        XCTAssertEqual(chapters.map(\.url), ["/comic/reader/\(id)/2", "/comic/reader/\(id)/1"])
        XCTAssertTrue(chapters.allSatisfy { $0.dateUpload > SChapter.undatedUpload })
    }

    func testMediaPathsAndEmptySearch() async throws {
        XCTAssertEqual(try BikaMedia(fileServer: "https://cdn.example/static/", path: "a/1 image.jpg").imageURL(), "https://cdn.example/static/a/1%20image.jpg")
        XCTAssertThrowsError(try BikaMedia(fileServer: "https://cdn.example", path: "../x.jpg").imageURL())
        XCTAssertThrowsError(try BikaMedia(fileServer: "https://user:secret@cdn.example", path: "x.jpg").imageURL())
        let api = client { _ in (200, ["comics": ["docs": [], "page": 1, "pages": 0, "limit": 20, "total": 0]]) }
        let page = try await BikaWebsite(api: api).searchManga(page: 1, query: "no results", filters: [])
        XCTAssertTrue(page.mangas.isEmpty)
        XCTAssertFalse(page.hasNextPage)
    }

    func testLogoutDiscardsAnInFlightLogin() async throws {
        let started = expectation(description: "request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let api = client(token: nil) { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return (200, ["token": "stale-token"])
        }
        let login = Task { try await api.login(account: "test", password: "test") }
        await fulfillment(of: [started], timeout: 3)
        await api.logout()
        release.signal()
        do { try await login.value; XCTFail("late login restored a logged-out account") } catch is CancellationError {}
        let loggedIn = await api.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testFilterDirectoryExcludesPromotionsAndDeduplicatesTags() async throws {
        BikaWebsite.clearBrowseCache()
        let api = client { request in
            if request.url!.path == "/categories" {
                return (200, ["categories": [
                    ["title": "promotion", "isWeb": true],
                    ["title": "virtual entry"],
                    ["_id": "1", "title": "全彩"],
                    ["_id": "2", "title": "全彩"],
                    ["_id": "3", "title": "inactive", "active": false]
                ]])
            }
            return (200, ["keywords": ["test", "test", "other"]])
        }
        let options = try await BikaWebsite(api: api).filterOptions()
        XCTAssertEqual(options.categories.map(\.value), ["全彩"])
        XCTAssertEqual(options.tags, ["test", "other"])
        BikaWebsite.clearBrowseCache()
    }

    /// Opt-in verification against production. Credentials are supplied by the invoking process, never fixtures.
    func testLiveIOSAPI() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let account = env["BIKA_TEST_ACCOUNT"], let password = env["BIKA_TEST_PASSWORD"] else { throw XCTSkip("Live credentials not provided") }
        let api = BikaAPI(session: URLSession(configuration: .ephemeral))
        try await api.login(account: account, password: password)
        let routes = try await api.sources()
        XCTAssertEqual(routes.prodUrl, BikaAPI.baseURL.absoluteString)
        _ = try await api.profile()
        BikaWebsite.clearBrowseCache()
        let engine = BikaWebsite(api: api)
        let options = try await engine.filterOptions()
        XCTAssertTrue(options.categories.contains { $0.value == BikaWebsite.lilyGarden })
        let garden = try await engine.popularManga(page: 1)
        XCTAssertFalse(garden.mangas.isEmpty)
        _ = try await engine.latestUpdates(page: 2)
        _ = try await engine.filteredManga(page: 1, filter: .init(selection: .categories([BikaWebsite.lilyGarden, "全彩"])))
        if let tag = options.tags.first { _ = try await engine.filteredManga(page: 1, filter: .init(selection: .tag(tag))) }
        _ = try await engine.searchManga(page: 1, query: "百合", filters: [])
        let target = env["BIKA_TEST_COMIC_ID"].map { SManga(url: "/comic/" + $0, title: "Live pagination check") } ?? garden.mangas.first
        let manga = try await engine.mangaDetails(manga: XCTUnwrap(target))
        let chapters = try await engine.chapterList(manga: manga)
        let chapter = try XCTUnwrap(chapters.first)
        var previewIndex: Int?
        let pages = try await engine.pageList(chapter: chapter, openingAt: 45) { page, _ in previewIndex = page.index }
        XCTAssertFalse(pages.isEmpty)
        XCTAssertEqual(previewIndex, min(45, pages.count - 1))
        if env["BIKA_TEST_COMIC_ID"] != nil { XCTAssertGreaterThan(pages.count, 80) }
        for url in [manga.thumbnailUrl, pages.first?.imageUrl].compactMap({ $0 }).compactMap(URL.init(string:)) {
            let data = try await MihonNetworkClient.shared.fetchAsset(url: url)
            XCTAssertGreaterThan(data.count, 1000)
            XCTAssertTrue(data.starts(with: [0xff, 0xd8]) || data.starts(with: [0x89, 0x50, 0x4e, 0x47]) || data.starts(with: [0x52, 0x49, 0x46, 0x46]))
        }
        print("Bika live: login, sources, profile, filters, search, details, \(chapters.count) chapters, \(pages.count) pages, cover and page image passed")
        await api.logout()
    }
}

private final class BikaStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, payload) = try Self.handler!(request)
            let data = try JSONSerialization.data(withJSONObject: ["code": status, "data": payload])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return String(data: result, encoding: .utf8)
    }
}
