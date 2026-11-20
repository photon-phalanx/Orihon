import SwiftUI
import MihonDomain
import MihonData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Navigation model

public enum MihonRoute: Hashable {
    case manga(Int64)
    case source(sourceId: Int64, listing: SourceListing, query: String?)
    case globalSearch(query: String?)
    /// Upstream `MigrateSearchScreen`: the title searched across the sources, a result picked to migrate to.
    case migrateSearch(mangaId: Int64)
    case extensionDetails(pkgName: String)
    case settings(MihonSettingsPage)
    /// Upstream's 即将推出 (Updates › calendar).
    case upcoming
}

public enum MihonSettingsPage: Hashable {
    case downloadQueue, categories, statistics, dataStorage
    case main, appearance, library, reader, duo, download, tracking, browse, extensionRepos, security, about
}

/// Screens never talk to `NavigationStack` directly; the root decides whether a manga opens in the right Duo pane
/// (unfolded book posture) or is pushed onto the current tab (folded single screen).
///
/// One stable instance lives for the whole session: screens observe only `isDualPane` / `selectedMangaId`,
/// so root re-renders never cascade into every screen through a changed environment value.
@Observable
public final class MihonNavigator: @unchecked Sendable {
    public internal(set) var isDualPane = false
    public internal(set) var selectedMangaId: Int64?
    fileprivate(set) var bikaAccountRevision = 0
    @ObservationIgnored var openBikaAccount: (URL) -> Void = { _ in }
    @ObservationIgnored var openMangaHandler: (Int64) -> Void = { _ in }
    @ObservationIgnored var openReaderHandler: (Manga, Chapter) -> Void = { _, _ in }
    @ObservationIgnored var pushHandler: (MihonRoute) -> Void = { _ in }

    public init() {}

    public func openManga(_ mangaId: Int64) { openMangaHandler(mangaId) }
    public func openReader(_ manga: Manga, _ chapter: Chapter) { openReaderHandler(manga, chapter) }
    public func push(_ route: MihonRoute) { pushHandler(route) }
}

private struct MihonNavigatorKey: EnvironmentKey {
    static let defaultValue = MihonNavigator()
}

public extension EnvironmentValues {
    var mihonNavigator: MihonNavigator {
        get { self[MihonNavigatorKey.self] }
        set { self[MihonNavigatorKey.self] = newValue }
    }
}

/// Root screens raise this while in action mode to hide the bottom bar (upstream `showBottomNavEvent`).
struct MihonHideBottomBarKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

enum MihonHomeTab: Int, CaseIterable {
    case library, updates, history, browse, more

    var title: String {
        switch self {
        case .library: return "书架"
        case .updates: return "更新"
        case .history: return "历史"
        case .browse: return "浏览"
        case .more: return "更多"
        }
    }

    var icon: (String, String) {
        switch self {
        case .library: return ("books.vertical", "books.vertical.fill")
        case .updates: return ("seal", "seal.fill")
        case .history: return ("clock.arrow.circlepath", "clock.arrow.circlepath")
        case .browse: return ("safari", "safari.fill")
        case .more: return ("ellipsis", "ellipsis")
        }
    }
}

// MARK: - 1:1 Mihon Root Container (iPhone Duo unfolded dual-screen book posture & folded single screen)

public struct MihonRootView: View {
    @State private var store: MihonRepositoryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab: Int = MihonHomeTab.library.rawValue
    @State private var visitedTabs: Set<Int> = [MihonHomeTab.library.rawValue]
    /// One `@State` per NavigationStack path. A stack must bind to a State's own projected value: bindings made
    /// in `body` — `Binding(get:set:)` or a derived `$paths[tab]` — are new objects on every evaluation, and a
    /// window scene evaluates its root several times in its first frame, so each stack reported
    /// "NavigationAuthority bound path tried to update multiple times per frame" at launch.
    @State private var libraryPath: [MihonRoute] = []
    @State private var updatesPath: [MihonRoute] = []
    @State private var historyPath: [MihonRoute] = []
    @State private var browsePath: [MihonRoute] = []
    @State private var morePath: [MihonRoute] = []
    @State private var bottomBarHiddenByContent = false

    // iPhone Duo right screen (live MangaDetailScreen pane)
    @State private var duoSelectedMangaId: Int64?
    @State private var duoDetailPath: [MihonRoute] = []
    @State private var activeReaderSession: ActiveReaderSession?
    @State private var navigator = MihonNavigator()
    @State private var isUnfolded = false
    // iOS has one application scene. Persist opening and closing immediately: a scene snapshot
    // taken during the password-manager switch may still contain a login that was later dismissed.
    // Only the entry route is stored. Credentials stay in the native form until login completes.
    #if os(iOS)
    @AppStorage("orihon.bika.accountRoute") private var bikaAccountRoute: String?
    #else
    @State private var bikaAccountRoute: String?
    #endif
    @State private var appLock: MihonAppLock

    public struct ActiveReaderSession: Identifiable {
        public var id: String { "\(manga.id)-\(chapter.id)" }
        public let manga: Manga
        public let chapter: Chapter
    }

    /// The store is owned by the caller (the app creates exactly one): constructing it here would create a new
    /// store every time SwiftUI re-creates this view.
    public init(store: MihonRepositoryStore) {
        #if DEBUG
        // Simulator screenshots of the lock: `MIHON_APP_LOCK=1` turns "需要解锁" on, `=0` off again.
        if let value = ProcessInfo.processInfo.environment["MIHON_APP_LOCK"] { store.requireBiometricLock = value == "1" }
        // `MIHON_AUTO_UPDATE=<hours>`: automatic updates without the settings screen (simulator checks).
        if let hours = ProcessInfo.processInfo.environment["MIHON_AUTO_UPDATE"].flatMap(Int.init) { store.autoUpdateInterval = hours }
        // `MIHON_KOMGA=<address>|<user>|<password>`: the first Komga instance's login (simulator checks).
        if let login = ProcessInfo.processInfo.environment["MIHON_KOMGA"]?.components(separatedBy: "|"), login.count == 3 {
            // Assigned whole: a subscript write reads the property first, and a read plus a write while the app's
            // body builds this view would rebuild it without end.
            store.komgaAccounts = [KomgaLiveEngine.instanceIds[0]: KomgaAccount(address: login[0], username: login[1], password: login[2])]
        }
        #endif
        _store = State(initialValue: store)
        _appLock = State(initialValue: MihonAppLock(locked: store.requireBiometricLock))
    }

    public var body: some View {
        GeometryReader { geo in
            // The posture follows the window, not the safe area: the keyboard shrinks the latter, and the layout must
            // not fold up (closing the search being typed in) while it shows.
            let window = CGSize(
                width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            )
            let unfolded = store.isUnfoldedDuo(viewportSize: window, horizontalSizeClass: horizontalSizeClass)
            RootChrome(store: store) {
                if unfolded {
                    duoWorkspace(size: geo.size, window: window, insets: geo.safeAreaInsets)
                } else {
                    foldedWorkspace
                }
            }
            .onChange(of: unfolded, initial: true) { _, newValue in
                isUnfolded = newValue
                adaptPathsForPosture(unfolded: newValue)
                syncNavigatorState()
            }
        }
        // Keep the native account form above both layouts, including during password-manager switches.
        .allowsHitTesting(bikaAccountRoute == nil)
        .accessibilityHidden(bikaAccountRoute != nil)
        .overlay {
            if bikaAccountRoute != nil {
                BikaAccountSheet {
                    BikaWebsite.endAccountEditing()
                    bikaAccountRoute = nil
                    navigator.bikaAccountRevision += 1
                }
                .onAppear { BikaWebsite.beginAccountEditing() }
                .background(.background, ignoresSafeAreaEdges: .all)
                .accessibilityAddTraits(.isModal)
            }
        }
        .environment(\.mihonNavigator, navigator)
        .onAppear(perform: installNavigatorHandlers)
        .onAppear(perform: startRuntimeSelfCheck)
        .onAppear { MihonLibraryUpdateScheduler.schedule(store) }
        // An automatic backup due since the last session, once the launch has settled.
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await store.performAutomaticBackupIfDue()
        }
        // A tapped "new chapters" notification.
        .onChange(of: MihonDeepLinks.shared.openUpdatesRequest) { _, _ in
            activeReaderSession = nil
            select(tab: MihonHomeTab.updates.rawValue)
        }
        #if DEBUG
        .task { await runSmokeScript() }
        .task { await openReaderFromEnvironment() }
        #endif
        .onChange(of: duoSelectedMangaId) { _, _ in syncNavigatorState() }
        .environment(store)
        .mihonTheme(store.themePalette, pureBlack: store.pureBlackDarkMode)
        .preferredColorScheme(store.darkMode.colorScheme)
        .modifier(MihonAppLockModifier(store: store, lock: appLock))
        #if os(iOS)
        .fullScreenCover(item: $activeReaderSession) { session in
            readerScreen(session)
        }
        #else
        .sheet(item: $activeReaderSession) { session in
            readerScreen(session)
                .frame(minWidth: 960, minHeight: 720)
        }
        #endif
    }

    private func readerScreen(_ session: ActiveReaderSession) -> some View {
        MangaReaderScreen(manga: session.manga, initialChapter: session.chapter, showMenuInitially: Self.readerMenuAtLaunch) {
            activeReaderSession = nil
        }
        .environment(store)
        .mihonTheme(store.themePalette, pureBlack: store.pureBlackDarkMode)
        .preferredColorScheme(store.darkMode.colorScheme)
    }

    // MARK: Runtime self-check (DEBUG)

    /// DEBUG builds watch their own unified log and surface SwiftUI runtime issues (AttributeGraph cycles,
    /// state mutated during updates, NavigationStack path faults) the moment they happen while you click around.
    private func startRuntimeSelfCheck() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        MihonRuntimeIssueMonitor.shared.start { [store] issue in
            store.showStatusBanner("⚠️ SwiftUI 运行时问题：\(issue.message.prefix(80))")
        }
        #endif
    }

    private static var readerMenuAtLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MIHON_READER_MENU"] != nil
        #else
        false
        #endif
    }

    #if DEBUG
    /// Simulator screenshots without UI automation: `MIHON_START_TAB=<library|updates|history|browse|more>` opens
    /// that tab, `MIHON_OPEN_SOURCE=<sourceId>` that source's popular listing, `MIHON_OPEN_SETTINGS=<page>` a settings
    /// page, `MIHON_GLOBAL_SEARCH=<query>` a global
    /// search, `MIHON_OPEN_MANGA=<mangaId>` that
    /// title's details, `MIHON_OPEN_READER=<mangaId>` its first chapter at launch (`MIHON_READER_MENU=1` shows the
    /// reader menu right away). `MIHON_OPEN_LOCAL=<folder>` adds that local-source title to the store; the two take
    /// `local` for its id.
    private func openReaderFromEnvironment() async {
        let environment = ProcessInfo.processInfo.environment
        let localId = environment["MIHON_OPEN_LOCAL"].map { folder in
            store.upsertCatalogMangaToStore(SManga(url: folder, title: folder), sourceId: MihonLocalSource.sourceId).id
        }
        func mangaId(_ key: String) -> Int64? {
            guard let raw = environment[key] else { return nil }
            return raw == "local" ? localId : Int64(raw)
        }
        // `MIHON_DUO_SPREAD=<auto|always|single>` and `MIHON_DUO_TURN=<curl|slide>`: the Duo spread settings (the
        // turn style for this launch only: not picked, so the next launch is back on the default).
        let spreads: [String: DuoDualPageSpreadBehavior] = ["auto": .autoWhenUnfolded, "always": .alwaysDualPage, "single": .singlePageOnly]
        if let behavior = environment["MIHON_DUO_SPREAD"].flatMap({ spreads[$0] }) { store.duoDualPageBehavior = behavior }
        let turns: [String: DuoPageTurnStyle] = ["curl": .curl, "slide": .slide]
        if let style = environment["MIHON_DUO_TURN"].flatMap({ turns[$0] }) { store.duoPageTurnStyle = style }
        if let name = environment["MIHON_START_TAB"], let tab = MihonHomeTab.allCases.first(where: { "\($0)" == name }) {
            select(tab: tab.rawValue)
        }
        if let raw = environment["MIHON_OPEN_SOURCE"], let sourceId = Int64(raw) {
            select(tab: MihonHomeTab.browse.rawValue)
            try? await Task.sleep(nanoseconds: 300_000_000)
            navigator.push(.source(sourceId: sourceId, listing: .popular, query: nil))
        }
        // `MIHON_OPEN_SETTINGS=<page>` (security, download, library, dataStorage, …): that settings page.
        if let name = environment["MIHON_OPEN_SETTINGS"],
           let page = [MihonSettingsPage.main, .appearance, .library, .reader, .duo, .download, .browse, .dataStorage, .security, .about]
               .first(where: { "\($0)" == name }) {
            select(tab: MihonHomeTab.more.rawValue)
            try? await Task.sleep(nanoseconds: 300_000_000)
            navigator.push(.settings(page))
        }
        if let query = environment["MIHON_GLOBAL_SEARCH"] {
            select(tab: MihonHomeTab.browse.rawValue)
            try? await Task.sleep(nanoseconds: 300_000_000)
            navigator.push(.globalSearch(query: query))
        }
        if let mangaId = mangaId("MIHON_OPEN_MANGA") {
            try? await Task.sleep(nanoseconds: 300_000_000)
            navigator.openManga(mangaId)
        }
        guard let id = mangaId("MIHON_OPEN_READER") else { return }
        // `MIHON_READING_MODE=<0…5>` (`ReadingMode`'s raw value, 0 the default): the title's reading mode (saved).
        if let mode = environment["MIHON_READING_MODE"].flatMap(Int.init).flatMap(ReadingMode.init(rawValue:)),
           let index = store.mangas.firstIndex(where: { $0.id == id }) {
            store.mangas[index].readingModeOverride = mode
        }
        // Live titles fetch their chapter list after launch (in library order); fetch this one right away.
        if store.chaptersByManga[id]?.isEmpty ?? true {
            await store.refreshMangaFromSource(mangaId: id)
        }
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let manga = store.manga(id: id), let chapter = store.filteredAndSortedChapters(for: manga).last {
                activeReaderSession = ActiveReaderSession(manga: manga, chapter: chapter)
                #if canImport(UIKit)
                // `MIHON_TOUCH_SCRIPT`: finger drags over the reader.
                Task { await MihonTouchDriver.runFromEnvironment() }
                #endif
                return
            }
        }
    }

    /// `MIHON_SMOKE_TEST` (see `MihonSmokeTest`): replays navigation inside the real window scene through the same
    /// handlers user input reaches. No reader and no library edits, so a smoke run leaves the user's data untouched.
    private func runSmokeScript() async {
        guard MihonSmokeTest.requestedDuration != nil else { return }
        func settle() async { try? await Task.sleep(nanoseconds: 450_000_000) }
        await settle()
        let mangaIds = store.libraryItems(forCategory: -1, searchQuery: "").prefix(3).map(\.id)
        for id in mangaIds {
            navigator.openManga(id)
            await settle()
        }
        for tab in MihonHomeTab.allCases {
            select(tab: tab.rawValue)
            await settle()
        }
        // Global search fans out to every source at once.
        select(tab: MihonHomeTab.browse.rawValue)
        navigator.push(.globalSearch(query: "恋爱"))
        for _ in 0..<4 { await settle() }
        reselect(tab: MihonHomeTab.browse.rawValue)
        await settle()
        navigator.push(.settings(.main))
        await settle()
        navigator.push(.settings(.appearance))
        await settle()
        reselect(tab: selectedTab)
        await settle()
        let posture = store.duoPostureMode
        store.duoPostureMode = .foldedSingle
        await settle()
        if let id = mangaIds.first {
            navigator.openManga(id)
            await settle()
        }
        store.duoPostureMode = .unfoldedBook
        await settle()
        select(tab: MihonHomeTab.library.rawValue)
        await settle()
        store.duoPostureMode = posture
        await settle()
        MihonSmokeTest.finishScript()
    }
    #endif

    // MARK: Navigator

    private func installNavigatorHandlers() {
        if bikaAccountRoute != nil && browsePath.isEmpty {
            select(tab: MihonHomeTab.browse.rawValue)
            browsePath = [.source(sourceId: BikaWebsite.sourceId, listing: .popular, query: nil)]
        }
        navigator.openBikaAccount = { url in
            BikaWebsite.beginAccountEditing()
            bikaAccountRoute = url == BikaWebsite.loginURL ? "login" : "profile"
        }
        navigator.openReaderHandler = { manga, chapter in
            activeReaderSession = ActiveReaderSession(manga: manga, chapter: chapter)
        }
        navigator.pushHandler = { route in
            pathBinding(selectedTab).wrappedValue.append(route)
        }
        navigator.openMangaHandler = { mangaId in
            if isUnfolded {
                guard mangaId != duoSelectedMangaId || !duoDetailPath.isEmpty else { return }
                if !duoDetailPath.isEmpty { duoDetailPath = [] }
                withAnimation(.easeInOut(duration: 0.2)) { duoSelectedMangaId = mangaId }
            } else {
                pathBinding(selectedTab).wrappedValue.append(.manga(mangaId))
            }
        }
    }

    private func syncNavigatorState() {
        if isUnfolded && duoSelectedMangaId == nil {
            duoSelectedMangaId = defaultDuoMangaId
        }
        let selected = isUnfolded ? duoSelectedMangaId : nil
        if navigator.isDualPane != isUnfolded { navigator.isDualPane = isUnfolded }
        if navigator.selectedMangaId != selected { navigator.selectedMangaId = selected }
    }

    private var defaultDuoMangaId: Int64? {
        store.libraryItems(forCategory: -1, searchQuery: "").first?.id ?? store.mangas.first?.id
    }

    /// Folding moves an open detail into the left stack; unfolding lifts it into the right screen.
    /// Each stack's path is written at most once.
    private func adaptPathsForPosture(unfolded: Bool) {
        if unfolded {
            for tab in MihonHomeTab.allCases.map(\.rawValue) {
                let path = pathBinding(tab)
                if case .manga(let id) = path.wrappedValue.last {
                    duoSelectedMangaId = id
                    path.wrappedValue.removeAll { if case .manga = $0 { return true } else { return false } }
                }
            }
        } else if let id = duoSelectedMangaId, pathBinding(selectedTab).wrappedValue.isEmpty,
                  selectedTab != MihonHomeTab.library.rawValue {
            pathBinding(selectedTab).wrappedValue = [.manga(id)]
        }
    }

    private func pathBinding(_ tab: Int) -> Binding<[MihonRoute]> {
        switch MihonHomeTab(rawValue: tab) ?? .library {
        case .library: $libraryPath
        case .updates: $updatesPath
        case .history: $historyPath
        case .browse: $browsePath
        case .more: $morePath
        }
    }


    private var navigationItems: [MihonNavigationItem] {
        MihonHomeTab.allCases.map { tab in
            var badge: Int?
            if tab == .updates {
                let count = store.newUpdatesCount
                badge = count > 0 ? count : nil
            } else if tab == .browse {
                let count = store.extensions.lazy.filter { $0.installState == .hasUpdate }.count
                badge = count > 0 ? count : nil
            }
            return MihonNavigationItem(id: tab.rawValue, title: tab.title, icon: tab.icon.0, selectedIcon: tab.icon.1, badge: badge)
        }
    }

    // MARK: Tab stacks

    @ViewBuilder
    private func tabStack(_ tab: Int) -> some View {
        NavigationStack(path: pathBinding(tab)) {
            tabRoot(tab)
                .mihonHideSystemNavigationBar()
                .navigationDestination(for: MihonRoute.self) { route in
                    MihonRouteDestination(route: route)
                        .mihonHideSystemNavigationBar()
                }
        }
    }

    @ViewBuilder
    private func tabRoot(_ tab: Int) -> some View {
        switch MihonHomeTab(rawValue: tab) ?? .library {
        case .library: LibraryScreen()
        case .updates: UpdatesScreen()
        case .history: HistoryScreen()
        case .browse: BrowseScreen()
        case .more: MoreScreen()
        }
    }

    private func select(tab: Int) {
        visitedTabs.insert(tab)
        selectedTab = tab
        if tab == MihonHomeTab.updates.rawValue {
            store.resetNewUpdatesCount()
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(get: { selectedTab }, set: { select(tab: $0) })
    }

    /// Re-selecting a tab pops it to its root (upstream `Tab.onReselect`).
    private func reselect(tab: Int) {
        let path = pathBinding(tab)
        if !path.wrappedValue.isEmpty { path.wrappedValue = [] }
    }

    /// Keeps every visited tab alive (scroll position & stacks survive tab switches like upstream's saveableState).
    private var tabContainer: some View {
        ZStack {
            ForEach(MihonHomeTab.allCases, id: \.rawValue) { tab in
                if visitedTabs.contains(tab.rawValue) {
                    let isSelected = tab.rawValue == selectedTab
                    tabStack(tab.rawValue)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .environment(\.mihonContentHidden, !isSelected)
                        // A selection left on a tab kept alive behind the current one does not hide the bar.
                        .transformPreference(MihonHideBottomBarKey.self) { if !isSelected { $0 = false } }
                        .zIndex(isSelected ? 1 : 0)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .onPreferenceChange(MihonHideBottomBarKey.self) { hidden in
            bottomBarHiddenByContent = hidden
        }
    }

    // MARK: Folded single-screen workspace (NavigationBar at the bottom)

    private var foldedWorkspace: some View {
        let showBar = pathBinding(selectedTab).wrappedValue.isEmpty && !bottomBarHiddenByContent
        return VStack(spacing: 0) {
            tabContainer
            if showBar {
                MihonNavigationBar(items: navigationItems, selection: tabSelection, onReselect: reselect(tab:))
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showBar)
    }

    // MARK: iPhone Duo unfolded workspace (left screen | physical hinge | right screen)

    private func duoWorkspace(size: CGSize, window: CGSize, insets: EdgeInsets) -> some View {
        // The physical hinge keeps content off its width; an iPad (or a phone forced into this layout) gets a hairline.
        let hasHinge = MihonRepositoryStore.hasHinge(viewportSize: window)
        let hinge = hasHinge ? max(0, CGFloat(store.duoHingeGutterWidth)) : 1
        let split = DuoSplit(width: size.width, hinge: hinge, insets: insets)
        return HStack(spacing: 0) {
            // Left screen: NavigationRail + primary destination
            HStack(spacing: 0) {
                MihonNavigationRail(items: navigationItems, selection: tabSelection, onReselect: reselect(tab:))
                tabContainer
            }
            .frame(width: split.leading)
            .clipped()

            if hasHinge {
                DuoHingeView(width: hinge)
            } else {
                DuoPaneDivider(width: hinge)
            }

            // Right screen: live manga detail
            NavigationStack(path: $duoDetailPath) {
                Group {
                    if let mangaId = duoSelectedMangaId {
                        MangaDetailScreen(mangaId: mangaId)
                            .id(mangaId)
                            .transition(.opacity)
                    } else {
                        DuoEmptyDetailPane()
                    }
                }
                .mihonHideSystemNavigationBar()
                .navigationDestination(for: MihonRoute.self) { route in
                    MihonRouteDestination(route: route)
                        .mihonHideSystemNavigationBar()
                }
            }
            .frame(width: split.trailing)
            .clipped()
        }
    }
}

// MARK: - Shared chrome (app-state banners + snackbar)

private struct RootChrome<Content: View>: View {
    let store: MihonRepositoryStore
    @ViewBuilder let content: () -> Content
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    var body: some View {
        VStack(spacing: 0) {
            // 1:1 with upstream `AppStateBanners`
            if store.downloadedOnlyMode {
                banner("仅限已下载内容", background: colors.tertiary, foreground: colors.onTertiary)
            }
            if store.incognitoMode {
                banner("无痕模式", background: colors.primary, foreground: colors.onPrimary)
            }
            content()
        }
        .background(colors.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let message = store.statusBannerMessage {
                MihonSnackbar(message: message)
                    .padding(.bottom, navigator.isDualPane ? 16 : 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(message)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: store.statusBannerMessage)
    }

    private func banner(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(MihonType.labelMedium)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(4)
            .background(background.ignoresSafeArea(edges: .top))
    }
}

struct MihonRouteDestination: View {
    let route: MihonRoute
    @Environment(MihonRepositoryStore.self) private var store

    var body: some View {
        switch route {
        case .manga(let id):
            MangaDetailScreen(mangaId: id)
        case .source(let sourceId, let listing, let query):
            BrowseSourceScreen(sourceId: sourceId, listing: listing, initialQuery: query)
        case .globalSearch(let query):
            GlobalSearchScreen(initialQuery: query)
        case .migrateSearch(let mangaId):
            GlobalSearchScreen(initialQuery: store.manga(id: mangaId)?.title, migratingMangaId: mangaId)
        case .extensionDetails(let pkgName):
            ExtensionDetailsScreen(pkgName: pkgName)
        case .settings(let page):
            MihonSettingsDestination(page: page)
        case .upcoming:
            UpcomingScreen()
        }
    }
}

/// Widths of the two iPhone Duo screens inside a container of `width` (its safe area). The fold runs down the
/// middle of the whole display, but side insets are not symmetric (each screen's status strip sits on its right
/// edge), so the split follows the display's centre rather than the centre of the safe area.
struct DuoSplit {
    let leading: CGFloat
    let trailing: CGFloat

    init(width: CGFloat, hinge: CGFloat, insets: EdgeInsets = EdgeInsets()) {
        let fold = (width + insets.leading + insets.trailing) / 2 - insets.leading
        leading = min(max(0, fold - hinge / 2), max(0, width - hinge))
        trailing = max(0, width - leading - hinge)
    }
}

/// Between the two panes on a screen without a hinge (iPad): a hairline.
private struct DuoPaneDivider: View {
    let width: CGFloat
    @Environment(\.mihonColors) private var colors

    var body: some View {
        Rectangle()
            .fill(colors.outlineVariant)
            .frame(width: width)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// The physical iPhone Duo hinge: content never renders underneath it.
struct DuoHingeView: View {
    let width: CGFloat

    var body: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [.white.opacity(0.07), .clear, .clear, .white.opacity(0.05)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .frame(width: width)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct DuoEmptyDetailPane: View {
    @Environment(\.mihonColors) private var colors

    var body: some View {
        VStack(spacing: 16) {
            MihonLogoMark()
                .fill(colors.onSurface.opacity(0.12))
                .frame(width: 72, height: 68)
            Text("在左侧屏幕选择一部作品")
                .font(MihonType.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
    }
}

// MARK: - Interactive swipe-back with a hidden navigation bar (root screens draw Material app bars)

#if canImport(UIKit)
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
#endif
