import Foundation
import WebKit

/// One chapter's first-party API responses. WebKit owns login and pagination requests.
@MainActor
final class BikaReaderPages: NSObject, WKScriptMessageHandler {
    private static let apiHosts = ["api.tipatipa.xyz", "picaapi.part26.art", "picaapi.picacomic.com"]
    private let apiPath: String
    private var batchCount = 0
    private(set) var total = 0
    private var limit = 0
    private var batches: [Int: [String]] = [:]
    private var nextBatch = 1
    private(set) var images: [String] = []
    private var lastAdvance: ContinuousClock.Instant?
    private var invalid = false

    init?(readerURL: URL) {
        guard readerURL.host == BikaWebsite.origin.host, readerURL.scheme == "https",
              let match = readerURL.path.wholeMatch(of: #//comic/reader/([0-9a-fA-F]{24})/([1-9][0-9]*)/waterfall/?/#) else { return nil }
        apiPath = "/comics/\(match.1)/order/\(match.2)/pages"
    }

    static let handler = "orihonBikaPages"

    func install(in controller: WKUserContentController) {
        controller.add(self, name: Self.handler)
        // Observe only the successful page-list response for this chapter. The site's fetch is returned untouched.
        let hosts = Self.apiHosts.map { "'\($0)'" }.joined(separator: ", ")
        let script = #"""
            if (location.origin === 'https://manhuabika.com' && /^\/comic\/reader\/[0-9a-f]{24}\/[1-9]\d*\/waterfall\/?$/i.test(location.pathname)) {
                const fetchPages = window.fetch;
                window.fetch = function(...args) {
                    const request = fetchPages.apply(this, args);
                    request.then(response => {
                        if (!response.ok) return;
                        const url = new URL(response.url);
                        if (url.protocol !== 'https:' || url.port || ![\#(hosts)].includes(url.hostname) ||
                            url.pathname !== '\#(apiPath)') return;
                        const endpoint = url.href;
                        response.clone().text().then(body => {
                            window.webkit.messageHandlers.orihonBikaPages.postMessage({endpoint, body});
                        }).catch(() => {});
                    }).catch(() => {});
                    return request;
                };
            }
            """#
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == BikaWebsite.origin.host,
              let fields = message.body as? [String: String], let endpoint = fields["endpoint"],
              let url = URL(string: endpoint), let body = fields["body"] else { return }
        receive(body: Data(body.utf8), from: url)
    }

    func receive(body: Data, from url: URL) {
        guard !invalid, url.scheme == "https", url.port == nil || url.port == 443,
              let host = url.host, Self.apiHosts.contains(host.lowercased()),
              url.path == apiPath, let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let page = query.first(where: { $0.name == "page" })?.value.flatMap(Int.init) else { return }
        do {
            let batch = try JSONDecoder().decode(Envelope.self, from: body).data.pages
            guard batch.page == page, batch.total > 0, batch.limit > 0,
                  batch.pages == (batch.total - 1) / batch.limit + 1, (1...batch.pages).contains(page),
                  batch.docs.count == min(batch.limit, batch.total - (page - 1) * batch.limit),
                  total == 0 || (total == batch.total && limit == batch.limit) else { throw BikaReadError.unavailable }
            let urls = try batch.docs.map { try $0.media.imageURL() }
            if let existing = batches[page] {
                guard existing == urls else { throw BikaReadError.unavailable }
                return
            }
            total = batch.total
            limit = batch.limit
            batchCount = batch.pages
            batches[page] = urls
            while let next = batches[nextBatch] {
                images.append(contentsOf: next)
                nextBatch += 1
                lastAdvance = .now
            }
        } catch {
            // The already-open reader can still supply its rendered images if the response is unusable.
            invalid = true
        }
    }

    var complete: [String]? {
        !invalid && total > 0 && images.count == total && nextBatch - 1 == batchCount ? images : nil
    }

    /// A scroll to the last known page tells the site's normal reader to load its next API batch.
    /// Return nil while the document is starting, or if it needs the usual login/error/recovery checks.
    func poll(in view: WKWebView) async throws -> (value: [String]?, progress: Int)? {
        guard !invalid else { return nil }
        if let complete { return (complete, complete.count) }
        guard let lastAdvance, lastAdvance.duration(to: .now) < .seconds(4) else { return nil }
        _ = try await view.callAsyncJavaScript(#"""
            const slot = document.querySelector('[data-reader-column] figure[data-page="' + last + '"]');
            if (slot) slot.scrollIntoView({block:'center', behavior:'instant'});
            """#, arguments: ["last": images.count], in: nil, contentWorld: .defaultClient)
        return (nil, images.count)
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable { let pages: Batch }
        let data: Payload
    }

    private struct Batch: Decodable {
        struct Document: Decodable { let media: Media }
        let docs: [Document]
        let page: Int
        let pages: Int
        let total: Int
        let limit: Int

        enum CodingKeys: CodingKey { case docs, page, pages, total, limit }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) throws -> Int {
                if let n = try? fields.decode(Int.self, forKey: key) { return n }
                guard let n = Int(try fields.decode(String.self, forKey: key)) else { throw BikaReadError.unavailable }
                return n
            }
            docs = try fields.decode([Document].self, forKey: .docs)
            page = try number(.page)
            pages = try number(.pages)
            total = try number(.total)
            limit = try number(.limit)
        }
    }

    private struct Media: Decodable {
        let fileServer: String
        let path: String

        func imageURL() throws -> String {
            guard let base = URL(string: fileServer), base.scheme == "https", base.host != nil,
                  base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
                  !path.isEmpty, !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw BikaReadError.unavailable }
            return base.appendingPathComponent("static").appendingPathComponent(path).absoluteString
        }
    }
}
