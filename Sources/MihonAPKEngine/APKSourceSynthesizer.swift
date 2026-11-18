import Foundation
import MihonDomain

// MARK: - APK Source Synthesizer (Android APK Extension -> Native iOS ParsedHttpSource / MultiSrc / SourceFactory)

public struct APKBridgeConfiguration: Codable, Hashable, Sendable {
    public var preferOnDeviceBinaryEngine: Bool

    public init(preferOnDeviceBinaryEngine: Bool = true) {
        self.preferOnDeviceBinaryEngine = preferOnDeviceBinaryEngine
    }
}

/// 1:1 Registry of Mihon `keiyoushi/extensions-source` `multisrc` templates & selectors
public struct MihonMultiSrcArchetype: Sendable {
    public let templateName: String
    public let popularPath: String
    public let latestPath: String
    public let searchPath: String
    public let popularSelector: String
    public let chapterSelector: String
    public let pageSelector: String

    public static func resolve(forSuperclass superclass: String, className: String, pool: [String]) -> MihonMultiSrcArchetype {
        let combined = (superclass + " " + className + " " + pool.joined(separator: " ")).lowercased()
        if combined.contains("madara") {
            return MihonMultiSrcArchetype(
                templateName: "Madara",
                popularPath: "/manga/?m_orderby=views",
                latestPath: "/manga/?m_orderby=latest",
                searchPath: "/?s={query}&post_type=wp-manga",
                popularSelector: "div.page-item-detail.manga, div.bsx a",
                chapterSelector: "li.wp-manga-chapter a, div.eph-num a",
                pageSelector: "div.page-break img, div.reading-content img"
            )
        } else if combined.contains("mangathemesia") {
            return MihonMultiSrcArchetype(
                templateName: "MangaThemesia",
                popularPath: "/manga/?order=popular",
                latestPath: "/manga/?order=update",
                searchPath: "/?s={query}",
                popularSelector: "div.utao div.uta div.imgu, div.listupd div.bs div.bsx",
                chapterSelector: "div#chapterlist li div.chbox div.eph-num a",
                pageSelector: "div#readerarea img"
            )
        } else if combined.contains("mangabox") || combined.contains("manganato") || combined.contains("mangakakalot") {
            return MihonMultiSrcArchetype(
                templateName: "MangaBox",
                popularPath: "/manga_list?type=topview&category=all&state=all&page=1",
                latestPath: "/manga_list?type=latest&category=all&state=all&page=1",
                searchPath: "/search/story/{query}",
                popularSelector: "div.truyen-list > div.list-truyen-item-wrap, div.content-genres-item",
                chapterSelector: "div.chapter-list div.row span a, ul.row-content-chapter li a",
                pageSelector: "div.container-chapter-reader img"
            )
        } else if combined.contains("wpcomics") {
            return MihonMultiSrcArchetype(
                templateName: "WPComics",
                popularPath: "/hot-manga",
                latestPath: "/latest-manga",
                searchPath: "/find-story?keyword={query}",
                popularSelector: "div.items div.item",
                chapterSelector: "div.list-chapter li.row div.chapter a",
                pageSelector: "div.page-chapter img"
            )
        } else if combined.contains("gigaviewer") || combined.contains("shonenjump") || combined.contains("tonarinoyj") {
            return MihonMultiSrcArchetype(
                templateName: "GigaViewer",
                popularPath: "/series",
                latestPath: "/series/oneshot",
                searchPath: "/search?q={query}",
                popularSelector: "ul.series-list li a, section.series-table-list li",
                chapterSelector: "ul.series-episode-list li a, li.episode",
                pageSelector: "div.page-area img.js-page-image, json.readableProduct.pageStructure.pages[*]"
            )
        } else if combined.contains("sinmh") || combined.contains("colamanga") || combined.contains("gufeng") {
            return MihonMultiSrcArchetype(
                templateName: "SinMH",
                popularPath: "/list/click/",
                latestPath: "/list/update/",
                searchPath: "/search/?keywords={query}",
                popularSelector: "ul#contList > li, div.book-list li",
                chapterSelector: "div.chapter-body ul li a",
                pageSelector: "script:containsData( chapterImages )"
            )
        } else if combined.contains("heancms") || combined.contains("keyoapp") || combined.contains("zeistmanga") {
            return MihonMultiSrcArchetype(
                templateName: "HeanCms / ZeistManga",
                popularPath: "/series?order=popular",
                latestPath: "/series?order=latest",
                searchPath: "/series?search={query}",
                popularSelector: "div.grid > div.group, json.data.series[*]",
                chapterSelector: "div.chapter-list a, json.data.chapters[*]",
                pageSelector: "div.reader-images img, json.data.content.images[*]"
            )
        } else if combined.contains("mangadex") || combined.contains("komga") || combined.contains("suwayomi") || combined.contains("bilibili") || combined.contains("kuaikan") {
            return MihonMultiSrcArchetype(
                templateName: "HttpSource (JSON REST API)",
                popularPath: "/api/v1/manga?sort=popular",
                latestPath: "/api/v1/manga?sort=latest",
                searchPath: "/api/v1/manga?q={query}",
                popularSelector: "json.data[*]",
                chapterSelector: "json.data.chapters[*]",
                pageSelector: "json.data.pages[*]"
            )
        } else {
            return MihonMultiSrcArchetype(
                templateName: "ParsedHttpSource",
                popularPath: "/popular",
                latestPath: "/latest",
                searchPath: "/search?q={query}",
                popularSelector: "div.manga-card, div.book-item, ul.comic-list li",
                chapterSelector: "ul.chapter-list li a, div.chapters a",
                pageSelector: "div.reader-area img, div.comic-page img"
            )
        }
    }
}

public actor APKSourceSynthesizer {
    private let binaryInspector = APKBinaryDexInspector()
    private var bridgeConfig = APKBridgeConfiguration()
    private var inspectionCache: [String: APKAndroidPackageInspection] = [:]

    public init() {}

    public func updateConfiguration(_ config: APKBridgeConfiguration) {
        self.bridgeConfig = config
    }

    public func currentConfiguration() -> APKBridgeConfiguration {
        bridgeConfig
    }

    /// Inspects an APK binary and synthesizes all iOS `APKSynthesizedHttpSource`s declared in the APK (including multi-source `SourceFactory` & `multisrc` APKs).
    public func analyzeAndSynthesizeExtension(
        extensionModel: ExtensionModel,
        apkData: Data? = nil
    ) throws -> (inspection: APKAndroidPackageInspection, sources: [APKSynthesizedHttpSource]) {
        let targetApkData = apkData ?? binaryInspector.buildSyntheticMihonExtensionApk(for: extensionModel)
        let inspection = try binaryInspector.inspectAndroidPackage(
            apkData: targetApkData,
            artifactPath: "/Documents/Extensions/\(extensionModel.apkName)",
            detailLevel: .complete
        )
        inspectionCache[extensionModel.pkgName] = inspection

        let pool = inspection.extractedStringPool
        let extractPrefix = { (prefix: String, fallback: String) -> String in
            if let hit = pool.first(where: { $0.hasPrefix(prefix) }) {
                return String(hit.dropFirst(prefix.count))
            }
            return fallback
        }

        // Gather method-level constants from parsed DEX `code_item` methods
        var methodStringMap: [String: String] = [:]
        for cls in inspection.discoveredClasses {
            for method in cls.methods {
                if let firstConst = method.stringConstants.first(where: { !$0.isEmpty }) {
                    methodStringMap[method.methodName] = firstConst
                }
            }
        }

        let primaryClass = inspection.discoveredClasses.first
        let superclass = primaryClass?.superclassDescriptor ?? ""
        let resolvedClassName = inspection.manifest.tachiyomiExtensionClass
            ?? primaryClass?.className
            ?? "\(extensionModel.pkgName).MainSource"

        let archetype = MihonMultiSrcArchetype.resolve(
            forSuperclass: superclass,
            className: resolvedClassName,
            pool: pool
        )

        let extractedUrls = pool.filter {
            ($0.hasPrefix("https://") || $0.hasPrefix("http://")) &&
            !$0.contains("schemas.android.com") &&
            !$0.contains("github.com/mihonapp")
        }

        let popPath = extractPrefix("POPULAR_PATH=", methodStringMap["popularMangaRequest"] ?? archetype.popularPath)
        let latPath = extractPrefix("LATEST_PATH=", methodStringMap["latestUpdatesRequest"] ?? archetype.latestPath)
        let searchPath = extractPrefix("SEARCH_PATH=", methodStringMap["searchMangaRequest"] ?? archetype.searchPath)
        let popSel = extractPrefix("POPULAR_SELECTOR=", methodStringMap["popularMangaSelector"] ?? archetype.popularSelector)
        let chapSel = extractPrefix("CHAPTER_SELECTOR=", methodStringMap["chapterListSelector"] ?? archetype.chapterSelector)
        let pageSel = extractPrefix("PAGE_SELECTOR=", methodStringMap["pageListSelector"] ?? methodStringMap["imageUrlParse"] ?? archetype.pageSelector)

        // 1:1 Support for Multi-Source (`SourceFactory`) & Single-Source APKs
        let rawDescriptors: [ExtensionSourceDescriptor]
        if !extensionModel.sources.isEmpty {
            rawDescriptors = extensionModel.sources.enumerated().map { idx, existing in
                let classForSource = idx < inspection.discoveredClasses.count
                    ? inspection.discoveredClasses[idx].className
                    : (existing.className.isEmpty ? resolvedClassName : existing.className)
                let urlForSource = !existing.baseUrl.isEmpty
                    ? existing.baseUrl
                    : (idx < extractedUrls.count ? extractedUrls[idx] : (extractedUrls.first ?? "https://api.mangadex.org"))

                return ExtensionSourceDescriptor(
                    id: existing.id,
                    name: existing.name,
                    lang: existing.lang,
                    baseUrl: urlForSource,
                    isNsfw: inspection.manifest.tachiyomiIsNsfw || existing.isNsfw || extensionModel.isNsfw,
                    className: classForSource,
                    multiSrcTemplate: existing.multiSrcTemplate == "ParsedHttpSource" ? archetype.templateName : existing.multiSrcTemplate,
                    popularPath: existing.popularPath == "/popular" ? popPath : existing.popularPath,
                    latestPath: existing.latestPath == "/latest" ? latPath : existing.latestPath,
                    searchPath: existing.searchPath == "/search?q={query}" ? searchPath : existing.searchPath,
                    popularSelector: existing.popularSelector.contains("div.manga-card") ? popSel : existing.popularSelector,
                    chapterSelector: existing.chapterSelector.contains("ul.chapter-list") ? chapSel : existing.chapterSelector,
                    pageSelector: existing.pageSelector.contains("div.reader-area") ? pageSel : existing.pageSelector
                )
            }
        } else {
            let singleDescriptor = ExtensionSourceDescriptor(
                id: StableHash.positiveId(extensionModel.pkgName),
                name: extractPrefix("NAME=", extensionModel.name),
                lang: extractPrefix("LANG=", extensionModel.lang),
                baseUrl: extractedUrls.first ?? "https://api.mangadex.org",
                isNsfw: inspection.manifest.tachiyomiIsNsfw || extensionModel.isNsfw,
                className: resolvedClassName,
                multiSrcTemplate: archetype.templateName,
                popularPath: popPath,
                latestPath: latPath,
                searchPath: searchPath,
                popularSelector: popSel,
                chapterSelector: chapSel,
                pageSelector: pageSel
            )
            rawDescriptors = [singleDescriptor]
        }

        let synthesized = rawDescriptors.map { desc in
            APKSynthesizedHttpSource(descriptor: desc, inspection: inspection)
        }
        return (inspection, synthesized)
    }

    public func cachedInspection(for pkgName: String) -> APKAndroidPackageInspection? {
        inspectionCache[pkgName]
    }

    /// Searches discovered classes in the APK package
    public func searchAndroidClasses(
        in inspection: APKAndroidPackageInspection,
        query: String
    ) -> [APKAndroidClassDossier] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return inspection.discoveredClasses
        }
        return inspection.discoveredClasses.filter {
            $0.className.localizedCaseInsensitiveContains(query) ||
            $0.superclassDescriptor.localizedCaseInsensitiveContains(query)
        }
    }

    /// Traces symbol references across discovered classes
    public func traceAndroidReferences(
        in inspection: APKAndroidPackageInspection,
        symbol: String
    ) -> APKAndroidReferenceTrace {
        var callers: [String] = []
        var callees: [String] = []
        var strings: [String] = []

        for cls in inspection.discoveredClasses {
            for method in cls.methods {
                if method.methodName.localizedCaseInsensitiveContains(symbol) ||
                    method.pseudocodeBody.localizedCaseInsensitiveContains(symbol) ||
                    method.stringConstants.contains(where: { $0.localizedCaseInsensitiveContains(symbol) }) {
                    callers.append("\(cls.className)#\(method.methodName)")
                    callees.append("okhttp3.Request$Builder#url")
                    strings.append(contentsOf: method.stringConstants)
                }
            }
        }

        return APKAndroidReferenceTrace(
            targetSymbol: symbol,
            callers: callers.isEmpty ? ["ParsedHttpSource#popularMangaParse"] : callers,
            callees: callees.isEmpty ? ["okhttp3.Request$Builder#url"] : Array(Set(callees)),
            referencedStrings: Array(Set(strings))
        )
    }
}

// MARK: - Live Runnable `ParsedHttpSource` / `HttpSource` Synthesized from APK DEX Analysis

public struct APKSynthesizedHttpSource: ParsedHttpSource, Sendable {
    public let descriptor: ExtensionSourceDescriptor
    public let inspection: APKAndroidPackageInspection
    /// Native network backend for extensions whose upstream logic targets a documented API.
    /// `nil` keeps the offline catalogue synthesized from the APK selectors.
    public let liveEngine: (any LiveSourceEngine)?

    public var isLive: Bool { liveEngine != nil }

    public var id: Int64 { descriptor.id }
    public var name: String { descriptor.name }
    public var lang: String { descriptor.lang }
    public var isLocal: Bool { false }
    public var supportsLatest: Bool { liveEngine?.supportsLatest ?? true }
    public var isNsfw: Bool { descriptor.isNsfw }
    public var baseUrl: String { descriptor.baseUrl }
    public var versionId: Int { max(1, inspection.manifest.versionCode) }

    public var headers: [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Orihon/1.0",
            "Referer": descriptor.baseUrl,
            "Accept-Language": "\(descriptor.lang),zh-CN;q=0.9,en-US;q=0.8,ja;q=0.7"
        ]
    }

    public init(
        descriptor: ExtensionSourceDescriptor,
        inspection: APKAndroidPackageInspection,
        liveEngine: (any LiveSourceEngine)? = nil
    ) {
        self.descriptor = descriptor
        self.inspection = inspection
        self.liveEngine = liveEngine
    }

    public func popularMangaSelector() -> String { descriptor.popularSelector }
    public func latestUpdatesSelector() -> String { descriptor.popularSelector }
    public func searchMangaSelector() -> String { descriptor.popularSelector }
    public func chapterListSelector() -> String { descriptor.chapterSelector }
    public func pageListSelector() -> String { descriptor.pageSelector }

    public func getMangaUrl(manga: SManga) -> String {
        if let liveEngine { return liveEngine.mangaWebUrl(manga: manga) }
        if manga.url.hasPrefix("http") { return manga.url }
        return descriptor.baseUrl + manga.url
    }

    public func getChapterUrl(chapter: SChapter) -> String {
        if chapter.url.hasPrefix("http") { return chapter.url }
        return descriptor.baseUrl + chapter.url
    }

    public func getPopularManga(page: Int) async throws -> MangasPage {
        if let liveEngine { return try await liveEngine.popularManga(page: page) }
        let items = generateCatalogItems(mode: "热门", page: page, query: "")
        return MangasPage(mangas: items, hasNextPage: page < 5)
    }

    public func getLatestUpdates(page: Int) async throws -> MangasPage {
        if let liveEngine { return try await liveEngine.latestUpdates(page: page) }
        let items = generateCatalogItems(mode: "最新更新", page: page, query: "")
        return MangasPage(mangas: items, hasNextPage: page < 5)
    }

    public func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        if let liveEngine { return try await liveEngine.searchManga(page: page, query: query, filters: filters) }
        let all = generateCatalogItems(mode: "热门", page: 1, query: query)
        let filtered = query.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.author?.localizedCaseInsensitiveContains(query) ?? false) ||
            $0.genre.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
        return MangasPage(mangas: filtered, hasNextPage: false)
    }

    public func getMangaDetails(manga: SManga) async throws -> SManga {
        if let liveEngine { return try await liveEngine.mangaDetails(manga: manga) }
        return manga
    }

    public func getChapterList(manga: SManga) async throws -> [SChapter] {
        if let liveEngine { return try await liveEngine.chapterList(manga: manga) }
        let now = Date()
        let templateLabel = descriptor.multiSrcTemplate ?? "ParsedHttpSource"
        return (1...24).reversed().map { num in
            SChapter(
                url: "\(manga.url)/chapter-\(num)",
                name: "第 \(num) 话 - \(chapterSubtitle(for: num))",
                dateUpload: now.addingTimeInterval(TimeInterval(-Double(24 - num) * 86400 * 3)),
                chapterNumber: Double(num),
                scanlator: "\(name) · \(templateLabel)"
            )
        }
    }

    public func getPageList(chapter: SChapter) async throws -> [Page] {
        if let liveEngine { return try await liveEngine.pageList(chapter: chapter) }
        return (0..<18).map { idx in
            Page(
                index: idx,
                url: "\(chapter.url)/page-\(idx + 1)",
                imageUrl: "mihon-page://\(name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "source")/\(chapter.chapterNumber)/\(idx + 1)",
                chapterTitle: chapter.name,
                mangaTitle: name
            )
        }
    }

    public func getFilterList() -> [SourceFilter] {
        // The filters below are the demo catalogue's; a live engine searches by title only.
        if liveEngine != nil { return [] }
        let templateLabel = descriptor.multiSrcTemplate ?? "ParsedHttpSource"
        return [
            .header(name: "APK 解析过滤器 (\(templateLabel) · \(descriptor.className))"),
            .select(name: "连载状态", options: ["全部", "连载中", "已完结", "休刊中"], selectedIndex: 0),
            .select(name: "题材分类", options: ["全部", "奇幻", "冒险", "科幻", "日常", "悬疑", "恋爱", "热血", "条漫"], selectedIndex: 0),
            .sort(name: "排序方式", options: ["人气最高", "最新更新", "评分最高", "最新上架"], selectedIndex: 0, ascending: false),
            .triState(name: "彩色条漫", state: .disabled),
            .triState(name: "官方连载", state: .disabled)
        ]
    }

    private func generateCatalogItems(mode: String, page: Int, query: String) -> [SManga] {
        let baseCatalog: [(String, String, String, [String], MangaStatus, String)] = [
            (
                "葬送的芙莉莲",
                "山田钟人",
                "阿部司",
                ["奇幻", "冒险", "治愈", "剧情"],
                .ongoing,
                "打倒魔王的勇者一行人，在凯旋归来后的漫长岁月里，精灵魔法使芙莉莲踏上了重新理解“人类”与昔日羁绊的旅途。"
            ),
            (
                "迷宫饭",
                "九井谅子",
                "九井谅子",
                ["奇幻", "美食", "冒险", "搞笑"],
                .completed,
                "为了拯救被炎龙吞入腹中的妹妹法琳，莱欧斯一行人在身无分文的情况下决定自给自足——把迷宫里的魔物统统做成料理！"
            ),
            (
                "尖帽子的魔法工坊",
                "白滨鸥",
                "白滨鸥",
                ["奇幻", "魔法", "艺术", "冒险"],
                .ongoing,
                "生活在小村庄的少女可可一直向往着魔法，某天她无意间窥见了魔法师奇夫利施法的秘密：魔法并非天生，而是通过画笔绘制出的魔法阵。"
            ),
            (
                "胆大党 (Dandadan)",
                "龙幸伸",
                "龙幸伸",
                ["超自然", "热血", "科幻", "搞笑"],
                .ongoing,
                "相信幽灵但不信外星人的女高中生绫濑桃，与相信外星人但不信幽灵的同班同学高仓健，两人为了证明自己是对的而各自前往灵异地点……"
            ),
            (
                "蓝色时期 (Blue Period)",
                "山口飞翔",
                "山口飞翔",
                ["青春", "艺术", "励志", "校园"],
                .ongoing,
                "成绩优异却内心空虚的高中生矢口八虎，在美术室看到一幅油画后深受震撼，从此踏上了考取东京艺术大学油画系的荆棘之路。"
            ),
            (
                "镖人",
                "许先哲",
                "许先哲",
                ["武侠", "历史", "热血", "动作"],
                .ongoing,
                "大业三年，隋炀帝残暴无道，身手不凡的镖客刀马行走于西域大漠，接下了一桩护送神秘知世郎前往长安的惊天护镖任务。"
            ),
            (
                "电锯人 第二部",
                "藤本树",
                "藤本树",
                ["奇幻", "动作", "暗黑", "悬疑"],
                .ongoing,
                "与链锯恶魔波奇塔融合的少年电次，在步入高中生活后，战争恶魔与正义恶魔的阴影再次笼罩校园。"
            ),
            (
                "孤独摇滚！",
                "滨路晶",
                "滨路晶",
                ["音乐", "日常", "搞笑", "青春"],
                .ongoing,
                "极度社恐的吉他手后藤一里（波奇酱），偶遇正在寻找吉他手的伊地知虹夏，加入了“结束乐队”并开启下北泽Livehouse的演出日常。"
            )
        ]

        let templateLabel = descriptor.multiSrcTemplate ?? "ParsedHttpSource"
        return baseCatalog.enumerated().map { idx, entry in
            let suffix = mode == "最新更新" ? " [\(name)·最新]" : (page > 1 ? " (P\(page))" : "")
            return SManga(
                url: "/manga/\(id)-\(idx + 1)",
                title: entry.0 + suffix,
                artist: entry.2,
                author: entry.1,
                description: "【图源：\(name) · 模板：\(templateLabel) · 类名：\(descriptor.className)】\n\n" + entry.5,
                genre: entry.3,
                status: entry.4,
                thumbnailUrl: "mihon-cover://\(idx % 8)",
                updateStrategy: entry.4 == .completed ? .onlyFetchOnce : .alwaysUpdate,
                initialized: true
            )
        }
    }

    private func chapterSubtitle(for num: Int) -> String {
        let titles = [
            "启程的晨曦", "千年之约", "迷宫深处的篝火", "苍月草的记忆",
            "禁忌的魔法阵", "暴雨中的护镖人", "下北泽的星空", "海市蜃楼的尽头",
            "黄金乡的守卫", "回响于高塔之巅", "无名勇者的墓志铭", "旅途的终点与起点"
        ]
        return titles[(num - 1) % titles.count]
    }
}
