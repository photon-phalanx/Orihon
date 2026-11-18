import Foundation
import MihonDomain

/// CopyManga's public catalogue API serves anonymous readers a list of groups and paginated chapters per group.
struct CopyWebsite: LiveSourceEngine {
    func mangaWebUrl(manga: SManga) -> String {
        let rule = BundledWebsite.copy.rule
        return rule.siteURL(manga.url)?.absoluteString ?? rule.baseUrl
    }

    func popularManga(page: Int) async throws -> MangasPage { try await Self.list(.popular, page: page) }

    func latestUpdates(page: Int) async throws -> MangasPage { try await Self.list(.latest, page: page) }

    func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        try await Self.list(query.isEmpty ? .popular : .search, page: page, query: query)
    }

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let message: String?
        let results: T?
        enum CodingKeys: CodingKey { case code, message, results }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            code = try fields.decode(Int.self, forKey: .code)
            message = try fields.decodeIfPresent(String.self, forKey: .message)
            results = code == 200 ? try fields.decode(T.self, forKey: .results) : nil
        }
    }

    private struct ListResult<Row: Decodable>: Decodable { let list: [Row]; let total: Int }
    private struct Tag: Decodable { let name: String }
    private struct Status: Decodable { let display: String }
    private struct Comic: Decodable {
        let name: String
        let path_word: String
        let cover: String?
        let author: [Tag]?
        let theme: [Tag]?
        let brief: String?
        let status: Status?

        var manga: SManga {
            let complete = status?.display.contains("完") == true
            return SManga(url: "/comic/" + path_word, title: name, author: author?.map(\.name).joined(separator: "、"),
                          description: brief, genre: theme?.map(\.name) ?? [], status: status == nil ? .unknown : complete ? .completed : .ongoing,
                          thumbnailUrl: cover, initialized: brief != nil)
        }
    }
    private struct Entry: Decodable { let comic: Comic }
    private struct Group: Decodable { let path_word: String; let name: String }
    private struct Book: Decodable { let comic: Comic; let groups: [String: Group]?; let is_lock: Bool? }
    private struct Chapter: Decodable { let name: String; let uuid: String; let datetime_created: String? }
    private struct Reader: Decodable {
        struct ChapterPages: Decodable {
            struct Image: Decodable { let url: String }
            let contents: [Image]?
            let words: [Int]?
        }
        let is_lock: Bool?
        let chapter: ChapterPages?
    }

    private static func request<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.2024manga.com"
        components.path = "/api/v3/" + path
        components.queryItems = query + [URLQueryItem(name: "platform", value: "3")]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await WebsiteHTTP.get(url)
        let result = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard let rows = result.results else {
            throw NSError(domain: "CopyManga", code: result.code, userInfo: [NSLocalizedDescriptionKey: result.message ?? "拷贝漫画接口请求失败"])
        }
        return rows
    }

    private static func pagination(_ limit: Int, _ offset: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
    }

    private static func list(_ listing: SourceListing, page: Int, query: String = "") async throws -> MangasPage {
        let limit = 30, offset = (max(page, 1) - 1) * limit
        let params = pagination(limit, offset)
        if listing == .popular {
            let rows: ListResult<Entry> = try await request("ranks", params + [URLQueryItem(name: "date_type", value: "day")])
            return MangasPage(mangas: rows.list.map(\.comic.manga), hasNextPage: !rows.list.isEmpty && offset + rows.list.count < rows.total)
        }
        let rows: ListResult<Comic> = listing == .search
            ? try await request("search/comic", params + [URLQueryItem(name: "q", value: query)])
            : try await request("comics", params + [URLQueryItem(name: "ordering", value: "-datetime_updated")])
        return MangasPage(mangas: rows.list.map(\.manga), hasNextPage: !rows.list.isEmpty && offset + rows.list.count < rows.total)
    }

    private static func book(_ manga: SManga) async throws -> Book {
        let parts = manga.url.split(separator: "/")
        guard parts.count == 2, parts[0] == "comic" else { throw URLError(.badURL) }
        return try await request("comic2/" + parts[1])
    }

    func mangaDetails(manga: SManga) async throws -> SManga { try await Self.book(manga).comic.manga }

    func chapterList(manga: SManga) async throws -> [SChapter] {
        let book = try await Self.book(manga)
        guard book.is_lock != true, let groups = book.groups else { throw HTMLSourceError.missing("公开章节目录") }
        var items: [SChapter] = []
        var seen = Set<String>()
        for group in groups.values.sorted(by: { $0.path_word < $1.path_word }) {
            var offset = 0
            while true {
                let rows: ListResult<Chapter> = try await Self.request("comic/\(book.comic.path_word)/group/\(group.path_word)/chapters", Self.pagination(100, offset))
                let previousCount = seen.count
                for row in rows.list where seen.insert(row.uuid).inserted {
                    items.append(SChapter(url: manga.url + "/chapter/" + row.uuid, name: row.name,
                                          dateUpload: row.datetime_created.flatMap(DongmanLiveEngine.date) ?? SChapter.undatedUpload,
                                          scanlator: groups.count > 1 ? group.name : nil))
                }
                offset += rows.list.count
                if offset >= rows.total { break }
                // Preserve an existing library if a partial/repeated response arrives mid-refresh.
                if previousCount == seen.count { throw HTMLSourceError.missing("完整章节目录") }
            }
        }
        guard !items.isEmpty else { throw HTMLSourceError.missing("公开章节目录") }
        return items.reversed()
    }

    func pageList(chapter: SChapter) async throws -> [Page] {
        let parts = chapter.url.split(separator: "/")
        guard parts.count == 4, parts[0] == "comic", parts[2] == "chapter" else { throw URLError(.badURL) }
        let reader: Reader = try await Self.request(parts.joined(separator: "/"))
        guard reader.is_lock != true, let data = reader.chapter, let images = data.contents, !images.isEmpty else {
            throw HTMLSourceError.missing("公开书页")
        }
        var indices = Array(images.indices)
        if let order = data.words, order.count == images.count { indices.sort { order[$0] < order[$1] } }
        return try indices.enumerated().map { index, i in
            guard let url = URL(string: images[i].url), url.scheme == "https", url.host != nil else { throw HTMLSourceError.missing("书页地址") }
            return Page(index: index, url: chapter.url, imageUrl: url.absoluteString, chapterTitle: chapter.name)
        }
    }
}
