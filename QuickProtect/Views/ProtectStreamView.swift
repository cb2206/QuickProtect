import SwiftUI
import AVFoundation
import AppKit

/// Wraps an AVSampleBufferDisplayLayer for display inside a SwiftUI view.
/// Also handles scroll-wheel zoom, trackpad pinch-to-zoom, trackpad pan,
/// and keyboard events (F/Escape) directly — no overlay views needed.
struct ProtectStreamView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    /// Bumping this forces `updateNSView` to run, which re-attaches the display
    /// layer if it fell out of the view tree (e.g. after returning from focus).
    var reattachNonce: Int = 0

    // Gesture callbacks (nil = not focused, events pass through)
    var onZoom: ((CGFloat) -> Void)? = nil
    var onPan: ((CGFloat, CGFloat) -> Void)? = nil
    var onKeyPress: ((UInt16) -> Void)? = nil
    var onKeyUp: ((UInt16) -> Void)? = nil

    func makeNSView(context: Context) -> DisplayLayerHostView {
        let view = DisplayLayerHostView()
        view.wantsLayer = true
        view.onZoom = onZoom
        view.onPan = onPan
        view.onKeyPress = onKeyPress
        view.onKeyUp = onKeyUp
        displayLayer.videoGravity = videoGravity
        // Hand the host view a reference so it can re-attach the layer on every
        // layout pass — see DisplayLayerHostView.layout().
        view.managedLayer = displayLayer
        displayLayer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: DisplayLayerHostView, context: Context) {
        nsView.onZoom = onZoom
        nsView.onPan = onPan
        nsView.onKeyPress = onKeyPress
        nsView.onKeyUp = onKeyUp

        // Cross-dissolve when the framing changes (grid .resizeAspectFill →
        // focus .resizeAspect, or the fit/fill toggle). Switching gravity is
        // otherwise an instant reflow that pops letterbox bars in/out mid-zoom.
        if displayLayer.videoGravity != videoGravity {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.28
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            displayLayer.add(fade, forKey: "videoGravity")
            displayLayer.videoGravity = videoGravity
        }

        // Re-parent the layer if it was somehow detached (e.g. after a focus
        // resize moved/dropped it from the layer tree).
        nsView.managedLayer = displayLayer
        nsView.reattachManagedLayerIfNeeded()
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
    var onKeyUp: ((UInt16) -> Void)?

    /// The display layer this view hosts. Tracked so it can be re-attached if it
    /// ever falls out of the layer tree (which leaves the stream showing black).
    weak var managedLayer: AVSampleBufferDisplayLayer? {
        didSet { reattachManagedLayerIfNeeded() }
    }

    /// Re-adds the managed display layer if it isn't currently our sublayer.
    /// Returning from a focused view resizes this host; if the layer became
    /// detached during that transition the stream goes black until it's
    /// re-parented — doing it here (and in layout) lets it self-heal.
    func reattachManagedLayerIfNeeded() {
        guard let dl = managedLayer, dl.superlayer !== layer else { return }
        layer?.addSublayer(dl)
        dl.frame = bounds
    }

    /// Resize sublayers to `frame` with implicit animations disabled. During an
    /// animated focus resize the host view's bounds change every tick; without
    /// this the display layer runs its own implicit (~0.25s) frame animation and
    /// lags behind the view, exposing the dark backing behind the video — the
    /// "black flash." Snapping it each pass keeps the picture glued to the view.
    private func syncSublayerFrames(to frame: CGRect) {
        guard let sublayers = layer?.sublayers else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayers.forEach { $0.frame = frame }
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reattachManagedLayerIfNeeded()
        syncSublayerFrames(to: CGRect(origin: .zero, size: newSize))
    }

    override func layout() {
        super.layout()
        reattachManagedLayerIfNeeded()
        syncSublayerFrames(to: bounds)
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

    // F / Escape keys + PTZ
    override func keyDown(with event: NSEvent) {
        if let handler = onKeyPress {
            handler(event.keyCode)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let handler = onKeyUp {
            handler(event.keyCode)
        } else {
            super.keyUp(with: event)
        }
    }
}
