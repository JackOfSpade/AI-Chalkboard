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
/// Each of the six draw tools used to repeat the same ~8-step sequence by
/// hand -- resolve screen id, look up its dimensions, normalize coordinates,
/// read color, read duration, `resolveTargetApp`, build the `Annotation`,
/// `store.add`, word the success message -- roughly 50 lines each, ~300
/// lines total. This type does every step that is genuinely shared ONCE;
/// each call site in `MCPToolHandlers` contributes only what is truly
/// tool-specific: its own geometry parsing (and any geometry validation),
/// its own default color, its `AnnotationKind`, its noun for the success
/// message ("circle", "arrow", "box", "label", "freehand path", "alignment
/// grid"), and whether it defaults to global (`draw_grid` alone does).
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
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        guard let screen = snapshot.resolve(args["screen_id"] as? String) else {
            return .failure("No displays are currently available (NSScreen.screens returned empty -- this can happen momentarily during display reconfiguration or wake). Nothing was drawn; retry the call in a moment.")
        }
        return .success(DrawRequest(screen: screen))
    }

    /// Normalizes one coordinate against this request's screen if
    /// `isNormalized`, else returns it unchanged. `alongWidth` selects which
    /// physical-pixel axis to scale against (x/width use the screen's width,
    /// y/height use its height).
    func normalize(_ raw: Double, alongWidth: Bool, isNormalized: Bool) -> Double {
        guard isNormalized else { return raw }
        return raw * Double(alongWidth ? screen.widthPx : screen.heightPx)
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
        noun: String
    ) -> DrawOutcome<String> {
        let colorHex = args["color"] as? String ?? defaultColor
        let duration = MCPServer.shared.getDouble(args["duration_seconds"]) ?? defaultDuration

        var appId: String?
        var appName: String?
        if let err = MCPServer.shared.resolveTargetApp(args, defaultsToGlobal: defaultsToGlobal, appId: &appId, appName: &appName) {
            return .failure(err)
        }

        let annotation = Annotation(
            screenId: screen.id,
            kind: kind,
            colorHex: colorHex,
            label: label,
            appId: appId,
            appName: appName
        )
        let evicted = AnnotationStore.shared.add(annotation, durationSeconds: duration)

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
    ///                               (`defaultsToGlobal` flips this to nil for
    ///                               `draw_grid`.)
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

    /// Coerces an MCP tool argument to `Double`, accepting a JSON number or a
    /// numeric string and rejecting everything else. This is the single
    /// shared numeric helper for every draw tool (radius, coordinates,
    /// duration, step_px, stroke_width, path points), so fixing coercion here
    /// covers every call site at once.
    ///
    /// Two rejections beyond a plain `as?`/`Double(_:)` attempt:
    ///   * `value as? NSNumber` alone succeeds for JSON `true`/`false` -- a
    ///     JSON boolean bridges to `NSNumber` (backed by `CFBoolean`) just as
    ///     readily as a real number does, so without this check
    ///     `{"radius": true}` would silently become `1.0` instead of being
    ///     rejected as the wrong type.
    ///   * Both branches reject non-finite results. `NSNumber.doubleValue`
    ///     can itself be NaN/infinite, and `Double.init(String)` accepts
    ///     "nan"/"inf"/"infinity" (case-insensitively) -- either would
    ///     otherwise flow straight into stored geometry/duration values and
    ///     corrupt rendering or scheduling.
    func getDouble(_ value: Any?) -> Double? {
        if let num = value as? NSNumber {
            guard CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }
            let d = num.doubleValue
            return d.isFinite ? d : nil
        }
        if let str = value as? String, let d = Double(str) {
            return d.isFinite ? d : nil
        }
        return nil
    }
}
