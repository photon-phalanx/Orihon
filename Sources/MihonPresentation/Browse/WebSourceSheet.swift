import SwiftUI
import UniformTypeIdentifiers
import WebKit
import MihonData

struct WebSourceSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Button("从文件导入 JSON 图源", systemImage: "square.and.arrow.down") { picking = true }
                if let error { Text(error).foregroundStyle(.red) }
                if !store.importedSourceDescriptors.isEmpty {
                    Section("已导入") {
                        ForEach(store.importedSourceDescriptors, id: \.id) { descriptor in
                            HStack {
                                Text(descriptor.name)
                                Spacer()
                                Button(role: .destructive) { store.removeHTMLSource(id: descriptor.id) } label: {
                                    Image(systemName: "trash").accessibilityLabel("移除" + descriptor.name)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("管理图源")
            .toolbar { Button("完成") { dismiss() } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    try store.importHTMLSource(try file.read(upToCount: 65_537) ?? Data())
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

struct WebsiteLocation: Identifiable {
    let url: URL
    var id: URL { url }
}

struct WebsiteSessionSheet: View {
    let url: URL
    var onDone: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var recoveryURL: URL?
    @State private var didRecover = false
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: WebsiteLoadState = .loading
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                SourceWebView(url: recoveryURL ?? url, loadState: $loadState)
                    .id(attempt)
                switch loadState {
                case .loading, .terminated:
                    ProgressView("正在打开源站…")
                        .allowsHitTesting(false)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("源站未能打开", systemImage: "globe")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重新打开") {
                            didRecover = false
                            loadState = .loading
                            attempt += 1
                        }
                    }
                case .ready:
                    EmptyView()
                }
            }
            .navigationTitle(url.host ?? "源站")
            .toolbar { Button("完成") { if let onDone { onDone() } else { dismiss() } } }
            .task(id: scenePhase == .active && loadState.isTerminated) {
                guard scenePhase == .active, case .terminated(let lastURL) = loadState else { return }
                guard !didRecover else {
                    loadState = .failed("网页暂时无法恢复，请重新打开。")
                    return
                }
                didRecover = true
                recoveryURL = lastURL
                loadState = .loading
                attempt += 1
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { didRecover = false }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 420, idealHeight: 600)
        #endif
    }
}

private enum WebsiteLoadState {
    case loading, ready, failed(String), terminated(URL)

    var isTerminated: Bool {
        if case .terminated = self { return true }
        return false
    }
}

@MainActor
private struct SourceWebView {
    let url: URL
    @Binding var loadState: WebsiteLoadState

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var state: WebsiteLoadState

        init(state: Binding<WebsiteLoadState>) { _state = state }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { state = .loading }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state = webView.url?.scheme == "about" ? .failed("源站返回了空白页。") : .ready
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                state = .failed("源站返回 HTTP \(http.statusCode)。")
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showError(error)
        }

        private func showError(_ error: Error) {
            if case .failed = state { return }
            let failure = error as NSError
            guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
            state = .failed(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let url = webView.url, url.scheme == "https", url.host == BikaWebsite.accountURL.host {
                state = .terminated(url)
            } else {
                state = .failed("网页已关闭，请重新打开。")
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: $loadState) }

    private func browser(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        BikaAdFilter.loadInitialPage(url, in: view)
        return view
    }
}

#if os(iOS)
extension SourceWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { browser(context: context) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
extension SourceWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { browser(context: context) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
