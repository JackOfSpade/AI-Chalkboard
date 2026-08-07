import AppKit
import XCTest
@testable import AIChalkboardCore

final class AppBehaviorTests: XCTestCase {
    func testStatusMenuItemsHaveExplicitDelegateTargetsAndExpectedActions() {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()

        let expected: [(index: Int, action: String)] = [
            (0, "clearAnnotationsForActiveApp"),
            (1, "clearEverything"),
            (3, "toggleCaptureVisible"),
            (5, "quitApp")
        ]

        XCTAssertEqual(menu.items.count, 6)
        for entry in expected {
            let item = menu.items[entry.index]
            XCTAssertTrue(item.target === delegate, "\(item.title) must target AppDelegate directly")
            XCTAssertEqual(item.action.map(NSStringFromSelector), entry.action)
            XCTAssertTrue(delegate.responds(to: item.action!), "AppDelegate must expose \(entry.action) to Objective-C action dispatch")
            XCTAssertTrue(item.isEnabled)
        }
    }

    func testBundleIdentifierSyntaxRejectsPrefixesAndAcceptsCompleteIds() {
        XCTAssertTrue(BundleIdentifierSyntax.looksComplete("com.apple.Safari"))
        XCTAssertTrue(BundleIdentifierSyntax.looksComplete("org.example.product.helper"))
        XCTAssertFalse(BundleIdentifierSyntax.looksComplete("com.apple"))
        XCTAssertFalse(BundleIdentifierSyntax.looksComplete("com..Safari"))
        XCTAssertFalse(BundleIdentifierSyntax.looksComplete("com.apple.Safari Beta"))
    }

    func testLoginwindowIsNeverAnUntaggedDrawFallback() {
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("com.apple.loginwindow"))
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("COM.APPLE.LOGINWINDOW"))
        XCTAssertFalse(ActiveAppTracker.isSystemSessionApp("com.apple.finder"))
    }

    func testPhysicalStrokeWidthIsStableAcrossBackingScales() {
        XCTAssertEqual(
            OverlayDrawingMetrics.points(forPhysicalPixels: 6, backingScaleFactor: 1),
            6
        )
        XCTAssertEqual(
            OverlayDrawingMetrics.points(forPhysicalPixels: 6, backingScaleFactor: 2),
            3
        )
        XCTAssertEqual(
            OverlayDrawingMetrics.points(forPhysicalPixels: 6, backingScaleFactor: 0),
            6,
            "invalid scale factors must safely fall back to 1x"
        )
    }

    func testAnnotationKindsExposeStableMCPTypeNames() {
        let kinds: [(AnnotationKind, String)] = [
            (.circle(x: 1, y: 2, radius: 3), "circle"),
            (.arrow(x1: 1, y1: 2, x2: 3, y2: 4), "arrow"),
            (.box(x: 1, y: 2, width: 3, height: 4), "box"),
            (.label(x: 1, y: 2, text: "label"), "label"),
            (.grid(stepPx: 100), "grid"),
            (.path(points: [[1, 2], [3, 4]], strokeWidth: 2, isClosed: false), "path")
        ]

        for (kind, expectedType) in kinds {
            XCTAssertEqual(kind.typeName, expectedType)
        }
    }
}
