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
            "get_screens", "get_overlay_state", "get_accessibility_status", "draw_path", "draw_image", "draw_text", "highlight_element", "draw_batch", "update_annotation", "suspend_annotations", "resume_annotations", "clear", "list_annotations",
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
            "suspend_annotations": nil,
            "resume_annotations": ["lease_token"],
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
        // The catalog's advertised cap must match what MCPToolHandlers
        // actually enforces for draw_text's `text` (DrawingDefaults.maxTextCharacters),
        // so a caller never discovers the real limit only via a rejection.
        XCTAssertEqual((text["text"] as? [String: Any])?["maxLength"] as? Int, DrawingDefaults.maxTextCharacters)
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
        // The catalog's advertised cap must match what MCPToolHandlers
        // actually enforces for highlight_element's `label`
        // (DrawingDefaults.maxHighlightLabelCharacters), so a caller never
        // discovers the real limit only via a rejection.
        XCTAssertEqual((highlight["label"] as? [String: Any])?["maxLength"] as? Int, DrawingDefaults.maxHighlightLabelCharacters)
    }

    func testSuspensionLeaseSchemasAreStrictAndPreserveTheClickWorkaroundContract() throws {
        let suspend = try XCTUnwrap(toolsByName["suspend_annotations"])
        let resume = try XCTUnwrap(toolsByName["resume_annotations"])
        XCTAssertEqual(inputSchema(suspend)["type"] as? String, "object")
        XCTAssertEqual(inputSchema(suspend)["additionalProperties"] as? Bool, false)
        XCTAssertNil(inputSchema(suspend)["required"])
        let suspendProperties = properties(suspend)
        XCTAssertEqual(Set(suspendProperties.keys), ["lease_seconds", "idempotency_key"])
        XCTAssertEqual((suspendProperties["lease_seconds"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((suspendProperties["lease_seconds"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((suspendProperties["lease_seconds"] as? [String: Any])?["maximum"] as? Int, 60)
        XCTAssertEqual((suspendProperties["idempotency_key"] as? [String: Any])?["pattern"] as? String,
                       "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

        XCTAssertEqual(inputSchema(resume)["type"] as? String, "object")
        XCTAssertEqual(inputSchema(resume)["additionalProperties"] as? Bool, false)
        XCTAssertEqual(inputSchema(resume)["required"] as? [String], ["lease_token"])
        let resumeProperties = properties(resume)
        XCTAssertEqual(Set(resumeProperties.keys), ["lease_token"])
        XCTAssertEqual((resumeProperties["lease_token"] as? [String: Any])?["minLength"] as? Int, 43)
        XCTAssertEqual((resumeProperties["lease_token"] as? [String: Any])?["maxLength"] as? Int, 43)
        XCTAssertEqual((resumeProperties["lease_token"] as? [String: Any])?["pattern"] as? String, "^[A-Za-z0-9_-]{43}$")

        let suspendDescription = suspend["description"] as? String ?? ""
        let resumeDescription = resume["description"] as? String ?? ""
        XCTAssertTrue(suspendDescription.contains("click") && suspendDescription.contains("leaseToken"))
        XCTAssertTrue(suspendDescription.contains("secret") && suspendDescription.contains("MCP server process instance"))
        XCTAssertTrue(resumeDescription.contains("suspend_annotations") && resumeDescription.contains("lease"))
        XCTAssertTrue(resumeDescription.contains("120-second"))
        XCTAssertTrue(resumeDescription.contains("peer presentation settled"))
        XCTAssertTrue(resumeDescription.contains("not proof of global window convergence"))
    }

    func testSuspendedReleaseRequiresPeerPresentationSettlementForMCPSuccess() {
        XCTAssertTrue(SuspensionLeaseResponsePolicy.isError(
            operation: "release", operationSucceeded: true,
            annotationsSuspended: true, peerPresentationSettled: false
        ))
        XCTAssertFalse(SuspensionLeaseResponsePolicy.isError(
            operation: "release", operationSucceeded: true,
            annotationsSuspended: true, peerPresentationSettled: true
        ))
        // Final release deliberately has no global convergence proof, but the
        // linearized durable mutation itself is still a successful cleanup.
        XCTAssertFalse(SuspensionLeaseResponsePolicy.isError(
            operation: "release", operationSucceeded: true,
            annotationsSuspended: false, peerPresentationSettled: false
        ))
        XCTAssertTrue(SuspensionLeaseResponsePolicy.isError(
            operation: "acquire", operationSucceeded: false,
            annotationsSuspended: true, peerPresentationSettled: false
        ))
    }
}
