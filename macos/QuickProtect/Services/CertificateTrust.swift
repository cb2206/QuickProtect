import Foundation
import Security
import CryptoKit

/// Trust-on-first-use (TOFU) certificate pinning for the UniFi controller.
///
/// UniFi controllers present a self-signed certificate, so default system trust
/// always fails. Rather than blindly accepting *any* certificate (which makes a
/// man-in-the-middle on the local network undetectable) — and rather than writing
/// blanket trust into the user's system keychain — this pins the controller's
/// public key the first time we see it and rejects mismatches thereafter.
///
/// Flow per host:
///   1. First connection: no pin stored → record the fingerprint, accept.
///   2. Later connection, same key: accept.
///   3. Later connection, different key: reject, and stash the new fingerprint as
///      "pending" so the user can explicitly re-pin from Settings (e.g. after the
///      controller's certificate is legitimately regenerated).
///
/// Nothing is ever written to the system trust store; pins live in UserDefaults
/// (a fingerprint is not a secret).
enum CertificateTrust {

    /// Evaluate a server trust for `host` under the TOFU policy.
    /// Returns true if the connection should be allowed.
    static func evaluate(host: String, trust: SecTrust) -> Bool {
        guard let fingerprint = fingerprint(forLeafOf: trust) else {
            // Couldn't read a public key — fail closed.
            return false
        }
        return evaluate(host: host, fingerprint: fingerprint)
    }

    /// Evaluate an already-computed fingerprint. Split out for testability and so
    /// both the URLSession and Network.framework paths share one decision point.
    static func evaluate(host: String, fingerprint: String) -> Bool {
        let store = Store()
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
        // Mismatch: remember the candidate so the user can choose to trust it.
        store.setPending(fingerprint, host: host)
        return false
    }

    // MARK: - Fingerprint

    /// SHA-256 of the leaf certificate's public key (SubjectPublicKeyInfo bytes),
    /// hex-encoded. Pinning the key (not the whole cert) means a renewed
    /// certificate with the same key still validates.
    static func fingerprint(forLeafOf trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return fingerprint(for: leaf)
    }

    static func fingerprint(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    /// UserDefaults-backed pin storage. Public-key fingerprints are not secrets,
    /// so they don't belong in the Keychain.
    struct Store {
        private let defaults = UserDefaults.standard
        private func pinnedKey(_ host: String) -> String { "qp.pinnedCert.\(host)" }
        private func pendingKey(_ host: String) -> String { "qp.pendingCert.\(host)" }

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

        /// Promote a pending (changed) certificate to the trusted pin. Used by the
        /// "Trust new certificate" action in Settings.
        func trustPending(host: String) {
            guard let candidate = pending(host: host) else { return }
            setPinned(candidate, host: host)
            setPending(nil, host: host)
        }
    }
}
