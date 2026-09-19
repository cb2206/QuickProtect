import AppKit

/// Asks the user whether to trust a controller's changed certificate, showing
/// the trusted and the new key so the change can be verified out of band.
/// Opened only by an explicit click (the grid's certificate card, a pinned
/// window's overlay) — never unprompted, so the decision stays deliberate.
@MainActor
enum CertificateReviewAlert {

    /// Shows the alert for the service's pending change and trusts the new key
    /// if the user confirms. No-op when nothing is pending.
    static func present(service: ProtectService) {
        guard let change = service.certificateChange else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Trust the controller's new certificate?")
        alert.informativeText = SettingsView.certificateChangedHint
        alert.accessoryView = fingerprintView(for: change)
        // Cancel first: it is the default button (Return), and Esc maps to it
        // by title. Trusting always takes a deliberate click.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Trust new certificate"))
        guard alert.runModalAboveFloatingWindows() == .alertSecondButtonReturn else { return }
        service.trustPendingCertificate(host: change.host)
    }

    /// Host plus both full fingerprints, selectable so they can be copied and
    /// compared against the controller.
    private static func fingerprintView(for change: CertificateTrust.Change) -> NSView {
        var lines = [String(localized: "Controller: \(change.host)"), ""]
        if let trusted = change.trustedFingerprint {
            lines += [String(localized: "Trusted key"), CertificateTrust.displayFingerprint(trusted, bytesPerLine: 16), ""]
        }
        lines += [String(localized: "New key"), CertificateTrust.displayFingerprint(change.newFingerprint, bytesPerLine: 16)]

        let field = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        field.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 380
        field.frame.size = field.fittingSize
        return field
    }
}

extension NSAlert {
    /// Runs the alert modally. The popover panel sits at `.popUpMenu` level and
    /// pinned windows above it, both of which draw over a modal alert, so any
    /// elevated app windows drop to normal level for the alert's lifetime.
    func runModalAboveFloatingWindows() -> NSApplication.ModalResponse {
        let elevated = NSApp.windows.filter { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
        let savedLevels = elevated.map(\.level)
        elevated.forEach { $0.level = .normal }
        NSApp.activate(ignoringOtherApps: true)
        let response = runModal()
        zip(elevated, savedLevels).forEach { $0.level = $1 }
        return response
    }
}
