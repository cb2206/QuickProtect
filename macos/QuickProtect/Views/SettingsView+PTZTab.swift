import SwiftUI
import Carbon

// MARK: - PTZ tab: classic-API credentials for pan/tilt/zoom.

extension SettingsView {

    // MARK: PTZ

    var ptzTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Classic API credentials")) {
                AuroraSettingsRow(
                    String(localized: "Username"),
                    hint: String(localized: "Local admin account on the Protect controller.")
                ) {
                    PastableTextField(text: $settings.username, placeholder: "")
                        .frame(width: 260)
                }
                AuroraSettingsRow(String(localized: "Password")) {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                PastableTextField(text: $settings.password, placeholder: "")
                            } else {
                                PastableSecureField(text: $settings.password, placeholder: "")
                            }
                        }
                        .frame(width: 234)
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(palette.subtext)
                        }
                        .buttonStyle(.plain)
                        .help(showPassword ? "Hide password" : "Show password")
                    }
                }
                AuroraSettingsRow(isLast: true) {
                    HStack(spacing: 10) {
                        AuroraPrimaryButton(
                            title: String(localized: "Test Connection"),
                            disabled: isTestingPtz || settings.ipAddress.isEmpty
                                || settings.username.isEmpty || settings.password.isEmpty,
                            action: runPtzTest
                        )
                        if isTestingPtz {
                            ProgressView().scaleEffect(0.6)
                        }
                        if let result = ptzTestResult {
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
            Text("PTZ control uses the classic Protect API, which requires a local account. The Integration API (API Key) only exposes preset and patrol endpoints, not free-form movement.")
                .font(.system(size: 11))
                .foregroundColor(palette.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
