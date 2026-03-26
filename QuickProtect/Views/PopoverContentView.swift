import SwiftUI

/// Root view shown inside the status-bar popover.
struct PopoverContentView: View {
    @ObservedObject var service: ProtectService
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))
            CameraGridView(service: service)
        }
        .preferredColorScheme(.dark)
        .background(Color(white: 0.1))
    }

    // MARK: - Header bar

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 13, weight: .semibold))

            Text("QuickProtect")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            if service.isLoading {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 16, height: 16)
            }

            // Refresh
            Button {
                Task { await service.fetchCameras() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Refresh cameras")
            .disabled(service.isLoading)

            // Settings
            Button(action: openSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 12))
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Settings")

            // Quit
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Quit QuickProtect")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(white: 0.13))
    }
}

// Minimal flat button style for the header icons
private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .white : .secondary)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.15 : 0))
            )
            .contentShape(Rectangle())
    }
}
