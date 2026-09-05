import Foundation
import AppKit

/// Handles all communication with the UniFi Protect Integration API.
final class ProtectService: NSObject, ObservableObject {

    @Published var cameras: [Camera] = []
    @Published var isLoading = false
    /// Controller reachability / API errors. The grid replaces itself with an
    /// error card while this is set, so it must only carry problems that make
    /// the camera list itself unusable.
    @Published var errorMessage: String?
    /// PTZ-only problems (classic-API login), surfaced as a toast on the
    /// focused camera — never in `errorMessage`, which would blank the grid.
    @Published var ptzErrorMessage: String?
    /// Set by AppDelegate when the popover opens/closes so cells can pause players.
    @Published var isPopoverOpen = false
    /// Remembers which camera was focused so it can be restored when the panel reopens.
    var lastFocusedCameraId: String?
    /// True while a camera is focused (single-camera view). Drives the popover
    /// header swap so the camera's own top bar replaces the grid header.
    @Published var isFocusMode = false

    private let settings = AppSettings.shared

    /// The configured controller, normalised (host, optional port, pin identity).
    var controllerAddress: ControllerAddress? { ControllerAddress.parse(settings.ipAddress) }

    /// Set by the URLSession delegate when it rejected the controller's
    /// certificate, so the failure that follows reports the real cause instead
    /// of the generic transport error. Read-and-cleared by `applyError`.
    private let certificateLock = NSLock()
    private var certificateRejected = false

    private func noteCertificateRejected() {
        certificateLock.lock(); defer { certificateLock.unlock() }
        certificateRejected = true
    }

    private func takeCertificateRejected() -> Bool {
        certificateLock.lock(); defer { certificateLock.unlock() }
        let value = certificateRejected
        certificateRejected = false
        return value
    }

    static let certificateChangedMessage = String(localized: "The controller's certificate changed. Open Settings to review and trust it.")

    /// Percent-encodes a controller-supplied identifier for use as one URL path segment.
    static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Guards `activeStreams` and `pinnedStreams`. They're mutated from the
    /// continuations of concurrent stream-start `Task`s, which resume on
    /// arbitrary cooperative-pool threads — without this lock two of them
    /// racing on the same `Set` corrupts its buffer and segfaults.
    private let streamsLock = NSLock()

    /// Active server-side RTSP stream allocations keyed as "<cameraId>:<quality>".
    /// Used to send DELETE requests on cleanup, preventing stale sessions from
    /// accumulating on the UDM when the panel is closed or the app quits. A
    /// camera can hold more than one (e.g. a doorbell's main + package lens).
    /// Access only via the `streamsLock`-guarded helpers below.
    private var activeStreams: Set<String> = []

    /// Server-side allocations held by pinned floating windows, tracked
    /// separately from `activeStreams` so the popover's `cleanupStreams()` never
    /// tears down a pinned window's feed. Released individually on unpin/close
    /// and en masse by `cleanupPinnedStreams()` on app termination.
    /// Access only via the `streamsLock`-guarded helpers below.
    private var pinnedStreams: Set<String> = []

    private func streamKey(_ cameraId: String, _ quality: String) -> String {
        "\(cameraId):\(quality)"
    }

    /// Records a freshly created allocation. `pinned` routes it to the set that
    /// survives `cleanupStreams()`.
    private func trackStream(_ key: String, pinned: Bool) {
        streamsLock.lock(); defer { streamsLock.unlock() }
        if pinned { pinnedStreams.insert(key) } else { activeStreams.insert(key) }
    }

    /// Atomically removes one active allocation; returns `true` if it was present.
    private func removeActiveStream(_ key: String) -> Bool {
        streamsLock.lock(); defer { streamsLock.unlock() }
        return activeStreams.remove(key) != nil
    }

    /// Atomically removes one pinned allocation; returns `true` if it was present.
    private func removePinnedStream(_ key: String) -> Bool {
        streamsLock.lock(); defer { streamsLock.unlock() }
        return pinnedStreams.remove(key) != nil
    }

    /// Atomically snapshots and clears the active set, so cleanup can iterate the
    /// keys without holding the lock across the DELETE requests.
    private func drainActiveStreams() -> Set<String> {
        streamsLock.lock(); defer { streamsLock.unlock() }
        let keys = activeStreams
        activeStreams.removeAll()
        return keys
    }

    /// Atomically snapshots and clears the pinned set.
    private func drainPinnedStreams() -> Set<String> {
        streamsLock.lock(); defer { streamsLock.unlock() }
        let keys = pinnedStreams
        pinnedStreams.removeAll()
        return keys
    }

    /// Guards the classic-API credential fields below, which are read and written
    /// from concurrent PTZ `Task`s and the fetch path.
    private let credLock = NSLock()
    private var _csrfToken: String?
    private var _tokenCookie: String?

    /// CSRF token captured from classic API login response. Required for POST/PUT/DELETE
    /// requests to the classic API (used for PTZ control).
    private var csrfToken: String? {
        get { credLock.lock(); defer { credLock.unlock() }; return _csrfToken }
        set { credLock.lock(); _csrfToken = newValue; credLock.unlock() }
    }
    /// TOKEN cookie captured from classic API login response. Manually set on requests
    /// because a fresh HTTPCookieStorage instance may not auto-accept cookies.
    private var tokenCookie: String? {
        get { credLock.lock(); defer { credLock.unlock() }; return _tokenCookie }
        set { credLock.lock(); _tokenCookie = newValue; credLock.unlock() }
    }
    /// Whether the classic API login succeeded. Drives the PTZ connection status
    /// pill in Settings. Updated on the main actor since it's observed by SwiftUI.
    @Published private(set) var isClassicLoggedIn = false

    // MARK: - Fetch camera list

    /// Guards the fetch-coalescing state below, which is touched from arbitrary
    /// caller contexts (status-bar toggle, refresh buttons, Settings).
    private let fetchLock = NSLock()
    private var _fetchTask: Task<Void, Never>?
    private var _lastFetchSucceededAt: Date?
    private var _lastPtzEnrich: ControllerRequestPolicy.PtzEnrichRecord?

    /// Fetches the camera list, coalescing concurrent calls into one request
    /// chain (rapid panel toggles must not stack fetches against the
    /// controller's 10 req/s limit) and throttling automatic refreshes.
    /// `forced` — a user-initiated refresh or Test Connection — bypasses the
    /// throttle but still joins an in-flight fetch.
    func fetchCameras(forced: Bool = false) async {
        guard let (task, started) = joinOrStartFetch(forced: forced) else { return }
        await task.value
        if started { clearFetchTask() }
    }

    /// Atomically joins the in-flight fetch or starts a new one; `nil` when the
    /// throttle says the current list is fresh enough. Synchronous so the lock
    /// never spans a suspension point.
    private func joinOrStartFetch(forced: Bool) -> (task: Task<Void, Never>, started: Bool)? {
        fetchLock.lock(); defer { fetchLock.unlock() }
        if let existing = _fetchTask { return (existing, false) }
        if !forced, ControllerRequestPolicy.shouldSkipFetch(
            lastSuccess: _lastFetchSucceededAt, now: Date()) {
            return nil
        }
        let task = Task { await self.performFetch(forced: forced) }
        _fetchTask = task
        return (task, true)
    }

    private func clearFetchTask() {
        fetchLock.lock(); defer { fetchLock.unlock() }
        _fetchTask = nil
    }

    /// Cancels an in-flight camera fetch. Called by the deferred stream
    /// teardown after the panel closes — a fetch that dies here must not
    /// surface an error card (see the cancellation check in `performFetch`).
    func cancelFetch() {
        fetchLock.lock(); defer { fetchLock.unlock() }
        _fetchTask?.cancel()
    }

    private func performFetch(forced: Bool) async {
        RTSPClient.log("[API] fetchCameras called")
        guard validate() else { RTSPClient.log("[API] validate failed"); return }
        await setLoading(true)

        do {
            let cameras = try await requestCameraList()
            markFetchSucceeded()
            await applySuccess(cameras)

            // If classic API credentials are configured, enrich PTZ flags.
            // Only a successful enrichment arms the throttle — a transient
            // failure (e.g. a 429 in the panel-open burst) must not silence
            // PTZ enrichment for the whole throttle window.
            if !settings.username.isEmpty && !settings.password.isEmpty,
               forced || !shouldSkipPtzEnrich() {
                if await enrichPtzFlags() {
                    markPtzEnriched()
                }
            }
        } catch {
            // A fetch cancelled by the deferred teardown isn't a failure the
            // user should see — leave the camera list and error state alone.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                await setLoading(false)
                return
            }
            await applyError(error)
        }
    }

    /// One camera-list request, retried once after the limiter's 1-second
    /// window when the controller answers 429 — a rapid panel toggle should
    /// recover silently rather than surface a rate-limit error card.
    private func requestCameraList() async throws -> [Camera] {
        do {
            return try await requestCameraListOnce()
        } catch APIError.http(429, _) {
            RTSPClient.log("[API] 429 — retrying after limiter window")
            try await Task.sleep(nanoseconds: 1_100_000_000)
            return try await requestCameraListOnce()
        }
    }

    private func requestCameraListOnce() async throws -> [Camera] {
        // Integration API camera list — works with X-API-Key, returns id/name/state.
        // RTSP URLs are created on-demand via POST rtsps-stream, not stored here.
        guard let url = makeURL(path: "proxy/protect/integration/v1/cameras") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await tlsSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidURL }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // Integration API wraps the array: { "data": [...] }
        struct Wrapped: Decodable { let data: [Camera] }
        if let w = try? JSONDecoder().decode(Wrapped.self, from: data) {
            return w.data
        }
        return try JSONDecoder().decode([Camera].self, from: data)
    }

    private func markFetchSucceeded() {
        fetchLock.lock(); defer { fetchLock.unlock() }
        _lastFetchSucceededAt = Date()
    }

    private func shouldSkipPtzEnrich() -> Bool {
        fetchLock.lock(); defer { fetchLock.unlock() }
        return ControllerRequestPolicy.shouldSkipPtzEnrich(
            last: _lastPtzEnrich,
            username: settings.username,
            password: settings.password,
            now: Date())
    }

    private func markPtzEnriched() {
        fetchLock.lock(); defer { fetchLock.unlock() }
        _lastPtzEnrich = ControllerRequestPolicy.PtzEnrichRecord(
            at: Date(), username: settings.username, password: settings.password)
    }

    // MARK: - RTSP stream creation (Integration API)

    /// Creates an on-demand RTSP stream, degrading through the remaining quality
    /// tiers if the requested one isn't available on this camera, so a sensor
    /// that doesn't expose every substream still plays. Returns the playable URL
    /// together with the quality that actually succeeded — the caller tracks that
    /// for `releaseStream(for:quality:)`. `nil` only if every tier fails.
    func createRtspStreamURL(for camera: Camera,
                             quality: String = "medium") async -> (url: URL, quality: String)? {
        for tier in Self.qualityFallbackLadder(from: quality) {
            switch await requestRtspStreamURL(for: camera, quality: tier) {
            case .success(let url):
                if tier != quality {
                    RTSPClient.log("[Stream] \(quality) unavailable for \(camera.name); using \(tier)")
                }
                return (url, tier)
            case .qualityUnavailable:
                continue
            case .failed:
                return nil
            }
        }
        return nil
    }

    /// Stream-URL creation for a pinned floating window. Identical to
    /// `createRtspStreamURL` but the resulting server-side allocation is tracked
    /// in `pinnedStreams`, so closing the popover (`cleanupStreams()`) leaves the
    /// pinned feed running. The caller releases it with `releasePinnedStream`.
    func createPinnedStreamURL(for camera: Camera,
                               quality: String = "high") async -> (url: URL, quality: String)? {
        for tier in Self.qualityFallbackLadder(from: quality) {
            switch await requestRtspStreamURL(for: camera, quality: tier, pinned: true) {
            case .success(let url):
                if tier != quality {
                    RTSPClient.log("[Stream] pinned \(quality) unavailable for \(camera.name); using \(tier)")
                }
                return (url, tier)
            case .qualityUnavailable:
                continue
            case .failed:
                return nil
            }
        }
        return nil
    }

    /// Quality tiers to try, in order. The high/medium/low tiers fall through to
    /// the others so a missing substream degrades gracefully; any other quality
    /// (e.g. "package", a distinct lens rather than a level) is tried alone so a
    /// secondary lens never silently becomes the main feed.
    private static func qualityFallbackLadder(from quality: String) -> [String] {
        switch quality {
        case "high":   return ["high", "medium", "low"]
        case "medium": return ["medium", "low", "high"]
        case "low":    return ["low", "medium", "high"]
        default:       return [quality]
        }
    }

    /// Result of one stream-creation POST, so the quality-fallback ladder can
    /// tell "this camera doesn't offer that quality" (try the next tier) from
    /// rate-limiting or an unreachable controller (abort the ladder — see
    /// `ControllerRequestPolicy.abortsQualityLadder`).
    private enum StreamRequestOutcome {
        case success(URL)
        case qualityUnavailable
        case failed
    }

    /// Single POST attempt for one quality.
    private func requestRtspStreamURL(for camera: Camera, quality: String,
                                      pinned: Bool = false) async -> StreamRequestOutcome {
        RTSPClient.log("[Stream] requestRtspStreamURL(\(quality)) for \(camera.name)")
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(Self.pathSegment(camera.id))/rtsps-stream"
        ) else { RTSPClient.log("[Stream] makeURL failed"); return .failed }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["qualities": [quality]]
        )

        guard let (data, resp) = try? await tlsSession.data(for: request) else {
            RTSPClient.log("[Stream] HTTP request failed (no response)")
            return .failed
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            RTSPClient.log("[Stream] HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
            return ControllerRequestPolicy.abortsQualityLadder(httpStatus: status)
                ? .failed : .qualityUnavailable
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rtspsString = json[quality] as? String else { return .qualityUnavailable }

        // The panel may have closed while the POST was in flight. cleanupStreams()
        // has already drained the tracking set by now, so recording the allocation
        // would leak it server-side — release it instead.
        guard !Task.isCancelled else {
            deleteRtspStream(for: camera.id, quality: quality)
            return .failed
        }

        trackStream(streamKey(camera.id, quality), pinned: pinned)
        let playable = toPlayableURL(rtspsString)
        RTSPClient.log("[Stream] Created \(quality) for \(camera.name): \(playable.map(RTSPClient.redactedDescription(of:)) ?? "nil")")
        guard let playable else { return .qualityUnavailable }
        return .success(playable)
    }

    // MARK: - RTSP stream cleanup

    /// Sends DELETE requests for all server-side stream allocations.
    /// Call when the panel closes to prevent stale sessions accumulating on the UDM.
    func cleanupStreams() {
        let keys = drainActiveStreams()
        for key in keys {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            deleteRtspStream(for: String(parts[0]), quality: String(parts[1]))
        }
    }

    /// Releases a single secondary allocation (e.g. a doorbell's package lens)
    /// when its picture-in-picture closes, without tearing down the main stream.
    func releaseStream(for cameraId: String, quality: String) {
        guard removeActiveStream(streamKey(cameraId, quality)) else { return }
        deleteRtspStream(for: cameraId, quality: quality)
    }

    /// Releases a pinned floating window's server-side allocation when it's
    /// unpinned or closed. Tracked apart from `activeStreams`, so this is the
    /// only path that frees it (never `cleanupStreams()`).
    func releasePinnedStream(for cameraId: String, quality: String) {
        guard removePinnedStream(streamKey(cameraId, quality)) else { return }
        deleteRtspStream(for: cameraId, quality: quality)
    }

    /// DELETEs every pinned allocation. Called on app termination so pinned
    /// windows don't leave sessions alive on the controller.
    func cleanupPinnedStreams() {
        let keys = drainPinnedStreams()
        for key in keys {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            deleteRtspStream(for: String(parts[0]), quality: String(parts[1]))
        }
    }

    /// In-flight allocation releases, so quit can wait (briefly) for them to
    /// reach the controller instead of spinning the run loop and hoping.
    private let releaseGroup = DispatchGroup()

    /// Blocks the caller for up to `timeout` while pending stream releases
    /// complete. Quit-time only: the releases run detached from any actor, so
    /// waiting on the main thread cannot deadlock them.
    func waitForStreamReleases(timeout: TimeInterval) {
        _ = releaseGroup.wait(timeout: .now() + timeout)
    }

    /// Fire-and-forget DELETE to release a server-side RTSP stream allocation.
    /// The API requires the `qualities` query parameter matching what was created.
    private func deleteRtspStream(for cameraId: String, quality: String) {
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(Self.pathSegment(cameraId))/rtsps-stream?qualities=\(quality)"
        ) else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")

        releaseGroup.enter()
        // Detached: an inherited main-actor context would make the quit-time
        // wait above deadlock on itself.
        Task.detached { [self] in
            defer { releaseGroup.leave() }
            _ = try? await tlsSession.data(for: request)
        }
    }

    // MARK: - Classic API (cookie auth — required for PTZ control)

    /// Logs in to the classic API with username/password.
    /// The Integration API (X-API-Key) does NOT support relative PTZ or expose isPtz flags,
    /// so we need the classic API for PTZ features.
    @discardableResult
    func classicLogin() async -> Bool {
        guard !settings.username.isEmpty, !settings.password.isEmpty else { return false }
        guard let url = makeURL(path: "api/auth/login") else { return false }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["username": settings.username, "password": settings.password]
        )

        RTSPClient.log("[PTZ] classicLogin attempting...")
        guard let (_, resp) = try? await classicSession.data(for: request),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            RTSPClient.log("[PTZ] classicLogin FAILED")
            await setClassicLoggedIn(false)
            csrfToken = nil
            tokenCookie = nil
            return false
        }

        // Capture CSRF token from response header — required for subsequent POST requests
        csrfToken = http.value(forHTTPHeaderField: "X-CSRF-Token")

        // Manually extract TOKEN cookie from Set-Cookie headers.
        // A fresh HTTPCookieStorage() instance may not auto-accept cookies,
        // so we store the token and set it explicitly on subsequent requests.
        tokenCookie = nil
        if let headerFields = http.allHeaderFields as? [String: String],
           let responseURL = http.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: responseURL)
            tokenCookie = cookies.first(where: { $0.name == "TOKEN" })?.value
        }

        await setClassicLoggedIn(true)
        // Don't log credential material — just whether each token was obtained.
        RTSPClient.log("[PTZ] classicLogin OK, csrf=\(csrfToken != nil), token=\(tokenCookie != nil)")
        return true
    }

    /// Fetches camera list from classic API and merges isPtz flags into existing cameras.
    /// Returns `true` only when flags were actually applied, so the caller can
    /// arm the enrichment throttle on success alone.
    private func enrichPtzFlags() async -> Bool {
        guard await classicLogin() else {
            RTSPClient.log("[PTZ] enrich failed: classic login failed")
            return false
        }
        guard let url = makeURL(path: "proxy/protect/api/cameras") else { return false }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Manually set TOKEN cookie — HTTPCookieStorage() may not auto-forward it
        if let token = tokenCookie {
            request.setValue("TOKEN=\(token)", forHTTPHeaderField: "Cookie")
        }

        let data: Data
        do {
            let (body, resp) = try await classicSession.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                RTSPClient.log("[PTZ] enrich failed: HTTP \(status)")
                return false
            }
            data = body
        } catch {
            RTSPClient.log("[PTZ] enrich failed: \(error.localizedDescription)")
            return false
        }

        // Classic API returns a plain array (not wrapped in {data: [...]})
        let classicCameras = (try? JSONDecoder().decode([Camera].self, from: data)) ?? []

        // Only apply flags when we actually got a camera list back. A transient
        // empty/failed response must not wipe previously-known PTZ flags; but when
        // the list is present it is authoritative (a camera that lost PTZ is cleared).
        guard !classicCameras.isEmpty else {
            RTSPClient.log("[PTZ] enrich failed: empty or undecodable camera list")
            return false
        }
        let ptzIds = Set(classicCameras.filter(\.isPtz).map(\.id))
        let zoomIds = Set(classicCameras.filter(\.canZoom).map(\.id))

        await MainActor.run {
            self.cameras = self.cameras.map { cam in
                var c = cam
                c.isPtz = ptzIds.contains(cam.id)
                c.canZoom = zoomIds.contains(cam.id)
                return c
            }
        }
        return true
    }

    // MARK: - Package snapshot (classic API)

    /// Fetches a JPEG snapshot of a camera's package lens. The package stream
    /// runs at 2 fps, so a client joining it mid-GOP waits many seconds for the
    /// first keyframe — the views bridge that gap with this snapshot. Classic
    /// API only: the Integration API has no package-snapshot endpoint.
    func fetchPackageSnapshot(for camera: Camera) async -> CGImage? {
        guard camera.secondaryLens != nil else { return nil }
        if tokenCookie == nil {
            guard await classicLogin() else { return nil }
        }
        let first = await requestPackageSnapshot(for: camera)
        if let image = first.image { return image }
        // Expired session (token timeout, controller restart): one fresh login,
        // one retry. Other failures just return nil — a login wouldn't help,
        // and every login is audit-logged on the controller.
        guard first.unauthorized, await classicLogin() else { return nil }
        return await requestPackageSnapshot(for: camera).image
    }

    private func requestPackageSnapshot(for camera: Camera) async -> (image: CGImage?, unauthorized: Bool) {
        let ts = Int(Date().timeIntervalSince1970 * 1000)   // cache-buster: always a fresh capture
        guard let url = makeURL(path: "proxy/protect/api/cameras/\(Self.pathSegment(camera.id))/package-snapshot?ts=\(ts)") else {
            return (nil, false)
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        // Manually set TOKEN cookie — HTTPCookieStorage() may not auto-forward it
        if let token = tokenCookie {
            request.setValue("TOKEN=\(token)", forHTTPHeaderField: "Cookie")
        }
        let data: Data
        let status: Int
        do {
            let (body, resp) = try await classicSession.data(for: request)
            status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            data = body
        } catch {
            RTSPClient.log("[Snapshot] package-snapshot request failed: \(error.localizedDescription)")
            return (nil, false)
        }
        guard (200...299).contains(status) else {
            RTSPClient.log("[Snapshot] package-snapshot HTTP \(status)")
            return (nil, status == 401 || status == 403)
        }
        guard let image = NSBitmapImageRep(data: data)?.cgImage else {
            RTSPClient.log("[Snapshot] package-snapshot undecodable (\(data.count) bytes)")
            return (nil, false)
        }
        return (image, false)
    }

    // MARK: - PTZ control (classic API — continuous velocity moves)

    /// Commanded velocity per axis on the controller's ±1000 scale. One
    /// continuous-move command carries all three axes, so they run in
    /// parallel; all zeros stops the motion. Mutated only inside the serial
    /// send chain.
    private struct PtzVelocity: Equatable {
        var x = 0.0
        var y = 0.0
        var z = 0.0
    }

    private enum PtzAxis: Hashable { case pan, tilt, zoom }

    private var ptzDesired = PtzVelocity()
    private var ptzAxisStartedAt: [PtzAxis: Date] = [:]
    /// Serializes move commands so they reach the controller in call order
    /// (an earlier send may still be waiting on login or a tap's minimum burst).
    private var ptzSendChain: Task<Void, Never>?

    /// Full speed on the ±1000 velocity scale.
    private static let ptzVelocityScale = 1000.0
    /// Minimum travel time for a quick tap before its stop goes out.
    private static let ptzMinBurst: TimeInterval = 0.25

    /// Sets the direction (−1, 0, +1) of the given axes; axes passed as nil
    /// keep their current velocity, so pan, tilt, and zoom can run in
    /// parallel. Pass 0 on key-up to stop a single axis.
    func ptzSetAxes(cameraId: String, pan: Double? = nil, tilt: Double? = nil, zoom: Double? = nil) {
        RTSPClient.log("[PTZ] setAxes pan=\(pan?.description ?? "·") tilt=\(tilt?.description ?? "·") zoom=\(zoom?.description ?? "·")")

        // A quick tap should still produce meaningful travel: when an axis is
        // released early, postpone the command until its minimum burst is up.
        var delay: TimeInterval = 0
        for (axis, direction) in [(PtzAxis.pan, pan), (.tilt, tilt), (.zoom, zoom)] {
            guard let direction else { continue }
            if direction == 0 {
                if let started = ptzAxisStartedAt[axis] {
                    delay = max(delay, Self.ptzMinBurst - Date().timeIntervalSince(started))
                }
                ptzAxisStartedAt[axis] = nil
            } else {
                ptzAxisStartedAt[axis] = Date()
            }
        }

        enqueuePtzSend(cameraId: cameraId, delay: max(0, delay)) { state in
            if let pan { state.x = pan * Self.ptzVelocityScale }
            if let tilt { state.y = tilt * Self.ptzVelocityScale }
            if let zoom { state.z = zoom * Self.ptzVelocityScale }
        }
    }

    /// Stops all PTZ motion (focus exit and other cleanup paths). Cheap when
    /// nothing is moving — unchanged state is never sent.
    func ptzStopAll(cameraId: String) {
        ptzAxisStartedAt = [:]
        enqueuePtzSend(cameraId: cameraId, delay: 0) { $0 = PtzVelocity() }
    }

    /// Applies `mutate` to the desired velocities and sends the resulting
    /// continuous-move command. Commands are chained so they reach the
    /// controller in call order; `delay` postpones the send within the chain.
    private func enqueuePtzSend(cameraId: String, delay: TimeInterval,
                                mutate: @escaping (inout PtzVelocity) -> Void) {
        let previous = ptzSendChain
        ptzSendChain = Task {
            await previous?.value
            if delay > 0 {
                // Only ends early on cancellation, which this chain never does.
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if !isClassicLoggedIn {
                guard await classicLogin() else {
                    let message = takeCertificateRejected()
                        ? Self.certificateChangedMessage
                        : String(localized: "PTZ unavailable — check the username and password in Settings.")
                    await MainActor.run { self.ptzErrorMessage = message }
                    return
                }
            }
            var state = ptzDesired
            mutate(&state)
            guard state != ptzDesired else { return }
            ptzDesired = state
            await sendMove(cameraId: cameraId, body: [
                "type": "continuous",
                "payload": ["x": Int(state.x), "y": Int(state.y), "z": Int(state.z)]
            ])
        }
    }

    private func sendMove(cameraId: String, body: [String: Any]) async {
        guard let url = makeURL(
            path: "proxy/protect/api/cameras/\(Self.pathSegment(cameraId))/move"
        ) else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let csrf = csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
        // Manually set TOKEN cookie — HTTPCookieStorage() may not auto-forward it
        if let token = tokenCookie {
            request.setValue("TOKEN=\(token)", forHTTPHeaderField: "Cookie")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let result = try? await classicSession.data(for: request)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? -1
        let respBody = result.flatMap { String(data: $0.0, encoding: .utf8) } ?? "nil"
        RTSPClient.log("[PTZ] sendMove HTTP \(status): \(respBody.prefix(200))")
        if status == 401 {
            await setClassicLoggedIn(false)
            csrfToken = nil
            tokenCookie = nil
        }
    }

    /// Updates the observed login flag on the main actor (SwiftUI requirement).
    private func setClassicLoggedIn(_ value: Bool) async {
        await MainActor.run { self.isClassicLoggedIn = value }
    }

    /// Returns the rtsps:// URL with ?enableSrtp stripped.
    /// The session token from rtsps-stream is only valid on rtsps://ip:7441/ —
    /// converting to rtsp://ip:7447/ points to a path that doesn't exist on that port.
    private func toPlayableURL(_ rtspsString: String) -> URL? {
        guard var components = URLComponents(string: rtspsString) else { return nil }
        // Strip ?enableSrtp — AVFoundation handles SRTP via TLS automatically
        components.queryItems = components.queryItems?.filter { $0.name != "enableSrtp" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    // MARK: - Private helpers

    private func applySuccess(_ cameras: [Camera]) async {
        RTSPClient.log("[API] applySuccess: \(cameras.count) cameras")
        await MainActor.run {
            // Integration-API payloads carry no PTZ flags; keep what the
            // classic-API enrichment already established (it may be throttled
            // and not run again for minutes).
            self.cameras = Camera.preservingEnrichmentFlags(from: self.cameras, into: cameras)
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func applyError(_ error: Error) async {
        RTSPClient.log("[API] applyError: \(error.localizedDescription)")
        let message = takeCertificateRejected() ? Self.certificateChangedMessage : error.localizedDescription
        await MainActor.run {
            self.errorMessage = message
            self.isLoading = false
        }
    }

    private func setLoading(_ value: Bool) async {
        await MainActor.run { self.isLoading = value }
    }

    func makeURL(path: String) -> URL? {
        guard let address = controllerAddress else { return nil }
        return URL(string: "\(address.httpsBase)/\(path)")
    }

    private func validate() -> Bool {
        if settings.ipAddress.isEmpty {
            Task { await MainActor.run { self.errorMessage = String(localized: "No IP address configured. Open Settings.") } }
            return false
        }
        if settings.apiKey.isEmpty {
            Task { await MainActor.run { self.errorMessage = String(localized: "No API key configured. Open Settings.") } }
            return false
        }
        return true
    }

    /// Integration API session — ephemeral config to avoid cookie pollution from classic API.
    private lazy var tlsSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }()

    /// Classic API session — separate cookie jar for session-based auth (PTZ).
    /// No disk cache: package-snapshot JPEGs and camera JSON must not be
    /// persisted to the Caches folder by the shared URLCache.
    private lazy var classicSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    enum APIError: LocalizedError {
        case invalidURL
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:            return String(localized: "Invalid IP address or URL.")
            case .http(let c, let body): return "HTTP \(c) – \(body.prefix(200))"
            }
        }
    }
}

// MARK: - URLSessionDelegate (trust-on-first-use pinning for the self-signed controller cert)

extension ProtectService: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // System trust first, then pin the controller's public key on first use
        // and reject if it later changes (possible MITM) — see CertificateTrust.
        // The pin is keyed by the configured controller identity so the RTSPS
        // video channel consults the same one. Never writes to the system trust store.
        let serverHost = challenge.protectionSpace.host
        let pinKey = controllerAddress?.pinKey ?? serverHost
        if CertificateTrust.evaluate(pinKey: pinKey, serverHost: serverHost, trust: trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            noteCertificateRejected()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
