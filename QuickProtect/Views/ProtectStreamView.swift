import SwiftUI
import AVFoundation
import AppKit

/// Wraps an AVSampleBufferDisplayLayer for display inside a SwiftUI view.
/// Also handles scroll-wheel zoom, trackpad pinch-to-zoom, trackpad pan,
/// and keyboard events (F/Escape) directly — no overlay views needed.
struct ProtectStreamView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var reparentTrigger: Bool = false

    // Gesture callbacks (nil = not focused, events pass through)
    var onZoom: ((CGFloat) -> Void)? = nil
    var onPan: ((CGFloat, CGFloat) -> Void)? = nil
    var onKeyPress: ((UInt16) -> Void)? = nil

    func makeNSView(context: Context) -> DisplayLayerHostView {
        let view = DisplayLayerHostView()
        view.wantsLayer = true
        view.onZoom = onZoom
        view.onPan = onPan
        view.onKeyPress = onKeyPress
        displayLayer.videoGravity = videoGravity
        view.layer?.addSublayer(displayLayer)
        displayLayer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: DisplayLayerHostView, context: Context) {
        nsView.onZoom = onZoom
        nsView.onPan = onPan
        nsView.onKeyPress = onKeyPress
        displayLayer.videoGravity = videoGravity

        // Re-parent the layer if it was somehow detached
        if displayLayer.superlayer !== nsView.layer {
            nsView.layer?.addSublayer(displayLayer)
        }
        displayLayer.frame = nsView.bounds

        // Become first responder when focused (needed for keyDown)
        if onKeyPress != nil, let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }
}

/// Host view that sizes all sublayers to match its bounds on layout.
/// Handles scroll wheel (mouse zoom / trackpad pan), pinch-to-zoom,
/// and key events directly.
final class DisplayLayerHostView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onKeyPress: ((UInt16) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.sublayers?.forEach { $0.frame = CGRect(origin: .zero, size: newSize) }
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }

    override var acceptsFirstResponder: Bool { true }

    // Mouse scroll wheel → zoom; Trackpad two-finger scroll → pan
    override func scrollWheel(with event: NSEvent) {
        if onZoom == nil && onPan == nil { super.scrollWheel(with: event); return }
        if event.hasPreciseScrollingDeltas {
            // Trackpad two-finger scroll → pan
            onPan?(event.scrollingDeltaX, event.scrollingDeltaY)
        } else {
            // Mouse scroll wheel → zoom
            onZoom?(event.scrollingDeltaY * 0.1)
        }
    }

    // Trackpad pinch-to-zoom
    override func magnify(with event: NSEvent) {
        onZoom?(event.magnification) ?? super.magnify(with: event)
    }

    // F / Escape keys
    override func keyDown(with event: NSEvent) {
        if let handler = onKeyPress {
            handler(event.keyCode)
        } else {
            super.keyDown(with: event)
        }
    }
}
