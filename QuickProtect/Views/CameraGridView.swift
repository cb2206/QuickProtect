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
    var searchQuery: String = ""
    var onOpenSettings: () -> Void = {}
    @StateObject private var clientManager = RTSPClientManager()
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
            primary: (String(localized: "Retry"), { lastRetryAt = Date(); Task { await service.fetchCameras() } }),
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
            primary: (String(localized: "Refresh"), { Task { await service.fetchCameras() } }),
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
        .onChange(of: service.isPopoverOpen) { open in
            if !open {
                clientManager.disconnectAll()
                service.cleanupStreams()
            }
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
    @State private var mode: Mode = .connecting
    @State private var streamTask: Task<Void, Never>?

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

    enum Mode { case connecting, playing, failed }

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
    }

    private var isFocused: Bool { focusedCameraId == camera.id }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Stream view: use .resizeAspect when focused to preserve full frame
            GeometryReader { geo in
                ProtectStreamView(
                    displayLayer: rtspClient.displayLayer,
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
                        let newX = lastPanOffset.width - dx
                        let newY = lastPanOffset.height - dy
                        panOffset = CGSize(
                            width: max(-maxPanX, min(maxPanX, newX)),
                            height: max(-maxPanY, min(maxPanY, newY))
                        )
                        lastPanOffset = panOffset
                    } : nil,
                    onKeyPress: isFocused ? { keyCode in
                        if keyCode == 3 { toggleTrueFullscreen() }     // F
                        else if keyCode == 53 { handleEscape() }       // Escape
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

            if mode != .playing {
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
                        visible: hudVisible
                    )
                    .transition(.opacity)
                } else {
                    focusOverlay
                        .transition(.opacity)
                }
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
            }
        }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
            removeKeyMonitor()
            stopClockTimer()
            removeMouseMonitor()
            hudHideWorkItem?.cancel()
        }
        .onChange(of: service.isPopoverOpen) { open in
            if open {
                startStream()
            } else {
                streamTask?.cancel()
                streamTask = nil
                mode = .connecting
            }
        }
        .onChange(of: rtspClient.hasFrame) { ready in
            // Reveal the picture only once a real frame exists, fading the
            // connecting overlay out so video doesn't pop in over black.
            if ready { withAnimation(.easeOut(duration: 0.25)) { mode = .playing } }
        }
        .onChange(of: rtspClient.error) { err in
            if err != nil { mode = .failed }
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

        Divider()

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

    private func startStream() {
        if rtspClient.hasFrame { mode = .playing; return }
        guard streamTask == nil else { return }
        guard service.isPopoverOpen, camera.isOnline else {
            mode = camera.isOnline ? .connecting : .failed
            return
        }
        mode = .connecting

        // Stagger connects by grid position so tiles light up as a calm
        // top-left → bottom-right cascade rather than a random scatter. Cap the
        // delay so large grids don't leave the last tiles waiting too long.
        let stagger = UInt64(min(loadOrder, 12)) * 90_000_000

        streamTask = Task {
            try? await Task.sleep(nanoseconds: stagger)
            guard !Task.isCancelled else { return }

            guard let streamURL = await service.createRtspStreamURL(for: camera) else {
                mode = .failed
                streamTask = nil
                return
            }
            guard !Task.isCancelled else { streamTask = nil; return }

            streamTask = nil
            rtspClient.connect(to: streamURL)
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        rtspClient.disconnect()
        mode = .connecting
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
                onBack: { exitFocus() },
                onToggleFullscreen: { toggleTrueFullscreen() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                if showOverlayControls {
                    AuroraFocusHints(showPtzHint: camera.isPtz,
                                     showZoomHint: camera.canZoom)
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
            if camera.isOnline && mode == .playing {
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
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                Color.black.opacity(0.55)
            }
        )
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
