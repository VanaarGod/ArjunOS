import SwiftUI
import AppKit

// MARK: - Theme

enum Theme {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let accent = Color(red: 0.23, green: 0.55, blue: 1.0)
    static let accent2 = Color(red: 0.55, green: 0.38, blue: 1.0)
    static let hairline = Color.white.opacity(0.08)

    // One set of motion curves so the whole app moves the same way.
    static let smooth = Animation.smooth(duration: 0.35)
    static let snappy = Animation.snappy(duration: 0.22)
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.86)
}

// MARK: - Liquid Glass

#if compiler(>=6.2)
/// The real thing: `glassEffect` on macOS 26 and later (needs Xcode 26 to compile, which is why this is behind `compiler(>=6.2)`).
@available(macOS 26.0, *)
private struct RealGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    func body(content: Content) -> some View { content.glassEffect(glass, in: shape) }
}
#endif

extension View {
    /// Liquid Glass on macOS 26+, a layered frosted look on macOS 14-25. `interactive` makes the surface react to the pointer.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.modifier(RealGlass(shape: shape, tint: tint, interactive: interactive))
        } else {
            self.frostedGlass(shape, tint: tint)
        }
        #else
        self.frostedGlass(shape, tint: tint)
        #endif
    }

    /// The fallback. Material blur, a faint tint, a specular rim light from the top, and a soft shadow so it floats.
    func frostedGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        self
            .background(shape.fill(.ultraThinMaterial))
            .background(shape.fill((tint ?? Color.white).opacity(tint == nil ? 0.035 : 0.22)))
            .overlay(
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.05), Color.white.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 8)
    }
}

/// Groups nearby glass surfaces so that on macOS 26 they blend and morph into each other like one piece of liquid glass.
struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content
    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
        #else
        content
        #endif
    }
}

// MARK: - Buttons

/// Capsule glass button that squishes when pressed. `prominent` tints it with the accent colour.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        GlassButtonBody(label: configuration.label, pressed: configuration.isPressed, prominent: prominent)
    }
}

private struct GlassButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .liquidGlass(in: Capsule(), tint: prominent ? Theme.accent.opacity(0.6) : nil, interactive: true)
            .scaleEffect(pressed ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.snappy, value: pressed)
    }
}

/// Round icon button (send, stop, +).
struct GlassCircleButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var size: CGFloat = 34
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        GlassCircleBody(label: configuration.label, pressed: configuration.isPressed, tint: tint, size: size)
    }
}

private struct GlassCircleBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let tint: Color?
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        label
            .frame(width: size, height: size)
            .liquidGlass(in: Circle(), tint: tint, interactive: true)
            .scaleEffect(pressed ? 0.9 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Theme.snappy, value: pressed)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glassButton: GlassButtonStyle { GlassButtonStyle() }
    static var glassProminentButton: GlassButtonStyle { GlassButtonStyle(prominent: true) }
}

// MARK: - Hover

struct HoverFill: ViewModifier {
    var cornerRadius: CGFloat = 12
    var strength: Double = 0.07
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.white.opacity(hovering ? strength : 0)))
            .onHover { inside in withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
    }
}

extension View {
    func hoverFill(cornerRadius: CGFloat = 12, strength: Double = 0.07) -> some View { modifier(HoverFill(cornerRadius: cornerRadius, strength: strength)) }
}

// MARK: - Entrance animation

/// Fades and floats a view in when it first appears. `index` staggers a list so items arrive one after another.
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let visible = shown || reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 10)
            .scaleEffect(visible ? 1 : 0.98)
            .onAppear {
                guard !shown else { return }
                withAnimation(.smooth(duration: 0.5).delay(Double(min(index, 12)) * 0.05)) { shown = true }
            }
    }
}

extension View {
    func staggerIn(_ index: Int = 0) -> some View { modifier(StaggerIn(index: index)) }
}

// MARK: - Ambient background

/// Near-black canvas with slowly drifting colour pools so the glass always has something to refract.
/// The drift is slow enough that a few frames a second look identical to 20, but cost a fraction of the GPU and CPU (every glass
/// surface above it has to be re-composited on each frame). It stops entirely when the window is hidden or covered (`paused`),
/// when this app is not frontmost, in Low Power Mode, or when Reduce Motion is on, so it costs nothing in the background.
struct AmbientBackground: View {
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 5.0, paused: paused || reduceMotion || lowPower || scenePhase != .active)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate / 14
            ZStack {
                Theme.bg
                pool(Theme.accent, 0.22, x: 0.55 + 0.10 * sin(t), y: 0.00 + 0.05 * cos(t * 1.3), radius: 600)
                pool(Color.purple, 0.14, x: 0.95 - 0.12 * cos(t * 0.8), y: 1.00 - 0.08 * sin(t), radius: 540)
                pool(Color.cyan, 0.09, x: 0.05 + 0.10 * sin(t * 0.7), y: 0.90 + 0.06 * cos(t), radius: 440)
            }
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }

    private func pool(_ color: Color, _ opacity: Double, x: Double, y: Double, radius: CGFloat) -> some View {
        RadialGradient(colors: [color.opacity(opacity), .clear], center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: radius)
    }
}

struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}

/// The faint 0/1 field at the top of the empty state. Decorative only; static when Reduce Motion is on.
struct BinaryField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion { field(tick: 0) }
        else { TimelineView(.periodic(from: .now, by: 0.7)) { ctx in field(tick: Int(ctx.date.timeIntervalSinceReferenceDate / 0.7)) } }
    }
    private func field(tick: Int) -> some View {
        Canvas { context, size in
            let cw: CGFloat = 17, rh: CGFloat = 19
            let cols = Int(size.width / cw), rows = Int(size.height / rh)
            var rng = LCG(state: 11)
            for r in 0..<rows {
                for c in 0..<cols {
                    let v = rng.next()
                    let flips = (v % 7 == 0) ? tick : 0            // only some digits change over time
                    let digit = ((v >> 3) + UInt64(flips)) % 2 == 0 ? "0" : "1"
                    let dx = (CGFloat(c) / CGFloat(max(cols - 1, 1))) - 0.5
                    let dy = CGFloat(r) / CGFloat(max(rows - 1, 1))
                    let fade = max(0, 1 - (dx * dx * 5.5 + dy * dy * 1.4).squareRoot())
                    guard fade > 0.02 else { continue }
                    let bright = (v >> 9) % 5 == 0 ? 1.0 : 0.45
                    let t = Text(digit).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.accent.opacity(Double(fade) * 0.55 * bright))
                    context.draw(t, at: CGPoint(x: CGFloat(c) * cw + cw / 2, y: CGFloat(r) * rh + rh / 2))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The orb

/// The assistant orb. It breathes when idle and shows a rotating light ring and a moving waveform while working.
struct AssistantOrb: View {
    var size: CGFloat = 64
    var thinking = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.15)], center: .center, startRadius: 0, endRadius: size * 0.6))
                .blur(radius: size * 0.12)
            ring
            Image(systemName: "waveform")
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: thinking && !reduceMotion)
        }
        .frame(width: size, height: size)
        .liquidGlass(in: Circle(), tint: Theme.accent.opacity(0.35))
        .scaleEffect(reduceMotion ? 1 : (breathe ? 1.04 : 0.97))
        .animation(breatheAnimation, value: breathe)
        .onAppear { breathe = true }
        .accessibilityHidden(true)
    }

    private var breatheAnimation: Animation? {
        reduceMotion ? nil : Animation.easeInOut(duration: 2.8).repeatForever(autoreverses: true)
    }

    @ViewBuilder private var ring: some View {
        if thinking && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
                let a = Angle.degrees((ctx.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360))
                Circle().strokeBorder(AngularGradient(colors: [.white.opacity(0.9), Theme.accent, .clear, .white.opacity(0.9)], center: .center, angle: a), lineWidth: 2)
            }
        } else {
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        }
    }
}

/// A soft rotating light around a surface while the assistant is working.
struct ThinkingGlow: View {
    var active: Bool
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active || reduceMotion)) { ctx in
            let a = Angle.degrees(reduceMotion ? 0 : (ctx.date.timeIntervalSinceReferenceDate * 70).truncatingRemainder(dividingBy: 360))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AngularGradient(colors: [Theme.accent, Theme.accent2, .cyan, Theme.accent], center: .center, angle: a), lineWidth: 1.6)
                .shadow(color: Theme.accent.opacity(0.5), radius: 8)
        }
        .opacity(active ? 1 : 0)
        .animation(.smooth(duration: 0.45), value: active)
        .allowsHitTesting(false)
    }
}

// MARK: - Window

/// Configures the host NSWindow (transparent title bar, draggable body) and, crucially, makes it key + frontmost
/// so the keyboard works even when launched via `swift run` from a terminal.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Neat text inputs (used everywhere instead of the stock bordered/rounded styles)

struct GlassField: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.white.opacity(focused ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct GlassEditor: ViewModifier {
    var monospaced: Bool
    var minHeight: CGFloat
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .body)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    func glassField() -> some View { modifier(GlassField()) }
    func glassEditor(monospaced: Bool = false, minHeight: CGFloat = 90) -> some View { modifier(GlassEditor(monospaced: monospaced, minHeight: minHeight)) }
}
