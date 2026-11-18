import Foundation
import MihonDomain

enum BundledWebsite: String, CaseIterable, Sendable {
    case baozi, copy, goda, manhuaren, vomic

    var rule: HTMLSourceRule {
        switch self {
        case .baozi:
            return HTMLSourceRule(name: "包子漫画", lang: "zh", baseUrl: "https://www.webmota.com",
                popular: "/classify?page={page}", latest: "/list/new", search: "/search?q={query}",
                cards: ".comics-card", cardTitle: ".comics-card__title", title: "h1.comics-detail__title",
                chapters: "#chapter-items .comics-chapters a, #chapters_other_list .comics-chapters a",
                oldestFirst: true, images: "amp-img.comic-contain__item")
        case .copy:
            return HTMLSourceRule(name: "拷贝漫画", lang: "zh", baseUrl: "https://www.mangacopy.com",
                popular: "/rank", latest: "/comics", search: "/search?q={query}",
                cards: ".exemptComicItem", title: ".comicParticulars-title-right h6",
                chapters: ".upLoop a[href*='/chapter/']", images: ".comicContent-list img", nsfw: true)
        case .goda:
            return HTMLSourceRule(name: "GoDa漫画", lang: "zh", baseUrl: "https://godamh.com",
                popular: "/hots/page/{page}", latest: "/newss/page/{page}", search: "/s/{query}?page={page}",
                cards: ".cardlist a", cardTitle: "h3", title: "main h1", chapters: "#mangachapters a",
                images: "#chapcontent img", next: "a[aria-label=下一頁]")
        case .manhuaren:
            return HTMLSourceRule(name: "漫画人", lang: "zh", baseUrl: "https://m.dm5.com",
                popular: "/manhua-rank/", latest: "/manhua-new/", search: "/search?title={query}",
                cards: ".rank-list-con a[title], .manga-list-2 li, .book-list li",
                cardTitle: ".rank-list-info-right-title, .manga-list-2-title, .book-list-info-title",
                title: ".detail-main-info-title", chapters: ".detail-list-select a.chapteritem, ul.detail-list-1 a[href^='/m']",
                chapterTitle: ".detail-list-2-info-title", oldestFirst: true, images: "#cp_img img")
        case .vomic:
            return HTMLSourceRule(name: "vomic", lang: "zh", baseUrl: "https://www.vomicmh.com",
                popular: "/", search: "/so/key/{query}/{page}",
                cards: "a[href^='/detail/']", cardTitle: ".title", title: ".detail .text-ellipsis",
                chapters: "a.chapter[href]", oldestFirst: true, images: "#myscroll img.myimage")
        }
    }

    // Web URLs are different from Android's app API identifiers. Keep their library entries distinct.
    var sourceId: Int64 { StableHash.positiveId("org.orihon.web." + rawValue) }
    var model: ExtensionModel { rule.extensionModel(id: sourceId, package: "org.orihon.web." + rawValue) }
}
