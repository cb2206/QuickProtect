import SwiftUI
import AVFoundation
import AppKit

// MARK: - Focus overlay: secondary-lens PiP, top bar, PTZ d-pad, HUD
// auto-hide, name badge.

extension CameraCell {

    // MARK: - Secondary lens picture-in-picture

    var secondaryLensPiP: some View {
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
                // Snapshot placeholder while the stream waits for its first
                // keyframe (many seconds on the 2 fps package lens).
                if let placeholder = pipClient.placeholderImage {
                    Image(decorative: placeholder, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
    var focusOverlay: some View {
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
    var showOverlayControls: Bool {
        AppSettings.shared.showFocusOverlayControls
    }

    func dpadPress(_ dir: AuroraPtzDpad.Direction) {
        ptzActiveDirection = dir
        switch dir {
        case .up:    service.ptzSetAxes(cameraId: camera.id, tilt:  1)
        case .down:  service.ptzSetAxes(cameraId: camera.id, tilt: -1)
        case .left:  service.ptzSetAxes(cameraId: camera.id, pan:  -1)
        case .right: service.ptzSetAxes(cameraId: camera.id, pan:   1)
        }
    }

    func dpadRelease() {
        service.ptzSetAxes(cameraId: camera.id, pan: 0, tilt: 0)
        ptzActiveDirection = nil
    }

    func zoomPress(_ dir: AuroraPtzZoomControl.Direction) {
        ptzActiveZoom = dir
        switch dir {
        case .zoomIn:  service.ptzSetAxes(cameraId: camera.id, zoom:  1)
        case .zoomOut: service.ptzSetAxes(cameraId: camera.id, zoom: -1)
        }
    }

    func zoomRelease() {
        service.ptzSetAxes(cameraId: camera.id, zoom: 0)
        ptzActiveZoom = nil
    }

    func startClockTimer() {
        stopClockTimer()
        clockTick = Date()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            // Fires on the main run loop; Swift 6.1 needs that spelled out.
            MainActor.assumeIsolated { clockTick = Date() }
        }
    }

    func stopClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    // MARK: - HUD auto-hide on cursor idle

    func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { event in
            bumpHud()
            return event
        }
    }

    func removeMouseMonitor() {
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    func bumpHud() {
        hudVisible = true
        hudHideWorkItem?.cancel()
        let item = DispatchWorkItem { hudVisible = false }
        hudHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Name badge (Aurora hairline pill)

    var nameBadge: some View {
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
