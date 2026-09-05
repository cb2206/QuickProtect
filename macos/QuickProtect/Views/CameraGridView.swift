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
    @State var dragCameraId: String?
    @State var focusedCameraId: String?
    @State var lastRetryAt: Date?

    /// On appear, restore the last focused camera so reopening the panel
    /// picks up where the user left off.
    func restoreFocus() {
        if let saved = service.lastFocusedCameraId,
           orderedCameras.contains(where: { $0.id == saved }) {
            focusedCameraId = saved
        }
    }

    /// 4 logical columns; cameras span 1, 2, or 4 based on their size setting.
    let columnCount = 4
    let spacing: CGFloat = 2
    @Environment(\.colorScheme) var colorScheme
    var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

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

    var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2).tint(palette.text)
            Text("Connecting…").foregroundColor(palette.subtext)
        }
    }

    func errorView(_ message: String) -> some View {
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

    var emptyView: some View {
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

    func openProtectDashboard() {
        let ip = AppSettings.shared.ipAddress
        guard !ip.isEmpty, let url = URL(string: "https://\(ip)/protect") else { return }
        NotificationCenter.default.post(name: .closeCameraPanel, object: nil)
        NSWorkspace.shared.open(url)
    }

    static func relativeAgo(from date: Date) -> String {
        let secs = Int(max(0, Date().timeIntervalSince(date)))
        if secs < 2 { return String(localized: "just now") }
        if secs < 60 { return String(localized: "\(secs) seconds ago") }
        let mins = secs / 60
        if mins < 60 { return String(localized: "\(mins) minutes ago") }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    // MARK: - Row-packed grid layout

    var orderedCameras: [Camera] {
        let visible = AppSettings.shared.visibleCameras(service.cameras)
        let ordered = AppSettings.shared.orderedCameras(visible)
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ordered }
        return ordered.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var cameraGrid: some View {
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

    func cellWidth(span: Int, colWidth: CGFloat) -> CGFloat {
        CGFloat(span) * colWidth + CGFloat(span - 1) * spacing
    }

    /// Aspect ratio used to size a grid cell's height. Uses the per-camera cached
    /// stream dimensions (populated on first connect, persisted across launches),
    /// falling back to 16:9. Kept here — rather than relying on the cell's own
    /// `.aspectRatio` — so the cell can keep a stable explicit frame.
    func gridAspect(for camera: Camera) -> CGFloat {
        AppSettings.shared.cachedAspectRatio(for: camera.id) ?? (16.0 / 9.0)
    }

    struct RowItem {
        let camera: Camera
        let span: Int
    }

    /// Pack cameras into rows, filling each row left-to-right.
    func packRows(cameras: [Camera], colWidth: CGFloat) -> [[RowItem]] {
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
    func effectiveSpan(for camera: Camera) -> Int {
        if let userSize = AppSettings.shared.cameraSize(for: camera.id) {
            return userSize.rawValue
        }
        // No override: every camera starts at medium (2 columns). Sizing from
        // the stream's native dimensions was considered and not implemented —
        // the span is a layout preference, not a property of the video.
        return AppSettings.CameraSize.medium.rawValue
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
