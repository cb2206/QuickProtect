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
    @StateObject private var clientManager = RTSPClientManager()
    @State private var dragCameraId: String?
    @State private var focusedCameraId: String?

    /// 4 logical columns; cameras span 1, 2, or 4 based on their size setting.
    private let columnCount = 4
    private let spacing: CGFloat = 3

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
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
            ProgressView().scaleEffect(1.2).tint(.white)
            Text("Connecting…").foregroundColor(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundColor(.yellow)
            Text(message)
                .multilineTextAlignment(.center).foregroundColor(.white)
                .frame(maxWidth: 380)
        }.padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 40)).foregroundColor(.gray)
            Text("No cameras found.\nCheck settings and refresh.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
        }
    }

    // MARK: - Row-packed grid layout

    private var orderedCameras: [Camera] {
        let visible = AppSettings.shared.visibleCameras(service.cameras)
        return AppSettings.shared.orderedCameras(visible)
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
                                CameraCell(camera: item.camera, service: service, span: item.span,
                                           focusedCameraId: $focusedCameraId,
                                           clientManager: clientManager)
                                    .frame(
                                        width:  isFocused ? geo.size.width  : (isHidden ? 0 : cellWidth(span: item.span, colWidth: colWidth)),
                                        height: isFocused ? geo.size.height : (isHidden ? 0 : nil)
                                    )
                                    .opacity(isHidden ? 0 : 1)
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
        .onChange(of: service.isPopoverOpen) { open in
            if !open { clientManager.disconnectAll() }
        }
    }

    private func cellWidth(span: Int, colWidth: CGFloat) -> CGFloat {
        CGFloat(span) * colWidth + CGFloat(span - 1) * spacing
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
    @Binding var focusedCameraId: String?

    @ObservedObject private var rtspClient: RTSPClient
    @State private var mode: Mode = .connecting
    @State private var streamTask: Task<Void, Never>?
    @State private var isHovered = false

    // Zoom & pan (only active when focused)
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @State private var cellSize: CGSize = .zero       // for pan clamping

    enum Mode { case connecting, playing, failed }

    init(camera: Camera, service: ProtectService, span: Int,
         focusedCameraId: Binding<String?>, clientManager: RTSPClientManager) {
        self.camera = camera
        self.service = service
        self.span = span
        self._focusedCameraId = focusedCameraId
        self._rtspClient = ObservedObject(wrappedValue: clientManager.client(for: camera.id))
    }

    private var isFocused: Bool { focusedCameraId == camera.id }

    /// Aspect ratio: live stream dims > cached dims > 16:9 fallback.
    private var aspectRatio: CGFloat {
        let dims = rtspClient.videoDimensions
        if dims.width > 0 && dims.height > 0 {
            return dims.width / dims.height
        }
        return AppSettings.shared.cachedAspectRatio(for: camera.id) ?? (16.0 / 9.0)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Stream view: use .resizeAspect when focused to preserve full frame
            GeometryReader { geo in
                ProtectStreamView(
                    displayLayer: rtspClient.displayLayer,
                    videoGravity: isFocused ? .resizeAspect : .resizeAspectFill,
                    onZoom: isFocused ? { delta in
                        let newScale = zoomScale + delta
                        zoomScale = max(1.0, min(8.0, newScale))
                        if zoomScale <= 1.0 { panOffset = .zero; lastPanOffset = .zero }
                    } : nil,
                    onPan: isFocused ? { dx, dy in
                        guard zoomScale > 1.0 else { return }
                        let maxPanX = cellSize.width * (zoomScale - 1) / 2
                        let maxPanY = cellSize.height * (zoomScale - 1) / 2
                        let newX = lastPanOffset.width + dx
                        let newY = lastPanOffset.height - dy
                        panOffset = CGSize(
                            width: max(-maxPanX, min(maxPanX, newX)),
                            height: max(-maxPanY, min(maxPanY, newY))
                        )
                        lastPanOffset = panOffset
                    } : nil,
                    onKeyPress: isFocused ? { keyCode in
                        if keyCode == 3 || keyCode == 49 { toggleTrueFullscreen() }    // F or Space
                        else if keyCode == 53 { handleEscape() }      // Escape
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
            }

            nameBadge

            if isFocused {
                // Controls overlay (top-right)
                VStack {
                    HStack {
                        Spacer()
                        // Fullscreen button
                        Button {
                            toggleTrueFullscreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(6)
                                .background(.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Fullscreen (F)")

                        // Close button
                        Button {
                            exitFocus()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.8), .black.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    Spacer()
                }
            }
        }
        .aspectRatio(isFocused ? nil : aspectRatio, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: isFocused ? 0 : 4))
        .overlay(
            RoundedRectangle(cornerRadius: isFocused ? 0 : 4)
                .stroke(isHovered && !isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onAppear {
            if rtspClient.isConnected {
                mode = .playing
            } else if rtspClient.error != nil {
                mode = .failed
            } else {
                startStream()
            }
            if isFocused { installKeyMonitor() }
        }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
            removeKeyMonitor()
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
        .onChange(of: rtspClient.isConnected) { connected in
            if connected { mode = .playing }
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
                installKeyMonitor()
            } else {
                removeKeyMonitor()
                zoomScale = 1.0
                panOffset = .zero
                lastPanOffset = .zero
            }
        }
        .onTapGesture(count: 2) { openInProtect() }
        .onTapGesture(count: 1) {
            if isFocused {
                exitFocus()
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
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
        withAnimation(.easeInOut(duration: 0.3)) {
            focusedCameraId = nil
        }
    }

    // MARK: - F key → true fullscreen

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        // Local monitor — fallback for when DisplayLayerHostView doesn't have focus
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard focusedCameraId == camera.id else { return event }
            if event.keyCode == 3 || event.keyCode == 49 { toggleTrueFullscreen(); return nil }
            if event.keyCode == 53 { handleEscape(); return nil }
            return event
        }

        // Global monitor — captures events when app isn't active
        // (needed because popover uses .nonactivatingPanel)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [self] event in
            guard focusedCameraId == camera.id else { return }
            if event.keyCode == 3 || event.keyCode == 49 { DispatchQueue.main.async { toggleTrueFullscreen() } }
            if event.keyCode == 53 { DispatchQueue.main.async { handleEscape() } }
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

    // MARK: - Size context menu

    @ViewBuilder
    private var sizeMenu: some View {
        Button { openInProtect() } label: {
            Label("Open in Protect", systemImage: "safari")
        }
        Divider()
        let current = AppSettings.shared.cameraSize(for: camera.id)
        Button { setSize(.small) } label: {
            Label("Small", systemImage: current == .small ? "checkmark" : "")
        }
        Button { setSize(.medium) } label: {
            Label("Medium", systemImage: current == .medium || current == nil ? "checkmark" : "")
        }
        Button { setSize(.large) } label: {
            Label("Large", systemImage: current == .large ? "checkmark" : "")
        }
        Divider()
        Button { setSize(nil) } label: {
            Text("Reset to Auto")
        }
        Divider()
        Button {
            AppSettings.shared.setHidden(true, for: camera.id)
            service.objectWillChange.send()
        } label: {
            Label("Hide Camera", systemImage: "eye.slash")
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
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.title2).foregroundColor(.gray)
            Text("Offline").font(.caption).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash").font(.title2).foregroundColor(.gray)
            Text("No stream").font(.caption).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stream lifecycle

    private func startStream() {
        if rtspClient.isConnected { mode = .playing; return }
        guard streamTask == nil else { return }
        guard service.isPopoverOpen, camera.isOnline else {
            mode = camera.isOnline ? .connecting : .failed
            return
        }
        mode = .connecting

        let stagger = UInt64(abs(camera.id.hashValue) % 7) * 260_000_000

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

    // MARK: - Name badge

    private var nameBadge: some View {
        HStack(spacing: 4) {
            if !camera.isOnline {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
            Text(camera.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(6)
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
