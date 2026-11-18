import Foundation
import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#endif
import MihonDomain
import MihonAPKEngine

// MARK: - Download task (observed per row so progress ticks only redraw the row that owns it)

@MainActor
@Observable
public final class MihonDownloadTask: Identifiable {
    public let id: Int64
    public let manga: Manga
    public let chapter: Chapter
    public let sourceName: String
    public var status: DownloadStatus
    public var downloadedPages: Int
    public var totalPages: Int
    public var errorMessage: String?

    public var progress: Double {
        guard totalPages > 0 else { return 0 }
        return min(1, Double(downloadedPages) / Double(totalPages))
    }

    init(manga: Manga, chapter: Chapter, sourceName: String, status: DownloadStatus, totalPages: Int) {
        self.id = chapter.id
        self.manga = manga
        self.chapter = chapter
        self.sourceName = sourceName
        self.status = status
        self.downloadedPages = 0
        self.totalPages = totalPages
    }
}

// MARK: - Central Orihon Data Store (1:1 Architecture with Mihon Interactors + Repositories)
//
// `@Observable` gives SwiftUI per-property dependency tracking: a screen only re-renders when a property it
// actually read changes. Expensive derived collections (library grid, chapter lists, catalogue sources) are
// memoized behind a revision counter so they are rebuilt at most once per mutation instead of on every redraw.

/// Launch-time switches for the app target.
public enum MihonFeatureFlags {
    /// Tester builds show the live sources. Development previews can also show simulated extensions and trackers.
    public static var showsDemoFeatures: Bool {
        ProcessInfo.processInfo.environment["MIHON_DEMO_FEATURES"] == "1"
    }
}

@MainActor
@Observable
public final class MihonRepositoryStore {
    // MARK: - Global App & Appearance State
    public var themePalette: MihonThemePalette = .mihonDefault
    public var darkMode: DarkModePreference = .system
    public var pureBlackDarkMode: Bool = false
    public var incognitoMode: Bool = false
    public var downloadedOnlyMode: Bool = false { didSet { invalidateLibrary(); invalidateChapters() } }
    public var requireBiometricLock: Bool = false
    /// Upstream "Automatic updates", in hours (`MihonLibraryUpdateInterval.choices`; 0: off, upstream's default).
    public var autoUpdateInterval: Int = 0
    /// When the library last finished an update (the next automatic one is due an interval later).
    public var lastLibraryUpdateAt: Date?
    /// Upstream "Automatic updates device restrictions" (Wi-Fi only by default).
    public var libraryUpdateDeviceRestrictions: Set<LibraryUpdateDeviceRestriction> = LibraryUpdateDeviceRestriction.defaults
    /// Upstream "Smart update": which titles every library update skips (all four rules by default).
    public var libraryUpdateMangaRestrictions: Set<LibraryUpdateMangaRestriction> = LibraryUpdateMangaRestriction.defaults
    /// Upstream "Categories" (include / exclude): a global update checks titles in an included category (any, when
    /// none is), never one in an excluded category. A category's own update ignores both.
    public var libraryUpdateIncludedCategories: Set<Int64> = []
    public var libraryUpdateExcludedCategories: Set<Int64> = []
    /// Upstream "Automatically refresh metadata": library updates fetch the details (cover, description) too.
    public var libraryUpdateRefreshesMetadata = false
    /// When a library update last checked each title: the next one starts with those checked longest ago.
    public var libraryUpdateCheckedAt: [Int64: Date] = [:]
    /// Upstream `UpcomingPreferences`: the categories 即将推出 shows (any, when none is) and hides.
    public var upcomingIncludedCategories: Set<Int64> = []
    public var upcomingExcludedCategories: Set<Int64> = []
    /// Names of sources this build lacks, from restored upstream backups (upstream `StubSource`).
    public var stubSourceNames: [Int64: String] = [:]
    /// Upstream "Lock when idle", in minutes (`MihonAppLockPolicy.lockAfterChoices`).
    public var lockAppAfter: Int = 0
    public var secureScreen: SecureScreenMode = .incognito

    // MARK: - Library Preferences
    public var libraryDisplayMode: LibraryDisplayMode = .compactGrid
    public var librarySortOption: LibrarySortOption = .lastRead { didSet { invalidateLibrary() } }
    public var librarySortAscending: Bool = false { didSet { invalidateLibrary() } }
    public var libraryFilter: LibraryFilterState = LibraryFilterState() { didSet { invalidateLibrary() } }
    public var showUnreadBadge: Bool = true
    public var showDownloadBadge: Bool = true
    public var showLocalBadge: Bool = true
    public var showLanguageBadge: Bool = false
    public var showCategoryTabs: Bool = true
    /// Upstream "Default category": -1 asks every time (upstream's default), 0 is the default category, otherwise a
    /// category id.
    public var defaultLibraryCategory: Int64 = -1
    public var showMangaCountInCategory: Bool = false
    public var showContinueReadingButton: Bool = true
    /// 0 = adaptive (upstream `GridCells.Adaptive(128.dp)`), otherwise a fixed column count.
    public var columnsPerRowPortrait: Int = 3

    // MARK: - Reader Preferences
    public var defaultReadingMode: ReadingMode = .rightToLeft
    public var readerTapZone: TapZoneType = .defaultZone
    public var readerBackground: ReaderBackgroundColor = .black
    public var readerScaleType: ReaderScaleType = .fitScreen
    public var cropBorders: Bool = false
    public var showPageNumber: Bool = true
    public var keepScreenOn: Bool = true
    public var showTapZonesOverlayOnLaunch: Bool = false
    public var volumeKeysScroll: Bool = false
    public var doubleTapToZoom: Bool = true
    /// Upstream `ReaderPreferences.skipRead` / `skipFiltered` / `skipDupe` (`readerChapters`).
    public var skipReadChapters = false
    public var skipFilteredChapters = true
    public var skipDuplicateChapters = false
    public var colorFilter: ReaderColorFilterState = ReaderColorFilterState()
    public var mangaDexDataSaver: Bool = false { didSet { invalidateSources() } }
    /// Upstream's Komga source preferences per instance (`KomgaLiveEngine.instanceIds`), kept in the Keychain.
    public var komgaAccounts: [Int64: KomgaAccount] = [:] {
        didSet {
            guard komgaAccounts != oldValue else { return }
            invalidateSources()
            Self.forgetServerCookies(Array(oldValue.values) + Array(komgaAccounts.values))
            Self.registerServerLogins(komgaAccounts)
            if persistsState, let data = try? JSONEncoder().encode(komgaAccounts) {
                MihonSecretStore.set(data, for: Self.komgaAccountsKey)
            }
        }
    }

    // MARK: - iPhone Duo (Dual-Screen / Foldable) Preferences
    public var duoPostureMode: iPhoneDuoPostureMode = .autoDetect
    public var duoDualPageBehavior: DuoDualPageSpreadBehavior = .autoWhenUnfolded
    /// Off by default, as upstream: a web chapter's first page is rarely a cover, and on the iPhone Duo a lone
    /// first page leaves the other screen blank.
    public var shiftDoublePageCover: Bool = false
    public var invertDoublePageOrder: Bool = false
    public var duoHingeGutterWidth: Double = 14.0
    public var showDuoSpineShadow: Bool = true
    public var duoPageTurnEffect: Bool = true
    /// Both pages slide by default; the printed-book curl is opt-in while it is being tested (`DuoPageTurnStyle`).
    public var duoPageTurnStyle: DuoPageTurnStyle = .slide
    /// Set when the style is picked in settings (`MihonSettingsSnapshot.duoPageTurnStylePicked`).
    public var duoPageTurnStylePicked = false

    /// The iPhone Duo's inner display held open like a book, the hinge running down its middle. iPads are flat; the
    /// macOS preview stands in for the Duo.
    public static func hasHinge(viewportSize: CGSize) -> Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && isOpenBookShaped(viewportSize)
        #else
        true
        #endif
    }

    /// A phone window in landscape whose short side no single-screen iPhone reaches (they stop at 440 pt; the Duo's
    /// inner display is 669 pt, its cover display 466 pt). Callers pass the window size: the safe area shrinks
    /// while the keyboard shows.
    nonisolated static func isOpenBookShaped(_ viewportSize: CGSize) -> Bool {
        viewportSize.width > viewportSize.height && viewportSize.height >= 520
    }

    public func isUnfoldedDuo(viewportSize: CGSize, horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        switch duoPostureMode {
        case .unfoldedBook:
            return true
        case .foldedSingle:
            return false
        case .tabletopTent:
            return true
        case .autoDetect:
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                // Only the Duo's inner display: a single-screen iPhone in landscape keeps one pane, as upstream
                // phones do.
                return Self.hasHinge(viewportSize: viewportSize)
            }
            #endif
            #if os(macOS)
            // macOS always reports a regular size class; the preview window's width stands in for the hinge.
            let regularWidth = false
            #else
            let regularWidth = horizontalSizeClass == .regular
            #endif
            return viewportSize.width >= 680 ||
                (viewportSize.width > viewportSize.height * 0.85 && viewportSize.width >= 560) ||
                regularWidth
        }
    }

    // MARK: - Core Data Collections
    // Each of these is part of the saved snapshot (`MihonBackupPayload`), so changing one schedules a save.
    public var mangas: [Manga] = [] { didSet { mangaIndexDirty = true; invalidateLibrary(); invalidateChapters(); scheduleBackgroundPersistence() } }
    public var categories: [MangaCategory] = [] { didSet { invalidateLibrary(); scheduleBackgroundPersistence() } }
    public var mangaCategories: [Int64: [Int64]] = [:] { didSet { invalidateLibrary(); scheduleBackgroundPersistence() } }
    public var chaptersByManga: [Int64: [Chapter]] = [:] {
        didSet { if !keepsLibraryCache { invalidateLibrary() }; invalidateChapters(); scheduleBackgroundPersistence() }
    }
    public var historyEntries: [HistoryEntry] = [] { didSet { if !keepsLibraryCache { invalidateLibrary() }; scheduleBackgroundPersistence() } }
    /// Set around a reading-progress write that changes nothing the library shows (no read mark, the title already
    /// the last read): rebuilding the library on every page turn stalled the turn's first frames under the reader.
    @ObservationIgnored private var keepsLibraryCache = false
    public var tracksByManga: [Int64: [Track]] = [:] { didSet { invalidateLibrary(); scheduleBackgroundPersistence() } }
    public var trackers: [TrackerServiceInfo] = []

    // MARK: - Downloads & Extensions & APK State
    public private(set) var downloadQueue: [MihonDownloadTask] = []
    public var downloadedChapterIds: Set<Int64> = [] { didSet { invalidateLibrary(); invalidateChapters() } }
    public var isDownloaderRunning: Bool = true
    public var deleteAfterReading: Bool = false
    /// Custom covers by title (their file's version, `MihonCustomCovers`); `coverUrl(for:)` prefers them.
    public private(set) var customCoverVersions: [Int64: Int64] = MihonCustomCovers.versions()
    /// Upstream "Automatic backups", in hours (`MihonAutoBackup.intervalChoices`; 0: off; upstream's default 12).
    public var autoBackupInterval: Int = MihonAutoBackup.defaultInterval
    public var lastAutoBackupAt: Date?
    @ObservationIgnored private var isWritingAutoBackup = false
    /// Titles being migrated (a second migration of the same title waits its turn — it is refused).
    public private(set) var migratingMangaIds: Set<Int64> = []
    /// Upstream `migrationFlags` (every flag by default).
    public var migrationFlags: Set<MigrationFlag> = Set(MigrationFlag.allCases)
    /// Upstream "Download new chapters": what a library update finds is queued for download.
    public var downloadNewChapters: Bool = false
    /// Upstream "Auto download while reading" (`downloadAheadChoices`; 0: off).
    public var downloadAheadCount: Int = 0
    public static let downloadAheadChoices = [0, 2, 3, 5, 10]

    public var extensions: [ExtensionModel] = [] { didSet { invalidateSources(); invalidateLibrary() } }
    public var extensionRepos: [ExtensionRepo] = [] { didSet { scheduleBackgroundPersistence() } }
    public var enabledLanguages: Set<String> = ["zh", "en", "ja", "all"] { didSet { invalidateSources() } }
    public var showNsfwSources: Bool = false { didSet { invalidateSources() } }
    public var pinnedSourceIds: Set<Int64> = []
    public var lastUsedSourceId: Int64?
    public var apkInspectionsByPkg: [String: APKAndroidPackageInspection] = [:] { didSet { invalidateSources() } }
    public var apkBridgeConfig: APKBridgeConfiguration = APKBridgeConfiguration()
    public var isUpdatingLibrary: Bool = false
    public var libraryUpdateProgress: Double = 0.0
    /// Chapters found by library updates since the Updates tab was last opened (navigation badge).
    public private(set) var newUpdatesCount: Int = 0
    private var importedRules: [Int64: HTMLSourceRule] = [:]
    private static let rulesKey = "orihon.html-source-rules.v1"
    public var importedSourceDescriptors: [ExtensionSourceDescriptor] {
        extensions.filter { $0.pkgName.hasPrefix("org.orihon.import.") }.flatMap(\.sources)
    }

    public var isSyncingExtensionRepos: Bool = false
    public var statusBannerMessage: String?
    /// Manga ids whose details/chapters are currently being fetched from their source.
    public private(set) var refreshingMangaIds: Set<Int64> = []

    // MARK: - Memoization (revision counters are observed; the caches themselves are not)
    public private(set) var libraryRevision: Int = 0
    public private(set) var chaptersRevision: Int = 0
    public private(set) var sourcesRevision: Int = 0

    @ObservationIgnored private var libraryCache: LibraryCache?
    @ObservationIgnored private var chapterListCache: [Int64: [Chapter]] = [:]
    @ObservationIgnored private var nextUnreadCache: [Int64: Chapter?] = [:]
    @ObservationIgnored private var readingOrderCache: [Int64: [Chapter]] = [:]
    @ObservationIgnored private var readerChaptersCache: [String: [Chapter]] = [:]
    @ObservationIgnored private var upcomingCache: (key: String, titles: [Manga])?
    @ObservationIgnored private var sourcesCache: [APKSynthesizedHttpSource]?
    @ObservationIgnored private var sourceDescriptorIndex: [Int64: ExtensionSourceDescriptor]?
    @ObservationIgnored private var mangaIndex: [Int64: Int] = [:]
    @ObservationIgnored private var mangaIndexDirty = true
    /// Page lists with the time they were fetched: live image URLs expire (`pageList(for:chapter:)`).
    @ObservationIgnored private var pageListCache: [Int64: (pages: [Page], fetched: Date)] = [:]
    /// Bumped when a restored backup reassigns chapter ids, so page lists requested before are not cached.
    @ObservationIgnored private var pageListGeneration = 0
    /// Bumped when a restored backup replaces the library: details and chapter lists requested before it belong to
    /// whatever title had that id, so they are dropped.
    @ObservationIgnored private var libraryGeneration = 0
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    #endif
    /// Read chapters whose download goes once the reader closes (`deletePendingReadChapters`); saved with the
    /// settings, so a chapter still pending when the app is ended goes at the next launch.
    var chaptersPendingDeletion: Set<Int64> = []
    @ObservationIgnored private var didSweepDownloads = false
    /// The saved download queue, re-queued once the library is restored (`restoreDownloadQueue`).
    @ObservationIgnored var queuedChapterIdsToRestore: [Int64] = []
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundDownloadTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    @ObservationIgnored private var downloadTasksById: [Int64: MihonDownloadTask] = [:]
    @ObservationIgnored private var pendingExtensionUpdates: [String: ExtensionModel] = [:]
    @ObservationIgnored private var nextChapterId: Int64 = 50_000

    @ObservationIgnored private let apkSynthesizer = APKSourceSynthesizer()
    @ObservationIgnored private let binaryInspector = APKBinaryDexInspector()
    @ObservationIgnored private var downloadWorker: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    private struct LibraryCache {
        var allItems: [LibraryMangaItem]
        var itemsByCategory: [Int64: [LibraryMangaItem]]
        var searchResults: [String: [LibraryMangaItem]] = [:]
    }

    #if DEBUG
    /// Stores created in this process; the app must create exactly one (see `MihonSmokeTest`).
    @ObservationIgnored public nonisolated(unsafe) static var instanceCount = 0
    #endif

    /// False in builds for testers, which keep only what is real (see `MihonFeatureFlags.showsDemoFeatures`).
    public let showsDemoFeatures: Bool
    /// Only the app's store restores the library saved by the previous launch and keeps saving it: test stores
    /// must neither read that file nor overwrite it.
    private let persistsState: Bool
    /// The saved library exists but could not be read at launch (`MihonDiskPersistenceManager.SnapshotLoad`).
    @ObservationIgnored var persistenceBlocked = false

    public init(bootstrapNetwork: Bool = true, showsDemoFeatures: Bool = true, persistsState: Bool = false) {
        self.showsDemoFeatures = showsDemoFeatures
        self.persistsState = persistsState
        #if DEBUG
        Self.instanceCount += 1
        #endif
        seedInitialMihonEcosystemData()
        if persistsState {
            if let data = UserDefaults.standard.data(forKey: Self.rulesKey),
               let rules = try? JSONDecoder().decode([HTMLSourceRule].self, from: data) {
                for rule in rules { if let valid = try? rule.validated() { installRule(valid) } }
            }
            MihonLocalStorage.createRootDirectory()
            if let data = MihonSecretStore.data(for: Self.komgaAccountsKey),
               let saved = try? JSONDecoder().decode([Int64: KomgaAccount].self, from: data) {
                komgaAccounts = saved
            }
            let seededLibrary = mangas
            let seededCategories = mangaCategories
            let saved = UserDefaults.standard.integer(forKey: Self.librarySeedVersionKey)
            switch MihonDiskPersistenceManager.loadSnapshotSynchronously() {
            case .loaded(let snapshot):
                apply(snapshot)
                if saved < Self.librarySeedVersion {
                    migrateRestoredLibrary(fromSeedVersion: saved, seeded: seededLibrary, seededCategories: seededCategories)
                    // On disk before the version marks it done: a kill within the save debounce would otherwise
                    // skip the migration for good.
                    try? MihonDiskPersistenceManager.saveSnapshotSynchronously(snapshotPayload())
                }
            case .empty:
                break
            case .unreadable:
                // This session shows the seed library and must not save it (or default settings) over the real one;
                // seeding has already queued a save.
                persistenceBlocked = true
                persistenceTask?.cancel()
                customCoverVersions = [:]
            }
            if persistenceBlocked {
                restoreSettings()
                // The saved download marks belong to the library that could not be read, not to the seed's chapters.
                downloadedChapterIds = []
            } else {
                // Never lowered: after a downgrade, the newer build must not run its migrations a second time.
                UserDefaults.standard.set(max(saved, Self.librarySeedVersion), forKey: Self.librarySeedVersionKey)
                restoreAndTrackSettings()
                forgetDownloadsOfMissingChapters()
                restoreDownloadQueue()
                // The reader is not open at launch.
                deletePendingReadChapters()
                let libraryCovers = Set(mangas.filter(\.favorite).compactMap(\.thumbnailUrl))
                Task.detached(priority: .background) { MihonTwoTierImageCache.shared.trimDiskCache(keepingCovers: libraryCovers) }
            }
            // New chapter ids never reuse one a saved page list is filed under.
            nextChapterId = max(nextChapterId, (MihonTwoTierImageCache.shared.highestDownloadedChapterId() ?? 0) + 1)
        }
        #if canImport(UIKit)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBackgroundTimeForDownloads() }
        }
        #endif
        guard bootstrapNetwork else { return }
        Task {
            await bootstrapInstalledAPKSources()
            // Without demo features there is no extension list to fill.
            if showsDemoFeatures { await syncExtensionsFromKeiyoushiRepo() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshUninitializedLiveManga()
        }
    }

    private func invalidateLibrary() {
        libraryCache = nil
        libraryRevision &+= 1
    }

    private func invalidateChapters() {
        chapterListCache.removeAll(keepingCapacity: true)
        nextUnreadCache.removeAll(keepingCapacity: true)
        readingOrderCache.removeAll(keepingCapacity: true)
        readerChaptersCache.removeAll(keepingCapacity: true)
        chaptersRevision &+= 1
    }

    private func invalidateSources() {
        sourcesCache = nil
        sourceDescriptorIndex = nil
        sourcesRevision &+= 1
    }

    // MARK: - Lookups

    public func manga(id: Int64) -> Manga? {
        if mangaIndexDirty {
            mangaIndex = Dictionary(mangas.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            mangaIndexDirty = false
        }
        guard let idx = mangaIndex[id], idx < mangas.count, mangas[idx].id == id else {
            return mangas.first { $0.id == id }
        }
        return mangas[idx]
    }

    private func mangaArrayIndex(_ id: Int64) -> Int? {
        _ = manga(id: id)
        if let idx = mangaIndex[id], idx < mangas.count, mangas[idx].id == id { return idx }
        return mangas.firstIndex { $0.id == id }
    }

    public func scheduleBackgroundPersistence() {
        guard persistsState, !persistenceBlocked else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, !self.persistenceBlocked else { return }
            // The library's parts are copy-on-write, so taking them is cheap; flattening every chapter into the
            // payload happens on the persistence actor, off the main thread.
            let parts = self.snapshotParts()
            try? await MihonDiskPersistenceManager.shared.saveSnapshot(building: { parts.payload })
        }
    }

    /// Saves the library right away: a background refresh may be suspended before the debounced save runs.
    public func saveNow() {
        guard persistsState, !persistenceBlocked else { return }
        persistenceTask?.cancel()
        try? MihonDiskPersistenceManager.saveSnapshotSynchronously(snapshotPayload())
    }

    private func snapshotPayload() -> MihonBackupPayload {
        snapshotParts().payload
    }

    private func snapshotParts() -> SnapshotParts {
        SnapshotParts(
            mangas: mangas, categories: categories, mangaCategories: mangaCategories, chaptersByManga: chaptersByManga,
            historyEntries: historyEntries, tracksByManga: tracksByManga, extensionRepos: extensionRepos
        )
    }

    /// The saved library before its chapters are flattened into the payload.
    struct SnapshotParts: Sendable {
        let mangas: [Manga]
        let categories: [MangaCategory]
        let mangaCategories: [Int64: [Int64]]
        let chaptersByManga: [Int64: [Chapter]]
        let historyEntries: [HistoryEntry]
        let tracksByManga: [Int64: [Track]]
        let extensionRepos: [ExtensionRepo]

        var payload: MihonBackupPayload {
            MihonBackupPayload(
                backupManga: mangas,
                backupCategories: categories,
                mangaCategoriesMap: mangaCategories,
                backupChapters: chaptersByManga.values.flatMap { $0 },
                backupHistory: historyEntries,
                backupTracks: tracksByManga.values.flatMap { $0 },
                backupExtensionRepos: extensionRepos
            )
        }
    }

    // MARK: - Chapter sync (1:1 Port of Mihon's `SyncChaptersWithSource` interactor)

    /// Recognizes chapter numbers via `ChapterRecognition`, preserves read/bookmark/lastPageRead states,
    /// and works out the next update (`FetchInterval`). Returns the number of newly inserted chapters.
    @discardableResult
    public func syncChaptersWithSource(mangaId: Int64, sourceChapters: [SChapter]) -> Int {
        syncNewChapters(mangaId: mangaId, sourceChapters: sourceChapters).count
    }

    /// `syncChaptersWithSource`, handing back the chapters it counts as new — not the ones a re-added listing took
    /// over (read before) — in the source's order. None on a title's first fetch.
    ///
    /// - Parameters:
    ///   - manualFetch: the user's own refresh of the title, which always works out its next update again.
    ///   - fetchWindow: a library update's window (`FetchInterval.window`).
    @discardableResult
    func syncNewChapters(mangaId: Int64, sourceChapters: [SChapter], manualFetch: Bool = false, fetchWindow: ClosedRange<Date>? = nil) -> [Chapter] {
        // Upstream throws `NoChaptersException` here: an empty list (a title taken down, every chapter paywalled)
        // must not wipe the chapters, read state and progress already saved.
        guard !sourceChapters.isEmpty, let mIdx = mangaArrayIndex(mangaId) else { return [] }
        let manga = mangas[mIdx]
        let existing = chaptersByManga[mangaId] ?? []
        let existingByUrl = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let isFirstSync = existing.isEmpty
        let now = Date()
        // New chapters found during the very first fetch are not "updates" (upstream compares date_fetch > date_added).
        let firstSyncFetchDate = min(now, manga.dateAdded ?? now)

        // Chapters the source no longer lists. One that comes back under another URL with the same number (a
        // re-upload, a renamed episode) keeps its read and bookmark state and its fetch date, as upstream: it is
        // not an update.
        let sourceUrls = Set(sourceChapters.map(\.url))
        let removed = existing.filter { !sourceUrls.contains($0.url) }
        var removedByNumber: [Double: Chapter] = [:]
        for chapter in removed where chapter.chapterNumber >= 0 {
            if let other = removedByNumber[chapter.chapterNumber] {
                var merged = other
                merged.read = other.read || chapter.read
                merged.bookmark = other.bookmark || chapter.bookmark
                merged.dateFetch = min(other.dateFetch, chapter.dateFetch)
                removedByNumber[chapter.chapterNumber] = merged
            } else {
                removedByNumber[chapter.chapterNumber] = chapter
            }
        }

        var merged: [Chapter] = []
        var inserted: [Chapter] = []
        var listChanged = !removed.isEmpty
        var seenUrls = Set<String>()
        var newIdsByName: [String: Int64] = [:]
        var readdedIdsByNumber: [Double: Int64] = [:]
        for (order, sChap) in sourceChapters.enumerated() where seenUrls.insert(sChap.url).inserted {
            let recognizedNum = ChapterRecognition.parseChapterNumber(
                mangaTitle: manga.title,
                chapterName: sChap.name,
                chapterNumber: sChap.chapterNumber
            )
            if var old = existingByUrl[sChap.url] {
                let before = old
                old.name = sChap.name
                old.chapterNumber = recognizedNum
                old.scanlator = sChap.scanlator
                old.sourceOrder = order
                // An undated listing keeps the date known from before.
                if sChap.dateUpload > SChapter.undatedUpload { old.dateUpload = sChap.dateUpload }
                if old != before { listChanged = true }
                merged.append(old)
            } else {
                listChanged = true
                nextChapterId += 1
                var chapter = Chapter(
                    id: nextChapterId,
                    mangaId: mangaId,
                    url: sChap.url,
                    name: sChap.name,
                    scanlator: sChap.scanlator,
                    totalPages: 0,
                    chapterNumber: recognizedNum,
                    sourceOrder: order,
                    // Keep the source ordering stable for chapters fetched in the same batch.
                    dateFetch: (isFirstSync ? firstSyncFetchDate : now).addingTimeInterval(-Double(order) * 0.001),
                    dateUpload: sChap.dateUpload
                )
                if recognizedNum >= 0, let gone = removedByNumber[recognizedNum] {
                    chapter.read = gone.read
                    chapter.bookmark = gone.bookmark
                    chapter.dateFetch = gone.dateFetch
                    readdedIdsByNumber[recognizedNum] = readdedIdsByNumber[recognizedNum] ?? chapter.id
                } else {
                    inserted.append(chapter)
                }
                newIdsByName["\(sChap.name)|\(sChap.scanlator ?? "")"] = newIdsByName["\(sChap.name)|\(sChap.scanlator ?? "")"] ?? chapter.id
                merged.append(chapter)
            }
        }

        chaptersByManga[mangaId] = merged
        if !removed.isEmpty {
            retireRemovedChapters(removed, newIdsByName: newIdsByName, readdedIdsByNumber: readdedIdsByNumber)
        }
        // Upstream: a changed list works the next update out again and becomes the title's last update; an unchanged
        // one only on the user's own refresh, for a title never scheduled, or once its next update has passed.
        let isNextUpdateBeforeWindow = fetchWindow.map { window in manga.nextUpdate.map { $0 < window.lowerBound } ?? true } ?? false
        if listChanged || manualFetch || manga.fetchInterval == 0 || isNextUpdateBeforeWindow {
            // A first fetch lists the back catalogue, so it is no release.
            let schedule = FetchInterval.update(
                for: manga, chapters: merged, now: now, window: fetchWindow,
                foundRelease: listChanged && !isFirstSync && !inserted.isEmpty
            )
            mangas[mIdx].nextUpdate = schedule.nextUpdate
            mangas[mIdx].fetchInterval = schedule.fetchInterval
            if listChanged { mangas[mIdx].lastUpdate = now }
        }
        scheduleBackgroundPersistence()
        return isFirstSync ? [] : inserted
    }

    /// What pointed at chapters the source dropped: a download moves to the chapter added back under the same name
    /// (upstream finds downloads by chapter name) and is deleted otherwise; history moves to the chapter added back
    /// under the same number and goes otherwise (upstream deletes it with the chapter).
    private func retireRemovedChapters(_ removed: [Chapter], newIdsByName: [String: Int64], readdedIdsByNumber: [Double: Int64]) {
        var moves: [Int64: Int64] = [:]
        for chapter in removed where downloadedChapterIds.contains(chapter.id) {
            if let newId = newIdsByName["\(chapter.name)|\(chapter.scanlator ?? "")"], !moves.values.contains(newId) {
                moves[chapter.id] = newId
            } else {
                removeChapterDownload(chapterId: chapter.id)
            }
        }
        if !moves.isEmpty {
            MihonTwoTierImageCache.shared.moveDownloadedChapters(moves)
            downloadedChapterIds.subtract(moves.keys)
            downloadedChapterIds.formUnion(moves.values)
        }
        for chapter in removed {
            cancelDownload(chapterId: chapter.id)
            pageListCache[chapter.id] = nil
            chaptersPendingDeletion.remove(chapter.id)
        }

        let removedNumbers = Dictionary(removed.map { ($0.id, $0.chapterNumber) }, uniquingKeysWith: { first, _ in first })
        guard historyEntries.contains(where: { removedNumbers[$0.chapterId] != nil }) else { return }
        var history: [HistoryEntry] = []
        var movedIndex: [Int64: Int] = [:]
        for var entry in historyEntries {
            if let number = removedNumbers[entry.chapterId] {
                guard number >= 0, let newId = readdedIdsByNumber[number] else { continue }
                entry.chapterId = newId
                // Two dropped chapters with one number come back as one chapter with one history entry.
                if let index = movedIndex[newId] {
                    history[index].readAt = max(history[index].readAt, entry.readAt)
                    history[index].readDurationSeconds += entry.readDurationSeconds
                    continue
                }
                movedIndex[newId] = history.count
            }
            history.append(entry)
        }
        historyEntries = history
    }

    // MARK: - Extension repository sync (Keiyoushi `index.pb`)

    public func syncExtensionsFromKeiyoushiRepo() async {
        guard !extensionRepos.isEmpty, !isSyncingExtensionRepos else { return }
        isSyncingExtensionRepos = true
        defer { isSyncingExtensionRepos = false }

        var merged = extensions.filter { !$0.apkName.isEmpty }
        var indexByPkg = Dictionary(merged.enumerated().map { ($0.element.pkgName, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var totalSynced = 0
        var totalAdded = 0

        for repo in extensionRepos {
            // A repo added while offline still lacks its key; installs from it are refused until it has one.
            await fillMissingSigningKey(baseUrl: repo.baseUrl)
            guard let remoteExts = try? await MihonNetworkClient.shared.fetchExtensionRepoIndex(repoBaseUrl: repo.baseUrl) else {
                continue
            }
            totalSynced += remoteExts.count
            for remote in remoteExts where !MihonSeedData.stubPackages.contains(remote.pkgName) {
                if let idx = indexByPkg[remote.pkgName] {
                    var local = merged[idx]
                    local.apkName = remote.apkName
                    local.apkUrl = remote.apkUrl
                    local.repoUrl = remote.repoUrl
                    local.iconUrl = remote.iconUrl ?? local.iconUrl
                    local.libVersion = remote.libVersion
                    if !remote.sources.isEmpty && local.sources.count < remote.sources.count {
                        local.sources = remote.sources
                    }
                    let isInstalled = local.installState == .installed || local.installState == .hasUpdate
                    if isInstalled && remote.versionCode > local.versionCode {
                        local.installState = .hasUpdate
                        pendingExtensionUpdates[remote.pkgName] = remote
                    } else if !isInstalled {
                        local.versionName = remote.versionName
                        local.versionCode = remote.versionCode
                        local.isNsfw = remote.isNsfw
                        local.name = remote.name
                    }
                    merged[idx] = local
                } else {
                    merged.append(remote)
                    indexByPkg[remote.pkgName] = merged.count - 1
                    totalAdded += 1
                }
            }
        }

        let websites = extensions.filter { $0.apkName.isEmpty }
        let websitePackages = Set(websites.map(\.pkgName))
        extensions = merged.filter { !websitePackages.contains($0.pkgName) } + websites
        if totalSynced > 0 {
            showStatusBanner("已同步扩展仓库：共 \(extensions.count) 个插件（新增 \(totalAdded) 个）")
        } else {
            showStatusBanner("无法连接扩展仓库，已加载内置的 \(extensions.count) 个插件")
        }
    }

    // MARK: - Seed Data

    private func seedInitialMihonEcosystemData() {
        let now = Date()
        categories = MihonSeedData.categories
        extensionRepos = MihonSeedData.repos
        // Without demo features only the extensions with a live engine remain, and the library holds their seed
        // entries plus a shelf of titles with Chinese chapters.
        extensions = (MihonSeedData.extensions + BundledWebsite.allCases.map(\.model) + [BikaWebsite.model]).filter { ext in
            showsDemoFeatures || ext.sources.contains { MihonLiveSources.handles($0) }
        }
        trackers = MihonSeedData.trackers
        let seededMangas = showsDemoFeatures
            ? MihonSeedData.mangas(now: now)
            : MihonSeedData.mangas(now: now).filter { isLiveSource($0.source) }
                + MihonSeedData.mangaDexLibrary(now: now) + MihonSeedData.zaimanhuaLibrary(now: now)
                + MihonSeedData.dongmanLibrary(now: now)
        let seededIds = Set(seededMangas.map(\.id))
        mangas = seededMangas
        mangaCategories = MihonSeedData.mangaCategories
            .merging(MihonSeedData.mangaDexLibraryCategories) { first, _ in first }
            .merging(MihonSeedData.zaimanhuaLibraryCategories) { first, _ in first }
            .merging(MihonSeedData.dongmanLibraryCategories) { first, _ in first }
            .filter { seededIds.contains($0.key) }
        if !showsDemoFeatures {
            categories.removeAll { category in
                category.id != 0 && !mangaCategories.values.contains { $0.contains(category.id) }
            }
        }

        var chapterIdCounter: Int64 = 5000
        var seededChapters: [Int64: [Chapter]] = [:]
        var downloaded: Set<Int64> = []
        for manga in seededMangas where !isLiveSource(manga.source) {
            let totalChapCount = manga.id == 102 ? 97 : 28
            let readThreshold = manga.id == 102 ? 97 : (manga.id == 101 ? 24 : 18)
            var chapters: [Chapter] = []

            for num in (1...totalChapCount).reversed() {
                chapterIdCounter += 1
                let isRead = num <= readThreshold
                let chap = Chapter(
                    id: chapterIdCounter,
                    mangaId: manga.id,
                    url: "\(manga.url)/chapter-\(num)",
                    name: "第 \(num) 话 - \(MihonSeedData.chapterSubtitle(for: num))",
                    scanlator: manga.source == 0 ? nil : "星期五汉化组",
                    read: isRead,
                    bookmark: num == 1 || num == readThreshold,
                    lastPageRead: isRead ? 17 : (num == readThreshold + 1 ? 7 : 0),
                    totalPages: 18,
                    chapterNumber: Double(num),
                    sourceOrder: totalChapCount - num,
                    dateFetch: now.addingTimeInterval(TimeInterval(-Double(totalChapCount - num) * 3600 * 6)),
                    dateUpload: now.addingTimeInterval(TimeInterval(-Double(totalChapCount - num) * 86400 * 2))
                )
                chapters.append(chap)
                if num >= totalChapCount - 1 && (manga.id == 101 || manga.id == 102 || manga.id == 106) {
                    downloaded.insert(chap.id)
                }
            }
            seededChapters[manga.id] = chapters
        }
        nextChapterId = chapterIdCounter + 1
        chaptersByManga = seededChapters
        downloadedChapterIds = downloaded

        if let fChap = seededChapters[101]?.first(where: { $0.chapterNumber == 24 }),
           let dChap = seededChapters[102]?.first(where: { $0.chapterNumber == 97 }),
           let wChap = seededChapters[103]?.first(where: { $0.chapterNumber == 18 }),
           let bChap = seededChapters[105]?.first(where: { $0.chapterNumber == 18 }) {
            historyEntries = [
                HistoryEntry(id: 1, chapterId: fChap.id, mangaId: 101, readAt: now.addingTimeInterval(-900), readDurationSeconds: 1420),
                HistoryEntry(id: 2, chapterId: wChap.id, mangaId: 103, readAt: now.addingTimeInterval(-5400), readDurationSeconds: 980),
                HistoryEntry(id: 3, chapterId: dChap.id, mangaId: 102, readAt: now.addingTimeInterval(-86400 - 1200), readDurationSeconds: 3650),
                HistoryEntry(id: 4, chapterId: bChap.id, mangaId: 105, readAt: now.addingTimeInterval(-86400 * 2), readDurationSeconds: 2150)
            ]
        }

        tracksByManga = [
            101: [
                Track(id: 901, mangaId: 101, trackerId: 1, remoteId: 118586, title: "Sousou no Frieren", lastChapterRead: 24, status: .reading, score: 9.5, remoteUrl: "https://anilist.co/manga/118586"),
                Track(id: 902, mangaId: 101, trackerId: 3, remoteId: 305195, title: "葬送的芙莉莲", lastChapterRead: 24, status: .reading, score: 9.2, remoteUrl: "https://bgm.tv/subject/305195")
            ],
            102: [
                Track(id: 903, mangaId: 102, trackerId: 1, remoteId: 86082, title: "Dungeon Meshi", lastChapterRead: 97, totalChapters: 97, status: .completed, score: 9.8, remoteUrl: "https://anilist.co/manga/86082")
            ]
        ].filter { seededIds.contains($0.key) }
    }

    // MARK: - APK Engine APK/DEX Analysis & Source Synthesis

    public func bootstrapInstalledAPKSources() async {
        var updated = extensions
        var inspections = apkInspectionsByPkg
        for idx in updated.indices where updated[idx].installState == .installed || updated[idx].installState == .hasUpdate {
            let ext = updated[idx]
            guard !ext.apkName.isEmpty else { continue }
            if let (inspection, synthesized) = try? await apkSynthesizer.analyzeAndSynthesizeExtension(extensionModel: ext) {
                inspections[ext.pkgName] = inspection
                if !synthesized.isEmpty {
                    updated[idx].sources = synthesized.map(\.descriptor)
                }
                updated[idx].apkMetadataSummary = "\(inspection.evidenceId) · \(inspection.discoveredClasses.count) DEX Classes · \(inspection.extractedStringPool.count) Strings"
            }
        }
        // Only touch the published state once so observers re-render a single time.
        apkInspectionsByPkg = inspections
        extensions = mergePreservingRemoteChanges(updated)
    }

    /// The repo sync may have run concurrently; keep its additions while applying local synthesis results.
    private func mergePreservingRemoteChanges(_ synthesized: [ExtensionModel]) -> [ExtensionModel] {
        let byPkg = Dictionary(synthesized.map { ($0.pkgName, $0) }, uniquingKeysWith: { first, _ in first })
        return extensions.map { current in
            guard !current.apkName.isEmpty, var local = byPkg[current.pkgName] else { return current }
            local.apkUrl = current.apkUrl ?? local.apkUrl
            local.iconUrl = current.iconUrl ?? local.iconUrl
            if current.sources.count > local.sources.count { local.sources = current.sources }
            if current.installState == .hasUpdate { local.installState = .hasUpdate }
            return local
        }
    }

    /// Like Android's installer under upstream's `TrustExtension`: only a package signed with its repo's key
    /// (`repo.json` → `signingKeyFingerprint`) is installed. A refused or failed install restores the previous
    /// state, so an update that fails leaves the installed version in place.
    public func inspectAndInstallExtensionApk(_ ext: ExtensionModel) async {
        guard let idx = extensions.firstIndex(where: { $0.pkgName == ext.pkgName }) else { return }
        // A second tap while one install runs would record the in-progress state as the one to restore.
        guard extensions[idx].installState != .downloadingApk, extensions[idx].installState != .parsingApk else { return }
        let target = pendingExtensionUpdates[ext.pkgName] ?? ext
        let previousState = extensions[idx].installState
        func fail(_ message: String) {
            if let idx = extensions.firstIndex(where: { $0.pkgName == ext.pkgName }) {
                extensions[idx].installState = previousState
            }
            showStatusBanner(message)
        }
        guard let trustedKey = signingKeyFingerprint(forRepo: target.repoUrl) else {
            fail("无法安装 \(ext.name)：插件仓库没有提供签名指纹")
            return
        }
        extensions[idx].installState = .downloadingApk

        let downloaded: Data
        do {
            downloaded = try await MihonNetworkClient.shared.downloadExtensionApk(
                repoBaseUrl: target.repoUrl,
                apkName: target.apkName,
                apkUrl: target.apkUrl
            ).0
        } catch {
            fail("插件下载失败：\(ext.name)")
            return
        }

        guard let idx = extensions.firstIndex(where: { $0.pkgName == ext.pkgName }) else { return }
        extensions[idx].installState = .parsingApk

        let signature: APKSignatureVerification
        do {
            signature = try await Task.detached(priority: .userInitiated) {
                try APKSignatureVerifier().verify(apkData: downloaded)
            }.value
            guard signature.isSigned(by: trustedKey) else { throw ExtensionTrustError.untrustedSigner }
            // Like Android's package manager: an update must come from the installed version's signer (another
            // repo listing the same package cannot replace it).
            if let installed = apkInspectionsByPkg[ext.pkgName]?.signature,
               Set(installed.certificateFingerprints).isDisjoint(with: signature.certificateFingerprints) {
                throw ExtensionTrustError.signerChanged
            }
        } catch {
            MihonNetworkClient.discardCachedExtensionApk(apkName: target.apkName)
            fail("已拒绝安装 \(ext.name)：\(error.localizedDescription)")
            return
        }

        var result = try? await apkSynthesizer.analyzeAndSynthesizeExtension(extensionModel: target, apkData: downloaded)
        result?.inspection.signature = signature
        if result == nil {
            // A genuine package whose DEX layout the parser does not support falls back to the descriptor-driven
            // synthetic package.
            result = try? await apkSynthesizer.analyzeAndSynthesizeExtension(extensionModel: target, apkData: nil)
        }

        guard let idx = extensions.firstIndex(where: { $0.pkgName == ext.pkgName }) else { return }
        guard let (inspection, synthesized) = result else {
            extensions[idx].installState = previousState
            showStatusBanner("插件安装失败：\(ext.name)")
            return
        }
        apkInspectionsByPkg[ext.pkgName] = inspection
        var installed = extensions[idx]
        installed.versionName = target.versionName
        installed.versionCode = target.versionCode
        if !synthesized.isEmpty {
            installed.sources = synthesized.map(\.descriptor)
        }
        installed.installState = .installed
        installed.apkMetadataSummary = "\(inspection.evidenceId) · \(inspection.discoveredClasses.count) Classes · \(inspection.extractedStringPool.count) Selectors"
        extensions[idx] = installed
        pendingExtensionUpdates[ext.pkgName] = nil
        showStatusBanner("已安装插件：\(ext.name)")
    }

    public func updateAllExtensions() async {
        for ext in extensions where ext.installState == .hasUpdate {
            await inspectAndInstallExtensionApk(ext)
        }
    }

    public func uninstallExtension(_ ext: ExtensionModel) {
        guard let idx = extensions.firstIndex(where: { $0.pkgName == ext.pkgName }) else { return }
        extensions[idx].installState = .available
        showStatusBanner("已卸载插件：\(ext.name)")
    }

    public func inspectExtensionApk(for ext: ExtensionModel) async -> APKAndroidPackageInspection? {
        if let cached = apkInspectionsByPkg[ext.pkgName] {
            return cached
        }
        let apkBytes = try? await MihonNetworkClient.shared.downloadExtensionApk(
            repoBaseUrl: ext.repoUrl,
            apkName: ext.apkName,
            apkUrl: ext.apkUrl
        ).0

        var result = try? await apkSynthesizer.analyzeAndSynthesizeExtension(extensionModel: ext, apkData: apkBytes)
        if let apkBytes, result != nil {
            // Shown on the details screen; trust is only decided at install time.
            result?.inspection.signature = try? await Task.detached(priority: .userInitiated) {
                try APKSignatureVerifier().verify(apkData: apkBytes)
            }.value
        }
        if result == nil {
            result = try? await apkSynthesizer.analyzeAndSynthesizeExtension(extensionModel: ext, apkData: nil)
        }
        guard let (inspection, _) = result else { return nil }
        apkInspectionsByPkg[ext.pkgName] = inspection
        return inspection
    }

    /// The repo's published signing key, normalized; nil when the repo is unknown or published none.
    func signingKeyFingerprint(forRepo repoUrl: String) -> String? {
        let clean = MihonNetworkClient.cleanRepoBaseUrl(repoUrl)
        guard let repo = extensionRepos.first(where: { MihonNetworkClient.cleanRepoBaseUrl($0.baseUrl) == clean }) else {
            return nil
        }
        let fingerprint = APKSignatureVerification.normalize(repo.signingKeyFingerprint)
        return fingerprint.count == 64 ? fingerprint : nil
    }

    /// Fills in a repo's signing key from its `repo.json`, as upstream's `CreateExtensionRepo` does. A known key is
    /// never replaced: a changed key is exactly what the install check exists to catch.
    private func fillMissingSigningKey(baseUrl: String) async {
        guard let idx = extensionRepos.firstIndex(where: { $0.baseUrl == baseUrl }),
              signingKeyFingerprint(forRepo: baseUrl) == nil,
              let meta = try? await MihonNetworkClient.shared.fetchExtensionRepoMeta(repoBaseUrl: baseUrl),
              let current = extensionRepos.firstIndex(where: { $0.baseUrl == baseUrl }), current == idx else { return }
        extensionRepos[idx].signingKeyFingerprint = meta.signingKeyFingerprint
        extensionRepos[idx].shortName = extensionRepos[idx].shortName ?? meta.shortName
        if extensionRepos[idx].website == baseUrl { extensionRepos[idx].website = meta.website }
    }

    // MARK: - Catalogue sources

    /// True when `lang` (e.g. `zh-Hans`) or its primary subtag (`zh`) is enabled.
    public func isLanguageEnabled(_ lang: String) -> Bool {
        if lang == "all" || lang == "other" || enabledLanguages.contains(lang) { return true }
        let primary = lang.split(separator: "-").first.map(String.init) ?? lang
        return enabledLanguages.contains(primary)
    }

    public func isLiveSource(_ sourceId: Int64) -> Bool {
        guard let descriptor = sourceDescriptor(for: sourceId) else { return false }
        return importedRules[sourceId] != nil || MihonLiveSources.handles(descriptor)
    }

    private func liveEngine(for descriptor: ExtensionSourceDescriptor) -> (any LiveSourceEngine)? {
        if let rule = importedRules[descriptor.id] { return HTMLRuleEngine(rule: rule) }
        return MihonLiveSources.engine(
            for: descriptor,
            settings: MihonLiveSources.Settings(
                allowNsfw: showNsfwSources, mangaDexDataSaver: mangaDexDataSaver, komgaAccounts: komgaAccounts
            )
        )
    }

    private func makeSource(_ descriptor: ExtensionSourceDescriptor, pkgName: String, ext: ExtensionModel) -> APKSynthesizedHttpSource {
        let inspection = apkInspectionsByPkg[pkgName] ?? APKAndroidPackageInspection(
            artifactPath: "/Documents/Extensions/\(ext.apkName)",
            manifest: APKManifestProjection(
                packageName: ext.pkgName,
                versionName: ext.versionName,
                versionCode: ext.versionCode,
                applicationLabel: "Mihon: \(ext.name)"
            ),
            dexMetrics: [],
            discoveredClasses: [],
            extractedStringPool: []
        )
        return APKSynthesizedHttpSource(descriptor: descriptor, inspection: inspection, liveEngine: liveEngine(for: descriptor))
    }

    public func activeCatalogueSources() -> [APKSynthesizedHttpSource] {
        _ = sourcesRevision
        if let sourcesCache { return sourcesCache }
        var list: [APKSynthesizedHttpSource] = []
        for ext in extensions where ext.installState == .installed || ext.installState == .hasUpdate {
            if !showNsfwSources && ext.isNsfw { continue }
            for descriptor in ext.sources where isLanguageEnabled(descriptor.lang) {
                list.append(makeSource(descriptor, pkgName: ext.pkgName, ext: ext))
            }
        }
        sourcesCache = list
        return list
    }

    static let komgaAccountsKey = "komga.accounts"

    /// Komga answers a login with a session cookie that later requests send in its place: a changed or removed
    /// login must not keep working through it.
    static func forgetServerCookies(_ accounts: [KomgaAccount]) {
        let storage = HTTPCookieStorage.shared
        for url in accounts.compactMap(\.baseURL) {
            for cookie in storage.cookies(for: url) ?? [] { storage.deleteCookie(cookie) }
        }
    }

    /// Every request to a Komga server carries its login (`MihonServerAuth`), images included.
    static func registerServerLogins(_ accounts: [Int64: KomgaAccount]) {
        var servers: [String: [String: String]] = [:]
        for account in accounts.values where account.isConfigured && !account.headers.isEmpty {
            servers[account.baseUrl] = account.headers
        }
        MihonServerAuth.set(servers)
    }

    /// Upstream's local source (id 0, language "other"): built in, not part of any extension.
    static let localSourceDescriptor = ExtensionSourceDescriptor(
        id: MihonLocalSource.sourceId, name: "本地图源", lang: "other", baseUrl: MihonLocalSource.baseUrl
    )

    public var localCatalogueSource: APKSynthesizedHttpSource {
        let descriptor = Self.localSourceDescriptor
        return APKSynthesizedHttpSource(
            descriptor: descriptor,
            inspection: APKAndroidPackageInspection(
                artifactPath: "",
                manifest: APKManifestProjection(
                    packageName: "eu.kanade.tachiyomi.source.local",
                    versionName: "",
                    versionCode: 0,
                    applicationLabel: descriptor.name
                ),
                dexMetrics: [],
                discoveredClasses: [],
                extractedStringPool: []
            ),
            liveEngine: MihonLocalSource()
        )
    }

    /// Copies picked folders / ZIP / CBZ files into the local source's folder (`MihonLocalStorage.importItems`),
    /// then rescans the titles that received chapters.
    @discardableResult
    public func importLocalFiles(_ urls: [URL], intoTitle title: String?) async -> MihonLocalStorage.ImportResult {
        let result = await Task.detached(priority: .userInitiated) {
            MihonLocalStorage.importItems(urls, intoTitle: title)
        }.value
        for name in result.titles {
            for manga in mangas where manga.source == MihonLocalSource.sourceId && manga.url == name {
                await refreshMangaFromSource(mangaId: manga.id, force: true, reportsErrors: false)
            }
        }
        let skipped = result.skipped > 0 ? "，\(result.skipped) 个已存在" : ""
        let failed = result.failed > 0 ? "，\(result.failed) 个无法导入（支持文件夹、ZIP、CBZ）" : ""
        if result.chapters > 0 {
            showStatusBanner("已导入 \(result.chapters) 个章节" + skipped + failed)
        } else if result.skipped > 0 {
            showStatusBanner("这些章节已经在本地图源里了" + failed)
        } else {
            showStatusBanner("没有可导入的文件（支持文件夹、ZIP、CBZ）")
        }
        return result
    }

    /// Resolves the runnable source of a library entry even when its language is currently hidden.
    public func catalogueSource(for sourceId: Int64) -> APKSynthesizedHttpSource? {
        if sourceId == MihonLocalSource.sourceId { return localCatalogueSource }
        if let hit = activeCatalogueSources().first(where: { $0.id == sourceId }) { return hit }
        for ext in extensions {
            if let descriptor = ext.sources.first(where: { $0.id == sourceId }) {
                return makeSource(descriptor, pkgName: ext.pkgName, ext: ext)
            }
        }
        return nil
    }

    public func sourceDescriptor(for sourceId: Int64) -> ExtensionSourceDescriptor? {
        if sourceId == MihonLocalSource.sourceId { return Self.localSourceDescriptor }
        if sourceDescriptorIndex == nil {
            var index: [Int64: ExtensionSourceDescriptor] = [:]
            for ext in extensions {
                for source in ext.sources where index[source.id] == nil {
                    index[source.id] = source
                }
            }
            sourceDescriptorIndex = index
        }
        return sourceDescriptorIndex?[sourceId]
    }

    public func extensionIconUrl(forSourceId sourceId: Int64) -> String? {
        _ = sourcesRevision
        return extensions.first { $0.sources.contains { $0.id == sourceId } }?.iconUrl
    }

    public func sourceName(for sourceId: Int64) -> String {
        if sourceId == 0 { return "本地图源" }
        guard let descriptor = sourceDescriptor(for: sourceId) else {
            // Upstream's stub source: the name a restored backup gave it.
            return stubSourceNames[sourceId] ?? "图源 #\(sourceId)"
        }
        return "\(descriptor.name) (\(MihonLanguage.displayName(descriptor.lang)))"
    }

    public func sourceLanguage(for sourceId: Int64) -> String {
        if sourceId == 0 { return "" }
        return sourceDescriptor(for: sourceId)?.lang.uppercased() ?? ""
    }

    public func markSourceUsed(_ sourceId: Int64) {
        lastUsedSourceId = sourceId
    }

    public func togglePinnedSource(_ sourceId: Int64) {
        if pinnedSourceIds.contains(sourceId) {
            pinnedSourceIds.remove(sourceId)
        } else {
            pinnedSourceIds.insert(sourceId)
        }
    }

    // MARK: - Library Queries & Operations (memoized)

    public func libraryItems(forCategory categoryId: Int64, searchQuery: String) -> [LibraryMangaItem] {
        _ = libraryRevision
        if libraryCache == nil { libraryCache = buildLibraryCache() }
        let base = categoryId == -1 ? libraryCache!.allItems : (libraryCache!.itemsByCategory[categoryId] ?? [])
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }

        let key = "\(categoryId)|\(query)"
        if let hit = libraryCache!.searchResults[key] { return hit }
        let result = base.filter { item in
            item.manga.title.localizedCaseInsensitiveContains(query) ||
            (item.manga.author?.localizedCaseInsensitiveContains(query) ?? false) ||
            item.manga.genre.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        libraryCache!.searchResults[key] = result
        return result
    }

    /// Categories shown as library tabs (upstream hides the default category when it is empty).
    public func visibleLibraryCategories() -> [MangaCategory] {
        _ = libraryRevision
        if libraryCache == nil { libraryCache = buildLibraryCache() }
        return categories
            .sorted { $0.order < $1.order }
            .filter { !$0.isSystemCategory || !(libraryCache!.itemsByCategory[$0.id] ?? []).isEmpty }
    }

    public var unreadUpdatesCount: Int {
        _ = libraryRevision
        if libraryCache == nil { libraryCache = buildLibraryCache() }
        return libraryCache!.allItems.reduce(0) { $0 + $1.unreadCount }
    }

    private func buildLibraryCache() -> LibraryCache {
        var lastReadByManga: [Int64: Date] = [:]
        for entry in historyEntries where (lastReadByManga[entry.mangaId] ?? .distantPast) < entry.readAt {
            lastReadByManga[entry.mangaId] = entry.readAt
        }

        var items: [LibraryMangaItem] = []
        for manga in mangas where manga.favorite {
            let assignedCats = mangaCategories[manga.id] ?? []
            let normalizedCats = assignedCats.isEmpty ? [MangaCategory.defaultCategoryId] : assignedCats
            let chapters = chaptersByManga[manga.id] ?? []
            let isLocal = manga.source == 0

            var unread = 0
            var downloaded = 0
            var bookmarks = false
            var latestUpload: Date?
            var latestFetch: Date?
            for chapter in chapters {
                if !chapter.read { unread += 1 }
                if downloadedChapterIds.contains(chapter.id) { downloaded += 1 }
                if chapter.bookmark { bookmarks = true }
                if latestUpload == nil || chapter.dateUpload > latestUpload! { latestUpload = chapter.dateUpload }
                if latestFetch == nil || chapter.dateFetch > latestFetch! { latestFetch = chapter.dateFetch }
            }

            let item = LibraryMangaItem(
                manga: manga,
                unreadCount: unread,
                downloadCount: downloaded,
                totalChapters: chapters.count,
                hasBookmarks: bookmarks,
                isTracked: !(tracksByManga[manga.id] ?? []).isEmpty,
                latestUploadDate: latestUpload,
                lastReadDate: lastReadByManga[manga.id],
                categories: normalizedCats,
                sourceLanguage: sourceLanguage(for: manga.source),
                isLocal: isLocal,
                nextChapter: Self.nextUnread(in: chapters, sortedBy: manga.chapterSortMode),
                hasReadChapters: unread < chapters.count,
                latestFetchDate: latestFetch
            )

            // Downloaded-only mode reads the downloaded filter as ✓, whatever it was set to (upstream).
            let downloadedFilter = downloadedOnlyMode ? TriStateFilter.include : libraryFilter.filterDownloaded
            guard passesTriState(downloadedFilter, condition: item.downloadCount > 0 || item.isLocal),
                  passesTriState(libraryFilter.filterUnread, condition: item.unreadCount > 0),
                  passesTriState(libraryFilter.filterStarted, condition: item.hasReadChapters && item.totalChapters > 0),
                  passesTriState(libraryFilter.filterBookmarked, condition: item.hasBookmarks),
                  passesTriState(libraryFilter.filterCompleted, condition: manga.status == .completed),
                  passesTriState(libraryFilter.filterTracked, condition: item.isTracked) else {
                continue
            }
            items.append(item)
        }

        let meanScore: [Int64: Double] = Dictionary(uniqueKeysWithValues: items.map { item in
            let scores = (tracksByManga[item.id] ?? []).map(\.score).filter { $0 > 0 }
            return (item.id, scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count))
        })
        let ascending = librarySortAscending
        let option = librarySortOption
        // Upstream `LibraryScreenModel.applySort`: every option compares ascending, descending reverses it, and ties
        // fall back to the title (then the id: unlike Kotlin's, Swift's sort is not stable).
        items.sort { lhs, rhs in
            var order: ComparisonResult
            switch option {
            case .alphabetical:
                order = lhs.manga.title.localizedStandardCompare(rhs.manga.title)
            case .lastRead:
                order = Self.compare(lhs.lastReadDate ?? .distantPast, rhs.lastReadDate ?? .distantPast)
            case .lastUpdated:
                order = Self.compare(lhs.manga.lastUpdate ?? .distantPast, rhs.manga.lastUpdate ?? .distantPast)
            case .unreadCount:
                // Titles with unread chapters come first either way.
                if (lhs.unreadCount == 0) != (rhs.unreadCount == 0) { return rhs.unreadCount == 0 }
                order = Self.compare(lhs.unreadCount, rhs.unreadCount)
            case .totalChapters:
                order = Self.compare(lhs.totalChapters, rhs.totalChapters)
            case .latestChapter:
                order = Self.compare(lhs.latestUploadDate ?? .distantPast, rhs.latestUploadDate ?? .distantPast)
            case .chapterFetchDate:
                order = Self.compare(lhs.latestFetchDate ?? .distantPast, rhs.latestFetchDate ?? .distantPast)
            case .dateAdded:
                order = Self.compare(lhs.manga.dateAdded ?? .distantPast, rhs.manga.dateAdded ?? .distantPast)
            case .trackerMeanScore:
                order = Self.compare(meanScore[lhs.id] ?? 0, meanScore[rhs.id] ?? 0)
            }
            if !ascending { order = Self.reversed(order) }
            if order == .orderedSame { order = lhs.manga.title.localizedStandardCompare(rhs.manga.title) }
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }

        var byCategory: [Int64: [LibraryMangaItem]] = [:]
        for item in items {
            for cat in item.categories {
                byCategory[cat, default: []].append(item)
            }
        }
        return LibraryCache(allItems: items, itemsByCategory: byCategory)
    }

    /// The first unread chapter in reading order (upstream `GetNextChapters`).
    private static func nextUnread(in chapters: [Chapter], sortedBy mode: ChapterSortMode) -> Chapter? {
        chapters.filter { !$0.read }.min { precedes($0, $1, by: mode, ascending: true) }
    }

    /// Upstream `getChapterSort`: ascending is oldest first (the source lists newest first), descending reverses
    /// it, and ties keep the source's order (Kotlin's sort is stable, Swift's is not).
    private static func precedes(_ lhs: Chapter, _ rhs: Chapter, by mode: ChapterSortMode, ascending: Bool) -> Bool {
        var order: ComparisonResult
        switch mode {
        case .source:
            order = compare(rhs.sourceOrder, lhs.sourceOrder)
        case .chapterNumber:
            order = compare(lhs.chapterNumber, rhs.chapterNumber)
        case .uploadDate:
            order = compare(lhs.dateUpload, rhs.dateUpload)
        case .alphabetical:
            order = lhs.name.localizedStandardCompare(rhs.name)
        }
        if !ascending { order = reversed(order) }
        return order == .orderedSame ? lhs.sourceOrder < rhs.sourceOrder : order == .orderedAscending
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (rhs < lhs ? .orderedDescending : .orderedSame)
    }

    private static func reversed(_ order: ComparisonResult) -> ComparisonResult {
        switch order {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func passesTriState(_ filter: TriStateFilter, condition: Bool) -> Bool {
        switch filter {
        case .disabled: return true
        case .include: return condition
        case .exclude: return !condition
        }
    }

    // MARK: - Library membership (upstream `MangaScreenModel.toggleFavorite`)

    /// Whether adding a title asks for its categories first: unless the default-category setting names the default
    /// category or an existing one (upstream's default is "Always ask"), as long as the user has categories.
    public var asksCategoriesOnAdd: Bool {
        let userCategories = categories.filter { !$0.isSystemCategory }
        guard !userCategories.isEmpty, defaultLibraryCategory != MangaCategory.defaultCategoryId else { return false }
        return !userCategories.contains { $0.id == defaultLibraryCategory }
    }

    /// Adds a title to the library under `categoryIds`, or where the default-category setting says.
    public func addToLibrary(mangaId: Int64, categoryIds: [Int64]? = nil) {
        guard let idx = mangaArrayIndex(mangaId) else { return }
        let preferred = categories.contains { $0.id == defaultLibraryCategory && !$0.isSystemCategory }
            ? [defaultLibraryCategory] : []
        let ids = categoryIds ?? preferred
        mangaCategories[mangaId] = ids.isEmpty ? [MangaCategory.defaultCategoryId] : ids
        guard !mangas[idx].favorite else { return }
        mangas[idx].favorite = true
        mangas[idx].dateAdded = Date()
        mangas[idx].favoriteModifiedAt = Date()
        showStatusBanner("已添加到书架")
    }

    public func removeFromLibrary(mangaId: Int64) {
        guard let idx = mangaArrayIndex(mangaId), mangas[idx].favorite else { return }
        mangas[idx].favorite = false
        mangas[idx].favoriteModifiedAt = Date()
        if mangas[idx].source != MihonLocalSource.sourceId { removeCustomCover(mangaId: mangaId) }
        showStatusBanner("已从书架移除")
    }

    /// Removes a title, or adds it where the default-category setting says (callers that can ask check
    /// `asksCategoriesOnAdd` first).
    public func toggleFavorite(mangaId: Int64) {
        if manga(id: mangaId)?.favorite == true {
            removeFromLibrary(mangaId: mangaId)
        } else {
            addToLibrary(mangaId: mangaId)
        }
    }

    /// Upstream `setMangaCategories(mangaList, addCategories, removeCategories)`: a category the dialog left mixed
    /// stays as each title has it.
    public func changeCategories(mangaIds: [Int64], adding: Set<Int64>, removing: Set<Int64>) {
        for mangaId in mangaIds {
            var ids = (mangaCategories[mangaId] ?? []).filter { $0 != MangaCategory.defaultCategoryId && !removing.contains($0) }
            for id in adding.sorted() where !ids.contains(id) {
                ids.append(id)
            }
            mangaCategories[mangaId] = ids.isEmpty ? [MangaCategory.defaultCategoryId] : ids
        }
    }

    public func upsertCatalogMangaToStore(_ smanga: SManga, sourceId: Int64) -> Manga {
        if let existing = mangas.first(where: { $0.url == smanga.url && $0.source == sourceId }) {
            return existing
        }
        let newId = (mangas.map(\.id).max() ?? 100) + 1
        let preferredMode = sourceDescriptor(for: sourceId).flatMap(liveEngine(for:))?.preferredReadingMode
        let newManga = Manga(
            id: newId,
            source: sourceId,
            url: smanga.url,
            title: smanga.title,
            artist: smanga.artist,
            author: smanga.author,
            description: smanga.description,
            genre: smanga.genre,
            status: smanga.status,
            thumbnailUrl: smanga.thumbnailUrl,
            favorite: false,
            lastUpdate: nil,
            dateAdded: nil,
            updateStrategy: smanga.updateStrategy,
            initialized: false,
            readingModeOverride: preferredMode ?? .defaultMode
        )
        mangas.append(newManga)
        return newManga
    }

    /// 1:1 with `MangaScreenModel.fetchAllFromSource`: refreshes details + chapters from the manga's source.
    /// `reportsErrors: false` keeps background refreshes quiet (the user did not ask for them).
    /// Returns whether the source's chapter list arrived (and was synced). `queuesDownloads: false` leaves new
    /// chapters to the caller (a migration marks them read first).
    @discardableResult
    public func refreshMangaFromSource(mangaId: Int64, force: Bool = false, reportsErrors: Bool = true, queuesDownloads: Bool = true) async -> Bool {
        guard let manga = manga(id: mangaId), !refreshingMangaIds.contains(mangaId) else { return false }
        let hasChapters = !(chaptersByManga[mangaId] ?? []).isEmpty
        guard force || !manga.initialized || !hasChapters else { return false }
        guard let source = catalogueSource(for: manga.source) else { return false }

        refreshingMangaIds.insert(mangaId)
        defer { refreshingMangaIds.remove(mangaId) }

        let smanga = SManga(url: manga.url, title: manga.title, thumbnailUrl: manga.thumbnailUrl)
        let generation = libraryGeneration
        async let detailsTask = try? source.getMangaDetails(manga: smanga)
        let chaptersResult: Result<[SChapter], Error>
        do {
            chaptersResult = .success(try await source.getChapterList(manga: smanga))
        } catch {
            chaptersResult = .failure(error)
        }
        let details = await detailsTask
        guard generation == libraryGeneration else { return false }

        if let details { applyDetails(details, toMangaId: mangaId) }

        switch chaptersResult {
        case .success(let chapters) where chapters.isEmpty:
            if reportsErrors { showStatusBanner("图源没有返回任何章节") }
            return false
        case .success(let chapters):
            let fresh = syncNewChapters(mangaId: mangaId, sourceChapters: chapters, manualFetch: force)
            await syncKomgaProgress(mangaId: mangaId)
            // Upstream's manual fetch (pull to refresh) downloads new chapters too.
            if force, queuesDownloads, downloadNewChapters, !fresh.isEmpty, let manga = self.manga(id: mangaId), manga.favorite {
                enqueueChapterDownloads(manga: manga, chapters: fresh)
            }
            return true
        case .failure(let error) where reportsErrors:
            showStatusBanner("获取章节失败：\(error.localizedDescription)")
            return false
        case .failure:
            return false
        }
    }

    /// Upstream `UpdateManga.awaitUpdateFromSource`: a title in the library keeps its name.
    private func applyDetails(_ details: SManga, toMangaId mangaId: Int64) {
        guard let idx = mangaArrayIndex(mangaId) else { return }
        var updated = mangas[idx]
        updated.updateStrategy = details.updateStrategy
        if !details.title.isEmpty, !updated.favorite || updated.title.isEmpty { updated.title = details.title }
        updated.author = details.author ?? updated.author
        updated.artist = details.artist ?? updated.artist
        updated.description = details.description ?? updated.description
        if !details.genre.isEmpty { updated.genre = details.genre }
        if details.status != .unknown { updated.status = details.status }
        updated.thumbnailUrl = details.thumbnailUrl ?? updated.thumbnailUrl
        updated.initialized = true
        mangas[idx] = updated
    }

    /// Upstream `LibraryUpdateJob.addMangaToQueue`: the library titles an update checks — a category's own update
    /// takes that category, a global one the included and not excluded categories — less what 智能更新 skips
    /// (handed back too) and titles fetched once.
    func libraryUpdateQueue(categoryId: Int64?, window: ClosedRange<Date>) -> (titles: [Manga], skipped: [Manga]) {
        var skipped: [Manga] = []
        let titles = mangas.filter { manga in
            guard manga.favorite else { return false }
            let assigned = mangaCategories[manga.id] ?? []
            let ids = Set(assigned.isEmpty ? [MangaCategory.defaultCategoryId] : assigned)
            if let categoryId {
                guard ids.contains(categoryId) else { return false }
            } else {
                let included = libraryUpdateIncludedCategories.isEmpty || !ids.isDisjoint(with: libraryUpdateIncludedCategories)
                guard included, ids.isDisjoint(with: libraryUpdateExcludedCategories) else { return false }
            }
            switch libraryUpdateSkip(manga, window: window) {
            case nil: return true
            case .fetchedOnce: return false
            case .smartUpdate: skipped.append(manga); return false
            }
        }
        return (titles, skipped)
    }

    /// Upstream `GetUpcomingManga`: library titles expected from today on — ongoing or publishing finished — earliest
    /// first, in the categories 即将推出 shows (titles in none count as 默认).
    public func upcomingManga(now: Date = Date()) -> [Manga] {
        let startOfDay = Calendar.current.startOfDay(for: now)
        // Memoised: titles, categories and filters all bump the library revision or are part of the key.
        let key = "\(libraryRevision)|\(startOfDay.timeIntervalSince1970)|\(upcomingIncludedCategories.sorted())|\(upcomingExcludedCategories.sorted())"
        if let upcomingCache, upcomingCache.key == key { return upcomingCache.titles }
        let titles = mangas
            .filter { manga in
                guard manga.favorite, let next = manga.nextUpdate, next >= startOfDay,
                      manga.status == .ongoing || manga.status == .publishingFinished else { return false }
                let assigned = mangaCategories[manga.id] ?? []
                let ids = Set(assigned.isEmpty ? [MangaCategory.defaultCategoryId] : assigned)
                let included = upcomingIncludedCategories.isEmpty || !ids.isDisjoint(with: upcomingIncludedCategories)
                return included && ids.isDisjoint(with: upcomingExcludedCategories)
            }
            .sorted { ($0.nextUpdate ?? .distantFuture, $0.id) < ($1.nextUpdate ?? .distantFuture, $1.id) }
        upcomingCache = (key, titles)
        return titles
    }

    /// Why a library update leaves a title out (upstream `LibraryUpdateJob.addMangaToQueue`).
    enum LibraryUpdateSkip: Equatable {
        /// Set to fetch once, and fetched: whatever the settings.
        case fetchedOnce
        /// A 智能更新 rule.
        case smartUpdate(LibraryUpdateMangaRestriction)
    }

    func libraryUpdateSkip(_ manga: Manga, window: ClosedRange<Date>) -> LibraryUpdateSkip? {
        let chapters = chaptersByManga[manga.id] ?? []
        if manga.updateStrategy == .onlyFetchOnce && !chapters.isEmpty { return .fetchedOnce }
        let rules = libraryUpdateMangaRestrictions
        if rules.contains(.completed) && manga.status == .completed { return .smartUpdate(.completed) }
        if rules.contains(.hasUnread) && chapters.contains(where: { !$0.read }) { return .smartUpdate(.hasUnread) }
        if rules.contains(.notStarted) && !chapters.isEmpty && !chapters.contains(where: \.read) { return .smartUpdate(.notStarted) }
        if rules.contains(.outsideReleasePeriod), let next = manga.nextUpdate, next > window.upperBound {
            return .smartUpdate(.outsideReleasePeriod)
        }
        return nil
    }

    /// One queue per source: a slow or unreachable site (MangaDex without a proxy) must not hold up the others.
    private func refreshUninitializedLiveManga() async {
        let targets = mangas.filter { $0.favorite && isLiveSource($0.source) && (chaptersByManga[$0.id] ?? []).isEmpty }
        await withTaskGroup(of: Void.self) { group in
            for queue in Dictionary(grouping: targets, by: \.source).values {
                group.addTask { @MainActor in
                    for manga in queue {
                        await self.refreshMangaFromSource(mangaId: manga.id, reportsErrors: false)
                    }
                }
            }
        }
    }

    /// 1:1 with `LibraryUpdateJob`: live entries are refreshed from their source; demo entries simulate a new chapter.
    /// Upstream `LibraryUpdateJob`: the library's titles that update, or those of one category (更新分类). Stops when
    /// its task is cancelled (a background refresh running out of time) and reports what it found until then;
    /// `reportsResult: false` (the background refresh, which notifies instead) shows no snackbar.
    @discardableResult
    public func refreshLibraryUpdates(categoryId: Int64? = nil, reportsResult: Bool = true) async -> LibraryUpdateResult {
        guard !isUpdatingLibrary else { return LibraryUpdateResult() }
        isUpdatingLibrary = true
        libraryUpdateProgress = 0.0
        let generation = libraryGeneration
        let window = FetchInterval.window(today: MihonLocalDate(Date(), in: .current), timeZone: .current)
        let (favs, skippedTitles) = libraryUpdateQueue(categoryId: categoryId, window: window)
        let skipped = skippedTitles.count
        let refreshesMetadata = libraryUpdateRefreshesMetadata
        // A background refresh has about half a minute: titles checked longest ago go first, so the same ones are not
        // checked every time while the rest wait (upstream's job runs to the end, in title order).
        libraryUpdateCheckedAt = libraryUpdateCheckedAt.filter { id, _ in mangaArrayIndex(id) != nil }
        let checkedAt = libraryUpdateCheckedAt
        let step = 1.0 / Double(max(1, favs.count))
        var newChapters = 0
        var failures = 0
        var updated: [LibraryUpdateResult.Title] = []
        var simulatedOnce = false

        // Live titles: one queue per source, like the first fetch, so a slow site does not hold up the others.
        await withTaskGroup(of: (found: Int, failed: Int, updated: [LibraryUpdateResult.Title]).self) { group in
            for titles in Dictionary(grouping: favs.filter { isLiveSource($0.source) }, by: \.source).values {
                let queue = titles.enumerated()
                    .sorted { (checkedAt[$0.element.id] ?? .distantPast, $0.offset) < (checkedAt[$1.element.id] ?? .distantPast, $1.offset) }
                    .map(\.element)
                group.addTask { @MainActor in
                    var found = 0
                    var failed = 0
                    var updated: [LibraryUpdateResult.Title] = []
                    for manga in queue {
                        guard generation == self.libraryGeneration, !Task.isCancelled else { break }
                        if let source = self.catalogueSource(for: manga.source) {
                            do {
                                let smanga = SManga(url: manga.url, title: manga.title, thumbnailUrl: manga.thumbnailUrl)
                                if refreshesMetadata {
                                    let details = try await source.getMangaDetails(manga: smanga)
                                    guard generation == self.libraryGeneration else { break }
                                    self.applyDetails(details, toMangaId: manga.id)
                                }
                                let chapters = try await source.getChapterList(manga: smanga)
                                guard generation == self.libraryGeneration else { break }
                                if chapters.isEmpty {
                                    failed += 1
                                } else {
                                    let fresh = self.syncNewChapters(mangaId: manga.id, sourceChapters: chapters, fetchWindow: window)
                                    await self.syncKomgaProgress(mangaId: manga.id)
                                    found += fresh.count
                                    if !fresh.isEmpty {
                                        updated.append(.init(mangaId: manga.id, title: manga.title,
                                                             chapterNames: fresh.map(\.name), chapterIds: fresh.map(\.id)))
                                    }
                                }
                            } catch {
                                // Out of time is not a failure of the title.
                                if Task.isCancelled { break }
                                failed += 1
                            }
                            self.libraryUpdateCheckedAt[manga.id] = Date()
                        }
                        self.libraryUpdateProgress = min(1, self.libraryUpdateProgress + step)
                    }
                    return (found, failed, updated)
                }
            }
            for await result in group {
                newChapters += result.found
                failures += result.failed
                updated += result.updated
            }
        }

        // Read progress on a Komga server is pulled for titles 智能更新 skipped too: read there, they can stop being
        // skipped here (one request each).
        for manga in skippedTitles where KomgaLiveEngine.handles(sourceId: manga.source) {
            guard generation == libraryGeneration, !Task.isCancelled else { break }
            await syncKomgaProgress(mangaId: manga.id)
        }

        // Demo entries (builds with demo features only) simulate one new chapter.
        for manga in favs where showsDemoFeatures && !isLiveSource(manga.source) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard generation == libraryGeneration else { break }
            if !simulatedOnce, var currentChaps = chaptersByManga[manga.id], !currentChaps.isEmpty {
                simulatedOnce = true
                let latestNum = Int(currentChaps.map(\.chapterNumber).max() ?? 28) + 1
                nextChapterId += 1
                currentChaps.insert(
                    Chapter(
                        id: nextChapterId,
                        mangaId: manga.id,
                        url: "\(manga.url)/chapter-\(latestNum)",
                        name: "第 \(latestNum) 话 - 最新连载",
                        scanlator: "星期五汉化组",
                        totalPages: 18,
                        chapterNumber: Double(latestNum),
                        sourceOrder: -1,
                        dateFetch: Date(),
                        dateUpload: Date()
                    ),
                    at: 0
                )
                chaptersByManga[manga.id] = currentChaps
                newChapters += 1
            }
            if let mIdx = mangaArrayIndex(manga.id) {
                mangas[mIdx].lastUpdate = Date()
            }
            libraryUpdateProgress = min(1, libraryUpdateProgress + step)
        }

        isUpdatingLibrary = false
        if !Task.isCancelled { lastLibraryUpdateAt = Date() }
        // A backup restored meanwhile replaced the titles these counts are about.
        guard generation == libraryGeneration else { return LibraryUpdateResult() }
        newUpdatesCount += newChapters
        let result = LibraryUpdateResult(newChapters: newChapters, failures: failures, titles: updated, skipped: skipped)
        if downloadNewChapters { queueNewChapterDownloads(result) }
        guard reportsResult else { return result }
        let found = newChapters > 0 ? "发现 \(newChapters) 个新章节" : "没有新章节"
        // Upstream reports the titles that failed (offline, a site down) instead of calling the update clean.
        let summary = failures > 0 ? "书架更新完成，\(found)；\(failures) 部作品更新失败" : "书架更新完成，\(found)"
        // Upstream skips without a word, which makes an update of a library not yet read look broken.
        showStatusBanner(skipped > 0 ? "\(summary)。智能更新跳过了 \(skipped) 部作品（设置 › 书架 › 智能更新）" : summary)
        return result
    }

    // MARK: - Covers

    /// The cover a title shows: the custom one (set from a page), else the source's.
    public func coverUrl(for manga: Manga) -> String? {
        guard let version = customCoverVersions[manga.id] else { return manga.thumbnailUrl }
        return MihonCustomCovers.url(manga.id, version: version)
    }

    /// Upstream `setMangaCoverFromPage`: a page becomes the title's cover (its JPEG bytes).
    public func setCustomCover(mangaId: Int64, data: Data) throws {
        // This session shows the seed library, whose ids are not the saved library's: its covers are left alone.
        guard !persistenceBlocked else { throw CustomCoverError.libraryNotLoaded }
        let file = MihonCustomCovers.file(mangaId)
        try FileManager.default.createDirectory(at: MihonCustomCovers.directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        // The file's own date, as the next launch reads it (`MihonCustomCovers.versions`).
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        customCoverVersions[mangaId] = Int64(modified.timeIntervalSince1970 * 1000)
    }

    public func removeCustomCover(mangaId: Int64) {
        guard !persistenceBlocked else { return }
        try? FileManager.default.removeItem(at: MihonCustomCovers.file(mangaId))
        customCoverVersions[mangaId] = nil
    }

    public enum CustomCoverError: Error, LocalizedError {
        case libraryNotLoaded

        public var errorDescription: String? { "书架没有正常读取，这次启动不能更改封面" }
    }

    // MARK: - Komga read progress (upstream's Komga tracker, an enhanced tracker)

    /// Upstream `SyncChapterProgressWithTrack` for an enhanced tracker: chapters numbered up to the server's
    /// progress become read here; what is read here without a gap from the first numbered chapter is the progress
    /// to send — nil when the server is there already.
    nonisolated static func mergeKomgaProgress(_ chapters: [Chapter], remote: Double) -> (chapters: [Chapter], push: Double?) {
        var merged = chapters
        for index in merged.indices where merged[index].chapterNumber >= 0 && merged[index].chapterNumber <= remote && !merged[index].read {
            merged[index].read = true
        }
        let numbered = merged.filter { $0.chapterNumber >= 0 }.sorted { $0.chapterNumber < $1.chapterNumber }
        let localLast = numbered.prefix { $0.read }.last?.chapterNumber ?? 0
        return (merged, localLast > remote ? localLast : nil)
    }

    /// For a Komga series in the library whose account syncs progress (upstream binds the tracker to such titles).
    func syncKomgaProgress(mangaId: Int64) async {
        guard let manga = manga(id: mangaId), manga.favorite, KomgaLiveEngine.isSeries(manga.url),
              let engine = catalogueSource(for: manga.source)?.liveEngine as? KomgaLiveEngine, engine.account.syncsProgress
        else { return }
        let series = SManga(url: manga.url, title: manga.title)
        guard let remote = try? await engine.readProgress(manga: series) else { return }
        let chapters = chaptersByManga[mangaId] ?? []
        let (merged, push) = Self.mergeKomgaProgress(chapters, remote: remote)
        if merged != chapters { chaptersByManga[mangaId] = merged }
        // Incognito tells no one what was read (upstream updates no tracker then).
        if let push, !incognitoMode { try? await engine.setReadProgress(manga: series, lastNumberSort: push) }
    }

    /// After chapters were marked read (reading one to its end, or by hand): the tracked server learns of it.
    private func syncTrackedProgressLater(_ mangaId: Int64) {
        guard let manga = manga(id: mangaId), KomgaLiveEngine.handles(sourceId: manga.source) else { return }
        Task { await syncKomgaProgress(mangaId: mangaId) }
    }

    /// Upstream `LibraryUpdateJob`: the new chapters of titles in the library, queued for download (never a local
    /// title's: its chapters are files already).
    func queueNewChapterDownloads(_ result: LibraryUpdateResult) {
        for title in result.titles {
            guard let manga = manga(id: title.mangaId), manga.favorite, manga.source != MihonLocalSource.sourceId else { continue }
            let chapters = (chaptersByManga[manga.id] ?? []).filter { title.chapterIds.contains($0.id) }
            enqueueChapterDownloads(manga: manga, chapters: chapters)
        }
    }

    /// Upstream `ReaderViewModel.downloadNextChapters`, past a quarter of a chapter: when it and the next one are
    /// downloaded (reading offline, so going on offline is wanted), the next `downloadAheadCount` unread chapters —
    /// counted from the next one, as upstream's `getNextChapters(…, next).take(n)` — are queued.
    public func downloadAhead(after chapter: Chapter, in manga: Manga) {
        guard downloadAheadCount > 0, downloadedChapterIds.contains(chapter.id) else { return }
        let order = readingOrderChapters(mangaId: manga.id)
        guard let index = order.firstIndex(where: { $0.id == chapter.id }), index + 1 < order.count,
              downloadedChapterIds.contains(order[index + 1].id) else { return }
        let next = order[(index + 1)...].filter { !$0.read }.prefix(downloadAheadCount)
        enqueueChapterDownloads(manga: manga, chapters: Array(next))
    }

    public func resetNewUpdatesCount() {
        if newUpdatesCount != 0 { newUpdatesCount = 0 }
    }

    // MARK: - Chapter Operations & Reader Progress Sync

    public func filteredAndSortedChapters(for manga: Manga) -> [Chapter] {
        _ = chaptersRevision
        if let cached = chapterListCache[manga.id] { return cached }
        let raw = chaptersByManga[manga.id] ?? []
        let isLocal = manga.source == 0
        let filtered = raw.filter { chap in
            let downloaded = downloadedChapterIds.contains(chap.id) || isLocal
            if !passesTriState(manga.filterUnread, condition: !chap.read) { return false }
            if !passesTriState(downloadedOnlyMode ? .include : manga.filterDownloaded, condition: downloaded) { return false }
            if !passesTriState(manga.filterBookmarked, condition: chap.bookmark) { return false }
            if downloadedOnlyMode && !downloaded { return false }
            return true
        }

        let sorted = filtered.sorted { Self.precedes($0, $1, by: manga.chapterSortMode, ascending: manga.chapterSortAscending) }
        chapterListCache[manga.id] = sorted
        return sorted
    }

    /// Chapters in reading order — the title's chapter sort, oldest first (upstream `getChapterSort(manga,
    /// sortDescending = false)`): the reader's previous/next, History's resume, 下载后 N 章. By number alone, a
    /// 咚漫 后记 recognized as 1 would sit between 第1话 and 第2话.
    /// Upstream `ReaderViewModel.loadChapterList`: the chapters the reader moves through from `currentChapterId`, in
    /// reading order. Read chapters can be skipped, and those the title's filters hide (on by default); duplicates
    /// keep one chapter per number (the open one, else its scanlator's, else the first); downloaded-only mode keeps
    /// downloaded ones. The open chapter always stays. Memoised per chapter revision and settings.
    public func readerChapters(mangaId: Int64, currentChapterId: Int64) -> [Chapter] {
        _ = chaptersRevision
        let key = "\(mangaId)|\(currentChapterId)|\(skipReadChapters)|\(skipFilteredChapters)|\(skipDuplicateChapters)|\(downloadedOnlyMode)"
        if let cached = readerChaptersCache[key] { return cached }
        let all = readingOrderChapters(mangaId: mangaId)
        guard let manga = manga(id: mangaId), let current = all.first(where: { $0.id == currentChapterId }) else { return all }
        let isLocal = manga.source == MihonLocalSource.sourceId
        func isDownloaded(_ chapter: Chapter) -> Bool { isLocal || downloadedChapterIds.contains(chapter.id) }
        func hiddenByFilters(_ chapter: Chapter) -> Bool {
            (manga.filterUnread == .include && chapter.read) || (manga.filterUnread == .exclude && !chapter.read)
                || (manga.filterDownloaded == .include && !isDownloaded(chapter))
                || (manga.filterDownloaded == .exclude && isDownloaded(chapter))
                || (manga.filterBookmarked == .include && !chapter.bookmark)
                || (manga.filterBookmarked == .exclude && chapter.bookmark)
        }
        var chapters = all.filter { chapter in
            chapter.id == currentChapterId
                || !((skipReadChapters && chapter.read) || (skipFilteredChapters && hiddenByFilters(chapter)))
        }
        if skipDuplicateChapters {
            // Upstream `removeDuplicates`: grouped by number in reading order.
            var groups: [Double: [Chapter]] = [:]
            var order: [Double] = []
            for chapter in chapters {
                if groups[chapter.chapterNumber] == nil { order.append(chapter.chapterNumber) }
                groups[chapter.chapterNumber, default: []].append(chapter)
            }
            chapters = order.compactMap { number in
                let group = groups[number] ?? []
                return group.first { $0.id == current.id } ?? group.first { $0.scanlator == current.scanlator } ?? group.first
            }
        }
        if downloadedOnlyMode {
            chapters = chapters.filter { $0.id == currentChapterId || isDownloaded($0) }
        }
        readerChaptersCache[key] = chapters
        return chapters
    }

    /// Memoised per chapter revision: the reader asks on every render, once per neighbouring chapter.
    public func readingOrderChapters(mangaId: Int64) -> [Chapter] {
        _ = chaptersRevision
        if let cached = readingOrderCache[mangaId] { return cached }
        let chapters = chaptersByManga[mangaId] ?? []
        guard let manga = manga(id: mangaId) else { return chapters }
        let ordered = chapters.sorted { Self.precedes($0, $1, by: manga.chapterSortMode, ascending: true) }
        readingOrderCache[mangaId] = ordered
        return ordered
    }

    private func mutateChapter(mangaId: Int64, chapterId: Int64, _ body: (inout Chapter) -> Void) {
        guard var list = chaptersByManga[mangaId],
              let idx = list.firstIndex(where: { $0.id == chapterId }) else { return }
        body(&list[idx])
        chaptersByManga[mangaId] = list
    }

    public func toggleChapterRead(mangaId: Int64, chapterId: Int64) {
        mutateChapter(mangaId: mangaId, chapterId: chapterId) { chapter in
            chapter.read.toggle()
            chapter.lastPageRead = chapter.read ? max(0, chapter.totalPages - 1) : 0
        }
        if chaptersByManga[mangaId]?.first(where: { $0.id == chapterId })?.read == true { syncTrackedProgressLater(mangaId) }
    }

    public func setChaptersRead(mangaId: Int64, chapterIds: Set<Int64>, read: Bool) {
        guard var list = chaptersByManga[mangaId] else { return }
        for i in list.indices where chapterIds.contains(list[i].id) {
            list[i].read = read
            list[i].lastPageRead = read ? max(0, list[i].totalPages - 1) : 0
        }
        chaptersByManga[mangaId] = list
        if read { syncTrackedProgressLater(mangaId) }
    }

    public func setChaptersBookmarked(mangaId: Int64, chapterIds: Set<Int64>, bookmarked: Bool) {
        guard var list = chaptersByManga[mangaId] else { return }
        for i in list.indices where chapterIds.contains(list[i].id) {
            list[i].bookmark = bookmarked
        }
        chaptersByManga[mangaId] = list
    }

    public func toggleChapterBookmark(mangaId: Int64, chapterId: Int64) {
        mutateChapter(mangaId: mangaId, chapterId: chapterId) { $0.bookmark.toggle() }
    }

    /// Upstream `markPreviousChapterRead`: the chapters shown before `chapterId` in reading order (the displayed
    /// list, reversed when it runs newest first) — by position, so unnumbered extras count where they are listed.
    public func markChaptersRead(before chapterId: Int64, in manga: Manga) {
        let shown = filteredAndSortedChapters(for: manga)
        let readingOrder = manga.chapterSortAscending ? shown : Array(shown.reversed())
        guard let position = readingOrder.firstIndex(where: { $0.id == chapterId }), position > 0 else { return }
        setChaptersRead(mangaId: manga.id, chapterIds: Set(readingOrder.prefix(position).map(\.id)), read: true)
    }

    public func updateChapterPageCount(mangaId: Int64, chapterId: Int64, totalPages: Int) {
        guard let chapter = chaptersByManga[mangaId]?.first(where: { $0.id == chapterId }),
              chapter.totalPages != totalPages, totalPages > 0 else { return }
        mutateChapter(mangaId: mangaId, chapterId: chapterId) { $0.totalPages = totalPages }
    }

    public func recordReadingProgress(
        mangaId: Int64,
        chapterId: Int64,
        pageIndex: Int,
        completedChapter: Bool,
        durationSeconds: Int64 = 45
    ) {
        // Incognito saves no reading progress at all: no page, no read mark, no tracker, no history (upstream
        // `ReaderViewModel.updateChapterProgress`).
        guard !incognitoMode, var list = chaptersByManga[mangaId],
              let idx = list.firstIndex(where: { $0.id == chapterId }) else { return }
        let alreadyRead = list[idx].read
        // Only a read mark (unread counts) or another title becoming the last read changes the library.
        keepsLibraryCache = !(completedChapter && !alreadyRead) && historyEntries.max(by: { $0.readAt < $1.readAt })?.mangaId == mangaId
        defer { keepsLibraryCache = false }
        if list[idx].lastPageRead != pageIndex || (completedChapter && !alreadyRead) {
            list[idx].lastPageRead = pageIndex
            let chapNumber = list[idx].chapterNumber
            if completedChapter && !alreadyRead {
                list[idx].read = true
                if deleteAfterReading && downloadedChapterIds.contains(chapterId) {
                    // Not while the chapter is open: paging back offline needs its files.
                    chaptersPendingDeletion.insert(chapterId)
                }
                if var mangaTracks = tracksByManga[mangaId] {
                    for tIdx in mangaTracks.indices where chapNumber > mangaTracks[tIdx].lastChapterRead {
                        mangaTracks[tIdx].lastChapterRead = chapNumber
                    }
                    tracksByManga[mangaId] = mangaTracks
                }
            }
            chaptersByManga[mangaId] = list
            if completedChapter && !alreadyRead { syncTrackedProgressLater(mangaId) }
        }

        if let hIdx = historyEntries.firstIndex(where: { $0.chapterId == chapterId }) {
            historyEntries[hIdx].readAt = Date()
            historyEntries[hIdx].readDurationSeconds += durationSeconds
        } else {
            let nextId = (historyEntries.map(\.id).max() ?? 0) + 1
            historyEntries.insert(
                HistoryEntry(id: nextId, chapterId: chapterId, mangaId: mangaId, readAt: Date(), readDurationSeconds: durationSeconds),
                at: 0
            )
        }
    }

    /// The chapter History's resume button opens (upstream `GetNextChapters`, `onlyUnread = false`): the history
    /// chapter while it is unfinished, otherwise the one after it in reading order, read or not; nil at the end.
    public func chapterToResume(mangaId: Int64, fromChapterId chapterId: Int64) -> Chapter? {
        let ordered = readingOrderChapters(mangaId: mangaId)
        guard let index = ordered.firstIndex(where: { $0.id == chapterId }) else { return ordered.first }
        if !ordered[index].read { return ordered[index] }
        return ordered.indices.contains(index + 1) ? ordered[index + 1] : nil
    }

    /// Memoised per chapter revision (the details screen asks on every render).
    public func nextUnreadChapter(for mangaId: Int64) -> Chapter? {
        _ = chaptersRevision
        if let cached = nextUnreadCache[mangaId] { return cached }
        let next = Self.nextUnread(in: chaptersByManga[mangaId] ?? [], sortedBy: manga(id: mangaId)?.chapterSortMode ?? .source)
        nextUnreadCache.updateValue(next, forKey: mangaId)
        return next
    }

    /// How long a fetched page list is reused: MangaDex@Home URLs carry a token valid for 15 minutes, 再漫画 signs
    /// its URLs with an expiry (`t`).
    static let pageListLifetime: TimeInterval = 5 * 60

    /// Resolves the page list for the reader: offline download → live source → demo renderer.
    public func pageList(for manga: Manga, chapter: Chapter) async throws -> [Page] {
        if let cached = pageListCache[chapter.id], Date().timeIntervalSince(cached.fetched) < Self.pageListLifetime {
            return cached.pages
        }
        let generation = pageListGeneration
        let pages: [Page]
        if downloadedChapterIds.contains(chapter.id),
           let urls = MihonTwoTierImageCache.shared.downloadedPageList(chapterId: chapter.id), !urls.isEmpty {
            // Downloaded: the saved list points at the files on disk; no network needed.
            pages = urls.enumerated().map { idx, url in
                Page(index: idx, url: chapter.url, imageUrl: url, chapterTitle: chapter.name, mangaTitle: manga.title)
            }
        } else if let source = catalogueSource(for: manga.source), source.isLive {
            pages = try await source.getPageList(chapter: SChapter(url: chapter.url, name: chapter.name))
            // Upstream's "No pages found": a locked episode or an error page, never a chapter to show or download.
            guard !pages.isEmpty else { throw ChapterPagesError.noPages }
        } else if !showsDemoFeatures {
            // A title from a source this build does not have (restored, or saved by an earlier build).
            throw ChapterPagesError.sourceNotInstalled
        } else {
            let count = max(1, chapter.totalPages)
            pages = (0..<count).map { idx in
                Page(index: idx, url: "\(chapter.url)/\(idx + 1)", imageUrl: nil, chapterTitle: chapter.name, mangaTitle: manga.title)
            }
        }
        // A backup restored during the request may have given this id to another chapter.
        guard generation == pageListGeneration else { return pages }
        pageListCache[chapter.id] = (pages, Date())
        updateChapterPageCount(mangaId: manga.id, chapterId: chapter.id, totalPages: pages.count)
        return pages
    }

    // MARK: - Updates & History Queries

    public func recentUpdates(searchQuery: String = "") -> [UpdateWithRelations] {
        let horizon = Date().addingTimeInterval(-86400 * 90)
        var items: [UpdateWithRelations] = []
        for manga in mangas where manga.favorite {
            if !searchQuery.isEmpty && !manga.title.localizedCaseInsensitiveContains(searchQuery) { continue }
            let added = manga.dateAdded ?? .distantPast
            let isLocal = manga.source == 0
            for chap in chaptersByManga[manga.id] ?? [] where chap.dateFetch > horizon && chap.dateFetch > added {
                items.append(UpdateWithRelations(manga: manga, chapter: chap, isDownloaded: downloadedChapterIds.contains(chap.id) || isLocal))
            }
        }
        items.sort { $0.chapter.dateFetch > $1.chapter.dateFetch }
        return Array(items.prefix(400))
    }

    /// Upstream `historyView`: one row per title, for the chapter read last, newest first; the search matches titles.
    public func readingHistory(searchQuery: String = "") -> [HistoryWithRelations] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = Set<Int64>()
        var rows: [HistoryWithRelations] = []
        for entry in historyEntries.sorted(by: { $0.readAt > $1.readAt }) where !shown.contains(entry.mangaId) {
            guard let manga = manga(id: entry.mangaId),
                  let chapter = chaptersByManga[entry.mangaId]?.first(where: { $0.id == entry.chapterId }) else { continue }
            shown.insert(entry.mangaId)
            guard query.isEmpty || manga.title.localizedCaseInsensitiveContains(query) else { continue }
            rows.append(HistoryWithRelations(
                id: entry.id, manga: manga, chapter: chapter, readAt: entry.readAt, readDurationSeconds: entry.readDurationSeconds
            ))
        }
        return rows
    }

    public func deleteHistoryEntry(id: Int64) {
        historyEntries.removeAll { $0.id == id }
    }

    public func deleteAllHistory(forMangaId mangaId: Int64) {
        historyEntries.removeAll { $0.mangaId == mangaId }
    }

    public func clearAllHistory() {
        historyEntries.removeAll()
        showStatusBanner("已清除历史记录")
    }

    // MARK: - Download Queue Engine

    public func downloadTask(for chapterId: Int64) -> MihonDownloadTask? {
        _ = downloadQueue
        return downloadTasksById[chapterId]
    }

    public func downloadState(for chapter: Chapter, in manga: Manga) -> DownloadStatus {
        if manga.source == 0 || downloadedChapterIds.contains(chapter.id) { return .downloaded }
        return downloadTask(for: chapter.id)?.status ?? .notDownloaded
    }

    public func enqueueChapterDownload(manga: Manga, chapter: Chapter) {
        guard manga.source != 0,
              !downloadedChapterIds.contains(chapter.id),
              downloadTasksById[chapter.id] == nil else { return }

        let task = MihonDownloadTask(
            manga: manga,
            chapter: chapter,
            sourceName: sourceName(for: manga.source),
            status: .queue,
            totalPages: chapter.totalPages
        )
        // A pause ends with the queue it paused (upstream starts the downloader when adding to an empty queue).
        if downloadQueue.isEmpty { isDownloaderRunning = true }
        downloadTasksById[chapter.id] = task
        downloadQueue.append(task)
        startDownloaderIfNeeded()
    }

    /// Oldest first (upstream `Downloader.queueChapters` sorts by source order): what is read next comes first.
    public func enqueueChapterDownloads(manga: Manga, chapters: [Chapter]) {
        for chapter in chapters.sorted(by: { $0.sourceOrder > $1.sourceOrder }) {
            enqueueChapterDownload(manga: manga, chapter: chapter)
        }
    }

    public func removeChapterDownload(chapterId: Int64) {
        downloadedChapterIds.remove(chapterId)
        MihonTwoTierImageCache.shared.removeDownloadedChapter(chapterId: chapterId)
        pageListCache[chapterId] = nil
        cancelDownload(chapterId: chapterId)
    }

    /// Every offline chapter, those still downloading included.
    public func removeAllDownloads() {
        clearDownloadQueue()
        MihonTwoTierImageCache.shared.removeAllDownloads()
        for chapterId in downloadedChapterIds {
            pageListCache[chapterId] = nil
        }
        downloadedChapterIds.removeAll()
    }

    /// Delete-after-reading, once the reader has closed (upstream's `deletePendingChapters`): a chapter read to its
    /// last page goes unless it was marked unread since.
    public func deletePendingReadChapters() {
        let pending = chaptersPendingDeletion
        guard !pending.isEmpty else { return }
        chaptersPendingDeletion.removeAll()
        let readIds = Set(chaptersByManga.values.joined().filter { pending.contains($0.id) && $0.read }.map(\.id))
        for chapterId in readIds where downloadedChapterIds.contains(chapterId) {
            removeChapterDownload(chapterId: chapterId)
        }
    }

    public func cancelDownload(chapterId: Int64) {
        guard downloadTasksById.removeValue(forKey: chapterId) != nil else { return }
        downloadQueue.removeAll { $0.id == chapterId }
    }

    public func toggleDownloaderRunning() {
        isDownloaderRunning.toggle()
        if isDownloaderRunning {
            startDownloaderIfNeeded()
        }
        updateBackgroundTimeForDownloads()
    }

    public func clearDownloadQueue() {
        downloadTasksById.removeAll()
        downloadQueue.removeAll()
    }

    private func startDownloaderIfNeeded() {
        guard downloadWorker == nil else { return }
        if !didSweepDownloads && !persistenceBlocked {
            // No download runs yet, so a page stored but not yet listed cannot be mistaken for a leftover. Queued
            // chapters (a queue restored at launch) keep what they already have.
            didSweepDownloads = true
            MihonTwoTierImageCache.shared.removeIncompleteDownloads(keeping: downloadedChapterIds.union(downloadQueue.map(\.id)))
        }
        downloadWorker = Task { [weak self] in
            // Paused between chapters, the worker ends (resuming starts a new one); paused within one, it waits there.
            while let self, !Task.isCancelled, self.isDownloaderRunning, let task = self.downloadQueue.first {
                await self.performDownload(task)
            }
            self?.downloadWorker = nil
            self?.updateBackgroundTimeForDownloads()
        }
        updateBackgroundTimeForDownloads()
    }

    /// Background time is held while downloads run, and asked for again each time the app leaves the screen (iOS
    /// ends it after a while, and the expiry handler gives it back).
    private func updateBackgroundTimeForDownloads() {
        holdBackgroundTimeForDownloads(downloadWorker != nil && isDownloaderRunning && !downloadQueue.isEmpty)
    }

    /// iOS lets downloads run on for a while once the app leaves the screen (upstream downloads in a foreground
    /// service, which iOS does not have); what is left waits in the queue saved with the settings.
    private func holdBackgroundTimeForDownloads(_ hold: Bool) {
        #if canImport(UIKit)
        if hold, backgroundDownloadTask == .invalid {
            backgroundDownloadTask = UIApplication.shared.beginBackgroundTask(withName: "MihonDownloads") { [weak self] in
                MainActor.assumeIsolated { self?.holdBackgroundTimeForDownloads(false) }
            }
        } else if !hold, backgroundDownloadTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundDownloadTask)
            backgroundDownloadTask = .invalid
        }
        #endif
    }

    /// Re-queues the chapters left in the queue when the app last stopped (iOS may end it in the background),
    /// paused until the user resumes.
    func restoreDownloadQueue() {
        let ids = queuedChapterIdsToRestore
        queuedChapterIdsToRestore = []
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        if !didSweepDownloads {
            // Before the first enqueue would sweep with only that chapter queued: every restored chapter keeps the
            // pages it already has.
            didSweepDownloads = true
            MihonTwoTierImageCache.shared.removeIncompleteDownloads(keeping: downloadedChapterIds.union(wanted))
        }
        var found: [Int64: (Manga, Chapter)] = [:]
        for manga in mangas {
            for chapter in chaptersByManga[manga.id] ?? [] where wanted.contains(chapter.id) {
                found[chapter.id] = (manga, chapter)
            }
        }
        for id in ids {
            if let (manga, chapter) = found[id] { enqueueChapterDownload(manga: manga, chapter: chapter) }
        }
        if !downloadQueue.isEmpty { isDownloaderRunning = false }
    }

    /// Live chapters download every page into the downloads folder; demo chapters simulate the transfer. The page
    /// list is saved before the first page, so the pages it shares with other downloads count as in use, and an
    /// abort (cancelled, queue cleared, an error) deletes what this download stored.
    private func performDownload(_ task: MihonDownloadTask) async {
        // The task in the queue under this id, which is a new one when the chapter was cancelled and queued again.
        func isActive() -> Bool { downloadTasksById[task.id] === task }
        // A connection that drops for a moment (the phone locked, a lift, another network) costs a retry, not the
        // chapter: two more attempts, a few seconds apart.
        func retrying<T>(_ operation: () async throws -> T) async throws -> T {
            var attempt = 1
            while true {
                do {
                    return try await operation()
                } catch {
                    guard attempt < 3, isActive(), !(error is CancellationError), !(error is ChapterPagesError) else { throw error }
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    attempt += 1
                }
            }
        }
        let cache = MihonTwoTierImageCache.shared
        // What an abort stored, unless the id meanwhile files a downloaded chapter (a restored backup's).
        func discardStoredPages() {
            if !downloadedChapterIds.contains(task.id) { cache.removeDownloadedChapter(chapterId: task.id) }
        }
        task.status = .downloading
        if let source = catalogueSource(for: task.manga.source), source.isLive {
            do {
                // A fresh list: one the reader cached earlier may expire before the last page is fetched.
                pageListCache[task.id] = nil
                let pages = try await retrying { try await pageList(for: task.manga, chapter: task.chapter) }
                guard isActive() else { return }
                task.totalPages = pages.count
                cache.saveDownloadedPageList(chapterId: task.id, urls: pages.compactMap(\.imageUrl))
                for page in pages {
                    while !isDownloaderRunning && isActive() {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    guard isActive() else { break }
                    if let urlString = page.imageUrl, let url = URL(string: urlString), !cache.hasDiskEntry(for: urlString) {
                        let data = try await retrying { try await MihonNetworkClient.shared.fetchAsset(url: url) }
                        let stored = await Task.detached(priority: .utility) {
                            cache.storeRawData(data, forKey: urlString)
                        }.value
                        guard stored else { throw MihonNetworkError.invalidResponse }
                    }
                    task.downloadedPages += 1
                }
                guard isActive() else {
                    discardStoredPages()
                    return
                }
            } catch {
                discardStoredPages()
                guard isActive() else { return }
                task.status = .error
                task.errorMessage = error.localizedDescription
                downloadQueue.removeAll { $0 === task }
                downloadTasksById[task.id] = nil
                showStatusBanner("下载失败：\(task.chapter.name)")
                return
            }
        } else if !showsDemoFeatures {
            task.status = .error
            task.errorMessage = ChapterPagesError.sourceNotInstalled.localizedDescription
            downloadQueue.removeAll { $0 === task }
            downloadTasksById[task.id] = nil
            showStatusBanner("下载失败：\(ChapterPagesError.sourceNotInstalled.localizedDescription)")
            return
        } else {
            task.totalPages = max(1, task.totalPages)
            while task.downloadedPages < task.totalPages {
                guard isActive() else { return }
                try? await Task.sleep(nanoseconds: 160_000_000)
                if isDownloaderRunning {
                    task.downloadedPages = min(task.totalPages, task.downloadedPages + 2)
                }
            }
            guard isActive() else { return }
        }
        task.status = .downloaded
        downloadedChapterIds.insert(task.id)
        downloadTasksById[task.id] = nil
        downloadQueue.removeAll { $0 === task }
    }

    // MARK: - Categories Management

    public func addCategory(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCategoryNameTaken(trimmed) else { return }
        let nextId = (categories.map(\.id).max() ?? 0) + 1
        categories.append(MangaCategory(id: nextId, name: trimmed, order: categories.count))
    }

    public func renameCategory(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCategoryNameTaken(trimmed, except: id),
              let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].name = trimmed
    }

    /// Upstream refuses a second category with the same name (`CategoryNameAlreadyExistsException`).
    private func isCategoryNameTaken(_ name: String, except id: Int64? = nil) -> Bool {
        let taken = categories.contains { $0.id != id && !$0.isSystemCategory && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if taken { showStatusBanner("已有名为「\(name)」的分类") }
        return taken
    }

    public func moveCategory(id: Int64, by offset: Int) {
        var ordered = categories.sorted { $0.order < $1.order }
        guard let idx = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard ordered.indices.contains(target), !ordered[target].isSystemCategory else { return }
        ordered.swapAt(idx, target)
        for i in ordered.indices { ordered[i].order = i }
        categories = ordered
    }

    public func deleteCategory(id: Int64) {
        guard id != MangaCategory.defaultCategoryId else { return }
        // A later category may get this id; titles added afterwards must not end up there.
        if defaultLibraryCategory == id { defaultLibraryCategory = -1 }
        categories.removeAll { $0.id == id }
        // An include list left with only a deleted category would match no title at all.
        libraryUpdateIncludedCategories.remove(id)
        libraryUpdateExcludedCategories.remove(id)
        upcomingIncludedCategories.remove(id)
        upcomingExcludedCategories.remove(id)
        var mapping = mangaCategories
        for (mangaId, cats) in mapping where cats.contains(id) {
            mapping[mangaId] = cats.filter { $0 != id }
        }
        mangaCategories = mapping
    }

    public func setCategoriesForManga(mangaId: Int64, categoryIds: [Int64]) {
        mangaCategories[mangaId] = categoryIds.isEmpty ? [MangaCategory.defaultCategoryId] : categoryIds
    }

    // MARK: - Source Migration (Migrate Manga Across Sources)

    /// Upstream `MigrateMangaUseCase`: the target is fetched in full (or nothing happens), then takes over the current
    /// title's read chapters (up to the furthest read number), bookmarks and fetch dates (same number), categories,
    /// custom cover, notes, chapter settings and reading mode. Replacing takes the current title out of the library;
    /// copying keeps both. Returns whether it migrated.
    @discardableResult
    public func migrateManga(currentId: Int64, to target: SManga, sourceId: Int64, replace: Bool) async -> Bool {
        // One migration of a title at a time (upstream blocks the screen while it runs).
        guard manga(id: currentId) != nil, !migratingMangaIds.contains(currentId) else { return false }
        let targetId = upsertCatalogMangaToStore(target, sourceId: sourceId).id
        guard targetId != currentId else {
            showStatusBanner("这就是原来的作品")
            return false
        }
        migratingMangaIds.insert(currentId)
        defer { migratingMangaIds.remove(currentId) }
        let generation = libraryGeneration
        // A refresh of the target already running (it was open) is waited for, then fetched again: its old chapters
        // must not pass for a successful fetch.
        for _ in 0..<300 where refreshingMangaIds.contains(targetId) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let fetchedChapters = await refreshMangaFromSource(mangaId: targetId, force: true, reportsErrors: false, queuesDownloads: false)
        // Upstream aborts when the target cannot be fetched: never a title out of the library for a stale one.
        guard fetchedChapters, generation == libraryGeneration, let current = manga(id: currentId), let fetched = manga(id: targetId)
        else {
            showStatusBanner("无法获取目标作品的章节，没有迁移")
            return false
        }
        let flags = migrationFlags
        if flags.contains(.chapters) {
            let previous = chaptersByManga[currentId] ?? []
            let maxRead = previous.filter { $0.read && $0.chapterNumber >= 0 }.map(\.chapterNumber).max()
            var chapters = chaptersByManga[targetId] ?? []
            for index in chapters.indices where chapters[index].chapterNumber >= 0 {
                if let match = previous.first(where: { $0.chapterNumber >= 0 && $0.chapterNumber == chapters[index].chapterNumber }) {
                    chapters[index].dateFetch = match.dateFetch
                    chapters[index].bookmark = match.bookmark
                }
                if let maxRead, chapters[index].chapterNumber <= maxRead { chapters[index].read = true }
            }
            chaptersByManga[targetId] = chapters
        }
        if flags.contains(.categories) { mangaCategories[targetId] = mangaCategories[currentId] ?? [] }
        // Upstream `UpsertTrack`: the target's track of the same tracker is replaced, its others stay.
        if let tracks = tracksByManga[currentId], !tracks.isEmpty {
            var merged = tracksByManga[targetId] ?? []
            var nextTrackId = (tracksByManga.values.joined().map(\.id).max() ?? 0) + 1
            for track in tracks {
                var moved = track
                moved.mangaId = targetId
                if let existing = merged.firstIndex(where: { $0.trackerId == track.trackerId }) {
                    moved.id = merged[existing].id
                    merged[existing] = moved
                } else {
                    moved.id = nextTrackId
                    nextTrackId += 1
                    merged.append(moved)
                }
            }
            tracksByManga[targetId] = merged
        }
        if flags.contains(.customCover), customCoverVersions[currentId] != nil,
           let data = try? Data(contentsOf: MihonCustomCovers.file(currentId)) {
            try? setCustomCover(mangaId: targetId, data: data)
        }
        if flags.contains(.removeDownloads) {
            // Upstream `deleteManga(removeQueued = true)`: the queued and running ones too.
            for chapter in chaptersByManga[currentId] ?? [] {
                if downloadedChapterIds.contains(chapter.id) {
                    removeChapterDownload(chapterId: chapter.id)
                } else {
                    cancelDownload(chapterId: chapter.id)
                }
            }
        }
        let now = Date()
        if let index = mangaArrayIndex(targetId) {
            var updated = mangas[index]
            updated.favorite = true
            updated.dateAdded = replace ? (current.dateAdded ?? now) : now
            updated.favoriteModifiedAt = now
            updated.chapterSortMode = current.chapterSortMode
            updated.chapterSortAscending = current.chapterSortAscending
            updated.chapterDisplayMode = current.chapterDisplayMode
            updated.filterUnread = current.filterUnread
            updated.filterDownloaded = current.filterDownloaded
            updated.filterBookmarked = current.filterBookmarked
            // Only a mode the user chose: the current source's own default (咚漫's webtoon) is not one.
            let sourceDefault = sourceDescriptor(for: current.source).flatMap(liveEngine(for:))?.preferredReadingMode ?? .defaultMode
            if current.readingModeOverride != .defaultMode && current.readingModeOverride != sourceDefault {
                updated.readingModeOverride = current.readingModeOverride
            }
            if flags.contains(.notes) { updated.notes = current.notes }
            mangas[index] = updated
        }
        // Directly, not `removeFromLibrary`: that would drop the custom cover just copied from it.
        if replace, let index = mangaArrayIndex(currentId) {
            mangas[index].favorite = false
            mangas[index].favoriteModifiedAt = now
        }
        showStatusBanner(replace ? "已迁移到「\(fetched.title)」" : "已复制为「\(fetched.title)」")
        return true
    }

    /// Upstream `MigrationFlag`: what a migration carries over (all of it by default).
    public enum MigrationFlag: String, Codable, CaseIterable, Sendable {
        case chapters = "章节"
        case categories = "分类"
        case customCover = "自定义封面"
        case notes = "注释"
        case removeDownloads = "删除已下载的章节"
    }

    // MARK: - Tracker Operations

    public func bindOrUpdateTrack(_ track: Track) {
        var list = tracksByManga[track.mangaId] ?? []
        if let idx = list.firstIndex(where: { $0.trackerId == track.trackerId }) {
            list[idx] = track
        } else {
            list.append(track)
        }
        tracksByManga[track.mangaId] = list
    }

    public func removeTrack(mangaId: Int64, trackerId: Int64) {
        tracksByManga[mangaId]?.removeAll { $0.trackerId == trackerId }
    }

    public func toggleTrackerLogin(trackerId: Int64) {
        guard let idx = trackers.firstIndex(where: { $0.id == trackerId }) else { return }
        trackers[idx].isLoggedIn.toggle()
        trackers[idx].username = trackers[idx].isLoggedIn ? "demo_user" : nil
    }

    public func importHTMLSource(_ data: Data) throws {
        guard data.count <= 64 * 1024 else { throw HTMLSourceError.invalidRule }
        let rule = try JSONDecoder().decode(HTMLSourceRule.self, from: data).validated()
        if let existing = sourceDescriptor(for: rule.id), importedRules[existing.id] == nil {
            throw HTMLSourceError.invalidRule
        }
        installRule(rule)
        saveRules()
        showStatusBanner("已导入图源「\(rule.name)」")
    }

    private func installRule(_ rule: HTMLSourceRule) {
        let model = rule.extensionModel(id: rule.id, package: "org.orihon.import.\(rule.id)")
        importedRules[rule.id] = rule
        if let index = extensions.firstIndex(where: { $0.pkgName == model.pkgName }) {
            extensions[index] = model
        } else {
            extensions.append(model)
        }
    }

    private func saveRules() {
        // A reader reopened after a rule change must resolve its pages with the new selectors.
        pageListGeneration &+= 1
        pageListCache.removeAll()
        if persistsState, let data = try? JSONEncoder().encode(Array(importedRules.values)) {
            UserDefaults.standard.set(data, forKey: Self.rulesKey)
        }
    }

    public func removeHTMLSource(id: Int64) {
        guard importedRules.removeValue(forKey: id) != nil else { return }
        extensions.removeAll { $0.pkgName == "org.orihon.import.\(id)" }
        saveRules()
    }

    public func websiteURL(sourceId: Int64, path: String) -> URL? {
        if sourceId == BikaWebsite.sourceId { return BikaWebsite.siteURL(path) }
        let rule = importedRules[sourceId] ?? MihonLiveSources.websites[sourceId]?.rule
        return rule?.siteURL(path)
    }

    // MARK: - Extension Repo Management

    public func addExtensionRepo(url: String, name: String) {
        let trimmed = MihonNetworkClient.cleanRepoBaseUrl(url.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, !extensionRepos.contains(where: { $0.baseUrl == trimmed }) else { return }
        extensionRepos.append(
            ExtensionRepo(
                baseUrl: trimmed,
                name: name.isEmpty ? (URL(string: trimmed)?.host ?? "自定义仓库") : name,
                shortName: nil,
                website: trimmed,
                signingKeyFingerprint: "—"
            )
        )
        showStatusBanner("已添加插件仓库")
        Task {
            await fillMissingSigningKey(baseUrl: trimmed)
            await syncExtensionsFromKeiyoushiRepo()
        }
    }

    public func removeExtensionRepo(baseUrl: String) {
        extensionRepos.removeAll { $0.baseUrl == baseUrl }
    }

    public func repoName(for repoUrl: String) -> String {
        let clean = MihonNetworkClient.cleanRepoBaseUrl(repoUrl)
        return extensionRepos.first { MihonNetworkClient.cleanRepoBaseUrl($0.baseUrl) == clean }?.name ?? "Keiyoushi"
    }

    // MARK: - Backup & Restore (.tachibk / .mihonbk JSON)

    /// Upstream `BackupCreateJob`: a backup in the autobackup folder when one is due — checked at launch and when the
    /// app leaves the foreground. Never from a session whose saved library could not be read: that would back up
    /// the seed library and prune the real backups.
    @discardableResult
    public func performAutomaticBackupIfDue(now: Date = Date()) async -> URL? {
        guard autoBackupInterval > 0, !persistenceBlocked, !isWritingAutoBackup else { return nil }
        if let last = lastAutoBackupAt, now.timeIntervalSince(last) < TimeInterval(autoBackupInterval) * 3600 { return nil }
        guard let data = try? createBackupJSONData() else { return nil }
        isWritingAutoBackup = true
        defer { isWritingAutoBackup = false }
        let file = await Task.detached(priority: .utility) { try? MihonAutoBackup.write(data, at: now) }.value
        if file != nil { lastAutoBackupAt = now }
        return file
    }

    public func createBackupJSONData() throws -> Data {
        let payload = MihonBackupPayload(
            backupManga: mangas,
            backupCategories: categories,
            mangaCategoriesMap: mangaCategories,
            backupChapters: chaptersByManga.values.flatMap { $0 },
            backupHistory: historyEntries,
            backupTracks: tracksByManga.values.flatMap { $0 },
            backupExtensionRepos: extensionRepos
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// Upstream `BackupCreator` with its default options, for Mihon / Tachiyomi on Android (`TachiyomiBackupEncoder`):
    /// the library, and the titles outside it that have been read (`getReadMangaNotInLibrary`), with their chapters,
    /// categories and history.
    public func createTachiyomiBackupData() async throws -> Data {
        let readTitles = Set(chaptersByManga.compactMap { mangaId, chapters in
            chapters.contains { $0.read || $0.lastPageRead != 0 } ? mangaId : nil
        })
        let titles = mangas.filter { $0.favorite || readTitles.contains($0.id) }
        let ids = Set(titles.map(\.id))
        let payload = MihonBackupPayload(
            backupManga: titles,
            backupCategories: categories,
            mangaCategoriesMap: mangaCategories.filter { ids.contains($0.key) },
            backupChapters: titles.flatMap { chaptersByManga[$0.id] ?? [] },
            backupHistory: historyEntries.filter { ids.contains($0.mangaId) },
            backupTracks: [],
            backupExtensionRepos: []
        )
        // Upstream `SourcesBackupCreator`: the source's own name, which Mihon shows for a source it lacks.
        var sourceNames: [Int64: String] = [:]
        for sourceId in Set(titles.map(\.source)) {
            sourceNames[sourceId] = sourceDescriptor(for: sourceId)?.name ?? stubSourceNames[sourceId]
        }
        return try await Task.detached(priority: .userInitiated) { [sourceNames] in
            try TachiyomiBackupEncoder.encode(payload, sourceNames: sourceNames)
        }.value
    }

    /// A backup file: upstream's `.tachibk` (from Mihon / Tachiyomi on Android) or this port's JSON.
    public nonisolated static func decodeBackup(_ data: Data) throws -> TachiyomiBackupDecoder.Result {
        if TachiyomiBackupDecoder.isTachiyomiBackup(data) {
            return try TachiyomiBackupDecoder.decode(data)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return TachiyomiBackupDecoder.Result(payload: try decoder.decode(MihonBackupPayload.self, from: data), sourceNames: [:])
    }

    /// The titles in a backup's library: decoding the file is the check that it can be restored at all.
    public func libraryTitleCount(inBackup data: Data) throws -> Int {
        try Self.decodeBackup(data).payload.backupManga.filter(\.favorite).count
    }

    public func restoreFromBackup(_ data: Data) throws {
        restore(try Self.decodeBackup(data))
    }

    /// Upstream `BackupRestorer`: a backup is merged into the library, never replacing it. Categories match by
    /// name, titles by source and URL, chapters by URL (read, bookmark and progress keep whichever is further
    /// along), history keeps the later read. What the backup adds gets new ids, so nothing already here — a
    /// download, a queued chapter, a page list being fetched — changes id.
    public func restoreFromBackupJSONData(_ data: Data) throws {
        try restoreFromBackup(data)
    }

    /// See `restoreFromBackupJSONData`; also keeps the names of the backup's sources this build lacks.
    public func restore(_ backup: TachiyomiBackupDecoder.Result) {
        let payload = backup.payload
        for (id, name) in backup.sourceNames where sourceDescriptor(for: id) == nil {
            stubSourceNames[id] = name
        }

        var categoryIds: [Int64: Int64] = [MangaCategory.defaultCategoryId: MangaCategory.defaultCategoryId]
        var mergedCategories = categories
        var nextCategoryId = (mergedCategories.map(\.id).max() ?? 0) + 1
        func sameName(_ lhs: String, _ rhs: String) -> Bool {
            lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        for category in payload.backupCategories.sorted(by: { $0.order < $1.order }) where !category.isSystemCategory {
            if let existing = mergedCategories.first(where: { !$0.isSystemCategory && sameName($0.name, category.name) }) {
                categoryIds[category.id] = existing.id
            } else {
                mergedCategories.append(MangaCategory(id: nextCategoryId, name: category.name, order: mergedCategories.count))
                categoryIds[category.id] = nextCategoryId
                nextCategoryId += 1
            }
        }
        categories = mergedCategories

        var mangaIds: [Int64: Int64] = [:]
        var merged = mangas
        var titleIndex = Dictionary(merged.indices.map { ("\(merged[$0].source)|\(merged[$0].url)", $0) }, uniquingKeysWith: { first, _ in first })
        // Above every id anything refers to, chapters or categories of titles removed included.
        var nextMangaId = (Set(merged.map(\.id)).union(chaptersByManga.keys).union(mangaCategories.keys).max() ?? 0) + 1
        var categoriesByManga = mangaCategories
        var addedTitles = 0
        var addedMangaIds: [Int64] = []
        for var backupManga in payload.backupManga {
            // Backups from before the 咚漫 URL migration name titles the old way.
            if backupManga.source == MihonSeedData.dongmanSourceId {
                backupManga.url = DongmanLiveEngine.canonicalTitleUrl(backupManga.url)
            }
            let key = "\(backupManga.source)|\(backupManga.url)"
            let id: Int64
            if let index = titleIndex[key] {
                id = merged[index].id
                let wasFavorite = merged[index].favorite
                // Upstream `mergeManga`: in the library here or in the backup — a restore never takes a title out
                // (old Mihon backups stamp `favoriteModifiedAt` on every refresh, so it cannot decide).
                if backupManga.favorite && !wasFavorite {
                    merged[index].favorite = true
                    merged[index].favoriteModifiedAt = backupManga.favoriteModifiedAt ?? Date()
                }
                if merged[index].favorite && !wasFavorite {
                    merged[index].dateAdded = backupManga.dateAdded ?? Date()
                    addedTitles += 1
                }
                if merged[index].description?.isEmpty ?? true { merged[index].description = backupManga.description }
                if merged[index].thumbnailUrl?.isEmpty ?? true { merged[index].thumbnailUrl = backupManga.thumbnailUrl }
            } else {
                var manga = backupManga
                manga.id = nextMangaId
                nextMangaId += 1
                id = manga.id
                titleIndex[key] = merged.count
                merged.append(manga)
                addedMangaIds.append(manga.id)
                if manga.favorite { addedTitles += 1 }
            }
            mangaIds[backupManga.id] = id
            let restored = (payload.mangaCategoriesMap[backupManga.id] ?? [])
                .compactMap { categoryIds[$0] }
                .filter { $0 != MangaCategory.defaultCategoryId }
            if !restored.isEmpty {
                var ids = (categoriesByManga[id] ?? []).filter { $0 != MangaCategory.defaultCategoryId }
                for category in restored where !ids.contains(category) {
                    ids.append(category)
                }
                categoriesByManga[id] = ids
            }
        }
        mangas = merged
        mangaCategories = categoriesByManga

        var chapterIds: [Int64: Int64] = [:]
        var chapters = chaptersByManga
        var addedChapters = 0
        for (backupMangaId, backupChapters) in Dictionary(grouping: payload.backupChapters, by: \.mangaId) {
            guard let mangaId = mangaIds[backupMangaId] else { continue }
            var list = chapters[mangaId] ?? []
            var chapterIndex = Dictionary(list.indices.map { (list[$0].url, $0) }, uniquingKeysWith: { first, _ in first })
            for backupChapter in backupChapters {
                if let index = chapterIndex[backupChapter.url] {
                    list[index].read = list[index].read || backupChapter.read
                    list[index].bookmark = list[index].bookmark || backupChapter.bookmark
                    list[index].lastPageRead = max(list[index].lastPageRead, backupChapter.lastPageRead)
                    chapterIds[backupChapter.id] = list[index].id
                } else {
                    nextChapterId += 1
                    var chapter = backupChapter
                    chapter.id = nextChapterId
                    chapter.mangaId = mangaId
                    chapterIndex[chapter.url] = list.count
                    list.append(chapter)
                    chapterIds[backupChapter.id] = chapter.id
                    addedChapters += 1
                }
            }
            chapters[mangaId] = list
        }
        chaptersByManga = chapters

        // Upstream `MangaRestorer`: a restored title's next update is worked out from its chapters; the backup's own
        // is kept while it is still ahead — from backups whose next updates come from the same schedule (version 3).
        let window = FetchInterval.window(today: MihonLocalDate(Date(), in: .current), timeZone: .current)
        // One write to `mangas` (each write would rebuild its id index for the next lookup).
        var scheduled = mangas
        let indexById = Dictionary(scheduled.indices.map { (scheduled[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in addedMangaIds {
            guard let index = indexById[id] else { continue }
            // Without chapters there is nothing to estimate from: no next update, so the next library update fetches it.
            guard let restoredChapters = chaptersByManga[id], !restoredChapters.isEmpty else {
                scheduled[index].nextUpdate = nil
                continue
            }
            let schedule = FetchInterval.update(for: scheduled[index], chapters: restoredChapters, window: window)
            let kept = payload.version >= 3 ? scheduled[index].nextUpdate.flatMap { $0 >= window.lowerBound ? $0 : nil } : nil
            scheduled[index].nextUpdate = kept ?? schedule.nextUpdate
            scheduled[index].fetchInterval = schedule.fetchInterval
        }
        if !addedMangaIds.isEmpty { mangas = scheduled }

        var history = historyEntries
        var historyIndex = Dictionary(history.indices.map { (history[$0].chapterId, $0) }, uniquingKeysWith: { first, _ in first })
        var nextHistoryId = (history.map(\.id).max() ?? 0) + 1
        for entry in payload.backupHistory {
            guard let chapterId = chapterIds[entry.chapterId], let mangaId = mangaIds[entry.mangaId] else { continue }
            if let index = historyIndex[chapterId] {
                history[index].readAt = max(history[index].readAt, entry.readAt)
                history[index].readDurationSeconds = max(history[index].readDurationSeconds, entry.readDurationSeconds)
            } else {
                historyIndex[chapterId] = history.count
                history.append(HistoryEntry(
                    id: nextHistoryId, chapterId: chapterId, mangaId: mangaId,
                    readAt: entry.readAt, readDurationSeconds: entry.readDurationSeconds
                ))
                nextHistoryId += 1
            }
        }
        historyEntries = history

        var tracks = tracksByManga
        var nextTrackId = (tracks.values.joined().map(\.id).max() ?? 0) + 1
        for track in payload.backupTracks {
            guard let mangaId = mangaIds[track.mangaId] else { continue }
            if let index = tracks[mangaId]?.firstIndex(where: { $0.trackerId == track.trackerId }) {
                tracks[mangaId]![index].lastChapterRead = max(tracks[mangaId]![index].lastChapterRead, track.lastChapterRead)
                continue
            }
            var restored = track
            restored.id = nextTrackId
            restored.mangaId = mangaId
            nextTrackId += 1
            tracks[mangaId, default: []].append(restored)
        }
        tracksByManga = tracks

        mergeExtensionRepos(payload.backupExtensionRepos)
        showStatusBanner("已恢复备份：书架新增 \(addedTitles) 部作品，新增 \(addedChapters) 个章节")
    }

    /// Replaces the library with a saved one, as the launch does with the previous session's snapshot (tests use
    /// it to set a library up).
    func replaceLibrary(with data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        libraryGeneration &+= 1
        pageListGeneration &+= 1
        pageListCache.removeAll()
        apply(try decoder.decode(MihonBackupPayload.self, from: data))
    }

    /// A backup only adds extension repos, like upstream's `ExtensionRepoRestorer`: it never changes the signing key
    /// of one already known.
    private func mergeExtensionRepos(_ repos: [ExtensionRepo]) {
        for repo in repos {
            let url = MihonNetworkClient.cleanRepoBaseUrl(repo.baseUrl)
            let key = APKSignatureVerification.normalize(repo.signingKeyFingerprint)
            let known = extensionRepos.contains { existing in
                MihonNetworkClient.cleanRepoBaseUrl(existing.baseUrl) == url
                    || (!key.isEmpty && APKSignatureVerification.normalize(existing.signingKeyFingerprint) == key)
            }
            if !known { extensionRepos.append(repo) }
        }
    }

    /// Bump when a build adds seed titles (tag them in `MihonSeedData.seedVersion(of:)`) or changes saved entries:
    /// a library saved by an earlier build is upgraded once. Version 2 (TestFlight build 6) added the MangaDex
    /// shelf, 3 the 再漫画 and 咚漫 shelves, 4 moved chapter sorting to upstream's default, 5 gave 咚漫 titles one
    /// URL form, 6 let MangaDex titles finished in the original keep updating; libraries without a version come
    /// from builds 1–5.
    private static let librarySeedVersion = 8
    private static let librarySeedVersionKey = "MihonLibrarySeedVersion"

    /// Whether a title saved by builds 1–5 holds real data. Those builds had an engine for MangaDex only — in every
    /// language, also ones this build's catalogue lacks — and generated the titles of every other source (the
    /// local source included), now real ones such as 再漫画 too.
    static func wasRealBeforeVersion2(_ manga: Manga) -> Bool {
        if let descriptor = MihonSeedData.extensions.lazy.flatMap(\.sources).first(where: { $0.id == manga.source }) {
            return MangaDexLiveEngine.handles(baseUrl: descriptor.baseUrl)
        }
        // A source from an installed extension: MangaDex titles are `/manga/<uuid>`, generated ones never are.
        return manga.source != 0
            && manga.url.wholeMatch(of: #/\/manga\/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/#) != nil
    }

    /// One-time upgrade of a library saved by an earlier build. Builds 1–5 served every source but MangaDex with
    /// generated demo data, so builds without demo features drop those entries once; nothing else ever drops
    /// entries, so a title from a source this build lacks survives (like an uninstalled extension in Mihon).
    func migrateRestoredLibrary(fromSeedVersion saved: Int, seeded: [Manga], seededCategories: [Int64: [Int64]]) {
        guard saved < Self.librarySeedVersion else { return }
        if saved < 2 && !showsDemoFeatures {
            removeEntries { !Self.wasRealBeforeVersion2($0) }
        }
        if saved < 4 {
            // Builds before version 4 sorted chapters by number by default, which sinks unnumbered episodes.
            for index in mangas.indices where mangas[index].chapterSortMode == .chapterNumber {
                mangas[index].chapterSortMode = .source
            }
        }
        if saved < 6 {
            // MangaDex "completed" describes the original: such titles were marked to fetch once and never got the
            // translated chapters still coming. Upstream calls them "publishing finished" and keeps updating.
            for index in mangas.indices where mangas[index].updateStrategy == .onlyFetchOnce
                && (sourceDescriptor(for: mangas[index].source).map { MangaDexLiveEngine.handles(baseUrl: $0.baseUrl) } ?? false) {
                mangas[index].updateStrategy = .alwaysUpdate
                if mangas[index].status == .completed { mangas[index].status = .publishingFinished }
            }
        }
        if saved < 8 {
            // Next updates worked out before upstream's release schedule (`FetchInterval`) can sit weeks ahead, which
            // 智能更新's "not expected yet" would trust (build 27, version 7, only cleared them). They are worked out
            // again from the chapters here: titles 智能更新 skips would otherwise never get one. Titles never fetched
            // keep none, so an update fetches them.
            for index in mangas.indices {
                mangas[index].nextUpdate = nil
                let chapters = chaptersByManga[mangas[index].id] ?? []
                guard !chapters.isEmpty else { continue }
                let schedule = FetchInterval.update(for: mangas[index], chapters: chapters)
                mangas[index].nextUpdate = schedule.nextUpdate
                mangas[index].fetchInterval = schedule.fetchInterval
            }
        }
        if saved < 5 {
            // 咚漫 titles saved under the schedule's URL form move to the canonical one (before the seed titles are
            // matched below). Lists and search find a title by URL, so of a title saved under both forms the library
            // entry gets the canonical URL; the other entry takes the old one and stays as it was.
            let dongman = mangas.indices.filter { mangas[$0].source == MihonSeedData.dongmanSourceId }
            let titles = Dictionary(grouping: dongman) { DongmanLiveEngine.canonicalTitleUrl(mangas[$0].url) }
            for (canonical, entries) in titles {
                guard let keeper = entries.first(where: { mangas[$0].favorite })
                    ?? entries.first(where: { mangas[$0].url == canonical }) ?? entries.first else { continue }
                if let holder = entries.first(where: { $0 != keeper && mangas[$0].url == canonical }) {
                    mangas[holder].url = mangas[keeper].url
                }
                mangas[keeper].url = canonical
            }
        }
        // Only entries added since: a title the user deleted after it was seeded stays deleted.
        addMissingSeedTitles(seeded.filter { MihonSeedData.seedVersion(of: $0.id) > saved }, categories: seededCategories)
    }

    /// Downloads saved for chapters the restored library lacks (the app quit before the library was saved) are
    /// deleted, and new chapter ids start past every id still referenced: a reused id would open another
    /// chapter's download or history.
    private func forgetDownloadsOfMissingChapters() {
        let known = Set(chaptersByManga.values.joined().map(\.id))
        for chapterId in downloadedChapterIds where !known.contains(chapterId) {
            removeChapterDownload(chapterId: chapterId)
        }
        let referenced = [downloadedChapterIds.max(), historyEntries.map(\.chapterId).max()].compactMap { $0 }
        nextChapterId = max(nextChapterId, (referenced.max() ?? 0) + 1)
    }

    /// Drops library entries together with their chapters, history, tracks and category links.
    private func removeEntries(where shouldRemove: (Manga) -> Bool) {
        let removed = Set(mangas.filter(shouldRemove).map(\.id))
        guard !removed.isEmpty else { return }
        mangas.removeAll { removed.contains($0.id) }
        chaptersByManga = chaptersByManga.filter { !removed.contains($0.key) }
        mangaCategories = mangaCategories.filter { !removed.contains($0.key) }
        historyEntries.removeAll { removed.contains($0.mangaId) }
        tracksByManga = tracksByManga.filter { !removed.contains($0.key) }
    }

    /// Appends the seed titles the restored library lacks (matched by source and URL) under fresh ids.
    private func addMissingSeedTitles(_ seeded: [Manga], categories seededCategories: [Int64: [Int64]]) {
        let present = Set(mangas.map { "\($0.source)|\($0.url)" })
        let knownCategories = Set(categories.map(\.id))
        var nextId = (mangas.map(\.id).max() ?? 200) + 1
        var added: [Manga] = []
        for var manga in seeded where !present.contains("\(manga.source)|\(manga.url)") {
            if let ids = seededCategories[manga.id]?.filter(knownCategories.contains), !ids.isEmpty {
                mangaCategories[nextId] = ids
            }
            manga.id = nextId
            nextId += 1
            added.append(manga)
        }
        mangas += added
    }

    /// Replaces the library with a saved one (the snapshot of the previous launch), entries from sources this build
    /// lacks included.
    private func apply(_ payload: MihonBackupPayload) {
        mangas = payload.backupManga
        categories = payload.backupCategories
        mangaCategories = payload.mangaCategoriesMap
        historyEntries = payload.backupHistory
        extensionRepos = payload.backupExtensionRepos
        chaptersByManga = Dictionary(grouping: payload.backupChapters, by: \.mangaId)
        nextChapterId = max(nextChapterId, (payload.backupChapters.map(\.id).max() ?? 0) + 1)
        tracksByManga = Dictionary(grouping: payload.backupTracks, by: \.mangaId)
    }

    // MARK: - Statistics Computation

    public func computeStatistics() -> LibraryStatistics {
        let favs = mangas.filter { $0.favorite }
        let completedCount = favs.filter { $0.status == .completed }.count
        let localCount = favs.filter { $0.source == 0 }.count

        var totalChapCount = 0
        var readChapCount = 0
        var dlChapCount = 0
        var startedCount = 0

        for m in favs {
            let chaps = chaptersByManga[m.id] ?? []
            totalChapCount += chaps.count
            let readInManga = chaps.filter(\.read).count
            readChapCount += readInManga
            dlChapCount += chaps.filter { downloadedChapterIds.contains($0.id) }.count
            if readInManga > 0 {
                startedCount += 1
            }
        }

        let allTracks = favs.flatMap { tracksByManga[$0.id] ?? [] }
        let trackedMangaCount = favs.filter { !(tracksByManga[$0.id] ?? []).isEmpty }.count
        let nonZeroScores = allTracks.map(\.score).filter { $0 > 0 }
        let meanScore = nonZeroScores.isEmpty ? 0.0 : (nonZeroScores.reduce(0, +) / Double(nonZeroScores.count))
        let totalDuration = historyEntries.map(\.readDurationSeconds).reduce(0, +)

        return LibraryStatistics(
            inLibraryCount: favs.count,
            completedMangaCount: completedCount,
            startedMangaCount: startedCount,
            localMangaCount: localCount,
            totalChaptersCount: totalChapCount,
            readChaptersCount: readChapCount,
            downloadedChaptersCount: dlChapCount,
            trackedMangaCount: trackedMangaCount,
            meanTrackerScore: meanScore,
            trackerCount: trackers.filter(\.isLoggedIn).count,
            totalReadDurationSeconds: totalDuration
        )
    }

    public func showStatusBanner(_ message: String) {
        statusBannerMessage = message
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, let self, self.statusBannerMessage == message else { return }
            self.statusBannerMessage = nil
        }
    }
}

// MARK: - Language display names (1:1 with upstream `LocaleHelper.getSourceDisplayName`)

public enum MihonLanguage {
    public static func displayName(_ lang: String) -> String {
        switch lang {
        case "all": return "多语言"
        case "other": return "其他"
        case "": return ""
        default:
            let identifier = lang.replacingOccurrences(of: "_", with: "-")
            let locale = Locale(identifier: identifier)
            let name = locale.localizedString(forIdentifier: identifier) ?? lang
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// A chapter whose source returned no pages (upstream's "No pages found"): a locked episode, an error page.
public enum ChapterPagesError: Error, LocalizedError {
    case noPages
    /// Upstream's "Source not installed": a title from a source this build has no engine for.
    case sourceNotInstalled

    public var errorDescription: String? {
        switch self {
        case .noPages: return "未找到页面"
        case .sourceNotInstalled: return "图源未安装"
        }
    }
}

/// Why an extension package was refused at install time (besides `APKSignatureError`).
enum ExtensionTrustError: Error, LocalizedError {
    case untrustedSigner
    case signerChanged

    var errorDescription: String? {
        switch self {
        case .untrustedSigner: return "签名不是插件仓库的密钥"
        case .signerChanged: return "签名与已安装的版本不同"
        }
    }
}
