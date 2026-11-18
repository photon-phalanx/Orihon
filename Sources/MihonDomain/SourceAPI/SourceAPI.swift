import Foundation

// MARK: - Mihon Source API Models (1:1 with eu.kanade.tachiyomi.source.model.*)

public struct SManga: Codable, Hashable, Sendable {
    public var url: String
    public var title: String
    public var artist: String?
    public var author: String?
    public var description: String?
    public var genre: [String]
    public var status: MangaStatus
    public var thumbnailUrl: String?
    public var updateStrategy: UpdateStrategy
    public var initialized: Bool

    public init(
        url: String,
        title: String,
        artist: String? = nil,
        author: String? = nil,
        description: String? = nil,
        genre: [String] = [],
        status: MangaStatus = .unknown,
        thumbnailUrl: String? = nil,
        updateStrategy: UpdateStrategy = .alwaysUpdate,
        initialized: Bool = true
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.author = author
        self.description = description
        self.genre = genre
        self.status = status
        self.thumbnailUrl = thumbnailUrl
        self.updateStrategy = updateStrategy
        self.initialized = initialized
    }
}

public struct SChapter: Codable, Hashable, Sendable {
    /// Upstream's `date_upload = 0`: the source gives no (believable) date.
    public static let undatedUpload = Date(timeIntervalSince1970: 0)

    public var url: String
    public var name: String
    public var dateUpload: Date
    public var chapterNumber: Double
    public var scanlator: String?

    public init(
        url: String,
        name: String,
        dateUpload: Date = Date(),
        chapterNumber: Double = -1,
        scanlator: String? = nil
    ) {
        self.url = url
        self.name = name
        self.dateUpload = dateUpload
        self.chapterNumber = chapterNumber
        self.scanlator = scanlator
    }
}

public struct Page: Identifiable, Codable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var url: String
    public var imageUrl: String?
    public var chapterTitle: String?
    public var mangaTitle: String?

    public init(
        index: Int,
        url: String = "",
        imageUrl: String? = nil,
        chapterTitle: String? = nil,
        mangaTitle: String? = nil
    ) {
        self.index = index
        self.url = url
        self.imageUrl = imageUrl
        self.chapterTitle = chapterTitle
        self.mangaTitle = mangaTitle
    }

    /// Image URLs of the local source (`MihonLocalSource`): files the app reads from disk.
    public static let localImagePrefix = "mihon-local:/"

    /// True when the page points at a real image — remote, or a local file — as opposed to the offline demo renderer.
    public var hasRealImage: Bool {
        guard let imageUrl else { return false }
        return imageUrl.hasPrefix("https://") || imageUrl.hasPrefix("http://") || imageUrl.hasPrefix(Self.localImagePrefix)
    }
}

// MARK: - Stable hashing (Swift's `hashValue` is randomized per launch and must never be persisted)

public enum StableHash {
    /// 64-bit FNV-1a over UTF-8 bytes; deterministic across launches and platforms.
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Positive identifier suitable for `Source.id` / `Manga.id` style keys.
    public static func positiveId(_ string: String) -> Int64 {
        Int64(bitPattern: fnv1a64(string) & 0x7FFF_FFFF_FFFF_FFFF)
    }
}

public struct MangasPage: Codable, Hashable, Sendable {
    public var mangas: [SManga]
    public var hasNextPage: Bool

    public init(mangas: [SManga], hasNextPage: Bool) {
        self.mangas = mangas
        self.hasNextPage = hasNextPage
    }
}

// MARK: - Source Filter System (1:1 with eu.kanade.tachiyomi.source.model.Filter)

public enum SourceFilter: Identifiable, Hashable, Sendable {
    case header(name: String)
    case separator
    case text(name: String, value: String)
    case checkBox(name: String, state: Bool)
    case triState(name: String, state: TriStateFilter)
    case select(name: String, options: [String], selectedIndex: Int)
    case sort(name: String, options: [String], selectedIndex: Int, ascending: Bool)

    public var id: String {
        switch self {
        case .header(let name): return "header_\(name)"
        case .separator: return "separator"
        case .text(let name, _): return "text_\(name)"
        case .checkBox(let name, _): return "checkbox_\(name)"
        case .triState(let name, _): return "tristate_\(name)"
        case .select(let name, _, _): return "select_\(name)"
        case .sort(let name, _, _, _): return "sort_\(name)"
        }
    }
}

// MARK: - Source Protocols (1:1 with Source / CatalogueSource / HttpSource / ParsedHttpSource)

public protocol Source: Sendable {
    var id: Int64 { get }
    var name: String { get }
    var lang: String { get }
    var isLocal: Bool { get }
    func getMangaDetails(manga: SManga) async throws -> SManga
    func getChapterList(manga: SManga) async throws -> [SChapter]
    func getPageList(chapter: SChapter) async throws -> [Page]
}

public protocol CatalogueSource: Source {
    var supportsLatest: Bool { get }
    var isNsfw: Bool { get }
    var baseUrl: String { get }
    func getPopularManga(page: Int) async throws -> MangasPage
    func getLatestUpdates(page: Int) async throws -> MangasPage
    func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage
    func getFilterList() -> [SourceFilter]
}

public protocol HttpSource: CatalogueSource {
    var versionId: Int { get }
    var headers: [String: String] { get }
    func getMangaUrl(manga: SManga) -> String
    func getChapterUrl(chapter: SChapter) -> String
}

public protocol ParsedHttpSource: HttpSource {
    func popularMangaSelector() -> String
    func latestUpdatesSelector() -> String
    func searchMangaSelector() -> String
    func chapterListSelector() -> String
    func pageListSelector() -> String
}

/// 1:1 with upstream `Listing` used by `BrowseSourceScreen`.
public enum SourceListing: String, Hashable, Codable, Sendable {
    case popular
    case latest
    case search
}

/// A natively implemented network backend that a synthesized APK source can delegate to.
///
/// Kotlin extension bytecode cannot run on iOS, so extensions whose upstream implementation talks to a
/// documented JSON API (e.g. MangaDex) are backed by a Swift engine that issues the same requests.
public protocol LiveSourceEngine: Sendable {
    var supportsLatest: Bool { get }
    func popularManga(page: Int) async throws -> MangasPage
    func latestUpdates(page: Int) async throws -> MangasPage
    func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage
    func mangaDetails(manga: SManga) async throws -> SManga
    func chapterList(manga: SManga) async throws -> [SChapter]
    func pageList(chapter: SChapter) async throws -> [Page]
    func mangaWebUrl(manga: SManga) -> String
    /// Reading mode for this source's titles until the reader picks one (webtoon sites read vertically).
    var preferredReadingMode: ReadingMode? { get }
}

extension LiveSourceEngine {
    public var supportsLatest: Bool { true }
    public var preferredReadingMode: ReadingMode? { nil }
}
