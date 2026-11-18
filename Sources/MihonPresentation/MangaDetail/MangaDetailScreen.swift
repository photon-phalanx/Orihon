import SwiftUI
import MihonDomain
import MihonData

// MARK: - 1:1 Mihon Manga Screen (MangaInfoBox · MangaActionRow · ExpandableMangaDescription · ChapterHeader · chapters · FAB)

private struct DetailHeaderOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Per-frame scroll state lives in its own observable object: only the app bar and FAB read it, so scrolling
/// never re-evaluates the screen body (header + chapter list) and never feeds geometry back into its layout.
@Observable
final class MangaDetailScrollState {
    private(set) var headerOffset: CGFloat = 0
    private(set) var fabExpanded = true
    @ObservationIgnored private var lastOffset: CGFloat = 0

    /// 0 at the top → 1 once the header has scrolled away (app bar tint & title fade).
    var toolbarProgress: Double { min(1, max(0, -headerOffset / 160)) }

    func update(offset: CGFloat) {
        // Expand while at the top or scrolling up (1:1 with `shouldExpandFAB`).
        let delta = offset - lastOffset
        lastOffset = offset
        let atTop = offset > -24
        let expand = atTop || delta > 4 ? true : (delta < -4 ? false : fabExpanded)
        if expand != fabExpanded { fabExpanded = expand }
        let clamped = min(0, max(-240, offset))
        if abs(clamped - headerOffset) > 1 || (clamped != headerOffset && (clamped == 0 || clamped == -240)) {
            headerOffset = clamped
        }
    }
}

/// Re-renders only itself when the scroll state changes.
private struct ScrollStateReader<Content: View>: View {
    let state: MangaDetailScrollState
    @ViewBuilder let content: (MangaDetailScrollState) -> Content

    var body: some View { content(state) }
}

public struct MangaDetailScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public let mangaId: Int64

    @State private var website: WebsiteLocation?
    @State private var descriptionExpanded = false
    @State private var selection: Set<Int64> = []
    @State private var scrollState = MangaDetailScrollState()
    @State private var showChapterSettings = false
    @State private var showTracking = false
    @State private var showNotes = false
    @State private var showNextUpdate = false
    @State private var showCategories = false
    @State private var showCover = false

    public init(mangaId: Int64) {
        self.mangaId = mangaId
    }

    public var body: some View {
        if let manga = store.manga(id: mangaId) {
            content(manga: manga)
        } else {
            MihonLoadingScreen()
                .background(colors.background)
        }
    }

    private func content(manga: Manga) -> some View {
        let chapters = store.filteredAndSortedChapters(for: manga)
        let allChapters = store.chaptersByManga[manga.id] ?? []
        let nextChapter = store.nextUnreadChapter(for: manga.id)
        let hasReadChapters = allChapters.contains(where: \.read)
        let isRefreshing = store.refreshingMangaIds.contains(manga.id)

        return GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        MangaInfoBox(manga: manga, topPadding: safeTop + 64, onCoverClick: { showCover = true })
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: DetailHeaderOffsetKey.self, value: proxy.frame(in: .named("mangaScroll")).minY)
                                }
                            )
                        MangaActionRow(
                            manga: manga,
                            trackingCount: store.tracksByManga[manga.id]?.count ?? 0,
                            onAddToLibrary: {
                                if manga.favorite {
                                    store.removeFromLibrary(mangaId: manga.id)
                                } else if store.asksCategoriesOnAdd {
                                    showCategories = true
                                } else {
                                    store.addToLibrary(mangaId: manga.id)
                                }
                            },
                            // Upstream: the estimate opens for titles in the library only.
                            onNextUpdate: manga.favorite ? { showNextUpdate = true } : nil,
                            // Tracker sign-in is demo-only, so tester builds leave the button out.
                            onTracking: store.showsDemoFeatures ? { showTracking = true } : nil,
                            onNotes: { showNotes = true },
                            onCategories: { showCategories = true }
                        )
                        ExpandableMangaDescription(
                            description: manga.description,
                            notes: manga.notes,
                            tags: manga.genre,
                            expanded: $descriptionExpanded
                        )
                        ChapterHeader(count: chapters.count, isRefreshing: isRefreshing) {
                            showChapterSettings = true
                        }

                        if chapters.isEmpty {
                            Text(isRefreshing ? "正在获取章节…" : "没有章节")
                                .font(MihonType.bodyMedium)
                                .foregroundStyle(colors.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        }

                        ForEach(chapters) { chapter in
                            MangaChapterListItem(
                                manga: manga,
                                chapter: chapter,
                                isSelected: selection.contains(chapter.id),
                                onClick: {
                                    if selection.isEmpty {
                                        navigator.openReader(manga, chapter)
                                    } else {
                                        toggleSelection(chapter.id)
                                    }
                                },
                                onLongClick: { toggleSelection(chapter.id) }
                            )
                        }
                        Color.clear.frame(height: 96)
                    }
                }
                .coordinateSpace(name: "mangaScroll")
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    await store.refreshMangaFromSource(mangaId: manga.id, force: true)
                }
                .onPreferenceChange(DetailHeaderOffsetKey.self) { [scrollState] offset in
                    scrollState.update(offset: offset)
                }

                VStack(spacing: 0) {
                    toolbar(manga: manga, chapters: chapters)
                    if isRefreshing {
                        MihonLinearProgress()
                    }
                }
            }
        }
        .background(colors.background)
        .overlay(alignment: .bottomTrailing) {
            if let nextChapter, selection.isEmpty {
                ScrollStateReader(state: scrollState) { state in
                    MihonExtendedFAB(
                        text: hasReadChapters ? "继续" : "开始",
                        systemImage: "play.fill",
                        expanded: state.fabExpanded
                    ) {
                        navigator.openReader(manga, nextChapter)
                    }
                }
                .padding(16)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty {
                chapterActionMenu(manga: manga, chapters: allChapters)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection.isEmpty)
        .task(id: manga.id) {
            await store.refreshMangaFromSource(mangaId: manga.id)
        }
        .sheet(item: $website, onDismiss: {
            Task { await store.refreshMangaFromSource(mangaId: manga.id, force: true) }
        }) { location in
            WebsiteSessionSheet(url: location.url)
        }
        .sheet(isPresented: $showChapterSettings) {
            ChapterSettingsSheet(mangaId: manga.id)
                .environment(store)
                .mihonSheetChrome(colors, detents: [.medium])
        }
        .sheet(isPresented: $showTracking) {
            MangaTrackerSheet(manga: manga)
                .environment(store)
                .mihonSheetChrome(colors)
        }
        // Upstream's `SetIntervalDialog` as release builds show it: the estimate, no custom interval.
        .alert("智能更新", isPresented: $showNextUpdate) {
            Button("取消", role: .cancel) {}
            Button("确定") {}
        } message: {
            Text(MihonDateText.nextUpdateEstimate(manga))
        }
        .sheet(isPresented: $showNotes) {
            MangaNotesEditorSheet(mangaId: manga.id)
                .environment(store)
                .mihonSheetChrome(colors)
        }
        .sheet(isPresented: $showCategories) {
            ChangeCategorySheet(mangaIds: [manga.id], addsToLibrary: true)
                .environment(store)
                .mihonSheetChrome(colors, detents: [.medium])
        }
        .sheet(isPresented: $showCover) {
            MangaCoverDialog(manga: manga)
                .environment(store)
                .mihonSheetChrome(colors, detents: [.large])
        }
    }

    private func toggleSelection(_ id: Int64) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    // MARK: Toolbar (transparent over the header → `surfaceColorAtElevation(3.dp)` when scrolled)

    @ViewBuilder
    private func toolbar(manga: Manga, chapters: [Chapter]) -> some View {
        if !selection.isEmpty {
            MihonTopAppBar(
                title: "\(selection.count)",
                navigation: .close { selection.removeAll() },
                background: colors.surfaceElevation3
            ) {
                MihonIconButton("checkmark.rectangle.stack") { selection = Set(chapters.map(\.id)) }
                    .help("全选")
                MihonIconButton("square.on.square") {
                    selection = Set(chapters.map(\.id)).symmetricDifference(selection)
                }
                .help("反选")
            }
        } else {
            ScrollStateReader(state: scrollState) { state in
            MihonTopAppBar(
                title: manga.title,
                navigation: navigator.isDualPane ? nil : .back { dismiss() },
                background: colors.surfaceElevation3.opacity(state.toolbarProgress),
                titleOpacity: state.toolbarProgress
            ) {
                if manga.source != 0 {
                    Menu {
                        Button("下一章") { download(manga: manga, chapters: chapters, count: 1) }
                        Button("后 5 章") { download(manga: manga, chapters: chapters, count: 5) }
                        Button("后 10 章") { download(manga: manga, chapters: chapters, count: 10) }
                        Button("未读章节") {
                            store.enqueueChapterDownloads(manga: manga, chapters: chapters.filter { !$0.read }.reversed())
                        }
                        Button("全部章节") { store.enqueueChapterDownloads(manga: manga, chapters: chapters.reversed()) }
                    } label: {
                        toolbarGlyph("arrow.down.to.line")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .help("下载")
                }
                MihonIconButton(
                    "line.3.horizontal.decrease",
                    tint: hasChapterFilters(manga) ? colors.active : nil
                ) {
                    showChapterSettings = true
                }
                .help("筛选")
                Menu {
                    Button("刷新") { Task { await store.refreshMangaFromSource(mangaId: manga.id, force: true) } }
                    Button("设置分类") { showCategories = true }
                    Button("编辑注释") { showNotes = true }
                    if let url = store.websiteURL(sourceId: manga.source, path: manga.url) {
                        Button("打开源站") { website = WebsiteLocation(url: url) }
                    } else if let source = store.catalogueSource(for: manga.source) {
                        Button("在浏览器中打开") {
                            let smanga = SManga(url: manga.url, title: manga.title)
                            if let url = URL(string: source.getMangaUrl(manga: smanga)) { openURL(url) }
                        }
                    }
                } label: {
                    toolbarGlyph("ellipsis").rotationEffect(.degrees(90))
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
            }
        }
    }

    private func toolbarGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }

    private func hasChapterFilters(_ manga: Manga) -> Bool {
        manga.filterUnread != .disabled || manga.filterDownloaded != .disabled || manga.filterBookmarked != .disabled
    }

    /// Upstream `getUnreadChaptersSorted`: the next unread chapters not already downloaded, queued or downloading.
    private func download(manga: Manga, chapters: [Chapter], count: Int) {
        let next = store.readingOrderChapters(mangaId: manga.id).filter { chapter in
            !chapter.read && store.downloadState(for: chapter, in: manga) == .notDownloaded
        }
        store.enqueueChapterDownloads(manga: manga, chapters: Array(next.prefix(count)))
    }

    // MARK: Chapter action mode (1:1 with `MangaBottomActionMenu`)

    private func chapterActionMenu(manga: Manga, chapters: [Chapter]) -> some View {
        let selected = chapters.filter { selection.contains($0.id) }
        let anyUnbookmarked = selected.contains { !$0.bookmark }
        let anyUnread = selected.contains { !$0.read }
        return HStack(spacing: 0) {
            MihonBottomActionButton(
                title: anyUnbookmarked ? "为章节添加书签" : "为章节删除书签",
                systemImage: anyUnbookmarked ? "bookmark" : "bookmark.slash"
            ) {
                store.setChaptersBookmarked(mangaId: manga.id, chapterIds: selection, bookmarked: anyUnbookmarked)
                selection.removeAll()
            }
            MihonBottomActionButton(
                title: anyUnread ? "标记为已读" : "标记为未读",
                systemImage: anyUnread ? "checkmark.circle" : "arrow.uturn.backward.circle"
            ) {
                store.setChaptersRead(mangaId: manga.id, chapterIds: selection, read: anyUnread)
                selection.removeAll()
            }
            if selected.count == 1, let only = selected.first {
                MihonBottomActionButton(title: "标记之前章节为已读", systemImage: "text.badge.checkmark") {
                    store.markChaptersRead(before: only.id, in: manga)
                    selection.removeAll()
                }
            }
            if manga.source != 0 {
                MihonBottomActionButton(title: "下载", systemImage: "arrow.down.circle") {
                    store.enqueueChapterDownloads(manga: manga, chapters: selected)
                    selection.removeAll()
                }
                MihonBottomActionButton(title: "删除", systemImage: "trash") {
                    for chapter in selected { store.removeChapterDownload(chapterId: chapter.id) }
                    selection.removeAll()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: MihonShape.large, topTrailingRadius: MihonShape.large)
                .fill(colors.surfaceContainerHigh)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - MangaInfoBox (small layout)

private struct MangaInfoBox: View {
    let manga: Manga
    let topPadding: CGFloat
    let onCoverClick: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            MangaCoverView(title: manga.title, thumbnailUrl: store.coverUrl(for: manga))
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 100)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture(perform: onCoverClick)

            VStack(alignment: .leading, spacing: 2) {
                Text(manga.title.isEmpty ? "未知标题" : manga.title)
                    .font(MihonType.titleLarge)
                    .foregroundStyle(colors.onSurface)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 2)
                metadataRow(icon: "person.fill", text: (manga.author?.isEmpty == false ? manga.author! : "未知作者"))
                if let artist = manga.artist, !artist.isEmpty, artist != manga.author {
                    metadataRow(icon: "paintbrush.fill", text: artist)
                }
                Spacer().frame(height: 2)
                HStack(spacing: 0) {
                    Image(systemName: manga.status.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16, height: 16)
                        .padding(.trailing, 4)
                    Text(manga.status.localizedTitle)
                        .lineLimit(1)
                    MihonDotSeparator()
                    if store.catalogueSource(for: manga.source) == nil && manga.source != 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.error)
                            .padding(.trailing, 4)
                    }
                    Text(store.sourceName(for: manga.source))
                        .lineLimit(1)
                }
                .font(MihonType.bodyMedium)
                .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, topPadding + 16)
        .background {
            // Backdrop: cover, crop, blur(4dp), alpha 0.2, gradient Transparent → background
            MihonRemoteImage(url: MangaCoverView.resolveCoverUrl(store.coverUrl(for: manga)), target: .cover, placeholder: .clear, showsErrorIcon: false)
                .blur(radius: 4)
                .opacity(0.2)
                .overlay(LinearGradient(colors: [.clear, colors.background], startPoint: .top, endPoint: .bottom))
                .clipped()
        }
    }

    private func metadataRow(icon: String, text: String) -> some View {
        HStack(spacing: MihonPadding.extraSmall) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
            Text(text)
                .font(MihonType.titleSmall)
                .lineLimit(2)
        }
        .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
    }
}

// MARK: - MangaActionRow (TextButton columns, 20pt icon + 12pt label)

private struct MangaActionRow: View {
    let manga: Manga
    let trackingCount: Int
    let onAddToLibrary: () -> Void
    let onNextUpdate: (() -> Void)?
    let onTracking: (() -> Void)?
    let onNotes: () -> Void
    let onCategories: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        let inactive = colors.onSurface.opacity(MihonAlpha.disabled)
        HStack(spacing: 0) {
            actionButton(
                title: manga.favorite ? "在书架中" : "添加到书架",
                icon: manga.favorite ? "heart.fill" : "heart",
                color: manga.favorite ? colors.primary : inactive,
                action: onAddToLibrary
            )
            // Upstream's next update button: highlighted for an interval the user set.
            actionButton(
                title: MihonDateText.nextUpdateLabel(manga),
                icon: "hourglass",
                color: manga.fetchInterval < 0 ? colors.primary : inactive,
                action: { onNextUpdate?() }
            )
            if let onTracking {
                actionButton(
                    title: trackingCount == 0 ? "进度记录" : "\(trackingCount) 个记录平台",
                    icon: trackingCount == 0 ? "arrow.triangle.2.circlepath" : "checkmark",
                    color: trackingCount == 0 ? inactive : colors.primary,
                    action: onTracking
                )
            }
            actionButton(
                title: "注释",
                icon: "note.text",
                color: manga.notes.isEmpty ? inactive : colors.primary,
                action: onNotes
            )
            actionButton(title: "设置分类", icon: "tag", color: inactive, action: onCategories)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(MihonStateLayerStyle(shape: Capsule()))
        .mihonTestAnchor("action.\(icon)")
    }
}

// MARK: - ExpandableMangaDescription (3 lines collapsed with fade + chevron; tags row / flow)

private struct ExpandableMangaDescription: View {
    let description: String?
    let notes: String
    let tags: [String]
    @Binding var expanded: Bool
    @Environment(\.mihonColors) private var colors

    var body: some View {
        let text = description.flatMap { $0.isEmpty ? nil : $0 } ?? "无简介"
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !notes.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(colors.primary).frame(width: 2)
                        Text(notes)
                            .font(MihonType.bodyMedium)
                            .foregroundStyle(colors.onSurface)
                            .lineLimit(expanded ? nil : 2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                // No `.textSelection` here: on macOS a click on selectable text starts a selection and never
                // reaches the expand tap. Copying goes through the context menu (long press / secondary click).
                // Collapsed, the summary is always three lines tall (upstream lays out a hidden "\n\n"), so the
                // fade and chevron sit below a short description instead of over it.
                ZStack(alignment: .topLeading) {
                    Text("\n\n")
                        .font(MihonType.bodyMedium)
                        .hidden()
                    Text(text)
                        .font(MihonType.bodyMedium)
                        .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
                        .lineLimit(expanded ? nil : 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .bottom) {
                if !expanded {
                    LinearGradient(colors: [colors.background.opacity(0), colors.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.onBackground)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .padding(4)
                    .background(expanded ? colors.background.opacity(0.0) : colors.background.opacity(0.85), in: Circle())
                    .offset(y: expanded ? 18 : 6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { expanded.toggle() }
            }
            .contextMenu {
                Button("复制到剪贴板", systemImage: "doc.on.doc") { copyToClipboard(text) }
            }
            .mihonTestAnchor("detail.description")
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, expanded ? 18 : 0)

            if !tags.isEmpty {
                Group {
                    if expanded {
                        MihonFlowLayout(spacing: MihonPadding.extraSmall) {
                            ForEach(tags, id: \.self) { tag in MihonTagChip(text: tag) }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MihonPadding.extraSmall) {
                                ForEach(tags, id: \.self) { tag in MihonTagChip(text: tag) }
                            }
                            .padding(.horizontal, 16)
                        }
                        // Horizontal scroll content would run under the Duo cover screen's status strip.
                        .clipped()
                    }
                }
                .padding(.top, 8)
                .padding(.vertical, 12)
            } else {
                Spacer().frame(height: 12)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - ChapterHeader

private struct ChapterHeader: View {
    let count: Int
    let isRefreshing: Bool
    let onClick: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        Button(action: onClick) {
            Text(isRefreshing && count == 0 ? "章节" : "共 \(count) 章")
                .font(MihonType.titleMedium)
                .foregroundStyle(colors.onBackground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.mihonRow)
    }
}

// MARK: - MangaChapterListItem (1:1 incl. swipe actions & `ChapterDownloadIndicator`)

struct MangaChapterListItem: View {
    let manga: Manga
    let chapter: Chapter
    let isSelected: Bool
    let onClick: () -> Void
    let onLongClick: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeLocked: Bool?

    private let swipeThreshold: CGFloat = 56

    var body: some View {
        let textAlpha = chapter.read ? MihonAlpha.disabled : 1
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    if !chapter.read {
                        Circle()
                            .fill(colors.primary)
                            .frame(width: 8, height: 8)
                            .padding(.trailing, 4)
                    }
                    if chapter.bookmark {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.primary)
                    }
                    Text(displayTitle)
                        .font(MihonType.bodyMedium)
                        .foregroundStyle(colors.onSurface.opacity(textAlpha))
                        .lineLimit(1)
                }
                // Upstream leaves out an unknown upload date (0) and the separator after it.
                let dated = chapter.dateUpload > SChapter.undatedUpload
                let inProgress = !chapter.read && chapter.lastPageRead > 0
                HStack(spacing: 0) {
                    if dated {
                        Text(MihonDateText.relative(chapter.dateUpload))
                    }
                    if inProgress {
                        if dated { MihonDotSeparator() }
                        Text("第 \(chapter.lastPageRead + 1) 页")
                            .foregroundStyle(colors.onSurface.opacity(MihonAlpha.disabled))
                    }
                    if let scanlator = chapter.scanlator, !scanlator.isEmpty {
                        if dated || inProgress { MihonDotSeparator() }
                        Text(scanlator)
                    }
                }
                .font(MihonType.bodySmall)
                .foregroundStyle(colors.onSurface.opacity(chapter.read ? MihonAlpha.disabled : MihonAlpha.secondary))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if manga.source != 0 {
                ChapterDownloadIndicator(manga: manga, chapter: chapter)
                    .padding(.leading, 4)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
        .background(isSelected ? colors.secondary.opacity(colors.isDark ? 0.16 : 0.22) : colors.background)
        .mihonClickable(onLongClick: onLongClick, onClick: onClick)
        .mihonTestAnchor("chapter.\(chapter.id)")
        .offset(x: swipeOffset)
        .background(swipeBackground)
        .clipped()
        .simultaneousGesture(swipeGesture)
    }

    private var displayTitle: String {
        if manga.chapterDisplayMode == .chapterNumber, chapter.chapterNumber >= 0 {
            return "第 \(MihonDateText.chapterNumber(chapter.chapterNumber)) 章"
        }
        return chapter.name
    }

    // Start → bookmark, end → read (upstream defaults `ToggleBookmark` / `ToggleRead`).
    private var swipeBackground: some View {
        ZStack {
            colors.primaryContainer
            HStack {
                if swipeOffset > 0 {
                    Image(systemName: chapter.bookmark ? "bookmark.slash" : "bookmark")
                        .padding(.leading, 16)
                    Spacer()
                } else if swipeOffset < 0 {
                    Spacer()
                    Image(systemName: chapter.read ? "arrow.uturn.backward" : "checkmark")
                        .padding(.trailing, 16)
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(colors.onPrimaryContainer)
            .scaleEffect(abs(swipeOffset) >= swipeThreshold ? 1.15 : 1)
            .animation(.spring(duration: 0.2), value: abs(swipeOffset) >= swipeThreshold)
        }
        .opacity(swipeOffset == 0 ? 0 : 1)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                if swipeLocked == nil {
                    swipeLocked = abs(value.translation.width) > abs(value.translation.height) * 1.4
                }
                guard swipeLocked == true else { return }
                swipeOffset = max(-140, min(140, value.translation.width))
            }
            .onEnded { _ in
                defer {
                    swipeLocked = nil
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { swipeOffset = 0 }
                }
                guard swipeLocked == true else { return }
                if swipeOffset >= swipeThreshold {
                    store.toggleChapterBookmark(mangaId: manga.id, chapterId: chapter.id)
                } else if swipeOffset <= -swipeThreshold {
                    store.toggleChapterRead(mangaId: manga.id, chapterId: chapter.id)
                }
            }
    }
}

/// 1:1 with `ChapterDownloadIndicator` (40pt state layer, 26pt glyph, 2pt progress ring).
struct ChapterDownloadIndicator: View {
    let manga: Manga
    let chapter: Chapter
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        let task = store.downloadTask(for: chapter.id)
        let downloaded = store.downloadedChapterIds.contains(chapter.id)
        Group {
            if downloaded {
                Menu {
                    Button("删除", role: .destructive) { store.removeChapterDownload(chapterId: chapter.id) }
                } label: {
                    glyph("checkmark.circle.fill", color: colors.onSurfaceVariant)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            } else if let task {
                Menu {
                    Button("取消", role: .destructive) { store.cancelDownload(chapterId: chapter.id) }
                } label: {
                    DownloadProgressRing(task: task)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            } else {
                Button {
                    store.enqueueChapterDownload(manga: manga, chapter: chapter)
                } label: {
                    glyph("arrow.down.circle", color: colors.onSurfaceVariant.opacity(MihonAlpha.secondary))
                }
                .buttonStyle(MihonStateLayerStyle(shape: Circle()))
            }
        }
        .frame(width: 40, height: 40)
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }
}

/// Observes a single `MihonDownloadTask`, so progress ticks only redraw this ring.
private struct DownloadProgressRing: View {
    let task: MihonDownloadTask
    @Environment(\.mihonColors) private var colors

    var body: some View {
        let indeterminate = task.status == .queue || task.downloadedPages == 0
        ZStack {
            MihonCircularProgress(
                progress: indeterminate ? nil : task.progress,
                size: 24,
                lineWidth: 2,
                color: colors.onSurfaceVariant,
                trackColor: indeterminate ? nil : colors.onSurfaceVariant.opacity(0.25)
            )
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(colors.onSurfaceVariant)
        }
    }
}

// MARK: - Date / chapter number formatting (upstream `relativeDateText`)

enum MihonDateText {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return "\(days) 天前" }
        return dateFormatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return dateFormatter.string(from: date)
    }

    /// Upstream `LocalDate.toRelativeString`: 今天, N 天后 or N 天前 within a week, else the date.
    static func relativeDay(_ day: MihonLocalDate, today: MihonLocalDate = MihonLocalDate(Date(), in: .current)) -> String {
        let difference = day.daysUntil(today)
        switch difference {
        case 0: return "今天"
        case -7 ..< 0: return "\(-difference) 天后"
        case 1 ..< 7: return "\(difference) 天前"
        default: return String(format: "%04d/%02d/%02d", day.year, day.month, day.day)
        }
    }

    /// Upstream `Manga.expectedNextUpdate` as whole days from now, never below zero (nil: none expected).
    static func daysUntilNextUpdate(_ manga: Manga, now: Date = Date()) -> Int? {
        guard manga.status != .completed, let next = manga.nextUpdate else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: now, to: next).day ?? 0)
    }

    /// The next update button: 无 / 即将更新 / N 天.
    static func nextUpdateLabel(_ manga: Manga, now: Date = Date()) -> String {
        switch daysUntilNextUpdate(manga, now: now) {
        case nil: return "无"
        case 0: return "即将更新"
        case let days?: return "\(days) 天"
        }
    }

    /// Upstream `SetIntervalDialog`'s text.
    static func nextUpdateEstimate(_ manga: Manga, now: Date = Date()) -> String {
        guard let days = daysUntilNextUpdate(manga, now: now), manga.fetchInterval >= 0 else {
            return "此漫画或已完结，或无发行日期。"
        }
        return "预计 \(days) 天后更新，每 \(manga.fetchInterval) 天检查一次。"
    }

    static func chapterNumber(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
    }
}

// MARK: - Cover dialog

/// Upstream `MangaCoverDialog`: the cover, to share or save — and a custom one to drop again.
private struct MangaCoverDialog: View {
    let manga: Manga
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cover = store.coverUrl(for: manga)
        VStack(spacing: 0) {
            MihonTopAppBar(title: "", navigation: .close { dismiss() }, background: .clear) {
                if let url = MangaCoverView.resolveCoverUrl(cover) {
                    let fileName = manga.title.replacingOccurrences(of: "/", with: "／") + ".jpg"
                    ShareLink(item: MihonPageImageFile(url: url, fileName: fileName), preview: SharePreview(fileName)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18))
                            .foregroundStyle(colors.onSurfaceVariant)
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    #if os(iOS)
                    MihonIconButton("square.and.arrow.down", label: "保存到相册") {
                        Task {
                            guard let data = await MihonPageImageFile.jpegData(url: url) else { return }
                            do {
                                try await MihonPageActions.saveToPhotos(data)
                                store.showStatusBanner("已保存到相册")
                            } catch {
                                store.showStatusBanner(error.localizedDescription)
                            }
                        }
                    }
                    #endif
                }
                if store.customCoverVersions[manga.id] != nil {
                    MihonIconButton("arrow.uturn.backward", label: "恢复默认封面") {
                        store.removeCustomCover(mangaId: manga.id)
                    }
                }
            }
            MihonRemoteImage(url: MangaCoverView.resolveCoverUrl(cover), target: .cover, contentMode: .fit, placeholder: .clear)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(colors.surfaceContainerLow)
    }
}

// MARK: - Chapter settings sheet (1:1 with `ChapterSettingsDialog`: 筛选 / 排序 / 显示)

public struct ChapterSettingsSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    public let mangaId: Int64
    @State private var tab: Int64 = 0

    public init(mangaId: Int64) { self.mangaId = mangaId }

    public var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            MihonTabRow(
                tabs: [MihonTab(id: 0, title: "筛选"), MihonTab(id: 1, title: "排序"), MihonTab(id: 2, title: "显示")],
                selection: $tab,
                background: colors.surfaceContainerLow
            )
            .padding(.top, 8)
            if let idx = store.mangas.firstIndex(where: { $0.id == mangaId }) {
                ScrollView {
                    VStack(spacing: 0) {
                        switch tab {
                        case 0:
                            MihonTriStateItem("已下载", state: $store.mangas[idx].filterDownloaded, isEnabled: !store.downloadedOnlyMode)
                            MihonTriStateItem("未读", state: $store.mangas[idx].filterUnread)
                            MihonTriStateItem("已添加书签", state: $store.mangas[idx].filterBookmarked)
                        case 1:
                            ForEach(ChapterSortMode.allCases, id: \.self) { mode in
                                let manga = store.mangas[idx]
                                MihonSortItem(mode.rawValue, descending: manga.chapterSortMode == mode ? !manga.chapterSortAscending : nil) {
                                    if store.mangas[idx].chapterSortMode == mode {
                                        store.mangas[idx].chapterSortAscending.toggle()
                                    } else {
                                        store.mangas[idx].chapterSortMode = mode
                                        store.mangas[idx].chapterSortAscending = false
                                    }
                                }
                            }
                        default:
                            ForEach(ChapterDisplayMode.allCases, id: \.self) { mode in
                                MihonRadioItem(mode.rawValue, selected: store.mangas[idx].chapterDisplayMode == mode) {
                                    store.mangas[idx].chapterDisplayMode = mode
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(colors.surfaceContainerLow)
    }
}

// MARK: - Tracking sheet (1:1 with `TrackInfoDialogHome`)

public struct MangaTrackerSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    public let manga: Manga

    public init(manga: Manga) { self.manga = manga }

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(store.trackers) { service in
                    trackerCard(service)
                }
            }
            .padding(16)
        }
        .background(colors.surfaceContainerLow)
    }

    @ViewBuilder
    private func trackerCard(_ service: TrackerServiceInfo) -> some View {
        let track = (store.tracksByManga[manga.id] ?? []).first { $0.trackerId == service.id }
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: service.iconSystemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(Color(hexString: service.brandColorHex)))

            if let track {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(track.title)
                            .font(MihonType.titleSmall)
                            .foregroundStyle(colors.onSurface)
                            .lineLimit(1)
                        Spacer()
                        Menu {
                            Button("移除", role: .destructive) { store.removeTrack(mangaId: manga.id, trackerId: service.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .rotationEffect(.degrees(90))
                                .foregroundStyle(colors.onSurfaceVariant)
                                .frame(width: 32, height: 32)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 0) {
                        Menu {
                            ForEach(TrackStatus.allCases, id: \.self) { status in
                                Button(status.localizedTitle) { update(track) { $0.status = status } }
                            }
                        } label: {
                            trackCell(track.status.localizedTitle)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        verticalDivider
                        HStack(spacing: 0) {
                            Button { update(track) { $0.lastChapterRead = max(0, $0.lastChapterRead - 1) } } label: {
                                Image(systemName: "minus").frame(width: 28, height: 36)
                            }
                            .buttonStyle(.plain)
                            trackCell("\(Int(track.lastChapterRead))\(track.totalChapters > 0 ? " / \(track.totalChapters)" : "")")
                            Button { update(track) { $0.lastChapterRead += 1 } } label: {
                                Image(systemName: "plus").frame(width: 28, height: 36)
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(colors.onSurface)
                        verticalDivider
                        Menu {
                            ForEach(Array(stride(from: 10.0, through: 0, by: -0.5)), id: \.self) { score in
                                Button(String(format: "%.1f", score)) { update(track) { $0.score = score } }
                            }
                        } label: {
                            trackCell(track.score > 0 ? String(format: "%.1f", track.score) : "评分")
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                    }
                    .font(MihonType.bodyMedium)
                    .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(colors.surfaceContainerHighest))
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(MihonType.titleSmall)
                        .foregroundStyle(colors.onSurface)
                    Text(service.isLoggedIn ? "已登录 · \(service.username ?? "")" : "未登录")
                        .font(MihonType.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer()
                Button("添加记录") { addTrack(service) }
                    .buttonStyle(MihonButtonStyle(.text))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: MihonShape.medium).fill(colors.surfaceContainer))
    }

    private var verticalDivider: some View {
        Rectangle().fill(colors.outlineVariant).frame(width: 1, height: 20)
    }

    private func trackCell(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(colors.onSurface)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
    }

    private func update(_ track: Track, _ body: (inout Track) -> Void) {
        var updated = track
        body(&updated)
        store.bindOrUpdateTrack(updated)
    }

    private func addTrack(_ service: TrackerServiceInfo) {
        if !service.isLoggedIn {
            store.toggleTrackerLogin(trackerId: service.id)
        }
        let highestRead = (store.chaptersByManga[manga.id] ?? []).filter(\.read).map(\.chapterNumber).max() ?? 0
        store.bindOrUpdateTrack(
            Track(
                id: StableHash.positiveId("\(manga.id)-\(service.id)") % 1_000_000,
                mangaId: manga.id,
                trackerId: service.id,
                remoteId: StableHash.positiveId(manga.title) % 500_000,
                title: manga.title,
                lastChapterRead: highestRead,
                totalChapters: manga.status == .completed ? (store.chaptersByManga[manga.id]?.count ?? 0) : 0,
                status: .reading,
                remoteUrl: "\(service.baseUrl)/manga/\(manga.id)"
            )
        )
    }
}

// MARK: - Notes editor (1:1 with `MangaNotesTextArea`)

public struct MangaNotesEditorSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss
    public let mangaId: Int64
    @State private var draft = ""
    @State private var loaded = false

    public init(mangaId: Int64) { self.mangaId = mangaId }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MihonTopAppBar(title: "编辑注释", navigation: .close { dismiss() }, background: colors.surfaceContainerLow) {
                Button("保存") {
                    if let idx = store.mangas.firstIndex(where: { $0.id == mangaId }) {
                        store.mangas[idx].notes = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    dismiss()
                }
                .buttonStyle(MihonButtonStyle(.text))
            }
            TextEditor(text: $draft)
                .font(MihonType.bodyLarge)
                .foregroundStyle(colors.onSurface)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: MihonShape.extraSmall)
                        .strokeBorder(colors.outline, lineWidth: 1)
                )
                .padding(16)
        }
        .background(colors.surfaceContainerLow)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = store.manga(id: mangaId)?.notes ?? ""
        }
    }
}

extension Color {
    /// `#RRGGBB` tracker brand colours.
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(cleaned, radix: 16) ?? 0x777777)
    }
}
