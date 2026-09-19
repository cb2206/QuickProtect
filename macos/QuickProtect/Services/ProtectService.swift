import Foundation
import AppKit

/// Handles all communication with the UniFi Protect Integration API.
/// Main-actor isolated: its published state feeds SwiftUI, and the network
/// calls are `async` so awaiting URLSession never blocks the actor. Anything
/// that must run off the actor (the TLS challenge, fire-and-forget releases)
/// receives value snapshots.
@MainActor
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
    /// The configured controller's certificate changed and awaits the user's
    /// decision. Derived from the pin store (not from whichever request failed
    /// first), so it survives restarts and can't be lost to a race; the grid
    /// shows a dedicated card while it is set.
    @Published private(set) var certificateChange: CertificateTrust.Change?
    /// Set by AppDelegate when the popover opens/closes so cells can pause players.
    @Published var isPopoverOpen = false
    /// Remembers which camera was focused so it can be restored when the panel reopens.
    var lastFocusedCameraId: String?
    /// True while a camera is focused (single-camera view). Drives the popover
    /// header swap so the camera's own top bar replaces the grid header.
    @Published var isFocusMode = false

    private let settings: ProtectCredentialSource
    /// Extra `URLProtocol` classes registered on both sessions — tests install
    /// a stub controller here; the app passes none.
    private let urlProtocolClasses: [AnyClass]
    /// Answers the TLS server-trust challenge on URLSession's delegate queue.
    private let pinning = PinningSessionDelegate()
    /// Where `certificateChange` is read from. Tests pass a scratch store.
    private let certificateStore: CertificateTrust.Store

    /// `settings` defaults to the app's shared store; tests pass their own so
    /// the service never reads UserDefaults or the Keychain.
    init(settings: ProtectCredentialSource = AppSettings.shared, urlProtocolClasses: [AnyClass] = [],
         certificateStore: CertificateTrust.Store = CertificateTrust.Store()) {
        self.settings = settings
        self.urlProtocolClasses = urlProtocolClasses
        self.certificateStore = certificateStore
        super.init()
        // Selector-based, so the registration ends with the object.
        NotificationCenter.default.addObserver(self, selector: #selector(certificateTrustDidChange),
                                               name: CertificateTrust.didChangeNotification, object: nil)
        refreshCertificateChange()
    }

    /// Evaluations run on URLSession's and the RTSP clients' queues; hop to the
    /// main actor before touching published state.
    @objc nonisolated private func certificateTrustDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in self?.refreshCertificateChange() }
    }

    /// Re-reads the pending certificate for the configured controller. Also
    /// called when the controller address changes, since the pin key does.
    func refreshCertificateChange() {
        let change = controllerAddress.flatMap { certificateStore.change(host: $0.pinKey) }
        if change != certificateChange { certificateChange = change }
    }

    /// Promotes the pending certificate for `host` to the trusted pin, then
    /// reconnects: the camera list is fetched again and observers of
    /// `certificateChange` (pinned windows) restart their streams.
    func trustPendingCertificate(host: String) {
        certificateStore.trustPending(host: host)
        refreshCertificateChange()
        errorMessage = nil
        Task { await fetchCameras(forced: true) }
    }

    /// The configured controller, normalised (host, optional port, pin identity).
    var controllerAddress: ControllerAddress? { ControllerAddress.parse(settings.ipAddress) }

    static let certificateChangedMessage = String(localized: "The controller's certificate changed. Open Settings to review and trust it.")

    /// Percent-encodes a controller-supplied identifier for use as one URL path segment.
    static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Server-side allocations "<cameraId>:<quality>" held by the popover and
    /// by pinned windows. The controller shares one allocation per key between
    /// them, so the ledger only lets a DELETE through once neither side holds
    /// (or is creating) it. Used to release sessions when the panel closes, a
    /// pin closes or the app quits, so stale ones don't accumulate on the UDM.
    private let allocations = StreamAllocationLedger()

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
    /// The controller address and API key the in-flight fetch was started
    /// with, and the ones the current camera list came from.
    private var _fetchConnection: Connection?
    private var _camerasConnection: Connection?
    private var _lastFetchSucceededAt: Date?
    private var _lastPtzEnrich: ControllerRequestPolicy.PtzEnrichRecord?

    /// What identifies "the controller" for a fetch: a different address or
    /// API key may answer with different cameras (or not at all).
    private struct Connection: Equatable {
        let address: String
        let apiKey: String
    }

    private var connection: Connection { Connection(address: settings.ipAddress, apiKey: settings.apiKey) }

    /// Fetches the camera list, coalescing concurrent calls into one request
    /// chain (rapid panel toggles must not stack fetches against the
    /// controller's 10 req/s limit) and throttling automatic refreshes.
    /// `forced` — a user-initiated refresh or Test Connection — bypasses the
    /// throttle but still joins an in-flight fetch.
    func fetchCameras(forced: Bool = false) async {
        guard let (task, started) = joinOrStartFetch(forced: forced) else { return }
        await task.value
        if started { clearFetchTask(task) }
    }

    /// The controller address or API key changed. Clears the old controller's
    /// error, cancels a fetch still talking to it and fetches again; a fetch
    /// already running for the new connection (Test Connection) is joined, not
    /// restarted. The old controller's cameras are dropped rather than left on
    /// screen under the new address's result — re-applying the same
    /// connection keeps them.
    func refetchForNewConnection() async {
        let stale = forgetOldConnection()

        // The classic-API session belongs to the old controller; its cookie
        // must never be sent to another host.
        csrfToken = nil
        tokenCookie = nil
        isClassicLoggedIn = false
        errorMessage = nil
        // Settings are read after the change here (the change notification
        // itself arrives before the new value is stored), so this pin lookup
        // is for the new controller.
        refreshCertificateChange()

        // Checked after the stale fetch ends: it may still have applied the old
        // controller's cameras just before it saw the cancellation.
        await stale?.value
        if camerasConnection != connection, !cameras.isEmpty {
            cameras = []
        }
        await fetchCameras(forced: true)
    }

    /// Resets the throttles (their last successes were for the old
    /// controller) and cancels a fetch still running against it, returning
    /// that fetch so the caller can wait for it to end. Synchronous so the
    /// lock never spans a suspension point.
    private func forgetOldConnection() -> Task<Void, Never>? {
        fetchLock.lock(); defer { fetchLock.unlock() }
        _lastFetchSucceededAt = nil
        _lastPtzEnrich = nil
        guard let inFlight = _fetchTask, _fetchConnection != connection else { return nil }
        inFlight.cancel()
        _fetchTask = nil
        return inFlight
    }

    private var camerasConnection: Connection? {
        fetchLock.lock(); defer { fetchLock.unlock() }
        return _camerasConnection
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
        _fetchConnection = connection
        return (task, true)
    }

    /// Clears the in-flight slot if it still holds `task` — a connection
    /// change may already have replaced it with a fetch for the new controller.
    private func clearFetchTask(_ task: Task<Void, Never>) {
        fetchLock.lock(); defer { fetchLock.unlock() }
        if _fetchTask == task { _fetchTask = nil }
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
        let connection = self.connection
        guard await validate() else { RTSPClient.log("[API] validate failed"); return }
        await setLoading(true)

        do {
            let cameras = try await requestCameraList()
            markFetchSucceeded(connection: connection)
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
            // user should see; a rejected certificate looks the same to
            // URLSession, so the pin store decides (see classifyFetchFailure).
            await MainActor.run { self.refreshCertificateChange() }
            switch Self.classifyFetchFailure(error, taskCancelled: Task.isCancelled,
                                             certificateChanged: certificateChange != nil) {
            case .ignore:
                await setLoading(false)
            case .certificateChanged:
                await applyErrorMessage(Self.certificateChangedMessage, logging: error)
            case .failed:
                await applyErrorMessage(error.localizedDescription, logging: error)
            }
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

    private func markFetchSucceeded(connection: Connection) {
        fetchLock.lock(); defer { fetchLock.unlock() }
        _lastFetchSucceededAt = Date()
        _camerasConnection = connection
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
    /// `createRtspStreamURL` but the resulting server-side allocation is owned by
    /// the pinned side of the ledger, so closing the popover (`cleanupStreams()`)
    /// leaves the pinned feed running — even when the popover was watching the
    /// same camera at the same quality. The caller releases it with
    /// `releasePinnedStream`.
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

    /// Single POST attempt for one quality, bracketed in the ledger so a
    /// release racing it can't DELETE the allocation it is about to return.
    private func requestRtspStreamURL(for camera: Camera, quality: String,
                                      pinned: Bool = false) async -> StreamRequestOutcome {
        RTSPClient.log("[Stream] requestRtspStreamURL(\(quality)) for \(camera.name)")
        let key = StreamAllocationLedger.key(cameraId: camera.id, quality: quality)
        let owner: StreamAllocationLedger.Owner = pinned ? .pinned : .popover

        allocations.beginCreate(key)
        let (outcome, allocated) = await postRtspStream(for: camera, quality: quality)
        // Every exit of the POST lands here, so the in-flight mark always ends.
        // A release that arrived meanwhile was held back; it is due now if the
        // POST failed and nobody else holds the allocation.
        if allocations.endCreate(key, owner: owner, succeeded: allocated) {
            deleteRtspStream(for: camera.id, quality: quality)
        }

        // The requester went away while the POST was in flight (panel closed,
        // pin torn down). Give the allocation straight back — through the
        // ledger, so a pinned window holding or creating the same key keeps it.
        if allocated, Task.isCancelled {
            release(key, owner: owner)
            return .failed
        }
        return outcome
    }

    /// The POST itself. `allocated` is true when the controller answered with
    /// a URL for `quality`, i.e. an allocation now exists server-side.
    private func postRtspStream(for camera: Camera,
                                quality: String) async -> (outcome: StreamRequestOutcome, allocated: Bool) {
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(Self.pathSegment(camera.id))/rtsps-stream"
        ) else { RTSPClient.log("[Stream] makeURL failed"); return (.failed, false) }

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
            return (.failed, false)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            RTSPClient.log("[Stream] HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
            return (ControllerRequestPolicy.abortsQualityLadder(httpStatus: status)
                ? .failed : .qualityUnavailable, false)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rtspsString = json[quality] as? String else { return (.qualityUnavailable, false) }

        let playable = toPlayableURL(rtspsString)
        RTSPClient.log("[Stream] Created \(quality) for \(camera.name): \(playable.map(RTSPClient.redactedDescription(of:)) ?? "nil")")
        // An unusable URL still allocated server-side: keep it owned so cleanup frees it.
        guard let playable else { return (.qualityUnavailable, true) }
        return (.success(playable), true)
    }

    // MARK: - RTSP stream cleanup

    /// Releases every popover-owned allocation — except those a pinned window
    /// still holds or is creating. Call when the panel closes to prevent stale
    /// sessions accumulating on the UDM.
    func cleanupStreams() {
        releaseAll(owner: .popover)
    }

    /// Releases a single popover allocation (e.g. a doorbell's package lens
    /// when its picture-in-picture closes, or the quality a switch replaced).
    func releaseStream(for cameraId: String, quality: String) {
        release(StreamAllocationLedger.key(cameraId: cameraId, quality: quality), owner: .popover)
    }

    /// Releases a pinned floating window's allocation when it's unpinned or
    /// closed. `cleanupStreams()` never frees it; the popover sharing the same
    /// key keeps it alive until the popover lets go too.
    func releasePinnedStream(for cameraId: String, quality: String) {
        release(StreamAllocationLedger.key(cameraId: cameraId, quality: quality), owner: .pinned)
    }

    /// Releases every pinned allocation. Called on app termination so pinned
    /// windows don't leave sessions alive on the controller.
    func cleanupPinnedStreams() {
        releaseAll(owner: .pinned)
    }

    private func release(_ key: String, owner: StreamAllocationLedger.Owner) {
        guard allocations.release(key, owner: owner),
              let parsed = StreamAllocationLedger.parse(key) else { return }
        deleteRtspStream(for: parsed.cameraId, quality: parsed.quality)
    }

    private func releaseAll(owner: StreamAllocationLedger.Owner) {
        for key in allocations.releaseAll(owner: owner) {
            guard let parsed = StreamAllocationLedger.parse(key) else { continue }
            deleteRtspStream(for: parsed.cameraId, quality: parsed.quality)
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

        RTSPClient.log("[Stream] DELETE \(quality) for camera \(cameraId)")
        releaseGroup.enter()
        // Detached: an inherited main-actor context would make the quit-time
        // wait above deadlock on itself. Only Sendable values cross over.
        let session = tlsSession
        let group = releaseGroup
        Task.detached {
            defer { group.leave() }
            _ = try? await session.data(for: request)
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
    /// Debug-only (QUICKPROTECT_PROBE_CLASSIC=1): DESCRIBE each online camera's
    /// classic RTSPS alias stream for a few seconds so the debug log shows
    /// whether the controller serves video on that path (the alias itself is
    /// never logged — RTSPClient redacts URLs).
    private static var classicProbes: [RTSPClient] = []
    private func probeClassicStreams(_ cameras: [Camera]) async {
        guard let address = controllerAddress else { return }
        let targets = cameras.compactMap { cam -> (String, URL)? in
            guard cam.isOnline, let alias = cam.primaryRtspAlias,
                  let url = URL(string: "rtsps://\(address.authority.contains(":") ? address.host : address.host):7441/\(alias)")
            else { return nil }
            return (cam.name, url)
        }
        await MainActor.run {
            for (name, url) in targets {
                RTSPClient.log("[Probe] \(name): DESCRIBE classic alias stream")
                let client = RTSPClient()
                Self.classicProbes.append(client)
                client.connect(to: url, pinKey: address.pinKey)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                for client in Self.classicProbes { client.disconnect() }
                Self.classicProbes.removeAll()
                RTSPClient.log("[Probe] classic alias probes closed")
            }
        }
    }

    /// Debug-log only: per-camera channel configuration from the classic API
    /// (codec, resolution, enabled/RTSP flags) — what the controller can hand
    /// out over RTSP for each camera. No aliases or tokens are logged.
    private static func logChannelSummary(_ data: Data) {
        guard let cams = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        for cam in cams {
            let name = cam["name"] as? String ?? "?"
            let model = cam["type"] as? String ?? "?"
            let state = cam["state"] as? String ?? "?"
            let fw = cam["firmwareVersion"] as? String ?? "?"
            let codec = cam["videoCodec"] as? String ?? (cam["videoMode"] as? String ?? "-")
            let channels = (cam["channels"] as? [[String: Any]] ?? []).map { ch -> String in
                let id = ch["id"].map { "\($0)" } ?? "?"
                let n = ch["name"] as? String ?? "?"
                let en = (ch["enabled"] as? Bool).map { $0 ? "on" : "off" } ?? "?"
                let rtsp = (ch["isRtspEnabled"] as? Bool).map { $0 ? "rtsp" : "no-rtsp" } ?? "?"
                let w = ch["width"] as? Int ?? 0, h = ch["height"] as? Int ?? 0
                let fps = ch["fps"] as? Int ?? 0
                let vid = ch["videoId"] as? String ?? "-"
                return "\(id):\(n) \(en) \(rtsp) \(w)x\(h)@\(fps) \(vid)"
            }
            RTSPClient.log("[Cameras] \(name) type=\(model) state=\(state) fw=\(fw) codec=\(codec) channels=[\(channels.joined(separator: "; "))]")
            if ProcessInfo.processInfo.environment["QUICKPROTECT_PROBE_CLASSIC"] == "1" {
                // Full record with anything credential-like stripped (aliases,
                // tokens, keys, hosts, MACs), scalars only at the top level plus
                // the channel objects — for comparing a failing camera with a
                // working one.
                let secretish = ["alias", "token", "password", "secret", "host", "mac", "uuid", "apikey", "wifi"]
                let exact: Set<String> = ["id", "nvrMac", "ip", "connectionHost", "sshKey"]
                func clean(_ dict: [String: Any]) -> [String: Any] {
                    dict.filter { k, v in
                        !exact.contains(k) && !secretish.contains { k.lowercased().contains($0) }
                            && !(v is [Any]) && !(v is [String: Any])
                    }
                }
                let top = clean(cam)
                let chans = (cam["channels"] as? [[String: Any]] ?? []).map(clean)
                RTSPClient.log("[Cameras:full] \(name) \(top.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                for ch in chans {
                    RTSPClient.log("[Cameras:channel] \(name) \(ch.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                }
            }
        }
    }

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
        if RTSPClient.debugLoggingEnabled { Self.logChannelSummary(data) }
        if ProcessInfo.processInfo.environment["QUICKPROTECT_PROBE_CLASSIC"] == "1" {
            await probeClassicStreams(classicCameras)
        }

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
                    await MainActor.run { self.refreshCertificateChange() }
                    let message = certificateChange != nil
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

    /// How a failed camera fetch is reported.
    enum FetchFailure: Equatable {
        /// Torn down on purpose (panel closed) — leave the UI alone.
        case ignore
        /// The pin check rejected the controller's key.
        case certificateChanged
        /// Anything else: show the error's own description.
        case failed
    }

    /// A rejected certificate surfaces from URLSession as `URLError.cancelled`
    /// (the delegate cancels the challenge) — the same code a deliberate
    /// teardown produces. A pending certificate change therefore wins over the
    /// cancellation, unless the fetch task itself was cancelled.
    nonisolated static func classifyFetchFailure(_ error: Error, taskCancelled: Bool,
                                                 certificateChanged: Bool) -> FetchFailure {
        if taskCancelled || error is CancellationError { return .ignore }
        if certificateChanged { return .certificateChanged }
        if (error as? URLError)?.code == .cancelled { return .ignore }
        return .failed
    }

    private func applyErrorMessage(_ message: String, logging error: Error) async {
        RTSPClient.log("[API] applyError: \(error.localizedDescription)")
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
        // Every request passes through here, so the delegate always pins
        // against the currently configured controller identity.
        pinning.pinKey = address.pinKey
        return URL(string: "\(address.httpsBase)/\(path)")
    }

    /// Checks the configuration and publishes the reason it's unusable before
    /// returning, so a caller that awaits `fetchCameras` sees the error.
    private func validate() async -> Bool {
        let problem: String?
        if settings.ipAddress.isEmpty {
            problem = String(localized: "No IP address configured. Open Settings.")
        } else if settings.apiKey.isEmpty {
            problem = String(localized: "No API key configured. Open Settings.")
        } else {
            problem = nil
        }
        guard let problem else { return true }
        await MainActor.run { self.errorMessage = problem }
        return false
    }

    /// Integration API session — ephemeral config to avoid cookie pollution from classic API.
    private lazy var tlsSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        installURLProtocols(on: config)
        return URLSession(configuration: config, delegate: pinning, delegateQueue: nil)
    }()

    /// Classic API session — separate cookie jar for session-based auth (PTZ).
    /// No disk cache: package-snapshot JPEGs and camera JSON must not be
    /// persisted to the Caches folder by the shared URLCache.
    private lazy var classicSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        installURLProtocols(on: config)
        return URLSession(configuration: config, delegate: pinning, delegateQueue: nil)
    }()

    private func installURLProtocols(on config: URLSessionConfiguration) {
        guard !urlProtocolClasses.isEmpty else { return }
        config.protocolClasses = urlProtocolClasses + (config.protocolClasses ?? [])
    }

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

/// Answers server-trust challenges: system trust first, then pin the
/// controller's public key on first use and reject if it later changes
/// (possible MITM) — see CertificateTrust. Runs on URLSession's delegate
/// queue, so it is a small Sendable object with lock-guarded state rather
/// than the main-actor service. Never writes to the system trust store.
final class PinningSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _pinKey: String?

    /// The configured controller identity the pin is keyed by (so the RTSPS
    /// video channel consults the same one). Nil falls back to the server host.
    var pinKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return _pinKey }
        set { lock.lock(); _pinKey = newValue; lock.unlock() }
    }

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
        let serverHost = challenge.protectionSpace.host
        let key = pinKey ?? serverHost
        // A rejection records the new key as pending, which is what the
        // service reports (see `ProtectService.certificateChange`).
        if CertificateTrust.evaluate(pinKey: key, serverHost: serverHost, trust: trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// The credentials `ProtectService` needs — the subset of `AppSettings` it
/// reads, so tests can hand it plain values.
@MainActor
protocol ProtectCredentialSource: AnyObject {
    var ipAddress: String { get }
    var apiKey: String { get }
    var username: String { get }
    var password: String { get }
}

extension AppSettings: ProtectCredentialSource {}
