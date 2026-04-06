import Foundation

/// Owns RTSPClient instances keyed by camera ID so they survive SwiftUI
/// view destruction/recreation during grid ↔ focused ↔ fullscreen transitions.
final class RTSPClientManager: ObservableObject {
    private var clients: [String: RTSPClient] = [:]

    /// Returns the existing client for a camera, or creates a new one.
    func client(for cameraId: String) -> RTSPClient {
        if let existing = clients[cameraId] {
            return existing
        }
        let client = RTSPClient()
        clients[cameraId] = client
        return client
    }

    /// Disconnects and removes all clients (called when popover closes).
    func disconnectAll() {
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
    }
}
