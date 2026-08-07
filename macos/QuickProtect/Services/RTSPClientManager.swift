import Foundation

/// Owns RTSPClient instances keyed by camera ID so they survive SwiftUI
/// view destruction/recreation during grid ↔ focused ↔ fullscreen transitions.
final class RTSPClientManager: ObservableObject {
    private var clients: [String: RTSPClient] = [:]

    /// Returns the existing client for a camera, or creates a new one.
    /// `lens` distinguishes a camera's secondary stream (e.g. "package") from
    /// its main feed, so a doorbell can hold two independent clients at once.
    func client(for cameraId: String, lens: String? = nil) -> RTSPClient {
        let key = lens.map { "\(cameraId):\($0)" } ?? cameraId
        if let existing = clients[key] {
            return existing
        }
        let client = RTSPClient()
        clients[key] = client
        return client
    }

    /// Pause or resume display decode on every owned client. Paused while the
    /// panel is hidden during the keep-alive grace (streams stay connected but
    /// nobody sees them); resumed when the panel reopens in time.
    func setRenderPaused(_ paused: Bool) {
        for client in clients.values {
            client.setRenderPaused(paused)
        }
    }

    /// Disconnects and removes all clients (called when popover closes).
    func disconnectAll() {
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
    }

    deinit {
        // Safety net: never let owned connections outlive the manager.
        disconnectAll()
    }
}
