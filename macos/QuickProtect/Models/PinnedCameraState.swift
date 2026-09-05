import AppKit

// MARK: - Pinned floating-window state

/// Persisted state for one pinned floating window. The frame is in screen
/// coordinates; a `nil` frame means "pinned but not yet positioned" so the
/// window controller can compute a default on first show and write it back.
///
/// The dictionary conversion is pure (touches no UserDefaults), so the
/// round-trip is unit-testable in isolation.
struct PinnedCameraState: Equatable {
    let cameraId: String
    var frame: NSRect?

    init(cameraId: String, frame: NSRect? = nil) {
        self.cameraId = cameraId
        self.frame = frame
    }

    init(cameraId: String, dictionary: [String: Double]) {
        self.cameraId = cameraId
        if let x = dictionary["x"], let y = dictionary["y"],
           let w = dictionary["w"], let h = dictionary["h"], w > 0, h > 0 {
            frame = NSRect(x: x, y: y, width: w, height: h)
        } else {
            frame = nil
        }
    }

    /// UserDefaults storage form. An unpositioned entry stores an empty dict,
    /// which still reads back as "pinned" (the key is present).
    var dictionary: [String: Double] {
        guard let f = frame else { return [:] }
        return ["x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height]
    }
}

/// Pure geometry helpers for the pinned floating window. Kept free of AppKit
/// window state so the sizing math can be unit-tested directly.
enum PinnedWindowGeometry {
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 1600
    static let fallbackAspect: CGFloat = 16.0 / 9.0

    /// Default content size for a freshly pinned window: `targetWidth` scaled to
    /// the camera's aspect ratio (width ÷ height), clamped to a sane range.
    static func defaultSize(aspectRatio: CGFloat, targetWidth: CGFloat = 360) -> NSSize {
        let ar = aspectRatio > 0 ? aspectRatio : fallbackAspect
        let w = min(maxWidth, max(minWidth, targetWidth)).rounded()
        return NSSize(width: w, height: (w / ar).rounded())
    }

    /// Constrain a proposed size to `aspectRatio`, driving from width so a
    /// corner drag keeps the camera's proportions. Width is clamped to range.
    static func constrain(_ proposed: NSSize, toAspectRatio aspectRatio: CGFloat) -> NSSize {
        let ar = aspectRatio > 0 ? aspectRatio : fallbackAspect
        let w = min(maxWidth, max(minWidth, proposed.width)).rounded()
        return NSSize(width: w, height: (w / ar).rounded())
    }
}
