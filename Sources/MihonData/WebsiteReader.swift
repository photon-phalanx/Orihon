import Foundation
import WebKit
import MihonDomain

/// vomic's website uses its own login session and renders the chapter into #myscroll.
@MainActor
enum VomicReader {
    static func pages(url: URL, chapter: SChapter) async throws -> [Page] {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        view.load(URLRequest(url: url))
        defer { view.stopLoading() }
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            guard view.url?.host == url.host else { continue }
            let script = """
                if (document.querySelector('.loginbox')) return { login: true };
                return { urls: Array.from(document.querySelectorAll('#myscroll img.myimage'), img => img.src) };
                """
            guard let state = try? await view.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                                  contentWorld: .defaultClient) as? [String: Any] else { continue }
            if state["login"] as? Bool == true { throw HTMLSourceError.loginRequired }
            guard let images = state["urls"] as? [String], !images.isEmpty else { continue }
            return try images.enumerated().map { index, image in
                guard let remote = URL(string: image), remote.scheme == "https", remote.host != nil else {
                    throw HTMLSourceError.missing("书页地址")
                }
                return Page(index: index, url: url.absoluteString, imageUrl: image, chapterTitle: chapter.name)
            }
        }
        throw HTMLSourceError.missing("书页")
    }
}

enum ManhuarenWebsite {
    static func imageReferer(_ url: URL) -> String? {
        guard let host = url.host, host.hasSuffix(".cdndm5.com"),
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cid" })?.value,
              let cid = Int(id), cid > 0 else { return nil }
        return "https://m.dm5.com/m\(cid)/"
    }

    // The mobile webpage declares its image array inside a packed script. Expand only string tokens,
    // without executing the script. The order in newImgs is the site's reading order.
    static func pages(in doc: HTMLDocument) -> [String] {
        for script in doc.select("script") {
            let source = script.data
            guard source.contains("newImgs"), let packed = source.firstMatch(of: #/\}\('([^\n]*)',(\d+),\d+,'([^']*)'\.split\('\|'\)/#),
                  let radix = Int(packed.2), (2...62).contains(radix) else { continue }
            let names = packed.3.split(separator: "|", omittingEmptySubsequences: false)
            let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let expanded = String(packed.1).replacing(#/[0-9A-Za-z]+/#) { match -> String in
                var index = 0
                for character in match.output {
                    guard let digit = digits.firstIndex(of: character), digit < radix, index <= names.count else { return String(match.output) }
                    index = index * radix + digit
                }
                return index < names.count && !names[index].isEmpty ? String(names[index]) : String(match.output)
            }
            guard let array = expanded.firstMatch(of: #/newImgs\s*=\s*\[([^\]]+)\]/#) else { continue }
            return array.1.matches(of: #/https?://[^'\\\s"]+/#).map { String($0.output) }
        }
        return []
    }
}
