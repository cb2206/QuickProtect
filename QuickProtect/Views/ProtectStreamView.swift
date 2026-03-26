import SwiftUI
import AVFoundation
import AppKit

/// Wraps an AVSampleBufferDisplayLayer for display inside a SwiftUI view.
/// The display layer is set as the NSView's *backing layer* (via makeBackingLayer)
/// rather than added as a sublayer.  This lets AppKit manage the layer's frame
/// automatically, avoiding subtle sizing/parenting issues that can produce a
/// black rectangle even though frames are being decoded.
struct ProtectStreamView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> DisplayLayerHostView {
        let view = DisplayLayerHostView()
        view.hostLayer = displayLayer
        view.wantsLayer = true          // triggers makeBackingLayer()
        return view
    }

    func updateNSView(_ nsView: DisplayLayerHostView, context: Context) {
        // Nothing to update — the backing layer is the display layer itself.
    }
}

/// An NSView whose backing CALayer is the provided AVSampleBufferDisplayLayer.
final class DisplayLayerHostView: NSView {
    var hostLayer: AVSampleBufferDisplayLayer?

    override func makeBackingLayer() -> CALayer {
        // Return the display layer as the view's own backing layer.
        // AppKit will manage its frame to match the view's bounds.
        if let layer = hostLayer {
            layer.videoGravity = .resizeAspectFill
            return layer
        }
        return super.makeBackingLayer()
    }

    // Tell AppKit we manage the layer contents ourselves.
    override var wantsUpdateLayer: Bool { true }
}
