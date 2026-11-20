import AppKit
import SwiftUI

// MARK: - Window drag

/// Panel that moves when dragged by a `WindowDragArea`. The move starts here,
/// before the event reaches SwiftUI: `isMovableByWindowBackground` gets no
/// background drags through the hosting view on macOS 27, and a view's own
/// `mouseDown` isn't reliable either — the hosting view swallowed about a
/// third of the clicks that hit-tested to `WindowDragNSView`.
///
/// Used by pinned camera windows (drag by the video) and by the camera panel
/// when it's kept open (drag by the header).
final class DragMovablePanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView,
           content.hitTest(content.convert(event.locationInWindow, from: nil)) is WindowDragNSView {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

/// Marks where a drag moves the window: everywhere the controls drawn above it
/// don't cover (they win the hit test).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    // `DragMovablePanel` starts the drag; don't let AppKit start a second one.
    override var mouseDownCanMoveWindow: Bool { false }
    // Both users are non-activating panels; accept the first click without focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
