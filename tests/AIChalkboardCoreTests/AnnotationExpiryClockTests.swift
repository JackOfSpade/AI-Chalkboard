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

    func testMalformedMonotonicDeadlineFallsBackToWallClock() {
        // The store normally stamps a finite uptime deadline, but the model is
        // public and mutable. A NaN comparison is always false, so trusting it
        // blindly would make an otherwise expired annotation live forever.
        let now = Date()
        let annotation = makeAnnotation(
            expiresAt: now.addingTimeInterval(-1),
            expiresAtUptime: .nan
        )

        XCTAssertTrue(annotation.hasExpired(now: now, uptime: ProcessInfo.processInfo.systemUptime))
        XCTAssertEqual(annotation.remainingSeconds(now: now, uptime: ProcessInfo.processInfo.systemUptime), 0)
    }

    func testNonFiniteCallerUptimeFallsBackToWallClock() {
        let now = Date()
        let annotation = makeAnnotation(
            expiresAt: now.addingTimeInterval(-1),
            expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60
        )

        XCTAssertTrue(annotation.hasExpired(now: now, uptime: .infinity))
        XCTAssertEqual(annotation.remainingSeconds(now: now, uptime: .infinity), 0)
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

    func testUpdateKeepsTheMonotonicDeadlineOfTheAnnotationItReplaces() throws {
        // The update path used to store the replacement verbatim, dropping
        // `expiresAtUptime` and quietly reverting a timed annotation to
        // wall-clock liveness -- so a machine asleep longer than the duration
        // made an UPDATED annotation vanish on wake while an un-updated twin
        // survived. The replacement the MCP layer builds carries `expiresAt`
        // forward but has no monotonic twin of its own (that value is never on
        // the wire), which is exactly the shape reproduced here.
        //
        // The stored deadline is first moved to a SENTINEL instant that no
        // re-derivation could produce. Carrying `old.expiresAtUptime` forward
        // and re-deriving from `expiresAt` land on the same number under a
        // still wall clock, so without this the assertion below passes even
        // with the carry-forward deleted -- the branch would be untested.
        let store = AnnotationStore()
        let original = makeAnnotation(expiresAt: nil, expiresAtUptime: nil)
        _ = store.addWithOutcome(original, durationSeconds: 300)
        let stored = try XCTUnwrap(store.getAll().first)

        // 300s from `expiresAt`, so a re-derivation cannot reach it, yet still
        // comfortably live so the annotation is not swept before the update.
        let sentinelDeadline = ProcessInfo.processInfo.systemUptime + 9_000
        var restamp = Annotation(
            id: stored.id, screenId: stored.screenId, kind: stored.kind, colorHex: stored.colorHex,
            label: stored.label, appId: stored.appId, appName: stored.appName,
            expiresAt: stored.expiresAt, opacity: stored.opacity, offsetX: stored.offsetX,
            offsetY: stored.offsetY, zIndex: stored.zIndex, createdAt: stored.createdAt
        )
        restamp.expiresAtUptime = sentinelDeadline
        XCTAssertEqual(store.updateWithOutcome(id: stored.id, with: restamp), .updated)
        XCTAssertEqual(try XCTUnwrap(store.get(id: stored.id)).expiresAtUptime, sentinelDeadline,
                       "A replacement that brings its own monotonic deadline keeps it.")

        let replacement = Annotation(
            id: stored.id, screenId: stored.screenId, kind: stored.kind, colorHex: stored.colorHex,
            label: stored.label, appId: stored.appId, appName: stored.appName,
            expiresAt: stored.expiresAt, opacity: 0.5, offsetX: 10, offsetY: 20,
            zIndex: stored.zIndex, createdAt: stored.createdAt
        )
        XCTAssertNil(replacement.expiresAtUptime, "The replacement must arrive without a monotonic twin.")
        XCTAssertEqual(store.updateWithOutcome(id: stored.id, with: replacement), .updated)

        let updated = try XCTUnwrap(store.get(id: stored.id))
        let deadlineAfterUpdate = try XCTUnwrap(
            updated.expiresAtUptime,
            "An updated timed annotation must keep deciding liveness on the monotonic clock."
        )
        XCTAssertEqual(deadlineAfterUpdate, sentinelDeadline,
                       "The ORIGINAL monotonic instant must be carried forward exactly, not re-derived.")
        XCTAssertEqual(updated.offsetX, 10, "The patch itself must still have been applied.")
    }

    func testUpdateThatClearsTheWallClockDeadlineDoesNotInheritTheOldMonotonicOne() throws {
        // The mirror image: a replacement that drops `expiresAt` is asking for
        // a persistent annotation. Inheriting the previous monotonic deadline
        // would expire it anyway, because `hasExpired` prefers that clock.
        let store = AnnotationStore()
        _ = store.addWithOutcome(makeAnnotation(expiresAt: nil, expiresAtUptime: nil), durationSeconds: 300)
        let stored = try XCTUnwrap(store.getAll().first)

        let persistent = Annotation(
            id: stored.id, screenId: stored.screenId, kind: stored.kind, colorHex: stored.colorHex,
            label: stored.label, appId: stored.appId, appName: stored.appName,
            expiresAt: nil, opacity: stored.opacity, offsetX: stored.offsetX, offsetY: stored.offsetY,
            zIndex: stored.zIndex, createdAt: stored.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: stored.id, with: persistent), .updated)

        let updated = try XCTUnwrap(store.get(id: stored.id))
        XCTAssertNil(updated.expiresAt)
        XCTAssertNil(updated.expiresAtUptime, "A cleared deadline must not survive on the monotonic clock.")
    }

    func testUpdateThatMovesTheDeadlineRederivesTheMonotonicTwin() throws {
        let store = AnnotationStore()
        _ = store.addWithOutcome(makeAnnotation(expiresAt: nil, expiresAtUptime: nil), durationSeconds: 10)
        let stored = try XCTUnwrap(store.getAll().first)

        let extended = Annotation(
            id: stored.id, screenId: stored.screenId, kind: stored.kind, colorHex: stored.colorHex,
            label: stored.label, appId: stored.appId, appName: stored.appName,
            expiresAt: Date().addingTimeInterval(600), opacity: stored.opacity,
            offsetX: stored.offsetX, offsetY: stored.offsetY,
            zIndex: stored.zIndex, createdAt: stored.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: stored.id, with: extended), .updated)

        let updated = try XCTUnwrap(store.get(id: stored.id))
        let deadline = try XCTUnwrap(updated.expiresAtUptime)
        XCTAssertEqual(deadline, ProcessInfo.processInfo.systemUptime + 600, accuracy: 5,
                       "A moved wall-clock deadline must produce a matching monotonic deadline.")
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
