import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var service: ProtectService
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    @State private var step: Int = 1
    @State private var showApiKey = false
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var isTestingPtz = false
    @State private var ptzTestResult: TestResult?

    private struct TestResult: Equatable {
        let connected: Bool
        let message: String
    }

    var body: some View {
        HStack(spacing: 0) {
            leftRail
            rightPane
        }
        .frame(width: 720, height: 540)
        .background(palette.popoverBg)
        .accentColor(Color(hex: settings.accentColorHex))
        .preferredColorScheme(settings.appearance.preferredColorScheme)
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuroraBrandMark(size: 52, color: Color(hex: settings.accentColorHex))
                .padding(.bottom, 20)
            Text("Welcome to\nQuickProtect.")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.5)
                .foregroundColor(palette.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Live UniFi Protect feeds, one click from your menu bar.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.subtext)
                .padding(.top, 10)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, String(localized: "Connect"))
                stepRow(2, String(localized: "PTZ (optional)"))
                stepRow(3, String(localized: "All set"))
            }
            .padding(.top, 28)

            Spacer()
        }
        .padding(.horizontal, 28).padding(.vertical, 40)
        .frame(width: 260, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12),
                    Color.accentColor.opacity(0.02),
                    Color.clear
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(AuroraHairline(color: palette.divider), alignment: .trailing)
    }

    private func stepRow(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if n <= step {
                    Circle().fill(Color.accentColor)
                } else {
                    Circle()
                        .stroke(palette.divider, lineWidth: 1)
                }
                Group {
                    if n < step {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(n)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(n <= step ? .white : palette.subtext)
                            .monospacedDigit()
                    }
                }
            }
            .frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 12.5, weight: n == step ? .semibold : .regular))
                .foregroundColor(n == step ? palette.text : palette.subtext)
        }
    }

    // MARK: - Right pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, 32).padding(.top, 40)
            Spacer(minLength: 0)
            footer
                .padding(.horizontal, 32).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 1: connectStep
        case 2: ptzStep
        default: doneStep
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepEyebrow(String(localized: "Step 1 of 3"))
            Text("Connect your controller")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(palette.text)
            Text("Enter your UniFi Protect controller's local IP and an API key from its settings.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.subtext)
                .lineSpacing(3)
                .padding(.bottom, 24)
            onField(String(localized: "IP Address")) {
                PastableTextField(text: $settings.ipAddress, placeholder: "10.0.1.1")
                    .frame(width: 300)
            }
            onField(String(localized: "API Key")) {
                HStack(spacing: 6) {
                    Group {
                        if showApiKey {
                            PastableTextField(text: $settings.apiKey, placeholder: "")
                        } else {
                            PastableSecureField(text: $settings.apiKey, placeholder: "")
                        }
                    }.frame(width: 274)
                    Button { showApiKey.toggle() } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundColor(palette.subtext)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                AuroraSecondaryButton(title: String(localized: "Test Connection"), action: runTest)
                    .disabled(isTesting || settings.ipAddress.isEmpty || settings.apiKey.isEmpty)
                if isTesting { ProgressView().scaleEffect(0.6) }
                if let result = testResult {
                    HStack(spacing: 5) {
                        Image(systemName: result.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(result.message).font(.system(size: 12))
                    }
                    .foregroundColor(result.connected ? AuroraTokens.statusGreenDark : AuroraTokens.statusRed)
                }
            }
            .padding(.top, 8)
        }
    }

    private var ptzStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepEyebrow(String(localized: "Step 2 of 3"))
            Text("PTZ control (optional)")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(palette.text)
            Text("To pan and tilt PTZ cameras, QuickProtect needs a local admin account. The Integration API key only exposes preset and patrol endpoints, not free-form movement. You can skip this and add it later in Settings.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.subtext)
                .lineSpacing(3)
                .padding(.bottom, 20)
            onField(String(localized: "Username")) {
                PastableTextField(text: $settings.username, placeholder: "")
                    .frame(width: 300)
            }
            onField(String(localized: "Password")) {
                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            PastableTextField(text: $settings.password, placeholder: "")
                        } else {
                            PastableSecureField(text: $settings.password, placeholder: "")
                        }
                    }.frame(width: 274)
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundColor(palette.subtext)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                AuroraSecondaryButton(title: String(localized: "Test Connection"), action: runPtzTest)
                    .disabled(isTestingPtz || settings.ipAddress.isEmpty
                              || settings.username.isEmpty || settings.password.isEmpty)
                if isTestingPtz { ProgressView().scaleEffect(0.6) }
                if let result = ptzTestResult {
                    HStack(spacing: 5) {
                        Image(systemName: result.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(result.message).font(.system(size: 12))
                    }
                    .foregroundColor(result.connected ? AuroraTokens.statusGreenDark : AuroraTokens.statusRed)
                }
            }
            .padding(.top, 8)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepEyebrow(String(localized: "Step 3 of 3"))
            Text("You're all set.")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(palette.text)
            Text("Click the aperture icon in your menu bar to open the camera grid, or press your global shortcut.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.subtext)
                .lineSpacing(3)
            if !service.cameras.isEmpty {
                Text("\(service.cameras.count) cameras detected.")
                    .font(.system(size: 12))
                    .foregroundColor(AuroraTokens.statusGreenDark)
                    .padding(.top, 8)
            }
        }
    }

    private func stepEyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(palette.subtext)
            .padding(.bottom, 6)
    }

    private func onField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.subtext)
            content()
        }
        .padding(.bottom, 14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $settings.launchAtLogin) {
                Text("Launch at login")
                    .font(.system(size: 12))
                    .foregroundColor(palette.subtext)
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button(action: { onFinish() }) {
                Text("Skip")
                    .font(.system(size: 12))
                    .foregroundColor(palette.subtext)
                    .padding(.horizontal, 12).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            AuroraPrimaryButton(title: step < 3 ? String(localized: "Continue") : String(localized: "Finish")) {
                if step < 3 {
                    step += 1
                } else {
                    onFinish()
                }
            }
        }
    }

    // MARK: - Test

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            await service.fetchCameras()
            isTesting = false
            if let err = service.errorMessage {
                testResult = TestResult(connected: false, message: err)
            } else {
                let n = service.cameras.count
                testResult = TestResult(connected: true,
                                        message: String(localized: "Connected — \(n) cameras found"))
            }
        }
    }

    private func runPtzTest() {
        isTestingPtz = true
        ptzTestResult = nil
        Task {
            let ok = await service.classicLogin()
            isTestingPtz = false
            if ok {
                ptzTestResult = TestResult(connected: true, message: String(localized: "Signed in — PTZ control ready"))
            } else {
                ptzTestResult = TestResult(connected: false,
                                           message: String(localized: "Login failed — check username and password"))
            }
        }
    }
}
