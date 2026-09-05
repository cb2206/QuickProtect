import SwiftUI
import Carbon

// MARK: - Pastable text fields (NSTextField-backed for proper Cmd+V support)

/// Routes the standard editing key equivalents (⌘X/⌘C/⌘V/⌘A/⌘Z) to the field
/// editor. A menu-bar (`.accessory`) app has no Edit menu, so these shortcuts
/// would otherwise be dropped and only the context-menu items would work.
private func handleEditingKeyEquivalent(_ event: NSEvent, from sender: NSControl) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
    let action: Selector
    switch key {
    case "x": action = #selector(NSText.cut(_:))
    case "c": action = #selector(NSText.copy(_:))
    case "v": action = #selector(NSText.paste(_:))
    case "a": action = #selector(NSText.selectAll(_:))
    case "z": action = Selector(("undo:"))
    default:  return false
    }
    // Dispatch through the responder chain to the first responder (field editor).
    return NSApp.sendAction(action, to: nil, from: sender)
}

final class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingKeyEquivalent(event, from: self) || super.performKeyEquivalent(with: event)
    }
}

final class EditableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingKeyEquivalent(event, from: self) || super.performKeyEquivalent(with: event)
    }
}

/// Regular text field that supports copy/paste in panels/popovers.
struct PastableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTextField {
        let field = EditableTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

/// Secure text field that supports copy/paste in panels/popovers.
struct PastableSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = EditableSecureTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

// MARK: - NSView-based hotkey recorder (captures key events)

struct HotkeyRecorderView: NSViewRepresentable {
    let onRecord: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCapture {
        let v = HotkeyCapture()
        v.onRecord = onRecord
        v.onCancel = onCancel
        // Become first responder to receive key events
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: HotkeyCapture, context: Context) {}

    final class HotkeyCapture: NSView {
        var onRecord: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // Escape cancels
            if event.keyCode == 53 { onCancel?(); return }
            // Require at least one modifier (cmd, ctrl, option, or shift)
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.isEmpty else { return }
            onRecord?(event.keyCode, mods)
        }
    }
}
