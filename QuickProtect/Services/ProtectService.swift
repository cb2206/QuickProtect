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

    private let settings = AppSettings.shared

    /// Camera IDs that have an active server-side RTSP stream allocation.
    /// Used to send DELETE requests on cleanup, preventing stale sessions from
    /// accumulating on the UDM when the panel is closed or the app quits.
    private var activeStreamCameraIds: Set<String> = []

    /// CSRF token captured from classic API login response. Required for POST/PUT/DELETE
    /// requests to the classic API (used for PTZ control).
    private var csrfToken: String?
    /// TOKEN cookie captured from classic API login response. Manually set on requests
    /// because a fresh HTTPCookieStorage instance may not auto-accept cookies.
    private var tokenCookie: String?
    private var isClassicLoggedIn = false

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
            let http = response as! HTTPURLResponse
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

    /// POSTs to the Integration API to create an on-demand RTSP stream.
    /// Returns a playable URL for AVPlayer (plain rtsp:// or rtsps:// per settings).
    func createRtspStreamURL(for camera: Camera) async -> URL? {
        RTSPClient.log("[Stream] createRtspStreamURL called for \(camera.name)")
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(camera.id)/rtsps-stream"
        ) else { RTSPClient.log("[Stream] makeURL failed"); return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["qualities": ["medium"]]
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
              let rtspsString = json["medium"] as? String else { return nil }

        activeStreamCameraIds.insert(camera.id)
        let playable = toPlayableURL(rtspsString)
        RTSPClient.log("[Stream] Created for \(camera.name): \(playable?.absoluteString ?? "nil")")
        return playable
    }

    // MARK: - RTSP stream cleanup

    /// Sends DELETE requests for all server-side stream allocations.
    /// Call when the panel closes to prevent stale sessions accumulating on the UDM.
    func cleanupStreams() {
        let ids = activeStreamCameraIds
        activeStreamCameraIds.removeAll()
        for id in ids {
            deleteRtspStream(for: id)
        }
    }

    /// Fire-and-forget DELETE to release a server-side RTSP stream allocation.
    /// The API requires the `qualities` query parameter matching what was created.
    private func deleteRtspStream(for cameraId: String) {
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(cameraId)/rtsps-stream?qualities=medium"
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
            isClassicLoggedIn = false
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

        isClassicLoggedIn = true
        RTSPClient.log("[PTZ] classicLogin OK, csrf=\(csrfToken?.prefix(12) ?? "nil"), token=\(tokenCookie != nil ? "yes(\(tokenCookie!.prefix(12))...)" : "nil")")
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
        let ptzIds = Set(classicCameras.filter(\.isPtz).map(\.id))

        guard !ptzIds.isEmpty else { return }

        await MainActor.run {
            self.cameras = self.cameras.map { cam in
                var c = cam
                c.isPtz = ptzIds.contains(cam.id)
                return c
            }
        }
    }

    // MARK: - PTZ control (classic API — repeating relative moves)

    private var ptzTimer: Timer?

    /// Starts repeating relative moves at max step size. Call `ptzStop` on key-up.
    func ptzStartMove(cameraId: String, pan: Double = 0, tilt: Double = 0) {
        ptzStopTimer()
        let step = 4095.0  // max allowed value
        RTSPClient.log("[PTZ] startMove cam=\(cameraId) pan=\(pan) tilt=\(tilt)")

        sendPtzRelative(cameraId: cameraId, pan: pan * step, tilt: tilt * step)
        ptzTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.sendPtzRelative(cameraId: cameraId, pan: pan * step, tilt: tilt * step)
        }
    }

    /// Stops PTZ movement by cancelling the repeat timer.
    func ptzStop(cameraId: String) {
        RTSPClient.log("[PTZ] stop")
        ptzStopTimer()
    }

    private func ptzStopTimer() {
        ptzTimer?.invalidate()
        ptzTimer = nil
    }

    private func sendPtzRelative(cameraId: String, pan: Double, tilt: Double) {
        Task {
            if !isClassicLoggedIn { guard await classicLogin() else { return } }
            await sendMove(cameraId: cameraId, body: [
                "type": "relative",
                "payload": [
                    "panPos": pan,
                    "tiltPos": tilt,
                    "panSpeed": 255,
                    "tiltSpeed": 255
                ]
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
            isClassicLoggedIn = false
            csrfToken = nil
            tokenCookie = nil
        }
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
            Task { await MainActor.run { self.errorMessage = "No IP address configured. Open Settings." } }
            return false
        }
        if settings.apiKey.isEmpty {
            Task { await MainActor.run { self.errorMessage = "No API key configured. Open Settings." } }
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
            case .invalidURL:            return "Invalid IP address or URL."
            case .http(let c, let body): return "HTTP \(c) – \(body.prefix(200))"
            }
        }
    }
}

// MARK: - URLSessionDelegate (self-signed cert bypass + trust registration)

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
        // Register the cert in the user's trust store so AVFoundation's internal
        // TLS stack also accepts it when opening rtsps:// streams.
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let cert = chain.first {
            registerCertTrust(cert)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func registerCertTrust(_ cert: SecCertificate) {
        // Skip if already trusted
        var existing: CFArray?
        guard SecTrustSettingsCopyTrustSettings(cert, .user, &existing) != errSecSuccess else { return }
        // Add to keychain (no-op if already present)
        SecItemAdd([kSecClass: kSecClassCertificate,
                    kSecValueRef: cert,
                    kSecAttrLabel: "QuickProtect Controller"] as CFDictionary, nil)
        // Mark trusted for all uses in the user domain
        SecTrustSettingsSetTrustSettings(cert, .user, nil)
    }
}
