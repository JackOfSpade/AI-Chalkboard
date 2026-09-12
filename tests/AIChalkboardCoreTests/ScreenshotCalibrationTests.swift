import Foundation
import XCTest
@testable import AIChalkboardCore

/// Coverage for `ScreenshotCalibration.solve(observations:screen:)` -- the
/// solver that recovers a screenshot's TRUE pixel dimensions from where an
/// agent reports seeing four fiducial markers, rather than trusting a
/// declared width/height that might be an unverifiable guess.
///
/// Every fixture below is a hand-built `ScreenInfo` plus a hand-built
/// `[ScreenshotCalibration.Observation]`; nothing here touches a display,
/// AppKit, or a live annotation, exactly like `DrawRequestScreenshotMappingTests`'s
/// treatment of `DrawRequest.coordinateTransform`.
final class ScreenshotCalibrationTests: XCTestCase {
    private func screen(id: String = "only", width: Int, height: Int, isMain: Bool = true) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: id, widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: isMain
        )
    }

    private typealias Observation = ScreenshotCalibration.Observation

    /// The exact marker positions an agent would report for a full-display,
    /// UNCROPPED, exact-scale-`scale` capture of a `trueWidth`x`trueHeight`
    /// display: each marker at its normalized position times `scale`, with
    /// no crop offset and no noise. Test bodies perturb this baseline to
    /// build every failure fixture, so each test's departure from a known-
    /// good reading is visible by inspection.
    private func exactObservations(trueWidth: Double, trueHeight: Double, scale: Double) -> [Observation] {
        [
            Observation(label: "TL", x: 0.1 * trueWidth * scale, y: 0.1 * trueHeight * scale),
            Observation(label: "TR", x: 0.9 * trueWidth * scale, y: 0.1 * trueHeight * scale),
            Observation(label: "BL", x: 0.1 * trueWidth * scale, y: 0.9 * trueHeight * scale),
            Observation(label: "BR", x: 0.9 * trueWidth * scale, y: 0.9 * trueHeight * scale)
        ]
    }

    private func observation(_ observations: [Observation], _ label: String) -> Observation {
        observations.first(where: { $0.label == label })!
    }

    // MARK: - Marker table

    /// Pins the marker table's exact labels and normalized positions: 0.1/0.9
    /// on each axis, one marker per corner. A drift here would silently
    /// change what every caller paints without touching this solver's own
    /// arithmetic, so it is asserted directly.
    func testMarkerTableHasFourCornersAtOneTenthAndNineTenths() {
        let byLabel = Dictionary(uniqueKeysWithValues: ScreenshotCalibration.markers.map { ($0.label, $0) })
        XCTAssertEqual(byLabel.count, 4, "Expected exactly four distinct marker labels.")
        XCTAssertEqual(byLabel["TL"], ScreenshotCalibration.Marker(label: "TL", normalizedX: 0.1, normalizedY: 0.1))
        XCTAssertEqual(byLabel["TR"], ScreenshotCalibration.Marker(label: "TR", normalizedX: 0.9, normalizedY: 0.1))
        XCTAssertEqual(byLabel["BL"], ScreenshotCalibration.Marker(label: "BL", normalizedX: 0.1, normalizedY: 0.9))
        XCTAssertEqual(byLabel["BR"], ScreenshotCalibration.Marker(label: "BR", normalizedX: 0.9, normalizedY: 0.9))
    }

    // MARK: - Clean solves

    /// A native-resolution, exact, noise-free reading must solve to the
    /// EXACT integer dimensions -- the input is exact, so nothing here should
    /// introduce rounding slop.
    func testExactNativeResolutionReadSolvesExactIntegerDimensions() {
        let display = screen(width: 3_840, height: 2_160)
        let observations = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("An exact native-resolution reading must solve successfully: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
            XCTAssertEqual(solution.scaleToBackingPx.x, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.y, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originX, 0, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originY, 0, accuracy: 1e-9)
        }
    }

    /// A uniform 0.5x downsample (e.g. a Retina display exported at half
    /// size) must also solve to exact integers, with `scaleToBackingPx`
    /// reporting the factor that converts a screenshot-pixel coordinate back
    /// into `screen`'s backing pixels.
    func testExactHalfScaleDownsampleReadSolvesExactIntegerDimensions() {
        let display = screen(width: 3_840, height: 2_160)
        let observations = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 0.5)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("An exact 0.5x downsample reading must solve successfully: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 1_920)
            XCTAssertEqual(solution.heightPx, 1_080)
            XCTAssertEqual(solution.scaleToBackingPx.x, 2, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.y, 2, accuracy: 1e-9)
        }
    }

    /// A couple of pixels of plausible human/agent eyeballing noise on every
    /// marker must still pass -- and, since the fix for the calibration/draw
    /// round-trip bug (see `ScreenshotCalibration.solve`'s step (e) doc
    /// comment), must now solve to the EXACT display size, not merely
    /// "close" to it.
    ///
    /// THE BUG THIS PINS THE FIX FOR: before the snap-to-display-consistent-
    /// size step existed, this solver rounded each axis to the nearest
    /// integer INDEPENDENTLY. A per-axis-independent reading like this one --
    /// width measured a few tenths of a pixel light, height measured exactly
    /// right -- used to round to a pair (e.g. 3839x2160) that is not any
    /// uniform downsample of a 3840x2160 display at all, which
    /// `ScreenshotGeometry.fullDisplayScale`'s strict half-pixel-per-axis
    /// tolerance (the SAME guard `DrawRequest.coordinateTransform` applies to
    /// every draw call) would then refuse -- calibration minting a space the
    /// draw pipeline immediately rejected. Estimating ONE scale from BOTH
    /// axes together and applying it to BOTH of the display's own
    /// dimensions recovers the true, uniform size instead: this specific
    /// jitter (up to 2px per marker, not designed to cancel) recovers the
    /// display's exact native size, asserted exactly below rather than with
    /// a tolerance -- that exactness is the whole point of the snap.
    func testTwoPixelEyeballingNoiseStillSolvesSuccessfully() {
        let display = screen(width: 3_840, height: 2_160)
        var observations = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        // Nudge each marker by up to 2px, alternating direction so the noise
        // does not cancel out uniformly across the set.
        let jitter: [String: (Double, Double)] = [
            "TL": (2, -2), "TR": (2, 1), "BL": (2, 1), "BR": (1, -2)
        ]
        observations = observations.map { obs in
            let (dx, dy) = jitter[obs.label] ?? (0, 0)
            return Observation(label: obs.label, x: obs.x + dx, y: obs.y + dy)
        }
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("2px of eyeballing noise must stay within tolerance: \(message)")
        case .success(let solution):
            // Exact, not merely close: the raw per-axis solve here is
            // 3839.375 x 2160.0 (a 0.625px width residual after the mean-of-
            // two-markers reduction), which the display-consistent snap
            // moves onto the display's own exact native size.
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
            // The snap distance is reported precisely: 0.625px on width
            // (the axis that actually carried noise here), 0 on height (the
            // axis whose noise happened to cancel).
            XCTAssertEqual(solution.residuals.widthSnapPx, 0.625, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.heightSnapPx, 0, accuracy: 1e-9)
        }
    }

    // MARK: - (a) Structural validation

    /// Missing marker: only three of the four required labels are present.
    func testMissingMarkerLabelIsRejectedByName() {
        let display = screen(width: 3_840, height: 2_160)
        var observations = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        observations.removeAll(where: { $0.label == "BR" })
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("A missing required marker must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("missing marker"), message)
            XCTAssertTrue(message.contains("BR"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// Duplicate marker: 'TL' reported twice, crowding out one of the other
    /// three labels. The duplicate is caught by name regardless of what else
    /// is wrong with the set.
    func testDuplicateMarkerLabelIsRejectedByName() {
        let display = screen(width: 3_840, height: 2_160)
        let base = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        let observations = [
            observation(base, "TL"),
            Observation(label: "TL", x: observation(base, "TL").x + 5, y: observation(base, "TL").y + 5),
            observation(base, "TR"),
            observation(base, "BL")
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("A duplicate marker label must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("supplied 2 times"), message)
            XCTAssertTrue(message.contains("'TL'"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// Unknown marker label: an observation naming a label outside
    /// TL/TR/BL/BR. Checked ahead of "missing", so this is what the caller
    /// sees even though the unknown label also leaves BR unreported.
    func testUnknownMarkerLabelIsRejectedByName() {
        let display = screen(width: 3_840, height: 2_160)
        let base = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        let observations = [
            observation(base, "TL"),
            observation(base, "TR"),
            observation(base, "BL"),
            Observation(label: "XX", x: observation(base, "BR").x, y: observation(base, "BR").y)
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("An unknown marker label must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("unknown marker label 'XX'"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// Non-finite coordinate: a marker whose reported y is NaN.
    func testNonFiniteMarkerCoordinateIsRejectedByName() {
        let display = screen(width: 3_840, height: 2_160)
        let base = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        let observations = [
            observation(base, "TL"),
            observation(base, "TR"),
            Observation(label: "BL", x: observation(base, "BL").x, y: Double.nan),
            observation(base, "BR")
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("A non-finite coordinate must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("marker 'BL'"), message)
            XCTAssertTrue(message.contains("non-finite"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (b) Non-positive/non-finite span

    /// All four markers reported at the same x collapses BOTH the TR/BR mean
    /// and the TL/BL mean to that one value, so the horizontal span is
    /// exactly zero -- non-positive, and must be rejected before any
    /// redundancy or origin arithmetic runs on a meaningless solved width.
    func testZeroHorizontalSpanIsRejectedAsNonPositive() {
        let display = screen(width: 3_840, height: 2_160)
        let base = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        let observations = [
            Observation(label: "TL", x: 1_000, y: observation(base, "TL").y),
            Observation(label: "TR", x: 1_000, y: observation(base, "TR").y),
            Observation(label: "BL", x: 1_000, y: observation(base, "BL").y),
            Observation(label: "BR", x: 1_000, y: observation(base, "BR").y)
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("A zero-width solve must be rejected, not treated as a degenerate but valid image.")
        case .failure(let message):
            XCTAssertTrue(message.contains("solved image width"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (e) Snapped result must be a positive integer size

    /// A sub-pixel solved size is positive, so it survives (b), and is
    /// perfectly self-consistent, so it survives (c) and (d) too -- but it
    /// snaps to 0x0, which (e) must still catch: a "0x0" image is not a
    /// valid size regardless of how clean the measurement was.
    ///
    /// `trueHeight` is chosen as EXACTLY `trueWidth` scaled by the display's
    /// own aspect ratio (0.3 * 2160/3840 = 0.16875), so both axes imply the
    /// identical scale and the snap-vs-observed rejection (the check
    /// immediately before this one) does not fire first -- this fixture
    /// isolates the positive-size guard specifically, rather than
    /// incidentally exercising the "not a uniform downsample" rejection
    /// instead.
    func testSubPixelSolvedWidthRoundsToZeroAndIsRejected() {
        let display = screen(width: 3_840, height: 2_160)
        let observations = exactObservations(trueWidth: 0.3, trueHeight: 0.3 * 2_160 / 3_840, scale: 1)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success(let solution):
            XCTFail("A size that snaps to zero must be rejected: got \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("snapped to 0x0"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (c) Redundancy check

    /// TL's x is misread far enough from BL's x (which shares the same
    /// normalized x) to exceed tolerance, while everything else about the
    /// set is clean. This is the check two-diagonal-marker calibration could
    /// never perform, because it has no second observation of that axis to
    /// disagree with.
    func testRedundancyCheckCatchesADisagreeingMarkerPairByName() {
        let display = screen(width: 3_840, height: 2_160)
        let base = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        var observations = base
        let index = observations.firstIndex(where: { $0.label == "TL" })!
        // Tolerance is the read-noise budget max(4, 0.25% of ~3840) ≈ 9.6px;
        // push TL's x 200px away from BL's matching x, well past that.
        observations[index] = Observation(label: "TL", x: observation(base, "TL").x + 200, y: observation(base, "TL").y)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("A 200px disagreement between TL and BL's shared x must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("TL/BL"), message)
            XCTAssertTrue(message.contains("disagree"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (d) Origin residual check -- the highest-value test in this file

    /// THE test that justifies this whole solver's existence. A crop that
    /// removes an equal 10% margin from every edge of the true display
    /// produces an image whose width/height RATIO is bit-for-bit identical
    /// to the full display's -- `ScreenshotGeometry.fullDisplayScale` cannot
    /// tell this apart from a genuine full-display downsample by dimensions
    /// alone, because it is not mathematically distinguishable that way. The
    /// marker SPREAD still recovers the true 3840x2160 size exactly (a crop
    /// preserves distances between points, only translating them), so this
    /// case sails through the redundancy check and both `ScreenshotGeometry`
    /// guards in step (f). The origin residual is the ONLY check that
    /// catches it: the crop shifts every marker away from the image's own
    /// (0,0) by the crop's offset, and that offset is exactly what
    /// `originX`/`originY` measure.
    func testCroppedImageWithPreservedAspectRatioIsCaughtOnlyByTheOriginResidual() {
        let trueWidth = 3_840.0
        let trueHeight = 2_160.0
        let display = screen(width: 3_840, height: 2_160)

        // True marker positions on the display, uncropped.
        let trueTL = (x: 0.1 * trueWidth, y: 0.1 * trueHeight)
        let trueTR = (x: 0.9 * trueWidth, y: 0.1 * trueHeight)
        let trueBL = (x: 0.1 * trueWidth, y: 0.9 * trueHeight)
        let trueBR = (x: 0.9 * trueWidth, y: 0.9 * trueHeight)

        // The screenshot only shows the middle 80% of the display on each
        // axis (crop offset = 10% of each true dimension), so every marker's
        // position in the CROPPED image's own pixel coordinates is shifted
        // by exactly that offset relative to the true display.
        let cropOffsetX = 0.1 * trueWidth
        let cropOffsetY = 0.1 * trueHeight
        let observations = [
            Observation(label: "TL", x: trueTL.x - cropOffsetX, y: trueTL.y - cropOffsetY),
            Observation(label: "TR", x: trueTR.x - cropOffsetX, y: trueTR.y - cropOffsetY),
            Observation(label: "BL", x: trueBL.x - cropOffsetX, y: trueBL.y - cropOffsetY),
            Observation(label: "BR", x: trueBR.x - cropOffsetX, y: trueBR.y - cropOffsetY)
        ]

        // Sanity-check the premise: the redundancy check sees a perfectly
        // self-consistent (noise-free) set, and the solved size below is
        // exactly the display's own size -- so `ScreenshotGeometry`'s
        // aspect/upscale guards, taken alone, would wrongly accept this as a
        // clean native capture.
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success(let solution):
            XCTFail("A same-aspect-ratio crop must be rejected by the origin residual, not silently accepted as size \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("cropped") || message.contains("not a full-display capture"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// The positive control for the crop test above: the SAME markers,
    /// uncropped (no offset), must solve cleanly with near-zero origin
    /// residuals -- confirming the rejection above is really about the crop
    /// offset and not some other property of this fixture.
    func testUncroppedCounterpartOfTheCropFixtureSolvesCleanly() {
        let display = screen(width: 3_840, height: 2_160)
        let observations = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("The uncropped counterpart must solve successfully: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
            XCTAssertEqual(solution.residuals.originX, 0, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originY, 0, accuracy: 1e-9)
        }
    }

    /// THE 40PX-CROP-AT-5K HOLE THE TOLERANCE SPLIT CLOSES. A native
    /// 5120x2880 capture cropped 40px off the left (and the proportional
    /// 22.5px off the top, preserving the aspect ratio) keeps the marker
    /// SPREAD exact -- the solve still recovers 5120x2880 to the pixel, the
    /// snap distance is zero, and both `ScreenshotGeometry` guards pass --
    /// so the origin residual of exactly 40px is the only trace of the crop.
    ///
    /// Under the old single `max(4px, 1% of span)` tolerance, that residual
    /// sat comfortably inside the 51.2px budget at 5120: the solve
    /// SUCCEEDED, registered a space with `observed` provenance, and every
    /// drawing made through it landed 40px off -- the crop detector defeated
    /// by its own tolerance precisely on the images where a crop costs the
    /// most pixels. The origin residual is a READ-NOISE-sized quantity (a
    /// mean of marker reads minus a fixed fraction of the solved width),
    /// never legitimately 1% of a 5K image, and the read-noise budget
    /// `max(4px, 0.25% of span)` = 12.8px at 5120 rejects the 40px shift
    /// while still clearing every honest reading in this file.
    func testAFortyPixelCropOfAFiveKCaptureIsRejectedByTheOriginResidual() {
        let display = screen(width: 5_120, height: 2_880)
        let cropOffsetX = 40.0
        let cropOffsetY = 22.5 // 40 * 2880/5120: the aspect-preserving share
        let observations = exactObservations(trueWidth: 5_120, trueHeight: 2_880, scale: 1).map {
            Observation(label: $0.label, x: $0.x - cropOffsetX, y: $0.y - cropOffsetY)
        }
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success(let solution):
            XCTFail("A 40px crop at 5K must be rejected by the origin residual, not registered as \(solution.widthPx)x\(solution.heightPx) -- that acceptance was the exact hole the read-noise tolerance closes.")
        case .failure(let message):
            XCTAssertTrue(message.contains("cropped") || message.contains("not a full-display capture"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// The counterweight that keeps the tightened gate honest at 5K:
    /// realistic read noise on a 5120x2880 native capture must still pass.
    ///
    /// WHY THE NOISE HERE IS LARGER THAN THE 4PX FLOOR: an agent reads a 5K
    /// screenshot through a fixed-resolution vision pipeline, so a +-2px
    /// reading error at ~1500 viewed pixels becomes ~7px of error at 5120 --
    /// read noise scales with image size, just far more slowly than 1% of
    /// span. This fixture gives every marker up to 8px of error (a
    /// common-mode bias of +6/-5 px, the dominant real component, plus
    /// per-marker differential jitter), producing pair disagreements of
    /// 4-6px and origin residuals of 5-6px. A FLAT 4px bound would reject
    /// this honest reading on three separate checks; the read-noise budget
    /// (12.8px horizontal, 7.2px vertical at this size) passes it, and the
    /// differential jitter cancels pairwise so the solve still lands on the
    /// display's exact native size.
    func testRealisticFiveKReadNoisePassesTheReadNoiseGatesAndSolvesToNative() {
        let display = screen(width: 5_120, height: 2_880)
        // Errors per marker: x = common +6 with +-2 differential,
        // y = common -5 with +-3 differential.
        let observations = [
            Observation(label: "TL", x: 512 + 8, y: 288 - 2),
            Observation(label: "TR", x: 4_608 + 8, y: 288 - 8),
            Observation(label: "BL", x: 512 + 4, y: 2_592 - 8),
            Observation(label: "BR", x: 4_608 + 4, y: 2_592 - 2)
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("Realistic vision-pipeline read noise at 5K must stay within the read-noise tolerance: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 5_120)
            XCTAssertEqual(solution.heightPx, 2_880)
            // The residuals a caller sees: pair disagreements of 4px
            // horizontal / 6px vertical and origin residuals of 6px / -5px
            // -- all above the 4px floor, all inside the 0.25%-of-span
            // budget, exactly the regime the relative term exists for.
            XCTAssertEqual(solution.residuals.horizontalPairDisagreement, 4, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.verticalPairDisagreement, 6, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originX, 6, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originY, -5, accuracy: 1e-9)
        }
    }

    /// The common MacBook case the tightening also touches: a 1470x956
    /// downsample of a 2940x1912 display, read with +-2px of ordinary
    /// jitter. At this size the read-noise budget's relative term (~3.7px)
    /// falls BELOW the 4px floor, so the floor governs -- deliberately
    /// tighter than the 14.7px the old 1% term allowed, because a +-2px
    /// read never produces a 14px residual either. This pins that the floor
    /// still clears realistic small-image noise: pair disagreements of
    /// 2-3px, origin residuals ~1px, solved size exactly 1470x956 with the
    /// 2x scale back into backing pixels.
    func testFourteenSeventyDownsampleWithTwoPixelReadsStillSolvesCleanly() {
        let display = screen(width: 2_940, height: 1_912)
        let jitter: [String: (Double, Double)] = [
            "TL": (2, -2), "TR": (-1, 1), "BL": (0, 2), "BR": (1, -1)
        ]
        let observations = exactObservations(trueWidth: 2_940, trueHeight: 1_912, scale: 0.5).map { obs in
            let (dx, dy) = jitter[obs.label] ?? (0, 0)
            return Observation(label: obs.label, x: obs.x + dx, y: obs.y + dy)
        }
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("+-2px reads of a 1470x956 downsample must stay inside the 4px floor: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 1_470)
            XCTAssertEqual(solution.heightPx, 956)
            XCTAssertEqual(solution.scaleToBackingPx.x, 2, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.y, 2, accuracy: 1e-9)
        }
    }

    // MARK: - Transposed labels

    /// TOP and BOTTOM rows are swapped wholesale (TL/TR report the true
    /// BL/BR positions and vice versa). The horizontal spread is untouched
    /// (only rows moved, not columns), but the vertical spread inverts sign,
    /// so this is caught by the same non-positive-span guard as (b) --
    /// exercised here as its own named scenario because a whole-row
    /// transposition is the concrete mistake that guard exists to catch.
    func testTransposedTopAndBottomRowsProduceNegativeHeightRejection() {
        let display = screen(width: 3_840, height: 2_160)
        let trueWidth = 3_840.0
        let trueHeight = 2_160.0
        let observations = [
            // TL reports the true BL position; TR reports the true BR
            // position; BL/BR report the true TL/TR positions.
            Observation(label: "TL", x: 0.1 * trueWidth, y: 0.9 * trueHeight),
            Observation(label: "TR", x: 0.9 * trueWidth, y: 0.9 * trueHeight),
            Observation(label: "BL", x: 0.1 * trueWidth, y: 0.1 * trueHeight),
            Observation(label: "BR", x: 0.9 * trueWidth, y: 0.1 * trueHeight)
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success:
            XCTFail("Transposed top/bottom rows must be rejected, not silently solved with a flipped height.")
        case .failure(let message):
            XCTAssertTrue(message.contains("solved image height"), message)
            XCTAssertTrue(message.contains("transposed") || message.contains("mislabelled"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (e) The uniform-downsample rejection catches a wrong aspect ratio

    /// A perfectly self-consistent marker set (no redundancy or origin
    /// issues at all) whose measured aspect ratio simply does not match the
    /// target display's -- e.g. the markers describe a square image against
    /// a 16:9 display.
    ///
    /// Caught by the snap-vs-observed rejection in step (e), NOT by the
    /// reverted `ScreenshotGeometry.fullDisplayScale` check in step (f):
    /// forcing a single shared scale onto a 1000x1000 reading against a
    /// 3840x2160 display snaps to 1389x781, 389px away from the measured
    /// 1000px width -- far past tolerance -- because no uniform downsample of
    /// this display can describe a square image at all. Step (f)'s aspect
    /// check never even runs for this input: it exists purely as belt-and-
    /// braces for a case the step (e) snap makes structurally impossible to
    /// reach it already mismatched.
    func testAspectRatioMismatchAgainstTheTargetDisplayIsRejected() {
        let display = screen(width: 3_840, height: 2_160) // 16:9
        let observations = exactObservations(trueWidth: 1_000, trueHeight: 1_000, scale: 1) // 1:1
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success(let solution):
            XCTFail("A solved 1:1 image must not map onto a 16:9 display: got \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("not close to any uniform downsample"), message)
            XCTAssertTrue(message.contains(display.id), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// A solved size that matches the display's aspect ratio exactly but is
    /// LARGER than it -- an upscale no capture pipeline ever produces. Since
    /// the measured size IS a uniform scale of the display (just >1x), the
    /// step (e) snap distance here is exactly zero -- this is the one
    /// rejection in this file where the reverted, strict step (f)
    /// `ScreenshotGeometry` checks are not mere belt-and-braces but the guard
    /// that actually fires: `fullDisplayScale` passes (same ratio), and only
    /// `isPlausibleFullDisplayCapture`'s no-upscale half rejects it.
    /// Pins the crash an adversarial review reproduced: `Int(someDouble)`
    /// TRAPS rather than returning nil when the value exceeds `Int.max`, and
    /// every guard before the conversion uses a purely RELATIVE tolerance, so
    /// an arbitrarily large SELF-CONSISTENT reading satisfies all of them and
    /// reaches it intact. The trap killed the whole MCP server process
    /// mid-request, losing every other annotation and stranding this
    /// calibration's own fiducials on the user's screen because the session
    /// cleanup never ran.
    func testAnAbsurdlyLargeSelfConsistentReadingIsRejectedInsteadOfTrappingTheProcess() {
        let display = screen(width: 1_920, height: 1_080)
        // Self-consistent to machine precision -- zero pair disagreement and
        // zero origin residual -- but describing an image ~4e19 px wide, far
        // beyond Int.max once snapped.
        let observations = exactObservations(trueWidth: 4.0e19, trueHeight: 2.25e19, scale: 1)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success(let solution):
            XCTFail("An absurdly large reading must be rejected, not solved: got \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("absurdly large"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// Pins the commonest real capture on macOS: a NATIVE-resolution
    /// screenshot, read by eye a fraction of a pixel HIGH.
    ///
    /// Scale exactly 1 sits precisely on step (f)'s no-upscale boundary,
    /// whose tolerance is effectively zero. Before the within-noise clamp,
    /// roughly half of all honest readings of a native capture rounded up to
    /// `screen.widthPx + 1` and were refused as "an upscale that no capture
    /// pipeline produces" -- telling the caller to re-measure, which failed
    /// again the same way. The markers here are read well inside this file's
    /// own 4 px noise floor.
    func testANativeCaptureReadSlightlyHighClampsToNativeRatherThanBeingRefusedAsAnUpscale() {
        let display = screen(width: 3_840, height: 2_160)
        // Both bottom markers read 1 px low: an ordinary eyeballing error.
        let observations = [
            Observation(label: "TL", x: 384, y: 216),
            Observation(label: "TR", x: 3_456, y: 216),
            Observation(label: "BL", x: 384, y: 1_945),
            Observation(label: "BR", x: 3_456, y: 1_945)
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("A native capture read a fraction of a pixel high must resolve to native, not be refused: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840,
                           "a within-noise overshoot must clamp to the display's native width")
            XCTAssertEqual(solution.heightPx, 2_160,
                           "a within-noise overshoot must clamp to the display's native height")
        }
    }

    /// The clamp must NOT swallow a genuine mis-measurement: an overshoot
    /// larger than the measurement budget is a wrong reading or the wrong
    /// display, and must still reach the existing upscale rejection.
    func testSolvedSizeLargerThanTheDisplayIsRejectedAsAnImplausibleUpscale() {
        let display = screen(width: 1_920, height: 1_080)
        // Markers describing a 3840x2160 image: same 16:9 aspect ratio as
        // the display, but exactly 2x its size.
        let observations = exactObservations(trueWidth: 3_840, trueHeight: 2_160, scale: 1)
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .success(let solution):
            XCTFail("A solved size larger than the display must be rejected as an implausible upscale: got \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("LARGER than display"), message)
            XCTAssertTrue(message.contains("upscale"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - Correspondence route: fixtures

    private typealias Correspondence = ScreenshotCalibration.Correspondence

    /// One element fiducial: where Chalkboard resolved its centre through
    /// Accessibility (display backing px) against where the caller says it
    /// sees that same centre in its own screenshot.
    private func element(
        _ name: String, at trueX: Double, _ trueY: Double, seenAt observedX: Double, _ observedY: Double
    ) -> Correspondence {
        Correspondence(name: name, trueX: trueX, trueY: trueY, observedX: observedX, observedY: observedY)
    }

    /// The three well-separated elements every noise/rejection fixture below
    /// perturbs: two near opposite corners of a 3840x2160 display (the same
    /// 0.1/0.9 insets the drawn markers use, so the baseline is known-good)
    /// plus one in the middle, which is the ONLY element that can exercise
    /// the redundancy check -- the outer two define the baseline the check
    /// predicts from.
    private func threeSpreadElements(observed: [(Double, Double)]) -> [Correspondence] {
        let trueCentres = [(384.0, 216.0), (3_456.0, 1_944.0), (1_920.0, 1_080.0)]
        let names = ["Back", "Send", "Search field"]
        return (0..<3).map { index in
            element(names[index],
                    at: trueCentres[index].0, trueCentres[index].1,
                    seenAt: observed[index].0, observed[index].1)
        }
    }

    // MARK: - Correspondence route: clean solves

    /// An exact, noise-free native-resolution reading of two well-separated
    /// elements must solve to the display's exact size, with the scale back
    /// into backing pixels reported as 1.
    ///
    /// This is the whole point of the element route: not one pixel of
    /// Chalkboard's own had to appear in the caller's screenshot for the
    /// image's true size to be measured rather than declared.
    func testExactNativeResolutionCorrespondenceReadSolvesExactIntegerDimensions() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: 200, 300, seenAt: 200, 300),
            element("Send", at: 3_600, 1_900, seenAt: 3_600, 1_900)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .failure(let message):
            XCTFail("An exact native-resolution correspondence reading must solve successfully: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
            XCTAssertEqual(solution.scaleToBackingPx.x, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.y, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originX, 0, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.originY, 0, accuracy: 1e-9)
        }
    }

    /// A uniform 0.5x downsample -- the case a declared "the screenshot is
    /// the display's native size" guess gets exactly 2x wrong while passing
    /// every aspect-ratio check ever written -- must be recovered exactly,
    /// with `scaleToBackingPx` reporting the 2 that converts a screenshot
    /// coordinate back into backing pixels.
    func testExactHalfScaleDownsampleCorrespondenceReadSolvesExactIntegerDimensions() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: 200, 300, seenAt: 100, 150),
            element("Send", at: 3_600, 1_900, seenAt: 1_800, 950)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .failure(let message):
            XCTFail("An exact 0.5x downsample correspondence reading must solve successfully: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 1_920)
            XCTAssertEqual(solution.heightPx, 1_080)
            XCTAssertEqual(solution.scaleToBackingPx.x, 2, accuracy: 1e-9)
            XCTAssertEqual(solution.scaleToBackingPx.y, 2, accuracy: 1e-9)
        }
    }

    /// A pixel of eyeballing noise on every one of three elements must still
    /// land on the display's EXACT native size, not merely near it -- the
    /// same guarantee the marker route's noise test pins, reached through
    /// the shared snap.
    ///
    /// The exact residuals are asserted rather than bounded, because they
    /// are what a caller is shown: the raw per-axis solve here is
    /// 3837.5 x 2162.5 (the two axes disagreeing about the scale by more
    /// than a pixel each), and the snap pulls both onto the single uniform
    /// scale that a real capture pipeline could actually have produced. A
    /// route that rounded each axis independently would return 3838x2163 --
    /// a pair no downsample of this display can produce, which
    /// `DrawRequest.coordinateTransform` would then refuse on the first
    /// draw call.
    func testEyeballingNoiseOnThreeCorrespondencesStillSnapsToTheDisplaysNativeSize() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = threeSpreadElements(observed: [(385, 215), (3_455, 1_945), (1_921, 1_079)])
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .failure(let message):
            XCTFail("A pixel of eyeballing noise per element must stay within tolerance: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
            XCTAssertEqual(solution.residuals.widthSnapPx, 2.5, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.heightSnapPx, -2.5, accuracy: 1e-9)
            // The middle element sat 1px off the line the outer two define,
            // on each axis -- reported, not silently absorbed.
            XCTAssertEqual(solution.residuals.horizontalPairDisagreement, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.verticalPairDisagreement, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.worstRedundancyResidualPx, 1, accuracy: 1e-9)
        }
    }

    /// A two-element solve reports a redundancy residual of ZERO because
    /// there was nothing to cross-check -- the fit through two points is
    /// exact by construction -- and NOT because the reading was flawless.
    ///
    /// Pinned as its own test because the number is genuinely ambiguous to a
    /// reader: anything surfacing `worstRedundancyResidualPx` has to say how
    /// many correspondences produced it, or it advertises a perfect
    /// measurement that was never actually tested.
    func testATwoElementCorrespondenceSolveReportsZeroRedundancyBecauseNothingWasCrossChecked() {
        let display = screen(width: 3_840, height: 2_160)
        // Deliberately NOT a perfect reading: the second element is read 3px
        // off on each axis, and the solve still reports zero redundancy.
        let pairs = [
            element("Back", at: 384, 216, seenAt: 384, 216),
            element("Send", at: 3_456, 1_944, seenAt: 3_453, 1_941)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .failure(let message):
            XCTFail("A slightly-off two-element reading must still solve: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.residuals.worstRedundancyResidualPx, 0,
                           "two correspondences fit exactly by construction, so nothing was cross-checked")
        }
    }

    // MARK: - (a) Structural validation of the correspondence set

    /// One element fixes where the image sits, never how big it is: a size
    /// can only come from the separation between two points.
    func testFewerThanTwoCorrespondencesIsRejected() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [element("Back", at: 384, 216, seenAt: 384, 216)]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success:
            XCTFail("A single correspondence cannot determine a size and must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("at least 2 elements"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// A NaN in the caller's reported centre must be rejected by ELEMENT
    /// NAME, before any arithmetic runs on it: every downstream comparison
    /// with NaN is false, so an unrejected NaN would sail past guards that
    /// look like they are checking it and end up in a JSON payload
    /// `JSONSerialization` cannot encode.
    func testANonFiniteObservedCentreIsRejectedByElementName() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: 384, 216, seenAt: 384, 216),
            element("Send", at: 3_456, 1_944, seenAt: 3_456, .nan)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success:
            XCTFail("A non-finite observed centre must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("'Send'"), message)
            XCTAssertTrue(message.contains("non-finite observed centre"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// The same guard on the OTHER half of a correspondence: a resolved
    /// element rect that came back non-finite. The rejection has to point at
    /// the element rather than at the caller's arithmetic, because this half
    /// of the pair is not something the caller supplied.
    func testANonFiniteResolvedElementCentreIsRejectedByElementName() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: .infinity, 216, seenAt: 384, 216),
            element("Send", at: 3_456, 1_944, seenAt: 3_456, 1_944)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success:
            XCTFail("A non-finite resolved element centre must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("'Back'"), message)
            XCTAssertTrue(message.contains("non-finite centre"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (b) The baseline gate

    /// THE ELEMENT ROUTE'S ANSWER TO "why do the drawn markers sit at
    /// 0.1/0.9". Two elements 200 backing px apart on a 3840 px-wide display
    /// give a baseline of 5% of the axis, so every pixel misread in their
    /// observed centres is multiplied by ~19 on its way into the solved
    /// width. The solve would still "succeed" -- arithmetic does not object
    /// to a short baseline -- which is exactly why this is an enforced gate
    /// and not a warning.
    ///
    /// The second half is the positive control that keeps this test honest:
    /// the SAME two elements, moved apart on the display, solve cleanly. The
    /// rejection is about the baseline and nothing else about the fixture.
    func testTheBaselineGateRejectsTwoAdjacentElementsAndAcceptsTheSameReadingFarApart() {
        let display = screen(width: 3_840, height: 2_160)
        let adjacent = [
            element("Bold", at: 1_800, 200, seenAt: 1_800, 200),
            element("Italic", at: 2_000, 1_900, seenAt: 2_000, 1_900)
        ]
        switch ScreenshotCalibration.solveCorrespondences(adjacent, screen: display) {
        case .success(let solution):
            XCTFail("A 200px baseline on a 3840px axis must be rejected, not solved as \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("'Bold'"), message)
            XCTAssertTrue(message.contains("'Italic'"), message)
            XCTAssertTrue(message.contains("furthest apart horizontally"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
            XCTAssertTrue(message.contains("Pick elements far apart"), message)
            // The gate has to be quoted in the SAME units the tool
            // description quotes it in ("at least 25% of the display's size
            // on that axis"); "0.25 of that display's width" is the same
            // rule wearing a different hat, and an agent should not have to
            // notice that.
            XCTAssertTrue(message.contains("25%"), message)
        }

        let farApart = [
            element("Bold", at: 200, 200, seenAt: 200, 200),
            element("Italic", at: 3_600, 1_900, seenAt: 3_600, 1_900)
        ]
        switch ScreenshotCalibration.solveCorrespondences(farApart, screen: display) {
        case .failure(let message):
            XCTFail("The same two elements far apart must NOT trip the baseline gate: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
        }
    }

    /// REGRESSION, found live against Finder: two elements stacked in the
    /// same sidebar column have IDENTICAL true x values, so the scan for the
    /// widest true pair found its minimum and its maximum at the same index
    /// and the rejection named one element twice -- "the two elements
    /// furthest apart horizontally -- 'Recents' and 'Recents'". The gate
    /// fired correctly; the sentence was useless, because the whole point of
    /// naming the pair is to tell the caller WHICH two to spread apart.
    func testAnAxisWhereEveryElementTiesStillNamesTwoDIFFERENTElements() {
        let display = screen(width: 3_840, height: 2_160)
        let stacked = [
            element("Recents", at: 300, 200, seenAt: 300, 200),
            element("AirDrop", at: 300, 1_900, seenAt: 300, 1_900)
        ]
        switch ScreenshotCalibration.solveCorrespondences(stacked, screen: display) {
        case .success(let solution):
            XCTFail("A zero horizontal baseline must be rejected, not solved as \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("furthest apart horizontally"), message)
            XCTAssertTrue(message.contains("'Recents'"), message)
            XCTAssertTrue(message.contains("'AirDrop'"), message)
            XCTAssertFalse(message.contains("'Recents' and 'Recents'"),
                           "the rejection must name two DIFFERENT elements: \(message)")
        }
    }

    // MARK: - (c) The scale must be positive and finite

    /// The two elements' observed x values run backwards relative to their
    /// true x values -- the signature of a caller that reported element A's
    /// screenshot position under element B's label. The solved scale is
    /// negative, and a negative scale would otherwise produce a
    /// mirror-imaged coordinate space that misplaces every subsequent draw
    /// call while looking perfectly self-consistent.
    func testObservedPositionsRunningBackwardsAreRejectedAsANonPositiveScale() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: 200, 300, seenAt: 3_600, 300),
            element("Send", at: 3_600, 1_900, seenAt: 200, 1_900)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("An inverted observed order must be rejected, not solved as \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("horizontal scale"), message)
            XCTAssertTrue(message.contains("not a positive finite number"), message)
            XCTAssertTrue(message.contains("runs backwards"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (d) The redundancy check

    /// The element route's equivalent of the four-marker redundancy check:
    /// a third element whose observed centre does not sit on the mapping the
    /// other two imply. Here the middle element is reported 200px to the
    /// right of where the baseline pair's own solve predicts it -- caught by
    /// name, with both the predicted and the observed position quoted so the
    /// caller can see which of the two it should re-read.
    ///
    /// With only two correspondences this is unreachable -- the fit through
    /// two points is exact -- which is exactly why the route asks for three
    /// or more.
    func testAThirdElementOffTheSolvedMappingIsRejectedByName() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = threeSpreadElements(observed: [(384, 216), (3_456, 1_944), (2_120, 1_080)])
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("A 200px redundancy residual must be rejected, not solved as \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("'Search field'"), message)
            XCTAssertTrue(message.contains("predicts it at observed_x=1920.0"), message)
            XCTAssertTrue(message.contains("reported at 2120.0"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - (e) The origin residual -- the crop check

    /// The highest-value rejection on this route, for the same reason it is
    /// on the marker route: a crop that preserves the display's aspect ratio
    /// produces an image whose dimensions are mathematically
    /// indistinguishable from an honest downsample's. The element SPACING
    /// survives a crop untouched, so the scale solve here returns the
    /// correct 3840x2160 and every dimension-based guard is satisfied. Only
    /// the origin moves: both elements sit 100px closer to the image's own
    /// (0,0) than the display's own coordinates say they should.
    func testACroppedCaptureIsCaughtByTheCorrespondenceOriginResidual() {
        let display = screen(width: 3_840, height: 2_160)
        // The screenshot begins 100px right of, and 100px below, the
        // display's top-left corner: every element's observed centre is
        // shifted by exactly that offset, and nothing else changes.
        let pairs = [
            element("Back", at: 384, 216, seenAt: 284, 116),
            element("Send", at: 3_456, 1_944, seenAt: 3_356, 1_844)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("A cropped capture must be caught by the origin residual, not accepted as \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("implied left edge"), message)
            XCTAssertTrue(message.contains("cropped"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// The element route's own 40px-crop-at-5K regression pin, mirroring the
    /// marker route's. Two elements read exactly, from a native 5120x2880
    /// capture cropped 40px left / 22.5px top: the separation (and so the
    /// scale) is untouched, and the origin residual of -40px is the only
    /// evidence. Under the old shared 1% tolerance the horizontal budget was
    /// 51.2px and the vertical 28.8px, so BOTH axes waved the crop through
    /// and the space registered; the read-noise budget (12.8px at 5120)
    /// rejects it on the first axis solved.
    func testAFortyPixelCropAtFiveKIsCaughtByTheCorrespondenceOriginResidualToo() {
        let display = screen(width: 5_120, height: 2_880)
        let pairs = [
            element("Back", at: 512, 288, seenAt: 472, 265.5),
            element("Send", at: 4_608, 2_592, seenAt: 4_568, 2_569.5)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("A 40px crop at 5K must be rejected on the element route as well, not registered as \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("implied left edge"), message)
            XCTAssertTrue(message.contains("cropped"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// The off-baseline FIT residual is read-noise-gated too: a third
    /// element 20px off the line the baseline pair defines at 5K is a
    /// misidentified or misread fiducial, not measurement noise -- one
    /// read's distance from a line through two other reads never
    /// legitimately reaches 1% of a 5K image, and the old 51.2px budget let
    /// exactly this size of mismatch smear a wrong element into a
    /// registered space. 20px exceeds the 12.8px read-noise budget and must
    /// reject by name.
    func testATwentyPixelOffBaselineResidualAtFiveKIsNowRejected() {
        let display = screen(width: 5_120, height: 2_880)
        let pairs = [
            element("Back", at: 512, 288, seenAt: 512, 288),
            element("Send", at: 4_608, 2_592, seenAt: 4_608, 2_592),
            element("Search field", at: 2_560, 1_440, seenAt: 2_580, 1_440)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("A 20px off-baseline residual at 5K must be rejected, not absorbed into \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("'Search field'"), message)
            XCTAssertTrue(message.contains("does not fit the horizontal mapping"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - The shared tail: one implementation, two entry points

    /// PROVES THE TAIL IS GENUINELY SHARED, not copied: the within-noise
    /// clamp -- a behaviour that exists nowhere else in this file -- is
    /// observable through BOTH entry points from equivalent readings.
    ///
    /// Both fixtures describe a NATIVE capture read a fraction of a pixel
    /// high on the vertical axis, which puts the averaged uniform scale at
    /// 1.00029. Without the clamp both routes would snap to 3841x2161 and
    /// then reject their own result as "an upscale that no capture pipeline
    /// produces", telling the caller to re-measure a reading that was
    /// already well inside the solver's 4px noise floor. A second copy of
    /// the tail would let one route keep the clamp while the other lost it,
    /// which is precisely the class of divergence that produced the
    /// calibration-accepts-what-drawing-rejects bug this file exists to fix.
    func testTheWithinNoiseClampIsSharedByBothCalibrationRoutes() {
        let display = screen(width: 3_840, height: 2_160)

        let markerObservations = [
            Observation(label: "TL", x: 384, y: 216),
            Observation(label: "TR", x: 3_456, y: 216),
            Observation(label: "BL", x: 384, y: 1_945),
            Observation(label: "BR", x: 3_456, y: 1_945)
        ]
        switch ScreenshotCalibration.solve(observations: markerObservations, screen: display) {
        case .failure(let message):
            XCTFail("The marker route must clamp a within-noise overshoot to native: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840)
            XCTAssertEqual(solution.heightPx, 2_160)
        }

        let pairs = [
            element("Back", at: 384, 216, seenAt: 384, 216),
            element("Send", at: 3_456, 1_944, seenAt: 3_456, 1_945)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .failure(let message):
            XCTFail("The correspondence route must clamp the same within-noise overshoot: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.widthPx, 3_840,
                           "the shared clamp must resolve a native capture read slightly high to native")
            XCTAssertEqual(solution.heightPx, 2_160)
            XCTAssertEqual(solution.residuals.heightSnapPx, -1.25, accuracy: 1e-9)
        }
    }

    /// The second half of the shared-tail proof, on the REJECTION side: a
    /// reading describing a square image against a 16:9 display is dragged
    /// to the same nearest display-consistent width (1389px) by both routes,
    /// through the same snap-distance guard, with the same sentence.
    ///
    /// It also pins what the sharing must NOT flatten: each route's
    /// rejection still names ITS OWN fiducials. Telling a caller who
    /// supplied UI elements to re-check where "the calibration markers were
    /// painted" names four things that caller never had, so the shared tail
    /// takes its nouns from the route while keeping one copy of the maths.
    func testTheNotAUniformDownsampleRejectionReachesBothRoutesWithRouteSpecificRemedies() {
        let display = screen(width: 3_840, height: 2_160)

        let markerObservations = exactObservations(trueWidth: 1_000, trueHeight: 1_000, scale: 1)
        switch ScreenshotCalibration.solve(observations: markerObservations, screen: display) {
        case .success:
            XCTFail("A square reading against a 16:9 display must be rejected on the marker route.")
        case .failure(let message):
            XCTAssertTrue(message.contains("not close to any uniform downsample"), message)
            XCTAssertTrue(message.contains("the nearest display-consistent width is 1389 px"), message)
            XCTAssertTrue(message.contains("confirm the calibration markers were painted on"), message)
        }

        // The same square reading expressed as correspondences: two elements
        // at the display's own 0.1/0.9 insets, observed where they would
        // land in a 1000x1000 image of that display.
        let pairs = [
            element("Back", at: 384, 216, seenAt: 100, 100),
            element("Send", at: 3_456, 1_944, seenAt: 900, 900)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success:
            XCTFail("A square reading against a 16:9 display must be rejected on the correspondence route too.")
        case .failure(let message):
            XCTAssertTrue(message.contains("not close to any uniform downsample"), message)
            XCTAssertTrue(message.contains("the nearest display-consistent width is 1389 px"), message)
            XCTAssertTrue(message.contains("confirm the fiducial elements were resolved on"), message)
            XCTAssertFalse(message.contains("marker"), message)
        }
    }

    /// The shared tail's `Int`-conversion guard protects the new route too.
    /// `Int(someDouble)` TRAPS rather than returning nil above `Int.max`, and
    /// a trap here kills the whole MCP server process mid-request. Every
    /// correspondence check before it uses a purely RELATIVE tolerance, so
    /// this absurd-but-perfectly-self-consistent reading satisfies the
    /// baseline gate, the scale solve and the origin residual and arrives at
    /// the conversion intact -- exactly as the marker route's own fixture
    /// does.
    func testAnAbsurdlyLargeCorrespondenceReadingIsRejectedInsteadOfTrappingTheProcess() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: 384, 216, seenAt: 3.84e18, 2.16e18),
            element("Send", at: 3_456, 1_944, seenAt: 3.456e19, 1.944e19)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("An absurdly large correspondence reading must be rejected: got \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("The element correspondences solve to an absurdly large image"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    /// The no-upscale half of the shared tail, reached through the
    /// correspondence route: elements observed at exactly twice their true
    /// separation describe an image larger than the display itself, which no
    /// capture pipeline produces. The reading is a perfect uniform scale, so
    /// the snap distance is zero and this is the guard that actually fires --
    /// and it fires with the ELEMENT vocabulary, not the marker one.
    func testACorrespondenceSolveLargerThanTheDisplayIsRejectedAsAnImplausibleUpscale() {
        let display = screen(width: 3_840, height: 2_160)
        let pairs = [
            element("Back", at: 384, 216, seenAt: 768, 432),
            element("Send", at: 3_456, 1_944, seenAt: 6_912, 3_888)
        ]
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: display) {
        case .success(let solution):
            XCTFail("A solved size larger than the display must be rejected: got \(solution.widthPx)x\(solution.heightPx).")
        case .failure(let message):
            XCTAssertTrue(message.contains("LARGER than display"), message)
            XCTAssertTrue(message.contains("the elements' observed centres were likely misread"), message)
            XCTAssertTrue(message.contains("Nothing was registered"), message)
        }
    }

    // MARK: - The marker route's own redundancy residual

    /// The marker route reports the worse of its two pair disagreements
    /// under the route-neutral `worstRedundancyResidualPx`, so a payload
    /// builder can render one "how far did independent measurements of the
    /// same thing disagree" figure without branching on which route produced
    /// the solution. This fixture's markers disagree by 1px horizontally and
    /// 3px vertically; the worse of the two is what a caller sees.
    func testTheMarkerRouteReportsTheWorseOfItsPairDisagreementsAsItsRedundancyResidual() {
        let display = screen(width: 3_840, height: 2_160)
        let observations = [
            Observation(label: "TL", x: 386, y: 214),
            Observation(label: "TR", x: 3_458, y: 217),
            Observation(label: "BL", x: 386, y: 1_945),
            Observation(label: "BR", x: 3_457, y: 1_942)
        ]
        switch ScreenshotCalibration.solve(observations: observations, screen: display) {
        case .failure(let message):
            XCTFail("This is the marker route's existing 2px-noise fixture and must still solve: \(message)")
        case .success(let solution):
            XCTAssertEqual(solution.residuals.horizontalPairDisagreement, 1, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.verticalPairDisagreement, 3, accuracy: 1e-9)
            XCTAssertEqual(solution.residuals.worstRedundancyResidualPx, 3, accuracy: 1e-9)
        }
    }
}
