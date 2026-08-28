import Foundation
import XCTest
@testable import AIChalkboardCore

/// `AnnotationStore` exists specifically to be safe across the MCP server's
/// background read queue and the AppKit main thread, but had no concurrency
/// test at all. These tests hammer it with concurrent mutations via
/// `DispatchQueue.concurrentPerform` and separately pin down the count-cap
/// REJECTION (`DrawingDefaults.maxStoredAnnotations`) -- an insertion that
/// would push the store past the cap is now refused outright rather than
/// evicting older annotations to make room for it; see
/// `AnnotationStore.addWithOutcome`'s doc comment for why.
final class AnnotationStoreConcurrencyTests: XCTestCase {
    private func annotation(id: String) -> Annotation {
        Annotation(id: id, screenId: "1", kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1))
    }

    /// Adds `count` annotations from `count` concurrent tasks, then removes
    /// every other one from concurrent tasks that also call `getAll()` in the
    /// same wave, and asserts the store lands on a consistent final count
    /// with no crash. Kept well under `DrawingDefaults.maxStoredAnnotations`
    /// so the count-cap rejection (covered separately below) cannot interfere.
    func testConcurrentAddRemoveAndGetAllProduceAConsistentFinalCountWithoutCrashing() {
        let store = AnnotationStore()
        let addCount = 1000
        XCTAssertLessThan(addCount, DrawingDefaults.maxStoredAnnotations)
        let ids = (0..<addCount).map { "annotation-\($0)" }

        DispatchQueue.concurrentPerform(iterations: addCount) { index in
            store.add(annotation(id: ids[index]))
        }
        XCTAssertEqual(store.getAll().count, addCount)

        let removeIndices = Array(stride(from: 0, to: addCount, by: 2))
        DispatchQueue.concurrentPerform(iterations: removeIndices.count) { i in
            _ = store.remove(id: ids[removeIndices[i]])
            _ = store.getAll() // concurrent reads must never crash or corrupt state
        }

        XCTAssertEqual(store.getAll().count, addCount - removeIndices.count)
        // The surviving ids must be exactly the odd-indexed ones.
        let expectedSurvivors = Set(stride(from: 1, to: addCount, by: 2).map { "annotation-\($0)" })
        XCTAssertEqual(Set(store.getAll().map(\.id)), expectedSurvivors)
    }

    /// CONTRAST WITH THE DELETED BEHAVIOUR: this cap used to evict the
    /// oldest stored annotations to make room once it was full, so a caller
    /// that kept drawing past the cap would silently lose its earliest work
    /// -- a second, silent way (alongside the deleted TTL/expiry mechanism)
    /// for a drawing to vanish without the AI or the user asking for it. It
    /// now REJECTS the new insertion outright and changes nothing already
    /// stored: no annotation is evicted, trimmed, or reordered to make room.
    func testCountCapRejectsOnceFullAndLeavesExactlyTheFirstAnnotationsAddedInPlace() {
        let store = AnnotationStore()
        let capacity = DrawingDefaults.maxStoredAnnotations
        let overflowBy = 50

        for i in 0..<capacity {
            guard case .added = store.addWithOutcome(annotation(id: "a-\(i)")) else {
                return XCTFail("annotation a-\(i) should still fit under the cap")
            }
        }

        for i in capacity..<(capacity + overflowBy) {
            let outcome = store.addWithOutcome(annotation(id: "a-\(i)"))
            guard case .rejected(.annotationCount(let limit, let attempted)) = outcome else {
                return XCTFail("expected an annotationCount rejection for a-\(i), got \(outcome)")
            }
            XCTAssertEqual(limit, capacity)
            // The store never actually grows past capacity, so every
            // rejected attempt reports the same one-past-the-cap number --
            // there is no accumulating overflow to report.
            XCTAssertEqual(attempted, capacity + 1)
        }

        let remainingIds = store.getAll().map(\.id)
        XCTAssertEqual(remainingIds.count, capacity, "the store's count must not have changed across every rejected insertion")
        XCTAssertEqual(remainingIds, (0..<capacity).map { "a-\($0)" },
                       "a rejection cap keeps EXACTLY what was already stored -- no eviction, no truncation, no reordering")
    }

    /// Rejections at the count cap must leave the running resource total
    /// exactly where it was before the rejected attempt, matching the same
    /// leave-everything-unchanged guarantee the payload-bytes and
    /// primitive-count caps already had (see `AnnotationStoreTests`'s
    /// `testRejectedAddLeavesRunningResourceUsageExactlyUnchanged`), now
    /// extended to the count cap.
    func testRunningResourceUsageIsUnchangedByRejectionsPastTheCountCap() {
        let store = AnnotationStore()
        let capacity = DrawingDefaults.maxStoredAnnotations
        let overflowBy = 25

        for i in 0..<capacity {
            store.add(annotation(id: "u-\(i)"))
        }
        let usageAtCapacity = store.retainedResourceUsage

        for i in capacity..<(capacity + overflowBy) {
            store.add(annotation(id: "u-\(i)"))
        }

        XCTAssertEqual(store.getAll().count, capacity)
        XCTAssertEqual(store.retainedResourceUsage, usageAtCapacity)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    /// Runs the same concurrent add/remove wave as
    /// `testConcurrentAddRemoveAndGetAllProduceAConsistentFinalCountWithoutCrashing`,
    /// then checks the running resource total landed exactly where a full
    /// recompute says it should. The store's internal `NSLock` serializes
    /// every `trackAdded`/`trackRemoved` call, so this must hold even though
    /// the adds and removes themselves ran from many concurrent tasks.
    func testRunningResourceUsageMatchesFullRecomputeAfterConcurrentAddsAndRemoves() {
        let store = AnnotationStore()
        let addCount = 500
        let ids = (0..<addCount).map { "ru-\($0)" }

        DispatchQueue.concurrentPerform(iterations: addCount) { index in
            store.add(annotation(id: ids[index]))
        }
        XCTAssertEqual(store.getAll().count, addCount)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())

        let removeIndices = Array(stride(from: 0, to: addCount, by: 2))
        DispatchQueue.concurrentPerform(iterations: removeIndices.count) { i in
            _ = store.remove(id: ids[removeIndices[i]])
        }

        XCTAssertEqual(store.getAll().count, addCount - removeIndices.count)
        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, addCount - removeIndices.count)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }
}
