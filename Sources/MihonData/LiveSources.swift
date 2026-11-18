import Foundation
import MihonDomain

// MARK: - Live sources

/// The sources with a real implementation on iOS (and the local source, the user's own files). Android extensions
/// cannot run here, so every other source only has generated demo data; the store asks this registry instead of
/// hard-coding one site.
public enum MihonLiveSources {
    public struct Settings: Sendable {
        public var allowNsfw: Bool
        public var mangaDexDataSaver: Bool
        public var komgaAccounts: [Int64: KomgaAccount]

        public init(allowNsfw: Bool = false, mangaDexDataSaver: Bool = false, komgaAccounts: [Int64: KomgaAccount] = [:]) {
            self.allowNsfw = allowNsfw
            self.mangaDexDataSaver = mangaDexDataSaver
            self.komgaAccounts = komgaAccounts
        }
    }

    static let websites = Dictionary(uniqueKeysWithValues: BundledWebsite.allCases.map { ($0.sourceId, $0) })

    /// Komga is recognised by its source ids: its address is the user's.
    public static func handles(_ descriptor: ExtensionSourceDescriptor) -> Bool {
        descriptor.id == BikaWebsite.sourceId || websites[descriptor.id] != nil || descriptor.id == MihonSeedData.dmzjSourceId
            || handles(baseUrl: descriptor.baseUrl) || KomgaLiveEngine.handles(sourceId: descriptor.id)
    }

    public static func handles(baseUrl: String) -> Bool {
        MangaDexLiveEngine.handles(baseUrl: baseUrl)
            || ZaimanhuaLiveEngine.handles(baseUrl: baseUrl)
            || DongmanLiveEngine.handles(baseUrl: baseUrl)
            || MihonLocalSource.handles(baseUrl: baseUrl)
    }

    public static func engine(for descriptor: ExtensionSourceDescriptor, settings: Settings) -> (any LiveSourceEngine)? {
        if descriptor.id == BikaWebsite.sourceId { return BikaWebsite() }
        if let website = websites[descriptor.id] {
            if website == .copy { return CopyWebsite() }
            return HTMLRuleEngine(rule: website.rule, site: website)
        }
        if KomgaLiveEngine.handles(sourceId: descriptor.id) {
            return KomgaLiveEngine(account: settings.komgaAccounts[descriptor.id] ?? KomgaAccount())
        }
        if MangaDexLiveEngine.handles(baseUrl: descriptor.baseUrl) {
            return MangaDexLiveEngine(
                sourceLang: descriptor.lang,
                allowNsfw: settings.allowNsfw,
                dataSaver: settings.mangaDexDataSaver
            )
        }
        let isDmzj = descriptor.id == MihonSeedData.dmzjSourceId
        if isDmzj || ZaimanhuaLiveEngine.handles(baseUrl: descriptor.baseUrl) {
            return ZaimanhuaLiveEngine(usesDmzjURLs: isDmzj)
        }
        if DongmanLiveEngine.handles(baseUrl: descriptor.baseUrl) {
            return DongmanLiveEngine()
        }
        if MihonLocalSource.handles(baseUrl: descriptor.baseUrl) {
            return MihonLocalSource()
        }
        return nil
    }

    /// The key images are cached under. 再漫画 signs its page URLs (`sign`, `t` = expiry) anew on every page-list
    /// request; keyed with the signature, a page read yesterday — or downloaded for offline reading — would miss.
    public static func stableImageKey(_ url: String) -> String {
        guard url.contains("zaimanhua.com"), var components = URLComponents(string: url),
              let items = components.queryItems else { return url }
        let kept = items.filter { $0.name != "sign" && $0.name != "t" }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string ?? url
    }
}
