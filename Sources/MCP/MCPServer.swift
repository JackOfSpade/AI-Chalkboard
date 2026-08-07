import Foundation
import AppKit

public final class MCPServer: @unchecked Sendable {
    public static let shared = MCPServer()
    private var isRunning = false
    
    private init() {}
    
    public func log(_ message: String) {
        Logger.shared.log(message, level: "MCP")
    }
    
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
        log("Starting stdio MCP Server loop...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop()
        }
    }
    
    private func readLoop() {
        let stdin = FileHandle.standardInput
        var buffer = Data()

        while isRunning {
            let availableData = stdin.availableData
            if availableData.isEmpty {
                log("EOF on stdin. Exiting MCP loop.")
                break
            }

            buffer.append(availableData)

            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                if lineData.last == UInt8(ascii: "\r") {
                    lineData.removeLast()
                }

                if lineData.isEmpty { continue }
                handleMessage(lineData)
            }
        }

        // `isRunning` is only ever set to `true` (in start()); it is never
        // flipped back to false anywhere. So the only way execution reaches
        // this point is the EOF `break` above -- i.e. stdin.availableData
        // came back empty, meaning the read end of stdin has been closed.
        //
        // CRITICAL GATING -- do not remove or "simplify" this check.
        // MCPServer.shared.start() (and therefore this readLoop) runs
        // unconditionally in BOTH launch modes -- see
        // AppDelegate.applicationDidFinishLaunching. In real MCP mode
        // (launched as `AIChalkboard --mcp` by an MCP host such as Claude
        // Desktop), stdin IS the client's pipe, and EOF means the client
        // process died or disconnected -- there is nothing left to serve, so
        // this process should exit rather than linger as an orphaned overlay
        // window (and Dock entry, in GUI mode) forever.
        //
        // But in normal GUI mode (user double-clicks AIChalkboard.app from
        // Finder/Dock), stdin is NOT a client pipe at all -- it's typically
        // /dev/null or simply closed, so stdin.availableData returns empty
        // essentially IMMEDIATELY on launch. If we terminated unconditionally
        // here, double-clicking the app would cause it to quit itself almost
        // instantly, making the GUI completely unusable. Gating on
        // LaunchMode.isMCPMode is what makes EOF-triggered shutdown safe: it
        // only fires when stdin EOF actually means "the MCP client hung up",
        // never when it just means "no one ever piped anything to stdin."
        guard LaunchMode.isMCPMode else {
            log("Not in MCP mode; leaving app running after stdin EOF (expected for a normal GUI launch, where stdin is not a client pipe).")
            return
        }

        log("MCP client pipe closed (stdin EOF) while in MCP mode. Terminating process to avoid leaving an orphaned background instance.")

        // NSApp.terminate(_:) must be called on the main thread. readLoop()
        // runs on a background DispatchQueue.global() queue (see start()),
        // so we hop to the main queue rather than calling it directly here.
        // Routing through NSApp.terminate(nil) (instead of a bare exit(0))
        // keeps this symmetric with the SIGTERM/SIGINT/SIGHUP shutdown path
        // in the launcher entry point, and ensures AppDelegate.applicationWillTerminate's
        // clean-shutdown log line still fires.
        DispatchQueue.main.async {
            // LIFECYCLE shutdown, NOT a user quit. Claude Desktop gives each of
            // the two processes it spawns its own stdin pipe, so this pipe
            // closing says nothing about the sibling's -- the sibling may still
            // be serving its client perfectly well. Marking the termination
            // internal is what stops AppDelegate.applicationShouldTerminate
            // from broadcasting a quit that would take that healthy sibling
            // down with us.
            AppDelegate.markInternalTermination(reason: "MCP client pipe closed (stdin EOF)")
            NSApp.terminate(nil)
        }
    }
    
    private func sendResponse(_ jsonObject: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
              var jsonString = String(data: data, encoding: .utf8) else {
            log("Failed to serialize response JSON.")
            return
        }
        
        jsonString += "\n"
        
        if let outputData = jsonString.data(using: .utf8) {
            FileHandle.standardOutput.write(outputData)
        }
    }
    
    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            log("Invalid JSON payload received.")
            return
        }
        
        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]
        
        log("Received message method: \(method)")
        
        switch method {
        case "initialize":
            handleInitialize(id: id)
        case "notifications/initialized":
            log("Client completed initialization handshake.")
        case "ping":
            if let id = id {
                sendResponse(["jsonrpc": "2.0", "id": id, "result": [:]])
            }
        case "tools/list":
            handleToolsList(id: id)
        case "tools/call":
            handleToolsCall(id: id, params: params)
        default:
            if let id = id {
                sendResponse([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": [
                        "code": -32601,
                        "message": "Method not found: \(method)"
                    ]
                ])
            }
        }
    }
    
    private func handleInitialize(id: Any?) {
        guard let id = id else { return }
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "ai-chalkboard",
                "version": "1.2.0"
            ]
        ]
        sendResponse(["jsonrpc": "2.0", "id": id, "result": result])
    }
    
    /// Shared wording for the optional `app` parameter, so every draw tool
    /// describes per-app linking identically.
    private static let appParamDescription = "Optional app to LINK this annotation to: a bundle id ('com.apple.Terminal') or a display name ('DaVinci Resolve'). The annotation is then drawn ONLY while that app is frontmost, and hidden whenever the user switches away. If omitted, it links to the app the user was in before switching to Claude (see get_active_app's 'fallback'), which is almost always the app they are asking about. Pass an empty string to make the annotation GLOBAL (visible over every app)."

    private func handleToolsList(id: Any?) {
        guard let id = id else { return }

        let tools: [[String: Any]] = [
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
                        "radius": ["type": "number", "description": "Radius in physical pixels."],
                        "color": ["type": "string", "description": "Hex color e.g. '#FF0000' or name 'red','green','blue','yellow','orange','purple','pink','white'."],
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
                        "width": ["type": "number", "description": "Width coordinate."],
                        "height": ["type": "number", "description": "Height coordinate."],
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
                            "description": "Array of points as [[x1, y1], [x2, y2]...] or [{'x': x1, 'y': y1}...]"
                        ],
                        "color": ["type": "string", "description": "Hex color e.g. '#FF9500' or color name."],
                        "stroke_width": ["type": "number", "description": "Line thickness in physical pixels. Default 3.5."],
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
                        "step_px": ["type": "number", "description": "Grid line interval in physical pixels. Default 200."],
                        "color": ["type": "string", "description": "Grid line color. Default '#00E0FF'."],
                        "label": ["type": "string", "description": "Optional label text used to identify the grid in list_annotations."],
                        "app": ["type": "string", "description": "Optional app (bundle id or display name) to restrict the grid to. Omit for the default: a GLOBAL grid visible over every app."],
                        "duration_seconds": ["type": "number", "description": "Duration in seconds before grid clears. Default 5.0."]
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
        
        sendResponse(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    }
    
    private func handleToolsCall(id: Any?, params: [String: Any]) {
        guard let id = id else { return }
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        
        log("Calling tool: \(name) with args: \(args)")
        
        switch name {
        case "get_screens":
            let screens = OverlayWindowController.shared.getScreenInfos()
            // The `screens` array is byte-identical to what this tool used to
            // return at the top level; it is now nested so the capture state can
            // ride along. Reporting that state here is what lets a caller who
            // turned capture on for a placement check notice it is still on and
            // put it back, instead of silently leaving every subsequent
            // compatible capture path eligible to include annotations.
            guard let screenData = try? JSONEncoder().encode(screens),
                  let screenArray = (try? JSONSerialization.jsonObject(with: screenData)) as? [Any] else {
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
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                sendTextResult(id: id, text: jsonString)
            } else {
                sendErrorResult(id: id, text: "Failed to encode screen list.")
            }
            
        case "draw_circle":
            guard let rawX = getDouble(args["x"]),
                  let rawY = getDouble(args["y"]),
                  let radius = getDouble(args["radius"]) else {
                sendErrorResult(id: id, text: "Missing required parameters: x, y, radius")
                return
            }
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let isNorm = args["is_normalized"] as? Bool ?? false
            let screenInfo = getScreenInfo(id: screenId)
            let x = isNorm ? rawX * Double(screenInfo?.widthPx ?? 1920) : rawX
            let y = isNorm ? rawY * Double(screenInfo?.heightPx ?? 1080) : rawY
            
            let color = args["color"] as? String ?? "#FF0000"
            let label = args["label"] as? String
            let duration = getDouble(args["duration_seconds"])

            var appId: String?
            var appName: String?
            if let err = resolveTargetApp(args, defaultsToGlobal: false, appId: &appId, appName: &appName) {
                sendErrorResult(id: id, text: err)
                return
            }

            let annotation = Annotation(
                screenId: screenId,
                kind: .circle(x: x, y: y, radius: radius),
                colorHex: color,
                label: label,
                appId: appId,
                appName: appName
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created circle annotation: \(annotation.id)\(linkageSuffix(appId: appId, appName: appName))")
            
        case "draw_arrow":
            guard let rawX1 = getDouble(args["x1"]),
                  let rawY1 = getDouble(args["y1"]),
                  let rawX2 = getDouble(args["x2"]),
                  let rawY2 = getDouble(args["y2"]) else {
                sendErrorResult(id: id, text: "Missing required parameters: x1, y1, x2, y2")
                return
            }
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let isNorm = args["is_normalized"] as? Bool ?? false
            let screenInfo = getScreenInfo(id: screenId)
            let w = Double(screenInfo?.widthPx ?? 1920)
            let h = Double(screenInfo?.heightPx ?? 1080)
            
            let x1 = isNorm ? rawX1 * w : rawX1
            let y1 = isNorm ? rawY1 * h : rawY1
            let x2 = isNorm ? rawX2 * w : rawX2
            let y2 = isNorm ? rawY2 * h : rawY2
            
            let color = args["color"] as? String ?? "#00E0FF"
            let label = args["label"] as? String
            let duration = getDouble(args["duration_seconds"])

            var appId: String?
            var appName: String?
            if let err = resolveTargetApp(args, defaultsToGlobal: false, appId: &appId, appName: &appName) {
                sendErrorResult(id: id, text: err)
                return
            }

            let annotation = Annotation(
                screenId: screenId,
                kind: .arrow(x1: x1, y1: y1, x2: x2, y2: y2),
                colorHex: color,
                label: label,
                appId: appId,
                appName: appName
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created arrow annotation: \(annotation.id)\(linkageSuffix(appId: appId, appName: appName))")
            
        case "draw_box":
            guard let rawX = getDouble(args["x"]),
                  let rawY = getDouble(args["y"]),
                  let rawW = getDouble(args["width"]),
                  let rawH = getDouble(args["height"]) else {
                sendErrorResult(id: id, text: "Missing required parameters: x, y, width, height")
                return
            }
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let isNorm = args["is_normalized"] as? Bool ?? false
            let screenInfo = getScreenInfo(id: screenId)
            let sw = Double(screenInfo?.widthPx ?? 1920)
            let sh = Double(screenInfo?.heightPx ?? 1080)
            
            let x = isNorm ? rawX * sw : rawX
            let y = isNorm ? rawY * sh : rawY
            let width = isNorm ? rawW * sw : rawW
            let height = isNorm ? rawH * sh : rawH
            
            let color = args["color"] as? String ?? "#00FF66"
            let label = args["label"] as? String
            let duration = getDouble(args["duration_seconds"])

            var appId: String?
            var appName: String?
            if let err = resolveTargetApp(args, defaultsToGlobal: false, appId: &appId, appName: &appName) {
                sendErrorResult(id: id, text: err)
                return
            }

            let annotation = Annotation(
                screenId: screenId,
                kind: .box(x: x, y: y, width: width, height: height),
                colorHex: color,
                label: label,
                appId: appId,
                appName: appName
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created box annotation: \(annotation.id)\(linkageSuffix(appId: appId, appName: appName))")
            
        case "draw_label":
            guard let rawX = getDouble(args["x"]),
                  let rawY = getDouble(args["y"]),
                  let text = args["text"] as? String else {
                sendErrorResult(id: id, text: "Missing required parameters: x, y, text")
                return
            }
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let isNorm = args["is_normalized"] as? Bool ?? false
            let screenInfo = getScreenInfo(id: screenId)
            let x = isNorm ? rawX * Double(screenInfo?.widthPx ?? 1920) : rawX
            let y = isNorm ? rawY * Double(screenInfo?.heightPx ?? 1080) : rawY
            
            let color = args["color"] as? String ?? "#FFFF00"
            let duration = getDouble(args["duration_seconds"])

            var appId: String?
            var appName: String?
            if let err = resolveTargetApp(args, defaultsToGlobal: false, appId: &appId, appName: &appName) {
                sendErrorResult(id: id, text: err)
                return
            }

            let annotation = Annotation(
                screenId: screenId,
                kind: .label(x: x, y: y, text: text),
                colorHex: color,
                label: nil,
                appId: appId,
                appName: appName
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created label annotation: \(annotation.id)\(linkageSuffix(appId: appId, appName: appName))")

        case "draw_path":
            guard let rawPointsArg = args["points"] as? [Any], rawPointsArg.count >= 2 else {
                sendErrorResult(id: id, text: "Missing or invalid 'points' array (must contain at least 2 points).")
                return
            }
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let isNorm = args["is_normalized"] as? Bool ?? false
            let screenInfo = getScreenInfo(id: screenId)
            let w = Double(screenInfo?.widthPx ?? 1920)
            let h = Double(screenInfo?.heightPx ?? 1080)
            
            var parsedPoints: [[Double]] = []
            for item in rawPointsArg {
                if let ptArr = item as? [Any], ptArr.count >= 2,
                   let px = getDouble(ptArr[0]), let py = getDouble(ptArr[1]) {
                    let x = isNorm ? px * w : px
                    let y = isNorm ? py * h : py
                    parsedPoints.append([x, y])
                } else if let dict = item as? [String: Any],
                          let px = getDouble(dict["x"]), let py = getDouble(dict["y"]) {
                    let x = isNorm ? px * w : px
                    let y = isNorm ? py * h : py
                    parsedPoints.append([x, y])
                }
            }
            
            guard parsedPoints.count >= 2 else {
                sendErrorResult(id: id, text: "Failed to parse points array into (x, y) coordinates.")
                return
            }
            
            let color = args["color"] as? String ?? "#FF9500"
            let strokeWidth = getDouble(args["stroke_width"]) ?? 3.5
            let isClosed = args["is_closed"] as? Bool ?? false
            let label = args["label"] as? String
            let duration = getDouble(args["duration_seconds"])

            var appId: String?
            var appName: String?
            if let err = resolveTargetApp(args, defaultsToGlobal: false, appId: &appId, appName: &appName) {
                sendErrorResult(id: id, text: err)
                return
            }

            let annotation = Annotation(
                screenId: screenId,
                kind: .path(points: parsedPoints, strokeWidth: strokeWidth, isClosed: isClosed),
                colorHex: color,
                label: label,
                appId: appId,
                appName: appName
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created freehand path annotation: \(annotation.id)\(linkageSuffix(appId: appId, appName: appName))")

        case "draw_grid":
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let stepPx = getDouble(args["step_px"]) ?? 200.0
            let color = args["color"] as? String ?? "#00E0FF"
            let label = args["label"] as? String
            let duration = getDouble(args["duration_seconds"]) ?? 5.0

            // GRID DEFAULTS TO GLOBAL (appId = nil) -- the one draw tool that
            // does. It is a calibration aid, not an annotation about any
            // particular app: you draw the grid precisely so you can look at it
            // while switching to the app you are measuring and read coordinates
            // off it. Linking it to the fallback app like everything else would
            // make it vanish the instant you switched to the app you wanted to
            // measure, which is the only moment it is useful. An explicit `app`
            // still scopes it, for measuring one app without covering others.
            var appId: String?
            var appName: String?
            if let err = resolveTargetApp(args, defaultsToGlobal: true, appId: &appId, appName: &appName) {
                sendErrorResult(id: id, text: err)
                return
            }

            let annotation = Annotation(
                screenId: screenId,
                kind: .grid(stepPx: stepPx),
                colorHex: color,
                label: label,
                appId: appId,
                appName: appName
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created alignment grid annotation: \(annotation.id)\(linkageSuffix(appId: appId, appName: appName))")
            
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

    /// `list_annotations` output: the raw encoded annotations, each enriched
    /// with the app it is linked to and whether it is on screen at this instant,
    /// wrapped alongside the current active app. The combination is what makes
    /// "I drew it and nothing appeared" self-diagnosing -- the answer is nearly
    /// always `isVisibleNow: false` because the linked app is not frontmost.
    private func buildAnnotationListJSON() -> String {
        let annotations = AnnotationStore.shared.getAll()
        let activeId = ActiveAppTracker.shared.currentAppId
        let captureVisible = OverlayWindowController.shared.isCaptureVisible
        let encoder = JSONEncoder()

        var entries: [[String: Any]] = []
        for annotation in annotations {
            // Round-tripping through the existing Codable encoding keeps the
            // `kind` payload byte-identical to what this tool returned before,
            // rather than re-deriving it by hand and risking drift.
            guard let data = try? encoder.encode(annotation),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            // Optionals are omitted entirely by the synthesized encoder, so set
            // them explicitly (JSONSerialization needs NSNull, not nil).
            object["appId"] = jsonValue(annotation.appId)
            object["appName"] = jsonValue(
                annotation.appName ?? ActiveAppTracker.shared.displayName(forBundleId: annotation.appId)
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

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "Error: failed to encode annotation list."
        }
        return jsonString
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

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "Error: failed to encode active app info."
        }
        return jsonString
    }
    
    private func getScreenInfo(id: String) -> ScreenInfo? {
        return OverlayWindowController.shared.getScreenInfos().first(where: { $0.id == id })
    }

    // MARK: - Per-app linking

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
    private func resolveTargetApp(
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
            if looksLikeBundleIdentifier(raw) {
                appId = raw
                appName = nil
                log("resolveTargetApp: '\(raw)' matched no running application but is bundle-id shaped; accepting it verbatim. The annotation will appear once that app is launched and brought to the front.")
                return nil
            }

            return "Could not resolve app '\(raw)'. Only RUNNING applications can be looked up by display name. Call get_active_app to see the current/fallback app, or pass a bundle identifier such as 'com.apple.Terminal' (accepted even if the app is not running yet)."
        }
    }

    /// Uses the same conservative complete-ID rule as ActiveAppTracker, so a
    /// vague prefix cannot be rejected there but accepted here.
    private func looksLikeBundleIdentifier(_ value: String) -> Bool {
        return BundleIdentifierSyntax.looksComplete(value)
    }

    /// Human-readable trailer appended to every draw_* success message, so the
    /// caller immediately learns that what it just drew may not be on screen.
    private func linkageSuffix(appId: String?, appName: String?) -> String {
        guard let appId = appId else {
            return " (GLOBAL: visible over every app)"
        }
        return " (linked to \(appName ?? appId) [\(appId)]: visible ONLY while that app is frontmost)"
    }
    
    private func getDouble(_ value: Any?) -> Double? {
        if let num = value as? NSNumber {
            return num.doubleValue
        }
        if let str = value as? String, let d = Double(str) {
            return d
        }
        return nil
    }
    
    private func sendTextResult(id: Any, text: String) {
        sendResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ])
    }
    
    private func sendErrorResult(id: Any, text: String) {
        sendResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "Error: \(text)"
                    ]
                ],
                "isError": true
            ]
        ])
    }
}
