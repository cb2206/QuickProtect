import XCTest
import Security

final class CertificateTrustTests: XCTestCase {

    /// Isolated UserDefaults suite per test so pins never leak between tests
    /// (or into the developer's real preferences).
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: CertificateTrust.Store!

    override func setUp() {
        super.setUp()
        suiteName = "CertificateTrustTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = CertificateTrust.Store(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func evaluate(_ host: String, _ fp: String, legacy: String? = nil) -> Bool {
        CertificateTrust.evaluate(host: host, fingerprint: fp, legacyFingerprint: legacy, store: store)
    }

    // MARK: - TOFU state machine

    func testFirstUsePinsAndAccepts() {
        XCTAssertTrue(evaluate("10.0.0.1", "A"))
        XCTAssertEqual(store.pinned(host: "10.0.0.1"), "A")
        XCTAssertNil(store.pending(host: "10.0.0.1"))
    }

    func testSameKeyAcceptsMismatchRejectsThenTrustPendingPromotes() {
        XCTAssertTrue(evaluate("h", "A"))
        XCTAssertTrue(evaluate("h", "A"))
        XCTAssertFalse(evaluate("h", "B"))
        XCTAssertEqual(store.pending(host: "h"), "B")
        store.trustPending(host: "h")
        XCTAssertTrue(evaluate("h", "B"))
        XCTAssertNil(store.pending(host: "h"))
    }

    func testReturningToPinnedKeyClearsPending() {
        XCTAssertTrue(evaluate("h", "A"))
        XCTAssertFalse(evaluate("h", "B"))
        XCTAssertTrue(evaluate("h", "A"))
        XCTAssertNil(store.pending(host: "h"))
    }

    func testLegacyPinMigratesToNewFormatWithoutRejecting() {
        store.setPinned("legacy-hash", host: "h")
        XCTAssertTrue(evaluate("h", "new-hash", legacy: "legacy-hash"))
        XCTAssertEqual(store.pinned(host: "h"), "new-hash")
        XCTAssertNil(store.pending(host: "h"))
    }

    func testLegacyMismatchStillRejects() {
        store.setPinned("legacy-hash", host: "h")
        XCTAssertFalse(evaluate("h", "new-hash", legacy: "other-legacy"))
        XCTAssertEqual(store.pending(host: "h"), "new-hash")
    }

    func testAllPendingListsEveryHost() {
        XCTAssertTrue(evaluate("b.local", "A"))
        XCTAssertTrue(evaluate("a.local", "A"))
        XCTAssertFalse(evaluate("b.local", "B"))
        XCTAssertFalse(evaluate("a.local", "C"))
        let pending = store.allPending()
        XCTAssertEqual(pending.map(\.host), ["a.local", "b.local"])
        XCTAssertEqual(pending.map(\.fingerprint), ["C", "B"])
    }

    // MARK: - Fingerprints

    // Self-signed test certificates generated with openssl; expected values from
    //   openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum
    // swiftlint:disable:next line_length
    private static let ecCertBase64 = "MIIBjTCCATOgAwIBAgIUQAk3QMFbtrlN0iekH5518nOWKukwCgYIKoZIzj0EAwIwHDEaMBgGA1UEAwwRcXVpY2twcm90ZWN0LXRlc3QwHhcNMjYwOTA0MjM1MTIxWhcNMzYwOTAxMjM1MTIxWjAcMRowGAYDVQQDDBFxdWlja3Byb3RlY3QtdGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMoJ5tX8ZmNoI183iORlGeC7z2VRkiSpR7PnMROrj91CDi1mY66qzALjLHMuKDje5HMsxpK8ArR0FpC7W3g5g/yjUzBRMB0GA1UdDgQWBBQmCj8GymgrtZ0RwNKqI5orgKsmrTAfBgNVHSMEGDAWgBQmCj8GymgrtZ0RwNKqI5orgKsmrTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQCG8+u3bTwdyXNgwI20r42+UomvKUgjzRmW++3IPnCdcAIgL2CTomMOXTO5h1vegJELC7aUdVE0vWkOGh52EBZNS5o="
    private static let ecSpkiSHA256 = "549ad694ca1a1a046511f469d10a2c52dc04d7beb93d52f84abe8447b92f882d"
    private static let ecRawPointSHA256 = "401f028287c98c4c46d963b62ac5df122ba475b4d983d8ebb4fa5334c030191b"

    // swiftlint:disable:next line_length
    private static let rsaCertBase64 = "MIIDITCCAgmgAwIBAgIUAmXeuxmfUYouRiV7ViI9mCrFHT0wDQYJKoZIhvcNAQELBQAwIDEeMBwGA1UEAwwVcXVpY2twcm90ZWN0LXRlc3QtcnNhMB4XDTI2MDkwNDIzNTEyMVoXDTM2MDkwMTIzNTEyMVowIDEeMBwGA1UEAwwVcXVpY2twcm90ZWN0LXRlc3QtcnNhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsVPp9Lt1ZP1fAXuc0URQI2rKLuvCHezeCwHLqarEjO6CFSXNpdp8l7yiDJ8iCHJoLWki8lIIAYVaivwVUjUjblCG3d4XDEXbAT9tFFFVgsCDQpY0vKdlrbewrBB8e3hnaOxygqogaWGp/xOltR1TYiFM2AmF0Lyy01ZABLqtrbaY7SA+xx7rqoFbeq4ZmXWmsTJYP2C2rDHYjYuXdO/SBBY7b7LL7p0QCqUMR63/UyrMp/YM8kWtq7nsMkBAH7ufoK+wECsAX7cTnty6UKg9oKb1MMrutC/EluScDvKJXjBeNFYqZYSEAlpROHD4N0VUUcsRHkHOHCjwpTy3QcCg8wIDAQABo1MwUTAdBgNVHQ4EFgQUz3BwY4DpX9hgGcUl7fRZNHzPmcUwHwYDVR0jBBgwFoAUz3BwY4DpX9hgGcUl7fRZNHzPmcUwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAXXK5j7LsojJK9MMTLm6DnJ6kvukyQTNHDBKzKo9YxjwkU4WRSYhSUcMJERYALtcf0OLgWxtWvyQxlTa1s1UVhHVDYchoqW0XjcMy52nqW/0WcqxzkBAinrt7FjQFcko5ouqfqV5e7w/eupzR+CWbamHWUNr9yqGnyjmJWL6vG36JSxETxip2E/ur7WEK9Bvic6V7Ey4VujjxkKtHwJwawr85gRSyWVLr3hGEz7Z8BmMKl+WuYk9p3bxMV3PrRrEfpqvOyK5fjy+RSUAEjoKDqP0ilm1lv+/49CpxE3Uc+g9q48oNQ2q4ziJNDlsU0mggIIo8aenkFW+Uhy1zYWVSWg=="
    private static let rsaSpkiSHA256 = "a4662040e5fbc904cd9908853fc1625fa59ecb2ca32dfd7d70ac5911ae5192d5"
    private static let rsaPkcs1SHA256 = "24114722f5d1a2e780d7329c9e0b9bcf5eb02c1438185d8ff625949621c7e3c6"

    private func certificate(_ base64: String) -> SecCertificate {
        let der = Data(base64Encoded: base64)!
        return SecCertificateCreateWithData(nil, der as CFData)!
    }

    func testSpkiFingerprintMatchesOpenSSLForEC() {
        XCTAssertEqual(CertificateTrust.fingerprint(for: certificate(Self.ecCertBase64)), Self.ecSpkiSHA256)
    }

    func testSpkiFingerprintMatchesOpenSSLForRSA() {
        XCTAssertEqual(CertificateTrust.fingerprint(for: certificate(Self.rsaCertBase64)), Self.rsaSpkiSHA256)
    }

    func testLegacyFingerprintIsRawKeyHash() {
        XCTAssertEqual(CertificateTrust.legacyFingerprint(for: certificate(Self.ecCertBase64)), Self.ecRawPointSHA256)
        XCTAssertEqual(CertificateTrust.legacyFingerprint(for: certificate(Self.rsaCertBase64)), Self.rsaPkcs1SHA256)
    }

    func testSpkiExtractionRejectsTruncatedDER() {
        let der = Data(base64Encoded: Self.ecCertBase64)!
        XCTAssertNil(CertificateTrust.subjectPublicKeyInfo(fromCertificateDER: der.prefix(40)))
        XCTAssertNil(CertificateTrust.subjectPublicKeyInfo(fromCertificateDER: Data()))
        XCTAssertNil(CertificateTrust.subjectPublicKeyInfo(fromCertificateDER: Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])))
    }

    func testSelfSignedCertificateIsNotSystemTrusted() {
        let cert = certificate(Self.ecCertBase64)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        XCTAssertFalse(CertificateTrust.isSystemTrusted(trust!, serverHost: "quickprotect-test"))
    }

    func testDisplayFingerprintGroupsBytes() {
        XCTAssertEqual(CertificateTrust.displayFingerprint("abcdef"), "ab:cd:ef")
        XCTAssertEqual(CertificateTrust.displayFingerprint(""), "")
    }
}
