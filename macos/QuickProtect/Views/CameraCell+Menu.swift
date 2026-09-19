import SwiftUI
import AVFoundation
import AppKit

// MARK: - Context menu (size, quality, pin, add/hide) and the state overlay.

extension CameraCell {

    // MARK: - Size context menu

    @ViewBuilder
    var sizeMenu: some View {
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

        if let pinned = appState.pinnedWindows {
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
    func addCamera(_ id: String) {
        let visibleOrder = AppSettings.shared
            .orderedCameras(AppSettings.shared.visibleCameras(service.cameras))
            .map(\.id)
        AppSettings.shared.addHiddenCamera(id, visibleOrder: visibleOrder)
        service.objectWillChange.send()
    }

    func openInProtect() {
        let ip = AppSettings.shared.ipAddress
        guard !ip.isEmpty,
              let url = URL(string: "https://\(ip)/protect/dashboard/all/sidepanel/device/\(camera.id)") else { return }
        NotificationCenter.default.post(name: .closeCameraPanel, object: nil)
        NSWorkspace.shared.open(url)
    }

    func setSize(_ size: AppSettings.CameraSize?) {
        AppSettings.shared.setCameraSize(size, for: camera.id)
        service.objectWillChange.send()   // trigger grid re-layout
        // An auto camera's grid quality scales with tile size (Large → medium),
        // so a resize may warrant a stream switch.
        reconcilePrimaryQuality()
    }

    /// Apply a per-camera quality override (or `nil` to follow the global
    /// default) and switch the live stream to match.
    func setStreamQuality(_ quality: StreamQuality?) {
        AppSettings.shared.setStreamQuality(quality, for: camera.id)
        reconcilePrimaryQuality()
    }

    // MARK: - State overlay

    @ViewBuilder
    var stateOverlay: some View {
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

    var offlinePlaceholder: some View {
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

    var failedPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 18))
                .foregroundColor(AuroraTokens.statusRed)
            Text("Stream unavailable")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            Button("Reconnect") { startStream() }
                .buttonStyle(AuroraStatePillButtonStyle(primary: true))
            // The client's own reason when it has one (certificate change,
            // controller not sending video, RTSP status), else the generic tag.
            Text(rtspClient.error ?? "RTSP · no media")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }
}
