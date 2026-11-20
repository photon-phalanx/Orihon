import SwiftUI
import MihonData

struct BikaFilterSheet: View {
    let engine: BikaWebsite
    @State private var options: BikaFilterOptions?
    let onApply: (BikaCatalogueFilter) -> Void
    @State private var draft: BikaCatalogueFilter
    @State private var loadError: String?
    @State private var attempt = 0
    @Environment(\.mihonColors) private var colors

    init(engine: BikaWebsite, applied: BikaCatalogueFilter?, onApply: @escaping (BikaCatalogueFilter) -> Void) {
        self.engine = engine
        self.onApply = onApply
        _draft = State(initialValue: applied ?? .init())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("重置") { draft = .init() }
                    .buttonStyle(MihonButtonStyle(.text))
                Spacer()
                Button("应用") { onApply(draft) }
                    .buttonStyle(MihonButtonStyle(.filled))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            MihonDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heading("排序")
                    MihonFlowLayout(lineSpacing: 8) {
                        ForEach(BikaCatalogueFilter.Order.allCases, id: \.self) { order in
                            chip(order.title, selected: draft.order == order) { draft.order = order }
                        }
                    }
                    if let options {
                        heading("分类（可多选）")
                        MihonFlowLayout(lineSpacing: 8) {
                            ForEach(options.categories, id: \.value) { category in
                                chip(category.label, selected: categories.contains(category.value)) {
                                    var values = categories
                                    if values.contains(category.value) { values.removeAll { $0 == category.value } }
                                    else { values.append(category.value) }
                                    draft.selection = .categories(values)
                                }
                            }
                        }
                        if !options.tags.isEmpty {
                            heading("热门标签（点选查看）")
                            MihonFlowLayout(lineSpacing: 8) {
                                ForEach(options.tags, id: \.self) { tag in
                                    chip("#" + tag, selected: draft.selection == .tag(tag)) {
                                        onApply(.init(selection: .tag(tag), order: draft.order))
                                    }
                                }
                            }
                        }
                    }
                    if let loadError {
                        Text(loadError).font(MihonType.bodyMedium)
                        Button("重试") { attempt += 1 }
                            .buttonStyle(MihonButtonStyle(.text))
                    } else if options == nil {
                        ProgressView("正在加载分类和标签")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(colors.surfaceContainerLow)
        .task(id: attempt) {
            loadError = nil
            if options == nil { options = await engine.savedFilterOptions() }
            do {
                let loaded = try await engine.filterOptions()
                try Task.checkCancellation()
                options = loaded
            } catch {
                guard !Task.isCancelled else { return }
                if (error as? BikaReadError) == .login { options = nil }
                loadError = error.localizedDescription
            }
        }
    }

    private var categories: [String] {
        if case let .categories(values) = draft.selection { return values }
        return []
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(MihonType.titleMedium).foregroundStyle(colors.onSurface)
            .accessibilityAddTraits(.isHeader)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        MihonFilterChip(label: label, selected: selected, action: action)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension BikaCatalogueFilter.Order {
    var title: String {
        switch self {
        case .newest: "最新"
        case .oldest: "最早"
        case .likes: "最多喜欢"
        case .views: "最多浏览"
        }
    }
}
