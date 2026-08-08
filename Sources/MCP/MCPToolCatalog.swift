import Foundation

/// The static `tools/list` payload: name, description, and JSON Schema for
/// every MCP tool this server exposes.
///
/// Numeric defaults mentioned in these description strings are interpolated
/// from `DrawingDefaults` rather than hand-typed a second time, so the docs
/// Claude reads can never drift from the code that actually applies them
/// (see `DrawingDefaults`'s own doc comment for the history of that drift).
/// Where a literal's hand-written text ("200", "3.5") would not round-trip
/// through naive `Double` interpolation (`\(200.0)` prints "200.0", not
/// "200"), the interpolation is written to reproduce the exact original
/// text -- verified via the golden wire-output diff, not just by eye.
enum MCPToolCatalog {
    /// Shared wording for the optional `app` parameter, so every draw tool
    /// describes per-app linking identically.
    static let appParamDescription = "Optional app to LINK this annotation to: a bundle id ('com.apple.Terminal') or a display name ('DaVinci Resolve'). The annotation is then drawn ONLY while that app is frontmost, and hidden whenever the user switches away. If omitted, it links to the app the user was in before switching to Claude (see get_active_app's 'fallback'), which is almost always the app they are asking about. Pass an empty string to make the annotation GLOBAL (visible over every app)."

    static let tools: [[String: Any]] = [
        [
            "name": "get_screens",
            "description": "Returns all connected macOS displays, physical pixel resolutions, backing scale factors, and point dimensions, plus the current capture_visible request state. backingScaleFactor follows the active macOS display mode: a Retina panel can legitimately report 1 when configured at native unscaled resolution, and 2 in a HiDPI scaled mode. capture_visible controls AI Chalkboard's renderer and legacy NSWindow sharing preference; the program taking a screenshot may still independently include or exclude overlay windows. Use this first to pick screen_id and determine coordinate bounds.",
            "inputSchema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "draw_circle",
            "description": "Draws a transparent highlighted circle on the overlay. Coordinates (x, y, radius) can be physical pixels (default) or normalized 0.0-1.0 (if is_normalized=true). Annotations are LINKED TO AN APP and are only visible while that app is frontmost -- see the 'app' parameter.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "screen_id": ["type": "string", "description": "Screen ID or index ('0', '1', or display ID from get_screens). Defaults to main screen."],
                    "x": ["type": "number", "description": "Center X coordinate (physical pixels or normalized 0.0-1.0)."],
                    "y": ["type": "number", "description": "Center Y coordinate (physical pixels or normalized 0.0-1.0)."],
                    "radius": ["type": "number", "exclusiveMinimum": 0, "description": "Radius in physical pixels. Must be greater than 0."],
                    "color": ["type": "string", "description": "Hex color e.g. '\(DrawingDefaults.circleColor)' or name 'red','green','blue','yellow','orange','purple','pink','white'."],
                    "label": ["type": "string", "description": "Optional label text attached to circle badge."],
                    "app": ["type": "string", "description": Self.appParamDescription],
                    "is_normalized": ["type": "boolean", "description": "Set to true if x and y are normalized 0.0-1.0 ratios."],
                    "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                ],
                "required": ["x", "y", "radius"]
            ]
        ],
        [
            "name": "draw_arrow",
            "description": "Draws a line with an arrowhead from (x1, y1) to (x2, y2). Supports physical pixels or normalized 0.0-1.0 coordinates. Annotations are LINKED TO AN APP and are only visible while that app is frontmost -- see the 'app' parameter.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                    "x1": ["type": "number", "description": "Start X coordinate."],
                    "y1": ["type": "number", "description": "Start Y coordinate."],
                    "x2": ["type": "number", "description": "End X (arrowhead tip) coordinate."],
                    "y2": ["type": "number", "description": "End Y (arrowhead tip) coordinate."],
                    "color": ["type": "string", "description": "Hex color or name."],
                    "label": ["type": "string", "description": "Optional label text along arrow."],
                    "app": ["type": "string", "description": Self.appParamDescription],
                    "is_normalized": ["type": "boolean", "description": "Set to true if x1, y1, x2, y2 are normalized 0.0-1.0 ratios."],
                    "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                ],
                "required": ["x1", "y1", "x2", "y2"]
            ]
        ],
        [
            "name": "draw_box",
            "description": "Draws a rectangle on the overlay. Coordinates (x, y, width, height) support physical pixels or normalized 0.0-1.0. Annotations are LINKED TO AN APP and are only visible while that app is frontmost -- see the 'app' parameter.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                    "x": ["type": "number", "description": "Top-left X coordinate."],
                    "y": ["type": "number", "description": "Top-left Y coordinate."],
                    "width": ["type": "number", "exclusiveMinimum": 0, "description": "Width in physical pixels, extending RIGHT from x. Must be greater than 0 -- pass the smaller corner as (x, y) rather than a negative width."],
                    "height": ["type": "number", "exclusiveMinimum": 0, "description": "Height in physical pixels, extending DOWN from y. Must be greater than 0 -- pass the smaller corner as (x, y) rather than a negative height."],
                    "color": ["type": "string", "description": "Hex color or name."],
                    "label": ["type": "string", "description": "Optional label text attached to box."],
                    "app": ["type": "string", "description": Self.appParamDescription],
                    "is_normalized": ["type": "boolean", "description": "Set to true if x, y, width, height are normalized 0.0-1.0 ratios."],
                    "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                ],
                "required": ["x", "y", "width", "height"]
            ]
        ],
        [
            "name": "draw_label",
            "description": "Draws a floating label badge at (x, y). Supports physical pixels or normalized 0.0-1.0 coordinates. Annotations are LINKED TO AN APP and are only visible while that app is frontmost -- see the 'app' parameter.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                    "x": ["type": "number", "description": "X coordinate."],
                    "y": ["type": "number", "description": "Y coordinate."],
                    "text": ["type": "string", "description": "Text to render inside badge."],
                    "color": ["type": "string", "description": "Border color for badge."],
                    "app": ["type": "string", "description": Self.appParamDescription],
                    "is_normalized": ["type": "boolean", "description": "Set to true if x and y are normalized 0.0-1.0 ratios."],
                    "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                ],
                "required": ["x", "y", "text"]
            ]
        ],
        [
            "name": "draw_path",
            "description": "Draws a freehand path or organic sketch from an array of points. Ideal for freehand circles, squiggles, custom highlights, checkmarks, or organic loops around UI elements. Annotations are LINKED TO AN APP and are only visible while that app is frontmost -- see the 'app' parameter.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                    "points": [
                        "type": "array",
                        "minItems": 2,
                        "maxItems": DrawingDefaults.maxPathPoints,
                        "description": "Array of points as [[x1, y1], [x2, y2]...] or [{'x': x1, 'y': y1}...]. At least 2 and at most \(DrawingDefaults.maxPathPoints) points; every stored point is re-walked on each repaint, so an oversized path costs frame time for as long as it exists."
                    ],
                    "color": ["type": "string", "description": "Hex color e.g. '\(DrawingDefaults.pathColor)' or color name."],
                    "stroke_width": ["type": "number", "description": "Line thickness in physical pixels. Default \(DrawingDefaults.pathStrokeWidthPx)."],
                    "is_closed": ["type": "boolean", "description": "Set to true to close the loop from last point back to first point (ideal for freehand circles/lassos)."],
                    "label": ["type": "string", "description": "Optional label text."],
                    "app": ["type": "string", "description": Self.appParamDescription],
                    "is_normalized": ["type": "boolean", "description": "Set to true if points are normalized 0.0-1.0 ratios."],
                    "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                ],
                "required": ["points"]
            ]
        ],
        [
            "name": "draw_grid",
            "description": "Draws a subtle pixel alignment grid over the specified screen for visual spatial calibration. Unlike the other draw tools this defaults to GLOBAL (visible over every app), because a coordinate ruler is only useful if it stays on screen while you switch to the app you are measuring. Pass 'app' to scope it to one app anyway.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                    "step_px": ["type": "number", "minimum": DrawingDefaults.minGridStepPx, "description": "Grid line interval in physical pixels. Default \(Int(DrawingDefaults.gridStepPx)); must be at least \(Int(DrawingDefaults.minGridStepPx)). A spacing below one physical pixel cannot be rendered and is rejected."],
                    "color": ["type": "string", "description": "Grid line color. Default '\(DrawingDefaults.gridColor)'."],
                    "label": ["type": "string", "description": "Optional label text used to identify the grid in list_annotations."],
                    "app": ["type": "string", "description": "Optional app (bundle id or display name) to restrict the grid to. Omit for the default: a GLOBAL grid visible over every app."],
                    "duration_seconds": ["type": "number", "description": "Duration in seconds before grid clears. Default \(DrawingDefaults.gridDurationSeconds)."]
                ]
            ]
        ],
        [
            "name": "clear",
            "description": "Clears annotations. With annotation_id: removes just that one, whatever app it belongs to. Without it, 'scope' decides: 'active' (THE DEFAULT) removes exactly what an untagged draw_* call would have targeted -- the annotations linked to get_active_app's 'fallback' app, plus the global ones -- and leaves notes attached to other apps alone; 'all' wipes every annotation for every app. 'active' targets the fallback app, NOT the literally-frontmost one, because when you call this Claude itself is frontmost: matching the draw path is what makes 'clear what you just drew' actually work. The default is deliberately the narrow one, because annotations linked to a background app are invisible and would otherwise be destroyed without the user ever seeing them.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "annotation_id": ["type": "string", "description": "Optional ID of a specific annotation to remove. Takes precedence over scope."],
                    "scope": ["type": "string", "enum": ["active", "all"], "description": "'active' (default): clear the annotations linked to the same app your untagged draw_* calls target (get_active_app's 'fallback'), plus global ones. 'all': clear everything across all apps."]
                ]
            ]
        ],
        [
            "name": "list_annotations",
            "description": "Returns every active annotation across all screens with its ID, type, coordinates, and the app it is linked to (appId + appName, or null = global), plus an isVisibleNow flag and which app is currently frontmost. Use this to diagnose 'I drew something but cannot see it' -- usually the annotation is linked to an app that is not frontmost.",
            "inputSchema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "get_active_app",
            "description": "Reports which app is frontmost right now AND which app an untagged draw_* call would link to. These differ on purpose: when the user asks Claude to annotate something, Claude's own window is frontmost, so untagged draws target the app the user was in BEFORE switching to Claude. Call this before drawing if you are unsure which app the user means, and pass that bundle id explicitly as the 'app' parameter.",
            "inputSchema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "set_capture_visible",
            "description": "Sets AI Chalkboard's capture-debug mode while keeping the existing API name. false (default) requests NSWindowSharingType.none and uses normal per-app rendering; true requests .readOnly and makes the overlay render EVERY annotation, including annotations linked to an app that is not frontmost, so supported full-display capture paths can verify placement. This is an eligibility/request flag, not a guarantee: modern capture tools such as ScreenCaptureKit or computer-use can independently include or exclude apps and windows. Restore false after debugging to restore normal filtering. Applies to every AI Chalkboard instance immediately; no restart needed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "visible": ["type": "boolean", "description": "true = request capture eligibility (.readOnly) and render all annotations. false = request legacy exclusion (.none) and restore normal app filtering. The capturing program's own filters still decide final inclusion."]
                ],
                "required": ["visible"]
            ]
        ]
    ]
}
