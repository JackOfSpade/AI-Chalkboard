import XCTest
@testable import AIChalkboardCore

/// Exercises `highlight_element`'s new `anchor`/`anchor_resize` surface in
/// its independently testable halves, matching `DrawRequestAnchorTests
/// .swift`'s own split for the `draw_*` tools:
///
/// 1. `parseHighlightAnchorArguments` -- pure string/enum validation, no
///    process or window work at all. The full argument-validation matrix:
///    valid values (including the "element" NEW DEFAULT), an unknown value,
///    a wrong type, and `anchor_resize` -- valid ONLY together with
///    `anchor="window"`, so it is rejected under "none" AND under "element"
///    alike (per the shipped `highlight_element` catalog entry: "element"
///    re-resolves the true bounds directly, so no resize POLICY applies).
/// 2. `makeAnchorElementSpec` -- pure construction of the `AnchorElementSpec`
///    a resolved `.element`-mode anchor carries, including this file's own
///    `occurrence`-absent-means-`0` sentinel.
/// 3. `buildHighlightAnchor` -- the pure DECISION half of window resolution:
///    which window wins (by intersection with the RESOLVED ELEMENT FRAME,
///    never some other rect), and what a `.window` vs. `.element` request
///    writes into the resulting `AnnotationAnchor`/`AnchorProjection`.
///    Exercised with hand-built `TargetWindowSample`s, needing no live
///    foreign window, matching `DrawRequestAnchorTests`'s treatment of
///    `buildWindowAnchor` itself.
/// 4. The per-mode `anchorBehavior` literal strings and the no-window
///    "target_window_unresolved" fallback payload shape -- both plain,
///    directly inspectable constants.
///
/// The impure glue (`attachHighlightAnchor`, which calls the live
/// `TargetWindowProbe.shared`/`AnnotationStore.shared`) is deliberately
/// `private` to MCPToolHandlers+Highlight.swift and not exercised here, for
/// the same reason `DrawRequest.resolveWindowAnchor` is not covered by
/// `DrawRequestAnchorTests`: it needs a real running process and a real
/// foreign window. Live Accessibility lookups are covered by neither file;
/// `AccessibilityAnchorElementResolverReasonCodeTests.swift` (alongside this
/// file) instead pins the pure DECISION/MAPPING half of the tracker's
/// element-resolve conformance.
final class HighlightElementAnchorTests: XCTestCase {

    // MARK: - parseHighlightAnchorArguments: valid values

    func testAnchorAbsentDefaultsToElementModeWithPinResize() {
        assertSuccess(parseHighlightAnchorArguments([:]), HighlightAnchorRequest(mode: .element, resize: .pin))
    }

    func testAnchorNoneIsExplicitlyUnanchored() {
        assertSuccess(parseHighlightAnchorArguments(["anchor": "none"]), nil)
    }

    func testAnchorElementExplicitWithNoResizeDefaultsToPin() {
        assertSuccess(parseHighlightAnchorArguments(["anchor": "element"]), HighlightAnchorRequest(mode: .element, resize: .pin))
    }

    func testAnchorWindowExplicitWithNoResizeDefaultsToPin() {
        assertSuccess(parseHighlightAnchorArguments(["anchor": "window"]), HighlightAnchorRequest(mode: .window, resize: .pin))
    }

    func testAnchorWindowWithExplicitPin() {
        assertSuccess(
            parseHighlightAnchorArguments(["anchor": "window", "anchor_resize": "pin"]),
            HighlightAnchorRequest(mode: .window, resize: .pin)
        )
    }

    func testAnchorWindowWithExplicitScale() {
        assertSuccess(
            parseHighlightAnchorArguments(["anchor": "window", "anchor_resize": "scale"]),
            HighlightAnchorRequest(mode: .window, resize: .scale)
        )
    }

    // MARK: - parseHighlightAnchorArguments: anchor_resize is "window"-only

    /// `anchor_resize` is inapplicable to `.element` mode -- it re-resolves
    /// the element's true bounds directly on settle, so no resize POLICY
    /// applies (see the shipped `highlight_element` catalog entry's own
    /// `anchor_resize` description) -- so this must be rejected exactly like
    /// `anchor="none"` is, with the SAME literal message.
    func testAnchorResizeWithAnchorElementIsRejected() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": "element", "anchor_resize": "pin"]),
            "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."
        )
    }

    /// THE KEY DIVERGENCE FROM `draw_*`: highlight_element's default anchor
    /// is "element", never "none" -- but `anchor_resize` is STILL rejected
    /// with no `anchor` argument at all, because the default it is being
    /// applied against is "element", not "window". Unlike
    /// `DrawRequestAnchorTests.testAnchorResizeWithoutAnchorIsRejected`
    /// (which is rejected because draw_*'s default effective mode is "none"),
    /// this is rejected because highlight_element's default effective mode is
    /// "element" -- a DIFFERENT reason arriving at the same outcome.
    func testAnchorResizeAloneIsRejectedBecauseTheDefaultModeIsElementNotWindow() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor_resize": "scale"]),
            "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."
        )
    }

    // MARK: - parseHighlightAnchorArguments: wrong type

    func testAnchorWrongTypeIsRejected() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": 42]),
            "anchor must be one of \"element\", \"window\", \"none\" when supplied."
        )
    }

    func testAnchorResizeWrongTypeIsRejected() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": "window", "anchor_resize": 1]),
            "anchor_resize must be one of \"pin\", \"scale\" when supplied."
        )
    }

    // MARK: - parseHighlightAnchorArguments: unknown value

    func testAnchorUnknownValueIsRejected() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": "orbit"]),
            "anchor must be one of \"element\", \"window\", \"none\" when supplied."
        )
    }

    func testAnchorResizeUnknownValueIsRejected() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": "element", "anchor_resize": "stretch"]),
            "anchor_resize must be one of \"pin\", \"scale\" when supplied."
        )
    }

    // MARK: - parseHighlightAnchorArguments: anchor_resize with anchor="none"

    func testAnchorResizeWithAnchorNoneIsRejected() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": "none", "anchor_resize": "scale"]),
            "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."
        )
    }

    /// `anchor_resize`'s own value must be validated even when it will end up
    /// rejected for `anchor="none"`: an unknown value is the caller's own
    /// mistake and should be named specifically, not masked by the
    /// "only valid with window" message -- mirrors `DrawRequestAnchorTests
    /// .testAnchorResizeInvalidValueTakesPrecedenceOverTheAnchorNoneRejection`.
    func testAnchorResizeInvalidValueTakesPrecedenceOverTheAnchorNoneRejection() {
        assertFailure(
            parseHighlightAnchorArguments(["anchor": "none", "anchor_resize": "bogus"]),
            "anchor_resize must be one of \"pin\", \"scale\" when supplied."
        )
    }

    // MARK: - makeAnchorElementSpec

    func testMakeAnchorElementSpecPopulatesEveryFieldFromTheRequest() {
        let spec = makeAnchorElementSpec(
            label: "Render", role: "AXButton", matchMode: .contains, occurrence: 3,
            maxNodes: 5_000, timeoutSeconds: 4.5, shape: .circle, paddingPx: 12
        )
        XCTAssertEqual(spec.label, "Render")
        XCTAssertEqual(spec.role, "AXButton")
        XCTAssertEqual(spec.matchMode, "contains")
        XCTAssertEqual(spec.occurrence, 3)
        XCTAssertEqual(spec.maxNodes, 5_000)
        XCTAssertEqual(spec.timeoutSeconds, 4.5)
        XCTAssertEqual(spec.shape, "circle")
        XCTAssertEqual(spec.paddingPx, 12)
    }

    func testMakeAnchorElementSpecDefaultsRoleToNilWhenNotSupplied() {
        let spec = makeAnchorElementSpec(
            label: "OK", role: nil, matchMode: .exact, occurrence: 1,
            maxNodes: 100, timeoutSeconds: 2, shape: .rect, paddingPx: 8
        )
        XCTAssertNil(spec.role)
    }

    /// `0` is `makeAnchorElementSpec`'s own sentinel for "the caller did not
    /// supply occurrence" -- `AccessibilityAnchorElementResolver` translates
    /// it back to `nil` to reproduce the original call's uniqueness
    /// requirement exactly (see that file's own doc comment).
    func testMakeAnchorElementSpecStoresZeroSentinelWhenOccurrenceIsNotSupplied() {
        let spec = makeAnchorElementSpec(
            label: "OK", role: nil, matchMode: .exact, occurrence: nil,
            maxNodes: 100, timeoutSeconds: 2, shape: .rect, paddingPx: 8
        )
        XCTAssertEqual(spec.occurrence, 0)
    }

    func testMakeAnchorElementSpecStoresASuppliedOccurrenceVerbatim() {
        let spec = makeAnchorElementSpec(
            label: "OK", role: nil, matchMode: .exact, occurrence: 5,
            maxNodes: 100, timeoutSeconds: 2, shape: .rect, paddingPx: 8
        )
        XCTAssertEqual(spec.occurrence, 5)
    }

    // MARK: - buildHighlightAnchor: the window-selection decision

    private static let fixtureScreenId = "screen-1"

    private func sample(
        windowId: UInt64, x: Double, y: Double, width: Double, height: Double,
        processId: Int64 = 500, screenId: String = fixtureScreenId
    ) -> TargetWindowSample {
        TargetWindowSample(
            windowId: windowId, processId: processId,
            frame: CGRect(x: x, y: y, width: width, height: height),
            screenId: screenId, isOnScreen: true
        )
    }

    private func elementSpecFixture() -> AnchorElementSpec {
        AnchorElementSpec(
            label: "Render", role: nil, matchMode: "exact", occurrence: 0,
            maxNodes: 3_000, timeoutSeconds: 2, shape: "rect", paddingPx: 8
        )
    }

    func testBuildHighlightAnchorReturnsNilForNoCandidatesInWindowMode() {
        XCTAssertNil(buildHighlightAnchor(
            mode: .window, processId: 500, appId: "com.example.App", samples: [],
            elementFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            resize: .pin, elementSpec: nil, now: Date()
        ))
    }

    func testBuildHighlightAnchorReturnsNilForNoCandidatesInElementMode() {
        XCTAssertNil(buildHighlightAnchor(
            mode: .element, processId: 500, appId: "com.example.App", samples: [],
            elementFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            resize: .pin, elementSpec: elementSpecFixture(), now: Date()
        ))
    }

    /// The selection must intersect against the RESOLVED ELEMENT FRAME, not
    /// some other rect: an element frame that only meaningfully overlaps the
    /// SECOND (non-front-most) window must select that window, exactly the
    /// distinction ELEMENT_MODE.md and this task both call out by name.
    func testBuildHighlightAnchorWindowModeSelectsLargestIntersectionWithTheElementFrame() throws {
        let elementFrame = CGRect(x: 190, y: 190, width: 20, height: 20)
        let samples = [
            sample(windowId: 1, x: 0, y: 0, width: 50, height: 50),   // front-most, no overlap at all
            sample(windowId: 2, x: 0, y: 0, width: 300, height: 300)  // fully contains the element frame
        ]
        let now = Date()
        let resolution = try XCTUnwrap(buildHighlightAnchor(
            mode: .window, processId: 500, appId: "com.example.App", samples: samples,
            elementFrame: elementFrame, resize: .pin, elementSpec: nil, now: now
        ))
        XCTAssertEqual(resolution.anchor.target.windowId, 2)
        XCTAssertEqual(resolution.anchor.mode, .window)
        XCTAssertNil(resolution.anchor.element, "window mode never carries an element spec")
        XCTAssertEqual(resolution.anchor.referenceWindowFrame, AnchorRect(CGRect(x: 0, y: 0, width: 300, height: 300)))
        XCTAssertEqual(resolution.projection.state, .tracking)
    }

    /// A drawing's own PAINTED bounds (padded/shaped) must not be what wins
    /// the window contest: an element frame with no padding at all, placed
    /// so only a small, unpadded window contains it, must still pick that
    /// window even though a padded highlight around the same element would
    /// have overlapped a different, larger window too.
    func testBuildHighlightAnchorUsesTheSuppliedElementFrameExactlyNotAPaddedVariant() throws {
        let elementFrame = CGRect(x: 5, y: 5, width: 2, height: 2)
        let samples = [
            sample(windowId: 1, x: 0, y: 0, width: 10, height: 10, processId: 77),
            sample(windowId: 2, x: 1_000, y: 1_000, width: 10, height: 10, processId: 77)
        ]
        let resolution = try XCTUnwrap(buildHighlightAnchor(
            mode: .window, processId: 77, appId: "com.example.App", samples: samples,
            elementFrame: elementFrame, resize: .pin, elementSpec: nil, now: Date()
        ))
        XCTAssertEqual(resolution.anchor.target.windowId, 1)
    }

    /// Sample frames are local to their own screens, so two windows on
    /// different displays may both appear to contain the same numerical
    /// element frame. The highlight must only consider the element's actual
    /// display; otherwise its identity projection would move the highlight
    /// into a different local coordinate system.
    func testBuildHighlightAnchorIgnoresFrontmostOtherScreenWithSameLocalCoordinates() throws {
        let elementFrame = CGRect(x: 40, y: 40, width: 20, height: 20)
        let samples = [
            sample(windowId: 1, x: 0, y: 0, width: 200, height: 200, screenId: "screen-2"),
            sample(windowId: 2, x: 0, y: 0, width: 100, height: 100, screenId: Self.fixtureScreenId)
        ]

        let resolution = try XCTUnwrap(buildHighlightAnchor(
            mode: .window, processId: 500, appId: "com.example.App", samples: samples,
            elementFrame: elementFrame, resize: .pin, elementSpec: nil, now: Date(),
            screenId: Self.fixtureScreenId
        ))
        XCTAssertEqual(resolution.anchor.target.windowId, 2)
        XCTAssertEqual(resolution.projection.effectiveScreenId, Self.fixtureScreenId)
    }

    func testBuildHighlightAnchorReturnsNilWhenNoWindowIsOnTheElementScreen() {
        XCTAssertNil(buildHighlightAnchor(
            mode: .element, processId: 500, appId: "com.example.App",
            samples: [sample(windowId: 1, x: 0, y: 0, width: 100, height: 100, screenId: "screen-2")],
            elementFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
            resize: .pin, elementSpec: elementSpecFixture(), now: Date(), screenId: Self.fixtureScreenId
        ))
    }

    /// `resize: .scale` is used here even though `parseHighlightAnchorArguments`
    /// never actually produces `.element` mode with anything but `.pin` (see
    /// that function's own doc comment on why `anchor_resize` is rejected
    /// outright for `anchor="element"`): `buildHighlightAnchor` itself is a
    /// lower-level function that has no opinion on that restriction -- it is
    /// the CALLER's policy, not this one's -- so this deliberately proves
    /// `buildHighlightAnchor` threads whatever `resize` it is given straight
    /// through, unconditionally.
    func testBuildHighlightAnchorElementModeAttachesTheSpecOnTopOfTheSameWindowSelection() throws {
        let elementFrame = CGRect(x: 10, y: 10, width: 5, height: 5)
        let samples = [sample(windowId: 9, x: 0, y: 0, width: 100, height: 100, processId: 42)]
        let spec = elementSpecFixture()
        let now = Date()
        let resolution = try XCTUnwrap(buildHighlightAnchor(
            mode: .element, processId: 42, appId: "com.example.App", samples: samples,
            elementFrame: elementFrame, resize: .scale, elementSpec: spec, now: now
        ))
        XCTAssertEqual(resolution.anchor.mode, .element)
        XCTAssertEqual(resolution.anchor.element, spec)
        XCTAssertEqual(resolution.anchor.target.windowId, 9)
        XCTAssertEqual(resolution.anchor.target.processId, 42)
        XCTAssertEqual(resolution.anchor.target.appId, "com.example.App")
        XCTAssertEqual(resolution.anchor.resize, .scale)
        XCTAssertEqual(resolution.anchor.referenceWindowFrame, AnchorRect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(resolution.anchor.referenceScreenId, Self.fixtureScreenId)
        XCTAssertEqual(resolution.anchor.createdAt, now)
        // .element mode reuses buildWindowAnchor's own identity projection
        // verbatim -- both modes must agree on the window that won.
        XCTAssertEqual(resolution.projection.state, .tracking)
        XCTAssertEqual(resolution.projection.adjustment, .identity)
        XCTAssertEqual(resolution.projection.effectiveScreenId, Self.fixtureScreenId)
        XCTAssertNil(resolution.projection.elementResolutionIssue)
    }

    func testBuildHighlightAnchorWindowAndElementModeAgreeOnWhichWindowWonForTheSameInputs() throws {
        let elementFrame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let samples = [
            sample(windowId: 1, x: 0, y: 0, width: 30, height: 30, processId: 9),
            sample(windowId: 2, x: 20, y: 20, width: 30, height: 30, processId: 9)
        ]
        let windowResolution = try XCTUnwrap(buildHighlightAnchor(
            mode: .window, processId: 9, appId: "com.example.App", samples: samples,
            elementFrame: elementFrame, resize: .pin, elementSpec: nil, now: Date()
        ))
        let elementResolution = try XCTUnwrap(buildHighlightAnchor(
            mode: .element, processId: 9, appId: "com.example.App", samples: samples,
            elementFrame: elementFrame, resize: .pin, elementSpec: elementSpecFixture(), now: Date()
        ))
        XCTAssertEqual(windowResolution.anchor.target.windowId, elementResolution.anchor.target.windowId)
        XCTAssertEqual(windowResolution.anchor.referenceWindowFrame, elementResolution.anchor.referenceWindowFrame)
    }

    // MARK: - anchorBehavior literal strings

    /// Must stay byte-identical to the string this tool has always returned
    /// -- see MCP_SURFACE.md: "the \"none\" string must stay byte-identical
    /// to today's so opting out is provably today's behaviour".
    func testAnchorBehaviorNoneStringIsByteIdenticalToTheOriginalHardcodedString() {
        XCTAssertEqual(
            highlightAnchorBehaviorNone,
            "resolved once at draw time; call highlight_element again after the UI moves"
        )
    }

    func testAnchorBehaviorElementStringMatchesMcpSurfaceVerbatim() {
        XCTAssertEqual(
            highlightAnchorBehaviorElement,
            "tracked: follows the target window as it moves and resizes, and re-resolves this element when the window settles so it stays on the control through a reflow. Check anchor.state and anchor.elementResolutionIssue in list_annotations; call highlight_element again only if it reports lost."
        )
    }

    func testAnchorBehaviorWindowStringMatchesMcpSurfaceVerbatim() {
        XCTAssertEqual(
            highlightAnchorBehaviorWindow,
            "tracked: follows the target window as it moves and resizes, applying anchor_resize to the highlight geometry. The element itself is NOT re-resolved, so a UI that reflows rather than scales will drift; use anchor=\"element\" for that."
        )
    }

    // MARK: - The no-window "target_window_unresolved" fallback payload

    /// This is the exact object `attachHighlightAnchor` reports whenever
    /// `buildHighlightAnchor` above returns nil (no eligible window found)
    /// for an "element"/"window" request -- see MCP_SURFACE.md: the call
    /// still succeeds ("the element resolved fine, and failing the call
    /// would be a regression over today's behaviour"), and this is
    /// deliberately NOT the standard `anchorResponsePayload` shape.
    func testUnresolvedAnchorPayloadIsExactlyModeNoneReasonTargetWindowUnresolved() {
        let payload = highlightAnchorUnresolvedPayload
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload["mode"] as? String, "none")
        XCTAssertEqual(payload["reason"] as? String, "target_window_unresolved")
    }

    // MARK: - BUG 5: the anchor-attach-failed fallback is NOT "target_window_unresolved"
    //
    // `attachHighlightAnchor`'s SECOND store write -- installing an already-
    // resolved anchor onto the just-created annotation -- can fail for
    // reasons that have nothing to do with "no window was found": a genuine
    // `.stale` (something changed the annotation between its creation and
    // this attach step) or a resource-cap `.rejected`. Before this fix, ANY
    // non-`.updated` outcome there was reported as `target_window_unresolved`,
    // which is simply untrue in those cases -- a window WAS resolved, and
    // the highlight itself is already drawn.
    // `highlightAnchorAttachFailurePayload(for:)` is the pure mapping this
    // pins directly, with nothing but an `AnnotationStoreUpdateResult`: no
    // live store, no window, no Accessibility walk needed (matching this
    // file's own `buildHighlightAnchor`/`parseHighlightAnchorArguments`
    // precedent for testing the DECISION half of impure glue in isolation).

    func testAnchorAttachFailurePayloadIsNilOnUpdated() {
        XCTAssertNil(highlightAnchorAttachFailurePayload(for: .updated))
    }

    func testAnchorAttachFailurePayloadOnStaleIsDistinctFromTargetWindowUnresolved() {
        let payload = highlightAnchorAttachFailurePayload(for: .stale)
        XCTAssertEqual(payload?["reason"] as? String, "annotation_changed_before_anchor_attached")
        XCTAssertNotEqual(payload?["reason"] as? String, "target_window_unresolved", "a `.stale` store write means the annotation changed underneath the attach, not that no window could be found -- conflating the two would tell the caller something false")
    }

    func testAnchorAttachFailurePayloadOnNotFoundUsesTheSameDistinctReason() {
        let payload = highlightAnchorAttachFailurePayload(for: .notFound)
        XCTAssertEqual(payload?["reason"] as? String, "annotation_changed_before_anchor_attached")
    }

    func testAnchorAttachFailurePayloadOnRejectedUsesTheSameDistinctReason() {
        let payload = highlightAnchorAttachFailurePayload(for: .rejected(.annotationCount(limit: 10, attempted: 11)))
        XCTAssertEqual(payload?["reason"] as? String, "annotation_changed_before_anchor_attached")
    }

    /// The payload must still say `mode: "none"` (this highlight ends up
    /// unanchored, exactly like the target-window-unresolved case) and must
    /// tell the caller what actually happened and what to do about it --
    /// the highlight was drawn, and a follow-up `update_annotation` can
    /// attach tracking.
    func testAnchorAttachRejectedPayloadShapeAndWording() {
        let payload = highlightAnchorAttachRejectedPayload
        XCTAssertEqual(payload["mode"] as? String, "none")
        XCTAssertEqual(payload["reason"] as? String, "annotation_changed_before_anchor_attached")
        let note = payload["note"] as? String
        XCTAssertTrue(note?.contains("was drawn") ?? false, "must tell the caller the highlight itself is still on screen")
        XCTAssertTrue(note?.contains("update_annotation") ?? false, "must tell the caller how to recover tracking")
    }

    /// `target_window_unresolved` itself must keep meaning exactly what it
    /// says -- untouched by this fix.
    func testTargetWindowUnresolvedPayloadIsUnaffectedByTheNewReasonCode() {
        XCTAssertEqual(highlightAnchorUnresolvedPayload["reason"] as? String, "target_window_unresolved")
    }

    // MARK: - Helpers

    private func assertSuccess(
        _ outcome: DrawOutcome<HighlightAnchorRequest?>,
        _ expected: HighlightAnchorRequest?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch outcome {
        case .success(let value):
            XCTAssertEqual(value, expected, file: file, line: line)
        case .failure(let message):
            XCTFail("expected success(\(String(describing: expected))) but got failure(\(message))", file: file, line: line)
        }
    }

    private func assertFailure(
        _ outcome: DrawOutcome<HighlightAnchorRequest?>,
        _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch outcome {
        case .success(let value):
            XCTFail("expected failure(\(expected)) but got success(\(String(describing: value)))", file: file, line: line)
        case .failure(let message):
            XCTAssertEqual(message, expected, file: file, line: line)
        }
    }
}
