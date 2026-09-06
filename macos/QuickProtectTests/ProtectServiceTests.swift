import XCTest

/// Exercises `ProtectService` against a stubbed controller: a `URLProtocol`
/// answers every request in-process, so the tests cover URL construction,
/// headers, JSON handling, the 429 retry, the quality-fallback ladder and
/// stream release without a network, a Keychain or `AppSettings`.
@MainActor
final class ProtectServiceTests: XCTestCase {

    private final class Credentials: ProtectCredentialSource {
        var ipAddress = "192.168.1.10"
        var apiKey = "test-api-key"
        var username = ""
        var password = ""
    }

    private var credentials: Credentials!
    private var service: ProtectService!

    // No super calls: XCTest's async setUp/tearDown defaults are empty, and
    // Swift 6.1 (CI's Xcode 16.4) rejects sending the non-Sendable test case
    // to them from a main-actor class.
    override func setUp() async throws {
        StubController.reset()
        await MainActor.run {
            credentials = Credentials()
            service = ProtectService(settings: credentials, urlProtocolClasses: [StubController.self])
        }
    }

    override func tearDown() async throws {
        StubController.reset()
        await MainActor.run { service = nil }
    }

    // MARK: - Camera list

    func testFetchCamerasDecodesWrappedListAndSendsAPIKey() async {
        StubController.respond { _ in
            (200, Data(#"{"data":[{"id":"cam1","name":"Front","state":"CONNECTED","hasPackageCamera":true}]}"#.utf8))
        }
        await service.fetchCameras(forced: true)

        let request = StubController.requests.first
        XCTAssertEqual(request?.url?.absoluteString,
                       "https://192.168.1.10/proxy/protect/integration/v1/cameras")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-API-Key"), "test-api-key")
        XCTAssertEqual(service.cameras.map(\.id), ["cam1"])
        XCTAssertEqual(service.cameras.first?.secondaryLens?.quality, "package")
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
    }

    func testFetchCamerasUsesConfiguredPort() async {
        credentials.ipAddress = "protect.local:8443"
        StubController.respond { _ in (200, Data("[]".utf8)) }
        await service.fetchCameras(forced: true)
        XCTAssertEqual(StubController.requests.first?.url?.absoluteString,
                       "https://protect.local:8443/proxy/protect/integration/v1/cameras")
    }

    func testFetchCamerasRetriesOnceAfter429() async {
        StubController.respond { _ in
            StubController.requests.count == 1 ? (429, Data()) : (200, Data(#"[{"id":"a","name":"A"}]"#.utf8))
        }
        await service.fetchCameras(forced: true)
        XCTAssertEqual(StubController.requests.count, 2)
        XCTAssertEqual(service.cameras.map(\.id), ["a"])
        XCTAssertNil(service.errorMessage)
    }

    func testFetchCamerasReportsHTTPErrorAndKeepsList() async {
        StubController.respond { _ in (200, Data(#"[{"id":"a","name":"A"}]"#.utf8)) }
        await service.fetchCameras(forced: true)
        StubController.respond { _ in (401, Data("Unauthorized".utf8)) }
        await service.fetchCameras(forced: true)

        XCTAssertEqual(service.cameras.map(\.id), ["a"], "a failed refresh must not blank the grid")
        XCTAssertEqual(service.errorMessage?.hasPrefix("HTTP 401"), true)
        XCTAssertFalse(service.isLoading)
    }

    func testFetchCamerasWithoutAPIKeyFailsBeforeAnyRequest() async {
        credentials.apiKey = ""
        StubController.respond { _ in (200, Data("[]".utf8)) }
        await service.fetchCameras(forced: true)
        XCTAssertTrue(StubController.requests.isEmpty)
        XCTAssertNotNil(service.errorMessage)
    }

    func testThrottledFetchIsSkippedUnlessForced() async {
        StubController.respond { _ in (200, Data("[]".utf8)) }
        await service.fetchCameras(forced: true)
        await service.fetchCameras()
        XCTAssertEqual(StubController.requests.count, 1)
        await service.fetchCameras(forced: true)
        XCTAssertEqual(StubController.requests.count, 2)
    }

    // MARK: - Stream URLs

    func testCreateStreamPostsQualityAndStripsSrtpFlag() async {
        StubController.respond { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "test-api-key")
            let body = request.bodyJSON as? [String: [String]]
            XCTAssertEqual(body?["qualities"], ["high"])
            return (200, Data(#"{"high":"rtsps://192.168.1.10:7441/AbC123?enableSrtp"}"#.utf8))
        }
        let result = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "high")

        XCTAssertEqual(StubController.requests.first?.url?.absoluteString,
                       "https://192.168.1.10/proxy/protect/integration/v1/cameras/cam1/rtsps-stream")
        XCTAssertEqual(result?.quality, "high")
        XCTAssertEqual(result?.url.absoluteString, "rtsps://192.168.1.10:7441/AbC123")
    }

    func testCreateStreamFallsThroughQualityLadder() async {
        StubController.respond { request in
            let quality = (request.bodyJSON as? [String: [String]])?["qualities"]?.first
            return quality == "low"
                ? (200, Data(#"{"low":"rtsps://192.168.1.10:7441/low"}"#.utf8))
                : (400, Data("no such quality".utf8))
        }
        let result = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "high")
        XCTAssertEqual(result?.quality, "low")
        XCTAssertEqual(StubController.requests.count, 3, "high → medium → low")
    }

    func testCreateStreamAbortsLadderOnRateLimit() async {
        StubController.respond { _ in (429, Data()) }
        let result = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "high")
        XCTAssertNil(result)
        XCTAssertEqual(StubController.requests.count, 1, "429 must not multiply requests against the limiter")
    }

    func testSecondaryLensQualityIsNeverSubstituted() async {
        StubController.respond { _ in (400, Data()) }
        let result = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "package")
        XCTAssertNil(result)
        XCTAssertEqual(StubController.requests.count, 1)
    }

    func testReleaseStreamDeletesMatchingQualityOnce() async {
        StubController.respond { _ in (200, Data(#"{"medium":"rtsps://192.168.1.10:7441/m"}"#.utf8)) }
        _ = await service.createRtspStreamURL(for: Self.camera("cam 1"), quality: "medium")

        service.releaseStream(for: "cam 1", quality: "medium")
        service.waitForStreamReleases(timeout: 5)
        service.releaseStream(for: "cam 1", quality: "medium")
        service.waitForStreamReleases(timeout: 5)

        let deletes = StubController.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 1, "an allocation is released exactly once")
        XCTAssertEqual(deletes.first?.url?.absoluteString,
                       "https://192.168.1.10/proxy/protect/integration/v1/cameras/cam%201/rtsps-stream?qualities=medium")
        XCTAssertEqual(deletes.first?.value(forHTTPHeaderField: "X-API-Key"), "test-api-key")
    }

    func testCleanupStreamsReleasesActiveButNotPinned() async {
        StubController.respond { request in
            let quality = (request.bodyJSON as? [String: [String]])?["qualities"]?.first ?? "x"
            return (200, Data("{\"\(quality)\":\"rtsps://192.168.1.10:7441/\(quality)\"}".utf8))
        }
        _ = await service.createRtspStreamURL(for: Self.camera("grid"), quality: "medium")
        _ = await service.createPinnedStreamURL(for: Self.camera("pinned"), quality: "high")

        service.cleanupStreams()
        service.waitForStreamReleases(timeout: 5)
        var deletes = StubController.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.map { $0.url?.path }, ["/proxy/protect/integration/v1/cameras/grid/rtsps-stream"])

        service.cleanupPinnedStreams()
        service.waitForStreamReleases(timeout: 5)
        deletes = StubController.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 2)
        XCTAssertEqual(deletes.last?.url?.path, "/proxy/protect/integration/v1/cameras/pinned/rtsps-stream")
    }

    // MARK: - Helpers

    private static func camera(_ id: String) -> Camera {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Camera.self, from: Data("{\"id\":\"\(id)\",\"name\":\"\(id)\"}".utf8))
    }
}

private extension URLRequest {
    /// `httpBody` is dropped when a request crosses into a `URLProtocol`; the
    /// stream survives, so read the body back from it.
    var bodyJSON: Any? {
        var data = Data()
        if let body = httpBody {
            data = body
        } else if let stream = httpBodyStream {
            stream.open(); defer { stream.close() }
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                data.append(chunk, count: n)
            }
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// In-process stand-in for the controller. Records every request and answers
/// with whatever the current test's handler returns.
private class StubController: URLProtocol {
    typealias Handler = (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?   // guarded by `lock`
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func respond(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let handler = Self._handler
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
