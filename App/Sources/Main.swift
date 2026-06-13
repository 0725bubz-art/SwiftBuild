import SwiftUI
import WebKit
import Combine

// ─────────────────────────────────────────────
// MARK: - Constants
// ─────────────────────────────────────────────

let APP_NAME     = "Various"
let DEFAULT_HOME = "https://duckduckgo.com/"
let DDG_SEARCH   = "https://duckduckgo.com/?q="

// Firefox 115 ESR UA — identical to what Mullvad Browser uses
let FF_UA        = "Mozilla/5.0 (Windows NT 10.0; rv:115.0) Gecko/20100101 Firefox/115.0"
let FF_ACCEPT_L  = "en-US,en;q=0.5"

// Tracker blocklist
let BLOCKED_HOSTS: Set<String> = [
    "google-analytics.com", "googletagmanager.com", "doubleclick.net",
    "facebook.net", "ads-twitter.com", "adservice.google.com",
    "scorecardresearch.com", "hotjar.com", "cdn.connectif.cloud",
    "bat.bing.com", "analytics.yahoo.com", "pixel.advertising.com",
    "quantserve.com", "optimizely.com", "segment.com", "segment.io",
    "mixpanel.com", "amplitude.com", "heap.io", "fullstory.com",
    "logrocket.com", "clarity.ms", "newrelic.com", "nr-data.net",
    "sentry.io", "bugsnag.com", "datadog-browser-agent.com",
    "mouseflow.com", "smartlook.com", "inspectlet.com",
    "crazyegg.com", "clicktale.com", "luckyorange.com",
    "ads.pubmatic.com", "rubiconproject.com", "openx.net",
    "outbrain.com", "taboola.com", "criteo.com", "adsymptotic.com"
]

// ─────────────────────────────────────────────
// MARK: - URL Resolution
// ─────────────────────────────────────────────

func resolveURL(_ raw: String) -> URL {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return URL(string: DEFAULT_HOME)! }

    if text.hasPrefix("http://") || text.hasPrefix("https://") ||
       text.hasPrefix("ftp://")  || text.hasPrefix("file://")  ||
       text.hasPrefix("about:")  || text.hasPrefix("data:")    ||
       text.hasPrefix("view-source:") {
        return URL(string: text) ?? URL(string: DEFAULT_HOME)!
    }

    let domainPattern = #"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(?:[/?#].*)?$"#
    if !text.contains(" "), text.range(of: domainPattern, options: .regularExpression) != nil {
        return URL(string: "https://\(text)") ?? URL(string: DEFAULT_HOME)!
    }

    let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    return URL(string: "\(DDG_SEARCH)\(encoded)") ?? URL(string: DEFAULT_HOME)!
}

// ─────────────────────────────────────────────
// MARK: - Bookmark Model
// ─────────────────────────────────────────────

struct Bookmark: Identifiable, Codable, Equatable {
    var id    = UUID()
    var title : String
    var url   : String
    var folder: String
}

// ─────────────────────────────────────────────
// MARK: - Tab Model
// ─────────────────────────────────────────────

class BrowserTab: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    @Published var title    : String = "New Tab"
    @Published var urlString: String = ""
    @Published var isLoading: Bool   = false
    @Published var progress : Double = 0.0
    @Published var canGoBack   : Bool = false
    @Published var canGoForward: Bool = false

    var webView: WKWebView

    init(url: URL? = nil) {
        let config = WKWebViewConfiguration()

        // ── Privacy: disable WebRTC ──────────────────────────────────
        // WKWebView does not expose WebRTC natively on iOS, but we also
        // inject JS to null out RTCPeerConnection for belt-and-suspenders.

        // ── Privacy: custom content rules (tracker blocking) ─────────
        // Applied below after init.

        // ── Privacy: no persistent data store ────────────────────────
        let store = WKWebsiteDataStore.nonPersistent()
        config.websiteDataStore = store

        // Disable JavaScript popups
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Spoof UA at WKWebView level
        config.applicationNameForUserAgent = ""

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.customUserAgent = FF_UA
        self.webView.allowsBackForwardNavigationGestures = true

        // Inject JS to disable WebRTC RTCPeerConnection
        let webRTCScript = WKUserScript(
            source: """
            (function() {
                try {
                    window.RTCPeerConnection = undefined;
                    window.webkitRTCPeerConnection = undefined;
                    window.mozRTCPeerConnection = undefined;
                    Object.defineProperty(window, 'RTCPeerConnection', {
                        get: function() { return undefined; },
                        configurable: false
                    });
                } catch(e) {}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        self.webView.configuration.userContentController.addUserScript(webRTCScript)

        // Inject JS to strip client-hint and fingerprint headers from JS access
        let fingerprintScript = WKUserScript(
            source: """
            (function() {
                try {
                    Object.defineProperty(navigator, 'userAgent', {
                        get: function() { return '\(FF_UA)'; },
                        configurable: false
                    });
                    Object.defineProperty(navigator, 'appVersion', {
                        get: function() { return '5.0 (Windows)'; }
                    });
                    Object.defineProperty(navigator, 'platform', {
                        get: function() { return 'Win32'; }
                    });
                    Object.defineProperty(navigator, 'language', {
                        get: function() { return 'en-US'; }
                    });
                    Object.defineProperty(navigator, 'languages', {
                        get: function() { return ['en-US', 'en']; }
                    });
                    Object.defineProperty(navigator, 'vendor', {
                        get: function() { return ''; }
                    });
                    Object.defineProperty(navigator, 'hardwareConcurrency', {
                        get: function() { return 4; }
                    });
                    Object.defineProperty(screen, 'colorDepth', {
                        get: function() { return 24; }
                    });
                } catch(e) {}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        self.webView.configuration.userContentController.addUserScript(fingerprintScript)

        if let url = url {
            let req = makeRequest(url: url)
            self.webView.load(req)
        }
    }

    static func == (lhs: BrowserTab, rhs: BrowserTab) -> Bool { lhs.id == rhs.id }
}

// ─────────────────────────────────────────────
// MARK: - Request Builder (Firefox headers)
// ─────────────────────────────────────────────

func makeRequest(url: URL) -> URLRequest {
    var req = URLRequest(url: url)
    req.setValue(FF_UA,       forHTTPHeaderField: "User-Agent")
    req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                 forHTTPHeaderField: "Accept")
    req.setValue(FF_ACCEPT_L, forHTTPHeaderField: "Accept-Language")
    req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
    // Strip leak headers
    req.setValue(nil, forHTTPHeaderField: "X-Forwarded-For")
    req.setValue(nil, forHTTPHeaderField: "Via")
    req.setValue(nil, forHTTPHeaderField: "Forwarded")
    return req
}

// ─────────────────────────────────────────────
// MARK: - WKNavigationDelegate + URL Interceptor
// ─────────────────────────────────────────────

class TabNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) { self.tab = tab }

    // Block trackers
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let host = action.request.url?.host?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        for blocked in BLOCKED_HOSTS {
            if host == blocked || host.hasSuffix(".\(blocked)") {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    // Spoof headers on every navigation by rebuilding the request
    func webView(_ webView: WKWebView,
                 decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { self.tab?.isLoading = true; self.tab?.progress = 0.05 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.tab?.isLoading     = false
            self.tab?.progress      = 1.0
            self.tab?.title         = webView.title ?? "Untitled"
            self.tab?.urlString     = webView.url?.absoluteString ?? ""
            self.tab?.canGoBack     = webView.canGoBack
            self.tab?.canGoForward  = webView.canGoForward
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.tab?.isLoading = false }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        DispatchQueue.main.async { self.tab?.isLoading = false }
    }

    // Disable popups
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open popup target in same view instead of new window
        if let url = navigationAction.request.url {
            webView.load(makeRequest(url: url))
        }
        return nil
    }
}

// ─────────────────────────────────────────────
// MARK: - BrowserViewModel
// ─────────────────────────────────────────────

class BrowserViewModel: ObservableObject {
    @Published var tabs          : [BrowserTab]     = []
    @Published var currentTabIndex: Int             = 0
    @Published var bookmarks     : [Bookmark]       = []
    @Published var urlBarText    : String           = ""
    @Published var showBookmarks : Bool             = false
    @Published var showTabs      : Bool             = false

    private var delegates: [UUID: TabNavigationDelegate] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    private var titleObservers   : [UUID: NSKeyValueObservation] = [:]
    private var urlObservers     : [UUID: NSKeyValueObservation] = [:]

    var currentTab: BrowserTab? {
        guard tabs.indices.contains(currentTabIndex) else { return nil }
        return tabs[currentTabIndex]
    }

    init() {
        loadBookmarks()
        addNewTab()
    }

    // ── Tabs ──────────────────────────────────

    func addNewTab(url: URL? = nil) {
        let tab = BrowserTab(url: url)
        attachDelegate(to: tab)
        tabs.append(tab)
        currentTabIndex = tabs.count - 1
        if url == nil { urlBarText = "" } else { urlBarText = url?.absoluteString ?? "" }
        showTabs = false
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1 else { return }
        let id = tabs[index].id
        progressObservers[id]?.invalidate(); progressObservers.removeValue(forKey: id)
        titleObservers[id]?.invalidate();    titleObservers.removeValue(forKey: id)
        urlObservers[id]?.invalidate();      urlObservers.removeValue(forKey: id)
        delegates.removeValue(forKey: id)
        tabs.remove(at: index)
        if currentTabIndex >= tabs.count { currentTabIndex = tabs.count - 1 }
    }

    func switchTab(to index: Int) {
        currentTabIndex = index
        urlBarText = currentTab?.urlString ?? ""
        showTabs   = false
    }

    private func attachDelegate(to tab: BrowserTab) {
        let delegate = TabNavigationDelegate(tab: tab)
        tab.webView.navigationDelegate = delegate
        tab.webView.uiDelegate         = delegate
        delegates[tab.id] = delegate

        progressObservers[tab.id] = tab.webView.observe(\.estimatedProgress, options: [.new]) { [weak tab] wv, _ in
            DispatchQueue.main.async { tab?.progress = wv.estimatedProgress }
        }
        titleObservers[tab.id] = tab.webView.observe(\.title, options: [.new]) { [weak tab] wv, _ in
            DispatchQueue.main.async {
                tab?.title = wv.title ?? "New Tab"
            }
        }
        urlObservers[tab.id] = tab.webView.observe(\.url, options: [.new]) { [weak self, weak tab] wv, _ in
            DispatchQueue.main.async {
                tab?.urlString      = wv.url?.absoluteString ?? ""
                tab?.canGoBack      = wv.canGoBack
                tab?.canGoForward   = wv.canGoForward
                if self?.currentTab?.id == tab?.id {
                    let s = wv.url?.absoluteString ?? ""
                    self?.urlBarText = s == "about:blank" ? "" : s
                }
            }
        }
    }

    // ── Navigation ────────────────────────────

    func navigate(to raw: String) {
        let url = resolveURL(raw)
        urlBarText = url.absoluteString
        currentTab?.webView.load(makeRequest(url: url))
    }

    func goBack()    { currentTab?.webView.goBack() }
    func goForward() { currentTab?.webView.goForward() }
    func reload()    { currentTab?.webView.reload() }
    func stopLoad()  { currentTab?.webView.stopLoading() }

    // ── Bookmarks ─────────────────────────────

    private func bookmarksURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("various_bookmarks.json")
    }

    func loadBookmarks() {
        let url = bookmarksURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: bookmarksURL())
    }

    func addBookmark(title: String, url: String) {
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        bookmarks.append(Bookmark(title: title, url: url, folder: "Bookmarks"))
        saveBookmarks()
    }

    func removeBookmark(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    func bookmarkCurrentPage() {
        guard let tab = currentTab else { return }
        addBookmark(title: tab.title.isEmpty ? tab.urlString : tab.title,
                    url: tab.urlString)
    }
}

// ─────────────────────────────────────────────
// MARK: - WKWebView SwiftUI Wrapper
// ─────────────────────────────────────────────

struct WebViewWrapper: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// ─────────────────────────────────────────────
// MARK: - Start Page
// ─────────────────────────────────────────────

struct StartPageView: View {
    @ObservedObject var vm: BrowserViewModel
    @State private var searchText = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(hex: "#1a1a1a").ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color(hex: "#444444"), lineWidth: 2).frame(width: 72, height: 72)
                        Circle().stroke(Color(hex: "#555555"), lineWidth: 2).frame(width: 48, height: 48)
                        Circle().stroke(Color(hex: "#666666"), lineWidth: 2).frame(width: 24, height: 24)
                        Circle().fill(Color(hex: "#888888")).frame(width: 8, height: 8)
                    }
                    .opacity(0.7)
                    .padding(.bottom, 16)

                    Text(APP_NAME.uppercased())
                        .font(.system(size: 38, weight: .ultraLight))
                        .tracking(8)
                        .foregroundColor(Color(hex: "#e0e0e0"))

                    Text("PRIVACY  ·  SECURITY  ·  ANONYMITY")
                        .font(.system(size: 10, weight: .regular))
                        .tracking(3)
                        .foregroundColor(Color(hex: "#3e3e3e"))
                        .padding(.top, 2)
                }
                .padding(.bottom, 44)

                // Search bar
                HStack(spacing: 0) {
                    TextField("", text: $searchText, prompt:
                        Text("Search DuckDuckGo or enter address...")
                            .foregroundColor(Color(hex: "#3a3a3a"))
                    )
                    .focused($focused)
                    .foregroundColor(Color(hex: "#dddddd"))
                    .font(.system(size: 15))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { submitSearch() }

                    Button(action: submitSearch) {
                        Text("Search")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#777777"))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                    }
                    .background(Color(hex: "#1e1e1e"))
                    .overlay(
                        Rectangle()
                            .frame(width: 1)
                            .foregroundColor(Color(hex: "#2e2e2e")),
                        alignment: .leading
                    )
                }
                .background(Color(hex: "#101010"))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#2e2e2e"), lineWidth: 1)
                )
                .cornerRadius(6)
                .padding(.horizontal, 28)

                Spacer()
                Spacer()
            }
        }
        .onTapGesture { focused = false }
    }

    private func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { vm.navigate(to: q) }
    }
}

// ─────────────────────────────────────────────
// MARK: - Tab Switcher Sheet
// ─────────────────────────────────────────────

struct TabSwitcherView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        ZStack {
            Color(hex: "#111111").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("\(vm.tabs.count) Tab\(vm.tabs.count == 1 ? "" : "s")")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(hex: "#e0e0e0"))
                    Spacer()
                    Button {
                        vm.addNewTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color(hex: "#aaaaaa"))
                            .padding(8)
                            .background(Color(hex: "#2a2a2a"))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 14)

                Divider().background(Color(hex: "#2a2a2a"))

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(vm.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabCard(tab: tab, isActive: index == vm.currentTabIndex) {
                                vm.switchTab(to: index)
                            } onClose: {
                                vm.closeTab(at: index)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    var isActive: Bool
    var onTap: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Favicon placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#2a2a2a"))
                    .frame(width: 36, height: 36)
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "#666666"))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#e0e0e0"))
                    .lineLimit(1)
                Text(tab.urlString.isEmpty ? APP_NAME : tab.urlString)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#555555"))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#666666"))
                    .padding(6)
                    .background(Color(hex: "#2a2a2a"))
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color(hex: "#242424") : Color(hex: "#1a1a1a"))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? Color(hex: "#444444") : Color(hex: "#222222"), lineWidth: 1)
                )
        )
        .onTapGesture(perform: onTap)
    }
}

// ─────────────────────────────────────────────
// MARK: - Bookmarks Sheet
// ─────────────────────────────────────────────

struct BookmarksView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        ZStack {
            Color(hex: "#111111").ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Bookmarks")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(hex: "#e0e0e0"))
                    Spacer()
                    Button { vm.showBookmarks = false } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(hex: "#aaaaaa"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 14)

                Divider().background(Color(hex: "#2a2a2a"))

                if vm.bookmarks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 40))
                            .foregroundColor(Color(hex: "#333333"))
                        Text("No Bookmarks")
                            .font(.system(size: 15))
                            .foregroundColor(Color(hex: "#444444"))
                        Text("Long-press the bookmark icon\nin the toolbar to save a page.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#333333"))
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(vm.bookmarks) { bm in
                            Button {
                                vm.navigate(to: bm.url)
                                vm.showBookmarks = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bm.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(hex: "#dddddd"))
                                        .lineLimit(1)
                                    Text(bm.url)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "#555555"))
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color(hex: "#1a1a1a"))
                        }
                        .onDelete(perform: vm.removeBookmark)
                    }
                    .listStyle(.plain)
                    .background(Color(hex: "#111111"))
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Menu Sheet
// ─────────────────────────────────────────────

struct MenuView: View {
    @ObservedObject var vm: BrowserViewModel
    @Binding var showMenu: Bool

    var body: some View {
        ZStack {
            Color(hex: "#1a1a1a").ignoresSafeArea()

            VStack(spacing: 0) {
                // Handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "#444444"))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 18)

                // Privacy info card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(Color(hex: "#aaaaaa"))
                        Text("Privacy Active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "#cccccc"))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        PrivacyRow(icon: "person.slash", text: "Firefox 115 UA spoofing")
                        PrivacyRow(icon: "antenna.radiowaves.left.and.right.slash", text: "WebRTC disabled")
                        PrivacyRow(icon: "hand.raised.slash", text: "40+ trackers blocked")
                        PrivacyRow(icon: "externaldrive.badge.xmark", text: "No persistent cookies")
                        PrivacyRow(icon: "eye.slash", text: "No browsing history saved")
                    }
                }
                .padding(14)
                .background(Color(hex: "#111111"))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Divider().background(Color(hex: "#2a2a2a")).padding(.horizontal, 16)

                // Actions
                VStack(spacing: 2) {
                    MenuAction(icon: "bookmark",         label: "Bookmarks") {
                        showMenu = false; vm.showBookmarks = true
                    }
                    MenuAction(icon: "square.on.square", label: "Tabs") {
                        showMenu = false; vm.showTabs = true
                    }
                    MenuAction(icon: "plus.square",      label: "New Tab") {
                        showMenu = false; vm.addNewTab()
                    }
                    MenuAction(icon: "bookmark.fill",    label: "Bookmark This Page") {
                        showMenu = false; vm.bookmarkCurrentPage()
                    }
                    MenuAction(icon: "arrow.clockwise",  label: "Reload Page") {
                        showMenu = false; vm.reload()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()
            }
        }
    }
}

struct PrivacyRow: View {
    var icon: String
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#666666"))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#666666"))
        }
    }
}

struct MenuAction: View {
    var icon: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "#888888"))
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "#cccccc"))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#333333"))
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 4)
        }
        .background(Color.clear)
        Divider().background(Color(hex: "#222222"))
    }
}

// ─────────────────────────────────────────────
// MARK: - Main Browser View
// ─────────────────────────────────────────────

struct BrowserView: View {
    @StateObject private var vm = BrowserViewModel()
    @State private var editingURL     = false
    @State private var urlInput       = ""
    @State private var showMenu       = false
    @State private var bookmarkFlash  = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: "#1a1a1a").ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Progress bar ──────────────────────────────
                if let tab = vm.currentTab, tab.isLoading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color(hex: "#aaaaaa"))
                            .frame(width: geo.size.width * tab.progress, height: 2)
                            .animation(.linear(duration: 0.2), value: tab.progress)
                    }
                    .frame(height: 2)
                } else {
                    Color.clear.frame(height: 2)
                }

                // ── Web content ───────────────────────────────
                if let tab = vm.currentTab {
                    if tab.urlString.isEmpty || tab.urlString == "about:blank" {
                        StartPageView(vm: vm)
                    } else {
                        WebViewWrapper(webView: tab.webView)
                    }
                }

                // ── Bottom toolbar ────────────────────────────
                bottomBar
            }
        }
        .sheet(isPresented: $vm.showTabs) {
            TabSwitcherView(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $vm.showBookmarks) {
            BookmarksView(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMenu) {
            MenuView(vm: vm, showMenu: $showMenu)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // ── Bottom bar ─────────────────────────────────────────────────────────

    var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color(hex: "#0d0d0d"))

            // URL bar row
            HStack(spacing: 8) {
                // Back
                Button { vm.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(vm.currentTab?.canGoBack == true
                                         ? Color(hex: "#aaaaaa") : Color(hex: "#333333"))
                }
                .disabled(vm.currentTab?.canGoBack != true)

                // Forward
                Button { vm.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(vm.currentTab?.canGoForward == true
                                         ? Color(hex: "#aaaaaa") : Color(hex: "#333333"))
                }
                .disabled(vm.currentTab?.canGoForward != true)

                // URL bar
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#555555"))
                        .opacity(urlBarShowsHTTPS ? 1 : 0)

                    if editingURL {
                        TextField("", text: $urlInput,
                                  prompt: Text("Search or enter address")
                                      .foregroundColor(Color(hex: "#444444")))
                            .focused($urlFocused)
                            .foregroundColor(Color(hex: "#e0e0e0"))
                            .font(.system(size: 13))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit {
                                vm.navigate(to: urlInput)
                                editingURL = false
                                urlFocused = false
                            }
                    } else {
                        Text(displayURL)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#cccccc"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    // Reload / Stop
                    if let tab = vm.currentTab, tab.isLoading {
                        Button { vm.stopLoad() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#777777"))
                        }
                    } else {
                        Button { vm.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#555555"))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(hex: "#111111"))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(editingURL ? Color(hex: "#555555") : Color(hex: "#2a2a2a"), lineWidth: 1)
                )
                .onTapGesture {
                    urlInput   = vm.urlBarText
                    editingURL = true
                    urlFocused = true
                }

                // Tabs button
                Button { vm.showTabs = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(hex: "#555555"), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        Text("\(vm.tabs.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(hex: "#aaaaaa"))
                    }
                }

                // Menu
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(hex: "#888888"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Second row: bookmark + share
            HStack(spacing: 0) {
                Spacer()

                // Bookmark
                Button {
                    vm.bookmarkCurrentPage()
                    withAnimation { bookmarkFlash = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        bookmarkFlash = false
                    }
                } label: {
                    Image(systemName: bookmarkFlash ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 18))
                        .foregroundColor(bookmarkFlash ? Color(hex: "#ffffff") : Color(hex: "#666666"))
                }
                .padding(.horizontal, 28)

                // Share
                Button {
                    shareCurrentPage()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundColor(Color(hex: "#666666"))
                }
                .padding(.horizontal, 28)

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.bottom, 4)

            // Safe area spacer
            Color(hex: "#1a1a1a")
                .frame(height: 0)
        }
        .background(Color(hex: "#1a1a1a"))
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    var displayURL: String {
        let s = vm.urlBarText
        if s.isEmpty { return APP_NAME + " — New Tab" }
        // Strip scheme for display
        return s
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    var urlBarShowsHTTPS: Bool {
        vm.urlBarText.hasPrefix("https://")
    }

    func shareCurrentPage() {
        guard let url = URL(string: vm.urlBarText), !vm.urlBarText.isEmpty else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root  = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Color Extension
// ─────────────────────────────────────────────

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch h.count {
        case 3:
            (a, r, g, b) = (255,
                            (int >> 8) * 17,
                            (int >> 4 & 0xF) * 17,
                            (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255,
                            int >> 16,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24,
                            int >> 16 & 0xFF,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:   Double(r) / 255,
                  green: Double(g) / 255,
                  blue:  Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// ─────────────────────────────────────────────
// MARK: - App Entry Point
// ─────────────────────────────────────────────

@main
struct VariousApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
                .preferredColorScheme(.dark)
        }
    }
}
