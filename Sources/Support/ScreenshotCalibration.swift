import Foundation

/// Solves the "what are the true pixel dimensions of the screenshot I am
/// looking at?" problem BY MEASUREMENT instead of by declaration.
///
/// An agent cannot generally learn the true pixel dimensions of a screenshot
/// it is looking at: the capture tool that produced it may not report them,
/// and the client showing the image to the model may have downsampled it
/// before the model ever saw a pixel. Every other coordinate-space guard in
/// this package (`ScreenshotGeometry`, `DrawRequest.coordinateTransform`'s
/// `screenshot_pixels` branch) takes the caller's DECLARED
/// `screenshot_width`/`screenshot_height` on faith and only checks that
/// declaration for INTERNAL consistency against the target display's aspect
/// ratio and size. That check is real and catches real mistakes, but it
/// cannot catch the one that matters most: a same-aspect WRONG declaration.
/// If an agent looking at a 1470x956 downsample of a 2940x1912 Retina display
/// simply guesses the display's native "2940x1912" because that is the
/// number `get_screens` reported, that guess passes `fullDisplayScale`'s
/// aspect check perfectly (it IS that display's aspect ratio), passes the
/// no-upscale check perfectly (it is not larger than the display), and then
/// misplaces every single coordinate that guess is used to transform by
/// EXACTLY the 2x scale error. Nothing downstream can detect this: the
/// numbers are entirely self-consistent, and self-consistency is all any
/// aspect-ratio-based guard can ever test.
///
/// The only way to learn the truth is to stop asking the agent to DECLARE
/// the image's dimensions and instead have it MEASURE them: paint four
/// fiducial markers at known NORMALIZED positions on the real display, ask
/// the agent to report where those markers appear in ITS OWN screenshot (in
/// that screenshot's own pixel coordinates, whatever they turn out to be),
/// and solve for the image's true dimensions from the observed spread
/// between the markers. A wrong guess about the image's size cannot survive
/// this: the markers' reported positions are ground truth about the image
/// the agent is actually looking at, not a number it read off a display
/// descriptor.
///
/// This file is the pure geometry half of that handshake -- the marker
/// layout and the solver that turns four observed points into a validated
/// `(widthPx, heightPx)` plus a scale factor into backing pixels. It holds NO
/// drawing code, no annotation types, and no MCP plumbing: the caller is
/// responsible for actually painting the markers (as ordinary annotations,
/// through the existing `draw_*` pipeline) and for collecting the agent's
/// reported observations. Keeping this half pure and platform-neutral is
/// what makes the solver's arithmetic -- the part most worth getting exactly
/// right, including its rejection thresholds -- directly unit-testable with
/// hand-built fixtures and no display, AppKit, or Win32 in play.
///
/// A SECOND ROUTE, THE SAME MATH: `solveCorrespondences` below solves the
/// very same `observed = scale * true + origin` model from fiducials
/// Chalkboard never painted -- UI elements of the TARGET APPLICATION, whose
/// true backing-pixel rects come from the Accessibility API. It exists
/// because the marker handshake above has one hard prerequisite that a real,
/// field-tested configuration failed to meet: Chalkboard's OWN pixels must
/// reach the caller's capture. Against one screen-control ("computer-use")
/// MCP tool they never did -- its screenshots were demonstrably of this same
/// local display (this machine's menu bar, Dock and wallpaper were all in
/// them) yet Chalkboard's fiducials never appeared, even with capture-debug
/// on, and that same tool returned its screenshots as inline image data with
/// no file path, closing the `screenshot_path` route too. Both measurement
/// routes shut at once leaves a bare `declared` assertion as the only
/// provenance, which is exactly the unverifiable guess this file was written
/// to eliminate. An element of the target app is immune to that failure: the
/// caller can see it precisely because the target app is the app its capture
/// tool was granted, and Chalkboard needs nothing of its own to be visible
/// to anyone.
///
/// BOTH ROUTES END IN THE SAME PRIVATE TAIL, `snapToDisplayConsistentSize`
/// -- shared deliberately rather than copied. That tail is what makes a
/// calibration produce a size the draw pipeline will actually ACCEPT, and a
/// second copy of it would reintroduce the precise round-trip bug this file
/// already had to fix once (see that helper's own doc comment).
enum ScreenshotCalibration {

    /// One fiducial mark, positioned in NORMALIZED display coordinates
    /// (0...1 on each axis) so the same four-marker definition works
    /// unchanged on every display regardless of its resolution: the caller
    /// converts `normalizedX`/`normalizedY` into that display's own backing
    /// pixels only when it actually paints the marker.
    struct Marker: Equatable {
        let label: String
        let normalizedX: Double
        let normalizedY: Double

        init(label: String, normalizedX: Double, normalizedY: Double) {
            self.label = label
            self.normalizedX = normalizedX
            self.normalizedY = normalizedY
        }
    }

    /// The inset fraction shared by every marker's near axis, and the
    /// complementary fraction for its far axis (`1 - markerInset`). Kept as
    /// named constants rather than the literals `0.1`/`0.9` scattered through
    /// the solver below, so the marker table and every place the solver
    /// divides by their spread (`markerOuterFraction - markerInsetFraction`)
    /// visibly derive from the same one number.
    private static let markerInsetFraction = 0.1
    private static let markerOuterFraction = 1.0 - markerInsetFraction

    /// The four markers, at 0.1/0.9 on each axis.
    ///
    /// WHY 0.1/0.9 AND NOT THE ACTUAL CORNERS: a mark at the very edge risks
    /// being clipped, anti-aliased against the boundary, or hidden under a
    /// menu bar / notch / taskbar, and a clipped mark's centre cannot be read
    /// accurately -- the whole solve depends on the agent reporting each
    /// marker's true centre. An inset pair still spans 80% of each axis,
    /// which is ample baseline for the scale solve below, and the origin-
    /// residual check (see `solve(observations:screen:)`) recovers the true
    /// edges analytically anyway, so nothing is lost by not marking the
    /// corners directly. x=0.1/0.9 also keeps every marker well clear of a
    /// MacBook display's centred notch, which sits in the top-centre strip
    /// this layout never touches.
    ///
    /// THE PRECISION COST THIS BUYS: the solve below divides the observed
    /// marker spread by `markerOuterFraction - markerInsetFraction` (0.8), so
    /// every pixel of marker-reading error is amplified by 1/0.8 = 1.25x on
    /// its way into the solved dimension. This is the direct, unavoidable
    /// price of insetting instead of marking the true corners: a 2px misread
    /// of one marker does not cost the solve 2px, it costs 2.5px. The clipping
    /// argument above still stands -- a clipped corner marker cannot be read
    /// AT ALL, which is strictly worse than a clean marker read with 25% more
    /// amplified noise -- but the amplification is real and is exactly why
    /// `solve`'s snap-to-display-consistent-size step exists: it is what
    /// absorbs this amplified noise rather than asking every downstream check
    /// to individually budget for it.
    static let markers: [Marker] = [
        Marker(label: "TL", normalizedX: markerInsetFraction, normalizedY: markerInsetFraction),
        Marker(label: "TR", normalizedX: markerOuterFraction, normalizedY: markerInsetFraction),
        Marker(label: "BL", normalizedX: markerInsetFraction, normalizedY: markerOuterFraction),
        Marker(label: "BR", normalizedX: markerOuterFraction, normalizedY: markerOuterFraction)
    ]

    /// The four labels `markers` defines, in the order above. `solve` treats
    /// this as the exact required set: not a subset, not a superset.
    private static let requiredLabels = markers.map(\.label)

    /// Where the agent SAW one marker's centre, in ITS OWN screenshot's
    /// pixels -- ground truth about the image actually in front of the
    /// model, as opposed to a declared dimension that might be a guess.
    struct Observation: Equatable {
        let label: String
        let x: Double
        let y: Double

        init(label: String, x: Double, y: Double) {
            self.label = label
            self.x = x
            self.y = y
        }
    }

    /// One (true position, observed position) pair for the SECOND
    /// calibration route: an on-screen thing whose true position Chalkboard
    /// determined INDEPENDENTLY -- a UI element of the target application,
    /// resolved to display backing pixels through the Accessibility API --
    /// together with where the caller reports seeing that same thing in ITS
    /// OWN screenshot.
    ///
    /// WHY A UI ELEMENT MAKES A LEGITIMATE FIDUCIAL: the marker route's
    /// fiducials are trustworthy because this package PAINTED them at a
    /// position it chose. An element is trustworthy for the same reason
    /// turned inside out -- this package did not choose where it sits, but it
    /// can READ where it sits without asking the caller, and a fact
    /// Chalkboard establishes for itself is exactly what a fiducial has to
    /// be. What the caller supplies is only the OBSERVED half, which is the
    /// half that was always the caller's to report.
    ///
    /// THE PRECISION COST, WHICH IS REAL AND MUST BE STATED TO CALLERS: an
    /// element's Accessibility frame is its REPORTED frame, which can differ
    /// from its painted pixels by a few points of padding, inset or shadow.
    /// A correspondence is therefore typically slightly less precise than
    /// reading a purpose-drawn crosshair, and that imprecision lands in the
    /// scale divided by the elements' separation -- which is why
    /// `solveCorrespondences` gates on a long baseline, and why three or more
    /// widely separated elements are worth materially more than the
    /// two-element minimum.
    struct Correspondence: Equatable {
        /// The element's label, exactly as the caller named it. Used
        /// verbatim in every rejection below so a caller is told WHICH
        /// element was wrong instead of an array index it then has to count
        /// back to.
        let name: String
        /// The element's true centre, in the DISPLAY's own backing pixels
        /// (display-local, top-left origin -- the space
        /// `AccessibilityBackingRect` reports).
        let trueX: Double
        /// The vertical half of the element's true centre; see `trueX`.
        let trueY: Double
        /// Where the caller reports seeing that same centre, in ITS OWN
        /// screenshot's pixels -- whatever size that image turns out to be,
        /// which is the unknown this solve recovers.
        let observedX: Double
        /// The vertical half of the observed centre; see `observedX`.
        let observedY: Double

        init(name: String, trueX: Double, trueY: Double, observedX: Double, observedY: Double) {
            self.name = name
            self.trueX = trueX
            self.trueY = trueY
            self.observedX = observedX
            self.observedY = observedY
        }
    }

    /// Measurement-quality diagnostics reported alongside every successful
    /// `Solution`, so a caller can see HOW CLEAN the calibration was rather
    /// than only a bare pass/fail. All four values are expected to sit near
    /// zero for a clean, uncropped, accurately-read capture.
    struct Residuals: Equatable {
        /// The implied left edge of the image, extrapolated from the solved
        /// width and the TL/BL markers' mean x. Should be ~0 for an
        /// uncropped full-display capture; see the origin-residual check
        /// below for why a nonzero value here is the one signal that can
        /// catch a same-aspect-ratio crop.
        let originX: Double
        /// The implied top edge of the image, the same construction as
        /// `originX` along the vertical axis.
        let originY: Double
        /// The worse of `|x_TL - x_BL|` and `|x_TR - x_BR|`: how far apart
        /// the two vertically-paired markers' x-coordinates landed, even
        /// though both markers in each pair share the same normalized x and
        /// so should report (almost) the same observed x.
        let horizontalPairDisagreement: Double
        /// The worse of `|y_TL - y_TR|` and `|y_BL - y_BR|`, the same
        /// construction as `horizontalPairDisagreement` along the vertical
        /// axis.
        let verticalPairDisagreement: Double
        /// How far the DISPLAY-CONSISTENT snap (the shared
        /// `snapToDisplayConsistentSize` tail) moved
        /// the width away from the raw per-axis solve, signed as
        /// `snappedWidthPx - observedWidth`. Near zero for a clean reading;
        /// large only when the redundancy/origin checks already passed but
        /// the two axes still disagreed on scale, which is exactly the
        /// measurement noise the snap exists to absorb. Reported so a caller
        /// can see HOW FAR the measurement was moved, not just that the
        /// solve ultimately succeeded.
        let widthSnapPx: Double
        /// The vertical counterpart to `widthSnapPx`: `snappedHeightPx -
        /// observedHeight`.
        let heightSnapPx: Double
        /// The worst REDUNDANCY residual either axis carried: the largest
        /// disagreement between two independent measurements of the same
        /// underlying quantity that this solve was actually able to
        /// cross-check, in that axis's screenshot pixels.
        ///
        /// For the drawn-marker route that is
        /// `max(horizontalPairDisagreement, verticalPairDisagreement)` --
        /// two markers sharing a normalized coordinate ARE its redundancy.
        /// For the element-correspondence route it is the largest gap
        /// between a non-baseline element's PREDICTED and OBSERVED centre on
        /// either axis. Reported as ONE number because "how far did two
        /// measurements of the same thing disagree" is the single quality
        /// figure worth putting next to a calibration, and a caller
        /// rendering it should not have to know which route produced it.
        ///
        /// ZERO IS NOT ALWAYS "PERFECT": a correspondence solve with exactly
        /// two elements has no third, off-baseline element to check the fit
        /// against -- with two points per axis the fit is exact BY
        /// CONSTRUCTION -- so it reports 0 here because NOTHING WAS
        /// CROSS-CHECKED, not because the reading was flawless. A caller
        /// surfacing this value should say how many correspondences produced
        /// it, and recommend three or more.
        let worstRedundancyResidualPx: Double

        /// Spelled out rather than left to the memberwise initializer purely
        /// so `worstRedundancyResidualPx` can carry a default: hand-built
        /// fixtures elsewhere in this package construct `Residuals` with the
        /// six original fields to exercise what a CALLER does with a
        /// solution, and making them all restate a residual they do not care
        /// about would be noise, not safety.
        init(
            originX: Double,
            originY: Double,
            horizontalPairDisagreement: Double,
            verticalPairDisagreement: Double,
            widthSnapPx: Double,
            heightSnapPx: Double,
            worstRedundancyResidualPx: Double = 0
        ) {
            self.originX = originX
            self.originY = originY
            self.horizontalPairDisagreement = horizontalPairDisagreement
            self.verticalPairDisagreement = verticalPairDisagreement
            self.widthSnapPx = widthSnapPx
            self.heightSnapPx = heightSnapPx
            self.worstRedundancyResidualPx = worstRedundancyResidualPx
        }
    }

    /// A small, named x/y pair -- deliberately not `(x: Double, y: Double)`,
    /// so `Solution.scaleToBackingPx` reads as one value at every call site
    /// instead of an anonymous tuple whose field names a caller could get
    /// away with omitting.
    struct Scale2D: Equatable {
        let x: Double
        let y: Double
    }

    /// The validated result of one calibration solve: the screenshot's true
    /// pixel dimensions, the measurement-quality residuals that were within
    /// tolerance, and the per-axis scale that converts a coordinate measured
    /// on THIS screenshot into `screen`'s backing pixels (multiply by this,
    /// the same direction `DrawRequest.coordinateTransform`'s
    /// `screenshot_pixels` branch already uses for its own scale).
    struct Solution: Equatable {
        let widthPx: Int
        let heightPx: Int
        let residuals: Residuals
        let scaleToBackingPx: Scale2D
    }

    /// The floor under every relative tolerance below, in screenshot pixels.
    /// WHY A FLOOR AT ALL: a purely relative tolerance (e.g. "1% of the
    /// solved dimension") shrinks toward zero as the solved dimension
    /// shrinks, which would make calibration against a small or heavily
    /// downsampled screenshot fail on ordinary sub-pixel rendering/rounding
    /// noise that a larger image would absorb without comment. 4px is
    /// comfortably above the anti-aliasing/rounding noise a marker's
    /// measured centre can carry, while still being tight enough to catch a
    /// genuine misread on any screenshot size this tool will plausibly see.
    private static let minimumAbsoluteTolerancePx = 4.0

    /// The relative half of every tolerance below: 1% of the relevant solved
    /// span/dimension, so a large screenshot's proportionally larger
    /// measurement noise does not trip a guard sized for a small one.
    private static let relativeTolerance = 0.01

    private static func tolerance(for span: Double) -> Double {
        max(minimumAbsoluteTolerancePx, relativeTolerance * span)
    }

    /// Solves the true `(widthPx, heightPx)` of a screenshot from four
    /// marker observations, and validates the result against `screen`
    /// before returning it.
    ///
    /// Runs, in order, exactly the checks documented on each guard below:
    /// structural validation of the observation set, the per-axis spread
    /// solve, the cross-marker redundancy check, the origin-residual crop
    /// check, the snap to the nearest display-consistent size (with its own
    /// not-close-to-any-uniform-downsample rejection and positive-size
    /// check), and finally two display-plausibility checks (aspect ratio,
    /// then no-upscale) kept as belt-and-braces on the now-snapped result.
    /// Each rejection names, in prose, what was wrong, states that nothing
    /// was registered, and says the one concrete thing to re-check or
    /// re-measure -- an agent reading the message should be able to
    /// self-correct without guessing.
    ///
    /// Everything from the snap onward lives in `snapToDisplayConsistentSize`,
    /// shared verbatim with `solveCorrespondences(_:screen:)`: this route
    /// owns only how four painted markers become a raw per-axis measurement,
    /// never how that measurement becomes a size the draw pipeline accepts.
    static func solve(observations: [Observation], screen: ScreenInfo) -> DrawOutcome<Solution> {
        // MARK: (a) Structural validation of the observation set

        for observation in observations {
            guard requiredLabels.contains(observation.label) else {
                return .failure("Calibration observation has unknown marker label '\(observation.label)'; the only valid labels are \(requiredLabels.joined(separator: ", ")). Nothing was registered; re-check which fiducial marker this observation was measured from and relabel it, or drop it if it does not belong to this calibration pass.")
            }
        }
        for observation in observations {
            guard observation.x.isFinite, observation.y.isFinite else {
                return .failure("Calibration observation for marker '\(observation.label)' has a non-finite coordinate (x=\(observation.x), y=\(observation.y)). Nothing was registered; re-measure that marker's centre as finite pixel coordinates in the screenshot.")
            }
        }
        var countByLabel: [String: Int] = [:]
        for observation in observations {
            countByLabel[observation.label, default: 0] += 1
        }
        for label in requiredLabels {
            let count = countByLabel[label] ?? 0
            guard count <= 1 else {
                return .failure("Calibration observation for marker '\(label)' was supplied \(count) times; each of \(requiredLabels.joined(separator: ", ")) must be reported exactly once. Nothing was registered; remove the duplicate reading for '\(label)' and confirm each of the other three markers was measured separately.")
            }
        }
        let missingLabels = requiredLabels.filter { (countByLabel[$0] ?? 0) == 0 }
        guard missingLabels.isEmpty else {
            return .failure("Calibration is missing marker(s) \(missingLabels.joined(separator: ", ")); all four of \(requiredLabels.joined(separator: ", ")) are required to solve for the image's true dimensions. Nothing was registered; report the observed pixel position of \(missingLabels.count == 1 ? "the missing marker" : "each missing marker") and retry.")
        }

        func observation(labeled label: String) -> Observation {
            // Safe: `missingLabels` above already proved every required
            // label is present exactly once.
            observations.first(where: { $0.label == label })!
        }
        let topLeft = observation(labeled: "TL")
        let topRight = observation(labeled: "TR")
        let bottomLeft = observation(labeled: "BL")
        let bottomRight = observation(labeled: "BR")

        // MARK: (b) Solve per axis from the observed marker spread

        let normalizedSpan = markerOuterFraction - markerInsetFraction
        let observedWidth = ((topRight.x + bottomRight.x) / 2 - (topLeft.x + bottomLeft.x) / 2) / normalizedSpan
        let observedHeight = ((bottomLeft.y + bottomRight.y) / 2 - (topLeft.y + topRight.y) / 2) / normalizedSpan

        guard observedWidth.isFinite, observedWidth > 0 else {
            return .failure("The solved image width (\(observedWidth)) is non-finite or not positive: TR and BR were expected to sit to the RIGHT of TL and BL in the reported pixel coordinates, but their observed spread says otherwise. Nothing was registered; check whether the TL/TR (or BL/BR) markers were transposed or mislabelled and re-measure.")
        }
        guard observedHeight.isFinite, observedHeight > 0 else {
            return .failure("The solved image height (\(observedHeight)) is non-finite or not positive: BL and BR were expected to sit BELOW TL and TR in the reported pixel coordinates, but their observed spread says otherwise. Nothing was registered; check whether the TL/BL (or TR/BR) markers were transposed or mislabelled and re-measure.")
        }

        // MARK: (c) Redundancy check

        // TL and BL share a normalized x (both `markerInsetFraction`), so
        // their OBSERVED x values must agree; likewise TR/BR share the far
        // x, and TL/TR and BL/BR each share a normalized y. This is the
        // entire reason four markers are used instead of two diagonal ones:
        // two markers (say TL and BR alone) always "solve" a width and
        // height with zero residual, because there is no second observation
        // of either axis to disagree with them -- a mislabelled or
        // misread diagonal pair is mathematically invisible to a two-marker
        // solve. With all four markers, each axis is measured TWICE by two
        // independent markers, and comparing those two measurements is what
        // actually catches a bad reading.
        let leftPairDisagreement = abs(topLeft.x - bottomLeft.x)
        let rightPairDisagreement = abs(topRight.x - bottomRight.x)
        let horizontalPairDisagreement = max(leftPairDisagreement, rightPairDisagreement)
        let topPairDisagreement = abs(topLeft.y - topRight.y)
        let bottomPairDisagreement = abs(bottomLeft.y - bottomRight.y)
        let verticalPairDisagreement = max(topPairDisagreement, bottomPairDisagreement)

        let horizontalRedundancyTolerance = tolerance(for: observedWidth)
        guard horizontalPairDisagreement <= horizontalRedundancyTolerance else {
            let offendingPair = leftPairDisagreement >= rightPairDisagreement ? "TL/BL" : "TR/BR"
            return .failure("Marker pair \(offendingPair) disagree on their observed x by \(horizontalPairDisagreement) px, exceeding the \(horizontalRedundancyTolerance) px tolerance for a ~\(observedWidth) px-wide image. These two markers share the same normalized x, so their observed x should match closely. Nothing was registered; re-check the \(offendingPair) markers' centres and re-measure.")
        }
        let verticalRedundancyTolerance = tolerance(for: observedHeight)
        guard verticalPairDisagreement <= verticalRedundancyTolerance else {
            let offendingPair = topPairDisagreement >= bottomPairDisagreement ? "TL/TR" : "BL/BR"
            return .failure("Marker pair \(offendingPair) disagree on their observed y by \(verticalPairDisagreement) px, exceeding the \(verticalRedundancyTolerance) px tolerance for a ~\(observedHeight) px-tall image. These two markers share the same normalized y, so their observed y should match closely. Nothing was registered; re-check the \(offendingPair) markers' centres and re-measure.")
        }

        // MARK: (d) Origin residual check

        // From the solved width, the implied left edge of the image is
        // mean(x of TL, BL) minus the inset fraction's share of that width;
        // for an UNCROPPED full-display capture that implied edge must sit
        // at ~0, because the markers were painted relative to the display's
        // own edges and the screenshot is assumed to show the whole thing.
        //
        // WHY THIS MATTERS: the aspect-ratio guard below cannot detect a
        // crop that happens to preserve the display's aspect ratio --
        // shrinking every edge by the same fraction produces an image whose
        // WIDTH/HEIGHT ratio is mathematically identical to the full
        // display's, which is exactly what an honest downsample also
        // produces. Dimensions alone cannot tell those two apart. But a
        // crop, unlike a downsample, also SHIFTS the markers away from the
        // image's own (0,0) origin -- the markers keep their true spacing
        // (so the width/height solve above still recovers the correct
        // dimensions), yet the implied edge no longer lands at zero. This
        // residual is the only signal in this solver that can tell a
        // same-aspect crop apart from a genuine full-display downsample.
        let originX = (topLeft.x + bottomLeft.x) / 2 - markerInsetFraction * observedWidth
        let originY = (topLeft.y + topRight.y) / 2 - markerInsetFraction * observedHeight

        let originXTolerance = tolerance(for: observedWidth)
        guard abs(originX) <= originXTolerance else {
            return .failure("The implied left edge of the image is \(originX) px away from zero, exceeding the \(originXTolerance) px tolerance for a ~\(observedWidth) px-wide image. Nothing was registered; the image appears cropped or is not a full-display capture -- re-capture an uncropped screenshot of the whole display and retry.")
        }
        let originYTolerance = tolerance(for: observedHeight)
        guard abs(originY) <= originYTolerance else {
            return .failure("The implied top edge of the image is \(originY) px away from zero, exceeding the \(originYTolerance) px tolerance for a ~\(observedHeight) px-tall image. Nothing was registered; the image appears cropped or is not a full-display capture -- re-capture an uncropped screenshot of the whole display and retry.")
        }

        // MARK: (e) Snap to the nearest display-consistent size, and
        // validate it against the display -- the SHARED TAIL
        //
        // Everything from here on is identical for every calibration route
        // and lives in ONE place: see `snapToDisplayConsistentSize` for the
        // clamp, the snap, the Int-magnitude guard, the snap-distance
        // rejections and the `ScreenshotGeometry` validation, and for the
        // round-trip bug that makes copying it rather than calling it a
        // mistake this file has already paid for once.
        let snapped: SnappedSize
        switch snapToDisplayConsistentSize(
            observedWidth: observedWidth,
            observedHeight: observedHeight,
            screen: screen,
            vocabulary: .drawnMarkers
        ) {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            snapped = value
        }

        // MARK: (g) Success: report residuals alongside the solved size

        let residuals = Residuals(
            originX: originX,
            originY: originY,
            horizontalPairDisagreement: horizontalPairDisagreement,
            verticalPairDisagreement: verticalPairDisagreement,
            widthSnapPx: snapped.widthSnapPx,
            heightSnapPx: snapped.heightSnapPx,
            // The two pair disagreements ARE this route's redundancy: each
            // is one axis measured twice by two markers that share a
            // normalized coordinate. Reporting the worse of them under the
            // route-neutral name lets a payload builder render "how far did
            // independent measurements of the same thing disagree" without
            // knowing which route it is looking at.
            worstRedundancyResidualPx: max(horizontalPairDisagreement, verticalPairDisagreement)
        )
        let scaleToBackingPx = Scale2D(
            x: Double(screen.widthPx) / Double(snapped.widthPx),
            y: Double(screen.heightPx) / Double(snapped.heightPx)
        )
        return .success(Solution(
            widthPx: snapped.widthPx,
            heightPx: snapped.heightPx,
            residuals: residuals,
            scaleToBackingPx: scaleToBackingPx
        ))
    }

    // MARK: - Route 2: element correspondences

    /// The minimum TRUE separation the two furthest-apart fiducial elements
    /// must span on an axis, as a fraction of the display's own size on that
    /// axis, before this solver will trust the scale they imply.
    ///
    /// WHY A GATE AT ALL: the solve divides the elements' OBSERVED
    /// separation by their TRUE separation, and then multiplies the
    /// resulting scale straight back up by the display's full size to get
    /// the screenshot's dimension. Compose those two steps and the error in
    /// the solved dimension is the reading error in an observed centre times
    /// (display size / baseline). Two elements a tenth of the display apart
    /// therefore turn a 2 px misread into a 20 px error in the answer. This
    /// is exactly the reasoning behind the drawn markers sitting at 0.1/0.9
    /// of the display rather than side by side (see `markers`), stated here
    /// as an enforced GATE for one reason: with markers this package chooses
    /// the positions and can simply guarantee a long baseline, whereas here
    /// the CALLER picks the elements and can pick two neighbouring toolbar
    /// buttons without any idea what that costs the solve.
    ///
    /// 0.25 is deliberately permissive rather than tight: it bounds the
    /// amplification at 4x, which the tolerances below can still absorb,
    /// while leaving a caller free to calibrate from two opposite corners of
    /// a window that occupies only half the display -- a completely
    /// reasonable thing to have on screen.
    private static let minimumBaselineFraction = 0.25

    /// The same number as a PERCENTAGE, for prose. `MCPToolCatalog` states
    /// this gate to the agent as "at least 25% of the display's size on that
    /// axis", so the rejection has to say "25%" too -- an agent that read the
    /// tool description and then hit a rejection reading "0.25 of that
    /// display's width" has to work out for itself that those are the same
    /// rule. Derived from the constant above rather than typed out, so the
    /// two can never disagree.
    private static var minimumBaselinePercentText: String {
        "\(Int((minimumBaselineFraction * 100).rounded()))%"
    }

    /// Everything the per-axis correspondence solve needs to do its work on
    /// EITHER axis: how to read a correspondence's true and observed value,
    /// how big the display is along that axis, and the prose fragments its
    /// rejections need in order to describe that axis in the caller's own
    /// vocabulary.
    ///
    /// WHY KEY PATHS INSTEAD OF TWO HAND-WRITTEN COPIES: the baseline gate,
    /// the scale solve, the redundancy check and the origin residual are the
    /// same four steps on x as on y. Writing them twice is precisely how two
    /// axes drift apart -- one copy gets a fix or a tightened tolerance the
    /// other never does -- and this file has already paid once for a
    /// duplicated block of arithmetic (see `snapToDisplayConsistentSize`).
    private struct CorrespondenceAxis {
        let trueValue: KeyPath<Correspondence, Double>
        let observedValue: KeyPath<Correspondence, Double>
        /// The display's own size along this axis, in backing pixels: both
        /// the baseline gate's yardstick and the multiplier that turns a
        /// solved scale into the screenshot's size on this axis.
        let displaySizePx: Double
        /// The argument the caller supplied, named exactly as the tool takes
        /// it (`observed_x` / `observed_y`), so a rejection points at a key
        /// the caller can find in its own request.
        let observedArgumentName: String
        /// "horizontal" / "vertical".
        let adjective: String
        /// "horizontally" / "vertically".
        let adverb: String
        /// "width" / "height".
        let dimensionName: String
        /// "wide" / "tall", for "a ~1920 px-wide image".
        let sizeAdjective: String
        /// "left edge" / "top edge", for the origin residual.
        let edgeName: String
        /// A concrete, axis-appropriate example of two far-apart elements,
        /// so the baseline gate's fix is something a caller can act on
        /// without inventing its own interpretation of "far apart".
        let farApartExample: String
    }

    private static func horizontalAxis(of screen: ScreenInfo) -> CorrespondenceAxis {
        CorrespondenceAxis(
            trueValue: \Correspondence.trueX,
            observedValue: \Correspondence.observedX,
            displaySizePx: Double(screen.widthPx),
            observedArgumentName: "observed_x",
            adjective: "horizontal",
            adverb: "horizontally",
            dimensionName: "width",
            sizeAdjective: "wide",
            edgeName: "left edge",
            farApartExample: "a toolbar item at one end of the window and one at the other end"
        )
    }

    private static func verticalAxis(of screen: ScreenInfo) -> CorrespondenceAxis {
        CorrespondenceAxis(
            trueValue: \Correspondence.trueY,
            observedValue: \Correspondence.observedY,
            displaySizePx: Double(screen.heightPx),
            observedArgumentName: "observed_y",
            adjective: "vertical",
            adverb: "vertically",
            dimensionName: "height",
            sizeAdjective: "tall",
            edgeName: "top edge",
            farApartExample: "a toolbar item near the top of the window and a status-bar item near the bottom"
        )
    }

    /// One axis's accepted fit: the scale, the origin residual that was
    /// found to be within tolerance, the screenshot span that scale implies,
    /// and the worst redundancy residual any off-baseline correspondence
    /// carried (0 when there was none to check).
    private struct AxisFit {
        let scale: Double
        let origin: Double
        /// `scale * displaySizePx` -- this axis's contribution to the raw
        /// per-axis solve the shared tail then snaps.
        let observedSpan: Double
        let worstRedundancyResidual: Double
    }

    /// Solves ONE axis of the `observed = scale * true + origin` model from
    /// the supplied correspondences: baseline gate, scale, redundancy check,
    /// origin residual.
    ///
    /// THE BASELINE PAIR IS THE WIDEST TRUE PAIR, which for a single axis is
    /// simply the minimum and maximum true value -- no pairwise search is
    /// needed, and using the widest pair rather than, say, the first two
    /// minimises the error amplification described on
    /// `minimumBaselineFraction`.
    ///
    /// THE REDUNDANCY CHECK PREDICTS FROM THE BASELINE PAIR'S OWN ORIGIN,
    /// not from the mean origin computed afterwards. This is deliberate: a
    /// mean origin absorbs a fraction of a bad element's error into itself
    /// and correspondingly shrinks that element's apparent residual, which
    /// is the difference between catching a mismatched label and quietly
    /// smearing it across every element. Anchoring the prediction on the two
    /// baseline points makes the residual of every OTHER element an honest
    /// distance from the line those two define.
    private static func solveAxis(
        _ pairs: [Correspondence], axis: CorrespondenceAxis, screen: ScreenInfo
    ) -> DrawOutcome<AxisFit> {
        // Safe: the caller has already rejected fewer than two
        // correspondences, so `pairs` is non-empty and these indices exist.
        var lowestIndex = pairs.startIndex
        var highestIndex = pairs.startIndex
        for index in pairs.indices {
            if pairs[index][keyPath: axis.trueValue] < pairs[lowestIndex][keyPath: axis.trueValue] {
                lowestIndex = index
            }
            // `>=`, not `>`, ON PURPOSE. When every true value on this axis
            // TIES -- two elements stacked in the same column, which is
            // exactly the mistake the baseline gate below exists to catch --
            // a strict `>` leaves `highestIndex` equal to `lowestIndex`, and
            // the rejection then names the SAME element twice ("the two
            // elements furthest apart horizontally -- 'Recents' and
            // 'Recents'"), telling the caller nothing about which pair to
            // spread apart. Observed live against Finder's sidebar. Taking
            // the LAST of a tied maximum keeps the two names distinct; the
            // baseline is 0 either way, so the gate fires identically.
            if pairs[index][keyPath: axis.trueValue] >= pairs[highestIndex][keyPath: axis.trueValue] {
                highestIndex = index
            }
        }
        let lowest = pairs[lowestIndex]
        let highest = pairs[highestIndex]

        // MARK: (b) Baseline gate

        let baseline = highest[keyPath: axis.trueValue] - lowest[keyPath: axis.trueValue]
        let requiredBaseline = minimumBaselineFraction * axis.displaySizePx
        guard baseline >= requiredBaseline else {
            return .failure("The two elements furthest apart \(axis.adverb) -- '\(lowest.name)' and '\(highest.name)' -- are only \(baseline) backing px apart on display \(screen.id), short of the \(requiredBaseline) px this solve requires (\(minimumBaselinePercentText) of that display's \(axis.dimensionName), which is \(axis.displaySizePx) px). Nothing was registered; the solve divides the elements' observed separation by their true separation and then scales the result back up by the whole display, so a short baseline multiplies every pixel of reading error in an observed centre by (display \(axis.dimensionName) / baseline) -- the same reason the drawn calibration markers sit at opposite tenths of the display rather than next to each other. Pick elements far apart \(axis.adverb) -- opposite corners of the window, or \(axis.farApartExample) -- and retry.")
        }

        // MARK: (c) Scale from the widest pair

        let observedSeparation = highest[keyPath: axis.observedValue] - lowest[keyPath: axis.observedValue]
        let scale = observedSeparation / baseline
        guard scale.isFinite, scale > 0 else {
            return .failure("Elements '\(lowest.name)' and '\(highest.name)' sit \(baseline) backing px apart \(axis.adverb) on display \(screen.id) ('\(lowest.name)' at \(lowest[keyPath: axis.trueValue]), '\(highest.name)' at \(highest[keyPath: axis.trueValue])), but their reported \(axis.observedArgumentName) values (\(lowest[keyPath: axis.observedValue]) and \(highest[keyPath: axis.observedValue])) give a \(axis.adjective) scale of \(scale), which is not a positive finite number. Nothing was registered; the observed order runs backwards relative to the true order, which means the labels and the observed points were mismatched -- confirm that each element's \(axis.observedArgumentName) is the position of the element reported under THAT label, and retry.")
        }

        // Named here rather than at the end because both remaining checks
        // size their tolerance against it: this axis's span in the
        // screenshot's own pixels is what "1% of the dimension" is 1% OF.
        let observedSpan = scale * axis.displaySizePx
        let residualTolerance = tolerance(for: observedSpan)

        // MARK: (d) Redundancy check against every off-baseline element

        // With exactly two correspondences on an axis the fit is EXACT BY
        // CONSTRUCTION -- a straight line through two points has no residual
        // to inspect -- so there is nothing here to check and this loop does
        // not run. That is not a clean bill of health, it is an absence of
        // evidence, and it is the whole reason this route asks for three or
        // more widely separated elements and why the success payload should
        // say how many it actually got. Every element beyond the baseline
        // pair is a genuinely independent test of the same mapping, exactly
        // as the marker route's four fiducials measure each axis twice so
        // that a misread can disagree with something.
        let baselineOrigin = lowest[keyPath: axis.observedValue] - scale * lowest[keyPath: axis.trueValue]
        var worstRedundancyResidual = 0.0
        for index in pairs.indices where index != lowestIndex && index != highestIndex {
            let pair = pairs[index]
            let predicted = scale * pair[keyPath: axis.trueValue] + baselineOrigin
            let observed = pair[keyPath: axis.observedValue]
            let residual = abs(observed - predicted)
            // Written `residual <= tolerance` rather than `residual >
            // tolerance` on purpose: every floating-point comparison with
            // NaN is false, so this form REJECTS a NaN residual instead of
            // waving it through into a JSON payload that cannot encode it.
            guard residual <= residualTolerance else {
                return .failure("Element '\(pair.name)' does not fit the \(axis.adjective) mapping solved from '\(lowest.name)' and '\(highest.name)': that mapping predicts it at \(axis.observedArgumentName)=\(predicted) in the screenshot, but it was reported at \(observed) -- a gap of \(residual) px, exceeding the \(residualTolerance) px tolerance for a ~\(observedSpan) px-\(axis.sizeAdjective) image. Nothing was registered; one of these three elements' observed centres does not sit on the same straight-line mapping as the other two -- re-check which on-screen element each of '\(lowest.name)', '\(highest.name)' and '\(pair.name)' actually is, re-read that element's centre in the screenshot, and retry.")
            }
            worstRedundancyResidual = max(worstRedundancyResidual, residual)
        }

        // MARK: (e) Origin residual -- the crop check

        // The mean of (observed - scale * true) is where this axis's zero
        // lands in the screenshot. For an UNCROPPED full-display capture it
        // must be ~0: the elements' true coordinates are measured from the
        // display's own edge, so if the image starts at that same edge the
        // two zeros coincide.
        //
        // WHY THIS IS THE CHECK THAT EARNS ITS KEEP: a crop that preserves
        // the display's aspect ratio produces an image whose width/height
        // ratio is mathematically identical to a genuine downsample's, so no
        // dimension-based guard can ever tell the two apart. A crop does
        // shift every fiducial away from the image's own origin, and the
        // spacing between fiducials survives it untouched -- so the scale
        // solve above still returns the right answer while this residual is
        // the only thing that moves. Unlike the marker route, whose four
        // fiducials always sit at fixed 0.1/0.9 insets, elements can sit
        // ANYWHERE on the display, so the mean here is taken over points
        // spread across whatever region the caller chose: this route's
        // version of the check sees more of the image than the marker
        // route's does.
        let origin = pairs.reduce(0.0) {
            $0 + ($1[keyPath: axis.observedValue] - scale * $1[keyPath: axis.trueValue])
        } / Double(pairs.count)
        guard abs(origin) <= residualTolerance else {
            return .failure("The implied \(axis.edgeName) of the screenshot is \(origin) px away from zero, exceeding the \(residualTolerance) px tolerance for a ~\(observedSpan) px-\(axis.sizeAdjective) image. Nothing was registered; the elements' true positions are measured from display \(screen.id)'s own \(axis.edgeName), so a screenshot that starts there puts this residual at zero -- a nonzero one means the image is cropped, or is a window-only capture rather than a full-display one. Re-capture an uncropped screenshot of the whole display and retry.")
        }

        return .success(AxisFit(
            scale: scale,
            origin: origin,
            observedSpan: observedSpan,
            worstRedundancyResidual: worstRedundancyResidual
        ))
    }

    /// Solves the true `(widthPx, heightPx)` of a screenshot from
    /// correspondences between UI elements whose true positions Chalkboard
    /// resolved INDEPENDENTLY (through the Accessibility API) and where the
    /// caller reports seeing those same elements in its own screenshot.
    ///
    /// Model: `observed = scale * true + origin`, solved per axis, the two
    /// axes' scales then reconciled into ONE uniform scale by the shared
    /// tail -- because a genuine full-display capture is one uniform
    /// downsample of the display, never two independent per-axis ones.
    ///
    /// Runs, in order: structural validation of the correspondence set;
    /// then, per axis, the baseline gate, the scale solve, the redundancy
    /// check and the origin residual (all in `solveAxis`); then the SAME
    /// snap-and-validate tail `solve(observations:screen:)` ends in. Each
    /// rejection names what was wrong, states that nothing was registered,
    /// and gives the one concrete fix.
    ///
    /// THE AXES ARE SOLVED ONE AT A TIME, horizontal first, so a caller with
    /// a problem on one axis is told about THAT axis specifically instead of
    /// receiving a merged complaint it has to disentangle before it can act.
    ///
    /// EVERY `Double` THIS RETURNS IS FINITE, and not by luck: the
    /// structural check below rejects a non-finite input coordinate, each
    /// per-axis guard is spelled `value <= tolerance` so that a NaN fails it
    /// rather than passing it, and the shared tail refuses a non-finite
    /// snapped size outright. A residual therefore cannot reach a caller's
    /// JSON payload as a NaN or an infinity, which `JSONSerialization`
    /// cannot encode and which would turn a successful calibration into an
    /// unencodable response.
    static func solveCorrespondences(_ pairs: [Correspondence], screen: ScreenInfo) -> DrawOutcome<Solution> {
        // MARK: (a) Structural validation of the correspondence set

        guard pairs.count >= 2 else {
            return .failure("An element-anchored calibration needs at least 2 elements, but \(pairs.count) \(pairs.count == 1 ? "was" : "were") supplied: a single element fixes only WHERE the image sits, never HOW BIG it is -- a size can only come from the separation between two points. Nothing was registered; supply at least two elements that sit far apart on the display (three or more, widely separated, is better still: a two-element solve is exact by construction and so cannot be cross-checked at all) and retry.")
        }
        for pair in pairs {
            guard pair.trueX.isFinite, pair.trueY.isFinite else {
                return .failure("Element '\(pair.name)' resolved to a non-finite centre (x=\(pair.trueX), y=\(pair.trueY)) in display backing pixels. Nothing was registered; this is a broken element rect rather than a mistake in the request -- re-run the calibration, and if it recurs choose a different element in place of '\(pair.name)'.")
            }
            guard pair.observedX.isFinite, pair.observedY.isFinite else {
                return .failure("Element '\(pair.name)' has a non-finite observed centre (observed_x=\(pair.observedX), observed_y=\(pair.observedY)). Nothing was registered; re-measure where that element's centre sits in the screenshot and report it as finite pixel coordinates.")
            }
        }

        // MARK: (b)-(e) Solve each axis: baseline, scale, redundancy, origin

        let horizontal: AxisFit
        switch solveAxis(pairs, axis: horizontalAxis(of: screen), screen: screen) {
        case .failure(let message):
            return .failure(message)
        case .success(let fit):
            horizontal = fit
        }
        let vertical: AxisFit
        switch solveAxis(pairs, axis: verticalAxis(of: screen), screen: screen) {
        case .failure(let message):
            return .failure(message)
        case .success(let fit):
            vertical = fit
        }

        // MARK: (f)-(g) The screenshot's size, then the SHARED TAIL
        //
        // `observedSpan` is already `scale * screen.<dimension>Px`: the
        // solved scale applied to the display's own size IS the screenshot's
        // size in its own pixels. Everything after this point is the same
        // code path the marker route takes -- see
        // `snapToDisplayConsistentSize` for why that sharing is mandatory
        // rather than merely tidy.
        let snapped: SnappedSize
        switch snapToDisplayConsistentSize(
            observedWidth: horizontal.observedSpan,
            observedHeight: vertical.observedSpan,
            screen: screen,
            vocabulary: .elementCorrespondences
        ) {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            snapped = value
        }

        // MARK: (h) Success: report residuals alongside the solved size

        let residuals = Residuals(
            originX: horizontal.origin,
            originY: vertical.origin,
            // The marker route's "pair disagreement" IS its redundancy
            // residual: one axis measured twice by two markers that share a
            // normalized coordinate. This route asks the identical question
            // of a different fiducial set -- how far the elements that did
            // NOT define the baseline sat from the mapping the baseline
            // implies -- so the answer belongs in the same field rather than
            // in a parallel one that would force every payload builder to
            // branch on which route produced the solution.
            horizontalPairDisagreement: horizontal.worstRedundancyResidual,
            verticalPairDisagreement: vertical.worstRedundancyResidual,
            widthSnapPx: snapped.widthSnapPx,
            heightSnapPx: snapped.heightSnapPx,
            worstRedundancyResidualPx: max(horizontal.worstRedundancyResidual, vertical.worstRedundancyResidual)
        )
        let scaleToBackingPx = Scale2D(
            x: Double(screen.widthPx) / Double(snapped.widthPx),
            y: Double(screen.heightPx) / Double(snapped.heightPx)
        )
        return .success(Solution(
            widthPx: snapped.widthPx,
            heightPx: snapped.heightPx,
            residuals: residuals,
            scaleToBackingPx: scaleToBackingPx
        ))
    }


    // MARK: - The shared tail both calibration routes end in

    /// The route-neutral prose fragments the shared tail below needs in
    /// order to describe the caller's OWN fiducials in its rejections.
    ///
    /// WHY THIS TYPE EXISTS: the tail's arithmetic is identical for every
    /// route -- that is the whole point of sharing it -- but its error
    /// messages must not be. Telling a caller who supplied UI elements to
    /// "re-measure the four marker centres" names four things that caller
    /// never had, and this repo's rule is that a rejection states the ONE
    /// concrete fix. Parameterising the handful of noun phrases that differ
    /// keeps every message route-accurate while leaving exactly one copy of
    /// the maths -- and, just as importantly, leaves the marker route's
    /// existing wording byte-for-byte unchanged, because its fragments are
    /// the strings that were already there.
    private struct FiducialVocabulary {
        /// Sentence-initial subject for "<subject> solve to an absurdly
        /// large image".
        let solveSubject: String
        /// The remedy clause after "Nothing was registered; " when the solve
        /// is too large to convert to an `Int`.
        let absurdSizeRemedy: String
        /// The clause after "confirm " in "confirm <clause> -- and observed
        /// from -- display X, and re-measure."
        let fiducialPlacementClause: String
        /// The remedy clause when the snapped size is not positive.
        let positiveSizeRemedy: String
        /// The remedy clause when the solve describes an upscale.
        let misreadRemedy: String

        /// The four painted crosshairs of `solve(observations:screen:)`.
        /// These strings are the ORIGINAL wording of that route's
        /// rejections and are pinned by `ScreenshotCalibrationTests`; they
        /// must not be reworded here to accommodate a second route.
        static let drawnMarkers = FiducialVocabulary(
            solveSubject: "The marker observations",
            absurdSizeRemedy: "re-measure the four marker centres as pixel coordinates within the screenshot itself.",
            fiducialPlacementClause: "the calibration markers were painted on",
            positiveSizeRemedy: "re-measure all four marker centres.",
            misreadRemedy: "the markers were likely misread -- re-measure their centres."
        )

        /// The target application's UI elements, for
        /// `solveCorrespondences(_:screen:)`. Nothing was painted on this
        /// route, so nothing is described as painted: an element was
        /// RESOLVED on a display, and its centre was READ from the
        /// screenshot.
        static let elementCorrespondences = FiducialVocabulary(
            solveSubject: "The element correspondences",
            absurdSizeRemedy: "re-measure each element's observed centre as pixel coordinates within the screenshot itself.",
            fiducialPlacementClause: "the fiducial elements were resolved on",
            positiveSizeRemedy: "re-measure each element's observed centre.",
            misreadRemedy: "the elements' observed centres were likely misread -- re-measure them."
        )
    }

    /// What the shared tail returns: the validated integer size, plus how
    /// far the snap had to move each axis to get there. The snap distances
    /// travel back out because they are `Residuals` fields a caller sees --
    /// the tail is the only place that knows them, and recomputing them at
    /// the call site would be a second copy of the very arithmetic this
    /// helper exists to keep singular.
    private struct SnappedSize {
        let widthPx: Int
        let heightPx: Int
        let widthSnapPx: Double
        let heightSnapPx: Double
    }

    /// Turns a raw per-axis measurement of a screenshot's size into a
    /// validated, DISPLAY-CONSISTENT integer size -- the last thing every
    /// calibration route does, and the reason a calibrated space is usable
    /// by the draw pipeline at all.
    ///
    /// CALLED, NEVER COPIED. This helper is deliberately the single
    /// implementation shared by `solve(observations:screen:)` and
    /// `solveCorrespondences(_:screen:)`. A second copy would not merely be
    /// duplication: it would reintroduce a bug this file has already had to
    /// fix once, in which a solver accepted a size that
    /// `DrawRequest.coordinateTransform` then REFUSED, because the two ends
    /// of the round trip were checked against two different tolerances. The
    /// snap below is precisely what closes that gap, so any route that skips
    /// it -- or reimplements it slightly differently -- mints spaces the
    /// drawing pipeline will reject at the worst possible moment: after the
    /// caller has been told calibration succeeded.
    ///
    /// Runs, in order: the within-noise overshoot clamp, the uniform-scale
    /// snap, the `Int`-magnitude guard, the two snap-distance rejections,
    /// the positive-size check, and finally the two `ScreenshotGeometry`
    /// validations the draw pipeline itself uses.
    private static func snapToDisplayConsistentSize(
        observedWidth: Double,
        observedHeight: Double,
        screen: ScreenInfo,
        vocabulary: FiducialVocabulary
    ) -> DrawOutcome<SnappedSize> {
        // THE BUG THIS STEP REPLACES: rounding `observedWidth`/`observedHeight`
        // to the nearest integer INDEPENDENTLY treats the two axes as if they
        // were two unrelated numbers, when a full-display screenshot's true
        // pixel size essentially always IS one uniform downsample of the
        // display, applied to BOTH axes, each axis then separately rounded
        // to an integer by whatever resampler produced the image. A reading
        // with a couple of pixels of eyeballing noise concentrated on one
        // axis -- e.g. a 3840x2160 display measured as 3836.25 wide with the
        // height read cleanly -- used to round, axis by axis, to 3836x2160.
        // No real downsample of a 3840x2160 display can ever produce that
        // pair: 3836/3840 and 2160/2160 are two different scale factors.
        // `ScreenshotGeometry.fullDisplayScale`'s STRICT half-pixel-per-axis
        // tolerance -- the SAME helper `DrawRequest.coordinateTransform`'s
        // `screenshot_pixels` branch enforces on every draw call -- correctly
        // rejects that pair as not a plausible full-display capture. So this
        // solver used to mint a `ScreenshotSpace` that the draw pipeline then
        // refused to use: calibration and drawing disagreed about what a
        // "valid" screenshot size even looks like. Closing that disagreement
        // is the entire point of this step.
        //
        // THE FIX: estimate ONE scale from BOTH axes together, then apply
        // THAT SAME scale to both of `screen`'s own dimensions before
        // rounding. `sx` and `sy` are two independent measurements of the
        // SAME underlying downsample -- averaging them uses the redundancy
        // between the two axes instead of discarding one, exactly the same
        // "more than one measurement of the same thing" reasoning each
        // route's own redundancy check already relies on, just applied to
        // the scale factor rather than to a single fiducial. The result is,
        // BY CONSTRUCTION, an exact uniform downsample of `screen` with each
        // axis independently rounded -- precisely the shape
        // `ScreenshotGeometry.fullDisplayScale` was written to accept -- so
        // the final validation below can go back to enforcing ITS strict
        // tolerance instead of the looser `tolerance(for:)` measurement
        // budget this step has already spent.
        let sx = observedWidth / Double(screen.widthPx)
        let sy = observedHeight / Double(screen.heightPx)
        let uniformScale = (sx + sy) / 2

        // CLAMP A WITHIN-NOISE OVERSHOOT TO NATIVE, rather than letting it
        // round UP past the display and then be rejected below.
        //
        // WHY: a NATIVE-resolution capture -- scale exactly 1, and the single
        // commonest screenshot on macOS -- sits precisely on the no-upscale
        // boundary, whose tolerance is `1 + 1e-6`, i.e. effectively zero.
        // Fiducial centres are read BY EYE off an image, so roughly half of
        // all real readings of a native capture land a fraction of a pixel
        // HIGH; `uniformScale` then comes out at 1.0002-ish, the snap rounds
        // to `screen.widthPx + 1`, and `isPlausibleFullDisplayCapture` refuses
        // it as "an upscale that no capture pipeline produces". The fiducials
        // were read to well inside this file's own 4 px noise floor, the true
        // answer was under a pixel away, and the caller is told to re-measure
        // -- which fails again for the same reason, roughly half the time.
        //
        // No capture pipeline enlarges a screenshot, so an overshoot that is
        // SMALLER than the measurement noise already budgeted by the caller's
        // own checks is evidence of exactly one thing: a native capture read
        // slightly high. Clamping the scale to 1 resolves it to the only size
        // it can actually be. An overshoot LARGER than that budget is a
        // different animal -- a genuine mis-measurement or the wrong display
        // -- and is deliberately NOT clamped, so it still flows through to
        // the "LARGER than display" rejection below with its existing
        // wording.
        let widthOvershoot = observedWidth - Double(screen.widthPx)
        let heightOvershoot = observedHeight - Double(screen.heightPx)
        let overshootIsWithinMeasurementNoise =
            widthOvershoot <= tolerance(for: observedWidth)
            && heightOvershoot <= tolerance(for: observedHeight)
        let snapScale = overshootIsWithinMeasurementNoise ? min(uniformScale, 1.0) : uniformScale

        let snappedWidth = (snapScale * Double(screen.widthPx)).rounded()
        let snappedHeight = (snapScale * Double(screen.heightPx)).rounded()

        // BOUND BEFORE CONVERTING. `Int(someDouble)` TRAPS -- it does not
        // return nil or saturate -- when the value exceeds `Int.max`, and a
        // trap here kills the whole MCP server process mid-request, losing
        // every other annotation and leaving a marker-route calibration's
        // fiducials stranded on the user's screen because the session
        // cleanup never runs.
        //
        // Nothing upstream prevents it: `MCPArgument.double` rejects only
        // non-finite values, each route's parser checks only that the
        // reported coordinates are finite numbers, and every guard before
        // this point -- both routes' redundancy checks and origin residuals
        // -- uses a purely RELATIVE tolerance (1% of the solved span). A
        // self-consistent reading of, say, 4e19 px therefore satisfies all of
        // them and arrives here intact. The guards that WOULD have caught it
        // as absurd (the snap-distance checks just below, and the no-upscale
        // check at the end) all consume `widthPx`/`heightPx` and so run
        // strictly after the conversion that traps.
        //
        // The bound is deliberately far above any real display, so it fires
        // only for values that are genuinely not Int-representable; every
        // merely-too-large-but-representable reading still falls through to
        // those existing rejections and keeps their messages.
        let maximumRepresentablePx = 9.0e18
        guard snappedWidth.isFinite, snappedHeight.isFinite,
              abs(snappedWidth) < maximumRepresentablePx,
              abs(snappedHeight) < maximumRepresentablePx else {
            return .failure("\(vocabulary.solveSubject) solve to an absurdly large image (~\(observedWidth)x\(observedHeight) px), orders of magnitude larger than any screenshot of display \(screen.id) (\(screen.widthPx)x\(screen.heightPx) backing px) could be. Nothing was registered; \(vocabulary.absurdSizeRemedy)")
        }

        let widthPx = Int(snappedWidth)
        let heightPx = Int(snappedHeight)

        // A measurement that is not close to ANY uniform downsample of THIS
        // display cannot be explained away by rounding noise no matter how
        // the snap above divides the disagreement between the two axes --
        // e.g. fiducials describing a roughly square image against a 16:9
        // display, or a calibration read against the wrong display entirely.
        // Comparing the SNAPPED size back against the RAW per-axis solve
        // (`observedWidth`/`observedHeight`, from before this step ran) is
        // what catches that: a clean uniform-downsample reading snaps by a
        // small fraction of the measurement tolerance already budgeted
        // above, while a genuinely wrong-shaped reading gets dragged a long
        // way toward the nearest shape that fits `screen`, and that distance
        // is the signal. This is a REAL rejection, not bookkeeping: without
        // it, a same-aspect-mismatched reading would silently snap to a
        // plausible-looking but wrong size instead of being caught.
        let widthSnapPx = Double(widthPx) - observedWidth
        let widthSnapTolerance = tolerance(for: observedWidth)
        guard abs(widthSnapPx) <= widthSnapTolerance else {
            return .failure("The measured width (~\(observedWidth) px) is not close to any uniform downsample of display \(screen.id) (\(screen.widthPx)x\(screen.heightPx) backing px): the nearest display-consistent width is \(widthPx) px, \(abs(widthSnapPx)) px away, exceeding the \(widthSnapTolerance) px tolerance for a ~\(observedWidth) px-wide image. Nothing was registered; confirm \(vocabulary.fiducialPlacementClause) -- and observed from -- display \(screen.id), and re-measure.")
        }
        let heightSnapPx = Double(heightPx) - observedHeight
        let heightSnapTolerance = tolerance(for: observedHeight)
        guard abs(heightSnapPx) <= heightSnapTolerance else {
            return .failure("The measured height (~\(observedHeight) px) is not close to any uniform downsample of display \(screen.id) (\(screen.widthPx)x\(screen.heightPx) backing px): the nearest display-consistent height is \(heightPx) px, \(abs(heightSnapPx)) px away, exceeding the \(heightSnapTolerance) px tolerance for a ~\(observedHeight) px-tall image. Nothing was registered; confirm \(vocabulary.fiducialPlacementClause) -- and observed from -- display \(screen.id), and re-measure.")
        }

        guard widthPx > 0, heightPx > 0 else {
            return .failure("The solved image dimensions snapped to \(widthPx)x\(heightPx) px, which is not a valid positive size. Nothing was registered; \(vocabulary.positiveSizeRemedy)")
        }

        // Validate the snapped result against the target display, using the
        // SAME strict helpers the draw pipeline uses.
        //
        // These are `ScreenshotGeometry.fullDisplayScale` /
        // `.isPlausibleFullDisplayCapture` rather than the looser
        // `tolerance(for:)` measurement budget a previous pass once
        // substituted here. That substitution WAS the bug this file exists to
        // fix: it let the solver accept a pair that
        // `DrawRequest.coordinateTransform`'s own strict guard would then
        // refuse, because the two call sites were checked against two
        // different tolerances. After the snap above, `widthPx`/`heightPx`
        // are already an exact uniform downsample of `screen` with per-axis
        // integer rounding -- exactly the shape
        // `ScreenshotGeometry.fullDisplayScale` accepts -- so its strict
        // half-pixel-per-axis tolerance passes BY CONSTRUCTION for every
        // input that reaches this point. These two calls are kept anyway, as
        // belt-and-braces against a future change to the snap rather than
        // because either is expected to actually fire here, and -- just as
        // important -- because they are now the SAME shared helper
        // `DrawRequest.coordinateTransform` calls, so a caller can never
        // again see calibration accept a size that drawing rejects.
        guard ScreenshotGeometry.fullDisplayScale(
            screenshotWidth: Double(widthPx), screenshotHeight: Double(heightPx),
            screenWidth: Double(screen.widthPx), screenHeight: Double(screen.heightPx)
        ) != nil else {
            return .failure("The solved image size \(widthPx)x\(heightPx) px does not map uniformly onto display \(screen.id) (\(screen.widthPx)x\(screen.heightPx) backing px). Nothing was registered; confirm \(vocabulary.fiducialPlacementClause) -- and observed from -- display \(screen.id), and re-measure.")
        }
        guard ScreenshotGeometry.isPlausibleFullDisplayCapture(
            screenshotWidth: Double(widthPx), screenshotHeight: Double(heightPx),
            screenWidth: Double(screen.widthPx), screenHeight: Double(screen.heightPx)
        ) else {
            return .failure("The solved image size \(widthPx)x\(heightPx) px is LARGER than display \(screen.id)'s \(screen.widthPx)x\(screen.heightPx) backing px, which would require an upscale that no capture pipeline produces. Nothing was registered; \(vocabulary.misreadRemedy)")
        }

        return .success(SnappedSize(
            widthPx: widthPx,
            heightPx: heightPx,
            widthSnapPx: widthSnapPx,
            heightSnapPx: heightSnapPx
        ))
    }
}
