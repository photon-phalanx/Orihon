import Foundation
import MihonDomain

// MARK: - 再漫画 Live Engine (native port of keiyoushi `zh.zaimanhua`)
//
// 再漫画 (the successor of 动漫之家) serves its apps from a public JSON API hosted in mainland China, so it stays
// reachable there without a proxy. Listings → `/comic/rank/list`, `/comic/update/list`, `/search/index`;
// details and chapters → `/comic/detail/{id}`; pages → `/comic/chapter/{id}/{chapterId}`. There is no account
// sign-in on iOS, so chapters that need one (`canRead == false`) are left out.

public struct ZaimanhuaLiveEngine: LiveSourceEngine {
    public static let apiBase = "https://v4api.zaimanhua.com/app/v1"
    /// The source's `baseUrl` in the keiyoushi index (also hosts the PC API used for hidden chapter lists).
    public static let siteBase = "https://manhua.zaimanhua.com"
    static let mobileBase = "https://m.zaimanhua.com"
    private static let apiVersion = URLQueryItem(name: "_v", value: "2.2.5")
    private static let pageSize = 20

    private let usesDmzjURLs: Bool

    public init() { usesDmzjURLs = false }

    init(usesDmzjURLs: Bool) { self.usesDmzjURLs = usesDmzjURLs }

    // The DMZJ APK stores comic URLs in this form. Keep that identity in lists and backups.
    private func storedManga(_ manga: SManga) -> SManga {
        guard usesDmzjURLs else { return manga }
        var result = manga
        result.url = "/comic/comic_\(manga.url).json?version=2.7.019"
        return result
    }

    private func comicId(_ url: String) throws -> String {
        guard usesDmzjURLs else { return url }
        guard let match = url.wholeMatch(of: #/\/comic\/comic_([0-9]+)\.json(?:\?version=[0-9.]+)?/#) else {
            throw URLError(.badURL)
        }
        return String(match.1)
    }

    public static func handles(baseUrl: String) -> Bool {
        baseUrl.contains("zaimanhua.com")
    }

    // MARK: Listings

    public func popularManga(page: Int) async throws -> MangasPage {
        let response: ZMResponse<[ZMListItem]> = try await get(
            "/comic/rank/list",
            [URLQueryItem(name: "tag_id", value: "0"), URLQueryItem(name: "page", value: "\(page)")]
        )
        return mangasPage(response.data ?? [])
    }

    public func latestUpdates(page: Int) async throws -> MangasPage {
        let response: ZMResponse<[ZMListItem]> = try await get("/comic/update/list/0/\(page)", [])
        return mangasPage(response.data ?? [])
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return try await popularManga(page: page) }
        let response: ZMResponse<ZMSearchPage> = try await get("/search/index", [
            URLQueryItem(name: "source", value: "0"),
            URLQueryItem(name: "size", value: "\(Self.pageSize)"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: "\(page)")
        ])
        let result = response.data
        return mangasPage(result?.list ?? [], hasNextPage: page * Self.pageSize < (result?.total ?? 0))
    }

    /// Ranking and update lists have no total; they simply run out (upstream: "没有更多结果了").
    func mangasPage(_ items: [ZMListItem], hasNextPage: Bool? = nil) -> MangasPage {
        MangasPage(mangas: items.compactMap(\.smanga).map(storedManga), hasNextPage: hasNextPage ?? !items.isEmpty)
    }

    // MARK: Details

    public func mangaDetails(manga: SManga) async throws -> SManga {
        let detail = try await comic(id: comicId(manga.url), platform: nil)
        return storedManga(detail.smanga)
    }

    public func mangaWebUrl(manga: SManga) -> String {
        guard let id = try? comicId(manga.url) else { return Self.mobileBase }
        return "\(Self.mobileBase)/pages/comic/detail?id=\(id)"
    }

    // MARK: Chapters

    public func chapterList(manga: SManga) async throws -> [SChapter] {
        let id = try comicId(manga.url)
        var comic = try await comic(id: id, platform: "pc")
        if comic.isHideChapter == 1 && comic.canRead == true {
            // Titles that hide their chapter list from the app API still publish it on the PC API.
            let response: ZMResponse<ZMWrapper<ZMComic>> = try await get(
                url: "\(Self.siteBase)/api/v1/comic2/comic/detail", [URLQueryItem(name: "id", value: id)], platform: "pc"
            )
            comic = try Self.unwrap(response)
        }
        return try comic.chapters()
    }

    private func comic(id: String, platform: String?) async throws -> ZMComic {
        let response: ZMResponse<ZMWrapper<ZMComic>> = try await get("/comic/detail/\(id)", [Self.apiVersion], platform: platform)
        return try Self.unwrap(response)
    }

    // MARK: Pages

    /// Chapter URLs are `{mangaId}/{chapterId}` (upstream format). Image URLs carry a signature that expires; the
    /// image cache keys them without it (`MihonLiveSources.stableImageKey`).
    public func pageList(chapter: SChapter) async throws -> [Page] {
        let response: ZMResponse<ZMWrapper<ZMChapterImages>> = try await get(
            "/comic/chapter/\(chapter.url)", [Self.apiVersion], platform: "h5"
        )
        let images = try Self.unwrap(response)
        guard images.canRead else { throw ZaimanhuaError.accountRequired }
        let urls = images.pageUrlHd.isEmpty ? images.pageUrl : images.pageUrlHd
        return urls.enumerated().map { index, url in
            Page(index: index, url: chapter.url, imageUrl: url, chapterTitle: chapter.name, mangaTitle: nil)
        }
    }

    // MARK: Networking

    private func get<T: Decodable>(_ path: String, _ queryItems: [URLQueryItem], platform: String? = nil) async throws -> T {
        try await get(url: Self.apiBase + path, queryItems, platform: platform)
    }

    private func get<T: Decodable>(url: String, _ queryItems: [URLQueryItem], platform: String? = nil) async throws -> T {
        var components = URLComponents(string: url)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw MihonNetworkError.invalidResponse }
        var headers = ["Accept": "application/json"]
        headers["Platform"] = platform
        let (data, _) = try await MihonNetworkClient.shared.performGET(url: url, headers: headers)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func unwrap<T>(_ response: ZMResponse<ZMWrapper<T>>) throws -> T {
        if let message = response.errmsg, !message.isEmpty { throw ZaimanhuaError.api(message) }
        guard let value = response.data?.data else { throw ZaimanhuaError.api("返回数据为空") }
        return value
    }

    // MARK: Text helpers (1:1 with the extension's `Common.kt`)

    static func status(_ text: String?) -> MangaStatus {
        switch text {
        case "连载中": return .ongoing
        case "已完结": return .completed
        default: return .unknown
        }
    }

    /// `连载12` / `12` / `12.5话` → `第12话`; anything else is kept as published.
    static func chapterName(_ name: String) -> String {
        guard let match = name.wholeMatch(of: #/(?:连载版?)?(\d[.\d]*)([话卷])?/#) else { return name }
        return "第\(match.1)\(match.2.map(String.init) ?? "话")"
    }

    /// List endpoints flatten tags into one string, separated by `/` or `,` (`搞笑/仙侠`, `历史,职场`).
    static func list(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { "/,，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum ZaimanhuaError: Error, LocalizedError, Equatable {
    case accountRequired
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .accountRequired: return "再漫画要求登录后才能阅读这一话"
        case .api(let message): return "再漫画：\(message)"
        }
    }
}

// MARK: - DTOs (field names as the API sends them; see the extension's `ZaimanhuaDto.kt`)

struct ZMResponse<T: Decodable>: Decodable {
    let errno: Int?
    let errmsg: String?
    let data: T?
}

/// Detail and chapter endpoints nest their payload under `data` (app API) or `comicInfo` (PC API).
struct ZMWrapper<T: Decodable>: Decodable {
    let data: T?

    private enum CodingKeys: String, CodingKey { case data, comicInfo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent(T.self, forKey: .data) ?? c.decodeIfPresent(T.self, forKey: .comicInfo)
    }
}

/// An entry of the ranking (`comic_id` only), update (`id` always 0) or search (`comic_id` always 0) lists.
struct ZMListItem: Decodable {
    let id: Int?
    let comicId: Int?
    let title: String?
    let authors: String?
    let status: String?
    let cover: String?
    let types: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, authors, status, cover, types
        case comicId = "comic_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        comicId = try c.decodeIfPresent(Int.self, forKey: .comicId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? c.decodeIfPresent(String.self, forKey: .name)
        authors = try c.decodeIfPresent(String.self, forKey: .authors)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        types = try c.decodeIfPresent(String.self, forKey: .types)
    }

    var smanga: SManga? {
        guard let id = [comicId, id].compactMap({ $0 }).first(where: { $0 != 0 }), let title else { return nil }
        let authors = ZaimanhuaLiveEngine.list(self.authors)
        return SManga(
            url: "\(id)",
            title: title,
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            genre: ZaimanhuaLiveEngine.list(types),
            status: ZaimanhuaLiveEngine.status(status),
            thumbnailUrl: cover,
            initialized: false
        )
    }
}

struct ZMSearchPage: Decodable {
    let list: [ZMListItem]?
    let total: Int?
}

struct ZMTag: Decodable {
    let name: String

    private enum CodingKeys: String, CodingKey { case name = "tag_name" }
}

struct ZMComic: Decodable {
    struct ChapterGroup: Decodable {
        let title: String
        let data: [Chapter]
    }

    struct Chapter: Decodable {
        let id: Int
        let title: String
        let updateTime: Int64?
        let canRead: Bool?
        let isFee: Bool?

        private enum CodingKeys: String, CodingKey {
            case id = "chapter_id"
            case title = "chapter_title"
            case updateTime = "updatetime"
            case canRead
            case isFee = "is_fee"
        }
    }

    let id: Int
    let title: String
    let cover: String?
    let description: String?
    let types: [ZMTag]?
    let status: [ZMTag]?
    let authors: [ZMTag]?
    let lastUpdateChapterId: Int?
    let lastUpdateTime: Int64?
    let chapterGroups: [ChapterGroup]?
    let isHideChapter: Int?
    let canRead: Bool?

    // The app API uses snake_case and `chapters`; the PC API camelCase and `chapterList`.
    private enum CodingKeys: String, CodingKey {
        case id, title, cover, description, types, status, authors, isHideChapter, canRead
        case lastUpdateChapterId = "last_update_chapter_id"
        case lastUpdateChapterIdPC = "lastUpdateChapterId"
        case lastUpdateTime = "last_updatetime"
        case lastUpdateTimePC = "lastUpdateTime"
        case chapters
        case chapterList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        types = try c.decodeIfPresent([ZMTag].self, forKey: .types)
        status = try c.decodeIfPresent([ZMTag].self, forKey: .status)
        authors = try c.decodeIfPresent([ZMTag].self, forKey: .authors)
        isHideChapter = try c.decodeIfPresent(Int.self, forKey: .isHideChapter)
        canRead = try c.decodeIfPresent(Bool.self, forKey: .canRead)
        lastUpdateChapterId = try c.decodeIfPresent(Int.self, forKey: .lastUpdateChapterId)
            ?? c.decodeIfPresent(Int.self, forKey: .lastUpdateChapterIdPC)
        lastUpdateTime = try c.decodeIfPresent(Int64.self, forKey: .lastUpdateTime)
            ?? c.decodeIfPresent(Int64.self, forKey: .lastUpdateTimePC)
        chapterGroups = try c.decodeIfPresent([ChapterGroup].self, forKey: .chapters)
            ?? c.decodeIfPresent([ChapterGroup].self, forKey: .chapterList)
    }

    var smanga: SManga {
        let status = ZaimanhuaLiveEngine.status(status?.first?.name)
        let authors = (authors ?? []).map(\.name)
        return SManga(
            url: "\(id)",
            title: title,
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            description: description,
            genre: (types ?? []).map(\.name),
            status: status,
            thumbnailUrl: cover,
            updateStrategy: status == .completed ? .onlyFetchOnce : .alwaysUpdate,
            initialized: true
        )
    }

    /// Newest first, as the API lists them; the group title ("连载", "单行本", …) becomes the scanlator. Chapters
    /// that need an account or payment are dropped.
    func chapters() throws -> [SChapter] {
        guard canRead != false else { throw ZaimanhuaError.accountRequired }
        guard let chapterGroups, !chapterGroups.isEmpty else {
            throw ZaimanhuaError.api("章节列表为空，用户权限不足或漫画不存在")
        }
        let comicUpdated = lastUpdateTime.flatMap { $0 > 0 ? $0 : nil }
        return chapterGroups.flatMap { group in
            group.data.compactMap { chapter -> SChapter? in
                guard chapter.canRead != false, chapter.isFee != true else { return nil }
                // Some chapters carry the time of the request instead of theirs; no chapter is newer than the
                // comic's last update, so the latest one takes that time and any other is undated (upstream: 0).
                let uploaded: Date
                if let time = chapter.updateTime, comicUpdated.map({ time <= $0 }) ?? true {
                    uploaded = Date(timeIntervalSince1970: TimeInterval(time))
                } else if chapter.id == lastUpdateChapterId, let comicUpdated {
                    uploaded = Date(timeIntervalSince1970: TimeInterval(comicUpdated))
                } else {
                    uploaded = SChapter.undatedUpload
                }
                return SChapter(
                    url: "\(id)/\(chapter.id)",
                    name: ZaimanhuaLiveEngine.chapterName(chapter.title),
                    dateUpload: uploaded,
                    scanlator: group.title
                )
            }
        }
    }
}

struct ZMChapterImages: Decodable {
    let pageUrlHd: [String]
    let pageUrl: [String]
    let canRead: Bool

    private enum CodingKeys: String, CodingKey {
        case pageUrlHd = "page_url_hd"
        case pageUrl = "page_url"
        case canRead
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageUrlHd = try c.decodeIfPresent([String].self, forKey: .pageUrlHd) ?? []
        pageUrl = try c.decodeIfPresent([String].self, forKey: .pageUrl) ?? []
        canRead = try c.decodeIfPresent(Bool.self, forKey: .canRead) ?? true
    }
}
