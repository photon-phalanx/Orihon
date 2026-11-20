import SwiftUI
import MihonDomain
import MihonData
#if canImport(UIKit)
import UIKit
#endif
#if DEBUG
import OSLog
#endif

// MARK: - 1:1 Mihon Reader (pager / webtoon viewers, ReaderAppBars, ChapterNavigator, iPhone Duo book spread)

/// Items of the pager: chapter transitions bracket the pages (1:1 with upstream `ChapterTransition`).
private enum ReaderItemID {
    static let previousTransition = -1
    static let nextTransition = 1_000_000
    /// Past a chapter card: paging onto it opens that chapter, as upstream's pager runs on into the next one.
    static let previousEdge = -2
    static let nextEdge = 1_000_001
}

/// Where a chapter opens: its saved place (opening the reader), its first page (moving on into it) or its last
/// (paging back into it).
private enum ChapterOpening {
    case saved, first, last
}

public struct MangaReaderScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.mihonColors) private var colors
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    public let manga: Manga
    public var onClose: () -> Void

    @State private var currentChapter: Chapter
    @State private var pages: [Page] = []
    @State private var isLoadingPages = true
    @State private var openingPreview: (chapterId: Int64, page: Page, total: Int)?
    @State private var website: WebsiteLocation?
    @State private var showBikaAccount = false
    @State private var loadError: String?
    @State private var currentPage = 0
    @State private var pagerPosition: Int?
    @State private var webtoonPosition: Int?
    /// The slide pager is being dragged or is still moving (iOS 18 / macOS 15 report it). A chapter's edge is left
    /// only once it has come to rest there (`pendingEdge`), never under a finger.
    @State private var pagerScrolling = false
    @State private var pendingEdge: Int?
    /// A new slide pager counts as placed once it has been scrolled to its page: before that it may report items of
    /// its own (its first, an edge), which are not where the reader is.
    @State private var pagerPlaced = false
    #if DEBUG
    /// The pager's position as it moves (the bundle id / `Reader`), for driving it in the simulator.
    private static let log = Logger(subsystem: MihonAppIdentity.bundleId, category: "Reader")
    #endif
    /// Where the chapter being loaded opens (`ChapterOpening`).
    @State private var opening = ChapterOpening.saved
    /// The open chapter shows a page list fetched ahead (a switch past a card, the webtoon strip running on): its load
    /// only renews it where the reader is (`loadPages`).
    @State private var pagesFetchedAhead = false
    /// The transition card the last tap or key scrolled the webtoon strip to: one more press there switches chapters
    /// (the strip's top-anchored scroll position cannot tell when the last card is in view).
    @State private var webtoonShownTransition: Int?
    /// Page lists of the chapters next to the open one, fetched ahead (`preloadNeighbor`): past a card the pager shows
    /// the next chapter's first page (the previous one's last) and the webtoon strip runs on into the next chapter.
    @State private var neighborPages: [Int64: [Page]] = [:]
    @State private var neighborsLoading: Set<Int64> = []
    @State private var neighborImages = NeighborImages()
    /// The webtoon strip (`ReaderStripItem`): the open chapter, those scrolled through before it and the next once
    /// fetched. Built afresh (`stripToken`) only when a chapter opens another way.
    @State private var strip: [ReaderStripChapter] = []
    @State private var stripToken = 0
    /// The strip's end is in view (iOS 18 / macOS 15 report it).
    @State private var webtoonAtEnd = false
    /// The edge a tap or key is sliding the pager to: its chapter opens when the slide ends (`slideToEdge`).
    @State private var edgeSlide: Int?
    @State private var readingMode: ReadingMode
    @State private var didResolveMode = false
    @State private var menuVisible = false
    @State private var showSettings = false
    @State private var showReadingModeSelect = false
    @State private var showTapZones = false
    @State private var zoomScale: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var zoomAnchor: UnitPoint = .center
    @State private var preloader = MihonReaderPagePreloader()
    /// Reading progress waiting for the turn to settle (`scheduleProgress` / `flushProgress`).
    @State private var progress = ReaderProgressWriter()
    @State private var chapterLoadToken = 0
    /// The chapter "download ahead" already ran for (once per chapter, as upstream past a quarter of it).
    @State private var downloadedAheadFor: Int64?

    public init(manga: Manga, initialChapter: Chapter, onClose: @escaping () -> Void) {
        self.init(manga: manga, initialChapter: initialChapter, showMenuInitially: false, onClose: onClose)
    }

    init(manga: Manga, initialChapter: Chapter, showMenuInitially: Bool, onClose: @escaping () -> Void) {
        self.manga = manga
        self.onClose = onClose
        _currentChapter = State(initialValue: initialChapter)
        _readingMode = State(initialValue: manga.readingModeOverride == .defaultMode ? .rightToLeft : manga.readingModeOverride)
        _menuVisible = State(initialValue: showMenuInitially)
    }

    // MARK: Derived state

    private var isWebtoon: Bool { readingMode == .webtoon || readingMode == .continuousVertical }
    private var isRTL: Bool { readingMode == .rightToLeft }
    private var isVerticalPager: Bool { readingMode == .vertical }
    private var isZoomed: Bool { zoomScale > 1.01 }

    private func isSpreadEnabled(in size: CGSize) -> Bool {
        guard !isWebtoon, !isVerticalPager else { return false }
        switch store.duoDualPageBehavior {
        case .alwaysDualPage: return true
        case .singlePageOnly: return false
        case .autoWhenUnfolded:
            // Two pages side by side need a landscape-shaped screen (the unfolded Duo, an iPad on its side): a
            // portrait iPad is wide enough for two panes but not for two pages.
            return size.width > size.height
                && store.isUnfoldedDuo(viewportSize: size, horizontalSizeClass: horizontalSizeClass)
        }
    }

    /// The gap a spread leaves for the Duo's hinge; an iPad spread has none.
    private func hingeWidth(in size: CGSize) -> CGFloat {
        MihonRepositoryStore.hasHinge(viewportSize: size) ? CGFloat(store.duoHingeGutterWidth) : 0
    }

    /// `[[0], [1, 2], [3, 4] …]` with `shiftDoublePageCover`, `[[0, 1], [2, 3] …]` otherwise.
    private var spreads: [[Int]] {
        ReaderSpreads.pairs(pageCount: pages.count, shiftCover: store.shiftDoublePageCover)
    }

    /// A Duo spread turning like a printed book (`curlViewer`).
    private var isCurling: Bool {
        #if canImport(UIKit)
        return lastSpreadState && store.duoPageTurnStyle == .curl
        #else
        return false
        #endif
    }

    /// The chapters previous / next move through (upstream's reader chapter list: skipped read, filtered, duplicates).
    /// Fixed when the reader opens, as upstream builds it once: a chapter read meanwhile must not drop out of it.
    private var readingOrder: [Chapter] {
        guard let ids = sessionChapterIds else {
            return store.readerChapters(mangaId: manga.id, currentChapterId: currentChapter.id)
        }
        let byId = Dictionary((store.chaptersByManga[manga.id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    private var previousChapter: Chapter? {
        let order = readingOrder
        guard let idx = order.firstIndex(where: { $0.id == currentChapter.id }), idx > 0 else { return nil }
        return order[idx - 1]
    }

    private var nextChapter: Chapter? {
        let order = readingOrder
        guard let idx = order.firstIndex(where: { $0.id == currentChapter.id }), idx + 1 < order.count else { return nil }
        return order[idx + 1]
    }

    /// The open chapter's place in `readingOrder` (the webtoon strip's `ReaderStripChapter.order`).
    private var currentOrder: Int {
        readingOrder.firstIndex { $0.id == currentChapter.id } ?? 0
    }

    private var backgroundColor: Color {
        switch store.readerBackground {
        case .black: return .black
        case .darkGray: return Color(hex: 0x202125)
        case .white: return .white
        case .automatic: return colors.isDark ? .black : .white
        }
    }

    private func maxPixelSize(for size: CGSize) -> Int {
        Int(min(3072, max(size.width, size.height) * displayScale))
    }

    /// The size the current viewer decodes pages at. The preloader must use the same one: the cache keys include
    /// it, so a page warmed at another size is downloaded and decoded again.
    private func pageDecodeSize(in size: CGSize, spread: Bool) -> Int {
        if isWebtoon { return Int(min(2048, min(size.width, 900) * displayScale)) }
        return maxPixelSize(for: spread ? CGSize(width: size.width / 2, height: size.height) : size)
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { geo in
            let spread = isSpreadEnabled(in: geo.size)
            ZStack {
                backgroundColor.ignoresSafeArea()

                // Pages are laid out in the safe area (`geo.size`), so the viewer must not extend past it: a paging
                // scroll view pages by its own width, and on the iPhone Duo cover display (84 pt sensor bar on the
                // right) a wider viewport left every page offset by a sliver of the next one.
                viewer(size: geo.size, spread: spread, insets: geo.safeAreaInsets)
                    .clipped()

                if !menuVisible && store.showPageNumber && !pages.isEmpty {
                    VStack {
                        Spacer()
                        ReaderPageIndicator(text: pageIndicatorText(spread: spread))
                            .padding(.bottom, 8)
                    }
                    .allowsHitTesting(false)
                }

                // The app's snackbar sits under this full-screen cover: show messages (reading mode, a saved page) here.
                VStack {
                    Spacer()
                    if let message = store.statusBannerMessage {
                        MihonSnackbar(message: message)
                            .padding(.bottom, menuVisible ? 140 : 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id(message)
                    }
                }
                .allowsHitTesting(false)
                .animation(.spring(duration: 0.3, bounce: 0.1), value: store.statusBannerMessage)

                if showTapZones {
                    ReaderNavigationOverlay(mode: store.readerTapZone, isRTL: tapsRightToLeft, isWebtoon: isWebtoon)
                        .onTapGesture { withAnimation { showTapZones = false } }
                        .transition(.opacity)
                }

                ReaderAppBars(
                    visible: menuVisible,
                    spread: spread,
                    size: geo.size,
                    hingeWidth: hingeWidth(in: geo.size),
                    insets: geo.safeAreaInsets,
                    mangaTitle: manga.title,
                    chapterTitle: currentChapter.name,
                    bookmarked: currentChapter.bookmark,
                    isRTL: isRTL && !isWebtoon,
                    currentPage: currentPage + 1,
                    totalPages: max(1, pages.count),
                    readingMode: readingMode,
                    cropEnabled: store.cropBorders,
                    enabledPrevious: previousChapter != nil,
                    enabledNext: nextChapter != nil,
                    onBack: close,
                    onToggleBookmark: toggleBookmark,
                    onPreviousChapter: { if let previousChapter { switchToChapter(previousChapter) } },
                    onNextChapter: { if let nextChapter { switchToChapter(nextChapter) } },
                    onPageChange: { jump(to: $0 - 1, spread: spread) },
                    onClickReadingMode: { showReadingModeSelect = true },
                    onToggleSpread: { toggleSpread(spread) },
                    onToggleCrop: { store.cropBorders.toggle() },
                    onClickSettings: { showSettings = true }
                )
            }
            .environment(\.mihonReaderMangaId, manga.id)
            .onChange(of: spread) { _, isSpread in
                syncPositions(spread: isSpread)
            }
            .onChange(of: readingMode) { _, _ in
                resetZoom()
                if isWebtoon { resetStrip() }
                syncPositions(spread: isSpreadEnabled(in: geo.size))
            }
            .onChange(of: pagerScrolling) { _, scrolling in
                #if DEBUG
                Self.log.notice("scrolling \(scrolling)")
                #endif
                guard !scrolling, let edge = pendingEdge else { return }
                pendingEdge = nil
                DispatchQueue.main.async { leaveEdge(edge) }
            }
            .onChange(of: pagerPosition) { _, position in
                handlePagerPosition(position, spread: spread, size: geo.size)
            }
            .onChange(of: webtoonPosition) { _, position in
                handleStripPosition(position, size: geo.size)
            }
            .onChange(of: webtoonAtEnd) { _, atEnd in
                #if DEBUG
                Self.log.notice("webtoon end \(atEnd)")
                #endif
                if atEnd { reachedStripEnd(size: geo.size) }
            }
            .task(id: chapterLoadToken) {
                await loadPages(size: geo.size)
            }
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(mangaId: manga.id, readingMode: $readingMode)
                .environment(store)
                .mihonSheetChrome(colors)
        }
        .sheet(isPresented: $showReadingModeSelect) {
            ReadingModeSelectSheet(mangaId: manga.id, readingMode: $readingMode)
                .environment(store)
                .mihonSheetChrome(colors, detents: [.medium, .large])
        }
        .sheet(isPresented: $showBikaAccount, onDismiss: { chapterLoadToken += 1 }) {
            BikaAccountSheet { showBikaAccount = false }
                .onAppear { BikaWebsite.beginAccountEditing() }
                .onDisappear { BikaWebsite.endAccountEditing() }
        }
        .sheet(item: $website, onDismiss: { chapterLoadToken += 1 }) { location in
            WebsiteSessionSheet(url: location.url)
        }
        .onAppear {
            if sessionChapterIds == nil {
                sessionChapterIds = store.readerChapters(mangaId: manga.id, currentChapterId: currentChapter.id).map(\.id)
            }
            if !didResolveMode {
                didResolveMode = true
                let override = store.manga(id: manga.id)?.readingModeOverride ?? manga.readingModeOverride
                let resolved = override == .defaultMode ? store.defaultReadingMode : override
                readingMode = resolved == .defaultMode ? .rightToLeft : resolved
                showTapZones = store.showTapZonesOverlayOnLaunch
            }
            setIdleTimerDisabled(store.keepScreenOn)
        }
        .onDisappear {
            flushProgress()
            setIdleTimerDisabled(false)
            Task { await preloader.cancelAll() }
            store.deletePendingReadChapters()
        }
        // iOS goes active → inactive → background on the way out and back through inactive on return.
        .onChange(of: scenePhase) { old, phase in
            if old == .active {
                // Leaving may end the app: the page reached is written.
                holdCurrentPage()
                flushProgress()
            }
            if phase == .background {
                // And on disk before the app is suspended.
                flushProgress()
                store.saveNow()
            }
            if phase == .active || old == .background {
                // Time away is not reading time.
                progress.lastWrite = Date()
            }
        }
        #if DEBUG
        // Profiling without touching the screen: `MIHON_READER_AUTOFLIP=<pages>` turns that many pages, one every
        // `MIHON_READER_AUTOFLIP_INTERVAL` seconds (0.8 by default), once the first page has loaded.
        .task {
            let environment = ProcessInfo.processInfo.environment
            guard let requestedCount = environment["MIHON_READER_AUTOFLIP"].flatMap(Int.init), requestedCount > 0 else { return }
            let count = min(requestedCount, 500)
            let requested = environment["MIHON_READER_AUTOFLIP_INTERVAL"].flatMap(Double.init) ?? 0.8
            let interval = requested.isFinite ? min(10, max(0.1, requested)) : 0.8
            while pages.isEmpty, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // `MIHON_READER_AUTOFLIP_MODE=swipe` (or `swipe-back`): the pager's position moves on (back) as a swipe
            // moves it, past the chapter cards too, instead of the tap zones' `moveForward`.
            let mode = environment["MIHON_READER_AUTOFLIP_MODE"]
            let swipeStep = mode == "swipe" ? 1 : mode == "swipe-back" ? -1 : 0
            for _ in 0..<count {
                if Task.isCancelled { break }
                if swipeStep != 0, !isWebtoon {
                    let ids = pagerItemIds(spread: lastSpreadState)
                    if let at = ids.firstIndex(of: pagerPosition ?? .min), ids.indices.contains(at + swipeStep) {
                        withAnimation(.easeInOut(duration: 0.3)) { pagerPosition = ids[at + swipeStep] }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    continue
                }
                moveForward()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        #endif
        #if os(iOS)
        .statusBarHidden(!menuVisible)
        .persistentSystemOverlays(menuVisible ? .automatic : .hidden)
        #endif
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { tapDirection(left: true); return .handled }
        .onKeyPress(.rightArrow) { tapDirection(left: false); return .handled }
        .onKeyPress(.upArrow) { moveBackward(); return .handled }
        .onKeyPress(.downArrow) { moveForward(); return .handled }
        .onKeyPress(.space) { moveForward(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    // MARK: Viewers

    @ViewBuilder
    private func viewer(size: CGSize, spread: Bool, insets: EdgeInsets) -> some View {
        if isLoadingPages && pages.isEmpty {
            if !spread, let preview = openingPreview, preview.chapterId == currentChapter.id {
                MangaPageImageView(page: preview.page, mangaTitle: manga.title, chapterTitle: currentChapter.name,
                    totalPages: preview.total, cropBorders: store.cropBorders, colorFilter: store.colorFilter,
                    maxPixelSize: pageDecodeSize(in: size, spread: false))
            } else {
                MihonCircularProgress(color: .white.opacity(0.9), trackColor: .white.opacity(0.15))
            }
        } else if let loadError, pages.isEmpty {
            VStack(spacing: 16) {
                Text(loadError)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                if manga.source == BikaWebsite.sourceId {
                    Button("登录哔咔账号") { showBikaAccount = true }
                } else if let url = store.websiteURL(sourceId: manga.source, path: currentChapter.url) {
                    Button("打开源站") { website = WebsiteLocation(url: url) }
                }
                Button("重试") { chapterLoadToken += 1 }
                    .buttonStyle(MihonButtonStyle(.filled))
            }
            .padding(32)
        } else if isWebtoon {
            webtoonViewer(size: size)
        } else {
            pagerViewer(size: size, spread: spread, insets: insets)
        }
    }

    /// The pager. A Duo spread turns like a printed book (`DuoPageTurnStyle.curl`, iOS) or slides; single pages slide.
    /// Either way the hinge holds still over the spine while the pages move under it.
    @ViewBuilder
    private func pagerViewer(size: CGSize, spread: Bool, insets: EdgeInsets) -> some View {
        Group {
            #if canImport(UIKit)
            if spread && store.duoPageTurnStyle == .curl {
                curlViewer(size: size, insets: insets)
            } else {
                slidePagerViewer(size: size, spread: spread, insets: insets)
            }
            #else
            slidePagerViewer(size: size, spread: spread, insets: insets)
            #endif
        }
        .overlay(alignment: .topLeading) {
            let hinge = spread ? hingeWidth(in: size) : 0
            if hinge > 0 {
                DuoHingeView(width: hinge)
                    .frame(height: size.height)
                    .offset(x: DuoSplit(width: size.width, hinge: hinge, insets: insets).leading)
                    .allowsHitTesting(false)
            }
        }
    }

    #if canImport(UIKit)
    /// The Duo spread as a printed book (`DuoPageCurlView`): its spine sits on the hinge, and the reader's position
    /// (`pagerPosition`: the chapter cards and the spreads) is what it shows and what a turn by hand moves.
    private func curlViewer(size: CGSize, insets: EdgeInsets) -> some View {
        let hinge = hingeWidth(in: size)
        let fold = DuoSplit(width: size.width, hinge: hinge, insets: insets).leading + hinge / 2
        let half = max(0, min(fold, size.width - fold))
        let layout = DuoBookLayout(
            pageCount: pages.count,
            shiftCover: store.shiftDoublePageCover,
            rightToLeft: isRTL != store.invertDoublePageOrder
        )
        let pixelSize = pageDecodeSize(in: size, spread: true)
        // Everything the pages show: read here, so the reader follows these settings, and handed over, so the pages
        // are rebuilt when it changes and not on every render (a pinch renders every frame).
        let contentKey = [
            "\(currentChapter.id)", "\(pages.count)", "\(pixelSize)", "\(store.cropBorders)", "\(store.showDuoSpineShadow)",
            String(describing: store.colorFilter), store.readerBackground.rawValue,
            "\(previousChapter?.id ?? -1)", "\(nextChapter?.id ?? -1)",
            // The sheets past the cards show the neighbouring chapters once fetched.
            "\(previousChapter.flatMap { neighborPages[$0.id]?.count } ?? -1)",
            "\(nextChapter.flatMap { neighborPages[$0.id]?.count } ?? -1)"
        ].joined(separator: "|")
        return DuoPageCurlView(
            layout: layout,
            layoutToken: chapterLoadToken,
            readingSpread: curlReadingSpread(pagerPosition),
            allowsTurning: !isZoomed,
            doubleTapZooms: store.doubleTapToZoom,
            contentKey: contentKey,
            page: { slot, isLeft in AnyView(curlPage(slot, isLeft: isLeft, pixelSize: pixelSize)) },
            onTurn: { reading in pagerPosition = pagerPosition(forCurlReading: reading) },
            onTurnPastCard: { forward in
                if forward, let nextChapter {
                    switchToChapter(nextChapter)
                    return true
                }
                if !forward, let previousChapter {
                    switchToChapter(previousChapter, atEnd: true)
                    return true
                }
                return false
            },
            onTap: { location, _ in
                handleTap(at: CGPoint(x: location.x + fold - half, y: location.y), size: size, spread: true)
            },
            onDoubleTap: { location, _ in
                toggleZoom(at: CGPoint(x: location.x + fold - half, y: location.y), size: size)
            },
            onSwipeDown: { if !isZoomed { close() } }
        )
        .frame(width: 2 * half, height: size.height)
        .padding(.leading, fold - half)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .modifier(ZoomTransform(active: true, scale: zoomScale, offset: zoomOffset, anchor: zoomAnchor))
        .simultaneousGesture(magnifyGesture(size: size))
        .simultaneousGesture(panGesture, including: isZoomed ? .all : .subviews)
        .onAppear {
            lastSpreadState = true
            if pagerPosition == nil { pagerPosition = spreads.firstIndex { $0.contains(currentPage) } ?? 0 }
        }
    }

    /// The curl's reading spread for the reader's position: 0 the previous chapter's card, then the spreads, then
    /// the next chapter's card.
    private func curlReadingSpread(_ position: Int?) -> Int {
        switch position {
        case ReaderItemID.previousTransition, ReaderItemID.previousEdge: return 0
        case ReaderItemID.nextTransition, ReaderItemID.nextEdge: return spreads.count + 1
        // Just unfolded, the position still counts single pages: the spread holding the page on screen.
        case let position? where lastSpreadState: return min(max(0, position), max(0, spreads.count - 1)) + 1
        default: return (spreads.firstIndex { $0.contains(currentPage) } ?? 0) + 1
        }
    }

    private func pagerPosition(forCurlReading reading: Int) -> Int {
        if reading <= 0 { return ReaderItemID.previousTransition }
        if reading > spreads.count { return ReaderItemID.nextTransition }
        return reading - 1
    }

    /// One face of a sheet: a page against the spine, a chapter card, or blank paper. Hosted by UIKit, so it is
    /// handed what the reader's own environment would give it.
    @ViewBuilder
    private func curlPage(_ slot: DuoBookLayout.Slot, isLeft: Bool, pixelSize: Int) -> some View {
        ZStack(alignment: isLeft ? .trailing : .leading) {
            backgroundColor
            switch slot {
            case .page(let index) where index < pages.count:
                MangaPageImageView(
                    page: pages[index],
                    mangaTitle: manga.title,
                    chapterTitle: currentChapter.name,
                    totalPages: pages.count,
                    cropBorders: store.cropBorders,
                    colorFilter: store.colorFilter,
                    maxPixelSize: pixelSize
                )
                .overlay(alignment: isLeft ? .trailing : .leading) {
                    if store.showDuoSpineShadow { DuoSpineShadow(isLeftScreen: isLeft) }
                }
            case .previousChapter:
                ChapterTransitionView(isNext: false, current: currentChapter, target: previousChapter, compact: true, showsButton: false) {}
            case .nextChapter:
                ChapterTransitionView(isNext: true, current: currentChapter, target: nextChapter, compact: true, showsButton: false) {}
            case .chapterEdge(let next):
                // Past a card: that chapter's spread there, which it opens on as the turn ends.
                if let edge = curlEdgePage(next: next, isLeft: isLeft) {
                    MangaPageImageView(
                        page: edge.page,
                        mangaTitle: manga.title,
                        chapterTitle: edge.chapter.name,
                        totalPages: edge.count,
                        cropBorders: store.cropBorders,
                        colorFilter: store.colorFilter,
                        maxPixelSize: pixelSize
                    )
                    .overlay(alignment: isLeft ? .trailing : .leading) {
                        if store.showDuoSpineShadow { DuoSpineShadow(isLeftScreen: isLeft) }
                    }
                }
            default:
                EmptyView()
            }
        }
        .environment(store)
        .environment(\.mihonColors, colors)
        .environment(\.mihonReaderMangaId, manga.id)
    }

    /// The page on one side of the sheet past a card: the neighbouring chapter's opening spread, once fetched ahead.
    private func curlEdgePage(next: Bool, isLeft: Bool) -> (page: Page, chapter: Chapter, count: Int)? {
        guard let chapter = next ? nextChapter : previousChapter,
              let neighbor = neighborPages[chapter.id], !neighbor.isEmpty else { return nil }
        let layout = DuoBookLayout(
            pageCount: neighbor.count,
            shiftCover: store.shiftDoublePageCover,
            rightToLeft: isRTL != store.invertDoublePageOrder
        )
        let spread = layout.openingSpread(fromStart: next)
        guard case .page(let index) = isLeft ? spread.left : spread.right, neighbor.indices.contains(index) else { return nil }
        return (neighbor[index], chapter, neighbor.count)
    }
    #endif

    /// Pager viewer (L2R / R2L / vertical) and the Duo spread's slide: one native paging scroll view.
    private func slidePagerViewer(size: CGSize, spread: Bool, insets: EdgeInsets) -> some View {
        let itemIds = pagerItemIds(spread: spread)
        let ordered = isRTL && !isVerticalPager ? Array(itemIds.reversed()) : itemIds
        let axis: Axis.Set = isVerticalPager ? .vertical : .horizontal
        let pixelSize = pageDecodeSize(in: size, spread: spread)

        return ScrollViewReader { proxy in
            ScrollView(axis, showsIndicators: false) {
                pagerStack(vertical: isVerticalPager) {
                    ForEach(ordered, id: \.self) { itemId in
                        pagerItem(itemId: itemId, spread: spread, size: size, insets: insets, pixelSize: pixelSize)
                            .frame(width: size.width, height: size.height)
                            .modifier(PageTurnTransition(enabled: spread && store.duoPageTurnEffect))
                            .id(itemId)
                    }
                }
            }
            .modifier(ReaderPaging(vertical: isVerticalPager))
            .scrollPosition(id: $pagerPosition, anchor: placementAnchor)
            .modifier(ScrollActivity(isScrolling: $pagerScrolling))
            .scrollDisabled(isZoomed)
            .simultaneousGesture(magnifyGesture(size: size))
            .simultaneousGesture(panGesture, including: isZoomed ? .all : .subviews)
            .simultaneousGesture(dismissGesture, including: isZoomed || isVerticalPager ? .subviews : .all)
            .gesture(tapGestures(size: size, spread: spread))
            .onAppear {
                // A pager torn down mid-scroll never reported coming to rest.
                pagerScrolling = false
                pagerPlaced = false
                pendingEdge = nil
                // A freshly created paging ScrollView ignores the binding's initial value; position it explicitly.
                let target = spread ? (spreads.firstIndex { $0.contains(currentPage) } ?? 0) : currentPage
                lastSpreadState = spread
                pagerPosition = target
                proxy.scrollTo(target, anchor: placementAnchor ?? .center)
                DispatchQueue.main.async {
                    proxy.scrollTo(target, anchor: placementAnchor ?? .center)
                    if pagerPosition == ReaderItemID.previousEdge || pagerPosition == ReaderItemID.nextEdge {
                        pagerPosition = target
                    }
                    pagerPlaced = true
                }
            }
        }
        // Recreate the pager whenever its item space changes (pages ↔ spreads, axis, direction, chapter).
        .id("pager-\(spread)-\(readingMode.rawValue)-\(currentChapter.id)-\(pages.count)")
    }

    /// Where the slide pager aligns the item it is placed on.
    private var placementAnchor: UnitPoint? { isVerticalPager ? .top : nil }

    @ViewBuilder
    private func pagerStack<Content: View>(vertical: Bool, @ViewBuilder content: () -> Content) -> some View {
        // The target layout is the stack itself: on the `if` around it, a swipe set the position to nil.
        if vertical {
            LazyVStack(spacing: 0, content: content)
                .scrollTargetLayout()
        } else {
            LazyHStack(spacing: 0, content: content)
                .scrollTargetLayout()
        }
    }

    /// In a spread a chapter card is a page of it, never across the hinge: the next card where the page after the
    /// last would go, the previous one where the page before the first would (as `DuoBookLayout` places them).
    @ViewBuilder
    private func chapterCard<Card: View>(
        isNext: Bool, spread: Bool, size: CGSize, insets: EdgeInsets, @ViewBuilder card: () -> Card
    ) -> some View {
        if spread {
            let hinge = hingeWidth(in: size)
            let split = DuoSplit(width: size.width, hinge: hinge, insets: insets)
            let onLeft = isNext != (isRTL != store.invertDoublePageOrder)
            HStack(spacing: 0) {
                Group { if onLeft { card() } else { Color.clear } }
                    .frame(width: split.leading)
                Color.clear.frame(width: hinge)
                Group { if onLeft { Color.clear } else { card() } }
                    .frame(width: split.trailing)
            }
        } else {
            card()
        }
    }

    /// The chapter cards and, past each card with a chapter behind it, an edge that opens that chapter (with none,
    /// the card is the end and the pager bounces).
    private func pagerItemIds(spread: Bool) -> [Int] {
        let count = spread ? spreads.count : pages.count
        return (previousChapter == nil ? [] : [ReaderItemID.previousEdge]) + [ReaderItemID.previousTransition]
            + Array(0..<count)
            + [ReaderItemID.nextTransition] + (nextChapter == nil ? [] : [ReaderItemID.nextEdge])
    }

    @ViewBuilder
    private func pagerItem(itemId: Int, spread: Bool, size: CGSize, insets: EdgeInsets, pixelSize: Int) -> some View {
        let isCurrent = itemId == pagerPosition
        if itemId == ReaderItemID.previousEdge || itemId == ReaderItemID.nextEdge {
            // Shown only while paging past a card: the chapter there opens as it lands (`handlePagerPosition`).
            neighborPreview(next: itemId == ReaderItemID.nextEdge, spread: spread, size: size, insets: insets, pixelSize: pixelSize)
        } else if itemId == ReaderItemID.previousTransition {
            chapterCard(isNext: false, spread: spread, size: size, insets: insets) {
                ChapterTransitionView(isNext: false, current: currentChapter, target: previousChapter) {
                    if let previousChapter { switchToChapter(previousChapter, atEnd: true) }
                }
            }
        } else if itemId == ReaderItemID.nextTransition {
            chapterCard(isNext: true, spread: spread, size: size, insets: insets) {
                ChapterTransitionView(isNext: true, current: currentChapter, target: nextChapter) {
                    if let nextChapter { switchToChapter(nextChapter) }
                }
            }
        } else if spread {
            let indices = itemId < spreads.count ? spreads[itemId] : []
            DuoBookSpreadView(
                pages: indices.map { pages[$0] },
                isRTL: isRTL != store.invertDoublePageOrder,
                isCoverSpread: store.shiftDoublePageCover && indices == [0],
                hingeWidth: hingeWidth(in: size),
                insets: insets,
                showSpineShadow: store.showDuoSpineShadow,
                mangaTitle: manga.title,
                chapterTitle: currentChapter.name,
                totalPages: pages.count,
                cropBorders: store.cropBorders,
                colorFilter: store.colorFilter,
                maxPixelSize: pixelSize
            )
            .modifier(ZoomTransform(active: isCurrent, scale: zoomScale, offset: zoomOffset, anchor: zoomAnchor))
        } else if itemId < pages.count {
            MangaPageImageView(
                page: pages[itemId],
                mangaTitle: manga.title,
                chapterTitle: currentChapter.name,
                totalPages: pages.count,
                cropBorders: store.cropBorders,
                colorFilter: store.colorFilter,
                maxPixelSize: pixelSize
            )
            .modifier(ReaderScaleTypeModifier(scaleType: store.readerScaleType, size: size))
            .modifier(ZoomTransform(active: isCurrent, scale: zoomScale, offset: zoomOffset, anchor: zoomAnchor))
        }
    }

    /// What the pager shows past a card: the next chapter's first page or spread (the previous one's last), fetched
    /// ahead, which that chapter opens on once the pager comes to rest there; blank until fetched.
    @ViewBuilder
    private func neighborPreview(next: Bool, spread: Bool, size: CGSize, insets: EdgeInsets, pixelSize: Int) -> some View {
        if let chapter = next ? nextChapter : previousChapter, let neighbor = neighborPages[chapter.id], !neighbor.isEmpty {
            if spread {
                let indices = ReaderSpreads.opening(pageCount: neighbor.count, shiftCover: store.shiftDoublePageCover, fromStart: next)
                DuoBookSpreadView(
                    pages: indices.map { neighbor[$0] },
                    isRTL: isRTL != store.invertDoublePageOrder,
                    isCoverSpread: store.shiftDoublePageCover && indices == [0],
                    hingeWidth: hingeWidth(in: size),
                    insets: insets,
                    showSpineShadow: store.showDuoSpineShadow,
                    mangaTitle: manga.title,
                    chapterTitle: chapter.name,
                    totalPages: neighbor.count,
                    cropBorders: store.cropBorders,
                    colorFilter: store.colorFilter,
                    maxPixelSize: pixelSize
                )
            } else {
                MangaPageImageView(
                    page: next ? neighbor[0] : neighbor[neighbor.count - 1],
                    mangaTitle: manga.title,
                    chapterTitle: chapter.name,
                    totalPages: neighbor.count,
                    cropBorders: store.cropBorders,
                    colorFilter: store.colorFilter,
                    maxPixelSize: pixelSize
                )
                .modifier(ReaderScaleTypeModifier(scaleType: store.readerScaleType, size: size))
            }
        } else {
            Color.clear
        }
    }

    /// Webtoon / continuous vertical viewer: full-width strip, width-preserving decode, gap for continuous mode. The
    /// strip runs on into the next chapter below its card (`strip`), as upstream's webtoon viewer does.
    private func webtoonViewer(size: CGSize) -> some View {
        let width = min(size.width, 900)
        let pixelSize = pageDecodeSize(in: size, spread: false)
        let order = readingOrder
        // The open chapter is always in it (a strip not built yet, as the reading mode changes, is this chapter).
        let entries = strip.contains { $0.chapter.id == currentChapter.id }
            ? strip
            : [ReaderStripChapter(order: currentOrder, chapter: currentChapter, pages: pages)]
        return ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: readingMode == .continuousVertical ? 16 : 0) {
                ForEach(ReaderStripItem.items(of: entries)) { item in
                    Group {
                        switch item {
                        case .cardAbove(let entry):
                            let previous = order.indices.contains(entry.order - 1) ? order[entry.order - 1] : nil
                            ChapterTransitionView(isNext: false, current: entry.chapter, target: previous, compact: true) {
                                if let previous { switchToChapter(previous, atEnd: true) }
                            }
                            .frame(height: 220)
                        case .page(let entry, let index):
                            MangaPageImageView(
                                page: entry.pages[index],
                                mangaTitle: manga.title,
                                chapterTitle: entry.chapter.name,
                                totalPages: entry.pages.count,
                                cropBorders: store.cropBorders,
                                colorFilter: store.colorFilter,
                                maxPixelSize: pixelSize,
                                fitsWidth: true
                            )
                            .frame(width: width)
                        case .cardBelow(let entry):
                            let following = order.indices.contains(entry.order + 1) ? order[entry.order + 1] : nil
                            ChapterTransitionView(isNext: true, current: entry.chapter, target: following, compact: true) {
                                if let following { goToStripChapter(following, order: entry.order + 1) }
                            }
                            .frame(height: 260)
                        }
                    }
                    .id(item.id)
                }
            }
            .frame(maxWidth: .infinity)
            .scrollTargetLayout()
          }
          .scrollPosition(id: $webtoonPosition, anchor: .top)
          .modifier(ScrollEndReached(atEnd: $webtoonAtEnd))
          .gesture(tapGestures(size: size, spread: false))
          .onAppear {
              webtoonAtEnd = false
              let target = ReaderStripID.page(currentPage, order: currentOrder)
              webtoonPosition = target
              proxy.scrollTo(target, anchor: .top)
              DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
          }
        }
        .id("webtoon-\(readingMode.rawValue)-\(stripToken)")
    }

    // MARK: Gestures (pinch / pan / double-tap zoom / tap zones)

    /// Pages zoom; the chapter cards and the edges past them do not (zoomed, the pager stops scrolling and taps).
    private var pagerShowsPage: Bool {
        guard let pagerPosition else { return false }
        return pagerPosition >= 0 && pagerPosition < pagerItemCount
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isZoomed || pagerShowsPage else { return }
                if committedZoom <= 1.01 {
                    zoomAnchor = value.startAnchor
                }
                zoomScale = min(4, max(1, committedZoom * value.magnification))
            }
            .onEnded { _ in
                committedZoom = zoomScale
                if zoomScale <= 1.01 { resetZoom() } else { clampOffset(size: size) }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isZoomed else { return }
                zoomOffset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                committedOffset = zoomOffset
            }
    }

    /// The full-screen reader has no navigation back gesture on iOS; a downward swipe closes it (the counterpart
    /// of Android's system back), as in Photos. Horizontal pagers only — vertical modes scroll with that motion.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dy = value.translation.height
                guard !isZoomed, !isVerticalPager, dy > 120, abs(value.translation.width) < dy / 2 else { return }
                close()
            }
    }

    private func tapGestures(size: CGSize, spread: Bool) -> some Gesture {
        let single = SpatialTapGesture(count: 1).onEnded { event in
            handleTap(at: event.location, size: size, spread: spread)
        }
        let double = SpatialTapGesture(count: 2).onEnded { event in
            toggleZoom(at: event.location, size: size)
        }
        return double.exclusively(before: single)
    }

    private func toggleZoom(at location: CGPoint, size: CGSize) {
        guard store.doubleTapToZoom, !isWebtoon, isZoomed || pagerShowsPage else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
            if isZoomed {
                resetZoom()
            } else {
                zoomAnchor = UnitPoint(x: location.x / max(1, size.width), y: location.y / max(1, size.height))
                zoomScale = 2
                committedZoom = 2
            }
        }
    }

    private func resetZoom() {
        zoomScale = 1
        committedZoom = 1
        zoomOffset = .zero
        committedOffset = .zero
        zoomAnchor = .center
    }

    private func clampOffset(size: CGSize) {
        let maxX = size.width * (zoomScale - 1) / 2 + 40
        let maxY = size.height * (zoomScale - 1) / 2 + 40
        withAnimation(.spring(duration: 0.25)) {
            zoomOffset.width = min(maxX, max(-maxX, zoomOffset.width))
            zoomOffset.height = min(maxY, max(-maxY, zoomOffset.height))
            committedOffset = zoomOffset
        }
    }

    /// 1:1 with upstream `ViewerNavigation` regions (`RightAndLeftNavigation` for pagers, `LNavigation` for webtoon).
    private func handleTap(at location: CGPoint, size: CGSize, spread: Bool) {
        if menuVisible {
            setMenu(false)
            return
        }
        if isZoomed { return }
        let x = location.x / max(1, size.width)
        let y = location.y / max(1, size.height)

        enum Region { case menu, next, previous, left, right }
        let region: Region
        switch store.readerTapZone {
        case .disabled:
            region = .menu
        case .defaultZone:
            region = isWebtoon || isVerticalPager ? lShaped(x, y) : (x < 0.33 ? .left : (x > 0.66 ? .right : .menu))
        case .rightAndLeft:
            region = x < 0.33 ? .left : (x > 0.66 ? .right : .menu)
        case .lShaped:
            region = lShaped(x, y)
        case .kindle:
            region = y < 0.33 ? .menu : (x < 0.33 ? .previous : .next)
        case .edge:
            region = x < 0.33 || x > 0.66 ? .next : (y > 0.66 ? .previous : .menu)
        }

        func lShaped(_ x: CGFloat, _ y: CGFloat) -> Region {
            if y < 0.33 { return .previous }
            if y > 0.66 { return .next }
            if x < 0.33 { return .previous }
            if x > 0.66 { return .next }
            return .menu
        }

        switch region {
        case .menu: setMenu(true)
        case .next: moveForward()
        case .previous: moveBackward()
        case .left: tapDirection(left: true)
        case .right: tapDirection(left: false)
        }
    }

    /// The book's direction in a curling spread, where swapping the pages of a spread turns the whole book around.
    private var tapsRightToLeft: Bool {
        #if canImport(UIKit)
        if lastSpreadState && store.duoPageTurnStyle == .curl { return isRTL != store.invertDoublePageOrder }
        #endif
        return isRTL
    }

    private func tapDirection(left: Bool) {
        // Pagers move in the reading direction; for R2L "left" means the next page.
        if isWebtoon || isVerticalPager {
            left ? moveBackward() : moveForward()
        } else if tapsRightToLeft {
            left ? moveForward() : moveBackward()
        } else {
            left ? moveBackward() : moveForward()
        }
    }

    private func moveForward() {
        if isWebtoon {
            let order = currentOrder
            let above = ReaderStripID.card(before: order)
            let below = ReaderStripID.card(before: order + 1)
            if webtoonShownTransition == above || webtoonPosition == above {
                scrollStrip(to: ReaderStripID.page(0, order: order))
            } else if currentPage < pages.count - 1 {
                scrollStrip(to: ReaderStripID.page(currentPage + 1, order: order))
            } else if strip.contains(where: { $0.order == order + 1 }) {
                // The next chapter runs on below its card.
                scrollStrip(to: ReaderStripID.page(0, order: order + 1))
            } else if webtoonShownTransition == below {
                if let nextChapter { switchToChapter(nextChapter) }
            } else {
                scrollStrip(to: below, shown: true)
            }
            return
        }
        guard let position = pagerPosition else { return }
        if position == ReaderItemID.nextEdge {
            leaveEdge(position)
            return
        }
        if position == ReaderItemID.nextTransition {
            if let nextChapter { moveOnPastCard(into: nextChapter, edge: ReaderItemID.nextEdge) }
            return
        }
        let count = pagerItemCount
        let next = position == ReaderItemID.previousTransition ? 0 : position + 1
        withAnimation(.snappy(duration: 0.28)) {
            pagerPosition = next >= count ? ReaderItemID.nextTransition : next
        }
    }

    private func moveBackward() {
        if isWebtoon {
            let order = currentOrder
            let above = ReaderStripID.card(before: order)
            let below = ReaderStripID.card(before: order + 1)
            if webtoonShownTransition == below {
                scrollStrip(to: ReaderStripID.page(max(0, pages.count - 1), order: order))
            } else if currentPage > 0 {
                scrollStrip(to: ReaderStripID.page(currentPage - 1, order: order))
            } else if let previous = strip.first(where: { $0.order == order - 1 }) {
                // The previous chapter runs on above its card.
                scrollStrip(to: ReaderStripID.page(max(0, previous.pages.count - 1), order: order - 1))
            } else if webtoonShownTransition == above || webtoonPosition == above {
                if let previousChapter { switchToChapter(previousChapter, atEnd: true) }
            } else {
                scrollStrip(to: above, shown: true)
            }
            return
        }
        guard let position = pagerPosition else { return }
        if position == ReaderItemID.previousEdge {
            leaveEdge(position)
            return
        }
        if position == ReaderItemID.previousTransition {
            if let previousChapter { moveOnPastCard(into: previousChapter, edge: ReaderItemID.previousEdge) }
            return
        }
        let count = pagerItemCount
        let previous = position == ReaderItemID.nextTransition ? count - 1 : position - 1
        withAnimation(.snappy(duration: 0.28)) {
            pagerPosition = previous < 0 ? ReaderItemID.previousTransition : previous
        }
    }

    /// A tap or key on a chapter card: the slide pager slides on past it as a swipe does when the page there has been
    /// fetched; otherwise (or turning like a book) the chapter opens at once.
    private func moveOnPastCard(into chapter: Chapter, edge: Int) {
        if !isCurling, neighborPages[chapter.id] != nil {
            slideToEdge(edge)
        } else {
            switchToChapter(chapter, atEnd: edge == ReaderItemID.previousEdge)
        }
    }

    /// Slides the pager to `edge`; its chapter opens once the slide has ended (a swipe away meanwhile keeps it shut).
    private func slideToEdge(_ edge: Int) {
        edgeSlide = edge
        withAnimation(.snappy(duration: 0.28)) {
            pagerPosition = edge
        } completion: {
            guard edgeSlide == edge else { return }
            edgeSlide = nil
            leaveEdge(edge)
        }
    }

    /// A tap or key's move along the strip; `shown`: to a card, which one more press past switches chapters.
    private func scrollStrip(to id: Int, shown: Bool = false) {
        webtoonShownTransition = shown ? id : nil
        withAnimation(.easeInOut(duration: 0.25)) { webtoonPosition = id }
    }

    @State private var lastSpreadState = false
    /// The session's chapter list, in reading order (`readingOrder`).
    @State private var sessionChapterIds: [Int64]?

    private var pagerItemCount: Int { lastSpreadState ? spreads.count : pages.count }

    private func setMenu(_ visible: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { menuVisible = visible }
    }

    // MARK: Position bookkeeping

    private func handlePagerPosition(_ position: Int?, spread: Bool, size: CGSize) {
        #if DEBUG
        Self.log.notice("pager \(position.map(String.init) ?? "nil", privacy: .public) placed=\(pagerPlaced) scrolling=\(pagerScrolling)")
        #endif
        lastSpreadState = spread
        guard let position else { return }
        // A zoom belongs to the item it was made on (a key press or a turn can move on while zoomed).
        resetZoom()
        // A new slide pager reports items of its own before it is placed (its first: a card or an edge); the curl
        // reports only turns.
        let placed = pagerPlaced || isCurling
        if position == ReaderItemID.nextEdge || position == ReaderItemID.previousEdge {
            // A tap's slide there opens the chapter as it ends.
            guard placed, !pages.isEmpty, edgeSlide != position else { return }
            if pagerScrolling {
                pendingEdge = position
            } else {
                // Leaving the edge moves the position again, so not from its own onChange (SwiftUI: "onChange action
                // tried to update multiple times per frame").
                DispatchQueue.main.async { leaveEdge(position) }
            }
            return
        }
        if position != ReaderItemID.previousTransition && position != ReaderItemID.nextTransition {
            let page = spread ? (position < spreads.count ? spreads[position].first ?? 0 : 0) : position
            pageChanged(to: page, size: size)
        } else if placed, position == ReaderItemID.nextTransition, !pages.isEmpty {
            pageChanged(to: pages.count - 1, size: size)
            // The book's last card: upstream shows the menu, as the reader is probably about to be closed.
            if nextChapter == nil { setMenu(true) }
        } else if placed, position == ReaderItemID.previousTransition, let previousChapter {
            // Upstream preloads the chapter a card leads to once it is shown.
            preloadNeighbor(previousChapter, next: false, pixelSize: pageDecodeSize(in: size, spread: spread))
        }
    }

    /// Paged past a chapter card: into that chapter, or (none there) back to the card.
    private func leaveEdge(_ edge: Int) {
        // Paged back meanwhile.
        guard pagerPosition == edge else { return }
        let forward = edge == ReaderItemID.nextEdge
        if forward, let nextChapter {
            switchToChapter(nextChapter)
        } else if !forward, let previousChapter {
            switchToChapter(previousChapter, atEnd: true)
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                pagerPosition = forward ? ReaderItemID.nextTransition : ReaderItemID.previousTransition
            }
        }
    }

    private func pageChanged(to page: Int, size: CGSize) {
        guard !pages.isEmpty else { return }
        let clamped = min(max(0, page), pages.count - 1)
        let changed = clamped != currentPage
        currentPage = clamped
        let spreadPages = lastSpreadState ? (spreads.first { $0.contains(clamped) } ?? [clamped]) : [clamped]
        let lastVisible = spreadPages.max() ?? clamped
        if changed || lastVisible >= pages.count - 1 {
            scheduleProgress(page: lastVisible, completed: lastVisible >= pages.count - 1)
        }
        let pagesSnapshot = pages
        let pixel = pageDecodeSize(in: size, spread: lastSpreadState)
        let crop = store.cropBorders
        Task { await preloader.updateWindow(currentPage: clamped, pages: pagesSnapshot, cropBorders: crop, maxPixelSize: pixel) }
        if clamped >= pages.count - 5, let nextChapter {
            // Upstream preloads the next chapter within the last five pages of the open one.
            preloadNeighbor(nextChapter, next: true, pixelSize: pixel)
        }
    }

    /// Fetches a neighbouring chapter's page list and warms the pages it opens on, so moving into it shows them at
    /// once: the next chapter's first pages, the previous one's last. In webtoon, the next runs on below the strip.
    private func preloadNeighbor(_ chapter: Chapter, next: Bool, pixelSize: Int) {
        if let known = neighborPages[chapter.id] {
            if next { appendToStrip(chapter, pages: known) }
            return
        }
        guard !neighborsLoading.contains(chapter.id) else { return }
        neighborsLoading.insert(chapter.id)
        let manga = manga
        let crop = store.cropBorders
        Task {
            let loaded = (try? await store.pageList(for: manga, chapter: chapter)) ?? []
            neighborsLoading.remove(chapter.id)
            // Moved on meanwhile: only the chapters next to the open one are kept.
            guard !loaded.isEmpty, chapter.id == (next ? nextChapter?.id : previousChapter?.id) else { return }
            neighborPages[chapter.id] = loaded
            #if DEBUG
            Self.log.notice("neighbor \(chapter.id) next=\(next) pages=\(loaded.count)")
            #endif
            let warm = next ? Array(loaded.prefix(3)) : Array(loaded.suffix(2))
            let held = neighborImages
            Task.detached(priority: .utility) {
                let target = MihonImageTarget.page(maxPixelSize: pixelSize)
                var decoded: [NeighborImages.Held] = []
                for page in warm {
                    guard page.hasRealImage, let url = page.imageUrl,
                          let image = await MihonTwoTierImageCache.shared.image(url: url, target: target, cropBorders: crop, priority: .utility)
                    else { continue }
                    decoded.append(NeighborImages.Held(url: url, target: target, cropBorders: crop, image: image))
                }
                let opening = decoded
                await MainActor.run { held.byChapter[chapter.id] = opening }
            }
            if next { appendToStrip(chapter, pages: loaded) }
        }
    }

    /// Only the open chapter's neighbours stay fetched.
    private func pruneNeighbors() {
        let keep = Set([previousChapter?.id, nextChapter?.id].compactMap { $0 })
        neighborPages = neighborPages.filter { keep.contains($0.key) }
        neighborImages.byChapter = neighborImages.byChapter.filter { keep.contains($0.key) }
    }

    // MARK: Webtoon strip

    /// The strip from the open chapter (and the next, when already fetched): the scroll view is built afresh.
    private func resetStrip() {
        var entries: [ReaderStripChapter] = []
        if !pages.isEmpty {
            let order = currentOrder
            entries.append(ReaderStripChapter(order: order, chapter: currentChapter, pages: pages))
            if let nextChapter, let nextPages = neighborPages[nextChapter.id], !nextPages.isEmpty {
                entries.append(ReaderStripChapter(order: order + 1, chapter: nextChapter, pages: nextPages))
            }
        }
        strip = entries
        stripToken += 1
        webtoonShownTransition = nil
    }

    /// A fetched chapter joins the strip below its last one, when it comes next in the reading order: nothing on
    /// screen moves.
    private func appendToStrip(_ chapter: Chapter, pages loaded: [Page]) {
        guard isWebtoon, let last = strip.last, !strip.contains(where: { $0.chapter.id == chapter.id }) else { return }
        let order = readingOrder
        guard order.indices.contains(last.order + 1), order[last.order + 1].id == chapter.id else { return }
        strip.append(ReaderStripChapter(order: last.order + 1, chapter: chapter, pages: loaded))
        #if DEBUG
        Self.log.notice("strip append \(chapter.id) order=\(last.order + 1) pages=\(loaded.count)")
        #endif
    }

    private func handleStripPosition(_ position: Int?, size: CGSize) {
        #if DEBUG
        Self.log.notice("webtoon \(position.map(String.init) ?? "nil", privacy: .public)")
        #endif
        guard let position else { return }
        let (order, index) = ReaderStripID.decode(position)
        // A card: the pages around it count.
        guard let index, let entry = strip.first(where: { $0.order == order }), entry.pages.indices.contains(index) else { return }
        if entry.chapter.id != currentChapter.id {
            enterStripChapter(entry)
        }
        // A card counts as shown only while a page next to it is the one in view.
        if let shown = webtoonShownTransition {
            let below = ReaderStripID.decode(shown).order
            let above = strip.first { $0.order == below - 1 }.map { ReaderStripID.page($0.pages.count - 1, order: below - 1) }
            if position != ReaderStripID.page(0, order: below) && position != above {
                webtoonShownTransition = nil
            }
        }
        pageChanged(to: index, size: size)
    }

    /// Scrolled from one chapter of the strip into another: it becomes the open one where it is, the strip unchanged.
    private func enterStripChapter(_ entry: ReaderStripChapter) {
        let forward = entry.order > currentOrder
        if forward, !pages.isEmpty {
            // Scrolled past its end, so read (a fling may skip its last page's own position).
            scheduleProgress(page: pages.count - 1, completed: true)
        }
        if !pages.isEmpty { neighborPages[currentChapter.id] = pages }
        currentChapter = store.chaptersByManga[manga.id]?.first { $0.id == entry.chapter.id } ?? entry.chapter
        pages = entry.pages
        webtoonShownTransition = nil
        pruneNeighbors()
        // Its list was fetched ahead, maybe a while ago: renewed in place if the store's has expired.
        pagesFetchedAhead = true
        chapterLoadToken += 1
        #if DEBUG
        Self.log.notice("strip enter \(entry.chapter.id) forward=\(forward)")
        #endif
    }

    /// The card's button: scrolls on into that chapter when the strip holds it, else opens it.
    private func goToStripChapter(_ chapter: Chapter, order: Int) {
        if strip.contains(where: { $0.order == order }) {
            scrollStrip(to: ReaderStripID.page(0, order: order))
        } else {
            switchToChapter(chapter)
        }
    }

    /// The strip's end in view: its last chapter is open and read to the end (a chapter or last page shorter than the
    /// screen never brings a page of its own to the top), the next one is fetched, and with none the menu shows, as
    /// upstream's webtoon viewer does at the last card.
    private func reachedStripEnd(size: CGSize) {
        guard let last = strip.last, !last.pages.isEmpty, strip.contains(where: { $0.chapter.id == currentChapter.id })
        else { return }
        if last.chapter.id != currentChapter.id { enterStripChapter(last) }
        pageChanged(to: pages.count - 1, size: size)
        if nextChapter == nil { setMenu(true) }
    }

    /// The page reached is written once the turn has settled: a write updates the screens under the reader (library,
    /// details), and done at once it fell in the turn's first frames.
    private func scheduleProgress(page: Int, completed: Bool) {
        let chapterId = currentChapter.id
        if let pending = progress.pending, pending.chapterId != chapterId {
            // Scrolled on into another chapter: the one left still writes its place, with the next write.
            progress.earlier.append(pending)
        }
        // Once the last page has shown, the chapter is read (upstream marks it then), even if paged back before the write.
        let wasCompleted = progress.pending.map { $0.chapterId == chapterId && $0.completed } ?? false
        progress.pending = (chapterId, page, completed || wasCompleted)
        let now = Date()
        let waitingSince = progress.waitingSince ?? now
        progress.waitingSince = waitingSince
        // Turning faster than the delay still writes every few seconds.
        let delay = max(0, min(0.6, 3 - now.timeIntervalSince(waitingSince)))
        progress.flush?.cancel()
        progress.flush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            flushProgress()
        }
    }

    /// Holds the page on screen (in a spread, its later page) when nothing is waiting: what closing or leaving saves.
    private func holdCurrentPage() {
        guard progress.pending == nil, !pages.isEmpty else { return }
        let lastVisible = lastSpreadState ? (spreads.first { $0.contains(currentPage) }?.max() ?? currentPage) : currentPage
        progress.pending = (currentChapter.id, lastVisible, lastVisible >= pages.count - 1)
    }

    /// Writes what is waiting — the time since the last write counts as reading — and, past a quarter of the chapter,
    /// downloads ahead (upstream `onPageSelected`).
    private func flushProgress() {
        progress.flush?.cancel()
        progress.flush = nil
        progress.waitingSince = nil
        let now = Date()
        // The time since the last write counts once, for the first chapter written.
        var duration = Int64(min(300, max(1, now.timeIntervalSince(progress.lastWrite))))
        let earlier = progress.earlier
        progress.earlier = []
        for left in earlier {
            store.recordReadingProgress(
                mangaId: manga.id,
                chapterId: left.chapterId,
                pageIndex: left.page,
                completedChapter: left.completed,
                durationSeconds: duration
            )
            duration = 1
            progress.lastWrite = now
        }
        guard let pending = progress.pending else { return }
        progress.pending = nil
        store.recordReadingProgress(
            mangaId: manga.id,
            chapterId: pending.chapterId,
            pageIndex: pending.page,
            completedChapter: pending.completed,
            durationSeconds: duration
        )
        progress.lastWrite = now
        if pending.chapterId == currentChapter.id, downloadedAheadFor != currentChapter.id, !pages.isEmpty,
           Double(pending.page + 1) / Double(pages.count) > 0.25 {
            downloadedAheadFor = currentChapter.id
            if let fresh = store.manga(id: manga.id) { store.downloadAhead(after: currentChapter, in: fresh) }
        }
    }

    private func syncPositions(spread: Bool) {
        lastSpreadState = spread
        if isWebtoon {
            webtoonPosition = ReaderStripID.page(currentPage, order: currentOrder)
        } else if spread {
            pagerPosition = spreads.firstIndex { $0.contains(currentPage) } ?? 0
        } else {
            pagerPosition = currentPage
        }
    }

    private func jump(to page: Int, spread: Bool) {
        let target = min(max(0, page), max(0, pages.count - 1))
        webtoonShownTransition = nil
        currentPage = target
        resetZoom()
        if isWebtoon {
            webtoonPosition = ReaderStripID.page(target, order: currentOrder)
        } else if spread {
            pagerPosition = spreads.firstIndex { $0.contains(target) } ?? 0
        } else {
            pagerPosition = target
        }
        // `currentPage` moved first, so `pageChanged` sees no change: the page jumped to is written from here.
        if !pages.isEmpty {
            let landed = spread ? (spreads.first { $0.contains(target) }?.max() ?? target) : target
            scheduleProgress(page: landed, completed: landed >= pages.count - 1)
        }
    }

    private func pageIndicatorText(spread: Bool) -> String {
        if spread, let pair = spreads.first(where: { $0.contains(currentPage) }), pair.count == 2 {
            return "\(pair[0] + 1)-\(pair[1] + 1) / \(pages.count)"
        }
        return "\(currentPage + 1) / \(pages.count)"
    }

    // MARK: Chapter loading

    private func loadPages(size: CGSize) async {
        let fetchedAhead = pagesFetchedAhead
        pagesFetchedAhead = false
        isLoadingPages = true
        loadError = nil
        openingPreview = nil
        let opensAt = opening
        let chapterId = currentChapter.id
        do {
            let saved = store.chaptersByManga[manga.id]?.first { $0.id == chapterId } ?? currentChapter
            let openingIndex = switch opensAt {
            case .first: 0
            case .last: Int.max
            case .saved: saved.read ? 0 : saved.lastPageRead
            }
            let loaded = try await store.pageList(for: manga, chapter: currentChapter, openingAt: openingIndex) { page, total in
                guard !Task.isCancelled, currentChapter.id == chapterId, pages.isEmpty else { return }
                openingPreview = (chapterId, page, total)
            }
            // Another chapter opened meanwhile (its task cancels this one only at the next update).
            guard !Task.isCancelled, currentChapter.id == chapterId else { return }
            openingPreview = nil
            opening = .saved
            if fetchedAhead, loaded.count == pages.count {
                // Open already, on the list fetched ahead: a fresher one (past the store's five minutes) only renews
                // the addresses, where the reader is.
                if loaded != pages { renewPages(loaded, size: size) }
                isLoadingPages = false
                return
            }
            let lastPage = max(0, loaded.count - 1)
            // The saved progress, not the caller's copy: the library's continue button hands over a cached chapter.
            if let saved = store.chaptersByManga[manga.id]?.first(where: { $0.id == currentChapter.id }) { currentChapter = saved }
            let resume: Int
            switch opensAt {
            // The chapter changed under the list fetched ahead: it stays where the reader is.
            case _ where fetchedAhead: resume = min(currentPage, lastPage)
            case .first: resume = 0
            case .last: resume = lastPage
            case .saved: resume = currentChapter.read ? 0 : min(max(0, currentChapter.lastPageRead), lastPage)
            }
            pages = loaded
            currentPage = resume
            isLoadingPages = false
            // Built already when the switch had the pages fetched ahead.
            if isWebtoon, strip.first?.chapter.id != chapterId || strip.first?.pages != loaded { resetStrip() }
            syncPositions(spread: isSpreadEnabled(in: size))
            await preloader.updateWindow(
                currentPage: resume,
                pages: loaded,
                cropBorders: store.cropBorders,
                maxPixelSize: pageDecodeSize(in: size, spread: isSpreadEnabled(in: size))
            )
        } catch {
            guard !Task.isCancelled, currentChapter.id == chapterId else { return }
            openingPreview = nil
            isLoadingPages = false
            // Shown already: the list fetched ahead, not an error over the pages being read.
            if fetchedAhead, !pages.isEmpty { return }
            pages = []
            loadError = "无法加载章节页面\n\(error.localizedDescription)"
        }
    }

    /// The open chapter's pages at renewed addresses (MangaDex's at-home server, 再漫画's signature): the images
    /// decoded at the old ones go with them, so nothing on screen loads again.
    private func renewPages(_ renewed: [Page], size: CGSize) {
        let crop = store.cropBorders
        let target = MihonImageTarget.page(maxPixelSize: pageDecodeSize(in: size, spread: lastSpreadState))
        for (old, new) in zip(pages, renewed) {
            guard let oldUrl = old.imageUrl, let newUrl = new.imageUrl, oldUrl != newUrl,
                  let image = MihonTwoTierImageCache.shared.cachedImage(url: oldUrl, target: target, cropBorders: crop)
            else { continue }
            MihonTwoTierImageCache.shared.remember(image, url: newUrl, target: target, cropBorders: crop)
        }
        let chapterId = currentChapter.id
        pages = renewed
        if let index = strip.firstIndex(where: { $0.chapter.id == chapterId }) {
            strip[index] = ReaderStripChapter(order: strip[index].order, chapter: strip[index].chapter, pages: renewed)
        }
    }

    /// Opens `target` at its first page, as moving on into a chapter does upstream (its pager runs on into it, its
    /// next / previous buttons open page one), or `atEnd` at its last (paged back into it). A page list fetched
    /// ahead shows at once: the pager past the card was already showing its first page.
    private func switchToChapter(_ target: Chapter, atEnd: Bool = false) {
        flushProgress()
        resetZoom()
        Task { await preloader.cancelAll() }
        let preloaded = neighborPages[target.id] ?? []
        // The pages it opens on, decoded ahead: in memory again for the views about to show them (the cache may have
        // let them go, and a page loading again flashed its spinner where the one past the card had been).
        for held in neighborImages.byChapter[target.id] ?? [] {
            MihonTwoTierImageCache.shared.remember(held.image, url: held.url, target: held.target, cropBorders: held.cropBorders)
        }
        #if DEBUG
        Self.log.notice("switch \(target.id) preloaded=\(preloaded.count) atEnd=\(atEnd)")
        #endif
        // The chapter left is a neighbour of the one opening: paging back to it needs no fetch.
        if !pages.isEmpty { neighborPages[currentChapter.id] = pages }
        currentChapter = store.chaptersByManga[manga.id]?.first { $0.id == target.id } ?? target
        pruneNeighbors()
        opening = atEnd ? .last : .first
        webtoonShownTransition = nil
        pendingEdge = nil
        edgeSlide = nil
        loadError = nil
        pagesFetchedAhead = !preloaded.isEmpty
        if preloaded.isEmpty {
            // Loading from this frame on: an empty pager in between would set its own position as it appears.
            isLoadingPages = true
            pages = []
            currentPage = 0
            pagerPosition = nil
            webtoonPosition = nil
            if isWebtoon { resetStrip() }
        } else {
            pages = preloaded
            currentPage = atEnd ? preloaded.count - 1 : 0
            isLoadingPages = false
            if isWebtoon { resetStrip() }
            // The new pager's (strip's) place, set now: cleared here and set again as it appears, the position
            // changed twice in one frame (SwiftUI: "onChange action tried to update multiple times per frame").
            syncPositions(spread: lastSpreadState)
        }
        progress.lastWrite = Date()
        chapterLoadToken += 1
    }

    private func toggleBookmark() {
        store.toggleChapterBookmark(mangaId: manga.id, chapterId: currentChapter.id)
        currentChapter.bookmark.toggle()
    }

    private func toggleSpread(_ spread: Bool) {
        store.duoDualPageBehavior = spread ? .singlePageOnly : .alwaysDualPage
    }

    private func close() {
        // The page last reached; the time since the last write counts too.
        holdCurrentPage()
        flushProgress()
        onClose()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

// MARK: - Zoom & scale helpers

private struct ZoomTransform: ViewModifier {
    let active: Bool
    let scale: CGFloat
    let offset: CGSize
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? scale : 1, anchor: anchor)
            .offset(active ? offset : .zero)
    }
}

/// `ReaderPreferences.imageScaleType` for the pager.
private struct ReaderScaleTypeModifier: ViewModifier {
    let scaleType: ReaderScaleType
    let size: CGSize

    func body(content: Content) -> some View {
        switch scaleType {
        case .fitScreen, .smartFit:
            content.frame(maxWidth: size.width, maxHeight: size.height)
        case .fitWidth:
            content.frame(width: size.width).frame(maxHeight: size.height, alignment: .top).clipped()
        case .fitHeight:
            content.frame(height: size.height).frame(maxWidth: size.width).clipped()
        case .originalSize:
            content.frame(maxWidth: size.width, maxHeight: size.height)
        }
    }
}

/// The neighbouring chapters' opening pages, decoded ahead (`preloadNeighbor`) and held for the chapter switch; a
/// reference, so filling it never re-renders the reader.
@MainActor
private final class NeighborImages {
    struct Held {
        let url: String
        let target: MihonImageTarget
        let cropBorders: Bool
        let image: CGImage
    }

    var byChapter: [Int64: [Held]] = [:]
}

/// 3D page-turn: spreads rotate around the spine side as they slide out (GPU transform only → 120fps).
/// Progress held between a page turn and its write; a reference, so holding it never re-renders the reader.
@MainActor
private final class ReaderProgressWriter {
    var pending: (chapterId: Int64, page: Int, completed: Bool)?
    /// What chapters scrolled out of (the webtoon strip runs on) still have to write, oldest first.
    var earlier: [(chapterId: Int64, page: Int, completed: Bool)] = []
    /// When the oldest unwritten turn happened (writes are at most a few seconds apart).
    var waitingSince: Date?
    var flush: Task<Void, Never>?
    var lastWrite = Date()
}

/// The pager's paging: a page per swipe. Vertical pages align to the pages themselves: that scroll view keeps the
/// home indicator's inset below them, and paging placed a page (opening a chapter, a tap) 17 pt off per page.
private struct ReaderPaging: ViewModifier {
    let vertical: Bool

    func body(content: Content) -> some View {
        if vertical {
            content.scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        } else {
            content.scrollTargetBehavior(.paging)
        }
    }
}

/// Whether the end of a vertical scroll view's content is in view, where the OS reports it (iOS 18, macOS 15).
private struct ScrollEndReached: ViewModifier {
    @Binding var atEnd: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height
                    && geometry.visibleRect.maxY >= geometry.contentSize.height - 2
            } action: { _, reached in
                atEnd = reached
            }
        } else {
            content
        }
    }
}

/// Whether a scroll view is being dragged or still moving, where the OS reports it (iOS 18, macOS 15).
private struct ScrollActivity: ViewModifier {
    @Binding var isScrolling: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
            }
        } else {
            content
        }
    }
}

private struct PageTurnTransition: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.scrollTransition(.interactive, axis: .horizontal) { view, phase in
                view
                    .rotation3DEffect(
                        .degrees(phase.value * -28),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: phase.value < 0 ? .trailing : .leading,
                        perspective: 0.45
                    )
                    .brightness(-abs(phase.value) * 0.25)
            }
        } else {
            content
        }
    }
}

// MARK: - iPhone Duo book spread (left screen | hinge | right screen)

private struct DuoBookSpreadView: View {
    let pages: [Page]
    /// Right-to-left books place the earlier page on the right screen.
    let isRTL: Bool
    let isCoverSpread: Bool
    let hingeWidth: CGFloat
    let insets: EdgeInsets
    let showSpineShadow: Bool
    let mangaTitle: String
    let chapterTitle: String
    let totalPages: Int
    let cropBorders: Bool
    let colorFilter: ReaderColorFilterState
    let maxPixelSize: Int

    var body: some View {
        let (left, right) = slots
        GeometryReader { geo in
            let split = DuoSplit(width: geo.size.width, hinge: hingeWidth, insets: insets)
            // The pages meet on the spine; the hinge drawn over the pager (not part of the spread) covers the seam,
            // so it never slides with the pages.
            HStack(spacing: 0) {
                pageSlot(left, alignment: .trailing, isLeftScreen: true)
                    .frame(width: split.leading + hingeWidth / 2, height: geo.size.height)
                pageSlot(right, alignment: .leading, isLeftScreen: false)
                    .frame(width: split.trailing + hingeWidth / 2, height: geo.size.height)
            }
        }
    }

    /// A lone cover sits where a closed book's front cover would be (left for R2L, right for L2R);
    /// a lone trailing page continues the reading direction.
    private var slots: (Page?, Page?) {
        if pages.count >= 2 {
            return isRTL ? (pages[1], pages[0]) : (pages[0], pages[1])
        }
        guard let only = pages.first else { return (nil, nil) }
        if isCoverSpread {
            return isRTL ? (only, nil) : (nil, only)
        }
        return isRTL ? (nil, only) : (only, nil)
    }

    @ViewBuilder
    private func pageSlot(_ page: Page?, alignment: Alignment, isLeftScreen: Bool) -> some View {
        ZStack(alignment: alignment) {
            Color.clear
            if let page {
                MangaPageImageView(
                    page: page,
                    mangaTitle: mangaTitle,
                    chapterTitle: chapterTitle,
                    totalPages: totalPages,
                    cropBorders: cropBorders,
                    colorFilter: colorFilter,
                    maxPixelSize: maxPixelSize
                )
                .overlay(alignment: isLeftScreen ? .trailing : .leading) {
                    if showSpineShadow { DuoSpineShadow(isLeftScreen: isLeftScreen) }
                }
            }
        }
    }
}

/// Binding shadow that deepens toward the spine (a book's gutter).
private struct DuoSpineShadow: View {
    let isLeftScreen: Bool

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.10), location: 0.55),
                .init(color: .black.opacity(0.32), location: 1)
            ],
            startPoint: isLeftScreen ? .leading : .trailing,
            endPoint: isLeftScreen ? .trailing : .leading
        )
        .frame(width: 34)
        .allowsHitTesting(false)
    }
}

// MARK: - Chapter transition (1:1 with `ChapterTransition`)

private struct ChapterTransitionView: View {
    let isNext: Bool
    let current: Chapter
    let target: Chapter?
    var compact = false
    /// Off on a curling page, whose own taps turn it: one tap must not do both.
    var showsButton = true
    let onGo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            if isNext {
                transitionText(label: "已读完：", title: current.name)
                if let target {
                    transitionText(label: "下一章：", title: target.name)
                } else {
                    Text("后面没有啦")
                        .font(MihonType.titleMedium)
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                if let target {
                    transitionText(label: "上一章：", title: target.name)
                } else {
                    Text("前面没有啦")
                        .font(MihonType.titleMedium)
                        .foregroundStyle(.white.opacity(0.85))
                }
                transitionText(label: "本章：", title: current.name)
            }
            if target != nil && showsButton {
                Button(isNext ? "下一章" : "上一章", action: onGo)
                    .buttonStyle(MihonButtonStyle(.tonal))
            }
        }
        .padding(32)
        .frame(maxWidth: 460, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func transitionText(label: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(MihonType.bodyMedium)
                .foregroundStyle(.white.opacity(0.7))
            Text(title)
                .font(MihonType.titleMedium)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
    }
}

// MARK: - Page indicator (light text with a dark stroke, 1:1 with `ReaderPageIndicator`)

private struct ReaderPageIndicator: View {
    let text: String

    var body: some View {
        ZStack {
            // Four offset copies emulate the 4px stroke outline.
            ForEach(0..<4, id: \.self) { corner in
                Text(text)
                    .offset(x: corner % 2 == 0 ? -1 : 1, y: corner < 2 ? -1 : 1)
                    .foregroundStyle(Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255))
            }
            Text(text).foregroundStyle(Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255))
        }
        .font(.system(size: 12, weight: .bold))
        .tracking(1)
        .monospacedDigit()
    }
}

// MARK: - Tap zone guide (1:1 with `ReaderNavigationOverlay`)

private struct ReaderNavigationOverlay: View {
    let mode: TapZoneType
    let isRTL: Bool
    let isWebtoon: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                    Rectangle()
                        .fill(region.color.opacity(0.42))
                        .frame(width: region.rect.width * w, height: region.rect.height * h)
                        .overlay(
                            Text(region.label)
                                .font(MihonType.titleMedium)
                                .foregroundStyle(.white)
                        )
                        .position(x: region.rect.midX * w, y: region.rect.midY * h)
                }
            }
        }
        .ignoresSafeArea()
    }

    private struct Region {
        let rect: CGRect
        let color: Color
        let label: String
    }

    private var regions: [Region] {
        let next = Color(red: 0.2, green: 0.6, blue: 0.35)
        let prev = Color(red: 0.8, green: 0.3, blue: 0.3)
        let menu = Color(red: 0.25, green: 0.45, blue: 0.85)
        let usesL = mode == .lShaped || (mode == .defaultZone && isWebtoon)
        if usesL {
            return [
                Region(rect: CGRect(x: 0, y: 0, width: 1, height: 0.33), color: prev, label: "上一页"),
                Region(rect: CGRect(x: 0, y: 0.33, width: 0.33, height: 0.34), color: prev, label: "上一页"),
                Region(rect: CGRect(x: 0.33, y: 0.33, width: 0.34, height: 0.34), color: menu, label: "菜单"),
                Region(rect: CGRect(x: 0.67, y: 0.33, width: 0.33, height: 0.34), color: next, label: "下一页"),
                Region(rect: CGRect(x: 0, y: 0.67, width: 1, height: 0.33), color: next, label: "下一页")
            ]
        }
        switch mode {
        case .kindle:
            return [
                Region(rect: CGRect(x: 0, y: 0, width: 1, height: 0.33), color: menu, label: "菜单"),
                Region(rect: CGRect(x: 0, y: 0.33, width: 0.33, height: 0.67), color: prev, label: "上一页"),
                Region(rect: CGRect(x: 0.33, y: 0.33, width: 0.67, height: 0.67), color: next, label: "下一页")
            ]
        case .edge:
            return [
                Region(rect: CGRect(x: 0, y: 0, width: 0.33, height: 1), color: next, label: "下一页"),
                Region(rect: CGRect(x: 0.33, y: 0, width: 0.34, height: 0.67), color: menu, label: "菜单"),
                Region(rect: CGRect(x: 0.33, y: 0.67, width: 0.34, height: 0.33), color: prev, label: "上一页"),
                Region(rect: CGRect(x: 0.67, y: 0, width: 0.33, height: 1), color: next, label: "下一页")
            ]
        case .disabled:
            return [Region(rect: CGRect(x: 0, y: 0, width: 1, height: 1), color: menu, label: "菜单")]
        default:
            return [
                Region(rect: CGRect(x: 0, y: 0, width: 0.33, height: 1), color: isRTL ? next : prev, label: isRTL ? "下一页" : "上一页"),
                Region(rect: CGRect(x: 0.33, y: 0, width: 0.34, height: 1), color: menu, label: "菜单"),
                Region(rect: CGRect(x: 0.67, y: 0, width: 0.33, height: 1), color: isRTL ? prev : next, label: isRTL ? "上一页" : "下一页")
            ]
        }
    }
}

// MARK: - Reader app bars (1:1 with `ReaderAppBars` / `ReaderTopBar` / `ChapterNavigator` / `ReaderBottomBar`)

private struct ReaderAppBars: View {
    let visible: Bool
    let spread: Bool
    let size: CGSize
    let hingeWidth: CGFloat
    let insets: EdgeInsets
    let mangaTitle: String
    let chapterTitle: String
    let bookmarked: Bool
    let isRTL: Bool
    let currentPage: Int
    let totalPages: Int
    let readingMode: ReadingMode
    let cropEnabled: Bool
    let enabledPrevious: Bool
    let enabledNext: Bool
    let onBack: () -> Void
    let onToggleBookmark: () -> Void
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void
    let onPageChange: (Int) -> Void
    let onClickReadingMode: () -> Void
    let onToggleSpread: () -> Void
    let onToggleCrop: () -> Void
    let onClickSettings: () -> Void
    @Environment(\.mihonColors) private var colors

    private var barColor: Color {
        colors.surfaceElevation3.opacity(colors.isDark ? 0.9 : 0.95)
    }

    var body: some View {
        let split = DuoSplit(width: size.width, hinge: hingeWidth, insets: insets)
        VStack(spacing: 0) {
            if visible {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if visible {
                Group {
                    if spread {
                        // Hinge-aware: navigator on the left screen, actions on the right screen.
                        HStack(alignment: .bottom, spacing: hingeWidth) {
                            VStack(spacing: 0) {
                                navigator
                                    .padding(.bottom, 8)
                            }
                            .frame(width: split.leading)
                            bottomBar
                                .background(barColor.clipShape(RoundedRectangle(cornerRadius: MihonShape.large)))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                                .frame(width: split.trailing)
                        }
                    } else if usesSideBar {
                        // The actions are in the sensor bar: only the chapter navigator over the page.
                        navigator
                            .padding(.bottom, MihonPadding.small)
                    } else {
                        VStack(spacing: MihonPadding.small) {
                            navigator
                            bottomBar
                                .padding(.horizontal, MihonPadding.small)
                                .background(barColor.ignoresSafeArea(edges: .bottom))
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if visible && usesSideBar {
                sideBar
                    .frame(width: insets.trailing)
                    // Below the camera and the status bar at the top of the sensor bar.
                    .padding(.top, 160)
                    .offset(x: insets.trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: visible)
    }

    /// Single-page reading on the Duo's cover display: its sensor bar (84 pt on the right) has room for the
    /// actions, which then leave the page uncovered.
    private var usesSideBar: Bool {
        !spread && size.height > size.width && insets.trailing >= 60 && insets.leading < 1
    }

    private var sideBar: some View {
        VStack(spacing: 4) {
            barIcon(readingMode.iconName, help: "阅读模式", action: onClickReadingMode)
            barIcon(spread ? "book.pages.fill" : "book.pages", help: "iPhone Duo 双页", tint: spread ? colors.primary : nil, action: onToggleSpread)
            barIcon("crop", help: "裁剪边缘", tint: cropEnabled ? colors.primary : nil, action: onToggleCrop)
            barIcon("gearshape", help: "设置", action: onClickSettings)
        }
        .padding(.vertical, 8)
        .frame(width: 56)
        .background(barColor.clipShape(Capsule()))
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            MihonIconButton("arrow.left", tint: colors.onSurface, action: onBack)
            VStack(alignment: .leading, spacing: 0) {
                Text(mangaTitle)
                    .font(MihonType.titleMedium)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
                Text(chapterTitle)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: spread ? max(0, (size.width - hingeWidth) / 2 - 64) : .infinity, alignment: .leading)
            .padding(.leading, 4)
            Spacer(minLength: spread ? hingeWidth : 0)
            MihonIconButton(bookmarked ? "bookmark.fill" : "bookmark", tint: colors.onSurfaceVariant, action: onToggleBookmark)
                .help(bookmarked ? "为章节删除书签" : "为章节添加书签")
        }
        .padding(.horizontal, 4)
        .frame(height: 64)
        // Edge to edge, including under the status strip at the screen's side.
        .background(barColor.ignoresSafeArea(edges: [.top, .horizontal]))
    }

    private var navigator: some View {
        HStack(spacing: 0) {
            navButton("backward.end.fill", enabled: isRTL ? enabledNext : enabledPrevious, action: isRTL ? onNextChapter : onPreviousChapter)
            if totalPages > 1 {
                HStack(spacing: 8) {
                    // R2L mirrors the whole pill (upstream `HorizontalChapterNavigator(isRtl)`).
                    Text("\(isRTL ? totalPages : currentPage)")
                        .frame(minWidth: 24, alignment: .trailing)
                    MihonSlider(
                        value: Binding(
                            get: { Double(currentPage) },
                            set: { onPageChange(Int($0.rounded())) }
                        ),
                        in: 1...Double(totalPages),
                        step: 1,
                        reversed: isRTL
                    )
                    Text("\(isRTL ? currentPage : totalPages)")
                        .frame(minWidth: 24, alignment: .leading)
                }
                .font(MihonType.bodyMedium)
                .monospacedDigit()
                .foregroundStyle(colors.onSurface)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(barColor, in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 8)
            } else {
                Spacer()
            }
            navButton("forward.end.fill", enabled: isRTL ? enabledPrevious : enabledNext, action: isRTL ? onPreviousChapter : onNextChapter)
        }
        .padding(.horizontal, spread ? 12 : 8)
    }

    private func navButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundStyle(colors.onSurface.opacity(enabled ? 1 : MihonAlpha.disabled))
                .frame(width: 48, height: 48)
                .background(barColor, in: Circle())
        }
        .buttonStyle(MihonStateLayerStyle(shape: Circle()))
        .disabled(!enabled)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barIcon(readingMode.iconName, help: "阅读模式", action: onClickReadingMode)
            barIcon(spread ? "book.pages.fill" : "book.pages", help: "iPhone Duo 双页", tint: spread ? colors.primary : nil, action: onToggleSpread)
            barIcon(cropEnabled ? "crop" : "crop", help: "裁剪边缘", tint: cropEnabled ? colors.primary : nil, action: onToggleCrop)
            barIcon("gearshape", help: "设置", action: onClickSettings)
        }
        .frame(height: 56)
    }

    private func barIcon(_ systemName: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        MihonIconButton(systemName, tint: tint ?? colors.onSurface, label: help, action: action)
            .frame(maxWidth: .infinity)
            .help(help)
    }
}

// MARK: - Reading mode / page-turn direction (1:1 with `ReadingModeSelectDialog`)

/// Picks how pages turn for *this* series — left/right paging or up/down paging / scrolling —
/// and stores it as the manga's reading-mode override (like upstream's per-series viewer flag).
public struct ReadingModeSelectSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss
    public let mangaId: Int64
    @Binding public var readingMode: ReadingMode

    public init(mangaId: Int64, readingMode: Binding<ReadingMode>) {
        self.mangaId = mangaId
        self._readingMode = readingMode
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("阅读模式")
                    .font(MihonType.titleLarge)
                    .foregroundStyle(colors.onSurface)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                Text("仅对当前作品生效，可在「设置 → 阅读器」修改默认值")
                    .font(MihonType.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                MihonHeadingItem("左右翻页")
                option(.rightToLeft)
                option(.leftToRight)
                MihonHeadingItem("上下翻页")
                option(.vertical)
                option(.webtoon)
                option(.continuousVertical)
                MihonDivider().padding(.vertical, 8)
                Button {
                    if let idx = store.mangas.firstIndex(where: { $0.id == mangaId }) {
                        store.mangas[idx].readingModeOverride = .defaultMode
                    }
                    let global = store.defaultReadingMode == .defaultMode ? ReadingMode.rightToLeft : store.defaultReadingMode
                    select(global, persistOverride: false)
                } label: {
                    Text("恢复默认（\(store.defaultReadingMode.shortTitle)）")
                }
                .buttonStyle(MihonButtonStyle(.text))
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(colors.surfaceContainerLow)
    }

    private func option(_ mode: ReadingMode) -> some View {
        let selected = readingMode == mode
        return Button {
            select(mode, persistOverride: true)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(selected ? colors.secondaryContainer : colors.surfaceContainerHighest))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.localizedTitle)
                        .font(MihonType.bodyLarge)
                        .foregroundStyle(colors.onSurface)
                    Text(mode.detail)
                        .font(MihonType.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.primary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.mihonRow)
        .mihonTestAnchor("readingMode.\(mode.rawValue)")
    }

    private func select(_ mode: ReadingMode, persistOverride: Bool) {
        readingMode = mode
        if persistOverride, let idx = store.mangas.firstIndex(where: { $0.id == mangaId }) {
            store.mangas[idx].readingModeOverride = mode
        }
        store.showStatusBanner("阅读模式：\(mode.localizedTitle)")
        dismiss()
    }
}

// MARK: - Reader settings (1:1 with `ReaderSettingsDialog`: 阅读模式 / 常规 / 滤镜)

public struct ReaderSettingsSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    public let mangaId: Int64
    @Binding public var readingMode: ReadingMode
    @State private var tab: Int64 = 0

    public init(mangaId: Int64, readingMode: Binding<ReadingMode>) {
        self.mangaId = mangaId
        self._readingMode = readingMode
    }

    public var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            MihonTabRow(
                tabs: [MihonTab(id: 0, title: "阅读模式"), MihonTab(id: 1, title: "常规"), MihonTab(id: 2, title: "滤镜")],
                selection: $tab,
                background: colors.surfaceContainerLow
            )
            .padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case 0: readingModePage(store: store)
                    case 1: generalPage(store: store)
                    default: filterPage(store: store)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(colors.surfaceContainerLow)
    }

    @ViewBuilder
    private func readingModePage(store: MihonRepositoryStore) -> some View {
        @Bindable var store = store
        MihonChipRow("阅读模式") {
            ForEach(ReadingMode.allCases.filter { $0 != .defaultMode }, id: \.self) { mode in
                MihonFilterChip(label: mode.localizedTitle, selected: readingMode == mode) {
                    readingMode = mode
                    if let idx = store.mangas.firstIndex(where: { $0.id == mangaId }) {
                        store.mangas[idx].readingModeOverride = mode
                    }
                }
            }
        }
        MihonChipRow("点按区域") {
            ForEach(TapZoneType.allCases, id: \.self) { zone in
                MihonFilterChip(label: zone.localizedTitle, selected: store.readerTapZone == zone) { store.readerTapZone = zone }
            }
        }
        MihonChipRow("缩放模式") {
            ForEach(ReaderScaleType.allCases, id: \.self) { scale in
                MihonFilterChip(label: scale.rawValue, selected: store.readerScaleType == scale) { store.readerScaleType = scale }
            }
        }
        MihonCheckboxItem("裁剪边缘", checked: store.cropBorders) { store.cropBorders.toggle() }
        MihonCheckboxItem("双击放大", checked: store.doubleTapToZoom) { store.doubleTapToZoom.toggle() }
        MihonHeadingItem("iPhone Duo 双页书本")
        MihonChipRow("双页显示") {
            ForEach(DuoDualPageSpreadBehavior.allCases, id: \.self) { behavior in
                MihonFilterChip(label: behavior.rawValue, selected: store.duoDualPageBehavior == behavior) { store.duoDualPageBehavior = behavior }
            }
        }
        MihonCheckboxItem("封面单独成页", checked: store.shiftDoublePageCover) { store.shiftDoublePageCover.toggle() }
        MihonCheckboxItem("交换左右页顺序", checked: store.invertDoublePageOrder) { store.invertDoublePageOrder.toggle() }
        MihonCheckboxItem("书脊阴影", checked: store.showDuoSpineShadow) { store.showDuoSpineShadow.toggle() }
        MihonChipRow("翻页效果") {
            ForEach(DuoPageTurnStyle.allCases, id: \.self) { style in
                MihonFilterChip(label: style.label, selected: store.duoPageTurnStyle == style) {
                    store.duoPageTurnStyle = style
                    store.duoPageTurnStylePicked = true
                }
            }
        }
        // The 3D tilt belongs to sliding; a curl is its own effect.
        if store.duoPageTurnStyle == .slide {
            MihonCheckboxItem("翻页立体效果", checked: store.duoPageTurnEffect) { store.duoPageTurnEffect.toggle() }
        }
        MihonSliderItem("铰链宽度", value: $store.duoHingeGutterWidth, in: 0...36, step: 2, valueText: "\(Int(store.duoHingeGutterWidth)) pt")
    }

    @ViewBuilder
    private func generalPage(store: MihonRepositoryStore) -> some View {
        MihonChipRow("背景颜色") {
            ForEach(ReaderBackgroundColor.allCases, id: \.self) { bg in
                MihonFilterChip(label: bg.rawValue, selected: store.readerBackground == bg) { store.readerBackground = bg }
            }
        }
        MihonCheckboxItem("显示页码", checked: store.showPageNumber) { store.showPageNumber.toggle() }
        MihonCheckboxItem("保持屏幕常亮", checked: store.keepScreenOn) { store.keepScreenOn.toggle() }
        MihonCheckboxItem("启动时显示点按区域", checked: store.showTapZonesOverlayOnLaunch) { store.showTapZonesOverlayOnLaunch.toggle() }
        MihonCheckboxItem("MangaDex 省流模式", checked: store.mangaDexDataSaver) { store.mangaDexDataSaver.toggle() }
    }

    @ViewBuilder
    private func filterPage(store: MihonRepositoryStore) -> some View {
        @Bindable var store = store
        MihonCheckboxItem("自定义滤镜", checked: store.colorFilter.isEnabled) { store.colorFilter.isEnabled.toggle() }
        MihonSliderItem("亮度", value: $store.colorFilter.customBrightness, in: -0.5...0.3, step: 0.05, valueText: "\(Int(store.colorFilter.customBrightness * 100))")
            .disabled(!store.colorFilter.isEnabled)
            .opacity(store.colorFilter.isEnabled ? 1 : MihonAlpha.disabled)
        MihonSliderItem("红", value: $store.colorFilter.redOverlay, in: 0...1, step: 0.01, valueText: "\(Int(store.colorFilter.redOverlay * 255))")
            .disabled(!store.colorFilter.isEnabled)
            .opacity(store.colorFilter.isEnabled ? 1 : MihonAlpha.disabled)
        MihonSliderItem("绿", value: $store.colorFilter.greenOverlay, in: 0...1, step: 0.01, valueText: "\(Int(store.colorFilter.greenOverlay * 255))")
            .disabled(!store.colorFilter.isEnabled)
            .opacity(store.colorFilter.isEnabled ? 1 : MihonAlpha.disabled)
        MihonSliderItem("蓝", value: $store.colorFilter.blueOverlay, in: 0...1, step: 0.01, valueText: "\(Int(store.colorFilter.blueOverlay * 255))")
            .disabled(!store.colorFilter.isEnabled)
            .opacity(store.colorFilter.isEnabled ? 1 : MihonAlpha.disabled)
        MihonSliderItem("透明度", value: $store.colorFilter.overlayAlpha, in: 0...0.6, step: 0.01, valueText: "\(Int(store.colorFilter.overlayAlpha * 100))%")
            .disabled(!store.colorFilter.isEnabled)
            .opacity(store.colorFilter.isEnabled ? 1 : MihonAlpha.disabled)
        MihonCheckboxItem("灰度", checked: store.colorFilter.grayscale) { store.colorFilter.grayscale.toggle() }
        MihonCheckboxItem("反色", checked: store.colorFilter.inverted) { store.colorFilter.inverted.toggle() }
    }
}
