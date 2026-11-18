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
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: WebsiteLoadState = .loading
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                SourceWebView(url: url, loadState: $loadState)
                    .id(attempt)
                switch loadState {
                case .loading:
                    ProgressView("正在打开源站…")
                        .allowsHitTesting(false)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("源站未能打开", systemImage: "globe")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重新打开") {
                            loadState = .loading
                            attempt += 1
                        }
                    }
                case .ready:
                    EmptyView()
                }
            }
            .navigationTitle(url.host ?? "源站")
            .toolbar { Button("完成") { dismiss() } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 420, idealHeight: 600)
        #endif
    }
}

private enum WebsiteLoadState {
    case loading, ready, failed(String)
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
            state = .failed("网页已关闭，请重新打开。")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: $loadState) }

    private func browser(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
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
