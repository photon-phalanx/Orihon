import Foundation
import MihonDomain

enum GoDaWebsite {
    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct TitleInfo: Decodable {
        struct Entry: Decodable {
            struct Attributes: Decodable { let slug: String; let title: String; let updatedAt: String? }
            let attributes: Attributes
        }
        let chapters: [Entry]
    }
    private struct Reader: Decodable {
        struct Info: Decodable {
            struct Images: Decodable { let images: String; let line: Int? }
            let images: Images
        }
        let info: Info
    }
    private struct Image: Decodable { let url: String; let order: Int }

    static func chapters(in doc: HTMLDocument, manga: SManga) async throws -> [SChapter] {
        guard let root = doc.selectFirst("#chapterDrawerConfig"), let id = Int(root.attr("data-mid")) else {
            throw HTMLSourceError.missing("章节目录")
        }
        let info: TitleInfo = try await get("/api/v2/manga/get?mid=\(id)&mode=all")
        guard !info.chapters.isEmpty else { throw HTMLSourceError.missing("章节目录") }
        let dates = ISO8601DateFormatter()
        return info.chapters.reversed().map { entry in
            let a = entry.attributes
            return SChapter(url: manga.url + "/" + a.slug, name: a.title,
                            dateUpload: a.updatedAt.flatMap(dates.date(from:)) ?? SChapter.undatedUpload)
        }
    }

    static func pages(chapter: SChapter, url: URL) async throws -> [Page] {
        let (html, _) = try await WebsiteHTTP.get(url)
        let doc = HTMLDocument(html: String(decoding: html, as: UTF8.self))
        guard let el = doc.selectFirst("#chapterContent"), let mid = Int(el.attr("data-ms")),
              let cid = Int(el.attr("data-cs")) else { throw HTMLSourceError.missing("章节编号") }
        let reader: Reader = try await get("/api/v2/chapter/getinfo?m=\(mid)&c=\(cid)")
        let images = try JSONDecoder().decode([Image].self, from: unpack(reader.info.images.images))
        guard !images.isEmpty else { throw HTMLSourceError.missing("书页") }
        let cdn = reader.info.images.line == 2 ? "https://c-nd2-1.6wm.top" : "https://c-nd3-1.6wm.top"
        return try images.sorted { $0.order < $1.order }.enumerated().map { index, item in
            guard item.url.hasPrefix("/"), !item.url.hasPrefix("//") else { throw HTMLSourceError.missing("书页地址") }
            return Page(index: index, url: url.absoluteString, imageUrl: cdn + item.url, chapterTitle: chapter.name)
        }
    }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "https://v2.apikk.top" + path) else { throw URLError(.badURL) }
        let (data, _) = try await WebsiteHTTP.get(url, origin: "https://godamh.com")
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    // The site serializes its public page array in three reordered, base64-encoded chunks.
    static func unpack(_ string: String) throws -> Data {
        let bytes = Array(string.utf8)
        guard bytes.count > 10, bytes.starts(with: "J7r".utf8), bytes.suffix(2).elementsEqual("nQ".utf8) else {
            throw HTMLSourceError.missing("书页数据")
        }
        let n = bytes.count - 10
        let a = n / 3, b = (n - a) / 2, c = n - a - b
        let first = 3 + b, second = first + 2 + c
        guard bytes[first..<first + 2].elementsEqual("kD".utf8), bytes[second..<second + 3].elementsEqual("W4s".utf8) else {
            throw HTMLSourceError.missing("书页数据")
        }
        var payload = Array(bytes[second + 3..<bytes.count - 2]) + bytes[3..<first] + bytes[first + 2..<second]
        for start in stride(from: 7, to: payload.count, by: 14) {
            payload[start..<min(start + 7, payload.count)].reverse()
        }
        let table = Dictionary(uniqueKeysWithValues: zip("_-9876543210abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8,
                                                         "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8))
        var base64 = payload.compactMap { table[$0] }
        guard base64.count == n else { throw HTMLSourceError.missing("书页数据") }
        base64 += Array(repeating: 61, count: (4 - n % 4) % 4)
        guard let data = Data(base64Encoded: Data(base64)) else { throw HTMLSourceError.missing("书页数据") }
        return data
    }
}
