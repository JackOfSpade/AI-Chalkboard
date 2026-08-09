import XCTest
@testable import AIChalkboardCore

final class PresentationDiagnosticsTests: XCTestCase {
    private func input(
        annotationExists: Bool = true,
        visible: Bool = true,
        windowExists: Bool = true,
        contentMatches: Bool = true,
        viewAttached: Bool = true,
        appKitVisible: Bool = true,
        frameMatches: Bool = true,
        allEntry: Bool = true,
        onScreenEntry: Bool = true,
        boundsMatch: Bool = true,
        appKitAlpha: Double? = 1,
        serverAlpha: Double? = 1,
        appKitLevel: Int? = 25,
        serverLayer: Int? = 25
    ) -> PresentationReadinessInput {
        PresentationReadinessInput(
            annotationExists: annotationExists,
            annotationIsInCurrentVisibleSet: visible,
            overlayWindowExists: windowExists,
            contentViewIsExpectedOverlayView: contentMatches,
            viewIsAttachedToWindow: viewAttached,
            appKitWindowIsVisible: appKitVisible,
            appKitFrameMatchesExpectedScreen: frameMatches,
            windowServerEntryFoundInAllWindows: allEntry,
            windowServerEntryFoundInOnScreenList: onScreenEntry,
            windowServerBoundsMatchExpectedDisplay: boundsMatch,
            appKitAlpha: appKitAlpha,
            windowServerAlpha: serverAlpha,
            appKitLevel: appKitLevel,
            windowServerLayer: serverLayer,
            expectedAlpha: 1,
            expectedLevel: 25
        )
    }

    func testFullyMatchingEvidenceIsReady() {
        XCTAssertEqual(PresentationReadiness.failureReasons(for: input()), [])
    }

    func testReducerReportsIndependentWindowServerAndViewFailures() {
        let failures = PresentationReadiness.failureReasons(for: input(
            visible: false,
            contentMatches: false,
            viewAttached: false,
            appKitVisible: false,
            frameMatches: false,
            allEntry: false,
            onScreenEntry: false,
            appKitAlpha: 0,
            serverAlpha: 0,
            appKitLevel: 3,
            serverLayer: 3
        ))
        XCTAssertEqual(failures, [
            "annotation_not_in_current_visible_set",
            "overlay_content_view_mismatch",
            "overlay_view_detached",
            "appkit_window_not_visible",
            "appkit_window_frame_mismatch",
            "windowserver_entry_missing",
            "windowserver_window_not_on_screen",
            "appkit_window_alpha_below_expected",
            "windowserver_alpha_below_expected",
            "appkit_window_level_mismatch",
            "windowserver_layer_mismatch"
        ])
    }

    func testReducerRejectsWindowServerEntryWhoseBoundsDoNotCoverTargetDisplay() {
        XCTAssertEqual(
            PresentationReadiness.failureReasons(for: input(boundsMatch: false)),
            ["windowserver_bounds_mismatch"]
        )
    }

    func testWindowServerBoundsMatcherAcceptsExactOrSmallInsetFullDisplayWindows() {
        let expected = PresentationRect(x: 0, y: 0, width: 3024, height: 1964)
        XCTAssertTrue(WindowServerBoundsMatcher.matchesExpectedDisplay(actual: expected, expected: expected))
        XCTAssertTrue(
            WindowServerBoundsMatcher.matchesExpectedDisplay(
                actual: PresentationRect(x: 30, y: 20, width: 2964, height: 1924),
                expected: expected
            ),
            "WindowServer can report a small clipped edge for transparent full-display windows."
        )
    }

    func testWindowServerBoundsMatcherRejectsWrongDisplayAndMaterialShrinkage() {
        let expected = PresentationRect(x: 0, y: 0, width: 3024, height: 1964)
        XCTAssertFalse(
            WindowServerBoundsMatcher.matchesExpectedDisplay(
                actual: PresentationRect(x: 3024, y: 0, width: 3024, height: 1964),
                expected: expected
            )
        )
        XCTAssertFalse(
            WindowServerBoundsMatcher.matchesExpectedDisplay(
                actual: PresentationRect(x: 100, y: 100, width: 2824, height: 1764),
                expected: expected
            )
        )
    }

    func testWindowServerDictionaryDecoderNormalizesNumericAndBoundsFields() {
        let entry = PresentationWindowServerEntry(dictionary: [
            "kCGWindowNumber": NSNumber(value: 42),
            "kCGWindowOwnerPID": NSNumber(value: 99),
            "kCGWindowOwnerName": "AI Chalkboard",
            "kCGWindowLayer": NSNumber(value: 25),
            "kCGWindowAlpha": NSNumber(value: 1.0),
            "kCGWindowSharingState": NSNumber(value: 0),
            "kCGWindowIsOnscreen": NSNumber(value: true),
            "kCGWindowBounds": ["X": 10, "Y": 20, "Width": 30, "Height": 40]
        ])
        XCTAssertEqual(entry.windowNumber, 42)
        XCTAssertEqual(entry.ownerPID, 99)
        XCTAssertEqual(entry.layer, 25)
        XCTAssertEqual(entry.alpha, 1)
        XCTAssertEqual(entry.isOnScreen, true)
        XCTAssertEqual(entry.bounds, PresentationRect(x: 10, y: 20, width: 30, height: 40))
    }
}
