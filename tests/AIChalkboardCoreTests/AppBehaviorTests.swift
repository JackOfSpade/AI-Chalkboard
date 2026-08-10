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

    func testCaptureAutoRevertIntervalIsPositiveAndSelfHealsWithinAWorkSession() {
        XCTAssertGreaterThan(OverlayWindowController.captureAutoRevertInterval, 0)
        XCTAssertLessThanOrEqual(
            OverlayWindowController.captureAutoRevertInterval,
            30 * 60,
            "a forgotten capture-debug toggle must self-heal within a reasonable work session, not linger for hours"
        )
    }

    func testOverlayWindowsDisableImplicitOrderingAnimation() {
        XCTAssertEqual(
            OverlayWindowController.overlayWindowAnimationBehavior,
            .none,
            "suspend/resume must not leave a transient, partially visible WindowServer overlay"
        )
    }

    func testOnCaptureVisibleChangedFiresOnlyOnActualStateChanges() {
        addTeardownBlock {
            OverlayWindowController.shared.onCaptureVisibleChanged = nil
            OverlayWindowController.shared.setCaptureVisible(false)
        }

        XCTAssertFalse(OverlayWindowController.shared.isCaptureVisible, "tests assume the default/prior state is off")

        var observedValues: [Bool] = []
        OverlayWindowController.shared.onCaptureVisibleChanged = { visible in
            observedValues.append(visible)
        }

        // Already false: a same-value request must not fire the observer.
        OverlayWindowController.shared.setCaptureVisible(false)
        XCTAssertEqual(observedValues, [])

        OverlayWindowController.shared.setCaptureVisible(true)
        XCTAssertEqual(observedValues, [true])

        // Renewal while already true (the "still debugging" keep-alive) must
        // not fire the observer again -- only the timer restarts.
        OverlayWindowController.shared.setCaptureVisible(true)
        XCTAssertEqual(observedValues, [true])

        OverlayWindowController.shared.setCaptureVisible(false)
        XCTAssertEqual(observedValues, [true, false])
    }

    func testTemporarySuspensionIsIdempotentPresentationStateAndRetainsAnnotationIdentityAndTTL() throws {
        let controller = OverlayWindowController.shared
        let id = "suspension-retention-\(UUID().uuidString)"
        let expiry = Date().addingTimeInterval(60)
        let annotation = Annotation(
            id: id,
            screenId: "suspension-test-screen",
            kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1),
            expiresAt: expiry
        )

        addTeardownBlock {
            _ = AnnotationStore.shared.remove(id: id)
            _ = controller.setAnnotationsSuspended(false)
        }

        // Start clean even when a previous failure skipped its normal resume.
        _ = controller.setAnnotationsSuspended(false)
        AnnotationStore.shared.add(annotation)
        let before = try XCTUnwrap(AnnotationStore.shared.get(id: id))

        XCTAssertTrue(controller.setAnnotationsSuspended(true))
        XCTAssertTrue(controller.isAnnotationsSuspended)
        XCTAssertFalse(controller.setAnnotationsSuspended(true), "repeat suspension must be idempotent")

        let whileSuspended = try XCTUnwrap(AnnotationStore.shared.get(id: id))
        XCTAssertEqual(whileSuspended.id, before.id)
        XCTAssertEqual(whileSuspended.createdAt, before.createdAt)
        XCTAssertEqual(whileSuspended.expiresAt, before.expiresAt, "suspension must not pause or extend TTL")

        XCTAssertTrue(controller.setAnnotationsSuspended(false))
        XCTAssertFalse(controller.isAnnotationsSuspended)
        XCTAssertFalse(controller.setAnnotationsSuspended(false), "repeat resume must be idempotent")
        XCTAssertEqual(AnnotationStore.shared.get(id: id)?.id, id)
    }

    func testBackgroundCaptureRequestReturnsOnlyAfterLocalStateIsApplied() {
        addTeardownBlock {
            OverlayWindowController.shared.setCaptureVisible(false)
        }

        let applied = expectation(description: "background request applied on main")
        DispatchQueue.global().async {
            _ = OverlayWindowController.shared.setCaptureVisible(true)
            XCTAssertTrue(
                OverlayWindowController.shared.isCaptureVisible,
                "a caller that received success must not observe the pre-toggle local state"
            )
            applied.fulfill()
        }

        wait(for: [applied], timeout: 2)
        XCTAssertTrue(OverlayWindowController.shared.isCaptureVisible)
    }

    func testCurrentlyVisibleAnnotationsHidesOtherAppsButShowsGlobalsAndRespectsCaptureDebugOverride() {
        let screenId = "test-screen-\(UUID().uuidString)"
        let globalId = "global-\(UUID().uuidString)"
        let appLinkedId = "app-linked-\(UUID().uuidString)"

        addTeardownBlock {
            _ = AnnotationStore.shared.remove(id: globalId)
            _ = AnnotationStore.shared.remove(id: appLinkedId)
            OverlayWindowController.shared.setCaptureVisible(false)
            _ = OverlayWindowController.shared.setAnnotationsSuspended(false)
        }

        // The controller intentionally starts fail-closed until the durable
        // coordinator bootstraps. This unit test exercises app filtering, not
        // that global safety gate, so establish its explicit ready state.
        _ = OverlayWindowController.shared.setAnnotationsSuspended(false)

        XCTAssertTrue(
            OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).isEmpty,
            "a screen nothing was ever drawn on must report no visible annotations -- this is what lets refreshViews() order its window off screen entirely"
        )

        AnnotationStore.shared.add(Annotation(id: globalId, screenId: screenId, kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1), appId: nil))
        XCTAssertEqual(
            OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).map(\.id),
            [globalId],
            "global annotations must be visible regardless of which app is frontmost"
        )

        AnnotationStore.shared.add(Annotation(id: appLinkedId, screenId: screenId, kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1), appId: "com.aichalkboard.test-fixture.never-frontmost"))
        XCTAssertEqual(
            OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).map(\.id),
            [globalId],
            "an annotation linked to an app that is not frontmost must stay hidden under normal (non-debug) filtering"
        )

        OverlayWindowController.shared.setCaptureVisible(true)
        XCTAssertEqual(
            Set(OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).map(\.id)),
            Set([globalId, appLinkedId]),
            "capture-debug mode must bypass the per-app filter and report every annotation on the screen as visible"
        )
    }

    func testAnnotationKindsExposeStableMCPTypeNames() {
        let kinds: [(AnnotationKind, String)] = [
            (.vectorPath(data: "M1 2 L3 4", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1), "path"),
            (.image(assetId: "asset", x: 1, y: 2, width: 3, height: 4, rotationDegrees: 0, opacity: 1), "image"),
            (.text(text: "Text", x: 1, y: 2, fontSize: 12, textColorHex: "white", backgroundColorHex: nil, backgroundOpacity: 1, paddingPx: 0, opacity: 1), "text"),
            (.batch(items: [AnnotationComponent(kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1))]), "batch")
        ]

        for (kind, expectedType) in kinds {
            XCTAssertEqual(kind.typeName, expectedType)
        }
    }
}
