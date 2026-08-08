import Foundation
import XCTest
@testable import AIChalkboardCore

/// `MCPArgument.double` and `DrawValidation`'s geometry/limit checks used to
/// be reachable only through `MCPServer.shared`, a singleton that writes real
/// JSON-RPC responses to real stdout and therefore cannot be driven from a
/// headless CI test -- so the real safety checks behind every `draw_*` tool
/// (rejecting `{"radius": true}`, rejecting a negative width, rejecting an
/// oversized path) had ZERO test coverage. Both types were pulled out
/// specifically to fix that: neither touches AppKit or `MCPServer.shared`, so
/// both can be exercised directly here.
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
        // rejecting a negative radius/width/height is DrawValidation's job,
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

    // MARK: - DrawValidation.positiveRadius

    func testPositiveRadiusAcceptsAnyValueGreaterThanZero() {
        XCTAssertNil(DrawValidation.positiveRadius(0.001))
        XCTAssertNil(DrawValidation.positiveRadius(40))
    }

    func testPositiveRadiusRejectsZeroAndNegativeValuesWithTheExactShippedMessage() {
        XCTAssertEqual(DrawValidation.positiveRadius(0), "radius must be > 0.")
        XCTAssertEqual(DrawValidation.positiveRadius(-1), "radius must be > 0.")
    }

    // MARK: - DrawValidation.positiveDimensions

    func testPositiveDimensionsAcceptsWidthAndHeightBothGreaterThanZero() {
        XCTAssertNil(DrawValidation.positiveDimensions(width: 1, height: 1))
        XCTAssertNil(DrawValidation.positiveDimensions(width: 200, height: 0.5))
    }

    func testPositiveDimensionsRejectsEitherSideBeingZeroOrNegativeWithTheExactShippedMessage() {
        XCTAssertEqual(DrawValidation.positiveDimensions(width: 0, height: 5), "width and height must both be > 0.")
        XCTAssertEqual(DrawValidation.positiveDimensions(width: 5, height: 0), "width and height must both be > 0.")
        XCTAssertEqual(DrawValidation.positiveDimensions(width: -1, height: -1), "width and height must both be > 0.")
    }

    // MARK: - DrawValidation.gridStep

    func testGridStepAcceptsTheMinimumItselfAndTheDefault() {
        // >= , not > -- the boundary value itself must be accepted.
        XCTAssertNil(DrawValidation.gridStep(DrawingDefaults.minGridStepPx))
        XCTAssertNil(DrawValidation.gridStep(DrawingDefaults.gridStepPx))
    }

    func testGridStepRejectsBelowTheMinimumWithTheExactShippedMessage() {
        XCTAssertEqual(
            DrawValidation.gridStep(DrawingDefaults.minGridStepPx - 0.5),
            "step_px must be >= \(DrawingDefaults.minGridStepPx) physical pixel(s); smaller values can make the grid renderer's line loop run effectively forever and wedge the main thread."
        )
    }

    // MARK: - DrawValidation.pathPointCount

    func testPathPointCountAcceptsAnythingUpToAndIncludingTheCap() {
        XCTAssertNil(DrawValidation.pathPointCount(2))
        XCTAssertNil(DrawValidation.pathPointCount(DrawingDefaults.maxPathPoints))
    }

    func testPathPointCountRejectsOneOverTheCapWithTheExactShippedMessage() {
        let overCount = DrawingDefaults.maxPathPoints + 1
        XCTAssertEqual(
            DrawValidation.pathPointCount(overCount),
            "'points' array resolved to \(overCount) valid point(s) after parsing, exceeding the \(DrawingDefaults.maxPathPoints)-point limit."
        )
    }
}
