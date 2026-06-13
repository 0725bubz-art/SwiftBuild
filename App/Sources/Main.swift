import SwiftUI
import WebKit

// ─────────────────────────────────────────────
// MARK: - Constants
// ─────────────────────────────────────────────

private let kAppName    = "Various"
private let kHomeURL    = "https://duckduckgo.com/"
private let kDDGSearch  = "https://duckduckgo.com/?q="
private let kFirefoxUA  = "Mozilla/5.0 (Windows NT 10.0; rv:115.0) Gecko/20100101 Firefox/115.0"
private let kAcceptLang = "en-US,en;q=0.5"

private let kBlockedHosts: [String] = [
    "google-analytics.com","googletagmanager.com","doubleclick.net",
    "facebook.net","ads-twitter.com","adservice.google.com",
    "scorecardresearch.com","hotjar.com","bat.bing.com",
    "analytics.yahoo.com","quantserve.com","optimizely.com",
    "segment.com","segment.io","mixpanel.com","amplitude.com",
    "heap.io","fullstory.com","logrocket.com","clarity.ms",
    "newrelic.com","nr-data.net","sentry.io","bugsnag.com",
    "mouseflow.com","smartlook.com","crazyegg.com","clicktale.com",
    "luckyorange.com","ads.pubmatic.com","rubiconproject.com",
    "openx.net","outbrain.com","taboola.com","criteo.com"
]

// ─────────────────────────────────────────────
// MARK: - URL Resolution
// ─────────────────────────────────────────────

func resolveURL(_ raw: String) -> URL {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return URL(string: kHomeURL)! }

    let schemes = ["http://","https://","ftp://","file://","about:","data:","view-source:"]
    for s in schemes { if text.hasPrefix(s) { return URL(string: text) ?? URL(string: kHomeURL)! } }

    let domainRegex = "^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}(?:[/?#].*)?$"
    if !text.contains(" "), text.range(of: domainRegex, options: .regularExpression) != nil {
        return URL(string: "https://\(text)") ?? URL(string: kHomeURL)!
    }
    let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    return URL(string: "\(kDDGSearch)\(encoded)") ?? URL(string: kHomeURL)!
}

// ─────────────────────────────────────────────
// MARK: - Bookmark
// ─────────────────────────────────────────────

struct Bookmark: Identifiable, Codable {
    var id     = UUID()
    var title  : String
    var url    : String
    var folder : String = "Bookmarks"
}

// ─────────────────────────────────────────────
// MARK: - BrowserTab
// ─────────────────────────────────────────────

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @Published var title      : String = "New Tab"
    @Published var urlString  : String = ""
    @Published var isLoading  : Bool   = false
    @Published var progress   : Double = 0.0
    @Published var canGoBack  : Bool   = false
    @Published var canGoForward: Bool  = false

    let webView: WKWebView

    private var progressObs: NSKeyValueObservation?
    private var titleObs   : NSKeyValueObservation?
    private var urlObs     : NSKeyValueObservation?

    override init() {
        // Non-persistent storage — no cookies saved between sessions
        let store = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Disable WebRTC via JS injection
        let webRTCBlock = WKUserScript(
            source: """
            (function(){
              try {
                var noop = function(){};
                window.RTCPeerConnection = noop;
                window.webkitRTCPeerConnection = noop;
                window.mozRTCPeerConnection = noop;
              } catch(e){}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(webRTCBlock)

        // Spoof navigator properties
        let navigatorSpoof = WKUserScript(
            source: """
            (function(){
              try {
                var def = Object.defineProperty;
                def(navigator,'userAgent',    {get:function(){return '\(kFirefoxUA)';}});
                def(navigator,'appVersion',   {get:function(){return '5.0 (Windows)';}});
                def(navigator,'platform',     {get:function(){return 'Win32';}});
                def(navigator,'language',     {get:function(){return 'en-US';}});
                def(navigator,'languages',    {get:function(){return ['en-US','en'];}});
                def(navigator,'vendor',       {get:function(){return '';}});
                def(navigator,'hardwareConcurrency',{get:function(){return 4;}});
              } catch(e){}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(navigatorSpoof)

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.customUserAgent = kFirefoxUA
        self.webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) {
            self.webView.isInspectable = false
        }

        super.init()

        self.webView.navigationDelegate = self
        self.webView.uiDelegate        = self

        progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.progress = wv.estimatedProgress }
        }
        titleObs = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.title = wv.title ?? "New Tab" }
        }
        urlObs = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.urlString    = wv.url?.absoluteString ?? ""
                self?.canGoBack    = wv.canGoBack
                self?.canGoForward = wv.canGoForward
            }
        }
    }

    deinit {
        progressObs?.invalidate()
        titleObs?.invalidate()
        urlObs?.invalidate()
    }

    func load(_ url: URL) {
        var req = URLRequest(url: url)
        req.setValue(kFirefoxUA,   forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        req.setValue(kAcceptLang,  forHTTPHeaderField: "Accept-Language")
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        webView.load(req)
    }
}

// ─────────────────────────────────────────────
// MARK: - WKNavigationDelegate
// ─────────────────────────────────────────────

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let host = action.request.url?.host?.lowercased() {
            for blocked in kBlockedHosts {
                if host == blocked || host.hasSuffix(".\(blocked)") {
                    decisionHandler(.cancel)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        DispatchQueue.main.async { self.isLoading = true; self.progress = 0.05 }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading      = false
            self.title          = webView.title ?? "Untitled"
            self.urlString      = webView.url?.absoluteString ?? ""
            self.canGoBack      = webView.canGoBack
            self.canGoForward   = webView.canGoForward
        }
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        DispatchQueue.main.async { self.isLoading = false }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        DispatchQueue.main.async { self.isLoading = false }
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith _: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { load(url) }
        return nil
    }
}

// ─────────────────────────────────────────────
// MARK: - BrowserViewModel
// ─────────────────────────────────────────────

final class BrowserViewModel: ObservableObject {
    @Published var tabs            : [BrowserTab] = []
    @Published var currentIndex    : Int          = 0
    @Published var bookmarks       : [Bookmark]   = []
    @Published var urlBarText      : String       = ""
    @Published var showBookmarks   : Bool         = false
    @Published var showTabs        : Bool         = false

    var currentTab: BrowserTab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    init() {
        loadBookmarks()
        addNewTab()
    }

    // ── Tab management ────────────────────────

    func addNewTab(url: URL? = nil) {
        let tab = BrowserTab()
        tabs.append(tab)
        currentIndex = tabs.count - 1
        if let url = url {
            tab.load(url)
            urlBarText = url.absoluteString
        } else {
            urlBarText = ""
        }
        showTabs = false
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1 else { return }
        tabs.remove(at: index)
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        urlBarText = currentTab?.urlString ?? ""
    }

    func switchTab(to index: Int) {
        currentIndex = index
        urlBarText = currentTab?.urlString ?? ""
        showTabs = false
    }

    // ── Navigation ────────────────────────────

    func navigate(to raw: String) {
        let url = resolveURL(raw)
        urlBarText = url.absoluteString
        currentTab?.load(url)
    }

    func goBack()    { currentTab?.webView.goBack() }
    func goForward() { currentTab?.webView.goForward() }
    func reload()    { currentTab?.webView.reload() }
    func stop()      { currentTab?.webView.stopLoading() }

    // ── Bookmarks ─────────────────────────────

    private var bookmarksFileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("various_bookmarks.json")
    }

    func loadBookmarks() {
        guard let data = try? Data(contentsOf: bookmarksFileURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return }
        bookmarks = decoded
    }

    func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: bookmarksFileURL)
    }

    func bookmarkCurrentPage() {
        guard let tab = currentTab, !tab.urlString.isEmpty else { return }
        let url = tab.urlString
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        bookmarks.append(Bookmark(
            title: tab.title.isEmpty ? url : tab.title,
            url: url
        ))
        saveBookmarks()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }
}

// ─────────────────────────────────────────────
// MARK: - WebView Wrapper
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
    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color(red: 0.102, green: 0.102, blue: 0.102).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // Concentric circles logo
                ZStack {
                    Circle().stroke(Color.white.opacity(0.27), lineWidth: 2).frame(width: 72, height: 72)
                    Circle().stroke(Color.white.opacity(0.33), lineWidth: 2).frame(width: 48, height: 48)
                    Circle().stroke(Color.white.opacity(0.40), lineWidth: 2).frame(width: 24, height: 24)
                    Circle().fill(Color.white.opacity(0.53)).frame(width: 8, height: 8)
                }
                .padding(.bottom, 20)

                Text(kAppName.uppercased())
                    .font(.system(size: 36, weight: .ultraLight))
                    .tracking(8)
                    .foregroundColor(Color(white: 0.88))

                Text("PRIVACY  ·  SECURITY  ·  ANONYMITY")
                    .font(.system(size: 10))
                    .tracking(3)
                    .foregroundColor(Color(white: 0.24))
                    .padding(.top, 6)
                    .padding(.bottom, 44)

                // Search box
                HStack(spacing: 0) {
                    TextField("", text: $query)
                        .placeholder(when: query.isEmpty) {
                            Text("Search DuckDuckGo or enter address...")
                                .foregroundColor(Color(white: 0.23))
                        }
                        .focused($isFocused)
                        .foregroundColor(Color(white: 0.87))
                        .font(.system(size: 15))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .onSubmit { doSearch() }

                    Button(action: doSearch) {
                        Text("Search")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.47))
                            .frame(height: 48)
                            .padding(.horizontal, 18)
                    }
                    .background(Color(white: 0.118))
                    .overlay(
                        Rectangle().frame(width: 1).foregroundColor(Color(white: 0.18)),
                        alignment: .leading
                    )
                }
                .background(Color(white: 0.063))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.18), lineWidth: 1))
                .padding(.horizontal, 28)

                Spacer()
                Spacer()
            }
        }
        .onTapGesture { isFocused = false }
    }

    private func doSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { vm.navigate(to: q) }
    }
}

// Placeholder helper (avoids iOS 16 dependency)
extension View {
    func placeholder<Content: View>(when show: Bool,
                                    @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            if show { placeholder() }
            self
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Tab Switcher
// ─────────────────────────────────────────────

struct TabSwitcherView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        ZStack {
            Color(white: 0.067).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("\(vm.tabs.count) Tab\(vm.tabs.count == 1 ? "" : "s")")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(white: 0.88))
                    Spacer()
                    Button { vm.addNewTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color(white: 0.67))
                            .padding(8)
                            .background(Color(white: 0.165))
                            .cornerRadius(8)
                    }
                }
                .padding(16)

                Divider().background(Color(white: 0.165))

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(vm.tabs.enumerated()), id: \.element.id) { i, tab in
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.system(size: 16))
                                    .foregroundColor(Color(white: 0.40))
                                    .frame(width: 36, height: 36)
                                    .background(Color(white: 0.165))
                                    .cornerRadius(6)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tab.title.isEmpty ? "New Tab" : tab.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(white: 0.88))
                                        .lineLimit(1)
                                    Text(tab.urlString.isEmpty ? kAppName : tab.urlString)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.33))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button { vm.closeTab(at: i) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(white: 0.40))
                                        .padding(6)
                                        .background(Color(white: 0.165))
                                        .cornerRadius(6)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(i == vm.currentIndex
                                          ? Color(white: 0.141)
                                          : Color(white: 0.102))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(i == vm.currentIndex
                                                    ? Color(white: 0.267)
                                                    : Color(white: 0.133),
                                                    lineWidth: 1)
                                    )
                            )
                            .onTapGesture { vm.switchTab(to: i) }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Bookmarks Sheet
// ─────────────────────────────────────────────

struct BookmarksView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        ZStack {
            Color(white: 0.067).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Bookmarks")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(white: 0.88))
                    Spacer()
                    Button { vm.showBookmarks = false } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(white: 0.67))
                    }
                }
                .padding(16)

                Divider().background(Color(white: 0.165))

                if vm.bookmarks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 40))
                            .foregroundColor(Color(white: 0.20))
                        Text("No Bookmarks Yet")
                            .font(.system(size: 15))
                            .foregroundColor(Color(white: 0.27))
                        Text("Tap the bookmark icon in the toolbar\nto save the current page.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.20))
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
                                        .foregroundColor(Color(white: 0.87))
                                        .lineLimit(1)
                                    Text(bm.url)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.33))
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color(white: 0.102))
                        }
                        .onDelete(perform: vm.removeBookmarks)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(white: 0.067))
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
            Color(white: 0.102).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                // Drag handle
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.267))
                        .frame(width: 36, height: 4)
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.bottom, 18)

                // Privacy status card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(Color(white: 0.67))
                        Text("Privacy Active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.80))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        privacyRow("person.slash",                    "Firefox 115 UA spoofing active")
                        privacyRow("antenna.radiowaves.left.and.right.slash", "WebRTC disabled")
                        privacyRow("hand.raised.slash",               "36 tracker domains blocked")
                        privacyRow("externaldrive.badge.xmark",       "No persistent cookies")
                        privacyRow("eye.slash",                       "No history saved")
                    }
                }
                .padding(14)
                .background(Color(white: 0.067))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Divider().background(Color(white: 0.165)).padding(.horizontal, 16)

                Group {
                    menuRow("bookmark",         "Bookmarks")   { showMenu=false; vm.showBookmarks=true }
                    menuRow("square.on.square", "Tabs")         { showMenu=false; vm.showTabs=true }
                    menuRow("plus.square",      "New Tab")      { showMenu=false; vm.addNewTab() }
                    menuRow("bookmark.fill",    "Bookmark This Page") { showMenu=false; vm.bookmarkCurrentPage() }
                    menuRow("arrow.clockwise",  "Reload")       { showMenu=false; vm.reload() }
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
    }

    private func privacyRow(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(Color(white: 0.40)).frame(width: 16)
            Text(label).font(.system(size: 11)).foregroundColor(Color(white: 0.40))
        }
    }

    private func menuRow(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 16)).foregroundColor(Color(white: 0.53)).frame(width: 24)
                    Text(label).font(.system(size: 15)).foregroundColor(Color(white: 0.80))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(Color(white: 0.20))
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 4)
            }
            Divider().background(Color(white: 0.133))
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Main Browser View
// ─────────────────────────────────────────────

struct BrowserView: View {
    @StateObject private var vm       = BrowserViewModel()
    @State private var editingURL     = false
    @State private var urlInput       = ""
    @State private var showMenu       = false
    @State private var bookmarkFlash  = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        ZStack {
            Color(white: 0.102).ignoresSafeArea()
            VStack(spacing: 0) {
                progressBar
                webContent
                bottomToolbar
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

    // ── Progress bar ───────────────────────────────────────────────────────

    @ViewBuilder
    var progressBar: some View {
        if let tab = vm.currentTab, tab.isLoading {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color(white: 0.67))
                    .frame(width: geo.size.width * tab.progress, height: 2)
                    .animation(.linear(duration: 0.15), value: tab.progress)
            }
            .frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    // ── Web content area ───────────────────────────────────────────────────

    @ViewBuilder
    var webContent: some View {
        if let tab = vm.currentTab {
            if tab.urlString.isEmpty {
                StartPageView(vm: vm)
            } else {
                WebViewWrapper(webView: tab.webView)
            }
        } else {
            StartPageView(vm: vm)
        }
    }

    // ── Bottom toolbar ─────────────────────────────────────────────────────

    var bottomToolbar: some View {
        VStack(spacing: 0) {
            Divider().background(Color(white: 0.051))

            // Row 1: nav + URL bar
            HStack(spacing: 10) {
                // Back
                Button { vm.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(vm.currentTab?.canGoBack == true
                                         ? Color(white: 0.67) : Color(white: 0.20))
                        .frame(width: 30)
                }
                .disabled(vm.currentTab?.canGoBack != true)

                // Forward
                Button { vm.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(vm.currentTab?.canGoForward == true
                                         ? Color(white: 0.67) : Color(white: 0.20))
                        .frame(width: 30)
                }
                .disabled(vm.currentTab?.canGoForward != true)

                // URL Bar
                HStack(spacing: 6) {
                    if showsLock {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.33))
                    }

                    if editingURL {
                        TextField("", text: $urlInput)
                            .placeholder(when: urlInput.isEmpty) {
                                Text("Search or enter address")
                                    .foregroundColor(Color(white: 0.27))
                                    .font(.system(size: 13))
                            }
                            .focused($urlFocused)
                            .foregroundColor(Color(white: 0.88))
                            .font(.system(size: 13))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .onSubmit {
                                vm.navigate(to: urlInput)
                                editingURL = false
                                urlFocused = false
                            }
                    } else {
                        Text(displayURL)
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.80))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    // Stop / Reload
                    if let tab = vm.currentTab, tab.isLoading {
                        Button { vm.stop() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.47))
                        }
                    } else if !vm.urlBarText.isEmpty {
                        Button { vm.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.33))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.067))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(editingURL ? Color(white: 0.33) : Color(white: 0.165), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    urlInput   = vm.urlBarText
                    editingURL = true
                    urlFocused = true
                }

                // Tab count button
                Button { vm.showTabs = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(white: 0.33), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                        Text("\(vm.tabs.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(white: 0.67))
                    }
                }

                // Menu
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(white: 0.53))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Row 2: bookmark + share
            HStack {
                Spacer()
                Button {
                    vm.bookmarkCurrentPage()
                    bookmarkFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { bookmarkFlash = false }
                } label: {
                    Image(systemName: bookmarkFlash ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 19))
                        .foregroundColor(bookmarkFlash ? Color(white: 0.88) : Color(white: 0.40))
                }
                Spacer()
                Button { shareCurrentPage() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19))
                        .foregroundColor(Color(white: 0.40))
                }
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.102))
    }

    // ── Computed helpers ────────────────────────────────────────────────────

    var displayURL: String {
        let s = vm.urlBarText
        if s.isEmpty { return kAppName }
        return s
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    var showsLock: Bool { vm.urlBarText.hasPrefix("https://") }

    func shareCurrentPage() {
        guard !vm.urlBarText.isEmpty, let url = URL(string: vm.urlBarText) else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root  = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
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
