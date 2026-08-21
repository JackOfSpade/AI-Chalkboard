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

    func testEmptinessQueryAgreesWithTheFilteredArrayItAvoidsBuilding() {
        // `hasVisibleAnnotations` exists so the repaint path can answer "is
        // there anything to paint on this screen" without materialising and
        // sorting the array.
        //
        // The EXPECTED answer is written out by hand below, because both
        // queries delegate to the same `isVisible(_:onScreen:forApp:)`:
        // comparing them only against each other would agree just as happily on
        // a wrong visibility rule, and would pin nothing beyond "neither has
        // re-inlined its own filter". The agreement assertion is kept as that
        // secondary property.
        let store = AnnotationStore()
        store.add(annotation(id: "global-1", appId: nil))
        store.add(annotation(id: "finder-1", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal-2", screen: "2", appId: "com.apple.Terminal"))

        // Screen 1 holds the global annotation, which is visible under EVERY
        // active app (including none); screen 2 holds only a Terminal-tagged
        // annotation; screen 3 holds nothing at all.
        let expectations: [(screen: String, app: String?, visible: Bool)] = [
            ("1", nil, true),
            ("1", "com.apple.finder", true),
            ("1", "com.apple.Terminal", true),
            ("1", "com.apple.Safari", true),
            ("2", nil, false),
            ("2", "com.apple.finder", false),
            ("2", "com.apple.Terminal", true),
            ("2", "com.apple.Safari", false),
            ("3", nil, false),
            ("3", "com.apple.finder", false),
            ("3", "com.apple.Terminal", false),
            ("3", "com.apple.Safari", false),
        ]
        for expectation in expectations {
            let context = "screen \(expectation.screen) / app \(expectation.app ?? "nil")"
            XCTAssertEqual(
                store.hasVisibleAnnotations(forScreenId: expectation.screen, visibleForApp: expectation.app),
                expectation.visible,
                context
            )
            XCTAssertEqual(
                !store.getForScreen(expectation.screen, visibleForApp: expectation.app).isEmpty,
                expectation.visible,
                "\(context) -- the array the emptiness query avoids building must agree"
            )
        }
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

    // MARK: - Incremental running-total accounting
    //
    // `AnnotationStore` used to recompute `retainedResourceUsage` from
    // scratch (walking every stored annotation, recursively for batches) on
    // every add/update. It now maintains a running total incrementally and
    // only falls back to a full recompute as a DEBUG-only invariant check
    // (`assertResourceUsageConsistent`, which fires automatically on every
    // mutation these tests perform) plus the `fullRecomputeResourceUsageForTesting()`
    // hook these tests call explicitly. Every test below asserts
    // `retainedResourceUsage` (the incremental total) equals
    // `fullRecomputeResourceUsageForTesting()` (an independent from-scratch
    // recompute) after the mutation under test.

    func testRunningResourceUsageMatchesFullRecomputeAfterAdds() {
        let store = AnnotationStore()
        store.add(annotation(id: "a", appId: nil))
        store.add(annotation(id: "b", appId: "com.apple.finder"))
        store.add(annotation(id: "c", appId: "com.apple.Terminal"))

        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 3)
        XCTAssertGreaterThan(store.retainedResourceUsage.payloadBytes, 0)
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterUpdate() {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        store.add(annotation(id: "other", appId: "com.apple.finder"))

        let replacement = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: .text(text: "a fairly different payload than the original path", x: 0, y: 0,
                        fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            createdAt: initial.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: replacement), .updated)

        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRejectedAddLeavesRunningResourceUsageExactlyUnchanged() {
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

        let before = store.retainedResourceUsage
        let outcome = store.addWithOutcome(second)
        guard case .rejected = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }

        XCTAssertEqual(store.retainedResourceUsage, before)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRejectedUpdateLeavesRunningResourceUsageExactlyUnchanged() {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        store.add(annotation(id: "bystander", appId: "com.apple.finder"))
        let oversized = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: .text(text: String(repeating: "x", count: DrawingDefaults.maxRetainedAnnotationPayloadBytes),
                        x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            createdAt: initial.createdAt
        )

        let before = store.retainedResourceUsage
        let outcome = store.updateWithOutcome(id: initial.id, with: oversized)
        guard case .rejected = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }

        XCTAssertEqual(store.retainedResourceUsage, before)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterRemove() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: nil))
        store.add(annotation(id: "second", appId: "com.apple.finder"))

        XCTAssertTrue(store.remove(id: "first"))

        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 1)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageIsZeroAfterClearAllAndMatchesFullRecompute() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: nil))
        store.add(annotation(id: "second", appId: "com.apple.finder"))

        XCTAssertEqual(store.clearAll(), 2)

        XCTAssertEqual(store.retainedResourceUsage, AnnotationStoreResourceUsage(payloadBytes: 0, primitiveCount: 0))
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterClearVisible() {
        let store = AnnotationStore()
        store.add(annotation(id: "global", appId: nil))
        store.add(annotation(id: "finder", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal", appId: "com.apple.Terminal"))

        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 2)

        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 1)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterExpiry() {
        let store = AnnotationStore()
        store.add(annotation(id: "expiring", appId: nil), durationSeconds: 0.01)
        store.add(annotation(id: "persisting", appId: "com.apple.finder"))

        Thread.sleep(forTimeInterval: 0.03)

        // A plain read triggers the expiry sweep as a side effect.
        XCTAssertEqual(store.getAll().map(\.id), ["persisting"])

        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 1)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    /// One annotation with EVERY top-level optional string field populated and
    /// one with all of them nil.
    ///
    /// Deliberately no longer a tour of every `AnnotationKind`: the two
    /// `resourceUsage` overloads duplicate only the six top-level
    /// `addPayload(&usage, annotation.<field>)` lines and then both delegate
    /// the kind walk to the SAME `addKindUsage`, so a fixture of nested batches
    /// and mixed kinds reads like coverage while being unable to fail -- both
    /// sides of the comparison walk it through the identical function.
    private func topLevelFieldAnnotations() -> [Annotation] {
        [
            Annotation(
                id: "path-every-field", screenId: "1",
                kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: "#112233",
                                  strokeWidth: 2, strokeOpacity: 1, fillColorHex: "#445566", fillOpacity: 0.5,
                                  dash: [2, 3], usesEvenOddFillRule: true, coordinateScaleX: 1, coordinateScaleY: 1),
                colorHex: "#778899", label: "path label",
                appId: "com.apple.finder", appName: "Finder"
            ),
            // Optional fields all nil: both implementations must skip them
            // identically rather than one of them counting something.
            Annotation(
                id: "path-no-optional-fields", screenId: "1",
                kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1,
                                  fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                                  coordinateScaleX: 1, coordinateScaleY: 1)
            )
        ]
    }

    /// `AnnotationStore.resourceUsage(of:)` exists in two forms: the array
    /// version, which is the oracle `assertResourceUsageConsistent` (and
    /// `fullRecomputeResourceUsageForTesting`) checks against, and the
    /// single-annotation version the incremental running total is built from.
    ///
    /// Only the six top-level field lines are genuinely duplicated between
    /// them, and only those can this test discriminate: editing one copy and
    /// forgetting the other would otherwise silently disable the invariant
    /// check instead of failing. The kind walk is SHARED (`addKindUsage`) by
    /// design, so no kind-accounting mistake can be caught here -- it would be
    /// made identically on both sides. This claims exactly the first property
    /// and no more.
    func testFullRecomputeEqualsSumOfPerAnnotationUsage() {
        let annotations = topLevelFieldAnnotations()

        // Each per-annotation figure comes from a store holding exactly one
        // annotation, whose running total is by construction the
        // SINGLE-annotation implementation; the combined store's
        // `fullRecomputeResourceUsageForTesting()` is the ARRAY one. Summing
        // the former and comparing with the latter is what ties the two
        // copies together.
        var summed = AnnotationStoreResourceUsage(payloadBytes: 0, primitiveCount: 0)
        for annotation in annotations {
            let isolated = AnnotationStore()
            isolated.add(annotation)
            let usage = isolated.retainedResourceUsage
            summed = AnnotationStoreResourceUsage(
                payloadBytes: summed.payloadBytes + usage.payloadBytes,
                primitiveCount: summed.primitiveCount + usage.primitiveCount
            )
        }

        let combined = AnnotationStore()
        for annotation in annotations { combined.add(annotation) }

        XCTAssertEqual(combined.fullRecomputeResourceUsageForTesting(), summed)
        XCTAssertEqual(combined.retainedResourceUsage, summed)
        XCTAssertGreaterThan(summed.payloadBytes, 0)
        XCTAssertEqual(summed.primitiveCount, 2, "one primitive per path annotation")
    }

    func testRunningResourceUsageMatchesFullRecomputeAcrossMixedOperations() {
        let store = AnnotationStore()
        for i in 0..<25 {
            store.add(annotation(id: "seed-\(i)", appId: i.isMultiple(of: 2) ? nil : "com.apple.finder"))
        }
        XCTAssertTrue(store.remove(id: "seed-3"))
        XCTAssertGreaterThan(store.clearVisible(forApp: "com.apple.finder"), 0)
        store.add(annotation(id: "post-clear", appId: "com.apple.Terminal"))
        let replacement = Annotation(
            id: "post-clear", screenId: "1",
            kind: .text(text: "replacement payload", x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF",
                        backgroundColorHex: nil, backgroundOpacity: 0, paddingPx: 0, opacity: 1)
        )
        XCTAssertEqual(store.updateWithOutcome(id: "post-clear", with: replacement), .updated)

        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }
}
