import SwiftUI
import AppKit
import JarvisCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare `swift run` executable has no bundle, so macOS would not give it keyboard focus. Force a regular,
        // frontmost app. (The packaged .app gets this automatically; this keeps dev runs working.)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        watchWindows()
        model.floating.start(model: model)         // pet / mini chat / global shortcut; independent of the main window
        Task { await model.bootstrap() }          // once per launch, NOT per window, so closing and reopening never restarts the bridge
    }

    /// Closing the window does not quit: ArjunOS keeps working from the menu bar and shows the sleep icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .arjunOpenMainWindow, object: nil) }
        return true
    }

    /// Stop the bridge we own BEFORE quitting (an async Task in willTerminate may never get to run).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await self.model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Window open/closed drives the sleep icon. "Closed" means no main window is showing; being covered by other apps does not count.
    private func watchWindows() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        for n in names {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshWindowVisibility() }      // after the close finishes, not before
            })
        }
        refreshWindowVisibility()
    }
    private func refreshWindowVisibility() { model.setWindowVisible(AppWindows.isMainVisible); model.setWindowOccluded(AppWindows.isMainOccluded) }
}

@main
struct JarvisOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ArjunOS", id: "main") {
            RootView()
                .environment(delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Chat") { delegate.model.newConversation() }.keyboardShortcut("n") }
            CommandMenu("Assistant") {
                Button("Show or Hide Floating Chat") { delegate.model.floating.toggleChat() }
                Button(delegate.model.floating.petVisible ? "Hide Pet" : "Show Pet") { delegate.model.floating.togglePet() }
                    .disabled(!delegate.model.floating.settings.displayMode.showsPet)
            }
            CommandMenu("Browser") {
                Button("Show or Hide Browser") { delegate.model.browser.toggle() }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("New Tab") { delegate.model.browser.newTab() }.keyboardShortcut("t")
                Button("Open Location…") { delegate.model.browser.focusAddressBar() }.keyboardShortcut("l")
                Divider()
                Button("Reload Page") { delegate.model.browser.reload() }.keyboardShortcut("r")
                Button("Back") { delegate.model.browser.goBack() }.keyboardShortcut("[")
                Button("Forward") { delegate.model.browser.goForward() }.keyboardShortcut("]")
                Divider()
                Button("Close Tab") { if let id = delegate.model.browser.selectedID { delegate.model.browser.closeTab(id) } }.keyboardShortcut("w", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(delegate.model)
        } label: {
            MenuBarLabel().environment(delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}
