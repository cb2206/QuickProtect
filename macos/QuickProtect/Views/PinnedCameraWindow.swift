import SwiftUI
import AppKit
import AVFoundation
import Combine

// MARK: - Manager

/// Owns the set of pinned floating windows, one per camera. Lives on the
/// AppDelegate so a pinned window's stream survives the popover opening and
/// closing. When nothing is pinned no controllers — and therefore no streams —
/// exist, preserving the app's "0% CPU when the popover is closed" behaviour.
@MainActor
final class PinnedWindowManager {
    private var controllers: [String: PinnedCameraController] = [:]
    private weak var service: ProtectService?
    private var camerasCancellable: AnyCancellable?

    init(service: ProtectService) {
        self.service = service
        // Reconcile whenever the camera list changes: this restores persisted
        // pins once their camera is known on launch, and refreshes the camera
        // data (e.g. PTZ enrichment, name changes) for open windows.
        camerasCancellable = service.$cameras
            .receive(on: RunLoop.main)
            .sink { [weak self] cameras in self?.reconcile(with: cameras) }
    }

    /// True when a live window exists or the camera is persisted as pinned.
    func isPinned(_ cameraId: String) -> Bool {
        controllers[cameraId] != nil || AppSettings.shared.isPinned(cameraId)
    }

    func togglePin(_ camera: Camera) {
        if isPinned(camera.id) { unpin(camera.id) } else { pin(camera) }
    }

    func pin(_ camera: Camera) {
        guard controllers[camera.id] == nil, let service else { return }
        AppSettings.shared.setPinned(camera.id)
        let controller = PinnedCameraController(
            camera: camera, service: service,
            cascadeIndex: controllers.count,
            onClose: { [weak self] id in self?.unpin(id) }
        )
        controllers[camera.id] = controller
        controller.show()
    }

    func unpin(_ cameraId: String) {
        AppSettings.shared.removePinned(cameraId)
        controllers.removeValue(forKey: cameraId)?.teardown()
    }

    /// Restore persisted pins for cameras now present, and refresh open windows.
    /// Never auto-pins a camera that isn't already persisted, and never removes
    /// persistence on a transient empty list — a camera that briefly drops out
    /// of a fetch keeps its pin and re-opens when it returns.
    private func reconcile(with cameras: [Camera]) {
        guard let service else { return }
        let byId = Dictionary(cameras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for state in AppSettings.shared.pinnedCameras() {
            guard let camera = byId[state.cameraId] else { continue }
            if let existing = controllers[state.cameraId] {
                existing.updateCamera(camera)
            } else {
                let controller = PinnedCameraController(
                    camera: camera, service: service,
                    cascadeIndex: controllers.count,
                    onClose: { [weak self] id in self?.unpin(id) }
                )
                controllers[state.cameraId] = controller
                controller.show()
            }
        }
    }

    /// Tear down every window (app termination). Persistence is left intact so
    /// the windows reopen on next launch; the server-side allocations are freed.
    func closeAll() {
        for controller in controllers.values { controller.teardown() }
        controllers.removeAll()
        service?.cleanupPinnedStreams()
    }
}

// MARK: - Controller

/// Owns one borderless, always-on-top floating window plus its own RTSPClient,
/// independent of the popover's client manager. Handles stream lifecycle,
/// aspect-ratio locking, and frame persistence.
@MainActor
final class PinnedCameraController: NSObject, NSWindowDelegate {
    let cameraId: String
    private var camera: Camera
    private weak var service: ProtectService?
    private let onClose: (String) -> Void

    private let client = RTSPClient()
    private let panel: NSPanel
    private var streamTask: Task<Void, Never>?
    private var connectedQuality: String?
    private var dimsCancellable: AnyCancellable?

    /// True once the on-screen size has been fixed to the real video aspect.
    private var lockedAspect = false
    /// True when the initial size came from a saved frame (don't auto-resize it).
    private let restoredSavedFrame: Bool
    /// Suppresses frame persistence while we programmatically resize.
    private var isAdjustingFrame = false

    init(camera: Camera, service: ProtectService, cascadeIndex: Int,
         onClose: @escaping (String) -> Void) {
        self.cameraId = camera.id
        self.camera = camera
        self.service = service
        self.onClose = onClose

        let aspect = AppSettings.shared.cachedAspectRatio(for: camera.id)
            ?? PinnedWindowGeometry.fallbackAspect
        let saved = AppSettings.shared.pinnedCameras().first { $0.cameraId == camera.id }?.frame
        let frame = Self.initialFrame(saved: saved, aspect: aspect, cascadeIndex: cascadeIndex)
        self.restoredSavedFrame = saved != nil

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Sit one step above the popover (`.popUpMenu`) so a freshly pinned
        // window is never hidden behind the open grid.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: PinnedWindowGeometry.minWidth,
                               height: (PinnedWindowGeometry.minWidth / aspect).rounded())
        // Lock to the (cached) aspect now; updated to the exact ratio when the
        // first frame's real dimensions arrive.
        panel.contentAspectRatio = NSSize(width: aspect, height: 1)
        self.panel = panel

        super.init()

        let view = PinnedCameraView(
            client: client,
            cameraName: camera.name,
            onClose: { [weak self] in self?.requestClose() }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self

        dimsCancellable = client.$videoDimensions
            .receive(on: RunLoop.main)
            .sink { [weak self] dims in self?.applyAspect(dims) }
    }

    func show() {
        panel.orderFrontRegardless()
        persistFrame()
        startStream()
    }

    func updateCamera(_ camera: Camera) {
        let nameChanged = camera.name != self.camera.name
        let cameWonline = camera.isOnline && !self.camera.isOnline
        self.camera = camera
        if nameChanged {
            let view = PinnedCameraView(
                client: client,
                cameraName: camera.name,
                onClose: { [weak self] in self?.requestClose() }
            )
            (panel.contentViewController as? NSHostingController<PinnedCameraView>)?.rootView = view
        }
        // Pinned at launch while offline → start streaming once it comes online.
        if cameWonline, streamTask == nil, connectedQuality == nil {
            startStream()
        }
    }

    private func requestClose() { onClose(cameraId) }

    /// Disconnect the stream, free the server-side allocation, and close the
    /// window. Persistence is the manager's responsibility (kept on quit,
    /// removed on explicit unpin).
    func teardown() {
        streamTask?.cancel()
        streamTask = nil
        dimsCancellable = nil
        client.disconnect()
        if let quality = connectedQuality {
            service?.releasePinnedStream(for: cameraId, quality: quality)
        }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    // MARK: Stream

    private func startStream() {
        guard let service, camera.isOnline else { return }
        // A pinned window is a dedicated viewing surface, so resolve `.auto` as
        // if focused (high). Explicit per-camera qualities are honoured as set.
        let quality = AppSettings.shared.effectiveStreamQuality(for: cameraId)
            .resolve(focused: true)
        let camera = self.camera
        streamTask = Task { [weak self] in
            guard let stream = await service.createPinnedStreamURL(
                for: camera, quality: quality.apiValue) else { return }
            guard let self, !Task.isCancelled else { return }
            self.connectedQuality = stream.quality
            self.streamTask = nil
            self.client.connect(to: stream.url, pinKey: self.service?.controllerAddress?.pinKey)
            // Negotiate audio (muted by default) and decode capture frames so the
            // window's mute and snapshot controls work without a reconnect.
            self.client.setMuted(true)
            self.client.setAudioActive(true)
            self.client.setCaptureActive(true)
        }
    }

    // MARK: Aspect ratio

    private func applyAspect(_ dims: CGSize) {
        guard dims.width > 0, dims.height > 0 else { return }
        let ar = dims.width / dims.height
        panel.contentAspectRatio = NSSize(width: dims.width, height: dims.height)
        AppSettings.shared.cacheVideoDimensions(dims, for: cameraId)
        // Resize to the true aspect only once, and only when we didn't restore a
        // user-sized frame — otherwise respect what the user (or last session)
        // chose and just keep the ratio locked from here on.
        guard !lockedAspect else { return }
        lockedAspect = true
        guard !restoredSavedFrame else { return }
        let size = PinnedWindowGeometry.defaultSize(aspectRatio: ar)
        guard size != panel.frame.size else { return }
        isAdjustingFrame = true
        // Keep the top-left corner anchored while the height changes.
        var frame = panel.frame
        frame.origin.y += frame.size.height - size.height
        frame.size = size
        panel.setFrame(Self.clamp(frame), display: true)
        isAdjustingFrame = false
        persistFrame()
    }

    // MARK: Geometry helpers

    private static func initialFrame(saved: NSRect?, aspect: CGFloat,
                                     cascadeIndex: Int) -> NSRect {
        if let saved { return clamp(saved) }
        let size = PinnedWindowGeometry.defaultSize(aspectRatio: aspect)
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let inset: CGFloat = 16
        let step = CGFloat(cascadeIndex) * 28
        // Bottom-right corner: the popover anchors to the menu bar (top), so this
        // keeps a new window clear of it. Extra windows cascade up and to the left.
        let x = screen.maxX - size.width - inset - step
        let y = screen.minY + inset + step
        return clamp(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    /// Keep a frame fully within a visible screen. Picks the screen it overlaps
    /// most (falling back to main, e.g. a monitor was disconnected since last
    /// launch) and shifts the origin so no edge spills off. A window larger than
    /// the work area is pinned so its top-left stays visible.
    private static func clamp(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let best = screens.max { overlapArea($0.visibleFrame, frame) < overlapArea($1.visibleFrame, frame) }
        let vf = (best ?? NSScreen.main ?? screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        var f = frame
        f.origin.x = f.width <= vf.width
            ? min(max(f.minX, vf.minX), vf.maxX - f.width)
            : vf.minX
        f.origin.y = f.height <= vf.height
            ? min(max(f.minY, vf.minY), vf.maxY - f.height)
            : vf.maxY - f.height
        return f
    }

    /// Area of the intersection of two rects (0 when they don't overlap).
    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    private func persistFrame() {
        AppSettings.shared.setPinnedFrame(panel.frame, for: cameraId)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame else { return }
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isAdjustingFrame else { return }
        persistFrame()
    }
}

// MARK: - View

/// The contents of a pinned floating window: the live feed plus hover chrome
/// (camera name, mute, snapshot, close). Reuses `ProtectStreamView` for display
/// and `AuroraFocusIconButton` for the controls.
struct PinnedCameraView: View {
    @ObservedObject var client: RTSPClient
    let cameraName: String
    let onClose: () -> Void

    @State private var hover = false
    @State private var toast: String?
    @State private var toastGen = 0

    var body: some View {
        ZStack {
            Color.black
            ProtectStreamView(displayLayer: client.displayLayer, videoGravity: .resizeAspect)

            if !client.hasFrame {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }

            chrome
                .opacity(hover ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: hover)
                .allowsHitTesting(hover)

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .onHover { hover = $0 }
        .preferredColorScheme(.dark)
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    if client.hasFrame { AuroraRecDot(size: 5) }
                    Text(cameraName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())

                Spacer(minLength: 4)

                HStack(spacing: 1) {
                    if client.hasAudio {
                        AuroraFocusIconButton(
                            systemName: client.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            help: client.isMuted ? String(localized: "Unmute (M)") : String(localized: "Mute (M)"),
                            action: toggleMute)
                    }
                    AuroraFocusIconButton(systemName: "camera",
                                          help: String(localized: "Save snapshot"),
                                          action: captureSnapshot)
                    AuroraFocusIconButton(systemName: "xmark",
                                          help: String(localized: "Unpin Floating Window"),
                                          action: onClose)
                }
                .padding(2)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .padding(8)

            Spacer()

            // Bottom-right corner grip: drag to resize, aspect-ratio preserved.
            HStack {
                Spacer()
                ResizeGrip()
                    .padding(6)
            }
        }
    }

    private func toggleMute() { client.setMuted(!client.isMuted) }

    private func captureSnapshot() {
        let text = PinnedSnapshot.capture(from: client)
        showToast(text)
    }

    private func showToast(_ text: String) {
        toastGen &+= 1
        let gen = toastGen
        withAnimation(.easeInOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if gen == toastGen { withAnimation(.easeInOut(duration: 0.3)) { toast = nil } }
        }
    }
}

// MARK: - Resize grip

/// Bottom-right corner affordance for resizing a borderless pinned window.
/// The visible chevron is SwiftUI; the transparent `WindowResizeHandle` on top
/// captures the drag and resizes the window directly (keeping aspect ratio).
private struct ResizeGrip: View {
    var body: some View {
        ZStack {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            WindowResizeHandle()
        }
        .frame(width: 20, height: 20)
        .help(String(localized: "Drag to resize"))
    }
}

private struct WindowResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizeHandleNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Transparent NSView that resizes its window on drag. Width follows the cursor;
/// height is derived from the window's locked aspect ratio. The top-left corner
/// stays anchored, so the window grows toward the cursor. `setFrame` isn't bound
/// by `contentAspectRatio` (that only constrains the system's own resize), so we
/// constrain explicitly via `PinnedWindowGeometry`.
private final class ResizeHandleNSView: NSView {
    private var anchorLeft: CGFloat = 0
    private var anchorTop: CGFloat = 0

    // Don't let `isMovableByWindowBackground` hijack the drag as a window move.
    override var mouseDownCanMoveWindow: Bool { false }
    // The pinned panel is non-activating; accept the first click without focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        anchorLeft = window.frame.minX
        anchorTop = window.frame.maxY
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let ca = window.contentAspectRatio
        let aspect = (ca.width > 0 && ca.height > 0)
            ? ca.width / ca.height : PinnedWindowGeometry.fallbackAspect
        let mouse = NSEvent.mouseLocation
        let size = PinnedWindowGeometry.constrain(
            NSSize(width: mouse.x - anchorLeft, height: 0), toAspectRatio: aspect)
        window.setFrame(
            NSRect(x: anchorLeft, y: anchorTop - size.height,
                   width: size.width, height: size.height),
            display: true)
    }
}

// MARK: - Snapshot helper

/// Writes the pinned stream's current frame to the configured destination
/// (clipboard or folder) and returns a localized confirmation for the toast.
/// Mirrors the focus-view snapshot, scoped to the single pinned client.
@MainActor
enum PinnedSnapshot {
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func capture(from client: RTSPClient) -> String {
        let destination = AppSettings.shared.snapshotDestination
        if destination == .folder, AppSettings.shared.resolveSnapshotFolder() == nil {
            return String(localized: "Choose a snapshot folder in Settings")
        }
        guard let image = client.snapshotCGImage() else {
            return String(localized: "Capturing…")
        }
        switch destination {
        case .clipboard:
            let nsImage = NSImage(cgImage: image,
                                  size: NSSize(width: image.width, height: image.height))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
            return String(localized: "Copied to clipboard")
        case .folder:
            return saveToFolder(image) ? String(localized: "Snapshot saved")
                                       : String(localized: "Snapshot failed")
        }
    }

    private static func saveToFolder(_ image: CGImage) -> Bool {
        guard let folder = AppSettings.shared.resolveSnapshotFolder() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let name = "QuickProtect-\(timestamp.string(from: Date())).png"
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        do {
            try png.write(to: folder.appendingPathComponent(name))
            return true
        } catch {
            RTSPClient.log("[Snapshot] pinned save failed: \(error.localizedDescription)")
            return false
        }
    }
}
