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
            "get_screens", "get_overlay_state", "get_accessibility_status", "draw_path", "draw_shape", "draw_image", "draw_text", "highlight_element", "draw_batch", "update_annotation", "suspend_annotations", "resume_annotations", "clear", "list_annotations",
            "verify_annotation", "verify_presentation", "get_active_app", "set_capture_visible"
        ])
    }

    func testEveryToolHasANonEmptyDescriptionAndObjectSchema() {
        for tool in MCPToolCatalog.tools {
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            XCTAssertEqual(inputSchema(tool)["type"] as? String, "object")
            XCTAssertEqual(inputSchema(tool)["additionalProperties"] as? Bool, false,
                           "\(tool["name"] as? String ?? "<unnamed>") must reject undocumented arguments")
        }
    }

    func testEveryFreeDrawToolExposesSharedLifecycleProperties() {
        for name in ["draw_path", "draw_shape", "draw_image", "draw_text", "draw_batch"] {
            let props = properties(try! XCTUnwrap(toolsByName[name]))
            XCTAssertEqual((props["app"] as? [String: Any])?["type"] as? String, "string")
            XCTAssertEqual((props["screen_id"] as? [String: Any])?["maxLength"] as? Int, 128)
        }
    }

    func testRequiredArraysMatchTheThreeFreeDrawTools() {
        let expected: [String: [String]?] = [
            "get_screens": nil,
            "get_overlay_state": nil,
            "get_accessibility_status": nil,
            "draw_path": ["path_data"],
            "draw_shape": ["shape"],
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

    func testShapeSchemaReusesPathStylingButExcludesPathDataAndExposesShapeGeometry() throws {
        let props = properties(try XCTUnwrap(toolsByName["draw_shape"]))
        // draw_shape always computes and overwrites its own path from the
        // shape geometry, so advertising path_data as a real, honored
        // parameter would be misleading -- see MCPToolCatalog's
        // pathStyleProperties doc comment.
        XCTAssertNil(props["path_data"], "path_data must not be advertised on draw_shape")
        // Styling is still the same shared path styling every draw_path
        // caller gets.
        XCTAssertEqual((props["stroke_width"] as? [String: Any])?["minimum"] as? Int, 0)
        XCTAssertEqual((props["fill_rule"] as? [String: Any])?["enum"] as? [String], ["nonzero", "evenodd"])
        XCTAssertEqual((props["dash"] as? [String: Any])?["maxItems"] as? Int, DrawingDefaults.maxDashElements)
        // Shape geometry.
        XCTAssertEqual((props["shape"] as? [String: Any])?["enum"] as? [String], ["circle", "ellipse", "rect"])
        XCTAssertEqual((props["radius"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((props["radius_x"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((props["radius_y"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((props["width"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((props["height"] as? [String: Any])?["exclusiveMinimum"] as? Int, 0)
        XCTAssertEqual((props["center_x"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((props["center_y"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((props["x"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((props["y"] as? [String: Any])?["type"] as? String, "number")

        // draw_batch's per-item schema must accept the same shape geometry
        // AND list "shape" as a valid item type, so a batch item can
        // actually select shape: "shape".
        let batchItemsArray = try XCTUnwrap(properties(try XCTUnwrap(toolsByName["draw_batch"]))["items"] as? [String: Any])
        let batchItemSchema = try XCTUnwrap(batchItemsArray["items"] as? [String: Any])
        XCTAssertEqual(batchItemSchema["additionalProperties"] as? Bool, false)
        let itemProperties = batchItemSchema["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual((itemProperties["shape"] as? [String: Any])?["enum"] as? [String], ["circle", "ellipse", "rect"])
        XCTAssertEqual((itemProperties["type"] as? [String: Any])?["enum"] as? [String], ["path", "image", "text", "shape"])
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
        XCTAssertEqual((text["screenshot_width"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((text["screenshot_width"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((text["screenshot_height"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((text["screenshot_height"] as? [String: Any])?["minimum"] as? Int, 1)
        // The catalog's advertised cap must match what MCPToolHandlers
        // actually enforces for draw_text's `text` (DrawingDefaults.maxTextCharacters),
        // so a caller never discovers the real limit only via a rejection.
        XCTAssertEqual((text["text"] as? [String: Any])?["maxLength"] as? Int, DrawingDefaults.maxTextCharacters)
        XCTAssertEqual((properties(try XCTUnwrap(toolsByName["update_annotation"]))["offset_x"] as? [String: Any])?["type"] as? String, "number")
        let coordinateDescription = (text["coordinate_space"] as? [String: Any])?["description"] as? String ?? ""
        XCTAssertTrue(coordinateDescription.contains("exact dimensions"))
        XCTAssertTrue(coordinateDescription.contains("uncropped full-display"))
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

    // MARK: - draw_batch's flat per-item schema

    /// `draw_batch` publishes ONE flat property object covering every item
    /// type, built by a last-writer-wins merge. Four keys are claimed by more
    /// than one type, so that merge silently published a single type's wording
    /// as the whole truth -- adding shape properties made `x` read "rect
    /// only", which tells a model that an `image` or `text` item must not send
    /// `x` when both actually require it. Pin that every shared key names each
    /// item type that uses it, so a future item type cannot quietly narrow one
    /// of these descriptions again.
    func testBatchItemSharedPropertyDescriptionsNameEveryClaimingItemType() throws {
        let contributors = MCPToolCatalog.batchItemSharedKeyContributors
        // Derived, not hand-listed. The first version of this guard enumerated
        // x/y/width/height by hand and silently missed `opacity`, which image
        // and text both claim -- so an image item's opacity was documented as
        // "Text opacity; default 1." Deriving the set means a NEW collision
        // introduced by a future item type fails here instead of shipping a
        // schema that misdescribes somebody's required field.
        XCTAssertFalse(contributors.isEmpty, "expected at least one shared batch-item key")
        XCTAssertNotNil(contributors["opacity"], "opacity is claimed by image and text and must be treated as shared")
        for (key, claimingTypes) in contributors {
            let property = try XCTUnwrap(MCPToolCatalog.batchItemProperties[key] as? [String: Any],
                                         "draw_batch item schema is missing '\(key)'")
            let description = try XCTUnwrap(property["description"] as? String,
                                            "draw_batch item property '\(key)' has no description")
            for type in claimingTypes {
                XCTAssertTrue(description.contains(type),
                              "draw_batch item '\(key)' is claimed by \(claimingTypes) but its description never mentions '\(type)': \(description)")
            }
        }
    }

    /// The image-opacity regression specifically: a fully transparent image is
    /// REJECTED by the loader, so publishing text's wording for image items
    /// hid a real constraint from the caller.
    func testBatchItemOpacityDescriptionCoversImageRejectionAndTextSemantics() throws {
        let property = try XCTUnwrap(MCPToolCatalog.batchItemProperties["opacity"] as? [String: Any])
        let description = try XCTUnwrap(property["description"] as? String)
        XCTAssertTrue(description.contains("image"))
        XCTAssertTrue(description.contains("text"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("transparent"),
                      "image items reject a fully transparent raster; the shared description must say so")
        XCTAssertNotEqual(description, "Text opacity; default 1.")
    }

    func testBatchItemSchemaCarriesEveryItemTypesOwnKeys() {
        for key in ["path_data", "image_path", "text", "font_size", "shape", "center_x", "center_y", "radius", "radius_x", "radius_y"] {
            XCTAssertNotNil(MCPToolCatalog.batchItemProperties[key],
                            "draw_batch item schema lost '\(key)' in the property merge")
        }
        let type = MCPToolCatalog.batchItemProperties["type"] as? [String: Any]
        XCTAssertEqual(type?["enum"] as? [String], ["path", "image", "text", "shape"])
    }

    // MARK: - duration_seconds removal (annotations never expire)
    //
    // Three OTHER timers legitimately remain in this codebase and are
    // explicitly out of scope for this change: suspend_annotations /
    // resume_annotations' click-workaround lease (1-60s, "expires
    // automatically" if not released, with a 120-second cleanup tombstone)
    // and set_capture_visible's five-minute debug-mode auto-revert. Neither
    // one hides or deletes an ANNOTATION -- the lease only orders overlay
    // windows out and back, and the capture flag only toggles a debug
    // filter -- so their tool descriptions are deliberately excluded from
    // the wording check below, which is only about annotation lifetime.
    private static let toolsWithUnrelatedExpiryWording: Set<String> = [
        "suspend_annotations", "resume_annotations", "set_capture_visible"
    ]

    /// `duration_seconds` was deleted from the tool surface entirely: an
    /// annotation now persists until the AI or the user explicitly clears it
    /// (see `Annotation`'s type comment). This walks every tool's schema --
    /// including `draw_batch`'s flat per-item properties, which are built by
    /// their own separate `merged(...)` call and so could silently keep a
    /// stale copy even after every top-level draw_* tool lost its own -- and
    /// asserts the key is gone everywhere, not just in the couple of spots a
    /// manual check would think to look.
    func testNoToolAdvertisesDurationSecondsAnywhereInItsSchema() {
        for tool in MCPToolCatalog.tools {
            let name = tool["name"] as? String ?? "<unnamed>"
            XCTAssertNil(properties(tool)["duration_seconds"], "\(name) must not advertise duration_seconds")
        }
        XCTAssertNil(MCPToolCatalog.batchItemProperties["duration_seconds"],
                     "draw_batch's per-item schema must not advertise duration_seconds")
    }

    /// No tool description may still describe annotations as something that
    /// auto-clears, expires, or carries a TTL -- that mechanism was deleted
    /// from the store, so wording implying it survives would be a lie to the
    /// caller about what actually happens to their drawing.
    func testNoToolDescriptionStillAdvertisesAnnotationAutoClearOrTTLWording() {
        let forbiddenSubstrings = ["duration_seconds", "auto-clear", "TTL"]
        for tool in MCPToolCatalog.tools {
            let name = tool["name"] as? String ?? "<unnamed>"
            guard !Self.toolsWithUnrelatedExpiryWording.contains(name) else { continue }
            let description = tool["description"] as? String ?? ""
            for term in forbiddenSubstrings {
                XCTAssertFalse(description.localizedCaseInsensitiveContains(term),
                               "\(name)'s description still mentions '\(term)': \(description)")
            }
            // Catches expire/expires/expiry/expired in one check rather than
            // hand-listing every inflection.
            XCTAssertFalse(description.localizedCaseInsensitiveContains("expir"),
                           "\(name)'s description still mentions annotation expiry: \(description)")
        }
    }
}
