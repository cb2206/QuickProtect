import Foundation

/// Decides when a server-side RTSP stream allocation may be released.
///
/// The controller keeps one allocation per camera and quality ("<cameraId>:<quality>")
/// and a DELETE removes it for every consumer: the popover and a pinned window
/// watching the same camera at the same quality share it. Releasing it while
/// the other side still holds it — or is still creating it — kills that side's
/// URL, and a client that connects to a deleted URL never plays. So a DELETE
/// is only due when nobody owns the key and no creation for it is in flight; a
/// release that finds a creation in flight is deferred until that creation
/// ends and sent then only if it failed.
///
/// Thread-safe: stream-start `Task` continuations can resume on arbitrary
/// cooperative-pool threads, and two of them racing on an unguarded `Set`
/// corrupts its buffer.
final class StreamAllocationLedger: @unchecked Sendable {

    /// Who holds an allocation.
    enum Owner: Sendable {
        /// The popover's grid, focus view and secondary-lens PiP.
        case popover
        /// A pinned floating window.
        case pinned
    }

    private let lock = NSLock()
    private var popover: Set<String> = []   // guarded by `lock`
    private var pinned: Set<String> = []    // guarded by `lock`
    private var creating: [String: Int] = [:] // guarded by `lock`
    private var deferred: Set<String> = []  // guarded by `lock`

    static func key(cameraId: String, quality: String) -> String {
        "\(cameraId):\(quality)"
    }

    /// Splits a key back into camera id and quality (camera ids never contain ":").
    static func parse(_ key: String) -> (cameraId: String, quality: String)? {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// A creation POST for `key` is about to be sent.
    func beginCreate(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        creating[key, default: 0] += 1
    }

    /// A creation POST for `key` finished. Returns `true` when a release
    /// deferred during the creation is now due (the creation failed and nobody
    /// else holds the allocation).
    func endCreate(_ key: String, owner: Owner, succeeded: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let n = creating[key], n > 1 { creating[key] = n - 1 } else { creating[key] = nil }

        if succeeded {
            insert(key, for: owner)
            // The new owner holds the allocation now; its own release deletes it.
            deferred.remove(key)
            return false
        }
        return takeDeferredIfUnheld(key)
    }

    /// `owner` gives up `key`. Returns `true` when the DELETE should be sent
    /// now; `false` when the owner didn't hold it or the allocation is still
    /// needed.
    func release(_ key: String, owner: Owner) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remove(key, for: owner) else { return false }
        return dueNow(key)
    }

    /// `owner` gives up everything it holds. Returns the keys whose DELETE
    /// should be sent now, sorted for a deterministic order.
    func releaseAll(owner: Owner) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let keys: Set<String>
        switch owner {
        case .popover: keys = popover; popover.removeAll()
        case .pinned:  keys = pinned; pinned.removeAll()
        }
        return keys.sorted().filter(dueNow)
    }

    // MARK: - Private (caller holds `lock`)

    private func insert(_ key: String, for owner: Owner) {
        switch owner {
        case .popover: popover.insert(key)
        case .pinned:  pinned.insert(key)
        }
    }

    private func remove(_ key: String, for owner: Owner) -> Bool {
        switch owner {
        case .popover: return popover.remove(key) != nil
        case .pinned:  return pinned.remove(key) != nil
        }
    }

    private func dueNow(_ key: String) -> Bool {
        if popover.contains(key) || pinned.contains(key) { return false }
        if creating[key] != nil {
            deferred.insert(key)
            return false
        }
        return true
    }

    private func takeDeferredIfUnheld(_ key: String) -> Bool {
        if creating[key] != nil || popover.contains(key) || pinned.contains(key) { return false }
        return deferred.remove(key) != nil
    }
}
