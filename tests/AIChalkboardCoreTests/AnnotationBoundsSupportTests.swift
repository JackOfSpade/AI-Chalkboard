import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `AnnotationBoundsSupport` -- the pure validation/arithmetic behind
/// `get_annotation_bounds` (Sources/MCP/MCPToolHandlers+AnnotationBounds.swift).
/// Every function here is a plain static func over `[String: Any]`/`CGRect`/
/// `ScreenInfo`/`AnchorAdjustment` values, so this suite drives it directly
/// with no MCP transport, no store, and no live display -- matching
/// `DrawRequestScreenshotMappingTests`'s and `AnchorAdjustmentTests`'s own
/// "decision separate from the runtime plumbing" precedent.
final class AnnotationBoundsSupportTests: XCTestCase {
    private func screen(width: Int = 3_840, height: Int = 2_160, scale: Double = 1) -> ScreenInfo {
        ScreenInfo(
            id: "screen-1", index: 0, name: "Test Screen", widthPx: width, heightPx: height,
            widthPt: Double(width) / scale, heightPt: Double(height) / scale,
            backingScaleFactor: scale, isMain: true
        )
    }

    // MARK: - resolveScreenshotDimensions: both-or-neither

    func testNeitherDimensionSuppliedSucceedsWithNil() {
        switch AnnotationBoundsSupport.resolveScreenshotDimensions([:], screen: screen()) {
        case .success(let value): XCTAssertNil(value)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testOnlyWidthSuppliedIsRejected() {
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(["screenshot_width": 1_920], screen: screen()) {
        case .success: XCTFail("one of the pair alone must be rejected")
        case .failure(let message):
            XCTAssertTrue(message.contains("together"), message)
        }
    }

    func testOnlyHeightSuppliedIsRejected() {
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(["screenshot_height": 1_080], screen: screen()) {
        case .success: XCTFail("one of the pair alone must be rejected")
        case .failure(let message):
            XCTAssertTrue(message.contains("together"), message)
        }
    }

    /// A JSON `null` must behave exactly like an absent key -- the same rule
    /// `DrawRequest.coordinateTransform`'s identical `isSupplied` helper
    /// documents (a schema-driven client that nulls unused fields is an
    /// ordinary caller, not a malformed one).
    func testExplicitNullOnBothCountsAsNeitherSupplied() {
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(
            ["screenshot_width": NSNull(), "screenshot_height": NSNull()], screen: screen()
        ) {
        case .success(let value): XCTAssertNil(value)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testNonPositiveOrNonIntegerDimensionsAreRejected() {
        for bad: [String: Any] in [
            ["screenshot_width": 0, "screenshot_height": 1_080],
            ["screenshot_width": -100, "screenshot_height": 1_080],
            ["screenshot_width": "oops", "screenshot_height": 1_080]
        ] {
            switch AnnotationBoundsSupport.resolveScreenshotDimensions(bad, screen: screen()) {
            case .success: XCTFail("non-positive/non-integer dimensions must be rejected: \(bad)")
            case .failure(let message): XCTAssertTrue(message.contains("positive integers"), message)
            }
        }
    }

    // MARK: - resolveScreenshotDimensions: aspect-mismatch rejection

    func testMatchingAspectRatioIsAccepted() {
        // A native full-resolution "screenshot" of the 3840x2160 test screen.
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(
            ["screenshot_width": 3_840, "screenshot_height": 2_160], screen: screen()
        ) {
        case .success(let value): XCTAssertEqual(value?.width, 3_840); XCTAssertEqual(value?.height, 2_160)
        case .failure(let error): XCTFail("a native full-display capture must be accepted, got \(error)")
        }

        // A clean half-resolution downsample must also be accepted.
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(
            ["screenshot_width": 1_920, "screenshot_height": 1_080], screen: screen()
        ) {
        case .success(let value): XCTAssertEqual(value?.width, 1_920); XCTAssertEqual(value?.height, 1_080)
        case .failure(let error): XCTFail("a uniform downsample must be accepted, got \(error)")
        }
    }

    func testAspectMismatchIsRejectedNamingTheDisplay() {
        // 1920x1200 does not share 3840x2160's 16:9 aspect ratio -- the
        // classic cropped/wrong-window screenshot mistake.
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(
            ["screenshot_width": 1_920, "screenshot_height": 1_200], screen: screen()
        ) {
        case .success: XCTFail("an aspect-ratio mismatch must be rejected, not stretched to fit")
        case .failure(let message):
            XCTAssertTrue(message.contains("aspect ratio"), message)
            XCTAssertTrue(message.contains("screen-1"), message)
        }
    }

    /// This reuses `ScreenshotGeometry.fullDisplayScale` -- the SAME rule
    /// `coordinate_space='screenshot_pixels'` uses for drawing coordinates
    /// -- deliberately NOT the stricter `isPlausibleFullDisplayCapture` that
    /// the verification/draw-path AMBIGUOUS-DISPLAY guards use elsewhere.
    /// That stricter rule additionally forbids an enlargement because its
    /// job is "which display is this image a picture of" (no capture
    /// pipeline upscales, so a larger image cannot be a native capture).
    /// This tool asks a different question -- "can these screenshot_width/
    /// height dimensions be mapped onto the display I ALREADY KNOW this
    /// annotation is on" -- exactly what a draw call already answers for
    /// itself when scaling backing pixels up into a caller's own numbers, so
    /// direction must not matter here, only aspect ratio.
    func testAspectRatioMatchIsAcceptedRegardlessOfScaleDirection() {
        // Screenshot SMALLER than backing pixels -- the ordinary downsampled
        // capture case, already covered by `testMatchingAspectRatioIsAccepted`.
        //
        // Screenshot LARGER than backing pixels, same aspect ratio: not a
        // realistic capture, but not this tool's question to answer either
        // -- see the doc comment above.
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(
            ["screenshot_width": 7_680, "screenshot_height": 4_320], screen: screen()
        ) {
        case .success(let value): XCTAssertEqual(value?.width, 7_680); XCTAssertEqual(value?.height, 4_320)
        case .failure(let error): XCTFail("aspect-ratio match must be accepted regardless of scale direction, got \(error)")
        }
    }

    // MARK: - parseTargetBounds

    func testTargetBoundsOmittedOrNullSucceedsWithNil() {
        switch AnnotationBoundsSupport.parseTargetBounds([:]) {
        case .success(let value): XCTAssertNil(value)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
        switch AnnotationBoundsSupport.parseTargetBounds(["target_bounds_screenshot_px": NSNull()]) {
        case .success(let value): XCTAssertNil(value)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testTargetBoundsParsesAllFourFields() {
        switch AnnotationBoundsSupport.parseTargetBounds([
            "target_bounds_screenshot_px": ["x": 10, "y": 20, "width": 30, "height": 40]
        ]) {
        case .success(let value):
            XCTAssertEqual(value, CGRect(x: 10, y: 20, width: 30, height: 40))
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testTargetBoundsRejectsMissingOrNonNumericFields() {
        switch AnnotationBoundsSupport.parseTargetBounds([
            "target_bounds_screenshot_px": ["x": 10, "y": 20, "width": 30]
        ]) {
        case .success: XCTFail("a missing field must be rejected")
        case .failure(let message): XCTAssertTrue(message.contains("finite numeric"), message)
        }
    }

    func testTargetBoundsRejectsNegativeSize() {
        switch AnnotationBoundsSupport.parseTargetBounds([
            "target_bounds_screenshot_px": ["x": 0, "y": 0, "width": -5, "height": 10]
        ]) {
        case .success: XCTFail("a negative width must be rejected")
        case .failure(let message): XCTAssertTrue(message.contains("not be negative"), message)
        }
    }

    // MARK: - screenshotRect: backing -> screenshot pixel-space mapping

    func testScreenshotRectScalesEachAxisIndependently() {
        let backing = CGRect(x: 100, y: 200, width: 300, height: 400)
        let mapped = AnnotationBoundsSupport.screenshotRect(backingRect: backing, scale: (x: 0.5, y: 0.25))
        XCTAssertEqual(mapped, CGRect(x: 50, y: 50, width: 150, height: 100))
    }

    func testScreenshotRectAtScaleOneIsIdentity() {
        let backing = CGRect(x: 12, y: 34, width: 56, height: 78)
        XCTAssertEqual(AnnotationBoundsSupport.screenshotRect(backingRect: backing, scale: (x: 1, y: 1)), backing)
    }

    // MARK: - correctedOffset: the correction arithmetic

    /// UNANCHORED case: `.identity` adjustment. The formula must reduce to
    /// the "obvious" answer -- current offset plus the backing-pixel delta,
    /// unscaled -- reached via the SAME code path as the anchored case
    /// below, not a special case.
    func testCorrectedOffsetWithIdentityAdjustmentAddsTheBackingDeltaDirectly() {
        let corrected = AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: 5, currentOffsetY: -3,
            deltaScreenshotX: 20, deltaScreenshotY: 10,
            screenshotToBackingScale: (x: 2, y: 2), // screenshot is half backing size
            adjustment: .identity
        )
        let value = try! XCTUnwrap(corrected)
        XCTAssertEqual(value.offsetX, 5 + 20 * 2)
        XCTAssertEqual(value.offsetY, -3 + 10 * 2)
    }

    /// ANCHORED, non-1 scale case: the coordinator's load-bearing formula --
    /// the backing-pixel delta must be divided by `adjustment.scaleX`/
    /// `scaleY`, not added directly, because
    /// `AnnotationRenderer.drawAnnotations` computes the painted offset as
    /// `offsetX * adjustment.scaleX + adjustment.translateX`. See the full
    /// derivation in `AnnotationBoundsSupport.correctedOffset`'s doc comment.
    func testCorrectedOffsetDividesBackingDeltaByTheAdjustmentScale() {
        let adjustment = AnchorAdjustment(scaleX: 2, scaleY: 4, translateX: 0, translateY: 0)
        let corrected = AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: 100, currentOffsetY: 100,
            deltaScreenshotX: 10, deltaScreenshotY: 10,
            screenshotToBackingScale: (x: 1, y: 1), // screenshot pixels == backing pixels here
            adjustment: adjustment
        )
        let value = try! XCTUnwrap(corrected)
        // deltaBacking = (10, 10); dividing by scaleX=2/scaleY=4 -- NOT
        // multiplying, and NOT adding the raw delta -- must land at exactly:
        XCTAssertEqual(value.offsetX, 100 + 10 / 2.0)
        XCTAssertEqual(value.offsetY, 100 + 10 / 4.0)
    }

    func testCorrectedOffsetReturnsNilForZeroOrNonFiniteAdjustmentScale() {
        let zeroScale = AnchorAdjustment(scaleX: 0, scaleY: 1, translateX: 0, translateY: 0)
        XCTAssertNil(AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: 0, currentOffsetY: 0, deltaScreenshotX: 1, deltaScreenshotY: 1,
            screenshotToBackingScale: (x: 1, y: 1), adjustment: zeroScale
        ), "a zero adjustment scale must omit the correction rather than divide by zero")

        let nanScale = AnchorAdjustment(scaleX: .nan, scaleY: 1, translateX: 0, translateY: 0)
        XCTAssertNil(AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: 0, currentOffsetY: 0, deltaScreenshotX: 1, deltaScreenshotY: 1,
            screenshotToBackingScale: (x: 1, y: 1), adjustment: nanScale
        ), "a non-finite adjustment scale must omit the correction rather than propagate NaN")
    }

    // MARK: - notPaintedDisclosure: the "hidden/lost is not currently painted" fix

    /// THE fix's core case: an anchored annotation whose window is currently
    /// `.hidden` must disclose that `paintedBoundsBackingPx` is a
    /// hypothetical, not a report of something actually on screen.
    func testNotPaintedDisclosureAppearsForAHiddenAnchor() {
        let disclosure = AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: true, state: .hidden)
        let text = try! XCTUnwrap(disclosure)
        XCTAssertTrue(text.contains("hidden"), "must name the actual state, not a generic warning")
        XCTAssertTrue(text.contains("NOT being painted"))
    }

    /// Same disclosure for `.lost` -- painting is suppressed permanently for
    /// a lost anchor too (see `Annotation.anchorPermitsPainting`'s doc
    /// comment), and this tool's caller needs the same warning either way.
    func testNotPaintedDisclosureAppearsForALostAnchor() {
        let disclosure = AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: true, state: .lost)
        let text = try! XCTUnwrap(disclosure)
        XCTAssertTrue(text.contains("lost"))
    }

    /// A `.tracking` anchor IS currently painted where reported -- no
    /// disclosure needed, and none must be added, or every anchored
    /// annotation's response would carry a spurious warning.
    func testNotPaintedDisclosureAbsentForATrackingAnchor() {
        XCTAssertNil(AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: true, state: .tracking))
    }

    /// An unanchored annotation has no `anchor.state` for a caller to
    /// cross-reference in the first place, so `state` is irrelevant to it --
    /// this must stay nil even if a stray `state` value were somehow passed
    /// in alongside `isAnchored: false`, since an unanchored annotation's
    /// bounds are never conditional on any window.
    func testNotPaintedDisclosureAbsentWhenUnanchoredRegardlessOfState() {
        XCTAssertNil(AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: false, state: .hidden))
        XCTAssertNil(AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: false, state: .lost))
        XCTAssertNil(AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: false, state: nil))
    }

    /// A `nil` state on an anchored annotation -- never sampled yet -- must
    /// not be treated as "not painted": only an OBSERVED `.hidden`/`.lost`
    /// verdict warrants the warning.
    func testNotPaintedDisclosureAbsentForAnAnchoredAnnotationWithNoStateYet() {
        XCTAssertNil(AnnotationBoundsSupport.notPaintedDisclosure(isAnchored: true, state: nil))
    }

    // MARK: - isScreenshotSpaceSupplied (Phase B: screenshot_space plumbing)

    /// A JSON `null` must NOT count as supplied -- the SAME rule
    /// `ScreenshotSpaceExpansion`'s own `isSupplied` documents, and this
    /// predicate exists precisely so `get_annotation_bounds`'s and
    /// `verify_annotation`'s display-mismatch guards agree with expansion
    /// about what "referenced a space" means.
    func testIsScreenshotSpaceSuppliedRules() {
        XCTAssertFalse(AnnotationBoundsSupport.isScreenshotSpaceSupplied([:]))
        XCTAssertFalse(AnnotationBoundsSupport.isScreenshotSpaceSupplied(["screenshot_space": NSNull()]))
        XCTAssertTrue(AnnotationBoundsSupport.isScreenshotSpaceSupplied(["screenshot_space": "space-ab12cd34"]))
    }

    // MARK: - rectPayload: the shared rect wire shape

    func testRectPayloadEncodesAllFourFields() {
        let payload = AnnotationBoundsSupport.rectPayload(CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(payload["x"], 1)
        XCTAssertEqual(payload["y"], 2)
        XCTAssertEqual(payload["width"], 3)
        XCTAssertEqual(payload["height"], 4)
    }

    // MARK: - rendererGeometryEvidenceSentence: shared verbatim with verify_annotation

    /// `get_annotation_bounds` and `verify_annotation`'s `capture_source=
    /// "none"` verdict both show this sentence word for word (see
    /// `handleVerifyAnnotationGeometry` in MCPToolHandlers+Verification.swift)
    /// -- covering it here as a pure function is what makes that sharing
    /// checkable without a live display.
    func testRendererGeometryEvidenceSentenceNamesDisplayAndDisclaimsProof() {
        let sentence = AnnotationBoundsSupport.rendererGeometryEvidenceSentence(
            screenId: "screen-1", screenWidthPx: 3_840, screenHeightPx: 2_160
        )
        XCTAssertTrue(sentence.contains("screen-1"), sentence)
        XCTAssertTrue(sentence.contains("3840x2160"), sentence)
        XCTAssertTrue(sentence.contains("renderer geometry"), sentence)
        XCTAssertTrue(sentence.contains("No screen-capture API"), sentence)
        XCTAssertTrue(sentence.contains("Screen Recording"), sentence)
        // Must point back at the paths that DO produce pixel proof, worded so
        // it stays true whether it is read from get_annotation_bounds or
        // from verify_annotation's own capture_source="none" branch (never
        // "use verify_annotation" bare, which would be circular from inside
        // verify_annotation itself).
        XCTAssertTrue(sentence.contains("verify_presentation"), sentence)
        XCTAssertTrue(sentence.contains("capture_source='chalkboard'"), sentence)
    }

    // MARK: - screenshotSpaceDisplayMismatchRejection: the Phase B addendum guard

    /// Both `get_annotation_bounds` and `verify_annotation` derive their
    /// screen from the ANNOTATION alone, never from a caller-supplied
    /// `screen_id` -- so a `screenshot_space` registered for a different
    /// display must be rejected naming BOTH display ids, the annotation id,
    /// and which tool is refusing, rather than silently scaling by the wrong
    /// space's numbers.
    func testScreenshotSpaceDisplayMismatchRejectionNamesBothDisplaysAnnotationAndTool() {
        let message = AnnotationBoundsSupport.screenshotSpaceDisplayMismatchRejection(
            toolName: "get_annotation_bounds", annotationId: "ann-1",
            spaceId: "space-ab12cd34", spaceScreenId: "screen-2", annotationScreenId: "screen-1"
        )
        XCTAssertTrue(message.contains("space-ab12cd34"), message)
        XCTAssertTrue(message.contains("screen-2"), message)
        XCTAssertTrue(message.contains("screen-1"), message)
        XCTAssertTrue(message.contains("ann-1"), message)
        XCTAssertTrue(message.contains("get_annotation_bounds"), message)
        XCTAssertTrue(message.contains("Nothing was done"), message)
    }

    /// Same helper, different tool name -- proves the wording actually
    /// substitutes the caller's tool name rather than hard-coding one.
    func testScreenshotSpaceDisplayMismatchRejectionNamesVerifyAnnotationToo() {
        let message = AnnotationBoundsSupport.screenshotSpaceDisplayMismatchRejection(
            toolName: "verify_annotation", annotationId: "ann-1",
            spaceId: "space-ab12cd34", spaceScreenId: "screen-2", annotationScreenId: "screen-1"
        )
        XCTAssertTrue(message.contains("verify_annotation"), message)
    }
}
