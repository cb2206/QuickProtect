import Foundation

/// Paces a pinned window's recovery from a stream that stopped working — the
/// URL POST failed, or the client lost its session (connection failure, an
/// RTSP 404 because another client deleted the allocation, a receive error).
///
/// Each failure waits longer before the next fresh-URL attempt: 5 s, doubling
/// to a 60 s cap, back to 5 s once a frame paints. Mirrors the .NET
/// `VideoStreamCoordinator` re-allocation pacing. Pure value type so the
/// schedule is unit-tested without a controller or a window.
struct StreamRecoveryBackoff: Equatable, Sendable {
    static let initialDelay: TimeInterval = 5
    static let maximumDelay: TimeInterval = 60

    /// The wait the next failure will get.
    private(set) var nextDelay: TimeInterval = initialDelay
    /// Set by `stop()`; no attempt is scheduled after that.
    private(set) var isStopped = false

    /// Records a failure. Returns how long to wait before the next attempt, or
    /// `nil` once stopped.
    mutating func failed() -> TimeInterval? {
        guard !isStopped else { return nil }
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, Self.maximumDelay)
        return delay
    }

    /// The stream is playing again: the next failure starts from the initial delay.
    mutating func recovered() {
        nextDelay = Self.initialDelay
    }

    /// The window is going away: no further attempts.
    mutating func stop() {
        isStopped = true
    }
}
