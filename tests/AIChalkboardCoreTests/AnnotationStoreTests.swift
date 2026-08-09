import XCTest
@testable import AIChalkboardCore

final class AnnotationStoreTests: XCTestCase {
    private func annotation(id: String, screen: String = "1", appId: String?) -> Annotation {
        Annotation(
            id: id,
            screenId: screen,
            kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1),
            appId: appId,
            appName: appId
        )
    }

    func testClearVisibleReturnsLiveRemovalCountAndPreservesRemainder() {
        let store = AnnotationStore()
        store.add(annotation(id: "global", appId: nil))
        store.add(annotation(id: "finder", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal", appId: "com.apple.Terminal"))

        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 2)
        XCTAssertEqual(store.getAll().map(\.id), ["terminal"])
    }

    func testRemoveByIDPreservesPeerAnnotations() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: "com.apple.finder"))
        store.add(annotation(id: "target", appId: "com.apple.finder"))
        store.add(annotation(id: "third", appId: nil))

        XCTAssertTrue(store.remove(id: "target"))
        XCTAssertEqual(store.getAll().map(\.id), ["first", "third"])
    }

    func testGetByIDReturnsAnExactSnapshotWithoutChangingTheStore() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: nil))
        store.add(annotation(id: "target", appId: "com.apple.finder"))

        XCTAssertEqual(store.get(id: "target")?.id, "target")
        XCTAssertNil(store.get(id: "missing"))
        XCTAssertEqual(store.getAll().map(\.id), ["first", "target"])
    }

    func testExpiredAnnotationIsExcludedFromLaterClearCount() {
        let store = AnnotationStore()
        store.add(annotation(id: "expiring-global", appId: nil), durationSeconds: 0.01)
        store.add(annotation(id: "live-finder", appId: "com.apple.finder"))

        let expiryProcessed = expectation(description: "main-queue expiration processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expiryProcessed.fulfill()
        }
        wait(for: [expiryProcessed], timeout: 1.0)

        XCTAssertEqual(store.getAll().map(\.id), ["live-finder"])
        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 1)
        XCTAssertTrue(store.getAll().isEmpty)
    }

    func testReadsEnforceExpiryEvenWhenScheduledMainQueueRemovalHasNotRun() {
        let store = AnnotationStore()
        store.add(annotation(id: "expired-without-timer", appId: nil), durationSeconds: 0.01)

        // This test runs on the main thread, deliberately preventing the
        // asyncAfter removal from firing before the deadline passes.
        Thread.sleep(forTimeInterval: 0.03)

        XCTAssertNil(store.get(id: "expired-without-timer"))
        XCTAssertTrue(store.getAll().isEmpty)
        XCTAssertTrue(store.getForScreen("1").isEmpty)
        XCTAssertTrue(store.getForScreen("1", visibleForApp: nil).isEmpty)
    }

    func testMutationsNeverCountExpiredAnnotationsAsLiveRemovals() {
        let store = AnnotationStore()
        store.add(annotation(id: "expired", appId: nil), durationSeconds: 0.01)
        Thread.sleep(forTimeInterval: 0.03)

        XCTAssertFalse(store.remove(id: "expired"))

        store.add(annotation(id: "expired-again", appId: nil), durationSeconds: 0.01)
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(store.clearVisible(forApp: nil), 0)

        store.add(annotation(id: "expired-all", appId: nil), durationSeconds: 0.01)
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(store.clearAll(), 0)
    }

    func testDurationIsRecordedAsAnAbsoluteExpiryBeforeRemoval() throws {
        let store = AnnotationStore()
        let before = Date().addingTimeInterval(9.5)

        store.add(annotation(id: "temporary", appId: nil), durationSeconds: 10)

        let stored = try XCTUnwrap(store.getAll().first)
        let expiry = try XCTUnwrap(stored.expiresAt)
        XCTAssertGreaterThanOrEqual(expiry, before)
        XCTAssertLessThanOrEqual(expiry, Date().addingTimeInterval(10.5))
    }

    func testExplicitExpiryTakesPrecedenceOverDurationArgument() throws {
        let store = AnnotationStore()
        let explicitExpiry = Date().addingTimeInterval(30)
        let expiring = Annotation(
            id: "explicit-expiry",
            screenId: "1",
            kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1),
            expiresAt: explicitExpiry
        )

        store.add(expiring, durationSeconds: 300)

        let storedExpiry = try XCTUnwrap(store.getAll().first?.expiresAt)
        XCTAssertEqual(storedExpiry.timeIntervalSince1970, explicitExpiry.timeIntervalSince1970, accuracy: 0.001)
    }

    func testClearVisibleWithNoAppRemovesGlobalsOnly() {
        let store = AnnotationStore()
        store.add(annotation(id: "global", appId: nil))
        store.add(annotation(id: "finder", appId: "com.apple.finder"))

        XCTAssertEqual(store.clearVisible(forApp: nil), 1)
        XCTAssertEqual(store.getAll().map(\.id), ["finder"])
    }

    func testVisibleFilterMatchesClearPredicateAndScreen() {
        let store = AnnotationStore()
        store.add(annotation(id: "global-1", appId: nil))
        store.add(annotation(id: "finder-1", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal-1", appId: "com.apple.Terminal"))
        store.add(annotation(id: "global-2", screen: "2", appId: nil))

        XCTAssertEqual(
            Set(store.getForScreen("1", visibleForApp: "com.apple.finder").map(\.id)),
            Set(["global-1", "finder-1"])
        )
        XCTAssertEqual(
            store.getForScreen("1", visibleForApp: nil).map(\.id),
            ["global-1"]
        )
    }

    func testUpdatePreservesIdentityAndStableSlotWhileChangingPaintOrder() throws {
        let store = AnnotationStore()
        let first = annotation(id: "first", appId: nil)
        let second = annotation(id: "second", appId: nil)
        store.add(first)
        store.add(second)

        let changed = Annotation(
            id: first.id, screenId: first.screenId, kind: first.kind, colorHex: first.colorHex,
            label: first.label, appId: first.appId, appName: first.appName, expiresAt: first.expiresAt,
            opacity: 0.5, offsetX: 10, offsetY: 20, zIndex: 2, createdAt: first.createdAt
        )
        XCTAssertTrue(store.update(id: first.id, with: changed))
        let stored = try XCTUnwrap(store.get(id: first.id))
        XCTAssertEqual(stored.id, first.id)
        XCTAssertEqual(stored.createdAt, first.createdAt)
        XCTAssertEqual(stored.offsetX, 10)
        XCTAssertEqual(stored.opacity, 0.5)
        XCTAssertEqual(store.getForScreen("1", visibleForApp: nil).map(\.id), ["second", "first"])
    }

    func testStaleRevisionCannotOverwriteANewerInPlaceUpdate() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        let firstSnapshot = try XCTUnwrap(store.get(id: initial.id))
        let staleSnapshot = try XCTUnwrap(store.get(id: initial.id))

        let newer = Annotation(
            id: firstSnapshot.id, screenId: firstSnapshot.screenId, kind: firstSnapshot.kind,
            colorHex: firstSnapshot.colorHex, label: firstSnapshot.label,
            appId: firstSnapshot.appId, appName: firstSnapshot.appName,
            expiresAt: firstSnapshot.expiresAt, opacity: 0.8, offsetX: 10, offsetY: 0,
            zIndex: firstSnapshot.zIndex, createdAt: firstSnapshot.createdAt
        )
        XCTAssertEqual(
            store.updateWithOutcome(id: initial.id, with: newer, expectedRevision: firstSnapshot.revision),
            .updated
        )

        let staleReplacement = Annotation(
            id: staleSnapshot.id, screenId: staleSnapshot.screenId, kind: staleSnapshot.kind,
            colorHex: staleSnapshot.colorHex, label: staleSnapshot.label,
            appId: staleSnapshot.appId, appName: staleSnapshot.appName,
            expiresAt: staleSnapshot.expiresAt, opacity: 0.4, offsetX: 99, offsetY: 0,
            zIndex: staleSnapshot.zIndex, createdAt: staleSnapshot.createdAt
        )
        XCTAssertEqual(
            store.updateWithOutcome(id: initial.id, with: staleReplacement, expectedRevision: staleSnapshot.revision),
            .stale
        )
        let retained = try XCTUnwrap(store.get(id: initial.id))
        XCTAssertEqual(retained.offsetX, 10)
        XCTAssertEqual(retained.opacity, 0.8)
        XCTAssertGreaterThan(retained.revision, staleSnapshot.revision)
    }

    func testAggregatePayloadBudgetRejectsWithoutEvictingOrInserting() {
        let store = AnnotationStore()
        let halfBudgetPlusMargin = DrawingDefaults.maxRetainedAnnotationPayloadBytes / 2 + 4_096
        let first = Annotation(
            id: "first-large", screenId: "1",
            kind: .text(text: String(repeating: "a", count: halfBudgetPlusMargin), x: 0, y: 0,
                        fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1)
        )
        let second = Annotation(
            id: "second-large", screenId: "1",
            kind: .vectorPath(data: String(repeating: "M0 0 L1 1 ", count: halfBudgetPlusMargin / 10 + 1),
                              strokeColorHex: "#FFFFFF", strokeWidth: 1, strokeOpacity: 1,
                              fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                              coordinateScaleX: 1, coordinateScaleY: 1)
        )

        guard case .added = store.addWithOutcome(first) else {
            return XCTFail("first annotation should fit the aggregate payload budget")
        }
        let before = store.getAll().map(\.id)
        let outcome = store.addWithOutcome(second)
        guard case .rejected(.payloadBytes(let limit, let attempted)) = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxRetainedAnnotationPayloadBytes)
        XCTAssertGreaterThan(attempted, limit)
        XCTAssertEqual(store.getAll().map(\.id), before)
        XCTAssertLessThanOrEqual(store.retainedResourceUsage.payloadBytes, limit)
    }

    func testAggregateBudgetRejectsUpdateAndLeavesExistingAnnotationUntouched() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        let oversized = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: .text(text: String(repeating: "x", count: DrawingDefaults.maxRetainedAnnotationPayloadBytes),
                        x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            createdAt: initial.createdAt
        )

        let outcome = store.updateWithOutcome(id: initial.id, with: oversized)
        guard case .rejected(.payloadBytes) = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }
        let stored = try XCTUnwrap(store.get(id: initial.id))
        XCTAssertEqual(stored.kind.typeName, "path")
        XCTAssertEqual(stored.createdAt, initial.createdAt)
    }

    func testBatchChildrenCountTowardAggregatePrimitiveBudget() {
        let store = AnnotationStore()
        let component = AnnotationComponent(kind: .vectorPath(
            data: "M0 0 L1 1", strokeColorHex: "#FFFFFF", strokeWidth: 1, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        ))
        let oversizedBatch = Annotation(
            id: "oversized-batch", screenId: "1",
            kind: .batch(items: Array(repeating: component, count: DrawingDefaults.maxRetainedAnnotationPrimitives + 1))
        )

        let outcome = store.addWithOutcome(oversizedBatch)
        guard case .rejected(.primitiveCount(let limit, let attempted)) = outcome else {
            return XCTFail("expected primitive-budget rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxRetainedAnnotationPrimitives)
        XCTAssertEqual(attempted, DrawingDefaults.maxRetainedAnnotationPrimitives + 1)
        XCTAssertTrue(store.getAll().isEmpty)
    }
}
