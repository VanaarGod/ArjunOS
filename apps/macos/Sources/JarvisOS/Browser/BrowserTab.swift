import SwiftUI
import WebKit
import AppKit
import JarvisCore

/// Why a page could not be shown, in words a person can act on.
struct BrowserFailure: Equatable {
    var title: String
    var message: String
    var url: URL?
    var canRetry = true
}

/// A web view that never lets a drag inside a page move the app window.
final class BrowserWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// WebKit retains script handlers strongly; this proxy breaks the tab <-> web view retain cycle.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(c, didReceive: message) }
}

@MainActor @Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    var title = "New tab"
    var url: URL?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var failure: BrowserFailure?
    var secure = false                       // https with only secure content
    var lastMutationAt = Date.distantPast    // the page changed itself (dynamic sites): used to let it settle before reading
    var needsInitialLoad = false             // a restored tab that has not been loaded yet

    let webView: BrowserWebView
    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: TabDelegate?

    var isBlank: Bool { url == nil }
    var host: String { (url?.host ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored) }

    init(url: URL?, browser: BrowserModel?, loadNow: Bool) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = browser?.dataStore ?? .default()
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"          // sites serve their normal pages to Safari, not to "unknown" browsers
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all                        // no surprise autoplay sound
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        let wv = BrowserWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.underPageBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        self.webView = wv
        self.browser = browser
        self.url = url
        self.needsInitialLoad = (url != nil && !loadNow)

        let d = TabDelegate(tab: self)
        self.delegate = d
        wv.navigationDelegate = d
        wv.uiDelegate = d
        ucc.add(WeakScriptHandler(d), name: "arjun")
        ucc.addUserScript(WKUserScript(source: PageScripts.observer, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        observers = [
            wv.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            wv.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            wv.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            wv.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            wv.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            wv.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            wv.observe(\.hasOnlySecureContent) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
        ]
        if let url, loadNow { load(url) }
    }

    // MARK: navigation
    func load(_ target: URL) {
        failure = nil; needsInitialLoad = false; url = target
        webView.load(URLRequest(url: target))
    }
    func ensureLoaded() { if needsInitialLoad, let u = url { load(u) } }
    func reload() {
        if let u = failure?.url ?? (webView.url == nil ? url : nil) { load(u) } else { failure = nil; webView.reload() }
    }
    func stop() { webView.stopLoading() }
    func goBack() { failure = nil; webView.goBack() }
    func goForward() { failure = nil; webView.goForward() }

    func noteMutation() { lastMutationAt = Date() }

    /// Mirrors the web view's state into observable properties.
    func sync() {
        let wv = webView
        if let t = wv.title, !t.isEmpty { title = t } else if let h = wv.url?.host { title = h }
        if let u = wv.url { url = u }
        isLoading = wv.isLoading
        progress = wv.estimatedProgress
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        secure = wv.hasOnlySecureContent && (wv.url?.scheme == "https")
        browser?.tabChanged(self)
    }

    func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        observers.removeAll()
        delegate = nil
    }

    // MARK: errors
    /// Turns a WebKit/URL-loading error into something readable. Returns nil for errors that are not failures (cancelled loads, downloads).
    static func failure(for error: Error, url: URL?) -> BrowserFailure? {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return nil }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 101) { return nil }       // "frame load interrupted" (became a download / policy change)
        let host = url?.host ?? "this site"
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return BrowserFailure(title: "You're offline", message: "Your Mac isn't connected to the internet, so \(host) can't be reached.", url: url)
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return BrowserFailure(title: "Can't find \(host)", message: "Check the address for typos, or search for it instead.", url: url)
            case NSURLErrorTimedOut:
                return BrowserFailure(title: "\(host) is taking too long", message: "The site didn't respond in time. It may be down or slow.", url: url)
            case NSURLErrorCannotConnectToHost:
                return BrowserFailure(title: "Can't connect to \(host)", message: "The server refused the connection.", url: url)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
                return BrowserFailure(title: "The connection isn't secure", message: "\(host) presented a certificate that can't be trusted, so the page was not loaded. This can happen on public Wi-Fi or with a misconfigured site.", url: url)
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return BrowserFailure(title: "Insecure connection blocked", message: "\(host) only offers plain http. Try its https address.", url: url)
            case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
                return BrowserFailure(title: "That address isn't valid", message: "Only web addresses (http and https) can be opened here.", url: url, canRetry: false)
            case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation:
                return BrowserFailure(title: "Too many redirects", message: "\(host) keeps sending the browser in circles. Clearing browsing data in Settings sometimes fixes this.", url: url)
            default: break
            }
        }
        return BrowserFailure(title: "Couldn't load the page", message: e.localizedDescription, url: url)
    }
}

// MARK: - delegate (navigation policy, permissions, dialogs, downloads)

@MainActor
final class TabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    weak var tab: BrowserTab?
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var dialogTimes: [Date] = []

    init(tab: BrowserTab) { self.tab = tab }

    // ---- page signals (never trusted for content: they only say "something changed") ----
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "arjun", message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let type = body["type"] as? String, let tab else { return }
        switch type {
        case "changed": tab.noteMutation(); tab.browser?.pageChanged(tab, delay: 1.2)
        case "scroll", "selection": tab.browser?.pageChanged(tab, delay: 0.8)
        default: break
        }
    }

    // ---- navigation policy ----
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        let scheme = (url.scheme ?? "").lowercased()
        let isMain = action.targetFrame?.isMainFrame ?? true
        switch scheme {
        case "http", "https", "blob", "about":
            decisionHandler(.allow)
        case "data" where !isMain:
            decisionHandler(.allow)                                            // inline images/frames are fine; top-level data: pages are a phishing favourite
        case "file", "javascript", "data", "vbscript":
            if isMain { tab?.failure = BrowserFailure(title: "Blocked", message: "\(scheme): addresses can't be opened in this browser.", url: nil, canRetry: false) }
            decisionHandler(.cancel)
        default:                                                               // mailto:, tel:, zoommtg:, itms-apps: ... belong to other apps
            if action.navigationType == .linkActivated || action.navigationType == .formSubmitted { askToOpenExternally(url) }
            decisionHandler(.cancel)                                           // scripted redirects into other apps are silently refused
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), cd.hasPrefix("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    // ---- lifecycle ----
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { tab?.failure = nil; tab?.sync() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { tab?.sync() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        tab.sync(); tab.browser?.pageFinished(tab)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error, webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, webView) }
    private func failed(_ error: Error, _ wv: WKWebView) {
        guard let tab else { return }
        let target = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? wv.url ?? tab.url
        if let f = BrowserTab.failure(for: error, url: target) { tab.failure = f; tab.url = target ?? tab.url }
        tab.sync()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.failure = BrowserFailure(title: "This page stopped working", message: "The page used too much memory or crashed. Reload to try again.", url: webView.url ?? tab?.url)
    }

    // ---- sign-in prompts from the server itself (HTTP auth); certificate problems are never bypassed ----
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        guard m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest || m == NSURLAuthenticationMethodNTLM else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = "This site is asking for a user name and password."
        let user = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24)); user.placeholderString = "User name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56)); box.addSubview(user); box.addSubview(pass)
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign In"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    // ---- UI: popups, dialogs, file pickers, camera and microphone ----
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url, ["http", "https"].contains((u.scheme ?? "").lowercased()) { tab?.browser?.open(u, newTab: true) }   // a popup becomes a normal tab
        return nil
    }
    func webViewDidClose(_ webView: WKWebView) { if let tab { tab.browser?.closeTab(tab.id) } }

    /// Pages can loop alert() forever; after three dialogs in five seconds they are dismissed automatically.
    private func allowDialog() -> Bool {
        let now = Date(); dialogTimes = dialogTimes.filter { now.timeIntervalSince($0) < 5 } + [now]
        return dialogTimes.count <= 3
    }
    private func dialog(_ frame: WKFrameInfo, _ message: String, buttons: [String], field: NSTextField? = nil) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = "\(frame.securityOrigin.host.isEmpty ? "This page" : frame.securityOrigin.host) says"
        a.informativeText = String(message.prefix(1000))
        buttons.forEach { a.addButton(withTitle: $0) }
        if let field { a.accessoryView = field }
        return a.runModal()
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        if allowDialog() { _ = dialog(frame, message, buttons: ["OK"]) }
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(allowDialog() ? dialog(frame, message, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn : false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard allowDialog() else { completionHandler(nil); return }
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = defaultText ?? ""
        completionHandler(dialog(frame, prompt, buttons: ["OK", "Cancel"], field: f) == .alertFirstButtonReturn ? f.stringValue : nil)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        p.message = "\(frame.securityOrigin.host) wants you to choose a file to upload."
        p.begin { completionHandler($0 == .OK ? p.urls : nil) }
    }

    /// Camera and microphone: only for https pages, only after the user says yes, and only in a packaged app that declares why it needs them.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let wantsCamera = (type == .camera || type == .cameraAndMicrophone), wantsMic = (type == .microphone || type == .cameraAndMicrophone)
        let info = Bundle.main.infoDictionary ?? [:]
        let declared = (!wantsCamera || info["NSCameraUsageDescription"] != nil) && (!wantsMic || info["NSMicrophoneUsageDescription"] != nil)
        guard origin.protocol == "https", declared else {
            tab?.browser?.notify("\(origin.host) asked to use your \(wantsCamera ? "camera" : "microphone"), which isn't available here.", icon: "video.slash")
            decisionHandler(.deny); return
        }
        let a = NSAlert()
        a.messageText = "\(origin.host) wants to use your \(wantsCamera && wantsMic ? "camera and microphone" : (wantsCamera ? "camera" : "microphone"))"
        a.informativeText = "Only allow this if you trust the site and expect it."
        a.addButton(withTitle: "Don't Allow"); a.addButton(withTitle: "Allow")
        decisionHandler(a.runModal() == .alertSecondButtonReturn ? .grant : .deny)
    }

    // ---- external apps and downloads ----
    private func askToOpenExternally(_ url: URL) {
        let a = NSAlert()
        a.messageText = "Open this link in another app?"
        a.informativeText = String(url.absoluteString.prefix(200))
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let host = response.url?.host ?? "a website"
        let name = Self.safeFilename(suggestedFilename)
        let a = NSAlert()
        a.messageText = "Download “\(name)”?"
        a.informativeText = "From \(host). It will be saved in your Downloads folder."
        a.addButton(withTitle: "Download"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn,
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { completionHandler(nil); return }
        let dest = Self.unique(dir.appendingPathComponent(name))
        downloads[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let dest = downloads.removeValue(forKey: ObjectIdentifier(download)) { tab?.browser?.notify("Downloaded \(dest.lastPathComponent)", icon: "arrow.down.circle.fill", reveal: dest) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        tab?.browser?.notify("The download failed: \((error as NSError).localizedDescription)", icon: "exclamationmark.triangle.fill")
    }

    static func safeFilename(_ raw: String) -> String {
        var n = (raw as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
        return n.isEmpty ? "download" : String(n.prefix(120))
    }
    static func unique(_ url: URL) -> URL {
        var candidate = url, i = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"); i += 1
        }
        return candidate
    }
}
