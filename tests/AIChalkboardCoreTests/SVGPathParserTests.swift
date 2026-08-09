import CoreGraphics
import XCTest
@testable import AIChalkboardCore

final class SVGPathParserTests: XCTestCase {
    func testRendererFacingAPIProducesCoreGraphicsPathInSourceCoordinates() throws {
        let path = try SVGPathParser.parse("M10 20 L30 40")
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 10, y: 20, width: 20, height: 20))
    }

    func testMoveLineHorizontalVerticalAndClose() throws {
        let result = try SVGPathParser.parseGeometry("M 10 20 L 30 40 H 50 V 60 Z")
        XCTAssertEqual(result.elements, [
            .move(CGPoint(x: 10, y: 20)), .line(CGPoint(x: 30, y: 40)),
            .line(CGPoint(x: 50, y: 40)), .line(CGPoint(x: 50, y: 60)), .close
        ])
    }

    func testRelativeAndImplicitRepeatedCommands() throws {
        let result = try SVGPathParser.parseGeometry("m10,10 20,0 0,20 l5,-5 h10 v-10")
        XCTAssertEqual(result.elements, [
            .move(CGPoint(x: 10, y: 10)), .line(CGPoint(x: 30, y: 10)),
            .line(CGPoint(x: 30, y: 30)), .line(CGPoint(x: 35, y: 25)),
            .line(CGPoint(x: 45, y: 25)), .line(CGPoint(x: 45, y: 15))
        ])
    }

    func testCubicAndSmoothCubicReflectControlPoint() throws {
        let result = try SVGPathParser.parseGeometry("M0 0 C 10 0 10 10 20 10 S 30 20 40 0")
        XCTAssertEqual(result.elements[1], .cubic(control1: CGPoint(x: 10, y: 0), control2: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 10)))
        XCTAssertEqual(result.elements[2], .cubic(control1: CGPoint(x: 30, y: 10), control2: CGPoint(x: 30, y: 20), to: CGPoint(x: 40, y: 0)))
    }

    func testQuadraticAndSmoothQuadraticReflectControlPoint() throws {
        let result = try SVGPathParser.parseGeometry("M0 0 Q 10 20 20 0 T 40 0")
        XCTAssertEqual(result.elements[1], .quad(control: CGPoint(x: 10, y: 20), to: CGPoint(x: 20, y: 0)))
        XCTAssertEqual(result.elements[2], .quad(control: CGPoint(x: 30, y: -20), to: CGPoint(x: 40, y: 0)))
    }

    func testArcBecomesCubicAndFinishesAtEndpoint() throws {
        let result = try SVGPathParser.parseGeometry("M 0 0 A 50 50 0 0 1 100 0")
        XCTAssertEqual(result.elements.count, 3) // move + two <= 90 degree cubics
        guard case let .cubic(_, _, end) = result.elements.last else { return XCTFail("arc should produce a cubic") }
        XCTAssertEqual(end.x, 100, accuracy: 0.000_001)
        XCTAssertEqual(end.y, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(result.bounds.width, 99)
    }

    func testArcAllowsCompactFlags() throws {
        let result = try SVGPathParser.parseGeometry("M0 0 A50 50 0 01100 0")
        guard case let .cubic(_, _, end) = result.elements.last else { return XCTFail("arc should produce a cubic") }
        XCTAssertEqual(end, CGPoint(x: 100, y: 0))
    }

    func testRelativeRotatedLargeArcIsReducedToCubics() throws {
        let result = try SVGPathParser.parseGeometry("M0 0 a 30 20 45 1 0 60 0")
        XCTAssertGreaterThanOrEqual(result.elements.count, 3)
        guard case let .cubic(_, _, end) = result.elements.last else { return XCTFail("arc should produce cubic segments") }
        XCTAssertEqual(end.x, 60, accuracy: 0.000_001)
        XCTAssertEqual(end.y, 0, accuracy: 0.000_001)
    }

    func testMalformedAndNonFiniteInputIsRejected() {
        XCTAssertThrowsError(try SVGPathParser.parse("L 1 2"))
        XCTAssertThrowsError(try SVGPathParser.parse("M 0"))
        XCTAssertThrowsError(try SVGPathParser.parse("M 0 0 A 1 1 0 2 0 3 4"))
        XCTAssertThrowsError(try SVGPathParser.parse("M 1e999 0"))
        XCTAssertThrowsError(try SVGPathParser.parse("M 0 0 R 10 10"))
    }

    func testRelativeArithmeticOverflowIsRejectedBeforeCoreGraphics() {
        // Both literals are individually finite, but adding them for the
        // relative line would yield +infinity.  The parser must reject the
        // computed geometry rather than handing it to CGPath.
        XCTAssertThrowsError(try SVGPathParser.parse("M 1e308 0 l 1e308 0"))
    }

    func testHugeArcIntermediateOverflowIsRejected() {
        // Radius squaring overflows even though the endpoint itself is
        // finite.  This previously degraded into a normal line command.
        XCTAssertThrowsError(try SVGPathParser.parse("M 0 0 A 1e308 1e308 0 0 1 100 0"))
    }

    func testDrawableGeometryDistinguishesMoveOnlyAndZeroLengthPaths() throws {
        XCTAssertFalse(try SVGPathParser.parseGeometry("M 10 10").hasDrawableGeometry)
        XCTAssertFalse(try SVGPathParser.parseGeometry("M 10 10 L 10 10 Z").hasDrawableGeometry)
        XCTAssertTrue(try SVGPathParser.parseGeometry("M 10 10 L 10 20").hasDrawableGeometry)
        XCTAssertTrue(try SVGPathParser.parseGeometry("M 10 10 Q 20 20 10 10").hasDrawableGeometry)
    }
}
