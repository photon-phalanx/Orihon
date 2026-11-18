import Foundation
import MihonDomain

// MARK: - First-launch seed data
//
// Mixes offline demo entries (synthesized APK sources, AniList artwork) with entries that are backed by the
// live MangaDex API, so covers, chapter lists and chapter pages are real network data out of the box.

enum MihonSeedData {
    /// Real source ids of the `all.mangadex` extension as published in Keiyoushi's `index.pb`.
    enum MangaDexSourceId {
        static let simplifiedChinese: Int64 = 5_148_895_169_070_562_838
        static let traditionalChinese: Int64 = 1_493_666_528_525_752_601
        static let english: Int64 = 2_499_283_573_021_220_255
        static let japanese: Int64 = 1_411_768_577_036_936_240
    }

    static let keiyoushiRepoUrl = "https://raw.githubusercontent.com/keiyoushi/extensions/repo"

    /// Packages that only exist to tell outdated apps to update (served by legacy `index.min.json`).
    static let stubPackages: Set<String> = [
        "eu.kanade.tachiyomi.extension.all.keiyoushi",
        "eu.kanade.tachiyomi.extension.all.mihon"
    ]

    /// Source id of `zh.zaimanhua` in Keiyoushi's `index.pb` (MD5 of `再漫画/zh/1`, as upstream derives ids).
    static let zaimanhuaSourceId: Int64 = 524_579_092_615_598_717
    /// Original Android source ID derived from 动漫之家/zh/1.
    static let dmzjSourceId: Int64 = 2_884_190_037_559_093_788
    /// Source id of `zh.dongmanmanhua` in Keiyoushi's `index.pb`.
    static let dongmanSourceId: Int64 = 4_222_375_517_460_530_289

    static func iconUrl(lang: String, name: String) -> String {
        "https://cdn.jsdelivr.net/gh/keiyoushi/extensions-source@main/src/\(lang)/\(name)/res/mipmap-xhdpi/ic_launcher.png"
    }

    static let categories: [MangaCategory] = [
        MangaCategory(id: 0, name: "默认", order: 0),
        MangaCategory(id: 1, name: "追更连载", order: 1),
        MangaCategory(id: 2, name: "经典必看", order: 2),
        MangaCategory(id: 3, name: "条漫/韩漫", order: 3)
    ]

    static let repos: [ExtensionRepo] = [
        ExtensionRepo(
            baseUrl: keiyoushiRepoUrl,
            name: "Keiyoushi",
            shortName: "KEI",
            website: "https://keiyoushi.github.io",
            signingKeyFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
        )
    ]

    // swiftlint:disable function_body_length
    static let extensions: [ExtensionModel] = [
        ExtensionModel(
            name: "MangaDex",
            pkgName: "eu.kanade.tachiyomi.extension.all.mangadex",
            versionName: "1.4.205",
            versionCode: 205,
            lang: "all",
            isNsfw: false,
            apkName: "tachiyomi-all.mangadex-v1.4.205.apk",
            iconUrl: iconUrl(lang: "all", name: "mangadex"),
            repoUrl: keiyoushiRepoUrl,
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: MangaDexSourceId.simplifiedChinese,
                    name: "MangaDex",
                    lang: "zh-Hans",
                    baseUrl: "https://mangadex.org",
                    className: "eu.kanade.tachiyomi.extension.all.mangadex.MangaDexFactory$ChineseSimplified",
                    multiSrcTemplate: "HttpSource (JSON API)",
                    popularPath: "/manga?order[followedCount]=desc",
                    latestPath: "/manga?order[latestUploadedChapter]=desc",
                    searchPath: "/manga?title={query}",
                    popularSelector: "json.data[*]",
                    chapterSelector: "json.data[*]",
                    pageSelector: "json.chapter.data[*]"
                ),
                ExtensionSourceDescriptor(
                    id: MangaDexSourceId.traditionalChinese,
                    name: "MangaDex",
                    lang: "zh-Hant",
                    baseUrl: "https://mangadex.org",
                    className: "eu.kanade.tachiyomi.extension.all.mangadex.MangaDexFactory$ChineseTraditional",
                    multiSrcTemplate: "HttpSource (JSON API)",
                    popularPath: "/manga?order[followedCount]=desc",
                    latestPath: "/manga?order[latestUploadedChapter]=desc",
                    searchPath: "/manga?title={query}",
                    popularSelector: "json.data[*]",
                    chapterSelector: "json.data[*]",
                    pageSelector: "json.chapter.data[*]"
                ),
                ExtensionSourceDescriptor(
                    id: MangaDexSourceId.english,
                    name: "MangaDex",
                    lang: "en",
                    baseUrl: "https://mangadex.org",
                    className: "eu.kanade.tachiyomi.extension.all.mangadex.MangaDexFactory$English",
                    multiSrcTemplate: "HttpSource (JSON API)",
                    popularPath: "/manga?order[followedCount]=desc",
                    latestPath: "/manga?order[latestUploadedChapter]=desc",
                    searchPath: "/manga?title={query}",
                    popularSelector: "json.data[*]",
                    chapterSelector: "json.data[*]",
                    pageSelector: "json.chapter.data[*]"
                ),
                ExtensionSourceDescriptor(
                    id: MangaDexSourceId.japanese,
                    name: "MangaDex",
                    lang: "ja",
                    baseUrl: "https://mangadex.org",
                    className: "eu.kanade.tachiyomi.extension.all.mangadex.MangaDexFactory$Japanese",
                    multiSrcTemplate: "HttpSource (JSON API)",
                    popularPath: "/manga?order[followedCount]=desc",
                    latestPath: "/manga?order[latestUploadedChapter]=desc",
                    searchPath: "/manga?title={query}",
                    popularSelector: "json.data[*]",
                    chapterSelector: "json.data[*]",
                    pageSelector: "json.chapter.data[*]"
                )
            ]
        ),
        // Live (`ZaimanhuaLiveEngine`): hosted in mainland China, so it works there without a proxy.
        ExtensionModel(
            name: "再漫画",
            pkgName: "eu.kanade.tachiyomi.extension.zh.zaimanhua",
            versionName: "1.6.1",
            versionCode: 106001,
            libVersion: 1.6,
            lang: "zh",
            apkName: "tachiyomi-zh.zaimanhua-v1.6.1.apk",
            iconUrl: iconUrl(lang: "zh", name: "zaimanhua"),
            repoUrl: keiyoushiRepoUrl,
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: zaimanhuaSourceId,
                    name: "再漫画",
                    lang: "zh",
                    baseUrl: ZaimanhuaLiveEngine.siteBase,
                    className: "eu.kanade.tachiyomi.extension.zh.zaimanhua.Zaimanhua",
                    multiSrcTemplate: "HttpSource (JSON API)",
                    popularPath: "/comic/rank/list?tag_id=0",
                    latestPath: "/comic/update/list/0/{page}",
                    searchPath: "/search/index?keyword={query}",
                    popularSelector: "json.data[*]",
                    chapterSelector: "json.data.data.chapters[*].data[*]",
                    pageSelector: "json.data.data.page_url_hd[*]"
                )
            ]
        ),
        ExtensionModel(
            name: "动漫之家（再漫画）", pkgName: "eu.kanade.tachiyomi.extension.zh.dmzj",
            versionName: "1", versionCode: 1, lang: "zh", apkName: "", installState: .installed,
            sources: [
                ExtensionSourceDescriptor(id: dmzjSourceId, name: "动漫之家（再漫画）", lang: "zh",
                    baseUrl: ZaimanhuaLiveEngine.siteBase, multiSrcTemplate: "HttpSource (JSON API)",
                    popularPath: "/comic/rank/list?tag_id=0", latestPath: "/comic/update/list/0/{page}",
                    searchPath: "/search/index?keyword={query}", popularSelector: "json.data[*]",
                    chapterSelector: "json.data.data.chapters[*].data[*]", pageSelector: "json.data.data.page_url_hd[*]")
            ]
        ),
        // Live (`DongmanLiveEngine`): LINE Webtoon's licensed Chinese edition, free on the web.
        ExtensionModel(
            name: "咚漫",
            pkgName: "eu.kanade.tachiyomi.extension.zh.dongmanmanhua",
            versionName: "1.6.0",
            versionCode: 106000,
            libVersion: 1.6,
            lang: "zh-Hans",
            apkName: "tachiyomi-zh.dongmanmanhua-v1.6.0.apk",
            iconUrl: iconUrl(lang: "zh", name: "dongmanmanhua"),
            repoUrl: keiyoushiRepoUrl,
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: dongmanSourceId,
                    name: "咚漫",
                    lang: "zh-Hans",
                    baseUrl: DongmanLiveEngine.siteBase,
                    className: "eu.kanade.tachiyomi.extension.zh.dongmanmanhua.DongmanManhua",
                    multiSrcTemplate: "ParsedHttpSource (HTML)",
                    popularPath: "/dailySchedule",
                    latestPath: "/dailySchedule?sortOrder=UPDATE&webtoonCompleteType=ONGOING",
                    searchPath: "/search?keyword={query}",
                    popularSelector: "div#dailyList .daily_section li a",
                    chapterSelector: "ul#_listUl li",
                    pageSelector: "div#_imageList > img"
                )
            ]
        ),
        ExtensionModel(
            name: "拷贝漫画",
            pkgName: "eu.kanade.tachiyomi.extension.zh.copymanga",
            versionName: "1.4.78",
            versionCode: 78,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.copymanga-v1.4.78.apk",
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1001,
                    name: "拷贝漫画",
                    lang: "zh",
                    baseUrl: "https://www.mangacopy.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.copymanga.CopyManga",
                    multiSrcTemplate: "HttpSource (JSON REST API)",
                    popularPath: "/comics?ordering=-popular",
                    latestPath: "/comics?ordering=-datetime_updated",
                    searchPath: "/search?q={query}",
                    popularSelector: "div.exemptComicItem, div.comic-card",
                    chapterSelector: "div.tab-pane ul li a",
                    pageSelector: "ul.comicContent-list li img"
                )
            ]
        ),
        ExtensionModel(
            name: "包子漫画",
            pkgName: "eu.kanade.tachiyomi.extension.zh.baozimh",
            versionName: "1.4.35",
            versionCode: 35,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.baozimh-v1.4.35.apk",
            iconUrl: iconUrl(lang: "zh", name: "baozimanhua"),
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1003,
                    name: "包子漫画",
                    lang: "zh",
                    baseUrl: "https://www.baozimh.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.baozimh.BaoziMH",
                    multiSrcTemplate: "ParsedHttpSource",
                    popularPath: "/classify?sort=popular",
                    latestPath: "/classify?sort=new",
                    searchPath: "/search?q={query}",
                    popularSelector: "div.comics-card",
                    chapterSelector: "div.comics-chapters a",
                    pageSelector: "ul.comic-contain img"
                )
            ]
        ),
        ExtensionModel(
            name: "漫画DB",
            pkgName: "eu.kanade.tachiyomi.extension.zh.manhuadb",
            versionName: "1.4.22",
            versionCode: 22,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.manhuadb-v1.4.22.apk",
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1004,
                    name: "漫画DB",
                    lang: "zh",
                    baseUrl: "https://www.manhuadb.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.manhuadb.ManhuaDB",
                    multiSrcTemplate: "ParsedHttpSource",
                    popularPath: "/manhua/list-popular.html",
                    latestPath: "/manhua/list-latest.html",
                    searchPath: "/search?q={query}",
                    popularSelector: "div.comic-book-unit",
                    chapterSelector: "ol.links-of-books li a",
                    pageSelector: "img.img-fluid.show-pic"
                )
            ]
        ),
        ExtensionModel(
            name: "Shonen Jump+",
            pkgName: "eu.kanade.tachiyomi.extension.ja.shonenjumpplus",
            versionName: "1.4.41",
            versionCode: 41,
            lang: "ja",
            isNsfw: false,
            apkName: "tachiyomi-ja.shonenjumpplus-v1.4.41.apk",
            installState: .installed,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1005,
                    name: "Shonen Jump+",
                    lang: "ja",
                    baseUrl: "https://shonenjumpplus.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.ja.shonenjumpplus.ShonenJumpPlus",
                    multiSrcTemplate: "GigaViewer",
                    popularPath: "/series",
                    latestPath: "/series/oneshot",
                    searchPath: "/search?q={query}",
                    popularSelector: "ul.series-list li",
                    chapterSelector: "ul.series-episode-list li a",
                    pageSelector: "div.page-area img.js-page-image"
                )
            ]
        ),
        ExtensionModel(
            name: "Asura Scans",
            pkgName: "eu.kanade.tachiyomi.extension.en.asurascans",
            versionName: "1.4.65",
            versionCode: 65,
            lang: "en",
            isNsfw: false,
            apkName: "tachiyomi-en.asurascans-v1.4.65.apk",
            installState: .hasUpdate,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1006,
                    name: "Asura Scans",
                    lang: "en",
                    baseUrl: "https://asuracomic.net",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.en.asurascans.AsuraScans",
                    multiSrcTemplate: "Madara",
                    popularPath: "/manga/?order=popular",
                    latestPath: "/manga/?order=update",
                    searchPath: "/?s={query}&post_type=wp-manga",
                    popularSelector: "div.bsx a",
                    chapterSelector: "div.eph-num a",
                    pageSelector: "div#readerarea img"
                )
            ]
        ),
        ExtensionModel(
            name: "动漫屋",
            pkgName: "eu.kanade.tachiyomi.extension.zh.dm5",
            versionName: "1.4.28",
            versionCode: 28,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.dm5-v1.4.28.apk",
            installState: .available,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1007,
                    name: "动漫屋",
                    lang: "zh",
                    baseUrl: "https://www.dm5.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.dm5.DM5",
                    multiSrcTemplate: "ParsedHttpSource",
                    popularPath: "/manhua-list-s2/",
                    latestPath: "/manhua-new/",
                    searchPath: "/search?title={query}",
                    popularSelector: "ul.mh-list li div.mh-item",
                    chapterSelector: "div#chapterlistload ul li a",
                    pageSelector: "div#cp_img img"
                )
            ]
        ),
        ExtensionModel(
            name: "快看漫画",
            pkgName: "eu.kanade.tachiyomi.extension.zh.kuaikanmanhua",
            versionName: "1.4.19",
            versionCode: 19,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.kuaikanmanhua-v1.4.19.apk",
            installState: .available,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1008,
                    name: "快看漫画",
                    lang: "zh",
                    baseUrl: "https://www.kuaikanmanhua.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.kuaikanmanhua.Kuaikanmanhua",
                    multiSrcTemplate: "HttpSource (JSON REST API)",
                    popularPath: "/v1/search/by_tag?since=0&count=20&f=3&tag=0",
                    latestPath: "/v1/search/by_tag?since=0&count=20&f=3&tag=19",
                    searchPath: "/s/result/{query}",
                    popularSelector: "json.data.hit[*]",
                    chapterSelector: "json.data.comics[*]",
                    pageSelector: "json.data.comic_info.comic_images[*]"
                )
            ]
        ),
        ExtensionModel(
            name: "哔哩哔哩漫画",
            pkgName: "eu.kanade.tachiyomi.extension.zh.bilibilimanga",
            versionName: "1.4.34",
            versionCode: 34,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.bilibilimanga-v1.4.34.apk",
            installState: .available,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1009,
                    name: "哔哩哔哩漫画",
                    lang: "zh",
                    baseUrl: "https://manga.bilibili.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.bilibilimanga.BilibiliManga",
                    multiSrcTemplate: "HttpSource (JSON REST API)",
                    popularPath: "/twirp/comic.v1.Comic/ClassPage",
                    latestPath: "/twirp/comic.v1.Comic/HomeUpdated",
                    searchPath: "/twirp/comic.v1.Comic/Search",
                    popularSelector: "json.data[*]",
                    chapterSelector: "json.data.ep_list[*]",
                    pageSelector: "json.data.images[*]"
                )
            ]
        ),
        ExtensionModel(
            name: "Colamanga",
            pkgName: "eu.kanade.tachiyomi.extension.zh.colamanga",
            versionName: "1.4.29",
            versionCode: 29,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.colamanga-v1.4.29.apk",
            installState: .available,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1010,
                    name: "Colamanga",
                    lang: "zh",
                    baseUrl: "https://www.colamanga.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.colamanga.Colamanga",
                    multiSrcTemplate: "SinMH",
                    popularPath: "/show?orderBy=dailyCount",
                    latestPath: "/show?orderBy=update",
                    searchPath: "/search?searchString={query}",
                    popularSelector: "li.fed-list-item",
                    chapterSelector: "div.all_data_list ul.fed-part-rows li a",
                    pageSelector: "div.mh_comicpic img"
                )
            ]
        ),
        ExtensionModel(
            name: "Bato.to",
            pkgName: "eu.kanade.tachiyomi.extension.all.batoto",
            versionName: "1.4.52",
            versionCode: 52,
            lang: "all",
            isNsfw: false,
            apkName: "tachiyomi-all.batoto-v1.4.52.apk",
            installState: .available,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1011,
                    name: "Bato.to",
                    lang: "zh",
                    baseUrl: "https://bato.to",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.all.batoto.BatoToZh",
                    multiSrcTemplate: "ParsedHttpSource",
                    popularPath: "/browse?langs=zh&sort=views_a",
                    latestPath: "/browse?langs=zh&sort=update",
                    searchPath: "/search?word={query}",
                    popularSelector: "div#series-list div.col",
                    chapterSelector: "div.episode-list div.main a",
                    pageSelector: "script:containsData(imgHttps)"
                ),
                ExtensionSourceDescriptor(
                    id: 10111,
                    name: "Bato.to",
                    lang: "en",
                    baseUrl: "https://bato.to",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.all.batoto.BatoToEn",
                    multiSrcTemplate: "ParsedHttpSource",
                    popularPath: "/browse?langs=en&sort=views_a",
                    latestPath: "/browse?langs=en&sort=update",
                    searchPath: "/search?word={query}",
                    popularSelector: "div#series-list div.col",
                    chapterSelector: "div.episode-list div.main a",
                    pageSelector: "script:containsData(imgHttps)"
                )
            ]
        ),
        ExtensionModel(
            name: "Manganato",
            pkgName: "eu.kanade.tachiyomi.extension.en.mangakakalot",
            versionName: "1.4.46",
            versionCode: 46,
            lang: "en",
            isNsfw: false,
            apkName: "tachiyomi-en.mangakakalot-v1.4.46.apk",
            installState: .available,
            sources: [
                ExtensionSourceDescriptor(
                    id: 1012,
                    name: "Manganato",
                    lang: "en",
                    baseUrl: "https://manganato.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.en.mangakakalot.Manganato",
                    multiSrcTemplate: "MangaBox",
                    popularPath: "/genre-all?type=topview",
                    latestPath: "/genre-all",
                    searchPath: "/search/story/{query}",
                    popularSelector: "div.content-genres-item",
                    chapterSelector: "ul.row-content-chapter li a",
                    pageSelector: "div.container-chapter-reader img"
                )
            ]
        ),
        ExtensionModel(
            name: "Komga",
            pkgName: "eu.kanade.tachiyomi.extension.all.komga",
            versionName: "1.4.48",
            versionCode: 48,
            lang: "all",
            isNsfw: false,
            apkName: "tachiyomi-all.komga-v1.4.48.apk",
            installState: .installed,
            sources: [
                // Upstream's first factory instance (`KomgaLiveEngine.instanceIds`); the address is the user's.
                ExtensionSourceDescriptor(
                    id: 4_508_733_312_114_627_536,
                    name: "Komga",
                    lang: "all",
                    baseUrl: "",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.all.komga.Komga",
                    multiSrcTemplate: "HttpSource (JSON REST API)",
                    popularPath: "/api/v1/series?sort=metadata.titleSort,asc",
                    latestPath: "/api/v1/series/latest",
                    searchPath: "/api/v1/series?search={query}",
                    popularSelector: "json.content[*]",
                    chapterSelector: "json.content[*]",
                    pageSelector: "json.pages[*]"
                )
            ]
        )
    ]
    // swiftlint:enable function_body_length

    static let trackers: [TrackerServiceInfo] = [
        TrackerServiceInfo(id: 1, name: "AniList", iconSystemName: "a.square.fill", brandColorHex: "#02A9FF", isLoggedIn: true, username: "demo_user", baseUrl: "https://anilist.co"),
        TrackerServiceInfo(id: 2, name: "MyAnimeList", iconSystemName: "m.square.fill", brandColorHex: "#2E51A2", isLoggedIn: true, username: "demo_user", baseUrl: "https://myanimelist.net"),
        TrackerServiceInfo(id: 3, name: "Bangumi", iconSystemName: "tv.fill", brandColorHex: "#F09199", isLoggedIn: true, username: "demo_user", baseUrl: "https://bgm.tv"),
        TrackerServiceInfo(id: 4, name: "MangaUpdates", iconSystemName: "chart.bar.doc.horizontal.fill", brandColorHex: "#F57C00", baseUrl: "https://www.mangaupdates.com"),
        TrackerServiceInfo(id: 5, name: "Kitsu", iconSystemName: "flame.fill", brandColorHex: "#FD755C", baseUrl: "https://kitsu.app"),
        TrackerServiceInfo(id: 6, name: "Komga", iconSystemName: "server.rack", brandColorHex: "#00897B", baseUrl: "http://127.0.0.1:25600")
    ]

    static func mangas(now: Date) -> [Manga] {
        [
            Manga(
                id: 101, source: 1001, url: "/manga/frieren", title: "葬送的芙莉莲",
                artist: "阿部司", author: "山田钟人",
                description: "打倒魔王的勇者辛美尔、僧侣海塔、矮人战士艾泽与精灵魔法使芙莉莲，在凯旋归来后迎来了50年一遇的流星雨。然而对于长寿的精灵而言，五十年不过转瞬即逝；在昔日同伴离世后，芙莉莲为了“真正理解人类”而再次踏上前往灵魂安眠之地（奥蕾欧尔）的旅途。",
                genre: ["奇幻", "冒险", "治愈", "剧情"], status: .ongoing,
                thumbnailUrl: "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx118586-CXKgWikBFQgS.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-1800), dateAdded: now.addingTimeInterval(-86400 * 30),
                notes: "周三更新，画风与分镜极佳，已同步 AniList 与 Bangumi。", readingModeOverride: .rightToLeft
            ),
            Manga(
                id: 102, source: 1001, url: "/manga/dungeon-meshi", title: "迷宫饭",
                artist: "九井谅子", author: "九井谅子",
                description: "莱欧斯一行人在迷宫深处挑战炎龙失败，妹妹法琳在将众人传送逃离前被炎龙吞入腹中。为了在法琳被消化前重返迷宫深处，身无分文的莱欧斯做出了惊人的决定——在迷宫里自给自足，把史莱姆、蛇尾鸡、走路菇乃至红龙统统做成美味佳肴！",
                genre: ["奇幻", "美食", "冒险", "群像"], status: .completed,
                thumbnailUrl: "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx86082-MXizJxzbijdd.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-7200), dateAdded: now.addingTimeInterval(-86400 * 45),
                updateStrategy: .onlyFetchOnce, notes: "", readingModeOverride: .rightToLeft
            ),
            Manga(
                id: 103, source: 1001, url: "/manga/witch-hat-atelier", title: "尖帽子的魔法工坊",
                artist: "白滨鸥", author: "白滨鸥",
                description: "生在普通裁缝家庭的少女可可一直向往着只有天选之人才能使用的魔法。直到某天，造访村庄的魔法师奇夫利在施法时被可可无意窥见——原来魔法并非与生俱来的奇迹，而是用特制墨水与画笔描绘出的魔法阵！",
                genre: ["奇幻", "魔法", "艺术", "冒险"], status: .ongoing,
                thumbnailUrl: "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx98263-kIeaTXrAbGkj.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-14400), dateAdded: now.addingTimeInterval(-86400 * 20),
                readingModeOverride: .rightToLeft
            ),
            Manga(
                id: 104, source: 1003, url: "/manga/dandadan", title: "胆大党",
                artist: "龙幸伸", author: "龙幸伸",
                description: "灵媒师家族出身的辣妹绫濑桃相信幽灵却不信外星人；沉迷神秘学的同班同学高仓健相信外星人却不信幽灵。两人打赌各自前往灵异隧道与废弃医院，却同时遭遇了超越常识的怪异危机！",
                genre: ["超自然", "热血", "科幻", "恋爱"], status: .ongoing,
                thumbnailUrl: "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx132029-prGF4gePdSKv.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-28800), dateAdded: now.addingTimeInterval(-86400 * 15),
                readingModeOverride: .rightToLeft
            ),
            Manga(
                id: 105, source: 1003, url: "/manga/blades-of-the-guardians", title: "镖人",
                artist: "许先哲", author: "许先哲",
                description: "大业三年，隋炀帝杨广残暴无道，民不聊生。行走于西域大漠的镖客刀马带着年幼的儿子小七，接下了一桩护送神秘面具人“知世郎”前往长安的千里护镖重任，庙堂与江湖的风暴由此席卷天下。",
                genre: ["武侠", "历史", "动作"], status: .ongoing,
                thumbnailUrl: "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx102796-wa9ZYchL991E.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-43200), dateAdded: now.addingTimeInterval(-86400 * 12),
                readingModeOverride: .webtoon
            ),
            // Live MangaDex entries (chapters & pages are fetched from api.mangadex.org on first open / update).
            Manga(
                id: 107, source: MangaDexSourceId.simplifiedChinese, url: "/manga/34f45c13-2b78-4900-8af2-d0bb551101f4",
                title: "异兽魔都", artist: "Hayashida Q", author: "Hayashida Q",
                genre: ["Seinen", "Action", "Comedy", "Horror", "Mystery"], status: .completed,
                thumbnailUrl: "https://uploads.mangadex.org/covers/34f45c13-2b78-4900-8af2-d0bb551101f4/54a405c8-c20b-475d-ae67-c8cf9d3b4aa6.jpg.512.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-3600 * 5), dateAdded: now.addingTimeInterval(-86400 * 10),
                updateStrategy: .onlyFetchOnce, initialized: false, readingModeOverride: .rightToLeft
            ),
            Manga(
                id: 108, source: MangaDexSourceId.simplifiedChinese, url: "/manga/b5b21ca1-bba5-4b9a-8cd1-6248f731650b",
                title: "終末的女武神", artist: "Ajichika", author: "Umemura Shinya, Fukui Takumi",
                genre: ["Seinen", "Action", "Martial Arts", "Survival"], status: .ongoing,
                thumbnailUrl: "https://uploads.mangadex.org/covers/b5b21ca1-bba5-4b9a-8cd1-6248f731650b/64235ab3-3595-47ea-b65a-457b828489c2.jpg.512.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-3600 * 9), dateAdded: now.addingTimeInterval(-86400 * 9),
                initialized: false, readingModeOverride: .rightToLeft
            ),
            Manga(
                id: 109, source: MangaDexSourceId.simplifiedChinese, url: "/manga/99b8eaeb-9041-4bfd-8eb7-d72addc88eb7",
                title: "女神的露天咖啡厅", artist: "Seo Kouji", author: "Seo Kouji",
                genre: ["Shounen", "Comedy", "Romance", "Harem"], status: .completed,
                thumbnailUrl: "https://uploads.mangadex.org/covers/99b8eaeb-9041-4bfd-8eb7-d72addc88eb7/738574de-d1d1-46fe-accc-85feefd47ad5.jpg.512.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-3600 * 12), dateAdded: now.addingTimeInterval(-86400 * 6),
                updateStrategy: .onlyFetchOnce, initialized: false, readingModeOverride: .rightToLeft
            )
        ]
    }

    static let mangaCategories: [Int64: [Int64]] = [
        101: [1, 2],
        102: [2],
        103: [1, 2],
        104: [1],
        105: [1, 3],
        107: [2],
        108: [1],
        109: [1]
    ]

    // MARK: - Library of builds without demo features

    /// MangaDex titles with many readable Chinese chapters that start at chapter 1 (safe-rated except the two
    /// headliners), most followed first. Picked from the MangaDex API on 2026-10-27; details, chapters and pages
    /// load live like the entries above.
    private struct MangaDexSeed {
        let source: Int64
        let uuid: String
        let title: String
        let author: String
        let artist: String
        let genre: [String]
        let status: MangaStatus
        let cover: String
        let readingMode: ReadingMode
        /// `categories` id; nil keeps the entry in the default category.
        let category: Int64?
    }

    private static let mangaDexSeeds: [MangaDexSeed] = [
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "789642f8-ca89-4e4e-8f7b-eee4d17ea08b", title: "滅鬼之刃", author: "Gotouge Koyoharu", artist: "Gotouge Koyoharu", genre: ["Historical", "Action", "Demons", "Comedy", "Martial Arts", "Adventure"], status: .completed, cover: "60530e72-f76f-45d5-b6f9-f95e05058fc3.png", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "a77742b1-befd-49a4-bff5-1ad4e6b0ef7b", title: "鏈鋸人", author: "Fujimoto Tatsuki", artist: "Fujimoto Tatsuki", genre: ["Award Winning", "Monsters", "Action", "Demons", "Comedy", "Horror"], status: .completed, cover: "6e518bd1-5f60-446b-8832-bfe6bf74834b.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "d8a959f7-648e-4c8d-8f23-f1f3f8e129f3", title: "一拳超人", author: "ONE", artist: "Murata Yuusuke", genre: ["Award Winning", "Sci-Fi", "Monsters", "Action", "Comedy", "Superhero"], status: .ongoing, cover: "d22cfde3-268a-48a3-b5ed-73772834764d.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "04c892b3-a202-46f5-ad11-0d433e712ab8", title: "帝乃三姐妹原来很好搞定", author: "Hirakawa Aya", artist: "Hirakawa Aya", genre: ["Romance", "Comedy", "Harem", "School Life"], status: .ongoing, cover: "63756802-4e2b-4a46-a27e-2ab2654247c0.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "1e03d257-f014-4f96-bc42-d28ed874ff1b", title: "骑士魔法", author: "Amazake-no Hisago", artist: "Katou Takuji", genre: ["Reincarnation", "Monsters", "Action", "Romance", "Comedy", "Mecha"], status: .completed, cover: "8126c281-f1ca-412a-9604-2187f05e23d7.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "58be6aa6-06cb-4ca5-bd20-f1392ce451fb", title: "四叶妹妹!", author: "Azuma Kiyohiko", artist: "Azuma Kiyohiko", genre: ["Award Winning", "Comedy", "Philosophical", "Slice of Life"], status: .onHiatus, cover: "ff8d4f70-1797-4036-8241-c63b2237254e.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "a72aa29f-62b6-4e67-8895-ab3bf9bb11d2", title: "面基对象是危险人物", author: "mii.m", artist: "mii.m", genre: ["Comedy", "Mafia", "Slice of Life"], status: .completed, cover: "3582f571-c636-4a99-9cdd-65b2c2640141.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "01e360bc-22da-4e86-bbb7-3ae1091a223b", title: "勇者再次启程", author: "Maki Akihisa", artist: "Yatsubo Miki", genre: ["Time Travel", "Monsters", "Action", "Demons", "Comedy", "Adventure"], status: .ongoing, cover: "072b7aec-5d4c-4019-8a9f-165e2e421e2d.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "f7d3a91a-f47a-43ce-9a2c-4da813b15eea", title: "我家碰太變成了人類這件事", author: "Hamada Kenji", artist: "Hamada Kenji", genre: ["Animals", "Comedy", "Fantasy", "Slice of Life"], status: .ongoing, cover: "17999fb5-51e7-4a89-af93-e798575bbbc4.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "acdbf57f-bf54-41b4-8d92-b3f3d14c852e", title: "想让“我爱你”游戏快点结束", author: "Doumoto Yuuki", artist: "Doumoto Yuuki", genre: ["Romance", "Comedy", "School Life"], status: .ongoing, cover: "431f703e-aeff-43af-a2bf-24f743a9cd17.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "b24d2c22-5b28-44d4-a77f-0e920cd960a6", title: "独狼女孩的单相思", author: "Honn Noshiori", artist: "Honn Noshiori", genre: ["Romance", "Comedy", "School Life", "Slice of Life"], status: .ongoing, cover: "8137bb4b-9a12-4420-a6e5-024fb72b3aaa.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "6233aed2-2f42-4308-a2b9-7d37b836cc33", title: "楠木同学高中出道失败了", author: "Mii Mitsuki", artist: "Mii Mitsuki", genre: ["Romance", "Comedy", "School Life", "Slice of Life"], status: .ongoing, cover: "9e0e7c5d-557b-4125-9854-70d268c49078.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "bc8f71a4-49d8-498b-a231-10faa0d53ab6", title: "星靈感應", author: "Ookuma Rasuko", artist: "Ookuma Rasuko", genre: ["Comedy", "Girls' Love", "4-Koma", "Drama", "School Life", "Slice of Life"], status: .ongoing, cover: "827e0ffd-f90e-4c7c-af57-faf1cb4312b5.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "ef96c21c-6838-43d1-9b6e-cb30546bba8c", title: "魂環", author: "Mizukami Satoshi", artist: "Mizukami Satoshi", genre: ["Reincarnation", "Sci-Fi", "Historical", "Psychological", "Ghosts", "Romance"], status: .completed, cover: "195e5d9f-46c0-4dd6-bced-259a3d889446.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "46596dea-95de-40e8-b2b8-4e63aa6acd1a", title: "轉生王女與天才千金的魔法革命", author: "Karasu Piero", artist: "Nadaka Harutsugu", genre: ["Reincarnation", "Action", "Romance", "Comedy", "Adventure", "Magic"], status: .completed, cover: "4490acd3-f9a1-4157-b16f-2d3c99530337.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "71b16e06-8c0d-42a3-b457-73cf55343bc0", title: "馬格梅爾深海水族館", author: "Sugishita Kiyomi", artist: "Sugishita Kiyomi", genre: ["Animals", "Slice of Life", "Mystery"], status: .ongoing, cover: "71ef1290-76f8-40b8-be4d-0191937322ce.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "34d1f553-fc45-417e-b314-28134942a539", title: "无意间向她告了白", author: "Gozen no Ryokucha", artist: "Ataru", genre: ["Romance", "Comedy", "School Life", "Slice of Life", "Adaptation"], status: .completed, cover: "ceeee860-decf-4170-9dee-2f2fa213df39.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "ae60aa84-3c58-40f1-935b-c7cdd1d5af6b", title: "与游戏中心的少女异文化交流的故事", author: "Yasuhara Hirokazu", artist: "Yasuhara Hirokazu", genre: ["Romance", "Comedy", "Video Games", "School Life", "Slice of Life"], status: .completed, cover: "3a39f96d-19e5-44ee-96aa-e7b1bf082f87.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "8e0da1d1-1018-47ca-a872-041f24876e2a", title: "因尾愛情。", author: "Yumeka Sumomo", artist: "Yumeka Sumomo", genre: ["Romance", "Philosophical", "Drama", "School Life", "Slice of Life", "Supernatural"], status: .completed, cover: "b2531297-dc2d-4bed-bd7f-ac26ffcc060f.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "5ebe52c0-995a-4a90-8f17-343e50b2f5a5", title: "一直以为是男孩子的孩子王其实是女孩子", author: "Cha Mirai", artist: "Cha Mirai", genre: ["Romance", "Comedy", "Web Comic", "Slice of Life", "Full Color"], status: .completed, cover: "f36fd9a6-3c61-49bc-9e55-ea0f39479663.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "6fac11a6-8b13-42bf-bed9-c194c15a261b", title: "不良退魔师蕾娜", author: "OTOSAMA", artist: "OTOSAMA", genre: ["Action", "Ghosts", "Comedy", "Drama", "Delinquents", "Supernatural"], status: .completed, cover: "e6db9d0a-dccd-4ac5-9932-e8332077c735.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "4535092c-36d9-49ce-982e-ad827d35a238", title: "离群鲛姬黛安娜", author: "Suama", artist: "Suama", genre: ["Romance", "Comedy", "Fantasy", "Monster Girls", "Slice of Life"], status: .completed, cover: "caca1f9f-9061-47be-a0da-246fe38f6d7b.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "b5f1d869-3333-45e2-9d68-463c3a49568a", title: "100天后跟阿宅交往的辣妹", author: "Shashaki", artist: "Shashaki", genre: ["Romance", "Comedy", "Web Comic", "Slice of Life", "Full Color", "Gyaru"], status: .cancelled, cover: "dcc37d85-bfd0-48b8-9297-61d893643c1d.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "6233e1c1-bd5e-424f-a317-61484640fc7e", title: "为行进小狗献上情书", author: "Tamasaki Tama", artist: "Tamasaki Tama", genre: ["Romance", "Girls' Love", "Military", "Drama", "School Life"], status: .completed, cover: "3675b43a-10f4-43f6-bf75-d3db303a5ef7.png", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "55ace2fb-e157-4d76-9e72-67c6bd762a39", title: "身為魔王的我娶了奴隸精靈為妻、該如何表白我的愛？", author: "Teshima Fuminori", artist: "Itagaki Hako", genre: ["Action", "Demons", "Romance", "Comedy", "Magic", "Drama"], status: .ongoing, cover: "d40cdb9f-76dd-4780-ae29-aa5893c0c89e.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "16dcfceb-4382-45f1-adb0-d57fc5ea0d06", title: "不知我的死亡flag将于何处停止", author: "Izumi", artist: "Otosu Mitsuya", genre: ["Award Winning", "Reincarnation", "Action", "Adventure", "Video Games", "Magic"], status: .ongoing, cover: "410068a9-c618-479c-bb39-817430514b0e.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "9dc08c5f-be0e-4fd3-800e-75a45321dcdf", title: "凜子與小白臉", author: "Nanase Hachi", artist: "Nanase Hachi", genre: ["Drama", "School Life", "Slice of Life"], status: .completed, cover: "416ef174-9f86-4427-9685-510b780da368.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.traditionalChinese, uuid: "df715a94-a013-4d5d-a7d5-f7f2f778d09d", title: "若愛在眼前", author: "Mikami Teren", artist: "Nanaji Yuuki", genre: ["Romance", "Girls' Love", "Harem", "School Life", "Slice of Life", "Supernatural"], status: .completed, cover: "428bd438-0ece-470f-ac91-aaded0fac82f.jpg", readingMode: .rightToLeft, category: 2),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "22484145-47ad-41f5-8d33-c0c2c2a3a39c", title: "高个子学妹和矮个子学长", author: "Inaba Shiro", artist: "Inaba Shiro", genre: ["Romance", "Comedy", "School Life", "Web Comic", "Slice of Life"], status: .ongoing, cover: "f5715ceb-6763-47b4-9376-24e4847c2b22.jpg", readingMode: .rightToLeft, category: 1),
        MangaDexSeed(source: MangaDexSourceId.simplifiedChinese, uuid: "a6a6fe8c-340b-428c-9220-8cd307b47475", title: "我的不起眼青梅竹马成为了S级勇者这档事", author: "Kotoha Toyonori", artist: "GUNP", genre: ["Action", "Adventure", "Magic", "Fantasy", "Supernatural", "Adaptation"], status: .completed, cover: "8488ce1e-e9e2-4994-8d1e-5ff6ddf9d009.jpg", readingMode: .rightToLeft, category: 2),
    ]

    /// Ids 201… follow the hand-written entries.
    static func mangaDexLibrary(now: Date) -> [Manga] {
        mangaDexSeeds.enumerated().map { index, seed in
            Manga(
                id: 201 + Int64(index), source: seed.source, url: "/manga/\(seed.uuid)", title: seed.title,
                artist: seed.artist, author: seed.author, genre: seed.genre, status: seed.status,
                thumbnailUrl: "https://uploads.mangadex.org/covers/\(seed.uuid)/\(seed.cover).512.jpg",
                favorite: true, lastUpdate: now.addingTimeInterval(-3600 * Double(index + 2)),
                dateAdded: now.addingTimeInterval(-86400 * Double(index / 3 + 1)),
                initialized: false, readingModeOverride: seed.readingMode
            )
        }
    }

    static var mangaDexLibraryCategories: [Int64: [Int64]] {
        Dictionary(uniqueKeysWithValues: mangaDexSeeds.enumerated().compactMap { index, seed in
            seed.category.map { (201 + Int64(index), [$0]) }
        })
    }

    /// 再漫画 titles from its rankings with at least 30 chapters readable without an account (suggestive-sounding
    /// ones skipped). Picked from the 再漫画 API on 2026-10-27; it is hosted in mainland China, so this shelf loads
    /// there without a proxy.
    private struct ZaimanhuaSeed {
        let comicId: Int
        let title: String
        let author: String
        let genre: [String]
        let status: MangaStatus
        let cover: String
        let readingMode: ReadingMode
        let category: Int64?
    }

    private static let zaimanhuaSeeds: [ZaimanhuaSeed] = [
        ZaimanhuaSeed(comicId: 19526, title: "大理寺日志", author: "RC", genre: ["历史", "职场", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/14/1002241141506407587.jpg", readingMode: .webtoon, category: 3),
        ZaimanhuaSeed(comicId: 64645, title: "北地之龙", author: "潇洒的转转笔", genre: ["冒险", "魔法", "奇幻"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/8/1044131881659931905.jpg", readingMode: .webtoon, category: 3),
        ZaimanhuaSeed(comicId: 20844, title: "我家大师兄脑子有坑", author: "剧象漫画", genre: ["颜艺", "搞笑", "仙侠"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/7/1002475871439187470.jpg", readingMode: .webtoon, category: 3),
        ZaimanhuaSeed(comicId: 27708, title: "崩坏3rd", author: "上海米哈游", genre: ["冒险", "热血"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/16/1017039361514025908.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 52785, title: "闪光的碎片", author: "三十七", genre: ["亲情", "治愈", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/3/1080211231590073854.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 72944, title: "血族Bloodline-圣魔虚像篇", author: "爱欧", genre: ["冒险", "魔法", "热血"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/15/1175612751709181189.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 85463, title: "咱们非要把漫画书店干黄吗？！", author: "孙烨&卢琪", genre: ["治愈", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/0/10531601782192766.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 61346, title: "果果与酱梓", author: "XIN", genre: ["ゆり", "奇幻", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/19/1097892591695295032.jpg", readingMode: .webtoon, category: 3),
        ZaimanhuaSeed(comicId: 60067, title: "灵墟游记", author: "墨小鱼漫画工作室", genre: ["冒险", "奇幻", "仙侠"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/3/1130223231633687529.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 51032, title: "辛巴狗日常篇", author: "七戒", genre: ["亲情", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/19/268485791573449751.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 67485, title: "我的怪物女友", author: "艾尔十六", genre: ["爱情", "校园", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/1/1051398611667805847.jpg", readingMode: .leftToRight, category: 1),
        ZaimanhuaSeed(comicId: 72313, title: "摸鱼小秦~开播了！", author: "Docurro", genre: ["亲情", "治愈", "搞笑"], status: .ongoing, cover: "https://images.zaimanhua.com/img/webpic/11/215177711702268868.jpg", readingMode: .leftToRight, category: 1),
    ]

    /// Ids 301… follow the MangaDex shelf.
    static func zaimanhuaLibrary(now: Date) -> [Manga] {
        zaimanhuaSeeds.enumerated().map { index, seed in
            Manga(
                id: 301 + Int64(index), source: zaimanhuaSourceId, url: "\(seed.comicId)", title: seed.title,
                author: seed.author, genre: seed.genre, status: seed.status, thumbnailUrl: seed.cover,
                favorite: true, lastUpdate: now.addingTimeInterval(-3600 * Double(index + 1)),
                dateAdded: now.addingTimeInterval(-86400 * Double(index / 3 + 1)),
                initialized: false, readingModeOverride: seed.readingMode
            )
        }
    }

    static var zaimanhuaLibraryCategories: [Int64: [Int64]] {
        Dictionary(uniqueKeysWithValues: zaimanhuaSeeds.enumerated().compactMap { index, seed in
            seed.category.map { (301 + Int64(index), [$0]) }
        })
    }

    /// Popular 咚漫 webtoons (its `/top` ranking, 2026-10-27) for the 条漫 category; details fill in on the first
    /// refresh like every uninitialized entry.
    private static let dongmanSeeds: [(path: String, title: String, cover: String)] = [
        ("/FANTASY/feirenzai/list?title_no=1804", "非人哉", "d10f7c87-43d4-407c-9c8c-4af8e39b5e72"),
        ("/BOY/wopeiyangdesjimen/list?title_no=1990", "我培养的S级们", "3dc60aff-3bec-434d-8cd3-8abaf7283eb3"),
        ("/BOY/xingjiandashi/list?title_no=2678", "星剑大师", "68d6fd21-5a56-4b8f-bcc6-0d9e4758c171"),
        ("/BOY/jianzunguilai/list?title_no=1639", "剑尊归来", "f772e379-34cb-4fc5-906c-2a76714251fe"),
        ("/BOY/sanliufanpaixueyuanshegncunji/list?title_no=2751", "三流反派的学院生存记", "1070a801-81c8-4fea-a502-e732c2a976f4"),
        ("/LOVE/dibaodebaizhou/list?title_no=2892", "地堡的白昼", "72a8eeb0-e232-4ab6-bf40-2fa90cf962d6")
    ]

    /// Ids 401… follow the 再漫画 shelf.
    static func dongmanLibrary(now: Date) -> [Manga] {
        dongmanSeeds.enumerated().map { index, seed in
            Manga(
                id: 401 + Int64(index), source: dongmanSourceId, url: DongmanLiveEngine.canonicalTitleUrl(seed.path), title: seed.title,
                thumbnailUrl: "https://cdn.dongmanmanhua.cn/\(seed.cover).jpg?x-oss-process=image/resize,w_400,limit_0",
                favorite: true, lastUpdate: now.addingTimeInterval(-3600 * Double(index + 3)),
                dateAdded: now.addingTimeInterval(-86400 * Double(index / 2 + 1)),
                initialized: false, readingModeOverride: .webtoon
            )
        }
    }

    static var dongmanLibraryCategories: [Int64: [Int64]] {
        Dictionary(uniqueKeysWithValues: dongmanSeeds.indices.map { (401 + Int64($0), [3]) })
    }

    /// The `MihonRepositoryStore.librarySeedVersion` that introduced a seed entry: 2 added the MangaDex shelf,
    /// 3 the 再漫画 and 咚漫 shelves. A library saved under an older version receives only the entries added since.
    static func seedVersion(of mangaId: Int64) -> Int {
        if (401..<401 + Int64(dongmanSeeds.count)).contains(mangaId) { return 3 }
        if (301..<301 + Int64(zaimanhuaSeeds.count)).contains(mangaId) { return 3 }
        if (201..<201 + Int64(mangaDexSeeds.count)).contains(mangaId) { return 2 }
        return 1
    }

    static func chapterSubtitle(for num: Int) -> String {
        let names = [
            "冒险的终点", "僧侣的诡计", "苍月草盛开之地", "魔法使的日常",
            "腐败的贤者", "红镜龙的巢穴", "英雄之剑", "北方诸国的寒冬",
            "休塔尔克的觉悟", "葬送的芙莉莲", "千年魔族的黄昏", "一级魔法使测验"
        ]
        return names[(num - 1) % names.count]
    }
}
