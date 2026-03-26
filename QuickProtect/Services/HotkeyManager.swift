import Carbon
import AppKit

/// Registers a system-wide keyboard shortcut using Carbon's RegisterEventHotKey.
/// Works without Accessibility permissions (unlike NSEvent global monitors for keys).
final class HotkeyManager {

    static let shared = HotkeyManager()

    var onHotkey: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    // MARK: - Public

    func register(keyCode: UInt32, carbonModifiers: UInt32) {
        unregister()

        let hotKeyID = EventHotKeyID(
            signature: FourCharCode(0x51505254),   // "QPRT"
            id: 1
        )

        // Install handler for kEventHotKeyPressed
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { mgr.onHotkey?() }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
    }

    func unregister() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
    }

    /// Register from the stored AppSettings preference.
    func registerFromSettings() {
        guard let (keyCode, mods) = AppSettings.shared.globalHotkey() else {
            unregister()
            return
        }
        register(keyCode: keyCode, carbonModifiers: mods)
    }

    // MARK: - Modifier conversion

    /// Convert NSEvent.ModifierFlags to Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Human-readable string for a hotkey combo.
    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var parts = [String]()
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 109: "F10", 111: "F12", 103: "F11",
            118: "F4", 120: "F2", 122: "F1",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}
