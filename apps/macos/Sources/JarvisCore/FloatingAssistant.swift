import Foundation
import CoreGraphics

// MARK: - Display mode

/// How the floating assistant shows up on the desktop. Saved in `FloatingSettings`.
public enum FloatingDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Pet on the desktop. Click it to open or close the mini chat. The chat stays open while you work in other apps.
    case petWithChat
    /// The mini chat only, no pet. Opened and closed with the global shortcut.
    case chatOnly
    /// Pet on the desktop. Click it to open a mini chat that closes by itself when you click away.
    case petOnly

    public var id: String { rawValue }
    public static let `default`: FloatingDisplayMode = .petWithChat

    public var title: String {
        switch self {
        case .petWithChat: "Pet with Chat"
        case .chatOnly: "Chat Only"
        case .petOnly: "Pet Only"
        }
    }
    public var summary: String {
        switch self {
        case .petWithChat: "Show the pet. Click it to open or close the mini chat, which stays open while you work in other apps."
        case .chatOnly: "Show the mini chat on its own, without the pet. Open and close it with the shortcut."
        case .petOnly: "Show only the pet. Click it to open the mini chat, which closes when you click away or press Esc."
        }
    }
    public var showsPet: Bool { self != .chatOnly }
}

// MARK: - Pet appearance

public enum PetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case orb, buddy, spark, monogram
    public var id: String { rawValue }
    public var title: String {
        switch self { case .orb: "Orb"; case .buddy: "Buddy"; case .spark: "Spark"; case .monogram: "Monogram" }
    }
}

public enum PetColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, violet, green, orange, pink, graphite
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Linear-ish sRGB components so the core module stays free of SwiftUI.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .blue: (0.23, 0.55, 1.00)
        case .violet: (0.55, 0.38, 1.00)
        case .green: (0.20, 0.78, 0.50)
        case .orange: (1.00, 0.55, 0.20)
        case .pink: (1.00, 0.38, 0.62)
        case .graphite: (0.55, 0.58, 0.64)
        }
    }
}

public enum PetCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .topLeft: "Top left"; case .topRight: "Top right"; case .bottomLeft: "Bottom left"; case .bottomRight: "Bottom right"
        }
    }
    /// Where the pet's centre sits, as a fraction of the screen's usable area.
    public var fractions: (fx: Double, fy: Double) {
        switch self {
        case .topLeft: (0.04, 0.96); case .topRight: (0.96, 0.96); case .bottomLeft: (0.04, 0.06); case .bottomRight: (0.96, 0.06)
        }
    }
}

/// Where the pet sits. Stored as a fraction of the screen's usable area (0...1, y up), so it survives resolution changes.
public struct PetAnchor: Codable, Equatable, Sendable {
    public var screenID: UInt32?
    public var fx: Double
    public var fy: Double
    public init(screenID: UInt32? = nil, fx: Double, fy: Double) { self.screenID = screenID; self.fx = fx; self.fy = fy }
    public static let `default` = PetAnchor(fx: PetCorner.bottomRight.fractions.fx, fy: PetCorner.bottomRight.fractions.fy)
}

// MARK: - Global shortcut

public struct HotKeyModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = HotKeyModifiers(rawValue: 1 << 0)
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    public static let shift = HotKeyModifiers(rawValue: 1 << 2)
    public static let command = HotKeyModifiers(rawValue: 1 << 3)
}

/// A global shortcut: a macOS virtual key code plus modifiers. Default is Control + Option + J.
public struct HotKeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: HotKeyModifiers
    public init(keyCode: UInt16, modifiers: HotKeyModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }

    public static let `default` = HotKeyCombo(keyCode: 38, modifiers: [.control, .option])      // 38 = J

    /// A shortcut must include Control or Command. Shift or Option alone would hijack ordinary typing
    /// (and macOS 15 no longer delivers Option-only global shortcuts).
    public var isValid: Bool {
        (modifiers.contains(.control) || modifiers.contains(.command)) && Self.keyNames[keyCode] != nil
    }

    /// Mac-style text, in the order macOS shows it: ⌃⌥⇧⌘ then the key.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "?")
    }
    public var spoken: String {
        var p: [String] = []
        if modifiers.contains(.control) { p.append("Control") }
        if modifiers.contains(.option) { p.append("Option") }
        if modifiers.contains(.shift) { p.append("Shift") }
        if modifiers.contains(.command) { p.append("Command") }
        return (p + [Self.keyNames[keyCode] ?? "?"]).joined(separator: " + ")
    }

    /// Key names for a US layout. Keys not listed here can't be used (they could not be shown back to the user reliably).
    public static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]
}

// MARK: - Settings

public struct FloatingSettings: Codable, Equatable, Sendable {
    public var displayMode: FloatingDisplayMode = .default
    public var petHidden = false                         // the pet can be hidden on its own; the chat is unaffected
    public var petStyle: PetStyle = .orb
    public var petID: String?                            // a Codex pet (folder id) to use instead of the built-in looks; nil = built-in
    public var petColor: PetColor = .blue
    public var petSize: Double = 72                      // points
    public var petIdleOpacity: Double = 0.9              // when you're not hovering and nothing is happening
    public var snapToEdges = true
    public var petAnchor: PetAnchor = .default
    public var hotKey: HotKeyCombo = .default
    public var chatWidth: Double = 380
    public var chatHeight: Double = 540
    public var chatOrigin: [Double]?                     // [x, y] used when the chat is not attached to a pet
    public var chatWasOpen = false                       // restored at launch where the mode allows it
    public var shareScreen = false                       // attach a capture of the window behind ArjunOS to each mini-chat message

    public static let petSizeRange: ClosedRange<Double> = 40...260
    public static let idleOpacityRange: ClosedRange<Double> = 0.35...1.0
    public static let chatMinSize = CGSize(width: 320, height: 360)

    public init() {}

    // Every field is optional on disk, so adding a field later never wipes the user's saved choices.
    private enum CodingKeys: String, CodingKey {
        case displayMode, petHidden, petStyle, petID, petColor, petSize, petIdleOpacity, snapToEdges, petAnchor, hotKey
        case chatWidth, chatHeight, chatOrigin, chatWasOpen, shareScreen
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FloatingSettings()
        displayMode = (try? c.decodeIfPresent(FloatingDisplayMode.self, forKey: .displayMode)) ?? d.displayMode
        petHidden = (try? c.decodeIfPresent(Bool.self, forKey: .petHidden)) ?? d.petHidden
        petStyle = (try? c.decodeIfPresent(PetStyle.self, forKey: .petStyle)) ?? d.petStyle
        petColor = (try? c.decodeIfPresent(PetColor.self, forKey: .petColor)) ?? d.petColor
        petID = try? c.decodeIfPresent(String.self, forKey: .petID)
        petSize = (try? c.decodeIfPresent(Double.self, forKey: .petSize)) ?? d.petSize
        petIdleOpacity = (try? c.decodeIfPresent(Double.self, forKey: .petIdleOpacity)) ?? d.petIdleOpacity
        snapToEdges = (try? c.decodeIfPresent(Bool.self, forKey: .snapToEdges)) ?? d.snapToEdges
        petAnchor = (try? c.decodeIfPresent(PetAnchor.self, forKey: .petAnchor)) ?? d.petAnchor
        hotKey = (try? c.decodeIfPresent(HotKeyCombo.self, forKey: .hotKey)) ?? d.hotKey
        chatWidth = (try? c.decodeIfPresent(Double.self, forKey: .chatWidth)) ?? d.chatWidth
        chatHeight = (try? c.decodeIfPresent(Double.self, forKey: .chatHeight)) ?? d.chatHeight
        chatOrigin = try? c.decodeIfPresent([Double].self, forKey: .chatOrigin)
        chatWasOpen = (try? c.decodeIfPresent(Bool.self, forKey: .chatWasOpen)) ?? d.chatWasOpen
        shareScreen = (try? c.decodeIfPresent(Bool.self, forKey: .shareScreen)) ?? d.shareScreen
        sanitize()
    }

    /// Brings every value back into a safe range (a hand-edited or corrupt file must never produce an invisible pet or an unusable shortcut).
    public mutating func sanitize() {
        petSize = petSize.isFinite ? min(max(petSize, Self.petSizeRange.lowerBound), Self.petSizeRange.upperBound) : 72
        petIdleOpacity = petIdleOpacity.isFinite ? min(max(petIdleOpacity, Self.idleOpacityRange.lowerBound), Self.idleOpacityRange.upperBound) : 0.9
        chatWidth = chatWidth.isFinite ? min(max(chatWidth, Self.chatMinSize.width), 1600) : 380
        chatHeight = chatHeight.isFinite ? min(max(chatHeight, Self.chatMinSize.height), 1600) : 540
        petAnchor.fx = petAnchor.fx.isFinite ? min(max(petAnchor.fx, 0), 1) : PetAnchor.default.fx
        petAnchor.fy = petAnchor.fy.isFinite ? min(max(petAnchor.fy, 0), 1) : PetAnchor.default.fy
        if !hotKey.isValid { hotKey = .default }
        if let id = petID, id.isEmpty || id.count > 120 || id.unicodeScalars.contains(where: { $0.value < 32 }) { petID = nil }
        if let o = chatOrigin, o.count != 2 || !o.allSatisfy(\.isFinite) { chatOrigin = nil }
    }

    public var chatSize: CGSize { CGSize(width: chatWidth, height: chatHeight) }
}

/// Saves `FloatingSettings` as one JSON value so they persist across restarts.
public struct FloatingSettingsStore {
    public static let key = "floating.settings.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> FloatingSettings {
        guard let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(FloatingSettings.self, from: data) else { return FloatingSettings() }
        return s
    }
    public func save(_ settings: FloatingSettings) {
        var s = settings; s.sanitize()
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - What shows when (pure, so it is easy to test)

public enum FloatingPolicy {
    public static func petVisible(mode: FloatingDisplayMode, petHidden: Bool) -> Bool { mode.showsPet && !petHidden }

    /// Chat state when the app starts. Pet Only never starts with the chat open; Chat Only shows it unless you closed it last time.
    public static func chatOpenAtLaunch(mode: FloatingDisplayMode, wasOpen: Bool, hasSavedState: Bool) -> Bool {
        switch mode {
        case .petOnly: return false
        case .petWithChat: return wasOpen
        case .chatOnly: return hasSavedState ? wasOpen : true
        }
    }

    /// Chat state right after the user picks a different mode in Settings.
    public static func chatOpenAfterModeChange(to mode: FloatingDisplayMode, currentlyOpen: Bool) -> Bool {
        switch mode {
        case .chatOnly: return true             // "display the mini chat directly"
        case .petOnly: return false             // "without an automatically opened chat"
        case .petWithChat: return currentlyOpen
        }
    }

    /// Pet Only treats the chat like a popover: it goes away when you click elsewhere, unless you pinned it.
    public static func dismissOnFocusLoss(mode: FloatingDisplayMode, pinned: Bool) -> Bool { mode == .petOnly && !pinned }

    /// The chat sits beside the pet only while the pet is on screen.
    public static func chatAttachesToPet(mode: FloatingDisplayMode, petHidden: Bool) -> Bool { petVisible(mode: mode, petHidden: petHidden) }
}

// MARK: - Geometry

public enum FloatingLayout {
    public static let petMargin: CGFloat = 12          // transparent room around the pet inside its window (for shadow and badge)
    public static let gap: CGFloat = 10
    public static let screenInset: CGFloat = 8

    /// Moves `frame` the least distance needed to lie fully inside `bounds` (and shrinks it if it is larger than `bounds`).
    public static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.width, bounds.width); f.size.height = min(f.height, bounds.height)
        f.origin.x = min(max(f.origin.x, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.origin.y, bounds.minY), bounds.maxY - f.height)
        return f
    }

    /// The pet's window frame for a saved anchor on the given usable screen area.
    public static func petFrame(anchor: PetAnchor, petSize: CGFloat, visible: CGRect) -> CGRect {
        let side = petSize + petMargin * 2
        let cx = visible.minX + CGFloat(anchor.fx) * visible.width
        let cy = visible.minY + CGFloat(anchor.fy) * visible.height
        return clamp(CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side), to: visible)
    }

    /// The anchor for a pet window frame (what gets saved after a drag).
    public static func anchor(for petFrame: CGRect, visible: CGRect, screenID: UInt32?) -> PetAnchor {
        guard visible.width > 0, visible.height > 0 else { return .default }
        let fx = (petFrame.midX - visible.minX) / visible.width
        let fy = (petFrame.midY - visible.minY) / visible.height
        return PetAnchor(screenID: screenID, fx: Double(min(max(fx, 0), 1)), fy: Double(min(max(fy, 0), 1)))
    }

    /// After a drop: keep the pet fully on screen and, if wanted, pull it to a nearby edge.
    public static func settle(_ petFrame: CGRect, visible: CGRect, snap: Bool, threshold: CGFloat = 28) -> CGRect {
        var f = clamp(petFrame, to: visible)
        guard snap else { return f }
        let edge = screenInset - petMargin                   // the visible pet, not its transparent margin, sits `screenInset` from the edge
        if f.minX - visible.minX < threshold { f.origin.x = visible.minX + edge }
        else if visible.maxX - f.maxX < threshold { f.origin.x = visible.maxX - f.width - edge }
        if f.minY - visible.minY < threshold { f.origin.y = visible.minY + edge }
        else if visible.maxY - f.maxY < threshold { f.origin.y = visible.maxY - f.height - edge }
        return clamp(f, to: visible)
    }

    /// Where the chat opens: beside the pet on the side with room (right first), growing upward when the pet is low on the
    /// screen and downward when it is high, always fully on screen. `petFrame` is the pet's window frame (margin included).
    public static func chatFrame(besidePet petFrame: CGRect, chatSize: CGSize, visible: CGRect) -> CGRect {
        let pet = petFrame.insetBy(dx: petMargin, dy: petMargin)
        let size = CGSize(width: min(chatSize.width, visible.width), height: min(chatSize.height, visible.height))
        let roomRight = visible.maxX - pet.maxX - gap
        let roomLeft = pet.minX - visible.minX - gap
        let x: CGFloat
        if roomRight >= size.width { x = pet.maxX + gap }
        else if roomLeft >= size.width { x = pet.minX - gap - size.width }
        else { x = roomRight >= roomLeft ? pet.maxX + gap : pet.minX - gap - size.width }      // no side fits: overlap the less cramped side, then clamp
        let petInLowerHalf = pet.midY < visible.midY
        let y = petInLowerHalf ? pet.minY : pet.maxY - size.height
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: size), to: visible)
    }

    /// Where a chat with no pet opens the first time: right side of the screen, a little above the middle.
    public static func defaultChatFrame(chatSize: CGSize, visible: CGRect) -> CGRect {
        let size = CGSize(width: min(chatSize.width, visible.width), height: min(chatSize.height, visible.height))
        let origin = CGPoint(x: visible.maxX - size.width - 32, y: visible.midY - size.height / 2 + 40)
        return clamp(CGRect(origin: origin, size: size), to: visible)
    }
}
