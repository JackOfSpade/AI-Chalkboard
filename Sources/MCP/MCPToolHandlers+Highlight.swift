import Foundation
import AppKit

private struct HighlightStyle {
    let strokeColor: String
    let strokeWidth: Double
    let strokeOpacity: Double
    let fillColor: String?
    let fillOpacity: Double
    let padding: Double
}

/// Renderer-visible alpha includes a color's own RGBA alpha.  Named colors
/// carry alpha too, so checking only a separately supplied opacity would let
/// `#RRGGBB00` create an annotation that can never paint a pixel.
// internal: called from makeVectorPathKind, makeTextKind, and patchKind in
// MCPToolHandlers+Drawing.swift.
func colorHasVisibleAlpha(_ color: String?) -> Bool {
    guard let color else { return false }
    return ColorParser.parse(color).alphaComponent > 0
}

extension MCPServer {
    // MARK: - Accessibility and verification

    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleHighlightElement(id: Any, args: [String: Any]) {
        guard let suppliedLabel = args["label"] as? String else {
            sendErrorResult(id: id, text: "Missing required string parameter: label")
            return
        }
        let label = suppliedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= DrawingDefaults.maxHighlightLabelCharacters else {
            sendErrorResult(id: id, text: "label must be a non-empty string containing at most \(DrawingDefaults.maxHighlightLabelCharacters) characters.")
            return
        }
        if args.keys.contains("role"), !(args["role"] is String) {
            sendErrorResult(id: id, text: "role must be a string when supplied.")
            return
        }
        if let role = args["role"] as? String,
           role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendErrorResult(id: id, text: "role must be non-empty when supplied.")
            return
        }
        if args.keys.contains("match"), !(args["match"] is String) {
            sendErrorResult(id: id, text: "match must be 'exact' or 'contains' when supplied.")
            return
        }
        let matchMode: AccessibilityLabelMatchMode
        switch (args["match"] as? String)?.lowercased() ?? "exact" {
        case "exact": matchMode = .exact
        case "contains": matchMode = .contains
        default:
            sendErrorResult(id: id, text: "match must be 'exact' or 'contains'.")
            return
        }
        if args.keys.contains("occurrence"), MCPArgument.integer(args["occurrence"]) == nil {
            sendErrorResult(id: id, text: "occurrence must be a one-based integer when supplied.")
            return
        }
        if let occurrence = MCPArgument.integer(args["occurrence"]), occurrence < 1 {
            sendErrorResult(id: id, text: "occurrence must be one-based and greater than zero.")
            return
        }

        // Validate every local/style argument before resolving a process or
        // touching the Accessibility hierarchy. A malformed highlight must not
        // trigger a TCC check or cross-process AX IPC merely to fail later.
        if args.keys.contains("z"), MCPArgument.integer(args["z"]) == nil {
            sendErrorResult(id: id, text: "z must be an integer when supplied.")
            return
        }
        if args.keys.contains("z_index"), MCPArgument.integer(args["z_index"]) == nil {
            sendErrorResult(id: id, text: "z_index must be an integer when supplied.")
            return
        }
        var finishArgs = args
        if let z = MCPArgument.integer(args["z"]) {
            if let zIndex = MCPArgument.integer(args["z_index"]), zIndex != z {
                sendErrorResult(id: id, text: "z and z_index must match when both are supplied.")
                return
            }
            finishArgs["z_index"] = z
        }
        if let error = DrawRequest.validateDurationSeconds(args: args) {
            sendErrorResult(id: id, text: error)
            return
        }
        let style: HighlightStyle
        switch makeHighlightStyle(args: args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): style = value
        }

        let target: (app: AppRef, pid: pid_t)
        switch resolveRunningHighlightTarget(args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): target = value
        }

        let screens = OverlayWindowController.shared.screenSnapshot().screens
        let match: AccessibilityElementMatch
        do {
            match = try AccessibilityElementResolver.resolve(
                processID: target.pid,
                request: AccessibilityElementRequest(
                    label: label,
                    role: args["role"] as? String,
                    matchMode: matchMode,
                    occurrence: MCPArgument.integer(args["occurrence"])
                ),
                screens: screens
            )
        } catch {
            sendErrorResult(id: id, text: error.localizedDescription)
            return
        }
        guard let screen = screens.first(where: { $0.id == match.backingFrame.screenId }) else {
            sendErrorResult(id: id, text: "The resolved accessibility element belongs to a display that is no longer connected. Retry the lookup.")
            return
        }

        let kind: AnnotationKind
        switch makeHighlightKind(style: style, frame: match.backingFrame) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): kind = value
        }

        var created: Annotation?
        let request = DrawRequest(screen: screen)
        switch request.finish(
            args: finishArgs,
            defaultColor: DrawingDefaults.pathColor,
            label: "Accessibility highlight: \(match.matchedLabel)",
            defaultsToGlobal: false,
            kind: kind,
            noun: "Accessibility element highlight",
            resolvedTargetApp: target.app,
            onAnnotationCreated: { created = $0 }
        ) {
        case .failure(let error):
            sendErrorResult(id: id, text: error)
        case .success(let message):
            var payload: [String: Any] = [
                "message": message,
                "annotationId": created?.id ?? NSNull(),
                "targetApp": ["bundleId": target.app.bundleId, "name": target.app.name],
                "anchorBehavior": "resolved once at draw time; call highlight_element again after the UI moves"
            ]
            payload["matchedElement"] = jsonObject(match) ?? NSNull()
            guard let text = jsonString(payload) else {
                sendErrorResult(id: id, text: "Created the highlight but failed to encode its accessibility metadata.")
                return
            }
            sendTextResult(id: id, text: text)
        }
    }

    private func resolveRunningHighlightTarget(_ args: [String: Any]) -> DrawOutcome<(app: AppRef, pid: pid_t)> {
        if args.keys.contains("app"), !(args["app"] is String) {
            return .failure("app must be a running app's bundle id or display name when supplied.")
        }
        let app: AppRef
        if let supplied = args["app"] as? String {
            let raw = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                return .failure("highlight_element cannot target GLOBAL visibility; app must resolve to one running application so its Accessibility hierarchy can be queried.")
            }
            switch ActiveAppTracker.shared.resolve(raw) {
            case .resolved(let value): app = value
            case .ambiguous(let matches):
                let candidates = matches.map { "'\($0.name)' [\($0.bundleId)]" }.joined(separator: ", ")
                return .failure("App '\(raw)' is AMBIGUOUS across running applications: \(candidates). Retry with an exact bundle id or display name.")
            case .notFound:
                return .failure("App '\(raw)' is not running or could not be resolved. highlight_element requires a running target application with a PID.")
            }
        } else {
            // Paired read: the id and the name become one AppRef, so they must
            // come from a single lock acquisition -- see
            // `ActiveAppTracker.fallbackApp`.
            let fallback = ActiveAppTracker.shared.fallbackApp
            guard let bundleId = fallback.bundleId else {
                return .failure("No fallback running app is available. Pass app with an exact running app bundle id or display name; GLOBAL highlighting is not supported.")
            }
            app = AppRef(bundleId: bundleId, name: fallback.name ?? bundleId)
        }

        // `NSWorkspace.runningApplications` is AppKit, and this runs on the MCP
        // server's background read queue, so the enumeration takes the same
        // main-thread hop every other NSWorkspace query in this package takes
        // (see MainThread.sync, whose contract names this exact API). The PIDs
        // are extracted INSIDE the hop so no NSRunningApplication -- a live,
        // main-thread-owned object -- escapes back to the read queue; a plain
        // pid_t is just a number.
        //
        // This does NOT close the gap between resolving the app above and
        // enumerating here, nor the one between this snapshot and the
        // Accessibility query that follows: the process can exit, or a second
        // instance can launch, in either window. The hop is a threading
        // correction, not a TOCTOU fix.
        let runningPIDs: [pid_t] = MainThread.sync {
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == app.bundleId && !$0.isTerminated }
                .map { $0.processIdentifier }
        }
        guard runningPIDs.count == 1, let target = runningPIDs.first else {
            return runningPIDs.isEmpty
                ? .failure("App '\(app.name)' [\(app.bundleId)] is no longer running, so its Accessibility hierarchy cannot be queried.")
                : .failure("App '\(app.name)' [\(app.bundleId)] has \(runningPIDs.count) running processes. highlight_element refuses to guess which PID to inspect.")
        }
        return .success((app, target))
    }

    private func makeHighlightStyle(args: [String: Any]) -> DrawOutcome<HighlightStyle> {
        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["padding_px", "stroke_width", "stroke_opacity", "fill_opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        if let key = MCPArgument.firstNonStringSupplied(args, keys: ["stroke_color", "color", "fill_color"]) {
            return .failure("\(key) must be a string when supplied.")
        }
        let explicitStroke = args["stroke_color"] as? String
        let colorAlias = args["color"] as? String
        if let explicitStroke, let colorAlias, explicitStroke != colorAlias {
            return .failure("stroke_color and color are aliases for highlight_element and must match when both are supplied.")
        }
        let strokeColor = explicitStroke ?? colorAlias ?? DrawingDefaults.pathColor
        let strokeWidth = MCPArgument.double(args["stroke_width"]) ?? 4
        let strokeOpacity = MCPArgument.double(args["stroke_opacity"]) ?? 1
        let fillColor = args["fill_color"] as? String
        let fillOpacity = MCPArgument.double(args["fill_opacity"]) ?? (fillColor == nil ? 0 : 0.15)
        let padding = MCPArgument.double(args["padding_px"]) ?? 8
        guard strokeWidth.isFinite, strokeWidth > 0, strokeWidth <= DrawingDefaults.maxStyleDimensionPx,
              strokeOpacity.isFinite, (0...1).contains(strokeOpacity),
              fillOpacity.isFinite, (0...1).contains(fillOpacity),
              padding.isFinite, padding >= 0, padding <= DrawingDefaults.maxStyleDimensionPx else {
            // The stroke_width half of this message says "greater than 0", not
            // "0...", because the guard above genuinely rejects 0: a
            // zero-width stroke would satisfy the visible-stroke-or-fill check
            // immediately below (its color still has alpha) and then draw
            // nothing at all. The old wording advertised a value the handler
            // refuses.
            return .failure("stroke_width must be greater than 0 and no more than \(Int(DrawingDefaults.maxStyleDimensionPx)); opacity values must be 0...1; and padding_px must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)).")
        }
        guard (colorHasVisibleAlpha(strokeColor) && strokeOpacity > 0)
                || (colorHasVisibleAlpha(fillColor) && fillOpacity > 0) else {
            return .failure("The highlight must have a visible stroke or fill.")
        }
        return .success(HighlightStyle(
            strokeColor: strokeColor, strokeWidth: strokeWidth, strokeOpacity: strokeOpacity,
            fillColor: fillColor, fillOpacity: fillOpacity, padding: padding
        ))
    }

    private func makeHighlightKind(style: HighlightStyle, frame: AccessibilityBackingRect) -> DrawOutcome<AnnotationKind> {
        let x = frame.x - style.padding
        let y = frame.y - style.padding
        let width = frame.width + 2 * style.padding
        let height = frame.height + 2 * style.padding
        guard [x, y, width, height].allSatisfy(\.isFinite),
              [x, y, width, height].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
              width > 0, height > 0 else {
            return .failure("Resolved accessibility bounds are not usable for a highlight.")
        }
        let data = "M \(x) \(y) H \(x + width) V \(y + height) H \(x) Z"
        return .success(.vectorPath(
            data: data,
            strokeColorHex: style.strokeColor,
            strokeWidth: style.strokeWidth,
            strokeOpacity: style.strokeOpacity,
            fillColorHex: style.fillColor,
            fillOpacity: style.fillOpacity,
            dash: [],
            usesEvenOddFillRule: false,
            coordinateScaleX: 1,
            coordinateScaleY: 1
        ))
    }
}
