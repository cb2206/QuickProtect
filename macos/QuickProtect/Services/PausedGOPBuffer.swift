import Foundation

/// Bounded buffer of compressed video access units collected while display
/// decode is paused (panel hidden during the stream keep-alive grace).
///
/// Keeps exactly the run of access units since the most recent keyframe, so
/// resume can burst-decode one valid GOP and land on the live picture. Frames
/// buffered mid-GOP with no anchoring keyframe are useless (their references
/// were never decoded) and are discarded. A GOP that outgrows `byteLimit` is
/// dropped wholesale; the buffer stays empty until the next keyframe restarts
/// it, and the caller falls back to waiting for a keyframe on resume.
///
/// Pure value type — no AVFoundation — so the policy is unit-testable.
struct PausedGOPBuffer {
    /// Several seconds of high-quality H.264/HEVC; a single GOP beyond this is
    /// abnormal and not worth holding per camera.
    static let defaultByteLimit = 8 * 1024 * 1024

    private(set) var accessUnits: [[[UInt8]]] = []
    private var bytes = 0
    private var dropped = false
    private let byteLimit: Int

    init(byteLimit: Int = Self.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    /// True when nothing replayable is buffered (paused mid-GOP, or the GOP
    /// overflowed the limit).
    var isEmpty: Bool { accessUnits.isEmpty }

    mutating func add(_ nals: [[UInt8]], isKeyframe: Bool) {
        if isKeyframe {
            accessUnits.removeAll(keepingCapacity: true)
            bytes = 0
            dropped = false
        } else if dropped || accessUnits.isEmpty {
            return
        }
        accessUnits.append(nals)
        bytes += nals.reduce(0) { $0 + $1.count }
        if bytes > byteLimit {
            accessUnits.removeAll(keepingCapacity: false)
            bytes = 0
            dropped = true
        }
    }

    /// Returns the buffered GOP (oldest first) and resets the buffer.
    mutating func drain() -> [[[UInt8]]] {
        defer { self = PausedGOPBuffer(byteLimit: byteLimit) }
        return accessUnits
    }
}
