import SwiftUI
import Carbon

// MARK: - Connection tab: controller address, API key, certificate pins.

extension SettingsView {

    // MARK: - Tabs

    var connectionTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SiteListSection(settings: settings, hub: service, selectedSiteID: selectedSiteBinding)
            // Re-created per site so field and test state never carry over.
            SiteConnectionSection(site: selectedSite, settings: settings, hub: service)
                .id(selectedSite.id)

            AuroraSettingsSection(String(localized: "Streams")) {
                AuroraSettingsRow(
                    String(localized: "Keep streams alive"),
                    hint: String(localized: "Streams stay connected for this long after closing, so a quick reopen shows video instantly"),
                    isLast: settings.streamKeepAliveSeconds == 0
                ) {
                    AuroraSegmented(
                        options: [
                            (String(localized: "Off"), 0),
                            ("5 s", 5),
                            ("10 s", 10),
                            ("30 s", 30),
                            ("60 s", 60)
                        ],
                        selection: $settings.streamKeepAliveSeconds
                    )
                }
                if settings.streamKeepAliveSeconds > 0 {
                    AuroraSettingsRow(
                        String(localized: "Pause decoding while closed"),
                        hint: String(localized: "Kept-alive streams stay connected but skip video decoding while the panel is closed, cutting CPU use to nearly nothing. The picture catches up instantly on reopen."),
                        isLast: true,
                        labelExpands: true
                    ) {
                        Toggle("", isOn: $settings.pauseDecodeWhileClosed)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            let pending = pendingCertificates
            if !pending.isEmpty {
                AuroraSettingsSection(String(localized: "Certificate")) {
                    ForEach(Array(pending.enumerated()), id: \.element.host) { index, entry in
                        AuroraSettingsRow(
                            String(localized: "Certificate changed"),
                            hint: Self.certificateChangedHint,
                            isLast: index == pending.count - 1,
                            labelExpands: true
                        ) {
                            VStack(alignment: .trailing, spacing: 8) {
                                certificateFingerprints(for: entry)
                                AuroraPrimaryButton(
                                    title: String(localized: "Trust new certificate"),
                                    disabled: false
                                ) {
                                    // Through the service, so the panel's card clears and
                                    // pinned windows reconnect along with the test.
                                    // The section itself refreshes on the store's notification.
                                    service.trustPendingCertificate(host: entry.host)
                                }
                            }
                        }
                    }
                }
            }
        }
        // The pin store isn't observable; re-read it whenever it changes —
        // a rejection, or a trust from the panel card or a pinned window —
        // rather than relying on the service happening to publish too.
        // Posted from URLSession's and the RTSP clients' queues.
        .onReceive(NotificationCenter.default.publisher(for: CertificateTrust.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            certRefresh.toggle()
        }
    }

    // One localizable literal (String(localized:) needs a literal key); kept out
    // of the view builder so the type-checker isn't asked to fold it.
    // swiftlint:disable:next line_length
    static let certificateChangedHint = String(localized: "The controller is presenting a new certificate. This is expected if you reinstalled or replaced the controller — but if you didn't, it may indicate someone intercepting the connection. Compare the new key with the certificate your controller shows before trusting it.")

    /// Full SHA-256 SubjectPublicKeyInfo fingerprints of the trusted and the
    /// new key, so the change can be verified against the controller. Broken
    /// at 16 bytes per line like the review alert, never mid-byte.
    func certificateFingerprints(for entry: (host: String, fingerprint: String)) -> some View {
        let pinned = CertificateTrust.Store().pinned(host: entry.host)
        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.host)
                .font(.system(size: 11, weight: .semibold))
            if let pinned {
                Text(String(localized: "Trusted key"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(CertificateTrust.displayFingerprint(pinned, bytesPerLine: 16))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    // Whole lines only: the hint column gives way instead.
                    .fixedSize()
            }
            Text(String(localized: "New key"))
                .font(.system(size: 10)).foregroundColor(.secondary)
            Text(CertificateTrust.displayFingerprint(entry.fingerprint, bytesPerLine: 16))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                // Whole lines only: the hint column gives way instead.
                .fixedSize()
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    /// Every changed controller certificate awaiting the user's decision.
    /// Listed for all hosts rather than one guessed key, so a pin left under an
    /// older key format can still be reviewed. Reads through `certRefresh`,
    /// which toggles on every pin-store change.
    var pendingCertificates: [(host: String, fingerprint: String)] {
        _ = certRefresh
        return CertificateTrust.Store().allPending()
    }
}
