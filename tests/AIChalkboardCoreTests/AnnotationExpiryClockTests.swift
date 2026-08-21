import XCTest
@testable import AIChalkboardCore

/// Pins the clock discipline for annotation expiry.
///
/// Liveness used to be decided by comparing the wall-clock `expiresAt` against
/// `Date()`, while the removal timer used the monotonic clock. A wall-clock
/// jump therefore desynchronised the two: annotations could disappear from
/// every read before their timer fired, or linger past their duration. These
/// tests assert that decisions now follow the monotonic deadline while the
/// wall-clock value survives for RFC 3339 reporting.
final class AnnotationExpiryClockTests: XCTestCase {

    private func makeAnnotation(expiresAt: Date?, expiresAtUptime: Double?) -> Annotation {
        var annotation = Annotation(
            screenId: "1",
            kind: .text(text: "x", x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF",
                        backgroundColorHex: nil, backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            expiresAt: expiresAt
        )
        annotation.expiresAtUptime = expiresAtUptime
        return annotation
    }

    func testMonotonicDeadlineWinsOverWallClock() {
        let uptime = ProcessInfo.processInfo.systemUptime
        // Wall clock says long expired; monotonic says still live. This is the
        // shape of a forward clock jump, and the annotation must stay live.
        let annotation = makeAnnotation(
            expiresAt: Date().addingTimeInterval(-3600),
            expiresAtUptime: uptime + 600
        )
        XCTAssertFalse(annotation.hasExpired(now: Date(), uptime: uptime),
                       "A wall-clock jump must not expire an annotation early.")
    }

    func testMonotonicDeadlineAlsoExpiresDespiteFutureWallClock() {
        let uptime = ProcessInfo.processInfo.systemUptime
        // The backward-jump shape: wall clock says far in the future, but the
        // monotonic deadline has genuinely passed.
        let annotation = makeAnnotation(
            expiresAt: Date().addingTimeInterval(3600),
            expiresAtUptime: uptime - 1
        )
        XCTAssertTrue(annotation.hasExpired(now: Date(), uptime: uptime),
                      "An elapsed monotonic deadline must expire the annotation.")
    }

    func testFallsBackToWallClockWhenMonotonicIsAbsent() {
        // Decoded annotations carry no monotonic deadline; behaviour there must
        // match the original wall-clock semantics exactly.
        let uptime = ProcessInfo.processInfo.systemUptime
        let expired = makeAnnotation(expiresAt: Date().addingTimeInterval(-1), expiresAtUptime: nil)
        let live = makeAnnotation(expiresAt: Date().addingTimeInterval(60), expiresAtUptime: nil)
        XCTAssertTrue(expired.hasExpired(now: Date(), uptime: uptime))
        XCTAssertFalse(live.hasExpired(now: Date(), uptime: uptime))
    }

    func testPersistentAnnotationNeverExpires() {
        let annotation = makeAnnotation(expiresAt: nil, expiresAtUptime: nil)
        XCTAssertFalse(annotation.hasExpired(now: Date(), uptime: ProcessInfo.processInfo.systemUptime))
        XCTAssertNil(annotation.remainingSeconds(now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
                     "A persistent annotation reports no remaining time.")
    }

    func testRemainingSecondsNeverGoesNegative() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let annotation = makeAnnotation(expiresAt: Date().addingTimeInterval(-500), expiresAtUptime: uptime - 500)
        XCTAssertEqual(annotation.remainingSeconds(now: Date(), uptime: uptime), 0)
    }

    func testStoreStampsAMonotonicDeadlineForADuration() throws {
        let store = AnnotationStore()
        let annotation = makeAnnotation(expiresAt: nil, expiresAtUptime: nil)
        _ = store.addWithOutcome(annotation, durationSeconds: 120)

        let stored = try XCTUnwrap(store.getAll().first)
        XCTAssertNotNil(stored.expiresAt, "The wall-clock value must survive for RFC 3339 reporting.")
        let deadline = try XCTUnwrap(stored.expiresAtUptime, "A duration must produce a monotonic deadline.")
        let expected = ProcessInfo.processInfo.systemUptime + 120
        XCTAssertEqual(deadline, expected, accuracy: 5)
    }

    func testStoreDerivesAMonotonicDeadlineFromAnExplicitExpiresAt() throws {
        // A caller can supply expiresAt directly, with no durationSeconds. The
        // monotonic twin must still be derived, or that annotation would keep
        // deciding liveness on the wall clock.
        let store = AnnotationStore()
        let annotation = makeAnnotation(expiresAt: Date().addingTimeInterval(90), expiresAtUptime: nil)
        _ = store.addWithOutcome(annotation)

        let stored = try XCTUnwrap(store.getAll().first)
        let deadline = try XCTUnwrap(stored.expiresAtUptime)
        XCTAssertEqual(deadline, ProcessInfo.processInfo.systemUptime + 90, accuracy: 5)
    }

    func testAlreadyPastDueExplicitExpiryPinsToNowRatherThanGoingNegative() throws {
        let store = AnnotationStore()
        let annotation = makeAnnotation(expiresAt: Date().addingTimeInterval(-30), expiresAtUptime: nil)
        _ = store.addWithOutcome(annotation)
        // It is immediately expired, so it must not be readable as live.
        XCTAssertTrue(store.getAll().isEmpty, "An already-elapsed annotation must not read as live.")
    }

    func testMonotonicDeadlineIsNotPutOnTheWire() throws {
        // expiresAtUptime is process-local; encoding it would change the public
        // annotation shape and would be meaningless to any other process.
        let annotation = makeAnnotation(
            expiresAt: Date().addingTimeInterval(60),
            expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60
        )
        let data = try JSONEncoder().encode(annotation)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["expiresAtUptime"], "The monotonic deadline must stay off the wire.")
        XCTAssertNotNil(object["expiresAt"], "The wall-clock deadline must remain on the wire.")
    }
}
