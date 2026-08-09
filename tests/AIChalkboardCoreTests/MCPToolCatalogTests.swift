import XCTest
@testable import AIChalkboardCore

final class MCPToolCatalogTests: XCTestCase {
    private var toolsByName: [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool) }
        })
    }

    private func inputSchema(_ tool: [String: Any]) -> [String: Any] {
        tool["inputSchema"] as? [String: Any] ?? [:]
    }

    private func properties(_ tool: [String: Any]) -> [String: Any] {
        inputSchema(tool)["properties"] as? [String: Any] ?? [:]
    }

    func testToolNamesAndOrderAreExactlyTheFreeDrawSurface() {
        XCTAssertEqual(MCPToolCatalog.tools.map { $0["name"] as? String }, [
            "get_screens", "get_overlay_state", "get_accessibility_status", "draw_path", "draw_image", "draw_text", "highlight_element", "draw_batch", "update_annotation", "clear", "list_annotations",
            "verify_annotation", "verify_presentation", "get_active_app", "set_capture_visible"
        ])
    }

    func testEveryToolHasANonEmptyDescriptionAndObjectSchema() {
        for tool in MCPToolCatalog.tools {
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            XCTAssertEqual(inputSchema(tool)["type"] as? String, "object")
        }
    }

    func testEveryFreeDrawToolExposesSharedLifecycleProperties() {
        for name in ["draw_path", "draw_image", "draw_text", "draw_batch"] {
            let props = properties(try! XCTUnwrap(toolsByName[name]))
            XCTAssertEqual((props["app"] as? [String: Any])?["type"] as? String, "string")
            XCTAssertEqual((props["duration_seconds"] as? [String: Any])?["type"] as? String, "number")
            XCTAssertEqual((props["duration_seconds"] as? [String: Any])?["maximum"] as? Double, DrawingDefaults.maxAnnotationDurationSeconds)
        }
    }

    func testRequiredArraysMatchTheThreeFreeDrawTools() {
        let expected: [String: [String]?] = [
            "get_screens": nil,
            "get_overlay_state": nil,
            "get_accessibility_status": nil,
            "draw_path": ["path_data"],
            "draw_image": ["image_path", "x", "y"],
            "draw_text": ["text", "x", "y", "font_size"],
            "highlight_element": ["label"],
            "draw_batch": ["items"],
            "update_annotation": ["annotation_id"],
            "clear": nil,
            "list_annotations": nil,
            "verify_annotation": ["annotation_id"],
            "verify_presentation": ["annotation_id"],
            "get_active_app": nil,
            "set_capture_visible": ["visible"]
        ]
        for (name, required) in expected {
            XCTAssertEqual(inputSchema(try! XCTUnwrap(toolsByName[name]))["required"] as? [String], required, name)
        }
    }

    func testPathSchemaCarriesSVGAndStyleBounds() throws {
        let props = properties(try XCTUnwrap(toolsByName["draw_path"]))
        XCTAssertEqual((props["path_data"] as? [String: Any])?["maxLength"] as? Int, DrawingDefaults.maxSVGPathCharacters)
        XCTAssertEqual((props["stroke_width"] as? [String: Any])?["minimum"] as? Int, 0)
        XCTAssertEqual((props["fill_opacity"] as? [String: Any])?["maximum"] as? Int, 1)
        XCTAssertEqual((props["stroke_opacity"] as? [String: Any])?["maximum"] as? Int, 1)
        let dash = try XCTUnwrap(props["dash"] as? [String: Any])
        XCTAssertEqual(dash["maxItems"] as? Int, DrawingDefaults.maxDashElements)
        XCTAssertEqual(((dash["items"] as? [String: Any])?["exclusiveMinimum"]) as? Int, 0)
    }

    func testImageAndBatchSchemasProtectGeometryAndBatchSize() throws {
        let image = properties(try XCTUnwrap(toolsByName["draw_image"]))
        XCTAssertEqual((image["width"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((image["height"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((image["opacity"] as? [String: Any])?["maximum"] as? Int, 1)
        let batch = properties(try XCTUnwrap(toolsByName["draw_batch"]))
        let items = try XCTUnwrap(batch["items"] as? [String: Any])
        XCTAssertEqual(items["minItems"] as? Int, 1)
        XCTAssertEqual(items["maxItems"] as? Int, DrawingDefaults.maxBatchItems)
    }

    func testTextCoordinateAndUpdateSchemasExposeTheNewSurface() throws {
        let text = properties(try XCTUnwrap(toolsByName["draw_text"]))
        XCTAssertEqual((text["font_size"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((text["coordinate_space"] as? [String: Any])?["enum"] as? [String], ["backing_pixels", "normalized", "screenshot_pixels"])
        XCTAssertEqual((properties(try XCTUnwrap(toolsByName["update_annotation"]))["offset_x"] as? [String: Any])?["type"] as? String, "number")
    }

    func testClearAndVerificationSchemasRemainExact() throws {
        let clear = properties(try XCTUnwrap(toolsByName["clear"]))
        XCTAssertEqual((clear["scope"] as? [String: Any])?["enum"] as? [String], ["active", "all"])
        XCTAssertEqual((clear["app"] as? [String: Any])?["type"] as? String, "string")
        let verify = properties(try XCTUnwrap(toolsByName["verify_annotation"]))
        XCTAssertEqual((verify["padding_px"] as? [String: Any])?["maximum"] as? Double, AnnotationVerificationCompositor.maxPaddingPx)
        XCTAssertEqual((verify["capture_source"] as? [String: Any])?["enum"] as? [String], ["chalkboard"])
        XCTAssertEqual((verify["request_permission"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual((properties(try XCTUnwrap(toolsByName["verify_presentation"]))["annotation_id"] as? [String: Any])?["type"] as? String, "string")

        let list = properties(try XCTUnwrap(toolsByName["list_annotations"]))
        XCTAssertEqual((list["offset"] as? [String: Any])?["minimum"] as? Int, 0)
        XCTAssertEqual((list["limit"] as? [String: Any])?["maximum"] as? Int, DrawingDefaults.maxAnnotationListPageItems)
    }

    func testAccessibilityAndOverlaySchemasExposeExplicitPermissionAndClickThroughContracts() throws {
        let accessibility = properties(try XCTUnwrap(toolsByName["get_accessibility_status"]))
        XCTAssertEqual((accessibility["request_permission"] as? [String: Any])?["type"] as? String, "boolean")

        let highlight = properties(try XCTUnwrap(toolsByName["highlight_element"]))
        XCTAssertEqual((highlight["match"] as? [String: Any])?["enum"] as? [String], ["exact", "contains"])
        XCTAssertEqual((highlight["occurrence"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((highlight["z"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((highlight["color"] as? [String: Any])?["type"] as? String, "string")
    }
}
