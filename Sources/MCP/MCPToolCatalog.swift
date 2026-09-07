import Foundation

/// Static MCP catalog. Drawing is built on three universal primitives --
/// arbitrary SVG paths, caller-rendered raster images, and first-class system
/// text -- plus draw_shape, a thin geometric convenience over the path
/// primitive for the one case (a circle/ellipse/rect specified by centre and
/// radius) common enough, and error-prone enough to hand-assemble as raw arc
/// commands, to be worth a dedicated tool. Anything more complex --
/// arrows, callouts, handwriting, grids -- still goes directly through
/// path_data; there is no canned tool for those.
enum MCPToolCatalog {
    // PLATFORM-ACCURATE TOOL PROSE. These strings are not documentation for a
    // human reader -- they are the catalog an AI agent reads to decide how to
    // CALL these tools, so naming the wrong platform's API is a correctness
    // problem rather than a wording nit. Telling a Windows caller to "ask macOS
    // to show its permission prompt" describes a prompt that cannot exist
    // there, and telling it to pass a "bundle id" names an identifier Windows
    // has no concept of. The underlying capability is the same on both
    // platforms; only the mechanism and its identifiers differ.
    #if os(macOS)
    /// macOS identifies applications by bundle identifier.
    static let appParamDescription = "Optional app to LINK this drawing to: bundle id or display name. It is visible only while that app is frontmost. If omitted, the previous non-Claude app is used. Pass an empty string for GLOBAL visibility."

    static let accessibilityStatusDescription = "Reports whether macOS Accessibility permission is available for element lookup. Set request_permission=true only to explicitly ask macOS to show its permission prompt; false/default never prompts."

    static let requestPermissionDescription = "Explicitly request the macOS Accessibility permission prompt when access is not granted; default false."

    static let captureBackendName = "ScreenCaptureKit"

    /// Distinct from `appParamDescription`: `highlight_element` must resolve
    /// the argument to a LIVE PROCESS to walk its element hierarchy, so unlike
    /// the drawing tools' visibility linkage there is no meaningful "global"
    /// value to accept.
    static let highlightAppParamDescription = "Running target app bundle id or display name. Omit for the normal fallback app; empty/global is invalid because a PID is required."

    /// The macOS ambiguity error renders a numbered per-candidate list with
    /// each candidate's role and resolved backing-pixel bounds (see
    /// AccessibilityElementResolver's `.ambiguous`). Windows UI Automation
    /// reports only a match COUNT at that layer, so this sentence is
    /// platform-split: promising a Windows caller a list that never arrives
    /// would leave it waiting for output that cannot exist and then guessing
    /// occurrence blind -- the exact failure the list exists to prevent.
    static let highlightAmbiguityDescription = "ambiguous labels are rejected with a numbered candidate list carrying each candidate's role and resolved on-screen bounds, so the right occurrence can be chosen by geometry instead of guessed"

    /// Platform-split for the same reason as `highlightAmbiguityDescription`.
    static let occurrenceAmbiguityDetail = "the ambiguity error numbers its candidates with the occurrence that selects each"

    static let captureRequestPermissionDescription = "For capture_source=chalkboard only: explicitly request Screen Recording permission if absent; default false."

    static let presentationCheckDescription = "Checks the retained overlay/view pair and WindowServer registration/on-screen state for one drawing, including bounded WindowServer-display-bounds alignment. presentationReady catches missing, hidden, detached, transparent, wrong-level/frame/display, or unregistered windows. It is drawable-state evidence, not raw framebuffer or occlusion proof."
    #elseif os(Windows)
    /// Windows has no bundle-identifier concept; `ActiveAppTracker` identifies
    /// an application by its executable name, matched case-insensitively.
    static let appParamDescription = "Optional app to LINK this drawing to: executable name (for example \"chrome.exe\", matched case-insensitively) or window/display name. It is visible only while that app is frontmost. If omitted, the previous non-Claude app is used. Pass an empty string for GLOBAL visibility."

    /// UI Automation needs no persistent grant to check ahead of time, so this
    /// reports reachability rather than a permission state, and
    /// `request_permission` has nothing to request. Said plainly so a caller
    /// does not wait for a prompt that will never appear.
    static let accessibilityStatusDescription = "Reports whether UI Automation is reachable for element lookup. Windows has no Accessibility permission to grant or prompt for, so this reports availability, not a permission state, and request_permission has no effect."

    static let requestPermissionDescription = "Accepted for cross-platform compatibility but has NO EFFECT on Windows: there is no Accessibility permission prompt to request."

    static let captureBackendName = "GDI BitBlt"

    /// See the macOS counterpart: `highlight_element` resolves this to a live
    /// process, so "global" is not a valid value here either.
    static let highlightAppParamDescription = "Running target app executable name (for example \"chrome.exe\", matched case-insensitively) or window/display name. Omit for the normal fallback app; empty/global is invalid because a PID is required."

    /// See the macOS counterpart: the Windows resolver's `.ambiguous` carries
    /// only a match COUNT (`chalk_uia_find_element` hands back no
    /// per-candidate preview), so this variant tells the caller the truth --
    /// iterate occurrence and verify -- instead of promising a list that
    /// never arrives.
    static let highlightAmbiguityDescription = "an ambiguous label is rejected with a match COUNT only -- Windows UI Automation reports no per-candidate preview -- so try occurrence from 1 upward and confirm each placement with verify_annotation"

    /// Platform-split for the same reason as `highlightAmbiguityDescription`.
    static let occurrenceAmbiguityDetail = "the ambiguity error reports a match count only (no per-candidate preview), so try occurrence from 1 upward"

    /// Windows has no capture-permission model to request: any process that
    /// can run code in this session can already capture the screen (see
    /// ScreenCaptureProvider's Windows permissionStatus() doc comment).
    static let captureRequestPermissionDescription = "For capture_source=chalkboard only: accepted for cross-platform compatibility but has NO EFFECT on Windows, which has no screen-capture permission to request; default false."

    /// Windows twin of the macOS description: there is no WindowServer here,
    /// only this process's own Win32 window state plus DWM's cloaking flag
    /// (see OverlayWindowController+Diagnostics.swift's Windows
    /// presentationStatus() note for the same "WEAKER THAN macOS" caveat).
    static let presentationCheckDescription = "Checks the retained overlay window's own Win32 state (IsWindow/IsWindowVisible/GetWindowRect/extended style) plus DWM's cloaking flag for one drawing, including bounded display-bounds alignment. presentationReady catches missing, hidden, detached, transparent, or wrong-level/frame/display windows. This is single-source evidence from this process's own window state, not a compositor-maintained record the way macOS's WindowServer check is, and it is not raw framebuffer or occlusion proof."
    #endif

    private static let sharedDrawProperties: [String: Any] = [
        "screen_id": ["type": "string", "maxLength": 128, "description": "Current screen ID/index from get_screens; omitted/blank defaults to main, while an unknown explicit value is rejected instead of falling back to another display."],
        "app": ["type": "string", "description": appParamDescription],
        "coordinate_space": ["type": "string", "enum": ["backing_pixels", "normalized", "screenshot_pixels"], "description": "Position/geometry space. When coordinates were measured from a screenshot, use screenshot_pixels with the exact dimensions of that same image version (after any model/client resize). It must be an uncropped full-display image; a detectable crop/window aspect mismatch is rejected because it has no safe display origin. A same-aspect crop is inherently indistinguishable from a downsampled full-display image, so callers remain responsible for full-display provenance. backing_pixels is the default, normalized is 0...1 of the selected display. NOTE for normalized specifically: unlike screenshot_pixels it carries no evidence of WHICH display it was measured against, so nothing can detect a mismatch on your behalf -- pass screen_id explicitly whenever you measured a display other than the main one. Style dimensions stay in backing pixels. In EVERY space, coordinates are relative to the SELECTED display's own top-left corner -- (0,0) is that display's top-left, never the virtual desktop -- so never add get_screens' appKitFrame/windowServerFrame desktop offsets to any coordinate."],
        "screenshot_width": ["type": "integer", "minimum": 1, "description": "Exact integer pixel width of the uncropped full-display image version used to measure coordinates when coordinate_space=screenshot_pixels; do not use its pre-resize/original width if the measured image was resized. Only valid with coordinate_space='screenshot_pixels': supplying it under any other coordinate_space is rejected rather than silently ignored."],
        "screenshot_height": ["type": "integer", "minimum": 1, "description": "Exact integer pixel height of the uncropped full-display image version used to measure coordinates when coordinate_space=screenshot_pixels; do not use its pre-resize/original height if the measured image was resized. Only valid with coordinate_space='screenshot_pixels': supplying it under any other coordinate_space is rejected rather than silently ignored."],
        "z_index": ["type": "integer", "description": "Paint order; higher values appear above lower values. Default 0; equal values retain creation order."],
        "anchor": ["type": "string", "enum": ["none", "window"], "description": "Anchors this drawing to one of app's windows so it follows that window as it moves and resizes, instead of staying at fixed display coordinates forever. \"window\" requires app to resolve to exactly one RUNNING process -- a global/untagged drawing (no app, or app='') has no window to anchor to and is rejected -- and picks whichever of that process's windows overlaps this drawing's own geometry the most (front-most breaks ties, including \"nothing overlaps\"). Default \"none\": today's fixed-coordinate behavior, completely unaffected. Tracking is SAMPLED, not event-driven, so the drawing trails the window by up to one sample interval while it is actively being dragged or resized, and lands exactly once the window settles. Check the response's anchor.state (and, later, list_annotations) to see whether the window is still being tracked. See anchor_resize for how the window's own resizing affects this drawing's geometry."],
        "anchor_resize": ["type": "string", "enum": ["pin", "scale"], "description": "Only meaningful together with anchor=\"window\" -- REJECTED when anchor is absent or \"none\", since there is no anchor window to react to. \"pin\" (default): follow only the window's top-left corner; this drawing keeps its own size while the window resizes. Choose pin for anything anchored to window CHROME -- a toolbar button, a tab, a sidebar item -- which is the common case, hence the default. \"scale\": scale this drawing's positions and geometry lengths (path coordinates, image width/height) per axis by the window's current-size/reference-size ratio. Choose scale only when the drawing's geometry was measured against CONTENT that itself scales with the window, such as a canvas, an image, or a video frame. Under BOTH policies, stroke width, font size, and padding stay fixed backing pixels -- only positions and geometry lengths scale."]
    ]

    private static let pathProperties: [String: Any] = [
        "path_data": ["type": "string", "maxLength": DrawingDefaults.maxSVGPathCharacters, "description": "SVG path data in the selected top-left-origin coordinate_space. Supports absolute/relative M L H V C S Q T A Z, implicit repeats, curves, arcs, and closed subpaths. The source values are stored with a scale-to-backing-pixels transform."],
        "stroke_color": ["type": "string", "description": "Stroke color name or hex. Defaults to orange when no fill-only intent is expressed."],
        "stroke_width": ["type": "number", "minimum": 0, "description": "Stroke width in backing pixels. Set 0 for fill-only art."],
        "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Stroke opacity; default 1."],
        "fill_color": ["type": "string", "description": "Optional fill color name or hex."],
        "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Fill opacity; default 1."],
        "fill_rule": ["type": "string", "enum": ["nonzero", "evenodd"], "description": "SVG fill rule; default nonzero."],
        "dash": ["type": "array", "maxItems": DrawingDefaults.maxDashElements, "items": ["type": "number", "exclusiveMinimum": 0], "description": "Optional repeating dash lengths in backing pixels."]
    ]

    private static let imageProperties: [String: Any] = [
        "image_path": ["type": "string", "description": "Absolute path to a PNG/JPEG/HEIC/TIFF raster. Alpha is preserved; pixels are decoded into memory once and the path is not retained."],
        "x": ["type": "number", "description": "Top-left X in the selected coordinate_space."],
        "y": ["type": "number", "description": "Top-left Y in the selected coordinate_space."],
        "width": ["type": "number", "exclusiveMinimum": 0, "description": "Optional output width in the selected coordinate_space. Omit one dimension and it is derived from the raster's true pixel aspect ratio in backing pixels, for every coordinate_space -- so a normalized width on a non-square display still yields an unstretched image, and the derived dimension may exceed the display. Omit both for intrinsic backing-pixel size."],
        "height": ["type": "number", "exclusiveMinimum": 0, "description": "Optional output height in the selected coordinate_space. Omitting it derives the height from width and the raster's true pixel aspect ratio; see width."],
        "rotation_degrees": ["type": "number", "description": "Clockwise rotation around image center; default 0."],
        "opacity": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Overall opacity; default 1. Fully transparent images are rejected because they cannot be shown or verified."]
    ]

    private static let textProperties: [String: Any] = [
        "text": ["type": "string", "minLength": 1, "maxLength": DrawingDefaults.maxTextCharacters, "description": "Text to draw; line breaks are supported. The combined text length, font_size, and padding_px must fit the renderer's conservative layout budget."],
        "x": ["type": "number", "description": "Top-left X in the selected coordinate space."],
        "y": ["type": "number", "description": "Top-left Y in the selected coordinate space."],
        "font_size": ["type": "number", "exclusiveMinimum": 0, "description": "System font size in backing pixels. Combined with text length and padding_px, it must fit the renderer's layout budget."],
        "color": ["type": "string", "description": "Text color name or hex; defaults to white."],
        "background_color": ["type": "string", "description": "Optional background color name or hex."],
        "background_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Background opacity; default 1."],
        "padding_px": ["type": "number", "minimum": 0, "description": "Padding around the text in backing pixels; default 0. Combined with text length and font_size, it must fit the renderer's layout budget."],
        "opacity": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Text opacity; default 1."]
    ]

    private static let shapeProperties: [String: Any] = [
        "shape": ["type": "string", "enum": ["circle", "ellipse", "rect"], "description": "Which shape to draw. circle requires center_x/center_y/radius; ellipse requires center_x/center_y/radius_x/radius_y; rect requires width/height plus EITHER x/y (top-left corner) OR center_x/center_y (centre) -- supplying both position forms, or neither, is rejected."],
        "center_x": ["type": "number", "description": "Centre X in the selected coordinate_space. Required for circle/ellipse; for rect it is an alternative to x/y (top-left corner) -- supply one position pair, not both."],
        "center_y": ["type": "number", "description": "Centre Y in the selected coordinate_space. Required for circle/ellipse; for rect it is an alternative to x/y (top-left corner) -- supply one position pair, not both."],
        "radius": ["type": "number", "exclusiveMinimum": 0, "description": "circle only: radius in the selected coordinate_space. Radius is scaled per axis, not as a point, so under coordinate_space='normalized' on a non-square display a single radius yields an ELLIPSE whose radius is that fraction of each axis; under backing_pixels/screenshot_pixels it stays a true circle."],
        "radius_x": ["type": "number", "exclusiveMinimum": 0, "description": "ellipse only: X radius in the selected coordinate_space."],
        "radius_y": ["type": "number", "exclusiveMinimum": 0, "description": "ellipse only: Y radius in the selected coordinate_space."],
        "width": ["type": "number", "exclusiveMinimum": 0, "description": "rect only: width in the selected coordinate_space."],
        "height": ["type": "number", "exclusiveMinimum": 0, "description": "rect only: height in the selected coordinate_space."],
        "x": ["type": "number", "description": "rect only: top-left X in the selected coordinate_space; alternative to center_x/center_y (supply one position pair, not both)."],
        "y": ["type": "number", "description": "rect only: top-left Y in the selected coordinate_space; alternative to center_x/center_y (supply one position pair, not both)."]
    ]

    /// `draw_shape` reuses `pathProperties` for its stroke/fill/opacity/dash/
    /// fill_rule styling -- every one of those arguments passes straight
    /// through to the same vector renderer draw_path uses. `path_data` itself
    /// is deliberately excluded: draw_shape always computes its own path from
    /// `shape`'s geometry, so advertising `path_data` as a usable parameter
    /// here would imply a caller-supplied path is honoured when it is in fact
    /// always overwritten.
    private static let pathStyleProperties: [String: Any] = {
        var properties = pathProperties
        properties.removeValue(forKey: "path_data")
        return properties
    }()

    private static func merged(_ dictionaries: [[String: Any]]) -> [String: Any] {
        dictionaries.reduce(into: [:]) { result, dictionary in
            for (key, value) in dictionary { result[key] = value }
        }
    }

    /// `draw_batch`'s per-item schema, where EVERY item type's properties
    /// share one flat object because JSON Schema cannot express "these fields
    /// depend on `type`" without a oneOf the MCP clients here do not reliably
    /// honour.
    ///
    /// WHY THIS EXISTS RATHER THAN A BARE `merged([...])`: `merged` is
    /// last-writer-wins, and four keys are claimed by more than one item type
    /// -- `x`/`y` by image, text, AND rect shapes; `width`/`height` by image
    /// AND rect shapes. A bare merge therefore silently published ONE type's
    /// wording as if it were the whole story. That is not cosmetic: adding
    /// `shapeProperties` to this merge made the batch schema describe `x` as
    /// "rect only", which tells a model that an `image` or `text` batch item
    /// must not pass `x` -- when both in fact REQUIRE it. A schema that
    /// misdescribes a required coordinate is precisely the kind of thing that
    /// puts a drawing in the wrong place, which is the bug class this tool
    /// exists to eliminate.
    ///
    /// So the shared keys are rewritten here, after the merge, with wording
    /// that names each item type that uses them. `MCPToolCatalogTests` pins
    /// that: if a future item type claims one of these keys, the test fails
    /// rather than letting the description quietly narrow again.
    /// The four per-item property dictionaries, paired with the `type` value
    /// each one belongs to, so the collision set below can be DERIVED rather
    /// than hand-listed. Hand-listing it was itself the bug: the first
    /// version of this guard enumerated x/y/width/height and silently missed
    /// `opacity`, which image and text both claim.
    private static let batchItemContributors: [(type: String, properties: [String: Any])] = [
        ("path", pathProperties), ("image", imageProperties),
        ("text", textProperties), ("shape", shapeProperties)
    ]

    /// Every key claimed by more than one item type, together with the types
    /// claiming it -- computed from the dictionaries themselves, so adding a
    /// property to any of them cannot quietly create an undescribed collision.
    /// `MCPToolCatalogTests` asserts each of these keys' published description
    /// names every type listed here, which fails the build for a new collision
    /// nobody wrote a union description for.
    static let batchItemSharedKeyContributors: [String: [String]] = {
        var claims: [String: [String]] = [:]
        for (type, properties) in batchItemContributors {
            for key in properties.keys { claims[key, default: []].append(type) }
        }
        return claims.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }()

    static var batchItemSharedKeys: [String] { batchItemSharedKeyContributors.keys.sorted() }

    /// `draw_batch` publishes ONE flat property object covering every item
    /// type, because JSON Schema cannot express "these fields depend on
    /// `type`" without a oneOf the MCP clients here do not reliably honour.
    ///
    /// WHY THIS EXISTS RATHER THAN A BARE `merged([...])`: `merged` is
    /// last-writer-wins, so for every key in `batchItemSharedKeyContributors`
    /// a bare merge publishes ONE type's wording as if it were the whole
    /// story. That is not cosmetic -- it is a schema that misdescribes a
    /// required field, which is exactly how a drawing ends up in the wrong
    /// place or omitted. Adding shape properties made `x` read "rect only",
    /// telling a model that an `image` or `text` item must not send `x` when
    /// both require it; `opacity` separately read "Text opacity" for image
    /// items, whose opacity has different semantics (a fully transparent
    /// image is rejected outright). Each shared key is therefore rewritten
    /// below with wording that names every type that uses it.
    static let batchItemProperties: [String: Any] = {
        var properties = merged(batchItemContributors.map(\.properties) + [
            ["type": ["type": "string", "enum": ["path", "image", "text", "shape"]]]
        ])
        properties["x"] = ["type": "number", "description": "image/text items: top-left X in the selected coordinate_space (required). shape items with shape='rect': top-left X, as the alternative to center_x/center_y -- supply one position pair, not both. Unused by path items, whose coordinates live inside path_data."]
        properties["y"] = ["type": "number", "description": "image/text items: top-left Y in the selected coordinate_space (required). shape items with shape='rect': top-left Y, as the alternative to center_x/center_y -- supply one position pair, not both. Unused by path items, whose coordinates live inside path_data."]
        properties["width"] = ["type": "number", "exclusiveMinimum": 0, "description": "image items: optional output width in the selected coordinate_space; omit one dimension and it is derived from the raster's true pixel aspect ratio in backing pixels, and omit both for intrinsic backing-pixel size. shape items with shape='rect': required width in the selected coordinate_space."]
        properties["height"] = ["type": "number", "exclusiveMinimum": 0, "description": "image items: optional output height in the selected coordinate_space; omitting it derives the height from width and the raster's true pixel aspect ratio. shape items with shape='rect': required height in the selected coordinate_space."]
        properties["opacity"] = ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Overall opacity of this item; default 1. image items: a fully transparent image is rejected outright, because it can neither be shown nor verified. text items: applies to the glyphs and compounds with background_opacity for the label's backing rectangle."]
        return properties
    }()

    /// The catalog is the one source of truth for the public argument
    /// surface.  Keep the runtime boundary derived from it too: maintaining a
    /// second hand-written allow-list next to these schemas is how a newly
    /// documented argument would eventually be rejected (or, worse, a removed
    /// argument silently accepted) by the server.
    static func validateArguments(toolName: String, args: [String: Any]) -> String? {
        guard let allowed = allowedArgumentKeys(for: toolName) else {
            // Preserve the normal dispatcher's more useful unknown-tool error.
            return nil
        }

        // This parameter was deliberately retired rather than ignored. Check
        // it before generic unknown-key validation so existing callers retain
        // the actionable migration error that says nothing was drawn.
        if toolsRejectingRetiredDuration.contains(toolName),
           let message = DrawRequest.rejectDurationSecondsIfSupplied(args: args) {
            return message
        }

        if let message = unknownArgumentMessage(
            unknownKeys: Set(args.keys).subtracting(allowed),
            context: toolName,
            allowedKeys: allowed
        ) {
            return message
        }

        guard toolName == "draw_batch",
              let items = args["items"] as? [[String: Any]] else {
            // The handler supplies the established type/size error for an
            // absent or malformed items value.
            return nil
        }
        for (index, item) in items.enumerated() {
            if let message = DrawRequest.rejectDurationSecondsIfSupplied(args: item) {
                return "items[\(index)]: \(message)"
            }
            guard let type = (item["type"] as? String)?.lowercased(),
                  let itemAllowed = batchItemAllowedKeysByType[type] else {
                // The handler retains responsibility for the established
                // missing/invalid type error.
                continue
            }
            if let message = unknownArgumentMessage(
                unknownKeys: Set(item.keys).subtracting(itemAllowed),
                context: "items[\(index)] (type '\(type)')",
                allowedKeys: itemAllowed
            ) {
                return message
            }
        }
        return nil
    }

    private static let toolsRejectingRetiredDuration: Set<String> = [
        "draw_path", "draw_shape", "draw_image", "draw_text", "draw_batch", "highlight_element"
    ]

    private static let batchItemAllowedKeysByType: [String: Set<String>] = [
        "path": Set(pathProperties.keys).union(["type"]),
        "image": Set(imageProperties.keys).union(["type"]),
        "text": Set(textProperties.keys).union(["type"]),
        "shape": Set(pathStyleProperties.keys).union(shapeProperties.keys).union(["type"])
    ]

    private static func allowedArgumentKeys(for toolName: String) -> Set<String>? {
        guard let tool = tools.first(where: { $0["name"] as? String == toolName }),
              let schema = tool["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            return nil
        }
        return Set(properties.keys)
    }

    private static func unknownArgumentMessage(unknownKeys: Set<String>,
                                               context: String,
                                               allowedKeys: Set<String>) -> String? {
        guard !unknownKeys.isEmpty else { return nil }
        let unknown = unknownKeys.sorted().map { "'\($0)'" }.joined(separator: ", ")
        guard !allowedKeys.isEmpty else {
            return "\(context) accepts no arguments; remove \(unknown)."
        }
        return "Unknown argument(s) for \(context): \(unknown). Allowed arguments: \(allowedKeys.sorted().joined(separator: ", "))."
    }

    static let tools: [[String: Any]] = {
        let definitions: [[String: Any]] = [
        [
            "name": "get_screens",
            "description": "Returns current display IDs and exact backing-pixel geometry. Call before drawing. If measuring from an uncropped full-display screenshot, use coordinate_space=screenshot_pixels with that exact measured image version's dimensions; do not copy resized-image coordinates into backing_pixels. Drawing coordinates are always relative to the selected display's OWN top-left corner; the returned appKitFrame/windowServerFrame describe only where a display sits on the desktop and must never be added to drawing coordinates.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "get_overlay_state",
            "description": "Reports Chalkboard's per-screen input policy and window state. A visible overlay is self-attested as click-through when ignoresMouseEvents is true, but an external click dispatcher must explicitly honor that state; this does not prove raw framebuffer pixels or occlusion.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "get_accessibility_status",
            "description": accessibilityStatusDescription,
            "inputSchema": ["type": "object", "properties": [
                "request_permission": ["type": "boolean", "description": requestPermissionDescription]
            ]]
        ],
        [
            "name": "draw_path",
            "description": "The vector free-draw primitive. Renders arbitrary SVG path geometry with independent stroke, fill, opacity, dash, and fill rule. Construct arrows, callouts, handwriting, diagrams, and arbitrary complex shapes through path_data. For a plain circle, ellipse, or rectangle, prefer draw_shape's center/radius parameters over hand-written arc commands -- every hand-written arc is a chance to mis-center it.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, pathProperties]),
                "required": ["path_data"]
            ]
        ],
        [
            "name": "draw_shape",
            "description": "Draws a circle, ellipse, or rectangle by centre and radius (or corner), instead of hand-assembling draw_path's raw SVG arc commands. Emits the identical closed-path vector geometry draw_path would, with the same stroke/fill/opacity/dash/fill_rule styling. See shape for the required fields per shape.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, pathStyleProperties, shapeProperties]),
                "required": ["shape"]
            ]
        ],
        [
            "name": "draw_image",
            "description": "The raster free-draw primitive. Places arbitrary caller-rendered artwork with alpha, scale, rotation, and opacity. Use this for custom text, brushes, gradients, textures, heatmaps, or anything more naturally produced as pixels.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, imageProperties]),
                "required": ["image_path", "x", "y"]
            ]
        ],
        [
            "name": "draw_text",
            "description": "Draws first-class system text at a top-left coordinate with optional background, padding, and opacity. No caller-rendered bitmap is required.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, textProperties]),
                "required": ["text", "x", "y", "font_size"]
            ]
        ],
        [
            "name": "highlight_element",
            "description": "Finds one running app's Accessibility element by label and draws a vector highlight around its live bounds -- rect (default), ellipse, or circle; see shape. This is the most accurate way to ring a UI element: the bounds come from the app itself, not from coordinates measured off a screenshot. Matching is exact by default; \(highlightAmbiguityDescription). By DEFAULT the highlight now tracks the element: see anchor.",
            "inputSchema": ["type": "object", "properties": [
                "label": ["type": "string", "minLength": 1, "maxLength": DrawingDefaults.maxHighlightLabelCharacters, "description": "Accessibility title, description, or value to match."],
                "app": ["type": "string", "description": highlightAppParamDescription],
                "role": ["type": "string", "description": "Optional raw Accessibility role, for example AXButton."],
                "match": ["type": "string", "enum": ["exact", "contains"], "description": "Label matching mode; exact is the default."],
                "occurrence": ["type": "integer", "minimum": 1, "description": "One-based match index in breadth-first discovery order (outermost elements first, NOT visual order), required when a label is ambiguous; \(occurrenceAmbiguityDetail). Supplying it short-circuits the walk at the Nth match and disables whole-tree ambiguity detection -- the result never proves the label was unique (the response says so via searchWasShortCircuited: true), so confirm placement with verify_annotation."],
                "max_nodes": ["type": "integer", "minimum": 1, "maximum": AccessibilityElementResolver.absoluteMaxNodes, "description": "Accessibility elements to visit before giving up; default \(AccessibilityElementResolver.defaultMaxNodes). The search is breadth-first and visits every element regardless of label/role, so this -- not a narrower query -- is what makes a large hierarchy reachable. Raise it together with timeout_seconds."],
                "timeout_seconds": ["type": "number", "minimum": AccessibilityElementResolver.minTraversalTimeoutSeconds, "maximum": AccessibilityElementResolver.maxTraversalTimeoutSeconds, "description": "Wall-clock budget for the whole traversal; default \(AccessibilityElementResolver.defaultTraversalTimeoutSeconds). A large app walks roughly 5,000 elements per second, so raising max_nodes without raising this just trades a node-cap error for a timeout."],
                "shape": ["type": "string", "enum": ["rect", "ellipse", "circle"], "description": "Highlight outline shape; default rect. ellipse is inscribed in the padded bounds (tangent to all four padded edges), so it traces a round or pill-shaped control's silhouette -- on a RECTANGULAR element it clips the corners, so use rect or circle when the whole element must be enclosed. circle FULLY ENCLOSES the element: it is concentric with it and its radius is half the element's diagonal plus padding_px, so no corner of the element sticks out of the ring."],
                "padding_px": ["type": "number", "minimum": 0, "description": "Outward rectangle padding in backing pixels; default 8. The stroke is centered on the outline, so ink extends stroke_width/2 INSIDE the traced path; keep padding_px at or above stroke_width/2 when the ink must not touch the element."],
                "anchor": ["type": "string", "enum": ["element", "window", "none"], "description": "How this highlight keeps up with the UI. \"element\" (DEFAULT): follow the element's window as it moves and resizes, AND re-run this same element lookup once the window settles, so the ring stays on the control even when the app REFLOWS its layout instead of scaling it -- this is the only mode that survives a reflow, and it is only as reliable as repeating this lookup (watch anchor.elementResolutionIssue). \"window\": follow the window's geometry only, never re-resolving the element; cheaper, but it drifts the moment the app reflows. \"none\": the pre-anchoring behavior -- resolve once at draw time and never move again; call highlight_element again yourself after the UI changes. Tracking is SAMPLED, not event-driven, so the ring trails the window slightly during an active drag and lands when it stops. If no window can be resolved for the element the highlight is still drawn, unanchored, and the response says so via anchor.reason -- the element itself resolved fine, so this never fails the call. Check anchor.state in list_annotations: \"hidden\" means the window is minimised, on another Space, or its app is hidden; \"lost\" means the window is gone. Neither deletes the annotation."],
                "anchor_resize": ["type": "string", "enum": ["pin", "scale"], "description": "Only meaningful with anchor=\"window\" -- REJECTED with anchor=\"element\" (which re-resolves the element's true bounds, so no resize policy applies) and with anchor=\"none\". See draw_path's anchor_resize for what pin and scale do."],
                "stroke_color": ["type": "string", "description": "Rectangle stroke color; color is accepted as an alias. Defaults to orange."],
                "color": ["type": "string", "description": "Alias for stroke_color; do not supply conflicting values."],
                "stroke_width": ["type": "number", "exclusiveMinimum": 0, "description": "Rectangle stroke width in backing pixels; default 4."],
                "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Stroke opacity; default 1."],
                "fill_color": ["type": "string", "description": "Optional rectangle fill color."],
                "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Fill opacity; default 0.15 when fill_color is supplied."],
                "z": ["type": "integer", "description": "Paint order; higher values appear above lower values. Alias for z_index."],
                "z_index": ["type": "integer", "description": "Paint order alias; do not supply a conflicting z value."]
            ], "required": ["label"]]
        ],
        [
            "name": "draw_batch",
            "description": "Atomically adds 1–100 mixed free-draw path/image/text/shape primitives under one annotation ID (maximum \(DrawingDefaults.maxRasterImagesPerBatch) raster items / \(DrawingDefaults.maxRasterDecodedBytesPerBatch / (1_024 * 1_024)) MiB decoded raster data). All items appear, verify, and clear together; if any item is invalid, nothing is added.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, [
                    "items": [
                        "type": "array", "minItems": 1, "maxItems": DrawingDefaults.maxBatchItems,
                        "items": [
                            "type": "object",
                            "properties": batchItemProperties,
                            "required": ["type"],
                            // The published flat schema admits the union of
                            // all item keys; validateArguments further
                            // narrows that union by each item's type before
                            // any raster decoding or annotation mutation.
                            "additionalProperties": false
                        ]
                    ]
                ]]),
                "required": ["items"]
            ]
        ],
        [
            "name": "update_annotation",
            "description": "Moves/restyles a live annotation without changing its ID. offset_x/offset_y are absolute backing-pixel offsets; supply at least one patch field. Text-only and path-only style fields are rejected for image/batch annotations rather than silently ignored. EVERY positional patch field is absolute BACKING PIXELS on the annotation's own display, regardless of the coordinate_space the original draw call used -- coordinates measured on a screenshot must be converted (multiply by the display's widthPx/screenshot_width) before patching, or the annotation teleports to the raw values.",
            "inputSchema": ["type": "object", "properties": merged([[
                "annotation_id": ["type": "string"],
                "offset_x": ["type": "number"], "offset_y": ["type": "number"],
                "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "z_index": ["type": "integer"],
                "anchor": ["type": "string", "enum": ["none", "window"], "description": "Changes what this annotation is anchored to. \"none\" DETACHES it and freezes it exactly where it is now -- it does not snap back to where it was originally drawn, and it stops following the window. \"window\" (re-)anchors it to whichever window of its own linked app it currently sits over, baselining from its present position so it does not jump; a global annotation with no app link is rejected, since there is no window to anchor to. Omit this to leave the existing anchor untouched."],
                "anchor_resize": ["type": "string", "enum": ["pin", "scale"], "description": "Changes the resize policy of an anchored annotation, re-baselining the reference frame to the window's current size so the drawing does not jump. REJECTED on an unanchored annotation, and with anchor=\"none\". See draw_path's anchor_resize for what pin and scale do."],
                "text": ["type": "string"],
                "x": ["type": "number", "description": "Text annotations only: new top-left X in absolute backing pixels on the annotation's own display -- NOT in the coordinate_space the original draw call used."],
                "y": ["type": "number", "description": "Text annotations only: new top-left Y in absolute backing pixels on the annotation's own display -- NOT in the coordinate_space the original draw call used."],
                "font_size": ["type": "number", "exclusiveMinimum": 0], "color": ["type": "string"],
                "background_color": ["type": "string"], "background_opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "padding_px": ["type": "number", "minimum": 0],
                "stroke_color": ["type": "string"], "stroke_width": ["type": "number", "minimum": 0],
                "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "fill_color": ["type": "string"], "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1]
            ]]), "required": ["annotation_id"]]
        ],
        [
            "name": "suspend_annotations",
            "description": "Acquires a short-lived suspension lease, ordering AI Chalkboard overlays out without clearing annotations or IDs. lease_seconds is 1...60 (default 15). Save the returned secret leaseToken and pass exactly it to resume_annotations. An optional fresh lowercase canonical UUID idempotency_key makes a retry from the same MCP server process instance return the same active lease. It is secret; reuse from another instance is rejected without revealing another lease token. clickSafeAtObservation is true only for the current live generation after bounded peer presentation settlement. This is a temporary click workaround, not true simultaneous highlight-and-click.",
            "inputSchema": ["type": "object", "properties": [
                "lease_seconds": ["type": "integer", "minimum": 1, "maximum": 60, "description": "Lease lifetime in seconds; default 15. It expires automatically if not released."],
                "idempotency_key": ["type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", "description": "Optional fresh lowercase canonical UUID capability, scoped to its creator MCP server process instance while active. Retry only from that instance; reuse elsewhere errors without returning a token. Do not log or reuse it across callers." ]
            ], "additionalProperties": false]
        ],
        [
            "name": "resume_annotations",
            "description": "Releases exactly one secret suspension lease token returned by suspend_annotations. If another lease remains, success requires bounded confirmation that the current generation's peer presentation settled off screen; otherwise the token is released but the tool result is an error. If no lease remains, the response is only a linearized registry snapshot plus a restoration request, not proof of global window convergence. Releasing an already-released or expired token succeeds only during the 120-second cleanup tombstone; an unknown/old token is an error.",
            "inputSchema": ["type": "object", "properties": [
                "lease_token": ["type": "string", "minLength": 43, "maxLength": 43, "pattern": "^[A-Za-z0-9_-]{43}$", "description": "The exact secret leaseToken returned by suspend_annotations. Do not log it." ]
            ], "required": ["lease_token"], "additionalProperties": false]
        ],
        [
            "name": "clear",
            "description": "Clears by exact annotation_id, explicit app, fallback active app, or scope='all'. Prefer annotation_id for exact undo.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "scope": ["type": "string", "enum": ["active", "all"]],
                "app": ["type": "string", "description": "Explicit app target for active scope; empty string means globals only."]
            ]]
        ],
        [
            "name": "list_annotations",
            "description": "Lists a bounded page of live drawings with IDs, geometry (or an explicit oversized-geometry summary), app linkage, and visibility. Use nextOffset to page.",
            "inputSchema": ["type": "object", "properties": [
                "offset": ["type": "integer", "minimum": 0, "description": "Zero-based page offset; default 0."],
                "limit": ["type": "integer", "minimum": 1, "maximum": DrawingDefaults.maxAnnotationListPageItems, "description": "Maximum entries to return; default and maximum \(DrawingDefaults.maxAnnotationListPageItems)."]
            ]]
        ],
        [
            "name": "verify_annotation",
            "description": "Uses the exact live renderer to composite one drawing into either a supplied clean screenshot or a Chalkboard-owned \(captureBackendName) image, returning a tight PNG crop. The metadata's paintedBoundsScreenshotPx is the painted annotation's top-left-origin bounds in the FULL screenshot's pixels -- compare it against where the target element sits in that same screenshot to measure placement error, then correct with update_annotation in backing pixels. The returned image is a CROP: never reuse the crop's own dimensions as screenshot_width/height on a later draw call; only full-display image dimensions are valid there. Chalkboard capture is single-flight and times out after 30 seconds. screenshot_path and capture_source are mutually exclusive. This verifies placement against UI pixels, not raw framebuffer presentation or occlusion.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "screenshot_path": ["type": "string", "description": "Absolute path to a clean uncropped full-display raster screenshot."],
                "screenshot_screen_id": ["type": "string", "description": "Display the screenshot_path image was captured from; required when the image could plausibly be a full-display capture (native or downsampled -- never upscaled) of MORE THAN ONE connected display. Must match the annotation's own display. Supplying it with capture_source is rejected rather than silently ignored, because Chalkboard capture always photographs the annotation's own display."],
                "capture_source": ["type": "string", "enum": ["chalkboard"], "description": "Use Chalkboard's in-memory \(captureBackendName) capture. Required when screenshot_path is omitted."],
                "request_permission": ["type": "boolean", "description": captureRequestPermissionDescription],
                "padding_px": ["type": "number", "minimum": 0, "maximum": AnnotationVerificationCompositor.maxPaddingPx]
            ], "required": ["annotation_id"]]
        ],
        [
            "name": "verify_presentation",
            "description": presentationCheckDescription,
            "inputSchema": ["type": "object", "properties": ["annotation_id": ["type": "string"]], "required": ["annotation_id"]]
        ],
        [
            "name": "get_annotation_bounds",
            "description": "Reports WHERE a drawing is painted, without capturing anything. Use this when your own screenshot tool does not show the overlay: it needs no screen capture, no Screen Recording permission, and never requires the annotation to appear in anybody's image. Bounds come from the exact live renderer (real glyph metrics, rotation, offsets, and any live window anchor included), reported in the annotation's current display's backing pixels and -- when you pass screenshot_width/screenshot_height -- in that screenshot's own pixels. Pass target_bounds_screenshot_px with the rect you measured for the UI element you meant to annotate and the result also returns the centre-to-centre gap plus correctionBackingPx, the ABSOLUTE offset_x/offset_y to hand straight to update_annotation; that conversion already accounts for the screenshot scale and for an anchor's own scaling, which is the step to get wrong by hand. This is renderer geometry, NOT proof that any pixel reached a framebuffer or any capture: verify_presentation remains the window-state check and verify_annotation the composited-image check.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "screenshot_width": ["type": "integer", "minimum": 1, "description": "Exact pixel width of the uncropped full-display screenshot you want bounds expressed in. Must be supplied together with screenshot_height; a detectable aspect-ratio mismatch against the display is rejected rather than silently stretched, exactly as for screenshot_pixels drawing coordinates."],
                "screenshot_height": ["type": "integer", "minimum": 1, "description": "Exact pixel height of that same screenshot. Must be supplied together with screenshot_width."],
                "target_bounds_screenshot_px": ["type": "object", "description": "Optional: the bounds of the UI element you actually wanted annotated, in the SAME screenshot pixels as screenshot_width/screenshot_height (which are then required). Returns the placement gap and the absolute offset_x/offset_y correction to apply with update_annotation.", "properties": [
                    "x": ["type": "number"], "y": ["type": "number"],
                    "width": ["type": "number", "minimum": 0], "height": ["type": "number", "minimum": 0]
                ], "required": ["x", "y", "width", "height"]]
            ], "required": ["annotation_id"]]
        ],
        [
            "name": "get_active_app",
            "description": "Reports the frontmost app, the fallback app an untagged draw call would link to, and this process's annotationsSuspended presentation state.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "set_capture_visible",
            "description": "Applies legacy capture eligibility/exclusion and per-app debug filtering locally before responding, then broadcasts the request to sibling instances. External capture programs retain independent filters; this flag auto-reverts after five minutes. Setting it false restores per-app filtering but does not by itself re-apply capture exclusion: on a session detected as remote or streamed the exclusion stays off. The response, get_screens, and get_overlay_state all report the resulting captureExclusion decision.",
            "inputSchema": ["type": "object", "properties": ["visible": ["type": "boolean"]], "required": ["visible"]]
        ]
        ]
        return definitions.map { tool in
            var strictTool = tool
            var schema = strictTool["inputSchema"] as? [String: Any] ?? [:]
            schema["additionalProperties"] = false
            strictTool["inputSchema"] = schema
            return strictTool
        }
    }()
}
