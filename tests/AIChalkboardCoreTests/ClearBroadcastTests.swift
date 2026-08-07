import Foundation
import XCTest
@testable import AIChalkboardCore

final class ClearBroadcastTests: XCTestCase {
    private func annotation(_ id: String, appId: String?) -> Annotation {
        Annotation(id: id, screenId: "1", kind: .grid(stepPx: 100), appId: appId, appName: appId)
    }

    private func populatedStore() -> AnnotationStore {
        let store = AnnotationStore()
        store.add(annotation("global", appId: nil))
        store.add(annotation("finder", appId: "com.apple.finder"))
        store.add(annotation("terminal", appId: "com.apple.Terminal"))
        return store
    }

    func testFinderRequestRoundTripsAndAppliesToTwoProcessLocalStores() {
        let sent = ClearBroadcastRequest(scope: .active, appId: "com.apple.finder", appName: "Finder")
        XCTAssertEqual(sent.userInfo, ["scope": "active", "appId": "com.apple.finder", "appName": "Finder"])

        let notification = Notification(name: .chalkboardClearAll, userInfo: sent.userInfo)
        let received = ClearBroadcastRequest(notification: notification)
        let primaryStore = populatedStore()
        let secondaryStore = populatedStore()

        XCTAssertEqual(received.apply(to: primaryStore), 2)
        XCTAssertEqual(received.apply(to: secondaryStore), 2)
        XCTAssertEqual(primaryStore.getAll().map(\.id), ["terminal"])
        XCTAssertEqual(secondaryStore.getAll().map(\.id), ["terminal"])
    }

    func testActiveRequestWithoutAppClearsGlobalsOnly() {
        let request = ClearBroadcastRequest(scope: .active, appId: nil, appName: nil)
        let received = ClearBroadcastRequest(
            notification: Notification(name: .chalkboardClearAll, userInfo: request.userInfo)
        )
        let store = populatedStore()

        XCTAssertEqual(received.apply(to: store), 1)
        XCTAssertEqual(Set(store.getAll().map(\.id)), Set(["finder", "terminal"]))
    }

    func testLegacyAndMalformedScopesClearEverything() {
        for userInfo in [nil, ["scope": "unexpected"]] as [[AnyHashable: Any]?] {
            let store = populatedStore()
            let request = ClearBroadcastRequest(
                notification: Notification(name: .chalkboardClearAll, userInfo: userInfo)
            )
            XCTAssertEqual(request.scope, .all)
            XCTAssertEqual(request.apply(to: store), 3)
            XCTAssertTrue(store.getAll().isEmpty)
        }
    }
}
