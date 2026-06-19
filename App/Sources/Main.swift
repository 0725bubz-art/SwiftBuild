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
