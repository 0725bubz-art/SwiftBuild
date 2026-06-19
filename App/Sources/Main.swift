import SwiftUI
import WebKit
import UIKit
// MARK: - Constants
private let kAppName    = "Various"
private let kHomeURL    = "https://duckduckgo.com/"
private let kDDGSearch  = "https://duckduckgo.com/?q="
private let kFirefoxUA  = "Mozilla/5.0 (Windows NT 10.0; rv:115.0) Gecko/20100101 Firefox/115.0"
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
    d(navigator,'userAgent',{get:function(){
      return 'Mozilla/5.0 (Windows NT 10.0; rv:115.0) Gecko/20100101 Firefox/115.0';
    }});
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
struct Bookmark: Identifiable, Codable {
    var id     = UUID()
    var title  : String
    var url    : String
    var folder : String = "Bookmarks"
}
// MARK: - Colours (UIKit + SwiftUI versions)
enum C {
    // UIKit
    static let bg        = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
    static let bgDeep    = UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1)
    static let bgCard    = UIColor(red: 0.141, green: 0.141, blue: 0.141, alpha: 1)
    static let border    = UIColor(white: 0.165, alpha: 1)
    static let textPri   = UIColor(white: 0.88,  alpha: 1)
    static let textSec   = UIColor(white: 0.53,  alpha: 1)
    static let textDim   = UIColor(white: 0.33,  alpha: 1)
    static let textFaint = UIColor(white: 0.20,  alpha: 1)
    static let accent    = UIColor(white: 0.67,  alpha: 1)
    // SwiftUI
    static let sbg        = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let sbgDeep    = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let sbgCard    = Color(red: 0.141, green: 0.141, blue: 0.141)
    static let sborder    = Color(white: 0.165)
    static let sborderHi  = Color(white: 0.267)
    static let stextPri   = Color(white: 0.88)
    static let stextSec   = Color(white: 0.53)
    static let stextDim   = Color(white: 0.33)
    static let stextFaint = Color(white: 0.20)
    static let saccent    = Color(white: 0.67)
    static let sdivider   = Color(white: 0.133)
}
// MARK: - BrowserTab
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()
    var title      = "New Tab"
    var urlString  = ""
    var isLoading  = false
    var progress   = 0.0
    var canGoBack  = false
    var canGoFwd   = false
    let webView: WKWebView
    private var obsProgress : NSKeyValueObservation?
    private var obsTitle    : NSKeyValueObservation?
    private var obsURL      : NSKeyValueObservation?
    private var obsLoading  : NSKeyValueObservation?
    // Called whenever any property changes so the VC can refresh UI
    var onChange: (() -> Void)?
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
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate         = self
        obsProgress = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async {
                self?.progress = w.estimatedProgress
                self?.onChange?()
            }
        }
        obsTitle = wv.observe(\.title, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async {
                if let t = w.title, !t.isEmpty { self?.title = t }
                self?.onChange?()
            }
        }
        obsURL = wv.observe(\.url, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async {
                let s = w.url?.absoluteString ?? ""
                self?.urlString = (s == "about:blank") ? "" : s
                self?.canGoBack = w.canGoBack
                self?.canGoFwd  = w.canGoForward
                self?.onChange?()
            }
        }
        obsLoading = wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async {
                self?.isLoading = w.isLoading
                self?.onChange?()
            }
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
        req.setValue(kAcceptLang,         forHTTPHeaderField: "Accept-Language")
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        webView.load(req)
    }
}
extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let host = action.request.url?.host?.lowercased() {
            for blocked in kBlockedHosts {
                if host == blocked || host.hasSuffix(".\(blocked)") {
                    decisionHandler(.cancel); return
                }
            }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        DispatchQueue.main.async { self.isLoading = true; self.progress = 0.05; self.onChange?() }
    }
    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.async {
            self.isLoading = false
            self.title     = webView.title?.isEmpty == false ? webView.title! : "Untitled"
            self.urlString = webView.url?.absoluteString ?? ""
            self.canGoBack = webView.canGoBack
            self.canGoFwd  = webView.canGoForward
            self.onChange?()
        }
    }
    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        DispatchQueue.main.async { self.isLoading = false; self.onChange?() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        DispatchQueue.main.async { self.isLoading = false; self.onChange?() }
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
// MARK: - BrowserState (plain class, no ObservableObject needed — UIKit drives UI)
final class BrowserState {
    var tabs        : [BrowserTab] = []
    var currentIndex: Int          = 0
    var bookmarks   : [Bookmark]   = []
    var onChange: (() -> Void)?
    var currentTab: BrowserTab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }
    var urlBarText: String {
        currentTab?.urlString ?? ""
    }
    init() {
        loadBookmarks()
        addNewTab()
    }
    func addNewTab(url: URL? = nil) {
        let tab       = BrowserTab()
        tab.onChange  = { [weak self] in self?.onChange?() }
        tabs.append(tab)
        currentIndex  = tabs.count - 1
        if let url = url { tab.load(url) }
        onChange?()
    }
    func closeTab(at index: Int) {
        guard tabs.count > 1 else { return }
        tabs.remove(at: index)
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        onChange?()
    }
    func switchTab(to index: Int) {
        currentIndex = index
        onChange?()
    }
    func navigate(to raw: String) {
        let url = resolveURL(raw)
        currentTab?.load(url)
        onChange?()
    }
    func goBack()    { currentTab?.webView.goBack() }
    func goForward() { currentTab?.webView.goForward() }
    func reload()    { currentTab?.webView.reload() }
    func stop()      { currentTab?.webView.stopLoading() }
    func bookmarkCurrentPage() {
        guard let tab = currentTab, !tab.urlString.isEmpty else { return }
        let url = tab.urlString
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        bookmarks.append(Bookmark(title: tab.title.isEmpty ? url : tab.title, url: url))
        saveBookmarks()
    }
    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }
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
}
// MARK: - RootViewController
// Pure UIKit layout. Every subview is pinned to view.bounds directly.
// No SwiftUI, no safe-area interference at the top level.
final class RootViewController: UIViewController {
    let state = BrowserState()
    // MARK: Subviews
    private let topBar       = UIView()    // solid colour behind notch
    private let progressBar  = UIView()
    private let webContainer = UIView()
    private let toolbar      = UIView()    // entire bottom bar incl. home indicator area
    private let urlField     = UITextField()
    private let backBtn      = UIButton(type: .system)
    private let fwdBtn       = UIButton(type: .system)
    private let reloadBtn    = UIButton(type: .system)
    private let tabsBtn      = UIButton(type: .system)
    private let menuBtn      = UIButton(type: .system)
    private let bookmarkBtn  = UIButton(type: .system)
    private let shareBtn     = UIButton(type: .system)
    private var startPageVC  : UIViewController?
    // MARK: viewDidLoad
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = C.bg
        buildTopBar()
        buildWebContainer()
        buildProgressBar()
        buildToolbar()
        state.onChange = { [weak self] in self?.refreshUI() }
        showCurrentContent()
        refreshUI()
    }
    // MARK: Layout — called every time bounds change (rotation, etc.)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayout()
    }
    private func applyLayout() {
        let b      = view.bounds
        let W      = b.width
        let H      = b.height
        let top    = view.safeAreaInsets.top
        let bottom = view.safeAreaInsets.bottom
        // 1. Top colour fill — exactly the height of the notch/island
        topBar.frame = CGRect(x: 0, y: 0, width: W, height: top)
        // 2. Toolbar total height: nav row (50) + action row (44) + home gap
        let tbH: CGFloat = 50 + 44 + bottom
        toolbar.frame = CGRect(x: 0, y: H - tbH, width: W, height: tbH)
        // 3. Web area fills exactly between topBar and toolbar
        let webY = top
        let webH = H - top - tbH
        webContainer.frame = CGRect(x: 0, y: webY, width: W, height: webH)
        // 4. Progress bar sits at very top of webContainer
        progressBar.frame = CGRect(x: 0, y: webY, width: 0, height: 2)
        // 5. Resize web content inside container
        webContainer.subviews.forEach { $0.frame = webContainer.bounds }
        if let host = startPageVC {
            host.view.frame = webContainer.bounds
        }
        // 6. Layout toolbar subviews
        layoutToolbarSubviews(W: W, bottom: bottom)
    }
    private func layoutToolbarSubviews(W: CGFloat, bottom: CGFloat) {
        let navH   : CGFloat = 50
        let actH   : CGFloat = 44
        let pad    : CGFloat = 14
        let btnW   : CGFloat = 34
        let gap    : CGFloat = 6
        // Nav row (y=0 inside toolbar)
        var x = pad
        let btnY: CGFloat = (navH - 30) / 2
        backBtn.frame   = CGRect(x: x, y: btnY, width: btnW, height: 30); x += btnW + gap
        fwdBtn.frame    = CGRect(x: x, y: btnY, width: btnW, height: 30); x += btnW + gap
        reloadBtn.frame = CGRect(x: x, y: btnY, width: btnW, height: 30); x += btnW + gap
        let rightEdge = W - pad
        var rx = rightEdge
        rx -= btnW
        menuBtn.frame = CGRect(x: rx, y: btnY, width: btnW, height: 30)
        rx -= gap + 32
        tabsBtn.frame = CGRect(x: rx, y: btnY + 4, width: 32, height: 22)
        rx -= gap
        let urlW = rx - x
        urlField.frame = CGRect(x: x, y: btnY, width: urlW, height: 32)
        // Action row (y=navH inside toolbar)
        let actY    = navH
        let quarter = W / 4
        bookmarkBtn.frame = CGRect(x: quarter - 24,     y: actY + 7, width: 48, height: 30)
        shareBtn.frame    = CGRect(x: quarter * 3 - 24, y: actY + 7, width: 48, height: 30)
    }
    // MARK: Build subviews
    private func buildTopBar() {
        topBar.backgroundColor = C.bg
        view.addSubview(topBar)
    }
    private func buildWebContainer() {
        webContainer.backgroundColor = C.bg
        webContainer.clipsToBounds   = true
        view.addSubview(webContainer)
    }
    private func buildProgressBar() {
        progressBar.backgroundColor = C.accent
        progressBar.alpha           = 0
        view.addSubview(progressBar)
    }
    private func buildToolbar() {
        toolbar.backgroundColor = C.bg
        view.addSubview(toolbar)
        // Top hairline separator
        let sep = UIView()
        sep.backgroundColor = UIColor(white: 0.08, alpha: 1)
        sep.frame = CGRect(x: 0, y: 0, width: 0, height: 1) // width set in applyLayout
        sep.autoresizingMask = [.flexibleWidth]
        toolbar.addSubview(sep)
        // Back
        styleNavBtn(backBtn, sfSymbol: "chevron.left")
        backBtn.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
        // Forward
        styleNavBtn(fwdBtn, sfSymbol: "chevron.right")
        fwdBtn.addTarget(self, action: #selector(tapFwd), for: .touchUpInside)
        // Reload
        styleNavBtn(reloadBtn, sfSymbol: "arrow.clockwise")
        reloadBtn.addTarget(self, action: #selector(tapReload), for: .touchUpInside)
        // URL field
        urlField.backgroundColor        = C.bgDeep
        urlField.textColor              = C.textPri
        urlField.font                   = .systemFont(ofSize: 13)
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType     = .no
        urlField.keyboardType           = .URL
        urlField.returnKeyType          = .go
        urlField.clearButtonMode        = .whileEditing
        urlField.leftViewMode           = .always
        urlField.leftView               = UIView(frame: CGRect(x:0,y:0,width:10,height:1))
        urlField.layer.cornerRadius     = 8
        urlField.layer.borderWidth      = 1
        urlField.layer.borderColor      = C.border.cgColor
        urlField.clipsToBounds          = true
        urlField.delegate               = self
        urlField.attributedPlaceholder  = NSAttributedString(
            string: "Search or enter address",
            attributes: [.foregroundColor: C.textDim])
        urlField.addTarget(self, action: #selector(urlFieldBegan), for: .editingDidBegin)
        // Tabs btn
        tabsBtn.setTitle("1", for: .normal)
        tabsBtn.titleLabel?.font   = .boldSystemFont(ofSize: 11)
        tabsBtn.setTitleColor(C.accent, for: .normal)
        tabsBtn.layer.borderColor  = C.textSec.cgColor
        tabsBtn.layer.borderWidth  = 1.5
        tabsBtn.layer.cornerRadius = 5
        tabsBtn.clipsToBounds      = true
        tabsBtn.addTarget(self, action: #selector(tapTabs), for: .touchUpInside)
        // Menu btn
        styleNavBtn(menuBtn, sfSymbol: "ellipsis")
        menuBtn.addTarget(self, action: #selector(tapMenu), for: .touchUpInside)
        // Bookmark btn
        styleActionBtn(bookmarkBtn, sfSymbol: "bookmark")
        bookmarkBtn.addTarget(self, action: #selector(tapBookmark), for: .touchUpInside)
        // Share btn
        styleActionBtn(shareBtn, sfSymbol: "square.and.arrow.up")
        shareBtn.addTarget(self, action: #selector(tapShare), for: .touchUpInside)
        for v in [backBtn, fwdBtn, reloadBtn, urlField,
                  tabsBtn, menuBtn, bookmarkBtn, shareBtn] {
            toolbar.addSubview(v)
        }
    }
    private func styleNavBtn(_ btn: UIButton, sfSymbol: String) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        btn.setImage(UIImage(systemName: sfSymbol, withConfiguration: cfg), for: .normal)
        btn.tintColor       = C.accent
        btn.backgroundColor = .clear
    }
    private func styleActionBtn(_ btn: UIButton, sfSymbol: String) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        btn.setImage(UIImage(systemName: sfSymbol, withConfiguration: cfg), for: .normal)
        btn.tintColor       = C.textSec
        btn.backgroundColor = .clear
    }
    // MARK: Content display
    func showCurrentContent() {
        // Remove previous content
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        startPageVC?.removeFromParent()
        startPageVC = nil
        guard let tab = state.currentTab else {
            mountStartPage(); return
        }
        if tab.urlString.isEmpty {
            mountStartPage()
        } else {
            let wv    = tab.webView
            wv.frame  = webContainer.bounds
            webContainer.addSubview(wv)
        }
    }
    private func mountStartPage() {
        let spView = StartPageView { [weak self] query in
            self?.state.navigate(to: query)
            self?.showCurrentContent()
            self?.refreshUI()
        }
        let host = UIHostingController(rootView: spView)
        host.view.frame           = webContainer.bounds
        host.view.backgroundColor = C.bg
        addChild(host)
        webContainer.addSubview(host.view)
        host.didMove(toParent: self)
        startPageVC = host
    }
    // MARK: UI Refresh
    func refreshUI() {
        guard let tab = state.currentTab else { return }
        // URL bar
        if !urlField.isEditing {
            let s = tab.urlString
            urlField.text = s.isEmpty ? "" : s
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://",  with: "")
        }
        // Back / forward
        backBtn.tintColor = tab.canGoBack ? C.accent : C.textFaint
        backBtn.isEnabled = tab.canGoBack
        fwdBtn.tintColor  = tab.canGoFwd  ? C.accent : C.textFaint
        fwdBtn.isEnabled  = tab.canGoFwd
        // Tab count
        tabsBtn.setTitle("\(state.tabs.count)", for: .normal)
        // Progress
        if tab.isLoading {
            progressBar.alpha = 1
            let w = webContainer.bounds.width * CGFloat(tab.progress)
            UIView.animate(withDuration: 0.15) {
                self.progressBar.frame.size.width = w
            }
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            reloadBtn.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        } else {
            UIView.animate(withDuration: 0.3) { self.progressBar.alpha = 0 }
            progressBar.frame.size.width = 0
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            reloadBtn.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: cfg), for: .normal)
        }
    }
    // MARK: Button actions
    @objc private func tapBack() {
        state.goBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refreshUI() }
    }
    @objc private func tapFwd() {
        state.goForward()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refreshUI() }
    }
    @objc private func tapReload() {
        if state.currentTab?.isLoading == true { state.stop() } else { state.reload() }
    }
    @objc private func urlFieldBegan() {
        urlField.text = state.currentTab?.urlString ?? ""
        DispatchQueue.main.async { self.urlField.selectAll(nil) }
    }
    @objc private func tapTabs() {
        let vc = UIHostingController(rootView: TabSheetView(state: state) { [weak self] in
            self?.dismiss(animated: true)
            self?.showCurrentContent()
            self?.refreshUI()
        })
        if #available(iOS 16.0, *) {
            vc.sheetPresentationController?.detents = [.large()]
        }
        present(vc, animated: true)
    }
    @objc private func tapMenu() {
        let vc = UIHostingController(rootView: MenuSheetView(state: state) { [weak self] in
            self?.dismiss(animated: true)
            self?.showCurrentContent()
            self?.refreshUI()
        } onBookmarks: { [weak self] in
            self?.dismiss(animated: true) {
                self?.tapBookmarksSheet()
            }
        })
        if #available(iOS 16.0, *) {
            vc.sheetPresentationController?.detents = [.medium(), .large()]
        }
        present(vc, animated: true)
    }
    private func tapBookmarksSheet() {
        let vc = UIHostingController(rootView: BookmarkSheetView(state: state) { [weak self] in
            self?.dismiss(animated: true)
            self?.showCurrentContent()
            self?.refreshUI()
        })
        if #available(iOS 16.0, *) {
            vc.sheetPresentationController?.detents = [.large()]
        }
        present(vc, animated: true)
    }
    @objc private func tapBookmark() {
        state.bookmarkCurrentPage()
        let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        bookmarkBtn.setImage(UIImage(systemName: "bookmark.fill", withConfiguration: cfg), for: .normal)
        bookmarkBtn.tintColor = C.textPri
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.bookmarkBtn.setImage(UIImage(systemName: "bookmark", withConfiguration: cfg), for: .normal)
            self?.bookmarkBtn.tintColor = C.textSec
        }
    }
    @objc private func tapShare() {
        guard let url = URL(string: state.currentTab?.urlString ?? "") else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(av, animated: true)
    }
}
// MARK: - UITextField Delegate
extension RootViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        state.navigate(to: textField.text ?? "")
        showCurrentContent()
        refreshUI()
        return true
    }
}
// MARK: - Start Page (SwiftUI — simple, just logo + search)
private struct StartPageView: View {
    var onSearch: (String) -> Void
    @State private var query = ""
    var body: some View {
        ZStack {
            Color(red: 0.102, green: 0.102, blue: 0.102).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // Logo
                ZStack {
                    Circle().stroke(Color.white.opacity(0.27), lineWidth: 2).frame(width: 72, height: 72)
                    Circle().stroke(Color.white.opacity(0.33), lineWidth: 2).frame(width: 48, height: 48)
                    Circle().stroke(Color.white.opacity(0.40), lineWidth: 2).frame(width: 24, height: 24)
                    Circle().fill(Color.white.opacity(0.53)).frame(width: 8, height: 8)
                }
                .opacity(0.75)
                .padding(.bottom, 20)
                Text(kAppName.uppercased())
                    .font(.system(size: 36, weight: .ultraLight))
                    .tracking(8)
                    .foregroundColor(Color(white: 0.88))
                Text("PRIVACY  ·  SECURITY  ·  ANONYMITY")
                    .font(.system(size: 10))
                    .tracking(3)
                    .foregroundColor(Color(white: 0.20))
                    .padding(.top, 6)
                    .padding(.bottom, 44)
                // Search box
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        if query.isEmpty {
                            Text("Search DuckDuckGo or enter address...")
                                .foregroundColor(Color(white: 0.23))
                                .font(.system(size: 15))
                                .padding(.leading, 16)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $query)
                            .foregroundColor(Color(white: 0.88))
                            .font(.system(size: 15))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .onSubmit { submit() }
                    }
                    Button(action: submit) {
                        Text("Search")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.53))
                            .frame(height: 48)
                            .padding(.horizontal, 18)
                    }
                    .background(Color(red: 0.141, green: 0.141, blue: 0.141))
                    .overlay(
                        Rectangle().frame(width: 1).foregroundColor(Color(white: 0.165)),
                        alignment: .leading
                    )
                }
                .background(Color(red: 0.067, green: 0.067, blue: 0.067))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.165), lineWidth: 1))
                .padding(.horizontal, 28)
                Spacer()
                Spacer()
            }
        }
    }
    private func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        onSearch(q)
    }
}
// MARK: - Tab Sheet (SwiftUI)
private struct TabSheetView: View {
    var state: BrowserState
    var onDismiss: () -> Void
    var body: some View {
        ZStack {
            C.sbgDeep.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("\(state.tabs.count) Tab\(state.tabs.count == 1 ? "" : "s")")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(C.stextPri)
                    Spacer()
                    Button {
                        state.addNewTab()
                        onDismiss()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(C.saccent)
                            .padding(8)
                            .background(C.sbgCard)
                            .cornerRadius(8)
                    }
                }
                .padding(16)
                Divider().background(C.sborder)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(state.tabs.enumerated()), id: \.element.id) { i, tab in
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .foregroundColor(C.stextDim)
                                    .frame(width: 36, height: 36)
                                    .background(C.sbgCard)
                                    .cornerRadius(6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tab.title.isEmpty ? "New Tab" : tab.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(C.stextPri).lineLimit(1)
                                    Text(tab.urlString.isEmpty ? kAppName : tab.urlString)
                                        .font(.system(size: 11))
                                        .foregroundColor(C.stextDim).lineLimit(1)
                                }
                                Spacer()
                                Button { state.closeTab(at: i) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(C.stextSec)
                                        .padding(6).background(C.sbgCard).cornerRadius(6)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(i == state.currentIndex ? C.sbgCard : C.sbg)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(i == state.currentIndex ? C.sborderHi : C.sborder, lineWidth: 1))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { state.switchTab(to: i); onDismiss() }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}
// MARK: - Bookmark Sheet (SwiftUI)
private struct BookmarkSheetView: View {
    var state: BrowserState
    var onDismiss: () -> Void
    var body: some View {
        ZStack {
            C.sbgDeep.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Bookmarks")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(C.stextPri)
                    Spacer()
                    Button { onDismiss() } label: {
                        Text("Done").font(.system(size: 15, weight: .medium)).foregroundColor(C.saccent)
                    }
                }
                .padding(16)
                Divider().background(C.sborder)
                if state.bookmarks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark").font(.system(size: 40)).foregroundColor(C.stextFaint)
                        Text("No Bookmarks Yet").font(.system(size: 15)).foregroundColor(C.stextDim)
                        Text("Tap the bookmark icon in the\ntoolbar to save the current page.")
                            .font(.system(size: 12)).foregroundColor(C.stextFaint).multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(state.bookmarks) { bm in
                            Button {
                                state.navigate(to: bm.url)
                                onDismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bm.title).font(.system(size: 13, weight: .medium))
                                        .foregroundColor(C.stextPri).lineLimit(1)
                                    Text(bm.url).font(.system(size: 11))
                                        .foregroundColor(C.stextDim).lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(C.sbg)
                        }
                        .onDelete { state.removeBookmarks(at: $0) }
                    }
                    .listStyle(.plain)
                    .background(C.sbgDeep)
                }
            }
        }
    }
}
// MARK: - Menu Sheet (SwiftUI)
private struct MenuSheetView: View {
    var state    : BrowserState
    var onDismiss: () -> Void
    var onBookmarks: () -> Void
    var body: some View {
        ZStack {
            C.sbg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack { Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(C.sborderHi).frame(width: 36, height: 4)
                    Spacer()
                }.padding(.top, 10).padding(.bottom, 18)
                // Privacy card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill").foregroundColor(C.saccent)
                        Text("Privacy Active").font(.system(size: 13, weight: .semibold)).foregroundColor(C.stextPri)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        pr("person.slash",                            "Firefox 115 UA spoofing active")
                        pr("antenna.radiowaves.left.and.right.slash", "WebRTC disabled via JS injection")
                        pr("hand.raised.slash",                       "35+ tracker domains blocked")
                        pr("externaldrive.badge.xmark",               "No persistent cookies or storage")
                        pr("eye.slash",                               "No browsing history saved")
                    }
                }
                .padding(14).background(C.sbgDeep).cornerRadius(10)
                .padding(.horizontal, 16).padding(.bottom, 16)
                Divider().background(C.sborder).padding(.horizontal, 16)
                VStack(spacing: 0) {
                    mr("bookmark",         "Bookmarks")        { onBookmarks() }
                    mr("plus.square",      "New Tab")          { state.addNewTab(); onDismiss() }
                    mr("bookmark.fill",    "Bookmark This Page") { state.bookmarkCurrentPage(); onDismiss() }
                    mr("arrow.clockwise",  "Reload Page")      { state.reload(); onDismiss() }
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Spacer()
            }
        }
    }
    private func pr(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(C.stextDim).frame(width: 16)
            Text(text).font(.system(size: 11)).foregroundColor(C.stextDim)
        }
    }
    private func mr(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 16)).foregroundColor(C.stextSec).frame(width: 24)
                    Text(label).font(.system(size: 15)).foregroundColor(C.stextPri)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(C.stextFaint)
                }
                .padding(.vertical, 13).padding(.horizontal, 4)
            }
            Divider().background(C.sdivider)
        }
    }
}
// MARK: - App Entry Point
// UIKit AppDelegate + SceneDelegate.
// The window is created manually so we have 100% control over
// whether safe areas affect layout — they don't, because
// RootViewController handles all insets manually via applyLayout().
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene,
               willConnectTo _: UISceneSession,
               options _: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let win = UIWindow(windowScene: ws)
        win.backgroundColor = C.bg
        let root = RootViewController()
        win.rootViewController = root
        win.makeKeyAndVisible()
        self.window = win
    }
}
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default Configuration",
                                       sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}
