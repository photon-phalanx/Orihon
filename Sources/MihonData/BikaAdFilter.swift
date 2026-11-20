import WebKit

@MainActor
public enum BikaAdFilter {
    private static let rules = #"""
        [
          {"trigger":{"url-filter":".*","if-domain":["manhuabika.com"]},
           "action":{"type":"css-display-none","selector":"section[data-banner-motion]:has([data-home-banner-slide]), [data-category-ad], [data-detail-advertisement], [data-waterfall-ad], [data-chapter-end-ad], [data-reader-ad-group]"}},
          {"trigger":{"url-filter":"^https?://pica-ad-api\\.diwodiwo\\.xyz/","if-domain":["manhuabika.com"]},
           "action":{"type":"block"}}
        ]
        """#

    // Closing the site's modal through its button also releases the backdrop, focus and scroll lock.
    private static let closePopup = #"""
        if (location.origin === 'https://manhuabika.com') {
            const dismissAd = () => {
                if (location.pathname !== '/') return;
                const ad = document.querySelector('dialog[open] [data-home-popup-ads]');
                const panel = ad?.closest('[data-home-popup-panel]');
                const close = panel?.querySelector('button[aria-label="关闭广告"], button[aria-label="關閉廣告"], button[aria-label="Close ad" i]');
                close?.click();
            };
            new MutationObserver(dismissAd).observe(document, {
                childList: true, subtree: true, attributes: true, attributeFilter: ['open']
            });
            dismissAd();
        }
        """#

    static let ruleList = Task {
        try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "orihon.bika.ads.v1", encodedContentRuleList: rules)
    }

    static func install(in controller: WKUserContentController) async {
        if let list = await ruleList.value { controller.add(list) }
        controller.addUserScript(WKUserScript(source: closePopup, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
    }

    /// Called once per new web view. Wait for the rules before its first request so early ads are covered.
    public static func loadInitialPage(_ url: URL, in view: WKWebView) {
        let request = URLRequest(url: url)
        guard url.scheme == "https", url.host == BikaWebsite.accountURL.host else {
            view.load(request)
            return
        }
        let controller = view.configuration.userContentController
        Task { [weak view] in
            await install(in: controller)
            view?.load(request)
        }
    }
}
