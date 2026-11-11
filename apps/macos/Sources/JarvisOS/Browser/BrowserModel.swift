import SwiftUI
import AppKit
import WebKit
import JarvisCore

/// The integrated browser: tabs on the right of the window, the assistant on the left. It owns the tabs, keeps a small
/// summary of what the assistant can currently see (for the chip above the composer), and reads the live page on demand.
@MainActor @Observable
final class BrowserModel {
    struct Notice: Identifiable, Equatable {
        let id = UUID(); var text: String; var icon: String; var reveal: URL?
    }
    struct RecentSite: Codable, Equatable, Identifiable { var url: String; var title: String; var id: String { url } }
    struct PageSummary: Equatable {
        var title: String; var host: String; var chars: Int; var source: String; var updated: Date; var productData: Bool; var thin: Bool
    }
    enum ContextState: Equatable {
        case off                      // sharing switched off
        case idle                     // nothing read yet
        case loading                  // the page is still loading
        case reading                  // being read right now
        case ready(PageSummary)
        case unavailable(String)      // e.g. offline, sign-in page, blocked
    }

    var tabs: [BrowserTab] = []
    var selectedID: UUID?
    var isOpen = false
    var paneFraction: Double = 0.42
    var notice: Notice?
    var shareWithAI = true            // "use this page when I ask a question"
    var alwaysOCR = false             // also read a screenshot of the visible page on every message
    var contextState: ContextState = .idle
    var recents: [RecentSite] = []
    var addressFocusToken = 0

    @ObservationIgnored var isFeatureEnabled: @MainActor () -> Bool = { true }     // Settings -> Browser -> "read the page I have open"
    @ObservationIgnored var onOpened: (@MainActor () -> Void)?                     // lets the window grow to make room
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var unchangedReads = 0                  // consecutive background reads that found the same page, for backing off
    @ObservationIgnored private var lastReadSignature = ""
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    static let maxTabs = 20

    /// An isolated browser belongs to one crew agent: it has its own cookies and logins (a throwaway, in-memory store, so an agent
    /// can never see the sites you are signed in to), and it never saves tabs or history, so it cannot disturb your own browser.
    let isolated: Bool
    let dataStore: WKWebsiteDataStore
    @ObservationIgnored var onPageFinished: (@MainActor (BrowserTab) -> Void)?

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }
    var wantsContext: Bool { isOpen && shareWithAI && isFeatureEnabled() && selected != nil }

    init(isolated: Bool = false) {
        self.isolated = isolated
        self.dataStore = isolated ? .nonPersistent() : .default()
        if isolated { isOpen = true; return }
        let f = defaults.double(forKey: "browser.fraction"); if f >= 0.25 && f <= 0.75 { paneFraction = f }
        shareWithAI = defaults.object(forKey: "browser.share") as? Bool ?? true
        alwaysOCR = defaults.bool(forKey: "browser.alwaysOCR")
        if let data = defaults.data(forKey: "browser.recents"), let r = try? JSONDecoder().decode([RecentSite].self, from: data) { recents = r }
        let saved = (defaults.array(forKey: "browser.tabs") as? [String] ?? []).compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme ?? "") }
        for u in saved.prefix(Self.maxTabs) { tabs.append(BrowserTab(url: u, browser: self, loadNow: false)) }    // restored lazily: nothing loads until it is shown
        let idx = defaults.integer(forKey: "browser.selected")
        selectedID = tabs.indices.contains(idx) ? tabs[idx].id : tabs.first?.id
    }

    // MARK: open / close
    func toggle() { isOpen ? close() : open() }

    func open(_ url: URL? = nil, newTab: Bool = true, background: Bool = false) {
        if let url, !["http", "https"].contains((url.scheme ?? "").lowercased()) { NSWorkspace.shared.open(url); return }
        if !isOpen {
            withAnimation(Theme.gentle) { isOpen = true }
            onOpened?()
        }
        if let url {
            if let t = selected, !background, (t.isBlank || !newTab) { t.load(url); select(t.id) }       // reuse an empty tab, or navigate in place
            else {
                let t = addTab(url)
                if !background { select(t.id) }
            }
        } else if tabs.isEmpty {
            let t = addTab(nil); select(t.id); addressFocusToken += 1
        } else if selected == nil, let first = tabs.first { select(first.id) }
        selected?.ensureLoaded()
        persist()
        scheduleRefresh(delay: 0.3)
    }

    func close() {
        withAnimation(Theme.gentle) { isOpen = false }
        refreshTask?.cancel()
        contextState = .idle
    }

    @discardableResult
    func addTab(_ url: URL?) -> BrowserTab {
        if tabs.count >= Self.maxTabs, let victim = tabs.first(where: { $0.id != selectedID }) { closeTab(victim.id, persistNow: false) }
        let t = BrowserTab(url: url, browser: self, loadNow: true)
        withAnimation(Theme.snappy) { tabs.append(t) }
        return t
    }

    func newTab() {
        if !isOpen { withAnimation(Theme.gentle) { isOpen = true }; onOpened?() }
        if let blank = tabs.first(where: { $0.isBlank }) { select(blank.id) } else { select(addTab(nil).id) }
        addressFocusToken += 1
        persist()
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        withAnimation(Theme.snappy) { selectedID = id }
        selected?.ensureLoaded()
        contextState = shareWithAI ? .idle : .off
        persist()
        scheduleRefresh(delay: 0.2)
    }

    func closeTab(_ id: UUID, persistNow: Bool = true) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = (id == selectedID)
        let tab = tabs[i]
        withAnimation(Theme.snappy) { _ = tabs.remove(at: i) }
        tab.teardown()
        if tabs.isEmpty { close() }
        else if wasSelected { select(tabs[min(i, tabs.count - 1)].id) }
        if persistNow { persist() }
    }

    // MARK: navigation
    func submit(_ input: String) {
        switch BrowserURL.resolve(input) {
        case .url(let u), .search(let u):
            if let t = selected { t.load(u) } else { select(addTab(u).id) }
            persist()
        case .blocked(let why):
            notify(why, icon: "exclamationmark.triangle.fill")
        }
    }
    func goBack() { selected?.goBack() }
    func goForward() { selected?.goForward() }
    func reload() { selected?.reload() }
    func stop() { selected?.stop() }
    func openInDefaultBrowser() { if let u = selected?.url { NSWorkspace.shared.open(u) } }
    func focusAddressBar() { if !isOpen { open() }; addressFocusToken += 1 }

    func clearBrowsingData() async {
        let store = dataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        recents = []; defaults.removeObject(forKey: "browser.recents")
        notify("Browsing data cleared (cookies, cache, site data, history).", icon: "trash")
        selected?.reload()
    }

    // MARK: notices
    func notify(_ text: String, icon: String, reveal: URL? = nil) {
        let n = Notice(text: text, icon: icon, reveal: reveal)
        withAnimation(Theme.smooth) { notice = n }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if Task.isCancelled { return }
            withAnimation(Theme.smooth) { if self?.notice?.id == n.id { self?.notice = nil } }
        }
    }
    func dismissNotice() { withAnimation(Theme.smooth) { notice = nil } }

    // MARK: signals from tabs
    func tabChanged(_ tab: BrowserTab) {
        guard tab.id == selectedID else { return }
        if tab.isLoading { if shareWithAI && isFeatureEnabled() { contextState = .loading } }
        else if case .loading = contextState { contextState = .idle }
    }
    func pageFinished(_ tab: BrowserTab) {
        onPageFinished?(tab)
        if let u = tab.url, ["http", "https"].contains(u.scheme ?? ""), tab.failure == nil { remember(u, title: tab.title) }
        persist()
        unchangedReads = 0                                                  // a new page: read it promptly again
        if tab.id == selectedID { scheduleRefresh(delay: 0.4) }
    }
    /// The page changed itself, was scrolled, or the selection changed.
    func pageChanged(_ tab: BrowserTab, delay: Double) { if tab.id == selectedID { scheduleRefresh(delay: delay) } }

    private func remember(_ url: URL, title: String) {
        guard !isolated else { return }
        let s = url.absoluteString
        recents.removeAll { $0.url == s }
        recents.insert(RecentSite(url: s, title: title.isEmpty ? (url.host ?? s) : title), at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        if let d = try? JSONEncoder().encode(recents) { defaults.set(d, forKey: "browser.recents") }
    }

    // MARK: sharing switches
    func setShare(_ on: Bool) {
        shareWithAI = on; defaults.set(on, forKey: "browser.share")
        contextState = on ? .idle : .off
        unchangedReads = 0
        if on { scheduleRefresh(delay: 0.1) }
    }
    func setAlwaysOCR(_ on: Bool) { alwaysOCR = on; defaults.set(on, forKey: "browser.alwaysOCR") }
    func setFraction(_ f: Double) { paneFraction = min(0.75, max(0.25, f)); defaults.set(paneFraction, forKey: "browser.fraction") }

    // MARK: reading the page
    /// Reads the live page right now for a chat message. Returns nil when there is nothing to share (pane closed, sharing off, blank tab).
    func contextForSend() async -> PagePayload? {
        guard wantsContext, let tab = selected else { return nil }
        capturing = true; contextState = .reading
        let r = await PageReader.read(tab, forceOCR: alwaysOCR)
        capturing = false
        apply(r, tab)
        return r.payload.isBlank ? nil : r.payload
    }

    /// Keeps the chip current as the user browses, WITHOUT a screenshot (cheap): debounced, at most one read per 4 seconds. If reads keep
    /// finding the same page (a site that animates ads or timers all day), the gap grows to 8, 16, then 32 seconds, and it resets on
    /// navigation. Nothing is read while ArjunOS is in the background; a message you send always reads the page fresh anyway.
    func scheduleRefresh(delay: Double) {
        guard isOpen, shareWithAI, isFeatureEnabled(), selected != nil, NSApplication.shared.isActive else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let gap = 4.0 * pow(2.0, Double(min(self.unchangedReads, 3)))
            let wait = gap - Date().timeIntervalSince(self.lastRefresh)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if Task.isCancelled { return }
            await self.refreshNow()
        }
    }

    func refreshNow(force: Bool = false) async {
        guard let tab = selected, isOpen, shareWithAI, isFeatureEnabled(), !capturing else { return }
        if tab.isLoading && !force { contextState = .loading; return }
        lastRefresh = Date()
        let r = await PageReader.read(tab, forceOCR: false, allowOCR: false)
        guard tab.id == selectedID, !capturing else { return }
        let signature = "\(r.payload.url)|\(r.payload.title)|\(r.payload.contentCount)|\(r.payload.status)"
        unchangedReads = signature == lastReadSignature ? unchangedReads + 1 : 0
        lastReadSignature = signature
        apply(r, tab)
    }

    private func apply(_ r: PageReadResult, _ tab: BrowserTab) {
        let p = r.payload
        withAnimation(Theme.smooth) {
            guard shareWithAI, isFeatureEnabled() else { contextState = .off; return }
            switch p.status {
            case "blank": contextState = .idle
            case "error", "restricted": contextState = .unavailable(p.statusDetail ?? "This page can't be read.")
            default:
                if p.contentCount == 0 && p.structured.isEmpty && !r.thin { contextState = .unavailable("Nothing readable on this page.") }
                else {
                    let host = URL(string: p.url)?.host ?? ""
                    contextState = .ready(PageSummary(title: p.title.isEmpty ? host : p.title, host: host, chars: p.contentCount, source: p.source,
                                                      updated: Date(), productData: !p.structured.isEmpty || !p.prices.isEmpty, thin: r.thin))
                }
            }
        }
    }

    // MARK: persistence
    private func persist() {
        guard !isolated else { return }
        let withURL = tabs.filter { $0.url != nil }                                  // blank tabs are not restored, so the index must ignore them
        defaults.set(withURL.compactMap { $0.url?.absoluteString }, forKey: "browser.tabs")
        defaults.set(withURL.firstIndex { $0.id == selectedID } ?? 0, forKey: "browser.selected")
    }
}
