import AppKit
import Carbon.HIToolbox
import JarvisCore

/// A system-wide keyboard shortcut using Carbon's RegisterEventHotKey. Unlike an NSEvent global monitor it needs no
/// Accessibility or Input Monitoring permission, and it swallows the key so the app in front never sees it.
@MainActor
final class GlobalHotKey {
    enum Failure: Error, Equatable { case taken, other(Int32) }

    var onPress: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in me.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }

    static func carbonModifiers(_ m: HotKeyModifiers) -> UInt32 {
        var c: UInt32 = 0
        if m.contains(.control) { c |= UInt32(controlKey) }
        if m.contains(.option) { c |= UInt32(optionKey) }
        if m.contains(.shift) { c |= UInt32(shiftKey) }
        if m.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        var m: HotKeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    @discardableResult
    func register(_ combo: HotKeyCombo) -> Result<Void, Failure> {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x41524A4E), id: 1)      // 'ARJN'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return .failure(status == OSStatus(eventHotKeyExistsErr) ? .taken : .other(status)) }
        hotKeyRef = ref
        return .success(())
    }

    func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    }
}
