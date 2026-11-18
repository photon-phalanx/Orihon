import XCTest
import SwiftUI
import AppKit
import OSLog
@testable import MihonDomain
@testable import MihonData
@testable import MihonPresentation

/// Self-test for SwiftUI runtime issues (AttributeGraph cycles, state mutated during view updates,
/// NavigationStack paths written several times per frame, …). These never crash or fail a build —
/// they only appear in the unified log — so the suite replays real user input and reads the log back.
///
/// The detector and the driver each have their own self-check, so a silent harness can never pass
/// the scenario vacuously. Set `MIHON_SKIP_UI_SELFTEST=1` to skip the (≈1 min) interactive scenario.
@MainActor
final class MihonRuntimeSelfTests: XCTestCase {

    // MARK: 1. Detector self-checks

    /// The log reader: a fault written through `Logger` must come back from `OSLogStore`.
    func testRuntimeGuardReadsOwnProcessLog() async throws {
        let checkpoint = MihonRuntimeGuard.checkpoint()
        Logger(subsystem: "com.apple.SwiftUI", category: "SelfTest").fault("Modifying state during view update (self-test probe)")
        try await Task.sleep(nanoseconds: 300_000_000)
        let issues = MihonRuntimeGuard.issues(after: checkpoint)
        XCTAssertTrue(issues.contains { $0.message.contains("self-test probe") }, "OSLogStore did not return this process' entries: \(issues)")
    }

    private struct StateMutatingDuringBody: View {
        @State private var counter = 0
        var body: some View {
            // Deliberate bug: SwiftUI logs "Modifying state during view update".
            let _ = { counter += 1 }()
            Text("canary \(counter)")
        }
    }

    /// Canary: a real SwiftUI misuse rendered by the driver must be reported.
    func testRuntimeGuardDetectsInjectedSwiftUIFault() async throws {
        let checkpoint = MihonRuntimeGuard.checkpoint()
        let driver = MihonUIDriver(StateMutatingDuringBody(), size: CGSize(width: 200, height: 80))
        defer { driver.close() }
        await driver.idle(1.0)
        let issues = MihonRuntimeGuard.issues(after: checkpoint)
        XCTAssertTrue(issues.contains { $0.message.contains("Modifying state during view update") }, "\(issues)")
    }

    // MARK: 2. Driver self-check

    private final class Counter: ObservableObject { @Published var taps = 0 }

    private struct DriverProbe: View {
        @ObservedObject var counter: Counter
        var body: some View {
            VStack(spacing: 20) {
                Text("点击次数 \(counter.taps)")
                Button("自测按钮") { counter.taps += 1 }
                    .mihonTestAnchor("probe.button")
                Text("自测文本")
                    .padding()
                    .onTapGesture { counter.taps += 10 }
                    .mihonTestAnchor("probe.text")
            }
            .frame(width: 300, height: 200)
        }
    }

    func testDriverFindsAndClicksElements() async throws {
        let counter = Counter()
        let driver = MihonUIDriver(DriverProbe(counter: counter), size: CGSize(width: 300, height: 200))
        defer { driver.close() }
        await driver.idle(0.5)
        XCTAssertNotNil(driver.anchor("probe.button"), "anchors must resolve to window coordinates")
        let clickedButton = await driver.tap("probe.button")
        let clickedText = await driver.tap("probe.text")
        await driver.idle(0.3)
        XCTAssertTrue(clickedButton && clickedText)
        XCTAssertEqual(counter.taps, 11, "synthesized NSEvents must reach Button actions and tap gestures")
    }

    // MARK: 3. Launch & posture changes driven by the window size (default `autoDetect` posture)

    /// A launching window is first laid out narrow (folded single screen) and then at its restored size
    /// (unfolded book), so posture flips within the first frames — exactly when the app starts up.
    func testLaunchAndWindowResizeHaveNoSwiftUIRuntimeIssues() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.duoPostureMode = .autoDetect
        let recorder = MihonRuntimeIssueRecorder()
        let driver = MihonUIDriver(MihonRootView(store: store), size: CGSize(width: 393, height: 720))
        defer { driver.close() }
        recorder.driver = driver
        recorder.artifactsDirectory = ProcessInfo.processInfo.environment["MIHON_SELFTEST_ARTIFACTS"]

        await recorder.step("启动（窄窗口 → 恢复为宽窗口）") {
            await driver.idle(0.05)
            await driver.resize(to: CGSize(width: 960, height: 860), settle: 1.0)
            return driver.hasAnchor("nav.浏览") && driver.hasAnchor(prefix: "chapter.")
        }
        await recorder.step("窗口变窄 → 折叠为单屏") {
            await driver.resize(to: CGSize(width: 393, height: 720), settle: 1.0)
            return !driver.hasAnchor(prefix: "chapter.")
        }
        await recorder.step("单屏打开详情") {
            guard await driver.tap("library.105", settle: 1.0) else { return false }
            return await driver.waitFor { driver.hasAnchor(prefix: "chapter.") }
        }
        await recorder.step("窗口变宽 → 详情移到右屏") {
            await driver.resize(to: CGSize(width: 960, height: 860), settle: 1.0)
            return driver.hasAnchor("nav.浏览") && driver.hasAnchor(prefix: "chapter.")
        }
        await recorder.step("切到「更多」后来回折叠") {
            guard await driver.tap("nav.更多", settle: 0.6) else { return false }
            await driver.resize(to: CGSize(width: 393, height: 720), settle: 0.8)
            await driver.resize(to: CGSize(width: 960, height: 860), settle: 0.8)
            return driver.hasAnchor("pref.设置")
        }
        print("🔎 launch self-test: failed postconditions: \(recorder.missingElements)\n\(recorder.report)")
        XCTAssertTrue(recorder.missingElements.isEmpty, "steps whose postcondition failed: \(recorder.missingElements)")
        XCTAssertTrue(recorder.findings.isEmpty, "SwiftUI runtime issues detected:\n\(recorder.report)")
    }

    // MARK: 3b. Tester build — demo features hidden

    /// `showsDemoFeatures: false` (the TestFlight configuration): only MangaDex content, no extensions / migration
    /// tabs, no local source, no tracking.
    func testTesterBuildHidesDemoFeatures() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.duoPostureMode = .foldedSingle
        let recorder = MihonRuntimeIssueRecorder()
        let driver = MihonUIDriver(MihonRootView(store: store), size: CGSize(width: 393, height: 720))
        defer { driver.close() }
        recorder.driver = driver
        recorder.artifactsDirectory = ProcessInfo.processInfo.environment["MIHON_SELFTEST_ARTIFACTS"]
        let liveIds = Set(store.mangas.map(\.id))

        await recorder.step("书架只有 MangaDex 作品") {
            await driver.idle(0.6)
            let shown = driver.anchors(withPrefix: "library.").compactMap { Int64($0.dropFirst("library.".count)) }
            return !shown.isEmpty && Set(shown).isSubset(of: liveIds)
        }
        await recorder.step("详情：没有进度记录按钮") {
            guard let first = driver.anchors(withPrefix: "library.").first, await driver.tap(first, settle: 1.0),
                  await driver.waitFor({ driver.hasAnchor("action.tag") }) else { return false }
            let noTracking = !driver.hasAnchor("action.arrow.triangle.2.circlepath")
            // Pushed screens hide the navigation bar; go back to the library.
            guard await driver.tap("icon.返回", settle: 0.8) else { return false }
            return noTracking && driver.hasAnchor("nav.浏览")
        }
        await recorder.step("浏览：显示可用图源和图源管理入口") {
            guard await driver.tap("nav.浏览", settle: 0.8) else { return false }
            let sources = driver.anchors(withPrefix: "source.").filter { !$0.hasPrefix("source.latest.") }
            let liveSources = store.activeCatalogueSources().filter(\.isLive) + [store.localCatalogueSource]
            let liveAnchors = Set(liveSources.map { "source.\($0.name).\($0.lang)" })
            let live = !sources.isEmpty && Set(sources).isSubset(of: liveAnchors)
            // 图源 and 迁移, never the demo extensions.
            return !driver.hasAnchor("tab.插件") && driver.hasAnchor("tab.迁移") && live
                && driver.hasAnchor("icon.管理图源") && sources.contains("source.包子漫画.zh")
        }
        await recorder.step("浏览：本地图源可导入并返回") {
            // Listed last, under "其他".
            await driver.scrollContent(at: CGPoint(x: 196, y: 400), by: 1600, steps: 20)
            guard await driver.waitFor({ driver.hasAnchor("source.本地图源.other") }),
                  await driver.tap("source.本地图源.other", settle: 1.0),
                  await driver.waitFor({ driver.hasAnchor("local.import") }),
                  await driver.tap("icon.返回", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("icon.全局搜索") }
        }
        await recorder.step("浏览：迁移页打开迁移搜索并返回") {
            guard await driver.tap("tab.迁移", settle: 0.8),
                  await driver.waitFor({ driver.hasAnchor(prefix: "migrate.") }),
                  let first = driver.anchors(withPrefix: "migrate.").first,
                  await driver.tap(first, settle: 1.0),
                  await driver.waitFor({ driver.hasAnchor("chip.只显示有结果的图源") }),
                  await driver.tap("icon.返回", settle: 0.8),
                  await driver.tap("tab.图源", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("icon.全局搜索") }
        }
        await recorder.step("浏览：全局搜索打开并返回") {
            guard await driver.tap("icon.全局搜索", settle: 0.8),
                  await driver.waitFor({ driver.hasAnchor("chip.只显示有结果的图源") }),
                  await driver.tap("icon.返回", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("icon.全局搜索") }
        }
        await recorder.step("设置：没有进度记录与插件仓库") {
            guard await driver.tap("nav.更多", settle: 0.6), await driver.tap("pref.设置", settle: 0.8) else { return false }
            guard driver.hasAnchor("pref.浏览"), !driver.hasAnchor("pref.进度记录") else { return false }
            guard await driver.tap("pref.浏览", settle: 0.8) else { return false }
            return driver.hasAnchor("pref.显示 18+ 图源") && !driver.hasAnchor("pref.插件仓库")
        }
        await recorder.step("设置：隐私有应用锁与安全屏幕") {
            guard await driver.tap("icon.返回", settle: 0.8), await driver.tap("pref.隐私", settle: 0.8) else { return false }
            // 闲置时锁定 only shows once the lock is on (which takes Face ID).
            return driver.hasAnchor("pref.需要解锁") && driver.hasAnchor("chip.无痕模式") && !driver.hasAnchor("chip.1 分钟后")
        }
        await recorder.step("更新：日历打开即将推出，点日期跳到当天，翻月并返回") {
            // Titles due today and on a later day of this month, so the list, headings and a day's scroll run too.
            let today = MihonLocalDate(Date(), in: .current)
            let later = today.plusDays(2).month == today.month ? today.plusDays(2) : today
            for (offset, index) in store.mangas.indices.filter({ store.mangas[$0].favorite }).prefix(3).enumerated() {
                store.mangas[index].status = .ongoing
                store.mangas[index].nextUpdate = (offset == 2 ? later : today).startOfDay(in: .current)
            }
            // Back to 更多 (pushed pages hide the navigation bar), then to 更新.
            guard await driver.tap("icon.返回", settle: 0.8), await driver.tap("icon.返回", settle: 0.8),
                  await driver.tap("nav.更新", settle: 0.8), await driver.tap("icon.显示即将推出的更新", settle: 1.0),
                  await driver.waitFor({ driver.hasAnchor("upcoming.screen") && driver.hasAnchor("upcoming.day.\(today)") }),
                  // Months first: tapping a day may scroll the calendar away.
                  await driver.tap("icon.下个月", settle: 0.6), await driver.tap("icon.上个月", settle: 0.6),
                  await driver.tap("upcoming.calendar.\(later)", settle: 0.8),
                  await driver.waitFor({ driver.hasAnchor("upcoming.day.\(later)") }),
                  await driver.tap("icon.返回", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("icon.显示即将推出的更新") }
        }
        await recorder.step("设置：书架的更新分类（包含 / 排除）保存") {
            guard await driver.tap("nav.更多", settle: 0.8), await driver.tap("pref.设置", settle: 0.8),
                  await driver.tap("pref.书架", settle: 0.8),
                  await driver.tap("settings.updateCategories", settle: 1.0) else { return false }
            // The sheet slides in: a tap before it settles lands where the row was.
            guard await driver.waitFor({ driver.hasAnchor("updateCategories.默认") }) else { return false }
            await driver.idle(0.8)
            guard await driver.tap("updateCategories.默认", settle: 0.4),
                  await driver.tap("updateCategories.save", settle: 1.0) else { return false }
            return await driver.waitFor { store.libraryUpdateIncludedCategories == [MangaCategory.defaultCategoryId] }
        }
        print("🔎 tester-build self-test: failed postconditions: \(recorder.missingElements)\n\(recorder.report)")
        XCTAssertTrue(recorder.missingElements.isEmpty, "steps whose postcondition failed: \(recorder.missingElements)")
        XCTAssertTrue(recorder.findings.isEmpty, "SwiftUI runtime issues detected:\n\(recorder.report)")
    }

    // MARK: 3c. Global search

    /// Every source is searched and gets its own row of results (demo sources only, so it runs offline).
    func testGlobalSearchListsEverySource() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.extensions.removeAll { ext in ext.sources.contains { MihonLiveSources.handles(baseUrl: $0.baseUrl) } }
        let sources = store.activeCatalogueSources()
        XCTAssertGreaterThanOrEqual(sources.count, 3)
        let recorder = MihonRuntimeIssueRecorder()
        let screen = GlobalSearchScreen(initialQuery: "冒险")
            .environment(store)
            .mihonTheme(store.themePalette, pureBlack: false)
        let driver = MihonUIDriver(screen, size: CGSize(width: 393, height: 1600))
        defer { driver.close() }
        recorder.driver = driver

        await recorder.step("每个图源一行结果") {
            await driver.waitFor(timeout: 5) {
                driver.anchors(withPrefix: "globalSearch.results.").count >= 3
            }
        }
        await recorder.step("只显示有结果的图源") {
            guard await driver.tap("chip.只显示有结果的图源", settle: 0.6) else { return false }
            return driver.anchors(withPrefix: "globalSearch.results.").count >= 3
        }
        print("🔎 global-search self-test: failed postconditions: \(recorder.missingElements)\n\(recorder.report)")
        XCTAssertTrue(recorder.missingElements.isEmpty, "steps whose postcondition failed: \(recorder.missingElements)")
        XCTAssertTrue(recorder.findings.isEmpty, "SwiftUI runtime issues detected:\n\(recorder.report)")
    }

    // MARK: 4. Interactive scenario — real clicks / long presses / scrolls / keys on the real app

    func testInteractiveScenarioHasNoSwiftUIRuntimeIssues() async throws {
        if ProcessInfo.processInfo.environment["MIHON_SKIP_UI_SELFTEST"] != nil {
            throw XCTSkip("MIHON_SKIP_UI_SELFTEST set")
        }
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.duoPostureMode = .unfoldedBook
        store.libraryDisplayMode = .comfortableGrid
        let size = CGSize(width: 960, height: 860)
        let recorder = MihonRuntimeIssueRecorder()
        let driver = MihonUIDriver(MihonRootView(store: store), size: size)
        defer { driver.close() }
        let artifacts = ProcessInfo.processInfo.environment["MIHON_SELFTEST_ARTIFACTS"]
        recorder.driver = driver
        recorder.artifactsDirectory = artifacts
        let detailCenter = CGPoint(x: size.width * 0.75, y: size.height * 0.5)
        func topChapterAnchor(_ mangaId: Int64) -> String? {
            guard let manga = store.manga(id: mangaId) else { return nil }
            return store.filteredAndSortedChapters(for: manga).first.map { "chapter.\($0.id)" }
        }

        await recorder.step("启动并空闲") { await driver.idle(2.0); return true }

        // Library (left screen) → live detail (right screen). Postcondition: the right pane shows that title.
        for (id, title) in [(103 as Int64, "尖帽子的魔法工坊"), (105, "镖人"), (104, "胆大党")] {
            await recorder.step("书架点选「\(title)」") {
                guard await driver.tap("library.\(id)", settle: 0.6), let anchor = topChapterAnchor(id) else { return false }
                return await driver.waitFor { driver.hasAnchor(anchor) }
            }
        }
        // Postcondition: the pager shows that category's page (a title only that page contains is visible).
        for (category, marker) in [("经典必看", 102 as Int64), ("条漫/韩漫", 105), ("追更连载", 104)] {
            await recorder.step("切换分类「\(category)」") {
                guard await driver.tap("tab.\(category)", settle: 0.8) else { return false }
                return await driver.waitFor {
                    let visible = driver.anchors(withPrefix: "library.")
                    return marker == 105 ? visible == ["library.105"] : visible.contains("library.\(marker)")
                }
            }
        }
        await recorder.step("右屏详情向下滚动") {
            guard await driver.scrollContent(at: detailCenter, by: 900) else { return false }
            return await driver.waitFor { !driver.hasAnchor("detail.description") }
        }
        await recorder.step("右屏详情向上滚动") {
            guard await driver.scrollContent(at: detailCenter, by: -900) else { return false }
            return await driver.waitFor { driver.hasAnchor("detail.description") }
        }
        // Expanding reflows the header (full text, wrapped tag chips), pushing the chapter list down.
        await recorder.step("展开简介") {
            guard let chapter = topChapterAnchor(104), let before = MihonTestAnchorRegistry.shared.frame(chapter)?.minY,
                  await driver.tap("detail.description") else { return false }
            return await driver.waitFor { (MihonTestAnchorRegistry.shared.frame(chapter)?.minY ?? 0) > before + 10 }
        }
        await recorder.step("长按进入多选") {
            guard await driver.longPress(anchor: "library.103") else { return false }
            return await driver.waitFor { driver.hasAnchor("action.标记为已读") }
        }
        await recorder.step("多选中再选一项") { await driver.tap("library.105") }
        await recorder.step("多选「标记为已读」后退出") {
            guard await driver.tap("action.标记为已读") else { return false }
            return await driver.waitFor { !driver.hasAnchor("action.标记为已读") }
        }
        await recorder.step("长按章节进入章节多选") {
            guard let anchor = topChapterAnchor(104), await driver.longPress(anchor: anchor) else { return false }
            return await driver.waitFor { driver.hasAnchor("icon.全选") }
        }
        await recorder.step("章节全选后退出") {
            guard await driver.tap("icon.全选"), await driver.tap("icon.关闭") else { return false }
            return await driver.waitFor { !driver.hasAnchor("icon.全选") }
        }

        // Navigation rail through every destination. Postcondition: an element only that destination shows.
        for (tab, marker) in [("更新", "icon.刷新"), ("历史", "icon.删除"), ("浏览", "tab.图源"), ("更多", "pref.设置"), ("书架", "tab.追更连载")] {
            await recorder.step("导航「\(tab)」") {
                guard await driver.tap("nav.\(tab)", settle: 0.8) else { return false }
                return await driver.waitFor { driver.hasAnchor(marker) }
            }
        }

        // Browse: tabs, an offline source catalogue, open a title into the right screen, back.
        await recorder.step("浏览「插件」") {
            guard await driver.tap("nav.浏览", settle: 0.8), await driver.tap("tab.插件", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor(prefix: "extension.") }
        }
        await recorder.step("插件列表快速滚动") {
            await driver.scrollContent(at: CGPoint(x: size.width * 0.3, y: size.height * 0.6), by: 2400, steps: 40)
        }
        await recorder.step("浏览「迁移」→「图源」") {
            guard await driver.tap("tab.迁移", settle: 0.6), await driver.tap("tab.图源", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("source.包子漫画.zh") }
        }
        // Pinned and last-used sources are listed twice (their section and their language).
        await recorder.step("置顶图源「漫画DB」") {
            guard await driver.tap("icon.置顶漫画DB", settle: 0.8) else { return false }
            return await driver.waitFor { store.pinnedSourceIds.contains(1004) && driver.hasAnchor("icon.取消置顶漫画DB") }
        }
        await recorder.step("打开演示图源「漫画DB」") {
            guard await driver.tap("source.漫画DB.zh", settle: 1.2) else { return false }
            return await driver.waitFor { driver.hasAnchor("chip.最近更新") }
        }
        await recorder.step("图源切换「最近更新」") {
            guard await driver.tap("chip.最近更新", settle: 1.0) else { return false }
            return await driver.waitFor { driver.hasAnchor(prefix: "browse.", containing: "最新") }
        }
        await recorder.step("图源打开作品到右屏") {
            guard let id = driver.anchors(withPrefix: "browse.").first(where: { $0.contains("最新") }) else { return false }
            return await driver.tap(id, settle: 1.0)
        }
        // Adding a title asks for its categories first (upstream's default) and files it under the ones ticked.
        await recorder.step("加入书架：选择分类") {
            guard await driver.tap("action.heart", settle: 0.8) else { return false }
            return await driver.waitFor { !driver.anchors(withPrefix: "category.").isEmpty }
        }
        await recorder.step("勾选分类并确定") {
            // The sheet slides in: a tap before it settles lands where the row was.
            await driver.idle(0.8)
            guard let anchor = driver.anchors(withPrefix: "category.").first,
                  let category = store.categories.first(where: { "category.\($0.name)" == anchor }),
                  await driver.tap(anchor, settle: 0.4), await driver.tap("dialog.确定", settle: 0.8) else { return false }
            let filed = await driver.waitFor {
                driver.hasAnchor("action.heart.fill") && store.mangas.contains {
                    $0.favorite && $0.title.contains("最新") && store.mangaCategories[$0.id] == [category.id]
                }
            }
            if !filed {
                let added = store.mangas.filter { $0.favorite && $0.title.contains("最新") }
                print("🔎 category step: wanted \(category.id), got \(added.map { "\($0.title) → \(store.mangaCategories[$0.id] ?? [])" })")
            }
            return filed
        }
        await recorder.step("图源返回") {
            guard await driver.tap("icon.返回", settle: 0.8) else { return false }
            return await driver.waitFor { !driver.hasAnchor("chip.最近更新") }
        }

        // Settings round-trip incl. a theme change (re-themes every live view).
        await recorder.step("更多 → 设置 → 外观") {
            guard await driver.tap("nav.更多", settle: 0.8), await driver.tap("pref.设置", settle: 0.8), await driver.tap("pref.外观", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("theme.青苹果") }
        }
        await recorder.step("切换主题「青苹果」") { await driver.tap("theme.青苹果", settle: 0.8) }
        await recorder.step("设置返回 ×2") {
            guard await driver.tap("icon.返回", settle: 0.8), await driver.tap("icon.返回", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("pref.设置") }
        }
        // The browse steps left a catalogue title on the right screen; show a library title again.
        await recorder.step("回到书架并选中「胆大党」") {
            guard await driver.tap("nav.书架", settle: 0.8), await driver.tap("library.104", settle: 0.8),
                  let anchor = topChapterAnchor(104) else { return false }
            return await driver.waitFor { driver.hasAnchor(anchor) }
        }

        // Reader: FAB (开始 / 继续) → tap zones / keys → switch page-turn direction (左右 ↔ 上下 ↔ 条漫) → close.
        // Page turns are verified through the reading progress the reader writes back to the store.
        func readingProgress() -> [Int] {
            (store.chaptersByManga[104] ?? []).map { $0.lastPageRead * 2 + ($0.read ? 1 : 0) }
        }
        await recorder.step("打开阅读器") {
            guard let fab = driver.anchors(withPrefix: "fab.").first, await driver.tap(fab, settle: 1.5) else { return false }
            return await driver.waitFor { driver.activeWindow !== driver.window }
        }
        func readerTap(_ fx: CGFloat, _ fy: CGFloat, settle: TimeInterval = 0.6) async {
            guard let bounds = driver.activeWindow.contentView?.bounds else { return }
            await driver.click(at: CGPoint(x: bounds.width * fx, y: bounds.height * fy), settle: settle)
        }
        /// Shows or hides the reader menu (a tap on the page while the menu is up only hides it, like upstream).
        func setReaderMenu(_ visible: Bool) async -> Bool {
            if driver.hasAnchor("icon.阅读模式") == visible { return true }
            await readerTap(0.5, 0.5)
            return await driver.waitFor { driver.hasAnchor("icon.阅读模式") == visible }
        }
        await recorder.step("阅读器点按翻页 ×3") {
            guard await setReaderMenu(false) else { return false }
            let before = readingProgress()
            for _ in 0..<3 { await readerTap(0.12, 0.5) }
            return await driver.waitFor { readingProgress() != before }
        }
        await recorder.step("阅读器方向键翻页") {
            let before = readingProgress()
            await driver.key(124, characters: "\u{F703}")
            await driver.key(124, characters: "\u{F703}")
            return await driver.waitFor { readingProgress() != before }
        }
        for (mode, label) in [(ReadingMode.vertical, "上下翻页"), (.webtoon, "上下滚动条漫"), (.leftToRight, "左右翻页从左到右"), (.rightToLeft, "左右翻页从右到左")] {
            await recorder.step("切换阅读模式「\(label)」") {
                guard await setReaderMenu(true),
                      await driver.tap("icon.阅读模式", settle: 0.8),
                      await driver.waitFor({ driver.hasAnchor("readingMode.\(mode.rawValue)") }),
                      await driver.tap("readingMode.\(mode.rawValue)", settle: 1.0) else { return false }
                return await driver.waitFor { store.manga(id: 104)?.readingModeOverride == mode }
            }
            await recorder.step("「\(label)」翻页") {
                guard await setReaderMenu(false) else { return false }
                let before = readingProgress()
                if mode.isVerticalDirection {
                    await driver.key(125, characters: "\u{F701}")
                    await driver.key(125, characters: "\u{F701}")
                    if mode == .webtoon { _ = await driver.scrollContent(at: CGPoint(x: 480, y: 430), by: 1200) }
                } else {
                    await readerTap(0.12, 0.5)
                    await readerTap(0.12, 0.5)
                }
                return await driver.waitFor { readingProgress() != before }
            }
        }
        if let artifacts { driver.snapshot(to: "\(artifacts)/selftest_reader.png") }
        await recorder.step("阅读器返回") {
            guard await setReaderMenu(true), await driver.tap("icon.返回", settle: 1.0) else { return false }
            return await driver.waitFor { driver.activeWindow === driver.window }
        }

        // Fold the device and walk the single-screen stack.
        await recorder.step("折叠为单屏") {
            store.duoPostureMode = .foldedSingle
            await driver.idle(1.0)
            return driver.hasAnchor("library.105")
        }
        await recorder.step("单屏打开详情并返回") {
            guard await driver.tap("library.105", settle: 1.0), await driver.waitFor({ driver.hasAnchor("icon.返回") }),
                  await driver.tap("icon.返回", settle: 0.8) else { return false }
            return await driver.waitFor { !driver.hasAnchor("icon.返回") && driver.hasAnchor("library.105") }
        }
        await recorder.step("单屏切换「更新」→「书架」") {
            guard await driver.tap("nav.更新", settle: 0.8), await driver.waitFor({ driver.hasAnchor("icon.刷新") }),
                  await driver.tap("nav.书架", settle: 0.8) else { return false }
            return await driver.waitFor { driver.hasAnchor("tab.追更连载") }
        }
        await recorder.step("展开为双屏") {
            store.duoPostureMode = .unfoldedBook
            await driver.idle(1.0)
            return driver.hasAnchor("nav.浏览") && driver.hasAnchor("library.105")
        }
        if let artifacts { driver.snapshot(to: "\(artifacts)/selftest_final.png") }

        print("🔎 runtime self-test: \(recorder.executedSteps) steps, failed postconditions: \(recorder.missingElements)")
        print("🔎 runtime self-test report:\n\(recorder.report)")
        // A vacuous run (driver could not reach the UI) must not count as a pass.
        XCTAssertTrue(recorder.missingElements.isEmpty, "steps whose postcondition failed: \(recorder.missingElements)")
        XCTAssertTrue(recorder.findings.isEmpty, "SwiftUI runtime issues detected:\n\(recorder.report)")
    }
}
