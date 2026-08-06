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
    
    private func handleToolsList(id: Any?) {
        guard let id = id else { return }
        
        let tools: [[String: Any]] = [
            [
                "name": "get_screens",
                "description": "Returns all connected macOS displays, physical pixel resolutions, backing scale factors, and point dimensions. Use this first to pick screen_id and determine coordinate bounds.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "draw_circle",
                "description": "Draws a transparent highlighted circle on the overlay. Coordinates (x, y, radius) can be physical pixels (default) or normalized 0.0-1.0 (if is_normalized=true).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "screen_id": ["type": "string", "description": "Screen ID or index ('0', '1', or display ID from get_screens). Defaults to main screen."],
                        "x": ["type": "number", "description": "Center X coordinate (physical pixels or normalized 0.0-1.0)."],
                        "y": ["type": "number", "description": "Center Y coordinate (physical pixels or normalized 0.0-1.0)."],
                        "radius": ["type": "number", "description": "Radius in physical pixels."],
                        "color": ["type": "string", "description": "Hex color e.g. '#FF0000' or name 'red','green','blue','yellow','orange','purple','pink','white'."],
                        "label": ["type": "string", "description": "Optional label text attached to circle badge."],
                        "is_normalized": ["type": "boolean", "description": "Set to true if x and y are normalized 0.0-1.0 ratios."],
                        "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                    ],
                    "required": ["x", "y", "radius"]
                ]
            ],
            [
                "name": "draw_arrow",
                "description": "Draws a line with an arrowhead from (x1, y1) to (x2, y2). Supports physical pixels or normalized 0.0-1.0 coordinates.",
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
                        "is_normalized": ["type": "boolean", "description": "Set to true if x1, y1, x2, y2 are normalized 0.0-1.0 ratios."],
                        "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                    ],
                    "required": ["x1", "y1", "x2", "y2"]
                ]
            ],
            [
                "name": "draw_box",
                "description": "Draws a rectangle on the overlay. Coordinates (x, y, width, height) support physical pixels or normalized 0.0-1.0.",
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
                        "is_normalized": ["type": "boolean", "description": "Set to true if x, y, width, height are normalized 0.0-1.0 ratios."],
                        "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                    ],
                    "required": ["x", "y", "width", "height"]
                ]
            ],
            [
                "name": "draw_label",
                "description": "Draws a floating label badge at (x, y). Supports physical pixels or normalized 0.0-1.0 coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                        "x": ["type": "number", "description": "X coordinate."],
                        "y": ["type": "number", "description": "Y coordinate."],
                        "text": ["type": "string", "description": "Text to render inside badge."],
                        "color": ["type": "string", "description": "Border color for badge."],
                        "is_normalized": ["type": "boolean", "description": "Set to true if x and y are normalized 0.0-1.0 ratios."],
                        "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                    ],
                    "required": ["x", "y", "text"]
                ]
            ],
            [
                "name": "draw_path",
                "description": "Draws a freehand path or organic sketch from an array of points. Ideal for freehand circles, squiggles, custom highlights, checkmarks, or organic loops around UI elements.",
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
                        "is_normalized": ["type": "boolean", "description": "Set to true if points are normalized 0.0-1.0 ratios."],
                        "duration_seconds": ["type": "number", "description": "Optional duration in seconds after which drawing automatically disappears."]
                    ],
                    "required": ["points"]
                ]
            ],
            [
                "name": "draw_grid",
                "description": "Draws a subtle pixel alignment grid over the specified screen for visual spatial calibration.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "screen_id": ["type": "string", "description": "Screen ID or index from get_screens."],
                        "step_px": ["type": "number", "description": "Grid line interval in physical pixels. Default 200."],
                        "color": ["type": "string", "description": "Grid line color. Default '#00E0FF'."],
                        "duration_seconds": ["type": "number", "description": "Duration in seconds before grid clears. Default 5.0."]
                    ]
                ]
            ],
            [
                "name": "clear",
                "description": "Clears a specific annotation by ID, or clears all annotations on all screens if annotation_id is omitted.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "annotation_id": ["type": "string", "description": "Optional ID of specific annotation to remove. If omitted, clears all annotations."]
                    ]
                ]
            ],
            [
                "name": "list_annotations",
                "description": "Returns a list of currently active annotations across all screens with their IDs, types, and coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
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
            if let data = try? JSONEncoder().encode(screens),
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
            
            let annotation = Annotation(
                screenId: screenId,
                kind: .circle(x: x, y: y, radius: radius),
                colorHex: color,
                label: label
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created circle annotation: \(annotation.id)")
            
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
            
            let annotation = Annotation(
                screenId: screenId,
                kind: .arrow(x1: x1, y1: y1, x2: x2, y2: y2),
                colorHex: color,
                label: label
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created arrow annotation: \(annotation.id)")
            
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
            
            let annotation = Annotation(
                screenId: screenId,
                kind: .box(x: x, y: y, width: width, height: height),
                colorHex: color,
                label: label
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created box annotation: \(annotation.id)")
            
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
            
            let annotation = Annotation(
                screenId: screenId,
                kind: .label(x: x, y: y, text: text),
                colorHex: color,
                label: nil
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created label annotation: \(annotation.id)")

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
            
            let annotation = Annotation(
                screenId: screenId,
                kind: .path(points: parsedPoints, strokeWidth: strokeWidth, isClosed: isClosed),
                colorHex: color,
                label: label
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created freehand path annotation: \(annotation.id)")

        case "draw_grid":
            let screenId = OverlayWindowController.shared.resolveScreenId(args["screen_id"] as? String)
            let stepPx = getDouble(args["step_px"]) ?? 200.0
            let color = args["color"] as? String ?? "#00E0FF"
            let duration = getDouble(args["duration_seconds"]) ?? 5.0
            
            let annotation = Annotation(
                screenId: screenId,
                kind: .grid(stepPx: stepPx),
                colorHex: color,
                label: nil
            )
            AnnotationStore.shared.add(annotation, durationSeconds: duration)
            sendTextResult(id: id, text: "Created alignment grid annotation: \(annotation.id)")
            
        case "clear":
            if let annId = args["annotation_id"] as? String, !annId.isEmpty {
                let removed = AnnotationStore.shared.remove(id: annId)
                if removed {
                    sendTextResult(id: id, text: "Cleared annotation \(annId)")
                } else {
                    sendTextResult(id: id, text: "Annotation \(annId) not found.")
                }
            } else {
                AnnotationStore.shared.clearAll()
                sendTextResult(id: id, text: "Cleared all annotations.")
            }
            
        case "list_annotations":
            let annotations = AnnotationStore.shared.getAll()
            if let data = try? JSONEncoder().encode(annotations),
               let jsonString = String(data: data, encoding: .utf8) {
                sendTextResult(id: id, text: jsonString)
            } else {
                sendErrorResult(id: id, text: "Failed to encode annotations.")
            }
            
        default:
            sendErrorResult(id: id, text: "Unknown tool: \(name)")
        }
    }
    
    private func getScreenInfo(id: String) -> ScreenInfo? {
        return OverlayWindowController.shared.getScreenInfos().first(where: { $0.id == id })
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
