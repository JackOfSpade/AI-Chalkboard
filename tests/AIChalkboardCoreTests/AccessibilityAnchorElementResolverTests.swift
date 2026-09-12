import XCTest
@testable import AIChalkboardCore

/// Pins `AccessibilityAnchorElementResolver`'s testable-without-live-AX
/// surfaces:
///
/// 1. `reasonCode(for:)` -- the pure, exhaustive mapping from every
///    `AccessibilityElementResolverError` case onto one of
///    `AnchorElementReresolution.issue`'s five fixed reason codes
///    ("ambiguous", "not_found", "unavailable", "permission", "timeout").
///    Every case is constructed directly (an injected/faked failure), no
///    live Accessibility/UI Automation session required.
/// 2. `reresolve`'s process-id guard -- a `target.processId` that does not
///    fit this platform's process-id type (`pid_t` on macOS, `UInt32` on
///    Windows) must fail closed with `.issue("not_found")` BEFORE ever
///    reaching `AccessibilityElementResolver.resolve`, which is likewise
///    exercisable with no live AX session.
/// 3. `conversionSurvivedWalk(match:screensAfterWalk:)` -- the pure core of
///    `reresolve`'s post-walk display-layout guard, exercised with
///    hand-built matches and screen snapshots. The guard's PLUMBING (the
///    injected `currentScreens` closure firing after a real walk) is not
///    coverable here for the same reason a genuinely successful re-resolve
///    is not: it sits on the far side of a live
///    `AccessibilityElementResolver.resolve` call.
///
/// A genuinely successful re-resolve (a live match rebuilding a highlight's
/// geometry) is NOT covered here -- that needs a real running process and a
/// real accessibility tree, exactly the "live AX lookups are not testable
/// here" boundary `HighlightElementAnchorTests.swift` also respects.
final class AccessibilityAnchorElementResolverTests: XCTestCase {

    // MARK: - reasonCode(for:): exhaustive mapping

    #if os(macOS)
    func testAccessibilityNotTrustedMapsToPermission() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .accessibilityNotTrusted), "permission")
    }

    func testApplicationBusyMapsToTimeout() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .applicationBusy), "timeout")
    }

    func testTraversalTimedOutMapsToTimeout() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .traversalTimedOut(seconds: 2.0)), "timeout")
    }

    func testAmbiguousMapsToAmbiguous() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .ambiguous(matches: [])), "ambiguous")
    }

    func testNoMatchesMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(for: .noMatches(label: "X", role: nil, exposedSample: [])),
            "not_found"
        )
    }

    func testLabelSeenUnderOtherRolesMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(
                for: .labelSeenUnderOtherRoles(label: "X", requestedRole: "AXButton", seenRoles: ["AXStaticText"])
            ),
            "not_found"
        )
    }

    func testOccurrenceOutOfRangeMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(
                for: .occurrenceOutOfRange(requested: 3, available: 1, framelessMatchCount: 0)
            ),
            "not_found"
        )
    }

    func testMatchesHaveNoUsableFrameMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(for: .matchesHaveNoUsableFrame(matchCount: 2)),
            "not_found"
        )
    }

    func testInvalidRequestMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .invalidRequest("bad")), "unavailable")
    }

    func testInvalidProcessIDMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .invalidProcessID), "unavailable")
    }

    func testApplicationUnavailableMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .applicationUnavailable), "unavailable")
    }

    func testTraversalLimitReachedMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .traversalLimitReached(3_000)), "unavailable")
    }

    func testFrameCannotBeMappedMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .frameCannotBeMapped), "unavailable")
    }

    // MARK: - reresolve: process-id guard, no live AX needed

    /// `Int64.max` fits neither `pid_t` (Int32) nor `UInt32`, so this must
    /// fail closed before ever calling `AccessibilityElementResolver.resolve`
    /// -- exercisable with no Accessibility permission and no live process.
    func testReresolveReturnsNotFoundWhenProcessIdDoesNotFitThePlatformType() {
        let resolver = AccessibilityAnchorElementResolver()
        let target = AnchorWindowTarget(processId: Int64.max, windowId: 1, appId: "com.example.App")
        let spec = AnchorElementSpec(
            label: "X", role: nil, matchMode: "exact", occurrence: 0,
            maxNodes: 100, timeoutSeconds: 2, shape: "rect", paddingPx: 4
        )
        let annotation = makeVectorPathAnnotation()

        let result = resolver.reresolve(annotation: annotation, spec: spec, target: target, screens: [])
        assertIssue(result, "not_found")
    }
    #endif

    #if os(Windows)
    func testAccessibilityNotTrustedMapsToPermission() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .accessibilityNotTrusted), "permission")
    }

    func testElevationBoundaryMapsToPermission() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .elevationBoundary), "permission")
    }

    func testApplicationBusyMapsToTimeout() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .applicationBusy), "timeout")
    }

    func testAmbiguousMapsToAmbiguous() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .ambiguous(matchCount: 4)), "ambiguous")
    }

    func testNoMatchesMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(for: .noMatches(label: "X", role: nil, exposedSample: [])),
            "not_found"
        )
    }

    func testOccurrenceOutOfRangeMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(
                for: .occurrenceOutOfRange(requested: 2, available: 1, framelessMatchCount: 0)
            ),
            "not_found"
        )
    }

    func testMatchesHaveNoUsableFrameMapsToNotFound() {
        XCTAssertEqual(
            AccessibilityAnchorElementResolver.reasonCode(for: .matchesHaveNoUsableFrame(matchCount: 1)),
            "not_found"
        )
    }

    func testInvalidRequestMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .invalidRequest("bad")), "unavailable")
    }

    func testInvalidProcessIDMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .invalidProcessID), "unavailable")
    }

    func testApplicationUnavailableMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .applicationUnavailable), "unavailable")
    }

    func testTraversalLimitReachedMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .traversalLimitReached(3_000)), "unavailable")
    }

    func testFrameCannotBeMappedMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .frameCannotBeMapped), "unavailable")
    }

    func testRoleFilterNotSupportedMapsToUnavailable() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .roleFilterNotSupported), "unavailable")
    }

    /// Regression pin: `.workerPoolExhausted` (CHALK_ERR_UIA_TOO_MANY_PENDING)
    /// must NOT land in `"timeout"` despite also being a hung-provider
    /// condition -- the header documents that code as explicitly
    /// NON-retryable (retrying only stacks another stuck worker thread onto
    /// an already-saturated pool), unlike `.applicationBusy`'s genuinely
    /// transient `CHALK_ERR_UIA_RETRYABLE_TIMEOUT`, so `AnchorTracker`'s own
    /// retry cadence must not be invited to hammer it. It groups with the
    /// other structural-budget-exhaustion case, `traversalLimitReached`.
    func testWorkerPoolExhaustedMapsToUnavailableNotTimeout() {
        XCTAssertEqual(AccessibilityAnchorElementResolver.reasonCode(for: .workerPoolExhausted), "unavailable")
    }

    /// `Int64.max` does not fit `UInt32` either, so this must fail closed
    /// before ever calling `AccessibilityElementResolver.resolve`.
    func testReresolveReturnsNotFoundWhenProcessIdDoesNotFitThePlatformType() {
        let resolver = AccessibilityAnchorElementResolver()
        let target = AnchorWindowTarget(processId: Int64.max, windowId: 1, appId: "com.example.App")
        let spec = AnchorElementSpec(
            label: "X", role: nil, matchMode: "exact", occurrence: 0,
            maxNodes: 100, timeoutSeconds: 2, shape: "rect", paddingPx: 4
        )
        let annotation = makeVectorPathAnnotation()

        let result = resolver.reresolve(annotation: annotation, spec: spec, target: target, screens: [])
        assertIssue(result, "not_found")
    }
    #endif

    // MARK: - Post-walk display-layout guard (pure core)

    // macOS-only, like the rest of this file's per-platform sections: the
    // fixtures below drive the macOS `backingRect` conversion (zero-origin
    // AppKit anchoring, points-times-scale), whose inputs differ on Windows.
    // `conversionSurvivedWalk` itself is platform-neutral.
    #if os(macOS)
    private func snapshot(scale: Double) -> [ScreenInfo] {
        // One zero-origin display -- `backingRect`'s macOS conversion
        // requires the (0,0)-AppKit-origin screen to anchor its y-flip.
        let frame = ScreenCoordinateRect(x: 0, y: 0, width: 2_000, height: 1_200)
        return [
            ScreenInfo(
                id: "main", index: 0, name: "main",
                widthPx: Int(2_000 * scale), heightPx: Int(1_200 * scale),
                widthPt: 2_000, heightPt: 1_200,
                backingScaleFactor: scale, isMain: true,
                appKitFrame: frame, windowServerFrame: frame, displayID: 1
            )
        ]
    }

    /// Builds a match exactly the way `resolve` does: `backingFrame`
    /// converted from `accessibilityFrame` against the PRE-walk snapshot.
    private func makeMatch(preWalkScreens: [ScreenInfo]) throws -> AccessibilityElementMatch {
        let axFrame = AccessibilityScreenRect(x: 100, y: 50, width: 200, height: 40)
        let backing = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: axFrame, screens: preWalkScreens
        ))
        return AccessibilityElementMatch(
            matchedAttribute: "AXTitle", matchedLabel: "OK", role: nil,
            accessibilityFrame: axFrame, backingFrame: backing
        )
    }

    func testConversionSurvivesAnUnchangedDisplayLayout() throws {
        let pre = snapshot(scale: 2)
        let match = try makeMatch(preWalkScreens: pre)
        XCTAssertTrue(
            AccessibilityAnchorElementResolver.conversionSurvivedWalk(match: match, screensAfterWalk: pre),
            "an unchanged layout must re-derive the identical backing frame and pass"
        )
    }

    func testConversionIsRejectedWhenTheDisplayWasRescaledMidWalk() throws {
        let match = try makeMatch(preWalkScreens: snapshot(scale: 2))
        // Same display id, same point geometry, HALF the density: the fresh
        // conversion yields a well-formed rect at different pixel
        // coordinates -- exactly the silent misplacement the guard exists
        // to catch.
        XCTAssertFalse(
            AccessibilityAnchorElementResolver.conversionSurvivedWalk(
                match: match, screensAfterWalk: snapshot(scale: 1)
            ),
            "a mid-walk density change must be reported, never committed as anchor geometry"
        )
    }

    func testConversionIsRejectedWhenTheDisplayWasDisconnectedMidWalk() throws {
        let match = try makeMatch(preWalkScreens: snapshot(scale: 2))
        XCTAssertFalse(
            AccessibilityAnchorElementResolver.conversionSurvivedWalk(match: match, screensAfterWalk: []),
            "a frame that no longer maps onto any connected display must be rejected"
        )
    }
    #endif

    // MARK: - Helpers

    private func makeVectorPathAnnotation() -> Annotation {
        Annotation(
            screenId: "screen-1",
            kind: .vectorPath(
                data: "M 0 0 H 1 V 1 H 0 Z",
                strokeColorHex: "#FF0000",
                strokeWidth: 4,
                strokeOpacity: 1,
                fillColorHex: nil,
                fillOpacity: 0,
                dash: [],
                usesEvenOddFillRule: false,
                coordinateScaleX: 1,
                coordinateScaleY: 1
            )
        )
    }

    /// `AnchorElementReresolution` is not `Equatable` (its `.resolved` case
    /// carries `AnnotationKind`, which is not `Equatable` either), so this
    /// asserts by pattern match instead of `XCTAssertEqual`.
    private func assertIssue(
        _ result: AnchorElementReresolution, _ expectedCode: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .issue(let code):
            XCTAssertEqual(code, expectedCode, file: file, line: line)
        case .resolved:
            XCTFail("expected .issue(\"\(expectedCode)\"), got .resolved", file: file, line: line)
        }
    }
}
