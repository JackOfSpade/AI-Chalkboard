import XCTest
@testable import AIChalkboardCore

/// Coverage for the PURE decision logic behind `register_screenshot_space`
/// and `calibrate_screenshot_space`:
///   * `RegisterScreenshotSpaceSupport` -- dimension-source resolution and
///     the shared aspect/ambiguity validation both provenances go through.
///   * `CalibrateScreenshotSpaceSupport` -- argument parsing, the
///     ADDENDUM-required marker/observed_* cross-check, and the residual
///     vocabulary BOTH measured routes report through.
///   * `CalibrateFromElementsSupport` -- everything `action="elements"`
///     decides before it touches Accessibility (argument parsing, the
///     same-display rule, the solver's correspondence input, the audit
///     payload, and the wording of every rejection). Testable at all only
///     because it is pure: the live handler needs a running target
///     application, an Accessibility grant, and a real display arrangement,
///     none of which exist in this process.
///   * `ScreenshotCalibrationRegistry` -- the bounded, thread-safe session
///     store the `begin`/`resolve`/`cancel` handshake reads and writes.
///   * `ScreenshotCalibrationMarkerDrawing` / `ScreenshotCalibrationToken` --
///     the marker geometry and token generation used to paint fiducials.
///
/// What is deliberately NOT tested here: `MCPServer.handleRegisterScreenshotSpace`
/// and `MCPServer.handleCalibrateScreenshotSpace` themselves. Both draw real
/// annotations through `DrawRequest.finish` (which stores into
/// `AnnotationStore.shared`), resolve the live display list via
/// `OverlayWindowController.shared.screenSnapshot()` (a main-thread AppKit
/// hop), and toggle real capture-visible state -- none of which is safe or
/// meaningful in a headless unit test process with no display attached. This
/// mirrors `ScreenshotSpaceExpansionTests`'/`ScreenshotCalibrationTests`'s
/// own "test the pure helper, not the live handler" split for exactly the
/// same reason. Every rejection a live call can produce is instead pinned
/// here at the pure-decision layer that actually decides it.
final class ScreenshotSpaceHandlerTests: XCTestCase {
    // MARK: - Fixtures

    private func screen(id: String = "display-1", width: Int, height: Int, isMain: Bool = true) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: id, widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: isMain
        )
    }

    private func solution(widthPx: Int, heightPx: Int) -> ScreenshotCalibration.Solution {
        ScreenshotCalibration.Solution(
            widthPx: widthPx, heightPx: heightPx,
            residuals: ScreenshotCalibration.Residuals(
                originX: 0, originY: 0, horizontalPairDisagreement: 0, verticalPairDisagreement: 0,
                // A hand-built fixture, so the snap distance is zero by
                // construction: these tests exercise what the handler layer
                // does WITH a solution, never how the solver reached one.
                // ScreenshotCalibrationTests owns the snap's own behavior.
                widthSnapPx: 0, heightSnapPx: 0
            ),
            scaleToBackingPx: ScreenshotCalibration.Scale2D(x: 1, y: 1)
        )
    }

    @discardableResult
    private func assertFailure<T>(
        _ outcome: DrawOutcome<T>,
        contains expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        switch outcome {
        case .success:
            XCTFail("expected a failure containing '\(expectedSubstring)', got success", file: file, line: line)
            return ""
        case .failure(let message):
            XCTAssertTrue(message.contains(expectedSubstring), "expected \(message) to contain \(expectedSubstring)", file: file, line: line)
            return message
        }
    }

    // MARK: - RegisterScreenshotSpaceSupport.resolveDimensionSource

    func testResolveDimensionSourceRejectsPathTogetherWithWidth() {
        assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_path": "/tmp/a.png", "screenshot_width": 100]),
            contains: "mutually exclusive"
        )
    }

    func testResolveDimensionSourceRejectsPathTogetherWithHeight() {
        assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_path": "/tmp/a.png", "screenshot_height": 100]),
            contains: "mutually exclusive"
        )
    }

    func testResolveDimensionSourceRejectsNeitherSupplied() {
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource([:]),
            contains: "requires exactly one dimension source"
        )
        XCTAssertTrue(message.contains("screenshot_path"), message)
        XCTAssertTrue(message.contains("screenshot_width"), message)
        XCTAssertTrue(message.contains("calibrate_screenshot_space"), message)
    }

    func testResolveDimensionSourceRejectsWidthWithoutHeight() {
        assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_width": 1_920]),
            contains: "must be supplied together"
        )
    }

    func testResolveDimensionSourceRejectsHeightWithoutWidth() {
        assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_height": 1_080]),
            contains: "must be supplied together"
        )
    }

    func testResolveDimensionSourceRejectsNonPositiveDeclaredDimensions() {
        assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_width": 0, "screenshot_height": 1_080]),
            contains: "positive integers"
        )
    }

    func testResolveDimensionSourceRejectsEmptyPath() {
        assertFailure(
            RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_path": "   "]),
            contains: "non-empty string"
        )
    }

    func testResolveDimensionSourceAcceptsPath() {
        switch RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_path": "/tmp/shot.png"]) {
        case .success(.path(let path)): XCTAssertEqual(path, "/tmp/shot.png")
        case .success(.declared): XCTFail("expected .path, got .declared")
        case .failure(let message): XCTFail("expected success: \(message)")
        }
    }

    func testResolveDimensionSourceAcceptsDeclaredDimensions() {
        switch RegisterScreenshotSpaceSupport.resolveDimensionSource(["screenshot_width": 1_470, "screenshot_height": 956]) {
        case .success(.declared(let width, let height)):
            XCTAssertEqual(width, 1_470)
            XCTAssertEqual(height, 956)
        case .success(.path): XCTFail("expected .declared, got .path")
        case .failure(let message): XCTFail("expected success: \(message)")
        }
    }

    /// A JSON `null` on the sibling keys must not count as "supplied" --
    /// same reasoning as `ScreenshotSpaceExpansionTests`'s identical case for
    /// `screenshot_width`/`screenshot_height` alongside `screenshot_space`.
    func testResolveDimensionSourceTreatsNullAsAbsent() {
        switch RegisterScreenshotSpaceSupport.resolveDimensionSource([
            "screenshot_path": "/tmp/shot.png", "screenshot_width": NSNull(), "screenshot_height": NSNull()
        ]) {
        case .success(.path(let path)): XCTAssertEqual(path, "/tmp/shot.png")
        case .success(.declared): XCTFail("expected .path, got .declared")
        case .failure(let message): XCTFail("a null screenshot_width/height must not count as supplied: \(message)")
        }
    }

    // MARK: - RegisterScreenshotSpaceSupport.validateAgainstDisplay

    func testValidateAgainstDisplayAcceptsAnExactNativeCapture() {
        let display = screen(width: 3_840, height: 2_160)
        switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
            widthPx: 3_840, heightPx: 2_160, screen: display, candidateScreens: [display], screenIsDetermined: false
        ) {
        case .success: break
        case .failure(let message): XCTFail("an exact native capture must be accepted: \(message)")
        }
    }

    func testValidateAgainstDisplayRejectsAspectMismatchAndNamesFittingDisplays() {
        let target = screen(id: "display-1", width: 1_920, height: 1_080)
        let sibling = screen(id: "display-2", width: 1_000, height: 2_000)
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: 1_000, heightPx: 2_000, screen: target, candidateScreens: [target, sibling], screenIsDetermined: true
            ),
            contains: "does not map onto display display-1"
        )
        XCTAssertTrue(message.contains("display-2"), message)
    }

    func testValidateAgainstDisplayRejectsAmbiguousDefaultedDisplay() {
        // Two identical 1920x1080 displays; screen_id was NOT supplied
        // (screenIsDetermined: false), so a 1920x1080 image cannot say which
        // one it is a picture of.
        let main = screen(id: "display-1", width: 1_920, height: 1_080)
        let secondary = screen(id: "display-2", width: 1_920, height: 1_080)
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: 1_920, heightPx: 1_080, screen: main, candidateScreens: [main, secondary], screenIsDetermined: false
            ),
            contains: "matches 2 connected displays"
        )
        XCTAssertTrue(message.contains("display-1"), message)
        XCTAssertTrue(message.contains("display-2"), message)
    }

    /// The identical dimensions are NOT ambiguous once `screen_id` was
    /// explicitly supplied -- an explicit id is already the caller's own
    /// answer to "which display".
    func testValidateAgainstDisplayAcceptsAmbiguousDimensionsWhenScreenIdWasExplicit() {
        let main = screen(id: "display-1", width: 1_920, height: 1_080)
        let secondary = screen(id: "display-2", width: 1_920, height: 1_080)
        switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
            widthPx: 1_920, heightPx: 1_080, screen: main, candidateScreens: [main, secondary], screenIsDetermined: true
        ) {
        case .success: break
        case .failure(let message): XCTFail("an explicit screen_id must not be second-guessed by sibling ambiguity: \(message)")
        }
    }

    // MARK: - CalibrateScreenshotSpaceSupport.parseAction

    func testParseActionRejectsMissing() {
        assertFailure(CalibrateScreenshotSpaceSupport.parseAction([:]), contains: "Missing required parameter: action")
    }

    func testParseActionRejectsUnknownValue() {
        assertFailure(CalibrateScreenshotSpaceSupport.parseAction(["action": "finish"]), contains: "must be one of")
    }

    func testParseActionAcceptsAllThreeValuesCaseInsensitively() {
        for (raw, expected) in [("begin", "begin"), ("RESOLVE", "resolve"), ("Cancel", "cancel")] {
            switch CalibrateScreenshotSpaceSupport.parseAction(["action": raw]) {
            case .success(let value): XCTAssertEqual(value, expected)
            case .failure(let message): XCTFail("'\(raw)' should be accepted: \(message)")
            }
        }
    }

    // MARK: - CalibrateScreenshotSpaceSupport.parseMarkerObservations

    func testParseMarkerObservationsReturnsNilWhenAbsent() {
        switch CalibrateScreenshotSpaceSupport.parseMarkerObservations([:]) {
        case .success(let value): XCTAssertNil(value)
        case .failure(let message): XCTFail("absent markers must not be rejected: \(message)")
        }
    }

    func testParseMarkerObservationsRejectsNonArray() {
        assertFailure(CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": "nope"]), contains: "must be an array")
    }

    func testParseMarkerObservationsRejectsEmptyArray() {
        assertFailure(CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": []]), contains: "must not be empty")
    }

    func testParseMarkerObservationsRejectsMissingLabel() {
        assertFailure(
            CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": [["x": 1, "y": 2]]]),
            contains: "non-empty string label"
        )
    }

    func testParseMarkerObservationsRejectsNonNumericCoordinate() {
        assertFailure(
            CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": [["label": "TL", "x": "left", "y": 2]]]),
            contains: "finite numeric x and y"
        )
    }

    func testParseMarkerObservationsParsesAllFour() {
        let raw: [[String: Any]] = [
            ["label": "TL", "x": 10, "y": 20],
            ["label": "TR", "x": 90, "y": 20],
            ["label": "BL", "x": 10, "y": 80],
            ["label": "BR", "x": 90, "y": 80]
        ]
        switch CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": raw]) {
        case .success(let observations):
            XCTAssertEqual(observations?.count, 4)
            XCTAssertEqual(observations?.first(where: { $0.label == "BR" }), ScreenshotCalibration.Observation(label: "BR", x: 90, y: 80))
        case .failure(let message): XCTFail("a well-formed markers array must parse: \(message)")
        }
    }

    // MARK: - CalibrateScreenshotSpaceSupport.parseObservedDimensions

    func testParseObservedDimensionsReturnsNilWhenAbsent() {
        switch CalibrateScreenshotSpaceSupport.parseObservedDimensions([:]) {
        case .success(let value): XCTAssertNil(value)
        case .failure(let message): XCTFail("absent observed_* must not be rejected: \(message)")
        }
    }

    func testParseObservedDimensionsRejectsWidthWithoutHeight() {
        assertFailure(
            CalibrateScreenshotSpaceSupport.parseObservedDimensions(["observed_width": 1_920]),
            contains: "must be supplied together"
        )
    }

    func testParseObservedDimensionsRejectsNonPositive() {
        assertFailure(
            CalibrateScreenshotSpaceSupport.parseObservedDimensions(["observed_width": 1_920, "observed_height": 0]),
            contains: "positive integers"
        )
    }

    func testParseObservedDimensionsAcceptsAPair() {
        switch CalibrateScreenshotSpaceSupport.parseObservedDimensions(["observed_width": 1_920, "observed_height": 1_080]) {
        case .success(let value):
            XCTAssertEqual(value?.width, 1_920)
            XCTAssertEqual(value?.height, 1_080)
        case .failure(let message): XCTFail("a well-formed pair must parse: \(message)")
        }
    }

    // MARK: - CalibrateFromElementsSupport.disambiguatedName

    /// Pins a wart found by driving this route against a live Finder window:
    /// distinct elements routinely share one accessible label (Finder answers
    /// to "Desktop" five times over -- a window, a radio button, three static
    /// texts), so a solver rejection naming two of them printed the SAME text
    /// twice: "the two elements furthest apart horizontally -- 'Desktop' and
    /// 'Desktop' -- are only 13.5 backing px apart". That reads as a bug in
    /// the tool rather than the actionable "you picked two elements sitting
    /// almost on top of each other" it actually is.
    func testTwoElementsSharingALabelDoNotPrintIdenticallyInARejection() {
        let first = CalibrateFromElementsSupport.ElementSpec(
            label: "Desktop", role: nil, matchMode: .exact, occurrence: 2,
            observation: .centre(x: 594, y: 604))
        let second = CalibrateFromElementsSupport.ElementSpec(
            label: "Desktop", role: nil, matchMode: .exact, occurrence: 4,
            observation: .centre(x: 600.75, y: 897))
        let firstName = CalibrateFromElementsSupport.disambiguatedName(of: first)
        let secondName = CalibrateFromElementsSupport.disambiguatedName(of: second)
        XCTAssertNotEqual(firstName, secondName,
                          "two different elements sharing a label must be distinguishable in rejection prose")
        XCTAssertTrue(firstName.contains("occurrence 2"), firstName)
        XCTAssertTrue(secondName.contains("occurrence 4"), secondName)
    }

    /// An element identified without an occurrence has nothing to disambiguate
    /// against, so it must print as the caller's bare label -- adding a
    /// suffix the caller never supplied would name the element in words it
    /// cannot find in its own request.
    func testAnElementWithNoOccurrencePrintsAsTheCallersBareLabel() {
        let spec = CalibrateFromElementsSupport.ElementSpec(
            label: "Sidebar", role: nil, matchMode: .exact, occurrence: nil,
            observation: .centre(x: 10, y: 20))
        XCTAssertEqual(CalibrateFromElementsSupport.disambiguatedName(of: spec), "Sidebar")
    }

    // MARK: - RegisterScreenshotSpaceSupport.declaredProvenanceCaveat

    /// Field testing against a screen-control tool that returns screenshots as
    /// inline image data found a combination where every stronger route is
    /// closed at once: no file for screenshot_path to measure, and fiducials
    /// that never appear in that tool's captures. A caller there is back to a
    /// bare assertion and deserves to be told so at the moment the space is
    /// minted, rather than reading `provenance` as a grade.
    func testADeclaredSpaceSaysPlainlyThatItsDimensionsAreAnAssertion() {
        let display = screen(width: 3_840, height: 2_160)
        let caveat = RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .declared, widthPx: 1_920, heightPx: 1_080, screen: display)
        XCTAssertNotNil(caveat, "a declared space must carry a caveat")
        XCTAssertTrue(caveat!.contains("ASSERTION"), caveat!)
        XCTAssertTrue(caveat!.contains("screenshot_path"), "the caveat must name the measured upgrade route")
        XCTAssertTrue(caveat!.contains("calibrate_screenshot_space"), "the caveat must name the observed upgrade route")
    }

    /// Evidence-backed provenances must NOT be hedged -- a caveat on every
    /// space would train a reader to skip it, blunting the one case that
    /// matters.
    func testMeasuredAndObservedSpacesCarryNoCaveat() {
        let display = screen(width: 3_840, height: 2_160)
        XCTAssertNil(RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .measured, widthPx: 1_920, heightPx: 1_080, screen: display))
        XCTAssertNil(RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .observed, widthPx: 1_920, heightPx: 1_080, screen: display))
    }

    /// Pins the single most dangerous declaration: the display's EXACT
    /// backing size. It is what a correct native capture looks like AND what
    /// a downsampled image looks like when its true size is unknown and the
    /// native size is declared instead -- self-consistent, passing both the
    /// aspect and no-upscale guards, and misplacing every coordinate by a
    /// constant factor. It cannot be rejected, only flagged.
    func testDeclaringTheDisplaysExactBackingSizeGetsTheExtraDownsampleWarning() {
        let display = screen(width: 2_940, height: 1_912)
        let caveat = RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .declared, widthPx: 2_940, heightPx: 1_912, screen: display)
        XCTAssertNotNil(caveat)
        XCTAssertTrue(caveat!.contains("EXACT backing size"), caveat!)
        XCTAssertTrue(caveat!.contains("constant fraction"),
                      "the warning must name the actual consequence, not just flag the coincidence")
    }

    /// A half-scale declaration is not the NATIVE-size mistake, so it must not
    /// borrow that wording -- but it is still a tidy ratio of the display, so
    /// it must carry the clean-fraction warning instead.
    func testAHalfScaleDeclarationGetsTheFractionWarningNotTheNativeSizeOne() {
        let display = screen(width: 2_940, height: 1_912)
        let caveat = RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .declared, widthPx: 1_470, heightPx: 956, screen: display)
        XCTAssertNotNil(caveat)
        XCTAssertFalse(caveat!.contains("EXACT backing size"),
                       "a half-scale declaration is not the native-size mistake and must not be flagged as it")
        XCTAssertTrue(caveat!.contains("exactly 1/2 of display"), caveat!)
    }

    /// Pins the real failure this heuristic was widened for, reported from a
    /// live session. A 1512x982 space was declared on a 3024x1964 display --
    /// exactly one half -- while the image was really 1372x891. A uniform
    /// fraction of a matching aspect ratio passes BOTH the aspect guard and the
    /// no-upscale guard, so every coordinate landed 10.2% out for an entire
    /// session with every call reporting success.
    ///
    /// The first version of this caveat flagged only a declaration equal to the
    /// display's EXACT native size, so it would have said nothing here. The
    /// dangerous value is not "native", it is any tidy fraction of native.
    func testTheReportedHalfOfNativeFieldFailureIsFlagged() {
        let display = screen(width: 3_024, height: 1_964)
        let caveat = RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .declared, widthPx: 1_512, heightPx: 982, screen: display)
        XCTAssertNotNil(caveat, "the exact reported field failure must be flagged")
        XCTAssertTrue(caveat!.contains("exactly 1/2 of display"), caveat!)
    }

    /// The true size from that same session. A cap-derived downsample lands on
    /// an arbitrary number, which is precisely what a MEASURED size looks like
    /// -- flagging it would be noise on a correct declaration, and noise here
    /// trains a reader to skip the one case that matters.
    func testACapDerivedDownsampleIsNotFlagged() {
        let display = screen(width: 3_024, height: 1_964)
        let caveat = RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: .declared, widthPx: 1_372, heightPx: 891, screen: display)
        XCTAssertNotNil(caveat, "every declared space still carries the assertion caveat")
        XCTAssertFalse(caveat!.contains("exactly"),
                       "1372x891 is not a tidy ratio of 3024x1964 and must not be flagged as one")
    }

    /// Both axes must agree on the SAME fraction; a coincidence on one axis
    /// alone is not evidence of a guessed ratio.
    func testAFractionMatchingOnlyOneAxisIsNotFlagged() {
        let display = screen(width: 3_024, height: 1_964)
        XCTAssertNil(RegisterScreenshotSpaceSupport.cleanFractionOfDisplay(
            widthPx: 1_512, heightPx: 891, screen: display),
            "half the width but an arbitrary height is not a uniform tidy ratio")
    }

    /// The table's other entries, so a future edit that drops one is caught.
    func testTheRecognisedFractionTable() {
        let display = screen(width: 1_200, height: 800)
        func fraction(_ w: Int, _ h: Int) -> String? {
            guard let f = RegisterScreenshotSpaceSupport.cleanFractionOfDisplay(
                widthPx: w, heightPx: h, screen: display) else { return nil }
            return "\(f.numerator)/\(f.denominator)"
        }
        XCTAssertEqual(fraction(1_200, 800), "1/1")
        XCTAssertEqual(fraction(600, 400), "1/2")
        XCTAssertEqual(fraction(400, 267), "1/3")
        XCTAssertEqual(fraction(800, 533), "2/3")
        XCTAssertEqual(fraction(300, 200), "1/4")
        XCTAssertEqual(fraction(900, 600), "3/4")
        XCTAssertNil(fraction(977, 651), "an arbitrary cap-derived size must not match any entry")
    }

    // MARK: - CalibrateScreenshotSpaceSupport.displayRounded

    /// Pins the defect this helper exists for: every residual is the
    /// difference of two floating-point sums, so a PERFECT marker reading
    /// does not produce 0.0 -- it produces something like 2.84e-14. The
    /// `residuals` object exists so an agent can answer "how good was my
    /// measurement", and scientific notation for what is exactly zero forces
    /// it to work that out for itself.
    func testAPerfectReadingsFloatingPointNoiseIsReportedAsAPlainZero() {
        XCTAssertEqual(
            CalibrateScreenshotSpaceSupport.displayRounded(2.8421709430404007e-14), 0,
            "Floating-point noise from a perfect reading must reach the wire as 0, not as scientific notation."
        )
        XCTAssertEqual(
            CalibrateScreenshotSpaceSupport.displayRounded(-2.27e-13), 0,
            "Negative floating-point noise must also collapse to a plain zero."
        )
    }

    /// A real, actionable residual must survive rounding intact: this helper
    /// is presentation only, and must never quietly erase a measurement the
    /// caller should act on.
    func testAMeaningfulResidualSurvivesRoundingIntact() {
        XCTAssertEqual(CalibrateScreenshotSpaceSupport.displayRounded(0.625), 0.625,
                       "A real sub-pixel snap distance must be reported unchanged.")
        XCTAssertEqual(CalibrateScreenshotSpaceSupport.displayRounded(-3.75), -3.75,
                       "A real multi-pixel residual must keep its sign and magnitude.")
        XCTAssertEqual(CalibrateScreenshotSpaceSupport.displayRounded(12.3456), 12.346,
                       "Rounding is to three decimals -- far below what an eyeballed pixel reading resolves.")
    }

    /// `-0.0` encodes as `-0` in JSON, which reads as a signed quantity when
    /// it is nothing of the sort.
    func testNegativeZeroIsNormalizedToPlainZero() {
        let rounded = CalibrateScreenshotSpaceSupport.displayRounded(-0.0)
        XCTAssertEqual(rounded, 0, "Negative zero must normalize to a plain zero.")
        XCTAssertFalse(rounded.sign == .minus, "The normalized value must not retain a negative sign bit.")
    }

    /// A non-finite value must never reach JSONSerialization, which cannot
    /// encode it and would fail the WHOLE response rather than this one field.
    func testNonFiniteResidualsAreNeutralizedRatherThanReachingJSONEncoding() {
        XCTAssertEqual(CalibrateScreenshotSpaceSupport.displayRounded(.nan), 0,
                       "NaN must not reach JSONSerialization.")
        XCTAssertEqual(CalibrateScreenshotSpaceSupport.displayRounded(.infinity), 0,
                       "Infinity must not reach JSONSerialization.")
    }

    // MARK: - CalibrateScreenshotSpaceSupport.reconcile (the ADDENDUM cross-check)

    func testReconcileRejectsWhenNeitherSourceIsSupplied() {
        assertFailure(
            CalibrateScreenshotSpaceSupport.reconcile(solved: nil, declaredObserved: nil),
            contains: "requires either markers"
        )
    }

    func testReconcileWithObservedAloneRegistersDeclaredProvenance() {
        switch CalibrateScreenshotSpaceSupport.reconcile(solved: nil, declaredObserved: (width: 1_920, height: 1_080)) {
        case .success(let value):
            XCTAssertEqual(value.width, 1_920)
            XCTAssertEqual(value.height, 1_080)
            XCTAssertEqual(value.provenance, .declared)
            XCTAssertNil(value.crossCheckNote)
        case .failure(let message): XCTFail("observed_* alone must succeed as .declared: \(message)")
        }
    }

    func testReconcileWithMarkersAloneRegistersObservedProvenance() {
        switch CalibrateScreenshotSpaceSupport.reconcile(solved: solution(widthPx: 3_840, heightPx: 2_160), declaredObserved: nil) {
        case .success(let value):
            XCTAssertEqual(value.width, 3_840)
            XCTAssertEqual(value.height, 2_160)
            XCTAssertEqual(value.provenance, .observed)
            XCTAssertNil(value.crossCheckNote)
        case .failure(let message): XCTFail("markers alone must succeed as .observed: \(message)")
        }
    }

    /// THE ADDENDUM SCENARIO: markers solve to the DISPLAY's full size
    /// (1000x1000) because a top-left-anchored, aspect-preserving crop is
    /// invisible to marker spacing alone, but the caller's OWN
    /// observed_width/observed_height (950x950, from some independent source)
    /// disagrees far outside tolerance. This must be REJECTED, naming both
    /// numbers -- exactly PHASE_B_SPEC.md's worked example.
    func testReconcileRejectsWhenMarkersAndObservedDisagreeBeyondTolerance() {
        let message = assertFailure(
            CalibrateScreenshotSpaceSupport.reconcile(
                solved: solution(widthPx: 1_000, heightPx: 1_000),
                declaredObserved: (width: 950, height: 950)
            ),
            contains: "cross-check FAILED"
        )
        XCTAssertTrue(message.contains("1000x1000"), message)
        XCTAssertTrue(message.contains("950x950"), message)
        XCTAssertTrue(message.contains("register_screenshot_space"), message)
    }

    func testReconcileAcceptsWhenMarkersAndObservedAgreeWithinTolerance() {
        switch CalibrateScreenshotSpaceSupport.reconcile(
            solved: solution(widthPx: 3_840, heightPx: 2_160),
            declaredObserved: (width: 3_840, height: 2_160)
        ) {
        case .success(let value):
            XCTAssertEqual(value.width, 3_840)
            XCTAssertEqual(value.height, 2_160)
            XCTAssertEqual(value.provenance, .observed)
            XCTAssertNotNil(value.crossCheckNote)
            XCTAssertTrue(value.crossCheckNote?.contains("cross-check passed") ?? false)
        case .failure(let message): XCTFail("an exact agreement must succeed: \(message)")
        }
    }

    func testReconcileAcceptsSmallJitterWithinFloorTolerance() {
        // Tolerance floor is 4px; a 2px gap on each axis must pass.
        switch CalibrateScreenshotSpaceSupport.reconcile(
            solved: solution(widthPx: 1_000, heightPx: 1_000),
            declaredObserved: (width: 998, height: 1_002)
        ) {
        case .success(let value): XCTAssertEqual(value.provenance, .observed)
        case .failure(let message): XCTFail("a 2px jitter must be within the tolerance floor: \(message)")
        }
    }

    // MARK: - ScreenshotCalibrationMarkerDrawing

    func testBackingCenterScalesNormalizedPositionByScreenSize() {
        let display = screen(width: 4_000, height: 2_000)
        let marker = ScreenshotCalibration.Marker(label: "TL", normalizedX: 0.1, normalizedY: 0.25)
        let center = ScreenshotCalibrationMarkerDrawing.backingCenter(of: marker, on: display)
        XCTAssertEqual(center.x, 400, accuracy: 1e-9)
        XCTAssertEqual(center.y, 500, accuracy: 1e-9)
    }

    /// The path must contain a closed circle subpath (from the shared
    /// `ellipsePathData` helper) PLUS two open line subpaths for the
    /// crosshair -- three `M` moves, one `Z` close.
    func testMarkerPathDataContainsACircleAndACrosshair() {
        let path = ScreenshotCalibrationMarkerDrawing.markerPathData(center: (x: 100, y: 200))
        XCTAssertEqual(path.filter { $0 == "M" }.count, 3, path)
        XCTAssertEqual(path.filter { $0 == "Z" }.count, 1, path)
        XCTAssertTrue(path.contains("A "), "expected an elliptical arc command: \(path)")
        XCTAssertTrue(path.contains("L "), "expected line commands for the crosshair: \(path)")
    }

    func testLabelPositionOffsetsUpAndRightOfCenter() {
        let position = ScreenshotCalibrationMarkerDrawing.labelPosition(center: (x: 100, y: 200))
        XCTAssertGreaterThan(position.x, 100)
        XCTAssertLessThan(position.y, 200)
    }

    // MARK: - ScreenshotCalibrationToken

    func testRandomTokenHasExpectedLengthAndExcludesAmbiguousCharacters() {
        for _ in 0..<50 {
            let token = ScreenshotCalibrationToken.random()
            XCTAssertEqual(token.count, 6, token)
            for character in token {
                XCTAssertFalse("01OI".contains(character), "token '\(token)' contains an ambiguous character '\(character)'")
            }
        }
    }

    // MARK: - ScreenshotCalibrationRegistry

    func testRegistryRegisterThenLookupRoundTrips() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-fixed" })
        let session = registry.register(screenId: "display-1", token: "ABC123", annotationIds: ["a1", "a2"], previousCaptureVisible: false, forcedCaptureVisible: true)
        XCTAssertEqual(session.id, "calibration-fixed")
        let found = registry.lookup(id: "calibration-fixed")
        XCTAssertEqual(found?.screenId, "display-1")
        XCTAssertEqual(found?.token, "ABC123")
        XCTAssertEqual(found?.annotationIds, ["a1", "a2"])
        XCTAssertEqual(found?.previousCaptureVisible, false)
    }

    func testRegistryLookupOfUnknownIdReturnsNil() {
        let registry = ScreenshotCalibrationRegistry()
        XCTAssertNil(registry.lookup(id: "calibration-does-not-exist"))
    }

    func testRegistryRemoveConsumesTheSessionExactlyOnce() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-fixed" })
        registry.register(screenId: "display-1", token: "ABC123", annotationIds: [], previousCaptureVisible: true, forcedCaptureVisible: true)
        let removed = registry.remove(id: "calibration-fixed")
        XCTAssertNotNil(removed)
        XCTAssertNil(registry.lookup(id: "calibration-fixed"), "a removed session must no longer be lookup-able")
        XCTAssertNil(registry.remove(id: "calibration-fixed"), "removing an already-removed session must return nil, not re-remove")
    }

    func testRegistryExistingSessionForScreenIdFindsTheOutstandingOne() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-fixed" })
        XCTAssertNil(registry.existingSession(forScreenId: "display-1"))
        registry.register(screenId: "display-1", token: "ABC123", annotationIds: [], previousCaptureVisible: true, forcedCaptureVisible: true)
        XCTAssertEqual(registry.existingSession(forScreenId: "display-1")?.id, "calibration-fixed")
        XCTAssertNil(registry.existingSession(forScreenId: "display-2"), "a session for a different display must not match")
    }

    /// Bounded eviction: registering past `maxEntries` drops the
    /// OLDEST-registered session, mirroring `ScreenshotSpaceRegistry`'s
    /// identical FIFO-by-insertion-order eviction rule.
    func testRegistryEvictsOldestSessionPastMaxEntries() {
        var counter = 0
        let registry = ScreenshotCalibrationRegistry(idGenerator: {
            counter += 1
            return "calibration-\(counter)"
        })
        for index in 0..<(ScreenshotCalibrationRegistry.maxEntries + 1) {
            registry.register(screenId: "display-\(index)", token: "T", annotationIds: [], previousCaptureVisible: true, forcedCaptureVisible: true)
        }
        XCTAssertNil(registry.lookup(id: "calibration-1"), "the oldest session must have been evicted")
        XCTAssertNotNil(registry.lookup(id: "calibration-\(ScreenshotCalibrationRegistry.maxEntries + 1)"), "the newest session must still be present")
        XCTAssertEqual(registry.all().count, ScreenshotCalibrationRegistry.maxEntries)
    }

    /// An id generator that ALWAYS collides must not spin the registry's
    /// lock forever -- it must fail closed to a still-unique id instead.
    /// Mirrors PHASE_B_SPEC.md's ADDENDUM 2 requirement for
    /// `ScreenshotSpaceRegistry.register`'s equivalent loop.
    func testRegistryBoundedIdCollisionRetryDoesNotHang() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "always-the-same-id" })
        let first = registry.register(screenId: "display-1", token: "T", annotationIds: [], previousCaptureVisible: true, forcedCaptureVisible: true)
        XCTAssertEqual(first.id, "always-the-same-id")
        let second = registry.register(screenId: "display-2", token: "T", annotationIds: [], previousCaptureVisible: true, forcedCaptureVisible: true)
        XCTAssertNotEqual(second.id, first.id, "a colliding generator must fail closed to a distinct id, not hang or overwrite the first session")
        XCTAssertNotNil(registry.lookup(id: first.id), "the first session must remain intact")
    }

    // MARK: - Capture-debug baseline reference counting

    /// Pins the two-monitor bug an adversarial review found: capture-debug is
    /// a single PROCESS-WIDE flag, but calibrations are per-display and two
    /// can be outstanding at once. When each session saved and restored the
    /// flag independently, the save/restore pairs nested wrongly and BOTH
    /// ends broke -- the first calibration to finish turned capture-debug off
    /// underneath the second (silently breaking its handshake, since its
    /// fiducials could no longer reach the caller's screenshot), and the
    /// second then restored it ON with no calibration outstanding at all.
    func testASecondConcurrentCalibrationInheritsTheFirstsBaselineRatherThanRecordingItsForcedValue() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-\(Int.random(in: 1_000...9_999))" })

        // Display 1 begins: nothing is forcing capture-debug yet, so the real
        // pre-calibration value (false) becomes the shared baseline.
        let baseline1 = registry.claimCaptureBaseline(currentCaptureVisible: false)
        XCTAssertFalse(baseline1, "the first forcing session must record the real pre-calibration value")
        let d1 = registry.register(screenId: "display-1", token: "T1", annotationIds: ["a"],
                                   previousCaptureVisible: baseline1, forcedCaptureVisible: true)

        // Display 2 begins while display 1 is still outstanding. The live flag
        // now reads TRUE because display 1 forced it -- and that is exactly
        // the value the old code recorded as display 2's "previous".
        let baseline2 = registry.claimCaptureBaseline(currentCaptureVisible: true)
        XCTAssertFalse(baseline2, "a second concurrent calibration must inherit the saved baseline, NOT the value the first one just forced")
        let d2 = registry.register(screenId: "display-2", token: "T2", annotationIds: ["b"],
                                   previousCaptureVisible: baseline2, forcedCaptureVisible: true)

        // Display 1 resolves first. Display 2 still needs the overlay in the
        // caller's screenshot, so capture-debug must STAY on.
        _ = registry.remove(id: d1.id)
        XCTAssertNil(registry.releaseCaptureBaseline(),
                     "capture-debug must stay on while another calibration is still outstanding")

        // Display 2 resolves last and restores the ORIGINAL value.
        _ = registry.remove(id: d2.id)
        XCTAssertEqual(registry.releaseCaptureBaseline(), false,
                       "the last outstanding calibration must restore the original pre-calibration value")
    }

    /// The single-calibration case must still restore normally -- the
    /// reference counting must not turn the ordinary path into a no-op.
    func testALoneCalibrationStillRestoresTheBaselineWhenItEnds() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-lone" })
        let baseline = registry.claimCaptureBaseline(currentCaptureVisible: false)
        let session = registry.register(screenId: "display-1", token: "T", annotationIds: [],
                                        previousCaptureVisible: baseline, forcedCaptureVisible: true)
        _ = registry.remove(id: session.id)
        XCTAssertEqual(registry.releaseCaptureBaseline(), false,
                       "a lone calibration must restore the value in effect before it started")
    }

    /// A user who already had capture-debug ON must get it back ON, not have
    /// the calibration silently turn their debugging session off.
    func testABaselineOfTrueIsRestoredAsTrue() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-on" })
        let baseline = registry.claimCaptureBaseline(currentCaptureVisible: true)
        XCTAssertTrue(baseline, "an already-on capture-debug must be recorded as the baseline")
        let session = registry.register(screenId: "display-1", token: "T", annotationIds: [],
                                        previousCaptureVisible: baseline, forcedCaptureVisible: true)
        _ = registry.remove(id: session.id)
        XCTAssertEqual(registry.releaseCaptureBaseline(), true,
                       "a calibration must not turn off capture-debug the user had already enabled")
    }

    /// A `set_capture_visible=false` begin changes the flag not at all, so it
    /// must not participate in the reference count -- otherwise ending it
    /// would restore a value it never saved, clobbering whatever some other
    /// actor set during the handshake window.
    func testANonForcingCalibrationDoesNotParticipateInTheBaselineCount() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-passive" })
        let session = registry.register(screenId: "display-1", token: "T", annotationIds: [],
                                        previousCaptureVisible: true, forcedCaptureVisible: false)
        XCTAssertFalse(session.forcedCaptureVisible, "a set_capture_visible=false begin must be recorded as non-forcing")
        _ = registry.remove(id: session.id)
        XCTAssertNil(registry.releaseCaptureBaseline(),
                     "with no baseline ever claimed there is nothing to restore")
    }

    func testRegistryRemoveAllClearsEverything() {
        let registry = ScreenshotCalibrationRegistry(idGenerator: { "calibration-fixed" })
        registry.register(screenId: "display-1", token: "T", annotationIds: [], previousCaptureVisible: true, forcedCaptureVisible: true)
        registry.removeAll()
        XCTAssertTrue(registry.all().isEmpty)
        XCTAssertNil(registry.lookup(id: "calibration-fixed"))
    }

    // MARK: - validateAgainstDisplay's no-upscale guard

    /// Pins the defect where `validateAgainstDisplay` checked ONLY
    /// `fullDisplayScale` (the aspect/rounding half) against the target
    /// display and used `isPlausibleFullDisplayCapture` (the no-upscale half)
    /// solely to build the ambiguity candidate list. A 7680x4320 image on a
    /// 3840x2160 display is a perfectly uniform 2x, so the aspect guard
    /// passed; `accepting` was empty, so the ambiguity guard could not fire;
    /// and the space registered with scaleToBackingPx 0.5x0.5, silently
    /// HALVING every coordinate later drawn through it -- while this tool's
    /// own catalog description promised the dimensions must be "never larger
    /// than" the resolved display or the call is rejected.
    func testValidateAgainstDisplayRejectsAScreenshotLargerThanTheDisplayAsAnImpossibleUpscale() {
        let display = screen(width: 3_840, height: 2_160)
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: 7_680, heightPx: 4_320, screen: display, candidateScreens: [display], screenIsDetermined: true
            ),
            contains: "is LARGER than display display-1"
        )
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        XCTAssertFalse(message.contains("does not map onto display"),
                       "a uniform upscale is not an aspect mismatch and must not be described as one: \(message)")
    }

    /// The no-upscale guard must run AFTER the aspect guard, so an image that
    /// is both the wrong shape and too big still gets the SPECIFIC "does not
    /// map onto display" message rather than the coarser upscale one.
    func testAnImageThatIsBothTheWrongShapeAndTooLargeStillReportsTheAspectMismatchFirst() {
        let display = screen(width: 3_840, height: 2_160)
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: 7_680, heightPx: 7_680, screen: display, candidateScreens: [display], screenIsDetermined: true
            ),
            contains: "does not map onto display display-1"
        )
        XCTAssertFalse(message.contains("is LARGER than display"), message)
    }

    /// The no-upscale guard must name the display the image really could have
    /// come from, so a multi-monitor caller is told the one argument to add
    /// rather than left to guess.
    func testTheUpscaleRejectionNamesASiblingDisplayTheImageWouldActuallyFit() {
        let target = screen(id: "display-1", width: 1_920, height: 1_080)
        let sibling = screen(id: "display-2", width: 3_840, height: 2_160, isMain: false)
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: 3_840, heightPx: 2_160, screen: target, candidateScreens: [target, sibling], screenIsDetermined: true
            ),
            contains: "is LARGER than display display-1"
        )
        XCTAssertTrue(message.contains("display-2"), message)
        XCTAssertTrue(message.contains("pass screen_id"), message)
    }

    /// The guard must bite ONLY on upscales: a genuine downsample (a Retina
    /// screenshot saved at logical size) and an exact native capture are the
    /// two commonest legitimate registrations and must both still pass.
    func testValidateAgainstDisplayStillAcceptsAnExactDownsampleAndANativeCapture() {
        let display = screen(width: 3_840, height: 2_160)
        for (width, height) in [(3_840, 2_160), (1_920, 1_080), (1_280, 720)] {
            switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: width, heightPx: height, screen: display, candidateScreens: [display], screenIsDetermined: true
            ) {
            case .success: break
            case .failure(let message):
                XCTFail("\(width)x\(height) is a legitimate capture of 3840x2160 and must be accepted: \(message)")
            }
        }
    }

    /// `calibrate_screenshot_space action="resolve"` reuses this gate, so the
    /// caller-facing tool name must be the one that actually rejected -- an
    /// agent told "register_screenshot_space rejected:" in the response to a
    /// calibrate call would go fix arguments it never passed.
    func testTheRejectionPrefixNamesWhicheverToolIsActuallyRejecting() {
        let display = screen(width: 3_840, height: 2_160)
        let message = assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: 1_512, heightPx: 982, screen: display, candidateScreens: [display], screenIsDetermined: true,
                rejectionPrefix: "calibrate_screenshot_space action=\"resolve\" rejected:"
            ),
            contains: "calibrate_screenshot_space action=\"resolve\" rejected:"
        )
        XCTAssertFalse(message.contains("register_screenshot_space rejected:"), message)
    }

    // MARK: - resolve's declared observed_width/observed_height display gate

    /// Pins the defect where `action="resolve"` with `observed_width`/
    /// `observed_height` and NO `markers` registered a space with NO
    /// display-plausibility validation at all: `parseObservedDimensions`
    /// checks only "positive integers", `reconcile`'s (nil, .some) branch
    /// passes them straight through, and the handler called
    /// `ScreenshotSpaceRegistry.register` without ever consulting the shared
    /// gate. On a 3840x2160 display, observed 1512x982 (a CROPPED screenshot,
    /// aspect 1.54 against the display's 1.78) SUCCEEDED and handed back a
    /// non-uniform mapping that every draw_* call then refused as an "unsafe
    /// screenshot mapping" -- the same numbers `register_screenshot_space`
    /// rejected up front. This asserts the reconciled pair is what goes
    /// through the gate, and that the gate refuses it.
    func testTheDeclaredObservedDimensionsResolveUsedToRegisterUncheckedAreRefusedByTheSharedDisplayGate() {
        let display = screen(width: 3_840, height: 2_160)
        let reconciled: CalibrateScreenshotSpaceSupport.Reconciliation
        switch CalibrateScreenshotSpaceSupport.reconcile(solved: nil, declaredObserved: (width: 1_512, height: 982)) {
        case .success(let value): reconciled = value
        case .failure(let message):
            XCTFail("observed_* alone still reconciles; the display gate is what must reject it: \(message)")
            return
        }
        XCTAssertEqual(reconciled.provenance, .declared)
        assertFailure(
            RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: reconciled.width, heightPx: reconciled.height,
                screen: display, candidateScreens: [display], screenIsDetermined: true,
                rejectionPrefix: "calibrate_screenshot_space action=\"resolve\" rejected:"
            ),
            contains: "does not map onto display display-1"
        )
    }

    /// The new gate must not cost the marker route anything: a solve has
    /// already snapped to a display-consistent size, so its reconciled
    /// dimensions pass unchanged. Without this, closing the declared-only
    /// hole would have broken the handshake the tool exists for.
    func testAMarkerSolvedReconciliationStillClearsTheSharedDisplayGateUnchanged() {
        let display = screen(width: 3_840, height: 2_160)
        switch CalibrateScreenshotSpaceSupport.reconcile(solved: solution(widthPx: 1_920, heightPx: 1_080), declaredObserved: nil) {
        case .failure(let message):
            XCTFail("a marker solve must reconcile: \(message)")
        case .success(let reconciled):
            XCTAssertEqual(reconciled.provenance, .observed)
            switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
                widthPx: reconciled.width, heightPx: reconciled.height,
                screen: display, candidateScreens: [display], screenIsDetermined: true,
                rejectionPrefix: "calibrate_screenshot_space action=\"resolve\" rejected:"
            ) {
            case .success: break
            case .failure(let message):
                XCTFail("a display-consistent marker solve must still pass the gate: \(message)")
            }
        }
    }

    // MARK: - resolve's "every rejection cleans up" wording

    /// Pins the defect where resolve's ARGUMENT-SHAPE rejections returned
    /// before any `clearCalibrationSession`, contradicting the catalog's and
    /// README's explicit promise that every resolve -- including a rejected
    /// one -- clears the fiducials and releases capture-visible. The failing
    /// payload is the commonest form: x/y arriving as JSON strings. Every
    /// post-lookup rejection now composes its message through
    /// `resolveRejectionMessage`, which states the cleanup that the handler's
    /// `rejectAndClear` has just performed.
    ///
    /// The payload is a marker centre carrying its unit -- `x: "120px"`.
    /// NOTE that a BARE numeric string (`x: "120"`) is deliberately NOT a
    /// rejection: `MCPArgument.double` coerces it, so the plain
    /// "JSON-stringified numbers" case never reached this branch at all.
    func testAMalformedMarkerCoordinateIsRejectedWithAMessageStatingTheFiducialsWereCleared() {
        switch CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": [["label": "TL", "x": "120", "y": "80"]]]) {
        case .success(let observations):
            XCTAssertEqual(observations?.first?.x, 120, "a bare numeric string is coerced, not rejected")
        case .failure(let message):
            XCTFail("MCPArgument.double coerces bare numeric strings; this must not be a rejection: \(message)")
        }
        let parseFailure = assertFailure(
            CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": [["label": "TL", "x": "120px", "y": "80"]]]),
            contains: "requires finite numeric x and y fields"
        )
        let message = CalibrateScreenshotSpaceSupport.resolveRejectionMessage(
            parseFailure, calibrationId: "cal-x",
            captureOutcome: MCPServer.CalibrationCaptureCleanup.restored(false).sentence
        )
        XCTAssertTrue(message.hasPrefix(parseFailure), "the specific parse complaint must survive verbatim: \(message)")
        XCTAssertTrue(message.contains("The fiducials for calibration 'cal-x' have been cleared"), message)
        XCTAssertTrue(message.contains("capture-visible was restored to false"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        XCTAssertTrue(message.contains("action=\"begin\""), message)
    }

    /// The same promise must hold for the OTHER argument-shape rejection that
    /// used to return bare: `observed_width` supplied without
    /// `observed_height`.
    func testObservedWidthWithoutObservedHeightIsRejectedWithTheSameCleanupPromise() {
        let parseFailure = assertFailure(
            CalibrateScreenshotSpaceSupport.parseObservedDimensions(["observed_width": 1_920]),
            contains: "must be supplied together"
        )
        let message = CalibrateScreenshotSpaceSupport.resolveRejectionMessage(
            parseFailure, calibrationId: "cal-y",
            captureOutcome: MCPServer.CalibrationCaptureCleanup.untouched.sentence
        )
        XCTAssertTrue(message.contains("The fiducials for calibration 'cal-y' have been cleared"), message)
        XCTAssertTrue(message.contains("capture-visible was not changed"), message)
    }

    /// The rejection wording must report what ACTUALLY happened to the
    /// process-wide capture-debug flag, never a hardcoded "restored to X":
    /// with a second calibration still outstanding the flag is deliberately
    /// left ON, and claiming a restore that did not happen sends an agent
    /// debugging a stuck orange menu-bar icon looking in the wrong place.
    func testTheRejectionWordingReportsTheRealCaptureVisibleOutcomeRatherThanAFixedRestoredClaim() {
        let shapeFailure = assertFailure(
            CalibrateScreenshotSpaceSupport.parseMarkerObservations(["markers": ["TL": ["x": 120, "y": 80]]]),
            contains: "markers must be an array"
        )
        let message = CalibrateScreenshotSpaceSupport.resolveRejectionMessage(
            shapeFailure,
            calibrationId: "cal-z",
            captureOutcome: MCPServer.CalibrationCaptureCleanup.heldForOtherCalibration.sentence
        )
        XCTAssertTrue(message.contains("deliberately LEFT ON"), message)
        XCTAssertFalse(message.contains("restored to"),
                       "no rejection may assert a capture-visible restore that did not happen: \(message)")
    }

    // MARK: - CalibrateFromElementsSupport fixtures

    /// One fully-parsed element request, so each test below varies only the
    /// one field it is actually about.
    private func spec(
        label: String,
        role: String? = nil,
        matchMode: AccessibilityLabelMatchMode = .exact,
        occurrence: Int? = nil,
        observation: CalibrateFromElementsSupport.Observation
    ) -> CalibrateFromElementsSupport.ElementSpec {
        CalibrateFromElementsSupport.ElementSpec(
            label: label, role: role, matchMode: matchMode, occurrence: occurrence,
            observation: observation
        )
    }

    /// One element that has already resolved through Accessibility, built by
    /// hand so the same-display rule and the payload shaping can be pinned
    /// with no live display, no Accessibility grant, and no target app.
    private func resolvedElement(
        label: String,
        matchedLabel: String? = nil,
        role: String? = nil,
        screenId: String = "display-1",
        x: Double, y: Double, width: Double, height: Double,
        observedX: Double, observedY: Double
    ) -> CalibrateFromElementsSupport.ResolvedElement {
        resolvedElement(
            label: label, matchedLabel: matchedLabel, role: role, screenId: screenId,
            x: x, y: y, width: width, height: height,
            observation: .centre(x: observedX, y: observedY)
        )
    }

    /// The same fixture for an element observed by its BOUNDING BOX, which is
    /// the form that yields TWO correspondences from one resolved rect.
    private func resolvedElement(
        label: String,
        matchedLabel: String? = nil,
        role: String? = nil,
        occurrence: Int? = nil,
        screenId: String = "display-1",
        x: Double, y: Double, width: Double, height: Double,
        observation: CalibrateFromElementsSupport.Observation
    ) -> CalibrateFromElementsSupport.ResolvedElement {
        CalibrateFromElementsSupport.ResolvedElement(
            spec: spec(label: label, role: role, occurrence: occurrence, observation: observation),
            matchedLabel: matchedLabel ?? label,
            resolvedRole: role,
            frame: AccessibilityBackingRect(screenId: screenId, x: x, y: y, width: width, height: height)
        )
    }

    private func elementArguments(
        app: String = "com.example.Target",
        elements: [[String: Any]],
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var args: [String: Any] = ["action": "elements", "app": app, "elements": elements]
        for (key, value) in extra { args[key] = value }
        return args
    }

    /// The same builder for the cases that need a HETEROGENEOUS `elements`
    /// array -- a non-object entry, say. It cannot share the typed helper
    /// above because `[[String: Any]]` cannot hold a bare string, and that is
    /// precisely the shape `parse` has to reject.
    private func elementArgumentsRaw(
        app: String = "com.example.Target",
        elements: [Any],
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var args: [String: Any] = ["action": "elements", "app": app, "elements": elements]
        for (key, value) in extra { args[key] = value }
        return args
    }

    // MARK: - parseAction with the fourth action

    /// The element route is a fourth ACTION on `calibrate_screenshot_space`,
    /// not a separate tool, so `parseAction` has to admit it -- and has to go
    /// on rejecting everything else, since a typo silently accepted here
    /// would fall through to a dispatch switch that cannot serve it.
    func testParseActionAcceptsElementsAlongsideTheThreeHandshakeActions() {
        for raw in ["elements", "ELEMENTS", "Elements"] {
            switch CalibrateScreenshotSpaceSupport.parseAction(["action": raw]) {
            case .success(let value): XCTAssertEqual(value, "elements")
            case .failure(let message): XCTFail("'\(raw)' should be accepted: \(message)")
            }
        }
        let rejection = assertFailure(
            CalibrateScreenshotSpaceSupport.parseAction(["action": "element"]),
            contains: "must be one of"
        )
        XCTAssertTrue(rejection.contains("\"elements\""), "the rejection must name the action the caller nearly typed: \(rejection)")
    }

    // MARK: - CalibrateFromElementsSupport.parse

    /// `app` is not optional on this route the way it is on `highlight_element`
    /// (which falls back to the frontmost app): an Accessibility hierarchy
    /// belongs to one process, and a silently-defaulted target would calibrate
    /// against whatever happened to be frontmost rather than against the app
    /// the caller can see in its own screenshot.
    func testParseRequiresAppBecauseAnAccessibilityHierarchyBelongsToOneProcess() {
        assertFailure(
            CalibrateFromElementsSupport.parse(["action": "elements", "elements": []]),
            contains: "requires app"
        )
    }

    /// An empty `app` is the GLOBAL-visibility spelling every draw tool
    /// accepts, and it is meaningless here. Rejected in the PURE layer rather
    /// than left to the shared app lookup, whose own wording names
    /// `highlight_element` -- a `calibrate_screenshot_space` caller must not
    /// be told to fix a tool it never called.
    func testParseRejectsGlobalVisibilityWithWordingThatNamesThisToolNotHighlightElement() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(app: "   ", elements: [])),
            contains: "cannot target GLOBAL visibility"
        )
        XCTAssertTrue(message.contains("calibrate_screenshot_space action=\"elements\""), message)
        XCTAssertFalse(message.contains("highlight_element"), "this rejection is about the tool the caller actually called: \(message)")
        XCTAssertTrue(message.contains("Nothing was registered"), message)
    }

    /// THE DEAD END THIS MESSAGE HAS TO OPEN, and the single most important
    /// string in the bounds-fiducial change. An agent driving DaVinci Resolve
    /// inside a Shadow PC remote-desktop client found exactly ONE labelled
    /// Accessibility element in the whole application -- the window itself --
    /// and the old wording ("supply at least 2 elements, widely separated")
    /// was advice it could not follow at any effort: there is no second
    /// element to find. The route out existed the whole time and the message
    /// never mentioned it, so this test pins that it now does.
    ///
    /// Two correspondences remains the arithmetic floor -- `observed = scale *
    /// true + origin` has two unknowns per axis -- but the floor is on POINTS,
    /// and a bounding box is two of them.
    func testOneCentreObservedElementIsRejectedWithTheOneWindowBoundsRouteSpelledOut() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Shadow PC - Display", "observed_x": 10, "observed_y": 20]
            ])),
            contains: "TWO POINTS, NOT TWO ELEMENTS"
        )
        XCTAssertTrue(message.contains("'Shadow PC - Display' observed by its CENTRE"),
                      "it must name what the caller actually sent: \(message)")
        XCTAssertTrue(message.contains("two unknowns per axis"), message)
        XCTAssertTrue(message.contains("cross-checked"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        for key in CalibrateFromElementsSupport.boundsObservationKeys {
            XCTAssertTrue(message.contains(key), "the bounds route's own argument names must be spelled out: \(message)")
        }
        XCTAssertTrue(message.contains("sufficient on its own"),
                      "one bounds element being ENOUGH is the fact that unblocks the caller: \(message)")
        XCTAssertTrue(message.contains("remote-desktop"),
                      "the class of app that needs this route has to be named in matchable terms: \(message)")
        XCTAssertTrue(message.contains("content area"),
                      "the one likely misreading has to be pre-empted: \(message)")
    }

    /// An EMPTY array reaches the same gate rather than a second, thinner
    /// message of its own: a caller that sent no observations needs the same
    /// explanation of what an observation is as one that sent too few.
    func testAnEmptyElementsArrayGetsTheSameTwoPointsExplanation() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [])),
            contains: "elements is empty"
        )
        XCTAssertTrue(message.contains("TWO POINTS, NOT TWO ELEMENTS"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
    }

    /// The counterpart to the rejection above: ONE element is now a complete,
    /// accepted request as long as it was observed by its bounding box. This
    /// is the whole surface change -- `elements`' floor is one entry, and the
    /// real gate counts points.
    func testOneBoundsObservedElementIsAcceptedOnItsOwn() {
        switch CalibrateFromElementsSupport.parse(elementArguments(elements: [
            ["label": "Shadow PC - Display", "role": "AXWindow",
             "observed_left": 50, "observed_top": 25, "observed_right": 1050, "observed_bottom": 625]
        ])) {
        case .success(let request):
            XCTAssertEqual(request.elements.count, 1)
            XCTAssertEqual(request.elements[0].observation,
                           .bounds(left: 50, top: 25, right: 1050, bottom: 625))
            XCTAssertEqual(request.elements[0].observation.correspondenceCount, 2,
                           "one box is two points, which is what makes a single element sufficient")
        case .failure(let message):
            XCTFail("one bounds-observed element must be a complete calibration: \(message)")
        }
    }

    /// The ceiling is about cross-process cost, not mathematics: one full
    /// breadth-first walk of the target app's hierarchy is paid PER ELEMENT,
    /// so a ninth element is refused before any of the eight are walked.
    func testParseRejectsMoreThanEightElementsBecauseEachOneCostsItsOwnHierarchyWalk() {
        let many = (0..<9).map { ["label": "Item \($0)", "observed_x": Double($0), "observed_y": 0.0] as [String: Any] }
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: many)),
            contains: "more than the 8 this action accepts"
        )
        XCTAssertTrue(message.contains("own full breadth-first walk"), message)
    }

    /// THE REGRESSION THIS PINS: the marker route next door takes
    /// `markers: [{label, x, y}]`, so `elements: [{label, x, y}]` is the
    /// single likeliest wrong shape a caller will send. Accepting the object
    /// and then complaining that `observed_x` is missing would describe the
    /// symptom; naming the stray `x`/`y` and the rename describes the mistake.
    func testAnElementCarryingTheMarkerRoutesXAndYFieldNamesIsRejectedByName() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "x": 10, "y": 20],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20]
            ])),
            contains: "elements[0] has unrecognized field(s) x, y"
        )
        XCTAssertTrue(message.contains("observed_x/observed_y"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
    }

    /// A stray field that is NOT the x/y mix-up gets the plain wording rather
    /// than an irrelevant lecture about the marker route's names.
    func testAnUnrelatedStrayElementFieldGetsThePlainUnrecognizedFieldWording() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": 10, "observed_y": 20, "colour": "red"],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20]
            ])),
            contains: "unrecognized field(s) colour"
        )
        XCTAssertFalse(message.contains("observed_x/observed_y"), "no marker-route lecture when x/y are not involved: \(message)")
    }

    /// Every per-element rejection names the INDEX as well as the label: a
    /// caller that sent four elements and got back a bare "label must be
    /// non-empty" has no way to know which of the four to fix.
    func testEveryPerElementRejectionNamesTheIndexSoAMultiElementCallIsFixable() {
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": 10, "observed_y": 20],
                ["label": "  ", "observed_x": 900, "observed_y": 20]
            ])),
            contains: "elements[1].label must be a non-empty string"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": 10, "observed_y": 20],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20, "occurrence": 0]
            ])),
            contains: "elements[1] (label 'Cancel') has occurrence 0"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": 10, "observed_y": 20],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20, "match": "fuzzy"]
            ])),
            contains: "elements[1] (label 'Cancel') has match 'fuzzy'"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": 10, "observed_y": 20],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20, "role": "  "]
            ])),
            contains: "elements[1] (label 'Cancel') has an empty role"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArgumentsRaw(elements: [
                "not an object",
                ["label": "Cancel", "observed_x": 900, "observed_y": 20] as [String: Any]
            ])),
            contains: "elements[0] must be an object"
        )
    }

    /// An observed centre carrying its unit -- `observed_x: "120px"` -- is a
    /// rejection, while a BARE numeric string is coerced: exactly the split
    /// `MCPArgument.double` already draws for the marker route, pinned here so
    /// this route cannot drift into rejecting an ordinary JSON-stringified
    /// number.
    func testAnObservedCentreCarryingItsUnitIsRejectedWhileABareNumericStringIsCoerced() {
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": "120px", "observed_y": 20],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20]
            ])),
            contains: "requires finite numeric observed_x and observed_y fields"
        )
        switch CalibrateFromElementsSupport.parse(elementArguments(elements: [
            ["label": "Save", "observed_x": "120", "observed_y": "20"],
            ["label": "Cancel", "observed_x": 900, "observed_y": 20]
        ])) {
        case .success(let request):
            XCTAssertEqual(request.elements.first?.observation, .centre(x: 120, y: 20))
        case .failure(let message):
            XCTFail("a bare numeric string must be coerced, not rejected: \(message)")
        }
    }

    /// `screen_id` is OPTIONAL here on purpose -- the elements name their own
    /// display, which is measured evidence rather than a caller assertion --
    /// but a supplied one must still be a usable string rather than an empty
    /// placeholder a schema-driven client filled in.
    func testAnEmptyScreenIdIsRejectedRatherThanTreatedAsOmitted() {
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(
                elements: [
                    ["label": "Save", "observed_x": 10, "observed_y": 20],
                    ["label": "Cancel", "observed_x": 900, "observed_y": 20]
                ],
                extra: ["screen_id": "   "]
            )),
            contains: "screen_id must be a non-empty string when supplied"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(
                elements: [
                    ["label": "Save", "observed_x": 10, "observed_y": 20],
                    ["label": "Cancel", "observed_x": 900, "observed_y": 20]
                ],
                extra: ["screen_id": 7]
            )),
            contains: "screen_id must be a string when supplied"
        )
    }

    /// A JSON `null` for an optional argument must read as ABSENT, not as
    /// supplied-and-malformed: a schema-driven client that serializes every
    /// declared property and nulls the ones it is not using is an ordinary way
    /// to build a request, and this route's optional fields
    /// (`screen_id`, `role`, `match`, `occurrence`) all sit in that path.
    func testAJSONNullOptionalReadsAsAbsentRatherThanAsAMalformedValue() {
        switch CalibrateFromElementsSupport.parse(elementArguments(
            elements: [
                ["label": "Save", "observed_x": 10, "observed_y": 20,
                 "role": NSNull(), "match": NSNull(), "occurrence": NSNull()],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20]
            ],
            extra: ["screen_id": NSNull()]
        )) {
        case .success(let request):
            XCTAssertNil(request.screenId)
            XCTAssertNil(request.elements[0].role)
            XCTAssertNil(request.elements[0].occurrence)
            XCTAssertEqual(request.elements[0].matchMode, .exact)
        case .failure(let message):
            XCTFail("nulled optionals must read as omitted: \(message)")
        }
    }

    /// The full happy path, including the resolver vocabulary this route
    /// shares with `highlight_element` verbatim, so an agent that already
    /// knows how to disambiguate a label does not have to learn a second way.
    func testAWellFormedCallParsesEveryResolverArgumentItSharesWithHighlightElement() {
        switch CalibrateFromElementsSupport.parse(elementArguments(
            elements: [
                ["label": "Save", "role": "AXButton", "match": "contains", "occurrence": 2,
                 "observed_x": 120.5, "observed_y": 80],
                ["label": "Status", "observed_x": 900, "observed_y": 700]
            ],
            extra: ["screen_id": " display-2 ", "max_nodes": 9_000, "timeout_seconds": 7.5]
        )) {
        case .success(let request):
            XCTAssertEqual(request.app, "com.example.Target")
            XCTAssertEqual(request.screenId, "display-2")
            XCTAssertEqual(request.maxNodes, 9_000)
            XCTAssertEqual(request.timeoutSeconds, 7.5)
            XCTAssertEqual(request.elements.count, 2)
            XCTAssertEqual(request.elements[0].label, "Save")
            XCTAssertEqual(request.elements[0].role, "AXButton")
            XCTAssertEqual(request.elements[0].matchMode, .contains)
            XCTAssertEqual(request.elements[0].occurrence, 2)
            XCTAssertEqual(request.elements[0].observation, .centre(x: 120.5, y: 80))
            XCTAssertEqual(request.elements[1].matchMode, .exact, "match defaults to exact, the safe mode")
        case .failure(let message):
            XCTFail("a well-formed elements call must parse: \(message)")
        }
    }

    /// THE REGRESSION THIS PINS: the resolver's own `traversalLimitReached`
    /// and `traversalTimedOut` messages instruct the caller to raise
    /// `max_nodes` and `timeout_seconds`, and both failures are reachable
    /// here -- more easily than from `highlight_element`, because this route
    /// pays one full hierarchy walk PER ELEMENT. An action that surfaced that
    /// advice while ignoring the two arguments it names would hand back
    /// instructions the caller cannot act on.
    func testTheTraversalBudgetsTheResolversOwnErrorsTellCallersToRaiseAreAccepted() {
        let base: [[String: Any]] = [
            ["label": "Save", "observed_x": 10, "observed_y": 20],
            ["label": "Cancel", "observed_x": 900, "observed_y": 20]
        ]
        switch CalibrateFromElementsSupport.parse(elementArguments(elements: base)) {
        case .success(let request):
            XCTAssertEqual(request.maxNodes, AccessibilityElementResolver.defaultMaxNodes)
            XCTAssertEqual(request.timeoutSeconds, AccessibilityElementResolver.defaultTraversalTimeoutSeconds)
        case .failure(let message):
            XCTFail("omitted budgets must fall back to the resolver's own defaults: \(message)")
        }
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: base, extra: ["max_nodes": "lots"])),
            contains: "max_nodes must be an integer between 1 and \(AccessibilityElementResolver.absoluteMaxNodes)"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(
                elements: base, extra: ["max_nodes": AccessibilityElementResolver.absoluteMaxNodes + 1])),
            contains: "max_nodes must be between 1 and \(AccessibilityElementResolver.absoluteMaxNodes)"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: base, extra: ["timeout_seconds": "soon"])),
            contains: "timeout_seconds must be a finite number when supplied"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(
                elements: base,
                extra: ["timeout_seconds": AccessibilityElementResolver.maxTraversalTimeoutSeconds + 1])),
            contains: "timeout_seconds must be between"
        )
    }

    /// `elements` sent as a JSON OBJECT keyed by label -- a thoroughly
    /// ordinary serialization shape, and the exact mistake the marker route
    /// already had to name -- must be rejected as a shape error rather than
    /// read as an empty array.
    func testElementsSentAsAnObjectKeyedByLabelIsRejectedAsAShapeError() {
        assertFailure(
            CalibrateFromElementsSupport.parse([
                "action": "elements", "app": "com.example.Target",
                "elements": ["Save": ["observed_x": 10, "observed_y": 20]]
            ]),
            contains: "elements must be an ARRAY"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(["action": "elements", "app": "com.example.Target"]),
            contains: "requires elements"
        )
    }

    // MARK: - Bounds observations: the one-window fiducial

    /// THE MEASURED CASE THIS WHOLE FORM EXISTS FOR, end to end through the
    /// UNCHANGED solver: a 3024x1964 display, a remote-desktop window whose
    /// Accessibility frame is (100,50) 2000x1200, and a screenshot at exactly
    /// 0.5x, so the window's corners are seen at (50,25) and (1050,625). One
    /// element, two points, and the image is 1512x982 -- exactly, not nearly.
    ///
    /// Before this form existed that application had ZERO usable
    /// calibrations: it published one labelled element in total, so no pair of
    /// centres could ever be assembled at any separation.
    func testOneBoundsObservedWindowSolvesTheScreenshotSizeExactlyOnItsOwn() {
        let window = resolvedElement(
            label: "Shadow PC - Display", role: "AXWindow",
            x: 100, y: 50, width: 2_000, height: 1_200,
            observation: .bounds(left: 50, top: 25, right: 1_050, bottom: 625)
        )
        let pairs = CalibrateFromElementsSupport.correspondences([window])
        XCTAssertEqual(pairs.count, 2, "one rect is two points -- that is the entire trick")

        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: screen(width: 3_024, height: 1_964)) {
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 1_512)
            XCTAssertEqual(solution.heightPx, 982)
            XCTAssertEqual(solution.residuals.originX, 0, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originY, 0, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.x, 2, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.y, 2, accuracy: 1e-9)
        case .failure(let message):
            XCTFail("a single bounds-observed window must solve on its own: \(message)")
        }
    }

    /// A bounds element yields TWO correspondences from ONE resolved rect --
    /// its (minX,minY) against the caller's left/top, and its (maxX,maxY)
    /// against the caller's right/bottom -- and each one is NAMED for the
    /// corner it came from.
    ///
    /// WHY THE NAMES MATTER: every solver rejection quotes the two
    /// correspondences it could not reconcile. Without the suffixes a window
    /// calibrated from its own corners produces "'Shadow PC - Display' and
    /// 'Shadow PC - Display'", which reads as a bug in the tool instead of as
    /// the actionable "one of your two corners is wrong".
    func testABoundsElementYieldsBothCornersAsSeparatelyNamedCorrespondences() {
        let pairs = CalibrateFromElementsSupport.correspondences([
            resolvedElement(label: "Shadow PC - Display", occurrence: 2,
                            x: 100, y: 50, width: 2_000, height: 1_200,
                            observation: .bounds(left: 50, top: 25, right: 1_050, bottom: 625))
        ])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].name, "Shadow PC - Display (occurrence 2) top-left corner")
        XCTAssertEqual(pairs[0].trueX, 100)
        XCTAssertEqual(pairs[0].trueY, 50)
        XCTAssertEqual(pairs[0].observedX, 50)
        XCTAssertEqual(pairs[0].observedY, 25)
        XCTAssertEqual(pairs[1].name, "Shadow PC - Display (occurrence 2) bottom-right corner")
        XCTAssertEqual(pairs[1].trueX, 2_100, "maxX is x + width, the far corner of the reported rect")
        XCTAssertEqual(pairs[1].trueY, 1_250)
        XCTAssertEqual(pairs[1].observedX, 1_050)
        XCTAssertEqual(pairs[1].observedY, 625)
    }

    /// One bounds element plus one centre element is THREE correspondences,
    /// which is the first count this route can actually cross-check -- and the
    /// cheapest way for a one-window application to get a checked solve, since
    /// any second element at all will do.
    func testABoundsElementPlusACentreElementSolvesAndIsGenuinelyCrossChecked() {
        let display = screen(width: 3_024, height: 1_964)
        let window = resolvedElement(
            label: "Shadow PC - Display", x: 100, y: 50, width: 2_000, height: 1_200,
            observation: .bounds(left: 50, top: 25, right: 1_050, bottom: 625)
        )
        // Centre (450, 820) at the same 0.5x, so it sits exactly on the
        // mapping the window's two corners define.
        let status = resolvedElement(
            label: "Status", x: 400, y: 800, width: 100, height: 40,
            observedX: 225, observedY: 410
        )
        let pairs = CalibrateFromElementsSupport.correspondences([window, status])
        XCTAssertEqual(pairs.count, 3)
        XCTAssertNil(CalibrateFromElementsSupport.redundancyCaveat(correspondenceCount: pairs.count),
                     "three points ARE checkable, so no caveat")

        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 1_512)
            XCTAssertEqual(solution.heightPx, 982)
            XCTAssertEqual(solution.residuals.worstRedundancyResidualPx, 0, accuracy: 1e-9)
        case .failure(let message):
            XCTFail("a box plus a centre must solve: \(message)")
        }

        // And the third point is genuinely TESTED against the window's
        // corners rather than merely carried along: move it 30 px and the
        // redundancy check names it, and names both corners it disagreed with.
        let misread = CalibrateFromElementsSupport.correspondences([
            window,
            resolvedElement(label: "Status", x: 400, y: 800, width: 100, height: 40,
                            observedX: 225, observedY: 440)
        ])
        let message = assertFailure(
            ScreenshotCalibration.solveCorrespondences(misread, screen: display),
            contains: "Element 'Status' does not fit the vertical mapping"
        )
        XCTAssertTrue(message.contains("Shadow PC - Display top-left corner"), message)
        XCTAssertTrue(message.contains("Shadow PC - Display bottom-right corner"), message)
    }

    /// THE LIKELIEST MISREADING OF A WINDOW, and proof it does not silently
    /// mis-scale. An Accessibility window frame INCLUDES the title bar;
    /// reporting the box of the CONTENT area instead omits roughly 28 px from
    /// the top. The scale solve happily absorbs it -- the corners still span a
    /// straight line -- so nothing about the numbers looks wrong until the
    /// ORIGIN RESIDUAL is computed: 14.58 px of implied top edge against a
    /// 9.59 px tolerance for a ~959 px-tall image.
    ///
    /// Pinned to that specific check because it is the reason this form can be
    /// offered at all: the failure mode is caught rather than registered.
    func testAContentAreaMisreadingIsCaughtByTheOriginResidualRatherThanMisScaling() {
        let contentAreaInsteadOfFrame = CalibrateFromElementsSupport.correspondences([
            resolvedElement(label: "Shadow PC - Display", x: 100, y: 50, width: 2_000, height: 1_200,
                            observation: .bounds(left: 50, top: 39, right: 1_050, bottom: 625))
        ])
        let message = assertFailure(
            ScreenshotCalibration.solveCorrespondences(
                contentAreaInsteadOfFrame, screen: screen(width: 3_024, height: 1_964)),
            contains: "The implied top edge of the screenshot is"
        )
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        XCTAssertTrue(message.contains("cropped"), message)
    }

    /// The baseline gate applies to a box exactly as it applies to two
    /// separate elements, because by the time the solver sees them there is no
    /// difference: a SMALL element's two corners are two points sitting close
    /// together, and the scale solved from them multiplies every pixel of
    /// reading error by (display width / their separation).
    ///
    /// This is also why the one-window route is honest advice rather than a
    /// loophole -- it works because a remote-desktop WINDOW is large.
    func testASmallElementsTwoCornersAreStillRejectedByTheBaselineGate() {
        let message = assertFailure(
            ScreenshotCalibration.solveCorrespondences(
                CalibrateFromElementsSupport.correspondences([
                    resolvedElement(label: "Toolbar", x: 100, y: 50, width: 200, height: 100,
                                    observation: .bounds(left: 50, top: 25, right: 150, bottom: 75))
                ]),
                screen: screen(width: 3_024, height: 1_964)
            ),
            contains: "are only 200.0 backing px apart"
        )
        XCTAssertTrue(message.contains("'Toolbar top-left corner' and 'Toolbar bottom-right corner'"),
                      "the gate must say WHICH two points were too close: \(message)")
        XCTAssertTrue(message.contains("25%"), message)
    }

    // MARK: - Bounds observations: parsing and its four new rejections

    /// Observing one element BOTH ways leaves it ambiguous which reading to
    /// trust, and silently preferring one would leave the caller believing the
    /// other took effect -- the same "reject rather than reinterpret" rule
    /// `register_screenshot_space` applies to its own two dimension sources.
    func testAnElementObservedBothWaysIsRejectedNamingWhichSetToDrop() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Shadow PC - Display", "observed_x": 500, "observed_y": 300,
                 "observed_left": 50, "observed_top": 25, "observed_right": 1_050, "observed_bottom": 625]
            ])),
            contains: "is observed BOTH ways at once"
        )
        XCTAssertTrue(message.contains("elements[0] (label 'Shadow PC - Display')"), message)
        XCTAssertTrue(message.contains("observed_x and observed_y"), message)
        XCTAssertTrue(message.contains("observed_left, observed_top, observed_right, observed_bottom"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        XCTAssertTrue(message.contains("drop observed_x/observed_y"), message)
    }

    /// A stray SINGLE bounds field alongside a centre is the same ambiguity,
    /// and is reported as one rather than as a partial box: the caller has two
    /// answers on the table, and which to delete is the question worth
    /// answering first.
    func testOneStrayBoundsFieldBesideACentreReadsAsTheAmbiguityItIs() {
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "observed_x": 500, "observed_y": 300, "observed_left": 50]
            ])),
            contains: "is observed BOTH ways at once"
        )
    }

    /// Three edges do not describe a rectangle, and filling the fourth in from
    /// the element's own resolved rect would mean inventing the very
    /// measurement this calibration exists to CHECK against that rect. Each of
    /// the four omissions is named individually, because "some field is
    /// missing" is not something a caller can act on.
    func testEachPartialBoundingBoxNamesExactlyTheEdgeThatIsMissing() {
        let complete: [String: Any] = [
            "observed_left": 50, "observed_top": 25, "observed_right": 1_050, "observed_bottom": 625
        ]
        for omitted in CalibrateFromElementsSupport.boundsObservationKeys {
            var element: [String: Any] = ["label": "Canvas"]
            for (key, value) in complete where key != omitted { element[key] = value }
            let message = assertFailure(
                CalibrateFromElementsSupport.parse(elementArguments(elements: [element])),
                contains: "supplies a PARTIAL bounding box"
            )
            XCTAssertTrue(message.contains("\(omitted) is missing"),
                          "the missing edge must be named exactly: \(message)")
            for present in CalibrateFromElementsSupport.boundsObservationKeys where present != omitted {
                XCTAssertFalse(message.contains("\(present) is missing"),
                               "a supplied edge must not be reported missing: \(message)")
            }
            XCTAssertTrue(message.contains("Nothing was registered"), message)
            XCTAssertTrue(message.contains("observed_x and observed_y"),
                          "the centre form is the other way out and must be offered: \(message)")
        }
    }

    /// An element nobody observed is a label, not a fiducial: there is nothing
    /// to pair its resolved position with. The rejection names BOTH forms,
    /// with what each one is worth, rather than only the one the caller
    /// happened to be closest to.
    func testAnElementObservedNeitherWayIsRejectedNamingBothWaysToObserveIt() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Save", "role": "AXButton"],
                ["label": "Cancel", "observed_x": 900, "observed_y": 20]
            ])),
            contains: "elements[0] (label 'Save') says nothing about where it appears"
        )
        XCTAssertTrue(message.contains("observed_x and observed_y"), message)
        XCTAssertTrue(message.contains("observed_left, observed_top, observed_right, observed_bottom"), message)
        XCTAssertTrue(message.contains("one point"), message)
        XCTAssertTrue(message.contains("two"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
    }

    /// A box whose corners arrived swapped -- or identical -- is caught HERE
    /// rather than left to the solver, which would reject it in prose written
    /// for a different mistake ("the labels and the observed points were
    /// mismatched"). There are no labels to re-pair inside one element's own
    /// box, so that advice would send the caller looking in the wrong place.
    func testAnInvertedOrZeroAreaBoxIsRejectedAsSuchRatherThanAsMismatchedLabels() {
        let horizontallyInverted = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Canvas", "observed_left": 1_050, "observed_top": 25,
                 "observed_right": 50, "observed_bottom": 625]
            ])),
            contains: "zero or negative width"
        )
        XCTAssertTrue(horizontallyInverted.contains("observed_right=50.0"), horizontallyInverted)
        XCTAssertTrue(horizontallyInverted.contains("observed_left=1050.0"), horizontallyInverted)
        XCTAssertTrue(horizontallyInverted.contains("SMALLER pair"), horizontallyInverted)
        XCTAssertFalse(horizontallyInverted.contains("mismatched"),
                       "this is one element's own box, not two elements paired wrongly: \(horizontallyInverted)")

        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Canvas", "observed_left": 50, "observed_top": 625,
                 "observed_right": 1_050, "observed_bottom": 25]
            ])),
            contains: "zero or negative height"
        )

        // Zero-area is the degenerate end of the same error and is rejected by
        // the same strict comparison: a box with no extent on an axis
        // contributes no separation to that axis at all.
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Canvas", "observed_left": 50, "observed_top": 25,
                 "observed_right": 50, "observed_bottom": 625]
            ])),
            contains: "zero or negative width"
        )
        assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Canvas", "observed_left": 50, "observed_top": 25,
                 "observed_right": 1_050, "observed_bottom": 25]
            ])),
            contains: "zero or negative height"
        )
    }

    /// A bounds edge carrying its unit is rejected exactly as `observed_x:
    /// "120px"` already is, and a BARE numeric string is coerced -- the same
    /// split `MCPArgument.double` draws everywhere else, pinned here so the
    /// new form cannot drift into its own numeric rules.
    func testABoundsEdgeCarryingItsUnitIsRejectedWhileABareNumericStringIsCoerced() {
        let message = assertFailure(
            CalibrateFromElementsSupport.parse(elementArguments(elements: [
                ["label": "Canvas", "observed_left": "50px", "observed_top": 25,
                 "observed_right": 1_050, "observed_bottom": 625]
            ])),
            contains: "has observed_left that is not a finite number"
        )
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        switch CalibrateFromElementsSupport.parse(elementArguments(elements: [
            ["label": "Canvas", "observed_left": "50", "observed_top": "25",
             "observed_right": "1050", "observed_bottom": "625"]
        ])) {
        case .success(let request):
            XCTAssertEqual(request.elements[0].observation, .bounds(left: 50, top: 25, right: 1_050, bottom: 625))
        case .failure(let failure):
            XCTFail("bare numeric strings must be coerced, not rejected: \(failure)")
        }
    }

    /// The four bounds keys are RECOGNIZED fields, not stray ones: without
    /// this they would be caught by the unknown-field guard and the caller
    /// would be told to remove exactly the fields it was asked to send.
    func testTheFourBoundsKeysAreRecognizedRatherThanTreatedAsStrayFields() {
        for key in CalibrateFromElementsSupport.boundsObservationKeys {
            XCTAssertTrue(CalibrateFromElementsSupport.recognizedElementKeys.contains(key), key)
        }
        for key in CalibrateFromElementsSupport.centreObservationKeys {
            XCTAssertTrue(CalibrateFromElementsSupport.recognizedElementKeys.contains(key), key)
        }
    }

    /// The success payload has to let a caller AUDIT a bounds solve, which
    /// means showing the same two points the solver was given -- both corners,
    /// resolved and observed -- and saying WHICH form was used. A bounds
    /// element's centre is deliberately absent: no such point took part in the
    /// fit, and reporting one would invite a reader to check the wrong number.
    func testABoundsElementsPayloadReportsBothCornersAndNamesTheFormUsed() {
        let element = resolvedElement(
            label: "Shadow PC - Display", role: "AXWindow",
            x: 100, y: 50, width: 2_000, height: 1_200,
            observation: .bounds(left: 50, top: 25, right: 1_050, bottom: 625)
        )
        let pairs = CalibrateFromElementsSupport.correspondences([element])
        let entry = CalibrateFromElementsSupport.elementsPayload([element])[0]
        XCTAssertEqual(entry["observation"] as? String, "bounds")
        XCTAssertEqual(entry["correspondences"] as? Int, 2)
        XCTAssertNil(entry["resolvedBackingCenter"], "no centre was solved from, so none is reported")
        XCTAssertNil(entry["observedCenter"])

        let resolvedCorners = entry["resolvedBackingCorners"] as? [String: Any]
        let observedCorners = entry["observedCorners"] as? [String: Any]
        for (index, corner) in ["topLeft", "bottomRight"].enumerated() {
            let reported = resolvedCorners?[corner] as? [String: Any]
            XCTAssertEqual(reported?["x"] as? Double,
                           CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].trueX), corner)
            XCTAssertEqual(reported?["y"] as? Double,
                           CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].trueY), corner)
            let seen = observedCorners?[corner] as? [String: Any]
            XCTAssertEqual(seen?["x"] as? Double,
                           CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].observedX), corner)
            XCTAssertEqual(seen?["y"] as? Double,
                           CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].observedY), corner)
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["elements": [entry]]))
    }

    /// A centre-observed element's payload is UNCHANGED by the arrival of the
    /// bounds form, and now says so in as many words -- a caller that meant to
    /// send a box, mistyped a key and got a centre solve finds out here.
    func testACentreElementsPayloadIsUnchangedAndStillNamesItsForm() {
        let entry = CalibrateFromElementsSupport.elementsPayload([
            resolvedElement(label: "Save", x: 100, y: 200, width: 80, height: 40,
                            observedX: 70, observedY: 110)
        ])[0]
        XCTAssertEqual(entry["observation"] as? String, "centre")
        XCTAssertEqual(entry["correspondences"] as? Int, 1)
        XCTAssertEqual((entry["resolvedBackingCenter"] as? [String: Any])?["x"] as? Double, 140)
        XCTAssertEqual((entry["observedCenter"] as? [String: Any])?["x"] as? Double, 70)
        XCTAssertNil(entry["resolvedBackingCorners"])
        XCTAssertNil(entry["observedCorners"])
    }

    /// A non-finite rect cannot reach `JSONSerialization` through the BOUNDS
    /// branch either -- it throws on a non-finite Double rather than encoding
    /// it, which would turn an already-registered, successful calibration into
    /// an unencodable response. Pinned for the corner path specifically,
    /// because that path is new and does not share the centre path's code.
    func testABoundsPayloadIsAlwaysJSONEncodableToo() {
        let payload = CalibrateFromElementsSupport.elementsPayload([
            resolvedElement(label: "Canvas", x: .infinity, y: .nan, width: 10, height: 10,
                            observation: .bounds(left: 1, top: 2, right: 3, bottom: 4))
        ])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["elements": payload]))
        let corner = (payload[0]["resolvedBackingCorners"] as? [String: Any])?["topLeft"] as? [String: Any]
        XCTAssertEqual(corner?["x"] as? Double, 0)
        XCTAssertEqual(corner?["y"] as? Double, 0)
    }

    // MARK: - CalibrateFromElementsSupport.resolveDisplay (the same-display rule)

    /// THE FAILURE THIS RULE CLOSES: a screenshot is the image of ONE display,
    /// and every number this route solves is in one display's backing pixels.
    /// Fiducials taken from two displays would still solve -- to a perfectly
    /// well-formed screenshot_space that misplaces every coordinate drawn
    /// through it -- so this is a rejection, not a vote for the majority
    /// display, and it must name each offending element WITH its display.
    func testElementsSpanningTwoDisplaysAreRejectedNamingEachLabelAndItsDisplay() {
        let message = assertFailure(
            CalibrateFromElementsSupport.resolveDisplay([
                resolvedElement(label: "Save", screenId: "display-1", x: 100, y: 100, width: 80, height: 24, observedX: 70, observedY: 62),
                resolvedElement(label: "Status", screenId: "display-2", x: 40, y: 900, width: 200, height: 20, observedX: 20, observedY: 455)
            ], explicitScreenId: nil),
            contains: "resolved onto 2 DIFFERENT displays"
        )
        XCTAssertTrue(message.contains("'Save' on display display-1"), message)
        XCTAssertTrue(message.contains("'Status' on display display-2"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
    }

    /// With no `screen_id` the display is DERIVED from the elements rather
    /// than defaulted to main -- on a two-monitor desk the target app very
    /// often is not on the main display, and a defaulted display is exactly
    /// how a space gets registered against a screen the screenshot is not of.
    func testTheDisplayIsDerivedFromTheElementsRatherThanDefaultedWhenScreenIdIsOmitted() {
        switch CalibrateFromElementsSupport.resolveDisplay([
            resolvedElement(label: "Save", screenId: "display-7", x: 100, y: 100, width: 80, height: 24, observedX: 70, observedY: 62),
            resolvedElement(label: "Status", screenId: "display-7", x: 40, y: 900, width: 200, height: 20, observedX: 20, observedY: 455)
        ], explicitScreenId: nil) {
        case .success(let screenId): XCTAssertEqual(screenId, "display-7")
        case .failure(let message): XCTFail("agreeing elements must resolve their own display: \(message)")
        }
    }

    /// An explicit `screen_id` is a CLAIM to be checked, never an override:
    /// the elements' own display was measured from the live arrangement,
    /// so registering against the caller's contradicting id would describe a
    /// display the fiducials are not on.
    func testAnExplicitScreenIdThatContradictsTheResolvedElementsIsRejectedRatherThanObeyed() {
        let message = assertFailure(
            CalibrateFromElementsSupport.resolveDisplay([
                resolvedElement(label: "Save", screenId: "display-1", x: 100, y: 100, width: 80, height: 24, observedX: 70, observedY: 62),
                resolvedElement(label: "Status", screenId: "display-1", x: 40, y: 900, width: 200, height: 20, observedX: 20, observedY: 455)
            ], explicitScreenId: "display-2"),
            contains: "you passed screen_id 'display-2'"
        )
        XCTAssertTrue(message.contains("resolved onto display 'display-1'"), message)
        XCTAssertTrue(message.contains("'Save'"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)

        switch CalibrateFromElementsSupport.resolveDisplay([
            resolvedElement(label: "Save", screenId: "display-1", x: 100, y: 100, width: 80, height: 24, observedX: 70, observedY: 62)
        ], explicitScreenId: "display-1") {
        case .success(let screenId): XCTAssertEqual(screenId, "display-1")
        case .failure(let message): XCTFail("an agreeing screen_id must be accepted: \(message)")
        }
    }

    /// The disagreement check runs BEFORE the `screen_id` check, so a caller
    /// whose elements span two displays is told about the span -- the thing it
    /// must actually fix -- rather than about an id that only looks wrong
    /// because half the elements are elsewhere.
    func testTheSpanningDisplaysRejectionTakesPrecedenceOverTheScreenIdMismatch() {
        assertFailure(
            CalibrateFromElementsSupport.resolveDisplay([
                resolvedElement(label: "Save", screenId: "display-1", x: 0, y: 0, width: 10, height: 10, observedX: 0, observedY: 0),
                resolvedElement(label: "Status", screenId: "display-2", x: 0, y: 0, width: 10, height: 10, observedX: 0, observedY: 0)
            ], explicitScreenId: "display-3"),
            contains: "DIFFERENT displays"
        )
    }

    // MARK: - CalibrateFromElementsSupport geometry and payload

    /// The element's TRUE point is its rect's CENTRE, which is the point least
    /// sensitive to the one systematic error this route carries: an
    /// Accessibility frame is the element's REPORTED rect, and padding or a
    /// focus ring that adds pixels on each side moves both corners while
    /// leaving the centre alone.
    func testTheElementsTruePointIsItsBackingRectsCentre() {
        let center = CalibrateFromElementsSupport.backingCenter(
            of: AccessibilityBackingRect(screenId: "display-1", x: 100, y: 200, width: 80, height: 40)
        )
        XCTAssertEqual(center.x, 140)
        XCTAssertEqual(center.y, 220)
    }

    /// The solver is fed the caller's OWN label as each correspondence's name,
    /// not the app's matched label, because a solver rejection has to name the
    /// element in words the caller can find in its own request -- under
    /// `match: "contains"` the two differ.
    func testCorrespondencesPairTheResolvedCentreWithTheObservedCentreUnderTheCallersOwnLabel() {
        let pairs = CalibrateFromElementsSupport.correspondences([
            resolvedElement(label: "Sav", matchedLabel: "Save Project", x: 100, y: 200, width: 80, height: 40,
                            observedX: 70, observedY: 110),
            resolvedElement(label: "Status", x: 40, y: 900, width: 200, height: 20,
                            observedX: 70, observedY: 455)
        ])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].name, "Sav", "a rejection must name the element the caller asked for")
        XCTAssertEqual(pairs[0].trueX, 140)
        XCTAssertEqual(pairs[0].trueY, 220)
        XCTAssertEqual(pairs[0].observedX, 70)
        XCTAssertEqual(pairs[0].observedY, 110)
        XCTAssertEqual(pairs[1].trueX, 140)
        XCTAssertEqual(pairs[1].trueY, 910)
    }

    /// THE DRIFT THIS PINS: the payload's whole job is to let a caller AUDIT
    /// the solve ("that is not the Save button I meant", "that centre is 40px
    /// off where I see it"). A second copy of the centre arithmetic for the
    /// report would let the reported centre drift from the solved one, which
    /// is the one drift that makes the audit actively misleading. Both must
    /// come from `backingCenter`.
    func testTheReportedCentreIsTheVerySameCentreTheSolverWasGiven() {
        let elements = [
            resolvedElement(label: "Save", role: "AXButton", x: 101, y: 203, width: 81, height: 41,
                            observedX: 70.5, observedY: 110.25),
            resolvedElement(label: "Status", x: 40, y: 900, width: 200, height: 20,
                            observedX: 20, observedY: 455)
        ]
        let pairs = CalibrateFromElementsSupport.correspondences(elements)
        let payload = CalibrateFromElementsSupport.elementsPayload(elements)
        XCTAssertEqual(payload.count, 2)
        for (index, entry) in payload.enumerated() {
            let reported = entry["resolvedBackingCenter"] as? [String: Any]
            XCTAssertEqual(reported?["x"] as? Double, CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].trueX))
            XCTAssertEqual(reported?["y"] as? Double, CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].trueY))
            let observed = entry["observedCenter"] as? [String: Any]
            XCTAssertEqual(observed?["x"] as? Double, CalibrateScreenshotSpaceSupport.displayRounded(pairs[index].observedX))
        }
        XCTAssertEqual(payload[0]["label"] as? String, "Save")
        XCTAssertEqual(payload[0]["role"] as? String, "AXButton")
        XCTAssertEqual(payload[0]["screenId"] as? String, "display-1")
        XCTAssertTrue(payload[1]["role"] is NSNull, "a role-less match reports null, never an empty string")
    }

    /// A match found through `match: "contains"` reports BOTH the label the
    /// caller asked for and the label the app actually published: without the
    /// second, a caller has no way to notice that a loose query answered with
    /// the wrong control, which is the failure mode a loose query has.
    func testAContainsMatchReportsBothTheRequestedAndTheMatchedLabel() {
        let payload = CalibrateFromElementsSupport.elementsPayload([
            resolvedElement(label: "Sav", matchedLabel: "Save Project", x: 0, y: 0, width: 10, height: 10,
                            observedX: 5, observedY: 5)
        ])
        XCTAssertEqual(payload[0]["label"] as? String, "Sav")
        XCTAssertEqual(payload[0]["matchedLabel"] as? String, "Save Project")
    }

    /// Every number this payload emits is JSON-encodable. `JSONSerialization`
    /// THROWS on a non-finite Double rather than encoding it, which would turn
    /// an already-registered, successful calibration into an unencodable
    /// response -- so the payload passes every value through `displayRounded`
    /// even though the solver has already rejected non-finite coordinates.
    func testTheElementsPayloadIsAlwaysJSONEncodable() {
        let payload = CalibrateFromElementsSupport.elementsPayload([
            resolvedElement(label: "Save", x: .infinity, y: .nan, width: 10, height: 10,
                            observedX: 5, observedY: 5)
        ])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["elements": payload]))
        let reported = payload[0]["resolvedBackingCenter"] as? [String: Any]
        XCTAssertEqual(reported?["x"] as? Double, 0)
        XCTAssertEqual(reported?["y"] as? Double, 0)
    }

    /// THE FALSE REASSURANCE THIS PREVENTS: with exactly two correspondences
    /// the per-axis fit has two unknowns and two readings, so it reproduces
    /// both EXACTLY whatever they were, and the redundancy check has nothing
    /// left over to test. A caller reading `provenance: "observed"` beside
    /// residuals of zero would reasonably conclude the calibration had been
    /// verified. It had not, and the payload has to say so.
    func testATwoCorrespondenceCalibrationSaysPlainlyThatItsZeroResidualsProveNothing() {
        let caveat = CalibrateFromElementsSupport.redundancyCaveat(correspondenceCount: 2)
        XCTAssertNotNil(caveat)
        XCTAssertTrue(caveat?.contains("MEASURED BUT NOT CROSS-CHECKED") == true, caveat ?? "")
        XCTAssertTrue(caveat?.contains("3 or more") == true, caveat ?? "")
        XCTAssertNil(CalibrateFromElementsSupport.redundancyCaveat(correspondenceCount: 3),
                     "three correspondences ARE cross-checkable, so the caveat must not fire and dilute itself")
        XCTAssertNil(CalibrateFromElementsSupport.redundancyCaveat(correspondenceCount: 8))
    }

    /// THE MISCOUNT THIS PINS: a lone bounds-observed element is ONE element
    /// and TWO correspondences, and it is precisely the input that cannot be
    /// cross-checked -- the fit reproduces both of its corners exactly and no
    /// third point exists to disagree. Had the caveat gone on counting
    /// ELEMENTS it would have skipped that request entirely at a count of 1
    /// (`1 < 3` is true, so it would in fact have fired -- but reading "with
    /// exactly 1 elements"), and would have wrongly fired for two boxes,
    /// which are four genuinely cross-checked points.
    func testTheCaveatCountsCorrespondencesSoALoneBoundsElementStillCarriesIt() {
        let loneWindow = [
            resolvedElement(label: "Shadow PC - Display", x: 100, y: 50, width: 2_000, height: 1_200,
                            observation: .bounds(left: 50, top: 25, right: 1_050, bottom: 625))
        ]
        let pairs = CalibrateFromElementsSupport.correspondences(loneWindow)
        XCTAssertEqual(pairs.count, 2, "one box is two points")
        XCTAssertNotNil(CalibrateFromElementsSupport.redundancyCaveat(correspondenceCount: pairs.count),
                        "a single window's two corners are exactly the uncheckable case")

        let twoWindows = loneWindow + [
            resolvedElement(label: "Preview", x: 200, y: 900, width: 800, height: 400,
                            observation: .bounds(left: 100, top: 450, right: 500, bottom: 650))
        ]
        XCTAssertNil(
            CalibrateFromElementsSupport.redundancyCaveat(
                correspondenceCount: CalibrateFromElementsSupport.correspondences(twoWindows).count),
            "four points across two rects ARE cross-checked, and a caveat that fired here would dilute itself"
        )
    }

    // MARK: - CalibrateFromElementsSupport failure wording

    /// THE MISTAKE THIS PREVENTS: the three sibling actions on this tool are a
    /// stateful handshake whose documented contract is full of cleanup
    /// promises, so an agent that meets a rejection here has every reason to
    /// believe fiducials are now stranded on the user's screen. Its next move
    /// is a `cancel` it has no `calibration_id` for, or a fresh `begin` that
    /// really does paint markers. Every rejection therefore states that this
    /// action is stateless -- while keeping the specific diagnosis verbatim,
    /// exactly as `resolveRejectionMessage` does for the marker route.
    func testEveryElementsRejectionStatesThatNothingWasDrawnAndThereIsNothingToCancel() {
        let diagnosis = "elements[1] (label 'Cancel') has occurrence 0; occurrence must be one-based and greater than zero."
        let message = CalibrateFromElementsSupport.rejection(diagnosis)
        XCTAssertTrue(message.hasPrefix(diagnosis), "the specific complaint must survive verbatim: \(message)")
        XCTAssertTrue(message.contains("single-shot and stateless"), message)
        XCTAssertTrue(message.contains("nothing was drawn"), message)
        XCTAssertTrue(message.contains("nothing to cancel"), message)
        XCTAssertFalse(message.contains("action=\"begin\""),
                       "this route must never point a rejected caller at the handshake that DOES paint markers: \(message)")
    }

    /// The app lookup is SHARED with `highlight_element` rather than
    /// re-implemented -- a second copy would be free to disagree about which
    /// process an ambiguous name means -- so its prose names that tool. The
    /// wrapper keeps that diagnosis verbatim while making clear which tool the
    /// caller actually reached and why the two share one answer.
    func testTheSharedAppLookupsFailureIsQuotedVerbatimUnderThisToolsOwnName() {
        let shared = "App 'Resolve' is AMBIGUOUS across running applications: 'DaVinci Resolve' [com.blackmagic-design.DaVinciResolve]. Retry with an exact bundle id or display name."
        let message = CalibrateFromElementsSupport.appResolutionFailure(shared, app: "Resolve")
        XCTAssertTrue(message.contains("calibrate_screenshot_space action=\"elements\""), message)
        XCTAssertTrue(message.contains("could not resolve app 'Resolve'"), message)
        XCTAssertTrue(message.contains(shared), "the shared lookup's own diagnosis must survive intact: \(message)")
        XCTAssertTrue(message.contains("SAME running-application lookup highlight_element uses"),
                      "the caller must be told why another tool's name appears in its error: \(message)")
        XCTAssertTrue(message.contains("Nothing was registered"), message)
    }

    /// THE WRONG-SETTINGS-PANE MISTAKE THIS PREVENTS: this route exists
    /// precisely because a caller was fighting an invisible-fiducial problem,
    /// and an agent in that state reads any failure here as the same Screen
    /// Recording grant failing again. It is not: element positions are read
    /// through ACCESSIBILITY and no screenshot of any kind is taken.
    ///
    /// The disambiguation advice is PLATFORM-SPLIT following `MCPToolCatalog`'s
    /// precedent -- the macOS resolver's ambiguity error carries a
    /// per-candidate list, the Windows one reports only a match COUNT -- so
    /// neither platform's caller is sent looking for information that does not
    /// exist there.
    func testAnElementLookupFailureNamesTheElementTheGrantAndOnlyThePlatformsRealAmbiguityAdvice() {
        let resolverError = "No accessibility element matched label 'Svae'. The UI may not expose that control to macOS Accessibility."
        let message = CalibrateFromElementsSupport.elementResolutionFailure(resolverError, index: 2, label: "Svae")
        XCTAssertTrue(message.contains("elements[2] (label 'Svae')"), message)
        XCTAssertTrue(message.contains(resolverError), "the resolver's own diagnosis must survive intact: \(message)")
        XCTAssertTrue(message.contains("ACCESSIBILITY, not Screen Recording"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        #if os(macOS)
        XCTAssertTrue(message.contains("lists the candidates it found"), message)
        #elseif os(Windows)
        XCTAssertTrue(message.contains("only HOW MANY candidates matched"), message)
        XCTAssertFalse(message.contains("lists the candidates"),
                       "Windows UI Automation publishes no per-candidate list; promising one sends the caller looking for it: \(message)")
        #endif
    }

    /// The post-walk re-confirmation guard: this route runs one hierarchy walk
    /// PER ELEMENT, serially, so the window in which a display can be added,
    /// removed, rearranged or rescaled is a multiple of the one
    /// `highlight_element`'s identical check was written for. Its rejection
    /// must name the element, say the condition is transient, and steer the
    /// caller away from the eyeballed-screenshot fallback this whole feature
    /// exists to remove.
    func testTheDisplayLayoutChangedRejectionNamesTheElementAndRefusesTheEyeballedFallback() {
        let message = CalibrateFromElementsSupport.displayLayoutChangedFailure(index: 1, label: "Status")
        XCTAssertTrue(message.contains("elements[1] (label 'Status')"), message)
        XCTAssertTrue(message.contains("transient"), message)
        XCTAssertTrue(message.contains("Nothing was registered"), message)
        XCTAssertTrue(message.contains("do not fall back to eyeballed screenshot coordinates"), message)
    }

    // MARK: - The residual vocabulary shared by both measured routes

    /// THE DRIFT THIS PINS: two routes now produce a
    /// `ScreenshotCalibration.Solution` -- the four-marker handshake and the
    /// stateless element route -- and both owe the caller the same reading of
    /// the same `Residuals` value. A second copy of this key list would let
    /// one route quietly grow or rename a field the other never reports, so an
    /// agent comparing two calibrations of the same display would be comparing
    /// two vocabularies.
    func testBothMeasuredRoutesReportResidualsThroughOneSharedKeyVocabulary() {
        let payload = CalibrateScreenshotSpaceSupport.residualsPayload(
            ScreenshotCalibration.Residuals(
                originX: 0.0004, originY: -0.0, horizontalPairDisagreement: 1.5,
                verticalPairDisagreement: 2.25, widthSnapPx: -3.5, heightSnapPx: 0
            )
        )
        XCTAssertEqual(Set(payload.keys), [
            "originX", "originY", "horizontalPairDisagreementPx",
            "verticalPairDisagreementPx", "widthSnapPx", "heightSnapPx"
        ])
        XCTAssertEqual(payload["originX"] as? Double, 0)
        XCTAssertEqual(payload["originY"] as? Double, 0, "-0.0 encodes as a signed -0 in JSON and must be normalized")
        XCTAssertEqual(payload["horizontalPairDisagreementPx"] as? Double, 1.5)
        XCTAssertEqual(payload["widthSnapPx"] as? Double, -3.5)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["residuals": payload]))
    }

    /// `JSONSerialization` throws on a non-finite Double rather than encoding
    /// it, which would turn a SUCCESSFUL, already-registered calibration into
    /// an unencodable response. Neutralizing at the payload boundary -- never
    /// before a tolerance comparison -- is what keeps that impossible.
    func testANonFiniteResidualCannotReachJSONEncodingFromEitherRoute() {
        let payload = CalibrateScreenshotSpaceSupport.residualsPayload(
            ScreenshotCalibration.Residuals(
                originX: .nan, originY: .infinity, horizontalPairDisagreement: -.infinity,
                verticalPairDisagreement: 0, widthSnapPx: .nan, heightSnapPx: 0
            )
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["residuals": payload]))
        for key in ["originX", "originY", "horizontalPairDisagreementPx", "widthSnapPx"] {
            XCTAssertEqual(payload[key] as? Double, 0, "\(key) must be neutralized, not encoded")
        }
    }
}
