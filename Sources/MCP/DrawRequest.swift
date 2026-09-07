import Foundation
#if os(macOS)
import AppKit
#elseif os(Windows)
import WinSDK
#endif

/// PLATFORM-ACCURATE NOUNS for the error strings below. These strings reach
/// the MCP caller (an AI agent deciding how to retry a rejected draw call),
/// so describing macOS's bundle-identifier/NSScreen model to a Windows
/// caller is a correctness problem, not a wording nit -- same reasoning as
/// MCPToolCatalog's platform-split prose. Windows identifies a running app
/// by executable name (see ActiveAppTracker's Windows branch) and enumerates
/// displays with EnumDisplayMonitors/GetMonitorInfoW, not NSScreen.
#if os(macOS)
private let displayEnumerationSource = "NSScreen.screens"
private let appIdentifierNoun = "bundle id"
private let appIdentifierPassExample = "a bundle identifier such as 'com.apple.Terminal'"
#elseif os(Windows)
private let displayEnumerationSource = "EnumDisplayMonitors"
private let appIdentifierNoun = "executable name"
private let appIdentifierPassExample = "an executable name such as \"Resolve.exe\" -- matched case-insensitively"
#endif

/// A tiny two-case outcome carrying either a value or a plain-text error
/// message.
///
/// Not `Swift.Result`: every "failure" produced anywhere in this pipeline
/// (an unresolvable screen, an ambiguous `app`) is already the exact,
/// user-facing string `sendErrorResult` hands back to the MCP caller, not an
/// `Error`-conforming value that would need to be rendered again. A second
/// wrapper type would only add ceremony.
enum DrawOutcome<Success> {
    case success(Success)
    case failure(String)
}

/// The shared pipeline behind every `draw_*` MCP tool.
///
/// The universal vector/raster/batch tools share screen resolution, app
/// linking, storage, and success reporting. This type performs that pipeline
/// once; each handler contributes only its media parsing and kind.
///
/// Split into two steps -- `resolveScreen(args:)`, then `finish(...)` -- ON
/// PURPOSE, matching the original per-tool ordering exactly: screen
/// resolution (and therefore coordinate normalization) has to happen BEFORE
/// a tool can validate its own geometry in physical pixels, but
/// color/app-link resolution happens AFTER that geometry is
/// validated -- so a caller that sent both malformed geometry AND an
/// ambiguous `app` still sees the geometry error first, exactly as the
/// original hand-written bodies did (they parsed and validated geometry
/// completely before ever calling `resolveTargetApp`).
struct DrawRequest {
    let screen: ScreenInfo

    /// Every display present in the snapshot `screen` was chosen from.
    ///
    /// Retained purely so `coordinateTransform` can tell a UNIQUE
    /// screenshot-to-display mapping apart from an AMBIGUOUS one: a
    /// `screenshot_pixels` call carries the dimensions of one specific
    /// display's image, and on a desktop with two identically-sized monitors
    /// those dimensions fit both. See that method's ambiguity guard.
    let candidateScreens: [ScreenInfo]

    /// False ONLY when `screen` came from the "no `screen_id` supplied, so
    /// use the main display" default in `ScreenSnapshot.resolve`.
    ///
    /// True when the caller named a display, and true for the default
    /// `init` used by `handleHighlightElement`, whose display is not a
    /// default at all -- it is derived from the Accessibility frame's own
    /// position, so it is already the one display the geometry can belong to.
    let screenIsDetermined: Bool

    init(screen: ScreenInfo, candidateScreens: [ScreenInfo]? = nil, screenIsDetermined: Bool = true) {
        self.screen = screen
        self.candidateScreens = candidateScreens ?? [screen]
        self.screenIsDetermined = screenIsDetermined
    }

    struct CoordinateTransform {
        let scaleX: Double
        let scaleY: Double
        let requiresUnitInterval: Bool

        init(scaleX: Double, scaleY: Double, requiresUnitInterval: Bool = false) {
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.requiresUnitInterval = requiresUnitInterval
        }

        /// Applies one axis of the public-coordinate transform without
        /// allowing a finite protocol number to turn into infinity. Callers
        /// must treat `nil` as an invalid geometry error rather than handing
        /// non-finite values to Core Graphics.
        func transformedX(_ value: Double) -> Double? {
            transformed(value, scale: scaleX)
        }

        /// See `transformedX(_:)`.
        func transformedY(_ value: Double) -> Double? {
            transformed(value, scale: scaleY)
        }

        func transformedPoint(x: Double, y: Double) -> (x: Double, y: Double)? {
            guard let transformedX = transformedX(x), let transformedY = transformedY(y) else {
                return nil
            }
            return (transformedX, transformedY)
        }

        /// True only if every scalar used by an SVG path can safely enter its
        /// backing-pixel render transform. Vector paths retain source-space
        /// data, so validating their parsed coordinates here is just as
        /// important as validating image/text positions before storage.
        func canTransform(_ geometry: SVGPathGeometry) -> Bool {
            geometry.elements.allSatisfy { element in
                switch element {
                case let .move(point), let .line(point):
                    return transformedPoint(x: point.x, y: point.y) != nil
                case let .quad(control, to: point):
                    return transformedPoint(x: control.x, y: control.y) != nil
                        && transformedPoint(x: point.x, y: point.y) != nil
                case let .cubic(control1, control2, to: point):
                    return transformedPoint(x: control1.x, y: control1.y) != nil
                        && transformedPoint(x: control2.x, y: control2.y) != nil
                        && transformedPoint(x: point.x, y: point.y) != nil
                case .close:
                    return true
                }
            }
        }

        private func transformed(_ value: Double, scale: Double) -> Double? {
            guard value.isFinite, scale.isFinite,
                  !requiresUnitInterval || (0...1).contains(value) else { return nil }
            let result = value * scale
            guard result.isFinite,
                  abs(result) <= DrawingDefaults.maxCoordinateMagnitudePx else {
                return nil
            }
            return result
        }
    }

    /// Resolves the target screen from ONE
    /// `OverlayWindowController.screenSnapshot()` call -- see that method's
    /// doc comment for why the old two-hop shape (`resolveScreenId(_:)` then
    /// a separate `getScreenInfo(id:)` lookup) was both a double main-thread
    /// cost and a TOCTOU hazard.
    ///
    /// Failure means either the snapshot contains no screens at all or the
    /// caller supplied an explicit id that is not current/in-bounds. An empty
    /// `NSScreen.screens` can occur during display reconfiguration or wake.
    /// That used to be silently papered over: the
    /// old `resolveScreenId` invented the synthetic id "0" while a SEPARATE,
    /// independently-empty `getScreenInfo(id:)` lookup found no dimensions
    /// and fell back to hardcoded `1920x1080` -- storing an annotation
    /// against a screen id no `OverlayView` would ever match, and reporting
    /// success. There is no reachable case left that needs a fallback
    /// dimension, so none exists any more: this is a hard error instead.
    static func resolveScreen(args: [String: Any]) -> DrawOutcome<DrawRequest> {
        if args.keys.contains("screen_id"), !(args["screen_id"] is String) {
            return .failure("screen_id must be a string when supplied.")
        }
        if let supplied = args["screen_id"] as? String, supplied.count > 128 {
            return .failure("screen_id must contain at most 128 characters when supplied. Nothing was drawn; call get_screens and use a current display id or in-bounds index.")
        }
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        guard !snapshot.screens.isEmpty else {
            Logger.shared.log("Drawing rejected: reason=no_displays", level: "WARN")
            return .failure("No displays are currently available (\(displayEnumerationSource) returned empty -- this can happen momentarily during display reconfiguration or wake). Nothing was drawn; retry the call in a moment.")
        }
        guard let screen = snapshot.resolve(args["screen_id"] as? String) else {
            Logger.shared.log(
                "Drawing rejected: reason=unknown_screen_id availableScreenCount=\(snapshot.screens.count)",
                level: "WARN"
            )
            return .failure("Unknown screen_id. Nothing was drawn; call get_screens and use a current display id or in-bounds index.")
        }
        let suppliedScreenId = (args["screen_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(DrawRequest(
            screen: screen,
            candidateScreens: snapshot.screens,
            // `ScreenSnapshot.resolve` treats an omitted OR blank id as "use
            // the main display". That is a fallback, not a caller decision,
            // and `coordinateTransform` needs to know the difference.
            screenIsDetermined: !(suppliedScreenId?.isEmpty ?? true)
        ))
    }

    /// `resolveScreen(args:)` followed immediately by `coordinateTransform(args:)`
    /// on the resolved request -- the identical two-step prologue that
    /// `draw_path`, `handleDrawImage`, `handleDrawText`, and `handleDrawBatch`
    /// each ran inline before this helper existed. Kept as two switches
    /// chained here, rather than collapsed into one, so the ordering stays
    /// self-evidently a screen-then-transform sequence: a caller who sends
    /// both a bad `screen_id` and a bad `coordinate_space` must still see the
    /// screen error first, exactly as every call site produced before this
    /// extraction (see this type's header comment for why that resolve-before-
    /// validate ordering is load-bearing all the way through `finish`).
    static func resolveDrawContext(args: [String: Any]) -> DrawOutcome<(DrawRequest, CoordinateTransform)> {
        let request: DrawRequest
        switch resolveScreen(args: args) {
        case .failure(let err): return .failure(err)
        case .success(let resolved): request = resolved
        }
        switch request.coordinateTransform(args: args) {
        case .failure(let err): return .failure(err)
        case .success(let transform): return .success((request, transform))
        }
    }

    /// Resolves public geometry coordinates into the backing-pixel geometry
    /// stored by annotations.  The old surface remains the default; source
    /// screenshot dimensions are deliberately required rather than guessed.
    func coordinateTransform(args: [String: Any]) -> DrawOutcome<CoordinateTransform> {
        if args.keys.contains("coordinate_space"), !(args["coordinate_space"] is String) {
            return .failure("coordinate_space must be 'backing_pixels', 'normalized', or 'screenshot_pixels' when supplied.")
        }
        let space = (args["coordinate_space"] as? String)?.lowercased() ?? "backing_pixels"

        // `screenshot_width`/`screenshot_height` are read by the
        // "screenshot_pixels" branch and NOWHERE ELSE, so supplying them in
        // any other space used to be a silent no-op: a caller that measured a
        // control on a client-resized screenshot, passed that image's exact
        // dimensions, and left `coordinate_space` at its "backing_pixels"
        // default had its numbers taken as backing pixels. On a 3840x2160
        // display measured from a 1512x850 image, a circle meant for backing
        // (1930, 1080) r=76 landed at (760, 425) r=30 -- roughly 1200 px away
        // and 2.5x too small -- and the tool answered with an ordinary
        // success string, so nothing in the loop could tell the agent its
        // frame of reference had been discarded. Supplying the dimensions is
        // unambiguous evidence of the space the caller MEANT, which makes the
        // contradiction a rejection rather than a reinterpretation -- the same
        // reject-rather-than-silently-do-something-else rule as
        // `rejectDurationSecondsIfSupplied`.
        //
        // DELIBERATELY LIMITED to the two spaces that really do ignore the
        // dimensions, and placed after the type check but before the switch,
        // so an unrecognised `coordinate_space` still reaches the
        // unknown-space error in `default` below: a typo'd space name is the
        // caller's actual problem, and telling it the coordinates "were
        // interpreted as <typo>" would be both untrue and unactionable.
        //
        // A JSON `null` does NOT count as supplied here, for exactly the
        // reason `makeShapeKind`'s rect branch spells out
        // (MCPToolHandlers+Shape.swift): `JSONSerialization` materialises it
        // as a real `NSNull` entry, and a schema-driven client that
        // serialises every declared property and nulls the ones it is not
        // using is a completely ordinary way to build a request -- rejecting
        // that caller would name arguments it never meaningfully sent.
        //
        // Sitting in `coordinateTransform` covers draw_path, draw_shape,
        // draw_image, draw_text AND draw_batch: `handleDrawBatch` resolves ONE
        // transform from the batch's TOP-LEVEL arguments via
        // `resolveDrawContext` and hands that same transform to every item, so
        // there is no second, per-item coordinate space that could slip past
        // this check.
        if space == "backing_pixels" || space == "normalized" {
            func isSupplied(_ key: String) -> Bool {
                guard let value = args[key] else { return false }
                return !(value is NSNull)
            }
            if isSupplied("screenshot_width") || isSupplied("screenshot_height") {
                Logger.shared.log(
                    "Drawing rejected: reason=screenshot_dimensions_ignored_in_space coordinateSpace=\(space) explicitSpace=\(args.keys.contains("coordinate_space"))",
                    level: "WARN"
                )
                return .failure("screenshot_width/screenshot_height were supplied but coordinate_space is '\(space)', so the screenshot dimensions would have been IGNORED and your coordinates interpreted as \(space). Nothing was drawn; pass coordinate_space='screenshot_pixels' if these coordinates were measured on that screenshot, or remove screenshot_width/screenshot_height.")
            }
        }

        switch space {
        case "backing_pixels":
            return .success(CoordinateTransform(scaleX: 1, scaleY: 1))
        case "normalized":
            let scaleX = Double(screen.widthPx)
            let scaleY = Double(screen.heightPx)
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
                return .failure("The selected display has invalid backing-pixel dimensions; nothing was drawn.")
            }
            return .success(CoordinateTransform(scaleX: scaleX, scaleY: scaleY, requiresUnitInterval: true))
        case "screenshot_pixels":
            for key in ["screenshot_width", "screenshot_height"] where args.keys.contains(key) && MCPArgument.integer(args[key]) == nil {
                return .failure("\(key) must be a positive integer pixel count for coordinate_space='screenshot_pixels'.")
            }
            guard let widthPixels = MCPArgument.integer(args["screenshot_width"]),
                  let heightPixels = MCPArgument.integer(args["screenshot_height"]),
                  widthPixels > 0, heightPixels > 0 else {
                return .failure("coordinate_space='screenshot_pixels' requires positive integer screenshot_width and screenshot_height pixel counts.")
            }
            let width = Double(widthPixels)
            let height = Double(heightPixels)
            let scaleX = Double(screen.widthPx) / width
            let scaleY = Double(screen.heightPx) / height
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
                return .failure("screenshot_width and screenshot_height produce an invalid coordinate transform; use finite dimensions that do not overflow the selected display scale.")
            }
            // Which of the CURRENTLY CONNECTED displays could this image
            // actually be a full-display screenshot of? Computed once and
            // used by both the mismatch hint and the ambiguity guard below.
            //
            // "Could actually be" is `isPlausibleFullDisplayCapture` -- a
            // uniform mapping AND no upscale -- not the bare
            // `fullDisplayScale` the TARGET-screen guard below uses. The
            // target guard answers a different question ("can these declared
            // dimensions be mapped onto the display the caller is drawing
            // on"), where the scale merely converts units. Here the question
            // is which display the image is a PICTURE of, and no screenshot
            // pipeline upscales: counting a same-aspect smaller sibling as a
            // candidate would flag a native capture of a larger display as
            // ambiguous when it identifies its display beyond reasonable
            // doubt. See that helper's doc comment.
            let accepting = candidateScreens.filter {
                ScreenshotGeometry.isPlausibleFullDisplayCapture(
                    screenshotWidth: width,
                    screenshotHeight: height,
                    screenWidth: Double($0.widthPx),
                    screenHeight: Double($0.heightPx)
                )
            }

            guard ScreenshotGeometry.fullDisplayScale(
                screenshotWidth: width,
                screenshotHeight: height,
                screenWidth: Double(screen.widthPx),
                screenHeight: Double(screen.heightPx)
            ) != nil else {
                let sourceScaleX = width / Double(screen.widthPx)
                let sourceScaleY = height / Double(screen.heightPx)
                Logger.shared.log(
                    "Drawing rejected: reason=unsafe_screenshot_mapping sourceWidth=\(widthPixels) sourceHeight=\(heightPixels) targetScreenId=\(screen.id) targetWidth=\(screen.widthPx) targetHeight=\(screen.heightPx) sourceScaleX=\(sourceScaleX) sourceScaleY=\(sourceScaleY)",
                    level: "WARN"
                )
                // Naming the display(s) these dimensions DO fit turns the
                // commonest multi-monitor mistake -- screenshotting the
                // secondary display and forgetting screen_id, so the request
                // is measured against the main one -- from a dead end into a
                // one-argument correction. Deliberately a hint, not an
                // automatic redirect: silently drawing on a display the
                // caller never named is the very failure the ambiguity guard
                // below exists to prevent.
                let hint = accepting.isEmpty
                    ? ""
                    : " These dimensions DO match connected display(s) \(accepting.map(\.id).joined(separator: ", ")); pass screen_id if the screenshot came from one of those."
                return .failure("Unsafe screenshot mapping rejected: source=\(width)x\(height) px, targetScreenId=\(screen.id), target=\(screen.widthPx)x\(screen.heightPx) backing px, sourceToTargetScales=\(sourceScaleX)x\(sourceScaleY). The dimensions do not match within pixel-rounding tolerance. screenshot_pixels requires the exact dimensions of the uncropped full-display image used to measure coordinates; cropped or window-only screenshots cannot be mapped safely.\(hint)")
            }

            // A screenshot is inherently the image of ONE display, but its
            // dimensions do not identify which one when several displays are
            // the same size -- the dual identical-monitor setup is standard
            // in exactly the editing suites this tool is used in. With no
            // `screen_id`, `ScreenSnapshot.resolve` silently returns the MAIN
            // display, so an agent that screenshotted the secondary monitor,
            // measured a control on it, and omitted `screen_id` got a
            // successful-looking result with its annotation drawn at the same
            // coordinates on the WRONG PHYSICAL MONITOR -- the scale guard
            // above cannot catch it, because identical dimensions map
            // perfectly to either display.
            //
            // Refuse to guess, listing the candidates, exactly as
            // `resolveTargetApp` does for an ambiguous `app` and as the
            // Accessibility resolver does for an ambiguous label. One extra
            // round trip beats a silently misplaced annotation.
            //
            // Only the DEFAULTED case is ambiguous: an explicit `screen_id`
            // is already the caller's answer to this question, and a single
            // accepting display leaves nothing to choose between.
            if !screenIsDetermined, accepting.count > 1 {
                Logger.shared.log(
                    "Drawing rejected: reason=ambiguous_screenshot_display sourceWidth=\(widthPixels) sourceHeight=\(heightPixels) acceptingScreenCount=\(accepting.count) defaultedScreenId=\(screen.id)",
                    level: "WARN"
                )
                return .failure("Ambiguous screenshot mapping rejected: source=\(width)x\(height) px matches \(accepting.count) connected displays (ids: \(accepting.map(\.id).joined(separator: ", "))) and no screen_id was supplied, so the annotation would have silently defaulted to display \(screen.id). A screenshot is the image of one specific display and its dimensions cannot say which. Nothing was drawn; retry with screen_id naming the display the screenshot was taken from.")
            }
            return .success(CoordinateTransform(scaleX: scaleX, scaleY: scaleY))
        default:
            return .failure("coordinate_space must be 'backing_pixels', 'normalized', or 'screenshot_pixels'.")
        }
    }

    /// `duration_seconds` is not a tool parameter any more: an annotation now
    /// persists until the AI or the user explicitly clears it (see
    /// `ClearScope`'s doc comment for the user-initiated half of that). A
    /// caller that still supplies `duration_seconds` at all -- any value,
    /// valid-looking or not -- is REJECTED outright rather than having the
    /// argument silently dropped.
    ///
    /// WHY REJECT RATHER THAN IGNORE: an agent that passes `duration_seconds`
    /// believes its drawing will clean itself up. Silently ignoring the
    /// argument would leave that agent's drawings on the user's screen
    /// forever while it believed otherwise, which is exactly the clutter
    /// this tool must not create. A loud rejection retrains the caller on the
    /// first call. This also matches this repo's standing preference for
    /// rejecting over silently doing something different from what was
    /// asked.
    ///
    /// `handleHighlightElement` deliberately re-runs this exact check before
    /// it ever resolves a process or touches the Accessibility hierarchy (see
    /// that handler's own comment on why: a rejected argument must not
    /// trigger a TCC prompt or cross-process AX IPC merely to fail later at
    /// `finish`). The check itself lives here once and both call sites share
    /// it.
    static func rejectDurationSecondsIfSupplied(args: [String: Any]) -> String? {
        guard args.keys.contains("duration_seconds") else { return nil }
        return "duration_seconds is no longer supported: annotations now persist until they are explicitly cleared. Nothing was drawn; remove duration_seconds and call clear (by annotation_id, by app, or scope='all') when you are done with the drawing."
    }

    // MARK: - `anchor`/`anchor_resize` argument parsing

    /// The purely-string-validated outcome of `anchor`/`anchor_resize` for
    /// one `draw_*` call. `nil` means "anchor=none" (the default, and by far
    /// the common case): draw exactly as before this feature existed, with
    /// no `AnnotationAnchor` attached. A non-nil value carries only the
    /// resize POLICY, not a mode enum, because every `draw_*` tool anchors
    /// in `.window` mode ONLY -- `AnchorMode.element` is `highlight_element`-
    /// only (see that case's own doc comment in AnnotationAnchor.swift:
    /// re-resolving an element requires an `AccessibilityElementRequest` no
    /// draw_* tool has), so there is nothing else this type needs to say.
    struct AnchorArgumentRequest: Equatable {
        let resize: AnchorResizeBehavior
    }

    /// Validates ONLY the `anchor`/`anchor_resize` argument STRINGS -- no app
    /// resolution, no process lookup, no window enumeration. This mirrors
    /// `rejectDurationSecondsIfSupplied`'s "reject before AX/TCC work"
    /// precedent (see that function's doc comment) for the identical reason:
    /// `resolveWindowAnchor` below spawns an `NSWorkspace`/
    /// `CGWindowListCopyWindowInfo` round trip that a typo'd enum value must
    /// never be allowed to trigger. Called from `finish` before ANY of that
    /// heavier work -- including the ordinary per-app resolution `finish`
    /// already does for every draw call -- runs.
    static func parseAnchorArguments(_ args: [String: Any]) -> DrawOutcome<AnchorArgumentRequest?> {
        if args.keys.contains("anchor"), !(args["anchor"] is String) {
            return .failure("anchor must be one of \"none\", \"window\" when supplied.")
        }
        let anchorRaw = (args["anchor"] as? String) ?? "none"
        guard anchorRaw == "none" || anchorRaw == "window" else {
            return .failure("anchor must be one of \"none\", \"window\" when supplied.")
        }
        if args.keys.contains("anchor_resize"), !(args["anchor_resize"] is String) {
            return .failure("anchor_resize must be one of \"pin\", \"scale\" when supplied.")
        }
        let resizeRaw = args["anchor_resize"] as? String
        if let resizeRaw, resizeRaw != "pin", resizeRaw != "scale" {
            return .failure("anchor_resize must be one of \"pin\", \"scale\" when supplied.")
        }
        guard anchorRaw == "window" else {
            // `anchor_resize` names a policy for reacting to the anchor
            // window's resize, and there is no anchor window at all under
            // the absent/"none" default -- supplying it here is unambiguous
            // evidence of an intent this call cannot honour, so it is
            // rejected rather than silently ignored (the same reject-over-
            // ignore rule `screenshot_width`/`screenshot_height` follow
            // under the wrong `coordinate_space`; see `coordinateTransform`
            // above).
            guard resizeRaw == nil else {
                return .failure("anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\".")
            }
            return .success(nil)
        }
        let resize: AnchorResizeBehavior = (resizeRaw == "scale") ? .scale : .pin
        return .success(AnchorArgumentRequest(resize: resize))
    }

    // MARK: - `anchor="window"` resolution

    /// One fully resolved `anchor="window"` request, ready to attach to a
    /// brand-new annotation: the `AnnotationAnchor` captured at creation
    /// time, plus the identity `.tracking` `AnchorProjection` that MUST be
    /// installed in the very same store write (see `Annotation
    /// .anchorPermitsPainting`'s doc comment: a real anchor is never
    /// observed sitting at `anchorProjection == nil`).
    struct DrawAnchorResolution {
        let anchor: AnnotationAnchor
        let projection: AnchorProjection
    }

    /// The pure DECISION half of window resolution: given windows already
    /// sampled for `processId` (front-to-back, exactly as
    /// `TargetWindowSampling.windows(forProcessId:screens:)` documents),
    /// choose one via `TargetWindowSelection.selectWindow(forRect:among:)`
    /// and build the anchor/projection a brand-new annotation is stored
    /// with. `nil` means `samples` offered no candidate at all (an empty
    /// array; `selectWindow` only returns nil in that case) -- the caller
    /// turns that into the MCP_SURFACE.md "found no eligible on-screen
    /// window" rejection.
    ///
    /// Deliberately independent of `TargetWindowProbe`/
    /// `MCPServer.runningProcessIds(forAppId:)`: sampling a live foreign
    /// window and enumerating real running processes cannot run in a unit
    /// test, but this decision -- which window wins the largest-
    /// intersection contest, and exactly what gets written into the anchor/
    /// projection -- has no such dependency and can be exercised directly
    /// with hand-built `TargetWindowSample`s (see `TargetWindowProbeTests
    /// .swift`'s identical split between `TargetWindowAssembly`/
    /// `TargetWindowSelection` and the two platforms' actual window-list
    /// readers).
    static func buildWindowAnchor(
        processId: Int64,
        appId: String,
        samples: [TargetWindowSample],
        paintedBounds: CGRect,
        resize: AnchorResizeBehavior,
        now: Date
    ) -> DrawAnchorResolution? {
        guard let selected = TargetWindowSelection.selectWindow(forRect: paintedBounds, among: samples) else {
            return nil
        }
        let anchor = AnnotationAnchor(
            mode: .window,
            resize: resize,
            target: AnchorWindowTarget(processId: processId, windowId: selected.windowId, appId: appId),
            referenceWindowFrame: AnchorRect(selected.frame),
            referenceScreenId: selected.screenId,
            element: nil,
            createdAt: now
        )
        let projection = AnchorProjection(
            state: .tracking,
            adjustment: .identity,
            effectiveScreenId: selected.screenId,
            currentWindowFrame: AnchorRect(selected.frame),
            sampledAt: now
        )
        return DrawAnchorResolution(anchor: anchor, projection: projection)
    }

    /// The impure half: resolves `appId` to exactly one RUNNING process,
    /// samples its windows, and hands the result to `buildWindowAnchor`
    /// above. Steps and their literal error text follow MCP_SURFACE.md's
    /// "Window resolution at draw time" contract exactly:
    ///
    /// 1. A `nil` `appId` means this annotation has no target application at
    ///    all (an untagged/global drawing) -- there is no window to anchor
    ///    to, so this is rejected before any process/window work runs.
    /// 2. `appId` is resolved to exactly one running pid via the SAME
    ///    per-platform lookup `highlight_element` uses (see
    ///    `MCPServer.runningProcessIds(forAppId:)`); zero or several running
    ///    processes are rejected with wording specific to this call site --
    ///    unlike `resolveRunningHighlightTarget`'s ambiguity/not-running
    ///    text, MCP_SURFACE.md prescribes no literal string for this case,
    ///    so it is worded for a drawing tool rather than reused verbatim
    ///    from an Accessibility-specific error.
    /// 3. `TargetWindowProbe.shared.windows(forProcessId:screens:)` samples
    ///    that pid's windows against every currently connected display
    ///    (`candidateScreens`, the same snapshot `resolveScreen` already
    ///    captured for this call).
    /// 4. `buildWindowAnchor` picks the window and builds the anchor; no
    ///    eligible window rejects with MCP_SURFACE.md's literal text.
    private func resolveWindowAnchor(
        resize: AnchorResizeBehavior,
        appId: String?,
        appName: String?,
        kind: AnnotationKind
    ) -> DrawOutcome<DrawAnchorResolution> {
        guard let appId else {
            return .failure("anchor=\"window\" requires a target application, because it anchors the drawing to one of that application's windows. Nothing was drawn; pass app explicitly, or draw without anchor to place this at fixed display coordinates.")
        }
        let displayName = appName ?? appId
        let pids = MCPServer.shared.runningProcessIds(forAppId: appId)
        guard pids.count == 1, let pid = pids.first else {
            if pids.isEmpty {
                return .failure("anchor=\"window\" requires \(displayName) to be a running application so its windows can be sampled, but no running process matches. Nothing was drawn; bring that application to the front and retry, or draw without anchor.")
            }
            return .failure("anchor=\"window\" cannot choose a window for \(displayName) because it has \(pids.count) running processes and anchoring refuses to guess which one owns the intended window. Nothing was drawn; quit the extra instance(s) and retry, or draw without anchor.")
        }
        let samples = TargetWindowProbe.shared.windows(forProcessId: pid, screens: candidateScreens)
        let bounds = PaintedBounds.paintedBounds(of: kind) ?? .zero
        guard let resolution = DrawRequest.buildWindowAnchor(
            processId: pid, appId: appId, samples: samples,
            paintedBounds: bounds, resize: resize, now: Date()
        ) else {
            return .failure("anchor=\"window\" found no eligible on-screen window for \(displayName) (pid \(pid)). Nothing was drawn: a window anchor with no window would silently behave like an unanchored drawing. Bring a window of that application on screen and retry, or draw without anchor.")
        }
        return .success(resolution)
    }

    /// Builds the `anchor` object every anchored `draw_*`/`list_annotations`
    /// response shares (see MCP_SURFACE.md's "Success payload -- the anchor
    /// object"). Kept independent of `finish` below so the exact key set is
    /// pinned in one place: `referenceWindowFrame`/`currentWindowFrame`/
    /// `adjustment` are encoded via `jsonObject` from their own `Codable`
    /// types (`AnchorRect`, `AnchorAdjustment`) rather than hand-typed,
    /// so a stray typo in a manually built dictionary can never drift from
    /// what `AnnotationAnchor`/`AnchorProjection` actually store.
    static func anchorResponsePayload(_ resolution: DrawAnchorResolution) -> [String: Any] {
        var payload: [String: Any] = [
            "mode": resolution.anchor.mode.rawValue,
            "resize": resolution.anchor.resize.rawValue,
            "state": resolution.projection.state.rawValue,
            "windowId": Int(resolution.anchor.target.windowId),
            "processId": Int(resolution.anchor.target.processId),
            "screenId": resolution.projection.effectiveScreenId
        ]
        payload["referenceWindowFrame"] = MCPServer.shared.jsonObject(resolution.anchor.referenceWindowFrame)
        if let currentWindowFrame = resolution.projection.currentWindowFrame {
            payload["currentWindowFrame"] = MCPServer.shared.jsonObject(currentWindowFrame)
        }
        payload["adjustment"] = MCPServer.shared.jsonObject(resolution.projection.adjustment)
        if let issue = resolution.projection.elementResolutionIssue {
            payload["elementResolutionIssue"] = issue
        }
        return payload
    }

    /// Reads the arguments every draw tool shares beyond geometry
    /// (`color`/`app`), resolves the per-app link, builds and stores the
    /// `Annotation`, and returns the worded success text -- or propagates
    /// `resolveTargetApp`'s error text unchanged.
    func finish(
        args: [String: Any],
        defaultColor: String,
        label: String?,
        defaultsToGlobal: Bool,
        kind: AnnotationKind,
        noun: String,
        resolvedTargetApp: AppRef? = nil,
        onAnnotationCreated: ((Annotation) -> Void)? = nil
    ) -> DrawOutcome<String> {
        if args.keys.contains("color"), !(args["color"] is String) {
            return .failure("color must be a string when supplied.")
        }
        let colorHex = args["color"] as? String ?? defaultColor
        if let error = DrawRequest.rejectDurationSecondsIfSupplied(args: args) {
            return .failure(error)
        }

        if args.keys.contains("z_index"), MCPArgument.integer(args["z_index"]) == nil {
            return .failure("z_index must be an integer when supplied.")
        }
        let zIndex = MCPArgument.integer(args["z_index"]) ?? 0

        // Pure string validation of `anchor`/`anchor_resize`, BEFORE any
        // process/window work -- including the ordinary per-app resolution
        // just below, which itself does no AX/TCC work but is still heavier
        // than a plain string compare. See `parseAnchorArguments`'s own doc
        // comment for why this ordering matters.
        let anchorRequest: AnchorArgumentRequest?
        switch DrawRequest.parseAnchorArguments(args) {
        case .failure(let err): return .failure(err)
        case .success(let value): anchorRequest = value
        }

        let appId: String?
        let appName: String?
        if let resolvedTargetApp {
            // Accessibility lookup has already resolved a single RUNNING app
            // and must not re-run the normal draw fallback (which can accept
            // a non-running bundle id or GLOBAL visibility).
            appId = resolvedTargetApp.bundleId
            appName = resolvedTargetApp.name
        } else {
            var resolvedAppId: String?
            var resolvedAppName: String?
            if let err = MCPServer.shared.resolveTargetApp(args, defaultsToGlobal: defaultsToGlobal, appId: &resolvedAppId, appName: &resolvedAppName) {
                return .failure(err)
            }
            appId = resolvedAppId
            appName = resolvedAppName
        }

        // Only NOW -- after the annotation's own app link is settled -- does
        // an `anchor="window"` request get to resolve a running process and
        // enumerate windows. `anchorRequest` is non-nil only once
        // `parseAnchorArguments` has already validated the strings above.
        var anchorResolution: DrawAnchorResolution?
        if let anchorRequest {
            switch resolveWindowAnchor(resize: anchorRequest.resize, appId: appId, appName: appName, kind: kind) {
            case .failure(let err): return .failure(err)
            case .success(let value): anchorResolution = value
            }
        }

        let annotation = Annotation(
            screenId: screen.id,
            kind: kind,
            colorHex: colorHex,
            label: label,
            appId: appId,
            appName: appName,
            zIndex: zIndex,
            anchor: anchorResolution?.anchor,
            // Installed in this SAME store write, per the design contract: a
            // real anchor is never observed with a nil projection (see
            // `Annotation.anchorPermitsPainting`'s doc comment).
            anchorProjection: anchorResolution?.projection
        )
        switch AnnotationStore.shared.addWithOutcome(annotation) {
        case .added:
            onAnnotationCreated?(annotation)
        case .rejected(.payloadBytes(let limit, let attempted)):
            return .failure("The annotation was not stored because retained vector/text payload would become \(attempted) bytes, exceeding the \(limit)-byte session limit. Clear old annotations or use smaller geometry.")
        case .rejected(.primitiveCount(let limit, let attempted)):
            return .failure("The annotation was not stored because retained primitive count would become \(attempted), exceeding the \(limit)-primitive session limit. Clear old annotations or use a smaller batch.")
        case .rejected(.batchNestingDepth(let limit, let attempted)):
            return .failure("The annotation was not stored because its batch nesting depth is \(attempted), exceeding the \(limit)-level safety limit. Flatten nested batches and retry.")
        case .rejected(.annotationCount(let limit, let attempted)):
            return .failure("The annotation was not stored because the store would hold \(attempted) annotations, exceeding the \(limit)-annotation session limit. Clear annotations you no longer need and retry.")
        }

        let text = "Created \(noun) annotation: \(annotation.id)\(MCPServer.shared.linkageSuffix(appId: appId, appName: appName))"
        guard let anchorResolution else {
            // Unanchored -- BY FAR the common case -- keeps today's exact
            // plain-text response, byte for byte: existing callers (and
            // `test_mcp_stdio.py`'s `"annotation: " `-splitting parse of this
            // exact response) must see no change at all when `anchor` is not
            // used.
            return .success(text)
        }
        // Anchored: the response becomes a JSON object carrying the same
        // message text plus the `anchor` block MCP_SURFACE.md's "Success
        // payload" section specifies, exactly like `highlight_element`'s
        // existing JSON success payload.
        let payload: [String: Any] = [
            "message": text,
            "annotationId": annotation.id,
            "anchor": DrawRequest.anchorResponsePayload(anchorResolution)
        ]
        guard let jsonText = MCPServer.shared.jsonString(payload) else {
            return .failure("Created \(noun) annotation \(annotation.id) and anchored it, but failed to encode the anchor metadata in the response. The annotation and its anchor were still stored; call list_annotations to inspect them.")
        }
        return .success(jsonText)
    }
}

// MARK: - Shared running-process lookup

extension MCPServer {
    /// Running process ids whose identity matches `appId` -- a bundle
    /// identifier on macOS (`NSWorkspace.runningApplications`), an
    /// executable name on Windows (`CreateToolhelp32Snapshot`). This is the
    /// ONE place both `highlight_element`'s single-running-instance
    /// requirement (`resolveRunningHighlightTarget` in
    /// MCPToolHandlers+Highlight.swift) and `anchor="window"`'s window-
    /// owning-process lookup (`DrawRequest.resolveWindowAnchor` above) ask
    /// "is this app running, and with how many processes" -- extracted here
    /// so the platform-specific enumeration mechanics (an AppKit main-thread
    /// hop on macOS, a raw Win32 snapshot walk on Windows) exist exactly
    /// once instead of twice slowly drifting apart.
    ///
    /// Deliberately returns the raw pid list with NO opinion on cardinality:
    /// "zero matches" and "more than one match" are different failures with
    /// different wording at each call site (highlight needs an Accessibility
    /// hierarchy to walk; anchor needs windows to sample), so this stays a
    /// pure lookup and lets each caller phrase its own rejection. Both
    /// callers widen/narrow this `Int64` to their own platform's process-id
    /// type (`pid_t` on macOS, `UInt32` on Windows) at their own call site.
    func runningProcessIds(forAppId appId: String) -> [Int64] {
        #if os(macOS)
        // `NSWorkspace.runningApplications` is AppKit, so this takes the
        // same main-thread hop every other NSWorkspace query in this
        // package takes (see `MainThread.sync`'s own doc comment, whose
        // contract names this exact API). The pids are extracted INSIDE the
        // hop so no `NSRunningApplication` -- a live, main-thread-owned
        // object -- escapes back to the caller's (possibly background)
        // queue; a plain pid is just a number.
        return MainThread.sync {
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == appId && !$0.isTerminated }
                .map { Int64($0.processIdentifier) }
        }
        #elseif os(Windows)
        return Self.processIDs(forExecutableIdentity: appId).map { Int64($0) }
        #endif
    }

    #if os(Windows)
    /// Enumerates every running process via `CreateToolhelp32Snapshot`
    /// (`TH32CS_SNAPPROCESS`) and returns the process ids whose executable
    /// file name -- or that name's extension-less stem -- case-
    /// insensitively matches `identity`. This is the Windows substitute for
    /// `NSWorkspace.runningApplications`'s bundle-id filter above: Win32 has
    /// no bundle-identifier concept, only a per-process executable file name
    /// (`PROCESSENTRY32W.szExeFile`), so process identity here is that name.
    /// Matching both the full file name AND its stem tolerates a caller (or
    /// `ActiveAppTracker`) supplying either `"Resolve.exe"` or `"Resolve"`.
    ///
    /// Moved here verbatim from `MCPToolHandlers+Highlight.swift` (where it
    /// was `resolveRunningHighlightTarget`'s private helper) so it exists in
    /// exactly one place for both callers -- see `runningProcessIds
    /// (forAppId:)` above.
    private static func processIDs(forExecutableIdentity identity: String) -> [UInt32] {
        let loweredFull = identity.lowercased()
        let loweredStem = stem(of: identity).lowercased()

        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
              snapshot != INVALID_HANDLE_VALUE else {
            return []
        }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var matches: [UInt32] = []
        guard Process32FirstW(snapshot, &entry) else { return [] }
        repeat {
            // `szExeFile` is a fixed-size WCHAR[MAX_PATH] C array, imported
            // as a Swift tuple; reinterpret it as a UTF-16 buffer to decode
            // it as a String, the standard idiom for a fixed C char array.
            let exeName = withUnsafePointer(to: &entry.szExeFile) { tuplePointer -> String in
                tuplePointer.withMemoryRebound(to: UInt16.self, capacity: 260) { wide in
                    String(decodingCString: wide, as: UTF16.self)
                }
            }
            let loweredExe = exeName.lowercased()
            if loweredExe == loweredFull || stem(of: exeName).lowercased() == loweredStem {
                matches.append(entry.th32ProcessID)
            }
        } while Process32NextW(snapshot, &entry)
        return matches
    }

    /// The extension-less stem of a file name (`"Resolve.exe"` -> `"Resolve"`).
    /// A tiny local helper rather than `NSString.deletingPathExtension`, to
    /// avoid depending on Foundation's NSString bridging on this platform
    /// for a one-line string operation. Moved here alongside
    /// `processIDs(forExecutableIdentity:)` above.
    private static func stem(of fileName: String) -> String {
        guard let dotIndex = fileName.lastIndex(of: ".") else { return fileName }
        return String(fileName[..<dotIndex])
    }
    #endif
}

// MARK: - Per-app linking

extension MCPServer {
    /// Works out which app a `draw_*` call should link its annotation to, from
    /// the optional `app` argument.
    ///
    /// Writes the result through `appId` / `appName` and returns `nil` on
    /// success, or an error message to hand back to the caller. (An inout pair
    /// rather than a `Result`, so each tool's existing straight-line body stays
    /// flat instead of being nested inside a `switch`.)
    ///
    /// The four cases:
    ///   * `app` omitted          -> `ActiveAppTracker.fallbackAppId`, i.e. the
    ///                               app the user was in before switching to
    ///                               Claude. See that property's doc comment for
    ///                               why the TRUE frontmost app would be wrong.
    ///                               (`defaultsToGlobal` can flip this to nil.)
    ///   * `app` is ""            -> GLOBAL (nil). An explicit, discoverable way
    ///                               to pin something over every app.
    ///   * `app` names a running app -> resolved to its real bundle id + name.
    ///   * `app` matches SEVERAL running apps ("Google", "com") -> rejected
    ///                               with the candidate list. Guessing one was
    ///                               the old behaviour and it silently linked
    ///                               annotations to an arbitrary app; see
    ///                               `AppResolution`.
    ///   * `app` looks like a bundle id but nothing matches -> accepted
    ///                               verbatim. `NSWorkspace` can only see
    ///                               RUNNING apps, and "draw this on DaVinci,
    ///                               I'm about to open it" is a legitimate
    ///                               request; the annotation simply stays hidden
    ///                               until that app comes to the front. A
    ///                               free-text name in the same situation is
    ///                               rejected instead, because we would have no
    ///                               way to turn it into a bundle id and would
    ///                               be storing a value that can never match.
    ///                               NOTE this only applies to `.notFound`: an
    ///                               AMBIGUOUS query must never fall through to
    ///                               verbatim acceptance, or "com.google" would
    ///                               be stored as an appId that matches nothing.
    func resolveTargetApp(
        _ args: [String: Any],
        defaultsToGlobal: Bool,
        appId: inout String?,
        appName: inout String?
    ) -> String? {
        if args.keys.contains("app"), !(args["app"] is String) {
            return "app must be a string \(appIdentifierNoun)/display name, or an empty string for global visibility."
        }
        guard let raw = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            if defaultsToGlobal {
                appId = nil
                appName = nil
            } else {
                // Paired read: both land on one annotation as its appId and
                // appName, so they must come from a single lock acquisition --
                // see `ActiveAppTracker.fallbackApp`.
                let fallback = ActiveAppTracker.shared.fallbackApp
                appId = fallback.bundleId
                appName = fallback.name
            }
            return nil
        }

        if raw.isEmpty {
            appId = nil
            appName = nil
            return nil
        }

        switch ActiveAppTracker.shared.resolve(raw) {
        case .resolved(let resolved):
            appId = resolved.bundleId
            appName = resolved.name
            return nil

        case .ambiguous(let matches):
            // Nothing is drawn. Listing the candidates is the point: it turns a
            // silent wrong-app link into one extra round trip in which the
            // caller can name the app exactly.
            let shown = matches.prefix(8).map { "'\($0.name)' [\($0.bundleId)]" }.joined(separator: ", ")
            let more = matches.count > 8 ? " (and \(matches.count - 8) more)" : ""
            log("resolveTargetApp: '\(raw)' is ambiguous across \(matches.count) running applications; refusing to guess. Nothing was drawn.")
            return "App '\(raw)' is AMBIGUOUS -- it matches \(matches.count) running applications: \(shown)\(more). Nothing was drawn, because picking one arbitrarily would link the annotation to an app you did not mean. Retry with the exact \(appIdentifierNoun) or the app's full display name from that list."

        case .notFound:
            // Uses the same conservative complete-ID rule as ActiveAppTracker,
            // so a vague prefix cannot be rejected there but accepted here.
            if BundleIdentifierSyntax.looksComplete(raw) {
                appId = raw
                appName = nil
                log("resolveTargetApp: '\(raw)' matched no running application but is bundle-id shaped; accepting it verbatim. The annotation will appear once that app is launched and brought to the front.")
                return nil
            }

            return "Could not resolve app '\(raw)'. Only RUNNING applications can be looked up by display name. Call get_active_app to see the current/fallback app, or pass \(appIdentifierPassExample) (accepted even if the app is not running yet)."
        }
    }

    /// Human-readable trailer appended to every draw_* success message, so the
    /// caller immediately learns that what it just drew may not be on screen.
    func linkageSuffix(appId: String?, appName: String?) -> String {
        guard let appId = appId else {
            return " (GLOBAL: visible over every app)"
        }
        return " (linked to \(appName ?? appId) [\(appId)]: visible ONLY while that app is frontmost)"
    }
}
