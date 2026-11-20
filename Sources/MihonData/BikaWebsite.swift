import CryptoKit
import Foundation
import MihonDomain

public struct BikaCatalogueFilter: Equatable, Sendable {
    public enum Order: String, CaseIterable, Sendable {
        case newest = "dd", oldest = "da", likes = "ld", views = "vd"
    }

    public enum Selection: Equatable, Sendable {
        case category(String)
        case categories([String])
        case tag(String)
    }

    public var selection: Selection
    public var order: Order

    public init(selection: Selection = .categories([]), order: Order = .newest) {
        self.selection = selection
        self.order = order
    }
}

public struct BikaFilterOptions: Codable, Sendable {
    public struct Category: Codable, Sendable {
        public let value: String
        public let label: String
    }

    public let categories: [Category]
    public let tags: [String]
}

/// The source ID and canonical library paths remain stable across the website → iOS API migration.
public struct BikaWebsite: LiveSourceEngine {
    private static let package = "org.orihon.web.bika"
    public static let sourceId = StableHash.positiveId(package)
    private let api: BikaAPI
    public init() { api = .shared }
    init(api: BikaAPI) { self.api = api }

    public static func hmacSHA256(for message: Data, using key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: message, using: key).map { String(format: "%02x", $0) }.joined()
    }
    static let origin = URL(string: "https://manhuabika.com")!
    public static let accountURL = origin.appendingPathComponent("profile")
    public static let loginURL = origin.appendingPathComponent("account/login")
        .appending(queryItems: [URLQueryItem(name: "returnTo", value: "/profile")])
    static let lilyGarden = "百合花園"
    @MainActor private static let gardenPage = BikaBrowseResource<MangasPage>(lifetime: .seconds(60))
    @MainActor private static let latestPage = BikaBrowseResource<MangasPage>(lifetime: .seconds(60))
    @MainActor private static let directory = BikaBrowseResource<BikaFilterOptions>(lifetime: .seconds(600))

    private static let archiveKey = "orihon.bika.ios.landingSession"
    private static let archive = BikaLandingArchive(directory: URL.cachesDirectory.appendingPathComponent("BikaLanding-iOS-v1"))
    @MainActor private static var landingSession: UUID = {
        if let id = UserDefaults.standard.string(forKey: archiveKey).flatMap(UUID.init(uuidString:)) { return id }
        return newLandingSession()
    }()
    @MainActor private static var editingAccount = false

    private static func newLandingSession() -> UUID {
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: archiveKey)
        return id
    }

    @MainActor public static func beginAccountEditing() {
        guard !editingAccount else { return }
        editingAccount = true
        clearBrowseCache()
    }

    @MainActor public static func endAccountEditing() {
        clearBrowseCache()
        editingAccount = false
    }

    @MainActor public static func clearBrowseCache() {
        let old = landingSession
        landingSession = newLandingSession()
        invalidateLiveListings()
        Task { await archive.remove(session: old) }
    }

    @MainActor public func savedLandingPage(for listing: SourceListing) async -> MangasPage? {
        guard !Self.editingAccount, listing != .search else { return nil }
        let resource = listing == .popular ? Self.gardenPage : Self.latestPage
        guard !resource.hasCachedValue else { return nil }
        let session = Self.landingSession
        let page = await Self.archive.read(listing, session: session)
        guard !Task.isCancelled, session == Self.landingSession, !Self.editingAccount else { return nil }
        return page
    }

    @MainActor public func savedFilterOptions() async -> BikaFilterOptions? {
        guard !Self.editingAccount, !Self.directory.hasCachedValue else { return nil }
        let session = Self.landingSession
        let options = await Self.archive.readOptions(session: session)
        guard !Task.isCancelled, session == Self.landingSession, !Self.editingAccount else { return nil }
        return options
    }

    @MainActor public static func invalidateLiveListings() {
        gardenPage.clear()
        latestPage.clear()
        directory.clear()
    }

    static let model = ExtensionModel(name: "哔咔漫画", pkgName: package, versionName: "2", versionCode: 2,
        lang: "zh", isNsfw: true, apkName: "", installState: .installed, sources: [
            ExtensionSourceDescriptor(id: sourceId, name: "哔咔漫画", lang: "zh", baseUrl: BikaAPI.baseURL.absoluteString,
                isNsfw: true, popularPath: "/comics?page=1&c=百合花園&s=dd", latestPath: "/comics?page=1&s=dd",
                searchPath: "/comics/advanced-search?page=1")
        ])

    static func siteURL(_ path: String) -> URL? {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme, url.host == origin.host, url.port == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public func mangaWebUrl(manga: SManga) -> String { Self.siteURL(manga.url)?.absoluteString ?? Self.origin.absoluteString }

    public func popularManga(page: Int) async throws -> MangasPage {
        let filter = BikaCatalogueFilter(selection: .category(Self.lilyGarden))
        return page == 1 ? try await landingPage(.popular, filter: filter) : try await filteredManga(page: page, filter: filter)
    }

    public func latestUpdates(page: Int) async throws -> MangasPage {
        return page == 1 ? try await landingPage(.latest, filter: .init()) : try await filteredManga(page: page, filter: .init())
    }

    @MainActor private func landingPage(_ listing: SourceListing, filter: BikaCatalogueFilter) async throws -> MangasPage {
        let resource = listing == .popular ? Self.gardenPage : Self.latestPage
        let session = Self.landingSession
        return try await resource.value {
            let page = try await filteredManga(page: 1, filter: filter)
            try Task.checkCancellation()
            if session == Self.landingSession, !Self.editingAccount {
                await Self.archive.save(page, listing: listing, session: session)
            }
            return page
        }
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        try await listing(page: page, filter: .init(), query: query)
    }

    public func filteredManga(page: Int, filter: BikaCatalogueFilter) async throws -> MangasPage {
        try await listing(page: page, filter: filter)
    }

    static func catalogueRequest(page: Int, filter: BikaCatalogueFilter, query: String = "") throws -> (path: String, form: [(String, String)]?) {
        guard page > 0 else { throw URLError(.badURL) }
        let sort = filter.order.rawValue
        switch filter.selection {
        case .category(let name):
            return ("/comics?page=\(page)&c=\(BikaAPI.encode(name))&s=\(sort)", nil)
        case .tag(let name):
            return ("/comics?page=\(page)&s=\(sort)&t=\(BikaAPI.encode(name))", nil)
        case .categories(let names):
            if names.isEmpty && query.isEmpty { return ("/comics?page=\(page)&s=\(sort)", nil) }
            return ("/comics/advanced-search?page=\(page)",
                    names.map { ("categories[]", $0) } + [("keyword", query), ("sort", sort)])
        }
    }

    private func listing(page: Int, filter: BikaCatalogueFilter, query: String = "") async throws -> MangasPage {
        let route = try Self.catalogueRequest(page: page, filter: filter, query: query)
        let response: BikaComics = try await api.request(route.path, form: route.form)
        try response.comics.validate(page: page)
        return MangasPage(mangas: try response.comics.docs.map { try $0.manga(initialized: false) }, hasNextPage: page < response.comics.pages)
    }

    @MainActor public func filterOptions() async throws -> BikaFilterOptions {
        let session = Self.landingSession
        return try await Self.directory.value {
            async let categories: BikaCategories = api.request("/categories")
            async let keywords: BikaKeywords = api.request("/keywords")
            let (c, k) = try await (categories, keywords)
            var seen = Set<String>()
            let values = c.categories.filter { $0._id != nil && $0.isWeb != true && $0.active != false && seen.insert($0.title).inserted }
            seen = []
            let options = BikaFilterOptions(categories: values.map { .init(value: $0.title, label: $0.title) },
                                            tags: k.keywords.filter { seen.insert($0).inserted })
            try Task.checkCancellation()
            if session == Self.landingSession, !Self.editingAccount { await Self.archive.saveOptions(options, session: session) }
            return options
        }
    }

    private func comicID(_ path: String) throws -> String {
        guard let url = Self.siteURL(path), let match = url.path.wholeMatch(of: #//comic/([0-9a-fA-F]{24})/?/#) else { throw URLError(.badURL) }
        return String(match.1)
    }

    public func mangaDetails(manga: SManga) async throws -> SManga {
        let response: BikaComicDetail = try await api.request("/comics/\(comicID(manga.url))")
        return try response.comic.manga(initialized: true)
    }

    public func chapterList(manga: SManga) async throws -> [SChapter] {
        let id = try comicID(manga.url)
        var result: [BikaEpisode] = [], page = 1
        var first: BikaBatch<BikaEpisode>?
        repeat {
            let response: BikaEpisodes = try await api.request("/comics/\(id)/eps?page=\(page)")
            let batch = response.eps
            try batch.validate(page: page)
            if let first { try batch.match(first) } else { first = batch }
            result += batch.docs
            if page >= batch.pages { break }
            page += 1
        } while true
        guard Set(result.map(\.order)).count == result.count, result.allSatisfy({ $0.order > 0 }) else { throw BikaReadError.unavailable }
        return result.sorted { $0.order > $1.order }.map {
            SChapter(url: "/comic/reader/\(id)/\($0.order)", name: $0.title,
                     dateUpload: Self.date($0.updated_at), chapterNumber: Double($0.order))
        }
    }

    private static func date(_ value: String?) -> Date {
        guard let value else { return SChapter.undatedUpload }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? SChapter.undatedUpload
    }

    @MainActor public func pageList(chapter: SChapter) async throws -> [Page] {
        try await pageList(chapter: chapter, openingAt: 0, onOpeningPage: nil)
    }

    @MainActor func pageList(chapter: SChapter, openingAt: Int,
                            onOpeningPage: (@MainActor (Page, Int) -> Void)?) async throws -> [Page] {
        guard let url = Self.siteURL(chapter.url),
              let match = url.path.wholeMatch(of: #//comic/reader/([0-9a-fA-F]{24})/([1-9][0-9]*)/?/#) else { throw URLError(.badURL) }
        let path = "/comics/\(match.1)/order/\(match.2)/pages?page="
        let response: BikaPages = try await api.request(path + "1")
        let first = response.pages
        try first.validate(page: 1)
        guard first.total > 0 else { throw BikaReadError.unavailable }
        let index = min(max(0, openingAt), first.total - 1)
        let openingBatch = index / first.limit + 1
        var batches = [1: first]
        func page(_ index: Int, _ doc: BikaPageDocument) throws -> Page {
            Page(index: index, url: url.absoluteString, imageUrl: try doc.media.imageURL(), chapterTitle: chapter.name)
        }
        // Fetch the saved reading position before the remaining batches, while preserving absolute page indices.
        if openingBatch > 1, onOpeningPage != nil {
            let response: BikaPages = try await api.request(path + String(openingBatch))
            try response.pages.validate(page: openingBatch)
            try response.pages.match(first)
            batches[openingBatch] = response.pages
        }
        if let show = onOpeningPage, let batch = batches[openingBatch] {
            try Task.checkCancellation()
            show(try page(index, batch.docs[index % first.limit]), first.total)
        }
        if first.pages > 1 {
            for number in 2...first.pages where batches[number] == nil {
                let response: BikaPages = try await api.request(path + String(number))
                try response.pages.validate(page: number)
                try response.pages.match(first)
                batches[number] = response.pages
            }
        }
        try Task.checkCancellation()
        return try (1...first.pages).flatMap { batches[$0]!.docs }.enumerated().map { try page($0.offset, $0.element) }
    }
}

/// Keep only the two landing pages and directory in memory. A sheet opened during
/// prefetch joins that request. Switching accounts drops both the value and its producer.
@MainActor
final class BikaBrowseResource<Value: Sendable> {
    private let lifetime: Duration
    private var cached: (value: Value, expires: ContinuousClock.Instant)?
    private var loading: Task<Value, Error>?

    init(lifetime: Duration) { self.lifetime = lifetime }

    var hasCachedValue: Bool { freshValue != nil }

    private var freshValue: Value? {
        guard let cached, .now < cached.expires else { return nil }
        return cached.value
    }

    func value(load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let freshValue { return freshValue }
        let task = loading ?? start(load)
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    /// Schedules the producer on this actor, after the current call returns.
    func prefetch(_ load: @escaping @MainActor () async throws -> Value) -> Bool {
        guard freshValue == nil, loading == nil else { return false }
        _ = start(load)
        return true
    }

    private func start(_ load: @escaping @MainActor () async throws -> Value) -> Task<Value, Error> {
        let task = Task {
            defer { if !Task.isCancelled { loading = nil } }
            let value = try await load()
            try Task.checkCancellation()
            cached = (value, .now + lifetime)
            return value
        }
        loading = task
        return task
    }

    func clear() {
        cached = nil
        loading?.cancel()
        loading = nil
    }
}

public enum BikaReadError: LocalizedError {
    case login, unavailable, noWindow
    public var errorDescription: String? {
        switch self {
        case .login: "请登录哔咔账号，或在登录过期后重新登录。"
        case .unavailable: "哔咔暂时未能加载完整内容，请重试。"
        case .noWindow: "请打开 Orihon 后再载入哔咔漫画。"
        }
    }
}
