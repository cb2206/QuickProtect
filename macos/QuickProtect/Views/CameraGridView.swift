import SwiftUI
import AVFoundation
import AppKit

extension Notification.Name {
    static let enterTrueFullscreen = Notification.Name("enterTrueFullscreen")
    static let exitTrueFullscreen  = Notification.Name("exitTrueFullscreen")
}

// MARK: - Grid

struct CameraGridView: View {
    @ObservedObject var service: ProtectService
    /// Owned by AppDelegate so stream teardown doesn't depend on this view's
    /// lifetime — see AppDelegate.closePanel().
    let clientManager: RTSPClientManager
    var searchQuery: String = ""
    var onOpenSettings: () -> Void = {}
    @State private var dragCameraId: String?
    @State private var focusedCameraId: String?
    @State private var lastRetryAt: Date?

    /// On appear, restore the last focused camera so reopening the panel
    /// picks up where the user left off.
    private func restoreFocus() {
        if let saved = service.lastFocusedCameraId,
           orderedCameras.contains(where: { $0.id == saved }) {
            focusedCameraId = saved
        }
    }

    /// 4 logical columns; cameras span 1, 2, or 4 based on their size setting.
    private let columnCount = 4
    private let spacing: CGFloat = 2
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        ZStack {
            palette.gridBg.ignoresSafeArea()
            if service.isLoading {
                loadingView
            } else if let error = service.errorMessage {
                errorView(error)
            } else if service.cameras.isEmpty {
                emptyView
            } else {
                cameraGrid
            }
        }
        .preferredColorScheme(.dark)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2).tint(palette.text)
            Text("Connecting…").foregroundColor(palette.subtext)
        }
    }

    private func errorView(_ message: String) -> some View {
        AuroraStateCard(
            tone: .warning,
            systemImage: "exclamationmark.circle",
            title: String(localized: "Can't reach controller"),
            message: message,
            primary: (String(localized: "Retry"), { lastRetryAt = Date(); Task { await service.fetchCameras(forced: true) } }),
            secondary: (String(localized: "Open Settings"), onOpenSettings),
            footer: lastRetryAt.map { String(localized: "Last try: \(Self.relativeAgo(from: $0))") }
        )
        .padding(24)
    }

    private var emptyView: some View {
        AuroraStateCard(
            tone: .neutral,
            systemImage: "video.slash",
            title: String(localized: "No cameras yet"),
            message: String(localized: "Connected, but no cameras came back. Adopt one in the Protect app, then refresh."),
            primary: (String(localized: "Refresh"), { Task { await service.fetchCameras(forced: true) } }),
            secondary: (String(localized: "Open in Protect"), openProtectDashboard),
            footer: nil
        )
        .padding(24)
    }

    private func openProtectDashboard() {
        let ip = AppSettings.shared.ipAddress
        guard !ip.isEmpty, let url = URL(string: "https://\(ip)/protect") else { return }
        NotificationCenter.default.post(name: .closeCameraPanel, object: nil)
        NSWorkspace.shared.open(url)
    }

    private static func relativeAgo(from date: Date) -> String {
        let secs = Int(max(0, Date().timeIntervalSince(date)))
        if secs < 2 { return String(localized: "just now") }
        if secs < 60 { return String(localized: "\(secs) seconds ago") }
        let mins = secs / 60
        if mins < 60 { return String(localized: "\(mins) minutes ago") }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    // MARK: - Row-packed grid layout

    private var orderedCameras: [Camera] {
        let visible = AppSettings.shared.visibleCameras(service.cameras)
        let ordered = AppSettings.shared.orderedCameras(visible)
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ordered }
        return ordered.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var cameraGrid: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - spacing * 2
            let colWidth = (totalWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let hasFocus = focusedCameraId != nil

            // Single ScrollView — cells are resized in place rather than destroyed/
            // recreated, so the AVSampleBufferDisplayLayer never needs reparenting.
            ScrollView {
                VStack(spacing: hasFocus ? 0 : spacing) {
                    let rows = packRows(cameras: orderedCameras, colWidth: colWidth)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        let rowHasFocused = row.contains { focusedCameraId == $0.camera.id }
                        HStack(spacing: hasFocus ? 0 : spacing) {
                            ForEach(row, id: \.camera.id) { item in
                                let isFocused = focusedCameraId == item.camera.id
                                let isHidden = hasFocus && !isFocused
                                let loadOrder = orderedCameras.firstIndex { $0.id == item.camera.id } ?? 0
                                CameraCell(camera: item.camera, service: service, span: item.span,
                                           focusedCameraId: $focusedCameraId,
                                           clientManager: clientManager, loadOrder: loadOrder)
                                    // Fade non-focused cells out faster than the frame
                                    // collapse so the eye locks onto the growing tile
                                    // instead of watching the whole grid implode. The
                                    // frame (below) stays on the ambient focus spring.
                                    .opacity(isHidden ? 0 : 1)
                                    .animation(.easeOut(duration: 0.18), value: isHidden)
                                    .frame(
                                        width:  isFocused ? geo.size.width  : (isHidden ? 0 : cellWidth(span: item.span, colWidth: colWidth)),
                                        height: isFocused ? geo.size.height : (isHidden ? 0 : cellWidth(span: item.span, colWidth: colWidth) / gridAspect(for: item.camera))
                                    )
                                    .allowsHitTesting(!isHidden)
                                    .onDrag {
                                        dragCameraId = item.camera.id
                                        return NSItemProvider(object: item.camera.id as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: CameraDropDelegate(
                                        targetId: item.camera.id,
                                        cameras: orderedCameras,
                                        dragCameraId: $dragCameraId,
                                        service: service
                                    ))
                            }
                        }
                        .frame(height: hasFocus && !rowHasFocused ? 0 : nil)
                        .clipped()
                    }
                }
                .padding(hasFocus ? 0 : spacing)
            }
            .scrollDisabled(hasFocus)
        }
        .onAppear { restoreFocus(); service.isFocusMode = focusedCameraId != nil }
        .onChange(of: focusedCameraId) { newId in
            service.lastFocusedCameraId = newId
            service.isFocusMode = newId != nil
        }
    }

    private func cellWidth(span: Int, colWidth: CGFloat) -> CGFloat {
        CGFloat(span) * colWidth + CGFloat(span - 1) * spacing
    }

    /// Aspect ratio used to size a grid cell's height. Uses the per-camera cached
    /// stream dimensions (populated on first connect, persisted across launches),
    /// falling back to 16:9. Kept here — rather than relying on the cell's own
    /// `.aspectRatio` — so the cell can keep a stable explicit frame.
    private func gridAspect(for camera: Camera) -> CGFloat {
        AppSettings.shared.cachedAspectRatio(for: camera.id) ?? (16.0 / 9.0)
    }

    private struct RowItem {
        let camera: Camera
        let span: Int
    }

    /// Pack cameras into rows, filling each row left-to-right.
    private func packRows(cameras: [Camera], colWidth: CGFloat) -> [[RowItem]] {
        var rows: [[RowItem]] = []
        var currentRow: [RowItem] = []
        var usedCols = 0

        for camera in cameras {
            let span = effectiveSpan(for: camera)
            if usedCols + span > columnCount {
                // Current row is full — start a new one
                if !currentRow.isEmpty { rows.append(currentRow) }
                currentRow = []
                usedCols = 0
            }
            currentRow.append(RowItem(camera: camera, span: span))
            usedCols += span
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }

    /// Determine the column span for a camera: user override > auto-detection.
    private func effectiveSpan(for camera: Camera) -> Int {
        if let userSize = AppSettings.shared.cameraSize(for: camera.id) {
            return userSize.rawValue
        }
        // No user override — auto-detect from stream dimensions
        // (This only works after the stream has connected once; defaults to medium)
        return 2   // default: medium (2 columns)
    }
}

// MARK: - Camera cell

struct CameraCell: View {
    let camera: Camera
    let service: ProtectService
    let span: Int
    let loadOrder: Int
    @Binding var focusedCameraId: String?

    @ObservedObject private var rtspClient: RTSPClient
    /// Second lens stream (e.g. doorbell package camera). For single-lens
    /// cameras this is an unused throwaway client that never connects.
    @ObservedObject private var secondaryClient: RTSPClient
    @State private var mode: Mode = .connecting
    @State private var streamTask: Task<Void, Never>?
    @State private var secondaryStreamTask: Task<Void, Never>?
    /// Concrete quality the primary client is currently connected (or connecting)
    /// at. Tracks the resolved substream so a quality change can release the old
    /// server allocation instead of leaking it until cleanup.
    @State private var primaryQuality: StreamQuality?
    /// True while a quality switch reconnects with the previous frame left on the
    /// display layer (see `RTSPClient.connect(keepLastFrame:)`). Suppresses the
    /// connecting overlay so the held frame shows through until the new feed
    /// arrives, instead of a grey spinner.
    @State private var preservingFrame = false
    /// Pending auto down-switch (high → low on leaving focus), delayed so a quick
    /// focus → unfocus → focus doesn't churn the grid stream. Cancelled if focus
    /// returns first.
    @State private var downSwitchWork: DispatchWorkItem?
    /// When true, the secondary lens fills the frame and the main lens moves
    /// into the PiP. Reset to false every time the camera (re)enters focus.
    @State private var secondaryIsPrimary = false

    // Zoom & pan (only active when focused)
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @State private var cellSize: CGSize = .zero       // for pan clamping
    @State private var focusFillMode: Bool = false    // fit/fill toggle; loaded per-camera on focus (default: fit)
    @State private var ptzActiveDirection: AuroraPtzDpad.Direction?  // lit arrow on the d-pad
    @State private var ptzActiveZoom: AuroraPtzZoomControl.Direction?  // lit +/− on the zoom pill
    @State private var reattachNonce = 0               // bump to re-attach the display layer
    @State private var clockTick: Date = Date()
    @State private var clockTimer: Timer?
    @State private var isTrueFullscreen = false
    @State private var hudVisible = true
    @State private var hudHideWorkItem: DispatchWorkItem?
    @State private var mouseMonitor: Any?
    @State private var snapshotToast: SnapshotToast?
    @State private var snapshotToastGen = 0
    @State private var snapshotInFlight = false        // armed, waiting for a frame

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
    private static let idleSecondaryClient = RTSPClient()

    /// The client whose frame fills the main viewport (swaps with the PiP).
    private var primaryClient: RTSPClient { secondaryIsPrimary ? secondaryClient : rtspClient }
    /// The client shown in the small picture-in-picture window.
    private var pipClient: RTSPClient { secondaryIsPrimary ? rtspClient : secondaryClient }

    /// Swappable PiP over the focused / fullscreen view.
    private var showsFocusPip: Bool {
        isFocused && camera.secondaryLens != nil
            && AppSettings.shared.showsSecondaryLensPip(for: camera.id)
    }

    /// Display-only PiP on the grid tile, shown once the tile is live.
    private var showsGridPip: Bool {
        !isFocused && appearsLive && camera.secondaryLens != nil
            && AppSettings.shared.showsSecondaryLensPipInGrid(for: camera.id)
    }

    private var showsPip: Bool { showsFocusPip || showsGridPip }

    /// Whether the secondary stream should currently be connected — either the
    /// grid PiP is on (runs whenever the tile is visible) or the camera is
    /// focused with the focus PiP on.
    private var wantsSecondaryStream: Bool {
        guard camera.secondaryLens != nil else { return false }
        if AppSettings.shared.showsSecondaryLensPipInGrid(for: camera.id) { return true }
        return isFocused && AppSettings.shared.showsSecondaryLensPip(for: camera.id)
    }

    private var isFocused: Bool { focusedCameraId == camera.id }

    /// The concrete substream this tile should be playing right now: the camera's
    /// effective quality (override or global default) resolved for the current
    /// focus state — so `.auto` is low in the grid and high when enlarged.
    private var desiredPrimaryQuality: StreamQuality {
        AppSettings.shared.effectiveStreamQuality(for: camera.id)
            .resolve(focused: isFocused,
                     gridIsLarge: AppSettings.shared.cameraSize(for: camera.id) == .large)
    }

    /// The tile reads as live whenever it's playing or holding the previous frame
    /// through a quality switch — used to keep the rec dot and grid PiP from
    /// blinking during an auto down-switch reconnect (which dips `mode`).
    private var appearsLive: Bool { mode == .playing || preservingFrame }

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

    private func exitFocus() {
        withAnimation(Self.focusAnimation) {
            focusedCameraId = nil
        }
    }

    // MARK: - Audio

    /// Begin audio playback for the focused stream, honoring the global speaker
    /// preference. Negotiation already happened at connect, so this never reconnects.
    private func activateAudio() {
        rtspClient.setMuted(!AppSettings.shared.speakerEnabled)
        rtspClient.setAudioActive(true)
        // Decode a still-capture copy of whichever lens is on screen (snapshot).
        rtspClient.setCaptureActive(true)
        secondaryClient.setCaptureActive(true)
    }

    private func deactivateAudio() {
        rtspClient.setAudioActive(false)
        rtspClient.setCaptureActive(false)
        secondaryClient.setCaptureActive(false)
    }

    /// Flip the global speaker preference and apply it to the focused stream.
    private func toggleMute() {
        guard rtspClient.hasAudio else { return }
        let enabled = !AppSettings.shared.speakerEnabled
        AppSettings.shared.speakerEnabled = enabled
        rtspClient.setMuted(!enabled)
    }

    /// Bumps `reattachNonce` a few times after the focus-exit transition so the
    /// stream view re-attaches its display layer once the cell has settled back
    /// into the grid. Without this the previously-focused tile can stay black.
    private func scheduleReattach() {
        for delay in [0.35, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                reattachNonce &+= 1
            }
        }
    }

    // MARK: - F key → true fullscreen

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        // Local monitor — fallback for when DisplayLayerHostView doesn't have focus
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [self] event in
            guard focusedCameraId == camera.id else { return event }
            if event.type == .keyUp {
                return handlePtzKeyUp(event.keyCode) ? nil : event
            }
            // keyDown
            if event.keyCode == 3 { toggleTrueFullscreen(); return nil }    // F
            if event.keyCode == 53 { handleEscape(); return nil }
            if event.keyCode == 46 { toggleMute(); return nil }             // M
            if event.keyCode == 8, showsPip { swapLenses(); return nil }    // C
            if event.keyCode == 1 { captureSnapshot(); return nil }         // S
            if event.isARepeat, isPtzKey(event.keyCode) { return nil } // consume repeats
            if handlePtzKeyDown(event.keyCode) { return nil }
            return event
        }

        // Global monitor — captures events when app isn't active
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [self] event in
            guard focusedCameraId == camera.id else { return }
            if event.type == .keyUp {
                _ = handlePtzKeyUp(event.keyCode)
                return
            }
            // keyDown
            if event.keyCode == 3 { DispatchQueue.main.async { toggleTrueFullscreen() } }    // F
            if event.keyCode == 53 { DispatchQueue.main.async { handleEscape() } }
            if event.keyCode == 46 { DispatchQueue.main.async { toggleMute() } }             // M
            if event.keyCode == 8 { DispatchQueue.main.async { if showsPip { swapLenses() } } } // C
            if event.keyCode == 1 { DispatchQueue.main.async { captureSnapshot() } }            // S
            if !event.isARepeat { _ = handlePtzKeyDown(event.keyCode) }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let m = globalKeyMonitor {
            NSEvent.removeMonitor(m)
            globalKeyMonitor = nil
        }
    }

    private func toggleTrueFullscreen() {
        // Access AppDelegate to check current state
        let appDelegate = NSApp.delegate as? AppDelegate
        if appDelegate?.isInTrueFullscreen == true {
            NotificationCenter.default.post(name: .exitTrueFullscreen, object: nil)
        } else {
            NotificationCenter.default.post(name: .enterTrueFullscreen, object: nil)
        }
    }

    private func handleEscape() {
        let appDelegate = NSApp.delegate as? AppDelegate
        if appDelegate?.isInTrueFullscreen == true {
            // Exit true fullscreen first, stay in popover focus
            NotificationCenter.default.post(name: .exitTrueFullscreen, object: nil)
        } else {
            // Exit popover focus
            exitFocus()
        }
    }

    // MARK: - PTZ key handling

    /// The camera's current capability flags from the service. The NSEvent
    /// monitor closures capture this view struct by value, so `camera` itself
    /// can be a stale pre-enrichment copy (canZoom=false) after the panel is
    /// reopened — always consult the live list for gating.
    private var currentCanZoom: Bool {
        service.cameras.first(where: { $0.id == camera.id })?.canZoom ?? camera.canZoom
    }

    private func isPtzKey(_ keyCode: UInt16) -> Bool {
        [123, 124, 125, 126].contains(keyCode) || (currentCanZoom && isZoomKey(keyCode))
    }

    private func isZoomKey(_ keyCode: UInt16) -> Bool {
        keyCode == 34 || keyCode == 31  // I, O
    }

    /// Key-down: start PTZ movement on the pressed axis (other axes keep
    /// running, so arrows and I/O combine). Also lights up the matching
    /// arrow on the on-screen d-pad / zoom pill.
    private func handlePtzKeyDown(_ keyCode: UInt16) -> Bool {
        guard !AppSettings.shared.username.isEmpty else { return false }
        switch keyCode {
        case 123: service.ptzSetAxes(cameraId: camera.id, pan: -1); ptzActiveDirection = .left    // Left
        case 124: service.ptzSetAxes(cameraId: camera.id, pan:  1); ptzActiveDirection = .right   // Right
        case 126: service.ptzSetAxes(cameraId: camera.id, tilt:  1); ptzActiveDirection = .up     // Up
        case 125: service.ptzSetAxes(cameraId: camera.id, tilt: -1); ptzActiveDirection = .down   // Down
        case 34 where currentCanZoom:
            service.ptzSetAxes(cameraId: camera.id, zoom:  1); ptzActiveZoom = .zoomIn            // I
        case 31 where currentCanZoom:
            service.ptzSetAxes(cameraId: camera.id, zoom: -1); ptzActiveZoom = .zoomOut           // O
        default:  return false
        }
        return true
    }

    /// Key-up: stop the released key's axis and clear its lit control;
    /// other axes keep moving.
    private func handlePtzKeyUp(_ keyCode: UInt16) -> Bool {
        guard !AppSettings.shared.username.isEmpty, isPtzKey(keyCode) else { return false }
        switch keyCode {
        case 123, 124: service.ptzSetAxes(cameraId: camera.id, pan: 0); ptzActiveDirection = nil
        case 125, 126: service.ptzSetAxes(cameraId: camera.id, tilt: 0); ptzActiveDirection = nil
        case 34, 31:   service.ptzSetAxes(cameraId: camera.id, zoom: 0); ptzActiveZoom = nil
        default: return false
        }
        return true
    }

    // MARK: - Size context menu

    @ViewBuilder
    private var sizeMenu: some View {
        Button {
            if focusedCameraId != camera.id {
                withAnimation(.easeInOut(duration: 0.3)) { focusedCameraId = camera.id }
                NSApp.activate(ignoringOtherApps: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .enterTrueFullscreen, object: nil)
            }
        } label: {
            Label("View fullscreen", systemImage: "play.fill")
        }
        Button { openInProtect() } label: {
            Label("Open in Protect", systemImage: "arrow.up.forward.square")
        }
        .keyboardShortcut(.return, modifiers: .command)

        if let pinned = (NSApp.delegate as? AppDelegate)?.pinnedWindows {
            let isPinned = pinned.isPinned(camera.id)
            Button {
                // Use the live (enriched) camera so the pinned window picks up
                // the latest name/state, not this cell's possibly-stale copy.
                pinned.togglePin(service.cameras.first { $0.id == camera.id } ?? camera)
            } label: {
                Label(isPinned ? String(localized: "Unpin Floating Window")
                               : String(localized: "Pin as Floating Window"),
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
        }

        Divider()

        let current = AppSettings.shared.cameraSize(for: camera.id)
        Section("Size") {
            Button { setSize(.small) } label: {
                Label("Small",  systemImage: current == .small  ? "checkmark" : "")
            }
            Button { setSize(.medium) } label: {
                Label("Medium", systemImage: (current == .medium || current == nil) ? "checkmark" : "")
            }
            Button { setSize(.large) } label: {
                Label("Large",  systemImage: current == .large  ? "checkmark" : "")
            }
        }

        let quality = AppSettings.shared.streamQuality(for: camera.id)
        Section("Stream quality") {
            // Follow the global default; the label spells out what that is.
            Button { setStreamQuality(nil) } label: {
                Label("\(String(localized: "Use default")) (\(AppSettings.shared.defaultStreamQuality.displayName))",
                      systemImage: quality == nil ? "checkmark" : "")
            }
            ForEach(StreamQuality.allCases, id: \.self) { q in
                Button { setStreamQuality(q) } label: {
                    Label(q.displayName, systemImage: quality == q ? "checkmark" : "")
                }
            }
        }

        Divider()

        let hiddenCameras = service.cameras
            .filter { AppSettings.shared.isHidden($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !hiddenCameras.isEmpty {
            Menu {
                ForEach(hiddenCameras) { cam in
                    Button { addCamera(cam.id) } label: { Text(cam.name) }
                }
            } label: {
                Label("Add Camera", systemImage: "plus")
            }
        }

        Button {
            AppSettings.shared.setHidden(true, for: camera.id)
            service.objectWillChange.send()
        } label: {
            Label("Hide this camera", systemImage: "eye.slash")
        }
        Button { setSize(nil) } label: {
            Label("Reset size to Auto", systemImage: "arrow.counterclockwise")
        }
    }

    /// Unhide a camera and append it to the end of the current profile's grid.
    private func addCamera(_ id: String) {
        let visibleOrder = AppSettings.shared
            .orderedCameras(AppSettings.shared.visibleCameras(service.cameras))
            .map(\.id)
        AppSettings.shared.addHiddenCamera(id, visibleOrder: visibleOrder)
        service.objectWillChange.send()
    }

    private func openInProtect() {
        let ip = AppSettings.shared.ipAddress
        guard !ip.isEmpty,
              let url = URL(string: "https://\(ip)/protect/dashboard/all/sidepanel/device/\(camera.id)") else { return }
        NotificationCenter.default.post(name: .closeCameraPanel, object: nil)
        NSWorkspace.shared.open(url)
    }

    private func setSize(_ size: AppSettings.CameraSize?) {
        AppSettings.shared.setCameraSize(size, for: camera.id)
        service.objectWillChange.send()   // trigger grid re-layout
        // An auto camera's grid quality scales with tile size (Large → medium),
        // so a resize may warrant a stream switch.
        reconcilePrimaryQuality()
    }

    /// Apply a per-camera quality override (or `nil` to follow the global
    /// default) and switch the live stream to match.
    private func setStreamQuality(_ quality: StreamQuality?) {
        AppSettings.shared.setStreamQuality(quality, for: camera.id)
        reconcilePrimaryQuality()
    }

    // MARK: - State overlay

    @ViewBuilder
    private var stateOverlay: some View {
        ZStack {
            Color(white: 0.12)
            switch mode {
            case .connecting:
                if !camera.isOnline {
                    offlinePlaceholder
                } else {
                    ProgressView().tint(.white)
                }
            case .failed:
                failedPlaceholder
            case .playing:
                EmptyView()
            }
        }
    }

    private var offlinePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18))
                .foregroundColor(AuroraTokens.statusOrange)
            Text("Offline")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }

    private var failedPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 18))
                .foregroundColor(AuroraTokens.statusRed)
            Text("Stream unavailable")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            Button("Reconnect") { startStream() }
                .buttonStyle(AuroraStatePillButtonStyle(primary: true))
            Text("RTSP · no media")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }

    // MARK: - Stream lifecycle

    /// `force` skips the "already playing" shortcut — required right after a
    /// `disconnect()`, whose `hasFrame = false` lands asynchronously on the RTSP
    /// queue, so a synchronous reconnect would otherwise see a stale `true` and
    /// bail without connecting (e.g. an auto camera staying low on focus).
    /// `keepLastFrame` holds the current frame on the display layer through the
    /// reconnect (a quality switch) instead of flashing grey.
    private func startStream(force: Bool = false, keepLastFrame: Bool = false) {
        if !force, rtspClient.hasFrame { mode = .playing; return }
        guard streamTask == nil else { preservingFrame = false; return }
        guard service.isPopoverOpen, camera.isOnline else {
            mode = camera.isOnline ? .connecting : .failed
            return
        }
        mode = .connecting

        let quality = desiredPrimaryQuality
        primaryQuality = quality

        // Stagger connects by grid position so tiles light up as a calm
        // top-left → bottom-right cascade rather than a random scatter. Cap the
        // delay so large grids don't leave the last tiles waiting too long.
        let stagger = UInt64(min(loadOrder, 12)) * 90_000_000

        streamTask = Task {
            try? await Task.sleep(nanoseconds: stagger)
            guard !Task.isCancelled else { return }

            guard let stream = await service.createRtspStreamURL(for: camera, quality: quality.apiValue) else {
                mode = .failed
                preservingFrame = false
                streamTask = nil
                return
            }
            guard !Task.isCancelled else { streamTask = nil; return }

            // Track the quality the server actually served (a fallback may differ
            // from what we asked for) so the next switch releases the right key.
            primaryQuality = StreamQuality(rawValue: stream.quality) ?? quality
            streamTask = nil
            rtspClient.connect(to: stream.url, keepLastFrame: keepLastFrame)
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        downSwitchWork?.cancel()
        downSwitchWork = nil
        preservingFrame = false
        rtspClient.disconnect()
        mode = .connecting
    }

    /// Reconnect the primary stream when its effective quality no longer matches
    /// what's playing — an `.auto` camera entering/leaving focus, or the user
    /// changing the per-camera quality. No-op when the resolved quality is
    /// unchanged, so explicit-quality tiles don't churn on focus.
    ///
    /// Upgrades (entering focus) apply immediately so high-res arrives ASAP;
    /// downgrades (leaving focus) are delayed so a quick focus → unfocus → focus
    /// keeps the high stream rather than reconnecting twice. A frozen frame masks
    /// the reconnect either way (see `applyQualitySwitch`).
    private func reconcilePrimaryQuality() {
        downSwitchWork?.cancel()
        downSwitchWork = nil
        let desired = desiredPrimaryQuality
        guard desired != primaryQuality else { return }

        let isDowngrade = primaryQuality.map { desired.rank < $0.rank } ?? false
        if isDowngrade {
            let work = DispatchWorkItem { applyQualitySwitch() }
            downSwitchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else {
            applyQualitySwitch()
        }
    }

    /// Reconnect the primary stream at the now-desired quality, holding the
    /// current frame on the display layer through the switch so it dissolves into
    /// the new feed rather than flashing grey. Releases the previous server-side
    /// allocation; `connect(keepLastFrame:)` sends the RTSP TEARDOWN for the old
    /// session without flushing the layer.
    private func applyQualitySwitch() {
        downSwitchWork = nil
        let previous = primaryQuality
        preservingFrame = true
        streamTask?.cancel()
        streamTask = nil
        if let previous {
            service.releaseStream(for: camera.id, quality: previous.apiValue)
        }
        // Force past the hasFrame shortcut: hasFrame is still true from the feed
        // we're replacing, so a plain startStream() would assume it's playing and
        // skip the reconnect.
        startStream(force: true, keepLastFrame: true)
    }

    // MARK: - Secondary lens (package camera) lifecycle

    /// Start or stop the secondary stream to match `wantsSecondaryStream`.
    /// Called whenever focus changes so the grid PiP keeps streaming after the
    /// camera leaves focus (and the focus-only PiP stops).
    private func reconcileSecondaryStream() {
        if wantsSecondaryStream { startSecondaryStream() } else { stopSecondaryStream() }
    }

    /// Lazily connect the secondary lens stream when a PiP that needs it is (or
    /// is about to be) visible. No-op for single-lens cameras.
    private func startSecondaryStream() {
        guard let lens = camera.secondaryLens, wantsSecondaryStream else { return }
        if secondaryClient.hasFrame { return }
        guard secondaryStreamTask == nil else { return }
        guard service.isPopoverOpen, camera.isOnline else { return }

        secondaryStreamTask = Task {
            // The package lens is its own quality with no fallback, so the served
            // quality always matches lens.quality — only the URL is needed here.
            guard let stream = await service.createRtspStreamURL(for: camera, quality: lens.quality) else {
                secondaryStreamTask = nil
                return
            }
            guard !Task.isCancelled else { secondaryStreamTask = nil; return }
            secondaryStreamTask = nil
            secondaryClient.connect(to: stream.url)
        }
    }

    /// Panel-close variant of `stopSecondaryStream`: with a keep-alive grace
    /// configured, leave the live stream to the deferred teardown — the client
    /// is owned by RTSPClientManager (disconnectAll) and its allocation stays
    /// in the tracking set (cleanupStreams) — so a quick reopen resumes the
    /// PiP instantly, mirroring the primary stream. Only the in-flight
    /// creation task is cancelled. Tile teardown while the panel stays open
    /// (unfocus, PiP toggled off) stops the stream as before.
    private func stopSecondaryStreamUnlessKeptAlive() {
        guard !service.isPopoverOpen, AppSettings.shared.streamKeepAliveSeconds > 0 else {
            stopSecondaryStream()
            return
        }
        secondaryStreamTask?.cancel()
        secondaryStreamTask = nil
    }

    /// Disconnect the secondary lens and release its server-side allocation.
    /// Safe to call for single-lens cameras (throwaway client, no allocation).
    private func stopSecondaryStream() {
        secondaryStreamTask?.cancel()
        secondaryStreamTask = nil
        secondaryClient.disconnect()
        if let lens = camera.secondaryLens {
            service.releaseStream(for: camera.id, quality: lens.quality)
        }
        secondaryIsPrimary = false
    }

    /// Swap which lens fills the frame. Both streams stay live, so this is an
    /// instant view reassignment — no reconnect. Resets zoom/pan to the new
    /// primary's natural frame.
    private func swapLenses() {
        withAnimation(.easeInOut(duration: 0.2)) { secondaryIsPrimary.toggle() }
        zoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
        reattachNonce &+= 1   // force both stream views to re-attach swapped layers
    }

    /// Label for whichever lens currently sits in the PiP.
    private var pipLabel: String {
        secondaryIsPrimary ? camera.name : (camera.secondaryLens?.label ?? "")
    }

    // MARK: - Snapshot capture (S)

    /// Filename timestamp: QuickProtect-YYYY-MM-DD-HH-mm-ss.png (24-hour clock).
    /// All-dashes: a colon is the legacy macOS path separator (Finder shows it
    /// as a slash), so the time uses dashes too.
    /// POSIX locale keeps the format stable regardless of the user's region.
    private static let snapshotTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Capture the frame currently on screen at the streamed resolution and send
    /// it to the configured destination — the clipboard or the selected folder.
    private func captureSnapshot() {
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
    private func awaitFrame(from source: RTSPClient,
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

    private func finishSnapshot(from source: RTSPClient,
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
    private func saveSnapshotToFolder(_ image: CGImage) -> Bool {
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

    private func showSnapshotToast(_ text: String, ok: Bool) {
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

    private var snapshotToastView: some View {
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

    // MARK: - Secondary lens picture-in-picture

    private var secondaryLensPiP: some View {
        // Grid tiles are small and the PiP there is a non-interactive thumbnail;
        // the focused/fullscreen PiP is larger, labelled, and tap-to-swap.
        let compact = !isFocused
        let width = compact ? max(56, cellSize.width * 0.30)
                            : max(120, cellSize.width * 0.26)
        let height = width * 3 / 4   // package lens is 1600×1200 (4:3)
        let radius: CGFloat = compact ? 5 : 7
        let outerPad: CGFloat = compact ? 6 : 16

        return ZStack(alignment: .bottomLeading) {
            ProtectStreamView(
                displayLayer: pipClient.displayLayer,
                videoGravity: .resizeAspectFill,
                reattachNonce: reattachNonce
            )
            .background(Color(white: 0.05))

            if !pipClient.hasFrame {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !compact {
                HStack(spacing: 5) {
                    Text(pipLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    Text("C")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(Color.white.opacity(compact ? 0.25 : 0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: compact ? 4 : 8, y: compact ? 1 : 3)
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .onTapGesture { swapLenses() }
        .help(String(localized: "Swap with main view (C)"))
        // In the grid the PiP must not swallow the tile's tap (which focuses the
        // camera) — let taps fall through. In focus it's tappable to swap.
        .allowsHitTesting(!compact)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(outerPad)
    }

    // MARK: - Focus overlay (Aurora top bar + PTZ d-pad + kbd hints)

    @ViewBuilder
    private var focusOverlay: some View {
        VStack(spacing: 0) {
            AuroraFocusTopBar(
                cameraName: camera.name,
                isPtz: camera.isPtz,
                fillMode: $focusFillMode,
                now: clockTick,
                hasAudio: rtspClient.hasAudio,
                isMuted: rtspClient.isMuted,
                onBack: { exitFocus() },
                onToggleFullscreen: { toggleTrueFullscreen() },
                onToggleMute: { toggleMute() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                if showOverlayControls {
                    AuroraFocusHints(showPtzHint: camera.isPtz,
                                     showZoomHint: camera.canZoom,
                                     showAudioHint: rtspClient.hasAudio)
                        .padding(.leading, 12).padding(.bottom, 12)
                }
                Spacer()
                if showOverlayControls && (camera.isPtz || camera.canZoom)
                    && !AppSettings.shared.username.isEmpty {
                    HStack(alignment: .bottom, spacing: 6) {
                        if camera.isPtz {
                            AuroraPtzDpad(
                                onPress: { dir in dpadPress(dir) },
                                onRelease: { dpadRelease() },
                                activeDirection: ptzActiveDirection
                            )
                        }
                        if camera.canZoom {
                            AuroraPtzZoomControl(
                                onPress: { dir in zoomPress(dir) },
                                onRelease: { zoomRelease() },
                                activeDirection: ptzActiveZoom
                            )
                        }
                    }
                    .padding(.trailing, 16).padding(.bottom, 16)
                }
            }
        }
    }

    /// User toggle: show the keyboard-shortcut hints and on-screen PTZ d-pad.
    private var showOverlayControls: Bool {
        AppSettings.shared.showFocusOverlayControls
    }

    private func dpadPress(_ dir: AuroraPtzDpad.Direction) {
        ptzActiveDirection = dir
        switch dir {
        case .up:    service.ptzSetAxes(cameraId: camera.id, tilt:  1)
        case .down:  service.ptzSetAxes(cameraId: camera.id, tilt: -1)
        case .left:  service.ptzSetAxes(cameraId: camera.id, pan:  -1)
        case .right: service.ptzSetAxes(cameraId: camera.id, pan:   1)
        }
    }

    private func dpadRelease() {
        service.ptzSetAxes(cameraId: camera.id, pan: 0, tilt: 0)
        ptzActiveDirection = nil
    }

    private func zoomPress(_ dir: AuroraPtzZoomControl.Direction) {
        ptzActiveZoom = dir
        switch dir {
        case .zoomIn:  service.ptzSetAxes(cameraId: camera.id, zoom:  1)
        case .zoomOut: service.ptzSetAxes(cameraId: camera.id, zoom: -1)
        }
    }

    private func zoomRelease() {
        service.ptzSetAxes(cameraId: camera.id, zoom: 0)
        ptzActiveZoom = nil
    }

    private func startClockTimer() {
        stopClockTimer()
        clockTick = Date()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            clockTick = Date()
        }
    }

    private func stopClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    // MARK: - HUD auto-hide on cursor idle

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { event in
            bumpHud()
            return event
        }
    }

    private func removeMouseMonitor() {
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    private func bumpHud() {
        hudVisible = true
        hudHideWorkItem?.cancel()
        let item = DispatchWorkItem { hudVisible = false }
        hudHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Name badge (Aurora hairline pill)

    private var nameBadge: some View {
        HStack(spacing: 6) {
            if camera.isOnline && appearsLive {
                AuroraRecDot(size: 5)
            } else if !camera.isOnline {
                Circle().fill(AuroraTokens.statusOrange).frame(width: 5, height: 5)
            }
            Text(camera.name)
                .font(.system(size: span >= 4 ? 12 : 11, weight: .medium))
                .foregroundColor(.white)
                .tracking(-0.1)
                .lineLimit(1)
            if camera.isPtz {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 9, weight: .medium))
                    Text("PTZ").font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.75))
                .padding(.leading, 4)
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 0.5)
                        .padding(.vertical, 2),
                    alignment: .leading
                )
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        // Plain fill, deliberately not a blur: a withinWindow blur whose
        // backdrop is live video forces a re-blur on every frame, per tile.
        .background(Color.black.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(8)
    }
}

// MARK: - Drag & drop reordering

struct CameraDropDelegate: DropDelegate {
    let targetId: String
    let cameras: [Camera]
    @Binding var dragCameraId: String?
    let service: ProtectService

    func performDrop(info: DropInfo) -> Bool {
        dragCameraId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragId = dragCameraId, dragId != targetId else { return }
        var ids = cameras.map(\.id)
        guard let fromIndex = ids.firstIndex(of: dragId),
              let toIndex = ids.firstIndex(of: targetId) else { return }
        ids.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        AppSettings.shared.setCameraOrder(ids)
        service.objectWillChange.send()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}
}
