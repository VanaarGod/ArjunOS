import SwiftUI
import WebKit
import AppKit

/// Where the bundled renderer lives: Contents/Resources/web in the packaged app, apps/macos/Web when run with `swift run`.
enum MarkdownAssets {
    static let directory: URL? = {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
           fm.fileExists(atPath: r.appendingPathComponent("chat.html").path) { return r }
        // dev: this file is apps/macos/Sources/JarvisOS/MarkdownView.swift -> apps/macos/Web
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Web", isDirectory: true)
        return fm.fileExists(atPath: dev.appendingPathComponent("chat.html").path) ? dev : nil
    }()
}

/// Remembers measured heights so a message that scrolls out and back in doesn't jump while its web view re-renders.
@MainActor final class HeightCache {
    static let shared = HeightCache()
    private var heights: [String: CGFloat] = [:]
    subscript(key: String) -> CGFloat? {
        get { heights[key] }
        set { heights[key] = newValue; if heights.count > 800 { heights.removeAll(keepingCapacity: true) } }
    }
}

/// Every rendered message shares ONE website data store, which lets WebKit keep ONE web-content process for all of them. Before,
/// each message created its own store, so a long chat started dozens of separate processes and re-loaded the page in each.
@MainActor enum MarkdownEngine {
    static let dataStore = WKWebsiteDataStore.nonPersistent()
}

/// A web view that never captures the scroll wheel, so the chat's own ScrollView keeps scrolling over messages.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
}

/// Renders markdown + math with the bundled marked/KaTeX page. Content is UNTRUSTED: the page escapes HTML, blocks remote
/// images, and carries a strict CSP; here we additionally block every navigation except the initial local load.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = MarkdownEngine.dataStore
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "height")
        ucc.add(context.coordinator, name: "copy")
        cfg.userContentController = ucc
        let wv = PassthroughWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")           // transparent: the glass shows through
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        if let dir = MarkdownAssets.directory { wv.loadFileURL(dir.appendingPathComponent("chat.html"), allowingReadAccessTo: dir) }
        return wv
    }

    func updateNSView(_ wv: PassthroughWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.set(markdown)
    }

    static func dismantleNSView(_ wv: PassthroughWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeAllScriptMessageHandlers()   // break the handler -> coordinator retain
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownWebView
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: String?
        private var last: String?
        private var scheduled = false

        init(_ parent: MarkdownWebView) { self.parent = parent }

        /// Coalesces rapid streaming updates (~20 renders/second at most).
        func set(_ md: String) {
            pending = md
            guard loaded, !scheduled, md != last else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.scheduled = false; self?.renderNow()
            }
        }

        private func renderNow() {
            guard loaded, let md = pending, md != last, let wv = webView else { return }
            last = md
            guard let data = try? JSONEncoder().encode(md), let json = String(data: data, encoding: .utf8) else { return }
            wv.evaluateJavaScript("render(\(json))", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; renderNow() }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                LinkRouter.open(url)                            // the user clicked a link: the built-in browser (or their default one)
                decisionHandler(.cancel); return
            }
            if action.navigationType == .other, action.request.url?.isFileURL == true { decisionHandler(.allow); return }   // initial load
            decisionHandler(.cancel)                            // anything else (scripted redirects, frames, ...) is refused
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "height":
                if let h = (message.body as? NSNumber)?.doubleValue, h.isFinite, h >= 0 {
                    let v = CGFloat(min(h, 200_000))
                    if abs(parent.height - v) > 0.5 { parent.height = v }
                }
            case "copy":
                if let s = message.body as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
            default: break
            }
        }
    }
}

/// Assistant message body: rendered markdown/math, with a plain-text fallback if the bundled assets are missing.
struct RichText: View {
    let key: String                  // message id, for the height cache
    let markdown: String
    @State private var height: CGFloat = 24

    var body: some View {
        if MarkdownAssets.directory == nil {
            Text(markdown).textSelection(.enabled).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownWebView(markdown: markdown, height: $height)
                .frame(height: max(height, 20))
                .frame(maxWidth: .infinity)
                .onAppear { if let h = HeightCache.shared[key] { height = h } }
                .onChange(of: height) { _, h in HeightCache.shared[key] = h }
        }
    }
}


/// Where a clicked link goes. AppModel installs the handler (built-in browser when enabled); without one it falls back to the system browser.
/// Callable from any context; it hops to the main actor itself.
enum LinkRouter {
    static var handler: (@MainActor (URL) -> Void)?
    static func open(_ url: URL) {
        Task { @MainActor in
            if let h = handler { h(url) } else { NSWorkspace.shared.open(url) }
        }
    }
}
