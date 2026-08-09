import XCTest
@testable import AIChalkboardCore

final class AccessibilityElementResolverTests: XCTestCase {
    private func screen(
        id: String,
        appKitFrame: ScreenCoordinateRect,
        scale: Double
    ) -> ScreenInfo {
        ScreenInfo(
            id: id,
            index: 0,
            name: id,
            widthPx: Int(appKitFrame.width * scale),
            heightPx: Int(appKitFrame.height * scale),
            widthPt: appKitFrame.width,
            heightPt: appKitFrame.height,
            backingScaleFactor: scale,
            isMain: id == "main",
            appKitFrame: appKitFrame,
            windowServerFrame: ScreenCoordinateRect(
                x: appKitFrame.x * scale, y: appKitFrame.y * scale,
                width: appKitFrame.width * scale, height: appKitFrame.height * scale
            ),
            displayID: 1
        )
    }

    func testExactLabelMatchingIsCaseSensitive() {
        XCTAssertTrue(AccessibilityElementResolver.labelMatches("Fusion", query: "Fusion", mode: .exact))
        XCTAssertFalse(AccessibilityElementResolver.labelMatches("fusion", query: "Fusion", mode: .exact))
        XCTAssertFalse(AccessibilityElementResolver.labelMatches("Fusion Studio", query: "Fusion", mode: .exact))
    }

    func testContainsLabelMatchingIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(AccessibilityElementResolver.labelMatches("Open Fusion Studio", query: "fusion", mode: .contains))
        XCTAssertTrue(AccessibilityElementResolver.labelMatches("Café Settings", query: "cafe", mode: .contains))
        XCTAssertFalse(AccessibilityElementResolver.labelMatches("Color", query: "Fusion", mode: .contains))
    }

    func testPrimaryDisplayAccessibilityFrameConvertsToLocalBackingPixels() throws {
        let primary = screen(
            id: "main",
            appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_512, height: 982),
            scale: 2
        )
        let result = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 100, y: 50, width: 120, height: 30),
            screens: [primary]
        ))
        XCTAssertEqual(result.screenId, "main")
        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 100)
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.height, 60)
    }

    func testSecondaryMixedScaleDisplayUsesDesktopTopAndItsOwnScale() throws {
        let main = screen(
            id: "main",
            appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800),
            scale: 1
        )
        let upperLeftRetina = screen(
            id: "upper-left",
            appKitFrame: ScreenCoordinateRect(x: -500, y: 800, width: 1_200, height: 600),
            scale: 2
        )
        let result = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            // AX's top-left global coordinates are anchored to the main
            // screen, so an element above it has a negative Y.
            forAccessibilityFrame: AccessibilityScreenRect(x: -400, y: -500, width: 40, height: 20),
            screens: [main, upperLeftRetina]
        ))
        XCTAssertEqual(result.screenId, "upper-left")
        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 200)
        XCTAssertEqual(result.width, 80)
        XCTAssertEqual(result.height, 40)
    }

    func testFrameStraddlingDisplaysIsRejectedRatherThanSilentlyClipped() {
        let left = screen(id: "left", appKitFrame: ScreenCoordinateRect(x: -1_000, y: 0, width: 1_000, height: 800), scale: 1)
        let right = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: -10, y: 100, width: 30, height: 20),
            screens: [left, right]
        ))
    }

    func testInvalidAccessibilityFrameIsRejected() {
        let primary = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 0, y: 0, width: 0, height: 20),
            screens: [primary]
        ))
    }

    func testTraversalDeadlineUsesMonotonicElapsedTime() {
        XCTAssertFalse(AccessibilityElementResolver.traversalDeadlineExceeded(
            startedAt: 100, now: 101.999, timeout: 2
        ))
        XCTAssertTrue(AccessibilityElementResolver.traversalDeadlineExceeded(
            startedAt: 100, now: 102, timeout: 2
        ))
        XCTAssertTrue(AccessibilityElementResolver.traversalDeadlineExceeded(
            startedAt: 100, now: 105, timeout: 2
        ))
    }

    func testEmptyWindowsFallsBackToApplicationChildrenButNonEmptyWindowsWin() {
        XCTAssertEqual(
            AccessibilityElementResolver.initialElements(windows: [], children: [1, 2]),
            [1, 2]
        )
        XCTAssertEqual(
            AccessibilityElementResolver.initialElements(windows: [3], children: [1, 2]),
            [3]
        )
    }

    func testBoundedAppendOnlyUsesRemainingInspectionCapacity() {
        XCTAssertEqual(
            AccessibilityElementResolver.boundedAppendCount(
                candidateCount: 100_000, queuedUninspected: 0, inspected: 0, maxNodes: 3_000
            ),
            3_000
        )
        XCTAssertEqual(
            AccessibilityElementResolver.boundedAppendCount(
                candidateCount: 50, queuedUninspected: 4, inspected: 3, maxNodes: 10
            ),
            3
        )
        XCTAssertEqual(
            AccessibilityElementResolver.boundedAppendCount(
                candidateCount: 1, queuedUninspected: 0, inspected: 10, maxNodes: 10
            ),
            0
        )
    }
}
