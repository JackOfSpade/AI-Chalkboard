import XCTest
@testable import AIChalkboardCore

/// Coverage for the PURE decision logic behind Phase B's additions to
/// `verify_annotation` (Sources/MCP/MCPToolHandlers+Verification.swift):
/// `capture_source="none"` (the permission-free renderer-geometry verdict)
/// and `expect_element`/`expect_window`/`target_bounds_screenshot_px`.
///
/// What is deliberately NOT tested here: `MCPServer.handleVerifyAnnotation`,
/// `handleVerifyAnnotationGeometry`, `resolveExpectationVerdict`, and
/// `resolveExpectationTargetProcess` themselves. All four resolve the live
/// display list via `OverlayWindowController.shared.screenSnapshot()` (a
/// main-thread AppKit hop), and the `expect_*` paths additionally walk a
/// real Accessibility tree or sample real foreign windows -- none of which
/// is safe or meaningful in a headless unit test process with no display
/// attached. This mirrors `ScreenshotSpaceHandlerTests`'/
/// `ScreenshotSpaceExpansionTests`'s own "test the pure helper, not the live
/// handler" split for exactly the same reason. Every rejection a live call
/// can produce is instead pinned here at the pure-decision layer
/// (`AnnotationBoundsSupport`, and `AnnotationGeometryVerdict`'s already-pure
/// `compare`) that actually decides or shapes it.
final class VerifyAnnotationGeometryTests: XCTestCase {
    // MARK: - The reworded discoverability errors (Phase B change item 4)

    /// The EXISTING "Supply screenshot_path, or capture_source='chalkboard'"
    /// rejection must now ALSO name capture_source='none' AND
    /// get_annotation_bounds -- the single most important discoverability
    /// fix in the change, per the Phase B spec: the permission-free path
    /// already half-existed and callers denied Screen Recording had no way
    /// to learn about it from this error alone.
    func testMissingCaptureSourceRejectionNamesNoneAndGetAnnotationBounds() {
        let message = AnnotationBoundsSupport.missingCaptureSourceRejection
        XCTAssertTrue(message.contains("capture_source='none'"), message)
        XCTAssertTrue(message.contains("get_annotation_bounds"), message)
        // The original literal value this rejection has always required is
        // still present -- this is a REWORDING, not a wholesale replacement.
        XCTAssertTrue(message.contains("screenshot_path"), message)
        XCTAssertTrue(message.contains("capture_source='chalkboard'"), message)
    }

    /// The Screen-Recording-permission-denied error must likewise name
    /// capture_source='none' and get_annotation_bounds as the two paths that
    /// need no Screen Recording grant -- appended to (never replacing) the
    /// underlying permission error's own System-Settings instructions, so a
    /// caller who does intend to grant the permission keeps that guidance
    /// too. See design rule 2: a missing grant must stay a loud, actionable
    /// error, never a silent fallback to renderer geometry.
    func testPermissionDeniedAddendumNamesNoneAndGetAnnotationBounds() {
        let addendum = AnnotationBoundsSupport.permissionDeniedDiscoverabilityAddendum
        XCTAssertTrue(addendum.contains("capture_source='none'"), addendum)
        XCTAssertTrue(addendum.contains("get_annotation_bounds"), addendum)
    }

    // MARK: - screenshot_space / annotation display mismatch (verify_annotation's own use)

    /// `verify_annotation`'s `capture_source="none"` verdict derives its
    /// screen from the ANNOTATION alone, exactly like `get_annotation_bounds`
    /// -- so a `screenshot_space` registered for a different display must be
    /// rejected the same way, naming BOTH display ids, the annotation id,
    /// and THIS tool's own name (not a copy-pasted "get_annotation_bounds"
    /// left over from that tool's identical guard).
    func testScreenshotSpaceDisplayMismatchNamesVerifyAnnotationAndBothDisplays() {
        let message = AnnotationBoundsSupport.screenshotSpaceDisplayMismatchRejection(
            toolName: "verify_annotation", annotationId: "ann-42",
            spaceId: "space-deadbeef", spaceScreenId: "screen-2", annotationScreenId: "screen-1"
        )
        XCTAssertTrue(message.contains("verify_annotation"), message)
        XCTAssertTrue(message.contains("space-deadbeef"), message)
        XCTAssertTrue(message.contains("screen-2"), message)
        XCTAssertTrue(message.contains("screen-1"), message)
        XCTAssertTrue(message.contains("ann-42"), message)
        XCTAssertTrue(message.contains("Nothing was done"), message)
    }

    // MARK: - expect_element / expect_window / target_bounds_screenshot_px: at most one

    func testNoExpectationSuppliedIsFine() {
        XCTAssertEqual(AnnotationBoundsSupport.suppliedExpectationKeys([:]), [])
        XCTAssertNil(AnnotationBoundsSupport.atMostOneExpectationRejection([:]))
    }

    /// A JSON `null` must not count as "supplied" -- the same rule this
    /// package applies to every optional argument everywhere else.
    func testNullExpectationFieldsDoNotCountAsSupplied() {
        let args: [String: Any] = [
            "expect_element": NSNull(), "expect_window": NSNull(), "target_bounds_screenshot_px": NSNull()
        ]
        XCTAssertEqual(AnnotationBoundsSupport.suppliedExpectationKeys(args), [])
        XCTAssertNil(AnnotationBoundsSupport.atMostOneExpectationRejection(args))
    }

    func testExactlyOneExpectationIsFine() {
        for args: [String: Any] in [
            ["expect_element": ["label": "OK"]],
            ["expect_window": ["app": "com.example.App"]],
            ["target_bounds_screenshot_px": ["x": 0, "y": 0, "width": 10, "height": 10]]
        ] {
            XCTAssertEqual(AnnotationBoundsSupport.suppliedExpectationKeys(args).count, 1, "\(args)")
            XCTAssertNil(AnnotationBoundsSupport.atMostOneExpectationRejection(args), "\(args)")
        }
    }

    /// Supplying TWO is a contradiction, rejected rather than silently
    /// preferring one -- this repo's standing "reject rather than
    /// reinterpret" rule, applied here for the first time to a NEW pair of
    /// arguments that did not exist before Phase B.
    func testTwoExpectationsAreRejected() {
        let message = try! XCTUnwrap(AnnotationBoundsSupport.atMostOneExpectationRejection([
            "expect_element": ["label": "OK"], "expect_window": ["app": "com.example.App"]
        ]))
        XCTAssertTrue(message.contains("mutually exclusive"), message)
        XCTAssertTrue(message.contains("expect_element"), message)
        XCTAssertTrue(message.contains("expect_window"), message)
    }

    /// All three at once must be rejected too, and name every one of the
    /// three supplied keys so the caller does not have to guess which two
    /// (of three) to remove.
    func testAllThreeExpectationsAreRejectedNamingAllThree() {
        let message = try! XCTUnwrap(AnnotationBoundsSupport.atMostOneExpectationRejection([
            "expect_element": ["label": "OK"],
            "expect_window": ["app": "com.example.App"],
            "target_bounds_screenshot_px": ["x": 0, "y": 0, "width": 10, "height": 10]
        ]))
        XCTAssertTrue(message.contains("expect_element"), message)
        XCTAssertTrue(message.contains("expect_window"), message)
        XCTAssertTrue(message.contains("target_bounds_screenshot_px"), message)
    }

    // MARK: - AnnotationGeometryVerdict.compare: the verdict fields the `expect` payload reports

    /// The `expect` payload's comparison half is `AnnotationGeometryVerdict
    /// .Comparison.payload` verbatim (see `resolveExpectationVerdict`'s
    /// construction in MCPToolHandlers+Verification.swift) -- pinning the
    /// exact field set and an "on_target" case here documents the contract
    /// that payload assembly depends on, directly, with no MCP transport and
    /// no live display.
    func testCompareOnTargetPayloadCarriesAllSixFields() {
        // The painted rect fully covers the target -- an on-target highlight.
        let painted = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 10, y: 10, width: 50, height: 50)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        let payload = comparison.payload

        XCTAssertEqual(payload["verdict"] as? String, "on_target")
        XCTAssertEqual(payload["containsTarget"] as? Bool, true)
        XCTAssertEqual(payload["coverageOfTarget"] as? Double, 1)
        XCTAssertNotNil(payload["intersectionOverUnion"])
        XCTAssertNotNil(payload["centerDeltaX"])
        XCTAssertNotNil(payload["centerDeltaY"])
        // Exactly these six keys -- the `expect` payload adds its own
        // targetSource/targetBoundsBackingPx/paintedBoundsBackingPx/
        // evidenceLevel/correction* fields ON TOP of this dictionary, so this
        // pins that the comparison half itself contributes no surprises.
        XCTAssertEqual(Set(payload.keys), [
            "verdict", "containsTarget", "coverageOfTarget", "intersectionOverUnion", "centerDeltaX", "centerDeltaY"
        ])
    }

    /// An OFF-TARGET case, so a caller reading only `verdict` (without
    /// re-deriving coverage/IoU by hand) can tell a miss from a hit.
    func testCompareOffTargetWhenRectsDoNotOverlap() {
        let painted = CGRect(x: 0, y: 0, width: 10, height: 10)
        let target = CGRect(x: 1_000, y: 1_000, width: 10, height: 10)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertEqual(comparison.payload["verdict"] as? String, "off_target")
        XCTAssertEqual(comparison.payload["coverageOfTarget"] as? Double, 0)
    }

    // MARK: - correctedOffset with an already-backing delta (resolveExpectationVerdict's identity-scale reuse)

    /// `resolveExpectationVerdict` computes `AnnotationGeometryVerdict
    /// .compare`'s center delta in BACKING pixels (both operands to
    /// `compare` are already backing-pixel rects), then feeds that delta
    /// into `AnnotationBoundsSupport.correctedOffset` with
    /// `screenshotToBackingScale: (1, 1)` -- deliberately treating an
    /// ALREADY-backing delta as if it were a screenshot-pixel delta at scale
    /// 1, which collapses the function's first conversion step to a no-op
    /// and leaves only the anchor-adjustment division. This pins that reuse
    /// is correct: the identity-scale call must equal the same computation
    /// done by hand with no scale step at all.
    func testCorrectedOffsetWithScaleOneTreatsDeltaAsAlreadyBacking() {
        let adjustment = AnchorAdjustment(scaleX: 2, scaleY: 5, translateX: 0, translateY: 0)
        let corrected = try! XCTUnwrap(AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: 10, currentOffsetY: 20,
            deltaScreenshotX: 30, deltaScreenshotY: 40,
            screenshotToBackingScale: (x: 1, y: 1),
            adjustment: adjustment
        ))
        XCTAssertEqual(corrected.offsetX, 10 + 30 / 2.0)
        XCTAssertEqual(corrected.offsetY, 20 + 40 / 5.0)
    }
}
