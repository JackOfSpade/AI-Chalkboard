import Foundation

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
            return .failure("No displays are currently available (NSScreen.screens returned empty -- this can happen momentarily during display reconfiguration or wake). Nothing was drawn; retry the call in a moment.")
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
            // used by both guards below.
            let accepting = candidateScreens.filter {
                ScreenshotGeometry.fullDisplayScale(
                    screenshotWidth: width,
                    screenshotHeight: height,
                    screenWidth: Double($0.widthPx),
                    screenHeight: Double($0.heightPx)
                ) != nil
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

        let annotation = Annotation(
            screenId: screen.id,
            kind: kind,
            colorHex: colorHex,
            label: label,
            appId: appId,
            appName: appName,
            zIndex: zIndex
        )
        switch AnnotationStore.shared.addWithOutcome(annotation) {
        case .added:
            onAnnotationCreated?(annotation)
        case .rejected(.payloadBytes(let limit, let attempted)):
            return .failure("The annotation was not stored because retained vector/text payload would become \(attempted) bytes, exceeding the \(limit)-byte session limit. Clear old annotations or use smaller geometry.")
        case .rejected(.primitiveCount(let limit, let attempted)):
            return .failure("The annotation was not stored because retained primitive count would become \(attempted), exceeding the \(limit)-primitive session limit. Clear old annotations or use a smaller batch.")
        case .rejected(.annotationCount(let limit, let attempted)):
            return .failure("The annotation was not stored because the store would hold \(attempted) annotations, exceeding the \(limit)-annotation session limit. Clear annotations you no longer need and retry.")
        }

        let text = "Created \(noun) annotation: \(annotation.id)\(MCPServer.shared.linkageSuffix(appId: appId, appName: appName))"
        return .success(text)
    }
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
            return "app must be a string bundle id/display name, or an empty string for global visibility."
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
            return "App '\(raw)' is AMBIGUOUS -- it matches \(matches.count) running applications: \(shown)\(more). Nothing was drawn, because picking one arbitrarily would link the annotation to an app you did not mean. Retry with the exact bundle id or the app's full display name from that list."

        case .notFound:
            // Uses the same conservative complete-ID rule as ActiveAppTracker,
            // so a vague prefix cannot be rejected there but accepted here.
            if BundleIdentifierSyntax.looksComplete(raw) {
                appId = raw
                appName = nil
                log("resolveTargetApp: '\(raw)' matched no running application but is bundle-id shaped; accepting it verbatim. The annotation will appear once that app is launched and brought to the front.")
                return nil
            }

            return "Could not resolve app '\(raw)'. Only RUNNING applications can be looked up by display name. Call get_active_app to see the current/fallback app, or pass a bundle identifier such as 'com.apple.Terminal' (accepted even if the app is not running yet)."
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
