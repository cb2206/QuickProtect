import Combine
import XCTest

/// `ProtectHub` over two stubbed consoles: merging, per-site failure
/// handling, routing of per-camera calls, and site removal.
@MainActor
final class ProtectHubTests: XCTestCase {

    private final class InMemorySecretStore: SecretStoring {
        var values: [String: String] = [:]
        func get(_ account: String) -> String? { values[account] }
        func set(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func remove(_ account: String) -> Bool { values.removeValue(forKey: account) != nil }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var pinSuite: String!
    private var settings: AppSettings!

    override func setUp() async throws {
        HubStub.reset()
        try await MainActor.run {
            suiteName = "com.cb.quickprotect.hubtests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            pinSuite = "com.cb.quickprotect.hubpins.\(UUID().uuidString)"
            settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore())
        }
    }

    override func tearDown() async throws {
        HubStub.reset()
        await MainActor.run {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: pinSuite)
        }
    }

    /// Two configured sites — Inca (10.0.0.1) and BC285 (10.0.0.2) — and a
    /// hub whose services talk to the stub with a scratch pin store.
    private func makeHub() throws -> (ProtectHub, inca: ControllerSite, bc: ControllerSite) {
        let inca = settings.sites[0]
        inca.name = "Inca"
        inca.ipAddress = "10.0.0.1"
        inca.apiKey = "inca-key"
        let bc = settings.addSite(name: "BC285")
        bc.ipAddress = "10.0.0.2"
        bc.apiKey = "bc-key"
        let pins = CertificateTrust.Store(defaults: try XCTUnwrap(UserDefaults(suiteName: pinSuite)))
        let hub = ProtectHub(settings: settings) { site in
            ProtectService(settings: site, siteID: site.id, urlProtocolClasses: [HubStub.self],
                           certificateStore: pins)
        }
        return (hub, inca, bc)
    }

    private static func list(_ ids: String...) -> HubStub.Reply {
        let items = ids.map { #"{"id":"\#($0)","name":"\#($0)","state":"CONNECTED"}"# }
        return .ok(Data(#"{"data":[\#(items.joined(separator: ","))]}"#.utf8))
    }

    func testMergesBothSitesAndStampsEachCameraWithItsSite() async throws {
        let (hub, inca, bc) = try makeHub()
        HubStub.replies = ["10.0.0.1": Self.list("i1", "i2"), "10.0.0.2": Self.list("b1")]

        await hub.fetchCameras(forced: true)

        XCTAssertEqual(hub.cameras.map(\.id), ["i1", "i2", "b1"])
        XCTAssertEqual(hub.cameras.map(\.siteID), [inca.id, inca.id, bc.id])
        XCTAssertEqual(hub.gridState, .cameras)
        XCTAssertTrue(hub.siteIssues.isEmpty)
        XCTAssertEqual(hub.service(forCameraID: "b1")?.siteID, bc.id)
        XCTAssertEqual(hub.siteBadge(for: hub.cameras[2]), "BC285")
        XCTAssertEqual(Set(HubStub.requests.compactMap { $0.value(forHTTPHeaderField: "X-API-Key") }),
                       ["inca-key", "bc-key"], "each console gets its own key")
    }

    /// A first fetch of the added site hides its cameras in other profiles.
    func testFirstFetchOfAnAddedSiteSeedsTheProfiles() async throws {
        let other = settings.createProfile(named: "Inca only")
        settings.switchProfile(to: AppSettings.defaultProfileID)
        let (hub, _, _) = try makeHub()
        HubStub.replies = ["10.0.0.1": Self.list("i1"), "10.0.0.2": Self.list("b1")]

        await hub.fetchCameras(forced: true)

        XCTAssertFalse(settings.isHidden("b1"))
        settings.switchProfile(to: other)
        XCTAssertTrue(settings.isHidden("b1"))
        XCTAssertFalse(settings.isHidden("i1"), "the migrated site was already seeded")
    }

    func testAFailingSiteBecomesAnIssueWhileTheOtherKeepsStreaming() async throws {
        let (hub, _, bc) = try makeHub()
        HubStub.replies = ["10.0.0.1": Self.list("i1"), "10.0.0.2": .status(401)]

        await hub.fetchCameras(forced: true)

        XCTAssertEqual(hub.cameras.map(\.id), ["i1"])
        XCTAssertEqual(hub.gridState, .cameras)
        XCTAssertEqual(hub.siteIssues.map(\.siteID), [bc.id])
        XCTAssertEqual(hub.siteIssues.first?.siteName, "BC285")
        XCTAssertEqual(hub.siteIssues.first?.message, ControllerErrors.apiKeyRejected)
    }

    func testEverySiteFailingShowsOneLinePerSite() async throws {
        let (hub, _, _) = try makeHub()
        HubStub.replies = ["10.0.0.1": .status(401), "10.0.0.2": .status(401)]

        await hub.fetchCameras(forced: true)

        let expected = "Inca: \(ControllerErrors.apiKeyRejected)\nBC285: \(ControllerErrors.apiKeyRejected)"
        XCTAssertEqual(hub.gridState, .error(expected))
    }

    /// With one site the grid behaves exactly like the single-controller app.
    func testASingleFailingSiteShowsTheBareMessage() async {
        let site = settings.sites[0]
        site.ipAddress = "10.0.0.1"
        site.apiKey = "k"
        let hub = ProtectHub(settings: settings) {
            ProtectService(settings: $0, siteID: $0.id, urlProtocolClasses: [HubStub.self])
        }
        HubStub.replies = ["10.0.0.1": .status(401)]

        await hub.fetchCameras(forced: true)

        XCTAssertEqual(hub.gridState, .error(ControllerErrors.apiKeyRejected))
        XCTAssertNil(hub.siteBadge(for: Camera(id: "x", name: "x", state: "CONNECTED", channels: [])))
    }

    func testStreamCallsGoToTheCamerasOwnConsole() async throws {
        let (hub, _, _) = try makeHub()
        HubStub.replies = [
            "10.0.0.1": Self.list("i1"),
            "10.0.0.2": Self.list("b1")
        ]
        await hub.fetchCameras(forced: true)
        let bcCamera = try XCTUnwrap(hub.cameras.first { $0.id == "b1" })
        HubStub.replies["10.0.0.2"] = .ok(Data(#"{"low":"rtsps://10.0.0.2:7441/abc?enableSrtp"}"#.utf8))

        let stream = await hub.createRtspStreamURL(for: bcCamera, quality: "low")
        XCTAssertEqual(stream?.url.host, "10.0.0.2")
        hub.releaseStream(for: "b1", quality: "low")
        hub.waitForStreamReleases(timeout: 2)

        let delete = HubStub.requests.last { $0.httpMethod == "DELETE" }
        XCTAssertEqual(delete?.url?.host, "10.0.0.2")
        XCTAssertEqual(delete?.value(forHTTPHeaderField: "X-API-Key"), "bc-key")
        XCTAssertEqual(hub.controllerAddress(for: bcCamera)?.host, "10.0.0.2")
    }

    func testRemovingASiteDropsItsCamerasAndAnnouncesIt() async throws {
        let (hub, _, bc) = try makeHub()
        HubStub.replies = ["10.0.0.1": Self.list("i1"), "10.0.0.2": Self.list("b1")]
        await hub.fetchCameras(forced: true)
        var removed: [String] = []
        let sub = hub.siteRemoved.sink { removed.append($0) }

        settings.removeSite(id: bc.id)

        XCTAssertEqual(removed, [bc.id])
        XCTAssertNil(hub.service(forSite: bc.id))
        XCTAssertEqual(hub.cameras.map(\.id), ["i1"])
        sub.cancel()
    }

    func testConnectionChangeIsAnnouncedPerSite() throws {
        let (hub, _, bc) = try makeHub()
        var changed: [String] = []
        let sub = hub.connectionWillChange.sink { changed.append($0) }
        bc.apiKey = "rotated"
        bc.name = "BC 285"
        sub.cancel()
        XCTAssertEqual(changed, [bc.id])
    }
}

// MARK: - Stub consoles

/// Answers each request by host from `replies`; records every request.
private final class HubStub: URLProtocol {
    enum Reply {
        case ok(Data)
        case status(Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _replies: [String: Reply] = [:]   // guarded by `lock`
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var replies: [String: Reply] {
        get { lock.lock(); defer { lock.unlock() }; return _replies }
        set { lock.lock(); _replies = newValue; lock.unlock() }
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    static func reset() {
        lock.lock(); _replies = [:]; _requests = []; lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let reply = request.url?.host.flatMap { Self._replies[$0] }
        Self.lock.unlock()

        let (status, body): (Int, Data)
        switch reply {
        case .ok(let data)?:      (status, body) = (200, data)
        case .status(let code)?:  (status, body) = (code, Data())
        case nil:                 (status, body) = (404, Data())
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
