import Foundation

struct Camera: Identifiable {
    let id: String
    let name: String
    let state: String
    let channels: [Channel]
    /// True if the camera supports physical pan/tilt/zoom.
    /// Set during classic API enrichment (Integration API doesn't expose this flag).
    var isPtz: Bool = false

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

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isPtz          = (try? c.decode(Bool.self, forKey: .isPtz))          ?? false
            canOpticalZoom = (try? c.decode(Bool.self, forKey: .canOpticalZoom)) ?? false
        }
        enum CodingKeys: String, CodingKey { case isPtz, canOpticalZoom }
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
            isPtz = flags.isPtz || flags.canOpticalZoom
        } else {
            isPtz = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encode(channels, forKey: .channels)
        // isPtz is enriched at runtime; featureFlags is decode-only
    }

    enum CodingKeys: String, CodingKey {
        case id, name, state, channels, featureFlags
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
