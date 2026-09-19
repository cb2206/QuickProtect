import AppKit

// MARK: - Per-camera preferences: fill mode, stream quality, secondary-lens
// picture-in-picture, pinned floating windows, cached video dimensions.

extension AppSettings {

    // MARK: - Per-camera fill mode (fit vs. fill the focus frame)

    /// User's fit/fill choice for a focused camera. `true` = fill (crop to frame),
    /// `false` = fit (whole image). `nil` = never set → caller defaults to fit.
    func cameraFillMode(for id: String) -> Bool? {
        let dict = defaults.dictionary(forKey: Keys.cameraFillModes) as? [String: Bool]
        return dict?[id]
    }

    func setCameraFillMode(_ fill: Bool, for id: String) {
        var dict = (defaults.dictionary(forKey: Keys.cameraFillModes) as? [String: Bool]) ?? [:]
        dict[id] = fill
        defaults.set(dict, forKey: Keys.cameraFillModes)
    }

    // MARK: - Per-camera stream quality

    /// This camera's explicit stream-quality override, or `nil` when it should
    /// follow `defaultStreamQuality`. The dict only holds cameras the user has
    /// explicitly set.
    func streamQuality(for id: String) -> StreamQuality? {
        let dict = defaults.dictionary(forKey: Keys.cameraStreamQualities) as? [String: String]
        return dict?[id].flatMap(StreamQuality.init(rawValue:))
    }

    /// Set (or, with `nil`, clear) this camera's quality override.
    func setStreamQuality(_ quality: StreamQuality?, for id: String) {
        var dict = (defaults.dictionary(forKey: Keys.cameraStreamQualities) as? [String: String]) ?? [:]
        if let quality {
            dict[id] = quality.rawValue
        } else {
            dict.removeValue(forKey: id)
        }
        defaults.set(dict, forKey: Keys.cameraStreamQualities)
    }

    /// The quality a camera actually streams at: its override if set, else the
    /// global default. Still `.auto` when that's the effective choice — callers
    /// resolve to a concrete substream with `StreamQuality.resolve(focused:)`.
    func effectiveStreamQuality(for id: String) -> StreamQuality {
        streamQuality(for: id) ?? defaultStreamQuality
    }

    // MARK: - Per-camera secondary-lens picture-in-picture

    /// Whether the secondary-lens PiP (e.g. doorbell package camera) is shown
    /// when this camera is focused. Defaults to `true` — the dict only holds
    /// entries the user has explicitly turned off.
    func showsSecondaryLensPip(for id: String) -> Bool {
        let dict = defaults.dictionary(forKey: Keys.secondaryLensPip) as? [String: Bool]
        return dict?[id] ?? true
    }

    func setShowsSecondaryLensPip(_ on: Bool, for id: String) {
        var dict = (defaults.dictionary(forKey: Keys.secondaryLensPip) as? [String: Bool]) ?? [:]
        dict[id] = on
        defaults.set(dict, forKey: Keys.secondaryLensPip)
    }

    /// Whether the secondary-lens PiP is also shown on the camera's grid tile
    /// (not just the focus/fullscreen view). Defaults to `false`: a grid PiP is
    /// tiny and keeps a second stream running whenever the grid is visible.
    func showsSecondaryLensPipInGrid(for id: String) -> Bool {
        let dict = defaults.dictionary(forKey: Keys.secondaryLensPipGrid) as? [String: Bool]
        return dict?[id] ?? false
    }

    func setShowsSecondaryLensPipInGrid(_ on: Bool, for id: String) {
        var dict = (defaults.dictionary(forKey: Keys.secondaryLensPipGrid) as? [String: Bool]) ?? [:]
        dict[id] = on
        defaults.set(dict, forKey: Keys.secondaryLensPipGrid)
    }

    // MARK: - Pinned floating windows (global, not per-profile)

    /// All currently pinned cameras with their saved frames. Order is
    /// unspecified (dictionary-backed); callers reconcile against the live
    /// camera list. Global on purpose — a pinned window is a standalone
    /// always-on-top thing, independent of the active layout profile.
    func pinnedCameras() -> [PinnedCameraState] {
        let dict = (defaults.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        return dict.map { PinnedCameraState(cameraId: $0.key, dictionary: $0.value) }
    }

    func isPinned(_ cameraId: String) -> Bool {
        let dict = (defaults.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        return dict[cameraId] != nil
    }

    /// Pin a camera, optionally recording its window frame. A `nil` frame marks
    /// the camera as pinned but not yet positioned (the controller computes a
    /// default and writes it back on first layout).
    func setPinned(_ cameraId: String, frame: NSRect? = nil) {
        var dict = (defaults.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        dict[cameraId] = PinnedCameraState(cameraId: cameraId, frame: frame).dictionary
        defaults.set(dict, forKey: Keys.pinnedCameras)
        objectWillChange.send()
    }

    /// Persist a moved/resized pinned window's frame. No-op if not pinned, so a
    /// late delegate callback during teardown can't resurrect an unpinned entry.
    func setPinnedFrame(_ frame: NSRect, for cameraId: String) {
        guard isPinned(cameraId) else { return }
        setPinned(cameraId, frame: frame)
    }

    func removePinned(_ cameraId: String) {
        var dict = (defaults.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        guard dict.removeValue(forKey: cameraId) != nil else { return }
        defaults.set(dict, forKey: Keys.pinnedCameras)
        objectWillChange.send()
    }

    // MARK: - Cached video dimensions (for stable initial layout)

    func cachedAspectRatio(for cameraId: String) -> CGFloat? {
        guard let dict = defaults.dictionary(forKey: Keys.videoDimensions) as? [String: [String: Double]],
              let dims = dict[cameraId],
              let w = dims["w"], let h = dims["h"], w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }

    func cacheVideoDimensions(_ size: CGSize, for cameraId: String) {
        guard size.width > 0, size.height > 0 else { return }
        var dict = (defaults.dictionary(forKey: Keys.videoDimensions) as? [String: [String: Double]]) ?? [:]
        dict[cameraId] = ["w": Double(size.width), "h": Double(size.height)]
        defaults.set(dict, forKey: Keys.videoDimensions)
    }
}
