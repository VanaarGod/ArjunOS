import SwiftUI
import AppKit
import JarvisCore

extension Notification.Name {
    static let arjunOpenMainWindow = Notification.Name("ArjunOS.openMainWindow")
}

/// Finding, showing and watching the one main window.
@MainActor
enum AppWindows {
    static func isMain(_ w: NSWindow) -> Bool { w.canBecomeMain && !(w is NSPanel) && w.level == .normal }
    static func mainWindow() -> NSWindow? { NSApp.windows.first { isMain($0) } }
    static var isMainVisible: Bool { NSApp.windows.contains { isMain($0) && $0.isVisible && !$0.isMiniaturized } }
    /// Completely covered by other windows (or on another Space): nothing in it can be seen, so nothing in it should animate.
    static var isMainOccluded: Bool {
        guard let w = mainWindow() else { return true }
        return !w.occlusionState.contains(.visible)
    }

    /// Makes room for the browser pane: widens the window (animated, never past the screen) if it is narrower than `target`.
    static func ensureWidth(_ target: CGFloat) {
        guard let win = mainWindow(), let screen = win.screen ?? NSScreen.main, !win.styleMask.contains(.fullScreen) else { return }
        let vis = screen.visibleFrame
        let want = min(target, vis.width - 20)
        guard win.frame.width < want - 1 else { return }
        var f = win.frame
        f.size.width = want
        if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - want) }
        win.setFrame(f, display: true, animate: true)
    }

    /// Reliable "Open": re-shows a hidden/minimised window, or asks SwiftUI to create it if it was really closed.
    static func show(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        if let w = mainWindow() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Draws the menu bar icon for each state. Sleep, thinking and ready are monochrome (they follow the menu bar's light/dark look);
/// done, approval and error are coloured, which needs a non-template image.
enum MenuBarIcon {
    @MainActor
    static func image(for state: MenuState, frame: Int) -> NSImage {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch state {
        case .asleep:
            return symbol("moon.zzz.fill", palette: nil, label: "ArjunOS is asleep")
        case .idle:
            return symbol("waveform.circle", palette: nil, label: "ArjunOS is ready")
        case .thinking:
            let frames = ["ellipsis.bubble", "ellipsis.bubble.fill", "ellipsis.bubble"]
            return symbol(frames[reduce ? 1 : frame % frames.count], palette: nil, label: "ArjunOS is thinking")
        case .needsApproval:
            return symbol("hand.raised.fill", palette: [.systemOrange], label: "ArjunOS is waiting for your approval")
        case .done:
            return symbol("checkmark.circle.fill", palette: [.white, .systemGreen], label: "ArjunOS is done", pointSize: 13)
        case .error:
            return symbol("exclamationmark.triangle.fill", palette: [.white, .systemRed], label: "ArjunOS needs attention")
        }
    }

    private static func symbol(_ name: String, palette: [NSColor]?, label: String, pointSize: CGFloat = 15) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        if let palette { config = config.applying(NSImage.SymbolConfiguration(paletteColors: palette)) }
        guard let raw = NSImage(systemSymbolName: name, accessibilityDescription: label),
              let img = raw.withSymbolConfiguration(config) else { return NSImage(size: NSSize(width: 18, height: 18)) }
        img.isTemplate = (palette == nil)
        return img
    }
}

/// The menu bar item itself. It re-renders whenever `menuState` or `menuFrame` changes.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: model.menuState, frame: model.menuFrame))
            .accessibilityLabel("\(model.assistantName): \(model.menuState.label)")
            .onReceive(NotificationCenter.default.publisher(for: .arjunOpenMainWindow)) { _ in AppWindows.show(openWindow) }
    }
}

/// The popover under the menu bar icon.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let a = model.approvals.first { approvalCard(a) }
            HStack(spacing: 10) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text(model.selectedModelShortName ?? "No model connected").font(.callout).lineLimit(1).truncationMode(.middle).help(model.selectedModelName ?? "")
                Spacer()
                BridgeBadge()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 8) {
                Button { model.floating.toggleChat() } label: { Label(model.floating.chatOpen ? "Hide chat" : "Mini chat", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity) }
                    .buttonStyle(GlassButtonStyle()).help("Shortcut: \(model.floating.settings.hotKey.display)")
                Button { model.floating.togglePet() } label: { Label(model.floating.petVisible ? "Hide pet" : "Show pet", systemImage: "pawprint").frame(maxWidth: .infinity) }
                    .buttonStyle(GlassButtonStyle()).disabled(!model.floating.settings.displayMode.showsPet)
            }

            Button { AppWindows.show(openWindow) } label: {
                Label("Open \(model.assistantName)", systemImage: "macwindow").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(prominent: true))
            .keyboardShortcut("o")

            HStack(spacing: 8) {
                Button { model.newConversation(); AppWindows.show(openWindow) } label: { Label("New chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(GlassButtonStyle())
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power").frame(maxWidth: .infinity) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 310)
        .animation(Theme.smooth, value: model.menuState)
        .animation(Theme.smooth, value: model.approvals.count)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AssistantOrb(size: 40, thinking: model.menuState == .thinking)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.assistantName).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(model.menuState.label).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
                }
            }
            Spacer()
        }
    }

    private var stateColor: Color {
        switch model.menuState {
        case .done: .green; case .thinking: Theme.accent; case .needsApproval: .orange; case .error: .red
        case .idle: .secondary; case .asleep: .gray
        }
    }

    /// Approve or deny a pending command right here, even when the window is closed.
    private func approvalCard(_ a: Approval) -> some View {
        let command: String? = { if case .string(let c)? = a.args["command"] { return c } else { return nil } }()
        return VStack(alignment: .leading, spacing: 8) {
            Label(command != nil ? "Wants to run a command" : "Wants to use \(a.tool)", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(Color.orange)
            if let command {
                Text("$ \(command)").font(.system(size: 12, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Button("Deny") { Task { await model.resolve(a.id, approve: false) } }.buttonStyle(GlassButtonStyle())
                Button(command != nil ? "Run once" : "Approve once") { Task { await model.resolve(a.id, approve: true) } }.buttonStyle(GlassButtonStyle(prominent: true))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Color.orange.opacity(0.28))
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}
