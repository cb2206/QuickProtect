import Foundation
import Security
import CryptoKit

/// Certificate policy for the UniFi controller.
///
/// Most controllers present a self-signed certificate, so default system trust
/// fails. Rather than blindly accepting *any* certificate (which makes a
/// man-in-the-middle on the local network undetectable) — and rather than writing
/// blanket trust into the user's system keychain — the controller's public key is
/// pinned the first time it is seen and mismatches are rejected thereafter
/// (trust on first use, TOFU).
///
/// Order of evaluation per connection:
///   1. System trust. A certificate the OS already trusts for the host it was
///      contacted under (e.g. a controller reached through its `*.unifi.ui.com`
///      name with a publicly issued certificate) is accepted outright and is
///      *not* pinned — its issuer is the authority, and routine renewals must
///      not trip a warning.
///   2. No pin stored for the controller → record the key's fingerprint, accept.
///   3. Same key as the pin → accept.
///   4. Different key → reject, and stash the new fingerprint as "pending" so
///      the user can explicitly re-pin from Settings (after a controller
///      reinstall, say). The full fingerprints of both keys are shown there so
///      the change can be verified out of band.
///
/// Pins are keyed by `ControllerAddress.pinKey` — one identity shared by the
/// HTTPS API and the RTSPS video channel — and live in UserDefaults (a
/// fingerprint is not a secret). Nothing is ever written to the system trust
/// store. The first connection is inherently unverified; that limitation is
/// documented in the privacy policy.
enum CertificateTrust {

    // MARK: - Evaluation

    /// Evaluate a server trust for the controller identified by `pinKey`,
    /// contacted as `serverHost` (the host name or IP the socket was opened to —
    /// what a system-trust check must validate the certificate against).
    /// Returns true if the connection should be allowed.
    static func evaluate(pinKey: String, serverHost: String, trust: SecTrust) -> Bool {
        if isSystemTrusted(trust, serverHost: serverHost) { return true }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let fingerprint = fingerprint(for: leaf) else {
            // Couldn't read a public key — fail closed.
            return false
        }
        return evaluate(host: pinKey,
                        fingerprint: fingerprint,
                        legacyFingerprint: legacyFingerprint(for: leaf))
    }

    /// Evaluate an already-computed fingerprint. Split out for testability and so
    /// the URLSession and Network.framework paths share one decision point.
    /// `legacyFingerprint` is the pre-1.4 hash of the same key; a pin stored in
    /// that format is silently upgraded so existing installs don't see a
    /// spurious "certificate changed" after updating.
    static func evaluate(host: String, fingerprint: String, legacyFingerprint: String? = nil,
                         store: Store = Store()) -> Bool {
        guard let pinned = store.pinned(host: host) else {
            // Trust on first use.
            store.setPinned(fingerprint, host: host)
            store.setPending(nil, host: host)
            return true
        }
        if pinned == fingerprint {
            // Known key — clear any stale pending warning.
            if store.pending(host: host) != nil { store.setPending(nil, host: host) }
            return true
        }
        if let legacy = legacyFingerprint, pinned == legacy {
            // Same key, older hash format — migrate in place.
            store.setPinned(fingerprint, host: host)
            store.setPending(nil, host: host)
            return true
        }
        // Mismatch: remember the candidate so the user can choose to trust it.
        store.setPending(fingerprint, host: host)
        return false
    }

    /// Whether the OS trusts this chain for `serverHost` under a standard SSL
    /// policy (chain to a trusted root, validity period, host name match).
    static func isSystemTrusted(_ trust: SecTrust, serverHost: String) -> Bool {
        let policy = SecPolicyCreateSSL(true, serverHost as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    // MARK: - Fingerprint

    /// SHA-256 of the leaf certificate's DER-encoded SubjectPublicKeyInfo,
    /// lower-case hex. Pinning the key (not the whole certificate) means a
    /// renewed certificate with the same key still validates. The same bytes are
    /// hashed by the .NET app (`ExportSubjectPublicKeyInfo`) and by
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform DER | sha256sum`,
    /// so a fingerprint shown in Settings can be checked against the controller.
    static func fingerprint(for certificate: SecCertificate) -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        guard let spki = subjectPublicKeyInfo(fromCertificateDER: der) else { return nil }
        return hex(SHA256.hash(data: spki))
    }

    /// The pre-1.4 fingerprint: SHA-256 over `SecKeyCopyExternalRepresentation`
    /// (PKCS#1 for RSA, the X9.63 point for EC) — the raw key without the
    /// algorithm identifier. Kept only so stored pins can be migrated.
    static func legacyFingerprint(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return hex(SHA256.hash(data: data))
    }

    /// Groups a hex fingerprint into colon-separated byte pairs for display.
    static func displayFingerprint(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(2, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: ":")
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - DER

    /// Extracts the SubjectPublicKeyInfo element (tag + length + content) from a
    /// DER-encoded X.509 certificate.
    ///
    ///     Certificate ::= SEQUENCE {
    ///       tbsCertificate SEQUENCE {
    ///         version [0] EXPLICIT OPTIONAL, serialNumber, signature,
    ///         issuer, validity, subject, subjectPublicKeyInfo, ... }
    ///
    /// A minimal TLV walker is enough: enter two SEQUENCEs, skip the optional
    /// context-tagged version, skip five elements, and the next one is the SPKI.
    static func subjectPublicKeyInfo(fromCertificateDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let cert = readTLV(bytes, at: 0), cert.tag == 0x30,
              let tbs = readTLV(bytes, at: cert.contentStart), tbs.tag == 0x30 else { return nil }
        var cursor = tbs.contentStart
        let tbsEnd = tbs.end
        guard let first = readTLV(bytes, at: cursor, limit: tbsEnd) else { return nil }
        if first.tag == 0xA0 { cursor = first.end }   // [0] EXPLICIT version
        for _ in 0..<5 {                              // serial, signature, issuer, validity, subject
            guard let element = readTLV(bytes, at: cursor, limit: tbsEnd) else { return nil }
            cursor = element.end
        }
        guard let spki = readTLV(bytes, at: cursor, limit: tbsEnd), spki.tag == 0x30 else { return nil }
        return Data(bytes[cursor..<spki.end])
    }

    private struct TLV {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    /// Reads one DER tag-length-value header at `offset`. Bounds-checked; returns
    /// nil on truncation or an indefinite/oversized length.
    private static func readTLV(_ bytes: [UInt8], at offset: Int, limit: Int? = nil) -> TLV? {
        let limit = limit ?? bytes.count
        guard offset + 2 <= limit else { return nil }
        let tag = bytes[offset]
        var cursor = offset + 1
        var length = Int(bytes[cursor]); cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, cursor + count <= limit else { return nil }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[cursor]); cursor += 1 }
        }
        guard length >= 0, cursor + length <= limit else { return nil }
        return TLV(tag: tag, contentStart: cursor, end: cursor + length)
    }

    // MARK: - Persistence

    /// UserDefaults-backed pin storage. Public-key fingerprints are not secrets,
    /// so they don't belong in the Keychain.
    struct Store {
        private let defaults: UserDefaults
        private static let pinnedPrefix = "qp.pinnedCert."
        private static let pendingPrefix = "qp.pendingCert."

        init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        private func pinnedKey(_ host: String) -> String { Self.pinnedPrefix + host }
        private func pendingKey(_ host: String) -> String { Self.pendingPrefix + host }

        func pinned(host: String) -> String? {
            defaults.string(forKey: pinnedKey(host))
        }
        func setPinned(_ fingerprint: String?, host: String) {
            if let fingerprint {
                defaults.set(fingerprint, forKey: pinnedKey(host))
            } else {
                defaults.removeObject(forKey: pinnedKey(host))
            }
        }
        func pending(host: String) -> String? {
            defaults.string(forKey: pendingKey(host))
        }
        func setPending(_ fingerprint: String?, host: String) {
            if let fingerprint {
                defaults.set(fingerprint, forKey: pendingKey(host))
            } else {
                defaults.removeObject(forKey: pendingKey(host))
            }
        }

        /// Every host with a changed certificate awaiting the user's decision,
        /// so Settings can list them all rather than guess one key.
        func allPending() -> [(host: String, fingerprint: String)] {
            defaults.dictionaryRepresentation().compactMap { key, value in
                guard key.hasPrefix(Self.pendingPrefix), let fp = value as? String else { return nil }
                return (String(key.dropFirst(Self.pendingPrefix.count)), fp)
            }.sorted { $0.host < $1.host }
        }

        /// Promote a pending (changed) certificate to the trusted pin. Used by the
        /// "Trust new certificate" action in Settings.
        func trustPending(host: String) {
            guard let candidate = pending(host: host) else { return }
            setPinned(candidate, host: host)
            setPending(nil, host: host)
        }
    }
}
