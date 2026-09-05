import SwiftUI
import AVFoundation
import AppKit

// MARK: - Camera cell

struct CameraCell: View {
    let camera: Camera
    let service: ProtectService
    let span: Int
    let loadOrder: Int
    @Binding var focusedCameraId: String?

    @Environment(\.appState) var appState
    @ObservedObject var rtspClient: RTSPClient
    /// Second lens stream (e.g. doorbell package camera). For single-lens
    /// cameras this is an unused throwaway client that never connects.
    @ObservedObject var secondaryClient: RTSPClient
    @State var mode: Mode = .connecting
    @State var streamTask: Task<Void, Never>?
    @State var secondaryStreamTask: Task<Void, Never>?
    @State var packageSnapshotTask: Task<Void, Never>?
    /// Concrete quality the primary client is currently connected (or connecting)
    /// at. Tracks the resolved substream so a quality change can release the old
    /// server allocation instead of leaking it until cleanup.
    @State var primaryQuality: StreamQuality?
    /// True while a quality switch reconnects with the previous frame left on the
    /// display layer (see `RTSPClient.connect(keepLastFrame:)`). Suppresses the
    /// connecting overlay so the held frame shows through until the new feed
    /// arrives, instead of a grey spinner.
    @State var preservingFrame = false
    /// Pending auto down-switch (high → low on leaving focus), delayed so a quick
    /// focus → unfocus → focus doesn't churn the grid stream. Cancelled if focus
    /// returns first.
    @State var downSwitchWork: DispatchWorkItem?
    /// When true, the secondary lens fills the frame and the main lens moves
    /// into the PiP. Reset to false every time the camera (re)enters focus.
    @State var secondaryIsPrimary = false

    // Zoom & pan (only active when focused)
    @State var zoomScale: CGFloat = 1.0
    @State var panOffset: CGSize = .zero
    @State var lastPanOffset: CGSize = .zero
    @State var keyMonitor: Any?
    @State var cellSize: CGSize = .zero       // for pan clamping
    @State var focusFillMode: Bool = false    // fit/fill toggle; loaded per-camera on focus (default: fit)
    @State var ptzActiveDirection: AuroraPtzDpad.Direction?  // lit arrow on the d-pad
    @State var ptzActiveZoom: AuroraPtzZoomControl.Direction?  // lit +/− on the zoom pill
    @State var reattachNonce = 0               // bump to re-attach the display layer
    @State var clockTick: Date = Date()
    @State var clockTimer: Timer?
    @State var isTrueFullscreen = false
    @State var hudVisible = true
    @State var hudHideWorkItem: DispatchWorkItem?
    @State var mouseMonitor: Any?
    @State var snapshotToast: SnapshotToast?
    @State var snapshotToastGen = 0
    @State var snapshotInFlight = false        // armed, waiting for a frame

    enum Mode { case connecting, playing, failed }

    /// Transient confirmation shown after pressing S.
    struct SnapshotToast: Equatable {
        let text: String
        let ok: Bool
    }

    /// Grid ↔ focus expansion. A spring settles more naturally than easeInOut;
    /// a high damping fraction keeps it from overshooting (no bounce on video).
    static let focusAnimation: Animation = .spring(response: 0.40, dampingFraction: 0.86)

    init(camera: Camera, service: ProtectService, span: Int,
         focusedCameraId: Binding<String?>, clientManager: RTSPClientManager, loadOrder: Int) {
        self.camera = camera
        self.service = service
        self.span = span
        self.loadOrder = loadOrder
        self._focusedCameraId = focusedCameraId
        self._rtspClient = ObservedObject(wrappedValue: clientManager.client(for: camera.id))
        if let lens = camera.secondaryLens {
            self._secondaryClient = ObservedObject(
                wrappedValue: clientManager.client(for: camera.id, lens: lens.quality))
        } else {
            // Single-lens camera: bind a shared, never-connected client so the
            // view struct can be cheaply recreated without allocating per render.
            self._secondaryClient = ObservedObject(wrappedValue: Self.idleSecondaryClient)
        }
    }

    /// Placeholder secondary client for single-lens cameras. Never connected and
    /// never displayed (its PiP is gated behind `camera.secondaryLens != nil`).
    static let idleSecondaryClient = RTSPClient()

    /// The client whose frame fills the main viewport (swaps with the PiP).
    var primaryClient: RTSPClient { secondaryIsPrimary ? secondaryClient : rtspClient }
    /// The client shown in the small picture-in-picture window.
    var pipClient: RTSPClient { secondaryIsPrimary ? rtspClient : secondaryClient }

    /// Swappable PiP over the focused / fullscreen view.
    var showsFocusPip: Bool {
        isFocused && camera.secondaryLens != nil
            && AppSettings.shared.showsSecondaryLensPip(for: camera.id)
    }

    /// Display-only PiP on the grid tile, shown once the tile is live.
    var showsGridPip: Bool {
        !isFocused && appearsLive && camera.secondaryLens != nil
            && AppSettings.shared.showsSecondaryLensPipInGrid(for: camera.id)
    }

    var showsPip: Bool { showsFocusPip || showsGridPip }

    /// Whether the secondary stream should currently be connected — either the
    /// grid PiP is on (runs whenever the tile is visible) or the camera is
    /// focused with the focus PiP on.
    var wantsSecondaryStream: Bool {
        guard camera.secondaryLens != nil else { return false }
        if AppSettings.shared.showsSecondaryLensPipInGrid(for: camera.id) { return true }
        return isFocused && AppSettings.shared.showsSecondaryLensPip(for: camera.id)
    }

    var isFocused: Bool { focusedCameraId == camera.id }

    /// The concrete substream this tile should be playing right now: the camera's
    /// effective quality (override or global default) resolved for the current
    /// focus state — so `.auto` is low in the grid and high when enlarged.
    var desiredPrimaryQuality: StreamQuality {
        AppSettings.shared.effectiveStreamQuality(for: camera.id)
            .resolve(focused: isFocused,
                     gridIsLarge: AppSettings.shared.cameraSize(for: camera.id) == .large)
    }

    /// The tile reads as live whenever it's playing or holding the previous frame
    /// through a quality switch — used to keep the rec dot and grid PiP from
    /// blinking during an auto down-switch reconnect (which dips `mode`).
    var appearsLive: Bool { mode == .playing || preservingFrame }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Stream view: use .resizeAspect when focused to preserve full frame
            GeometryReader { geo in
                ProtectStreamView(
                    displayLayer: primaryClient.displayLayer,
                    videoGravity: isFocused ? (focusFillMode ? .resizeAspectFill : .resizeAspect) : .resizeAspectFill,
                    reattachNonce: reattachNonce,
                    onZoom: isFocused ? { delta in
                        let newScale = zoomScale + delta
                        zoomScale = max(1.0, min(8.0, newScale))
                        if zoomScale <= 1.0 { panOffset = .zero; lastPanOffset = .zero }
                    } : nil,
                    onPan: isFocused ? { dx, dy in
                        guard zoomScale > 1.0 else { return }
                        let maxPanX = cellSize.width * (zoomScale - 1) / 2
                        let maxPanY = cellSize.height * (zoomScale - 1) / 2
                        // Add the deltas: verified by hand against Photos — with the
                        // system scroll preference already baked into
                        // scrollingDeltaX/Y, adding gives the Photos-style pan.
                        // Do not "fix" the sign without testing on a trackpad.
                        let newX = lastPanOffset.width + dx
                        let newY = lastPanOffset.height + dy
                        panOffset = CGSize(
                            width: max(-maxPanX, min(maxPanX, newX)),
                            height: max(-maxPanY, min(maxPanY, newY))
                        )
                        lastPanOffset = panOffset
                    } : nil,
                    onKeyPress: isFocused ? { keyCode in
                        if keyCode == 3 { toggleTrueFullscreen() }     // F
                        else if keyCode == 53 { handleEscape() }       // Escape
                        else if keyCode == 46 { toggleMute() }         // M
                        else if keyCode == 8, showsPip { swapLenses() } // C
                        else if keyCode == 1 { captureSnapshot() }      // S
                        // PTZ keys are handled by the NSEvent monitors (keyDown + keyUp)
                    } : nil
                )
                    .scaleEffect(isFocused ? zoomScale : 1.0)
                    .offset(x: isFocused ? panOffset.width : 0,
                            y: isFocused ? panOffset.height : 0)
                    .onAppear { cellSize = geo.size }
                    .onChange(of: geo.size) { cellSize = $0 }
            }
            .background(Color(white: 0.05))

            // Package lens swapped into the main viewport before its first
            // keyframe: show the controller snapshot until real frames arrive.
            // Main-lens clients never carry a placeholder, so this is inert
            // for ordinary tiles.
            if !primaryClient.hasFrame, let placeholder = primaryClient.placeholderImage {
                Image(decorative: placeholder, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: isFocused && !focusFillMode ? .fit : .fill)
                    .frame(width: cellSize.width, height: cellSize.height)
                    .clipped()
            }

            // During a quality switch the previous frame is held on the display
            // layer (keepLastFrame), so suppress the connecting spinner — the held
            // frame shows through until the new feed replaces it.
            if mode != .playing && !preservingFrame {
                stateOverlay
                    .transition(.opacity)
            }

            if !isFocused {
                nameBadge
            }

            if isFocused {
                if isTrueFullscreen {
                    AuroraFullscreenHUD(
                        cameraName: camera.name,
                        isPtz: camera.isPtz,
                        now: clockTick,
                        visible: hudVisible,
                        canZoom: camera.canZoom,
                        hasAudio: rtspClient.hasAudio,
                        isMuted: rtspClient.isMuted
                    )
                    .transition(.opacity)
                } else {
                    focusOverlay
                        .transition(.opacity)
                }
            }

            // Rendered last so the PiP sits above the focus chrome and the
            // fullscreen HUD, keeping it visible and first to receive taps.
            if showsPip {
                secondaryLensPiP
                    .transition(.opacity)
            }

            // Snapshot confirmation, topmost so it reads over the PiP and HUD.
            if isFocused {
                snapshotToastView
            }
        }
        // PTZ problems (a failed classic-API login) are per-camera feedback —
        // shown as a toast on the focused camera, never as the grid's error card.
        .onChange(of: service.ptzErrorMessage) { message in
            guard let message, isFocused else { return }
            showSnapshotToast(message, ok: false)
            service.ptzErrorMessage = nil
        }
        // The parent always supplies an explicit width AND height (grid cells get
        // an aspect-shaped frame; focus gets the full geometry), so this view never
        // toggles an .aspectRatio modifier. That keeps its structural identity
        // stable across the grid↔focus transition — no subtree teardown (which
        // reparents the display layer → black flash) and no GeometryReader
        // ideal-size collapse (the "tiny box that zooms back" on exit). The video
        // layer's gravity handles fit/fill inside the fixed frame.
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: isFocused ? 0 : 4))
        .onAppear {
            if rtspClient.hasFrame {
                mode = .playing
            } else if rtspClient.error != nil {
                mode = .failed
            } else {
                startStream()
            }
            if isFocused {
                focusFillMode = AppSettings.shared.cameraFillMode(for: camera.id) ?? false
                installKeyMonitor(); startClockTimer()
                activateAudio()
                secondaryIsPrimary = false
            }
            // Self-gates on `wantsSecondaryStream`, so this also starts the grid
            // PiP stream for an unfocused tile when that setting is on.
            startSecondaryStream()
        }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
            downSwitchWork?.cancel()
            downSwitchWork = nil
            preservingFrame = false
            removeKeyMonitor()
            stopClockTimer()
            removeMouseMonitor()
            hudHideWorkItem?.cancel()
            deactivateAudio()
            stopSecondaryStreamUnlessKeptAlive()
        }
        .onChange(of: service.isPopoverOpen) { open in
            if open {
                startStream()
                startSecondaryStream()
            } else {
                streamTask?.cancel()
                streamTask = nil
                downSwitchWork?.cancel()
                downSwitchWork = nil
                preservingFrame = false
                mode = .connecting
                stopSecondaryStreamUnlessKeptAlive()
            }
        }
        .onChange(of: rtspClient.hasFrame) { ready in
            // Reveal the picture only once a real frame exists, fading the
            // connecting overlay out so video doesn't pop in over black.
            if ready {
                withAnimation(.easeOut(duration: 0.25)) { mode = .playing }
                // New feed is up — stop holding the previous frame.
                preservingFrame = false
            }
        }
        .onChange(of: rtspClient.error) { err in
            // Stop preserving so a genuine failure surfaces its overlay instead of
            // leaving a stale frame on screen.
            if err != nil { mode = .failed; preservingFrame = false }
        }
        .onChange(of: rtspClient.videoDimensions) { dims in
            if dims.width > 0 && dims.height > 0 {
                AppSettings.shared.cacheVideoDimensions(dims, for: camera.id)
            }
        }
        .onChange(of: focusedCameraId) { newId in
            if newId == camera.id {
                // Restore the saved fit/fill choice; new cameras default to fit.
                focusFillMode = AppSettings.shared.cameraFillMode(for: camera.id) ?? false
                installKeyMonitor()
                startClockTimer()
                activateAudio()
                // Always reopen with the main lens large (matches Protect).
                secondaryIsPrimary = false
                startSecondaryStream()
            } else {
                // Only the previously-focused cell holds a key monitor; make
                // sure no axis keeps moving after focus is gone (a held key's
                // key-up is never delivered once the monitor is removed).
                if keyMonitor != nil {
                    service.ptzStopAll(cameraId: camera.id)
                }
                removeKeyMonitor()
                stopClockTimer()
                removeMouseMonitor()
                hudHideWorkItem?.cancel()
                deactivateAudio()
                // Leaving focus ends the swappable focus PiP, but the grid PiP
                // (if enabled) keeps streaming — reconcile rather than hard-stop.
                secondaryIsPrimary = false
                reconcileSecondaryStream()
                isTrueFullscreen = false
                hudVisible = true
                zoomScale = 1.0
                panOffset = .zero
                lastPanOffset = .zero
                ptzActiveDirection = nil
                ptzActiveZoom = nil
                // Returning to the grid resizes this cell; the shared display
                // layer can fall out of the view tree and render black. Nudge a
                // re-attach after the transition settles (mirrors what the
                // toolbar Refresh did manually).
                scheduleReattach()
            }
            // Auto cameras stream low in the grid and high in focus; this swaps
            // the substream on either transition. No-op for explicit qualities.
            reconcilePrimaryQuality()
        }
        .onChange(of: focusFillMode) { newValue in
            // Persist the user's fit/fill choice per camera while focused.
            guard isFocused else { return }
            AppSettings.shared.setCameraFillMode(newValue, for: camera.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .enterTrueFullscreen)) { _ in
            guard isFocused else { return }
            // Crossfade the focus chrome → fullscreen HUD over the panel resize.
            withAnimation(.easeInOut(duration: 0.3)) { isTrueFullscreen = true }
            installMouseMonitor()
            bumpHud()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exitTrueFullscreen)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) { isTrueFullscreen = false }
            removeMouseMonitor()
            hudHideWorkItem?.cancel()
            hudVisible = true
        }
        .onTapGesture(count: 2) { openInProtect() }
        .onTapGesture(count: 1) {
            if isFocused {
                exitFocus()
            } else {
                withAnimation(Self.focusAnimation) {
                    focusedCameraId = camera.id
                }
                // Activate app so keyboard events reach our panel
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .contextMenu { sizeMenu }
    }

    // MARK: - Focus management

    func exitFocus() {
        withAnimation(Self.focusAnimation) {
            focusedCameraId = nil
        }
    }

    // MARK: - Audio

    /// Begin audio playback for the focused stream, honoring the global speaker
    /// preference. Negotiation already happened at connect, so this never reconnects.
    func activateAudio() {
        rtspClient.setMuted(!AppSettings.shared.speakerEnabled)
        rtspClient.setAudioActive(true)
        // Decode a still-capture copy of whichever lens is on screen (snapshot).
        rtspClient.setCaptureActive(true)
        secondaryClient.setCaptureActive(true)
    }

    func deactivateAudio() {
        rtspClient.setAudioActive(false)
        rtspClient.setCaptureActive(false)
        secondaryClient.setCaptureActive(false)
    }

    /// Flip the global speaker preference and apply it to the focused stream.
    func toggleMute() {
        guard rtspClient.hasAudio else { return }
        let enabled = !AppSettings.shared.speakerEnabled
        AppSettings.shared.speakerEnabled = enabled
        rtspClient.setMuted(!enabled)
    }

    /// Bumps `reattachNonce` a few times after the focus-exit transition so the
    /// stream view re-attaches its display layer once the cell has settled back
    /// into the grid. Without this the previously-focused tile can stay black.
    func scheduleReattach() {
        for delay in [0.35, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                reattachNonce &+= 1
            }
        }
    }
}
