import Foundation
import WebKit
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

/// The website renders its catalogue and reader in JavaScript. Keep authentication and media
/// selection inside its normal WebKit session, and keep canonical web paths in the library.
public struct BikaWebsite: LiveSourceEngine {
    private static let package = "org.orihon.web.bika"
    public static let sourceId = StableHash.positiveId(package)
    static let origin = URL(string: "https://manhuabika.com")!
    private static let directoryURL = origin.appendingPathComponent("categories")
    public static let accountURL = origin.appendingPathComponent("profile")
    public static let loginURL = origin.appendingPathComponent("account/login")
        .appending(queryItems: [URLQueryItem(name: "returnTo", value: "/profile")])
    static let lilyGarden = "百合花園"
    @MainActor private static let gardenPage = BikaBrowseResource<MangasPage>(lifetime: .seconds(60))
    @MainActor private static let latestPage = BikaBrowseResource<MangasPage>(lifetime: .seconds(60))
    @MainActor private static let directory = BikaBrowseResource<BikaFilterOptions>(lifetime: .seconds(600))

    private static let archiveKey = "orihon.bika.landingSession"
    private static let archive = BikaLandingArchive(directory: URL.cachesDirectory.appendingPathComponent("BikaLanding-v1"))
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

    static let model = ExtensionModel(name: "哔咔漫画", pkgName: package, versionName: "1", versionCode: 1,
        lang: "zh", isNsfw: true, apkName: "", installState: .installed, sources: [
            ExtensionSourceDescriptor(id: sourceId, name: "哔咔漫画", lang: "zh", baseUrl: origin.absoluteString,
                isNsfw: true, popularPath: "/comics/category/\(lilyGarden)?s=dd", latestPath: "/comics?s=dd",
                searchPath: "/comics/search?q={query}", popularSelector: "[data-card-layout]",
                chapterSelector: "#comic-chapters a", pageSelector: "figure[data-page] img")
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
        guard page == 1 else { return try await filteredManga(page: page, filter: filter) }
        return try await landingPage(.popular, filter: filter)
    }

    public func latestUpdates(page: Int) async throws -> MangasPage {
        guard page == 1 else { return try await filteredManga(page: page, filter: .init()) }
        return try await landingPage(.latest, filter: .init())
    }

    @MainActor
    private func landingPage(_ listing: SourceListing, filter: BikaCatalogueFilter) async throws -> MangasPage {
        let resource = listing == .popular ? Self.gardenPage : Self.latestPage
        let session = Self.landingSession
        do {
            return try await resource.value {
                let page = try await readListing(Self.catalogueURL(page: 1, filter: filter), warmDirectory: true)
                try Task.checkCancellation()
                if session == Self.landingSession, !Self.editingAccount {
                    await Self.archive.save(page, listing: listing, session: session)
                }
                return page
            }
        } catch {
            // A concurrent directory request can discover the logout and cancel this request.
            if session != Self.landingSession, !Self.editingAccount, !Task.isCancelled { throw BikaReadError.login }
            throw error
        }
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        try await readListing(Self.catalogueURL(page: page, filter: .init(), query: query))
    }

    @MainActor public func filterOptions() async throws -> BikaFilterOptions {
        let session = Self.landingSession
        do {
            return try await Self.directory.value {
                let browser = try BikaPageSession.acquire(Self.directoryURL, share: false)
                defer { browser.release() }
                return try await readDirectory(in: browser.view)
            }
        } catch {
            if session != Self.landingSession, !Self.editingAccount, !Task.isCancelled { throw BikaReadError.login }
            throw error
        }
    }

    @MainActor private func readDirectory(in view: WKWebView) async throws -> BikaFilterOptions {
        let session = Self.landingSession
        let options: BikaFilterOptions = try await read(Self.directoryURL, document: .filterOptions, in: view)
        try Task.checkCancellation()
        if session == Self.landingSession, !Self.editingAccount {
            await Self.archive.saveOptions(options, session: session)
        }
        return options
    }

    public func filteredManga(page: Int, filter: BikaCatalogueFilter) async throws -> MangasPage {
        try await readListing(Self.catalogueURL(page: page, filter: filter))
    }

    static func catalogueURL(page: Int, filter: BikaCatalogueFilter, query: String = "") throws -> URL {
        guard page > 0 else { throw URLError(.badURL) }
        var route = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "s", value: filter.order.rawValue), URLQueryItem(name: "page", value: String(page))]
        switch filter.selection {
        case .categories(let categories):
            route.path = query.isEmpty && categories.isEmpty ? "/comics" : "/comics/search"
            if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
            items += categories.map { URLQueryItem(name: "c", value: $0) }
        case .category(let name):
            route.percentEncodedPath = "/comics/category/" + (try encodedSegment(name))
        case .tag(let name):
            route.percentEncodedPath = "/comics/tag/" + (try encodedSegment(name))
        }
        route.queryItems = items
        route.percentEncodedQuery = route.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = route.url else { throw URLError(.badURL) }
        return url
    }

    private static func encodedSegment(_ name: String) throws -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard !name.isEmpty, name != ".", name != "..",
              let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { throw URLError(.badURL) }
        return encoded
    }

    @MainActor
    private func readListing(_ url: URL, warmDirectory: Bool = false) async throws -> MangasPage {
        struct Listing: Decodable { let items: [Book]; let more: Bool }
        let session = try BikaPageSession.acquire(url, share: false)
        defer { session.release() }
        let listing: Listing = try await read(url, document: .catalogue, in: session.view)
        try Task.checkCancellation()
        if warmDirectory {
            // The catalogue includes the site's own directory link. Follow it in the
            // already initialized reader once the cards have been handed to the app.
            let started = Self.directory.prefetch {
                defer { session.release() }
                try Task.checkCancellation()
                let followed = try await session.view.callAsyncJavaScript("""
                    const link = document.querySelector('a[href="/categories"]:not([target="_blank"])');
                    if (!link) return false;
                    link.click();
                    await new Promise(resolve => setTimeout(resolve, 0));
                    return location.pathname === '/categories';
                    """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
                if followed != true { session.view.load(URLRequest(url: Self.directoryURL)) }
                return try await readDirectory(in: session.view)
            }
            if started { session.retain() }
        }
        return MangasPage(mangas: listing.items.map(\.manga), hasNextPage: listing.more)
    }

    private struct Book: Decodable {
        let path: String
        let title: String
        let cover: String?
        let author: String?
        let description: String?
        let genres: [String]?
        let completed: Bool?

        var manga: SManga {
            SManga(url: path, title: title, author: author, description: description, genre: genres ?? [],
                   status: completed.map { $0 ? .completed : .ongoing } ?? .unknown,
                   thumbnailUrl: cover, initialized: genres != nil)
        }
    }

    public func mangaDetails(manga: SManga) async throws -> SManga {
        guard let url = Self.siteURL(manga.url), url.path.wholeMatch(of: #//comic/[0-9a-fA-F]{24}/#) != nil else { throw URLError(.badURL) }
        let book: Book = try await read(url, document: .detail)
        return book.manga
    }

    public func chapterList(manga: SManga) async throws -> [SChapter] {
        guard let url = Self.siteURL(manga.url), url.path.wholeMatch(of: #//comic/[0-9a-fA-F]{24}/#) != nil else { throw URLError(.badURL) }
        struct Episode: Decodable { let path: String; let title: String; let order: Int; let date: String? }
        let episodes: [Episode] = try await read(url, document: .episodes)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return episodes.sorted { $0.order > $1.order }.map {
            SChapter(url: $0.path, name: $0.title, dateUpload: $0.date.flatMap(dates.date(from:)) ?? SChapter.undatedUpload,
                     chapterNumber: Double($0.order))
        }
    }

    public func pageList(chapter: SChapter) async throws -> [Page] {
        guard let url = Self.siteURL(chapter.url),
              url.path.wholeMatch(of: #//comic/reader/[0-9a-fA-F]{24}/[1-9][0-9]*/#) != nil else { throw URLError(.badURL) }
        let images: [String] = try await read(url.appendingPathComponent("waterfall"), document: .reader)
        return images.enumerated().map { Page(index: $0.offset, url: url.absoluteString, imageUrl: $0.element, chapterTitle: chapter.name) }
    }

    @MainActor
    private func read<T: Decodable>(_ url: URL, document: BikaDocument) async throws -> T {
        let session = try BikaPageSession.acquire(url, share: document == .detail || document == .episodes)
        defer { session.release() }
        return try await read(url, document: document, in: session.view)
    }

    @MainActor
    private func read<T: Decodable>(_ url: URL, document: BikaDocument, in view: WKWebView) async throws -> T {
        let session = Self.landingSession
        func loginRequired() -> BikaReadError {
            if !Task.isCancelled, !Self.editingAccount, session == Self.landingSession { Self.clearBrowseCache() }
            return .login
        }
        var deadline = ContinuousClock.now + .seconds(30)
        var lastProgress = 0
        var authenticated: Bool?
        var retried = false
        var reopened = false
        var loginFormSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(220))
            guard let current = view.url, current.host == url.host, current.scheme == "https" else { continue }
            let state = try await view.callAsyncJavaScript(document.script,
                arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
            let redirected = state?["login"] as? Bool == true
            if redirected || state?["checkAccount"] as? Bool == true {
                if let retry = document.retryScript {
                    // The site can briefly render a guest/error state on a cold navigation.
                    // Give its own retry a chance before opening another WebKit page for the profile.
                    if !retried && !redirected {
                        retried = true
                        if try await view.callAsyncJavaScript(retry, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool == true {
                            try await Task.sleep(for: .milliseconds(450))
                            continue
                        }
                    }
                    if authenticated == nil {
                        authenticated = try await read(Self.accountURL, document: .account)
                        continue
                    }
                    if !reopened && (authenticated == true || Self.gardenPage.hasCachedValue || Self.latestPage.hasCachedValue) {
                        // A signed-in catalogue may recover on a fresh visit even when the
                        // profile just showed a login form. The site still decides access.
                        reopened = true
                        view.load(URLRequest(url: url))
                        deadline = .now + .seconds(30)
                        try await Task.sleep(for: .milliseconds(450))
                        continue
                    }
                    throw authenticated == false || redirected ? loginRequired() : BikaReadError.unavailable
                }
                if redirected { throw loginRequired() }
                if authenticated == nil {
                    authenticated = try await read(Self.accountURL, document: .account)
                    deadline = .now + .seconds(30)
                    continue
                }
                if authenticated == false { throw loginRequired() }
                continue
            }
            if state?["failed"] as? Bool == true { throw BikaReadError.unavailable }
            if document == .account, state?["json"] as? String == "false" {
                let since = loginFormSince ?? .now
                loginFormSince = since
                if since.duration(to: .now) < .seconds(1) { continue }
            } else {
                loginFormSince = nil
            }
            if let result = state?["json"] as? String { return try JSONDecoder().decode(T.self, from: Data(result.utf8)) }
            if let progress = state?["progress"] as? Int, progress > lastProgress {
                lastProgress = progress
                deadline = .now + .seconds(30)
            }
        }
        throw BikaReadError.unavailable
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

/// Detail and episode requests start together when a title opens. Share the live document
/// until its last reader leaves, so one navigation cannot obscure or supersede the other.
@MainActor
private final class BikaPageSession {
    private static var active: [URL: BikaPageSession] = [:]
    private let url: URL
    let view: WKWebView
    private var readers = 0

    static func acquire(_ url: URL, share: Bool) throws -> BikaPageSession {
        let session: BikaPageSession
        if share, let existing = active[url] {
            session = existing
        } else {
            session = try BikaPageSession(url)
            if share { active[url] = session }
        }
        session.retain()
        return session
    }

    private init(_ url: URL) throws {
        self.url = url
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 650))
        // PicaWeb needs animation frames to finish navigation and mount lazy images.
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows).filter { !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController != nil }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { throw BikaReadError.noWindow }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.clipsToBounds = true
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        window.insertSubview(host, at: 0)
        #else
        guard let content = (NSApp?.mainWindow ?? NSApp?.keyWindow ?? NSApp?.windows.first(where: \.isVisible))?.contentView
        else { throw BikaReadError.noWindow }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.clipsToBounds = true
        host.setAccessibilityElement(false)
        content.addSubview(host, positioned: .below, relativeTo: nil)
        #endif
        host.addSubview(view)
        view.load(URLRequest(url: url))
    }

    func retain() { readers += 1 }

    func release() {
        readers -= 1
        guard readers == 0 else { return }
        view.stopLoading()
        view.superview?.removeFromSuperview()
        if Self.active[url] === self { Self.active.removeValue(forKey: url) }
    }
}

enum BikaDocument {
    case account, filterOptions, catalogue, detail, episodes, reader

    var script: String {
        let body: String = switch self {
        case .account: Self.readAccount
        case .filterOptions: Self.readFilterOptions
        case .catalogue: Self.readCatalogue
        case .detail: Self.readDetail
        case .episodes: Self.readEpisodes
        case .reader: Self.readPages
        }
        let loginForm = self == .account ? "" : Self.redirectedToLogin
        return Self.prelude + loginForm + body
    }

    private static let prelude = #"""
        if (location.origin !== 'https://manhuabika.com') return;
        const imageURL = img => {
            const src = img?.currentSrc || img?.getAttribute('src');
            if (!src) return null;
            const url = new URL(src, location.href);
            return url.protocol === 'https:' ? url.href : null;
        };
        const done = value => ({json: JSON.stringify(value)});
        """# + "\n"

    private static let redirectedToLogin = #"""
        if (location.pathname === '/account/login' && document.querySelector('main input[type=password]')) return {login:true};
        """# + "\n"

    private static let readAccount = #"""
        if (location.pathname === '/account/login' && document.querySelector('main input[type=password]')) return done(false);
        if (location.pathname === '/profile' && Array.from(document.querySelectorAll('main button')).some(
            button => /^(退出登录|退出登錄|登出|log out|sign out)$/i.test(button.textContent.trim())
        )) return done(true);
        """#

    private static let readFilterOptions = #"""
        const root = document.querySelector('[data-category-directory]');
        const directory = root?.querySelector('section[aria-labelledby="category-directory-heading"]');
        if (!directory || directory.getAttribute('aria-busy') === 'true') return;
        if (root.querySelector('[role=alert]')) return {checkAccount:true};
        if (root.querySelector('[class*="_keywordsSkeleton_"]')) return;
        const value = link => decodeURIComponent(link.pathname.split('/').pop());
        // These are editorial feeds in the directory, excluded by the site's advanced search.
        const excluded = new Set(['全部','最近更新','大家都在看','大濕推薦','那年今天','官方都在看']);
        const categories = new Map();
        for (const link of directory.querySelectorAll('[data-category-grid] a[href^="/comics/category/"]')) {
            const name = value(link);
            if (name && !excluded.has(name)) categories.set(name, link.getAttribute('aria-label') || name);
        }
        const tags = Array.from(root.querySelectorAll('[data-keyword-list] a[href^="/comics/tag/"]'), value);
        return done({categories:Array.from(categories, ([value,label]) => ({value,label})),tags:[...new Set(tags)]});
        """#

    var retryScript: String? {
        switch self {
        case .catalogue:
            "const button = document.querySelector('section[aria-labelledby=\"catalog-heading\"] > [role=alert] button'); button?.click(); return !!button;"
        case .filterOptions:
            "const buttons = document.querySelectorAll('[data-category-directory] [role=alert] button'); buttons.forEach(button => button.click()); return buttons.length > 0;"
        default:
            nil
        }
    }

    private static let readCatalogue = #"""
        const section = document.querySelector('section[aria-labelledby="catalog-heading"]');
        const footer = section?.querySelector('#catalog-pagination');
        if (!section || !footer) return;
        const cards = Array.from(section.querySelectorAll('article[data-card-layout]:has(a[href^="/comic/"])'));
        if (!cards.length) {
            const error = section.querySelector(':scope > [role=alert]');
            if (error) return {checkAccount:true};
            if (section.querySelector('[role=status] a[href="/comics/search"]')) return done({items:[],more:false});
            return;
        }
        const items = cards.map(card => {
            const link = card.querySelector('a[href^="/comic/"]');
            const title = link?.getAttribute('title')?.split('\n')[0] || link?.textContent.trim();
            return link && title ? {path:link.pathname,title,cover:imageURL(card.querySelector('img'))} : null;
        });
        if (items.some(row => !row)) return {failed:true};
        const pagination = footer.querySelector('[class*="_pagination_"]');
        if (!pagination) return;
        return done({items,more:!!pagination.querySelector('button')});
        """#

    private static let readDetail = #"""
        const root = document.querySelector('[data-comic-detail]');
        const title = root?.querySelector('#comic-detail-title')?.textContent.trim();
        if (!title) return document.querySelector('main [role=alert] a[href^="/account/login"]') ? {checkAccount:true} : undefined;
        const status = root.querySelector('[data-completed]')?.dataset.completed;
        const genres = Array.from(root.querySelectorAll('#comic-description a')).map(a=>a.textContent.trim().replace(/^#\s*/, ''));
        return done({path:location.pathname,title,cover:imageURL(root.querySelector('[class*="_cover"] img')),
            author:root.querySelector('a[href^="/comics/author/"]')?.textContent,
            description:root.querySelector('#comic-description p[data-expanded]')?.textContent.trim(),
            genres,completed:status == null ? null : status === 'true'});
        """#

    private static let readEpisodes = #"""
        const root = document.querySelector('#comic-chapters');
        if (!root || !root.querySelector('a[href^="/comic/reader/"]')) {
            if (document.querySelector('main [role=alert] a[href^="/account/login"]')) return {checkAccount:true};
            if (!root) return;
        }
        if (root.querySelector('[role=alert]')) return {failed:true};
        const links = Array.from(root.querySelectorAll('a[href^="/comic/reader/"]'));
        const more = root.querySelector('[class*="_chapterPagination_"] button');
        if (more) {
            if (!more.disabled && window.orihonChapterCount !== links.length) {
                window.orihonChapterCount = links.length;
                more.click();
            }
            return {progress:links.length};
        }
        if (!links.length) return;
        const loaded = root.querySelector('[class*="_chapterLoaded_"]')?.textContent.match(/([\d,]+)\s*\/\s*([\d,]+)/);
        if (loaded && Number(loaded[2].replaceAll(',', '')) !== links.length) return {progress:links.length};
        const chapters = links.map(a => ({path:a.pathname,order:Number(a.pathname.split('/').pop()),
            title:a.querySelector('strong')?.textContent.trim(),date:a.querySelector('time')?.dateTime}));
        if (chapters.some(e=>!e.title || !(e.order>0)) || new Set(chapters.map(e=>e.order)).size !== chapters.length)
            return {failed:true};
        return done(chapters);
        """#

    private static let readPages = #"""
        if (document.querySelector('main [role=alert] a[href^="/account/login"]')) return {checkAccount:true};
        if (document.querySelector('[data-phase=error],[data-phase=empty]')) return {failed:true};
        const slots = Array.from(document.querySelectorAll('[data-reader-column] figure[data-page]'));
        if (!slots.length) return;
        const images = window.orihonPageImages ??= new Map();
        for (const slot of slots) {
            const src = imageURL(slot.querySelector('img'));
            if (src) images.set(Number(slot.dataset.page), src);
        }
        const missing = slots.find(slot => !images.has(Number(slot.dataset.page)));
        if (missing) {
            missing.scrollIntoView({block:'center', behavior:'instant'});
            return {progress:images.size};
        }
        const count = Number(document.querySelector('[class*="_pageCount_"]')?.textContent.split('/').pop()?.trim().replaceAll(',', ''));
        if (!count || count !== slots.length || slots.some((slot,i) => Number(slot.dataset.page) !== i+1))
            return {progress:images.size};
        return done(Array.from({length:count}, (_,i)=>images.get(i+1)));
        """#
}

public enum BikaReadError: LocalizedError {
    case login, unavailable, noWindow
    public var errorDescription: String? {
        switch self {
        case .login: return "请在哔咔源站登录，完成后返回 Orihon。"
        case .unavailable: return "哔咔暂时未能加载完整内容，请重试或到源站检查线路。"
        case .noWindow: return "请打开 Orihon 后再载入哔咔漫画。"
        }
    }
}
