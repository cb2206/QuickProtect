import Foundation

/// Pure request-policy decisions for talking to the Protect controller, whose
/// rate limiter allows 10 requests per second. Kept free of URLSession and
/// service state so the rules are unit-testable in isolation.
enum ControllerRequestPolicy {

    /// Minimum interval between automatic camera-list fetches. Reopening the
    /// panel within this window reuses the current list instead of hitting the
    /// controller again; user-initiated refreshes bypass it.
    static let fetchInterval: TimeInterval = 3

    /// Minimum interval between PTZ-flag enrichments. Enrichment costs two
    /// extra requests per fetch — one of them a login the controller also
    /// audit-logs — and PTZ capabilities rarely change.
    static let ptzEnrichInterval: TimeInterval = 300

    /// Whether an automatic fetch may be skipped because the last successful
    /// one is fresher than `interval`.
    static func shouldSkipFetch(lastSuccess: Date?, now: Date,
                                interval: TimeInterval = fetchInterval) -> Bool {
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) < interval
    }

    /// When and with which credentials PTZ flags were last enriched.
    struct PtzEnrichRecord {
        let at: Date
        let username: String
        let password: String
    }

    /// Whether PTZ enrichment may be skipped: same credentials as last time and
    /// enriched recently. Credential changes always re-enrich so the Settings
    /// PTZ status reflects what the user just typed.
    static func shouldSkipPtzEnrich(last: PtzEnrichRecord?,
                                    username: String, password: String, now: Date,
                                    interval: TimeInterval = ptzEnrichInterval) -> Bool {
        guard let last, last.username == username, last.password == password else { return false }
        return now.timeIntervalSince(last.at) < interval
    }

    /// Whether a failed stream-creation POST should abort the quality-fallback
    /// ladder instead of trying the next tier. On 429 or a server error the
    /// tier isn't the problem — retrying other tiers just multiplies requests
    /// against the limiter (up to 3× per camera).
    static func abortsQualityLadder(httpStatus: Int) -> Bool {
        httpStatus == 429 || httpStatus >= 500
    }
}
