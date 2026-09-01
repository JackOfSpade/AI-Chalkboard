import Foundation
#if os(macOS)
import AppKit
#elseif os(Windows)
import WinSDK
#endif

#if os(macOS)
/// The process-id type `resolveRunningHighlightTarget`/`AccessibilityElementResolver.resolve`
/// share on this platform -- unchanged from before this file gained a
/// Windows branch.
private typealias HighlightProcessID = pid_t
#elseif os(Windows)
/// `pid_t` does not exist on the Windows Swift toolchain (confirmed by a
/// direct compile attempt: `error: cannot find type 'pid_t' in scope`).
/// `UInt32` is both what chalkboard_win.h declares `chalk_uia_find_element`'s
/// `process_id` parameter as and what `PROCESSENTRY32W.th32ProcessID`
/// naturally hands back (see `processIDs(forExecutableIdentity:)` below), so
/// it is the natural Windows analogue used throughout this file's Windows
/// branch and by `AccessibilityElementResolver.resolve(processID:...)`.
private typealias HighlightProcessID = UInt32
#endif

/// The outline traced around an Accessibility element's padded bounds.
/// `.rect` is the historical, still-default behaviour; `.ellipse` and
/// `.circle` exist because a lot of real UI controls are round or pill-shaped
/// (radio buttons, circular icon buttons, dots), and ringing one with a
/// rectangle draws attention to its bounding box rather than its actual
/// silhouette.
private enum HighlightShape: String {
    case rect, ellipse, circle
}

private struct HighlightStyle {
    let strokeColor: String
    let strokeWidth: Double
    let strokeOpacity: Double
    let fillColor: String?
    let fillOpacity: Double
    let padding: Double
    let shape: HighlightShape
}

/// Renderer-visible alpha includes a color's own RGBA alpha.  Named colors
/// carry alpha too, so checking only a separately supplied opacity would let
/// `#RRGGBB00` create an annotation that can never paint a pixel.
// internal: called from makeVectorPathKind, makeTextKind, and patchKind in
// MCPToolHandlers+Drawing.swift.
func colorHasVisibleAlpha(_ color: String?) -> Bool {
    guard let color else { return false }
    return ColorParser.parse(color).alpha > 0
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
        // The traversal budgets are caller-settable because the errors they
        // produce used to be unactionable: the breadth-first walk visits every
        // element regardless of what is being searched for, so a caller told
        // to "refine the label or role" had no way to make the SAME lookup
        // finish. These two arguments are the only things that actually move
        // that outcome, and they are deliberately raised TOGETHER -- a
        // measured DaVinci Resolve session walks ~5,200 elements/second, so
        // the 10,000-node ceiling needs roughly 1.9s and would otherwise trip
        // the 2.0s default deadline instead of returning a match.
        if args.keys.contains("max_nodes"), MCPArgument.integer(args["max_nodes"]) == nil {
            sendErrorResult(id: id, text: "max_nodes must be an integer between 1 and \(AccessibilityElementResolver.absoluteMaxNodes) when supplied.")
            return
        }
        let maxNodes = MCPArgument.integer(args["max_nodes"]) ?? AccessibilityElementResolver.defaultMaxNodes
        guard maxNodes > 0, maxNodes <= AccessibilityElementResolver.absoluteMaxNodes else {
            sendErrorResult(id: id, text: "max_nodes must be between 1 and \(AccessibilityElementResolver.absoluteMaxNodes).")
            return
        }
        if MCPArgument.hasInvalidSuppliedDouble(args, key: "timeout_seconds") {
            sendErrorResult(id: id, text: "timeout_seconds must be a finite number when supplied.")
            return
        }
        let timeoutSeconds = MCPArgument.double(args["timeout_seconds"]) ?? AccessibilityElementResolver.defaultTraversalTimeoutSeconds
        guard timeoutSeconds >= AccessibilityElementResolver.minTraversalTimeoutSeconds,
              timeoutSeconds <= AccessibilityElementResolver.maxTraversalTimeoutSeconds else {
            sendErrorResult(id: id, text: "timeout_seconds must be between \(AccessibilityElementResolver.minTraversalTimeoutSeconds) and \(AccessibilityElementResolver.maxTraversalTimeoutSeconds).")
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
        if let error = DrawRequest.rejectDurationSecondsIfSupplied(args: args) {
            sendErrorResult(id: id, text: error)
            return
        }
        let style: HighlightStyle
        switch makeHighlightStyle(args: args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): style = value
        }

        let target: (app: AppRef, pid: HighlightProcessID)
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
                    occurrence: MCPArgument.integer(args["occurrence"]),
                    maxNodes: maxNodes,
                    timeoutSeconds: timeoutSeconds
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

    #if os(macOS)
    private func resolveRunningHighlightTarget(_ args: [String: Any]) -> DrawOutcome<(app: AppRef, pid: HighlightProcessID)> {
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
        let runningPIDs: [HighlightProcessID] = MainThread.sync {
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
    #elseif os(Windows)
    /// Resolves the `app` argument to a live Windows process. Same contract
    /// and guarantees as the macOS branch above (see its doc comments for
    /// the "GLOBAL is not supported", ambiguity-refusal, and TOCTOU notes,
    /// all unchanged in spirit here), with two substitutions forced by the
    /// platform:
    ///
    /// (a) APP IDENTITY. Windows has no bundle-identifier concept.
    ///     `AppRef.bundleId` is ASSUMED here to hold an executable name such
    ///     as `"Resolve.exe"` or its extension-less stem, matched case-
    ///     insensitively -- per this task's brief, this mirrors the Windows
    ///     app-identity model `ActiveAppTracker` defines separately (owned
    ///     by another change, not this one). This file does not itself
    ///     define that identity string; it only assumes the shape above. If
    ///     the actual `ActiveAppTracker` Windows implementation picks a
    ///     different identity shape (e.g. a full path, or a different
    ///     matching rule), `processIDs(forExecutableIdentity:)` below must
    ///     be updated to match -- see contractChanges/followUps.
    ///
    /// (b) PID RESOLUTION. In place of `NSWorkspace.runningApplications`'s
    ///     bundle-id filter, this enumerates every running process via
    ///     `CreateToolhelp32Snapshot` and matches executable names --
    ///     see `processIDs(forExecutableIdentity:)`. Like the macOS branch,
    ///     this does NOT close the gap between resolving the app and
    ///     enumerating processes, nor between this snapshot and the UI
    ///     Automation query that follows: the process can exit, or a second
    ///     instance can launch, in either window.
    private func resolveRunningHighlightTarget(_ args: [String: Any]) -> DrawOutcome<(app: AppRef, pid: HighlightProcessID)> {
        if args.keys.contains("app"), !(args["app"] is String) {
            return .failure("app must be a running app's executable name or display name when supplied.")
        }
        let app: AppRef
        if let supplied = args["app"] as? String {
            let raw = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                return .failure("highlight_element cannot target GLOBAL visibility; app must resolve to one running application so its UI Automation tree can be queried.")
            }
            switch ActiveAppTracker.shared.resolve(raw) {
            case .resolved(let value): app = value
            case .ambiguous(let matches):
                let candidates = matches.map { "'\($0.name)' [\($0.bundleId)]" }.joined(separator: ", ")
                return .failure("App '\(raw)' is AMBIGUOUS across running applications: \(candidates). Retry with an exact executable name or display name.")
            case .notFound:
                return .failure("App '\(raw)' is not running or could not be resolved. highlight_element requires a running target application with a process id.")
            }
        } else {
            // Paired read: the identity and the name become one AppRef, same
            // reasoning as the macOS branch's `fallbackApp` comment.
            let fallback = ActiveAppTracker.shared.fallbackApp
            guard let identity = fallback.bundleId else {
                return .failure("No fallback running app is available. Pass app with an exact running app executable name or display name; GLOBAL highlighting is not supported.")
            }
            app = AppRef(bundleId: identity, name: fallback.name ?? identity)
        }

        let matchingPIDs = Self.processIDs(forExecutableIdentity: app.bundleId)
        guard matchingPIDs.count == 1, let target = matchingPIDs.first else {
            return matchingPIDs.isEmpty
                ? .failure("App '\(app.name)' [\(app.bundleId)] is no longer running, so its UI Automation tree cannot be queried.")
                : .failure("App '\(app.name)' [\(app.bundleId)] has \(matchingPIDs.count) running processes. highlight_element refuses to guess which process id to inspect.")
        }
        return .success((app, target))
    }

    /// Enumerates every running process via `CreateToolhelp32Snapshot`
    /// (`TH32CS_SNAPPROCESS`) and returns the process ids whose executable
    /// file name -- or that name's extension-less stem -- case-
    /// insensitively matches `identity`. This is the Windows substitute for
    /// `NSWorkspace.runningApplications`'s bundle-id filter on the macOS
    /// branch: Win32 has no bundle-identifier concept, only a per-process
    /// executable file name (`PROCESSENTRY32W.szExeFile`), so process
    /// identity here is that name. Matching both the full file name AND its
    /// stem tolerates a caller (or `ActiveAppTracker`) supplying either
    /// `"Resolve.exe"` or `"Resolve"`.
    private static func processIDs(forExecutableIdentity identity: String) -> [HighlightProcessID] {
        let loweredFull = identity.lowercased()
        let loweredStem = stem(of: identity).lowercased()

        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
              snapshot != INVALID_HANDLE_VALUE else {
            return []
        }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var matches: [HighlightProcessID] = []
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
    /// for a one-line string operation.
    private static func stem(of fileName: String) -> String {
        guard let dotIndex = fileName.lastIndex(of: ".") else { return fileName }
        return String(fileName[..<dotIndex])
    }
    #endif

    private func makeHighlightStyle(args: [String: Any]) -> DrawOutcome<HighlightStyle> {
        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["padding_px", "stroke_width", "stroke_opacity", "fill_opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        if let key = MCPArgument.firstNonStringSupplied(args, keys: ["stroke_color", "color", "fill_color"]) {
            return .failure("\(key) must be a string when supplied.")
        }
        // Checked separately from the other string arguments above (rather
        // than folded into the generic firstNonStringSupplied scan) because
        // it needs its own wording: an unknown shape and a wrong-typed shape
        // are different mistakes, and the caller should be told which one it
        // made -- exactly the same reasoning `match` gets its own check in
        // handleHighlightElement above.
        if args.keys.contains("shape"), !(args["shape"] is String) {
            return .failure("shape must be 'rect', 'ellipse', or 'circle' when supplied.")
        }
        let shape: HighlightShape
        switch (args["shape"] as? String)?.lowercased() ?? "rect" {
        case "rect": shape = .rect
        case "ellipse": shape = .ellipse
        case "circle": shape = .circle
        default:
            return .failure("shape must be 'rect', 'ellipse', or 'circle'.")
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
            fillColor: fillColor, fillOpacity: fillOpacity, padding: padding, shape: shape
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

        let data: String
        switch style.shape {
        case .rect:
            // Byte-identical to the pre-`shape` behaviour: an omitted `shape`
            // must change nothing about what an existing caller gets back.
            data = "M \(x) \(y) H \(x + width) V \(y + height) H \(x) Z"

        case .ellipse:
            // Inscribed in the padded bounds -- the ellipse touches the
            // padded rectangle at the midpoint of each of its four edges.
            // That is the natural reading of "ellipse around this element":
            // the padded rectangle already traces the element's outline, so
            // the tightest ellipse containing it is the one tangent to it.
            let cx = x + width / 2
            let cy = y + height / 2
            let rx = width / 2
            let ry = height / 2
            guard [cx, cy, rx, ry].allSatisfy(\.isFinite),
                  [cx, cy, rx, ry].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
                  rx > 0, ry > 0 else {
                return .failure("Resolved accessibility bounds are not usable for a highlight.")
            }
            data = ellipsePathData(centerX: cx, centerY: cy, radiusX: rx, radiusY: ry)

        case .circle:
            // Concentric with the padded bounds, but sized to CIRCUMSCRIBE
            // them (r = max(width, height)/2) rather than inscribe them (r =
            // min(width, height)/2). A UI element -- a button, a toolbar
            // icon -- is usually wider than it is tall; an inscribed circle
            // would clip its left/right ends, which defeats the entire point
            // of ringing it. Circumscribing costs a little extra ring
            // above/below a wide element in exchange for never cutting off
            // what it is meant to highlight.
            let cx = x + width / 2
            let cy = y + height / 2
            let r = max(width, height) / 2
            guard [cx, cy, r].allSatisfy(\.isFinite),
                  [cx, cy, r].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
                  r > 0 else {
                return .failure("Resolved accessibility bounds are not usable for a highlight.")
            }
            data = ellipsePathData(centerX: cx, centerY: cy, radiusX: r, radiusY: r)
        }

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
