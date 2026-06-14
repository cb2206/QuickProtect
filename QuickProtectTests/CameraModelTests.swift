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
        XCTAssertFalse(camera.canZoom)
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
        XCTAssertFalse(camera.canZoom, "pan/tilt-only camera must not report optical zoom")
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
        XCTAssertTrue(camera.canZoom)
    }

    func testDecodeZoomRatioSetsCanZoom() throws {
        // Modern firmware (e.g. G6 PTZ) reports canOpticalZoom=false and
        // expresses the zoom lens via featureFlags.zoom.ratio instead.
        let json = """
        {
            "id": "g6ptz",
            "name": "Backyard",
            "state": "CONNECTED",
            "channels": [],
            "featureFlags": {
                "isPtz": true,
                "canOpticalZoom": false,
                "zoom": { "ratio": 10, "steps": { "min": 0, "max": 1000, "step": 1 } }
            }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertTrue(camera.isPtz)
        XCTAssertTrue(camera.canZoom, "zoom.ratio > 1 should set canZoom")
    }

    func testDecodeZoomRatioOneIsNotZoom() throws {
        // Fixed-lens cameras report zoom.ratio = 1 with null steps.
        let json = """
        {
            "id": "fixed2",
            "name": "Doorbell",
            "state": "CONNECTED",
            "channels": [],
            "featureFlags": {
                "isPtz": false,
                "canOpticalZoom": false,
                "zoom": { "ratio": 1, "steps": { "min": null, "max": null, "step": null } }
            }
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertFalse(camera.isPtz)
        XCTAssertFalse(camera.canZoom)
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
        XCTAssertFalse(camera.canZoom)
    }

    // MARK: - Secondary lens (package camera)

    func testDecodeSecondaryLensFromPackageFlag() throws {
        let json = """
        {
            "id": "doorbell1",
            "name": "Doorbell",
            "state": "CONNECTED",
            "channels": [],
            "hasPackageCamera": true
        }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertNotNil(camera.secondaryLens)
        XCTAssertEqual(camera.secondaryLens?.quality, "package")
    }

    func testDecodeNoSecondaryLensByDefault() throws {
        let json = """
        { "id": "cam1", "name": "Front", "state": "CONNECTED", "channels": [] }
        """.data(using: .utf8)!

        let camera = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertNil(camera.secondaryLens)
    }

    func testSecondaryLensSurvivesRoundTrip() throws {
        let json = """
        {
            "id": "doorbell2",
            "name": "Doorbell",
            "state": "CONNECTED",
            "channels": [],
            "hasPackageCamera": true
        }
        """.data(using: .utf8)!

        let original = try JSONDecoder().decode(Camera.self, from: json)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Camera.self, from: encoded)
        XCTAssertEqual(decoded.secondaryLens?.quality, "package")
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
        XCTAssertFalse(camera.canZoom)
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

    // MARK: - StreamQuality

    func testStreamQualityAutoResolvesByFocus() {
        XCTAssertEqual(StreamQuality.auto.resolve(focused: false), .low)
        XCTAssertEqual(StreamQuality.auto.resolve(focused: true), .high)
    }

    func testStreamQualityExplicitResolvesUnchanged() {
        for q in [StreamQuality.high, .medium, .low] {
            XCTAssertEqual(q.resolve(focused: false), q)
            XCTAssertEqual(q.resolve(focused: true), q)
        }
    }

    func testStreamQualityRankOrdersResolutions() {
        XCTAssertLessThan(StreamQuality.low.rank, StreamQuality.medium.rank)
        XCTAssertLessThan(StreamQuality.medium.rank, StreamQuality.high.rank)
        // Leaving focus (high → low resolved) is a downgrade…
        XCTAssertLessThan(StreamQuality.auto.resolve(focused: false).rank,
                          StreamQuality.auto.resolve(focused: true).rank)
    }

    func testStreamQualityApiValue() {
        XCTAssertEqual(StreamQuality.high.apiValue, "high")
        XCTAssertEqual(StreamQuality.medium.apiValue, "medium")
        XCTAssertEqual(StreamQuality.low.apiValue, "low")
        // A raw .auto that escapes resolution falls back to medium, never "auto".
        XCTAssertEqual(StreamQuality.auto.apiValue, "medium")
    }
}
