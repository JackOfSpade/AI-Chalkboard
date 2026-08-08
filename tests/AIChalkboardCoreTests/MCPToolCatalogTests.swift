import XCTest
@testable import AIChalkboardCore

/// `MCPToolCatalog.tools` is the static `tools/list` payload every MCP client
/// depends on. These tests lock in the structural contract -- names, order,
/// required schema shape -- without pinning exact prose, and confirm the
/// numeric schema fields an MCP client actually validates against
/// (`exclusiveMinimum`, `minItems`/`maxItems`, `minimum`) match the
/// `DrawingDefaults` constants that `DrawValidation` enforces server-side.
///
/// That last group used to instead assert that a schema DESCRIPTION STRING
/// contained a substring built from the very same `DrawingDefaults` constant
/// being checked -- e.g. asserting `colorDescription.contains(DrawingDefaults
/// .circleColor)`. That passed even if `circleColor` were wrong, because the
/// "expected" value and the "actual" value were the same expression evaluated
/// twice; it protected nothing. Comparing a SCHEMA FIELD like `exclusiveMinimum`
/// or `maxItems` to the `DrawingDefaults` constant it must equal is not
/// tautological the same way: the schema literal (`MCPToolCatalog.swift`) and
/// the runtime check (`DrawValidation`) are two independently-written
/// expressions of the same limit, so this is what actually catches them
/// drifting apart -- which is the failure mode worth guarding against, since
/// an MCP client validates a call against the SCHEMA before this server ever
/// sees it, and a client-side bound that is looser than the server's would
/// let a call through that `DrawValidation` then silently rejects.
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

    func testDrawCircleRadiusSchemaExclusiveMinimumMatchesTheValidationBoundary() {
        guard let tool = toolsByName["draw_circle"] else { return XCTFail("missing draw_circle") }
        let radiusSchema = properties(tool)["radius"] as? [String: Any]
        // `DrawValidation.positiveRadius` rejects `radius <= 0`; the schema's
        // `exclusiveMinimum: 0` is what lets a well-behaved MCP client refuse
        // that same call itself, before ever sending it here. If a future
        // edit loosened one boundary without the other, an MCP client would
        // accept calls this server then rejects (or vice versa) -- this is
        // what would catch that.
        XCTAssertEqual(radiusSchema?["exclusiveMinimum"] as? Int, 0,
                       "draw_circle's radius schema must declare exclusiveMinimum: 0, matching DrawValidation.positiveRadius's own boundary")
    }

    func testDrawBoxWidthAndHeightSchemaExclusiveMinimumsMatchTheValidationBoundary() {
        guard let tool = toolsByName["draw_box"] else { return XCTFail("missing draw_box") }
        let props = properties(tool)
        let widthSchema = props["width"] as? [String: Any]
        let heightSchema = props["height"] as? [String: Any]
        // Mirrors the draw_circle radius test above: DrawValidation.
        // positiveDimensions rejects `width <= 0 || height <= 0`, and the
        // schema's `exclusiveMinimum: 0` on both properties is the
        // independent, client-side expression of that same boundary.
        XCTAssertEqual(widthSchema?["exclusiveMinimum"] as? Int, 0,
                       "draw_box's width schema must declare exclusiveMinimum: 0, matching DrawValidation.positiveDimensions's own boundary")
        XCTAssertEqual(heightSchema?["exclusiveMinimum"] as? Int, 0,
                       "draw_box's height schema must declare exclusiveMinimum: 0, matching DrawValidation.positiveDimensions's own boundary")
    }

    func testDrawPathPointsSchemaMinAndMaxItemsMatchTheEnforcedLimits() {
        guard let tool = toolsByName["draw_path"] else { return XCTFail("missing draw_path") }
        let pointsSchema = properties(tool)["points"] as? [String: Any]
        // The lower bound mirrors MCPToolHandlers' own "at least 2 points"
        // guard; the upper bound must equal DrawingDefaults.maxPathPoints,
        // the very constant DrawValidation.pathPointCount enforces against
        // the count of points that actually get stored. The schema literal
        // in MCPToolCatalog.swift and the runtime check in DrawValidation are
        // two independently-written expressions of that same cap -- this is
        // what catches them drifting apart.
        XCTAssertEqual(pointsSchema?["minItems"] as? Int, 2,
                       "draw_path's points schema must declare minItems: 2")
        XCTAssertEqual(pointsSchema?["maxItems"] as? Int, DrawingDefaults.maxPathPoints,
                       "draw_path's points schema maxItems must equal DrawingDefaults.maxPathPoints, matching DrawValidation.pathPointCount's own limit")
    }

    func testDrawGridStepPxSchemaMinimumMatchesTheHangGuardFloor() {
        guard let tool = toolsByName["draw_grid"] else { return XCTFail("missing draw_grid") }
        let stepSchema = properties(tool)["step_px"] as? [String: Any]
        // DrawingDefaults.minGridStepPx is a hang guard (see its doc comment),
        // not a cosmetic minimum, and DrawValidation.gridStep enforces it at
        // runtime. The schema's `minimum` field is the independent,
        // client-side expression of that exact same floor.
        XCTAssertEqual(stepSchema?["minimum"] as? Double, DrawingDefaults.minGridStepPx,
                       "draw_grid's step_px schema minimum must equal DrawingDefaults.minGridStepPx, matching DrawValidation.gridStep's own boundary")
    }
}
