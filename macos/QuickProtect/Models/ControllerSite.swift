import Foundation
import Combine

/// One UniFi console (a "site") QuickProtect streams from: its address, the
/// Integration API key and the optional classic-API login used for PTZ.
///
/// The site list itself (id, name, address) lives in UserDefaults; the three
/// secrets live in the Keychain under per-site accounts. The site migrated from
/// the pre-multi-site configuration keeps the original account names
/// (`unifi.apiKey` …) so upgrading never re-reads or re-writes the Keychain.
@MainActor
final class ControllerSite: ObservableObject, Identifiable {
    /// Stable identifier. `legacyID` for the migrated original controller,
    /// a UUID string for every site added later.
    let id: String

    /// User-facing label shown on tiles, menus and Settings ("Inca", "BC285").
    @Published var name: String {
        didSet { if name != oldValue { onListChange?() } }
    }

    @Published var ipAddress: String {
        didSet { if ipAddress != oldValue { onListChange?() } }
    }

    /// Integration API key. Sensitive — Keychain only.
    @Published var apiKey: String {
        didSet { secrets.set(apiKey, account: Self.account(AppSettings.Keys.apiKey, siteID: id)) }
    }

    /// Classic-API username (PTZ). Sensitive — Keychain only.
    @Published var username: String {
        didSet { secrets.set(username, account: Self.account(AppSettings.Keys.username, siteID: id)) }
    }

    /// Classic-API password (PTZ). Sensitive — Keychain only.
    @Published var password: String {
        didSet { secrets.set(password, account: Self.account(AppSettings.Keys.password, siteID: id)) }
    }

    /// Id of the site migrated from the single-controller configuration.
    nonisolated static let legacyID = "default"

    private let secrets: any SecretStoring
    /// Set by `AppSettings` to persist the list when the name or address changes.
    var onListChange: (() -> Void)?

    init(id: String, name: String, ipAddress: String, secrets: any SecretStoring,
         apiKey: String, username: String, password: String) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.secrets = secrets
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }

    /// Loads a stored site, reading its secrets from the store.
    convenience init(id: String, name: String, ipAddress: String, secrets: any SecretStoring) {
        self.init(id: id, name: name, ipAddress: ipAddress, secrets: secrets,
                  apiKey: secrets.get(Self.account(AppSettings.Keys.apiKey, siteID: id)) ?? "",
                  username: secrets.get(Self.account(AppSettings.Keys.username, siteID: id)) ?? "",
                  password: secrets.get(Self.account(AppSettings.Keys.password, siteID: id)) ?? "")
    }

    /// Keychain account for one of a site's secrets. The legacy site keeps the
    /// pre-multi-site account names; others get a `.<siteID>` suffix.
    nonisolated static func account(_ base: String, siteID: String) -> String {
        siteID == legacyID ? base : "\(base).\(siteID)"
    }

    /// Deletes this site's secrets (the site is being removed).
    func removeSecrets() {
        for base in [AppSettings.Keys.apiKey, AppSettings.Keys.username, AppSettings.Keys.password] {
            secrets.remove(Self.account(base, siteID: id))
        }
    }

    /// The name to show: the user's label, else the address, else a placeholder.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !ipAddress.isEmpty { return ipAddress }
        return String(localized: "New Site")
    }

    /// Address and API key are both set, so the camera list can be fetched.
    var isConfigured: Bool { !ipAddress.isEmpty && !apiKey.isEmpty }

    /// Fires (before the new value is stored, like `@Published`) whenever the
    /// address or API key changes — the connection identity of this site.
    var connectionChanges: AnyPublisher<Void, Never> {
        $ipAddress.dropFirst().removeDuplicates().map { _ in () }
            .merge(with: $apiKey.dropFirst().removeDuplicates().map { _ in () })
            .eraseToAnyPublisher()
    }

    /// UserDefaults storage form of the site-list entry (no secrets).
    var listEntry: [String: String] { ["id": id, "name": name, "address": ipAddress] }
}

extension ControllerSite: ProtectCredentialSource {}
