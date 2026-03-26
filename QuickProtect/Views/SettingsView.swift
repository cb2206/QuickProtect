import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var service: ProtectService

    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var isRecordingHotkey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("QuickProtect")
                    .font(.title2.bold())
                Text("v0.1")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 14)

            Divider()

            // Two-column layout: settings on left, camera list on right
            HStack(alignment: .top, spacing: 0) {
                // Left: connection + shortcut settings
                Form {
                    Section("Connection") {
                        LabeledContent("Controller IP") {
                            TextField("192.168.1.1", text: $settings.ipAddress)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }

                        LabeledContent("API Key") {
                            SecureField("Paste your API key here", text: $settings.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }

                        LabeledContent("Stream protocol") {
                            Toggle("Use plain RTSP (port 7447)", isOn: $settings.usePlainRtsp)
                                .help("Enable if streams fail due to TLS certificate errors.")
                        }
                    }

                    Section("Global Shortcut") {
                        LabeledContent("Toggle panel") {
                            HStack(spacing: 8) {
                                Text(isRecordingHotkey ? "Press shortcut…" : settings.hotkeyDisplayString)
                                    .foregroundColor(isRecordingHotkey ? .accentColor : .primary)
                                    .frame(width: 120, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(isRecordingHotkey
                                                  ? Color.accentColor.opacity(0.15)
                                                  : Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(isRecordingHotkey ? Color.accentColor : Color.gray.opacity(0.3))
                                    )

                                Button(isRecordingHotkey ? "Cancel" : "Record") {
                                    isRecordingHotkey.toggle()
                                }
                                .font(.caption)

                                if settings.globalHotkey() != nil {
                                    Button("Clear") {
                                        settings.clearGlobalHotkey()
                                        HotkeyManager.shared.unregister()
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 380)

                // Right: camera visibility list
                if !service.cameras.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Cameras")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 8)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(service.cameras) { camera in
                                    Toggle(isOn: Binding(
                                        get: { !settings.isHidden(camera.id) },
                                        set: { settings.setHidden(!$0, for: camera.id) }
                                    )) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(camera.isOnline ? Color.green : Color.red)
                                                .frame(width: 7, height: 7)
                                            Text(camera.name)
                                                .lineLimit(1)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                    .frame(width: 200)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                }
            }

            Divider()

            // Footer / test button
            HStack {
                Button {
                    runTest()
                } label: {
                    Label("Test Connection", systemImage: "network")
                }
                .disabled(isTesting || settings.ipAddress.isEmpty || settings.apiKey.isEmpty)

                if isTesting {
                    ProgressView().scaleEffect(0.7).padding(.leading, 4)
                }

                Spacer()

                if let result = testResult {
                    Label(result.message, systemImage: result.icon)
                        .font(.caption)
                        .foregroundColor(result.color)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: testResult?.message)
            .padding(16)
        }
        .frame(minWidth: 620, maxWidth: 700, minHeight: 400, maxHeight: 480)
        .background(hotkeyRecorderOverlay)
    }

    // MARK: - Hotkey recorder

    /// Invisible overlay that captures the next key press when recording.
    private var hotkeyRecorderOverlay: some View {
        Group {
            if isRecordingHotkey {
                HotkeyRecorderView { keyCode, modifiers in
                    let carbonMods = HotkeyManager.carbonModifiers(from: modifiers)
                    settings.setGlobalHotkey(keyCode: UInt32(keyCode), carbonModifiers: carbonMods)
                    HotkeyManager.shared.register(keyCode: UInt32(keyCode), carbonModifiers: carbonMods)
                    isRecordingHotkey = false
                } onCancel: {
                    isRecordingHotkey = false
                }
            }
        }
    }

    // MARK: - Test connection

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            await service.fetchCameras()
            isTesting = false
            if let err = service.errorMessage {
                testResult = TestResult(message: err, icon: "xmark.circle.fill", color: .red)
            } else {
                let n = service.cameras.count
                testResult = TestResult(
                    message: "Connected – \(n) camera\(n == 1 ? "" : "s") found",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
            }
        }
    }

    private struct TestResult: Equatable {
        let message: String
        let icon: String
        let color: Color
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
