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
/// The universal vector/raster/batch tools share screen resolution, lifetime,
/// app linking, storage, and success reporting. This type performs that
/// pipeline once; each handler contributes only its media parsing and kind.
///
/// Split into two steps -- `resolveScreen(args:)`, then `finish(...)` -- ON
/// PURPOSE, matching the original per-tool ordering exactly: screen
/// resolution (and therefore coordinate normalization) has to happen BEFORE
/// a tool can validate its own geometry in physical pixels, but
/// color/duration/app-link resolution happens AFTER that geometry is
/// validated -- so a caller that sent both malformed geometry AND an
/// ambiguous `app` still sees the geometry error first, exactly as the
/// original hand-written bodies did (they parsed and validated geometry
/// completely before ever calling `resolveTargetApp`).
struct DrawRequest {
    let screen: ScreenInfo

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
    /// The only failure case is the snapshot containing NO screens at all
    /// (`NSScreen.screens` came back empty -- e.g. during display
    /// reconfiguration or wake). That used to be silently papered over: the
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
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        guard let screen = snapshot.resolve(args["screen_id"] as? String) else {
            return .failure("No displays are currently available (NSScreen.screens returned empty -- this can happen momentarily during display reconfiguration or wake). Nothing was drawn; retry the call in a moment.")
        }
        return .success(DrawRequest(screen: screen))
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
            for key in ["screenshot_width", "screenshot_height"] where MCPArgument.hasInvalidSuppliedDouble(args, key: key) {
                return .failure("\(key) must be a finite number greater than 0 for coordinate_space='screenshot_pixels'.")
            }
            guard let width = MCPArgument.double(args["screenshot_width"]),
                  let height = MCPArgument.double(args["screenshot_height"]),
                  width > 0, height > 0 else {
                return .failure("coordinate_space='screenshot_pixels' requires screenshot_width and screenshot_height greater than 0.")
            }
            let scaleX = Double(screen.widthPx) / width
            let scaleY = Double(screen.heightPx) / height
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
                return .failure("screenshot_width and screenshot_height produce an invalid coordinate transform; use finite dimensions that do not overflow the selected display scale.")
            }
            return .success(CoordinateTransform(scaleX: scaleX, scaleY: scaleY))
        default:
            return .failure("coordinate_space must be 'backing_pixels', 'normalized', or 'screenshot_pixels'.")
        }
    }

    /// Validates a `duration_seconds` argument the same way `finish(...)`
    /// does, without resolving it to a value. `handleHighlightElement`
    /// deliberately re-runs this exact check before it ever resolves a
    /// process or touches the Accessibility hierarchy (see that handler's own
    /// comment on why: a malformed highlight must not trigger a TCC prompt or
    /// cross-process AX IPC merely to fail later at `finish`). That early
    /// front-loaded rejection is the deliberate part; the validation logic
    /// itself was a literal copy, so it lives here once and both call sites
    /// share it.
    static func validateDurationSeconds(args: [String: Any]) -> String? {
        if args.keys.contains("duration_seconds"),
           MCPArgument.hasInvalidSuppliedDouble(args, key: "duration_seconds") {
            return "duration_seconds must be a finite number greater than 0 when supplied."
        }
        if let requestedDuration = MCPArgument.double(args["duration_seconds"]),
           (requestedDuration <= 0 || requestedDuration > DrawingDefaults.maxAnnotationDurationSeconds) {
            return "duration_seconds must be greater than 0 and no more than \(Int(DrawingDefaults.maxAnnotationDurationSeconds)) seconds when supplied; omit it for a persistent annotation."
        }
        return nil
    }

    /// Reads the arguments every draw tool shares beyond geometry
    /// (`color`/`duration_seconds`/`app`), resolves the per-app link, builds
    /// and stores the `Annotation`, and returns the worded success text -- or
    /// propagates `resolveTargetApp`'s error text unchanged.
    func finish(
        args: [String: Any],
        defaultColor: String,
        defaultDuration: Double? = nil,
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
        if let error = DrawRequest.validateDurationSeconds(args: args) {
            return .failure(error)
        }
        let requestedDuration = MCPArgument.double(args["duration_seconds"])
        let duration = requestedDuration ?? defaultDuration

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
        let addResult = AnnotationStore.shared.addWithOutcome(annotation, durationSeconds: duration)
        let evicted: Int
        switch addResult {
        case .added(let count):
            evicted = count
            onAnnotationCreated?(annotation)
        case .rejected(.payloadBytes(let limit, let attempted)):
            return .failure("The annotation was not stored because retained vector/text payload would become \(attempted) bytes, exceeding the \(limit)-byte session limit. Clear old annotations or use smaller geometry.")
        case .rejected(.primitiveCount(let limit, let attempted)):
            return .failure("The annotation was not stored because retained primitive count would become \(attempted), exceeding the \(limit)-primitive session limit. Clear old annotations or use a smaller batch.")
        }

        var text = "Created \(noun) annotation: \(annotation.id)\(MCPServer.shared.linkageSuffix(appId: appId, appName: appName))"
        if evicted > 0 {
            // AnnotationStore.add's eviction count is a return value
            // specifically so this can surface here instead of only in a log
            // line -- a runaway session (never passing duration_seconds,
            // never calling clear) should be visible from the tool result
            // itself, not just from a log file the user is unlikely to open.
            // When `evicted == 0` (the overwhelmingly common case) this
            // branch is skipped entirely, so the message stays byte-identical
            // to what this tool returned before eviction reporting existed.
            text += " Note: \(evicted) older annotation(s) were dropped to stay under the \(DrawingDefaults.maxStoredAnnotations)-annotation limit -- call clear if you no longer need the old ones."
        }
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
                appId = ActiveAppTracker.shared.fallbackAppId
                appName = ActiveAppTracker.shared.fallbackAppName
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
