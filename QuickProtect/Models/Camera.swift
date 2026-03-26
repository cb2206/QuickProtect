import Foundation

struct Camera: Identifiable {
    let id: String
    let name: String
    let state: String
    let channels: [Channel]

    struct Channel {
        let id: Int
        let name: String
        let rtspAlias: String?
        let isRtspEnabled: Bool
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
    }

    enum CodingKeys: String, CodingKey {
        case id, name, state, channels
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
