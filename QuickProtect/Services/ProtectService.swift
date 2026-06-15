import Foundation
import AppKit

/// Handles all communication with the UniFi Protect Integration API.
final class ProtectService: NSObject, ObservableObject {

    @Published var cameras: [Camera] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set by AppDelegate when the popover opens/closes so cells can pause players.
    @Published var isPopoverOpen = false
    /// Remembers which camera was focused so it can be restored when the panel reopens.
    var lastFocusedCameraId: String?
    /// True while a camera is focused (single-camera view). Drives the popover
    /// header swap so the camera's own top bar replaces the grid header.
    @Published var isFocusMode = false

    private let settings = AppSettings.shared

    /// Active server-side RTSP stream allocations keyed as "<cameraId>:<quality>".
    /// Used to send DELETE requests on cleanup, preventing stale sessions from
    /// accumulating on the UDM when the panel is closed or the app quits. A
    /// camera can hold more than one (e.g. a doorbell's main + package lens).
    private var activeStreams: Set<String> = []

    private func streamKey(_ cameraId: String, _ quality: String) -> String {
        "\(cameraId):\(quality)"
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

    func fetchCameras() async {
        RTSPClient.log("[API] fetchCameras called")
        guard validate() else { RTSPClient.log("[API] validate failed"); return }
        await setLoading(true)

        do {
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
            let cameras: [Camera]
            if let w = try? JSONDecoder().decode(Wrapped.self, from: data) {
                cameras = w.data
            } else {
                cameras = try JSONDecoder().decode([Camera].self, from: data)
            }
            await applySuccess(cameras)

            // If classic API credentials are configured, enrich PTZ flags
            if !settings.username.isEmpty && !settings.password.isEmpty {
                await enrichPtzFlags()
            }
        } catch {
            await applyError(error)
        }
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
            if let url = await requestRtspStreamURL(for: camera, quality: tier) {
                if tier != quality {
                    RTSPClient.log("[Stream] \(quality) unavailable for \(camera.name); using \(tier)")
                }
                return (url, tier)
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

    /// Single POST attempt for one quality. Returns the playable URL, or `nil` if
    /// the endpoint errors or doesn't offer that quality.
    private func requestRtspStreamURL(for camera: Camera, quality: String) async -> URL? {
        RTSPClient.log("[Stream] requestRtspStreamURL(\(quality)) for \(camera.name)")
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(camera.id)/rtsps-stream"
        ) else { RTSPClient.log("[Stream] makeURL failed"); return nil }

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
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            RTSPClient.log("[Stream] HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rtspsString = json[quality] as? String else { return nil }

        activeStreams.insert(streamKey(camera.id, quality))
        let playable = toPlayableURL(rtspsString)
        RTSPClient.log("[Stream] Created \(quality) for \(camera.name): \(playable?.absoluteString ?? "nil")")
        return playable
    }

    // MARK: - RTSP stream cleanup

    /// Sends DELETE requests for all server-side stream allocations.
    /// Call when the panel closes to prevent stale sessions accumulating on the UDM.
    func cleanupStreams() {
        let keys = activeStreams
        activeStreams.removeAll()
        for key in keys {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            deleteRtspStream(for: String(parts[0]), quality: String(parts[1]))
        }
    }

    /// Releases a single secondary allocation (e.g. a doorbell's package lens)
    /// when its picture-in-picture closes, without tearing down the main stream.
    func releaseStream(for cameraId: String, quality: String) {
        guard activeStreams.remove(streamKey(cameraId, quality)) != nil else { return }
        deleteRtspStream(for: cameraId, quality: quality)
    }

    /// Fire-and-forget DELETE to release a server-side RTSP stream allocation.
    /// The API requires the `qualities` query parameter matching what was created.
    private func deleteRtspStream(for cameraId: String, quality: String) {
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(cameraId)/rtsps-stream?qualities=\(quality)"
        ) else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")

        Task { _ = try? await tlsSession.data(for: request) }
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
    private func enrichPtzFlags() async {
        guard await classicLogin() else { return }
        guard let url = makeURL(path: "proxy/protect/api/cameras") else { return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Manually set TOKEN cookie — HTTPCookieStorage() may not auto-forward it
        if let token = tokenCookie {
            request.setValue("TOKEN=\(token)", forHTTPHeaderField: "Cookie")
        }

        guard let (data, resp) = try? await classicSession.data(for: request),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return }

        // Classic API returns a plain array (not wrapped in {data: [...]})
        let classicCameras = (try? JSONDecoder().decode([Camera].self, from: data)) ?? []

        // Only apply flags when we actually got a camera list back. A transient
        // empty/failed response must not wipe previously-known PTZ flags; but when
        // the list is present it is authoritative (a camera that lost PTZ is cleared).
        guard !classicCameras.isEmpty else { return }
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
                    await MainActor.run {
                        self.errorMessage = String(localized: "PTZ unavailable — check the username and password in Settings.")
                    }
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
            path: "proxy/protect/api/cameras/\(cameraId)/move"
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
            self.cameras = cameras
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func applyError(_ error: Error) async {
        RTSPClient.log("[API] applyError: \(error.localizedDescription)")
        await MainActor.run {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    private func setLoading(_ value: Bool) async {
        await MainActor.run { self.isLoading = value }
    }

    func makeURL(path: String) -> URL? {
        guard !settings.ipAddress.isEmpty else { return nil }
        return URL(string: "https://\(settings.ipAddress)/\(path)")
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
    private lazy var classicSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage()
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
        // Pin the controller's public key on first use; reject if it later changes
        // (possible MITM). Never writes to the system trust store.
        let host = challenge.protectionSpace.host
        if CertificateTrust.evaluate(host: host, trust: trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            Task { await MainActor.run {
                self.errorMessage = String(localized: "The controller's certificate changed. Open Settings to review and trust it.")
            } }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
