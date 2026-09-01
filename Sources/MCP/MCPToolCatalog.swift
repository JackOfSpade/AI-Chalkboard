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
        "coordinate_space": ["type": "string", "enum": ["backing_pixels", "normalized", "screenshot_pixels"], "description": "Position/geometry space. When coordinates were measured from a screenshot, use screenshot_pixels with the exact dimensions of that same image version (after any model/client resize). It must be an uncropped full-display image; a detectable crop/window aspect mismatch is rejected because it has no safe display origin. A same-aspect crop is inherently indistinguishable from a downsampled full-display image, so callers remain responsible for full-display provenance. backing_pixels is the default, normalized is 0...1 of the selected display. NOTE for normalized specifically: unlike screenshot_pixels it carries no evidence of WHICH display it was measured against, so nothing can detect a mismatch on your behalf -- pass screen_id explicitly whenever you measured a display other than the main one. Style dimensions stay in backing pixels."],
        "screenshot_width": ["type": "integer", "minimum": 1, "description": "Exact integer pixel width of the uncropped full-display image version used to measure coordinates when coordinate_space=screenshot_pixels; do not use its pre-resize/original width if the measured image was resized."],
        "screenshot_height": ["type": "integer", "minimum": 1, "description": "Exact integer pixel height of the uncropped full-display image version used to measure coordinates when coordinate_space=screenshot_pixels; do not use its pre-resize/original height if the measured image was resized."],
        "z_index": ["type": "integer", "description": "Paint order; higher values appear above lower values. Default 0; equal values retain creation order."]
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
        "text": ["type": "string", "minLength": 1, "maxLength": DrawingDefaults.maxTextCharacters, "description": "Text to draw; line breaks are supported."],
        "x": ["type": "number", "description": "Top-left X in the selected coordinate space."],
        "y": ["type": "number", "description": "Top-left Y in the selected coordinate space."],
        "font_size": ["type": "number", "exclusiveMinimum": 0, "description": "System font size in backing pixels."],
        "color": ["type": "string", "description": "Text color name or hex; defaults to white."],
        "background_color": ["type": "string", "description": "Optional background color name or hex."],
        "background_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Background opacity; default 1."],
        "padding_px": ["type": "number", "minimum": 0, "description": "Padding around the text in backing pixels; default 0."],
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

    static let tools: [[String: Any]] = [
        [
            "name": "get_screens",
            "description": "Returns current display IDs and exact backing-pixel geometry. Call before drawing. If measuring from an uncropped full-display screenshot, use coordinate_space=screenshot_pixels with that exact measured image version's dimensions; do not copy resized-image coordinates into backing_pixels.",
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
            "description": "Finds one running app's Accessibility element by label and draws a vector highlight around its live bounds -- rect (default), ellipse, or circle; see shape. Matching is exact by default; ambiguous labels are rejected unless occurrence is supplied. The resolved frame is anchored at creation time, not continuously tracked as the UI moves.",
            "inputSchema": ["type": "object", "properties": [
                "label": ["type": "string", "minLength": 1, "maxLength": DrawingDefaults.maxHighlightLabelCharacters, "description": "Accessibility title, description, or value to match."],
                "app": ["type": "string", "description": highlightAppParamDescription],
                "role": ["type": "string", "description": "Optional raw Accessibility role, for example AXButton."],
                "match": ["type": "string", "enum": ["exact", "contains"], "description": "Label matching mode; exact is the default."],
                "occurrence": ["type": "integer", "minimum": 1, "description": "One-based candidate index, required when a label is ambiguous."],
                "max_nodes": ["type": "integer", "minimum": 1, "maximum": AccessibilityElementResolver.absoluteMaxNodes, "description": "Accessibility elements to visit before giving up; default \(AccessibilityElementResolver.defaultMaxNodes). The search is breadth-first and visits every element regardless of label/role, so this -- not a narrower query -- is what makes a large hierarchy reachable. Raise it together with timeout_seconds."],
                "timeout_seconds": ["type": "number", "minimum": AccessibilityElementResolver.minTraversalTimeoutSeconds, "maximum": AccessibilityElementResolver.maxTraversalTimeoutSeconds, "description": "Wall-clock budget for the whole traversal; default \(AccessibilityElementResolver.defaultTraversalTimeoutSeconds). A large app walks roughly 5,000 elements per second, so raising max_nodes without raising this just trades a node-cap error for a timeout."],
                "shape": ["type": "string", "enum": ["rect", "ellipse", "circle"], "description": "Highlight outline shape; default rect. ellipse is inscribed in the padded bounds (tangent to all four padded edges). circle is concentric with the padded bounds but sized to CIRCUMSCRIBE them (radius = max(width,height)/2) rather than inscribe them, so it rings a wide element -- most buttons and icons are wider than tall -- without clipping its ends."],
                "padding_px": ["type": "number", "minimum": 0, "description": "Outward rectangle padding in backing pixels; default 8."],
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
                            "required": ["type"]
                        ]
                    ]
                ]]),
                "required": ["items"]
            ]
        ],
        [
            "name": "update_annotation",
            "description": "Moves/restyles a live annotation without changing its ID. offset_x/offset_y are absolute backing-pixel offsets; supply at least one patch field. Text-only and path-only style fields are rejected for image/batch annotations rather than silently ignored.",
            "inputSchema": ["type": "object", "properties": merged([[
                "annotation_id": ["type": "string"],
                "offset_x": ["type": "number"], "offset_y": ["type": "number"],
                "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "z_index": ["type": "integer"],
                "text": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"],
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
            "description": "Uses the exact live renderer to composite one drawing into either a supplied clean screenshot or a Chalkboard-owned \(captureBackendName) image, returning a tight PNG crop. Chalkboard capture is single-flight and times out after 30 seconds. screenshot_path and capture_source are mutually exclusive. This verifies placement against UI pixels, not raw framebuffer presentation or occlusion.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "screenshot_path": ["type": "string", "description": "Absolute path to a clean uncropped full-display raster screenshot."],
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
            "name": "get_active_app",
            "description": "Reports the frontmost app, the fallback app an untagged draw call would link to, and this process's annotationsSuspended presentation state.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "set_capture_visible",
            "description": "Applies legacy capture eligibility/exclusion and per-app debug filtering locally before responding, then broadcasts the request to sibling instances. External capture programs retain independent filters; this flag auto-reverts after five minutes.",
            "inputSchema": ["type": "object", "properties": ["visible": ["type": "boolean"]], "required": ["visible"]]
        ]
    ]
}
