import SwiftUI
import AppKit
import Observation
import JarvisCore

/// A panel that can take the keyboard without making ArjunOS the frontmost app, so the app you are working in stays in front.
final class FloatingChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
/// The pet never takes focus: clicking it must not steal the keyboard from what you are typing in.
final class FloatingPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the pet window, the mini chat window and the global shortcut. Both windows are views onto the one `AppModel`,
/// so they share its conversation, model, approvals, attachments and page awareness with the main window.
@MainActor @Observable
final class FloatingAssistantController {
    private(set) var settings: FloatingSettings
    private(set) var chatOpen = false
    private(set) var petHovering = false
    private(set) var petPulse = 0                 // bumped on every click so the pet can react
    private(set) var petDragging = false            // true while the pet is being dragged (a Codex pet runs in that direction)
    private(set) var petDragDirection = 1           // +1 right, -1 left
    let pets = PetLibraryModel()                    // Codex pets found in ~/.codex/pets and this app's own pets folder
    var chatPinned = false                        // Pet Only: keep the chat open when you click elsewhere
    var focusRequest = 0                          // bumped whenever the chat should focus its text box
    var hotKeyError: String?
    var suppressDismiss = false                   // set while a file picker is open, so the chat is not dismissed behind it

    @ObservationIgnored private let store = FloatingSettingsStore()
    @ObservationIgnored private let hadSavedState: Bool
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var petPanel: FloatingPetPanel?
    @ObservationIgnored private var chatPanel: FloatingChatPanel?
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private var attachedOffset: CGPoint?        // chat origin minus pet origin while the chat is attached to the pet
    @ObservationIgnored private var programmaticMove = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init() {
        hadSavedState = UserDefaults.standard.data(forKey: FloatingSettingsStore.key) != nil
        settings = FloatingSettingsStore().load()
    }

    // MARK: Lifecycle

    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        hotKey.onPress = { [weak self] in self?.toggleChat() }
        pets.rescan()
        applyHotKey()
        chatOpen = FloatingPolicy.chatOpenAtLaunch(mode: settings.displayMode, wasOpen: settings.chatWasOpen, hasSavedState: hadSavedState)
        watch()
        apply()
    }

    private func watch() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        })
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let w = n.object as? NSWindow, w === self.chatPanel, !self.programmaticMove else { return }
                self.chatMovedByUser()
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let w = n.object as? NSWindow, w === self.chatPanel else { return }
                self.mutate { $0.chatWidth = w.frame.width; $0.chatHeight = w.frame.height }
                self.chatMovedByUser()
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                guard let self, let w = n.object as? NSWindow, w === self.chatPanel else { return }
                self.chatLostFocus()
            }
        })
    }

    // MARK: Settings

    private func mutate(_ change: (inout FloatingSettings) -> Void) {
        var s = settings; change(&s); s.sanitize()
        guard s != settings else { return }
        settings = s; store.save(s)
    }

    func setMode(_ mode: FloatingDisplayMode) {
        guard mode != settings.displayMode else { return }
        let open = FloatingPolicy.chatOpenAfterModeChange(to: mode, currentlyOpen: chatOpen)
        mutate { $0.displayMode = mode; if mode.showsPet { $0.petHidden = false }; $0.chatWasOpen = open }
        chatOpen = open; chatPinned = false
        apply()
    }

    func setPetHidden(_ hidden: Bool) {
        mutate { $0.petHidden = hidden }
        syncPet(); if chatOpen { placeChat() }
    }

    func setStyle(_ s: PetStyle) { mutate { $0.petStyle = s } }
    /// Choose a Codex pet by id, or nil for the built-in look.
    func setPetID(_ id: String?) { mutate { $0.petID = id } }
    func setColor(_ c: PetColor) { mutate { $0.petColor = c } }
    func setIdleOpacity(_ v: Double) { mutate { $0.petIdleOpacity = v } }
    func setSnap(_ on: Bool) { mutate { $0.snapToEdges = on } }
    func setShareScreen(_ on: Bool) { mutate { $0.shareScreen = on } }
    func setSize(_ v: Double) {
        mutate { $0.petSize = v }
        syncPet(); if chatOpen && attached { placeChat() }
    }

    func movePet(to corner: PetCorner) {
        let f = corner.fractions
        mutate { $0.petAnchor = PetAnchor(screenID: $0.petAnchor.screenID, fx: f.fx, fy: f.fy) }
        syncPet(animated: true); if chatOpen && attached { placeChat() }
    }
    func resetPetPosition() {
        mutate { $0.petAnchor = .default }
        syncPet(animated: true); if chatOpen && attached { placeChat() }
    }

    // MARK: Shortcut

    @discardableResult
    func setHotKey(_ combo: HotKeyCombo) -> Bool {
        guard combo.isValid else { hotKeyError = "A shortcut needs Control or Command, plus a key."; return false }
        let previous = settings.hotKey
        switch hotKey.register(combo) {
        case .success:
            mutate { $0.hotKey = combo }; hotKeyError = nil; return true
        case .failure(let f):
            _ = hotKey.register(previous)
            hotKeyError = f == .taken ? "\(combo.display) is already used by another app or by macOS. Choose a different shortcut." : "macOS refused \(combo.display) (error \(f)). Choose a different shortcut."
            return false
        }
    }
    func resetHotKey() { setHotKey(.default) }
    func beginShortcutRecording() { hotKey.unregister() }          // otherwise the current shortcut would fire while you press the new one
    func endShortcutRecording() { applyHotKey() }

    private func applyHotKey() {
        switch hotKey.register(settings.hotKey) {
        case .success: hotKeyError = nil
        case .failure(let f):
            hotKeyError = f == .taken ? "\(settings.hotKey.display) is already used by another app or by macOS. Choose a different shortcut in Settings."
                                      : "The shortcut \(settings.hotKey.display) could not be registered (error \(f))."
        }
    }

    // MARK: Pet window

    var petVisible: Bool { FloatingPolicy.petVisible(mode: settings.displayMode, petHidden: settings.petHidden) }
    private var attached: Bool { FloatingPolicy.chatAttachesToPet(mode: settings.displayMode, petHidden: settings.petHidden) }

    func setHovering(_ on: Bool) { petHovering = on }

    private func apply() { syncPet(); syncChat() }

    private func screen(for id: UInt32?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    private func screenID(_ s: NSScreen) -> UInt32? { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    private var anchorScreen: NSScreen { screen(for: settings.petAnchor.screenID) ?? NSScreen.main ?? NSScreen.screens[0] }
    private func bestScreen(for rect: CGRect) -> NSScreen {
        NSScreen.screens.max { a, b in a.frame.intersection(rect).area < b.frame.intersection(rect).area } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func petFrameFromSettings() -> CGRect {
        FloatingLayout.petFrame(anchor: settings.petAnchor, petSize: CGFloat(settings.petSize), visible: anchorScreen.visibleFrame)
    }

    private func syncPet(animated: Bool = false) {
        guard petVisible, !NSScreen.screens.isEmpty else { petPanel?.orderOut(nil); return }
        let panel = petPanel ?? makePetPanel()
        panel.setFrame(petFrameFromSettings(), display: true, animate: animated && !reduceMotion)
        panel.orderFrontRegardless()
    }

    private func makePetPanel() -> FloatingPetPanel {
        let p = FloatingPetPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)          // above the chat, so it never gets covered
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false; p.isMovable = false; p.animationBehavior = .none
        p.title = "ArjunOS pet"
        if let model {
            let host = NSHostingView(rootView: PetView(controller: self).environment(model))
            host.sizingOptions = []
            let container = PetContainerView(controller: self, hosting: host)
            p.contentView = container
        }
        petPanel = p
        return p
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Called by the pet's window while it is dragged / dropped / clicked.
    func petDragged(to origin: CGPoint) {
        guard let p = petPanel else { return }
        let dx = origin.x - p.frame.origin.x
        if abs(dx) > 0.5 { petDragDirection = dx > 0 ? 1 : -1 }
        petDragging = true
        p.setFrameOrigin(origin)
        if let off = attachedOffset, chatOpen, attached, let c = chatPanel {
            programmaticMove = true
            c.setFrameOrigin(CGPoint(x: origin.x + off.x, y: origin.y + off.y))
            programmaticMove = false
        }
    }

    func petDropped() {
        petDragging = false
        guard let p = petPanel else { return }
        let screen = bestScreen(for: p.frame)
        let settled = FloatingLayout.settle(p.frame, visible: screen.visibleFrame, snap: settings.snapToEdges)
        p.setFrame(settled, display: true, animate: !reduceMotion)
        let anchor = FloatingLayout.anchor(for: settled, visible: screen.visibleFrame, screenID: screenID(screen))
        mutate { $0.petAnchor = anchor }
        if chatOpen && attached { placeChat(keepOffset: true) }
    }

    func petClicked() { petPulse += 1; toggleChat() }

    private func screensChanged() {
        syncPet()
        if chatOpen { placeChat() }
    }

    // MARK: Chat window

    func toggleChat() { setChatOpen(!chatOpen) }

    func setChatOpen(_ open: Bool) {
        guard open != chatOpen else { if open { focusChat() }; return }
        chatOpen = open
        mutate { $0.chatWasOpen = open }
        syncChat()
    }

    func togglePet() { setPetHidden(petVisible) }

    func focusChat() { chatPanel?.makeKeyAndOrderFront(nil); petPanel?.orderFrontRegardless(); focusRequest += 1 }

    private func syncChat() {
        if chatOpen { showChat() } else { hideChat() }
    }

    private func makeChatPanel() -> FloatingChatPanel? {
        guard let model else { return nil }
        let p = FloatingChatPanel(contentRect: NSRect(origin: .zero, size: settings.chatSize),
                                  styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isMovableByWindowBackground = true
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.minSize = FloatingSettings.chatMinSize
        p.appearance = NSAppearance(named: .darkAqua)
        p.title = "\(model.assistantName) mini chat"
        let host = NSHostingView(rootView: MiniChatView(controller: self).environment(model).environment(model.browser))
        host.sizingOptions = []
        p.contentView = host
        chatPanel = p
        return p
    }

    private func showChat() {
        guard let panel = chatPanel ?? makeChatPanel() else { return }
        placeChat()
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = reduceMotion ? 1 : 0 }
        panel.makeKeyAndOrderFront(nil)
        petPanel?.orderFrontRegardless()
        if !wasVisible && !reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 } }
        model?.clearDone()
        focusRequest += 1
    }

    private func hideChat() {
        guard let panel = chatPanel, panel.isVisible else { return }
        if reduceMotion { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            Task { @MainActor in if self?.chatOpen == false { panel.orderOut(nil) }; panel.alphaValue = 1 }
        })
    }

    /// Puts the chat beside the pet (or at its saved spot when there is no pet) and remembers how far it sits from the pet.
    private func placeChat(keepOffset: Bool = false) {
        guard let panel = chatPanel else { return }
        let size = settings.chatSize
        var frame: CGRect
        if attached, let pet = petPanel, pet.isVisible || petVisible {
            let petFrame = pet.frame
            let screen = bestScreen(for: petFrame)
            if keepOffset, let off = attachedOffset {
                frame = FloatingLayout.clamp(CGRect(origin: CGPoint(x: petFrame.origin.x + off.x, y: petFrame.origin.y + off.y), size: panel.frame.size), to: screen.visibleFrame)
            } else {
                frame = FloatingLayout.chatFrame(besidePet: petFrame, chatSize: keepOffset ? panel.frame.size : size, visible: screen.visibleFrame)
            }
            attachedOffset = CGPoint(x: frame.origin.x - petFrame.origin.x, y: frame.origin.y - petFrame.origin.y)
        } else {
            attachedOffset = nil
            let screen = NSScreen.main ?? NSScreen.screens[0]
            if let o = settings.chatOrigin, o.count == 2 {
                let probe = CGRect(origin: CGPoint(x: o[0], y: o[1]), size: size)
                frame = FloatingLayout.clamp(probe, to: bestScreen(for: probe).visibleFrame)
            } else {
                frame = FloatingLayout.defaultChatFrame(chatSize: size, visible: screen.visibleFrame)
            }
        }
        programmaticMove = true
        panel.setFrame(frame, display: true)
        programmaticMove = false
    }

    /// The user dragged or resized the chat window: remember it (as an offset from the pet, or as a screen position without one).
    private func chatMovedByUser() {
        guard let c = chatPanel, c.isVisible else { return }
        if attached, let pet = petPanel {
            attachedOffset = CGPoint(x: c.frame.origin.x - pet.frame.origin.x, y: c.frame.origin.y - pet.frame.origin.y)
        } else {
            mutate { $0.chatOrigin = [c.frame.origin.x, c.frame.origin.y] }
        }
    }

    /// Pet Only: the chat behaves like a popover and closes when you click elsewhere (unless pinned, or a file picker is open).
    private func chatLostFocus() {
        guard chatOpen, FloatingPolicy.dismissOnFocusLoss(mode: settings.displayMode, pinned: chatPinned), !suppressDismiss else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.chatOpen, !self.suppressDismiss, NSApp.modalWindow == nil, self.chatPanel?.isKeyWindow == false else { return }
            self.setChatOpen(false)
        }
    }

    // MARK: Actions shared by the pet's context menu, the menu bar and the mini chat

    func openMainWindow(section: NavSection? = nil, settings: SettingsSection? = nil) {
        if let section { model?.selection = section }
        if let settings { model?.settingsSection = settings }
        NotificationCenter.default.post(name: .arjunOpenMainWindow, object: nil)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
