import SwiftUI
import UniformTypeIdentifiers
import MihonDomain
import MihonAPKEngine
import MihonData

// MARK: - 1:1 Mihon Browse Tab (图源 | 插件 | 迁移)

public struct BrowseScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    @State private var tab: Int64
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var showLanguageSheet = false
    @State private var showWebSources = false
    @State private var showRepoSheet = false

    public init() {
        _tab = State(initialValue: 0)
    }

    init(initialTab: Int64) {
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                MihonSearchAppBar(query: $searchQuery, placeholder: tab == 1 ? "搜索插件…" : "搜索图源…", onClose: { isSearching = false })
            } else {
                MihonTopAppBar(title: "浏览") {
                    if tab == 0 {
                        MihonIconButton("plus", label: "管理图源") { showWebSources = true }
                    }
                    if tab != 2 {
                        // Sources: Mihon's global search across every source; extensions: filter the list.
                        MihonIconButton("magnifyingglass", label: tab == 0 ? "全局搜索" : "搜索") {
                            if tab == 0 {
                                navigator.push(.globalSearch(query: nil))
                            } else {
                                isSearching = true
                            }
                        }
                        .help(tab == 0 ? "全局搜索" : "搜索")
                        MihonIconButton(tab == 1 ? "globe" : "line.3.horizontal.decrease") { showLanguageSheet = true }
                            .help(tab == 1 ? "插件语言" : "筛选")
                    }
                    if tab == 1 {
                        Menu {
                            Button("插件仓库") { showRepoSheet = true }
                            Button("刷新插件列表") { Task { await store.syncExtensionsFromKeiyoushiRepo() } }
                        } label: {
                            Image(systemName: "ellipsis")
                                .rotationEffect(.degrees(90))
                                .font(.system(size: 18))
                                .foregroundStyle(colors.onSurfaceVariant)
                                .frame(width: 48, height: 48)
                                .contentShape(Rectangle())
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                    }
                }
            }

            // Without demo features the extensions tab is left out (its extensions would be demo data).
            if store.showsDemoFeatures {
                let updates = store.extensions.lazy.filter { $0.installState == .hasUpdate }.count
                MihonTabRow(
                    tabs: [
                        MihonTab(id: 0, title: "图源"),
                        MihonTab(id: 1, title: "插件", badgeCount: updates > 0 ? updates : nil),
                        MihonTab(id: 2, title: "迁移")
                    ],
                    selection: $tab
                )
            } else {
                MihonTabRow(tabs: [MihonTab(id: 0, title: "图源"), MihonTab(id: 2, title: "迁移")], selection: $tab)
            }

            Group {
                switch tab {
                case 0: SourcesTab(searchQuery: searchQuery)
                case 1: ExtensionsTab(searchQuery: searchQuery)
                default: MigrateTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(colors.background)
        .onChange(of: tab) { _, _ in
            searchQuery = ""
            isSearching = false
        }
        .sheet(isPresented: $showWebSources) { WebSourceSheet().environment(store) }
        .sheet(isPresented: $showLanguageSheet) {
            LanguageFilterSheet()
                .environment(store)
                .mihonSheetChrome(colors)
        }
        .sheet(isPresented: $showRepoSheet) {
            ExtensionRepoAndAPKConfigSheet()
                .environment(store)
                .mihonSheetChrome(colors)
        }
    }
}

// MARK: - Sources tab (1:1 with `SourcesScreen`: pinned · last used · language headers)

private struct SourcesTab: View {
    let searchQuery: String
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        // The local source lists under "其他" (its language), as upstream.
        let sources = (store.activeCatalogueSources() + [store.localCatalogueSource]).filter {
            searchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
        let sections = groupedSections(sources)

        if sources.isEmpty && !searchQuery.isEmpty {
            MihonEmptyScreen(message: "没有结果")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections, id: \.title) { section in
                        MihonListGroupHeader(section.title)
                            .padding(.top, 8)
                        ForEach(section.sources, id: \.id) { source in
                            SourceItemRow(source: source)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .task {
                let id = BikaWebsite.sourceId
                guard store.lastUsedSourceId == id || store.pinnedSourceIds.contains(id),
                      let engine = sources.first(where: { $0.id == id })?.liveEngine as? BikaWebsite else { return }
                _ = try? await engine.popularManga(page: 1)
            }
        }
    }

    private struct Section {
        let title: String
        let sources: [APKSynthesizedHttpSource]
    }

    private func groupedSections(_ sources: [APKSynthesizedHttpSource]) -> [Section] {
        var result: [Section] = []
        let pinned = sources.filter { store.pinnedSourceIds.contains($0.id) }
        if !pinned.isEmpty { result.append(Section(title: "已置顶", sources: pinned)) }
        if let lastId = store.lastUsedSourceId, let last = sources.first(where: { $0.id == lastId }) {
            result.append(Section(title: "最近使用", sources: [last]))
        }
        let byLang = Dictionary(grouping: sources) { $0.lang }
        let order = byLang.keys.sorted { MihonLanguageOrder.precedes($0, $1) }
        for lang in order {
            let items = byLang[lang, default: []].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result.append(Section(title: MihonLanguage.displayName(lang), sources: items))
        }
        return result
    }

}

private struct SourceItemRow: View {
    let source: APKSynthesizedHttpSource
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @State private var showsKomgaSettings = false

    var body: some View {
        let pinned = store.pinnedSourceIds.contains(source.id)
        HStack(spacing: 0) {
            MihonSourceIconView(
                iconUrl: store.extensionIconUrl(forSourceId: source.id),
                isLocal: source.id == MihonLocalSource.sourceId,
                size: 40
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(source.name)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(MihonLanguage.displayName(source.lang))
                        .font(MihonType.bodySmall)
                        .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
                        .lineLimit(1)
                    // Only builds with demo features list sources without a real engine.
                    if !source.isLive {
                        ExtensionPill(text: "演示数据", color: colors.onSurfaceVariant)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            if source.supportsLatest {
                Button("最近更新") { open(.latest) }
                    .buttonStyle(MihonButtonStyle(.text))
                    .mihonTestAnchor("source.latest.\(source.name).\(source.lang)")
            }
            // Upstream opens a source's preferences from its extension; tester builds have no extensions tab.
            if KomgaLiveEngine.handles(sourceId: source.id) {
                MihonIconButton("gearshape", label: "\(source.name)设置") { showsKomgaSettings = true }
            }
            MihonIconButton(
                pinned ? "pin.fill" : "pin",
                tint: pinned ? colors.primary : colors.onBackground.opacity(MihonAlpha.secondary),
                label: "\(pinned ? "取消置顶" : "置顶")\(source.name)"
            ) {
                store.togglePinnedSource(source.id)
            }
            .help(pinned ? "取消置顶" : "置顶")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .mihonClickable { open(.popular) }
        .mihonTestAnchor("source.\(source.name).\(source.lang)")
        .sheet(isPresented: $showsKomgaSettings) {
            KomgaSettingsSheet(sourceId: source.id) { showsKomgaSettings = false }
                .environment(store)
                .mihonSheetChrome(colors)
        }
    }

    private func open(_ listing: SourceListing) {
        store.markSourceUsed(source.id)
        navigator.push(.source(sourceId: source.id, listing: listing, query: nil))
    }
}

enum MihonLanguageOrder {
    /// Multi-language first, then the user's enabled languages (zh → en → ja), then display-name order.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ lang: String) -> Int {
            if lang == "all" { return 0 }
            if lang.hasPrefix("zh") { return 1 }
            if lang == "en" { return 2 }
            if lang == "ja" { return 3 }
            if lang == "other" { return 99 }
            return 10
        }
        let (l, r) = (rank(lhs), rank(rhs))
        if l != r { return l < r }
        return MihonLanguage.displayName(lhs).localizedStandardCompare(MihonLanguage.displayName(rhs)) == .orderedAscending
    }
}

// MARK: - Extensions tab (1:1 with `ExtensionsScreen`; List-backed for the 1,400+ entry catalogue)

/// Grouping 1,400 extensions is cheap but not free; memoize it against the inputs instead of redoing it per redraw.
private final class ExtensionListMemo {
    struct Model {
        var updates: [ExtensionModel] = []
        var installed: [ExtensionModel] = []
        var available: [(lang: String, items: [ExtensionModel])] = []
        var isEmpty: Bool { updates.isEmpty && installed.isEmpty && available.isEmpty }
    }

    private var key: String?
    private var cached = Model()

    @MainActor
    func model(store: MihonRepositoryStore, query: String) -> Model {
        let newKey = "\(store.sourcesRevision)|\(query)|\(store.enabledLanguages.sorted().joined(separator: ","))|\(store.showNsfwSources)"
        if newKey == key { return cached }
        key = newKey

        var model = Model()
        var availableByLang: [String: [ExtensionModel]] = [:]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in store.extensions where !ext.apkName.isEmpty {
            if !trimmed.isEmpty {
                let matches = ext.name.localizedCaseInsensitiveContains(trimmed)
                    || ext.pkgName.localizedCaseInsensitiveContains(trimmed)
                    || ext.sources.contains { $0.baseUrl.localizedCaseInsensitiveContains(trimmed) }
                if !matches { continue }
            }
            switch ext.installState {
            case .hasUpdate:
                model.updates.append(ext)
            case .installed:
                model.installed.append(ext)
            case .available, .downloadingApk, .parsingApk, .untrusted:
                if ext.isNsfw && !store.showNsfwSources { continue }
                guard store.isLanguageEnabled(ext.lang) || ext.sources.contains(where: { store.isLanguageEnabled($0.lang) && $0.lang != "all" }) else { continue }
                availableByLang[ext.lang, default: []].append(ext)
            }
        }
        let byName: (ExtensionModel, ExtensionModel) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        model.updates.sort(by: byName)
        model.installed.sort(by: byName)
        model.available = availableByLang.keys
            .sorted { MihonLanguageOrder.precedes($0, $1) }
            .map { ($0, availableByLang[$0, default: []].sorted(by: byName)) }
        cached = model
        return model
    }
}

private struct ExtensionsTab: View {
    let searchQuery: String
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var memo = ExtensionListMemo()

    var body: some View {
        let model = memo.model(store: store, query: searchQuery)
        if model.isEmpty {
            if store.isSyncingExtensionRepos {
                MihonLoadingScreen()
            } else {
                MihonEmptyScreen(message: searchQuery.isEmpty ? "没有插件" : "没有结果")
            }
        } else {
            List {
                if !model.updates.isEmpty {
                    headerRow("待更新") {
                        Button("全部更新") { Task { await store.updateAllExtensions() } }
                            .buttonStyle(MihonButtonStyle(.text))
                    }
                    ForEach(model.updates) { ext in row(ext) }
                }
                if !model.installed.isEmpty {
                    headerRow("已安装") { EmptyView() }
                    ForEach(model.installed) { ext in row(ext) }
                }
                ForEach(model.available, id: \.lang) { group in
                    headerRow(MihonLanguage.displayName(group.lang)) { EmptyView() }
                    ForEach(group.items) { ext in row(ext) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await store.syncExtensionsFromKeiyoushiRepo() }
        }
    }

    private func headerRow<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colors.onSurfaceVariant)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(minHeight: 40)
        .mihonListRow(colors)
    }

    private func row(_ ext: ExtensionModel) -> some View {
        ExtensionItemRow(ext: ext)
            .mihonListRow(colors)
    }
}

extension View {
    /// Removes `List` chrome so rows render edge-to-edge like Compose `LazyColumn` items.
    func mihonListRow(_ colors: MihonColorScheme) -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(colors.background)
    }
}

private struct ExtensionItemRow: View {
    let ext: ExtensionModel
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.openURL) private var openURL

    private var isWorking: Bool { ext.installState == .downloadingApk || ext.installState == .parsingApk }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if isWorking {
                    MihonCircularProgress(size: 48, lineWidth: 2)
                }
                MihonSourceIconView(iconUrl: ext.iconUrl, size: isWorking ? 32 : 48)
            }
            .frame(width: 48, height: 48)
            .animation(.spring(duration: 0.3), value: isWorking)

            VStack(alignment: .leading, spacing: 0) {
                Text(ext.name)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
                Text(store.repoName(for: ext.repoUrl))
                    .font(MihonType.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .lineLimit(1)
                HStack(spacing: MihonPadding.extraSmall) {
                    Text(facts)
                        .font(MihonType.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .lineLimit(1)
                    if let step = stepLabel {
                        ExtensionPill(text: step, color: colors.primary)
                    }
                    if ext.isNsfw {
                        ExtensionPill(text: "18+", color: colors.error)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, MihonPadding.medium)

            actions
        }
        .padding(.leading, MihonPadding.medium)
        .padding(.trailing, MihonPadding.small)
        .padding(.vertical, MihonPadding.small)
        .mihonClickable {
            navigator.push(.extensionDetails(pkgName: ext.pkgName))
        }
        .mihonTestAnchor("extension.\(ext.pkgName)")
    }

    private var facts: String {
        let installed = ext.installState == .installed || ext.installState == .hasUpdate
        let parts = [installed ? MihonLanguage.displayName(ext.lang) : nil, ext.versionName.isEmpty ? nil : ext.versionName].compactMap { $0 }
        return parts.joined(separator: " • ")
    }

    private var stepLabel: String? {
        switch ext.installState {
        case .downloadingApk: return "下载中"
        case .parsingApk: return "安装中"
        default: return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: MihonPadding.small) {
            if isWorking {
                MihonIconButton("xmark") {}
                    .disabled(true)
            } else {
                switch ext.installState {
                case .available, .untrusted:
                    if let home = ext.sources.first?.baseUrl, let url = URL(string: home), !home.isEmpty {
                        MihonIconButton("globe") { openURL(url) }
                            .help("在 WebView 中打开")
                    }
                    Button("安装") { Task { await store.inspectAndInstallExtensionApk(ext) } }
                        .buttonStyle(MihonButtonStyle(.text))
                case .hasUpdate:
                    MihonIconButton("gearshape") { navigator.push(.extensionDetails(pkgName: ext.pkgName)) }
                    Button("更新") { Task { await store.inspectAndInstallExtensionApk(ext) } }
                        .buttonStyle(MihonButtonStyle(.text))
                case .installed:
                    MihonIconButton("gearshape") { navigator.push(.extensionDetails(pkgName: ext.pkgName)) }
                        .help("设置")
                case .downloadingApk, .parsingApk:
                    EmptyView()
                }
            }
        }
    }
}

/// `ExtensionPill`
private struct ExtensionPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Migrate tab (1:1 with `MigrateSourceScreen` → manga list)

private struct MigrateTab: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    var body: some View {
        // Upstream leaves the local source out: its titles are the user's files.
        let favorites = store.mangas.filter { $0.favorite && $0.source != MihonLocalSource.sourceId }
        let grouped = Dictionary(grouping: favorites, by: \.source)
        let sourceIds = grouped.keys.sorted { store.sourceName(for: $0).localizedStandardCompare(store.sourceName(for: $1)) == .orderedAscending }

        if favorites.isEmpty {
            MihonEmptyScreen(message: "书架为空")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sourceIds, id: \.self) { sourceId in
                        HStack(spacing: 12) {
                            MihonSourceIconView(iconUrl: store.extensionIconUrl(forSourceId: sourceId), size: 32)
                            Text(store.sourceName(for: sourceId))
                                .font(MihonType.bodyMedium)
                                .foregroundStyle(colors.onSurface)
                            if !store.isLiveSource(sourceId) {
                                ExtensionPill(text: "未安装", color: colors.error)
                            }
                            Spacer()
                            MihonPill(text: "\(grouped[sourceId]?.count ?? 0)")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                        ForEach((grouped[sourceId] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { manga in
                            HStack(spacing: 0) {
                                MangaCoverView(title: manga.title, thumbnailUrl: store.coverUrl(for: manga))
                                    .aspectRatio(2 / 3, contentMode: .fit)
                                    .frame(height: 48)
                                Text(manga.title)
                                    .font(MihonType.bodyMedium)
                                    .foregroundStyle(colors.onSurface)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 16))
                                    .foregroundStyle(colors.onSurfaceVariant)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .mihonClickable { navigator.push(.migrateSearch(mangaId: manga.id)) }
                            .mihonTestAnchor("migrate.\(manga.id)")
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Language filter sheet (1:1 with `SourcesFilterScreen` / `ExtensionFilterScreen`)

private struct LanguageFilterSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        @Bindable var store = store
        let languages = Set(store.extensions.flatMap { [$0.lang] + $0.sources.map(\.lang) })
            .map { $0.split(separator: "-").first.map(String.init) ?? $0 }
        let unique = Array(Set(languages)).sorted { MihonLanguageOrder.precedes($0, $1) }
        VStack(spacing: 0) {
            MihonHeadingItem("语言")
                .padding(.top, 12)
            MihonSwitchPreference(title: "显示 18+ 图源与插件", isOn: $store.showNsfwSources)
            MihonDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(unique, id: \.self) { lang in
                        MihonCheckboxItem(MihonLanguage.displayName(lang), checked: store.enabledLanguages.contains(lang)) {
                            if store.enabledLanguages.contains(lang) {
                                store.enabledLanguages.remove(lang)
                            } else {
                                store.enabledLanguages.insert(lang)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(colors.surfaceContainerLow)
    }
}

// MARK: - Browse source screen (1:1 with `BrowseSourceScreen`: chips row + compact grid + infinite paging)

public struct BrowseSourceScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public let sourceId: Int64
    @State private var listing: SourceListing
    @State private var query: String
    @State private var isSearching = false
    @State private var items: [SManga] = []
    @State private var page = 0
    @State private var hasNextPage = true
    @State private var isLoading = false
    @State private var listingError: (any Error)?
    /// A later page that failed: the list stays and offers a retry instead of ending there.
    @State private var nextPageError: String?
    /// The search the listing shows; what is being typed only counts once submitted.
    @State private var searchedQuery = ""
    /// Covers warmed so far (see `warmCovers(after:)`).
    @State private var coversWarmedUpTo = 0
    @State private var showingSavedPage = false
    @State private var bikaFilter: BikaCatalogueFilter?
    @State private var showFilters = false
    @State private var loadGeneration = 0
    /// Local source: picking files, and the picked files waiting for a title.
    @State private var showImporter = false
    @State private var pendingImport: [URL]?
    @State private var importTitle = ""
    @State private var showsKomgaSettings = false

    private var isLocal: Bool { sourceId == MihonLocalSource.sourceId }

    public init(sourceId: Int64, listing: SourceListing, initialQuery: String? = nil) {
        self.sourceId = sourceId
        _listing = State(initialValue: listing)
        _query = State(initialValue: initialQuery ?? "")
        _searchedQuery = State(initialValue: initialQuery ?? "")
    }

    public var body: some View {
        let source = store.catalogueSource(for: sourceId)
        VStack(spacing: 0) {
            if isSearching {
                MihonSearchAppBar(query: $query, onClose: {
                    isSearching = false
                    if listing == .search && bikaFilter == nil { switchListing(.popular) }
                }, onSubmit: { switchListing(.search) })
            } else {
                MihonTopAppBar(
                    title: source?.name ?? "图源",
                    subtitle: source.map { MihonLanguage.displayName($0.lang) + ($0.isLive ? "" : " · 演示数据") },
                    navigation: .back { dismiss() }
                ) {
                    MihonIconButton("magnifyingglass") { isSearching = true }
                    if isLocal {
                        MihonIconButton("square.and.arrow.down", label: "导入") { showImporter = true }
                            .mihonTestAnchor("local.import")
                        // Upstream's local source shows its guide here instead of a WebView.
                        MihonIconButton("questionmark.circle", label: "本地图源指南") { openLocalSourceGuide() }
                    } else if sourceId == BikaWebsite.sourceId {
                        MihonIconButton("person.crop.circle", label: "哔咔账号") {
                            navigator.openBikaAccount(BikaWebsite.accountURL)
                        }
                    } else if let source {
                        Menu {
                            Button("在 WebView 中打开") {
                                if let url = URL(string: source.baseUrl) { openURL(url) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .rotationEffect(.degrees(90))
                                .font(.system(size: 18))
                                .foregroundStyle(colors.onSurfaceVariant)
                                .frame(width: 48, height: 48)
                                .contentShape(Rectangle())
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MihonPadding.small) {
                    MihonFilterChip(label: sourceId == BikaWebsite.sourceId ? "百合花园" : "热门", selected: listing == .popular) { switchListing(.popular) }
                    if source?.supportsLatest ?? true {
                        MihonFilterChip(label: "最近更新", selected: listing == .latest) { switchListing(.latest) }
                    }
                    MihonFilterChip(label: "筛选", selected: sourceId == BikaWebsite.sourceId ? bikaFilter != nil : listing == .search) { showFilters = true }
                    if showingSavedPage {
                        if isLoading {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("正在更新上次的书单")
                                .accessibilityIdentifier("bika.catalogue.refreshing")
                        } else if let nextPageError {
                            Button("上次书单 · 重试") {
                                self.nextPageError = nil
                                Task { await loadNextPage(source: source) }
                            }
                            .buttonStyle(MihonButtonStyle(.text))
                            .accessibilityHint(nextPageError)
                        }
                    }
                }
                .padding(.horizontal, MihonPadding.small)
                .padding(.vertical, MihonPadding.extraSmall)
            }
            .clipped()
            MihonDivider()

            content(source: source)
        }
        .background(colors.background)
        .task(id: "\(sourceId)|\(listing.rawValue)|\(loadGeneration)") {
            if items.isEmpty || showingSavedPage { await loadNextPage(source: source) }
        }
        .sheet(isPresented: $showFilters) {
            if let engine = source?.liveEngine as? BikaWebsite {
                BikaFilterSheet(engine: engine, applied: bikaFilter) { filter in
                    showFilters = false
                    isSearching = false
                    query = ""
                    bikaFilter = filter
                    listing = .search
                    reload()
                }
                .mihonSheetChrome(colors, detents: [.large])
            } else {
                SourceFilterSheet(source: source, query: $query) {
                    showFilters = false
                    switchListing(.search)
                }
                .environment(store)
                .mihonSheetChrome(colors)
            }
        }
        .onChange(of: navigator.bikaAccountRevision) { _, _ in
            if sourceId == BikaWebsite.sourceId {
                reload()
            }
        }
        .sheet(isPresented: $showsKomgaSettings, onDismiss: { reload() }) {
            KomgaSettingsSheet(sourceId: sourceId) { showsKomgaSettings = false }
                .environment(store)
                .mihonSheetChrome(colors)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let archives = urls.filter { MihonLocalSource.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard !archives.isEmpty else {
                runImport(urls, title: nil)
                return
            }
            Task {
                // Off the main thread: it opens the first archive for its ComicInfo.xml.
                importTitle = await Task.detached { MihonLocalStorage.suggestedTitle(for: archives) }.value
                pendingImport = urls
            }
        }
        .alert("导入到作品", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            TextField("作品名", text: $importTitle)
            Button("取消", role: .cancel) { pendingImport = nil }
            Button("导入") {
                if let urls = pendingImport { runImport(urls, title: importTitle) }
                pendingImport = nil
            }
        } message: {
            Text("ZIP / CBZ / EPUB 文件会成为这部作品的章节；选中的文件夹各自成为一部作品。")
        }
    }

    /// The system's own type for `.cbz` (declared by an app, else dynamic): one made here `conformingTo: .zip` is a
    /// different dynamic type that no file has.
    static let importTypes: [UTType] = [.folder, .zip, UTType(filenameExtension: "cbz") ?? .zip, .epub]

    private func runImport(_ urls: [URL], title: String?) {
        store.showStatusBanner("正在导入…")
        Task {
            await store.importLocalFiles(urls, intoTitle: title)
            reload()
        }
    }

    private func openLocalSourceGuide() {
        if let url = URL(string: MihonLocalSource.helpUrl) { openURL(url) }
    }

    /// Where to put files: the Files app shows the app's Documents folder (`UIFileSharingEnabled`).
    private var localSourceHint: String {
        #if os(iOS)
        "本地图源还没有漫画\n把漫画文件夹放进「文件」App 的\n我的 iPhone › Orihon › local\n或者导入文件夹、ZIP、CBZ、EPUB 文件"
        #else
        "本地图源还没有漫画\n把漫画文件夹放进\n\(MihonLocalStorage.defaultRootDirectory.path)\n或者导入文件夹、ZIP、CBZ、EPUB 文件"
        #endif
    }

    @ViewBuilder
    private func content(source: APKSynthesizedHttpSource?) -> some View {
        if source == nil {
            MihonEmptyScreen(message: "图源未安装")
        } else if items.isEmpty && isLoading {
            MihonLoadingScreen()
        } else if items.isEmpty, let listingError {
            MihonEmptyScreen(message: listingError.localizedDescription, actions: [
                (title: "重试", systemImage: "arrow.clockwise", action: { reload() })
            ] + ((listingError as? BikaReadError) == .login ? [
                (title: "登录哔咔账号", systemImage: "person.crop.circle", action: { navigator.openBikaAccount(BikaWebsite.loginURL) })
            ] : []) + (KomgaLiveEngine.handles(sourceId: sourceId) ? [
                (title: "设置", systemImage: "gearshape", action: { showsKomgaSettings = true })
            ] : []))
        } else if items.isEmpty && isLocal && listing == .popular && searchedQuery.isEmpty {
            MihonEmptyScreen(message: localSourceHint, actions: [
                (title: "导入", systemImage: "square.and.arrow.down", action: { showImporter = true }),
                (title: "本地图源指南", systemImage: "questionmark.circle", action: { openLocalSourceGuide() })
            ])
        } else if items.isEmpty {
            MihonEmptyScreen(message: "没有结果")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 4)], spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.url) { index, manga in
                        BrowseSourceGridItem(manga: manga, sourceId: sourceId)
                            .onAppear {
                                if index >= items.count - 6 {
                                    Task { await loadNextPage(source: source) }
                                }
                                warmCovers(after: index)
                            }
                    }
                }
                .padding(8)
                if let nextPageError, !showingSavedPage {
                    VStack(spacing: MihonPadding.small) {
                        Text(nextPageError)
                            .font(MihonType.bodyMedium)
                            .foregroundStyle(colors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            self.nextPageError = nil
                            Task { await loadNextPage(source: source) }
                        }
                        .buttonStyle(MihonButtonStyle(.text))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
                } else if !showingSavedPage && (isLoading || hasNextPage) {
                    MihonCircularProgress(size: 32, lineWidth: 3)
                        .padding(.vertical, 24)
                        .onAppear { Task { await loadNextPage(source: source) } }
                }
            }
            .accessibilityIdentifier("source.catalogue.results")
            .refreshable {
                if sourceId == BikaWebsite.sourceId { BikaWebsite.invalidateLiveListings() }
                reload()
            }
        }
    }

    private func switchListing(_ newListing: SourceListing) {
        bikaFilter = nil
        listing = newListing
        reload()
    }

    private func reload() {
        items = []
        showingSavedPage = false
        page = 0
        hasNextPage = true
        listingError = nil
        nextPageError = nil
        coversWarmedUpTo = 0
        searchedQuery = query
        isLoading = false
        loadGeneration += 1
    }

    /// Covers of the next couple of rows: warming a whole page instead would download every cover of 咚漫's
    /// 热门 listing, a single page of 1,300 titles.
    private func warmCovers(after index: Int) {
        let end = min(items.count, index + 13)
        let start = max(coversWarmedUpTo, index + 1)
        guard start < end else { return }
        coversWarmedUpTo = end
        MihonTwoTierImageCache.shared.prefetch(
            urls: items[start..<end].compactMap { MangaCoverView.resolveCoverUrl($0.thumbnailUrl) },
            target: .cover
        )
    }

    private func loadNextPage(source: APKSynthesizedHttpSource?) async {
        guard let source, !isLoading, hasNextPage, nextPageError == nil else { return }
        isLoading = true
        let generation = loadGeneration
        let nextPage = page + 1
        if nextPage == 1, !showingSavedPage, let engine = source.liveEngine as? BikaWebsite,
           let saved = await engine.savedLandingPage(for: listing) {
            guard generation == loadGeneration else { return }
            items = saved.mangas
            showingSavedPage = true
        }
        do {
            let result: MangasPage
            switch listing {
            case .popular: result = try await source.getPopularManga(page: nextPage)
            case .latest: result = try await source.getLatestUpdates(page: nextPage)
            case .search:
                if let bikaFilter, let engine = source.liveEngine as? BikaWebsite {
                    result = try await engine.filteredManga(page: nextPage, filter: bikaFilter)
                } else {
                    result = try await source.getSearchManga(page: nextPage, query: searchedQuery, filters: source.getFilterList())
                }
            }
            guard generation == loadGeneration else { return }
            if showingSavedPage {
                items = result.mangas
                showingSavedPage = false
                coversWarmedUpTo = 0
            } else {
                let known = Set(items.map(\.url))
                items.append(contentsOf: result.mangas.filter { !known.contains($0.url) })
            }
            page = nextPage
            hasNextPage = result.hasNextPage && !result.mangas.isEmpty
        } catch {
            guard generation == loadGeneration else { return }
            if sourceId == BikaWebsite.sourceId, (error as? BikaReadError) == .login {
                items = []
                showingSavedPage = false
                listingError = error
                hasNextPage = false
            } else if Task.isCancelled && showingSavedPage {
                loadGeneration += 1
            } else if showingSavedPage {
                nextPageError = "当前显示上次的书单。更新失败：\(error.localizedDescription)"
            } else if items.isEmpty {
                listingError = error
                hasNextPage = false
            } else {
                // Upstream keeps what loaded and offers a retry; the next page is not given up on.
                nextPageError = error.localizedDescription
            }
        }
        isLoading = false
    }
}

/// `BrowseSourceCompactGridItem` — favourites are dimmed to 34% with an "在书架中" badge.
struct BrowseSourceGridItem: View {
    let manga: SManga
    let sourceId: Int64
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    /// Long press (upstream `BrowseSourceScreen`): adding may ask for categories, removing asks to confirm.
    @State private var addingMangaId: Int64?
    @State private var removingMangaId: Int64?

    var body: some View {
        let existing = store.mangas.first { $0.url == manga.url && $0.source == sourceId }
        let inLibrary = existing?.favorite ?? false
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                MangaCoverView(title: manga.title, thumbnailUrl: existing.flatMap(store.coverUrl(for:)) ?? manga.thumbnailUrl)
                    .opacity(inLibrary ? 0.34 : 1)
            }
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(hex: 0x000000, alpha: 0xAA / 255.0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: geo.size.height * 0.33)
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: MihonShape.extraSmall, bottomTrailingRadius: MihonShape.extraSmall))
                        Text(manga.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineSpacing(3)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if inLibrary {
                    MihonBadgeGroup {
                        MihonBadge(text: "在书架中", color: colors.secondary, contentColor: colors.onSecondary)
                    }
                    .padding(4)
                }
            }
            .padding(4)
            .mihonClickable(
                cornerRadius: MihonShape.small,
                onLongClick: {
                    let saved = store.upsertCatalogMangaToStore(manga, sourceId: sourceId)
                    if saved.favorite {
                        removingMangaId = saved.id
                    } else if store.asksCategoriesOnAdd {
                        addingMangaId = saved.id
                    } else {
                        store.addToLibrary(mangaId: saved.id)
                    }
                },
                onClick: {
                    let saved = store.upsertCatalogMangaToStore(manga, sourceId: sourceId)
                    navigator.openManga(saved.id)
                }
            )
            .mihonTestAnchor("browse.\(manga.title)")
            .sheet(isPresented: Binding(get: { addingMangaId != nil }, set: { if !$0 { addingMangaId = nil } })) {
                if let id = addingMangaId {
                    ChangeCategorySheet(mangaIds: [id], addsToLibrary: true)
                        .environment(store)
                        .mihonSheetChrome(colors, detents: [.medium])
                }
            }
            .confirmationDialog(
                "从书架移除？",
                isPresented: Binding(get: { removingMangaId != nil }, set: { if !$0 { removingMangaId = nil } }),
                titleVisibility: .visible
            ) {
                Button("移除", role: .destructive) {
                    if let id = removingMangaId { store.removeFromLibrary(mangaId: id) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将「\(manga.title)」从书架中移除。")
            }
    }
}

/// `SourceFilterSheet` — search text + the APK-declared `FilterList`.
private struct SourceFilterSheet: View {
    let source: APKSynthesizedHttpSource?
    @Binding var query: String
    let onApply: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("重置") { query = "" }
                    .buttonStyle(MihonButtonStyle(.text))
                Spacer()
                Button("筛选") { onApply() }
                    .buttonStyle(MihonButtonStyle(.filled))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            MihonDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("", text: $query, prompt: Text("标题").foregroundStyle(colors.onSurfaceVariant))
                        .textFieldStyle(.plain)
                        .font(MihonType.bodyLarge)
                        .foregroundStyle(colors.onSurface)
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: MihonShape.extraSmall).strokeBorder(colors.outline, lineWidth: 1))
                        .padding(16)
                    ForEach(source?.getFilterList() ?? []) { filter in
                        switch filter {
                        case .header(let name):
                            MihonHeadingItem(name)
                        case .select(let name, let options, let index):
                            MihonPreferenceRow(title: name, subtitle: options[min(index, max(0, options.count - 1))])
                        case .sort(let name, let options, let index, _):
                            MihonPreferenceRow(title: name, subtitle: options[min(index, max(0, options.count - 1))])
                        case .triState(let name, _):
                            MihonTriStateItem(name, state: .constant(.disabled))
                        case .checkBox(let name, let state):
                            MihonCheckboxItem(name, checked: state) {}
                        case .text(let name, let value):
                            MihonPreferenceRow(title: name, subtitle: value)
                        case .separator:
                            MihonDivider()
                        }
                    }
                }
            }
        }
        .background(colors.surfaceContainerLow)
    }
}

// MARK: - Extension details (1:1 with `ExtensionDetailsScreen` + native APK/DEX inspector)

public struct ExtensionDetailsScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    public let pkgName: String

    public init(pkgName: String) { self.pkgName = pkgName }

    public var body: some View {
        VStack(spacing: 0) {
            MihonTopAppBar(title: "插件详情", navigation: .back { dismiss() })
            if let ext = store.extensions.first(where: { $0.pkgName == pkgName }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(ext)
                        MihonDivider().padding(.vertical, 8)
                        MihonPreferenceGroupHeader("图源")
                        ForEach(ext.sources) { source in
                            MihonPreferenceRow(
                                title: source.name,
                                subtitle: "\(MihonLanguage.displayName(source.lang)) · \(source.baseUrl)"
                            )
                        }
                        MihonPreferenceGroupHeader("APK 解析")
                        APKInspectionContent(extensionModel: ext)
                    }
                    .padding(.bottom, 24)
                }
            } else {
                MihonEmptyScreen(message: "插件不存在")
            }
        }
        .background(colors.background)
    }

    private func header(_ ext: ExtensionModel) -> some View {
        let installed = ext.installState == .installed || ext.installState == .hasUpdate
        return VStack(spacing: 16) {
            MihonSourceIconView(iconUrl: ext.iconUrl, size: 112)
                .padding(.top, 16)
            VStack(spacing: 4) {
                Text(ext.name)
                    .font(MihonType.headlineSmall)
                    .foregroundStyle(colors.onSurface)
                Text(ext.pkgName)
                    .font(MihonType.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .textSelection(.enabled)
            }
            HStack(spacing: 0) {
                infoItem(ext.versionName, "版本")
                infoItem(MihonLanguage.displayName(ext.lang), "语言")
                if ext.isNsfw {
                    infoItem("18+", "年龄分级", color: colors.error)
                }
                infoItem(String(format: "%.1f", ext.libVersion), "扩展库")
            }
            HStack(spacing: 16) {
                if installed {
                    Button("卸载") { store.uninstallExtension(ext); dismiss() }
                        .buttonStyle(MihonButtonStyle(.outlined))
                        .frame(maxWidth: .infinity)
                } else {
                    Button("安装") { Task { await store.inspectAndInstallExtensionApk(ext) } }
                        .buttonStyle(MihonButtonStyle(.filled))
                        .frame(maxWidth: .infinity)
                }
                if ext.installState == .hasUpdate {
                    Button("更新") { Task { await store.inspectAndInstallExtensionApk(ext) } }
                        .buttonStyle(MihonButtonStyle(.filled))
                        .frame(maxWidth: .infinity)
                } else if let home = ext.sources.first?.baseUrl, let url = URL(string: home), !home.isEmpty {
                    Button("在浏览器中打开") { openURL(url) }
                        .buttonStyle(MihonButtonStyle(.tonal))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func infoItem(_ value: String, _ label: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MihonType.titleSmall)
                .foregroundStyle(color ?? colors.onSurface)
                .lineLimit(1)
            Text(label)
                .font(MihonType.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Native Swift ZIP / binary AXML / DEX inspection results for an extension APK.
struct APKInspectionContent: View {
    let extensionModel: ExtensionModel
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var inspection: APKAndroidPackageInspection?
    @State private var section: Int64 = 0
    @State private var didStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MihonTabRow(
                tabs: [MihonTab(id: 0, title: "Manifest & DEX"), MihonTab(id: 1, title: "类与方法"), MihonTab(id: 2, title: "字符串常量池")],
                selection: $section
            )
            if let inspection = inspection ?? store.apkInspectionsByPkg[extensionModel.pkgName] {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case 0: manifestSection(inspection)
                    case 1: classesSection(inspection)
                    default: stringsSection(inspection)
                    }
                }
                .padding(.top, 8)
            } else {
                HStack(spacing: 12) {
                    MihonCircularProgress(size: 24, lineWidth: 3)
                    Text("正在下载并解析 APK…")
                        .font(MihonType.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            inspection = await store.inspectExtensionApk(for: extensionModel)
        }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(MihonType.bodyMedium)
                .foregroundStyle(colors.onSurfaceVariant)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(colors.onSurface)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func manifestSection(_ inspection: APKAndroidPackageInspection) -> some View {
        keyValue("Package", inspection.manifest.packageName)
        keyValue("Version", "\(inspection.manifest.versionName) (\(inspection.manifest.versionCode))")
        keyValue("Extension class", inspection.manifest.tachiyomiExtensionClass ?? "—")
        keyValue("NSFW", inspection.manifest.tachiyomiIsNsfw ? "1" : "0")
        keyValue("Target SDK", "API \(inspection.manifest.targetSdkVersion)")
        keyValue("Parser", inspection.provider)
        if let signature = inspection.signature {
            keyValue("Signature", "APK " + signature.schemes.map { "v\($0)" }.joined(separator: " + ") + " · 已验证")
            keyValue("Signer SHA-256", signature.certificateFingerprints.joined(separator: "\n"))
        } else {
            keyValue("Signature", "未验证")
        }
        ForEach(inspection.dexMetrics, id: \.dexFileName) { metric in
            MihonHeadingItem("\(metric.dexFileName) · dex \(metric.dexVersion) · \(metric.fileSize) B")
                .padding(.leading, -8)
            keyValue("string_ids", "\(metric.stringIdsCount)")
            keyValue("type_ids", "\(metric.typeIdsCount)")
            keyValue("proto_ids", "\(metric.protoIdsCount)")
            keyValue("field_ids", "\(metric.fieldIdsCount)")
            keyValue("method_ids", "\(metric.methodIdsCount)")
            keyValue("class_defs", "\(metric.classDefsCount)")
        }
    }

    @ViewBuilder
    private func classesSection(_ inspection: APKAndroidPackageInspection) -> some View {
        ForEach(inspection.discoveredClasses) { cls in
            VStack(alignment: .leading, spacing: 6) {
                Text(cls.className)
                    .font(MihonType.titleSmall)
                    .foregroundStyle(colors.onSurface)
                Text("extends \(cls.superclassDescriptor)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(colors.onSurfaceVariant)
                Text(cls.decompiledPseudocode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.onSurface)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(colors.surfaceContainerHighest))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func stringsSection(_ inspection: APKAndroidPackageInspection) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(inspection.extractedStringPool.prefix(600).enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// Stand-alone sheet form of the APK inspector (kept for snapshot tests & deep links).
public struct APKExtensionInspectorSheet: View {
    @Environment(\.mihonColors) private var colors
    public let extensionModel: ExtensionModel

    public init(extensionModel: ExtensionModel) {
        self.extensionModel = extensionModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            MihonTopAppBar(title: extensionModel.name, subtitle: extensionModel.pkgName)
            ScrollView {
                APKInspectionContent(extensionModel: extensionModel)
            }
        }
        .background(colors.background)
    }
}

// MARK: - Extension repositories (1:1 with `ExtensionReposScreen`)

public struct ExtensionRepoAndAPKConfigSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var newRepoUrl = ""

    public init() {}

    public var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            Text("插件仓库")
                .font(MihonType.titleLarge)
                .foregroundStyle(colors.onSurface)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.extensionRepos) { repo in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "tag")
                                .font(.system(size: 18))
                                .foregroundStyle(colors.onSurfaceVariant)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.name)
                                    .font(MihonType.bodyLarge)
                                    .foregroundStyle(colors.onSurface)
                                Text(repo.baseUrl)
                                    .font(MihonType.bodySmall)
                                    .foregroundStyle(colors.onSurfaceVariant)
                                    .lineLimit(2)
                                Text("签名指纹 \(repo.signingKeyFingerprint)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(colors.onSurfaceVariant)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            MihonIconButton("trash") { store.removeExtensionRepo(baseUrl: repo.baseUrl) }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                    TextField("", text: $newRepoUrl, prompt: Text("仓库地址（repo.json / index.min.json 所在目录）").foregroundStyle(colors.onSurfaceVariant))
                        .textFieldStyle(.plain)
                        .font(MihonType.bodyLarge)
                        .foregroundStyle(colors.onSurface)
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: MihonShape.extraSmall).strokeBorder(colors.outline, lineWidth: 1))
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    HStack {
                        Spacer()
                        Button("添加") {
                            store.addExtensionRepo(url: newRepoUrl, name: "")
                            newRepoUrl = ""
                        }
                        .buttonStyle(MihonButtonStyle(.filled))
                        .disabled(newRepoUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    MihonDivider().padding(.vertical, 8)
                    MihonSwitchPreference(
                        title: "端侧 APK / DEX 解析器",
                        subtitle: "安装时在本机解压 APK，解析 AndroidManifest 与 classes.dex",
                        isOn: $store.apkBridgeConfig.preferOnDeviceBinaryEngine
                    )
                }
            }
        }
        .background(colors.surfaceContainerLow)
    }
}
