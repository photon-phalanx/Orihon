import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import MihonDomain

// MARK: - 1. Per-Host Sliding-Window Rate Limiter (1:1 with Mihon RateLimitInterceptor)

public actor MihonRateLimitInterceptor {
    public struct HostBucket {
        public var permits: Int
        public var periodSeconds: TimeInterval
        public var requestTimestamps: [Date] = []
    }

    private var bucketsByHost: [String: HostBucket] = [:]
    private let defaultPermits: Int
    private let defaultPeriod: TimeInterval

    public init(defaultPermits: Int = 5, defaultPeriod: TimeInterval = 1.0) {
        self.defaultPermits = defaultPermits
        self.defaultPeriod = defaultPeriod
    }

    public func configureRateLimit(forHost host: String, permits: Int, periodSeconds: TimeInterval) {
        bucketsByHost[host] = HostBucket(permits: max(1, permits), periodSeconds: max(0.1, periodSeconds))
    }

    public func acquirePermit(for url: URL) async {
        let host = url.host ?? "default"
        var bucket = bucketsByHost[host] ?? HostBucket(permits: defaultPermits, periodSeconds: defaultPeriod)
        let now = Date()
        bucket.requestTimestamps.removeAll { now.timeIntervalSince($0) >= bucket.periodSeconds }

        // Reserve the slot *before* suspending so re-entrant callers observe it (actor reentrancy safe).
        var slot = now
        if bucket.requestTimestamps.count >= bucket.permits {
            let oldest = bucket.requestTimestamps[bucket.requestTimestamps.count - bucket.permits]
            slot = oldest.addingTimeInterval(bucket.periodSeconds)
        }
        bucket.requestTimestamps.append(slot)
        bucketsByHost[host] = bucket

        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}

// MARK: - 2. Network Client with Cloudflare Detection & Extension Store Fetchers

public enum MihonNetworkError: Error, LocalizedError {
    case cloudflareChallengeDetected(domain: String)
    case httpStatusError(code: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .cloudflareChallengeDetected(let domain):
            return "站点 \(domain) 触发了 Cloudflare 验证，请在 WebView 中完成验证"
        case .httpStatusError(let code):
            return "HTTP 错误 \(code)"
        case .invalidResponse:
            return "服务器返回了无效的响应"
        }
    }
}

public actor MihonNetworkClient {
    public static let shared = MihonNetworkClient()

    private let rateLimiter = MihonRateLimitInterceptor(defaultPermits: 5, defaultPeriod: 1.0)
    /// URLSession is thread-safe; it is `nonisolated` so image transfers never queue behind the actor.
    nonisolated let session: URLSession
    public nonisolated let defaultUserAgent: String = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Orihon/1.0"

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 48 * 1024 * 1024)
        self.session = URLSession(configuration: config)
    }

    /// Rate-limited request path used for source APIs (1:1 with extension `RateLimitInterceptor`).
    public func performGET(url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        await rateLimiter.acquirePermit(for: url)
        return try await Self.transfer(session: session, url: url, headers: headers, userAgent: defaultUserAgent)
    }

    /// A write to a source's API (Komga's read progress): rate-limited like `performGET`.
    public func send(url: URL, method: String, body: Data?, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        await rateLimiter.acquirePermit(for: url)
        return try await Self.transfer(session: session, url: url, headers: headers, userAgent: defaultUserAgent, method: method, body: body)
    }

    /// Unthrottled request path for CDN assets (covers, extension icons, chapter pages). Asks for an image, as
    /// upstream's image requests do: Komga answers `*/*` for a PDF book's page with the PDF itself.
    public nonisolated func fetchAsset(url: URL, headers: [String: String] = [:]) async throws -> Data {
        var imageHeaders = headers
        if headers.keys.allSatisfy({ $0.caseInsensitiveCompare("Accept") != .orderedSame }) {
            imageHeaders["Accept"] = "image/*,*/*;q=0.8"
        }
        // DM5's CDN checks the specific referring chapter for both online viewing and offline downloads.
        if let referer = ManhuarenWebsite.imageReferer(url) { imageHeaders["Referer"] = referer }
        return try await Self.transfer(session: session, url: url, headers: imageHeaders, userAgent: defaultUserAgent).0
    }

    private static func transfer(
        session: URLSession,
        url: URL,
        headers: [String: String],
        userAgent: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(Self.userAgent(for: url, fallback: userAgent), forHTTPHeaderField: "User-Agent")
        // The login of the user's own server (Komga), unless the caller gave headers of its own.
        for (k, v) in MihonServerAuth.headers(for: url).merging(headers, uniquingKeysWith: { _, given in given }) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: request, delegate: MihonRedirectGuard())
        guard let http = response as? HTTPURLResponse else {
            throw MihonNetworkError.invalidResponse
        }

        // 1:1 Cloudflare Challenge Detection (Mihon CloudflareInterceptor)
        if http.statusCode == 403 || http.statusCode == 503 {
            let serverHeader = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased()
            let cfMitigated = http.value(forHTTPHeaderField: "cf-mitigated") ?? ""
            if serverHeader.contains("cloudflare") || !cfMitigated.isEmpty {
                throw MihonNetworkError.cloudflareChallengeDetected(domain: url.host ?? "")
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MihonNetworkError.httpStatusError(code: http.statusCode)
        }
        return (data, http)
    }

    /// MangaDex@Home image nodes answer 404 to browser user agents (anti-hotlinking), so MangaDex traffic
    /// identifies itself as an API client — the same thing the upstream extension does.
    static func userAgent(for url: URL, fallback: String) -> String {
        let host = url.host ?? ""
        if host.hasSuffix("mangadex.network") || host.hasSuffix("mangadex.org") {
            return "Orihon/1.0 (MangaDex)"
        }
        return fallback
    }

    /// Legacy `index.min.json` entry (repos that have not migrated to `index.pb`).
    public struct KeiyoushiRepoEntry: Codable, Sendable {
        public var name: String
        public var pkg: String
        public var apk: String
        public var lang: String
        public var code: Int
        public var version: String
        public var nsfw: Int
        public var sources: [KeiyoushiSourceItem]?
    }

    public struct KeiyoushiSourceItem: Codable, Sendable {
        public var name: String
        public var lang: String
        public var id: String
        public var baseUrl: String
    }

    private struct LegacyRepoMeta: Decodable {
        var indexV2: String?
        enum CodingKeys: String, CodingKey { case indexV2 = "index_v2" }
    }

    /// `repo.json` → `meta` (upstream `ExtensionRepoMetaDto`).
    public struct ExtensionRepoMeta: Decodable, Sendable {
        public var name: String
        public var shortName: String?
        public var website: String
        public var signingKeyFingerprint: String
    }

    private struct RepoJSON: Decodable {
        var meta: ExtensionRepoMeta
    }

    public func fetchExtensionRepoMeta(repoBaseUrl: String) async throws -> ExtensionRepoMeta {
        guard let url = URL(string: "\(Self.cleanRepoBaseUrl(repoBaseUrl))/repo.json") else {
            throw MihonNetworkError.invalidResponse
        }
        let (data, _) = try await performGET(url: url)
        return try JSONDecoder().decode(RepoJSON.self, from: data).meta
    }

    /// 1:1 port of upstream `ExtensionStoreService.fetch`: `repo.json` → `index_v2` (gzip protobuf) with
    /// a fallback to the legacy `index.min.json` list.
    public func fetchExtensionRepoIndex(repoBaseUrl: String) async throws -> [ExtensionModel] {
        let cleanBaseUrl = Self.cleanRepoBaseUrl(repoBaseUrl)

        if let repoJsonUrl = URL(string: "\(cleanBaseUrl)/repo.json"),
           let (repoData, _) = try? await performGET(url: repoJsonUrl),
           let meta = try? JSONDecoder().decode(LegacyRepoMeta.self, from: repoData),
           let indexV2 = meta.indexV2,
           let indexV2Url = URL(string: indexV2) {
            let (payload, _) = try await performGET(url: indexV2Url)
            var store = try KeiyoushiExtensionStoreDecoder.decode(payload)
            if store.extensions.isEmpty,
               let listUrlString = store.extensionListUrl,
               let listUrl = URL(string: listUrlString) {
                let (listPayload, _) = try await performGET(url: listUrl)
                store.extensions = try KeiyoushiExtensionStoreDecoder.decodeExtensionList(listPayload)
            }
            if !store.extensions.isEmpty {
                return store.extensions.map { $0.toExtensionModel(repoUrl: cleanBaseUrl, storeName: store.name) }
            }
        }

        guard let url = URL(string: "\(cleanBaseUrl)/index.min.json") else {
            throw MihonNetworkError.invalidResponse
        }
        let (data, _) = try await performGET(url: url)
        let entries = try JSONDecoder().decode([KeiyoushiRepoEntry].self, from: data)

        return entries.map { entry in
            let cleanName = entry.name
                .replacingOccurrences(of: "Tachiyomi: ", with: "")
                .replacingOccurrences(of: "Mihon: ", with: "")
            let descriptors: [ExtensionSourceDescriptor] = (entry.sources ?? []).enumerated().map { idx, s in
                ExtensionSourceDescriptor(
                    id: Int64(s.id) ?? StableHash.positiveId("\(entry.pkg):\(s.name):\(s.lang)"),
                    name: s.name,
                    lang: s.lang,
                    baseUrl: s.baseUrl,
                    isNsfw: entry.nsfw == 1,
                    className: "\(entry.pkg).Source\(idx + 1)",
                    multiSrcTemplate: Self.inferMultiSrcTemplate(pkg: entry.pkg, sourceName: s.name, baseUrl: s.baseUrl)
                )
            }
            return ExtensionModel(
                name: cleanName,
                pkgName: entry.pkg,
                versionName: entry.version,
                versionCode: entry.code,
                libVersion: Double(entry.version.split(separator: ".").prefix(2).joined(separator: ".")) ?? 1.4,
                lang: entry.lang,
                isNsfw: entry.nsfw == 1,
                apkName: entry.apk,
                apkUrl: "\(cleanBaseUrl)/apk/\(entry.apk)",
                iconUrl: "\(cleanBaseUrl)/icon/\(entry.pkg).png",
                repoUrl: cleanBaseUrl,
                installState: .available,
                sources: descriptors
            )
        }
    }

    /// Where a downloaded APK is cached; nil for a name that is not a plain file name (the name comes from the
    /// repo index, so `../…` must not reach outside the cache).
    public static func cachedExtensionApkURL(apkName: String) -> URL? {
        guard !apkName.isEmpty, apkName != ".", apkName != "..", !apkName.contains("/"), !apkName.contains("\\") else {
            return nil
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let extDir = appSupport.appendingPathComponent("Mihon-iOS/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        return extDir.appendingPathComponent(apkName)
    }

    /// Drops a cached APK (one whose signature was refused), so the next install downloads it again.
    public static func discardCachedExtensionApk(apkName: String) {
        guard let url = cachedExtensionApkURL(apkName: apkName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Downloads the real `.apk` binary and caches it on disk.
    public func downloadExtensionApk(repoBaseUrl: String, apkName: String, apkUrl: String? = nil) async throws -> (Data, URL) {
        guard let localFileUrl = Self.cachedExtensionApkURL(apkName: apkName) else {
            throw MihonNetworkError.invalidResponse
        }

        if let cached = try? Data(contentsOf: localFileUrl), cached.count > 64 {
            return (cached, localFileUrl)
        }

        let resolved = apkUrl ?? "\(Self.cleanRepoBaseUrl(repoBaseUrl))/apk/\(apkName)"
        guard let url = URL(string: resolved) else {
            throw MihonNetworkError.invalidResponse
        }

        let (data, _) = try await performGET(url: url)
        try? data.write(to: localFileUrl, options: .atomic)
        return (data, localFileUrl)
    }

    static func cleanRepoBaseUrl(_ repoBaseUrl: String) -> String {
        var base = repoBaseUrl
        for suffix in ["/index.min.json", "/repo.json", "/index.pb"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func inferMultiSrcTemplate(pkg: String, sourceName: String, baseUrl: String) -> String {
        let token = "\(pkg) \(sourceName) \(baseUrl)".lowercased()
        if token.contains("madara") || token.contains("asura") || token.contains("reaper") || token.contains("leviatan") {
            return "Madara"
        } else if token.contains("themesia") || token.contains("flame") || token.contains("luminous") || token.contains("rawkuma") {
            return "MangaThemesia"
        } else if token.contains("mangabox") || token.contains("manganato") || token.contains("mangakakalot") {
            return "MangaBox"
        } else if token.contains("gigaviewer") || token.contains("jumpplus") || token.contains("tonarinoyj") || token.contains("comicdays") {
            return "GigaViewer"
        } else if token.contains("sinmh") || token.contains("colamanga") || token.contains("gufeng") {
            return "SinMH"
        } else if token.contains("mangadex") || token.contains("komga") || token.contains("suwayomi") || token.contains("bilibili") || token.contains("kuaikan") || token.contains("copymanga") {
            return "HttpSource (JSON API)"
        }
        return "ParsedHttpSource"
    }
}

// MARK: - 3. Image Decoder, Subsampler, Pixel-Level Border Cropper & Tall Webtoon Splitter (1:1 with Mihon libimage-decoder)

public enum MihonImageProcessor {
    /// Subsampled off-main-thread decoding via `CGImageSource` so 4K/8K manga pages never spike RAM
    public static func decodeSubsampledCGImage(from data: Data, maxDimensionPixels: Int = 2560) -> CGImage? {
        decodeForDisplay(from: data, maxPixelSize: maxDimensionPixels, preserveTallStrips: false)
    }

    /// Decodes straight into a display-ready bitmap. Never upscales, and for long webtoon strips limits the
    /// *width* instead of the longest edge so text stays legible.
    public static func decodeForDisplay(from data: Data, maxPixelSize: Int, preserveTallStrips: Bool) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        var targetMaxDimension = maxPixelSize
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            let longest = max(width, height)
            if preserveTallStrips && height > width * 2 {
                let targetWidth = Double(min(width, maxPixelSize))
                let scaledHeight: Double = targetWidth * Double(height) / Double(width)
                targetMaxDimension = Int(scaledHeight.rounded())
            }
            targetMaxDimension = min(targetMaxDimension, longest)
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, targetMaxDimension)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary)
    }

    /// 1:1 port of Mihon's native C++ `crop_borders` algorithm:
    /// Scans top, bottom, left, and right edges of a `CGImage` for uniform white (>=245) or black (<=10) margins
    public static func cropWhiteOrBlackBorders(from image: CGImage, thresholdRatio: Double = 0.96) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 16, height > 16 else { return image }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelBuffer = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelBuffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isBorderPixel(x: Int, y: Int) -> Bool {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let r = pixelBuffer[offset]
            let g = pixelBuffer[offset + 1]
            let b = pixelBuffer[offset + 2]
            let isWhite = (r >= 242 && g >= 242 && b >= 242)
            let isBlack = (r <= 12 && g <= 12 && b <= 12)
            return isWhite || isBlack
        }

        func isRowUniformBorder(y: Int) -> Bool {
            let step = max(1, width / 64)
            var matches = 0
            var total = 0
            for x in stride(from: 0, to: width, by: step) {
                total += 1
                if isBorderPixel(x: x, y: y) { matches += 1 }
            }
            return Double(matches) / Double(max(1, total)) >= thresholdRatio
        }

        func isColumnUniformBorder(x: Int, top: Int, bottom: Int) -> Bool {
            let span = max(1, bottom - top)
            let step = max(1, span / 64)
            var matches = 0
            var total = 0
            for y in stride(from: top, to: bottom, by: step) {
                total += 1
                if isBorderPixel(x: x, y: y) { matches += 1 }
            }
            return Double(matches) / Double(max(1, total)) >= thresholdRatio
        }

        var top = 0
        let maxTopCrop = height / 4
        while top < maxTopCrop && isRowUniformBorder(y: top) {
            top += 1
        }

        var bottom = height - 1
        let minBottomCrop = height - (height / 4)
        while bottom > minBottomCrop && bottom > top && isRowUniformBorder(y: bottom) {
            bottom -= 1
        }

        var left = 0
        let maxLeftCrop = width / 4
        while left < maxLeftCrop && isColumnUniformBorder(x: left, top: top, bottom: bottom) {
            left += 1
        }

        var right = width - 1
        let minRightCrop = width - (width / 4)
        while right > minRightCrop && right > left && isColumnUniformBorder(x: right, top: top, bottom: bottom) {
            right -= 1
        }

        let cropWidth = right - left + 1
        let cropHeight = bottom - top + 1
        guard cropWidth > width / 2, cropHeight > height / 2 else { return image }
        if top == 0 && bottom == height - 1 && left == 0 && right == width - 1 {
            return image
        }

        let cropRect = CGRect(x: left, y: top, width: cropWidth, height: cropHeight)
        return image.cropping(to: cropRect) ?? image
    }

    /// 1:1 port of Mihon's `ImageDecoder` tall Webtoon splitter:
    /// Splits ultra-tall vertical strip images (>4096px) into GPU-safe slices
    public static func splitTallWebtoonImage(_ image: CGImage, maxSliceHeight: Int = 3072) -> [CGImage] {
        guard image.height > maxSliceHeight else {
            return [image]
        }
        var slices: [CGImage] = []
        var y = 0
        while y < image.height {
            let sliceH = min(maxSliceHeight, image.height - y)
            let rect = CGRect(x: 0, y: y, width: image.width, height: sliceH)
            if let slice = image.cropping(to: rect) {
                slices.append(slice)
            }
            y += sliceH
        }
        return slices
    }
}

// MARK: - 4. Two-Tier Image Pipeline (NSCache L1 + Disk SHA-256 L2) & Reader Sliding-Window Page Preloader

/// Target decode sizes. Covers are decoded once at grid size and shared by every screen.
public enum MihonImageTarget: Sendable {
    case cover
    case icon
    case page(maxPixelSize: Int)

    public var maxPixelSize: Int {
        switch self {
        case .cover: return 600
        case .icon: return 144
        case .page(let size): return size
        }
    }

    var preserveTallStrips: Bool {
        if case .page = self { return true }
        return false
    }
}

/// Coalesces concurrent requests for the same image so a fast-scrolling grid never downloads twice. A load is
/// cancelled once every caller waiting for it is (cells scrolled away, the reader's slider dragged across a
/// chapter), and a caller arriving after that starts a new one.
actor MihonImageLoadCoordinator {
    /// Mutated only on the coordinator.
    private final class Load: @unchecked Sendable {
        let task: Task<CGImage?, Never>
        var waiting = 0

        init(task: Task<CGImage?, Never>) {
            self.task = task
        }
    }

    private var inflight: [String: Load] = [:]

    func image(forKey key: String, priority: TaskPriority, operation: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        let load: Load
        if let existing = inflight[key] {
            load = existing
        } else {
            load = Load(task: Task.detached(priority: priority, operation: operation))
            inflight[key] = load
        }
        load.waiting += 1
        let result = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { await self.callerCancelled(key, load) }
        }
        if inflight[key] === load { inflight[key] = nil }
        return result
    }

    /// Callers that finish normally are not counted down: by then the load is over.
    private func callerCancelled(_ key: String, _ load: Load) {
        load.waiting -= 1
        guard load.waiting == 0 else { return }
        load.task.cancel()
        if inflight[key] === load { inflight[key] = nil }
    }
}

public final class MihonTwoTierImageCache: @unchecked Sendable {
    /// Under XCTest the shared cache lives in a temporary folder: tests download and delete chapters, and on a Mac
    /// the default folders belong to the preview app.
    public static let shared = MihonTwoTierImageCache(
        rootDirectory: NSClassFromString("XCTestCase") == nil ? nil : FileManager.default.temporaryDirectory
            .appendingPathComponent("MihonTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    )

    private let memoryCache = NSCache<NSString, CGImage>()
    /// Pages read online (upstream's chapter cache).
    private let diskDirectory: URL
    /// Covers and icons, apart from the pages so the cache trim can spare the library's (upstream `CoverCache`).
    private let coverDirectory: URL
    /// Downloaded chapters: pages (same file names as the cache) and each chapter's page list. Application
    /// Support, which iOS never purges (Caches it may) and "clear chapter cache" leaves alone, as upstream.
    private let downloadsDirectory: URL
    private let pageListsDirectory: URL
    private let coordinator = MihonImageLoadCoordinator()

    /// `rootDirectory` holds the cache and the downloads in one folder instead of Caches and Application Support.
    public init(rootDirectory: URL? = nil) {
        memoryCache.totalCostLimit = 160 * 1024 * 1024
        memoryCache.countLimit = 400

        let baseCache = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.diskDirectory = baseCache.appendingPathComponent("MihonChapterImageCache", isDirectory: true)
        self.coverDirectory = baseCache.appendingPathComponent("MihonCoverCache", isDirectory: true)
        let appSupport = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let downloads = appSupport.appendingPathComponent("Mihon-iOS/Downloads", isDirectory: true)
        self.downloadsDirectory = downloads.appendingPathComponent("Pages", isDirectory: true)
        self.pageListsDirectory = downloads.appendingPathComponent("Chapters", isDirectory: true)
        for directory in [diskDirectory, coverDirectory, downloadsDirectory, pageListsDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func cacheKey(for rawKey: String) -> String {
        let digest = SHA256.hash(data: Data(MihonLiveSources.stableImageKey(rawKey).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func memoryKey(_ url: String, _ target: MihonImageTarget, cropBorders: Bool) -> NSString {
        "\(target.maxPixelSize)|\(cropBorders ? 1 : 0)|\(url)" as NSString
    }

    /// O(1) memory-only lookup. Safe to call from SwiftUI `body` / view initializers.
    public func cachedImage(url: String, target: MihonImageTarget, cropBorders: Bool = false) -> CGImage? {
        memoryCache.object(forKey: memoryKey(url, target, cropBorders: cropBorders))
    }

    /// Puts an image decoded earlier back in memory: one a view is about to show again (the memory cache may have let
    /// it go while the caller held on to it).
    public func remember(_ image: CGImage, url: String, target: MihonImageTarget, cropBorders: Bool = false) {
        memoryCache.setObject(image, forKey: memoryKey(url, target, cropBorders: cropBorders), cost: image.bytesPerRow * image.height)
    }

    /// Memory → disk → network. Disk I/O, decoding and cropping always run off the main thread.
    public func image(
        url: String,
        target: MihonImageTarget,
        headers: [String: String] = [:],
        cropBorders: Bool = false,
        priority: TaskPriority = .userInitiated
    ) async -> CGImage? {
        let key = memoryKey(url, target, cropBorders: cropBorders)
        if let hit = memoryCache.object(forKey: key) {
            return hit
        }
        guard let remoteUrl = URL(string: url) else { return nil }
        let diskUrl = (target.preserveTallStrips ? diskDirectory : coverDirectory).appendingPathComponent(cacheKey(for: url))
        let downloadedUrl = downloadsDirectory.appendingPathComponent(cacheKey(for: url))
        let isLocal = url.hasPrefix(MihonLocalSource.baseUrl) || MihonCustomCovers.isCustomCoverUrl(url)

        let keyString = key as String
        return await coordinator.image(forKey: keyString, priority: priority) { [self] in
            var data: Data?
            var fromNetwork = false
            if isLocal {
                // The user's own files (and custom covers): read where they are, never copied into the cache.
                data = MihonLocalSource.data(forUrl: url) ?? MihonCustomCovers.data(forUrl: url)
            } else {
                data = try? Data(contentsOf: downloadedUrl)
                if data == nil, let cached = try? Data(contentsOf: diskUrl) {
                    data = cached
                    // Read again: the cache trim goes by this date, so it drops what was used least recently.
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diskUrl.path)
                }
                fromNetwork = data == nil
                if fromNetwork {
                    data = try? await MihonNetworkClient.shared.fetchAsset(url: remoteUrl, headers: headers)
                }
            }
            guard let data,
                  var decoded = MihonImageProcessor.decodeForDisplay(
                    from: data,
                    maxPixelSize: target.maxPixelSize,
                    preserveTallStrips: target.preserveTallStrips
                  ) else {
                return nil
            }
            // Kept only once it decodes: a 200 that is not an image (a captive portal, an error page) would
            // otherwise stick — for good under a signature-free key (`MihonLiveSources.stableImageKey`).
            if fromNetwork {
                try? data.write(to: diskUrl, options: .atomic)
            }
            if cropBorders {
                decoded = MihonImageProcessor.cropWhiteOrBlackBorders(from: decoded)
            }
            self.memoryCache.setObject(decoded, forKey: keyString as NSString, cost: decoded.bytesPerRow * decoded.height)
            return decoded
        }
    }

    /// A page's original bytes (upstream saves and shares these, not the displayed bitmap): downloaded, cached,
    /// local, else fetched again.
    public func originalData(url: String, headers: [String: String] = [:]) async -> Data? {
        if url.hasPrefix(MihonLocalSource.baseUrl) || MihonCustomCovers.isCustomCoverUrl(url) {
            return await Task.detached(priority: .userInitiated) {
                MihonLocalSource.data(forUrl: url) ?? MihonCustomCovers.data(forUrl: url)
            }.value
        }
        let key = cacheKey(for: url)
        let candidates = [downloadsDirectory, diskDirectory, coverDirectory].map { $0.appendingPathComponent(key) }
        if let stored = await Task.detached(priority: .userInitiated, operation: {
            candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first
        }).value {
            return stored
        }
        guard let remoteUrl = URL(string: url) else { return nil }
        return try? await MihonNetworkClient.shared.fetchAsset(url: remoteUrl, headers: headers)
    }

    /// Warms the cache for upcoming grid rows / chapter pages without blocking the caller.
    public func prefetch(urls: [String], target: MihonImageTarget, headers: [String: String] = [:]) {
        for url in urls where cachedImage(url: url, target: target) == nil {
            Task.detached(priority: .utility) {
                _ = await self.image(url: url, target: target, headers: headers, priority: .utility)
            }
        }
    }

    /// Synchronous memory + disk lookup (legacy API). Never call this from the main thread.
    public func image(forKey key: String) -> CGImage? {
        let target = MihonImageTarget.page(maxPixelSize: 2560)
        if let hit = cachedImage(url: key, target: target) {
            return hit
        }
        let file = cacheKey(for: key)
        let data = (try? Data(contentsOf: downloadsDirectory.appendingPathComponent(file)))
            ?? (try? Data(contentsOf: diskDirectory.appendingPathComponent(file)))
        if let data, let decoded = MihonImageProcessor.decodeSubsampledCGImage(from: data) {
            memoryCache.setObject(decoded, forKey: memoryKey(key, target, cropBorders: false), cost: decoded.bytesPerRow * decoded.height)
            return decoded
        }
        return nil
    }

    /// Stores raw bytes on disk and returns the decoded bitmap (legacy API used by downloads).
    @discardableResult
    public func store(imageData: Data, forKey key: String, cropBorders: Bool = false) -> CGImage? {
        let diskUrl = diskDirectory.appendingPathComponent(cacheKey(for: key))
        try? imageData.write(to: diskUrl, options: .atomic)

        let target = MihonImageTarget.page(maxPixelSize: 2560)
        guard var decoded = MihonImageProcessor.decodeForDisplay(
            from: imageData,
            maxPixelSize: target.maxPixelSize,
            preserveTallStrips: true
        ) else {
            return nil
        }
        if cropBorders {
            decoded = MihonImageProcessor.cropWhiteOrBlackBorders(from: decoded)
        }
        memoryCache.setObject(decoded, forKey: memoryKey(key, target, cropBorders: cropBorders), cost: decoded.bytesPerRow * decoded.height)
        return decoded
    }

    /// Stores a downloaded page (raw bytes; decoded when shown). Bytes that are not an image are refused (as in
    /// `image(url:target:)`); returns whether they were stored.
    @discardableResult
    public func storeRawData(_ data: Data, forKey key: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return (try? data.write(to: downloadsDirectory.appendingPathComponent(cacheKey(for: key)), options: .atomic)) != nil
    }

    /// The image URLs of a downloaded chapter, in page order: reading it needs no page-list request (offline, or
    /// a MangaDex@Home node that changed since the download). Pages are stored once per URL and shared between
    /// chapters (咚漫 episodes repeat most of their images), so this list is also what keeps a page in use.
    public func saveDownloadedPageList(chapterId: Int64, urls: [String]) {
        guard let data = try? JSONEncoder().encode(urls) else { return }
        try? data.write(to: pageListURL(chapterId), options: .atomic)
    }

    public func downloadedPageList(chapterId: Int64) -> [String]? {
        guard let data = try? Data(contentsOf: pageListURL(chapterId)) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Deletes a downloaded chapter's page list, and those of its pages no other saved list names.
    public func removeDownloadedChapter(chapterId: Int64) {
        let urls = downloadedPageList(chapterId: chapterId) ?? []
        try? FileManager.default.removeItem(at: pageListURL(chapterId))
        var unused = Set(urls.map(cacheKey(for:)))
        for other in savedPageListIds() where !unused.isEmpty {
            for url in downloadedPageList(chapterId: other) ?? [] {
                unused.remove(cacheKey(for: url))
            }
        }
        for key in unused {
            try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(key))
        }
    }

    /// Files downloaded chapters under new chapter ids (`[old: new]`; swaps and chains included), keeping their pages.
    public func moveDownloadedChapters(_ moves: [Int64: Int64]) {
        let lists = moves.compactMap { old, new in downloadedPageList(chapterId: old).map { (new, $0) } }
        for old in moves.keys {
            try? FileManager.default.removeItem(at: pageListURL(old))
        }
        for (new, urls) in lists {
            saveDownloadedPageList(chapterId: new, urls: urls)
        }
    }

    /// Deletes every downloaded page and page list.
    public func removeAllDownloads() {
        for directory in [downloadsDirectory, pageListsDirectory] {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Deletes what downloads cut short left behind (the app quit mid-chapter, an abort in an earlier build): page
    /// lists of chapters not in `downloaded`, and pages no remaining list names. Call it while no download runs —
    /// one stores pages it has just listed.
    public func removeIncompleteDownloads(keeping downloaded: Set<Int64>) {
        for id in savedPageListIds() where !downloaded.contains(id) {
            try? FileManager.default.removeItem(at: pageListURL(id))
        }
        var listed = Set<String>()
        for id in savedPageListIds() {
            for url in downloadedPageList(chapterId: id) ?? [] {
                listed.insert(cacheKey(for: url))
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path)) ?? []
        for file in files where !listed.contains(file) {
            try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(file))
        }
    }

    /// Whether `url` is already downloaded (pages the cache happens to hold are fetched into the downloads too).
    public func hasDiskEntry(for url: String) -> Bool {
        FileManager.default.fileExists(atPath: downloadsDirectory.appendingPathComponent(cacheKey(for: url)).path)
    }

    /// The highest chapter id a page list is saved under: new chapter ids must not reuse one.
    public func highestDownloadedChapterId() -> Int64? {
        savedPageListIds().max()
    }

    private func pageListURL(_ chapterId: Int64) -> URL {
        pageListsDirectory.appendingPathComponent("\(chapterId).json")
    }

    private func savedPageListIds() -> [Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pageListsDirectory.path)) ?? []
        return names.compactMap { $0.hasSuffix(".json") ? Int64($0.dropLast(5)) : nil }
    }

    public func clearAllCaches() {
        memoryCache.removeAllObjects()
        for directory in [diskDirectory, coverDirectory] {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Keeps the image cache under its limits by deleting the files used longest ago, down to three quarters —
    /// upstream caps its chapter cache too, and iOS clears Caches only when the device runs out of space. The
    /// covers in `keepingCovers` (the library's, which upstream keeps apart in `CoverCache`) are neither deleted
    /// nor counted; downloads live elsewhere. Slow on a big cache: run it off the main thread.
    public func trimDiskCache(
        pageLimit: Int64 = 300 * 1024 * 1024,
        coverLimit: Int64 = 100 * 1024 * 1024,
        keepingCovers covers: Set<String> = []
    ) {
        Self.trim(diskDirectory, limit: pageLimit, keeping: [])
        Self.trim(coverDirectory, limit: coverLimit, keeping: Set(covers.map(cacheKey(for:))))
    }

    private static func trim(_ directory: URL, limit: Int64, keeping: Set<String>) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        var files = urls.compactMap { url -> (url: URL, size: Int64, used: Date)? in
            guard !keeping.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        files.sort { $0.used < $1.used }
        for file in files where total > limit / 4 * 3 {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    public func diskCacheSizeBytes() -> Int64 {
        var total: Int64 = 0
        for directory in [diskDirectory, coverDirectory] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}

/// 1:1 with Mihon's `PageLoader` preloader:
/// Preloads `[currentPage - preloadBehind ... currentPage + preloadAhead]` in background and drops stale work on jump.
public actor MihonReaderPagePreloader {
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    /// The pages the indices of `activeTasks` refer to.
    private var windowPages: (count: Int, first: String?, last: String?)?
    public var preloadAheadCount: Int = 4
    public var preloadBehindCount: Int = 1

    public init() {}

    public func updateWindow(
        currentPage: Int,
        pages: [Page],
        cropBorders: Bool,
        maxPixelSize: Int = 2048
    ) {
        guard !pages.isEmpty else { return }
        // Another chapter's pages (the webtoon strip runs on into the next): the indices name other pages now.
        let identity = (count: pages.count, first: pages.first?.imageUrl, last: pages.last?.imageUrl)
        if let windowPages, windowPages != identity { cancelAll() }
        windowPages = identity
        let minKeep = max(0, currentPage - preloadBehindCount)
        let maxKeep = min(pages.count - 1, currentPage + preloadAheadCount)
        guard minKeep <= maxKeep else { return }
        let validRange = minKeep...maxKeep

        for (pageIdx, task) in activeTasks where !validRange.contains(pageIdx) {
            task.cancel()
            activeTasks.removeValue(forKey: pageIdx)
        }

        let target = MihonImageTarget.page(maxPixelSize: maxPixelSize)
        for idx in validRange where activeTasks[idx] == nil {
            let page = pages[idx]
            guard page.hasRealImage, let imgUrlStr = page.imageUrl else { continue }
            if MihonTwoTierImageCache.shared.cachedImage(url: imgUrlStr, target: target, cropBorders: cropBorders) != nil {
                continue
            }
            // Nearest pages first: the page right after the current one gets the highest priority.
            let priority: TaskPriority = idx == currentPage + 1 ? .userInitiated : .utility
            activeTasks[idx] = Task.detached(priority: priority) {
                _ = await MihonTwoTierImageCache.shared.image(
                    url: imgUrlStr,
                    target: target,
                    cropBorders: cropBorders,
                    priority: priority
                )
            }
        }
    }

    public func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }
}

// MARK: - 5. Asynchronous Disk Persistence Engine

public actor MihonDiskPersistenceManager {
    public static let shared = MihonDiskPersistenceManager()
    private let storageFileURL: URL

    public init() {
        self.storageFileURL = Self.defaultStorageFileURL()
    }

    private static func defaultStorageFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Mihon-iOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mihon_state_v2.json")
    }

    public func saveSnapshot(_ payload: MihonBackupPayload) throws {
        let data = try Self.encode(payload)
        try Self.writeLock.withLock { try data.write(to: storageFileURL, options: .atomic) }
    }

    /// Builds the payload here, on the actor: flattening a whole library is not main-thread work. A newer save
    /// (`saveSnapshotSynchronously`) cancels the task this runs in, so a slow one never lands after it.
    public func saveSnapshot(building payload: @Sendable () -> MihonBackupPayload) throws {
        let data = try Self.encode(payload())
        try Self.writeLock.withLock {
            guard !Task.isCancelled else { return }
            try data.write(to: storageFileURL, options: .atomic)
        }
    }

    /// Orders the two ways the library reaches disk (this actor, and the synchronous save on the main thread).
    private static let writeLock = NSLock()

    public enum SnapshotLoad {
        /// Nothing saved yet, or a file that no longer decodes (moved aside).
        case empty
        case loaded(MihonBackupPayload)
        /// A saved file that cannot be read right now (data protection before the first unlock, an I/O error):
        /// nothing may be saved over it.
        case unreadable
    }

    public func loadSnapshot() -> MihonBackupPayload? {
        if case .loaded(let payload) = Self.loadSnapshotSynchronously(at: storageFileURL) { return payload }
        return nil
    }

    /// For launch: the store restores the saved library before its first frame instead of flashing the seed data.
    public static func loadSnapshotSynchronously() -> SnapshotLoad {
        loadSnapshotSynchronously(at: defaultStorageFileURL())
    }

    /// A file that no longer decodes (a schema change, a downgrade) is moved aside rather than left to be
    /// overwritten by the next save.
    static func loadSnapshotSynchronously(at url: URL) -> SnapshotLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let payload = try? decoder.decode(MihonBackupPayload.self, from: data) { return .loaded(payload) }
        let aside = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return .empty
    }

    /// For launch-time migrations, which must be on disk before they are recorded as done.
    public static func saveSnapshotSynchronously(_ payload: MihonBackupPayload) throws {
        let data = try encode(payload)
        try writeLock.withLock { try data.write(to: defaultStorageFileURL(), options: .atomic) }
    }

    private static func encode(_ payload: MihonBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }
}
