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
            "get_screens", "get_overlay_state", "get_accessibility_status", "register_screenshot_space", "calibrate_screenshot_space", "draw_path", "draw_shape", "draw_image", "draw_text", "highlight_element", "draw_batch", "update_annotation", "suspend_annotations", "resume_annotations", "clear", "list_annotations",
            "verify_annotation", "verify_presentation", "get_annotation_bounds", "get_active_app", "set_capture_visible"
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

    // MARK: - screenshot_space (Phase B)

    /// `screenshot_space` must reach every `draw_*` tool (via
    /// `sharedDrawProperties`) AND `get_annotation_bounds` AND
    /// `verify_annotation` -- the exact set `PHASE_B_SPEC.md` names -- with
    /// the same `minLength`/`maxLength` bounds and description everywhere,
    /// so a caller cannot discover a narrower or differently-worded
    /// contract on one tool than another.
    func testScreenshotSpaceReachesEveryDrawToolPlusBoundsAndVerify() throws {
        for name in ["draw_path", "draw_shape", "draw_image", "draw_text", "draw_batch", "get_annotation_bounds", "verify_annotation"] {
            let property = try XCTUnwrap(properties(try XCTUnwrap(toolsByName[name], name))["screenshot_space"] as? [String: Any], "\(name) is missing screenshot_space")
            XCTAssertEqual(property["type"] as? String, "string", name)
            XCTAssertEqual(property["minLength"] as? Int, 1, name)
            XCTAssertEqual(property["maxLength"] as? Int, 64, name)
            let description = try XCTUnwrap(property["description"] as? String, name)
            XCTAssertTrue(description.contains("register_screenshot_space"), name)
            XCTAssertTrue(description.contains("calibrate_screenshot_space"), name)
            XCTAssertTrue(description.contains("REPLACES"), "\(name): screenshot_space must say it replaces coordinate_space/screenshot_width/screenshot_height/screen_id")
            XCTAssertTrue(description.contains("REJECTED"), "\(name): screenshot_space must say contradicting arguments are rejected, not reconciled")
        }
        // Not a batch-item key: screenshot_space is one per ANNOTATION (like
        // anchor/anchor_resize), never a per-item override inside draw_batch's
        // flat items schema.
        XCTAssertNil(MCPToolCatalog.batchItemProperties["screenshot_space"])
    }

    func testRegisterScreenshotSpaceToolSchema() throws {
        let tool = try XCTUnwrap(toolsByName["register_screenshot_space"])
        XCTAssertNil(inputSchema(tool)["required"], "register_screenshot_space must have no required array -- the handler enforces the exactly-one-source rule")
        let props = properties(tool)
        XCTAssertEqual((props["screen_id"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["screen_id"] as? [String: Any])?["maxLength"] as? Int, 128)
        XCTAssertEqual((props["screenshot_path"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["screenshot_width"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((props["screenshot_width"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((props["screenshot_height"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((props["screenshot_height"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual(inputSchema(tool)["additionalProperties"] as? Bool, false)

        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertTrue(description.contains("measured"))
        XCTAssertTrue(description.contains("declared"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("mutually exclusive") || description.contains("rejected"))
    }

    func testCalibrateScreenshotSpaceToolSchema() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        XCTAssertEqual(inputSchema(tool)["required"] as? [String], ["action"])
        let props = properties(tool)
        XCTAssertEqual((props["action"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["action"] as? [String: Any])?["enum"] as? [String], ["begin", "resolve", "cancel", "elements"])
        XCTAssertEqual((props["screen_id"] as? [String: Any])?["maxLength"] as? Int, 128)
        XCTAssertEqual((props["set_capture_visible"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual((props["calibration_id"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["observed_width"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((props["observed_width"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((props["observed_height"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((props["observed_height"] as? [String: Any])?["minimum"] as? Int, 1)

        let markers = try XCTUnwrap(props["markers"] as? [String: Any])
        XCTAssertEqual(markers["type"] as? String, "array")
        XCTAssertEqual(markers["maxItems"] as? Int, 4)
        // minItems == maxItems: see
        // testCalibrateScreenshotSpaceMarkersSchemaAndProseBothRequireAllFourMarkerLabels
        // for the defect an advertised minItems of 1 caused.
        XCTAssertEqual(markers["minItems"] as? Int, 4)
        let markerItem = try XCTUnwrap(markers["items"] as? [String: Any])
        XCTAssertEqual(markerItem["type"] as? String, "object")
        XCTAssertEqual(markerItem["required"] as? [String], ["label", "x", "y"])
        XCTAssertEqual(markerItem["additionalProperties"] as? Bool, false)
        let markerProps = try XCTUnwrap(markerItem["properties"] as? [String: Any])
        XCTAssertEqual((markerProps["label"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((markerProps["x"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((markerProps["y"] as? [String: Any])?["type"] as? String, "number")

        // The description is the only place the three-step handshake is
        // documented (there is no separate human doc an agent reads before
        // calling this), so it must be executable from the catalog alone:
        // name every action, explain why the tool exists at all, and
        // state the calibration solver's known blind spot plus the stronger
        // alternative.
        let description = try XCTUnwrap(tool["description"] as? String)
        for action in ["begin", "resolve", "cancel", "elements"] {
            XCTAssertTrue(description.contains("action='\(action)'"), "calibrate_screenshot_space description must document action='\(action)'")
        }
        XCTAssertTrue(description.localizedCaseInsensitiveContains("cannot"), "must state the tool exists because a caller generally cannot learn its screenshot's true pixel dimensions any other way")
        XCTAssertTrue(description.contains("register_screenshot_space"), "must name register_screenshot_space with screenshot_path as strictly stronger when a file is available")
        XCTAssertTrue(description.localizedCaseInsensitiveContains("cross-check"), "must describe markers + observed_* as a cross-check per the Phase B addendum")
    }

    /// `capture_source='none'` and `get_annotation_bounds` are, per
    /// PHASE_B_SPEC.md, "the single most important discoverability fix in
    /// the change": a caller denied Screen Recording permission must find
    /// the permission-free path from the ONE description it is already
    /// reading (verify_annotation's), not only from a separate tool's own
    /// listing.
    func testCaptureSourceNoneAndGetAnnotationBoundsPermissionFreePathIsDiscoverable() throws {
        let verify = try XCTUnwrap(toolsByName["verify_annotation"])
        let toolDescription = try XCTUnwrap(verify["description"] as? String)
        XCTAssertTrue(toolDescription.contains("capture_source='none'"))
        XCTAssertTrue(toolDescription.contains("get_annotation_bounds"))
        XCTAssertTrue(toolDescription.localizedCaseInsensitiveContains("no screen recording") || toolDescription.contains("NO Screen Recording"))

        let captureSource = try XCTUnwrap(properties(verify)["capture_source"] as? [String: Any])
        let captureSourceDescription = try XCTUnwrap(captureSource["description"] as? String)
        XCTAssertTrue(captureSourceDescription.contains("none"))
        XCTAssertTrue(captureSourceDescription.localizedCaseInsensitiveContains("permission"))
        XCTAssertTrue(captureSourceDescription.contains("get_annotation_bounds"))
    }

    /// `expect_element`/`expect_window`/`target_bounds_screenshot_px` on
    /// `verify_annotation`: exact shapes, and each names the permission it
    /// needs (or explicitly needs none) so a caller never has to guess which
    /// one survives a denied grant.
    func testVerifyAnnotationExpectationSchemasAndPermissionWording() throws {
        let verify = properties(try XCTUnwrap(toolsByName["verify_annotation"]))

        let expectElement = try XCTUnwrap(verify["expect_element"] as? [String: Any])
        XCTAssertEqual(expectElement["type"] as? String, "object")
        XCTAssertEqual(expectElement["required"] as? [String], ["app", "label"])
        XCTAssertEqual(expectElement["additionalProperties"] as? Bool, false)
        let expectElementProps = try XCTUnwrap(expectElement["properties"] as? [String: Any])
        XCTAssertEqual((expectElementProps["app"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((expectElementProps["label"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((expectElementProps["role"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((expectElementProps["match"] as? [String: Any])?["enum"] as? [String], ["exact", "contains"])
        XCTAssertEqual((expectElementProps["occurrence"] as? [String: Any])?["minimum"] as? Int, 1)
        let expectElementDescription = try XCTUnwrap(expectElement["description"] as? String)
        XCTAssertTrue(expectElementDescription.localizedCaseInsensitiveContains("accessibility") || expectElementDescription.localizedCaseInsensitiveContains("ui automation"),
                      "expect_element must name the Accessibility/UI Automation grant it needs")

        let expectWindow = try XCTUnwrap(verify["expect_window"] as? [String: Any])
        XCTAssertEqual(expectWindow["type"] as? String, "object")
        XCTAssertEqual(expectWindow["required"] as? [String], ["app"])
        XCTAssertEqual(expectWindow["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set((expectWindow["properties"] as? [String: Any] ?? [:]).keys), ["app"])
        let expectWindowDescription = try XCTUnwrap(expectWindow["description"] as? String)
        XCTAssertTrue(expectWindowDescription.localizedCaseInsensitiveContains("no permission"),
                      "expect_window must state it needs no permission at all")

        let targetBounds = try XCTUnwrap(verify["target_bounds_screenshot_px"] as? [String: Any])
        XCTAssertEqual(targetBounds["type"] as? String, "object")
        XCTAssertEqual(targetBounds["required"] as? [String], ["x", "y", "width", "height"])
        XCTAssertEqual(targetBounds["additionalProperties"] as? Bool, false)
        let targetBoundsProps = try XCTUnwrap(targetBounds["properties"] as? [String: Any])
        XCTAssertEqual((targetBoundsProps["width"] as? [String: Any])?["minimum"] as? Int, 0)
        XCTAssertEqual((targetBoundsProps["height"] as? [String: Any])?["minimum"] as? Int, 0)

        // Reuse check: get_annotation_bounds' own target_bounds_screenshot_px
        // must be the field-for-field IDENTICAL shape, per PHASE_B_SPEC.md's
        // "reuse the identical shape get_annotation_bounds already declares".
        let boundsTargetBounds = try XCTUnwrap(properties(try XCTUnwrap(toolsByName["get_annotation_bounds"]))["target_bounds_screenshot_px"] as? [String: Any])
        XCTAssertEqual(boundsTargetBounds["required"] as? [String], ["x", "y", "width", "height"])
        XCTAssertEqual(boundsTargetBounds["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set((boundsTargetBounds["properties"] as? [String: Any] ?? [:]).keys), Set(targetBoundsProps.keys))
    }

    /// `anchor`/`anchor_resize` are advertised on every `draw_*` tool
    /// (top-level, via `sharedDrawProperties`) with the exact enum values and
    /// defaults MCP_SURFACE.md specifies, and are NOT advertised as a
    /// per-item key on `draw_batch`'s flat item schema -- an anchor is one
    /// per ANNOTATION, not per batch item, so a batch item cannot supply its
    /// own.
    func testEveryFreeDrawToolAdvertisesAnchorAndAnchorResize() throws {
        for name in ["draw_path", "draw_shape", "draw_image", "draw_text", "draw_batch"] {
            let props = properties(try XCTUnwrap(toolsByName[name], name))
            let anchor = try XCTUnwrap(props["anchor"] as? [String: Any], "\(name) is missing 'anchor'")
            XCTAssertEqual(anchor["type"] as? String, "string", name)
            XCTAssertEqual(anchor["enum"] as? [String], ["none", "window"], name)
            let anchorResize = try XCTUnwrap(props["anchor_resize"] as? [String: Any], "\(name) is missing 'anchor_resize'")
            XCTAssertEqual(anchorResize["type"] as? String, "string", name)
            XCTAssertEqual(anchorResize["enum"] as? [String], ["pin", "scale"], name)
        }
        let batchItemProperties = MCPToolCatalog.batchItemProperties
        XCTAssertNil(batchItemProperties["anchor"], "draw_batch items must not carry their own anchor -- anchoring is per annotation, not per item")
        XCTAssertNil(batchItemProperties["anchor_resize"])
    }

    /// Avoidance is deliberately opt-in and scoped to the common
    /// highlight-plus-label workflow: callers may ask text, shape, and an
    /// annotation-wide batch to avoid already-created annotations.  It is
    /// not a blanket stacking prohibition for every draw primitive, and a
    /// batch item cannot independently opt out of another item -- the batch
    /// has exactly one placement and one annotation ID.
    func testAvoidSchemaIsScopedToTextShapeAndTopLevelBatchOnly() throws {
        let supported = ["draw_text", "draw_shape", "draw_batch"]
        for name in supported {
            let avoid = try XCTUnwrap(
                properties(try XCTUnwrap(toolsByName[name], name))["avoid"] as? [String: Any],
                "\(name) is missing top-level avoid"
            )
            XCTAssertEqual(avoid["type"] as? String, "array", name)
            XCTAssertEqual(avoid["minItems"] as? Int, 1, name)
            XCTAssertEqual(avoid["maxItems"] as? Int, 32, name)
            XCTAssertEqual(avoid["uniqueItems"] as? Bool, true, name)
            let item = try XCTUnwrap(avoid["items"] as? [String: Any], name)
            XCTAssertEqual(item["type"] as? String, "string", name)
            XCTAssertEqual(item["minLength"] as? Int, 1, name)
            XCTAssertEqual(item["maxLength"] as? Int, 128, name)

            let description = (avoid["description"] as? String ?? "").lowercased()
            XCTAssertTrue(description.contains("draw-time"), "\(name): avoid must say it is evaluated only at draw time")
            XCTAssertTrue(description.contains("overlap"), "\(name): avoid must say it prevents overlap")
            XCTAssertTrue(description.contains("final placement"), "\(name): avoid must promise the resolved placement in its response")
        }

        for name in ["draw_path", "draw_image"] {
            XCTAssertNil(properties(try XCTUnwrap(toolsByName[name], name))["avoid"],
                         "\(name) must retain deliberate stacking without avoid")
        }

        let batchItemProperties = MCPToolCatalog.batchItemProperties
        XCTAssertNil(batchItemProperties["avoid"],
                     "draw_batch items must not have independent avoidance; it is an annotation-wide placement")
    }

    /// The catalog description guidance MCP_SURFACE.md specifies: what the
    /// value does, when to choose each `anchor_resize` policy, and that
    /// style dimensions stay backing pixels under both policies. Checked
    /// once against `draw_path`'s copy since `sharedDrawProperties` is one
    /// shared dictionary reused verbatim by all five tools.
    func testAnchorDescriptionsAnswerTheCatalogGuidanceQuestions() throws {
        let props = properties(try XCTUnwrap(toolsByName["draw_path"]))
        let anchorDescription = try XCTUnwrap(props["anchor"] as? [String: Any])["description"] as? String ?? ""
        XCTAssertTrue(anchorDescription.contains("moves"), "anchor description must say what happens when the window moves")
        XCTAssertTrue(anchorDescription.localizedCaseInsensitiveContains("sampled"),
                      "anchor description must state that tracking is sampled, not event-driven")
        XCTAssertTrue(anchorDescription.contains("trails"),
                      "anchor description must say the drawing trails the window while actively dragged")

        let resizeDescription = try XCTUnwrap(props["anchor_resize"] as? [String: Any])["description"] as? String ?? ""
        XCTAssertTrue(resizeDescription.contains("toolbar") || resizeDescription.contains("chrome") || resizeDescription.localizedCaseInsensitiveContains("chrome"),
                      "anchor_resize description must say when to choose pin (window chrome)")
        XCTAssertTrue(resizeDescription.localizedCaseInsensitiveContains("canvas") || resizeDescription.localizedCaseInsensitiveContains("content"),
                      "anchor_resize description must say when to choose scale (content that scales with the window)")
        XCTAssertTrue(resizeDescription.contains("stroke width") && resizeDescription.contains("font size") && resizeDescription.contains("padding"),
                      "anchor_resize description must say stroke width/font size/padding stay backing pixels under both policies")
    }

    func testRequiredArraysMatchTheThreeFreeDrawTools() {
        let expected: [String: [String]?] = [
            "get_screens": nil,
            "get_overlay_state": nil,
            "get_accessibility_status": nil,
            "register_screenshot_space": nil,
            "calibrate_screenshot_space": ["action"],
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
        XCTAssertEqual((verify["capture_source"] as? [String: Any])?["enum"] as? [String], ["chalkboard", "none"])
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

    /// PINS: `calibrate_screenshot_space`'s `markers` schema advertised
    /// `minItems: 1` and its description said "up to four" observations,
    /// while `ScreenshotCalibration.solve` has always required the complete
    /// TL/TR/BL/BR set and rejects anything less. An agent that could
    /// confidently read only two crosshairs did the documented thing, sent
    /// two, and was rejected -- and that rejection is DESTRUCTIVE: it lands
    /// after `handleCalibrateScreenshotSpaceResolve` consumed the session,
    /// so the fiducials it is telling the agent to re-measure have already
    /// been cleared and only a fresh `action="begin"` can bring them back.
    /// The advertised arity must therefore equal the enforced one, in the
    /// schema AND in the prose an agent reads before it ever sees the
    /// schema.
    func testCalibrateScreenshotSpaceMarkersSchemaAndProseBothRequireAllFourMarkerLabels() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        let markers = try XCTUnwrap(properties(tool)["markers"] as? [String: Any])

        let minItems = try XCTUnwrap(markers["minItems"] as? Int)
        let maxItems = try XCTUnwrap(markers["maxItems"] as? Int)
        XCTAssertEqual(minItems, 4, "markers must advertise the arity the solver enforces: all four of TL/TR/BL/BR")
        XCTAssertEqual(minItems, maxItems, "markers is an exactly-four array; a minItems below maxItems advertises a partial set the solver rejects")

        // The prose is what an agent reads when deciding what to send, so it
        // must carry the requirement on its own rather than leaning on the
        // schema's numbers.
        let markerDescription = try XCTUnwrap(markers["description"] as? String)
        XCTAssertTrue(markerDescription.contains("EXACTLY FOUR"),
                      "markers' description must state the exact count, not a maximum: \(markerDescription)")
        for label in ["TL", "TR", "BL", "BR"] {
            XCTAssertTrue(markerDescription.contains(label), "markers' description must name the \(label) label")
        }
        XCTAssertTrue(markerDescription.localizedCaseInsensitiveContains("single resolve call")
                        || markerDescription.localizedCaseInsensitiveContains("supplied together"),
                      "markers' description must say all four are reported together in one call: \(markerDescription)")
        XCTAssertTrue(markerDescription.contains("REJECTED") || markerDescription.contains("rejected"),
                      "markers' description must say a partial set is rejected rather than degraded: \(markerDescription)")

        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertFalse(description.localizedCaseInsensitiveContains("up to four"),
                       "the handshake prose must no longer advertise a partial marker set as legal")
        XCTAssertTrue(description.contains("ALL FOUR"),
                      "step 2 of the handshake prose must state that all four observations are mandatory")
        XCTAssertTrue(description.localizedCaseInsensitiveContains("never accumulated across calls")
                        || description.localizedCaseInsensitiveContains("not accumulated across calls"),
                      "the prose must say a later resolve cannot supply a marker an earlier one omitted")
    }

    /// PINS the two `calibrate_screenshot_space` promises that the
    /// reference-counted capture-visible restore made untrue.
    ///
    /// Capture-debug is ONE process-wide flag, so
    /// `ScreenshotCalibrationRegistry.claimCaptureBaseline`/
    /// `releaseCaptureBaseline` now let only the LAST outstanding
    /// calibration restore it -- a second handshake running on another
    /// display deliberately keeps it on. The description's flat "records the
    /// PRIOR value so resolve/cancel restore it" and "the prior
    /// capture-visible value restored on EVERY resolve call" both promised
    /// an immediate restore that a concurrent calibration will not perform,
    /// which is exactly the wrong thing to tell an agent debugging a stuck
    /// orange menu-bar icon.
    func testCalibrateScreenshotSpaceDescribesTheCaptureVisibleRestoreAsReferenceCounted() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        let description = try XCTUnwrap(tool["description"] as? String)

        XCTAssertFalse(description.contains("records the PRIOR value so resolve/cancel restore it"),
                       "begin must not promise an unconditional per-session restore")
        XCTAssertFalse(description.contains("the prior capture-visible value restored on EVERY resolve call"),
                       "resolve must not promise an unconditional restore it may deliberately skip")
        XCTAssertTrue(description.contains("LAST outstanding calibration"),
                      "the prose must say the restore happens when the last outstanding calibration ends")
        XCTAssertTrue(description.contains("last-one-out"),
                      "resolve and cancel must both point at the same last-one-out rule")

        // Clearing the fiducials, unlike restoring the flag, IS
        // unconditional on every resolve -- the two promises must stay
        // distinguishable in the prose rather than being merged back into
        // one sentence.
        XCTAssertTrue(description.contains("EVERY resolve call clears this calibration's fiducials"),
                      "resolve must still promise the fiducials are cleared even when it rejects")

        let setCaptureVisible = try XCTUnwrap(properties(tool)["set_capture_visible"] as? [String: Any])
        let captureDescription = try XCTUnwrap(setCaptureVisible["description"] as? String)
        XCTAssertFalse(captureDescription.contains("records the PRIOR value so resolve/cancel restore it"),
                       "set_capture_visible's own description must not repeat the retracted promise")
        XCTAssertTrue(captureDescription.contains("LAST outstanding calibration"),
                      "set_capture_visible's description must describe the same reference-counted restore: \(captureDescription)")
        XCTAssertTrue(captureDescription.contains("auto-revert to OFF") || captureDescription.contains("auto-reverts to OFF"),
                      "the five-minute auto-revert goes to OFF, not back to the recorded value")
    }

    /// PINS a name mismatch an agent copies straight out of the response:
    /// `begin` returns the id under the key `calibrationId`, but `resolve`/
    /// `cancel` take it as the argument `calibration_id`, and every tool
    /// schema in this catalog sets `additionalProperties: false`, so passing
    /// the response spelling back is rejected as an unknown argument rather
    /// than accepted as an alias. The description said only "Returns
    /// calibration_id", which names the argument spelling for a key that is
    /// not spelled that way on the wire.
    func testCalibrateScreenshotSpaceDistinguishesTheResponseIdKeyFromTheArgumentName() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertTrue(description.contains("calibrationId"),
                      "the prose must name the response's own spelling of the id")
        XCTAssertTrue(description.contains("calibration_id ARGUMENT"),
                      "the prose must say which spelling goes back in as an argument")
        XCTAssertEqual(inputSchema(tool)["additionalProperties"] as? Bool, false,
                       "this is only worth documenting because the camelCase spelling is actually rejected")
        XCTAssertNil(properties(tool)["calibrationId"],
                     "calibrationId must not exist as an argument alias -- the description promises it is rejected")
    }

    // MARK: - action="elements" (element-anchored calibration)

    /// PINS the advertised arity and per-element shape of the ELEMENT route.
    ///
    /// The arity lesson of
    /// `testCalibrateScreenshotSpaceMarkersSchemaAndProseBothRequireAllFourMarkerLabels`
    /// cuts both ways: `markers` was advertised looser than the solver
    /// accepted, and an agent that believed the schema was rejected. Here the
    /// risk is the mirror image -- the prose asks for THREE OR MORE points
    /// while `ScreenshotCalibration.solveCorrespondences` genuinely solves
    /// from two, so advertising `minItems: 3` would reject calls the solver
    /// would have answered, and an agent that can confidently identify only
    /// two elements would be pushed back to a `declared` space (a bare
    /// assertion) for no reason. The "3 is much better" argument therefore
    /// lives in prose, which is the only place a preference can live at all.
    ///
    /// `minItems` is now 1, not 2, and that number is load-bearing: a
    /// BOUNDS-observed element carries TWO correspondences (its resolved
    /// rect's top-left and bottom-right corners), so ONE element is a
    /// complete, gate-passing calibration for an app that exposes nothing
    /// but its own window -- the Shadow PC remote-desktop client exposed
    /// exactly one labelled element, `'Shadow PC - Display' [AXWindow]`.
    /// Advertising `minItems: 2` would reject that call outright and send
    /// the only app class that NEEDS this route back to a `declared` space.
    ///
    /// `required` is `["label"]` alone for the complementary reason: JSON
    /// Schema cannot express "exactly one of {observed_x, observed_y} or
    /// {observed_left, observed_top, observed_right, observed_bottom}", and
    /// advertising a requirement the handler does not enforce is the same
    /// defect as advertising an arity the solver does not accept -- here it
    /// would reject every bounds observation before the handler ever saw it.
    ///
    /// `additionalProperties: false` on the item matters for the same reason
    /// it does tool-wide: a caller that spells the observation `x`/`y` (as
    /// the marker route does) must be told so, not have its observed centre
    /// silently dropped and the element solved against nothing.
    func testCalibrateScreenshotSpaceElementsSchemaPinsTheArityAndPerElementShape() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        let props = properties(tool)

        XCTAssertEqual((props["app"] as? [String: Any])?["type"] as? String, "string",
                       "the element route needs an app to resolve elements in")

        let elements = try XCTUnwrap(props["elements"] as? [String: Any])
        XCTAssertEqual(elements["type"] as? String, "array")
        XCTAssertEqual(elements["minItems"] as? Int, 1,
                       "minItems must equal the minimum the solver actually accepts -- one bounds-observed element is two points -- not the count the prose recommends")
        XCTAssertEqual(elements["maxItems"] as? Int, 8)

        let item = try XCTUnwrap(elements["items"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "object")
        XCTAssertEqual(item["required"] as? [String], ["label"],
                       "only the label is unconditionally required; requiring observed_x/observed_y would reject every bounds observation in the schema, before the handler could explain anything")
        XCTAssertEqual(item["additionalProperties"] as? Bool, false,
                       "a misspelled observation key must be rejected, never silently dropped")
        let itemProps = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual((itemProps["label"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((itemProps["role"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((itemProps["match"] as? [String: Any])?["enum"] as? [String], ["exact", "contains"])
        XCTAssertEqual((itemProps["occurrence"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((itemProps["occurrence"] as? [String: Any])?["minimum"] as? Int, 1)
        XCTAssertEqual((itemProps["observed_x"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((itemProps["observed_y"] as? [String: Any])?["type"] as? String, "number")
        for key in ["observed_left", "observed_top", "observed_right", "observed_bottom"] {
            XCTAssertEqual((itemProps[key] as? [String: Any])?["type"] as? String, "number",
                           "\(key) must be advertised: it is the only observation form a window-only app can supply")
        }

        // The observation fields must say WHOSE pixels they are in. A caller
        // that reports the display's coordinates instead of its own image's
        // would hand the solver two identical spaces and calibrate 1.0.
        for key in ["observed_x", "observed_y"] {
            let description = try XCTUnwrap((itemProps[key] as? [String: Any])?["description"] as? String, key)
            XCTAssertTrue(description.contains("CENTRE"), "\(key) must ask for the element's centre: \(description)")
        }
        let observedX = try XCTUnwrap((itemProps["observed_x"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(observedX.contains("YOUR OWN screenshot's pixels"),
                      "observed_x must say the coordinate is in the caller's own image, not the display: \(observedX)")
    }

    /// PINS the BOUNDS observation's per-property prose, which is the only
    /// thing standing between a caller and four numbers it can misread in
    /// four different ways.
    ///
    /// The schema deliberately cannot enforce any of this (all four fields
    /// are optional so that a CENTRE observation stays legal), so each
    /// description has to carry the rule itself: all four together or none,
    /// left/top smaller than right/bottom, the caller's OWN image's pixels
    /// rather than the display's, and -- the point of the whole feature --
    /// that ONE bounds-observed element calibrates on its own where one
    /// centre-observed element does not. A caller that reads only
    /// `observed_left` must come away knowing all four of those.
    func testCalibrateScreenshotSpaceBoundsObservationPropertiesExplainTheAllFourRuleAndTheirOwnAxisOrder() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        let itemProps = try XCTUnwrap(((properties(tool)["elements"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])

        for key in ["observed_left", "observed_top", "observed_right", "observed_bottom"] {
            let description = try XCTUnwrap((itemProps[key] as? [String: Any])?["description"] as? String, key)
            XCTAssertTrue(description.contains("YOUR OWN screenshot's pixels"),
                          "\(key) must say whose pixels it is measured in: \(description)")
            XCTAssertTrue(description.contains("observed_left") && description.contains("observed_top")
                            && description.contains("observed_right") && description.contains("observed_bottom"),
                          "\(key) must name all four fields, because they are supplied together or not at all: \(description)")
        }

        // Axis order, stated per field rather than left to be inferred: an
        // inverted or zero-area box is rejected, never silently normalised,
        // so the caller has to be told which end is which BEFORE it sends.
        let left = try XCTUnwrap((itemProps["observed_left"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(left.contains("SMALLER than observed_right"), "observed_left must state the ordering: \(left)")
        let top = try XCTUnwrap((itemProps["observed_top"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(top.contains("SMALLER than observed_bottom"), "observed_top must state the ordering: \(top)")
        let right = try XCTUnwrap((itemProps["observed_right"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(right.contains("LARGER than observed_left"), "observed_right must state the ordering: \(right)")
        let bottom = try XCTUnwrap((itemProps["observed_bottom"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(bottom.contains("LARGER than observed_top"), "observed_bottom must state the ordering: \(bottom)")

        // The headline fact, on the first bounds field a caller reads.
        XCTAssertTrue(left.contains("TWO points"),
                      "observed_left must say a bounds observation is two points, which is why one element suffices: \(left)")
        XCTAssertTrue(left.contains("SINGLE bounds-observed element is a complete calibration"),
                      "observed_left must say one bounds-observed element calibrates on its own: \(left)")

        // And the mirror warning on the centre form, so an agent that picks
        // the wrong one for a window-only app learns it here rather than
        // from a rejection.
        let observedX = try XCTUnwrap((itemProps["observed_x"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(observedX.contains("ONE point"),
                      "observed_x must say a centre observation is one point, so it cannot calibrate alone: \(observedX)")
        XCTAssertTrue(observedX.contains("observed_left"),
                      "observed_x must name the bounds alternative it is exclusive with: \(observedX)")
    }

    /// PINS the discoverability property the bounds form was added for: an
    /// agent looking at an app whose ONLY resolvable Accessibility element is
    /// its own window must be able to work out FROM THE CATALOG ALONE that
    /// it should pass that window as a single bounds-observed fiducial.
    ///
    /// The field failure: driving DaVinci Resolve inside the Shadow PC
    /// remote-desktop client, the whole application exposed one labelled
    /// element -- the window, `'Shadow PC - Display' [AXWindow]`. The old
    /// description's advice ("pick 3 or more widely separated elements") is
    /// unsatisfiable there, and an agent that reads it as the only shape of
    /// call keeps hunting for a second fiducial that does not exist, then
    /// falls back to a `declared` space: a bare assertion, for an app whose
    /// geometry was perfectly measurable. So the description must BRANCH,
    /// and must name the app class in terms an agent can match against what
    /// it is looking at -- a remote-desktop client, a media player, a
    /// canvas/video surface -- rather than describing the condition only in
    /// the abstract.
    func testCalibrateScreenshotSpaceDescriptionSendsAWindowOnlyAppToOneBoundsObservedFiducial() throws {
        let description = try XCTUnwrap(toolsByName["calibrate_screenshot_space"]?["description"] as? String)

        // The branch itself: the 3-or-more advice must now be scoped to the
        // apps it is true for, instead of reading as the only shape of call.
        XCTAssertTrue(description.contains("APPS WITH NAMEABLE INNER CONTROLS"),
                      "the 3-or-more advice must be scoped to apps that actually have inner controls")
        XCTAssertTrue(description.contains("APPS THAT EXPOSE NOTHING BUT THEIR OWN WINDOW"),
                      "the description must give the window-only app its own branch")

        // The app class, in matchable terms.
        for symptom in ["remote-desktop", "media player", "canvas/video surface"] {
            XCTAssertTrue(description.contains(symptom),
                          "the description must name '\(symptom)' so an agent can match it against what it is looking at")
        }

        // The instruction, concrete enough to execute: which argument, how
        // many elements, and why one is enough.
        XCTAssertTrue(description.contains("observed_left/observed_top/observed_right/observed_bottom"),
                      "the description must name the four bounds arguments by their exact spelling")
        XCTAssertTrue(description.contains("SINGLE element observed by BOUNDS"),
                      "the description must say to pass that one window as a single bounds-observed element")
        XCTAssertTrue(description.contains("a rect is TWO points"),
                      "the description must explain why one element is sufficient, rather than asserting it")
        XCTAssertTrue(description.contains("ONE BOUNDS-OBSERVED ELEMENT IS A COMPLETE CALIBRATION ON ITS OWN"),
                      "step 4 must state the sufficiency claim where an agent reading the route's mechanics will hit it")
        XCTAssertTrue(description.contains("not a degraded fallback"),
                      "the description must say this is the intended call for those apps, so an agent does not keep hunting for a second fiducial")

        // The gate still applies to the single window -- it passes it
        // comfortably, which is a reason, not a loophole.
        XCTAssertTrue(description.contains("25% baseline gate is cleared comfortably"),
                      "the window branch must say the baseline gate still applies and why a window clears it")

        // The elements argument's own prose must carry the same branch: it
        // is what an agent reads while assembling the array.
        let elements = try XCTUnwrap((properties(try XCTUnwrap(toolsByName["calibrate_screenshot_space"]))["elements"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(elements.contains("1-8"), "elements must advertise the arity its schema now allows: \(elements)")
        XCTAssertTrue(elements.contains("TWO POINTS, NOT TWO ELEMENTS"),
                      "elements must state the real requirement, which is points rather than elements: \(elements)")
        XCTAssertTrue(elements.contains("NOTHING BUT ITS OWN WINDOW"),
                      "elements must name the window-only case it is now legal to call with one entry: \(elements)")
    }

    /// PINS the accuracy caveat that makes a single-window calibration
    /// trustworthy, and the diagnosis that makes its rejection actionable.
    ///
    /// The misreading this exists to prevent is the natural one: an agent
    /// calibrating from a remote-desktop window measures the VIDEO SURFACE
    /// it actually cares about -- the content area -- and so omits the title
    /// bar from the top edge. On a 3024x1964 display with a 2000x1200 window
    /// captured at exactly 0.5x, dropping a ~28 px title bar gives a y-scale
    /// of 0.48833 against an x-scale of 0.5 and an origin residual of 14.58
    /// against a 9.59 tolerance, so the EXISTING origin-residual check
    /// rejects the call instead of registering a space whose every vertical
    /// coordinate is ~2% short. That is the good outcome -- but only for a
    /// caller who can read the rejection. The description must therefore say
    /// both halves: measure the FRAME, and a residual rejection here means
    /// you probably measured the content area.
    func testCalibrateScreenshotSpaceDescriptionCarriesTheWindowFrameAccuracyCaveat() throws {
        let description = try XCTUnwrap(toolsByName["calibrate_screenshot_space"]?["description"] as? String)
        XCTAssertTrue(description.contains(MCPToolCatalog.calibrationWindowFrameCaveat),
                      "the tool description must carry the platform-split window-frame caveat verbatim, not a paraphrase of it")

        let caveat = MCPToolCatalog.calibrationWindowFrameCaveat
        XCTAssertTrue(caveat.contains("ORIGIN-RESIDUAL"),
                      "the caveat must name the check that catches the mistake, so a rejection there is readable: \(caveat)")
        XCTAssertTrue(caveat.contains("registers NOTHING rather than mis-scaling the space"),
                      "the caveat must promise rejection instead of a silently mis-scaled space: \(caveat)")
        XCTAssertTrue(caveat.contains("ONE axis only"),
                      "the caveat must explain why the mistake is detectable at all -- it shortens one axis, not both: \(caveat)")

        // Platform-split for the same reason every other permission/API
        // sentence in this catalog is: the rect has a different name and a
        // different pair of included/excluded edges on each platform, and
        // naming the wrong one tells the caller to measure the wrong box.
        #if os(macOS)
        XCTAssertTrue(caveat.contains("ACCESSIBILITY FRAME"), "macOS prose must name the Accessibility frame: \(caveat)")
        XCTAssertTrue(caveat.contains("INCLUDES the title bar") && caveat.contains("EXCLUDES the drop shadow"),
                      "macOS prose must state both edges of the frame convention: \(caveat)")
        XCTAssertTrue(caveat.contains("not the bounding box of the content area inside it"),
                      "macOS prose must rule out the content area explicitly: \(caveat)")
        XCTAssertTrue(caveat.contains("I probably measured the content area"),
                      "macOS prose must give the residual rejection its diagnosis: \(caveat)")
        #elseif os(Windows)
        XCTAssertTrue(caveat.contains("UI AUTOMATION BOUNDING RECTANGLE"),
                      "Windows prose must name UI Automation's rect, not a macOS Accessibility frame: \(caveat)")
        XCTAssertTrue(caveat.contains("caption bar"), "Windows prose must name the caption bar: \(caveat)")
        XCTAssertTrue(caveat.contains("not the bounding box of the client area inside it"),
                      "Windows prose must rule out the client area explicitly: \(caveat)")
        XCTAssertTrue(caveat.contains("I probably measured the client area"),
                      "Windows prose must give the residual rejection its diagnosis: \(caveat)")
        #endif
    }

    /// PINS the discoverability property this route exists for: an agent
    /// whose screenshots never show Chalkboard's fiducials must be able to
    /// tell FROM THE CATALOG ALONE that this is the route to take, and why.
    ///
    /// The field failure behind it: a screen-control MCP tool composited
    /// only the windows of the applications IT had been granted, so
    /// Chalkboard's overlay never appeared no matter what
    /// `set_capture_visible` did -- that filtering lives inside the capture
    /// tool, above the window-sharing flag Chalkboard can toggle -- and the
    /// same tool returned its screenshots as inline image data with no file
    /// path, closing `register_screenshot_space`'s `screenshot_path` route
    /// too. Both measurement routes shut at once leaves `declared`, a bare
    /// assertion, as the only provenance available. If this description
    /// fails to name the symptom ("screenshots ARE of this display -- menu
    /// bar and Dock visible -- yet the fiducials are not"), an agent hitting
    /// exactly that wall re-runs `begin` with `set_capture_visible` toggled
    /// and never discovers the route that would have worked, so these
    /// assertions are the feature's actual delivery mechanism rather than
    /// wording taste.
    func testCalibrateScreenshotSpaceElementRouteIsChoosableFromTheCatalogAlone() throws {
        let tool = try XCTUnwrap(toolsByName["calibrate_screenshot_space"])
        let description = try XCTUnwrap(tool["description"] as? String)

        // The symptom that selects this route, in the agent's own terms.
        XCTAssertTrue(description.contains("menu bar") && description.contains("Dock"),
                      "the prose must name the evidence that the screenshots really are of THIS display")
        XCTAssertTrue(description.localizedCaseInsensitiveContains("no matter what set_capture_visible does"),
                      "the prose must say the capture tool's own filtering is above set_capture_visible's reach")
        XCTAssertTrue(description.contains("NO Chalkboard pixels"),
                      "the prose must say this route needs none of Chalkboard's own pixels to be visible")

        // The baseline gate, stated as the concrete number the solver
        // enforces plus the reason it exists.
        XCTAssertTrue(description.contains("PICK 3 OR MORE ELEMENTS"),
                      "the prose must still ask for three or more elements where the app has them, which no schema number can say")
        XCTAssertTrue(description.contains("25%"),
                      "the prose must state the baseline gate in the same terms the rejection does")
        XCTAssertTrue(description.contains("REJECTED"),
                      "the prose must say two adjacent elements are rejected, not silently solved")

        // The honest limits.
        XCTAssertTrue(description.localizedCaseInsensitiveContains("LESS precise"),
                      "the prose must admit reported element frames are less precise than a drawn crosshair")
        XCTAssertTrue(description.contains("register_screenshot_space with screenshot_path is STRICTLY STRONGER"),
                      "the prose must still point at the measured-file route as the strongest option")

        // Permission, platform-split: naming the wrong one sends an agent to
        // grant a permission that has no bearing on whether this call works.
        #if os(macOS)
        XCTAssertTrue(description.contains("needs the macOS Accessibility grant -- NOT Screen Recording"),
                      "macOS prose must name Accessibility and rule out Screen Recording")
        #elseif os(Windows)
        XCTAssertTrue(description.contains("PERMISSION: none"),
                      "Windows prose must say there is no permission to grant")
        XCTAssertTrue(description.contains("UI Automation"),
                      "Windows prose must name UI Automation, not Accessibility")
        #endif

        // The element route's own `app` has no fallback, unlike
        // highlight_element's -- resolving a different app's hierarchy would
        // solve against points the caller never observed and register the
        // result as 'observed'.
        let appDescription = try XCTUnwrap((properties(tool)["app"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(appDescription.contains("REQUIRED there"), "app must be documented as required for this action: \(appDescription)")
        XCTAssertTrue(appDescription.contains("NO fallback"), "app must say it does NOT fall back to the active app: \(appDescription)")

        // Ambiguity is answered by the same resolver highlight_element uses,
        // so the elements prose must carry the SAME platform-accurate
        // promise -- a candidate list on macOS, a match count on Windows.
        let elementsDescription = try XCTUnwrap((properties(tool)["elements"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(elementsDescription.contains(MCPToolCatalog.highlightAmbiguityDescription),
                      "elements must reuse the platform-split ambiguity sentence rather than promising a list Windows cannot produce")
        XCTAssertTrue(elementsDescription.contains("SAME display"),
                      "elements must say every element has to resolve to one display")
        XCTAssertTrue(elementsDescription.contains("Nothing is registered"),
                      "elements must say a rejected call registers nothing")
    }

    /// PINS the arguments whose prose the second route made STALE. Each of
    /// these said "begin only" or "resolve/cancel only" when the tool had
    /// exactly one route, and each would now be read by an agent running the
    /// element route -- where `screen_id` has a DIFFERENT default (derived
    /// from the resolved elements, not main), where there is no calibration
    /// id at all, and where nothing is painted so capture-visible is never
    /// touched. A stale "only" here is not a wording nit: it tells an agent
    /// that the argument it needs does not apply to the call it is making.
    func testCalibrateScreenshotSpaceArgumentProseCoversTheElementRouteToo() throws {
        let props = properties(try XCTUnwrap(toolsByName["calibrate_screenshot_space"]))

        let screenID = try XCTUnwrap((props["screen_id"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(screenID.contains("elements"), "screen_id must no longer read 'begin only': \(screenID)")
        XCTAssertTrue(screenID.contains("DERIVES the display from the resolved elements"),
                      "screen_id must state the element route's different default: \(screenID)")

        let calibrationID = try XCTUnwrap((props["calibration_id"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(calibrationID.contains("stateless and single-shot"),
                      "calibration_id must say the element route issues no id: \(calibrationID)")

        let captureVisible = try XCTUnwrap((props["set_capture_visible"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(captureVisible.contains("paints nothing at all"),
                      "set_capture_visible must say the element route never touches the flag: \(captureVisible)")

        let action = try XCTUnwrap((props["action"] as? [String: Any])?["description"] as? String)
        XCTAssertFalse(action.contains("three-step handshake"),
                       "action can no longer describe the whole tool as one three-step handshake: \(action)")
        XCTAssertTrue(action.contains("nothing to cancel"),
                      "action must say the element route leaves nothing outstanding: \(action)")

        // The dead end the element route removes: `begin` used to tell an
        // agent whose fiducials never appear that only screenshot_path could
        // help -- which is unreachable for a capture tool that returns
        // inline image data with no file path.
        let description = try XCTUnwrap(toolsByName["calibrate_screenshot_space"]?["description"] as? String)
        XCTAssertFalse(description.contains("this handshake cannot work for it -- use register_screenshot_space with screenshot_path instead"),
                       "begin must no longer present screenshot_path as the ONLY escape from an invisible fiducial")
        XCTAssertTrue(description.contains("switch to action='elements' (step 4)"),
                      "begin must send an agent whose fiducials never appear to the route built for exactly that")

        // markers is the drawn route's argument, and it is what an agent
        // reads at the moment it discovers it cannot see a crosshair, so it
        // must distinguish "hard to read" (retake) from "absent" (retaking
        // is futile -- change routes).
        let markers = try XCTUnwrap((props["markers"] as? [String: Any])?["description"] as? String)
        XCTAssertTrue(markers.contains("not in your screenshot AT ALL"),
                      "markers must distinguish an unreadable crosshair from an absent one: \(markers)")
        XCTAssertTrue(markers.contains("action='elements'"),
                      "markers must name the route that works when no fiducial ever appears: \(markers)")

        // register_screenshot_space's own listing of the ways to get a space
        // is where a caller lands first; it must not still describe
        // calibrate_screenshot_space as only a fiducial handshake.
        let register = try XCTUnwrap(toolsByName["register_screenshot_space"]?["description"] as? String)
        XCTAssertTrue(register.contains("action='elements'"),
                      "register_screenshot_space must list the element route among the ways to get a space: \(register)")
    }

    /// PINS that `verify_annotation`'s `expect_element` and
    /// `calibrate_screenshot_space`'s per-element items publish ONE shared
    /// element-query shape rather than two hand-maintained copies.
    ///
    /// Both are answered by the same `AccessibilityElementResolver.resolve`
    /// call, so a copy that drifts -- `occurrence` missing on one, `match`
    /// accepting a different enum, `occurrence` documented as zero-based --
    /// makes a caller that pinned an ambiguous label on one tool pin the
    /// WRONG element on the other. On the calibration route specifically,
    /// the wrong element is a wrong TRUE point fed straight into the solve,
    /// producing a confidently wrong space with provenance 'observed'. This
    /// is the same argument `targetBoundsScreenshotPxShape` already carries.
    func testExpectElementAndCalibrationElementsPublishTheSameElementQueryShape() throws {
        let expect = try XCTUnwrap((properties(try XCTUnwrap(toolsByName["verify_annotation"]))["expect_element"] as? [String: Any])?["properties"] as? [String: Any])
        let elementsItem = try XCTUnwrap(((properties(try XCTUnwrap(toolsByName["calibrate_screenshot_space"]))["elements"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])

        for key in ["label", "role", "match", "occurrence"] {
            let left = try XCTUnwrap(expect[key] as? [String: Any], "expect_element is missing \(key)")
            let right = try XCTUnwrap(elementsItem[key] as? [String: Any], "calibrate_screenshot_space's elements item is missing \(key)")
            XCTAssertEqual(left["type"] as? String, right["type"] as? String, "\(key) type drifted between the two tools")
            XCTAssertEqual(left["description"] as? String, right["description"] as? String, "\(key) description drifted between the two tools")
            XCTAssertEqual(left["enum"] as? [String], right["enum"] as? [String], "\(key) enum drifted between the two tools")
            XCTAssertEqual(left["minimum"] as? Int, right["minimum"] as? Int, "\(key) minimum drifted between the two tools")
        }

        // The shape is the QUERY only: `app` is per-call on the calibration
        // route (one app owns every element in one screenshot), so it must
        // NOT ride along inside each element.
        XCTAssertNil(elementsItem["app"], "app is a top-level argument of the element route, not a per-element one")
        XCTAssertEqual(expect["app"] as? [String: Any] != nil, true, "expect_element still carries its own app")
    }
}
