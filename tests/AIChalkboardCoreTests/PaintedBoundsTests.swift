import XCTest
@testable import AIChalkboardCore

/// Exercises `PaintedBounds.paintedBounds(of:)` -- the pure helper
/// `DrawRequest.resolveWindowAnchor` uses to pick which of a target app's
/// windows a NEW `anchor="window"` annotation should follow. Every case is a
/// hand-built `AnnotationKind`; nothing here touches the store, renderer, or
/// a live display.
final class PaintedBoundsTests: XCTestCase {
    // MARK: - .vectorPath

    func testVectorPathBoundsAreScaledByCoordinateScaleThenInflatedByHalfTheStroke() throws {
        // A closed 100x50 rectangle with its top-left corner at (10, 10) --
        // the same "M ... H ... V ... H ... Z" shape `makeShapeKind`/
        // `makeHighlightKind` already emit for a rect.
        let kind = AnnotationKind.vectorPath(
            data: "M 10 10 H 110 V 60 H 10 Z",
            strokeColorHex: "#FF0000", strokeWidth: 2, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false,
            coordinateScaleX: 2, coordinateScaleY: 3
        )
        let bounds = try XCTUnwrap(PaintedBounds.paintedBounds(of: kind))
        // Source-space bounds (10, 10, 100, 50) scaled per axis by (2, 3):
        // origin (20, 30), size (200, 150). The stroke is a STYLE dimension
        // in backing pixels -- never multiplied by the coordinate scale --
        // so its half-width inflation (2 / 2 = 1) is added AFTER scaling,
        // uniformly on every side: origin (19, 29), size (202, 152).
        XCTAssertEqual(bounds, CGRect(x: 19, y: 29, width: 202, height: 152))
    }

    func testUnstrokedVectorPathAtIdentityScaleMatchesSourceBoundsExactly() {
        // With no stroke there is nothing painted beyond the geometric box,
        // so `strokeWidth: 0` pins the pure pass-through: identity scale,
        // zero inflation. (Stroke inflation has its own pins above/below.)
        let kind = AnnotationKind.vectorPath(
            data: "M 0 0 H 40 V 20 H 0 Z",
            strokeColorHex: "#FFFFFF", strokeWidth: 0, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        )
        XCTAssertEqual(PaintedBounds.paintedBounds(of: kind), CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    /// A flat stroke's GEOMETRIC bounds have zero height, and a zero-AREA
    /// rect would defeat `TargetWindowSelection.selectWindow`'s
    /// largest-intersection contest exactly like the `.text` 0x0 case
    /// documented below: every candidate window ties at intersection area
    /// 0, and the selection silently falls back to the front-most window --
    /// anchoring a horizontal underline to whatever happened to be in
    /// front, not the window it was drawn across. What the renderer paints
    /// is `strokeWidth` tall (half the pen width each side of the line), so
    /// the estimate must be too.
    func testFlatStrokeGetsNonZeroAreaEstimatedBounds() throws {
        let kind = AnnotationKind.vectorPath(
            data: "M 100 500 L 400 500",
            strokeColorHex: "#00FF00", strokeWidth: 6, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 0, dash: [],
            usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        )
        let bounds = try XCTUnwrap(PaintedBounds.paintedBounds(of: kind))
        // Geometric box (100, 500, 300, 0) inflated by strokeWidth/2 = 3 on
        // every side (round caps extend past the endpoints by the same 3).
        XCTAssertEqual(bounds, CGRect(x: 97, y: 497, width: 306, height: 6))
        XCTAssertGreaterThan(bounds.width * bounds.height, 0)
    }

    /// Defensive: a `data` string that fails to re-parse must not crash or
    /// force-unwrap -- it simply contributes no bounds. This should never
    /// happen for a kind that already passed `makeVectorPathKind`'s own
    /// parse-and-validate step, but this function makes no assumption about
    /// its caller's history.
    func testUnparsableVectorPathReturnsNil() {
        let kind = AnnotationKind.vectorPath(
            data: "not an svg path",
            strokeColorHex: "#FFFFFF", strokeWidth: 1, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        )
        XCTAssertNil(PaintedBounds.paintedBounds(of: kind))
    }

    // MARK: - .image

    func testImageBoundsAreThePassThroughRect() {
        let kind = AnnotationKind.image(
            assetId: "asset-1", x: 15, y: 25, width: 300, height: 200,
            rotationDegrees: 0, opacity: 1
        )
        XCTAssertEqual(PaintedBounds.paintedBounds(of: kind), CGRect(x: 15, y: 25, width: 300, height: 200))
    }

    // MARK: - .text

    /// A text annotation's true rendered footprint needs glyph metrics
    /// (`DrawingContext.measureText`), which needs a live drawing context
    /// this draw-request-time code does not have -- so this is documented
    /// as a 1x1 point, not the label's real extent.
    func testTextBoundsAreAOneByOnePointAtItsOrigin() {
        let kind = AnnotationKind.text(
            text: "hello", x: 500, y: 600, fontSize: 24,
            textColorHex: "#FFFFFF", backgroundColorHex: nil,
            backgroundOpacity: 1, paddingPx: 0, opacity: 1
        )
        XCTAssertEqual(PaintedBounds.paintedBounds(of: kind), CGRect(x: 500, y: 600, width: 1, height: 1))
    }

    /// A ZERO-size rect would defeat `TargetWindowSelection.selectWindow`'s
    /// largest-intersection rule (every intersection area would be 0,
    /// indistinguishable from "over no window at all"), which is exactly why
    /// the text case is deliberately 1x1, not 0x0. Pin that this function
    /// never regresses to a degenerate rect.
    func testTextBoundsAreNeverDegenerate() {
        let kind = AnnotationKind.text(
            text: "x", x: 0, y: 0, fontSize: 12,
            textColorHex: "#FFFFFF", backgroundColorHex: nil,
            backgroundOpacity: 1, paddingPx: 0, opacity: 1
        )
        let bounds = try? XCTUnwrap(PaintedBounds.paintedBounds(of: kind))
        XCTAssertNotEqual(bounds?.width, 0)
        XCTAssertNotEqual(bounds?.height, 0)
    }

    // MARK: - .batch

    func testBatchBoundsAreTheUnionOfItsItems() throws {
        let items = [
            AnnotationComponent(kind: .image(assetId: "a", x: 0, y: 0, width: 100, height: 100, rotationDegrees: 0, opacity: 1)),
            AnnotationComponent(kind: .image(assetId: "b", x: 300, y: 400, width: 50, height: 25, rotationDegrees: 0, opacity: 1))
        ]
        let bounds = try XCTUnwrap(PaintedBounds.paintedBounds(of: .batch(items: items)))
        // Union of (0,0,100,100) and (300,400,50,25): spans (0,0) to (350,425).
        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: 350, height: 425))
    }

    func testBatchSkipsItemsWithNoComputableBounds() {
        let items = [
            AnnotationComponent(kind: .vectorPath(
                data: "garbage", strokeColorHex: "#FFF", strokeWidth: 1, strokeOpacity: 1,
                fillColorHex: nil, fillOpacity: 1, dash: [], usesEvenOddFillRule: false,
                coordinateScaleX: 1, coordinateScaleY: 1
            )),
            AnnotationComponent(kind: .image(assetId: "b", x: 10, y: 20, width: 30, height: 40, rotationDegrees: 0, opacity: 1))
        ]
        // The unparsable path contributes nothing; the union is just the
        // one image's own rect, not nil and not an average/zero placeholder.
        XCTAssertEqual(PaintedBounds.paintedBounds(of: .batch(items: items)), CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testBatchWithNoComputableItemsReturnsNil() {
        let items = [
            AnnotationComponent(kind: .vectorPath(
                data: "garbage", strokeColorHex: "#FFF", strokeWidth: 1, strokeOpacity: 1,
                fillColorHex: nil, fillOpacity: 1, dash: [], usesEvenOddFillRule: false,
                coordinateScaleX: 1, coordinateScaleY: 1
            ))
        ]
        XCTAssertNil(PaintedBounds.paintedBounds(of: .batch(items: items)))
    }

    func testNestedBatchUnionsRecursively() {
        let inner = AnnotationKind.batch(items: [
            AnnotationComponent(kind: .image(assetId: "a", x: 0, y: 0, width: 10, height: 10, rotationDegrees: 0, opacity: 1))
        ])
        let outer = AnnotationKind.batch(items: [
            AnnotationComponent(kind: inner),
            AnnotationComponent(kind: .image(assetId: "b", x: 90, y: 90, width: 10, height: 10, rotationDegrees: 0, opacity: 1))
        ])
        XCTAssertEqual(PaintedBounds.paintedBounds(of: outer), CGRect(x: 0, y: 0, width: 100, height: 100))
    }
}
