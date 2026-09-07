import XCTest
@testable import AIChalkboardCore

final class PresentationDiagnosticsTests: XCTestCase {
    private func input(
        annotationExists: Bool = true,
        visible: Bool = true,
        annotationsSuspended: Bool = false,
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
        serverLayer: Int? = 25,
        anchorState: AnchorTrackingState? = nil
    ) -> PresentationReadinessInput {
        PresentationReadinessInput(
            annotationExists: annotationExists,
            annotationIsInCurrentVisibleSet: visible,
            annotationsSuspended: annotationsSuspended,
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
            expectedLevel: 25,
            anchorState: anchorState
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

    func testReducerReportsOnlyDedicatedReasonForIntentionalSuspension() {
        XCTAssertEqual(
            PresentationReadiness.failureReasons(for: input(
                visible: false,
                annotationsSuspended: true,
                appKitVisible: false,
                onScreenEntry: false
            )),
            ["annotations_suspended"]
        )
    }

    func testReducerRetainsMissingAnnotationEvidenceDuringSuspension() {
        XCTAssertEqual(
            PresentationReadiness.failureReasons(for: input(
                annotationExists: false,
                visible: false,
                annotationsSuspended: true,
                windowExists: false,
                appKitVisible: false,
                allEntry: false,
                onScreenEntry: false
            )),
            ["annotation_not_found", "annotations_suspended"]
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

    // MARK: - anchor_window_hidden / anchor_window_lost layering

    /// The bare code for an UNANCHORED annotation (or one whose anchor is
    /// still `.tracking`) is unchanged: this is the pre-existing behaviour
    /// `testReducerReportsIndependentWindowServerAndViewFailures` already
    /// pins, repeated here explicitly against the new `anchorState`
    /// parameter's two "no substitution" values.
    func testUnanchoredOrTrackingAnchorKeepsTheBareVisibleSetFailure() {
        XCTAssertEqual(
            PresentationReadiness.failureReasons(for: input(visible: false, anchorState: nil)),
            ["annotation_not_in_current_visible_set"]
        )
        XCTAssertEqual(
            PresentationReadiness.failureReasons(for: input(visible: false, anchorState: .tracking)),
            ["annotation_not_in_current_visible_set"]
        )
    }

    /// THE LAYERING FIX: a `.hidden` anchor state is the ACTIONABLE reason
    /// the annotation dropped out of the visible set (its target window is
    /// minimised/on another Space/its app is hidden), so it is reported
    /// INSTEAD OF the bare, less useful `annotation_not_in_current_visible_set` --
    /// the same "do not emit a second, misleading failure" layering this file
    /// already applies to `windowserver_bounds_mismatch`.
    func testHiddenAnchorReplacesTheBareVisibleSetFailure() {
        let failures = PresentationReadiness.failureReasons(for: input(visible: false, anchorState: .hidden))
        XCTAssertEqual(failures, ["anchor_window_hidden"])
        XCTAssertFalse(failures.contains("annotation_not_in_current_visible_set"),
                       "the bare code must not also be emitted alongside the actionable anchor reason")
    }

    /// Same layering for `.lost`: the target window is gone (or a recycled
    /// id now belongs to a different app), which is permanent and distinct
    /// from `.hidden`'s "temporarily off screen".
    func testLostAnchorReplacesTheBareVisibleSetFailure() {
        let failures = PresentationReadiness.failureReasons(for: input(visible: false, anchorState: .lost))
        XCTAssertEqual(failures, ["anchor_window_lost"])
        XCTAssertFalse(failures.contains("annotation_not_in_current_visible_set"))
    }

    /// The substitution is scoped to the visible-set slot only: every other
    /// independent failure (WindowServer entry, alpha, level, ...) must still
    /// be reported alongside it, exactly as `testReducerReportsIndependentWindowServerAndViewFailures`
    /// pins for the unanchored case.
    func testAnchorFailureCoexistsWithOtherIndependentFailures() {
        let failures = PresentationReadiness.failureReasons(for: input(
            visible: false, appKitVisible: false, allEntry: false, onScreenEntry: false, anchorState: .hidden
        ))
        XCTAssertEqual(failures, [
            "anchor_window_hidden",
            "appkit_window_not_visible",
            "windowserver_entry_missing",
            "windowserver_window_not_on_screen"
        ])
    }

    /// Suspension still outranks everything, including an anchor state --
    /// the existing `annotations_suspended`-only layering
    /// (`testReducerReportsOnlyDedicatedReasonForIntentionalSuspension`) must
    /// not gain a competing anchor code.
    func testSuspensionStillOutranksAnAnchorState() {
        XCTAssertEqual(
            PresentationReadiness.failureReasons(for: input(
                visible: false, annotationsSuspended: true, anchorState: .hidden
            )),
            ["annotations_suspended"]
        )
    }

    func testVisibilityAbsenceReasonPureMapping() {
        XCTAssertEqual(PresentationReadiness.visibilityAbsenceReason(anchorState: nil), "annotation_not_in_current_visible_set")
        XCTAssertEqual(PresentationReadiness.visibilityAbsenceReason(anchorState: .tracking), "annotation_not_in_current_visible_set")
        XCTAssertEqual(PresentationReadiness.visibilityAbsenceReason(anchorState: .hidden), "anchor_window_hidden")
        XCTAssertEqual(PresentationReadiness.visibilityAbsenceReason(anchorState: .lost), "anchor_window_lost")
    }

    // MARK: - Capture-honesty block (`captureExclusion` / `captureHonestyNote`)

    func testCaptureExclusionSummaryRestatesADecisionWithoutRecomputing() {
        let decision = CaptureExclusionPolicy.Decision.includeSuppressedForRemoteSession(signals: ["Parsec (parsecd)"])
        let summary = PresentationCaptureExclusionSummary(decision: decision)
        XCTAssertEqual(summary.excludesFromCapture, false)
        XCTAssertEqual(summary.reasonCode, "included-suppressed-remote-session")
        XCTAssertEqual(summary.signals, ["Parsec (parsecd)"])
        XCTAssertEqual(summary.environmentVariable, CaptureExclusionPolicy.environmentVariableName)
        XCTAssertEqual(summary.note, decision.explanation)
    }

    func testCaptureExclusionSummaryForOrdinaryExcludedDesktop() {
        let summary = PresentationCaptureExclusionSummary(decision: .exclude)
        XCTAssertEqual(summary.excludesFromCapture, true)
        XCTAssertEqual(summary.reasonCode, "excluded")
        XCTAssertEqual(summary.signals, [])
    }

    /// The note must be FACTUAL and CONDITIONED on the live decision, never a
    /// static claim that could contradict `captureExclusion.excludesFromCapture`
    /// in the same response -- the exact bug CAPTURE_GAP.md reports
    /// (`presentationReady: true` with no mention of capture exclusion at
    /// all).
    func testCaptureHonestyNoteDiffersByExclusionStateAndNamesTheRemedy() {
        let excluded = PresentationReadiness.captureHonestyNote(excludesFromCapture: true)
        XCTAssertTrue(excluded.contains("will NOT contain"), excluded)
        XCTAssertTrue(excluded.contains("set_capture_visible(true)"), excluded)
        XCTAssertTrue(excluded.contains("get_annotation_bounds"), excluded)

        let included = PresentationReadiness.captureHonestyNote(excludesFromCapture: false)
        XCTAssertFalse(included.contains("will NOT contain"), included)
        XCTAssertTrue(included.contains("get_annotation_bounds"), included)
        XCTAssertNotEqual(excluded, included)
    }
}
