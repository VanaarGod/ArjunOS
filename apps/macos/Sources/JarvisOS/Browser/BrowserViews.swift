import SwiftUI
import WebKit
import AppKit
import JarvisCore

// MARK: - Hosting a tab's web view

/// Shows one tab's WKWebView. Each tab keeps its own web view alive, so switching tabs never reloads a page.
struct WebHost: NSViewRepresentable {
    let tab: BrowserTab
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(tab.webView, to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        if tab.webView.superview !== container { attach(tab.webView, to: container) }
    }
    static func dismantleNSView(_ container: NSView, coordinator: ()) { container.subviews.forEach { $0.removeFromSuperview() } }
    private func attach(_ wv: WKWebView, to container: NSView) {
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([wv.leadingAnchor.constraint(equalTo: container.leadingAnchor), wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                     wv.topAnchor.constraint(equalTo: container.topAnchor), wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
    }
}

// MARK: - The pane

struct BrowserPane: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(spacing: 8) {
            GlassGroup(spacing: 8) {
                VStack(spacing: 8) {
                    BrowserTabStrip()
                    if let tab = browser.selected { BrowserToolbar(tab: tab) }
                }
            }
            ZStack(alignment: .top) {
                if let tab = browser.selected {
                    BrowserContent(tab: tab).id(tab.id).transition(.opacity)
                } else {
                    EmptyBrowser()
                }
                if let n = browser.notice { NoticeBar(notice: n).padding(10).transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .animation(Theme.smooth, value: browser.selectedID)
        }
    }
}

struct BrowserContent: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.07, green: 0.07, blue: 0.08)
            if tab.isBlank && tab.failure == nil { NewTabPage() }
            else { WebHost(tab: tab) }
            if let f = tab.failure { FailureView(tab: tab, failure: f).transition(.opacity) }
            LoadingBar(progress: tab.progress, active: tab.isLoading)
        }
        .animation(Theme.smooth, value: tab.failure)
    }
}

struct LoadingBar: View {
    let progress: Double
    let active: Bool
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(8, geo.size.width * (active ? max(0.08, progress) : 1)), height: 2.5)
                .opacity(active ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: progress)
                .animation(.easeOut(duration: 0.35), value: active)
        }
        .frame(height: 2.5).allowsHitTesting(false)
    }
}

struct EmptyBrowser: View {
    @Environment(BrowserModel.self) private var browser
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("No tabs open").font(.headline)
            Button { browser.newTab() } label: { Label("New tab", systemImage: "plus") }.buttonStyle(GlassButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

// MARK: - Tabs

struct BrowserTabStrip: View {
    @Environment(BrowserModel.self) private var browser
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(browser.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == browser.selectedID, ns: ns)
                            .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity), removal: .scale(scale: 0.85).combined(with: .opacity)))
                    }
                }
                .padding(.horizontal, 2)
            }
            Button { browser.newTab() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(GlassCircleButtonStyle(size: 28)).help("New tab (⌘T)")
            Button { browser.close() } label: { Image(systemName: "sidebar.right").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(GlassCircleButtonStyle(size: 28)).help("Hide the browser (⇧⌘B)")
        }
        .padding(6)
        .liquidGlass(in: Capsule())
        .animation(Theme.snappy, value: browser.tabs.count)
    }
}

struct TabChip: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    let ns: Namespace.ID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
            else { Image(systemName: tab.isBlank ? "plus.square" : "globe").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14, height: 14) }
            Text(tab.isBlank ? "New tab" : tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            if selected || hovering {
                Button { browser.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Circle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close tab")
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background {
            if selected {
                Capsule().fill(Color.white.opacity(0.14)).overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                    .matchedGeometryEffect(id: "tabpill", in: ns)
            }
        }
        .hoverFill(cornerRadius: 14, strength: selected ? 0 : 0.07)
        .contentShape(Capsule())
        .onTapGesture { browser.select(tab.id) }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(tab.url?.absoluteString ?? "New tab")
    }
}

// MARK: - Toolbar and address bar

struct BrowserToolbar: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    var body: some View {
        HStack(spacing: 6) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(GlassCircleButtonStyle(size: 28)).disabled(!tab.canGoBack).help("Back")
            Button { browser.goForward() } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(GlassCircleButtonStyle(size: 28)).disabled(!tab.canGoForward).help("Forward")
            AddressBar(tab: tab)
            Menu {
                Button { browser.openInDefaultBrowser() } label: { Label("Open in your default browser", systemImage: "safari") }.disabled(tab.url == nil)
                Button { if let u = tab.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) } } label: { Label("Copy link", systemImage: "link") }.disabled(tab.url == nil)
                Divider()
                Toggle(isOn: Binding(get: { browser.alwaysOCR }, set: { browser.setAlwaysOCR($0) })) { Label("Also read a screenshot of the page (OCR)", systemImage: "text.viewfinder") }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .liquidGlass(in: Circle(), interactive: true)
        }
        .padding(6)
        .liquidGlass(in: Capsule())
    }
}

struct AddressBar: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.isBlank ? "magnifyingglass" : (tab.secure ? "lock.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 11)).foregroundStyle(tab.isBlank || tab.secure ? Color.secondary : Color.orange)
                .help(tab.isBlank ? "" : (tab.secure ? "Secure connection" : "This page isn't using a secure connection"))
            TextField("Search or enter a URL", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                .onSubmit { browser.submit(text); focused = false }
                .autocorrectionDisabled()
            if tab.isLoading {
                Button { browser.stop() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).help("Stop")
            } else if !tab.isBlank {
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }.buttonStyle(.plain).help("Reload (⌘R)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(focused ? 0.10 : 0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { text = shown }
        .onChange(of: tab.url) { _, _ in if !focused { text = shown } }
        .onChange(of: tab.title) { _, _ in if !focused { text = shown } }
        .onChange(of: focused) { _, now in
            if now { text = tab.url?.absoluteString ?? ""; DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
            else { text = shown }
        }
        .onChange(of: browser.addressFocusToken) { _, _ in focused = true }
    }

    private var shown: String { tab.isBlank ? "" : (tab.host.isEmpty ? (tab.url?.absoluteString ?? "") : tab.host) }
}

// MARK: - New tab, errors, notices

struct NewTabPage: View {
    @Environment(BrowserModel.self) private var browser
    @State private var query = ""
    @FocusState private var focused: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "globe.americas.fill").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent).staggerIn(0)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search or enter a URL", text: $query).textFieldStyle(.plain).font(.system(size: 14)).focused($focused).onSubmit { browser.submit(query) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(focused ? 0.10 : 0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: focused ? 1.5 : 1))
                .animation(.easeOut(duration: 0.15), value: focused)
                .frame(maxWidth: 420).staggerIn(1)
                Text("Open a page, then ask about it in the chat.").font(.callout).foregroundStyle(.secondary).staggerIn(2)
                if !browser.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent").font(.caption).foregroundStyle(.tertiary).padding(.leading, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(Array(browser.recents.enumerated()), id: \.element.id) { i, r in
                                Button { if let u = URL(string: r.url) { browser.selected?.load(u) } } label: {
                                    HStack(spacing: 8) {
                                        Text(String((URL(string: r.url)?.host ?? "?").replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                                            .font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24).background(Theme.accent.opacity(0.25), in: Circle())
                                        Text(r.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(8).liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
                                }
                                .buttonStyle(.plain).staggerIn(3 + i)
                            }
                        }
                    }.frame(maxWidth: 520)
                }
            }
            .padding(.top, 70).padding(.horizontal, 24).frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
    }
}

struct FailureView: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    let failure: BrowserFailure
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .light)).foregroundStyle(Color.orange).symbolEffect(.bounce, value: failure)
            Text(failure.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(failure.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack {
                if failure.canRetry { Button { browser.reload() } label: { Label("Try again", systemImage: "arrow.clockwise") }.buttonStyle(GlassButtonStyle(prominent: true)) }
                if tab.url != nil { Button { browser.openInDefaultBrowser() } label: { Label("Open in Safari", systemImage: "safari") }.buttonStyle(GlassButtonStyle()) }
            }
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

struct NoticeBar: View {
    @Environment(BrowserModel.self) private var browser
    let notice: BrowserModel.Notice
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.icon).foregroundStyle(Theme.accent)
            Text(notice.text).font(.callout).lineLimit(2)
            Spacer(minLength: 6)
            if let r = notice.reveal { Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([r]) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout.weight(.semibold)) }
            Button { browser.dismissNotice() } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liquidGlass(in: Capsule())
    }
}

// MARK: - Layout helpers used by RootView

/// The draggable divider between the chat and the browser.
struct SplitHandle: View {
    @Environment(BrowserModel.self) private var browser
    let totalWidth: CGFloat
    @State private var startFraction: Double?
    @State private var hovering = false
    var body: some View {
        Color.clear.frame(width: 12).contentShape(Rectangle())
            .overlay(Capsule().fill(Color.white.opacity(hovering ? 0.4 : 0.18)).frame(width: 3, height: hovering ? 48 : 36).animation(Theme.snappy, value: hovering))
            .onHover { inside in
                if inside && !hovering { NSCursor.resizeLeftRight.push() } else if !inside && hovering { NSCursor.pop() }
                hovering = inside
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = startFraction ?? browser.paneFraction
                    startFraction = start
                    browser.setFraction(start - Double(v.translation.width / max(totalWidth, 1)))
                }
                .onEnded { _ in startFraction = nil })
            .help("Drag to resize")
    }
}

struct BrowserToggleButton: View {
    @Environment(BrowserModel.self) private var browser
    var body: some View {
        Button { browser.toggle() } label: { Image(systemName: browser.isOpen ? "sidebar.right" : "globe").font(.system(size: 14, weight: .medium)).contentTransition(.symbolEffect(.replace)) }
            .buttonStyle(GlassCircleButtonStyle(size: 34)).help(browser.isOpen ? "Hide the browser (⇧⌘B)" : "Open the browser (⇧⌘B)")
    }
}

// MARK: - "What the assistant can see" chip above the composer

struct PageChip: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppModel.self) private var model

    var body: some View {
        if browser.isOpen, let tab = browser.selected {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(tab)).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle).contentTransition(.opacity)
                    if let sub = subline { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if browser.shareWithAI && featureOn {
                    Button { Task { await browser.refreshNow(force: true) } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Read the page again now")
                }
                Button { browser.setShare(!browser.shareWithAI) } label: {
                    Image(systemName: browser.shareWithAI ? "eye.fill" : "eye.slash").font(.system(size: 12)).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).foregroundStyle(browser.shareWithAI ? Theme.accent : Color.secondary).disabled(!featureOn)
                .help(browser.shareWithAI ? "The assistant uses this page. Click to stop sharing it." : "Not sharing this page. Click to share it.")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .liquidGlass(in: Capsule(), tint: stateTint)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(Theme.smooth, value: browser.contextState)
            .animation(Theme.smooth, value: browser.shareWithAI)
        }
    }

    private var featureOn: Bool { model.settings?.browserEnabled ?? true }

    @ViewBuilder private var icon: some View {
        switch browser.contextState {
        case .reading, .loading: ProgressView().controlSize(.small).frame(width: 18, height: 18)
        case .unavailable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).frame(width: 18, height: 18)
        case .off: Image(systemName: "eye.slash").foregroundStyle(.secondary).frame(width: 18, height: 18)
        case .ready: Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Theme.accent).symbolEffect(.bounce, value: browser.contextState).frame(width: 18, height: 18)
        case .idle: Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 18, height: 18)
        }
    }

    private func headline(_ tab: BrowserTab) -> String {
        if !featureOn { return "Page context is off in Settings" }
        switch browser.contextState {
        case .off: return "Not sharing this page"
        case .loading: return "Page is loading…"
        case .reading: return "Reading the page…"
        case .unavailable(let why): return why
        case .ready(let s): return "Using “\(s.title)”"
        case .idle: return tab.isBlank ? "Open a page to ask about it" : "Ask about “\(tab.title)”"
        }
    }

    private var subline: String? {
        guard featureOn, case .ready(let s) = browser.contextState else { return nil }
        var bits = ["\(s.host)", "\(s.chars.formatted()) characters"]
        if s.source == "pdf" { bits.append("PDF") }
        if s.productData { bits.append("product data") }
        if s.thin { bits.append("mostly images: reads a screenshot when you ask") }
        return bits.joined(separator: " · ")
    }

    private var stateTint: Color? {
        if case .unavailable = browser.contextState { return Color.orange.opacity(0.25) }
        if case .ready = browser.contextState, browser.shareWithAI { return Theme.accent.opacity(0.18) }
        return nil
    }
}
