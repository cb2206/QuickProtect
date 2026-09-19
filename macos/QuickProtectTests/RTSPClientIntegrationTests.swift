import XCTest
import AVFoundation

/// Drives the real `RTSPClient` against a local RTSPS server: mediamtx serves a
/// self-signed certificate, ffmpeg publishes a synthetic test pattern into it,
/// and the client must negotiate TLS (trust-on-first-use pin), run the RTSP
/// handshake, demux interleaved RTP, reassemble NALs and put a first frame on
/// its display layer — the whole streaming core, without a controller.
///
/// Skipped when `mediamtx`, `ffmpeg` or `openssl` is not on PATH, so it runs on
/// developer Macs that have them (`brew install mediamtx ffmpeg`) and stays
/// silent in CI.
final class RTSPClientIntegrationTests: XCTestCase {

    private var workDir: URL!
    private var processes: [Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        for tool in ["mediamtx", "ffmpeg", "openssl"] where Self.path(of: tool) == nil {
            throw XCTSkip("\(tool) not on PATH — install with `brew install mediamtx ffmpeg`")
        }
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qp-rtsps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for p in processes where p.isRunning { p.terminate() }
        for p in processes { p.waitUntilExit() }
        processes.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        // The server's certificate is fresh every run; drop the pin it left
        // behind so the next run's first-use trust isn't a "changed" rejection.
        CertificateTrust.Store().setPinned(nil, host: "127.0.0.1")
        CertificateTrust.Store().setPending(nil, host: "127.0.0.1")
        try super.tearDownWithError()
    }

    func testDecodesH264OverRTSPS() throws {
        try streamAndExpectFrame(encoder: "libx264", extraArgs: ["-x264-params", "repeat-headers=1"])
    }

    func testDecodesH265OverRTSPS() throws {
        try streamAndExpectFrame(encoder: "libx265", extraArgs: ["-x265-params", "repeat-headers=1"])
    }

    func testChangedCertificateIsRejected() throws {
        // Pin a bogus key first: the server's real key must then be refused and
        // parked as pending, and no frame may arrive.
        CertificateTrust.Store().setPinned(String(repeating: "0", count: 64), host: "127.0.0.1")
        let (client, url) = try launchServerAndClient(encoder: "libx264", extraArgs: [])
        client.connect(to: url)
        XCTAssertFalse(pump(until: { client.hasFrame }, timeout: 6))
        XCTAssertNotNil(CertificateTrust.Store().pending(host: "127.0.0.1"))
        client.disconnect()
    }

    // MARK: - Helpers

    private func streamAndExpectFrame(encoder: String, extraArgs: [String]) throws {
        CertificateTrust.Store().setPinned(nil, host: "127.0.0.1")
        let (client, url) = try launchServerAndClient(encoder: encoder, extraArgs: extraArgs)
        client.connect(to: url)
        XCTAssertTrue(pump(until: { client.hasFrame }, timeout: 25), "no frame within 25 s (error: \(client.error ?? "none"))")
        XCTAssertTrue(client.isConnected)
        XCTAssertNil(client.error)
        XCTAssertEqual(client.videoDimensions, CGSize(width: 320, height: 240))
        // First use pinned the server's key.
        XCTAssertNotNil(CertificateTrust.Store().pinned(host: "127.0.0.1"))
        client.disconnect()
        XCTAssertTrue(pump(until: { !client.isConnected }, timeout: 5))
    }

    /// Starts mediamtx (RTSP + RTSPS with a fresh self-signed certificate) and
    /// an ffmpeg publisher, returning a client and the rtsps:// URL to play.
    private func launchServerAndClient(encoder: String, extraArgs: [String]) throws -> (RTSPClient, URL) {
        let key = workDir.appendingPathComponent("server.key").path
        let crt = workDir.appendingPathComponent("server.crt").path
        try run("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                            "-keyout", key, "-out", crt, "-days", "2", "-subj", "/CN=127.0.0.1",
                            "-addext", "subjectAltName=IP:127.0.0.1"]).waitUntilExit()

        let rtspPort = Self.freePort()
        let rtspsPort = Self.freePort()
        let config = """
            logLevel: error
            api: false
            metrics: false
            pprof: false
            playback: false
            rtmp: false
            hls: false
            webrtc: false
            srt: false
            rtsp: true
            rtspTransports: [tcp]
            rtspEncryption: "optional"
            rtspAddress: 127.0.0.1:\(rtspPort)
            rtspsAddress: 127.0.0.1:\(rtspsPort)
            rtspServerKey: \(key)
            rtspServerCert: \(crt)
            paths:
              all_others:

            """
        let configPath = workDir.appendingPathComponent("mediamtx.yml")
        try config.write(to: configPath, atomically: true, encoding: .utf8)
        processes.append(try run("mediamtx", [configPath.path]))
        XCTAssertTrue(Self.waitForPort(rtspPort, timeout: 10), "mediamtx did not start")

        var args = ["-hide_banner", "-loglevel", "error", "-re",
                    "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15", "-t", "40",
                    "-c:v", encoder, "-preset", "ultrafast", "-tune", "zerolatency",
                    "-g", "15", "-pix_fmt", "yuv420p"]
        args += extraArgs
        args += ["-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:\(rtspPort)/test"]
        let publisher = try run("ffmpeg", args)
        processes.append(publisher)
        // Let the publisher's ANNOUNCE/RECORD land before a player subscribes.
        Thread.sleep(forTimeInterval: 1.5)
        if !publisher.isRunning { throw XCTSkip("ffmpeg could not publish with \(encoder) (encoder missing?)") }

        let client = RTSPClient()
        return (client, URL(string: "rtsps://127.0.0.1:\(rtspsPort)/test")!)
    }

    /// Runs the main run loop until `condition` holds or the timeout passes —
    /// the client publishes its state on the main queue.
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func path(of tool: String) -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in candidates where FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)") {
            return "\(dir)/\(tool)"
        }
        return nil
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.path(of: tool)))
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private static func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func waitForPort(_ port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = in_port_t(port).bigEndian
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(sock)
            if ok { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
