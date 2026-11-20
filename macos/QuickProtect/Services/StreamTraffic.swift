import Foundation

/// Bytes received by every RTSP client, for the bitrate shown next to the
/// stream count in the panel header. Fed from `RTSPClient`'s receive loop,
/// which runs on each client's own queue, hence the lock.
/// .NET counterpart: `StreamTraffic` (fed by the RTSPS tunnel).
final class StreamTraffic: @unchecked Sendable {
    static let shared = StreamTraffic()

    private let lock = NSLock()
    private var total: UInt64 = 0

    func add(_ bytes: Int) {
        lock.lock()
        total &+= UInt64(bytes)
        lock.unlock()
    }

    var totalBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// Turns a running byte total into a rate between two samples.
struct BitrateMeter {
    private var last: (bytes: UInt64, time: TimeInterval)?

    /// Bits per second since the previous sample, or nil for the first one, a
    /// clock that didn't advance, or a total that went backwards.
    mutating func sample(totalBytes: UInt64, at time: TimeInterval) -> Double? {
        defer { last = (totalBytes, time) }
        guard let last, time > last.time, totalBytes >= last.bytes else { return nil }
        return Double(totalBytes - last.bytes) * 8 / (time - last.time)
    }

    /// "850 kbps" below one megabit, "4.2 Mbps" above (decimal separator from
    /// `locale`). Units stay untranslated, as on the .NET side.
    static func format(bitsPerSecond: Double, locale: Locale = .current) -> String {
        if bitsPerSecond < 999_500 {
            let kbps = (bitsPerSecond / 1000).rounded()
            return kbps.formatted(.number.precision(.fractionLength(0)).grouping(.never).locale(locale)) + " kbps"
        }
        let mbps = bitsPerSecond / 1_000_000
        return mbps.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale)) + " Mbps"
    }
}
