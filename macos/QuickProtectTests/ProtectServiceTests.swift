import Combine
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

    // MARK: - Certificate change

    /// A service reading pins from a scratch store, plus that store.
    private func makeServiceWithScratchPins() -> (ProtectService, CertificateTrust.Store, () -> Void) {
        let suite = "ProtectServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = CertificateTrust.Store(defaults: defaults)
        let service = ProtectService(settings: credentials, urlProtocolClasses: [StubController.self],
                                     certificateStore: store)
        return (service, store, { defaults.removePersistentDomain(forName: suite) })
    }

    /// The reported bug: a rejected certificate reaches the fetch as
    /// `URLError.cancelled`, which used to be swallowed as a teardown and left
    /// a stale "can't connect" error on screen.
    func testCancelledFetchWithPendingCertificateReportsCertificateChange() async {
        let (service, store, cleanup) = makeServiceWithScratchPins()
        defer { cleanup() }
        _ = CertificateTrust.evaluate(host: "192.168.1.10", fingerprint: "aa", store: store)
        _ = CertificateTrust.evaluate(host: "192.168.1.10", fingerprint: "bb", store: store)
        StubController.fail(with: URLError(.cancelled))

        await service.fetchCameras(forced: true)

        XCTAssertEqual(service.certificateChange,
                       CertificateTrust.Change(host: "192.168.1.10", trustedFingerprint: "aa", newFingerprint: "bb"))
        XCTAssertEqual(service.errorMessage, ProtectService.certificateChangedMessage)
        XCTAssertFalse(service.isLoading)
    }

    func testCancelledFetchWithoutPendingCertificateStaysSilent() async {
        let (service, _, cleanup) = makeServiceWithScratchPins()
        defer { cleanup() }
        StubController.fail(with: URLError(.cancelled))

        await service.fetchCameras(forced: true)

        XCTAssertNil(service.certificateChange)
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
    }

    func testCertificateChangeFollowsTheConfiguredController() {
        let (service, store, cleanup) = makeServiceWithScratchPins()
        defer { cleanup() }
        _ = CertificateTrust.evaluate(host: "10.0.0.5", fingerprint: "aa", store: store)
        _ = CertificateTrust.evaluate(host: "10.0.0.5", fingerprint: "bb", store: store)
        service.refreshCertificateChange()
        XCTAssertNil(service.certificateChange, "another controller's pending key is not ours")

        credentials.ipAddress = "10.0.0.5"
        service.refreshCertificateChange()
        XCTAssertEqual(service.certificateChange?.newFingerprint, "bb")
    }

    func testTrustingPendingCertificateClearsTheChange() {
        let (service, store, cleanup) = makeServiceWithScratchPins()
        defer { cleanup() }
        _ = CertificateTrust.evaluate(host: "192.168.1.10", fingerprint: "aa", store: store)
        _ = CertificateTrust.evaluate(host: "192.168.1.10", fingerprint: "bb", store: store)
        service.refreshCertificateChange()
        XCTAssertNotNil(service.certificateChange)

        service.trustPendingCertificate(host: "192.168.1.10")

        XCTAssertNil(service.certificateChange)
        XCTAssertEqual(store.pinned(host: "192.168.1.10"), "bb")
    }

    /// Rejections happen on URLSession's and the RTSP clients' queues; the
    /// published state must follow without anyone calling refresh.
    func testRejectionOnAnotherQueuePublishesTheChange() async {
        let (service, store, cleanup) = makeServiceWithScratchPins()
        defer { cleanup() }
        _ = CertificateTrust.evaluate(host: "192.168.1.10", fingerprint: "aa", store: store)
        let published = expectation(description: "certificateChange published")
        let subscription = service.$certificateChange.dropFirst().sink { change in
            if change != nil { published.fulfill() }
        }
        DispatchQueue.global().async {
            _ = CertificateTrust.evaluate(host: "192.168.1.10", fingerprint: "bb", store: store)
        }
        await fulfillment(of: [published], timeout: 2)
        subscription.cancel()
    }

    func testFetchFailureClassification() {
        let cancelled = URLError(.cancelled)
        let offline = URLError(.cannotConnectToHost)
        typealias Svc = ProtectService
        XCTAssertEqual(Svc.classifyFetchFailure(cancelled, taskCancelled: true, certificateChanged: true), .ignore)
        XCTAssertEqual(Svc.classifyFetchFailure(CancellationError(), taskCancelled: false, certificateChanged: true), .ignore)
        XCTAssertEqual(Svc.classifyFetchFailure(cancelled, taskCancelled: false, certificateChanged: true), .certificateChanged)
        XCTAssertEqual(Svc.classifyFetchFailure(cancelled, taskCancelled: false, certificateChanged: false), .ignore)
        XCTAssertEqual(Svc.classifyFetchFailure(offline, taskCancelled: false, certificateChanged: true), .certificateChanged)
        XCTAssertEqual(Svc.classifyFetchFailure(offline, taskCancelled: false, certificateChanged: false), .failed)
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

    func testPopoverCleanupKeepsAnAllocationAPinnedWindowHolds() async {
        StubController.respond { _ in (200, Data(#"{"high":"rtsps://192.168.1.10:7441/h"}"#.utf8)) }
        _ = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "high")
        _ = await service.createPinnedStreamURL(for: Self.camera("cam1"), quality: "high")

        service.cleanupStreams()
        service.waitForStreamReleases(timeout: 5)
        XCTAssertTrue(Self.deletes.isEmpty, "the pinned window still plays cam1:high")

        service.releasePinnedStream(for: "cam1", quality: "high")
        service.waitForStreamReleases(timeout: 5)
        XCTAssertEqual(Self.deletes.map { $0.url?.query }, ["qualities=high"])
    }

    func testPopoverCleanupRacingAnInFlightPinnedPostDoesNotDelete() async throws {
        // Pin a camera open in focus with keep-alive off: the panel hides and
        // cleans up while the pin's POST for the same key is still in flight.
        let gate = DispatchSemaphore(value: 0)
        StubController.respond { _ in (200, Data(#"{"high":"rtsps://192.168.1.10:7441/h"}"#.utf8)) }
        _ = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "high")
        StubController.respond { _ in
            _ = gate.wait(timeout: .now() + 5)
            return (200, Data(#"{"high":"rtsps://192.168.1.10:7441/h"}"#.utf8))
        }

        let service = self.service!
        let pin = Task { await service.createPinnedStreamURL(for: Self.camera("cam1"), quality: "high") }
        try await Self.waitForPosts(2)

        service.cleanupStreams()
        service.waitForStreamReleases(timeout: 5)
        XCTAssertTrue(Self.deletes.isEmpty, "the pin's creation is in flight")

        gate.signal()
        let pinned = await pin.value
        service.waitForStreamReleases(timeout: 5)
        XCTAssertEqual(pinned?.quality, "high")
        XCTAssertTrue(Self.deletes.isEmpty, "the pin now owns the allocation")

        service.cleanupPinnedStreams()
        service.waitForStreamReleases(timeout: 5)
        XCTAssertEqual(Self.deletes.count, 1)
    }

    func testPopoverReleaseDeferredByAFailedPinnedPostIsSentAfterwards() async throws {
        let gate = DispatchSemaphore(value: 0)
        StubController.respond { _ in (200, Data(#"{"high":"rtsps://192.168.1.10:7441/h"}"#.utf8)) }
        _ = await service.createRtspStreamURL(for: Self.camera("cam1"), quality: "high")
        StubController.respond { request in
            guard request.httpMethod == "POST" else { return (200, Data()) }
            _ = gate.wait(timeout: .now() + 5)
            return (429, Data())
        }

        let service = self.service!
        let pin = Task { await service.createPinnedStreamURL(for: Self.camera("cam1"), quality: "high") }
        try await Self.waitForPosts(2)

        service.cleanupStreams()
        service.waitForStreamReleases(timeout: 5)
        XCTAssertTrue(Self.deletes.isEmpty)

        gate.signal()
        let pinned = await pin.value
        service.waitForStreamReleases(timeout: 5)
        XCTAssertNil(pinned)
        XCTAssertEqual(Self.deletes.count, 1, "nobody holds cam1:high any more")
    }

    // MARK: - Helpers

    private static var deletes: [URLRequest] {
        StubController.requests.filter { $0.httpMethod == "DELETE" }
    }

    /// Yields until the stub has seen `count` POSTs (bounded at ~5 s).
    private static func waitForPosts(_ count: Int) async throws {
        for _ in 0..<500 {
            if StubController.requests.filter({ $0.httpMethod == "POST" }).count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("expected \(count) POSTs")
    }

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
    nonisolated(unsafe) private static var _failure: URLError?

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func respond(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    /// Fail every request with `error` instead of answering.
    static func fail(with error: URLError) {
        lock.lock(); defer { lock.unlock() }
        _failure = error
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requests = []
        _failure = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(request)
        let handler = Self._handler
        let failure = Self._failure
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

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
