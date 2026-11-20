import Foundation
import MihonDomain

struct BikaBatch<Document: Decodable & Sendable>: Decodable, Sendable {
    let docs: [Document]
    let page: Int
    let pages: Int
    let total: Int
    let limit: Int

    enum CodingKeys: CodingKey { case docs, page, pages, total, limit }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) throws -> Int {
            if let value = try? fields.decode(Int.self, forKey: key) { return value }
            guard let value = Int(try fields.decode(String.self, forKey: key)) else { throw BikaReadError.unavailable }
            return value
        }
        docs = try fields.decode([Document].self, forKey: .docs)
        page = try number(.page); pages = try number(.pages); total = try number(.total); limit = try number(.limit)
    }

    func validate(page requested: Int) throws {
        guard page == requested, page > 0, total >= 0, limit > 0, pages >= 0,
              pages == (total == 0 ? 0 : (total - 1) / limit + 1) || (total == 0 && pages == 1),
              page <= max(1, pages), docs.count == min(limit, max(0, total - (page - 1) * limit)) else {
            throw BikaReadError.unavailable
        }
    }

    func match(_ first: Self) throws {
        guard total == first.total, limit == first.limit, pages == first.pages else { throw BikaReadError.unavailable }
    }
}

struct BikaMedia: Decodable, Sendable {
    let fileServer: String
    let path: String
    func imageURL() throws -> String {
        guard let base = URL(string: fileServer), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw BikaReadError.unavailable }
        let root = base.path.hasSuffix("/static") || base.path.hasSuffix("/static/") ? base : base.appendingPathComponent("static")
        return root.appendingPathComponent(path).absoluteString
    }
}
struct BikaComic: Decodable, Sendable {
    let _id: String
    let title: String
    let author: String?
    let description: String?
    let categories: [String]?
    let tags: [String]?
    let finished: Bool?
    let thumb: BikaMedia?

    func manga(initialized: Bool) throws -> SManga {
        guard _id.wholeMatch(of: #/[0-9a-fA-F]{24}/#) != nil else { throw BikaReadError.unavailable }
        var seen = Set<String>()
        return SManga(url: "/comic/" + _id, title: title, author: author, description: description,
                      genre: ((categories ?? []) + (tags ?? [])).filter { seen.insert($0).inserted },
                      status: finished.map { $0 ? .completed : .ongoing } ?? .unknown,
                      thumbnailUrl: try thumb?.imageURL(), initialized: initialized)
    }
}
struct BikaComics: Decodable, Sendable { let comics: BikaBatch<BikaComic> }
struct BikaComicDetail: Decodable, Sendable { let comic: BikaComic }
struct BikaEpisode: Decodable, Sendable { let title: String; let order: Int; let updated_at: String? }
struct BikaEpisodes: Decodable, Sendable { let eps: BikaBatch<BikaEpisode> }
struct BikaPageDocument: Decodable, Sendable { let media: BikaMedia }
struct BikaPages: Decodable, Sendable { let pages: BikaBatch<BikaPageDocument> }
struct BikaCategories: Decodable, Sendable {
    struct Category: Decodable, Sendable { let _id: String?; let title: String; let isWeb: Bool?; let active: Bool? }
    let categories: [Category]
}
struct BikaKeywords: Decodable, Sendable { let keywords: [String] }
