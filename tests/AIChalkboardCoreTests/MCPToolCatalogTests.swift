import XCTest
@testable import AIChalkboardCore

/// `MCPToolCatalog.tools` is the static `tools/list` payload every MCP client
/// depends on. These tests lock in the structural contract -- names, order,
/// required schema shape -- without pinning exact prose, and confirm the
/// description strings that interpolate `DrawingDefaults` constants actually
/// contain the current values, which is what stops the docs Claude reads from
/// drifting from the code that applies them.
final class MCPToolCatalogTests: XCTestCase {
    private var toolsByName: [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for tool in MCPToolCatalog.tools {
            if let name = tool["name"] as? String {
                result[name] = tool
            }
        }
        return result
    }

    private func inputSchema(_ tool: [String: Any]) -> [String: Any] {
        (tool["inputSchema"] as? [String: Any]) ?? [:]
    }

    private func properties(_ tool: [String: Any]) -> [String: Any] {
        (inputSchema(tool)["properties"] as? [String: Any]) ?? [:]
    }

    func testToolNamesAndOrderAreExactlyWhatClientsExpect() {
        let expectedOrder = [
            "get_screens",
            "draw_circle",
            "draw_arrow",
            "draw_box",
            "draw_label",
            "draw_path",
            "draw_grid",
            "clear",
            "list_annotations",
            "get_active_app",
            "set_capture_visible"
        ]
        XCTAssertEqual(MCPToolCatalog.tools.map { $0["name"] as? String }, expectedOrder)
    }

    func testEveryToolHasANonEmptyDescriptionAndAnObjectInputSchema() {
        for tool in MCPToolCatalog.tools {
            let name = (tool["name"] as? String) ?? "<unnamed>"
            let description = tool["description"] as? String
            XCTAssertNotNil(description, "\(name) is missing a description")
            XCTAssertFalse(description?.isEmpty ?? true, "\(name) has an empty description")
            XCTAssertEqual(inputSchema(tool)["type"] as? String, "object", "\(name)'s inputSchema must be a JSON object schema")
        }
    }

    func testEveryDrawToolExposesAppAndDurationSecondsProperties() {
        let drawTools = ["draw_circle", "draw_arrow", "draw_box", "draw_label", "draw_path", "draw_grid"]
        let tools = toolsByName
        for name in drawTools {
            guard let tool = tools[name] else {
                XCTFail("missing tool \(name)")
                continue
            }
            let props = properties(tool)
            XCTAssertNotNil(props["app"], "\(name) must expose an 'app' property")
            XCTAssertNotNil(props["duration_seconds"], "\(name) must expose a 'duration_seconds' property")
        }
    }

    func testRequiredArraysAreExactlyRightPerTool() {
        let tools = toolsByName
        let expectedRequired: [String: [String]?] = [
            "get_screens": nil,
            "draw_circle": ["x", "y", "radius"],
            "draw_arrow": ["x1", "y1", "x2", "y2"],
            "draw_box": ["x", "y", "width", "height"],
            "draw_label": ["x", "y", "text"],
            "draw_path": ["points"],
            "draw_grid": nil,
            "clear": nil,
            "list_annotations": nil,
            "get_active_app": nil,
            "set_capture_visible": ["visible"]
        ]

        for (name, expected) in expectedRequired {
            guard let tool = tools[name] else {
                XCTFail("missing tool \(name)")
                continue
            }
            let actual = inputSchema(tool)["required"] as? [String]
            XCTAssertEqual(actual, expected, "\(name)'s required array does not match the documented contract")
        }
    }

    func testClearScopeEnumIsExactlyActiveOrAll() {
        guard let clearTool = toolsByName["clear"] else {
            return XCTFail("missing clear tool")
        }
        let scopeSchema = properties(clearTool)["scope"] as? [String: Any]
        XCTAssertEqual(scopeSchema?["enum"] as? [String], ["active", "all"])
    }

    func testDrawCircleColorDescriptionContainsTheCurrentDefaultConstant() {
        guard let tool = toolsByName["draw_circle"] else { return XCTFail("missing draw_circle") }
        let colorDescription = (properties(tool)["color"] as? [String: Any])?["description"] as? String
        XCTAssertTrue(colorDescription?.contains(DrawingDefaults.circleColor) ?? false,
                      "draw_circle's color description must mention the current circleColor default")
    }

    func testDrawPathDescriptionsContainTheCurrentDefaultConstants() {
        guard let tool = toolsByName["draw_path"] else { return XCTFail("missing draw_path") }
        let props = properties(tool)
        let colorDescription = (props["color"] as? [String: Any])?["description"] as? String
        let strokeWidthDescription = (props["stroke_width"] as? [String: Any])?["description"] as? String

        XCTAssertTrue(colorDescription?.contains(DrawingDefaults.pathColor) ?? false,
                      "draw_path's color description must mention the current pathColor default")
        XCTAssertTrue(strokeWidthDescription?.contains("\(DrawingDefaults.pathStrokeWidthPx)") ?? false,
                      "draw_path's stroke_width description must mention the current pathStrokeWidthPx default")
    }

    func testDrawGridDescriptionsContainTheCurrentDefaultConstants() {
        guard let tool = toolsByName["draw_grid"] else { return XCTFail("missing draw_grid") }
        let props = properties(tool)
        let stepDescription = (props["step_px"] as? [String: Any])?["description"] as? String
        let colorDescription = (props["color"] as? [String: Any])?["description"] as? String
        let durationDescription = (props["duration_seconds"] as? [String: Any])?["description"] as? String

        XCTAssertTrue(stepDescription?.contains("\(Int(DrawingDefaults.gridStepPx))") ?? false,
                      "draw_grid's step_px description must mention the current gridStepPx default")
        XCTAssertTrue(colorDescription?.contains(DrawingDefaults.gridColor) ?? false,
                      "draw_grid's color description must mention the current gridColor default")
        XCTAssertTrue(durationDescription?.contains("\(DrawingDefaults.gridDurationSeconds)") ?? false,
                      "draw_grid's duration_seconds description must mention the current gridDurationSeconds default")
    }
}
