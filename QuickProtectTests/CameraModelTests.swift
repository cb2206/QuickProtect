import XCTest

final class CameraModelTests: XCTestCase {

    // MARK: - Integration API shape (no featureFlags)

    func testDecodeIntegrationAPI() throws {
        let json = """
        {
            "id": "cam1",
            "name": "Front Door",
            "state": "CONNECTED",
            "channels": []
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertEqual(camera.id, "cam1")
        XCTAssertEqual(camera.name, "Front Door")
        XCTAssertEqual(camera.state, "CONNECTED")
        XCTAssertTrue(camera.isOnline)
        XCTAssertFalse(camera.isPtz)
    }

    // MARK: - Classic API shape with featureFlags

    func testDecodePtzCamera() throws {
        let json = """
        {
            "id": "ptz1",
            "name": "Backyard",
            "state": "CONNECTED",
            "channels": [],
            "featureFlags": {
                "isPtz": true,
                "canOpticalZoom": false
            }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertTrue(camera.isPtz)
    }

    func testDecodeOpticalZoomSetsPtz() throws {
        let json = """
        {
            "id": "oz1",
            "name": "Garage",
            "state": "CONNECTED",
            "channels": [],
            "featureFlags": {
                "isPtz": false,
                "canOpticalZoom": true
            }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertTrue(camera.isPtz, "canOpticalZoom should also set isPtz")
    }

    func testDecodeNonPtzCamera() throws {
        let json = """
        {
            "id": "fixed1",
            "name": "Doorbell",
            "state": "CONNECTED",
            "channels": [],
            "featureFlags": {
                "isPtz": false,
                "canOpticalZoom": false
            }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertFalse(camera.isPtz)
    }

    // MARK: - Partial/missing fields

    func testDecodeMissingState() throws {
        let json = """
        { "id": "x", "name": "Test" }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertEqual(camera.state, "UNKNOWN")
        XCTAssertFalse(camera.isOnline)
    }

    func testDecodePartialFeatureFlags() throws {
        // featureFlags present but missing canOpticalZoom
        let json = """
        {
            "id": "p1",
            "name": "Partial",
            "state": "CONNECTED",
            "featureFlags": { "isPtz": true }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertTrue(camera.isPtz)
    }

    // MARK: - Channel decoding

    func testDecodeChannels() throws {
        let json = """
        {
            "id": "ch1",
            "name": "WithChannels",
            "state": "CONNECTED",
            "channels": [
                { "id": 0, "name": "High", "rtspAlias": "abc123", "isRtspEnabled": true },
                { "id": 1, "name": "Medium", "rtspAlias": "def456", "isRtspEnabled": false }
            ]
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertEqual(camera.channels.count, 2)
        XCTAssertEqual(camera.channels[0].rtspAlias, "abc123")
        XCTAssertTrue(camera.channels[0].isRtspEnabled)
        XCTAssertEqual(camera.primaryRtspAlias, "abc123")
    }

    // MARK: - Encode round-trip

    func testEncodeDoesNotIncludeFeatureFlags() throws {
        let json = """
        {
            "id": "enc1",
            "name": "Encode Test",
            "state": "CONNECTED",
            "channels": [],
            "featureFlags": { "isPtz": true, "canOpticalZoom": true }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertTrue(camera.isPtz)

        // Re-encode — featureFlags should not appear in output
        let encoded = try JSONEncoder().encode(camera)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertNil(dict["featureFlags"], "featureFlags should not be encoded")
        XCTAssertEqual(dict["id"] as? String, "enc1")
    }

    func testEncodeDecodeRoundTrip() throws {
        let json = """
        {
            "id": "rt1",
            "name": "Round Trip",
            "state": "CONNECTED",
            "channels": [
                { "id": 0, "name": "High", "rtspAlias": "stream1", "isRtspEnabled": true }
            ]
        }
        """.data(using: .utf8)!

        let original = try JSONDecoder().decode(Camera.self, from: json)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Camera.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.state, original.state)
        XCTAssertEqual(decoded.channels.count, original.channels.count)
        XCTAssertEqual(decoded.primaryRtspAlias, "stream1")
        // isPtz is lost in round-trip since featureFlags isn't encoded — expected
        XCTAssertFalse(decoded.isPtz)
    }
}
