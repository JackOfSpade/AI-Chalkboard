import Foundation

/// Static MCP catalog. Drawing uses three universal primitives: arbitrary SVG
/// paths, caller-rendered raster images, and first-class system text. There
/// are no canned circles/arrows/boxes/grids; agents construct those (and
/// anything more complex) from the same free-draw surface.
enum MCPToolCatalog {
    static let appParamDescription = "Optional app to LINK this drawing to: bundle id or display name. It is visible only while that app is frontmost. If omitted, the previous non-Claude app is used. Pass an empty string for GLOBAL visibility."

    private static let sharedDrawProperties: [String: Any] = [
        "screen_id": ["type": "string", "description": "Screen ID/index from get_screens; defaults to main."],
        "app": ["type": "string", "description": appParamDescription],
        "duration_seconds": ["type": "number", "exclusiveMinimum": 0, "maximum": DrawingDefaults.maxAnnotationDurationSeconds, "description": "Optional lifetime up to \(Int(DrawingDefaults.maxAnnotationDurationSeconds)) seconds; omit to persist until clear/eviction."],
        "coordinate_space": ["type": "string", "enum": ["backing_pixels", "normalized", "screenshot_pixels"], "description": "Position/geometry space; backing_pixels is the default, normalized is 0...1 of the selected display, and screenshot_pixels requires screenshot_width and screenshot_height. Style dimensions stay in backing pixels."],
        "screenshot_width": ["type": "number", "exclusiveMinimum": 0, "description": "Source full-display screenshot width when coordinate_space=screenshot_pixels."],
        "screenshot_height": ["type": "number", "exclusiveMinimum": 0, "description": "Source full-display screenshot height when coordinate_space=screenshot_pixels."],
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
        "width": ["type": "number", "exclusiveMinimum": 0, "description": "Optional output width in the selected coordinate_space. Omit one dimension to preserve aspect ratio; omit both for intrinsic backing-pixel size."],
        "height": ["type": "number", "exclusiveMinimum": 0, "description": "Optional output height in the selected coordinate_space."],
        "rotation_degrees": ["type": "number", "description": "Clockwise rotation around image center; default 0."],
        "opacity": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Overall opacity; default 1. Fully transparent images are rejected because they cannot be shown or verified."]
    ]

    private static let textProperties: [String: Any] = [
        "text": ["type": "string", "minLength": 1, "description": "Text to draw; line breaks are supported."],
        "x": ["type": "number", "description": "Top-left X in the selected coordinate space."],
        "y": ["type": "number", "description": "Top-left Y in the selected coordinate space."],
        "font_size": ["type": "number", "exclusiveMinimum": 0, "description": "System font size in backing pixels."],
        "color": ["type": "string", "description": "Text color name or hex; defaults to white."],
        "background_color": ["type": "string", "description": "Optional background color name or hex."],
        "background_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Background opacity; default 1."],
        "padding_px": ["type": "number", "minimum": 0, "description": "Padding around the text in backing pixels; default 0."],
        "opacity": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Text opacity; default 1."]
    ]

    private static func merged(_ dictionaries: [[String: Any]]) -> [String: Any] {
        dictionaries.reduce(into: [:]) { result, dictionary in
            for (key, value) in dictionary { result[key] = value }
        }
    }

    static let tools: [[String: Any]] = [
        [
            "name": "get_screens",
            "description": "Returns displays in the exact backing-pixel coordinate space used by free-draw, plus backing scale and capture-debug state. A screenshot may be independently downsampled; compare its dimensions with widthPx/heightPx.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "get_overlay_state",
            "description": "Reports Chalkboard's per-screen input policy and window state. A visible overlay is self-attested as click-through when ignoresMouseEvents is true, but an external click dispatcher must explicitly honor that state; this does not prove raw framebuffer pixels or occlusion.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "get_accessibility_status",
            "description": "Reports whether macOS Accessibility permission is available for element lookup. Set request_permission=true only to explicitly ask macOS to show its permission prompt; false/default never prompts.",
            "inputSchema": ["type": "object", "properties": [
                "request_permission": ["type": "boolean", "description": "Explicitly request the macOS Accessibility permission prompt when access is not granted; default false."]
            ]]
        ],
        [
            "name": "draw_path",
            "description": "The vector free-draw primitive. Renders arbitrary SVG path geometry with independent stroke, fill, opacity, dash, and fill rule. Construct circles, arrows, boxes, callouts, handwriting, diagrams, and complex shapes through path_data; no canned shape tools exist.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, pathProperties]),
                "required": ["path_data"]
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
            "description": "Finds one running app's Accessibility element by label and draws a rectangular vector highlight around its live bounds. Matching is exact by default; ambiguous labels are rejected unless occurrence is supplied. The resolved frame is anchored at creation time, not continuously tracked as the UI moves.",
            "inputSchema": ["type": "object", "properties": [
                "label": ["type": "string", "minLength": 1, "description": "Accessibility title, description, or value to match."],
                "app": ["type": "string", "description": "Running target app bundle id or display name. Omit for the normal fallback app; empty/global is invalid because a PID is required."],
                "role": ["type": "string", "description": "Optional raw Accessibility role, for example AXButton."],
                "match": ["type": "string", "enum": ["exact", "contains"], "description": "Label matching mode; exact is the default."],
                "occurrence": ["type": "integer", "minimum": 1, "description": "One-based candidate index, required when a label is ambiguous."],
                "padding_px": ["type": "number", "minimum": 0, "description": "Outward rectangle padding in backing pixels; default 8."],
                "stroke_color": ["type": "string", "description": "Rectangle stroke color; color is accepted as an alias. Defaults to orange."],
                "color": ["type": "string", "description": "Alias for stroke_color; do not supply conflicting values."],
                "stroke_width": ["type": "number", "exclusiveMinimum": 0, "description": "Rectangle stroke width in backing pixels; default 4."],
                "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Stroke opacity; default 1."],
                "fill_color": ["type": "string", "description": "Optional rectangle fill color."],
                "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Fill opacity; default 0.15 when fill_color is supplied."],
                "duration_seconds": ["type": "number", "exclusiveMinimum": 0, "maximum": DrawingDefaults.maxAnnotationDurationSeconds],
                "z": ["type": "integer", "description": "Paint order; higher values appear above lower values. Alias for z_index."],
                "z_index": ["type": "integer", "description": "Paint order alias; do not supply a conflicting z value."]
            ], "required": ["label"]]
        ],
        [
            "name": "draw_batch",
            "description": "Atomically adds 1–100 mixed free-draw path/image/text primitives under one annotation ID (maximum \(DrawingDefaults.maxRasterImagesPerBatch) raster items / \(DrawingDefaults.maxRasterDecodedBytesPerBatch / (1_024 * 1_024)) MiB decoded raster data). All items appear, verify, expire, and clear together; if any item is invalid, nothing is added.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, [
                    "items": [
                        "type": "array", "minItems": 1, "maxItems": DrawingDefaults.maxBatchItems,
                        "items": [
                            "type": "object",
                            "properties": merged([pathProperties, imageProperties, textProperties, ["type": ["type": "string", "enum": ["path", "image", "text"]]]]),
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
            "description": "Acquires a short-lived suspension lease, ordering AI Chalkboard overlays out without clearing annotations, IDs, or running TTLs. lease_seconds is 1...60 (default 15). Save the returned secret leaseToken and pass exactly it to resume_annotations. An optional fresh lowercase canonical UUID idempotency_key makes a retry from the same MCP server process instance return the same active lease. It is secret; reuse from another instance is rejected without revealing another lease token. clickSafeAtObservation is true only for the current live generation after bounded peer presentation settlement. This is a temporary click workaround, not true simultaneous highlight-and-click.",
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
            "description": "Lists a bounded page of live drawings with IDs, geometry (or an explicit oversized-geometry summary), app linkage, visibility, expiresAt, and remainingSeconds. Use nextOffset to page.",
            "inputSchema": ["type": "object", "properties": [
                "offset": ["type": "integer", "minimum": 0, "description": "Zero-based page offset; default 0."],
                "limit": ["type": "integer", "minimum": 1, "maximum": DrawingDefaults.maxAnnotationListPageItems, "description": "Maximum entries to return; default and maximum \(DrawingDefaults.maxAnnotationListPageItems)."]
            ]]
        ],
        [
            "name": "verify_annotation",
            "description": "Uses the exact live renderer to composite one drawing into either a supplied clean screenshot or a Chalkboard-owned ScreenCaptureKit image, returning a tight PNG crop. Chalkboard capture is single-flight and times out after 30 seconds. screenshot_path and capture_source are mutually exclusive. This verifies placement against UI pixels, not raw framebuffer presentation or occlusion.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "screenshot_path": ["type": "string", "description": "Absolute path to a clean uncropped full-display raster screenshot."],
                "capture_source": ["type": "string", "enum": ["chalkboard"], "description": "Use Chalkboard's in-memory ScreenCaptureKit capture. Required when screenshot_path is omitted."],
                "request_permission": ["type": "boolean", "description": "For capture_source=chalkboard only: explicitly request Screen Recording permission if absent; default false."],
                "padding_px": ["type": "number", "minimum": 0, "maximum": AnnotationVerificationCompositor.maxPaddingPx]
            ], "required": ["annotation_id"]]
        ],
        [
            "name": "verify_presentation",
            "description": "Checks the retained overlay/view pair and WindowServer registration/on-screen state for one drawing, including bounded WindowServer-display-bounds alignment. presentationReady catches missing, hidden, detached, transparent, wrong-level/frame/display, or unregistered windows. It is drawable-state evidence, not raw framebuffer or occlusion proof.",
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
