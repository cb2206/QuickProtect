import Foundation
import AppKit

/// Handles all communication with the UniFi Protect Integration API.
final class ProtectService: NSObject, ObservableObject {

    @Published var cameras: [Camera] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set by AppDelegate when the popover opens/closes so cells can pause players.
    @Published var isPopoverOpen = false

    private let settings = AppSettings.shared

    /// Camera IDs that have an active server-side RTSP stream allocation.
    /// Used to send DELETE requests on cleanup, preventing stale sessions from
    /// accumulating on the UDM when the panel is closed or the app quits.
    private var activeStreamCameraIds: Set<String> = []

    // MARK: - Fetch camera list

    func fetchCameras() async {
        guard validate() else { return }
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
        } catch {
            await applyError(error)
        }
    }

    // MARK: - RTSP stream creation (Integration API)

    /// POSTs to the Integration API to create an on-demand RTSP stream.
    /// Returns a playable URL for AVPlayer (plain rtsp:// or rtsps:// per settings).
    func createRtspStreamURL(for camera: Camera) async -> URL? {
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(camera.id)/rtsps-stream"
        ) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["qualities": ["medium"]]
        )

        guard let (data, resp) = try? await tlsSession.data(for: request) else { return nil }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rtspsString = json["medium"] as? String else { return nil }

        activeStreamCameraIds.insert(camera.id)
        return toPlayableURL(rtspsString)
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
    private func deleteRtspStream(for cameraId: String) {
        guard let url = makeURL(
            path: "proxy/protect/integration/v1/cameras/\(cameraId)/rtsps-stream"
        ) else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-API-Key")

        Task { _ = try? await tlsSession.data(for: request) }
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
        await MainActor.run {
            self.cameras = cameras
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func applyError(_ error: Error) async {
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

    private lazy var tlsSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
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
