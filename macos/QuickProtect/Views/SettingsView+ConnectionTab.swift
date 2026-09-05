import SwiftUI
import Carbon

// MARK: - Connection tab: controller address, API key, certificate pins.

extension SettingsView {

    // MARK: - Tabs

    var connectionTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Controller")) {
                AuroraSettingsRow(String(localized: "IP Address"), hint: String(localized: "Local IP of your UniFi Protect controller")) {
                    PastableTextField(text: $settings.ipAddress, placeholder: "10.0.1.1")
                        .frame(width: 260)
                }
                AuroraSettingsRow(String(localized: "API Key"), hint: String(localized: "Integration API key from controller settings")) {
                    HStack(spacing: 6) {
                        Group {
                            if showApiKey {
                                PastableTextField(text: $settings.apiKey, placeholder: "")
                            } else {
                                PastableSecureField(text: $settings.apiKey, placeholder: "")
                            }
                        }
                        .frame(width: 234)
                        Button {
                            showApiKey.toggle()
                        } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(palette.subtext)
                        }
                        .buttonStyle(.plain)
                        .help(showApiKey ? "Hide API key" : "Show API key")
                    }
                }
                AuroraSettingsRow(
                    String(localized: "Keep streams alive"),
                    hint: String(localized: "Streams stay connected for this long after closing, so a quick reopen shows video instantly")
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
                        labelExpands: true
                    ) {
                        Toggle("", isOn: $settings.pauseDecodeWhileClosed)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                AuroraSettingsRow(isLast: true) {
                    HStack(spacing: 10) {
                        AuroraPrimaryButton(
                            title: String(localized: "Test Connection"),
                            disabled: isTesting || settings.ipAddress.isEmpty || settings.apiKey.isEmpty,
                            action: runTest
                        )
                        if isTesting {
                            ProgressView().scaleEffect(0.6)
                        }
                        if let result = testResult {
                            HStack(spacing: 5) {
                                Image(systemName: result.icon)
                                Text(result.message)
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(result.color)
                            .transition(.opacity)
                        }
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
                                    CertificateTrust.Store().trustPending(host: entry.host)
                                    certRefresh.toggle()
                                    runTest()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // One localizable literal (String(localized:) needs a literal key); kept out
    // of the view builder so the type-checker isn't asked to fold it.
    // swiftlint:disable:next line_length
    static let certificateChangedHint = String(localized: "The controller is presenting a new certificate. This is expected if you reinstalled or replaced the controller — but if you didn't, it may indicate someone intercepting the connection. Compare the new key with the certificate your controller shows before trusting it.")

    /// Full SHA-256 SubjectPublicKeyInfo fingerprints of the trusted and the
    /// new key, so the change can be verified against the controller.
    func certificateFingerprints(for entry: (host: String, fingerprint: String)) -> some View {
        let pinned = CertificateTrust.Store().pinned(host: entry.host)
        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.host)
                .font(.system(size: 11, weight: .semibold))
            if let pinned {
                Text(String(localized: "Trusted key"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(CertificateTrust.displayFingerprint(pinned))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(String(localized: "New key"))
                .font(.system(size: 10)).foregroundColor(.secondary)
            Text(CertificateTrust.displayFingerprint(entry.fingerprint))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    /// Every changed controller certificate awaiting the user's decision.
    /// Listed for all hosts rather than one guessed key, so a pin left under an
    /// older key format can still be reviewed. Reads through `certRefresh` so
    /// re-pinning updates the UI.
    var pendingCertificates: [(host: String, fingerprint: String)] {
        _ = certRefresh
        return CertificateTrust.Store().allPending()
    }
}
