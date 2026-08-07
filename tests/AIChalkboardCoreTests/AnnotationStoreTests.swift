import XCTest
@testable import AIChalkboardCore

final class AnnotationStoreTests: XCTestCase {
    private func annotation(id: String, screen: String = "1", appId: String?) -> Annotation {
        Annotation(
            id: id,
            screenId: screen,
            kind: .box(x: 0, y: 0, width: 10, height: 10),
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
}
