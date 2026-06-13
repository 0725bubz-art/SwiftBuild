import SwiftUI
import WebKit

// MARK: - Constants

private let kAppName   = "Various"
private let kHomeURL   = "https://duckduckgo.com/"
private let kDDGSearch = "https://duckduckgo.com/?q="
private let kFirefoxUA = "Mozilla/5.0 (Windows NT 10.0; rv:115.0) Gecko/20100101 Firefox/115.0"
private let kAcceptLang = "en-US,en;q=0.5"

private let kBlockedHosts: [String] = [
    "google-analytics.com", "googletagmanager.com", "doubleclick.net",
    "facebook.net", "ads-twitter.com", "adservice.google.com",
    "scorecardresearch.com", "hotjar.com", "bat.bing.com",
    "analytics.yahoo.com", "quantserve.com", "optimizely.com",
    "segment.com", "segment.io", "mixpanel.com", "amplitude.com",
    "heap.io", "fullstory.com", "logrocket.com", "clarity.ms",
    "newrelic.com", "nr-data.net", "sentry.io", "bugsnag.com",
    "mouseflow.com", "smartlook.com", "crazyegg.com", "clicktale.com",
    "luckyorange.com", "ads.pubmatic.com", "rubiconproject.com",
    "openx.net", "outbrain.com", "taboola.com", "criteo.com"
]

private let kWebRTCScript = """
(function(){
  try {
    window.RTCPeerConnection = undefined;
    window.webkitRTCPeerConnection = undefined;
    window.mozRTCPeerConnection = undefined;
    Object.defineProperty(window,'RTCPeerConnection',{
      get:function(){return undefined;},configurable:false
    });
  } catch(e){}
})();
"""

private let kSpoofScript = """
(function(){
  try {
    var d=Object.defineProperty;
    d(navigator,'userAgent',{get:function(){return 'Mozilla/5.0 (Windows NT 10.0; rv:115.0) Gecko/20100101 Firefox/115.0';}});
    d(navigator,'appVersion',{get:function(){return '5.0 (Windows)';}});
    d(navigator,'platform',{get:function(){return 'Win32';}});
    d(navigator,'language',{get:function(){return 'en-US';}});
    d(navigator,'languages',{get:function(){return ['en-US','en'];}});
    d(navigator,'vendor',{get:function(){return '';}});
    d(navigator,'hardwareConcurrency',{get:function(){return 4;}});
  } catch(e){}
})();
"""

// MARK: - URL Resolution

private func resolveURL(_ raw: String) -> URL {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return URL(string: kHomeURL)! }
    let schemes = ["http://","https://","ftp://","file://","about:","data:"]
    for s in schemes {
        if text.hasPrefix(s) {
            return URL(string: text) ?? URL(string: kHomeURL)!
        }
    }
    let pat = "^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}(?:[/?#].*)?$"
    if !text.contains(" "),
       text.range(of: pat, options: .regularExpression) != nil {
        return URL(string: "https://\(text)") ?? URL(string: kHomeURL)!
    }
    let enc = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    return URL(string: "\(kDDGSearch)\(enc)") ?? URL(string: kHomeURL)!
}

// MARK: - Bookmark Model

private struct Bookmark: Identifiable, Codable {
    var id    = UUID()
    var title : String
    var url   : String
    var folder: String = "Bookmarks"
}

// MARK: - BrowserTab

private final class BrowserTab: NSObject, ObservableObject, Identifiable {

    let id = UUID()

    @Published var title       = "New Tab"
    @Published var urlString   = ""
    @Published var isLoading   = false
    @Published var progress    = 0.0
    @Published var canGoBack   = false
    @Published var canGoFwd    = false

    let webView: WKWebView

    private var obsProgress : NSKeyValueObservation?
    private var obsTitle    : NSKeyValueObservation?
    private var obsURL      : NSKeyValueObservation?
    private var obsLoading  : NSKeyValueObservation?

    override init() {
        let store  = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let uc = config.userContentController
        uc.addUserScript(WKUserScript(
            source: kWebRTCScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        uc.addUserScript(WKUserScript(
            source: kSpoofScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = kFirefoxUA
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv

        super.init()

        wv.navigationDelegate = self
        wv.uiDelegate         = self

        obsProgress = wv.observe(\.estimatedProgress, options: [.new]) {
            [weak self] w, _ in
            DispatchQueue.main.async { self?.progress = w.estimatedProgress }
        }
        obsTitle = wv.observe(\.title, options: [.new]) {
            [weak self] w, _ in
            DispatchQueue.main.async { self?.title = w.title ?? "New Tab" }
        }
        obsURL = wv.observe(\.url, options: [.new]) {
            [weak self] w, _ in
            DispatchQueue.main.async {
                let s = w.url?.absoluteString ?? ""
                self?.urlString   = (s == "about:blank") ? "" : s
                self?.canGoBack   = w.canGoBack
                self?.canGoFwd    = w.canGoForward
            }
        }
        obsLoading = wv.observe(\.isLoading, options: [.new]) {
            [weak self] w, _ in
            DispatchQueue.main.async { self?.isLoading = w.isLoading }
        }
    }

    deinit {
        obsProgress?.invalidate()
        obsTitle?.invalidate()
        obsURL?.invalidate()
        obsLoading?.invalidate()
    }

    func load(_ url: URL) {
        var req = URLRequest(url: url)
        req.setValue(kFirefoxUA, forHTTPHeaderField: "User-Agent")
        req.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        req.setValue(kAcceptLang,        forHTTPHeaderField: "Accept-Language")
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        webView.load(req)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
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
        DispatchQueue.main.async {
            self.isLoading = true
            self.progress  = 0.05
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = false
            self.title     = webView.title?.isEmpty == false ? webView.title! : "Untitled"
            self.urlString = webView.url?.absoluteString ?? ""
            self.canGoBack = webView.canGoBack
            self.canGoFwd  = webView.canGoForward
        }
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        DispatchQueue.main.async { self.isLoading = false }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        DispatchQueue.main.async { self.isLoading = false }
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url { load(url) }
        return nil
    }
}

// MARK: - BrowserViewModel

private final class BrowserViewModel: ObservableObject {
    @Published var tabs          : [BrowserTab] = []
    @Published var currentIndex  : Int          = 0
    @Published var bookmarks     : [Bookmark]   = []
    @Published var urlBarText    : String       = ""
    @Published var showBookmarks : Bool         = false
    @Published var showTabs      : Bool         = false

    var currentTab: BrowserTab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    init() {
        loadBookmarks()
        addNewTab()
    }

    // MARK: Tabs

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
        urlBarText   = currentTab?.urlString ?? ""
        showTabs     = false
    }

    func syncURLBar() {
        urlBarText = currentTab?.urlString ?? ""
    }

    // MARK: Navigation

    func navigate(to raw: String) {
        let url    = resolveURL(raw)
        urlBarText = url.absoluteString
        currentTab?.load(url)
    }

    func goBack()    { currentTab?.webView.goBack() }
    func goForward() { currentTab?.webView.goForward() }
    func reload()    { currentTab?.webView.reload() }
    func stop()      { currentTab?.webView.stopLoading() }

    // MARK: Bookmarks

    private var bookmarksFile: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("various_bookmarks.json")
    }

    func loadBookmarks() {
        guard let data    = try? Data(contentsOf: bookmarksFile),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return }
        bookmarks = decoded
    }

    func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: bookmarksFile)
    }

    func bookmarkCurrentPage() {
        guard let tab = currentTab, !tab.urlString.isEmpty else { return }
        let url = tab.urlString
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        bookmarks.append(Bookmark(
            title: tab.title.isEmpty ? url : tab.title,
            url: url))
        saveBookmarks()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }
}

// MARK: - WebView Wrapper

private struct WebViewWrapper: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Colours (no extension, no hex parsing)

private enum C {
    static let bg        = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let bgDeep    = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let bgCard    = Color(red: 0.141, green: 0.141, blue: 0.141)
    static let border    = Color(white: 0.165)
    static let borderHi  = Color(white: 0.267)
    static let textPri   = Color(white: 0.88)
    static let textSec   = Color(white: 0.53)
    static let textDim   = Color(white: 0.33)
    static let textFaint = Color(white: 0.20)
    static let accent    = Color(white: 0.67)
    static let divider   = Color(white: 0.133)
}

// MARK: - Start Page

private struct StartPageView: View {
    @ObservedObject var vm: BrowserViewModel
    @State private var query = ""

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                logo
                searchBox
                Spacer()
                Spacer()
            }
        }
    }

    private var logo: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.27), lineWidth: 2).frame(width: 72, height: 72)
                Circle().stroke(Color.white.opacity(0.33), lineWidth: 2).frame(width: 48, height: 48)
                Circle().stroke(Color.white.opacity(0.40), lineWidth: 2).frame(width: 24, height: 24)
                Circle().fill(Color.white.opacity(0.53)).frame(width: 8,  height: 8)
            }
            .opacity(0.75)
            .padding(.bottom, 20)

            Text(kAppName.uppercased())
                .font(.system(size: 36, weight: .ultraLight))
                .tracking(8)
                .foregroundColor(C.textPri)

            Text("PRIVACY  ·  SECURITY  ·  ANONYMITY")
                .font(.system(size: 10))
                .tracking(3)
                .foregroundColor(C.textFaint)
                .padding(.top, 6)
                .padding(.bottom, 44)
        }
    }

    private var searchBox: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search DuckDuckGo or enter address...")
                        .foregroundColor(Color(white: 0.23))
                        .font(.system(size: 15))
                        .padding(.leading, 16)
                }
                TextField("", text: $query)
                    .foregroundColor(C.textPri)
                    .font(.system(size: 15))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .onSubmit { doSearch() }
            }

            Button(action: doSearch) {
                Text("Search")
                    .font(.system(size: 13))
                    .foregroundColor(C.textSec)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
            }
            .background(C.bgCard)
            .overlay(
                Rectangle()
                    .frame(width: 1)
                    .foregroundColor(C.border),
                alignment: .leading
            )
        }
        .background(C.bgDeep)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(C.border, lineWidth: 1))
        .padding(.horizontal, 28)
    }

    private func doSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        vm.navigate(to: q)
    }
}

// MARK: - Tab Switcher

private struct TabSwitcherView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        ZStack {
            C.bgDeep.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(C.border)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(vm.tabs.enumerated()), id: \.element.id) { i, tab in
                            tabCard(index: i, tab: tab)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(vm.tabs.count) Tab\(vm.tabs.count == 1 ? "" : "s")")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(C.textPri)
            Spacer()
            Button {
                vm.addNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(C.accent)
                    .padding(8)
                    .background(C.bgCard)
                    .cornerRadius(8)
            }
        }
        .padding(16)
    }

    private func tabCard(index: Int, tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 16))
                .foregroundColor(C.textDim)
                .frame(width: 36, height: 36)
                .background(C.bgCard)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.textPri)
                    .lineLimit(1)
                Text(tab.urlString.isEmpty ? kAppName : tab.urlString)
                    .font(.system(size: 11))
                    .foregroundColor(C.textDim)
                    .lineLimit(1)
            }
            Spacer()

            Button {
                vm.closeTab(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(C.textSec)
                    .padding(6)
                    .background(C.bgCard)
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(index == vm.currentIndex ? C.bgCard : C.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            index == vm.currentIndex ? C.borderHi : C.border,
                            lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.switchTab(to: index) }
    }
}

// MARK: - Bookmarks Sheet

private struct BookmarksView: View {
    @ObservedObject var vm: BrowserViewModel

    var body: some View {
        ZStack {
            C.bgDeep.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Bookmarks")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(C.textPri)
                    Spacer()
                    Button { vm.showBookmarks = false } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(C.accent)
                    }
                }
                .padding(16)

                Divider().background(C.border)

                if vm.bookmarks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 40))
                            .foregroundColor(C.textFaint)
                        Text("No Bookmarks Yet")
                            .font(.system(size: 15))
                            .foregroundColor(C.textDim)
                        Text("Tap the bookmark icon in the\ntoolbar to save the current page.")
                            .font(.system(size: 12))
                            .foregroundColor(C.textFaint)
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
                                        .foregroundColor(C.textPri)
                                        .lineLimit(1)
                                    Text(bm.url)
                                        .font(.system(size: 11))
                                        .foregroundColor(C.textDim)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(C.bg)
                        }
                        .onDelete(perform: vm.removeBookmarks)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(C.bgDeep)
                }
            }
        }
    }
}

// MARK: - Menu Sheet

private struct MenuView: View {
    @ObservedObject var vm: BrowserViewModel
    @Binding var showMenu: Bool

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                dragHandle
                privacyCard
                Divider().background(C.border).padding(.horizontal, 16)
                menuItems
                Spacer()
            }
        }
    }

    private var dragHandle: some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 2)
                .fill(C.borderHi)
                .frame(width: 36, height: 4)
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(C.accent)
                Text("Privacy Active")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(C.textPri)
            }
            VStack(alignment: .leading, spacing: 6) {
                pRow("person.slash",
                     "Firefox 115 UA spoofing active")
                pRow("antenna.radiowaves.left.and.right.slash",
                     "WebRTC disabled via JS injection")
                pRow("hand.raised.slash",
                     "35+ tracker domains blocked")
                pRow("externaldrive.badge.xmark",
                     "No persistent cookies or storage")
                pRow("eye.slash",
                     "No browsing history saved")
            }
        }
        .padding(14)
        .background(C.bgDeep)
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var menuItems: some View {
        VStack(spacing: 0) {
            mRow("bookmark",         "Bookmarks")       { showMenu=false; vm.showBookmarks=true }
            mRow("square.on.square", "Tabs")             { showMenu=false; vm.showTabs=true }
            mRow("plus.square",      "New Tab")          { showMenu=false; vm.addNewTab() }
            mRow("bookmark.fill",    "Bookmark This Page") { showMenu=false; vm.bookmarkCurrentPage() }
            mRow("arrow.clockwise",  "Reload Page")      { showMenu=false; vm.reload() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func pRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(C.textDim)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(C.textDim)
        }
    }

    private func mRow(
        _ icon: String,
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(C.textSec)
                        .frame(width: 24)
                    Text(label)
                        .font(.system(size: 15))
                        .foregroundColor(C.textPri)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(C.textFaint)
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 4)
            }
            Divider().background(C.divider)
        }
    }
}

// MARK: - Bottom Toolbar

private struct BottomToolbar: View {
    @ObservedObject var vm         : BrowserViewModel
    @Binding var editingURL        : Bool
    @Binding var urlInput          : String
    @Binding var showMenu          : Bool
    @Binding var bookmarkFlash     : Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color(white: 0.05))
            navRow
            actionRow
        }
        .background(C.bg)
    }

    // Row 1 ──────────────────────────────────────────────────────────────────

    private var navRow: some View {
        HStack(spacing: 10) {
            backButton
            fwdButton
            urlBar
            tabCountButton
            menuButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var backButton: some View {
        Button { vm.goBack() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(vm.currentTab?.canGoBack == true ? C.accent : C.textFaint)
                .frame(width: 30)
        }
        .disabled(vm.currentTab?.canGoBack != true)
    }

    private var fwdButton: some View {
        Button { vm.goForward() } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(vm.currentTab?.canGoFwd == true ? C.accent : C.textFaint)
                .frame(width: 30)
        }
        .disabled(vm.currentTab?.canGoFwd != true)
    }

    private var urlBar: some View {
        HStack(spacing: 6) {
            if vm.urlBarText.hasPrefix("https://") {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(C.textDim)
            }

            if editingURL {
                TextField("Search or enter address", text: $urlInput)
                    .foregroundColor(C.textPri)
                    .font(.system(size: 13))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit {
                        vm.navigate(to: urlInput)
                        editingURL = false
                    }
            } else {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundColor(C.textPri)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if let tab = vm.currentTab, tab.isLoading {
                Button { vm.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundColor(C.textSec)
                }
            } else if !vm.urlBarText.isEmpty {
                Button { vm.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(C.textDim)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(C.bgDeep)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(editingURL ? C.textSec : C.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            urlInput   = vm.urlBarText
            editingURL = true
        }
    }

    private var tabCountButton: some View {
        Button { vm.showTabs = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(C.textSec, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                Text("\(vm.tabs.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(C.accent)
            }
        }
    }

    private var menuButton: some View {
        Button { showMenu = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(C.textSec)
        }
    }

    // Row 2 ──────────────────────────────────────────────────────────────────

    private var actionRow: some View {
        HStack {
            Spacer()
            Button {
                vm.bookmarkCurrentPage()
                bookmarkFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    bookmarkFlash = false
                }
            } label: {
                Image(systemName: bookmarkFlash ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 19))
                    .foregroundColor(bookmarkFlash ? C.textPri : C.textSec)
            }
            Spacer()
            Button { shareURL() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 19))
                    .foregroundColor(C.textSec)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    // Helpers ────────────────────────────────────────────────────────────────

    private var displayText: String {
        let s = vm.urlBarText
        if s.isEmpty { return kAppName }
        return s
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://",  with: "")
    }

    private func shareURL() {
        guard !vm.urlBarText.isEmpty,
              let url = URL(string: vm.urlBarText) else { return }
        let av = UIActivityViewController(
            activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first
                as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        root.present(av, animated: true)
    }
}

// MARK: - Browser View

private struct BrowserView: View {
    @StateObject private var vm      = BrowserViewModel()
    @State private var editingURL    = false
    @State private var urlInput      = ""
    @State private var showMenu      = false
    @State private var bookmarkFlash = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                progressBar
                webArea
                BottomToolbar(
                    vm            : vm,
                    editingURL    : $editingURL,
                    urlInput      : $urlInput,
                    showMenu      : $showMenu,
                    bookmarkFlash : $bookmarkFlash
                )
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

    @ViewBuilder
    private var progressBar: some View {
        if let tab = vm.currentTab, tab.isLoading {
            GeometryReader { geo in
                Rectangle()
                    .fill(C.accent)
                    .frame(width: geo.size.width * tab.progress, height: 2)
                    .animation(.linear(duration: 0.15), value: tab.progress)
            }
            .frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    @ViewBuilder
    private var webArea: some View {
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
}

// MARK: - App Entry Point

@main
struct VariousApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
                .preferredColorScheme(.dark)
        }
    }
}
