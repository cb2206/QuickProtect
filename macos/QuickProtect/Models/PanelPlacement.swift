import AppKit

/// Pure placement rules for the camera panel, kept out of `AppDelegate` so
/// they are unit-testable.
enum PanelPlacement {
    /// The panel's window level. As a popover it sits at `.popUpMenu`, like the
    /// status-item menus it stands in for. Kept open it is a long-lived window,
    /// so it floats above ordinary windows but no longer above other apps'
    /// menus. Pinned camera windows sit above both (`.popUpMenu + 1`).
    static func level(keepOpen: Bool) -> NSWindow.Level {
        keepOpen ? .floating : .popUpMenu
    }

    /// A saved origin that still makes sense: the screen holding the panel's
    /// center, with the panel pulled fully onto that screen's visible frame (a
    /// display may have shrunk or moved since). Nil when the center lands on no
    /// screen at all; that display is gone and the caller anchors the panel to
    /// the status item instead. Mirrors `MainWindow.RestorablePosition` (.NET).
    static func restoredOrigin(saved: NSPoint, size: NSSize, visibleFrames: [NSRect]) -> NSPoint? {
        let center = NSPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2)
        guard let frame = visibleFrames.first(where: { $0.contains(center) }) else { return nil }
        return NSPoint(
            x: min(max(saved.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
            y: min(max(saved.y, frame.minY), max(frame.minY, frame.maxY - size.height))
        )
    }
}
