import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `ChalkTransform` and `ChalkPath` -- the platform-neutral stand-ins
/// for `CGAffineTransform`/`CGPath` that let `SVGPathParser` and its callers
/// drop CoreGraphics from shared code. These are pure value-type primitives,
/// so every test here constructs its input directly rather than going
/// through SVG text (see `SVGPathParserTests` for the parser-driven bounds
/// coverage, including the tight-vs-loose curve bounds cases).
final class ChalkGeometryTests: XCTestCase {

    // MARK: - ChalkTransform

    func testIdentityTransformIsNoOp() {
        let point = CGPoint(x: 3, y: -7)
        XCTAssertEqual(ChalkTransform.identity.apply(to: point), point)
    }

    func testTranslationAppliesOffset() {
        let transform = ChalkTransform.translation(x: 5, y: -2)
        XCTAssertEqual(transform.apply(to: CGPoint(x: 1, y: 1)), CGPoint(x: 6, y: -1))
    }

    func testScaleAppliesPerAxisFactors() {
        let transform = ChalkTransform.scale(x: 2, y: 3)
        XCTAssertEqual(transform.apply(to: CGPoint(x: 4, y: 5)), CGPoint(x: 8, y: 15))
    }

    func testRotationMatchesCGAffineTransformConvention() {
        // CGAffineTransform's rotation convention is `a=cos, b=sin, c=-sin,
        // d=cos`, which rotates (1, 0) to (cos θ, sin θ). At θ=π/2 that is
        // (~0, 1); `accuracy` absorbs the fact that `cos(.pi / 2)` is not
        // bit-exact zero.
        let transform = ChalkTransform.rotation(radians: .pi / 2)
        let rotated = transform.apply(to: CGPoint(x: 1, y: 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rotated.y, 1, accuracy: 1e-9)
    }

    func testConcatenatingAppliesSelfThenOther() {
        // `translate.concatenating(scale)` must equal applying `translate`
        // and then `scale` in sequence -- the same order
        // `CGAffineTransform.concatenating(_:)` documents.
        let translate = ChalkTransform.translation(x: 5, y: 0)
        let scale = ChalkTransform.scale(x: 2, y: 2)
        let combined = translate.concatenating(scale)
        let point = CGPoint(x: 0, y: 0)
        XCTAssertEqual(combined.apply(to: point), scale.apply(to: translate.apply(to: point)))
        XCTAssertEqual(combined.apply(to: point), CGPoint(x: 10, y: 0))
    }

    func testConcatenatingOrderIsNotCommutative() {
        let translate = ChalkTransform.translation(x: 5, y: 0)
        let scale = ChalkTransform.scale(x: 2, y: 2)
        let point = CGPoint(x: 0, y: 0)
        // translate THEN scale: (0,0) -> (5,0) -> (10,0)
        XCTAssertEqual(translate.concatenating(scale).apply(to: point), CGPoint(x: 10, y: 0))
        // scale THEN translate: (0,0) -> (0,0) -> (5,0)
        XCTAssertEqual(scale.concatenating(translate).apply(to: point), CGPoint(x: 5, y: 0))
    }

    // MARK: - ChalkPath.transformed(by:)

    func testTransformedMapsEveryPointAndShiftsBoundsForALineSegment() {
        let path = ChalkPath(elements: [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 10, y: 0))])
        let moved = path.transformed(by: .translation(x: 3, y: 4))
        XCTAssertEqual(moved.elements, [.move(CGPoint(x: 3, y: 4)), .line(CGPoint(x: 13, y: 4))])
        XCTAssertEqual(moved.bounds, CGRect(x: 3, y: 4, width: 10, height: 0))
    }

    func testTransformedRecomputesTightCurveBoundsRatherThanRotatingTheRect() throws {
        // A rotation does not commute with taking a bounding box: the tight
        // box of a rotated curve is not simply the rotated corners of the
        // original tight box. Built from exact literal coefficients (not
        // `.rotation(radians:)`) so every value below is exact, not merely
        // close, and isolates that property from floating-point cos/sin
        // rounding.
        let quarterTurn = ChalkTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        let path = try SVGPathParser.parse("M0 0 Q 50 100 100 0")
        XCTAssertEqual(path.bounds, CGRect(x: 0, y: 0, width: 100, height: 50))

        let rotated = path.transformed(by: quarterTurn)
        // Re-derived independently: the rotated control points are
        // (0,0), (-100,50), (0,100); that quad's own y(t) is exactly linear
        // (0 -> 100), but its x(t) has an interior extremum of -50 at
        // t=0.5 -- so the tight box is (-50, 0, 50, 100). (A plain
        // axis-aligned rectangle happens to survive an exact 90-degree turn
        // with the same corners either way; the general claim -- that
        // rotating first and re-deriving tight curve bounds is NOT the same
        // as rotating an already-computed bounding rect -- is what does not
        // hold at an arbitrary angle, and is why `transformed(by:)`
        // recomputes bounds from the mapped curve instead of transforming
        // the old rectangle.)
        XCTAssertEqual(rotated.bounds, CGRect(x: -50, y: 0, width: 50, height: 100))
    }
}
