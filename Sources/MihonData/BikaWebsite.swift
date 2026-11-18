import Foundation
import WebKit
import MihonDomain

/// The website renders its catalogue and reader in JavaScript. Keep authentication and media
/// selection inside its normal WebKit session, and keep canonical web paths in the library.
public struct BikaWebsite: LiveSourceEngine {
    private static let package = "org.orihon.web.bika"
    public static let sourceId = StableHash.positiveId(package)
    static let origin = URL(string: "https://manhuabika.com")!
    public static let accountURL = origin.appendingPathComponent("profile")
    public static let loginURL = origin.appendingPathComponent("account/login")
        .appending(queryItems: [URLQueryItem(name: "returnTo", value: "/profile")])
    static let model = ExtensionModel(name: "哔咔漫画", pkgName: package, versionName: "1", versionCode: 1,
        lang: "zh", isNsfw: true, apkName: "", installState: .installed, sources: [
            ExtensionSourceDescriptor(id: sourceId, name: "哔咔漫画", lang: "zh", baseUrl: origin.absoluteString,
                isNsfw: true, popularPath: "/comics?s=vd", latestPath: "/comics?s=dd",
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

    public func popularManga(page: Int) async throws -> MangasPage { try await list(page, sort: "vd") }
    public func latestUpdates(page: Int) async throws -> MangasPage { try await list(page, sort: "dd") }
    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        try await list(page, sort: query.isEmpty ? "vd" : "dd", query: query)
    }

    private func list(_ page: Int, sort: String, query: String = "") async throws -> MangasPage {
        guard page > 0 else { throw URLError(.badURL) }
        var route = URLComponents(url: Self.origin, resolvingAgainstBaseURL: false)!
        route.path = query.isEmpty ? "/comics" : "/comics/search"
        route.queryItems = [URLQueryItem(name: "s", value: sort), URLQueryItem(name: "page", value: String(page))]
        if !query.isEmpty { route.queryItems?.append(URLQueryItem(name: "q", value: query)) }
        route.percentEncodedQuery = route.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = route.url else { throw URLError(.badURL) }
        struct Listing: Decodable { let items: [Book]; let more: Bool }
        let listing: Listing = try await read(url, document: .catalogue)
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
        let session = try BikaPageSession.acquire(url)
        defer { session.release() }
        let view = session.view
        var deadline = ContinuousClock.now + .seconds(30)
        var lastProgress = 0
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(220))
            guard let current = view.url, current.host == url.host, current.scheme == "https" else { continue }
            let state = try await view.callAsyncJavaScript(document.script,
                arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
            if state?["login"] as? Bool == true { throw BikaReadError.login }
            if state?["failed"] as? Bool == true { throw BikaReadError.unavailable }
            if let result = state?["json"] as? String { return try JSONDecoder().decode(T.self, from: Data(result.utf8)) }
            if let progress = state?["progress"] as? Int, progress > lastProgress {
                lastProgress = progress
                deadline = .now + .seconds(30)
            }
        }
        throw BikaReadError.unavailable
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

    static func acquire(_ url: URL) throws -> BikaPageSession {
        let session: BikaPageSession
        if let existing = active[url] {
            session = existing
        } else {
            session = try BikaPageSession(url)
            active[url] = session
        }
        session.readers += 1
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

    func release() {
        readers -= 1
        guard readers == 0 else { return }
        view.stopLoading()
        view.superview?.removeFromSuperview()
        Self.active.removeValue(forKey: url)
    }
}

enum BikaDocument {
    case catalogue, detail, episodes, reader

    var script: String {
        let body: String = switch self {
        case .catalogue: Self.readCatalogue
        case .detail: Self.readDetail
        case .episodes: Self.readEpisodes
        case .reader: Self.readPages
        }
        return Self.prelude + body
    }

    private static let prelude = #"""
        if (location.origin !== 'https://manhuabika.com') return;
        if (location.pathname === '/account/login' || document.querySelector('input[type=password], [role=alert] a[href^="/account/login"]')) return {login:true};
        const imageURL = img => {
            const src = img?.currentSrc || img?.getAttribute('src');
            if (!src) return null;
            const url = new URL(src, location.href);
            return url.protocol === 'https:' ? url.href : null;
        };
        const done = value => ({json: JSON.stringify(value)});
        """# + "\n"

    private static let readCatalogue = #"""
        const section = document.querySelector('section[aria-labelledby="catalog-heading"]');
        const footer = section?.querySelector('#catalog-pagination');
        if (!section || !footer) return;
        if (section.querySelector('[role=alert]')) return {failed:true};
        const cards = Array.from(section.querySelectorAll('article[data-card-layout]:has(a[href^="/comic/"])'));
        if (!cards.length) {
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
        if (!title) return;
        const status = root.querySelector('[data-completed]')?.dataset.completed;
        const genres = Array.from(root.querySelectorAll('#comic-description a')).map(a=>a.textContent.trim().replace(/^#\s*/, ''));
        return done({path:location.pathname,title,cover:imageURL(root.querySelector('[class*="_cover"] img')),
            author:root.querySelector('a[href^="/comics/author/"]')?.textContent,
            description:root.querySelector('#comic-description p[data-expanded]')?.textContent.trim(),
            genres,completed:status == null ? null : status === 'true'});
        """#

    private static let readEpisodes = #"""
        const root = document.querySelector('#comic-chapters');
        if (!root) return;
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

enum BikaReadError: LocalizedError {
    case login, unavailable, noWindow
    var errorDescription: String? {
        switch self {
        case .login: return "请在哔咔源站登录，完成后返回 Orihon。"
        case .unavailable: return "哔咔未能加载完整内容。请在源站检查登录状态和线路，再返回重试。"
        case .noWindow: return "请打开 Orihon 后再载入哔咔漫画。"
        }
    }
}
