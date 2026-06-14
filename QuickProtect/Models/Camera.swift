import Foundation

/// User-selectable RTSP stream quality. `.high`/`.medium`/`.low` map directly to
/// the `qualities` key the rtsps-stream endpoint accepts; `.auto` is a UI-level
/// choice that resolves to a concrete quality based on whether the camera is
/// enlarged (low in the grid, high in focus) — see `resolve(focused:)`.
enum StreamQuality: String, CaseIterable, Codable {
    case auto, high, medium, low

    /// Concrete substream key for the rtsps-stream endpoint. `.auto` must be
    /// resolved with `resolve(focused:)` before reaching the network layer; if a
    /// raw `.auto` slips through it falls back to `.medium`.
    var apiValue: String { self == .auto ? "medium" : rawValue }

    /// Resolve `.auto` to a concrete quality for the current view state. Pass-through
    /// for the explicit cases so callers can resolve unconditionally.
    func resolve(focused: Bool) -> StreamQuality {
        self == .auto ? (focused ? .high : .low) : self
    }

    /// Resolution ordering (low < medium < high) used to tell an upgrade from a
    /// downgrade. `.auto` sits with medium; it's only meaningful once resolved.
    var rank: Int {
        switch self {
        case .low:    return 0
        case .auto:   return 1
        case .medium: return 1
        case .high:   return 2
        }
    }

    /// Localized name for menus and settings.
    var displayName: String {
        switch self {
        case .auto:   return String(localized: "Auto")
        case .high:   return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low:    return String(localized: "Low")
        }
    }
}

struct Camera: Identifiable {
    let id: String
    let name: String
    let state: String
    let channels: [Channel]
    /// True if the camera supports physical pan/tilt/zoom.
    /// Set during classic API enrichment (Integration API doesn't expose this flag).
    var isPtz: Bool = false
    /// True if the camera has an optical zoom lens (may be true on cameras
    /// without pan/tilt motors). Enriched the same way as `isPtz`.
    var canZoom: Bool = false

    /// Secondary lens descriptor for multi-sensor cameras (currently the
    /// doorbell package camera). `nil` for ordinary single-lens cameras.
    /// Decoded straight from the Integration API list, so the rest of the app
    /// stays lens-agnostic: it only needs the stream quality and a UI label.
    var secondaryLens: SecondaryLens?

    /// A camera's additional fixed lens, streamed as its own RTSP quality.
    struct SecondaryLens: Equatable {
        /// The `qualities` key passed to the rtsps-stream endpoint (e.g. "package").
        let quality: String
        /// Human-readable label for the picture-in-picture and Settings row.
        let label: String
    }

    struct Channel {
        let id: Int
        let name: String
        let rtspAlias: String?
        let isRtspEnabled: Bool
    }

    /// Feature flags decoded from the classic API's camera payload.
    struct FeatureFlags: Decodable {
        let isPtz: Bool
        let canOpticalZoom: Bool
        /// Optical zoom range from the nested `zoom` flags. Current firmware
        /// reports canOpticalZoom=false even on zoom lenses (e.g. G6 PTZ) and
        /// expresses the capability as zoom.ratio > 1 instead; fixed lenses
        /// report ratio 1.
        let zoomRatio: Double

        var hasOpticalZoom: Bool { canOpticalZoom || zoomRatio > 1 }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isPtz          = (try? c.decode(Bool.self, forKey: .isPtz))          ?? false
            canOpticalZoom = (try? c.decode(Bool.self, forKey: .canOpticalZoom)) ?? false
            let zoom = try? c.decode(Zoom.self, forKey: .zoom)
            zoomRatio = zoom?.ratio ?? 1
        }
        enum CodingKeys: String, CodingKey { case isPtz, canOpticalZoom, zoom }

        struct Zoom: Decodable {
            let ratio: Double?
        }
    }

    var primaryRtspAlias: String? {
        // Prefer the first enabled channel; fall back to any channel that has an alias
        channels.first(where: { $0.isRtspEnabled && $0.rtspAlias != nil })?.rtspAlias
            ?? channels.first(where: { $0.rtspAlias != nil })?.rtspAlias
    }

    var isOnline: Bool { state == "CONNECTED" }
}

// MARK: - Codable (lenient — handles both classic and integration API shapes)

extension Camera: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        name     = try c.decode(String.self, forKey: .name)
        state    = (try? c.decode(String.self, forKey: .state)) ?? "UNKNOWN"
        // channels may be absent in some API responses
        channels = (try? c.decode([Channel].self, forKey: .channels)) ?? []
        // featureFlags with isPtz/canOpticalZoom — only present in classic API responses
        if let flags = try? c.decode(FeatureFlags.self, forKey: .featureFlags) {
            isPtz = flags.isPtz || flags.hasOpticalZoom
            canZoom = flags.hasOpticalZoom
        } else {
            isPtz = false
            canZoom = false
        }
        // hasPackageCamera (Integration API list) → the only secondary lens
        // current firmware exposes. Mapping it here keeps the view/stream layers
        // generic; new secondary-lens types slot in by extending this branch.
        if (try? c.decode(Bool.self, forKey: .hasPackageCamera)) == true {
            secondaryLens = SecondaryLens(quality: "package",
                                          label: String(localized: "Package Camera"))
        } else {
            secondaryLens = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encode(channels, forKey: .channels)
        // Round-trip the secondary-lens flag so a cached list keeps its PiP.
        try c.encode(secondaryLens?.quality == "package", forKey: .hasPackageCamera)
        // isPtz/canZoom are enriched at runtime; featureFlags is decode-only
    }

    enum CodingKeys: String, CodingKey {
        case id, name, state, channels, featureFlags, hasPackageCamera
    }
}

extension Camera.Channel: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(Int.self,    forKey: .id))          ?? 0
        name        = (try? c.decode(String.self, forKey: .name))        ?? ""
        rtspAlias   =  try? c.decode(String.self, forKey: .rtspAlias)
        // field is called isRtspEnabled in classic API; treat missing as true
        // so any channel that has an alias is considered usable
        isRtspEnabled = (try? c.decode(Bool.self, forKey: .isRtspEnabled)) ?? (rtspAlias != nil)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, rtspAlias, isRtspEnabled
    }
}
