import Foundation
import MihonDomain

/// Version 1 source files describe links and CSS selectors on one HTTPS website.
struct HTMLSourceRule: Codable, Sendable {
    var version: Int = 1
    var name: String
    var lang: String
    var baseUrl: String
    var popular: String
    var latest: String?
    var search: String?
    var cards: String
    var cardTitle: String?
    var title: String
    var chapters: String
    var chapterTitle: String?
    var oldestFirst: Bool?
    var images: String
    var next: String?
    var nsfw: Bool?

    var id: Int64 { StableHash.positiveId("orihon.html.v1/" + baseUrl) }

    func validated() throws -> Self {
        guard version == 1, !name.isEmpty, name.count <= 100, !lang.isEmpty, lang.count <= 20,
              let base = URLComponents(string: baseUrl), base.scheme == "https",
              base.host?.isEmpty == false, base.user == nil, base.password == nil,
              base.path.isEmpty || base.path == "/", base.query == nil, base.fragment == nil,
              search?.contains("{query}") ?? !popular.contains("{page}"),
              [popular, latest, search].compactMap({ $0 }).allSatisfy({ $0.hasPrefix("/") && !$0.hasPrefix("//") && !$0.contains("\\") })
        else { throw HTMLSourceError.invalidRule }
        for css in [cards, cardTitle, title, chapters, chapterTitle, images, next].compactMap({ $0 }) {
            guard !css.isEmpty, css.utf8.count <= 512, (try? CSSSelectorParser.parse(css)) != nil else {
                throw HTMLSourceError.invalidRule
            }
        }
        var canonical = self
        var origin = base
        origin.host = base.host?.lowercased()
        origin.path = ""
        if origin.port == 443 { origin.port = nil }
        guard let url = origin.string else { throw HTMLSourceError.invalidRule }
        canonical.baseUrl = url
        return canonical
    }

    func siteURL(_ path: String) -> URL? {
        guard let base = URL(string: baseUrl),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host?.lowercased() == base.host?.lowercased(),
              url.port == base.port, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func extensionModel(id sourceId: Int64, package: String) -> ExtensionModel {
        ExtensionModel(name: name, pkgName: package, versionName: "1", versionCode: 1, lang: lang,
                       isNsfw: nsfw ?? false, apkName: "", installState: .installed, sources: [
                        ExtensionSourceDescriptor(id: sourceId, name: name, lang: lang, baseUrl: baseUrl,
                            isNsfw: nsfw ?? false, multiSrcTemplate: "HTML", popularPath: popular, latestPath: latest ?? popular,
                            searchPath: search ?? popular, popularSelector: cards, chapterSelector: chapters, pageSelector: images)
                       ])
    }
}

enum HTMLSourceError: Error, LocalizedError {
    case invalidRule, loginRequired, vomicUnavailable, missing(String)
    var errorDescription: String? {
        switch self {
        case .loginRequired: return "请打开 vomic 源站登录。登录后点「完成」，阅读器会重新载入本章。"
        case .vomicUnavailable: return "vomic 源站暂时无法载入内容，请稍后重试。"
        case .invalidRule: return "图源文件格式无效，请检查版本、HTTPS 站址和选择器。"
        case .missing(let field): return "源站没有返回可用的" + field + "。请打开源站查看访问要求。"
        }
    }
}

struct HTMLRuleEngine: LiveSourceEngine {
    let rule: HTMLSourceRule
    var site: BundledWebsite? = nil

    var supportsLatest: Bool { rule.latest != nil }

    func document(_ path: String) async throws -> HTMLDocument {
        guard let url = rule.siteURL(path) else { throw URLError(.badURL) }
        for attempt in 0...1 {
            let (data, response) = try await WebsiteHTTP.get(url)
            let doc = HTMLDocument(html: String(decoding: data, as: UTF8.self), baseURL: response.url ?? url)
            guard site == .vomic else { return doc }
            // vomic sometimes sends its temporary-error page with HTTP 200, even for a valid search or book.
            let emptyHome = path == "/" && doc.selectFirst(rule.cards) == nil
            if !emptyHome && !doc.root.text.contains("服务器出小差了") { return doc }
            if attempt == 0 { try await Task.sleep(for: .milliseconds(400)) }
        }
        throw HTMLSourceError.vomicUnavailable
    }

    func mangaWebUrl(manga: SManga) -> String { rule.siteURL(manga.url)?.absoluteString ?? rule.baseUrl }

    func listing(_ pattern: String, page: Int, query: String = "") async throws -> MangasPage {
        if page > 1 && !pattern.contains("{page}") { return MangasPage(mangas: [], hasNextPage: false) }
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let path = pattern.replacingOccurrences(of: "{page}", with: String(page)).replacingOccurrences(of: "{query}", with: escaped)
        let doc = try await document(path)
        let mangas = cards(in: doc)
        if page == 1 && mangas.isEmpty && query.isEmpty { throw HTMLSourceError.missing("作品列表") }
        let more = rule.next.map { doc.selectFirst($0) != nil } ?? !mangas.isEmpty
        return MangasPage(mangas: mangas, hasNextPage: pattern.contains("{page}") && more)
    }

    func cards(in doc: HTMLDocument) -> [SManga] {
        var seen = Set<String>()
        return doc.select(rule.cards).compactMap { card in
            guard let link = card.selectFirst("a[href]"), let url = rule.siteURL(link.absUrl("href")) else { return nil }
            var path = DongmanLiveEngine.pathAndQuery(url.absoluteString)
            if site == .manhuaren { path = url.path }
            let title = rule.cardTitle.flatMap { card.selectFirst($0)?.text } ?? link.attr("title")
            let name = title.isEmpty ? link.text : title
            guard !name.isEmpty, !name.contains("{{"), seen.insert(path).inserted else { return nil }
            return SManga(url: path, title: name, thumbnailUrl: imageURL(card.selectFirst("img, amp-img")), initialized: false)
        }
    }

    func popularManga(page: Int) async throws -> MangasPage {
        try await listing(rule.popular, page: page)
    }

    func latestUpdates(page: Int) async throws -> MangasPage {
        guard let latest = rule.latest else { return MangasPage(mangas: [], hasNextPage: false) }
        return try await listing(latest, page: page)
    }

    func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        guard !query.isEmpty else { return try await popularManga(page: page) }
        if let search = rule.search { return try await listing(search, page: page, query: query) }
        guard page == 1 else { return MangasPage(mangas: [], hasNextPage: false) }
        let catalogue = try await popularManga(page: 1)
        return MangasPage(mangas: catalogue.mangas.filter { $0.title.localizedCaseInsensitiveContains(query) }, hasNextPage: false)
    }

    func mangaDetails(manga: SManga) async throws -> SManga {
        let doc = try await document(manga.url)
        guard let element = doc.selectFirst(rule.title) else { throw HTMLSourceError.missing("作品资料") }
        let title = element.ownText.isEmpty ? element.text : element.ownText
        guard !title.isEmpty else { throw HTMLSourceError.missing("作品标题") }
        var result = manga
        result.title = title
        result.thumbnailUrl = imageURL(doc.selectFirst("meta[property='og:image'], meta[name='og:image']")) ?? manga.thumbnailUrl
        result.description = doc.selectFirst(".comics-detail__desc, p.intro, .detail-main-info-content")?.text
            ?? doc.selectFirst("meta[name=description], meta[name=Description]")?.attr("content")
        result.initialized = true
        return result
    }

    func chapterList(manga: SManga) async throws -> [SChapter] {
        let doc = try await document(manga.url)
        if site == .goda { return try await GoDaWebsite.chapters(in: doc, manga: manga) }
        let chapters = chapters(in: doc)
        guard !chapters.isEmpty else { throw HTMLSourceError.missing("章节目录") }
        return chapters
    }

    func chapters(in doc: HTMLDocument) -> [SChapter] {
        var seen = Set<String>()
        var rows = doc.select(rule.chapters)
        let latestOnly = rows.isEmpty && site == .baozi
        if latestOnly { rows = doc.select(".comics-chapters a") }
        var chapters = rows.compactMap { row -> SChapter? in
            guard let link = row.selectFirst("a[href]"), let url = rule.siteURL(link.absUrl("href")) else { return nil }
            let path = DongmanLiveEngine.pathAndQuery(url.absoluteString)
            let name = rule.chapterTitle.flatMap { row.selectFirst($0)?.text } ?? link.text
            guard seen.insert(path).inserted, !name.isEmpty else { return nil }
            return SChapter(url: path, name: name, dateUpload: SChapter.undatedUpload)
        }
        if !latestOnly && rule.oldestFirst == true { chapters.reverse() }
        return chapters
    }

    func pageList(chapter: SChapter) async throws -> [Page] {
        guard let url = rule.siteURL(chapter.url) else { throw URLError(.badURL) }
        if site == .vomic {
            return try await VomicReader.pages(url: url, chapter: chapter)
        }
        if site == .goda { return try await GoDaWebsite.pages(chapter: chapter, url: url) }
        let doc = try await document(chapter.url)
        let urls: [String]
        switch site {
        case .manhuaren: urls = ManhuarenWebsite.pages(in: doc)
        default: urls = doc.select(rule.images).compactMap(imageURL)
        }
        guard !urls.isEmpty else { throw HTMLSourceError.missing("书页") }
        return urls.enumerated().map { Page(index: $0.offset, url: url.absoluteString, imageUrl: $0.element, chapterTitle: chapter.name) }
    }

    private func imageURL(_ node: HTMLElement?) -> String? {
        guard let node else { return nil }
        for attr in ["data-src", "data-original", "src", "content"] {
            guard let url = URL(string: node.absUrl(attr)), url.scheme == "https" || url.scheme == "http", url.host != nil else { continue }
            if site == .baozi, var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let host = c.host, host.hasSuffix(".bzcdn.net") || host.hasSuffix(".baozicdn.com") {
                c.host = String(host.split(separator: ".")[0]) + ".baozimh.com"
                return c.string
            }
            return url.absoluteString
        }
        return nil
    }
}

/// Website sources have their own HTTP session so imported rules never receive private library-server credentials.
enum WebsiteHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, origin: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (compatible; Orihon/1.0)", forHTTPHeaderField: "User-Agent")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else { throw MihonNetworkError.httpStatusError(code: response.statusCode) }
        return (data, response)
    }
}
