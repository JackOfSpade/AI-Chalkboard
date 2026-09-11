import Foundation

/// `register_screenshot_space` and `calibrate_screenshot_space` -- the two
/// tools that let an agent establish a `ScreenshotSpace` (see
/// `Sources/Support/ScreenshotSpace.swift`'s header comment for the full
/// "silent 2x misplacement" failure this closes) ONCE, either by measurement
/// (`register_screenshot_space` with `screenshot_path`, or a solved
/// calibration) or by declaration, and reference it afterward by id instead
/// of re-guessing `screenshot_width`/`screenshot_height` on every `draw_*`
/// call.
///
/// This file owns exactly two things:
///   1. `register_screenshot_space` -- a single-shot registration from an
///      explicit `screen_id`/`screenshot_path`/`screenshot_width`+`height`.
///   2. `calibrate_screenshot_space` -- which SOLVES the dimensions when no
///      screenshot file is available to measure directly, by either of two
///      routes:
///        * the `begin`/`resolve`/`cancel` fiducial-marker handshake, which
///          paints crosshairs of Chalkboard's own and asks the caller to
///          report where they landed in its screenshot; and
///        * the single-shot, stateless `elements` action, which paints
///          nothing at all and instead reads UI elements of the TARGET
///          APPLICATION through Accessibility -- the route that still works
///          when Chalkboard's own pixels never reach the caller's capture.
///          See `CalibrateFromElementsSupport` for the measured field
///          failure that made it necessary.
///
/// Neither tool is wired into `handleToolsCall`'s dispatch switch here --
/// that switch lives in `MCPToolHandlers.swift`, owned by a sibling agent in
/// this phase of work. `handleRegisterScreenshotSpace(id:args:)` and
/// `handleCalibrateScreenshotSpace(id:args:)` are simply made available on
/// `MCPServer` for that switch to call.
enum RegisterScreenshotSpaceSupport {
    /// Which of the two mutually exclusive dimension sources
    /// `register_screenshot_space` was given.
    enum DimensionSource {
        case path(String)
        case declared(width: Int, height: Int)
    }

    /// A JSON `null` does not count as supplied -- the same reasoning
    /// `ScreenshotSpaceExpansion.expand`'s and `DrawRequest.coordinateTransform`'s
    /// identical `isSupplied` helpers give: a schema-driven client that
    /// serializes every declared property and nulls the ones it is not using
    /// is an ordinary way to build a request, and treating that null as
    /// "supplied" would reject a caller for an argument it never
    /// meaningfully sent.
    static func isSupplied(_ args: [String: Any], _ key: String) -> Bool {
        guard let value = args[key] else { return false }
        return !(value is NSNull)
    }

    /// Resolves WHICH dimension source `register_screenshot_space` was
    /// given, or rejects a contradictory/incomplete combination.
    ///
    /// Exactly one of three shapes is accepted: `screenshot_path` alone,
    /// `screenshot_width`+`screenshot_height` together, or neither (a
    /// rejection naming calibration as the third route). `screenshot_path`
    /// together with EITHER width/height key is rejected outright rather
    /// than silently preferring one -- the same "reject rather than
    /// reinterpret" rule `ScreenshotSpaceExpansion`'s rule 5 applies to
    /// `screenshot_space` + hand-declared dimensions, applied here to this
    /// tool's own two dimension sources.
    static func resolveDimensionSource(_ args: [String: Any]) -> DrawOutcome<DimensionSource> {
        let hasPath = isSupplied(args, "screenshot_path")
        let hasWidth = isSupplied(args, "screenshot_width")
        let hasHeight = isSupplied(args, "screenshot_height")

        guard !(hasPath && (hasWidth || hasHeight)) else {
            return .failure("register_screenshot_space rejected: screenshot_path and screenshot_width/screenshot_height are mutually exclusive dimension sources -- supplying both leaves it ambiguous which one should actually be trusted, and silently preferring one would leave you believing the other took effect. Nothing was registered; drop screenshot_width/screenshot_height and let the file be MEASURED directly (strictly stronger evidence when a file is available), or drop screenshot_path and DECLARE the dimensions yourself.")
        }

        if hasPath {
            guard let rawPath = args["screenshot_path"] as? String, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("screenshot_path must be a non-empty string when supplied.")
            }
            return .success(.path(rawPath))
        }

        guard hasWidth == hasHeight else {
            return .failure("register_screenshot_space rejected: screenshot_width and screenshot_height must be supplied together (both, or neither) -- one alone is meaningless for describing a screenshot's pixel grid. Nothing was registered; supply both, or omit both and use screenshot_path (measured) or calibrate_screenshot_space (solved) instead.")
        }

        guard hasWidth else {
            return .failure("register_screenshot_space requires exactly one dimension source: screenshot_path (Chalkboard decodes and MEASURES the file), screenshot_width + screenshot_height (you DECLARE them), or neither of those two -- in which case calibrate_screenshot_space SOLVES them from an on-screen fiducial handshake instead. Nothing was registered; supply one of these three.")
        }

        guard let width = MCPArgument.integer(args["screenshot_width"]), width > 0,
              let height = MCPArgument.integer(args["screenshot_height"]), height > 0 else {
            return .failure("screenshot_width and screenshot_height must be positive integers when supplied.")
        }
        return .success(.declared(width: width, height: height))
    }

    /// The shared aspect-ratio, no-upscale, and ambiguity gate that EVERY
    /// `ScreenshotSpace` dimension pair must clear before registration,
    /// regardless of whether those dimensions were MEASURED (decoded from a
    /// file), DECLARED (stated by the caller), or SOLVED/RECONCILED out of a
    /// `calibrate_screenshot_space` handshake: all three are, structurally,
    /// "here is a pixel size; which display's full-display capture could this
    /// be?", so all three go through the exact same checks
    /// `DrawRequest.coordinateTransform`'s `screenshot_pixels` branch already
    /// applies to a hand-declared draw call --
    /// `ScreenshotGeometry.fullDisplayScale` for the aspect/rounding guard,
    /// then `ScreenshotGeometry.isPlausibleFullDisplayCapture` against the
    /// RESOLVED display for the no-upscale guard and again across every
    /// currently connected display for the ambiguous-display guard -- rather
    /// than a second, independently-drifting copy of any of them.
    ///
    /// THE NO-UPSCALE GUARD IS HERE BECAUSE IT WAS ONCE MISSING.
    /// `isPlausibleFullDisplayCapture` used to be called ONLY to build the
    /// ambiguity candidate list, never against the target display itself, so
    /// a screenshot LARGER than its display sailed straight through. On a
    /// single 3840x2160 display, `register_screenshot_space
    /// {screenshot_width: 7680, screenshot_height: 4320}` (or a
    /// `screenshot_path` pointing at an upscaled 7680x4320 PNG, which even
    /// earned provenance `measured`) passed the `fullDisplayScale` aspect
    /// guard -- a perfectly uniform 2x is not an aspect mismatch -- and then
    /// found an EMPTY `accepting` list, so the ambiguity guard could not fire
    /// either. The space registered with `scaleToBackingPx` 0.5x0.5 and every
    /// later draw through it HALVED the agent's coordinates: a click target
    /// measured at screenshot (7000, 4000) was painted at backing
    /// (3500, 2000), silently and with no diagnostic. Meanwhile
    /// `MCPToolCatalog.swift`'s own description of this tool promised the
    /// dimensions "must describe a plausible full-display capture of the
    /// resolved display (matching its aspect ratio within rounding tolerance,
    /// never larger than it) or the call is rejected", and the marker-solve
    /// route (`ScreenshotCalibration.solve`'s no-upscale step) rejected that
    /// exact shape. One registration route accepting what its own
    /// documentation AND its sibling route both refuse is the defect; this
    /// guard closes it.
    ///
    /// ORDER IS DELIBERATE: the aspect guard stays FIRST. An image that is
    /// both the wrong shape and too large is better described by "does not
    /// map onto this display as a full-display capture at all" than by "is
    /// larger than it", so running aspect first keeps each message the
    /// specific one for its own failure instead of letting the coarser
    /// upscale wording swallow the finer aspect wording.
    ///
    /// `screenIsDetermined` mirrors `DrawRequest.screenIsDetermined`'s exact
    /// meaning: false only when `screen_id` was omitted and the caller is
    /// about to receive a DEFAULTED display, in which case an image that
    /// fits more than one connected display cannot be silently resolved.
    /// An explicit `screen_id` is already the caller's own answer to "which
    /// display", so ambiguity among OTHER displays is irrelevant.
    ///
    /// `rejectionPrefix` names the TOOL doing the rejecting, and exists
    /// because this gate is genuinely shared: `calibrate_screenshot_space
    /// action="resolve"` routes its reconciled dimensions through this very
    /// function (see `handleCalibrateScreenshotSpaceResolve`). A message
    /// reading "register_screenshot_space rejected:" in the response to a
    /// `calibrate_screenshot_space` call would send the agent off to fix
    /// arguments it never passed, so the one caller-visible tool name is
    /// parameterized rather than hardcoded. The default preserves
    /// `register_screenshot_space`'s existing wording exactly.
    /// The caveat a `.declared` space carries, or `nil` for a `.measured` or
    /// `.observed` one (which have real evidence behind them and need no
    /// hedge).
    ///
    /// WHY THIS EXISTS: field testing against a screen-control tool that
    /// returns screenshots as INLINE IMAGE DATA -- no file path -- found a
    /// combination where every stronger route is closed at once. There is no
    /// file for `screenshot_path` to measure, and the calibration fiducials
    /// never appear in that tool's captures, so `.declared` is not merely the
    /// weakest option, it is the ONLY one. A caller in that position is back
    /// to exactly the per-call guess this whole feature was built to remove,
    /// except now the guess is made once and reused -- which is better for
    /// consistency and no better for correctness. Saying so plainly, at the
    /// moment the space is minted, is the difference between a caller who
    /// knows it is standing on an assertion and one who reads `provenance`
    /// as a grade and moves on.
    ///
    /// THE EXTRA SENTENCE FOR A NATIVE-SIZED DECLARATION is the specific
    /// failure this whole design exists to prevent, and it is worth naming
    /// separately because it is the one wrong answer that looks most right:
    /// declaring the display's exact backing size for an image that is really
    /// a downsample of it is self-consistent, passes the aspect guard and the
    /// no-upscale guard, and lands every coordinate at a constant fraction of
    /// where it was meant to go. It is ALSO what a correct native capture
    /// looks like, so this cannot be a rejection -- only a prompt to confirm.
    static func declaredProvenanceCaveat(
        provenance: ScreenshotSpace.Provenance, widthPx: Int, heightPx: Int, screen: ScreenInfo
    ) -> String? {
        guard provenance == .declared else { return nil }
        var caveat = "This space's dimensions are an ASSERTION you supplied, not a measurement: nothing here has checked them against the image they describe, and a wrong-but-self-consistent declaration misplaces every coordinate by a constant factor without any guard being able to notice. Registering it once removes the repeated guess, not the guess itself. To upgrade it: register_screenshot_space with screenshot_path when a screenshot FILE exists (provenance 'measured'), or calibrate_screenshot_space when the fiducials are visible in your own captures (provenance 'observed')."
        if let fraction = cleanFractionOfDisplay(widthPx: widthPx, heightPx: heightPx, screen: screen) {
            if fraction.numerator == fraction.denominator {
                caveat += " NOTE that you declared display \(screen.id)'s EXACT backing size (\(screen.widthPx)x\(screen.heightPx)). That is correct for a native, un-resized capture -- and it is also precisely what a downsampled image looks like when its true size is unknown and the display's native size is declared instead. If anything between the capture and you resized that image, these coordinates will land at a constant fraction of their target. Confirm the image really is un-resized before relying on this space."
            } else {
                caveat += " NOTE that \(widthPx)x\(heightPx) is exactly \(fraction.numerator)/\(fraction.denominator) of display \(screen.id)'s backing size (\(screen.widthPx)x\(screen.heightPx)). A tidy fraction like that is what a GUESS looks like: a real resize is driven by a maximum-dimension or pixel-budget cap and lands on an arbitrary number, not on a round ratio of whatever display it came from. A measured case: 1512x982 was declared on a 3024x1964 display -- exactly one half -- when the image was really 1372x891, and because a uniform fraction of a matching aspect ratio passes both the aspect and the no-upscale guard, every coordinate landed 10.2% out for an entire session with every call reporting success. Confirm this is the image's real size rather than an assumed ratio before relying on this space."
            }
        }
        return caveat
    }

    /// The simple fraction `widthPx`x`heightPx` is of `screen`'s backing size,
    /// or `nil` when it is not a tidy ratio of it.
    ///
    /// WHY THIS IS THE SIGNAL. A declared screenshot size cannot be checked --
    /// that is the whole problem -- but it CAN be asked whether it looks
    /// guessed. An agent that does not know its image's true size reaches for a
    /// round relationship to something it does know: the display's native size,
    /// or a half or two-thirds of it. A genuine downsample is produced by a
    /// client resizing to fit a maximum dimension or a pixel budget, so it
    /// lands on an arbitrary number that happens to preserve the aspect ratio.
    /// "Tidy ratio of the display" is therefore evidence of assumption rather
    /// than measurement.
    ///
    /// This is a PROMPT, never a rejection: exactly one half is also what an
    /// honest 2x-HiDPI-to-logical capture legitimately produces, so the value
    /// cannot be refused, only questioned.
    ///
    /// The table stops at quarters deliberately. Beyond that the fractions stop
    /// being things a caller would reach for by hand and start colliding with
    /// ordinary cap-derived sizes, turning a pointed warning into noise on
    /// correct declarations -- which would train a reader to skip it, blunting
    /// the one case that matters.
    ///
    /// Both axes must match the SAME fraction, each to the nearest pixel, so a
    /// coincidence on one axis alone does not trigger it.
    static func cleanFractionOfDisplay(
        widthPx: Int, heightPx: Int, screen: ScreenInfo
    ) -> (numerator: Int, denominator: Int)? {
        guard screen.widthPx > 0, screen.heightPx > 0 else { return nil }
        let candidates: [(Int, Int)] = [(1, 1), (1, 2), (1, 3), (2, 3), (1, 4), (3, 4)]
        for (numerator, denominator) in candidates {
            let ratio = Double(numerator) / Double(denominator)
            let expectedWidth = Int((Double(screen.widthPx) * ratio).rounded())
            let expectedHeight = Int((Double(screen.heightPx) * ratio).rounded())
            if widthPx == expectedWidth && heightPx == expectedHeight {
                return (numerator, denominator)
            }
        }
        return nil
    }

    static func validateAgainstDisplay(
        widthPx: Int, heightPx: Int,
        screen: ScreenInfo, candidateScreens: [ScreenInfo], screenIsDetermined: Bool,
        rejectionPrefix: String = "register_screenshot_space rejected:"
    ) -> DrawOutcome<Void> {
        let width = Double(widthPx)
        let height = Double(heightPx)

        func acceptingScreens() -> [ScreenInfo] {
            candidateScreens.filter {
                ScreenshotGeometry.isPlausibleFullDisplayCapture(
                    screenshotWidth: width, screenshotHeight: height,
                    screenWidth: Double($0.widthPx), screenHeight: Double($0.heightPx)
                )
            }
        }

        guard ScreenshotGeometry.fullDisplayScale(
            screenshotWidth: width, screenshotHeight: height,
            screenWidth: Double(screen.widthPx), screenHeight: Double(screen.heightPx)
        ) != nil else {
            let sourceScaleX = width / Double(screen.widthPx)
            let sourceScaleY = height / Double(screen.heightPx)
            let accepting = acceptingScreens()
            let hint = accepting.isEmpty
                ? ""
                : " These dimensions DO match connected display(s) \(accepting.map(\.id).joined(separator: ", ")); pass screen_id if the screenshot came from one of those."
            return .failure("\(rejectionPrefix) \(widthPx)x\(heightPx) px does not map onto display \(screen.id) (\(screen.widthPx)x\(screen.heightPx) backing px) as a full-display capture within pixel-rounding tolerance (scales \(sourceScaleX)x\(sourceScaleY)). Nothing was registered; supply the exact dimensions of an uncropped full-display screenshot of that display, or measure it directly with screenshot_path instead of declaring it.\(hint)")
        }

        // The no-upscale half of `isPlausibleFullDisplayCapture`, applied to
        // the RESOLVED display -- the half that used to be reachable only
        // through `acceptingScreens()` above. A capture pipeline downsamples
        // (a Retina screenshot saved at logical size) or matches natively; it
        // never invents pixels the display does not have, so an image bigger
        // than its display is not a full-display capture of it and its
        // implied sub-1 `scaleToBackingPx` would silently shrink every
        // coordinate drawn through the space.
        guard ScreenshotGeometry.isPlausibleFullDisplayCapture(
            screenshotWidth: width, screenshotHeight: height,
            screenWidth: Double(screen.widthPx), screenHeight: Double(screen.heightPx)
        ) else {
            let accepting = acceptingScreens()
            let hint = accepting.isEmpty
                ? ""
                : " These dimensions ARE a plausible capture of connected display(s) \(accepting.map(\.id).joined(separator: ", ")); pass screen_id naming the display the screenshot was actually taken from."
            return .failure("\(rejectionPrefix) \(widthPx)x\(heightPx) px is LARGER than display \(screen.id)'s \(screen.widthPx)x\(screen.heightPx) backing px, which would require an upscale that no capture pipeline produces -- so this image cannot be a full-display capture of that display. Nothing was registered; supply the dimensions of an uncropped, un-upscaled full-display screenshot of that display (native size or any downsample of it).\(hint)")
        }

        let accepting = acceptingScreens()
        guard screenIsDetermined || accepting.count <= 1 else {
            return .failure("\(rejectionPrefix) \(widthPx)x\(heightPx) px matches \(accepting.count) connected displays (ids: \(accepting.map(\.id).joined(separator: ", "))) and no screen_id was supplied, so this space would have silently been registered against display \(screen.id) -- a screenshot is the image of one specific display and its dimensions alone cannot say which. Nothing was registered; retry with screen_id naming the display the screenshot was actually taken from.")
        }
        return .success(())
    }
}

/// Pure decision logic behind `calibrate_screenshot_space`'s `resolve`
/// action -- argument parsing, and the ADDENDUM-required cross-check between
/// a marker solve and a caller-declared `observed_width`/`observed_height`
/// (see PHASE_B_SPEC.md's "ADDENDUM -- a verified blind spot in the
/// calibration solver"). Kept free of `MCPServer`, `AnnotationStore`, and
/// `OverlayWindowController` so every branch is directly unit-testable
/// against hand-built `ScreenshotCalibration.Solution` fixtures, with no
/// live display, no annotation store, and no MCP transport in play.
enum CalibrateScreenshotSpaceSupport {
    static func isSupplied(_ args: [String: Any], _ key: String) -> Bool {
        guard let value = args[key] else { return false }
        return !(value is NSNull)
    }

    /// `action` is the ONE required, always-present argument every call to
    /// `calibrate_screenshot_space` carries; every other argument's meaning
    /// depends on it, so this is validated before anything else.
    ///
    /// WHY `"elements"` JOINS THE THREE-STEP HANDSHAKE ON THIS SAME TOOL
    /// rather than becoming a tool of its own: it does the identical job --
    /// establish a `ScreenshotSpace` BY MEASUREMENT rather than by
    /// declaration -- and an agent asking "how do I calibrate?" should find
    /// one answer, not two tools it must first learn to tell apart. What it
    /// does NOT share is the handshake's SHAPE: `begin`/`resolve`/`cancel`
    /// are three calls around a piece of live, must-be-cleaned-up state
    /// (fiducials painted on the user's screen, capture-debug forced on),
    /// whereas `elements` is SINGLE-SHOT and STATELESS -- it paints nothing,
    /// opens no session, touches no flag, and therefore has nothing to
    /// cancel. `calibration_id` is meaningless to it, and that asymmetry is
    /// the one thing a caller reading this vocabulary has to internalize.
    static func parseAction(_ args: [String: Any]) -> DrawOutcome<String> {
        guard let raw = args["action"] as? String else {
            return .failure("Missing required parameter: action (one of \"begin\", \"resolve\", \"cancel\", \"elements\").")
        }
        let action = raw.lowercased()
        guard action == "begin" || action == "resolve" || action == "cancel" || action == "elements" else {
            return .failure("action must be one of \"begin\", \"resolve\", \"cancel\", \"elements\"; got \"\(raw)\".")
        }
        return .success(action)
    }

    /// Parses `resolve`'s optional `markers` array of `{label, x, y}` objects
    /// into `ScreenshotCalibration.Observation`s. `nil` means the key was not
    /// supplied at all (a caller relying solely on `observed_width`/
    /// `observed_height` is legitimate -- see `reconcile` below); a present
    /// but structurally wrong value is a rejection here, before it ever
    /// reaches `ScreenshotCalibration.solve`'s own semantic checks.
    static func parseMarkerObservations(_ args: [String: Any]) -> DrawOutcome<[ScreenshotCalibration.Observation]?> {
        guard isSupplied(args, "markers") else { return .success(nil) }
        guard let rawArray = args["markers"] as? [Any] else {
            return .failure("markers must be an array of {label, x, y} objects when supplied.")
        }
        guard !rawArray.isEmpty else {
            return .failure("markers must not be empty when supplied. Nothing was registered; report all four marker centres (TL, TR, BL, BR), or omit markers entirely and supply observed_width/observed_height instead.")
        }
        var observations: [ScreenshotCalibration.Observation] = []
        observations.reserveCapacity(rawArray.count)
        for (index, raw) in rawArray.enumerated() {
            guard let dict = raw as? [String: Any] else {
                return .failure("markers[\(index)] must be an object with label, x, and y fields.")
            }
            guard let label = (dict["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                return .failure("markers[\(index)] is missing a non-empty string label.")
            }
            guard let x = MCPArgument.double(dict["x"]), let y = MCPArgument.double(dict["y"]) else {
                return .failure("markers[\(index)] (label '\(label)') requires finite numeric x and y fields -- the marker's centre in YOUR screenshot's own pixel coordinates.")
            }
            observations.append(ScreenshotCalibration.Observation(label: label, x: x, y: y))
        }
        return .success(observations)
    }

    /// Parses `resolve`'s optional `observed_width`/`observed_height` pair --
    /// paired exactly like every other dimension pair in this package
    /// (`screenshot_width`/`screenshot_height` in `AnnotationBoundsSupport`
    /// and `DrawRequest.coordinateTransform`): one alone cannot describe a
    /// screenshot's pixel grid, so it is rejected rather than silently
    /// ignored.
    static func parseObservedDimensions(_ args: [String: Any]) -> DrawOutcome<(width: Int, height: Int)?> {
        let hasWidth = isSupplied(args, "observed_width")
        let hasHeight = isSupplied(args, "observed_height")
        guard hasWidth == hasHeight else {
            return .failure("observed_width and observed_height must be supplied together (both, or neither): one alone cannot describe a screenshot's pixel grid. Nothing was registered.")
        }
        guard hasWidth else { return .success(nil) }
        guard let width = MCPArgument.integer(args["observed_width"]), width > 0,
              let height = MCPArgument.integer(args["observed_height"]), height > 0 else {
            return .failure("observed_width and observed_height must be positive integers when supplied.")
        }
        return .success((width, height))
    }

    /// DUPLICATES `ScreenshotCalibration.tolerance(for:)`'s formula
    /// (`max(4px, 1% of span)`) rather than calling it. That private helper
    /// lives in `Sources/Support/ScreenshotCalibration.swift`, which is
    /// EXCLUSIVELY owned in this phase of work by the sibling agent fixing
    /// its snap-to-display-consistent-size behaviour (PHASE_B_SPEC.md's
    /// "ADDENDUM 2"); this file's ownership rules forbid touching it, even
    /// to widen one function's access level. This is therefore a deliberate,
    /// documented duplication of a two-line formula -- not a second,
    /// independent guess at what the right tolerance should be -- and it
    /// only needs to be roughly right: the scenario it exists to catch (a
    /// top-left-anchored aspect-preserving crop, see PHASE_B_SPEC.md's
    /// "ADDENDUM") produces a disagreement of tens to hundreds of pixels,
    /// far outside either constant's plausible range. If the solver's own
    /// formula ever changes, this pair should be revisited to match.
    private static let crossCheckMinimumAbsoluteTolerancePx = 4.0
    private static let crossCheckRelativeTolerance = 0.01
    /// Rounds one residual to a sane number of decimal places for the WIRE
    /// ONLY -- never for a comparison.
    ///
    /// WHY THIS EXISTS: every residual is the difference of two
    /// floating-point sums, so a PERFECT reading does not produce `0.0`, it
    /// produces something like `2.84e-14`. `residuals` exists so a caller can
    /// answer "how good was my measurement", and an agent reading
    /// `originX: 2.8421709430404007e-14` has to work out for itself that this
    /// is a clean zero and not a real 2.8-of-something offset. Rounding to
    /// three decimals collapses that to `0`, which is both true and readable:
    /// these are pixel measurements read off a screenshot by eye, so a
    /// thousandth of a pixel is far below anything the caller could have
    /// observed or could act on.
    ///
    /// DELIBERATELY APPLIED ONLY AT THE PAYLOAD BOUNDARY. Every tolerance
    /// comparison in `ScreenshotCalibration.solve` and in `reconcile` below
    /// stays on the exact unrounded values -- rounding before a comparison
    /// would move a marginal reading across a threshold and change which
    /// calibrations are accepted, which is a correctness change, not a
    /// presentation one.
    static func displayRounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let scale = 1000.0
        let rounded = (value * scale).rounded() / scale
        // `-0.0` encodes as `-0` in JSON, which reads as a signed quantity
        // when it is nothing of the sort. Normalize it to a plain zero.
        return rounded == 0 ? 0 : rounded
    }

    static func crossCheckTolerance(for span: Double) -> Double {
        max(crossCheckMinimumAbsoluteTolerancePx, crossCheckRelativeTolerance * span)
    }

    /// The `residuals` object EVERY solved calibration reports, in exactly
    /// one place.
    ///
    /// WHY THIS IS SHARED RATHER THAN WRITTEN TWICE: two different routes now
    /// produce a `ScreenshotCalibration.Solution` -- the four-marker
    /// `begin`/`resolve` handshake, and the stateless `action="elements"`
    /// route that reads its fiducials out of the target app's Accessibility
    /// hierarchy instead of painting them. Both hand back the SAME
    /// `Residuals` value and both owe the caller the same reading of it, so a
    /// second copy of this key list would let one route quietly grow a field
    /// (or spell one differently) that the other never reports -- and an
    /// agent comparing two calibrations of the same display would be
    /// comparing two different vocabularies. Adding a residual means editing
    /// this function once.
    ///
    /// EVERY value goes through `displayRounded`, which is also the guarantee
    /// that no non-finite `Double` can reach `JSONSerialization` from here:
    /// a residual is the difference of two floating-point sums, and
    /// `JSONSerialization` throws on NaN/infinity rather than encoding it,
    /// which would turn a SUCCESSFUL, already-registered calibration into an
    /// unencodable response.
    static func residualsPayload(_ residuals: ScreenshotCalibration.Residuals) -> [String: Any] {
        [
            "originX": displayRounded(residuals.originX),
            "originY": displayRounded(residuals.originY),
            "horizontalPairDisagreementPx": displayRounded(residuals.horizontalPairDisagreement),
            "verticalPairDisagreementPx": displayRounded(residuals.verticalPairDisagreement),
            // How far the solver MOVED the raw solve to land on the nearest
            // exact uniform downsample of this display (signed: snapped minus
            // raw). Reported because the snap is the one step that changes the
            // caller's own measurement into a different number, and a caller
            // comparing screenshotPx against what it believes its image to be
            // deserves to see the size of that correction rather than discover
            // it as an unexplained discrepancy. Near-zero means the reading
            // already described a display-consistent capture; a value close to
            // the per-axis tolerance means the reading was marginal and worth
            // repeating.
            "widthSnapPx": displayRounded(residuals.widthSnapPx),
            "heightSnapPx": displayRounded(residuals.heightSnapPx)
        ]
    }

    /// The reconciled result of `resolve`'s dimension sources: the
    /// registered width/height, the `ScreenshotSpace.Provenance` they earn,
    /// and an optional human-readable cross-check note for the response.
    struct Reconciliation {
        let width: Int
        let height: Int
        let provenance: ScreenshotSpace.Provenance
        let crossCheckNote: String?
    }

    /// The pure decision behind the ADDENDUM's required cross-check: given a
    /// marker solve (or `nil`, if no `markers` were supplied) and a declared
    /// `observed_width`/`observed_height` pair (or `nil`, if neither was
    /// supplied), decides what gets registered.
    ///
    /// Four cases:
    ///   * Neither supplied -- rejected: nothing to solve or declare from.
    ///   * `observed_*` alone -- registered `.declared`. An assertion with no
    ///     independent measurement behind it earns exactly today's
    ///     per-call-guess evidentiary weight, no stronger -- see
    ///     `ScreenshotSpace.Provenance.declared`'s own doc comment.
    ///   * `markers` alone -- registered `.observed` at the solver's own
    ///     (already display-validated) dimensions.
    ///   * BOTH -- compared. Disagreement past `crossCheckTolerance` is
    ///     EXACTLY the signature of a top-left-anchored, aspect-preserving
    ///     crop that marker spacing alone cannot detect (see
    ///     PHASE_B_SPEC.md's "ADDENDUM"): REJECTED, naming both numbers.
    ///     Agreement keeps `.observed` provenance (the marker solve is still
    ///     the stronger, independently-measured claim) and reports that the
    ///     cross-check passed.
    static func reconcile(
        solved: ScreenshotCalibration.Solution?,
        declaredObserved: (width: Int, height: Int)?
    ) -> DrawOutcome<Reconciliation> {
        switch (solved, declaredObserved) {
        case (nil, nil):
            return .failure("calibrate_screenshot_space action=\"resolve\" requires either markers (all four TL/TR/BL/BR observations, to SOLVE the dimensions) or observed_width/observed_height (to DECLARE them) -- or both together, as a cross-check. Nothing was registered; supply at least one of these.")

        case (nil, .some(let observed)):
            return .success(Reconciliation(width: observed.width, height: observed.height, provenance: .declared, crossCheckNote: nil))

        case (.some(let solution), nil):
            return .success(Reconciliation(width: solution.widthPx, height: solution.heightPx, provenance: .observed, crossCheckNote: nil))

        case (.some(let solution), .some(let observed)):
            let widthGap = abs(Double(solution.widthPx) - Double(observed.width))
            let heightGap = abs(Double(solution.heightPx) - Double(observed.height))
            let widthTolerance = crossCheckTolerance(for: Double(solution.widthPx))
            let heightTolerance = crossCheckTolerance(for: Double(solution.heightPx))
            guard widthGap <= widthTolerance, heightGap <= heightTolerance else {
                return .failure("calibrate_screenshot_space cross-check FAILED: markers solved to \(solution.widthPx)x\(solution.heightPx) px, but observed_width/observed_height declared \(observed.width)x\(observed.height) px -- a gap of \(widthGap)x\(heightGap) px, exceeding the \(widthTolerance)x\(heightTolerance) px tolerance. This disagreement is exactly the signature of a top-left-anchored, aspect-preserving crop that marker spacing alone cannot detect: the markers still read correctly and extrapolate to the wrong (larger) extent. Nothing was registered; if you have the actual screenshot file, call register_screenshot_space with screenshot_path instead -- decoding the file measures its true extent directly, which is strictly stronger than either number reported here.")
            }
            let note = "cross-check passed: observed_width/observed_height (\(observed.width)x\(observed.height)) agreed with the marker solve (\(solution.widthPx)x\(solution.heightPx)) within \(widthTolerance)x\(heightTolerance) px tolerance."
            return .success(Reconciliation(width: solution.widthPx, height: solution.heightPx, provenance: .observed, crossCheckNote: note))
        }
    }

    /// The ONE wording every post-lookup `resolve` rejection carries, so that
    /// the guarantee `MCPToolCatalog.swift` and `README.md` both publish --
    /// "the fiducials are cleared and the prior capture-visible value restored
    /// on EVERY resolve call, including a rejected one" -- is stated in
    /// exactly one place and cannot drift branch by branch.
    ///
    /// THE DEFECT THIS PINS: `resolve`'s two ARGUMENT-SHAPE rejections used to
    /// `return` before any `clearCalibrationSession` ran, so the documented
    /// promise was false for exactly the caller mistakes it most needed to
    /// hold for. A client that keyed its markers by label -- `markers:
    /// {"TL": {x: 120, y: 80}, ...}`, a JSON object where the schema wants an
    /// array, and a thoroughly ordinary serialization shape -- got back
    /// "markers must be an array of {label, x, y} objects when supplied."
    /// while all four crosshairs and the CAL token stayed painted on the
    /// user's display and capture-debug stayed forced on with the menu-bar
    /// icon orange. Likewise a marker centre reported with its unit attached
    /// (`x: "120px"`, which `MCPArgument.double` cannot coerce, unlike a bare
    /// numeric string), an empty `markers: []`, and `observed_width` without
    /// `observed_height`. An agent holding the documented model ("a rejected
    /// resolve cleans up") then believes the screen is clear and the
    /// handshake dead, so it runs a whole fresh `action="begin"` -- painting
    /// a SECOND set of fiducials over the still-present first, which only the
    /// same-display displacement rule happens to rescue -- instead of simply
    /// re-sending `resolve` with the corrected argument.
    ///
    /// `captureOutcome` is `MCPServer.CalibrationCaptureCleanup.sentence`,
    /// never a hardcoded "restored to X": with a second calibration still
    /// outstanding the flag is deliberately LEFT ON, and asserting a restore
    /// that did not happen would send an agent debugging a stuck orange icon
    /// looking in the wrong place.
    static func resolveRejectionMessage(
        _ error: String, calibrationId: String, captureOutcome: String
    ) -> String {
        "\(error) The fiducials for calibration '\(calibrationId)' have been cleared and \(captureOutcome), regardless of this failure -- a rejected resolve must never leave markers stranded on the user's screen. Nothing was registered; call action=\"begin\" to start a fresh calibration."
    }
}

/// Pure argument parsing, display-agreement, and payload shaping behind
/// `calibrate_screenshot_space action="elements"` -- the route that
/// calibrates a screenshot space against UI elements of the TARGET
/// APPLICATION instead of against fiducial crosshairs Chalkboard paints for
/// itself.
///
/// WHY THIS ROUTE EXISTS AT ALL. `action="begin"` paints four crosshairs on
/// the display and asks the caller to report where they land in its own
/// screenshot. That handshake is only as good as its one unstated
/// precondition: Chalkboard's own pixels have to reach the caller's capture.
/// Field testing against a screen-control ("computer-use") MCP tool found a
/// real configuration where they never do. The caller's screenshots WERE of
/// this same local display -- this machine's menu bar, Dock and wallpaper are
/// all plainly visible in them, so this is not a remote-desktop or
/// different-framebuffer topology -- and yet Chalkboard's fiducials never
/// appeared, EVEN WITH CAPTURE-DEBUG ON. The leading explanation is that the
/// capture tool composites only the windows of applications the user has
/// explicitly granted it, as its own application-level policy, entirely
/// separate from the macOS `NSWindow.sharingType` mechanism that
/// `set_capture_visible` toggles. If that is what is happening there is
/// nothing at the OS level for Chalkboard to switch: the filtering happens
/// ABOVE it. That same tool returns screenshots as INLINE IMAGE DATA with no
/// file path, so `register_screenshot_space`'s `screenshot_path` route --
/// the strongest one, which decodes the file and MEASURES it -- is
/// unreachable in the same session. Both measurement routes closed at once
/// leaves `declared`, a bare assertion, as the only available provenance,
/// which is exactly the per-call guess this whole feature was built to
/// remove.
///
/// THE FIX IS TO STOP REQUIRING CHALKBOARD'S OWN PIXELS TO BE THE FIDUCIAL.
/// Any on-screen thing whose true position Chalkboard can determine
/// INDEPENDENTLY serves just as well, and a UI element of the target
/// application is close to ideal: Chalkboard can read its exact
/// backing-pixel rect through the Accessibility API (the same lookup
/// `highlight_element` already performs), while the caller can see that same
/// element in its own screenshot -- because the target app is precisely the
/// app the capture tool was granted. This route therefore needs the
/// ACCESSIBILITY grant, NOT Screen Recording, and needs nothing of
/// Chalkboard's own to be visible in anybody's capture. It is immune to the
/// hypothesis above whether or not that hypothesis turns out to be correct.
///
/// Kept free of `MCPServer`, `OverlayWindowController`, `AnnotationStore`
/// and the Accessibility APIs for the same reason
/// `CalibrateScreenshotSpaceSupport` is: every branch below has to be
/// directly unit-testable with no live display, no AppKit main-thread hop,
/// and no Accessibility grant in the test process -- which is the only way
/// the same-display rule and the argument rejections get pinned at all.
enum CalibrateFromElementsSupport {
    /// Two CORRESPONDENCES -- two POINTS -- is the arithmetic minimum:
    /// `observed = scale * true + origin` has two unknowns per axis. It is
    /// also the WEAKEST useful input, because a two-point per-axis fit is
    /// exact by construction and therefore cannot be checked -- see
    /// `redundancyCaveat` for what the payload has to say about that.
    ///
    /// COUNTED IN POINTS, NOT IN ELEMENTS, and the distinction is new. It
    /// used to be the same number either way, because every element was
    /// observed by its CENTRE and so contributed exactly one point. An
    /// element observed by its BOUNDING BOX contributes TWO (its top-left
    /// and its bottom-right corner), so the two counts have come apart, and
    /// every gate in this file has to be explicit about which one it means.
    /// THIS is the one the solve actually requires.
    static let minimumCorrespondenceCount = 2
    /// ONE element can now be a complete calibration, which is the entire
    /// point of `Observation.bounds`.
    ///
    /// THE MEASURED FAILURE THAT FORCED THIS. Driving DaVinci Resolve running
    /// inside a Shadow PC remote-desktop client, the whole application
    /// published exactly ONE labelled Accessibility element: its own window,
    /// 'Shadow PC - Display' [AXWindow]. No buttons, no child controls, no
    /// second fiducial at any separation whatsoever. That is not one app's
    /// quirk -- a remote-desktop or VNC client, a media player, a game,
    /// anything that paints into a single video or canvas surface is, to
    /// Accessibility, a window containing nothing, and with centre-only
    /// observations it had ZERO usable calibrations no matter how the
    /// baseline gate was tuned. A rect, however, is two points, and a
    /// remote-desktop window is large enough that its two corners clear the
    /// solver's 25%-of-the-display baseline gate comfortably.
    ///
    /// So the floor on the ARRAY is 1, and `minimumCorrespondenceCount` is
    /// what actually decides whether a request can be solved.
    static let minimumElementCount = 1
    /// Eight is a ceiling on cross-process Accessibility work, not on the
    /// mathematics: each element costs its own full breadth-first walk of
    /// the target application's hierarchy, and a walk can legitimately run
    /// for seconds against a large app. Refusing a ninth element up front is
    /// cheaper for everyone than discovering the total cost after eight
    /// walks have already been paid for.
    static let maximumElementCount = 8

    /// The only fields one `elements[i]` object may carry. Enforced, rather
    /// than left to the JSON Schema's `additionalProperties: false`, because
    /// an MCP client is free to send whatever it likes and a schema a server
    /// does not itself check is a suggestion.
    ///
    /// THE CONCRETE MISTAKE THIS CATCHES: the marker route right next door
    /// takes `markers: [{label, x, y}]`, so `elements: [{label, x, y}]` is
    /// the single likeliest wrong shape a caller will send. Silently ignoring
    /// the unknown `x`/`y` and then complaining that `observed_x` is missing
    /// would describe the symptom rather than the mistake.
    static let recognizedElementKeys: Set<String> = Set(
        ["label", "role", "match", "occurrence"] + centreObservationKeys + boundsObservationKeys
    )

    /// The two keys of a CENTRE observation, in the order every rejection
    /// lists them.
    static let centreObservationKeys = ["observed_x", "observed_y"]
    /// The four keys of a BOUNDS observation, ordered top-left corner first
    /// so a rejection lists them in the same order as the two
    /// correspondences the box produces.
    ///
    /// Spelled as ARRAYS rather than folded into `recognizedElementKeys`
    /// alone because the parser has to ask three separate questions of them
    /// -- which group was supplied, which members of a group are MISSING, and
    /// which were supplied but unreadable -- and each answer is printed back
    /// to the caller in this order.
    static let boundsObservationKeys = ["observed_left", "observed_top", "observed_right", "observed_bottom"]

    /// HOW one element was observed in the caller's screenshot. Exactly one
    /// of the two forms, which is precisely why this is an enum and not four
    /// more optional `Double`s hung off `ElementSpec`: a struct of optionals
    /// can represent "a left edge and a centre y", a half-observed state the
    /// parser must reject and the solver must never be handed, whereas this
    /// type cannot express it at all.
    enum Observation: Equatable {
        /// The element's CENTRE, in the caller's own screenshot's pixels.
        /// Centre, not corner, because the centre is the one point on a
        /// CONTROL that a reader can identify without also having to agree
        /// about where its padding, shadow, or focus ring ends.
        case centre(x: Double, y: Double)
        /// The element's BOUNDING BOX, in the caller's own screenshot's
        /// pixels, with `left`/`top` the smaller values.
        ///
        /// WHY CORNERS ARE ACCEPTABLE HERE despite the argument for centres
        /// above: this form exists for an element that is a WINDOW, not a
        /// control. A window's edges are high-contrast and unambiguous in a
        /// screenshot -- if anything easier to read than a control's centre
        /// -- and the padding/focus-ring disagreement the centre avoids is a
        /// pixel or two against a baseline of a whole window. The one real
        /// misreading, reporting the CONTENT area and so omitting the title
        /// bar, does not silently mis-scale: it lands as an origin residual
        /// (14.58 px against a 9.59 px tolerance on the measured 3024x1964
        /// case), so the solver's existing origin check rejects it.
        case bounds(left: Double, top: Double, right: Double, bottom: Double)

        /// How many `ScreenshotCalibration.Correspondence` values this
        /// observation yields: ONE for a centre, TWO for a box.
        ///
        /// THE SINGLE PLACE THAT KNOWS THAT RATIO. Everything that has to
        /// count points rather than elements -- the "at least 2" gate, the
        /// redundancy caveat, the success payload's tally -- asks here, so a
        /// third observation form could never be added and leave one of them
        /// quietly counting the old way.
        var correspondenceCount: Int {
            switch self {
            case .centre: return 1
            case .bounds: return 2
            }
        }

        /// What the success payload calls this form, so a caller auditing a
        /// solve can see WHICH way each fiducial was read rather than having
        /// to infer it from which coordinate keys are present.
        var payloadName: String {
            switch self {
            case .centre: return "centre"
            case .bounds: return "bounds"
            }
        }
    }

    /// One requested fiducial: which element to look up, and where -- and in
    /// which of the two forms -- the caller says it appears in its own
    /// screenshot.
    struct ElementSpec: Equatable {
        let label: String
        let role: String?
        let matchMode: AccessibilityLabelMatchMode
        let occurrence: Int?
        let observation: Observation
    }

    /// The fully parsed, still entirely inert `action="elements"` call.
    struct Request: Equatable {
        /// The raw (trimmed) `app` string, kept only so a resolution failure
        /// can quote back what the caller actually asked for. Resolving it is
        /// `handleHighlightElement`'s shared lookup's job, not this type's.
        let app: String
        /// The caller's explicit `screen_id`, or `nil` when it was omitted.
        /// Omitted is the ORDINARY case: the elements themselves name the
        /// display, which is strictly better evidence than a caller-supplied
        /// id and does not require the caller to already know the answer.
        let screenId: String?
        let elements: [ElementSpec]
        let maxNodes: Int
        let timeoutSeconds: TimeInterval
    }

    /// One requested fiducial after its Accessibility lookup succeeded and
    /// its backing rect was re-confirmed against a post-walk display
    /// snapshot.
    struct ResolvedElement: Equatable {
        let spec: ElementSpec
        /// What the app actually published, which can differ from
        /// `spec.label` under `match: "contains"`. Reported back so a caller
        /// can see WHICH control answered a loose query.
        let matchedLabel: String
        let resolvedRole: String?
        let frame: AccessibilityBackingRect
    }

    // MARK: - Parsing

    /// Parses every argument of an `action="elements"` call, rejecting on the
    /// first thing that is wrong.
    ///
    /// ORDER IS DELIBERATE and matches `handleHighlightElement`'s own: every
    /// purely syntactic complaint is raised here, BEFORE the caller's `app`
    /// is resolved to a PID and before a single cross-process Accessibility
    /// message is sent. A malformed request must not trigger a TCC check or
    /// walk another application's UI hierarchy merely to fail afterwards.
    static func parse(_ args: [String: Any]) -> DrawOutcome<Request> {
        guard let suppliedApp = args["app"] as? String else {
            return .failure("calibrate_screenshot_space action=\"elements\" requires app: the running application whose UI elements are the fiducials. Nothing was registered; pass app with that application's exact bundle id or display name (the same value highlight_element takes).")
        }
        let app = suppliedApp.trimmingCharacters(in: .whitespacesAndNewlines)
        // GLOBAL/empty is not merely discouraged here, it is meaningless: an
        // Accessibility hierarchy belongs to one process, so without a PID
        // there is no tree to walk and nothing to measure. Rejected in this
        // pure layer -- rather than left to the shared app resolution, which
        // rejects it in `highlight_element`'s own wording -- so the message a
        // `calibrate_screenshot_space` caller reads names the tool it called.
        guard !app.isEmpty else {
            return .failure("calibrate_screenshot_space action=\"elements\" cannot target GLOBAL visibility: app must name ONE running application, because an Accessibility hierarchy belongs to a single process and there is no tree to measure without one. Nothing was registered; pass app with a running application's exact bundle id or display name.")
        }

        var screenId: String?
        if CalibrateScreenshotSpaceSupport.isSupplied(args, "screen_id") {
            guard let raw = args["screen_id"] as? String else {
                return .failure("screen_id must be a string when supplied.")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure("screen_id must be a non-empty string when supplied. Nothing was registered; omit it entirely to let the resolved elements name their own display, or pass the id get_screens reported.")
            }
            screenId = trimmed
        }

        let budgets: (maxNodes: Int, timeoutSeconds: TimeInterval)
        switch parseTraversalBudgets(args) {
        case .failure(let error): return .failure(error)
        case .success(let value): budgets = value
        }

        guard CalibrateScreenshotSpaceSupport.isSupplied(args, "elements") else {
            return .failure("calibrate_screenshot_space action=\"elements\" requires elements: an array of \(minimumElementCount)-\(maximumElementCount) objects naming UI elements of app and saying where each one appears in YOUR own screenshot -- {label, observed_x, observed_y} to observe an element by its CENTRE, or {label, observed_left, observed_top, observed_right, observed_bottom} to observe it by its BOUNDING BOX. A centre is one point, a box is two, and this solve needs \(minimumCorrespondenceCount): two centre-observed elements, or ONE bounds-observed element on its own. Nothing was registered; supply that array.")
        }
        guard let rawElements = args["elements"] as? [Any] else {
            return .failure("elements must be an ARRAY of {label, observed_x, observed_y} or {label, observed_left, observed_top, observed_right, observed_bottom} objects. Nothing was registered; send a JSON array, not an object keyed by label.")
        }
        guard rawElements.count <= maximumElementCount else {
            return .failure("elements has \(rawElements.count) entries, more than the \(maximumElementCount) this action accepts. Each element costs its own full breadth-first walk of \(app)'s accessibility hierarchy, which can take seconds against a large application. Nothing was registered; keep the \(maximumElementCount) most widely separated elements and drop the rest -- separation, not count, is what makes this solve accurate.")
        }

        var specs: [ElementSpec] = []
        specs.reserveCapacity(rawElements.count)
        for (index, raw) in rawElements.enumerated() {
            switch parseElement(raw, index: index) {
            case .failure(let error): return .failure(error)
            case .success(let spec): specs.append(spec)
            }
        }

        // COUNTED IN POINTS, NOT ELEMENTS -- see `minimumCorrespondenceCount`.
        // This runs LAST among the element checks on purpose: a caller whose
        // single element is also malformed should be told what is wrong with
        // that element, not handed the long "how to reach two points" lecture
        // for an element it would have had to fix anyway.
        let correspondenceCount = specs.reduce(0) { $0 + $1.observation.correspondenceCount }
        guard correspondenceCount >= minimumCorrespondenceCount else {
            return .failure(insufficientCorrespondencesRejection(specs, correspondenceCount: correspondenceCount))
        }

        return .success(Request(
            app: app, screenId: screenId, elements: specs,
            maxNodes: budgets.maxNodes, timeoutSeconds: budgets.timeoutSeconds
        ))
    }

    /// One `elements[i]` object.
    ///
    /// Every rejection names the INDEX as well as the label, because an agent
    /// that sent five elements and got back "label must be non-empty" has no
    /// way to know which of the five to fix.
    private static func parseElement(_ raw: Any, index: Int) -> DrawOutcome<ElementSpec> {
        guard let dict = raw as? [String: Any] else {
            return .failure("elements[\(index)] must be an object with label, observed_x, and observed_y fields.")
        }

        let unknownKeys = dict.keys.filter { !recognizedElementKeys.contains($0) }.sorted()
        guard unknownKeys.isEmpty else {
            let recognized = recognizedElementKeys.sorted().joined(separator: ", ")
            var message = "elements[\(index)] has unrecognized field(s) \(unknownKeys.joined(separator: ", ")); the only recognized fields are \(recognized). Nothing was registered."
            if unknownKeys.contains("x") || unknownKeys.contains("y") {
                message += " NOTE that this action deliberately does NOT reuse the marker route's x/y field names: a drawn marker has only an observed position, whereas an ELEMENT also has a TRUE position that Chalkboard reads for itself, and naming the caller's half observed_x/observed_y is what stops the two being confused for one another. Rename x/y to observed_x/observed_y."
            } else {
                message += " Drop the extra field(s) and retry."
            }
            return .failure(message)
        }

        guard let suppliedLabel = dict["label"] as? String else {
            return .failure("elements[\(index)] is missing a non-empty string label -- the element's accessible label, exactly as highlight_element takes it.")
        }
        let label = suppliedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= DrawingDefaults.maxHighlightLabelCharacters else {
            return .failure("elements[\(index)].label must be a non-empty string containing at most \(DrawingDefaults.maxHighlightLabelCharacters) characters.")
        }

        var role: String?
        if CalibrateScreenshotSpaceSupport.isSupplied(dict, "role") {
            guard let raw = dict["role"] as? String else {
                return .failure("elements[\(index)] (label '\(label)') has a non-string role; role must be a string when supplied.")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure("elements[\(index)] (label '\(label)') has an empty role; role must be non-empty when supplied.")
            }
            role = trimmed
        }

        let matchMode: AccessibilityLabelMatchMode
        if CalibrateScreenshotSpaceSupport.isSupplied(dict, "match") {
            guard let rawMatch = dict["match"] as? String else {
                return .failure("elements[\(index)] (label '\(label)') has a non-string match; match must be 'exact' or 'contains' when supplied.")
            }
            switch rawMatch.lowercased() {
            case "exact": matchMode = .exact
            case "contains": matchMode = .contains
            default:
                return .failure("elements[\(index)] (label '\(label)') has match '\(rawMatch)'; match must be 'exact' or 'contains'.")
            }
        } else {
            matchMode = .exact
        }

        var occurrence: Int?
        if CalibrateScreenshotSpaceSupport.isSupplied(dict, "occurrence") {
            guard let value = MCPArgument.integer(dict["occurrence"]) else {
                return .failure("elements[\(index)] (label '\(label)') has a non-integer occurrence; occurrence must be a one-based integer when supplied.")
            }
            guard value >= 1 else {
                return .failure("elements[\(index)] (label '\(label)') has occurrence \(value); occurrence must be one-based and greater than zero.")
            }
            occurrence = value
        }

        let observation: Observation
        switch parseObservation(dict, index: index, label: label) {
        case .failure(let error): return .failure(error)
        case .success(let value): observation = value
        }

        return .success(ElementSpec(
            label: label, role: role, matchMode: matchMode, occurrence: occurrence,
            observation: observation
        ))
    }

    /// WHICH of the two observation forms one `elements[i]` object supplied,
    /// or a rejection naming exactly what was wrong with the combination it
    /// actually sent.
    ///
    /// REJECT RATHER THAN REINTERPRET, four times over, because every
    /// plausible reinterpretation here is a silently wrong calibration:
    ///   * BOTH forms on one element -- there is no way to know which reading
    ///     the caller actually trusts, and preferring one would leave it
    ///     believing the other took effect.
    ///   * A PARTIAL box -- three edges do not describe a rectangle, and
    ///     filling the fourth in from the element's own resolved rect would
    ///     mean INVENTING the very measurement this calibration exists to
    ///     check against that rect.
    ///   * NEITHER form -- an element nobody observed is not a fiducial; it
    ///     is a label, and the solve has nothing to pair it with.
    ///   * An INVERTED or zero-area box -- swapped corners give a negative or
    ///     zero observed separation, which the solver would report as a
    ///     non-positive scale in prose about mismatched labels, diagnosing
    ///     the wrong mistake entirely.
    private static func parseObservation(_ dict: [String: Any], index: Int, label: String) -> DrawOutcome<Observation> {
        let phrase = labelPhrase(index: index, label: label)
        let suppliedCentre = centreObservationKeys.filter { CalibrateScreenshotSpaceSupport.isSupplied(dict, $0) }
        let suppliedBounds = boundsObservationKeys.filter { CalibrateScreenshotSpaceSupport.isSupplied(dict, $0) }

        guard suppliedCentre.isEmpty || suppliedBounds.isEmpty else {
            return .failure("\(phrase) is observed BOTH ways at once: it supplies \(suppliedCentre.joined(separator: " and ")) (a CENTRE) and \(suppliedBounds.joined(separator: ", ")) (a BOUNDING BOX). Exactly one form is allowed per element -- observing one element twice, in two different ways, leaves it ambiguous which reading should be trusted, and silently preferring one would leave you believing the other took effect. Nothing was registered; drop \(centreObservationKeys.joined(separator: "/")) to keep the bounding box (which yields TWO correspondences from this one element, enough to calibrate on its own), or drop \(boundsObservationKeys.joined(separator: "/")) to keep the centre (ONE correspondence, so a second element is then required).")
        }

        if !suppliedBounds.isEmpty {
            let missing = boundsObservationKeys.filter { !suppliedBounds.contains($0) }
            guard missing.isEmpty else {
                return .failure("\(phrase) supplies a PARTIAL bounding box: \(suppliedBounds.joined(separator: ", ")) \(suppliedBounds.count == 1 ? "was" : "were") supplied, but \(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") missing. All four edges are supplied together or not at all -- three edges do not describe a rectangle, and filling the fourth in from the element's own resolved rect would mean inventing the very measurement this calibration exists to check. Nothing was registered; add \(missing.joined(separator: ", ")) in YOUR screenshot's own pixel coordinates, or drop the bounds fields entirely and observe this element's CENTRE with \(centreObservationKeys.joined(separator: " and ")) instead.")
            }
            let unreadable = boundsObservationKeys.filter { MCPArgument.double(dict[$0]) == nil }
            // The `unreadable.isEmpty` guard is what makes the four bindings
            // below infallible; they are written as `guard let` rather than
            // force-unwrapped so that a future edit cannot turn a parsing
            // change into a crash.
            guard unreadable.isEmpty,
                  let left = MCPArgument.double(dict["observed_left"]),
                  let top = MCPArgument.double(dict["observed_top"]),
                  let right = MCPArgument.double(dict["observed_right"]),
                  let bottom = MCPArgument.double(dict["observed_bottom"]) else {
                let offending = unreadable.isEmpty ? boundsObservationKeys : unreadable
                return .failure("\(phrase) has \(offending.joined(separator: ", ")) that \(offending.count == 1 ? "is" : "are") not \(offending.count == 1 ? "a finite number" : "finite numbers"); all four of \(boundsObservationKeys.joined(separator: ", ")) must be finite numeric pixel coordinates -- that element's BOUNDING BOX in YOUR screenshot's own pixels. Nothing was registered.")
            }

            guard right > left else {
                return .failure(invertedBoundsFailure(
                    phrase: phrase, lowKey: "observed_left", lowValue: left,
                    highKey: "observed_right", highValue: right,
                    axisName: "width", edgesToReread: "that element's left and right edges"
                ))
            }
            guard bottom > top else {
                return .failure(invertedBoundsFailure(
                    phrase: phrase, lowKey: "observed_top", lowValue: top,
                    highKey: "observed_bottom", highValue: bottom,
                    axisName: "height", edgesToReread: "that element's top and bottom edges"
                ))
            }
            return .success(.bounds(left: left, top: top, right: right, bottom: bottom))
        }

        if !suppliedCentre.isEmpty {
            guard let observedX = MCPArgument.double(dict["observed_x"]),
                  let observedY = MCPArgument.double(dict["observed_y"]) else {
                return .failure("elements[\(index)] (label '\(label)') requires finite numeric observed_x and observed_y fields -- where that element's CENTRE appears in YOUR screenshot's own pixel coordinates. Nothing was registered.")
            }
            return .success(.centre(x: observedX, y: observedY))
        }

        return .failure("\(phrase) says nothing about where it appears in YOUR screenshot, so it is a label rather than a fiducial and there is nothing to pair its resolved position with. Every element must be observed in exactly ONE of two ways. Nothing was registered; add either its CENTRE -- \(centreObservationKeys.joined(separator: " and ")), which contributes one point, so at least two such elements are needed -- or its BOUNDING BOX -- \(boundsObservationKeys.joined(separator: ", ")), which contributes two (its top-left and bottom-right corners) and is therefore sufficient from this one element alone.")
    }

    /// The rejection for a bounding box whose two corners are the wrong way
    /// round on one axis, or identical on it.
    ///
    /// WHY THIS IS CAUGHT HERE AND NOT LEFT TO THE SOLVER. A swapped pair
    /// gives a negative observed separation and an equal pair gives zero, and
    /// `solveCorrespondences` does reject both -- but in prose written for
    /// the mistake it was expecting, "the observed order runs backwards
    /// relative to the true order, which means the labels and the observed
    /// points were mismatched". That is excellent advice for a caller who
    /// paired up two SEPARATE elements wrongly, and it is the wrong diagnosis
    /// entirely for a caller who wrote one element's own box back to front:
    /// there are no labels to re-pair. Naming the real mistake costs one
    /// comparison per axis.
    ///
    /// ZERO-AREA IS REJECTED TOO, and by the same `>` rather than a separate
    /// `==` branch: a box with no extent on an axis contributes no separation
    /// to it, which is simply the degenerate end of the same error.
    private static func invertedBoundsFailure(
        phrase: String, lowKey: String, lowValue: Double,
        highKey: String, highValue: Double,
        axisName: String, edgesToReread: String
    ) -> String {
        "\(phrase) has \(highKey)=\(highValue), which is not greater than \(lowKey)=\(lowValue), so its bounding box has zero or negative \(axisName) -- an inverted or empty box, not a rectangle this solve can read two corners off. Nothing was registered; the box is two OPPOSITE CORNERS in your screenshot's own pixel coordinates, where x increases rightwards and y increases downwards from the image's top-left: observed_left/observed_top are the SMALLER pair (the box's top-left corner) and observed_right/observed_bottom the LARGER pair (its bottom-right corner). Swap \(lowKey) and \(highKey) if they arrived reversed, or re-read \(edgesToReread) if the box genuinely came out empty."
    }

    /// THE MESSAGE A STUCK AGENT ACTUALLY READS, and the reason this whole
    /// change exists. Everything else here is arithmetic; this is the part
    /// that has to get an agent out of a dead end it cannot otherwise see the
    /// way out of.
    ///
    /// THE DEAD END, MEASURED. An agent driving DaVinci Resolve inside a
    /// Shadow PC remote-desktop client found exactly ONE labelled
    /// Accessibility element in the entire application -- the window itself,
    /// 'Shadow PC - Display' [AXWindow]. The old wording told it to "supply at
    /// least 2 elements... widely separated", advice that is unfollowable when
    /// the application publishes one element, and the agent's only remaining
    /// moves were to re-query for controls that do not exist or to abandon
    /// calibration and eyeball coordinates. The route out was available the
    /// whole time and the message never mentioned it: a rect is TWO points.
    ///
    /// So this message is built around the distinction the old one blurred --
    /// the requirement is two POINTS, not two ELEMENTS -- and it names the
    /// class of application that needs the bounds route in terms an agent can
    /// match against what it is actually looking at, rather than describing
    /// the arithmetic and leaving the inference to the reader.
    static func insufficientCorrespondencesRejection(_ specs: [ElementSpec], correspondenceCount: Int) -> String {
        let supplied: String
        if specs.isEmpty {
            supplied = "elements is empty, so this call observes nothing at all"
        } else {
            let named = specs
                .map { "'\(disambiguatedName(of: $0))' observed by its \($0.observation.payloadName.uppercased())" }
                .joined(separator: ", ")
            supplied = "elements supplies \(specs.count) entr\(specs.count == 1 ? "y" : "ies") -- \(named) -- which is \(correspondenceCount) point\(correspondenceCount == 1 ? "" : "s") in total"
        }
        return "calibrate_screenshot_space action=\"elements\" rejected: \(supplied), but this solve needs at least \(minimumCorrespondenceCount). Solving observed = scale * true + origin has two unknowns per axis, so a single point fixes only WHERE the image sits and never HOW BIG it is -- and the size is the entire thing being solved for. Nothing was registered."
            + "\n\nTWO POINTS, NOT TWO ELEMENTS, is the requirement, and there are two ways to reach it. (1) A CENTRE observation -- \(centreObservationKeys.joined(separator: ", ")) -- contributes ONE point per element, so that route needs 2 or more elements, WIDELY separated; 3 or more is better still, because a two-point fit is exact by construction and so cannot be cross-checked at all. (2) A BOUNDS observation -- \(boundsObservationKeys.joined(separator: ", ")), that element's bounding box in your own screenshot's pixels -- contributes TWO points from ONE element, its top-left corner and its bottom-right corner, so a single bounds-observed element is sufficient on its own."
            + "\n\nIF THIS APPLICATION EXPOSES ONLY ITS OWN WINDOW, USE THAT WINDOW. A remote-desktop or VNC client, a media player, a game -- anything that paints into one video or canvas surface -- is, to Accessibility, a window containing nothing, and no amount of re-querying will produce a second element: measured case, DaVinci Resolve inside a Shadow PC client published exactly one labelled element, its own window 'Shadow PC - Display' [AXWindow]. Send that ONE window as a single bounds-observed element. A window is large, so its two corners clear the solver's baseline gate (25% of the display on each axis) comfortably, and window edges are higher-contrast and less ambiguous in a screenshot than any control's centre. Report the box of the WINDOW FRAME as Accessibility reports it -- title bar included, drop shadow excluded -- not of the content area inside it; getting that wrong does not silently mis-scale, it lands as an origin residual the solver rejects, so a rejection there means you probably measured the content area."
    }

    /// The two Accessibility traversal budgets, validated exactly as
    /// `handleHighlightElement` validates its own.
    ///
    /// WHY THIS ACTION ACCEPTS THEM AT ALL. They are not in this route's
    /// minimum argument list, and it would be simpler to take the resolver's
    /// defaults. But the resolver's OWN failures explicitly instruct the
    /// caller to raise them -- `traversalLimitReached` and
    /// `traversalTimedOut` both name `max_nodes` and `timeout_seconds` as
    /// the only two things that move their outcome, and both are entirely
    /// reachable here (a measured DaVinci Resolve session exceeded 60,000
    /// elements in 11 seconds without completing). An action that surfaces
    /// that advice while refusing the arguments it names would hand back
    /// instructions the caller cannot act on, which is precisely the defect
    /// those two error messages were rewritten to fix. They matter MORE
    /// here than in `highlight_element`, because this action performs one
    /// full walk per element rather than one per call.
    ///
    /// The wording below is deliberately identical to
    /// `handleHighlightElement`'s: the same argument, the same bounds and
    /// the same failure should not read as two different rules depending on
    /// which tool the caller reached them through. That parsing currently
    /// lives inline in `MCPToolHandlers+Highlight.swift`, which this change
    /// does not own; if it is ever extracted into a shared helper, this
    /// function should become a call to it rather than a second survivor.
    private static func parseTraversalBudgets(_ args: [String: Any]) -> DrawOutcome<(maxNodes: Int, timeoutSeconds: TimeInterval)> {
        if args.keys.contains("max_nodes"), MCPArgument.integer(args["max_nodes"]) == nil {
            return .failure("max_nodes must be an integer between 1 and \(AccessibilityElementResolver.absoluteMaxNodes) when supplied.")
        }
        let maxNodes = MCPArgument.integer(args["max_nodes"]) ?? AccessibilityElementResolver.defaultMaxNodes
        guard maxNodes > 0, maxNodes <= AccessibilityElementResolver.absoluteMaxNodes else {
            return .failure("max_nodes must be between 1 and \(AccessibilityElementResolver.absoluteMaxNodes).")
        }
        if MCPArgument.hasInvalidSuppliedDouble(args, key: "timeout_seconds") {
            return .failure("timeout_seconds must be a finite number when supplied.")
        }
        let timeoutSeconds = MCPArgument.double(args["timeout_seconds"]) ?? AccessibilityElementResolver.defaultTraversalTimeoutSeconds
        guard timeoutSeconds >= AccessibilityElementResolver.minTraversalTimeoutSeconds,
              timeoutSeconds <= AccessibilityElementResolver.maxTraversalTimeoutSeconds else {
            return .failure("timeout_seconds must be between \(AccessibilityElementResolver.minTraversalTimeoutSeconds) and \(AccessibilityElementResolver.maxTraversalTimeoutSeconds).")
        }
        return .success((maxNodes, timeoutSeconds))
    }

    // MARK: - The same-display rule

    /// Decides WHICH display this screenshot is of, from the displays the
    /// elements themselves landed on, and checks that answer against an
    /// explicit `screen_id` when one was supplied.
    ///
    /// WHY ALL ELEMENTS MUST AGREE. A screenshot is the image of ONE display.
    /// Every number this route solves -- the per-axis scale, the origin
    /// residual, the final `screenshotPx` size -- is expressed in one
    /// display's backing pixels, so two fiducials on two different displays
    /// do not describe a capture at all: they describe two captures, and the
    /// arithmetic that mixed them would still produce a perfectly
    /// well-formed, entirely wrong `ScreenshotSpace`. That is the same class
    /// of silent, self-consistent misplacement `ScreenshotSpace` exists to
    /// close, so it is a rejection rather than a preference for the majority
    /// display.
    ///
    /// WHY THE DERIVED ANSWER IS PREFERRED OVER `screen_id`. The elements'
    /// own resolved `screenId` is EVIDENCE -- Chalkboard read it from the
    /// live display arrangement -- whereas `screen_id` is an assertion the
    /// caller had to already know. Defaulting to the main display when
    /// `screen_id` is omitted would be worse still: on a two-monitor desk the
    /// target app is very often not on the main display, and a defaulted
    /// display is exactly how a space gets registered against a screen the
    /// screenshot is not of. So `screen_id` is optional, and when it IS
    /// supplied it is treated as a claim to be CHECKED, never as an override.
    static func resolveDisplay(
        _ resolved: [ResolvedElement], explicitScreenId: String?
    ) -> DrawOutcome<String> {
        guard let first = resolved.first else {
            return .failure("No elements were resolved, so there is no display to calibrate against. Nothing was registered; supply at least one element -- one observed by its BOUNDING BOX (observed_left/observed_top/observed_right/observed_bottom) is enough on its own, two observed by their CENTRES otherwise.")
        }

        var distinctScreenIds: [String] = []
        for element in resolved where !distinctScreenIds.contains(element.frame.screenId) {
            distinctScreenIds.append(element.frame.screenId)
        }

        guard distinctScreenIds.count == 1 else {
            let breakdown = resolved
                .map { "'\($0.spec.label)' on display \($0.frame.screenId)" }
                .joined(separator: ", ")
            return .failure("calibrate_screenshot_space action=\"elements\" rejected: the elements resolved onto \(distinctScreenIds.count) DIFFERENT displays (\(breakdown)). A screenshot is the image of ONE display, and every number this route solves is expressed in one display's backing pixels, so fiducials spanning two displays cannot describe a single capture -- mixing them would still register a perfectly well-formed screenshot_space that misplaces every coordinate drawn through it. Nothing was registered; retry with elements that all sit on the one display your screenshot is of, moving the target window fully onto that display first if it currently straddles two.")
        }

        let derived = first.frame.screenId
        if let explicitScreenId, explicitScreenId != derived {
            let labels = resolved.map { "'\($0.spec.label)'" }.joined(separator: ", ")
            return .failure("calibrate_screenshot_space action=\"elements\" rejected: you passed screen_id '\(explicitScreenId)', but every element (\(labels)) resolved onto display '\(derived)'. The resolved positions are MEASURED from the live display arrangement while screen_id is an assertion, so this disagreement is treated as a mistake rather than silently resolved either way -- registering against '\(explicitScreenId)' would describe a display the fiducials are not on. Nothing was registered; drop screen_id and let the elements name their own display, or pass '\(derived)' if that is genuinely the display your screenshot is of.")
        }
        return .success(derived)
    }

    // MARK: - Geometry and payload

    /// The element's TRUE point: the centre of the rect Accessibility
    /// reported for it.
    ///
    /// CENTRE, NOT ORIGIN, for two independent reasons. It is the point a
    /// reader can pick out of a screenshot without first agreeing where the
    /// element's padding, shadow, or focus ring ends -- corners are exactly
    /// where a reported frame and its painted pixels disagree most. And it is
    /// the point least sensitive to that disagreement being asymmetric:
    /// padding that adds a pixel on each side moves both corners and leaves
    /// the centre alone.
    ///
    /// Deliberately ONE function used by both `correspondences` (which feeds
    /// the solver) and `elementsPayload` (which reports what was fed to it).
    /// A second copy would let the reported centre drift from the solved one,
    /// which is the worst possible drift: the payload's whole job is to let a
    /// caller audit the solve.
    static func backingCenter(of frame: AccessibilityBackingRect) -> (x: Double, y: Double) {
        (frame.x + frame.width / 2, frame.y + frame.height / 2)
    }

    /// The element's TWO TRUE POINTS when it was observed by its BOUNDING
    /// BOX: the opposite corners of the rect Accessibility reported for it.
    ///
    /// THIS IS THE WHOLE TRICK. `backingCenter` above collapses a rect to one
    /// point, which is why a centre-observed element cannot calibrate alone.
    /// The rect it collapsed always held two, with a known separation on BOTH
    /// axes -- exactly what the solve needs -- and for an application whose
    /// only Accessibility element is its own window, those two are the only
    /// two points in existence.
    ///
    /// `(minX, minY)` and `(maxX, maxY)` specifically, not the other
    /// diagonal: they are the pair whose separation is positive on both axes,
    /// so they pair term-for-term with the caller's left/top and
    /// right/bottom and the solver's per-axis ordering never has to be
    /// reasoned about twice.
    ///
    /// Deliberately ONE function, for the same reason `backingCenter` is:
    /// `correspondences` feeds these points to the solver and
    /// `elementsPayload` reports them, and a second copy would let the
    /// reported corner drift from the solved one -- which is the worst
    /// possible drift, since the payload's only job is to let a caller audit
    /// the solve.
    static func backingCorners(
        of frame: AccessibilityBackingRect
    ) -> (topLeft: (x: Double, y: Double), bottomRight: (x: Double, y: Double)) {
        ((frame.x, frame.y), (frame.x + frame.width, frame.y + frame.height))
    }

    /// The solver's input: each element's true backing point(s) paired with
    /// what the caller says it saw -- a CENTRE against the resolved rect's
    /// centre, or a BOUNDING BOX against that rect's two opposite corners.
    /// `name` carries the label the CALLER used, not the app's matched label,
    /// because a rejection has to name the element in the words the caller
    /// can find in its own request.
    ///
    /// THE OCCURRENCE SUFFIX IS NOT DECORATION. Distinct elements routinely
    /// share one accessible label -- a live Finder window answers to
    /// "Desktop" five times over, as a window, a radio button, and three
    /// separate static texts -- and `occurrence` is the only thing telling
    /// them apart in the request. Without it, every solver rejection that
    /// names two elements reads as though it named the same one twice
    /// ("the two elements furthest apart are 'Desktop' and 'Desktop', only
    /// 13.5 backing px apart"), which reads as a bug in the tool rather than
    /// as the actionable "you picked two elements that sit almost on top of
    /// each other" it actually is. Observed live against Finder; see
    /// `disambiguatedName`.
    ///
    /// ONE ELEMENT IS NOT ONE CORRESPONDENCE ANY MORE, which is why this
    /// `flatMap`s rather than `map`s: a bounds-observed element yields TWO,
    /// its top-left corner and its bottom-right corner. Everything
    /// downstream -- the "at least 2" gate, the redundancy caveat, the
    /// payload's tally -- counts what comes OUT of here, never the number of
    /// elements that went in.
    ///
    /// THE CORNER SUFFIXES ARE NOT DECORATION, for the same reason the
    /// occurrence suffix below is not. Every solver rejection names the two
    /// correspondences it could not reconcile, and a window calibrated from
    /// its own two corners would otherwise produce "'Shadow PC - Display' and
    /// 'Shadow PC - Display' are only 0 backing px apart" -- which reads as a
    /// bug in the tool rather than as "your two corners are the wrong way
    /// round" or "the box you read is far too small". With the suffixes, a
    /// rejection says WHICH corner was inconsistent, which is the one thing a
    /// caller can act on.
    ///
    /// The bounds fiducials go through this ordinary `Correspondence` array
    /// and nothing else: `solveCorrespondences` is not told which form
    /// produced which point, and no arithmetic of its own is duplicated here.
    /// A box is simply two more points on the same fit.
    static func correspondences(_ resolved: [ResolvedElement]) -> [ScreenshotCalibration.Correspondence] {
        resolved.flatMap { element -> [ScreenshotCalibration.Correspondence] in
            let name = disambiguatedName(of: element.spec)
            switch element.spec.observation {
            case .centre(let observedX, let observedY):
                let center = backingCenter(of: element.frame)
                return [ScreenshotCalibration.Correspondence(
                    name: name,
                    trueX: center.x, trueY: center.y,
                    observedX: observedX, observedY: observedY
                )]
            case .bounds(let left, let top, let right, let bottom):
                let corners = backingCorners(of: element.frame)
                return [
                    ScreenshotCalibration.Correspondence(
                        name: "\(name) top-left corner",
                        trueX: corners.topLeft.x, trueY: corners.topLeft.y,
                        observedX: left, observedY: top
                    ),
                    ScreenshotCalibration.Correspondence(
                        name: "\(name) bottom-right corner",
                        trueX: corners.bottomRight.x, trueY: corners.bottomRight.y,
                        observedX: right, observedY: bottom
                    )
                ]
            }
        }
    }

    /// How one requested element is named inside a solver rejection: the
    /// caller's own label, plus its `occurrence` when it supplied one.
    ///
    /// Kept separate and pure so the "two different elements sharing a label
    /// must not print identically" property is directly testable without a
    /// live Accessibility hierarchy to produce the collision.
    static func disambiguatedName(of spec: ElementSpec) -> String {
        guard let occurrence = spec.occurrence else { return spec.label }
        return "\(spec.label) (occurrence \(occurrence))"
    }

    /// What the success payload says about each fiducial: what was asked for,
    /// what answered, HOW it was observed, where Chalkboard measured it, and
    /// where the caller said it saw it.
    ///
    /// THE SHAPE FOLLOWS THE OBSERVATION FORM. A centre-observed element
    /// reports `resolvedBackingCenter`/`observedCenter`, exactly as it always
    /// has; a bounds-observed one reports
    /// `resolvedBackingCorners`/`observedCorners`, each with a `topLeft` and
    /// a `bottomRight`. Both spellings are the literal points that were fed
    /// to the solver, so the audit compares like with like -- a bounds
    /// element's centre is deliberately absent, because no such point took
    /// part in the fit.
    ///
    /// REPORTED IN FULL ON PURPOSE. Unlike the marker route -- where
    /// Chalkboard chose the true positions itself and the caller already knows
    /// them -- both halves of every pair here are things the caller cannot
    /// otherwise see: it never learns the Accessibility rect, and it has no
    /// way to confirm that `match: "contains"` picked the control it meant.
    /// Printing the pairs is what makes a suspicious result diagnosable
    /// ("that is not the Save button I meant") instead of merely wrong.
    ///
    /// Every emitted `Double` goes through `displayRounded`, which is also
    /// this payload's guarantee that no non-finite value can reach
    /// `JSONSerialization`. Finiteness is in fact already established by the
    /// time this runs -- `solveCorrespondences` rejects a non-finite
    /// coordinate before anything is registered -- so this is belt-and-braces
    /// against a future reordering, not the primary check.
    static func elementsPayload(_ resolved: [ResolvedElement]) -> [[String: Any]] {
        resolved.map { element in
            var entry: [String: Any] = [
                "label": element.spec.label,
                "matchedLabel": element.matchedLabel,
                "role": element.resolvedRole ?? NSNull(),
                "screenId": element.frame.screenId,
                // WHICH FORM WAS USED, said outright rather than left to be
                // inferred from which coordinate keys are present. A caller
                // auditing a space it registered an hour ago needs to know
                // whether one element contributed one point or two before any
                // of the numbers below mean anything -- and a caller that
                // MEANT to send a box, mistyped a key and got a centre solve
                // finds it here.
                "observation": element.spec.observation.payloadName,
                "correspondences": element.spec.observation.correspondenceCount
            ]
            switch element.spec.observation {
            case .centre(let observedX, let observedY):
                let center = backingCenter(of: element.frame)
                entry["resolvedBackingCenter"] = [
                    "x": CalibrateScreenshotSpaceSupport.displayRounded(center.x),
                    "y": CalibrateScreenshotSpaceSupport.displayRounded(center.y)
                ]
                entry["observedCenter"] = [
                    "x": CalibrateScreenshotSpaceSupport.displayRounded(observedX),
                    "y": CalibrateScreenshotSpaceSupport.displayRounded(observedY)
                ]
            case .bounds(let left, let top, let right, let bottom):
                // BOTH CORNERS, RESOLVED AND OBSERVED, and deliberately NOT
                // the rect's centre: the centre was never solved from, and
                // reporting a point that took no part in the fit is exactly
                // how an audit talks a reader into checking the wrong number.
                // These four points ARE the two correspondences this element
                // contributed, in the same order and under the same corner
                // names a solver rejection would use.
                let corners = backingCorners(of: element.frame)
                entry["resolvedBackingCorners"] = [
                    "topLeft": [
                        "x": CalibrateScreenshotSpaceSupport.displayRounded(corners.topLeft.x),
                        "y": CalibrateScreenshotSpaceSupport.displayRounded(corners.topLeft.y)
                    ],
                    "bottomRight": [
                        "x": CalibrateScreenshotSpaceSupport.displayRounded(corners.bottomRight.x),
                        "y": CalibrateScreenshotSpaceSupport.displayRounded(corners.bottomRight.y)
                    ]
                ]
                entry["observedCorners"] = [
                    "topLeft": [
                        "x": CalibrateScreenshotSpaceSupport.displayRounded(left),
                        "y": CalibrateScreenshotSpaceSupport.displayRounded(top)
                    ],
                    "bottomRight": [
                        "x": CalibrateScreenshotSpaceSupport.displayRounded(right),
                        "y": CalibrateScreenshotSpaceSupport.displayRounded(bottom)
                    ]
                ]
            }
            return entry
        }
    }

    /// The warning a two-CORRESPONDENCE calibration MUST carry, and a
    /// three-or-more one must not.
    ///
    /// COUNTED IN CORRESPONDENCES, NOT ELEMENTS, and that is not a rename.
    /// A single bounds-observed element -- the remote-desktop window case
    /// this route exists for -- is TWO correspondences from ONE element, and
    /// it is the most exposed input this route accepts: the fit reproduces
    /// both of its corners exactly, and there is no third point anywhere to
    /// disagree with them. Counting elements would have handed that request a
    /// caveat reading "with exactly 1 elements", or, had the threshold been
    /// left at `< 3` elements, would have gone on firing for a genuinely
    /// cross-checked four-correspondence pair of boxes. Both counts have to
    /// be the one the arithmetic uses.
    ///
    /// WHY THE PAYLOAD HAS TO SAY THIS. With exactly two correspondences the
    /// per-axis fit `observed = scale * true + origin` has two unknowns and
    /// two equations: it reproduces both readings EXACTLY, whatever they
    /// were. The solver's redundancy check -- the element-route equivalent of
    /// the four-marker route's cross-marker check -- has nothing left over to
    /// test against, so a badly misread pair produces a clean-looking solve
    /// with zero residuals. That is not a defect in the solver; it is what a
    /// determined system means. A caller reading `provenance: "observed"` and
    /// residuals of 0 would reasonably conclude the calibration was verified,
    /// and here it simply was not, so the payload says so in as many words.
    static func redundancyCaveat(correspondenceCount: Int) -> String? {
        guard correspondenceCount < 3 else { return nil }
        return "MEASURED BUT NOT CROSS-CHECKED: this solve had exactly \(correspondenceCount) correspondences (two centre-observed elements, or one bounds-observed element contributing both of its corners), and with two readings per axis the fit has two unknowns and reproduces both of them exactly no matter what they were -- residuals of zero here mean the arithmetic is consistent, NOT that the readings were right. Add a third point to get a real redundancy check: 3 or more widely separated elements, or the one bounds-observed element plus any second element. Confirm any drawing made through this space with verify_annotation."
    }

    // MARK: - Failure wording

    /// The ONE sentence every `action="elements"` rejection carries.
    ///
    /// WHY IT IS WORTH SAYING EVERY TIME: the three sibling actions on this
    /// tool are a stateful handshake, and their documented contract is full
    /// of cleanup promises -- `begin` paints crosshairs and forces
    /// capture-debug on, a rejected `resolve` still clears them, `cancel`
    /// exists purely to undo them. An agent carrying that model into this
    /// action and receiving a rejection has every reason to believe something
    /// is now stranded on the user's screen, and its next move is a
    /// `cancel` it has no `calibration_id` for, or a fresh `begin` that
    /// really does paint markers. Saying plainly that nothing happened is
    /// what stops a rejected call from turning into visible clutter.
    ///
    /// Stated in one place, exactly like
    /// `CalibrateScreenshotSpaceSupport.resolveRejectionMessage` states the
    /// opposite promise for the marker route, so neither can drift branch by
    /// branch.
    static func rejection(_ error: String) -> String {
        "\(error) (calibrate_screenshot_space action=\"elements\" is single-shot and stateless: nothing was drawn on the user's screen, no calibration session was opened, capture-visible was not touched, and there is nothing to cancel -- just retry this one call with the correction above.)"
    }

    /// Wraps a failure from the app resolution `highlight_element` and this
    /// action SHARE, so the caller learns which tool rejected it without
    /// losing the specific diagnosis.
    ///
    /// The shared lookup's own prose names `highlight_element`, because that
    /// is the tool it was written for and this change does not own that file.
    /// Rewriting the message here would mean re-deriving its ambiguity and
    /// not-running cases -- a second resolution path in all but name, and
    /// exactly what must not happen. Quoting it verbatim under a sentence
    /// that explains the shared lookup keeps one implementation and one
    /// vocabulary.
    static func appResolutionFailure(_ error: String, app: String) -> String {
        "calibrate_screenshot_space action=\"elements\" could not resolve app '\(app)'. It uses the SAME running-application lookup highlight_element uses -- one app, one PID, no guessing between instances -- and that lookup reported: \(error) Nothing was registered."
    }

    /// Wraps one element's Accessibility lookup failure.
    ///
    /// Names the INDEX and the LABEL because a caller that sent four elements
    /// otherwise cannot tell which one to fix, and states that this route
    /// needs the ACCESSIBILITY grant specifically -- an agent that has just
    /// been fighting an invisible-fiducial problem will otherwise assume this
    /// is the same Screen Recording permission failing again, and go looking
    /// in the wrong pane of System Settings.
    ///
    /// The disambiguation advice is PLATFORM-SPLIT, following
    /// `MCPToolCatalog`'s precedent: the macOS resolver's ambiguity error
    /// carries a per-candidate list (label, role and backing frame for each),
    /// while the Windows resolver reports only how MANY candidates matched.
    /// Promising a Windows caller a list it will never receive would send it
    /// re-reading an error for information that does not exist there.
    static func elementResolutionFailure(_ error: String, index: Int, label: String) -> String {
        #if os(macOS)
        let disambiguation = "If that failure was an ambiguity, the message above lists the candidates it found, with each one's role and backing frame -- pick one with role, or with a one-based occurrence."
        #elseif os(Windows)
        let disambiguation = "If that failure was an ambiguity, the message above reports only HOW MANY candidates matched: this platform's UI Automation lookup publishes no per-candidate list, so disambiguate with role, or with a one-based occurrence."
        #endif
        return "calibrate_screenshot_space action=\"elements\" could not resolve elements[\(index)] (label '\(label)'): \(error) \(disambiguation) This route reads element positions through ACCESSIBILITY, not Screen Recording -- a screen-capture grant has no bearing on it, and no screenshot of any kind is taken. Nothing was registered; correct that one element and resend the whole elements array."
    }

    /// The rejection for the post-walk re-confirmation of an element's
    /// backing rect.
    ///
    /// WHAT THIS GUARDS, in `handleHighlightElement`'s own words: the display
    /// snapshot used to convert an element's frame is taken BEFORE a walk
    /// that may legitimately run for seconds, and a display reconfiguration
    /// in between silently moves the answer -- the conversion anchors to the
    /// zero-origin display's height, picks the containing screen by frame,
    /// and multiplies by that screen's backing scale factor, all three of
    /// which change when a monitor is added, removed, rearranged or
    /// rescaled. It fails invisibly: a well-formed rectangle in the wrong
    /// place. Re-deriving against a FRESH snapshot and demanding the two
    /// agree makes it detectable, and DISAGREEMENT IS A REJECTION rather
    /// than a re-derivation, because if the two differ then the frame itself
    /// was measured in an arrangement that can no longer be identified and
    /// neither conversion is trustworthy.
    ///
    /// This route runs that check once PER ELEMENT and over a window that is
    /// longer still -- one walk per element, serially -- so the check matters
    /// more here, not less.
    static func displayLayoutChangedFailure(index: Int, label: String) -> String {
        "The display layout changed while \(labelPhrase(index: index, label: label))'s accessibility frame was being read, so its screen coordinates cannot be converted safely -- the frame was measured against the previous arrangement, and converting it against the current one would produce a well-formed rectangle in the wrong place. Nothing was registered. This is transient: retry the same call once the layout settles, and do not fall back to eyeballed screenshot coordinates -- the elements themselves resolved fine."
    }

    private static func labelPhrase(index: Int, label: String) -> String {
        "elements[\(index)] (label '\(label)')"
    }
}

/// Pure geometry for painting `ScreenshotCalibration.markers` as on-screen
/// fiducials: where each marker's centre lands in backing pixels, the SVG
/// path for its "crosshair-in-a-circle" glyph, and where its text label sits
/// beside it.
///
/// Deliberately built directly as `AnnotationKind` cases in
/// `MCPServer.drawCalibrationFiducials` below, rather than through
/// `MCPServer.makeVectorPathKind`/the file-private `makeTextKind` in
/// `MCPToolHandlers+Drawing.swift` (which is not even visible outside that
/// file): every value here is produced by THIS file, not parsed from a
/// caller's untrusted JSON, so there is no validation to reuse -- only the
/// geometry helper `ellipsePathData` (declared free, in
/// `MCPToolHandlers+Shape.swift`, and used identically by `draw_shape`/
/// `highlight_element`) is shared, which is the part actually worth not
/// re-deriving. What IS reused, unchanged, is the part that matters for
/// consistency with every other drawing: `AnnotationComponent`/
/// `AnnotationKind.batch`/`DrawRequest.finish`, the exact storage/app-link/
/// success-reporting pipeline `draw_batch` itself runs through.
enum ScreenshotCalibrationMarkerDrawing {
    static let circleRadiusPx: Double = 14
    static let crosshairHalfLengthPx: Double = 22
    static let strokeWidthPx: Double = 3
    static let labelFontSizePx: Double = 16
    static let labelOffsetPx: Double = 20
    static let tokenFontSizePx: Double = 28

    /// The backing-pixel centre of `marker` on `screen`: a pure per-axis
    /// multiply of its NORMALIZED position by that display's own backing
    /// pixel size -- the same arithmetic `DrawRequest.CoordinateTransform`'s
    /// `'normalized'` branch performs for a caller-supplied point.
    static func backingCenter(of marker: ScreenshotCalibration.Marker, on screen: ScreenInfo) -> (x: Double, y: Double) {
        (marker.normalizedX * Double(screen.widthPx), marker.normalizedY * Double(screen.heightPx))
    }

    /// One high-contrast "crosshair-in-a-circle" as a single multi-subpath
    /// SVG path: a filled white, black-outlined circle (so it reads against
    /// either a light or dark background) plus a black crosshair through its
    /// centre. The circle comes from the exact two-arc `ellipsePathData`
    /// helper `draw_shape`/`highlight_element` already use -- not a fourth
    /// hand-rolled arc implementation -- with the crosshair's two straight
    /// line subpaths appended after it. A fill rule applied to this whole
    /// path fills only the closed circle subpath; the two open line subpaths
    /// contribute zero enclosed area, so they are effectively stroke-only.
    static func markerPathData(center: (x: Double, y: Double)) -> String {
        let circle = ellipsePathData(centerX: center.x, centerY: center.y, radiusX: circleRadiusPx, radiusY: circleRadiusPx)
        let horizontal = "M \(center.x - crosshairHalfLengthPx) \(center.y) L \(center.x + crosshairHalfLengthPx) \(center.y)"
        let vertical = "M \(center.x) \(center.y - crosshairHalfLengthPx) L \(center.x) \(center.y + crosshairHalfLengthPx)"
        return "\(circle) \(horizontal) \(vertical)"
    }

    /// Where the marker's text label ("TL", "TR", "BL", "BR") is drawn,
    /// offset up-and-right of the circle by a fixed amount. Safe for every
    /// corner at the 0.1/0.9 marker inset on any display this tool will
    /// plausibly run against: the offset is a few tens of pixels, far
    /// smaller than the 10%-of-display margin every marker sits inside.
    static func labelPosition(center: (x: Double, y: Double)) -> (x: Double, y: Double) {
        (center.x + circleRadiusPx + labelOffsetPx, center.y - circleRadiusPx - labelOffsetPx)
    }
}

/// Mints a short, human-typeable random token an agent reads back from its
/// OWN screenshot to prove that image is THIS calibration and not a stale
/// one left over from an earlier `begin` call. Excludes visually ambiguous
/// characters (0/O, 1/I) that a model reading a low-resolution or
/// heavily-compressed screenshot could easily transpose.
enum ScreenshotCalibrationToken {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let length = 6

    static func random() -> String {
        var token = ""
        token.reserveCapacity(length)
        for _ in 0..<length {
            token.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return token
    }
}

/// Tracks outstanding `calibrate_screenshot_space` handshakes between
/// `begin` and `resolve`/`cancel`.
///
/// WHY THIS EXISTS: `begin` draws real, ordinary annotations on the user's
/// screen and, by default, flips capture-debug mode on -- both are STATE
/// CHANGES that must be undone no matter how the handshake ends (a clean
/// `resolve`, a rejected solve, or an explicit `cancel`; see
/// `MCPServer.clearCalibrationSession`). Without a durable record of WHICH
/// annotation ids were drawn and WHAT capture-visible value preceded them, a
/// failed or abandoned calibration would strand fiducials on the user's
/// screen -- in direct violation of this repo's "a drawing persists until
/// explicitly cleared, but nothing here creates clutter the caller cannot
/// account for" guarantee -- and leave capture-debug mode stuck on.
///
/// Thread-safe (a plain `NSLock`) and bounded, mirroring
/// `ScreenshotSpaceRegistry`'s exact shape in
/// `Sources/Support/ScreenshotSpace.swift`: an agent that calls `begin`
/// repeatedly without ever resolving/cancelling must not grow this store
/// without bound, so the oldest outstanding session is evicted (and its
/// fiducials/capture-visible are NOT auto-restored by eviction alone -- see
/// `MCPServer.handleCalibrateScreenshotSpaceBegin`'s own per-display
/// "only one outstanding calibration" rule, which is the mechanism that
/// actually keeps this bounded in ordinary use; the eviction cap here is
/// belt-and-braces against a caller that ignores that rule across MANY
/// different displays).
final class ScreenshotCalibrationRegistry: @unchecked Sendable {
    static let shared = ScreenshotCalibrationRegistry()

    static let maxEntries = 16

    struct Session {
        let id: String
        let screenId: String
        let token: String
        let annotationIds: [String]
        let previousCaptureVisible: Bool
        /// Whether THIS session is one of the sessions currently forcing
        /// capture-debug on. False when `begin` was called with
        /// `set_capture_visible=false`, which changes the flag not at all --
        /// and such a session must therefore not restore anything when it
        /// ends, because it never saved anything meaningful.
        let forcedCaptureVisible: Bool
    }

    private let lock = NSLock()
    /// Oldest-registered first, mirroring `ScreenshotSpaceRegistry.order`.
    private var order: [Session] = []
    private var byId: [String: Session] = [:]
    private let makeId: () -> String

    /// The capture-debug value that was in effect before the FIRST currently
    /// outstanding session forced it on, or `nil` when no session is forcing
    /// it right now.
    ///
    /// WHY A SHARED BASELINE RATHER THAN A PER-SESSION ONE: capture-debug is
    /// a single PROCESS-WIDE flag (`OverlayWindowController.setCaptureVisible`
    /// has no per-display dimension), but calibrations are per-display and
    /// two can legitimately be outstanding at once on a two-monitor desktop.
    /// With each session saving and restoring the flag independently, the
    /// save/restore pairs nest incorrectly and BOTH ends break:
    ///
    ///   1. `begin` D1 records previous=false and forces the flag on.
    ///   2. `begin` D2 records previous=TRUE -- the value D1 just set -- since
    ///      the per-display dedupe keys on screen id and does not fire.
    ///   3. `resolve` D1 restores false, turning capture-debug OFF while D2's
    ///      fiducials are still on screen and still need to reach the
    ///      caller's screenshot. D2's handshake silently stops working.
    ///   4. `resolve` D2 restores TRUE, leaving capture-debug stuck on with
    ///      no calibration outstanding at all -- the menu-bar icon orange and
    ///      every annotation rendering over every app until the five-minute
    ///      auto-revert.
    ///
    /// Reference counting fixes both: the first forcing session records the
    /// real baseline, later forcing sessions inherit it, and only the LAST
    /// one to finish restores it.
    private var captureBaseline: Bool?

    init(idGenerator: @escaping () -> String = ScreenshotCalibrationRegistry.randomId) {
        self.makeId = idGenerator
    }

    static func randomId() -> String {
        let hexDigits = Array("0123456789abcdef")
        var suffix = ""
        suffix.reserveCapacity(8)
        for _ in 0..<8 {
            suffix.append(hexDigits[Int.random(in: 0..<hexDigits.count)])
        }
        return "calibration-" + suffix
    }

    /// The outstanding session for `screenId`, if any -- a non-mutating
    /// peek, used by `begin` to detect and report "a previous calibration
    /// for this display was cleared" BEFORE registering the new one.
    func existingSession(forScreenId screenId: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return order.first(where: { $0.screenId == screenId })
    }

    /// Registers a brand-new session unconditionally. Callers enforce "only
    /// one outstanding calibration per display" THEMSELVES, by calling
    /// `existingSession(forScreenId:)` and `remove(id:)` first -- kept out of
    /// this method so the caller can clear that prior session's fiducials
    /// and restore ITS capture-visible value (both of which require
    /// `MCPServer`/`AnnotationStore`/`OverlayWindowController`, none of which
    /// this registry touches) BEFORE this registry's own state changes,
    /// rather than this method silently discarding a live session's record
    /// while its fiducials are still on screen.
    /// Claims the process-wide capture-debug flag for a session that is about
    /// to be registered, returning the baseline value that must eventually be
    /// restored.
    ///
    /// Returns the CURRENT value the caller passes in when this is the first
    /// forcing session (there is nothing saved yet, so this reading becomes
    /// the baseline), or the ALREADY-SAVED baseline when another forcing
    /// session is still outstanding -- which is the whole point: the second
    /// caller must not record "true" just because the first one already
    /// turned it on. See `captureBaseline`'s doc comment for the two-monitor
    /// failure this prevents.
    ///
    /// Taken as a parameter rather than read from `OverlayWindowController`
    /// here so this registry stays free of AppKit/overlay dependencies and
    /// remains unit-testable headlessly, exactly like the rest of this type.
    func claimCaptureBaseline(currentCaptureVisible: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = captureBaseline { return existing }
        captureBaseline = currentCaptureVisible
        return currentCaptureVisible
    }

    /// Releases one forcing session's claim. Returns the value to restore the
    /// process-wide flag to when this was the LAST outstanding forcing
    /// session, or `nil` when another forcing session is still running and
    /// capture-debug must therefore stay on.
    ///
    /// Call this AFTER the session has been removed from the registry, so the
    /// "is anyone else still forcing it" question is asked about the sessions
    /// that actually remain.
    func releaseCaptureBaseline() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard order.contains(where: { $0.forcedCaptureVisible }) == false else { return nil }
        let baseline = captureBaseline
        captureBaseline = nil
        return baseline
    }

    @discardableResult
    func register(screenId: String, token: String, annotationIds: [String], previousCaptureVisible: Bool, forcedCaptureVisible: Bool) -> Session {
        lock.lock()
        defer { lock.unlock() }

        var id = makeId()
        var attempts = 0
        // Bounded id-collision retry -- an injected generator that always
        // collides must fail closed (falling back to a still-unique,
        // timestamp-suffixed id) rather than spin this lock forever. Mirrors
        // the fix PHASE_B_SPEC.md's ADDENDUM 2 requires for
        // `ScreenshotSpaceRegistry.register`'s equivalent loop, applied here
        // even though that specific defect lives in a file this phase does
        // not touch, because a fresh registry with the same unbounded-loop
        // shape would simply reintroduce it.
        while byId[id] != nil, attempts < 1_000 {
            id = makeId()
            attempts += 1
        }
        if byId[id] != nil {
            id = "calibration-fallback-\(order.count)-\(UInt64(Date().timeIntervalSince1970 * 1_000_000))"
        }

        if order.count >= Self.maxEntries {
            let evicted = order.removeFirst()
            byId.removeValue(forKey: evicted.id)
        }

        let session = Session(id: id, screenId: screenId, token: token, annotationIds: annotationIds, previousCaptureVisible: previousCaptureVisible, forcedCaptureVisible: forcedCaptureVisible)
        order.append(session)
        byId[id] = session
        return session
    }

    func lookup(id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return byId[id]
    }

    /// Removes and returns the session, or `nil` if it was never registered,
    /// was already resolved/cancelled, or was evicted. `resolve`/`cancel`
    /// both consume a session this way, so a handshake cannot be ended a
    /// second time.
    @discardableResult
    func remove(id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = byId.removeValue(forKey: id) else { return nil }
        order.removeAll { $0.id == id }
        return session
    }

    /// Every currently outstanding session. Exists for tests; production
    /// code has no standing reason to enumerate this, mirroring
    /// `ScreenshotSpaceRegistry.all()`'s equivalent role.
    func all() -> [Session] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        order.removeAll()
        byId.removeAll()
    }
}

/// One drawn calibration marker, for `begin`'s response payload.
private struct DrawnMarker {
    let label: String
    let annotationId: String
    let normalizedX: Double
    let normalizedY: Double
    let backingX: Double
    let backingY: Double
}

private struct CalibrationFiducialSet {
    let markers: [DrawnMarker]
    let tokenAnnotationId: String
    var allAnnotationIds: [String] { markers.map(\.annotationId) + [tokenAnnotationId] }
}

extension MCPServer {
    // MARK: - `register_screenshot_space`

    /// Registers a `ScreenshotSpace` from a single call: either MEASURED (by
    /// decoding `screenshot_path`) or DECLARED (`screenshot_width`+
    /// `screenshot_height`). See `RegisterScreenshotSpaceSupport` for the
    /// pure validation this orchestrates, and `ScreenshotSpace`'s own header
    /// comment for why establishing this mapping once, by measurement where
    /// possible, is the actual fix for the "silent 2x misplacement" failure
    /// this whole feature exists to close.
    // internal: made available for a sibling agent's handleToolsCall dispatch.
    func handleRegisterScreenshotSpace(id: Any, args: [String: Any]) {
        let request: DrawRequest
        switch DrawRequest.resolveScreen(args: args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let value): request = value
        }

        let source: RegisterScreenshotSpaceSupport.DimensionSource
        switch RegisterScreenshotSpaceSupport.resolveDimensionSource(args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let value): source = value
        }

        let widthPx: Int
        let heightPx: Int
        let provenance: ScreenshotSpace.Provenance
        let sourcePath: String?

        switch source {
        case .path(let rawPath):
            guard AbsolutePath.isAbsolute(rawPath) else {
                sendErrorResult(id: id, text: "screenshot_path must be an absolute path to a local screenshot image; \"\(rawPath)\" is not absolute. Nothing was registered; supply an absolute path, or use screenshot_width/screenshot_height to declare the dimensions instead, or calibrate_screenshot_space to solve them from an on-screen fiducial.")
                return
            }
            do {
                let dimensions = try AnnotationVerificationCompositor.screenshotPixelDimensions(path: rawPath)
                widthPx = dimensions.width
                heightPx = dimensions.height
            } catch {
                sendErrorResult(id: id, text: error.localizedDescription)
                return
            }
            provenance = .measured
            sourcePath = rawPath

        case .declared(let width, let height):
            widthPx = width
            heightPx = height
            provenance = .declared
            sourcePath = nil
        }

        switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
            widthPx: widthPx, heightPx: heightPx,
            screen: request.screen, candidateScreens: request.candidateScreens,
            screenIsDetermined: request.screenIsDetermined
        ) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success: break
        }

        let space = ScreenshotSpaceRegistry.shared.register(
            screenId: request.screen.id, widthPx: widthPx, heightPx: heightPx,
            screenWidthPx: request.screen.widthPx, screenHeightPx: request.screen.heightPx,
            provenance: provenance, sourcePath: sourcePath
        )

        var payload = space.payload
        payload["note"] = "screenshot_space '\(space.id)' now names this exact screenshot-to-display mapping (provenance: \(provenance.rawValue)); pass it as screenshot_space on any draw_*/get_annotation_bounds/verify_annotation call instead of re-declaring screenshot_width/screenshot_height on every one. It is invalidated the moment display \(space.screenId)'s resolution, HiDPI scale, or connection state changes -- re-register or re-calibrate after any display-configuration change, sleep/wake cycle, or reconnect."
        if let caveat = RegisterScreenshotSpaceSupport.declaredProvenanceCaveat(
            provenance: provenance, widthPx: space.widthPx, heightPx: space.heightPx, screen: request.screen
        ) {
            payload["caveat"] = caveat
        }

        guard let text = jsonString(payload) else {
            sendErrorResult(id: id, text: "screenshot_space '\(space.id)' WAS registered, but its confirmation payload could not be encoded. Call get_overlay_state to see it, or re-register.")
            return
        }
        sendTextResult(id: id, text: text)
    }

    // MARK: - `calibrate_screenshot_space`

    /// Dispatches on `action` to the three handshake steps. See
    /// PHASE_B_SPEC.md's "New MCP tools -- calibrate_screenshot_space" for
    /// the full contract each step implements.
    // internal: made available for a sibling agent's handleToolsCall dispatch.
    func handleCalibrateScreenshotSpace(id: Any, args: [String: Any]) {
        let action: String
        switch CalibrateScreenshotSpaceSupport.parseAction(args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let value): action = value
        }

        switch action {
        case "begin": handleCalibrateScreenshotSpaceBegin(id: id, args: args)
        case "resolve": handleCalibrateScreenshotSpaceResolve(id: id, args: args)
        case "cancel": handleCalibrateScreenshotSpaceCancel(id: id, args: args)
        case "elements": handleCalibrateScreenshotSpaceElements(id: id, args: args)
        default:
            // Unreachable: `parseAction` above already restricts `action` to
            // these four values. Kept as an actionable fallback rather than
            // `fatalError`, matching this repo's standing preference for
            // failing loudly with text over trapping on a state a future
            // refactor might make reachable by accident.
            sendErrorResult(id: id, text: "action must be one of \"begin\", \"resolve\", \"cancel\", \"elements\".")
        }
    }

    /// Clears one calibration session's fiducial annotations and restores
    /// the capture-visible value that preceded it. Called from every path
    /// that ends a handshake -- `begin` displacing a prior session on the
    /// same display, `resolve` on BOTH success and failure, and `cancel` --
    /// so there is exactly one place this "undo the state changes `begin`
    /// made" logic lives, rather than four independently-drifting copies of
    /// it.
    ///
    /// Removing each annotation id is best-effort: an id already cleared by
    /// the user (via `clear`) is not an error here, it simply has nothing
    /// left to remove -- the goal ("nothing from this calibration is left on
    /// screen") is already satisfied for that id.
    /// What `clearCalibrationSession` actually did to the process-wide
    /// capture-debug flag, so the response can say the TRUE thing rather than
    /// a fixed "restored to X" sentence.
    ///
    /// This exists because reference counting made the old wording capable of
    /// lying: with a second calibration still outstanding, capture-debug is
    /// deliberately left ON, and telling the caller it was "restored to false"
    /// would describe a state change that did not happen -- and would send an
    /// agent debugging a stuck orange menu-bar icon looking in the wrong place.
    enum CalibrationCaptureCleanup {
        /// The flag was set back to this value: this was the last outstanding
        /// calibration forcing it on.
        case restored(Bool)
        /// Deliberately left ON: another calibration is still outstanding and
        /// still needs the overlay to reach its caller's screenshot.
        case heldForOtherCalibration
        /// Untouched: this session never forced the flag
        /// (`set_capture_visible=false`), so it had nothing to undo.
        case untouched

        var sentence: String {
            switch self {
            case .restored(let value):
                return "capture-visible was restored to \(value)"
            case .heldForOtherCalibration:
                return "capture-visible was deliberately LEFT ON because another calibration is still outstanding and still needs the overlay to appear in its caller's screenshot; it reverts when that one resolves or cancels"
            case .untouched:
                return "capture-visible was not changed (this calibration never turned it on)"
            }
        }

        /// The wire value for `captureVisibleRestoredTo`. `nil` -- omitted
        /// from the payload -- whenever no restore happened, rather than a
        /// misleading boolean.
        var restoredValue: Bool? {
            if case .restored(let value) = self { return value }
            return nil
        }
    }

    @discardableResult
    func clearCalibrationSession(_ session: ScreenshotCalibrationRegistry.Session) -> CalibrationCaptureCleanup {
        for annotationId in session.annotationIds {
            _ = AnnotationStore.shared.remove(id: annotationId)
        }
        // Only a session that actually FORCED capture-debug on has anything
        // to restore. A `set_capture_visible=false` begin changed the flag not
        // at all, so touching it here would clobber whatever value some other
        // actor (the menu bar, a sibling instance, another calibration) set
        // during the handshake window -- an undo of something this session
        // never did.
        guard session.forcedCaptureVisible else { return .untouched }
        // nil means another calibration is still outstanding and still needs
        // the overlay to reach the caller's screenshot, so capture-debug must
        // STAY on. See `ScreenshotCalibrationRegistry.captureBaseline`.
        guard let restoreTo = ScreenshotCalibrationRegistry.shared.releaseCaptureBaseline() else {
            return .heldForOtherCalibration
        }
        _ = OverlayWindowController.shared.setCaptureVisible(restoreTo)
        InstanceBroadcast.shared.postSetCaptureVisible(restoreTo)
        return .restored(restoreTo)
    }

    /// `action="begin"`: draws the four `ScreenshotCalibration.markers` plus
    /// a random verification token as ORDINARY, global-scope, non-expiring
    /// annotations, optionally turns on capture-debug mode, and registers a
    /// new outstanding calibration session.
    private func handleCalibrateScreenshotSpaceBegin(id: Any, args: [String: Any]) {
        let request: DrawRequest
        switch DrawRequest.resolveScreen(args: args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let value): request = value
        }
        let screen = request.screen

        var shouldSetCaptureVisible = true
        if CalibrateScreenshotSpaceSupport.isSupplied(args, "set_capture_visible") {
            guard let value = MCPArgument.bool(args["set_capture_visible"]) else {
                sendErrorResult(id: id, text: "set_capture_visible must be a boolean when supplied.")
                return
            }
            shouldSetCaptureVisible = value
        }

        // "Only one calibration may be outstanding per display" -- clearing
        // any prior session for THIS screen before drawing new fiducials
        // keeps two calibrations from drawing over one another, and its
        // capture-visible restore must happen BEFORE this call reads the
        // "previous" value it will itself later restore to (see below).
        var displacedNote = ""
        if let displaced = ScreenshotCalibrationRegistry.shared.existingSession(forScreenId: screen.id) {
            ScreenshotCalibrationRegistry.shared.remove(id: displaced.id)
            let displacedCleanup = clearCalibrationSession(displaced)
            displacedNote = " A previous outstanding calibration ('\(displaced.id)') for this display was cleared to make room for this one: its \(displaced.annotationIds.count) fiducial annotation(s) were removed and \(displacedCleanup.sentence)."
        }

        let token = ScreenshotCalibrationToken.random()
        let drawn: CalibrationFiducialSet
        switch drawCalibrationFiducials(request: request, screen: screen, token: token) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let value): drawn = value
        }

        // Captured AFTER any displaced-session restore above, so it reflects
        // the value actually in effect immediately before THIS session turns
        // it on -- never a stale read from before that restore, and never
        // the displaced session's own (possibly different) prior value.
        // Claimed through the registry rather than read directly, so that a
        // SECOND concurrent calibration (a two-monitor desktop, one handshake
        // per display) inherits the first one's baseline instead of recording
        // the `true` the first one just set. See
        // `ScreenshotCalibrationRegistry.captureBaseline` for the nested
        // save/restore failure that arises otherwise.
        let previousCaptureVisible = shouldSetCaptureVisible
            ? ScreenshotCalibrationRegistry.shared.claimCaptureBaseline(
                currentCaptureVisible: OverlayWindowController.shared.isCaptureVisible)
            : OverlayWindowController.shared.isCaptureVisible
        if shouldSetCaptureVisible {
            _ = OverlayWindowController.shared.setCaptureVisible(true)
            InstanceBroadcast.shared.postSetCaptureVisible(true)
        }

        let session = ScreenshotCalibrationRegistry.shared.register(
            screenId: screen.id, token: token,
            annotationIds: drawn.allAnnotationIds,
            previousCaptureVisible: previousCaptureVisible,
            forcedCaptureVisible: shouldSetCaptureVisible
        )

        let markerPayload: [[String: Any]] = drawn.markers.map { marker in
            [
                "label": marker.label,
                "annotationId": marker.annotationId,
                "normalized": ["x": marker.normalizedX, "y": marker.normalizedY],
                "expectedBackingPx": ["x": marker.backingX, "y": marker.backingY]
            ]
        }

        let captureNote = shouldSetCaptureVisible
            ? "set_capture_visible(true) was applied (the default): capture-debug mode is now ON for this display's overlay, which turns the menu-bar icon orange and auto-reverts after five minutes without renewal. action=\"resolve\"/\"cancel\" restore it to \(previousCaptureVisible), its value immediately before this call."
            : "set_capture_visible=false was supplied, so capture-debug mode was left at \(previousCaptureVisible) and this calibration will not change it at either end. If it is currently false, the fiducials will NOT appear in another application's screenshot and this handshake cannot complete -- see this tool's limitation note."

        let payload: [String: Any] = [
            "calibrationId": session.id,
            "token": token,
            "screenId": screen.id,
            "screenBackingPx": ["width": screen.widthPx, "height": screen.heightPx],
            "markers": markerPayload,
            "tokenAnnotationId": drawn.tokenAnnotationId,
            "annotationIds": drawn.allAnnotationIds,
            "instructions": "Take a screenshot of display \(screen.id) now. In THAT screenshot's own pixel coordinates (whatever they turn out to be -- do not guess or declare them), read each marker's CENTRE (the crosshair intersection, not its label text) and confirm the token '\(token)' is visible near the display centre; if the token is missing or reads differently, this screenshot is STALE and must not be used. Then call calibrate_screenshot_space with action=\"resolve\", calibration_id=\"\(session.id)\" (note the snake_case ARGUMENT name -- the calibrationId key above is the response spelling, and passing that spelling as an argument is rejected), and markers=[{label, x, y}, ...] for all four of TL/TR/BL/BR. If your screenshot tool can also report the image's own pixel width and height, pass them as observed_width/observed_height too: they are cross-checked against the solve, which is the only way to catch a top-left-anchored crop that the marker geometry alone cannot see.",
            "fallback": "If these markers do NOT appear anywhere in your screenshot at all, this handshake cannot work over that capture path. Call action=\"cancel\" to clean up, then work out WHICH of the two causes you have, because they have different remedies. (a) FILTERED: the capture path photographs this display but omits this app's windows. A saved screenshot file still shows the real desktop, so register_screenshot_space with screenshot_path gives you a MEASURED space. (b) DIFFERENT SURFACE: your screenshots are not of this display at all -- the commonest case is a remote-desktop or screen-sharing client, whose screenshots show the REMOTE machine's framebuffer, which a locally drawn overlay was never composited into and never can be. No fiducial can bridge that, because the two framebuffers are disjoint. Tell them apart by looking for THIS machine's own desktop furniture in the screenshot (its menu bar, its Dock, its wallpaper): present means (a), absent means (b). Under (b), and under (a) whenever your screenshot tool returns inline image data with no file path to measure, a DECLARED space is the best available and its dimensions remain an assertion -- the capture tool reporting its own image's pixel width and height is the only thing that upgrades it.",
            "limitation": "This calibration proves the MAPPING between marker spacing and display geometry, and detects a crop that shifts the image's origin -- but it CANNOT detect a top-left-anchored crop that also preserves the display's aspect ratio, because that crop leaves both marker spacing and origin looking correct. If you have (or can obtain) the actual screenshot file, register_screenshot_space with screenshot_path is STRICTLY STRONGER: it measures the file's true pixel extent directly instead of extrapolating it from marker spacing.",
            "clearedBy": "These fiducial annotations are ORDINARY annotations: they persist until explicitly cleared and do NOT self-expire. action=\"resolve\" and action=\"cancel\" both clear them and restore capture-visible automatically; failing that, clear them yourself with the clear tool (by annotation_id, or scope=\"all\").",
            "captureVisible": captureNote + displacedNote
        ]

        guard let text = jsonString(payload) else {
            // An unreportable calibration is not a usable one: roll the
            // whole handshake back rather than leave fiducials on screen
            // with no way for the caller to learn their ids.
            ScreenshotCalibrationRegistry.shared.remove(id: session.id)
            clearCalibrationSession(session)
            sendErrorResult(id: id, text: "Failed to encode the calibration handshake response. The fiducials that were drawn have already been cleared and capture-visible restored; nothing is left on screen. Retry.")
            return
        }
        sendTextResult(id: id, text: text)
    }

    /// `action="resolve"`: feeds any supplied `markers` to
    /// `ScreenshotCalibration.solve`, reconciles that solve (if any) against
    /// any supplied `observed_width`/`observed_height` via
    /// `CalibrateScreenshotSpaceSupport.reconcile`, puts the reconciled
    /// dimensions through the SAME
    /// `RegisterScreenshotSpaceSupport.validateAgainstDisplay` gate
    /// `register_screenshot_space` uses, and -- on EITHER outcome -- clears
    /// the calibration's fiducials and releases capture-visible.
    ///
    /// EVERY rejection after the `calibration_id` lookup goes through the
    /// `rejectAndClear` helper below, including the two ARGUMENT-SHAPE
    /// rejections that used to `return` bare (see
    /// `CalibrateScreenshotSpaceSupport.resolveRejectionMessage` for the
    /// stranded-fiducials bug that caused). The two guards BEFORE the lookup
    /// -- missing and unknown `calibration_id` -- correctly do not: there is
    /// no session to clear.
    private func handleCalibrateScreenshotSpaceResolve(id: Any, args: [String: Any]) {
        guard let calibrationId = (args["calibration_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !calibrationId.isEmpty else {
            sendErrorResult(id: id, text: "Missing required parameter: calibration_id")
            return
        }
        guard let session = ScreenshotCalibrationRegistry.shared.lookup(id: calibrationId) else {
            sendErrorResult(id: id, text: "Unknown calibration_id '\(calibrationId)'. It may never have been started, may already have been resolved/cancelled, or may have been displaced by a newer calibration on the same display. Nothing was changed; call calibrate_screenshot_space with action=\"begin\" to start a fresh handshake.")
            return
        }

        /// The single exit every post-lookup rejection takes, so the catalog's
        /// and README's "every resolve cleans up, including a rejected one"
        /// promise holds for ALL of them -- not just the ones that happened to
        /// remember. Before this existed, the two argument-shape rejections
        /// immediately below returned bare, leaving four crosshairs and the
        /// CAL token painted on the user's display and capture-debug forced
        /// on, for something as ordinary as `markers` arriving as a
        /// label-keyed JSON object rather than an array.
        ///
        /// ORDER IS LOAD-BEARING: `remove(id:)` FIRST, `clearCalibrationSession`
        /// SECOND. The capture-debug release asks "is any REMAINING session
        /// still forcing the flag on"; clearing before removing would count
        /// this very session as a reason to hold capture-debug on and strand
        /// the orange menu-bar icon until the unrelated five-minute
        /// auto-revert. Every other cleanup site in this file uses the same
        /// remove-then-clear order for the same reason.
        func rejectAndClear(_ err: String) {
            ScreenshotCalibrationRegistry.shared.remove(id: session.id)
            let cleanup = clearCalibrationSession(session)
            sendErrorResult(id: id, text: CalibrateScreenshotSpaceSupport.resolveRejectionMessage(
                err, calibrationId: calibrationId, captureOutcome: cleanup.sentence))
        }

        let markerObservations: [ScreenshotCalibration.Observation]?
        switch CalibrateScreenshotSpaceSupport.parseMarkerObservations(args) {
        case .failure(let err): rejectAndClear(err); return
        case .success(let value): markerObservations = value
        }
        let declaredObserved: (width: Int, height: Int)?
        switch CalibrateScreenshotSpaceSupport.parseObservedDimensions(args) {
        case .failure(let err): rejectAndClear(err); return
        case .success(let value): declaredObserved = value
        }

        // The CURRENT screen for this session's display, not a value cached
        // from `begin` -- a display disconnect/reconfiguration during the
        // handshake window must be caught before solving against geometry
        // that may no longer describe anything real.
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        guard let screen = snapshot.screens.first(where: { $0.id == session.screenId }) else {
            rejectAndClear("Display \(session.screenId), which calibration '\(calibrationId)' was started against, is no longer connected, so there is no display geometry left to solve these markers against. Call get_screens for the current display list.")
            return
        }

        var solution: ScreenshotCalibration.Solution?
        if let markerObservations {
            switch ScreenshotCalibration.solve(observations: markerObservations, screen: screen) {
            case .failure(let err):
                rejectAndClear(err)
                return
            case .success(let value):
                solution = value
            }
        }

        let reconciled: CalibrateScreenshotSpaceSupport.Reconciliation
        switch CalibrateScreenshotSpaceSupport.reconcile(solved: solution, declaredObserved: declaredObserved) {
        case .failure(let err):
            rejectAndClear(err)
            return
        case .success(let value):
            reconciled = value
        }

        // THE SAME display-plausibility gate `register_screenshot_space`
        // applies -- deliberately the shared function, not a second copy.
        //
        // THE DEFECT THIS CLOSES: a `resolve` carrying `observed_width`/
        // `observed_height` and NO `markers` reached
        // `ScreenshotSpaceRegistry.register` with no display validation
        // whatsoever. `parseObservedDimensions` only checks "positive
        // integers", `reconcile`'s `(nil, .some)` branch passes them straight
        // through, and nothing between here and registration ever called
        // `fullDisplayScale`. So on a 3840x2160 display,
        // `action="resolve", observed_width: 1512, observed_height: 982` (a
        // CROPPED screenshot -- aspect 1.54 against the display's 1.78)
        // SUCCEEDED, handing back scaleToBackingPx {x: 2.5397, y: 2.1996} and
        // a note inviting the agent to "pass it as screenshot_space on any
        // draw_*/get_annotation_bounds/verify_annotation call". The identical
        // numbers handed to `register_screenshot_space` were rejected up
        // front, and every draw_* call naming the space then failed with
        // "Unsafe screenshot mapping rejected": the agent was told it held a
        // usable mapping that no drawing tool would accept. Worse,
        // `verify_annotation` with `capture_source='none'` computes its
        // scales straight off the space's own dimensions, so it silently
        // reported paintedBoundsScreenshotPx under the non-uniform 0.394 x
        // 0.455 mapping that `get_annotation_bounds` -- documented as
        // reporting "the same geometry" -- refused for the same space.
        //
        // `candidateScreens: [screen]` / `screenIsDetermined: true` is the
        // right shape here: the calibration session already FIXES the
        // display (`begin` recorded it, and the lookup above re-resolved that
        // same id against the live snapshot), so "which display is this a
        // picture of" is settled and only the aspect/no-upscale half of the
        // gate has anything to say. A marker-solved value already snaps to a
        // display-consistent size, so it passes here unchanged; this gate
        // bites exactly the declared-only route that had none.
        switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
            widthPx: reconciled.width, heightPx: reconciled.height,
            screen: screen, candidateScreens: [screen], screenIsDetermined: true,
            rejectionPrefix: "calibrate_screenshot_space action=\"resolve\" rejected:"
        ) {
        case .failure(let err):
            rejectAndClear(err)
            return
        case .success:
            break
        }

        // SUCCESS: clear the fiducials and restore capture-visible here too
        // -- the whole point of the handshake is a mapping the caller now
        // references by id, not a still-visible set of markers.
        ScreenshotCalibrationRegistry.shared.remove(id: session.id)
        let cleanup = clearCalibrationSession(session)

        let space = ScreenshotSpaceRegistry.shared.register(
            screenId: screen.id, widthPx: reconciled.width, heightPx: reconciled.height,
            screenWidthPx: screen.widthPx, screenHeightPx: screen.heightPx,
            provenance: reconciled.provenance
        )

        var payload = space.payload
        payload["note"] = "screenshot_space '\(space.id)' now names this exact screenshot-to-display mapping, solved from calibration '\(calibrationId)' (provenance: \(reconciled.provenance.rawValue)). Pass it as screenshot_space on any draw_*/get_annotation_bounds/verify_annotation call. It is invalidated the moment display \(space.screenId)'s resolution, HiDPI scale, or connection state changes. The calibration fiducials have been cleared and \(cleanup.sentence)."
        if let solution {
            // The SHARED residual vocabulary -- deliberately the same function
            // `action="elements"` reports through, so the two measured routes
            // can never publish differently-spelled diagnostics for the same
            // `Residuals` value.
            payload["residuals"] = CalibrateScreenshotSpaceSupport.residualsPayload(solution.residuals)
        }
        if let crossCheckNote = reconciled.crossCheckNote {
            payload["crossCheck"] = crossCheckNote
        }
        payload["limitation"] = "This calibration proves the mapping between marker spacing and display geometry, and detects an origin-shifting crop -- but cannot by itself detect a top-left-anchored, aspect-preserving crop (see this tool's begin-time limitation note). register_screenshot_space with screenshot_path is strictly stronger when a screenshot file is available, because it measures the file's true pixel extent directly."

        guard let text = jsonString(payload) else {
            sendErrorResult(id: id, text: "Calibration '\(calibrationId)' solved successfully and its fiducials were cleared, but the response could not be encoded. screenshot_space '\(space.id)' WAS registered; call get_overlay_state to inspect it.")
            return
        }
        sendTextResult(id: id, text: text)
    }

    /// `action="elements"`: establishes a `ScreenshotSpace` by measuring UI
    /// elements of the TARGET APPLICATION through Accessibility, instead of
    /// by painting fiducials of Chalkboard's own and asking whether they
    /// showed up.
    ///
    /// See `CalibrateFromElementsSupport`'s header comment for the measured
    /// field failure this exists to route around -- a capture tool whose
    /// screenshots are unmistakably of this local display, yet in which
    /// Chalkboard's crosshairs never appear even with capture-debug forced
    /// on, and which returns its images inline with no file path, closing the
    /// `screenshot_path` route in the same session. The insight this handler
    /// implements is that the fiducial does not have to be OURS: it only has
    /// to be something whose true position Chalkboard can establish
    /// independently, and a control of the app the caller is already looking
    /// at is both independently measurable (Accessibility publishes its rect)
    /// and guaranteed visible in the caller's capture (that app is precisely
    /// the one the capture tool was granted).
    ///
    /// SINGLE-SHOT AND STATELESS, unlike every other action on this tool. It
    /// draws nothing, so there is no `ScreenshotCalibrationRegistry` session
    /// to open, no capture-visible flag to force and restore, no fiducials
    /// that could be stranded on the user's screen, and consequently nothing
    /// for `cancel` to undo. Every rejection below therefore goes through
    /// `CalibrateFromElementsSupport.rejection`, which says so -- an agent
    /// carrying the handshake's cleanup model into this action would
    /// otherwise answer a rejection with a `cancel` it has no id for, or with
    /// a fresh `begin` that really does paint markers.
    ///
    /// THE PERMISSION IS ACCESSIBILITY, NOT SCREEN RECORDING. Nothing here
    /// captures a single pixel; the whole route is a read of another
    /// application's published UI geometry.
    private func handleCalibrateScreenshotSpaceElements(id: Any, args: [String: Any]) {
        // Everything syntactic first, before a PID lookup or one byte of
        // cross-process Accessibility IPC -- `handleHighlightElement`'s own
        // ordering rule, and it matters more here because a malformed request
        // would otherwise pay for up to `maximumElementCount` full hierarchy
        // walks before failing on an argument that was wrong all along.
        let request: CalibrateFromElementsSupport.Request
        switch CalibrateFromElementsSupport.parse(args) {
        case .failure(let error):
            sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(error))
            return
        case .success(let value):
            request = value
        }

        // THE SAME app resolution `highlight_element` performs -- one running
        // application, exactly one PID, an explicit refusal to guess between
        // instances -- called rather than re-implemented. A second lookup
        // here would be a second set of ambiguity and not-running rules for
        // the same question, free to disagree with the first about which
        // process an ambiguous name means.
        let target: (app: AppRef, pid: HighlightProcessID)
        switch resolveRunningHighlightTarget(args) {
        case .failure(let error):
            sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(
                CalibrateFromElementsSupport.appResolutionFailure(error, app: request.app)
            ))
            return
        case .success(let value):
            target = value
        }

        let screens = OverlayWindowController.shared.screenSnapshot().screens
        var matches: [AccessibilityElementMatch] = []
        matches.reserveCapacity(request.elements.count)
        for (index, spec) in request.elements.enumerated() {
            do {
                // `AccessibilityElementRequest` built exactly as
                // `handleHighlightElement` builds it, from the same argument
                // vocabulary (label/role/match/occurrence plus the two
                // traversal budgets), so an element that `highlight_element`
                // can ring is an element this action can measure, and the
                // disambiguation an agent already knows works unchanged.
                matches.append(try AccessibilityElementResolver.resolve(
                    processID: target.pid,
                    request: AccessibilityElementRequest(
                        label: spec.label,
                        role: spec.role,
                        matchMode: spec.matchMode,
                        occurrence: spec.occurrence,
                        maxNodes: request.maxNodes,
                        timeoutSeconds: request.timeoutSeconds
                    ),
                    screens: screens
                ))
            } catch {
                sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(
                    CalibrateFromElementsSupport.elementResolutionFailure(
                        error.localizedDescription, index: index, label: spec.label
                    )
                ))
                return
            }
        }

        // RE-READ THE DISPLAY LAYOUT AFTER THE WALKS AND RE-CONVERT EVERY
        // FRAME, rather than trusting the pre-walk `screens` above -- the
        // discipline `handleHighlightElement` documents at length, preserved
        // here because this route's exposure to it is strictly WORSE. That
        // handler runs one walk of up to `maxTraversalTimeoutSeconds`; this
        // one runs up to `maximumElementCount` walks back to back, so the
        // window in which a monitor can be added, removed, rearranged or
        // rescaled is a multiple of the one that check was written for. The
        // failure is invisible without it: `backingRect` anchors its
        // conversion to the zero-origin display's height, picks the
        // containing screen by frame, and multiplies by that screen's backing
        // scale factor, and all three move under a reconfiguration -- yielding
        // a perfectly well-formed rectangle in the wrong place.
        //
        // DISAGREEMENT IS A REJECTION, not a re-derivation: if the two
        // conversions differ then the AX frame itself was measured in an
        // arrangement that can no longer be identified, so NEITHER answer is
        // trustworthy and choosing between them would only move the
        // misplacement around.
        let screensAfterWalk = OverlayWindowController.shared.screenSnapshot().screens
        var resolved: [CalibrateFromElementsSupport.ResolvedElement] = []
        resolved.reserveCapacity(matches.count)
        for (index, match) in matches.enumerated() {
            let spec = request.elements[index]
            guard let confirmedFrame = AccessibilityElementResolver.backingRect(
                      forAccessibilityFrame: match.accessibilityFrame, screens: screensAfterWalk
                  ),
                  confirmedFrame == match.backingFrame
            else {
                sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(
                    CalibrateFromElementsSupport.displayLayoutChangedFailure(index: index, label: spec.label)
                ))
                return
            }
            resolved.append(CalibrateFromElementsSupport.ResolvedElement(
                spec: spec, matchedLabel: match.matchedLabel, resolvedRole: match.role,
                frame: confirmedFrame
            ))
        }

        let screenId: String
        switch CalibrateFromElementsSupport.resolveDisplay(resolved, explicitScreenId: request.screenId) {
        case .failure(let error):
            sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(error))
            return
        case .success(let value):
            screenId = value
        }

        // Unreachable by construction -- `backingRect` only ever returns an
        // id belonging to a member of the array it was handed, and that array
        // is `screensAfterWalk` -- but reported as text rather than trapped,
        // matching this file's standing preference for failing loudly over
        // `fatalError` on a state a future refactor might make reachable.
        guard let screen = screensAfterWalk.first(where: { $0.id == screenId }) else {
            sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(
                "The elements resolved onto display '\(screenId)', which is not in the display list read immediately afterwards. Nothing was registered; retry once the display arrangement has settled."
            ))
            return
        }

        // The PURE solver, given nothing but facts: each element's true
        // backing point(s) and the caller's own reading of the same. Every
        // baseline, scale, redundancy, origin-residual and snap decision
        // lives there (`Sources/Support/ScreenshotCalibration.swift`), sharing
        // the marker route's own validated tail so the two can never drift
        // into producing differently-validated sizes for the same display.
        //
        // BOUNDS FIDUCIALS CHANGE NOTHING HERE. A bounds-observed element
        // arrives as two ordinary correspondences named "... top-left corner"
        // and "... bottom-right corner"; the solver is not told which form
        // produced which point and needs no new arithmetic to accept them.
        //
        // Bound once rather than recomputed, because the COUNT is reported in
        // two places below and must be the count that was actually solved
        // from -- the number of elements is no longer the same number.
        let pairs = CalibrateFromElementsSupport.correspondences(resolved)
        let solution: ScreenshotCalibration.Solution
        switch ScreenshotCalibration.solveCorrespondences(pairs, screen: screen) {
        case .failure(let error):
            sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(error))
            return
        case .success(let value):
            solution = value
        }

        // THE SAME display-plausibility gate `register_screenshot_space` and
        // `action="resolve"` apply -- deliberately the shared function, not a
        // third copy. A solved size has already snapped to a
        // display-consistent one and passes here unchanged; running it anyway
        // is what keeps every registration route, however it arrived at its
        // dimensions, answerable to one aspect/no-upscale rule.
        //
        // `candidateScreens: [screen]` / `screenIsDetermined: true` is the
        // right shape: the display is not being guessed at here, it was
        // MEASURED -- the elements themselves resolved onto it and
        // `resolveDisplay` already required them to agree -- so "which display
        // is this a picture of" is settled and only the aspect/no-upscale half
        // of the gate has anything left to say.
        switch RegisterScreenshotSpaceSupport.validateAgainstDisplay(
            widthPx: solution.widthPx, heightPx: solution.heightPx,
            screen: screen, candidateScreens: [screen], screenIsDetermined: true,
            rejectionPrefix: "calibrate_screenshot_space action=\"elements\" rejected:"
        ) {
        case .failure(let error):
            sendErrorResult(id: id, text: CalibrateFromElementsSupport.rejection(error))
            return
        case .success:
            break
        }

        // `.observed`, exactly like the marker route: this is a measurement,
        // made indirectly against a real, independently-established on-screen
        // reference rather than asserted. That the reference happens to belong
        // to another application rather than to Chalkboard changes who painted
        // it, not how strong the evidence is.
        let space = ScreenshotSpaceRegistry.shared.register(
            screenId: screen.id, widthPx: solution.widthPx, heightPx: solution.heightPx,
            screenWidthPx: screen.widthPx, screenHeightPx: screen.heightPx,
            provenance: .observed
        )

        var payload = space.payload
        // Names WHICH kind of `observed` this is. Provenance alone no longer
        // distinguishes a crosshair read off a screenshot from an
        // Accessibility rect read out of another process, and those two have
        // genuinely different accuracy characteristics -- a caller auditing a
        // space it registered an hour ago should not have to guess which one
        // produced it.
        payload["method"] = "accessibility-elements"
        payload["note"] = "screenshot_space '\(space.id)' now names this exact screenshot-to-display mapping, solved from \(pairs.count) correspondence(s) across \(resolved.count) Accessibility element(s) of '\(target.app.name)' [\(target.app.bundleId)] on display \(space.screenId) (provenance: observed, method: accessibility-elements). Each element's entry below says which form it was observed in -- a CENTRE contributes one correspondence, a BOUNDING BOX two (its top-left and bottom-right corners). Pass it as screenshot_space on any draw_*/get_annotation_bounds/verify_annotation call instead of re-declaring screenshot_width/screenshot_height on every one. Nothing was drawn and nothing needs cleaning up -- this action is single-shot and stateless. The space is invalidated the moment display \(space.screenId)'s resolution, HiDPI scale, or connection state changes; re-run this call after any display-configuration change, sleep/wake cycle, or reconnect."
        payload["elements"] = CalibrateFromElementsSupport.elementsPayload(resolved)
        payload["residuals"] = CalibrateScreenshotSpaceSupport.residualsPayload(solution.residuals)
        if let caveat = CalibrateFromElementsSupport.redundancyCaveat(correspondenceCount: pairs.count) {
            payload["redundancy"] = caveat
        }
        payload["limitation"] = "HONEST LIMITS OF THIS ROUTE: an Accessibility frame is the element's REPORTED rect, which can differ from the pixels it actually paints (padding, shadow, focus ring), so this is typically slightly less precise than reading a purpose-drawn crosshair -- the points above are exactly what was solved from, and comparing them against your own screenshot is the way to judge that. A bounds observation inherits that same caveat at its CORNERS, where a reported frame and its painted pixels disagree most; for a WINDOW, which is what that form exists for, the frame is the window's own rect (title bar included, drop shadow excluded) and its edges are unusually clean to read. Prefer 3 or more WIDELY separated points: separation, not count, is what makes the scale solve stable, and a third reading is what makes it checkable at all. And prefer register_screenshot_space with screenshot_path whenever a screenshot FILE exists, because decoding the file measures its true pixel extent directly rather than inferring it."

        guard let text = jsonString(payload) else {
            sendErrorResult(id: id, text: "The element calibration SUCCEEDED and screenshot_space '\(space.id)' WAS registered (\(solution.widthPx)x\(solution.heightPx) px on display \(space.screenId)), but its confirmation payload could not be encoded. Nothing needs cleaning up; call get_overlay_state to inspect the registered space, or re-run this call.")
            return
        }
        sendTextResult(id: id, text: text)
    }

    /// `action="cancel"`: clears the fiducials, restores capture-visible,
    /// and confirms what was removed. No solve, no registration -- an
    /// abandoned calibration that never intends to call `resolve`.
    private func handleCalibrateScreenshotSpaceCancel(id: Any, args: [String: Any]) {
        guard let calibrationId = (args["calibration_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !calibrationId.isEmpty else {
            sendErrorResult(id: id, text: "Missing required parameter: calibration_id")
            return
        }
        guard let session = ScreenshotCalibrationRegistry.shared.lookup(id: calibrationId) else {
            sendErrorResult(id: id, text: "Unknown calibration_id '\(calibrationId)'. It may never have been started, may already have been resolved/cancelled, or may have been displaced by a newer calibration on the same display. Nothing was changed.")
            return
        }
        ScreenshotCalibrationRegistry.shared.remove(id: session.id)
        let cancelCleanup = clearCalibrationSession(session)

        let payload: [String: Any] = [
            "calibrationId": session.id,
            "clearedAnnotationIds": session.annotationIds,
            "captureVisibleOutcome": cancelCleanup.sentence
        ]
        guard let text = jsonString(payload) else {
            sendTextResult(id: id, text: "Calibration '\(calibrationId)' cancelled: \(session.annotationIds.count) fiducial annotation(s) were cleared and \(cancelCleanup.sentence).")
            return
        }
        sendTextResult(id: id, text: text)
    }

    // MARK: - Fiducial drawing (shared by `begin`)

    /// Draws the four `ScreenshotCalibration.markers` plus the verification
    /// token, all as ORDINARY, non-expiring, global-scope (`app: ""`)
    /// annotations, through `DrawRequest.finish` -- the SAME storage/app-
    /// link/success pipeline `draw_batch` itself runs through (see this
    /// file's header comment on `ScreenshotCalibrationMarkerDrawing` for why
    /// the media-parsing half is built directly rather than through the
    /// per-item, file-private helpers `draw_batch` uses for CALLER-supplied
    /// geometry).
    ///
    /// On any failure partway through, every annotation this call itself
    /// already created is rolled back before returning the error -- a
    /// half-drawn calibration must never be left half-visible on the user's
    /// screen. Nothing about capture-visible or the calibration registry is
    /// touched here; the caller (`handleCalibrateScreenshotSpaceBegin`)
    /// handles both only after this succeeds completely.
    private func drawCalibrationFiducials(
        request: DrawRequest, screen: ScreenInfo, token: String
    ) -> DrawOutcome<CalibrationFiducialSet> {
        var createdIds: [String] = []
        func rollback() {
            for annotationId in createdIds { _ = AnnotationStore.shared.remove(id: annotationId) }
        }

        var markers: [DrawnMarker] = []
        for marker in ScreenshotCalibration.markers {
            let center = ScreenshotCalibrationMarkerDrawing.backingCenter(of: marker, on: screen)
            let pathKind = AnnotationKind.vectorPath(
                data: ScreenshotCalibrationMarkerDrawing.markerPathData(center: center),
                strokeColorHex: "#000000",
                strokeWidth: ScreenshotCalibrationMarkerDrawing.strokeWidthPx,
                strokeOpacity: 1,
                fillColorHex: "#FFFFFF",
                fillOpacity: 1,
                dash: [],
                usesEvenOddFillRule: false,
                coordinateScaleX: 1,
                coordinateScaleY: 1
            )
            let labelPosition = ScreenshotCalibrationMarkerDrawing.labelPosition(center: center)
            let textKind = AnnotationKind.text(
                text: marker.label,
                x: labelPosition.x, y: labelPosition.y,
                fontSize: ScreenshotCalibrationMarkerDrawing.labelFontSizePx,
                textColorHex: "#000000",
                backgroundColorHex: "#FFFFFF",
                backgroundOpacity: 1,
                paddingPx: 4,
                opacity: 1
            )
            let markerKind = AnnotationKind.batch(items: [
                AnnotationComponent(kind: pathKind, colorHex: "#000000", label: nil),
                AnnotationComponent(kind: textKind, colorHex: "#000000", label: nil)
            ])

            var createdAnnotationId: String?
            let outcome = request.finish(
                args: ["app": ""], defaultColor: "#000000", label: nil, defaultsToGlobal: false,
                kind: markerKind, noun: "screenshot calibration marker '\(marker.label)'",
                onAnnotationCreated: { annotation in createdAnnotationId = annotation.id }
            )
            switch outcome {
            case .failure(let err):
                rollback()
                return .failure("Failed to draw calibration marker '\(marker.label)': \(err) No calibration fiducials were left on screen.")
            case .success:
                guard let createdAnnotationId else {
                    rollback()
                    return .failure("Calibration marker '\(marker.label)' reported success but no annotation id was captured. No calibration fiducials were left on screen; retry.")
                }
                createdIds.append(createdAnnotationId)
                markers.append(DrawnMarker(
                    label: marker.label, annotationId: createdAnnotationId,
                    normalizedX: marker.normalizedX, normalizedY: marker.normalizedY,
                    backingX: center.x, backingY: center.y
                ))
            }
        }

        let center = (x: Double(screen.widthPx) / 2, y: Double(screen.heightPx) / 2)
        let tokenKind = AnnotationKind.text(
            text: "CAL " + token,
            x: center.x, y: center.y,
            fontSize: ScreenshotCalibrationMarkerDrawing.tokenFontSizePx,
            textColorHex: "#000000",
            backgroundColorHex: "#FFFF00",
            backgroundOpacity: 1,
            paddingPx: 6,
            opacity: 1
        )
        var tokenAnnotationId: String?
        let tokenOutcome = request.finish(
            args: ["app": ""], defaultColor: "#000000", label: nil, defaultsToGlobal: false,
            kind: tokenKind, noun: "screenshot calibration token",
            onAnnotationCreated: { annotation in tokenAnnotationId = annotation.id }
        )
        switch tokenOutcome {
        case .failure(let err):
            rollback()
            return .failure("Failed to draw the calibration verification token: \(err) No calibration fiducials were left on screen.")
        case .success:
            guard let tokenAnnotationId else {
                rollback()
                return .failure("The calibration verification token reported success but no annotation id was captured. No calibration fiducials were left on screen; retry.")
            }
            return .success(CalibrationFiducialSet(markers: markers, tokenAnnotationId: tokenAnnotationId))
        }
    }
}
