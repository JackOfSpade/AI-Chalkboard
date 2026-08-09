import Foundation
import XCTest
@testable import AIChalkboardCore

/// `AnnotationStore` exists specifically to be safe across the MCP server's
/// background read queue and the AppKit main thread, but had no concurrency
/// test at all. These tests hammer it with concurrent mutations via
/// `DispatchQueue.concurrentPerform` and separately pin down the new
/// eviction cap (`DrawingDefaults.maxStoredAnnotations`).
final class AnnotationStoreConcurrencyTests: XCTestCase {
    private func annotation(id: String) -> Annotation {
        Annotation(id: id, screenId: "1", kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1))
    }

    /// Adds `count` annotations from `count` concurrent tasks, then removes
    /// every other one from concurrent tasks that also call `getAll()` in the
    /// same wave, and asserts the store lands on a consistent final count
    /// with no crash. Kept well under `DrawingDefaults.maxStoredAnnotations`
    /// so eviction (covered separately below) cannot interfere.
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

    func testEvictionCapDropsOldestFirstReturnsEvictedCountAndKeepsNewest() {
        let store = AnnotationStore()
        let capacity = DrawingDefaults.maxStoredAnnotations
        let overflowBy = 50
        let totalToAdd = capacity + overflowBy

        var totalEvicted = 0
        for i in 0..<totalToAdd {
            totalEvicted += store.add(annotation(id: "a-\(i)"))
        }

        XCTAssertEqual(totalEvicted, overflowBy)

        let remainingIds = store.getAll().map(\.id)
        XCTAssertEqual(remainingIds.count, capacity)
        XCTAssertEqual(remainingIds, (overflowBy..<totalToAdd).map { "a-\($0)" },
                       "eviction must drop the oldest entries first and keep the newest, in order")
    }
}
