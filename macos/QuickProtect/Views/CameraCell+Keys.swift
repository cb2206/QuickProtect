import SwiftUI
import AVFoundation
import AppKit

// MARK: - Key handling: true fullscreen (F), Escape, PTZ arrows and zoom.

extension CameraCell {

    // MARK: - F key → true fullscreen

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        // Local monitor — fallback for when DisplayLayerHostView doesn't have
        // focus. Deliberately no global monitor: focus activates the app, so
        // the local one sees every key, and a global key monitor is a
        // system-wide keystroke hook that needs Input Monitoring permission.
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
    }

    func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    func toggleTrueFullscreen() {
        if appState.isInTrueFullscreen {
            NotificationCenter.default.post(name: .exitTrueFullscreen, object: nil)
        } else {
            NotificationCenter.default.post(name: .enterTrueFullscreen, object: nil)
        }
    }

    func handleEscape() {
        if appState.isInTrueFullscreen {
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
    var currentCanZoom: Bool {
        service.cameras.first(where: { $0.id == camera.id })?.canZoom ?? camera.canZoom
    }

    func isPtzKey(_ keyCode: UInt16) -> Bool {
        [123, 124, 125, 126].contains(keyCode) || (currentCanZoom && isZoomKey(keyCode))
    }

    func isZoomKey(_ keyCode: UInt16) -> Bool {
        keyCode == 34 || keyCode == 31  // I, O
    }

    /// Key-down: start PTZ movement on the pressed axis (other axes keep
    /// running, so arrows and I/O combine). Also lights up the matching
    /// arrow on the on-screen d-pad / zoom pill.
    func handlePtzKeyDown(_ keyCode: UInt16) -> Bool {
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
    func handlePtzKeyUp(_ keyCode: UInt16) -> Bool {
        guard !AppSettings.shared.username.isEmpty, isPtzKey(keyCode) else { return false }
        switch keyCode {
        case 123, 124: service.ptzSetAxes(cameraId: camera.id, pan: 0); ptzActiveDirection = nil
        case 125, 126: service.ptzSetAxes(cameraId: camera.id, tilt: 0); ptzActiveDirection = nil
        case 34, 31:   service.ptzSetAxes(cameraId: camera.id, zoom: 0); ptzActiveZoom = nil
        default: return false
        }
        return true
    }
}
