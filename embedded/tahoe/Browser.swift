import SwiftUI
import WebKit

@MainActor
final class TahoeBrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    @Published var address = "https://www.apple.com"
    @Published var title = "New Tab"
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var message: String?
    @Published private(set) var webView: WKWebView?
    var openTab: ((URL, WKWebViewConfiguration?) -> WKWebView?)?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL, configuration: WKWebViewConfiguration? = nil) {
        super.init()
        address = url.absoluteString
        makeWebView(configuration: configuration)
        // WebKit loads the original request itself when it supplies a popup configuration.
        if configuration == nil { webView?.load(URLRequest(url: url)) }
    }

    private func makeWebView(configuration: WKWebViewConfiguration? = nil) {
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webView = view
        observations = [
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.progress = view.estimatedProgress }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            }
        ]
    }

    func navigate() {
        guard let url = TahoeAddress.url(for: address) else { message = "Enter an HTTP or HTTPS address, or a search."; return }
        if webView == nil { makeWebView() }
        message = nil
        webView?.load(URLRequest(url: url))
    }

    func hibernate() {
        if let url = webView?.url { address = url.absoluteString }
        observations.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        loading = false
        canGoBack = false
        canGoForward = false
        message = "Page unloaded to save memory. Resume reloads its address; unsaved page state and back history are not retained."
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        message = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        address = webView.url?.absoluteString ?? address
        title = webView.title ?? "Browser"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        message = "The page process stopped. Reload to restore this page."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        // Subframe blobs/data are common in web applications. Top-level executable/file URLs are refused.
        let allowed = ["http", "https", "about"].contains(scheme) ||
            (navigationAction.targetFrame?.isMainFrame == false && ["blob", "data"].contains(scheme))
        if !allowed { message = "This link uses an unsupported scheme: \(scheme)." }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return openTab?(url, configuration)
    }
}

@MainActor
final class TahoeBrowserSession: ObservableObject {
    @Published var tabs: [TahoeBrowserTab] = []
    @Published var selectedID: UUID?
    init(url: URL) { add(url: url) }

    @discardableResult func add(url: URL = URL(string: "https://www.apple.com")!, configuration: WKWebViewConfiguration? = nil) -> WKWebView? {
        let tab = TahoeBrowserTab(url: url, configuration: configuration)
        tab.openTab = { [weak self] url, configuration in self?.add(url: url, configuration: configuration) }
        tabs.append(tab)
        selectedID = tab.id
        return tab.webView
    }
    func close(_ id: UUID) {
        tabs.first(where: { $0.id == id })?.hibernate()
        tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs.last?.id }
        if tabs.isEmpty { add() }
    }
    func hibernate() { tabs.forEach { $0.hibernate() } }
}

struct TahoeBrowserView: View {
    @ObservedObject var session: TahoeBrowserSession
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(session.tabs) { tab in
                        HStack(spacing: 4) {
                            Button { session.selectedID = tab.id } label: { TahoeTabLabel(tab: tab) }
                            Button { session.close(tab.id) } label: { Image(systemName: "xmark").font(.caption2) }.accessibilityLabel("Close tab")
                        }
                        .padding(6).background(session.selectedID == tab.id ? Color.primary.opacity(0.08) : .clear,
                                               in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button { session.add() } label: { Image(systemName: "plus") }.accessibilityLabel("New tab")
                }.padding(6)
            }
            if let tab = session.tabs.first(where: { $0.id == session.selectedID }) {
                TahoeBrowserPage(tab: tab).id(tab.id)
            }
        }.buttonStyle(.plain)
    }
}

private struct TahoeTabLabel: View {
    @ObservedObject var tab: TahoeBrowserTab
    var body: some View { Text(tab.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 140) }
}

private struct TahoeBrowserPage: View {
    @ObservedObject var tab: TahoeBrowserTab
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { tab.webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!tab.canGoBack).accessibilityLabel("Back")
                Button { tab.webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!tab.canGoForward).accessibilityLabel("Forward")
                TextField("Search or enter website", text: $tab.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                    .onSubmit { tab.navigate() }.padding(6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Button {
                    if tab.loading { tab.webView?.stopLoading(); tab.loading = false }
                    else if tab.webView == nil { tab.navigate() }
                    else { tab.webView?.reload() }
                } label: { Image(systemName: tab.loading ? "xmark" : "arrow.clockwise") }
                .accessibilityLabel(tab.loading ? "Stop loading" : "Reload")
            }.font(.system(size: 13)).padding(8)
            ProgressView(value: tab.progress).opacity(tab.loading ? 1 : 0).frame(height: 2)
            if let message = tab.message {
                HStack {
                    Text(message).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(tab.webView == nil ? "Resume" : "Retry") { tab.navigate() }
                }.padding(10).background(Color.orange.opacity(0.12))
            }
            if let webView = tab.webView { TahoeWebSurface(webView: webView) }
            else { Spacer() }
        }
    }
}

private struct TahoeWebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) { /* Navigation is never triggered by layout updates. */ }
}
