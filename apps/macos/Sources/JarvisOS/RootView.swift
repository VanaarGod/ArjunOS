import SwiftUI
import JarvisCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    private let sidebarWidth: CGFloat = 272 + 10
    private let minChat: CGFloat = 400
    private let minBrowser: CGFloat = 360

    /// Width of the browser pane: the user's chosen fraction, but never so wide that the chat gets crushed, nor so narrow it is unusable.
    private func browserWidth(_ total: CGFloat) -> CGFloat {
        let maxW = max(minBrowser, total - sidebarWidth - minChat)
        return min(maxW, max(minBrowser, total * CGFloat(model.browser.paneFraction)))
    }

    var body: some View {
        let browser = model.browser
        ZStack {
            AmbientBackground(paused: model.windowIdle)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: 272)
                        .padding(.leading, 10).padding(.vertical, 10)
                    VStack(spacing: 0) {
                        if case .failed(let msg) = model.bridgeState { BridgeFailureBanner(message: msg).padding(.top, 28) }
                        if let e = model.lastError { ErrorStrip(text: e) }
                        detail
                            .id(model.selection)
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                    .frame(minWidth: minChat, maxWidth: .infinity)
                    .animation(.smooth(duration: 0.28), value: model.selection)
                    if browser.isOpen {
                        SplitHandle(totalWidth: geo.size.width)
                        BrowserPane()
                            .frame(width: browserWidth(geo.size.width))
                            .padding(.trailing, 10).padding(.vertical, 10)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)          // GeometryReader would otherwise pin the content to the top-left
                .animation(Theme.gentle, value: browser.isOpen)
            }
            .overlay(alignment: .topTrailing) {
                if !browser.isOpen { BrowserToggleButton().padding(.top, 12).padding(.trailing, 16).transition(.opacity) }
            }
        }
        .overlay { if model.needsWelcome { WelcomeOverlay().transition(.opacity) } }          // first launch: ask what to call the user
        .animation(.smooth(duration: 0.25), value: model.needsWelcome)
        .frame(minWidth: browser.isOpen ? 1180 : 1020, minHeight: 680)
        .environment(browser)
        .environment(\.openURL, OpenURLAction { url in model.openLink(url); return .handled })     // links in chat open in the built-in browser
        .background(WindowAccessor())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .chat: ChatScreen()
        case .crew: Screen { CrewView() }
        case .models: Screen { ModelsView() }
        case .tools: Screen { McpView() }
        case .memory: Screen { MemoryView() }
        case .voice: Screen { NotImplementedView(title: "Voice", detail: "Microphone capture, local speech recognition (whisper.cpp), Piper TTS and the voice loop are not implemented yet. This build never records audio.") }
        case .tasks: Screen { TasksView() }
        case .knowledge: Screen { VaultView() }
        case .system: Screen { SystemView() }
        case .settings: Screen { SettingsView() }
        }
    }
}

/// Wraps secondary screens: clears the traffic-light area and keeps the content on the shared background.
struct Screen<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(.top, 30).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct BridgeBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
        }
        .animation(Theme.smooth, value: label)
        .accessibilityElement(children: .combine)
    }
    private var color: Color { switch model.bridgeState { case .running: .green; case .starting: .yellow; case .stopped: .gray; case .failed: .red } }
    private var label: String {
        switch model.bridgeState {
        case .running(let p): "Bridge running (port \(p))"; case .starting: "Bridge starting…"
        case .stopped: "Bridge stopped"; case .failed: "Bridge failed"
        }
    }
}

struct BridgeFailureBanner: View {
    @Environment(AppModel.self) private var model
    let message: String
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading) {
                Text("The local AI bridge is not running").bold()
                Text(message).font(.caption).textSelection(.enabled)
                Text("Chat, models and memory need the bridge. Run scripts/setup.sh (or fix the Python path in Settings), then retry.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(); Button("Retry") { Task { await model.restartBridge() } }.buttonStyle(GlassButtonStyle())
        }.padding(12).liquidGlass(in: RoundedRectangle(cornerRadius: 14), tint: .red.opacity(0.5)).padding(.horizontal, 16)
    }
}

struct ErrorStrip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)).textSelection(.enabled)
    }
}

struct NotImplementedView: View {
    let title: String, detail: String
    var body: some View {
        ContentUnavailableView { Label("\(title): not implemented yet", systemImage: "hammer") } description: { Text(detail) }
    }
}
