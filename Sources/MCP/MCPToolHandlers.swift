import Foundation
import AppKit

/// `tools/call` dispatch and the body of every individual tool, plus the two
/// diagnostic JSON payload builders (`list_annotations`, `get_active_app`).
///
/// The six `draw_*` bodies below each contribute only what is genuinely
/// tool-specific to the shared `DrawRequest` pipeline (see DrawRequest.swift):
/// their own geometry parsing/validation, their own default color, their
/// `AnnotationKind`, their noun for the success message, and whether they
/// default to global.
extension MCPServer {
    func handleToolsCall(id: Any?, params: [String: Any]) {
        guard let id = id else { return }
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        log("Calling tool: \(name) with args: \(args)")

        switch name {
        case "get_screens":
            let screens = OverlayWindowController.shared.screenSnapshot().screens
            // The `screens` array is byte-identical to what this tool used to
            // return at the top level; it is now nested so the capture state can
            // ride along. Reporting that state here is what lets a caller who
            // turned capture on for a placement check notice it is still on and
            // put it back, instead of silently leaving every subsequent
            // compatible capture path eligible to include annotations.
            guard let screenArray = jsonObject(screens) as? [Any] else {
                sendErrorResult(id: id, text: "Failed to encode screen list.")
                return
            }
            let captureVisible = OverlayWindowController.shared.isCaptureVisible
            let payload: [String: Any] = [
                "screens": screenArray,
                "captureVisible": captureVisible,
                "captureNote": captureVisible
                    ? "Capture-debug mode is ON: overlay windows request sharingType=.readOnly and render every annotation. A capture tool may still omit these windows through its own app/window filter. Call set_capture_visible(false) to restore normal filtering."
                    : "Capture-debug mode is OFF (default): overlay windows request legacy sharingType=.none and render only annotations visible for the active app. This is not a security guarantee; modern capture tools control their own inclusion filters."
            ]
            guard let text = jsonString(payload) else {
                sendErrorResult(id: id, text: "Failed to encode screen list.")
                return
            }
            sendTextResult(id: id, text: text)

        case "draw_circle":
            guard let rawX = MCPArgument.double(args["x"]),
                  let rawY = MCPArgument.double(args["y"]),
                  let radius = MCPArgument.double(args["radius"]) else {
                sendErrorResult(id: id, text: "Missing required parameters: x, y, radius")
                return
            }
            if let err = DrawValidation.positiveRadius(radius) {
                sendErrorResult(id: id, text: err)
                return
            }
            let isNorm = args["is_normalized"] as? Bool ?? false
            let label = args["label"] as? String

            switch DrawRequest.resolveScreen(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let request):
                let x = request.normalize(rawX, alongWidth: true, isNormalized: isNorm)
                let y = request.normalize(rawY, alongWidth: false, isNormalized: isNorm)
                switch request.finish(
                    args: args,
                    defaultColor: DrawingDefaults.circleColor,
                    label: label,
                    defaultsToGlobal: false,
                    kind: .circle(x: x, y: y, radius: radius),
                    noun: "circle"
                ) {
                case .failure(let err):
                    sendErrorResult(id: id, text: err)
                case .success(let message):
                    sendTextResult(id: id, text: message)
                }
            }

        case "draw_arrow":
            guard let rawX1 = MCPArgument.double(args["x1"]),
                  let rawY1 = MCPArgument.double(args["y1"]),
                  let rawX2 = MCPArgument.double(args["x2"]),
                  let rawY2 = MCPArgument.double(args["y2"]) else {
                sendErrorResult(id: id, text: "Missing required parameters: x1, y1, x2, y2")
                return
            }
            let isNorm = args["is_normalized"] as? Bool ?? false
            let label = args["label"] as? String

            switch DrawRequest.resolveScreen(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let request):
                let x1 = request.normalize(rawX1, alongWidth: true, isNormalized: isNorm)
                let y1 = request.normalize(rawY1, alongWidth: false, isNormalized: isNorm)
                let x2 = request.normalize(rawX2, alongWidth: true, isNormalized: isNorm)
                let y2 = request.normalize(rawY2, alongWidth: false, isNormalized: isNorm)
                switch request.finish(
                    args: args,
                    defaultColor: DrawingDefaults.arrowColor,
                    label: label,
                    defaultsToGlobal: false,
                    kind: .arrow(x1: x1, y1: y1, x2: x2, y2: y2),
                    noun: "arrow"
                ) {
                case .failure(let err):
                    sendErrorResult(id: id, text: err)
                case .success(let message):
                    sendTextResult(id: id, text: message)
                }
            }

        case "draw_box":
            guard let rawX = MCPArgument.double(args["x"]),
                  let rawY = MCPArgument.double(args["y"]),
                  let rawW = MCPArgument.double(args["width"]),
                  let rawH = MCPArgument.double(args["height"]) else {
                sendErrorResult(id: id, text: "Missing required parameters: x, y, width, height")
                return
            }
            let isNorm = args["is_normalized"] as? Bool ?? false
            let label = args["label"] as? String

            switch DrawRequest.resolveScreen(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let request):
                let x = request.normalize(rawX, alongWidth: true, isNormalized: isNorm)
                let y = request.normalize(rawY, alongWidth: false, isNormalized: isNorm)
                let width = request.normalize(rawW, alongWidth: true, isNormalized: isNorm)
                let height = request.normalize(rawH, alongWidth: false, isNormalized: isNorm)
                if let err = DrawValidation.positiveDimensions(width: width, height: height) {
                    sendErrorResult(id: id, text: err)
                    return
                }
                switch request.finish(
                    args: args,
                    defaultColor: DrawingDefaults.boxColor,
                    label: label,
                    defaultsToGlobal: false,
                    kind: .box(x: x, y: y, width: width, height: height),
                    noun: "box"
                ) {
                case .failure(let err):
                    sendErrorResult(id: id, text: err)
                case .success(let message):
                    sendTextResult(id: id, text: message)
                }
            }

        case "draw_label":
            guard let rawX = MCPArgument.double(args["x"]),
                  let rawY = MCPArgument.double(args["y"]),
                  let text = args["text"] as? String else {
                sendErrorResult(id: id, text: "Missing required parameters: x, y, text")
                return
            }
            let isNorm = args["is_normalized"] as? Bool ?? false

            switch DrawRequest.resolveScreen(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let request):
                let x = request.normalize(rawX, alongWidth: true, isNormalized: isNorm)
                let y = request.normalize(rawY, alongWidth: false, isNormalized: isNorm)
                // `label: nil` here (not the `label` argument) -- the text
                // this tool draws lives inside `.label(text:)` itself, not in
                // `Annotation.label`, which is the separate side-badge caption
                // every OTHER draw tool optionally attaches.
                switch request.finish(
                    args: args,
                    defaultColor: DrawingDefaults.labelColor,
                    label: nil,
                    defaultsToGlobal: false,
                    kind: .label(x: x, y: y, text: text),
                    noun: "label"
                ) {
                case .failure(let err):
                    sendErrorResult(id: id, text: err)
                case .success(let message):
                    sendTextResult(id: id, text: message)
                }
            }

        case "draw_path":
            guard let rawPointsArg = args["points"] as? [Any], rawPointsArg.count >= 2 else {
                sendErrorResult(id: id, text: "Missing or invalid 'points' array (must contain at least 2 points).")
                return
            }
            // NOTE: no separate cap on rawPointsArg.count here, and none is
            // needed. Two reasons:
            //   1. The cap this tool actually enforces (DrawValidation.
            //      pathPointCount, below) is checked against parsedPoints.count
            //      -- the number of points that will actually reach
            //      AnnotationStore -- not this raw count, precisely because
            //      parsing silently drops malformed entries and checking the
            //      raw length could reject a request that would have produced
            //      an entirely acceptable number of stored points. See that
            //      function's doc comment.
            //   2. Unbounded parse work over an enormous raw array is already
            //      bounded upstream: LineFramer.maxBufferBytes caps a single
            //      JSON-RPC line -- and therefore this entire request,
            //      'points' included -- at 4 MB before this code ever runs. A
            //      future reader should not re-add a raw-size guard here for
            //      that reason.
            let isNorm = args["is_normalized"] as? Bool ?? false
            let isClosed = args["is_closed"] as? Bool ?? false
            let label = args["label"] as? String

            switch DrawRequest.resolveScreen(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let request):
                var parsedPoints: [[Double]] = []
                for item in rawPointsArg {
                    if let ptArr = item as? [Any], ptArr.count >= 2,
                       let px = MCPArgument.double(ptArr[0]), let py = MCPArgument.double(ptArr[1]) {
                        let x = request.normalize(px, alongWidth: true, isNormalized: isNorm)
                        let y = request.normalize(py, alongWidth: false, isNormalized: isNorm)
                        parsedPoints.append([x, y])
                    } else if let dict = item as? [String: Any],
                              let px = MCPArgument.double(dict["x"]), let py = MCPArgument.double(dict["y"]) {
                        let x = request.normalize(px, alongWidth: true, isNormalized: isNorm)
                        let y = request.normalize(py, alongWidth: false, isNormalized: isNorm)
                        parsedPoints.append([x, y])
                    }
                }

                guard parsedPoints.count >= 2 else {
                    sendErrorResult(id: id, text: "Failed to parse points array into (x, y) coordinates.")
                    return
                }

                if let err = DrawValidation.pathPointCount(parsedPoints.count) {
                    sendErrorResult(id: id, text: err)
                    return
                }

                let strokeWidth = MCPArgument.double(args["stroke_width"]) ?? DrawingDefaults.pathStrokeWidthPx

                switch request.finish(
                    args: args,
                    defaultColor: DrawingDefaults.pathColor,
                    label: label,
                    defaultsToGlobal: false,
                    kind: .path(points: parsedPoints, strokeWidth: strokeWidth, isClosed: isClosed),
                    noun: "freehand path"
                ) {
                case .failure(let err):
                    sendErrorResult(id: id, text: err)
                case .success(let message):
                    sendTextResult(id: id, text: message)
                }
            }

        case "draw_grid":
            let stepPx = MCPArgument.double(args["step_px"]) ?? DrawingDefaults.gridStepPx
            if let err = DrawValidation.gridStep(stepPx) {
                sendErrorResult(id: id, text: err)
                return
            }
            let label = args["label"] as? String

            switch DrawRequest.resolveScreen(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let request):
                // GRID DEFAULTS TO GLOBAL (appId = nil) -- the one draw tool that
                // does. It is a calibration aid, not an annotation about any
                // particular app: you draw the grid precisely so you can look at it
                // while switching to the app you are measuring and read coordinates
                // off it. Linking it to the fallback app like everything else would
                // make it vanish the instant you switched to the app you wanted to
                // measure, which is the only moment it is useful. An explicit `app`
                // still scopes it, for measuring one app without covering others.
                switch request.finish(
                    args: args,
                    defaultColor: DrawingDefaults.gridColor,
                    defaultDuration: DrawingDefaults.gridDurationSeconds,
                    label: label,
                    defaultsToGlobal: true,
                    kind: .grid(stepPx: stepPx),
                    noun: "alignment grid"
                ) {
                case .failure(let err):
                    sendErrorResult(id: id, text: err)
                case .success(let message):
                    sendTextResult(id: id, text: message)
                }
            }

        case "clear":
            // An explicit id wins over any scope: the caller named one specific
            // annotation, so which app it belongs to is irrelevant.
            if let annId = args["annotation_id"] as? String, !annId.isEmpty {
                let removed = AnnotationStore.shared.remove(id: annId)
                if removed {
                    sendTextResult(id: id, text: "Cleared annotation \(annId)")
                } else {
                    sendTextResult(id: id, text: "Annotation \(annId) not found.")
                }
                return
            }

            // Unrecognised scope strings fall back to `.active`, matching the
            // documented default -- a typo must not silently escalate into
            // wiping every app's annotations.
            let scope = ClearScope(rawValue: (args["scope"] as? String)?.lowercased() ?? "") ?? .active
            switch scope {
            case .all:
                AnnotationStore.shared.clearAll()
                sendTextResult(id: id, text: "Cleared ALL annotations, for every app, on every screen.")
            case .active:
                // TARGET THE SAME APP THE MCP DRAW PATH TARGETS -- i.e.
                // `fallbackAppId`, NOT `currentAppId`.
                //
                // THE TWO CALLERS OF clearVisible(forApp:) DELIBERATELY DIFFER;
                // do not "unify" them, that is the bug:
                //   * This one (MCP `clear`) is reached because Claude called
                //     it, which means Claude Desktop is frontmost. An untagged
                //     `draw_*` in that same conversation resolved its target
                //     through `resolveTargetApp` -> `fallbackAppId` (Claude is
                //     excluded from the fallback on purpose). If clear resolved
                //     `currentAppId` instead, the two would ALWAYS disagree
                //     inside Claude Desktop: "circle the login button" tags the
                //     annotation com.apple.Safari, then "clear that" resolves
                //     active=Claude, so the Safari circle SURVIVES and every
                //     GLOBAL annotation (a draw_grid, say) is destroyed in its
                //     place -- exactly the wrong set, reported as success.
                //   * The STATUS MENU stays on `currentAppId`
                //     (AppDelegate.clearAnnotationsForActiveApp), because a
                //     human clicking a menu item means "clear what I am looking
                //     at", and what they are looking at is the true frontmost
                //     app.
                // In short: clear must undo what the SAME channel drew.
                //
                // With no fallback known yet, untagged draws were GLOBAL.
                // Keep the target nil so `clearVisible(forApp:)` removes only
                // globals; falling back to currentAppId here would target
                // Claude's annotations instead.
                let tracker = ActiveAppTracker.shared
                let activeId: String?
                let activeName: String?
                if let fallbackId = tracker.fallbackAppId {
                    activeId = fallbackId
                    activeName = tracker.fallbackAppName
                } else {
                    activeId = nil
                    activeName = nil
                }
                let removed = AnnotationStore.shared.clearVisible(forApp: activeId)
                let target = activeName ?? activeId ?? "<no frontmost app detected>"
                sendTextResult(id: id, text: "Cleared \(removed) annotation(s) visible over \(target) (its own annotations plus global ones). Annotations linked to other apps were left in place -- pass scope='all' to remove those too.")
            }

        case "list_annotations":
            sendTextResult(id: id, text: buildAnnotationListJSON())

        case "get_active_app":
            sendTextResult(id: id, text: buildActiveAppJSON())

        case "set_capture_visible":
            guard let visible = args["visible"] as? Bool else {
                sendErrorResult(id: id, text: "Missing required boolean parameter: visible")
                return
            }
            // Broadcast rather than setting locally: every AI Chalkboard
            // instance owns its own overlay windows, and Claude Desktop runs two
            // of them. The posting process receives its own notification back,
            // so this single call applies the change here as well.
            InstanceBroadcast.shared.postSetCaptureVisible(visible)
            let explanation = visible
                ? "AI Chalkboard now requests capture eligibility and renders every annotation for placement checks. The capture program can still omit overlay windows through its own filters. Restore false when finished."
                : "AI Chalkboard now requests legacy capture exclusion and has restored normal per-app rendering. Modern capture programs may independently include or exclude these windows, so this is not a privacy guarantee."
            sendTextResult(id: id, text: "capture_visible = \(visible) (sharingType = \(visible ? "NSWindowSharingType.readOnly" : "NSWindowSharingType.none")), applied to all AI Chalkboard instances. \(explanation)")

        default:
            sendErrorResult(id: id, text: "Unknown tool: \(name)")
        }
    }

    // MARK: - Diagnostic payload builders

    /// `JSONSerialization` cannot encode Swift's `nil`; it needs `NSNull`. And
    /// `optional ?? NSNull()` does not type-check (mismatched operand types), so
    /// this does the widening to `Any` explicitly. Used so that an absent app
    /// link serialises as an explicit JSON `null` -- which is meaningful here
    /// ("global, visible everywhere") -- rather than the key vanishing.
    private func jsonValue(_ value: String?) -> Any {
        guard let value = value else { return NSNull() }
        return value
    }

    /// Encodes a `Codable` value and immediately decodes it back through
    /// `JSONSerialization`, producing plain `[String: Any]`/`[Any]`-shaped
    /// data. Used where an `Encodable` model (`[ScreenInfo]`, an
    /// `Annotation`) needs to be embedded inside a hand-built
    /// `JSONSerialization` payload alongside sibling keys that are not
    /// themselves `Codable` -- `get_screens` and `list_annotations` both did
    /// this exact two-step conversion by hand; this is the one copy.
    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Serializes a `JSONSerialization`-compatible object (built from
    /// `[String: Any]`/`[Any]`/`String`/`Bool`/`NSNumber`/`NSNull`) to a
    /// UTF-8 JSON string. `get_screens`, `list_annotations`, and
    /// `get_active_app` each built and threw away this exact
    /// `data(withJSONObject:)` -> `String(data:encoding:)` pair individually;
    /// this is the one copy.
    private func jsonString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `list_annotations` output: the raw encoded annotations, each enriched
    /// with the app it is linked to and whether it is on screen at this instant,
    /// wrapped alongside the current active app. The combination is what makes
    /// "I drew it and nothing appeared" self-diagnosing -- the answer is nearly
    /// always `isVisibleNow: false` because the linked app is not frontmost.
    private func buildAnnotationListJSON() -> String {
        let annotations = AnnotationStore.shared.getAll()
        let activeId = ActiveAppTracker.shared.currentAppId
        let captureVisible = OverlayWindowController.shared.isCaptureVisible

        // `ActiveAppTracker.displayName(forBundleId:)` is only consulted as a
        // fallback for annotations whose `appName` was never captured at
        // creation time (see `Annotation.appName`'s doc comment), but each
        // call independently hops to the main thread to enumerate
        // `NSWorkspace.runningApplications`. With N such annotations that was
        // N main-thread round trips per `list_annotations` call. This memo
        // resolves each DISTINCT bundle id at most once per call by caching
        // as it goes, rather than changing `ActiveAppTracker` itself.
        var displayNameMemo: [String: String?] = [:]
        func resolvedDisplayName(forBundleId bundleId: String) -> String? {
            if let cached = displayNameMemo[bundleId] { return cached }
            let name = ActiveAppTracker.shared.displayName(forBundleId: bundleId)
            displayNameMemo[bundleId] = name
            return name
        }

        var entries: [[String: Any]] = []
        for annotation in annotations {
            // Round-tripping through the existing Codable encoding keeps the
            // `kind` payload byte-identical to what this tool returned before,
            // rather than re-deriving it by hand and risking drift.
            guard var object = jsonObject(annotation) as? [String: Any] else {
                continue
            }
            // Optionals are omitted entirely by the synthesized encoder, so set
            // them explicitly (JSONSerialization needs NSNull, not nil).
            object["appId"] = jsonValue(annotation.appId)
            object["appName"] = jsonValue(
                annotation.appName ?? annotation.appId.flatMap(resolvedDisplayName(forBundleId:))
            )
            object["type"] = annotation.kind.typeName
            object["scope"] = annotation.appId == nil ? "global" : "app-linked"
            object["isVisibleNow"] = captureVisible || annotation.appId == nil || annotation.appId == activeId
            entries.append(object)
        }

        let payload: [String: Any] = [
            "activeApp": [
                "bundleId": jsonValue(activeId),
                "name": jsonValue(ActiveAppTracker.shared.currentAppName)
            ] as [String: Any],
            "captureVisible": captureVisible,
            "count": entries.count,
            "annotations": entries,
            "note": "With captureVisible=false, an annotation is drawn only when scope='global' or its appId equals activeApp.bundleId. With captureVisible=true, every annotation is drawn for capture-debug placement checks. External capture filters still decide whether the overlay is included. isVisibleNow reflects the current rendering mode."
        ]

        guard let text = jsonString(payload) else {
            return "Error: failed to encode annotation list."
        }
        return text
    }

    /// `get_active_app` output.
    private func buildActiveAppJSON() -> String {
        let tracker = ActiveAppTracker.shared
        let raw = tracker.rawFrontmostApp()

        let payload: [String: Any] = [
            "frontmost": [
                "bundleId": jsonValue(tracker.currentAppId),
                "name": jsonValue(tracker.currentAppName)
            ] as [String: Any],
            "fallback": [
                "bundleId": jsonValue(tracker.fallbackAppId),
                "name": jsonValue(tracker.fallbackAppName)
            ] as [String: Any],
            "rawFrontmost": [
                "bundleId": jsonValue(raw?.bundleId),
                "name": jsonValue(raw?.name)
            ] as [String: Any],
            "captureVisible": OverlayWindowController.shared.isCaptureVisible,
            "note": "'frontmost' is the app whose annotations are on screen right now. 'fallback' is what an untagged draw_* call links to: the last app that was frontmost excluding AI Chalkboard and Claude -- because when you receive a draw request, Claude's own window is frontmost, so tagging the true frontmost app would link every annotation to Claude and it would never show over the app the user meant. 'rawFrontmost' is the unfiltered NSWorkspace value, for debugging only. A null fallback means an untagged draw becomes GLOBAL."
        ]

        guard let text = jsonString(payload) else {
            return "Error: failed to encode active app info."
        }
        return text
    }
}
