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
    private var errorCancellable: AnyCancellable?
    private var frameCancellable: AnyCancellable?
    private var certificateCancellable: AnyCancellable?

    /// Failure state shown by the view between recovery attempts.
    private let streamState = PinnedStreamState()
    private var recovery = StreamRecoveryBackoff()
    /// The pending fresh-URL attempt after a failure.
    private var retryTask: Task<Void, Never>?

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

        let panel = PinnedPanel(
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

        panel.contentViewController = NSHostingController(rootView: makeView())
        panel.delegate = self

        dimsCancellable = client.$videoDimensions
            .receive(on: RunLoop.main)
            .sink { [weak self] dims in self?.applyAspect(dims) }
        // The client never retries a URL on its own, so any error it reports
        // (connection failed, RTSP 404 after another client deleted the
        // allocation, receive error) needs a fresh URL.
        errorCancellable = client.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let error else { return }
                self?.streamFailed(reason: error)
            }
        frameCancellable = client.$hasFrame
            .receive(on: RunLoop.main)
            .sink { [weak self] hasFrame in
                if hasFrame { self?.streamRecovered() }
            }
        certificateCancellable = service.$certificateChange
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] changed in self?.certificateChanged(changed) }
    }

    private func makeView() -> PinnedCameraView {
        PinnedCameraView(
            client: client,
            stream: streamState,
            cameraName: camera.name,
            onReconnect: { [weak self] in self?.reconnect() },
            onReviewCertificate: { [weak self] in
                guard let service = self?.service else { return }
                CertificateReviewAlert.present(service: service)
            },
            onClose: { [weak self] in self?.requestClose() }
        )
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
            (panel.contentViewController as? NSHostingController<PinnedCameraView>)?.rootView = makeView()
        }
        // Pinned at launch while offline, or offline long enough to fail →
        // start streaming as soon as it comes online, without waiting out a
        // pending retry.
        if cameWonline, streamTask == nil, connectedQuality == nil {
            reconnect()
        }
    }

    private func requestClose() { onClose(cameraId) }

    /// Disconnect the stream, free the server-side allocation, and close the
    /// window. Persistence is the manager's responsibility (kept on quit,
    /// removed on explicit unpin).
    func teardown() {
        recovery.stop()
        retryTask?.cancel()
        retryTask = nil
        streamTask?.cancel()
        streamTask = nil
        dimsCancellable = nil
        errorCancellable = nil
        frameCancellable = nil
        certificateCancellable = nil
        client.disconnect()
        releaseAllocation()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    // MARK: Stream

    private func startStream() {
        guard let service, camera.isOnline, !recovery.isStopped else { return }
        // A pinned window is a dedicated viewing surface, so resolve `.auto` as
        // if focused (high). Explicit per-camera qualities are honoured as set.
        let quality = AppSettings.shared.effectiveStreamQuality(for: cameraId)
            .resolve(focused: true)
        let camera = self.camera
        // The attempt shows the spinner; a failure brings the overlay back.
        streamState.isFailed = false
        streamTask = Task { [weak self] in
            let stream = await service.createPinnedStreamURL(for: camera, quality: quality.apiValue)
            guard let self, !Task.isCancelled else { return }
            self.streamTask = nil
            guard let stream else {
                self.streamFailed(reason: nil)
                return
            }
            self.connectedQuality = stream.quality
            self.client.connect(to: stream.url, pinKey: self.service?.controllerAddress?.pinKey)
            // Negotiate audio (muted by default) and decode capture frames so the
            // window's mute and snapshot controls work without a reconnect.
            self.client.setMuted(true)
            self.client.setAudioActive(true)
            self.client.setCaptureActive(true)
        }
    }

    // MARK: Recovery

    /// The URL POST failed (`reason` nil) or the client lost its session.
    /// Frees the allocation — it may already be gone server-side, and a live
    /// one would leak once a fresh URL replaces it — and schedules a fresh-URL
    /// attempt on the backoff. Mirrors the .NET coordinator's
    /// `OnAllocationLost`.
    private func streamFailed(reason: String?) {
        // One pending attempt at a time; a POST in flight reports for itself.
        guard retryTask == nil, streamTask == nil, let delay = recovery.failed() else { return }
        RTSPClient.log("[Pinned] \(camera.name): stream failed (\(reason ?? "no stream URL")); "
            + "fresh URL in \(Int(delay))s")
        streamState.isFailed = true
        streamState.reason = reason
        client.disconnect()
        releaseAllocation()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // cancelled: torn down, or a manual reconnect took over
            }
            self?.reconnect()
        }
    }

    /// Starts a fresh-URL attempt now (Reconnect button, camera back online,
    /// or the backoff elapsing). The backoff keeps its place until a frame paints.
    private func reconnect() {
        retryTask?.cancel()
        retryTask = nil
        guard streamTask == nil else { return }
        if connectedQuality != nil {
            client.disconnect()
            releaseAllocation()
        }
        startStream()
    }

    /// The controller's certificate changed (streams can't connect until the
    /// user trusts it) or was just trusted — then reconnect right away rather
    /// than waiting out the backoff the rejected attempts built up.
    private func certificateChanged(_ changed: Bool) {
        streamState.certificateChanged = changed
        guard !changed, streamState.isFailed else { return }
        recovery.recovered()
        reconnect()
    }

    private func streamRecovered() {
        recovery.recovered()
        streamState.isFailed = false
        streamState.reason = nil
    }

    private func releaseAllocation() {
        guard let quality = connectedQuality else { return }
        connectedQuality = nil
        service?.releasePinnedStream(for: cameraId, quality: quality)
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

/// A pinned window's stream failure, published by its controller so the view
/// can show why the feed is gone while the next fresh-URL attempt is pending.
@MainActor
final class PinnedStreamState: ObservableObject {
    /// True between a failure and the next attempt.
    @Published var isFailed = false
    /// The client's reason, when it gave one (nil when the URL POST failed).
    @Published var reason: String?
    /// The controller's certificate changed; the failure overlay offers review.
    @Published var certificateChanged = false
}

/// The contents of a pinned floating window: the live feed plus hover chrome
/// (camera name, mute, snapshot, close). Reuses `ProtectStreamView` for display
/// and `AuroraFocusIconButton` for the controls.
struct PinnedCameraView: View {
    @ObservedObject var client: RTSPClient
    @ObservedObject var stream: PinnedStreamState
    let cameraName: String
    let onReconnect: () -> Void
    let onReviewCertificate: () -> Void
    let onClose: () -> Void

    @State private var hover = false
    @State private var toast: String?
    @State private var toastGen = 0

    var body: some View {
        ZStack {
            Color.black
            ProtectStreamView(displayLayer: client.displayLayer, videoGravity: .resizeAspect)
            // Drag anywhere outside the controls to move the window.
            WindowDragArea()

            if !client.hasFrame {
                if stream.isFailed {
                    failedOverlay
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .allowsHitTesting(false)
                }
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

    /// Shown between recovery attempts. Only the button takes clicks, so the
    /// window can still be dragged from anywhere else.
    private var failedOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .allowsHitTesting(false)
            VStack(spacing: 6) {
                if stream.certificateChanged {
                    certificateContent
                } else {
                    failureContent
                }
            }
        }
    }

    private var certificateContent: some View {
        Group {
            Group {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 18))
                    .foregroundColor(AuroraTokens.statusOrange)
                Text("Controller certificate changed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)
            Button("Review Certificate…", action: onReviewCertificate)
                .buttonStyle(AuroraStatePillButtonStyle(primary: true))
        }
    }

    private var failureContent: some View {
        Group {
            Group {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 18))
                    .foregroundColor(AuroraTokens.statusRed)
                Text("Stream unavailable")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            .allowsHitTesting(false)
            Button("Reconnect", action: onReconnect)
                .buttonStyle(AuroraStatePillButtonStyle(primary: true))
            if let reason = stream.reason {
                Text(reason)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
        }
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

// MARK: - Window drag

/// Borderless panel that moves when dragged by its video. The move starts here,
/// before the event reaches SwiftUI: `isMovableByWindowBackground` gets no
/// background drags through the hosting view on macOS 27, and a view's own
/// `mouseDown` isn't reliable either — the hosting view swallowed about a
/// third of the clicks that hit-tested to `WindowDragNSView`.
private final class PinnedPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView,
           content.hitTest(content.convert(event.locationInWindow, from: nil)) is WindowDragNSView {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

/// Marks where a drag moves the window: everywhere over the video that the
/// controls and the resize grip don't cover (they sit above it and win the
/// hit test).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    // `PinnedPanel` starts the drag; don't let AppKit start a second one.
    override var mouseDownCanMoveWindow: Bool { false }
    // The pinned panel is non-activating; accept the first click without focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
