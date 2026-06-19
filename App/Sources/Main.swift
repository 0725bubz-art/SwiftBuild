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
        if text.hasPrefix(s) { return URL(string: text) ?? URL(string: kHomeURL)! }
    }
    let pat = "^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}(?:[/?#].*)?$"
    if !text.contains(" "), text.range(of: pat, options: .regularExpression) != nil {
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

// MARK: - Colours
enum C {
    static let bg        = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
    static let bgDeep    = UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1)
    static let bgCard    = UIColor(red: 0.141, green: 0.141, blue: 0.141, alpha: 1)
    static let border    = UIColor(white: 0.165, alpha: 1)
    static let textPri   = UIColor(white: 0.88,  alpha: 1)
    static let textSec   = UIColor(white: 0.53,  alpha: 1)
    static let textDim   = UIColor(white: 0.33,  alpha: 1)
    static let textFaint = UIColor(white: 0.20,  alpha: 1)
    static let accent    = UIColor(white: 0.67,  alpha: 1)
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
final class BrowserTab: NSObject, Identifiable,
                        WKNavigationDelegate, WKUIDelegate {
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
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.scrollView.automaticallyAdjustsScrollIndicatorInsets = true
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

// MARK: - AppDelegate
@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

// MARK: - SceneDelegate
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let win = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: ContentView())
        host.view.backgroundColor = C.bg
        win.rootViewController = host
        win.makeKeyAndVisible()
        self.window = win
    }
}

// MARK: - BrowserViewModel
@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeIndex: Int = 0
    @Published var bookmarks: [Bookmark] = []

    var activeTab: BrowserTab? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        return tabs[activeIndex]
    }

    init() {
        loadBookmarks()
        newTab()
    }

    func newTab(url: URL? = nil) {
        let tab = BrowserTab()
        tab.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        tabs.append(tab)
        activeIndex = tabs.count - 1
        if let u = url { tab.load(u) }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty { newTab() }
        activeIndex = min(activeIndex, tabs.count - 1)
    }

    func addBookmark(title: String, url: String) {
        bookmarks.append(Bookmark(title: title, url: url))
        saveBookmarks()
    }

    func deleteBookmark(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "bookmarks")
        }
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: "bookmarks"),
           let bms = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = bms
        }
    }
}

// MARK: - WebView wrapper
struct WebViewWrapper: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var vm = BrowserViewModel()
    @State private var urlInput: String = ""
    @State private var showTabs: Bool = false
    @State private var showBookmarks: Bool = false
    @State private var isEditingURL: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            C.sbgDeep.ignoresSafeArea()
            VStack(spacing: 0) {
                addressBar
                if let tab = vm.activeTab {
                    ZStack(alignment: .top) {
                        WebViewWrapper(webView: tab.webView)
                            .ignoresSafeArea(edges: [.bottom])
                        if tab.isLoading {
                            GeometryReader { geo in
                                Rectangle().fill(C.saccent)
                                    .frame(width: geo.size.width * tab.progress, height: 2)
                                    .animation(.linear(duration: 0.2), value: tab.progress)
                            }.frame(height: 2)
                        }
                    }
                } else { Spacer() }
                bottomBar
            }
            .ignoresSafeArea(edges: [.bottom])
        }
        .sheet(isPresented: $showTabs) { tabsSheet }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
        .onAppear {
            if let tab = vm.activeTab { tab.load(resolveURL(kHomeURL)) }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { vm.activeTab?.webView.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .medium))
            }
            .disabled(!(vm.activeTab?.canGoBack ?? false))
            .foregroundColor(vm.activeTab?.canGoBack == true ? C.stextPri : C.stextFaint)
            TextField("Search or enter address", text: $urlInput,
                      onEditingChanged: { isEditingURL = $0 },
                      onCommit: {
                let url = resolveURL(urlInput)
                vm.activeTab?.load(url)
                isEditingURL = false
            })
            .textFieldStyle(PlainTextFieldStyle())
            .foregroundColor(C.stextPri).font(.system(size: 14))
            .keyboardType(.webSearch).autocapitalization(.none).disableAutocorrection(true)
            .onTapGesture { urlInput = vm.activeTab?.urlString ?? ""; isEditingURL = true }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(C.sbgCard).cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isEditingURL ? C.sborderHi : C.sborder, lineWidth: 1))
            if vm.activeTab?.isLoading == true {
                Button { vm.activeTab?.webView.stopLoading() } label: {
                    Image(systemName: "xmark").font(.system(size: 14))
                }.foregroundColor(C.stextSec)
            } else {
                Button { vm.activeTab?.webView.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14))
                }.foregroundColor(C.stextSec)
            }
            Button { vm.activeTab?.webView.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium))
            }
            .disabled(!(vm.activeTab?.canGoFwd ?? false))
            .foregroundColor(vm.activeTab?.canGoFwd == true ? C.stextPri : C.stextFaint)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(C.sbg)
        .overlay(Divider().background(C.sdivider), alignment: .bottom)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Spacer()
            Button { showBookmarks.toggle() } label: {
                Image(systemName: "bookmark").font(.system(size: 18))
            }.foregroundColor(C.stextSec)
            Spacer()
            Button {
                if let tab = vm.activeTab, !tab.urlString.isEmpty {
                    vm.addBookmark(title: tab.title, url: tab.urlString)
                }
            } label: {
                Image(systemName: "bookmark.fill").font(.system(size: 18))
            }.foregroundColor(C.stextSec)
            Spacer()
            Button { showTabs.toggle() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).stroke(C.stextSec, lineWidth: 1.5).frame(width: 22, height: 22)
                    Text("\(vm.tabs.count)").font(.system(size: 11, weight: .bold)).foregroundColor(C.stextSec)
                }
            }
            Spacer()
            Button { vm.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 18))
            }.foregroundColor(C.stextSec)
            Spacer()
        }
        .padding(.vertical, 10).padding(.bottom, 20)
        .background(C.sbg)
        .overlay(Divider().background(C.sdivider), alignment: .top)
    }

    private var tabsSheet: some View {
        NavigationView {
            List {
                ForEach(vm.tabs.indices, id: \.self) { i in
                    Button { vm.activeIndex = i; showTabs = false } label: {
                        HStack {
                            Text(vm.tabs[i].title).lineLimit(1).foregroundColor(C.stextPri)
                            Spacer()
                            Button { vm.closeTab(at: i) } label: {
                                Image(systemName: "xmark").foregroundColor(C.stextSec)
                            }
                        }
                    }
                }
            }.listStyle(InsetGroupedListStyle()).navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("New Tab") { vm.newTab(); showTabs = false }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { showTabs = false }
                }
            }
        }
    }

    private var bookmarksSheet: some View {
        NavigationView {
            List {
                ForEach(vm.bookmarks) { bm in
                    Button {
                        vm.activeTab?.load(resolveURL(bm.url))
                        showBookmarks = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bm.title).foregroundColor(C.stextPri).lineLimit(1)
                            Text(bm.url).font(.caption).foregroundColor(C.stextSec).lineLimit(1)
                        }
                    }
                }.onDelete(perform: vm.deleteBookmark)
            }.listStyle(InsetGroupedListStyle()).navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { showBookmarks = false }
                }
            }
        }
    }
}
