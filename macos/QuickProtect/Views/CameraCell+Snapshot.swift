import SwiftUI
import AVFoundation
import AppKit

// MARK: - Snapshot capture (S): clipboard or folder, with a toast.

extension CameraCell {

    // MARK: - Snapshot capture (S)

    /// Filename timestamp: QuickProtect-YYYY-MM-DD-HH-mm-ss.png (24-hour clock).
    /// All-dashes: a colon is the legacy macOS path separator (Finder shows it
    /// as a slash), so the time uses dashes too.
    /// POSIX locale keeps the format stable regardless of the user's region.
    static let snapshotTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Capture the frame currently on screen at the streamed resolution and send
    /// it to the configured destination — the clipboard or the selected folder.
    func captureSnapshot() {
        RTSPClient.log("[Snapshot] S pressed focused=\(isFocused) cam=\(camera.name)")
        guard isFocused, !snapshotInFlight else { return }
        let destination = AppSettings.shared.snapshotDestination
        if destination == .folder, AppSettings.shared.resolveSnapshotFolder() == nil {
            showSnapshotToast(String(localized: "Choose a snapshot folder in Settings"), ok: false)
            return
        }
        // Snapshot whichever lens is shown as the primary view (respects a swap).
        let source = secondaryIsPrimary ? secondaryClient : rtspClient
        if source.snapshotCGImage() != nil {
            finishSnapshot(from: source, destination: destination)
        } else {
            // No frame decoded yet — the capture session is still waiting for a
            // keyframe. Arm the capture and complete as soon as one arrives.
            snapshotInFlight = true
            showSnapshotToast(String(localized: "Capturing…"), ok: true)
            awaitFrame(from: source, destination: destination, attempt: 0)
        }
    }

    /// Poll for the first decoded frame (up to ~6s) after S is pressed before a
    /// keyframe is available, then complete the capture.
    func awaitFrame(from source: RTSPClient,
                    destination: AppSettings.SnapshotDestination, attempt: Int) {
        guard snapshotInFlight else { return }
        guard isFocused else { snapshotInFlight = false; return }
        if source.snapshotCGImage() != nil {
            snapshotInFlight = false
            finishSnapshot(from: source, destination: destination)
        } else if attempt < 250 {
            // Some cameras have a long keyframe interval (10s+), so the capture
            // session can take a while to produce its first frame after focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                awaitFrame(from: source, destination: destination, attempt: attempt + 1)
            }
        } else {
            snapshotInFlight = false
            RTSPClient.log("[Snapshot] timed out waiting for a frame")
            showSnapshotToast(String(localized: "Snapshot failed"), ok: false)
        }
    }

    func finishSnapshot(from source: RTSPClient,
                        destination: AppSettings.SnapshotDestination) {
        guard let image = source.snapshotCGImage() else {
            showSnapshotToast(String(localized: "Snapshot failed"), ok: false)
            return
        }
        RTSPClient.log("[Snapshot] captured \(image.width)x\(image.height) dest=\(destination == .clipboard ? "clipboard" : "folder")")
        switch destination {
        case .clipboard:
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
            showSnapshotToast(String(localized: "Copied to clipboard"), ok: true)
        case .folder:
            if saveSnapshotToFolder(image) {
                showSnapshotToast(String(localized: "Snapshot saved"), ok: true)
            } else {
                showSnapshotToast(String(localized: "Snapshot failed"), ok: false)
            }
        }
    }

    /// Writes the captured frame as a PNG into the configured folder.
    func saveSnapshotToFolder(_ image: CGImage) -> Bool {
        guard let folder = AppSettings.shared.resolveSnapshotFolder() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }

        let name = "QuickProtect-\(Self.snapshotTimestamp.string(from: Date())).png"
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        do {
            try png.write(to: folder.appendingPathComponent(name))
            return true
        } catch {
            RTSPClient.log("[Snapshot] save failed: \(error.localizedDescription)")
            return false
        }
    }

    func showSnapshotToast(_ text: String, ok: Bool) {
        snapshotToastGen &+= 1
        let gen = snapshotToastGen
        withAnimation(.easeInOut(duration: 0.2)) {
            snapshotToast = SnapshotToast(text: text, ok: ok)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if gen == snapshotToastGen {
                withAnimation(.easeInOut(duration: 0.3)) { snapshotToast = nil }
            }
        }
    }

    var snapshotToastView: some View {
        VStack {
            if let toast = snapshotToast {
                HStack(spacing: 7) {
                    Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(toast.ok ? Color.green : Color.orange)
                    Text(toast.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(red: 18/255, green: 18/255, blue: 20/255).opacity(0.85))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .clipShape(Capsule())
                .padding(.top, 64)
                .transition(.opacity)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}
