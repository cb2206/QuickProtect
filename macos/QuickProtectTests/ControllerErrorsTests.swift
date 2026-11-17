import XCTest

/// `ControllerErrors` maps failures to the catalog messages the .NET port
/// shares, and every one of them is translated in every shipped language.
final class ControllerErrorsTests: XCTestCase {

    private typealias Msg = ControllerErrors
    private typealias APIError = ProtectService.APIError

    func testHTTPStatusesMapToCatalogMessages() {
        XCTAssertEqual(Msg.describe(APIError.http(401, #"{"error":"Unauthorized"}"#)), Msg.apiKeyRejected)
        XCTAssertEqual(Msg.describe(APIError.http(403, "")), Msg.apiKeyRejected)
        XCTAssertEqual(Msg.describe(APIError.http(429, "")), Msg.busy)
        XCTAssertEqual(Msg.describe(APIError.http(500, "")), Msg.serverError)
        XCTAssertEqual(Msg.describe(APIError.http(503, "")), Msg.serverError)
        XCTAssertEqual(Msg.describe(APIError.http(400, #"{"error":"bad"}"#)), Msg.unexpectedResponse)
        XCTAssertEqual(Msg.describe(APIError.invalidURL), Msg.invalidAddress)
        XCTAssertEqual(Msg.describe(APIError.notHTTP), Msg.unexpectedResponse)
    }

    /// A camera's own web server (lighttpd) answers the Integration API path
    /// with an HTML 404 — the user entered the camera's IP, not the console's.
    func testCameraWebServerRepliesPointAtTheConsoleAddress() {
        let html = "\n<?xml version=\"1.0\"?>\n<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0\"><html>404</html>"
        XCTAssertEqual(Msg.describe(APIError.http(404, html)), Msg.notAConsole)
        XCTAssertEqual(Msg.describe(APIError.http(404, "")), Msg.notAConsole)
        XCTAssertEqual(Msg.describe(APIError.http(405, html)), Msg.notAConsole)
        XCTAssertEqual(Msg.describe(APIError.notJSON(html)), Msg.notAConsole)
        XCTAssertEqual(APIError.http(404, html).localizedDescription, Msg.notAConsole)
    }

    func testHTMLDetectionIgnoresLeadingWhitespaceOnly() {
        XCTAssertTrue(Msg.looksLikeHTML("  \r\n<html>"))
        XCTAssertFalse(Msg.looksLikeHTML(#"{"data":[]}"#))
        XCTAssertFalse(Msg.looksLikeHTML("[]"))
        XCTAssertFalse(Msg.looksLikeHTML(""))
    }

    func testAPIErrorDescriptionNeverShowsTheResponseBody() {
        let error: Error = APIError.http(401, #"{"error":"Unauthorized"}"#)
        XCTAssertEqual(error.localizedDescription, Msg.apiKeyRejected)
    }

    func testURLErrorsMapToCatalogMessages() {
        XCTAssertEqual(Msg.describe(URLError(.cannotFindHost)), Msg.hostNotFound)
        XCTAssertEqual(Msg.describe(URLError(.dnsLookupFailed)), Msg.hostNotFound)
        XCTAssertEqual(Msg.describe(URLError(.timedOut)), Msg.timedOut)
        XCTAssertEqual(Msg.describe(URLError(.notConnectedToInternet)), Msg.unreachable)
        XCTAssertEqual(Msg.describe(URLError(.cannotConnectToHost)), Msg.unreachable)
        XCTAssertEqual(Msg.describe(URLError(.secureConnectionFailed)), Msg.secureConnectionFailed)
        XCTAssertEqual(Msg.describe(URLError(.serverCertificateUntrusted)), Msg.secureConnectionFailed)
        XCTAssertEqual(Msg.describe(URLError(.badServerResponse)), Msg.unexpectedResponse)
        XCTAssertEqual(Msg.describe(URLError(.cannotParseResponse)), Msg.unreadableResponse)
    }

    func testRefusedConnectionIsToldApartByItsSocketError() {
        let refused = URLError(.cannotConnectToHost, userInfo: [
            "_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": Int(ECONNREFUSED)
        ])
        let unreachable = URLError(.cannotConnectToHost, userInfo: [
            "_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": Int(EHOSTUNREACH)
        ])
        XCTAssertEqual(Msg.describe(refused), Msg.connectionRefused)
        XCTAssertEqual(Msg.describe(unreachable), Msg.unreachable)
    }

    func testUndecodableListAndUnknownFailuresFallBack() throws {
        let decoding = try XCTUnwrap(decodingError())
        XCTAssertEqual(Msg.describe(decoding), Msg.unreadableResponse)
        let other = URLError(.userAuthenticationRequired)
        XCTAssertEqual(Msg.describe(other), other.localizedDescription)
    }

    /// The catalog keys are the English literals; a message missing from a
    /// language would show English there.
    func testEveryMessageIsTranslatedInEveryLanguage() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QuickProtect/Localizable.xcstrings")
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let messages = [Msg.hostNotFound, Msg.connectionRefused, Msg.unreachable, Msg.timedOut,
                        Msg.secureConnectionFailed, Msg.invalidAddress, Msg.apiKeyRejected, Msg.busy,
                        Msg.serverError, Msg.unexpectedResponse, Msg.unreadableResponse, Msg.notAConsole]
        for message in messages {
            let localizations = strings[message]?["localizations"] as? [String: Any] ?? [:]
            for language in ["de", "es", "fr", "it", "nl", "pt-BR"] {
                XCTAssertNotNil(localizations[language], "\"\(message)\" has no \(language) translation")
            }
        }
    }

    private func decodingError() -> Error? {
        struct Probe: Decodable { let id: String }
        do {
            _ = try JSONDecoder().decode(Probe.self, from: Data("{}".utf8))
            return nil
        } catch {
            return error
        }
    }
}
