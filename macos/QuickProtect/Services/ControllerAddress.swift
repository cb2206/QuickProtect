import Foundation

/// The controller address as the user typed it, normalised into the two forms
/// the app actually needs:
///
/// - `authority` (`host` or `host:port`) for building `https://` API URLs, and
/// - `pinKey` (the lower-cased host alone) as the single identity under which
///   the controller's certificate is pinned.
///
/// One identity matters because the controller is reached over two channels —
/// HTTPS for the API and RTSPS for video, where the stream URL the controller
/// hands back names *its own* idea of its address (usually the bare IP). Both
/// channels must consult the same pin, or a certificate change can be trusted
/// for one channel and stay rejected on the other with nothing in Settings to
/// fix it.
///
/// Accepts the lenient forms people paste: an optional scheme, a port, a
/// trailing slash or path, surrounding whitespace, bracketed IPv6. Userinfo and
/// paths are dropped.
struct ControllerAddress: Equatable {
    /// Lower-cased host name or IP literal (IPv6 without brackets).
    let host: String
    /// Explicit port, or nil for the HTTPS default (443).
    let port: Int?

    static let defaultPort = 443

    /// Parses the raw Settings text. Returns nil when no usable host is present.
    static func parse(_ raw: String) -> ControllerAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // URLComponents needs a scheme to recognise the authority part.
        let withScheme = trimmed.range(of: "://") != nil ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              var host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        // Older Foundation versions keep IPv6 brackets in `host`.
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
        return ControllerAddress(host: host, port: port)
    }

    /// Identity used for certificate pinning: the host alone, so the API and
    /// stream channels share one pin regardless of port or how it was typed.
    var pinKey: String { host }

    /// `host` or `host:port`, IPv6 literals bracketed — what goes after `https://`.
    var authority: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port.map { "\(h):\($0)" } ?? h
    }

    var httpsBase: String { "https://\(authority)" }
}
