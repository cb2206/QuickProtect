import XCTest

/// Tests for `StreamAllocationLedger`: the controller shares one allocation per
/// camera and quality between the popover and a pinned window, so a DELETE
/// must wait until neither side holds or is creating it.
final class StreamAllocationLedgerTests: XCTestCase {

    private let key = "cam1:high"

    private func holding(_ owners: StreamAllocationLedger.Owner...) -> StreamAllocationLedger {
        let ledger = StreamAllocationLedger()
        for owner in owners {
            ledger.beginCreate(key)
            _ = ledger.endCreate(key, owner: owner, succeeded: true)
        }
        return ledger
    }

    func testKeyCombinesCameraAndQuality() {
        XCTAssertEqual(StreamAllocationLedger.key(cameraId: "cam1", quality: "high"), "cam1:high")
    }

    func testParseSplitsAtFirstColon() {
        let parsed = StreamAllocationLedger.parse("cam 1:package")
        XCTAssertEqual(parsed?.cameraId, "cam 1")
        XCTAssertEqual(parsed?.quality, "package")
        XCTAssertNil(StreamAllocationLedger.parse("nocolon"))
    }

    func testSoleOwnerReleaseIsDue() {
        XCTAssertTrue(holding(.popover).release(key, owner: .popover))
    }

    func testReleaseByNonOwnerIsIgnored() {
        XCTAssertFalse(holding(.popover).release(key, owner: .pinned))
    }

    func testReleaseIsNotRepeated() {
        let ledger = holding(.popover)
        XCTAssertTrue(ledger.release(key, owner: .popover))
        XCTAssertFalse(ledger.release(key, owner: .popover))
    }

    func testPopoverReleaseKeepsAnAllocationAPinnedWindowHolds() {
        let ledger = holding(.popover, .pinned)
        XCTAssertFalse(ledger.release(key, owner: .popover))
        XCTAssertTrue(ledger.release(key, owner: .pinned))
    }

    func testPopoverCleanupSkipsKeysAPinnedWindowHolds() {
        let ledger = holding(.popover, .pinned)
        ledger.beginCreate("cam2:low")
        _ = ledger.endCreate("cam2:low", owner: .popover, succeeded: true)

        XCTAssertEqual(ledger.releaseAll(owner: .popover), ["cam2:low"])
        XCTAssertEqual(ledger.releaseAll(owner: .pinned), [key])
    }

    func testReleaseDuringAnotherOwnersCreationIsDroppedWhenItSucceeds() {
        // Pinning the camera open in focus: the panel closes while the pinned
        // window's POST is in flight. Deleting then would kill the URL the pin
        // is about to receive.
        let ledger = holding(.popover)
        ledger.beginCreate(key)

        XCTAssertEqual(ledger.releaseAll(owner: .popover), [])
        XCTAssertFalse(ledger.endCreate(key, owner: .pinned, succeeded: true))
        XCTAssertTrue(ledger.release(key, owner: .pinned))
    }

    func testReleaseDuringACreationThatFailsIsSentAfterwards() {
        let ledger = holding(.popover)
        ledger.beginCreate(key)

        XCTAssertFalse(ledger.release(key, owner: .popover))
        XCTAssertTrue(ledger.endCreate(key, owner: .pinned, succeeded: false))
    }

    func testDeferredReleaseWaitsForEveryConcurrentCreation() {
        let ledger = holding(.popover)
        ledger.beginCreate(key)
        ledger.beginCreate(key)

        XCTAssertFalse(ledger.release(key, owner: .popover))
        XCTAssertFalse(ledger.endCreate(key, owner: .pinned, succeeded: false))
        XCTAssertTrue(ledger.endCreate(key, owner: .popover, succeeded: false))
    }

    func testFailedCreationWithoutADeferredReleaseSendsNothing() {
        let ledger = StreamAllocationLedger()
        ledger.beginCreate(key)
        XCTAssertFalse(ledger.endCreate(key, owner: .popover, succeeded: false))
    }

    func testConcurrentUseFromManyThreadsStaysConsistent() {
        // Stream-start continuations resume on arbitrary threads; the lock must
        // keep the sets intact (an unguarded Set crashes here).
        let ledger = StreamAllocationLedger()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let k = "cam\(i % 17):high"
            let owner: StreamAllocationLedger.Owner = i.isMultiple(of: 2) ? .popover : .pinned
            ledger.beginCreate(k)
            _ = ledger.endCreate(k, owner: owner, succeeded: true)
            _ = ledger.release(k, owner: owner)
        }
        XCTAssertEqual(ledger.releaseAll(owner: .popover), [])
        XCTAssertEqual(ledger.releaseAll(owner: .pinned), [])
    }
}
