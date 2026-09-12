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
/// internal (not private): `handleCalibrateScreenshotSpaceElements` in
/// MCPToolHandlers+ScreenshotSpace.swift names this type when it calls
/// `resolveRunningHighlightTarget`, and `private` at file scope would hide it.
typealias HighlightProcessID = pid_t
#elseif os(Windows)
/// `pid_t` does not exist on the Windows Swift toolchain (confirmed by a
/// direct compile attempt: `error: cannot find type 'pid_t' in scope`).
/// `UInt32` is both what chalkboard_win.h declares `chalk_uia_find_element`'s
/// `process_id` parameter as and what `PROCESSENTRY32W.th32ProcessID`
/// naturally hands back (see `MCPServer.runningProcessIds(forAppId:)`'s
/// Windows branch in DrawRequest.swift), so it is the natural Windows
/// analogue used throughout this file's Windows
/// branch and by `AccessibilityElementResolver.resolve(processID:...)`.
/// internal (not private), for the same cross-file reason as the macOS twin above.
typealias HighlightProcessID = UInt32
#endif

/// The outline traced around an Accessibility element's padded bounds.
/// `.rect` is the historical, still-default behaviour; `.ellipse` and
/// `.circle` exist because a lot of real UI controls are round or pill-shaped
/// (radio buttons, circular icon buttons, dots), and ringing one with a
/// rectangle draws attention to its bounding box rather than its actual
/// silhouette.
///
/// The real declaration -- and the outline arithmetic itself -- now lives in
/// `HighlightOutlineGeometry` (Sources/Support/HighlightOutlineGeometry.swift),
/// platform-neutral and MCP-free so the element anchor tracker can regenerate
/// a highlight's outline after its window settles without reaching into this
/// file. This is a typealias, not a second enum, so this file's own shape
/// vocabulary can never drift from the one `HighlightOutlineGeometry` defines
/// -- exactly the kind of drift that put a ring through the middle of a 44x44
/// button before. The raw values are the wire strings `highlight_element`'s
/// `shape` argument accepts and are part of the published schema (see
/// MCPToolCatalog.swift); do not rename them.
typealias HighlightOutlineShape = HighlightOutlineGeometry.Shape

/// Thin forwarding wrapper over `HighlightOutlineGeometry.rawPathData` (see
/// that type in Sources/Support/HighlightOutlineGeometry.swift for the actual
/// arithmetic, moved there verbatim so the element anchor tracker can share
/// it without reaching into this MCP-only file). Kept here, under its
/// original name and signature, purely so this function's existing callers --
/// notably `MCPShapeGeometryTests`, which pins this exact geometry with
/// nothing but a few doubles -- need not change.
///
/// ARITHMETIC ONLY, no validation, exactly as before: every finite/magnitude/
/// positivity check stays in `makeHighlightKind` below, which must reject bad
/// bounds with its own error text before any path exists (now via
/// `HighlightOutlineGeometry.pathData`). Callers must validate first.
func highlightOutlinePathData(
    shape: HighlightOutlineShape,
    frameX: Double,
    frameY: Double,
    frameWidth: Double,
    frameHeight: Double,
    padding: Double
) -> String {
    HighlightOutlineGeometry.rawPathData(
        shape: shape, frameX: frameX, frameY: frameY,
        frameWidth: frameWidth, frameHeight: frameHeight, padding: padding
    )
}

/// The extra `highlight_element` result fields that disclose a
/// short-circuited search, or an empty dictionary when the search was NOT
/// short-circuited.
///
/// WHY THIS EXISTS. `AccessibilityElementResolver.resolve` returns the moment
/// `matches.count == occurrence`, and that return is a TRUNCATED walk: it
/// never visits the rest of the tree, so it never learns whether another
/// element carries the same label. The post-walk ambiguity check (`guard
/// matches.count == 1`) is provably unreachable on every occurrence-supplied
/// success path, because reaching it requires the loop to run to completion,
/// which an occurrence-supplied match by construction prevents. Until now
/// nothing said so: an occurrence-driven success and an
/// uniqueness-PROVEN success produced byte-identical payloads, so a caller
/// had no way to tell "this is the only 'Render' button" from "this is the
/// first of possibly many". The fix is disclosure, NOT more walking -- the
/// short circuit is what keeps `highlight_element` inside its max_nodes and
/// timeout budgets on the large trees that need occurrence in the first
/// place (measured: 0.01-1.3s with occurrence versus a 4.2s node-cap failure
/// without it).
///
/// A free, internal, pure function -- no `MCPServer`, no Accessibility, no
/// display -- for the same reason `highlightOutlinePathData` above is one:
/// the wire KEY NAMES and the note's wording are the entire product here, and
/// a test can pin them with nothing but an `Int?`.
///
/// The keys are absent (rather than present-and-false) when `occurrence` was
/// not supplied: their presence IS the signal, and a payload that grows two
/// permanent fields to say "nothing unusual happened" trains a reader to skip
/// them.
func highlightSearchDisclosureFields(occurrence: Int?) -> [String: Any] {
    guard let occurrence else { return [:] }
    return [
        "searchWasShortCircuited": true,
        "searchShortCircuitNote": "Because occurrence was supplied, the accessibility walk stopped at highlightable match \(occurrence) instead of finishing the tree, so uniqueness was NOT checked: other elements may share this label, and this may not be the one you meant. Confirm the placement with verify_annotation before relying on it."
    ]
}

private struct HighlightStyle {
    let strokeColor: String
    let strokeWidth: Double
    let strokeOpacity: Double
    let fillColor: String?
    let fillOpacity: Double
    let padding: Double
    let shape: HighlightOutlineShape
}

// MARK: - `anchor`/`anchor_resize` argument parsing (highlight_element)

/// The purely-string-validated outcome of `highlight_element`'s
/// `anchor`/`anchor_resize` arguments. `nil` means anchor="none": no
/// `AnnotationAnchor` is attached and this highlight resolves once at draw
/// time, exactly as it always has. Unlike `DrawRequest.AnchorArgumentRequest`
/// (every `draw_*` tool's `.window`-only, `"none"`-default vocabulary), this
/// also carries the requested `AnchorMode`, because `highlight_element` alone
/// can additionally request `.element`, and defaults to it -- see
/// `parseHighlightAnchorArguments` below.
struct HighlightAnchorRequest: Equatable {
    let mode: AnchorMode
    let resize: AnchorResizeBehavior
}

/// Validates ONLY `anchor`/`anchor_resize`'s STRINGS -- no process
/// resolution, no window enumeration, no Accessibility/TCC work -- mirroring
/// `DrawRequest.parseAnchorArguments`'s "reject before AX/TCC work" contract
/// (see that function's own doc comment, and `rejectDurationSecondsIfSupplied`'s,
/// for the identical reasoning): `handleHighlightElement` calls this BEFORE
/// `resolveRunningHighlightTarget`/`AccessibilityElementResolver.resolve`, so
/// a typo'd `anchor` value fails before it can trigger a process lookup or a
/// cross-process Accessibility walk.
///
/// `highlight_element`'s vocabulary differs from every `draw_*` tool's (see
/// MCP_SURFACE.md's argument table: `"element"` here is the NEW DEFAULT,
/// alongside `"window"`/`"none"`, versus draw_*'s `"none"`-default
/// `"none"`/`"window"` pair), so this cannot simply call
/// `DrawRequest.parseAnchorArguments` -- it is instead this file's own small
/// three-value counterpart, following that function's exact structure.
///
/// `anchor_resize` is valid ONLY together with `anchor="window"` -- REJECTED
/// under `"none"` (no anchor window at all) AND under `"element"` (which
/// re-resolves the element's true bounds directly on settle, so no resize
/// POLICY applies -- see the shipped `highlight_element` catalog entry's own
/// `anchor_resize` description). This is narrower than
/// `DrawRequest.parseAnchorArguments`'s "REJECTED whenever the effective mode
/// is none" rule, because unlike every `draw_*` tool, `highlight_element` has
/// a THIRD mode for it to also be inapplicable to; the literal rejection
/// text ("only valid with anchor=\"window\"") already says exactly this.
/// `.element`-mode anchors therefore always carry `resize: .pin` -- an inert
/// default, since the caller has no way to choose otherwise and the interim
/// window-projection phase this briefly governs is corrected away by the
/// next on-settle regeneration regardless (see ELEMENT_MODE.md).
///
/// internal (not private): called from `handleHighlightElement` below and
/// pinned directly by tests.
func parseHighlightAnchorArguments(_ args: [String: Any]) -> DrawOutcome<HighlightAnchorRequest?> {
    if args.keys.contains("anchor"), !(args["anchor"] is String) {
        return .failure("anchor must be one of \"element\", \"window\", \"none\" when supplied.")
    }
    let anchorRaw = (args["anchor"] as? String) ?? "element"
    guard anchorRaw == "element" || anchorRaw == "window" || anchorRaw == "none" else {
        return .failure("anchor must be one of \"element\", \"window\", \"none\" when supplied.")
    }
    if args.keys.contains("anchor_resize"), !(args["anchor_resize"] is String) {
        return .failure("anchor_resize must be one of \"pin\", \"scale\" when supplied.")
    }
    let resizeRaw = args["anchor_resize"] as? String
    if let resizeRaw, resizeRaw != "pin", resizeRaw != "scale" {
        return .failure("anchor_resize must be one of \"pin\", \"scale\" when supplied.")
    }
    guard anchorRaw == "none" else {
        guard anchorRaw == "window" else {
            // anchorRaw == "element": same reject-over-ignore rule as
            // "none" below, and the SAME literal message -- `anchor_resize`
            // is unconditionally inapplicable to any mode but "window".
            guard resizeRaw == nil else {
                return .failure("anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\".")
            }
            return .success(HighlightAnchorRequest(mode: .element, resize: .pin))
        }
        let resize: AnchorResizeBehavior = (resizeRaw == "scale") ? .scale : .pin
        return .success(HighlightAnchorRequest(mode: .window, resize: resize))
    }
    // Mirrors `DrawRequest.parseAnchorArguments`'s reject-over-ignore rule for
    // `anchor_resize` supplied under the "none" effective mode: it is
    // unambiguous evidence of an intent this call cannot honour (there is no
    // anchor window without an anchor), so it is rejected rather than
    // silently ignored.
    guard resizeRaw == nil else {
        return .failure("anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\".")
    }
    return .success(nil)
}

/// Everything `AnchorTracker`'s `.element`-mode re-resolve needs to re-run
/// THIS exact lookup later, captured from the request that produced a
/// successful match. `occurrence` stores `0` when the caller did not supply
/// one -- this file's own sentinel, reusing the SAME 0-means-"require
/// exactly one" convention `AccessibilityElementRequest.occurrence == nil`
/// already has on macOS and `chalk_uia_find_element`'s `occurrence`
/// parameter already has on Windows (see `AccessibilityElementResolver
/// .resolve`'s Windows overload doc comment) -- so
/// `AccessibilityAnchorElementResolver` (Sources/Overlay/
/// AccessibilityAnchorElementResolver.swift) need only translate `0` back to
/// `nil` to reproduce this exact call's uniqueness requirement.
///
/// internal (not private): called from `handleHighlightElement` below and
/// pinned directly by tests. Takes primitive fields rather than the private
/// `HighlightStyle` struct so its signature stays visible outside this file.
func makeAnchorElementSpec(
    label: String,
    role: String?,
    matchMode: AccessibilityLabelMatchMode,
    occurrence: Int?,
    maxNodes: Int,
    timeoutSeconds: Double,
    shape: HighlightOutlineShape,
    paddingPx: Double
) -> AnchorElementSpec {
    AnchorElementSpec(
        label: label,
        role: role,
        matchMode: matchMode.rawValue,
        occurrence: occurrence ?? 0,
        maxNodes: maxNodes,
        timeoutSeconds: timeoutSeconds,
        shape: shape.rawValue,
        paddingPx: paddingPx
    )
}

/// Builds the anchor a resolved `highlight_element` match should carry, by
/// picking the containing window via largest intersection with the RESOLVED
/// ELEMENT FRAME -- deliberately never the rendered highlight's own padded/
/// shaped bounds, which is what would be passed for an ordinary `draw_*`
/// call -- among `processId`'s windows.
///
/// Reuses `DrawRequest.buildWindowAnchor` (which itself reuses
/// `TargetWindowSelection.selectWindow`) for the actual window pick and the
/// identity `.tracking` projection every new anchor is stored with, rather
/// than duplicating that selection logic: `.window` mode's result is used
/// exactly as `buildWindowAnchor` returns it (no element spec), and
/// `.element` mode re-shapes ONLY the `mode`/`element` fields of that SAME
/// resolved anchor afterward, so both modes are guaranteed to agree on which
/// window won and what its reference frame/projection are.
///
/// `nil` means `samples` offered no eligible window at all -- unlike
/// `anchor="window"` on a `draw_*` tool (which fails the call), the caller
/// here falls back to `highlight_element`'s no-fail
/// `"target_window_unresolved"` reporting instead, per MCP_SURFACE.md ("the
/// element resolved fine, and failing the call would be a regression over
/// today's behaviour").
///
/// internal (not private): called from `handleHighlightElement` below and
/// pinned directly by tests with hand-built `TargetWindowSample`s -- no live
/// foreign window needed, matching `DrawRequestAnchorTests`'s treatment of
/// `buildWindowAnchor` itself.
func buildHighlightAnchor(
    mode: AnchorMode,
    processId: Int64,
    appId: String,
    samples: [TargetWindowSample],
    elementFrame: CGRect,
    resize: AnchorResizeBehavior,
    elementSpec: AnchorElementSpec?,
    now: Date,
    screenId: String? = nil,
    screens: [ScreenInfo] = []
) -> DrawRequest.DrawAnchorResolution? {
    guard let windowResolution = DrawRequest.buildWindowAnchor(
        processId: processId, appId: appId, samples: samples,
        paintedBounds: elementFrame, resize: resize, now: now, screenId: screenId,
        screens: screens
    ) else {
        return nil
    }
    guard mode == .element else { return windowResolution }
    let anchor = windowResolution.anchor
    let elementAnchor = AnnotationAnchor(
        mode: .element,
        resize: anchor.resize,
        target: anchor.target,
        referenceWindowFrame: anchor.referenceWindowFrame,
        referenceScreenId: anchor.referenceScreenId,
        // Carried from the window resolution above, which recorded the
        // selected display's backing scale for pin-mode density
        // compensation -- see `AnnotationAnchor.referenceScreenScale`.
        referenceScreenScale: anchor.referenceScreenScale,
        element: elementSpec,
        createdAt: anchor.createdAt
    )
    return DrawRequest.DrawAnchorResolution(anchor: elementAnchor, projection: windowResolution.projection)
}

/// The `anchorBehavior` text for a highlight whose `anchor` was explicitly
/// "none", OR that could not be resolved to any window at all. Byte-identical
/// to the string this file has always returned (see MCP_SURFACE.md: "the
/// \"none\" string must stay byte-identical to today's so opting out is
/// provably today's behaviour") -- unchanged even by name, so a caller
/// diffing against yesterday's response sees no difference at all.
let highlightAnchorBehaviorNone = "resolved once at draw time; call highlight_element again after the UI moves"

/// literal text from MCP_SURFACE.md's "`anchorBehavior` (highlight_element
/// only)" section -- ship verbatim.
let highlightAnchorBehaviorElement = "tracked: follows the target window as it moves and resizes, and re-resolves this element when the window settles so it stays on the control through a reflow. Check anchor.state and anchor.elementResolutionIssue in list_annotations; call highlight_element again only if it reports lost."

/// literal text from MCP_SURFACE.md's "`anchorBehavior` (highlight_element
/// only)" section -- ship verbatim.
let highlightAnchorBehaviorWindow = "tracked: follows the target window as it moves and resizes, applying anchor_resize to the highlight geometry. The element itself is NOT re-resolved, so a UI that reflows rather than scales will drift; use anchor=\"element\" for that."

/// The special no-fail fallback payload for an `"element"`/`"window"`
/// request whose target window could not be resolved at all. Deliberately
/// NOT the standard `DrawRequest.anchorResponsePayload` shape (mode/resize/
/// state/windowId/...): this is a distinct, minimal object so a caller can
/// tell "you asked for anchor=\"none\"" (key omitted entirely) apart from
/// "you asked for tracking but no window could be found" (this object),
/// per MCP_SURFACE.md.
let highlightAnchorUnresolvedPayload: [String: Any] = ["mode": "none", "reason": "target_window_unresolved"]

/// The no-fail fallback payload for a highlight whose target window WAS
/// resolved (`buildHighlightAnchor` succeeded, below), but whose SECOND
/// store write -- installing that resolved anchor onto the just-created
/// annotation -- could not commit. Deliberately distinct from
/// `highlightAnchorUnresolvedPayload` above (BUG 5 in the adversarial review
/// this fixes): that payload means "no window could be found to track",
/// reported BEFORE any second write is even attempted, so reusing it here
/// would be false -- a window genuinely was resolved, and the highlight
/// itself is already on screen (`request.finish` stored it before this
/// file's `attachHighlightAnchor` ever runs); only attaching TRACKING to it
/// failed, because `AnnotationStore`'s own compare-and-swap or resource caps
/// rejected the second write. The wording says both things and names the
/// recovery, since the drawing does not need to be redone, only re-anchored.
let highlightAnchorAttachRejectedPayload: [String: Any] = [
    "mode": "none",
    "reason": "annotation_changed_before_anchor_attached",
    "note": "The highlight was drawn, but attaching the resolved anchor to it failed because the annotation changed (or was cleared) between its creation and this attach step. Call list_annotations to see its current state; if it still exists, update_annotation with anchor=\"window\" can attach tracking."
]

/// Maps the outcome of `attachHighlightAnchor`'s SECOND
/// `AnnotationStore.updateWithOutcome` call -- installing a resolved anchor
/// onto a just-created annotation -- to the fallback payload reported on
/// anything but `.updated`. A free, pure function (like
/// `highlightSearchDisclosureFields` above) so the reason-code MAPPING --
/// the actual BUG 5 fix -- is pinned by a test with nothing but an
/// `AnnotationStoreUpdateResult`: no live store, no window, no Accessibility
/// walk.
func highlightAnchorAttachFailurePayload(for outcome: AnnotationStoreUpdateResult) -> [String: Any]? {
    if case .updated = outcome { return nil }
    return highlightAnchorAttachRejectedPayload
}

/// The impure glue between a resolved `highlight_element` match and its
/// caller-requested anchor: samples `processId`'s windows, builds the anchor
/// via `buildHighlightAnchor` above, and -- on success -- patches it onto the
/// already-created (and, until this call returns, unanchored) annotation.
///
/// TWO STORE WRITES, deliberately: `AnnotationStore.updateWithOutcome`
/// unconditionally carries the OLD annotation's `anchorProjection` forward
/// rather than the replacement's (see that method's own doc comment on why
/// -- an ordinary `update_annotation` restyle must not reset tracking
/// state), so installing the brand-new `.tracking` identity projection needs
/// a second, explicit `applyAnchorProjections` call. This is exactly the
/// pattern `AnchorTracker.applyResolvedElement` already uses for the same
/// reason.
///
/// This function is IMPURE (live window sampling, live store mutation) and
/// therefore not unit tested directly, matching `DrawRequest
/// .resolveWindowAnchor`'s own precedent: `buildHighlightAnchor`/
/// `parseHighlightAnchorArguments`/`makeAnchorElementSpec` above carry the
/// actually-testable decisions.
///
/// Returns the `anchorBehavior` text for the FINAL resolved mode (never
/// merely the requested one -- a request that could not find a window
/// resolves to "none" behaviour, since that is genuinely what happens) and
/// the `anchor` payload to merge into the response, or `nil` to omit the key
/// entirely (MCP_SURFACE.md: "Key omitted entirely when the annotation is
/// unanchored").
private func attachHighlightAnchor(
    request: HighlightAnchorRequest?,
    created: Annotation?,
    processId: Int64,
    appId: String,
    elementFrame: CGRect,
    elementSpec: AnchorElementSpec?,
    screens: [ScreenInfo]
) -> (payload: [String: Any]?, behavior: String) {
    guard let request, let created else {
        return (nil, highlightAnchorBehaviorNone)
    }
    let samples = TargetWindowProbe.shared.windows(forProcessId: processId, screens: screens)
    guard let resolution = buildHighlightAnchor(
        mode: request.mode, processId: processId, appId: appId, samples: samples,
        elementFrame: elementFrame, resize: request.resize, elementSpec: elementSpec, now: Date(),
        screenId: created.screenId, screens: screens
    ) else {
        return (highlightAnchorUnresolvedPayload, highlightAnchorBehaviorNone)
    }
    let replacement = Annotation(
        id: created.id, screenId: created.screenId, kind: created.kind, colorHex: created.colorHex,
        label: created.label, appId: created.appId, appName: created.appName, opacity: created.opacity,
        offsetX: created.offsetX, offsetY: created.offsetY, zIndex: created.zIndex,
        anchor: resolution.anchor, staticAdjustment: created.staticAdjustment,
        anchorProjection: created.anchorProjection, revision: created.revision, createdAt: created.createdAt
    )
    let commitOutcome = AnnotationStore.shared.updateWithOutcome(
        id: created.id, with: replacement, expectedRevision: created.revision
    )
    guard case .updated = commitOutcome else {
        // BUG 5's fix: this is NOT "target_window_unresolved" -- a window
        // WAS found (`buildHighlightAnchor` already succeeded above) and the
        // highlight is already drawn. See `highlightAnchorAttachFailurePayload`'s
        // doc comment for why conflating the two would mislead the caller
        // into thinking nothing was resolved, or nothing was drawn, when
        // both happened.
        return (highlightAnchorAttachFailurePayload(for: commitOutcome), highlightAnchorBehaviorNone)
    }
    _ = AnnotationStore.shared.applyAnchorProjections([created.id: resolution.projection])
    let behavior = (resolution.anchor.mode == .element) ? highlightAnchorBehaviorElement : highlightAnchorBehaviorWindow
    return (DrawRequest.anchorResponsePayload(resolution), behavior)
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
        // Pure string validation of `anchor`/`anchor_resize`, BEFORE any
        // process resolution or AX/TCC work -- see `parseHighlightAnchorArguments`'s
        // own doc comment, and `rejectDurationSecondsIfSupplied`'s just above,
        // for why this ordering matters: a malformed anchor argument must not
        // trigger a running-process lookup or a cross-process Accessibility
        // walk merely to fail later.
        let anchorRequest: HighlightAnchorRequest?
        switch parseHighlightAnchorArguments(args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): anchorRequest = value
        }
        // `finish` below (DrawRequest.swift) validates `args["anchor"]`/
        // `args["anchor_resize"]` itself, against the DIFFERENT two-value
        // `draw_*` vocabulary -- it would reject "element" outright. Anchor
        // resolution for THIS tool is handled entirely by this file (see
        // `attachHighlightAnchor` below, called once the element itself has
        // actually been resolved), so these two keys must not reach `finish`
        // at all; stripping them here is what keeps `finish` creating a
        // plain, unanchored annotation exactly as it always has.
        finishArgs.removeValue(forKey: "anchor")
        finishArgs.removeValue(forKey: "anchor_resize")
        // The draw tools' placement-feedback riders are likewise stripped
        // before `finish` sees them: this tool's response ALREADY reports the
        // element's exact resolved bounds (`matchedElement`) and its anchor
        // state -- the very facts the riders exist to fetch -- and `finish`
        // answering them would return a JSON payload this handler then embeds
        // as its `message` STRING, nesting one JSON document inside another.
        // highlight_element's schema does not declare these arguments;
        // stripping keeps a caller who passes them anyway on the documented
        // response shape instead of a malformed hybrid.
        finishArgs.removeValue(forKey: "report_placement")
        finishArgs.removeValue(forKey: "expect_element")
        finishArgs.removeValue(forKey: "expect_window")
        finishArgs.removeValue(forKey: "target_bounds_screenshot_px")
        finishArgs.removeValue(forKey: "apply_correction")
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
        // RE-READ THE DISPLAY LAYOUT AND RE-CONVERT, rather than trusting the
        // pre-walk snapshot. `screens` above was captured BEFORE a traversal
        // that callers may legitimately let run for up to
        // `maxTraversalTimeoutSeconds` (10s), and the element's frame is read
        // live, mid-walk, in whatever display arrangement is current AT THAT
        // MOMENT. Convert that frame against a snapshot from ten seconds
        // earlier and a display reconfiguration in between silently shifts
        // the answer: `backingRect` anchors macOS's conversion to the
        // zero-origin display's height, picks the containing screen by
        // frame, and multiplies by that screen's backingScaleFactor -- all
        // three change when a monitor is added, removed, rearranged, or
        // rescaled. Nothing about that failure is visible: it returns a
        // perfectly well-formed rectangle in the wrong place, and stores the
        // annotation against a screen id that may no longer exist.
        //
        // The guard this replaces could not catch any of it. It looked the
        // resolved `screenId` up in the SAME `screens` array that produced
        // it, and `backingRect` only ever returns an id belonging to a
        // member of that array -- so "belongs to a display that is no longer
        // connected" was unreachable by construction, on both platforms.
        //
        // Re-deriving the rect from a FRESH snapshot and requiring it to be
        // identical makes the check real. Equality is the right test, not
        // "recompute and use the new value": if the two disagree, the AX
        // frame itself was measured in an arrangement we can no longer
        // identify, so NEITHER conversion is trustworthy and guessing
        // between them would just move the misplacement around. Note this
        // deliberately compares the conversion RESULT, not the snapshots:
        // `ScreenInfo.isMain` follows keyboard focus and changes constantly
        // without affecting placement at all, so comparing snapshots would
        // reject ordinary window switching. Cost is one extra main-thread
        // hop plus pure arithmetic, against a lookup that just spent
        // milliseconds-to-seconds in cross-process IPC.
        // `.live`, not the default cached read: this re-read EXISTS to detect
        // a display reconfiguration that happened during the walk, and a
        // cached snapshot served before the reconfiguration notification
        // lands would compare the pre-walk layout against itself and miss
        // exactly the change it is looking for.
        let screensAfterWalk = OverlayWindowController.shared.screenSnapshot(freshness: .live).screens
        guard let confirmedFrame = AccessibilityElementResolver.backingRect(
                  forAccessibilityFrame: match.accessibilityFrame, screens: screensAfterWalk
              ),
              confirmedFrame == match.backingFrame,
              let screen = screensAfterWalk.first(where: { $0.id == confirmedFrame.screenId })
        else {
            sendErrorResult(id: id, text: "The display layout changed while the target app's accessibility tree was being walked, so the matched element's screen coordinates cannot be converted safely (its frame was measured against the previous arrangement). Nothing was drawn. This is transient -- retry highlight_element; do not fall back to screenshot-measured coordinates, because the element itself resolved fine and anchoring will work once the layout settles.")
            return
        }

        // The RESOLVED ELEMENT FRAME -- confirmedFrame, re-derived above --
        // not the eventual highlight's own padded/shaped bounds: anchor
        // window selection must intersect against what the caller actually
        // asked to highlight, not against this tool's rendering of it.
        let elementFrame = CGRect(
            x: confirmedFrame.x, y: confirmedFrame.y,
            width: confirmedFrame.width, height: confirmedFrame.height
        )
        // Only `.element` mode re-runs this lookup later, so this is built
        // only then; `.window`/`.none` never read it.
        let elementSpec: AnchorElementSpec? = (anchorRequest?.mode == .element)
            ? makeAnchorElementSpec(
                label: label, role: args["role"] as? String, matchMode: matchMode,
                occurrence: MCPArgument.integer(args["occurrence"]), maxNodes: maxNodes,
                timeoutSeconds: timeoutSeconds, shape: style.shape, paddingPx: style.padding
              )
            : nil

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
                "targetApp": ["bundleId": target.app.bundleId, "name": target.app.name]
            ]
            let anchorOutcome = attachHighlightAnchor(
                request: anchorRequest, created: created, processId: Int64(target.pid),
                appId: target.app.bundleId, elementFrame: elementFrame, elementSpec: elementSpec,
                screens: screensAfterWalk
            )
            payload["anchorBehavior"] = anchorOutcome.behavior
            if let anchorPayload = anchorOutcome.payload {
                payload["anchor"] = anchorPayload
            }
            payload["matchedElement"] = jsonObject(match) ?? NSNull()
            // Merged rather than assigned field-by-field so the disclosure's
            // key names live in exactly one place -- the pure function a test
            // can pin. See `highlightSearchDisclosureFields` for why an
            // occurrence-driven success MUST say that uniqueness was skipped.
            for (key, value) in highlightSearchDisclosureFields(occurrence: MCPArgument.integer(args["occurrence"])) {
                payload[key] = value
            }
            guard let text = jsonString(payload) else {
                sendErrorResult(id: id, text: "Created the highlight but failed to encode its accessibility metadata.")
                return
            }
            sendTextResult(id: id, text: text)
        }
    }

    #if os(macOS)
    /// internal, not private: called from `handleCalibrateScreenshotSpaceElements`
    /// in MCPToolHandlers+ScreenshotSpace.swift, so that the element-anchored
    /// calibration route resolves `app` through THIS one helper rather than
    /// growing a second app-resolution path free to disagree with it.
    func resolveRunningHighlightTarget(_ args: [String: Any]) -> DrawOutcome<(app: AppRef, pid: HighlightProcessID)> {
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

        // The pid enumeration itself -- an `NSWorkspace.runningApplications`
        // filter behind the same main-thread hop every other NSWorkspace
        // query in this package takes -- lives in
        // `MCPServer.runningProcessIds(forAppId:)` (DrawRequest.swift), the
        // ONE place both this lookup and `anchor="window"`'s window-owning-
        // process lookup ask "is this app running, and with how many
        // processes". See that function's own doc comment for the
        // main-thread-hop rationale; `HighlightProcessID(exactly:)` narrows
        // its cross-platform `Int64` back to this platform's real `pid_t`.
        //
        // This does NOT close the gap between resolving the app above and
        // enumerating here, nor the one between this snapshot and the
        // Accessibility query that follows: the process can exit, or a second
        // instance can launch, in either window. The hop is a threading
        // correction, not a TOCTOU fix.
        let runningPIDs: [HighlightProcessID] = MCPServer.shared.runningProcessIds(forAppId: app.bundleId)
            .compactMap { HighlightProcessID(exactly: $0) }
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
    ///     matching rule), `MCPServer.runningProcessIds(forAppId:)`'s
    ///     Windows branch (DrawRequest.swift) must be updated to match --
    ///     see contractChanges/followUps.
    ///
    /// (b) PID RESOLUTION. In place of `NSWorkspace.runningApplications`'s
    ///     bundle-id filter, this calls `MCPServer.runningProcessIds
    ///     (forAppId:)` (DrawRequest.swift), whose Windows branch enumerates
    ///     every running process via `CreateToolhelp32Snapshot` and matches
    ///     executable names -- the ONE place that enumeration exists for
    ///     both this lookup and `anchor="window"`'s window-owning-process
    ///     lookup. Like the macOS branch, this does NOT close the gap
    ///     between resolving the app and enumerating processes, nor between
    ///     this snapshot and the UI Automation query that follows: the
    ///     process can exit, or a second instance can launch, in either
    ///     window.
    /// internal, not private: called from `handleCalibrateScreenshotSpaceElements`
    /// in MCPToolHandlers+ScreenshotSpace.swift, so that the element-anchored
    /// calibration route resolves `app` through THIS one helper rather than
    /// growing a second app-resolution path free to disagree with it.
    func resolveRunningHighlightTarget(_ args: [String: Any]) -> DrawOutcome<(app: AppRef, pid: HighlightProcessID)> {
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

        let matchingPIDs = MCPServer.shared.runningProcessIds(forAppId: app.bundleId)
            .compactMap { HighlightProcessID(exactly: $0) }
        guard matchingPIDs.count == 1, let target = matchingPIDs.first else {
            return matchingPIDs.isEmpty
                ? .failure("App '\(app.name)' [\(app.bundleId)] is no longer running, so its UI Automation tree cannot be queried.")
                : .failure("App '\(app.name)' [\(app.bundleId)] has \(matchingPIDs.count) running processes. highlight_element refuses to guess which process id to inspect.")
        }
        return .success((app, target))
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
        let shape: HighlightOutlineShape
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

    /// The finite/magnitude/positive-extent validation that used to live
    /// directly in this function now lives in
    /// `HighlightOutlineGeometry.pathData`
    /// (Sources/Support/HighlightOutlineGeometry.swift), moved verbatim so
    /// the element anchor tracker's on-settle re-resolve can reject the same
    /// unusable bounds the same way, through the same code, instead of a
    /// second copy of this guard drifting from this one. The error text
    /// below is unchanged: `pathData` returns nil under exactly the
    /// conditions this function used to fail on directly.
    private func makeHighlightKind(style: HighlightStyle, frame: AccessibilityBackingRect) -> DrawOutcome<AnnotationKind> {
        guard let data = HighlightOutlineGeometry.pathData(
            shape: style.shape,
            frameX: frame.x,
            frameY: frame.y,
            frameWidth: frame.width,
            frameHeight: frame.height,
            padding: style.padding
        ) else {
            return .failure("Resolved accessibility bounds are not usable for a highlight.")
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
