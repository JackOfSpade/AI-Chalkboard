import Foundation
import XCTest
@testable import AIChalkboardCore

/// `MCPArgument.double` used to be reachable only through
/// `MCPServer.shared`, a singleton that writes real
/// JSON-RPC responses to real stdout and therefore cannot be driven from a
/// headless CI test. It is isolated so numeric coercion can be exercised here.
final class MCPArgumentValidationTests: XCTestCase {

    // MARK: - MCPArgument.double: values that must parse

    func testJSONNumbersParseAsDoubles() throws {
        // Round-tripped through JSONSerialization (not hand-built Swift
        // literals) so these are genuinely the NSNumber shapes a real
        // tools/call payload produces: an integer JSON literal and a
        // fractional one.
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"intValue": 42, "doubleValue": 3.14}
        """.utf8)) as! [String: Any]

        XCTAssertEqual(MCPArgument.double(json["intValue"]), 42.0)
        XCTAssertEqual(MCPArgument.double(json["doubleValue"])!, 3.14, accuracy: 1e-9)
    }

    func testNumericStringsParseAsDoubles() {
        XCTAssertEqual(MCPArgument.double("42"), 42.0)
        XCTAssertEqual(MCPArgument.double("3.14")!, 3.14, accuracy: 1e-9)
    }

    func testNegativeValuesParse() {
        // Numeric coercion is deliberately permissive about sign --
        // rejecting a semantically invalid negative dimension is the tool's job,
        // not MCPArgument.double's. A caller that needs "positive" has to
        // ask for it separately.
        XCTAssertEqual(MCPArgument.double(-5), -5.0)
        XCTAssertEqual(MCPArgument.double("-5.5")!, -5.5, accuracy: 1e-9)
    }

    func testZeroParses() {
        XCTAssertEqual(MCPArgument.double(0), 0.0)
        XCTAssertEqual(MCPArgument.double("0"), 0.0)
    }

    func testVeryLargeFiniteValuesParse() throws {
        // 1e308 is finite (Double.greatestFiniteMagnitude is ~1.8e308), so
        // this must NOT be rejected by the non-finite guard.
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"big": 1e308}
        """.utf8)) as! [String: Any]
        let parsed = MCPArgument.double(json["big"])
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.isFinite ?? false)
        XCTAssertEqual(parsed!, 1e308, accuracy: 1e298)

        XCTAssertEqual(MCPArgument.double("1e308"), 1e308)
    }

    // MARK: - MCPArgument.double: the CFBoolean coercion bug

    func testJSONBooleansAreRejectedRatherThanCoercedToOneOrZero() throws {
        // THE POINT OF THIS TEST: `value as? NSNumber` alone succeeds for a
        // JSON boolean, because JSON `true`/`false` bridges to NSNumber
        // (backed by CFBoolean) exactly like a real number does. Building
        // these inputs by hand as Swift `Bool` literals and casting them
        // would NOT reliably reproduce that bridging -- the whole bug this
        // guards against is specifically about how *JSONSerialization*
        // bridges a parsed JSON boolean, not about Swift's own Bool type.
        // So these values are round-tripped through the real JSON parser,
        // exactly like every `tools/call` argument is in production.
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"radius": true, "flag": false}
        """.utf8)) as! [String: Any]

        XCTAssertTrue(json["radius"] is NSNumber, "sanity check: JSONSerialization must bridge a JSON boolean to NSNumber for this test to be meaningful")

        // Before the CFBoolean check existed, this returned 1.0 instead of
        // nil -- i.e. `{"radius": true}` silently became a 1-pixel circle
        // instead of being rejected as the wrong argument type.
        XCTAssertNil(MCPArgument.double(json["radius"]),
                     "a JSON `true` must not coerce to 1.0 -- this is the exact CFBoolean coercion bug this type exists to fix")
        XCTAssertNil(MCPArgument.double(json["flag"]),
                     "a JSON `false` must not coerce to 0.0 either")
    }

    func testStrictBooleanAcceptsOnlyJSONBooleans() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"truth": true, "falsity": false, "one": 1, "zero": 0}
        """.utf8)) as! [String: Any]

        XCTAssertEqual(MCPArgument.bool(json["truth"]), true)
        XCTAssertEqual(MCPArgument.bool(json["falsity"]), false)
        XCTAssertNil(MCPArgument.bool(json["one"]), "JSON number 1 must not enable a boolean flag")
        XCTAssertNil(MCPArgument.bool(json["zero"]), "JSON number 0 must not disable a boolean flag")
        XCTAssertNil(MCPArgument.bool("true"))
    }

    // MARK: - MCPArgument.double: non-finite rejection

    func testNonFiniteStringSpellingsAreRejectedRegardlessOfCase() {
        for spelling in ["NaN", "nan", "NAN", "Infinity", "infinity", "INFINITY", "-inf", "-Inf", "inf", "Inf"] {
            XCTAssertNil(MCPArgument.double(spelling), "\"\(spelling)\" must be rejected, not silently parsed into a non-finite Double")
        }
    }

    func testAlreadyNonFiniteNumericValuesAreRejected() {
        // Not reachable through JSONSerialization (JSON has no NaN/Infinity
        // literal), but NSNumber.doubleValue can itself be non-finite if
        // something upstream ever constructs one directly -- the second
        // rejection in MCPArgument.double's doc comment exists for exactly
        // this case.
        XCTAssertNil(MCPArgument.double(NSNumber(value: Double.nan)))
        XCTAssertNil(MCPArgument.double(NSNumber(value: Double.infinity)))
        XCTAssertNil(MCPArgument.double(NSNumber(value: -Double.infinity)))
    }

    // MARK: - MCPArgument.double: everything else is rejected

    func testNonNumericStringsAreRejected() {
        XCTAssertNil(MCPArgument.double("hello"))
        XCTAssertNil(MCPArgument.double(""))
        XCTAssertNil(MCPArgument.double("12abc"))
    }

    func testNilArraysAndDictionariesAreRejected() {
        let value: Any? = nil
        XCTAssertNil(MCPArgument.double(value))
        XCTAssertNil(MCPArgument.double([1, 2, 3]))
        XCTAssertNil(MCPArgument.double(["x": 1, "y": 2]))
    }

    func testSuppliedInvalidDoubleIsNotConfusedWithAnOmittedOptionalArgument() {
        XCTAssertFalse(MCPArgument.hasInvalidSuppliedDouble([:], key: "opacity"))
        XCTAssertFalse(MCPArgument.hasInvalidSuppliedDouble(["opacity": 0.5], key: "opacity"))
        XCTAssertTrue(MCPArgument.hasInvalidSuppliedDouble(["opacity": true], key: "opacity"))
        XCTAssertTrue(MCPArgument.hasInvalidSuppliedDouble(["opacity": "not-a-number"], key: "opacity"))
        XCTAssertTrue(MCPArgument.hasInvalidSuppliedDouble(["opacity": NSNull()], key: "opacity"))
    }

    func testIntegerAcceptsOnlyWholeFiniteNumericValues() {
        XCTAssertEqual(MCPArgument.integer(3), 3)
        XCTAssertEqual(MCPArgument.integer("-2"), -2)
        XCTAssertNil(MCPArgument.integer(1.5))
        XCTAssertNil(MCPArgument.integer(true))
    }

    func testIntegerRejectsTheRoundedDoublePastIntMaximumWithoutTrapping() {
        // Double cannot represent Int.max. Its nearest value is 2^63, which
        // is outside Int's positive range and used to reach trapping Int(...).
        XCTAssertNil(MCPArgument.integer(Double(Int.max)))
        XCTAssertNil(MCPArgument.integer(Double(Int.min)), "floating integer spellings beyond 2^53 are ambiguous even when the rounded value happens to be representable")
    }

    func testIntegerPreservesExactIntegerBackedJSONAndRejectsAmbiguousFloatingSpellings() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"exact": 9007199254740993, "decimal": 9007199254740993.0, "scientific": 9.007199254740993e15}
        """.utf8)) as! [String: Any]

        XCTAssertEqual(MCPArgument.integer(json["exact"]), 9_007_199_254_740_993)
        XCTAssertNil(MCPArgument.integer(json["decimal"]))
        XCTAssertNil(MCPArgument.integer(json["scientific"]))
        XCTAssertNil(MCPArgument.integer("9007199254740993.0"))
        XCTAssertEqual(MCPArgument.integer("9007199254740993"), 9_007_199_254_740_993)
    }

    // MARK: - tools/call protocol boundary

    func testToolCallArgumentsMustBeAnObjectWhenPresent() {
        let malformed: [String: Any] = ["name": "clear", "arguments": 42]
        switch MCPProtocolValidation.toolCallParameters(malformed) {
        case .success:
            XCTFail("A numeric arguments value must not be treated as an empty object.")
        case .failure(let message):
            XCTAssertEqual(message, "tools/call arguments must be an object when supplied.")
        }

        let omitted: [String: Any] = ["name": "clear"]
        switch MCPProtocolValidation.toolCallParameters(omitted) {
        case .success(let params):
            XCTAssertNil(params["arguments"])
        case .failure(let message):
            XCTFail("Omitted arguments are valid: \(message)")
        }
    }

    func testToolCallParamsMustBeAnObject() {
        switch MCPProtocolValidation.toolCallParameters(["clear"]) {
        case .success:
            XCTFail("An array must not be accepted as tools/call params.")
        case .failure(let message):
            XCTAssertEqual(message, "tools/call params must be an object.")
        }
    }

    // MARK: - Catalog-derived strict argument boundary

    func testUnknownTopLevelArgumentIsRejectedBeforeDispatch() throws {
        let error = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "clear", args: ["annotation_iid": "mistyped"]
        ))
        XCTAssertTrue(error.contains("annotation_iid"))
        XCTAssertTrue(error.contains("annotation_id"))
    }

    func testUnknownDrawingArgumentIsRejectedInsteadOfFallingBackToDefaults() throws {
        let error = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "draw_path",
            args: ["path_data": "M 0 0 L 1 1", "coordinate_spce": "normalized"]
        ))
        XCTAssertTrue(error.contains("coordinate_spce"))
        XCTAssertTrue(error.contains("coordinate_space"))
    }

    func testRetiredDurationKeepsItsSpecificMigrationErrorAheadOfUnknownKeyValidation() throws {
        let error = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "draw_shape",
            args: ["duration_seconds": 1]
        ))
        XCTAssertTrue(error.contains("duration_seconds is no longer supported"))
        XCTAssertTrue(error.contains("Nothing was drawn"))
    }

    func testBatchItemsRejectCrossTypeAndUnknownArgumentsBeforeAnyItemIsLoaded() throws {
        let crossType = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "draw_batch",
            args: ["items": [["type": "path", "path_data": "M 0 0 L 1 1", "image_path": "/tmp/a.png"]]]
        ))
        XCTAssertTrue(crossType.contains("items[0]"))
        XCTAssertTrue(crossType.contains("image_path"))

        let typo = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "draw_batch",
            args: ["items": [["type": "shape", "shape": "circle", "center_x": 1, "center_y": 1, "radius": 1, "raduis": 1]]]
        ))
        XCTAssertTrue(typo.contains("raduis"))

        let duration = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "draw_batch",
            args: ["items": [["type": "text", "duration_seconds": 1]]]
        ))
        XCTAssertTrue(duration.contains("items[0]"))
        XCTAssertTrue(duration.contains("duration_seconds is no longer supported"))
    }

    // MARK: - Annotation avoidance catalog boundary

    /// The catalog validator is the strict protocol boundary: it verifies
    /// which tools/levels may name `avoid` and validates its inexpensive
    /// structure before any handler can load batch raster assets.
    func testAvoidIsAcceptedOnlyForItsThreeTopLevelDrawingTools() throws {
        for name in ["draw_text", "draw_shape", "draw_batch"] {
            XCTAssertNil(MCPToolCatalog.validateArguments(
                toolName: name, args: ["avoid": ["existing-highlight"]]
            ), "\(name) should accept top-level avoid before its handler validates geometry")
        }

        for name in ["draw_path", "draw_image"] {
            let error = try XCTUnwrap(MCPToolCatalog.validateArguments(
                toolName: name, args: ["avoid": ["existing-highlight"]]
            ))
            XCTAssertTrue(error.contains("avoid"), error)
        }

        let itemError = try XCTUnwrap(MCPToolCatalog.validateArguments(
            toolName: "draw_batch",
            args: ["items": [[
                "type": "text", "text": "Label", "x": 10, "y": 10,
                "font_size": 16, "avoid": ["existing-highlight"]
            ]]]
        ))
        XCTAssertTrue(itemError.contains("items[0]"), itemError)
        XCTAssertTrue(itemError.contains("avoid"), itemError)
    }

    func testMalformedAvoidIsRejectedAtCatalogBoundaryBeforeDispatch() throws {
        for name in ["draw_text", "draw_shape", "draw_batch"] {
            let wrongType = try XCTUnwrap(MCPToolCatalog.validateArguments(
                toolName: name, args: ["avoid": "existing-highlight"]
            ))
            XCTAssertTrue(wrongType.contains("array"), "\(name): \(wrongType)")

            let duplicate = try XCTUnwrap(MCPToolCatalog.validateArguments(
                toolName: name, args: ["avoid": ["same-id", " same-id "]]
            ))
            XCTAssertTrue(duplicate.contains("duplicate"), "\(name): \(duplicate)")
        }
    }

    // MARK: - Coordinate transform safety

    private func testScreen(width: Int = 3_024, height: Int = 1_964) -> ScreenInfo {
        ScreenInfo(id: "test-screen", index: 0, name: "Test", widthPx: width, heightPx: height,
                   widthPt: Double(width), heightPt: Double(height), backingScaleFactor: 1, isMain: true)
    }

    func testScreenshotSubnormalDimensionsAreRejectedBeforeTheyCreateInfiniteScale() {
        let request = DrawRequest(screen: testScreen())
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": Double.leastNonzeroMagnitude,
            "screenshot_height": 100
        ]) {
        case .success:
            XCTFail("A subnormal screenshot width must not create an infinite scale.")
        case .failure(let message):
            XCTAssertTrue(message.contains("integer pixel count"))
        }
    }

    func testScreenshotPixelsRejectFractionalDimensions() {
        let request = DrawRequest(screen: testScreen())
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 2048.5,
            "screenshot_height": 1330
        ]) {
        case .success:
            XCTFail("Pixel dimensions must be integers")
        case .failure(let message):
            XCTAssertTrue(message.contains("positive integer pixel count"))
        }
    }

    func testScreenshotPixelsAcceptUniformFullDisplayDownsamplingWithRounding() {
        let request = DrawRequest(screen: testScreen())
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 2048,
            "screenshot_height": 1330
        ]) {
        case .failure(let message):
            XCTFail("A uniformly downsampled full-display image should map safely: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 3_024.0 / 2_048.0, accuracy: 1e-12)
            XCTAssertEqual(transform.scaleY, 1_964.0 / 1_330.0, accuracy: 1e-12)
        }
    }

    func testScreenshotPixelsRejectFusionPanelCropInsteadOfStretchingIt() {
        let request = DrawRequest(screen: testScreen())
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 2600,
            "screenshot_height": 490
        ]) {
        case .success:
            XCTFail("A narrow panel crop must not be stretched across the full display")
        case .failure(let message):
            XCTAssertTrue(message.contains("cropped or window-only"))
        }
    }

    func testSafeCoordinateTransformRejectsPostTransformOverflow() throws {
        let transform = DrawRequest.CoordinateTransform(scaleX: Double.greatestFiniteMagnitude, scaleY: 1)
        XCTAssertNil(transform.transformedX(2))
        XCTAssertNil(transform.transformedPoint(x: 2, y: 1))

        let geometry = try SVGPathParser.parseGeometry("M2 0 L3 1")
        XCTAssertFalse(transform.canTransform(geometry))
    }

    func testHugeNormalizedGeometryIsRejectedForPathImageTextAndBatchCallers() throws {
        // All four free-draw parsers route their selected-space positions
        // through these same guarded transform methods. This locks the shared
        // boundary rather than duplicating four private-handler tests.
        let normalized = DrawRequest.CoordinateTransform(scaleX: 3_024, scaleY: 1_964, requiresUnitInterval: true)
        let huge = Double.greatestFiniteMagnitude
        XCTAssertNil(normalized.transformedPoint(x: huge, y: huge), "image/text positions")
        XCTAssertNil(normalized.transformedX(huge), "image width / path X")
        XCTAssertNil(normalized.transformedY(huge), "image height / path Y")
        let path = try SVGPathParser.parseGeometry("M 1e308 0 L 1e308 1")
        XCTAssertFalse(normalized.canTransform(path), "standalone and batch path items")
    }

    func testNormalizedCoordinatesAreStrictlyWithinTheDocumentedUnitInterval() {
        let normalized = DrawRequest.CoordinateTransform(scaleX: 3_024, scaleY: 1_964, requiresUnitInterval: true)
        XCTAssertNil(normalized.transformedX(-0.001))
        XCTAssertNil(normalized.transformedY(1.001))
        XCTAssertNotNil(normalized.transformedPoint(x: 0, y: 1))
    }

}
