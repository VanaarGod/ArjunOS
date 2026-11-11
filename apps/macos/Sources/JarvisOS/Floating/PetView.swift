import SwiftUI
import AppKit
import JarvisCore

/// Hosts the pet's SwiftUI view and handles the mouse in AppKit: a press that moves more than a few points is a drag
/// (the pet follows the pointer), anything else is a click. Right-click opens a menu. Nothing here takes keyboard focus.
final class PetContainerView: NSView {
    private weak var controller: FloatingAssistantController?
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var dragged = false

    init(controller: FloatingAssistantController, hosting: NSView) {
        self.controller = controller
        super.init(frame: .zero)
        hosting.frame = bounds; hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("ArjunOS assistant")
        setAccessibilityHelp("Opens or closes the mini chat")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {       // only the round pet is clickable; its transparent corners fall through to the app below
        let p = superview.map { convert(point, from: $0) } ?? point             // AppKit passes the point in the superview's coordinates
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = bounds.width / 2 - FloatingLayout.petMargin * 0.5
        return hypot(p.x - c.x, p.y - c.y) <= r ? self : nil
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool { Task { @MainActor in controller?.petClicked() }; return true }

    override func mouseEntered(with event: NSEvent) { Task { @MainActor in controller?.setHovering(true) } }
    override func mouseExited(with event: NSEvent) { Task { @MainActor in controller?.setHovering(false) } }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        startMouse = NSEvent.mouseLocation; startOrigin = w.frame.origin; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if !dragged && hypot(dx, dy) > 4 { dragged = true }
        guard dragged else { return }
        let origin = CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        Task { @MainActor in controller?.petDragged(to: origin) }
    }
    override func mouseUp(with event: NSEvent) {
        let wasDrag = dragged
        Task { @MainActor in if wasDrag { controller?.petDropped() } else { controller?.petClicked() } }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller else { return }
        MainActor.assumeIsolated {
            let menu = controller.makePetMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

@MainActor
extension FloatingAssistantController {
    func makePetMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action); item.state = checked ? .on : .off; menu.addItem(item)
        }
        add(chatOpen ? "Close Chat" : "Open Chat") { [weak self] in self?.toggleChat() }
        add("Hide Pet") { [weak self] in self?.setPetHidden(true) }
        menu.addItem(.separator())
        let modes = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: ""); let sub = NSMenu()
        for m in FloatingDisplayMode.allCases {
            let item = ClosureMenuItem(title: m.title) { [weak self] in self?.setMode(m) }
            item.state = m == settings.displayMode ? .on : .off; sub.addItem(item)
        }
        modes.submenu = sub; menu.addItem(modes)
        menu.addItem(.separator())
        add("Open ArjunOS") { [weak self] in self?.openMainWindow(section: .chat) }
        add("Floating Assistant Settings…") { [weak self] in self?.openMainWindow(section: .settings, settings: .floating) }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// MARK: - Look

enum PetMood { case idle, thinking, needsApproval, done, error }

extension PetColor {
    var color: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }
}

struct PetView: View {
    let controller: FloatingAssistantController
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false
    @State private var celebrating = false                // a short jump after a click or when an answer is ready (Codex pets)

    private var mood: PetMood {
        switch model.menuState {
        case .thinking: .thinking; case .needsApproval: .needsApproval; case .done: .done; case .error: .error; default: .idle
        }
    }

    var body: some View {
        let s = controller.settings
        let size = CGFloat(s.petSize)
        let color = s.petColor.color
        let active = controller.petHovering || mood != .idle || controller.chatOpen
        let sprite = controller.pets.sprite(for: s.petID)
        ZStack {
            if let sprite {
                PetSpriteView(sprite: sprite, state: spriteState, animate: !reduceMotion)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.30), radius: size * 0.05, y: size * 0.03)
            } else {
                disc(size: size, color: color, style: s.petStyle)
                ThinkingGlow(active: mood == .thinking, cornerRadius: size / 2)
            }
            badge(size: size)
        }
        .frame(width: size, height: size)
        .scaleEffect(bounce ? 1.14 : (controller.petHovering ? 1.06 : 1))
        .opacity(active ? 1 : s.petIdleOpacity)
        .padding(FloatingLayout.petMargin)
        .animation(Theme.snappy, value: controller.petHovering)
        .animation(Theme.smooth, value: active)
        .onChange(of: controller.petPulse) { _, _ in
            celebrate()
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bounce = false } }
        }
        .onChange(of: mood) { _, now in if now == .done { celebrate() } }
        .allowsHitTesting(false)                         // the AppKit container handles the mouse
        .accessibilityHidden(true)
    }

    /// Which Codex animation fits what is happening: running while it thinks, waiting for your approval, failed on an error,
    /// a jump to celebrate, "ready for review" while an answer is unread, a wave on hover, and running in the direction you drag it.
    private var spriteState: CodexPetState {
        if controller.petDragging { return controller.petDragDirection >= 0 ? .runningRight : .runningLeft }
        switch mood {
        case .thinking: return .running
        case .needsApproval: return .waiting
        case .error: return .failed
        default: break
        }
        if celebrating { return .jumping }
        if mood == .done { return .review }
        if controller.petHovering { return .waving }
        return .idle
    }

    private func celebrate() {
        celebrating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { celebrating = false }
    }

    private func disc(size: CGFloat, color: Color, style: PetStyle) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0.25)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1, size * 0.02))
            face(size: size, style: style)
        }
        .frame(width: size, height: size)
        .liquidGlass(in: Circle(), tint: color.opacity(0.35))
        .shadow(color: color.opacity(0.45), radius: size * 0.12, y: size * 0.04)
    }

    @ViewBuilder private func face(size: CGFloat, style: PetStyle) -> some View {
        switch style {
        case .orb:
            Image(systemName: "waveform").font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: mood == .thinking && !reduceMotion)
        case .spark:
            Image(systemName: "sparkles").font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: mood == .thinking && !reduceMotion)
        case .monogram:
            Text(String(model.assistantName.first ?? "A").uppercased()).font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        case .buddy:
            BuddyFace(size: size, mood: mood, reduceMotion: reduceMotion)
        }
    }

    private var badgeInfo: (symbol: String, tint: Color)? {
        switch mood {
        case .needsApproval: ("hand.raised.fill", .orange)
        case .done: ("checkmark", .green)
        case .error: ("exclamationmark", .red)
        default: nil
        }
    }

    @ViewBuilder private func badge(size: CGFloat) -> some View {
        let d = max(16, size * 0.3)
        if let info = badgeInfo {
            Image(systemName: info.symbol).font(.system(size: d * 0.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: d, height: d).background(Circle().fill(info.tint)).overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .offset(x: size * 0.36, y: -size * 0.36)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// A small face: eyes blink every few seconds, drift side to side while thinking, and squint happily when an answer is done.
private struct BuddyFace: View {
    let size: CGFloat
    let mood: PetMood
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let blink = !reduceMotion && t.truncatingRemainder(dividingBy: 4.6) > 4.45
            let look = (mood == .thinking && !reduceMotion) ? CGFloat(sin(t * 2.4)) * size * 0.05 : 0
            ZStack {
                HStack(spacing: size * 0.2) { eye(blink: blink); eye(blink: blink) }
                    .offset(x: look, y: -size * 0.04)
                mouth.offset(y: size * 0.2)
            }
        }
    }

    @ViewBuilder private func eye(blink: Bool) -> some View {
        if mood == .done {
            Path { p in
                p.addArc(center: CGPoint(x: size * 0.07, y: size * 0.09), radius: size * 0.07, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            }.stroke(.white, style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round)).frame(width: size * 0.14, height: size * 0.12)
        } else {
            Capsule().fill(.white).frame(width: size * 0.1, height: blink ? size * 0.015 : size * 0.18)
        }
    }

    @ViewBuilder private var mouth: some View {
        switch mood {
        case .error: Capsule().fill(.white.opacity(0.9)).frame(width: size * 0.14, height: size * 0.025)
        case .thinking: Circle().fill(.white.opacity(0.9)).frame(width: size * 0.07, height: size * 0.07)
        default:
            Path { p in p.addArc(center: CGPoint(x: size * 0.1, y: 0), radius: size * 0.1, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false) }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round)).frame(width: size * 0.2, height: size * 0.1)
        }
    }
}
