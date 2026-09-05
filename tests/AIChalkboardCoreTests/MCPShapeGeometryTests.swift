import Foundation
#if os(macOS)
import CoreGraphics
#endif
import XCTest
@testable import AIChalkboardCore

/// Covers `ellipsePathData` (the two-half-arc closed-ellipse formula shared by
/// `draw_shape` and `highlight_element`), `draw_shape`'s own geometry parsing
/// (`MCPServer.makeShapeKind`), and `highlight_element`'s padding/coverage
/// arithmetic (`highlightOutlinePathData`), all of it headless and
/// display-free.
///
/// `highlight_element`'s geometry used to be listed here as untestable, and it
/// really was: the arithmetic lived inside `private makeHighlightKind`, whose
/// only entry point resolves a live running application through the real
/// Accessibility API and answers on stdout. Nothing headless could reach it,
/// and a `circle` that clipped the very element it was drawn to ring shipped
/// unnoticed as a direct result. That arithmetic now lives in the free, pure
/// `highlightOutlinePathData`, which the tests below pin with nothing but a
/// few doubles -- including the containment property whose violation was the
/// bug.
///
/// STILL NOT covered here: the AX-resolution and transport plumbing around it
/// -- `handleHighlightElement`'s live element lookup (no seam to inject a fake
/// AX tree) and its write straight to stdout, the live JSON-RPC transport,
/// exactly the hazard `MCPPureHelperTests`'s header comment calls out for
/// `send*` methods. `makeHighlightStyle`'s argument validation stays `private`
/// with it for the same reason.
final class MCPShapeGeometryTests: XCTestCase {

    // MARK: - Helpers

    /// Parses SVG path data and returns its true geometric bounding box
    /// (curve extrema included, not just control points) -- the same
    /// entry point `SVGPathParserTests` uses.
    private func boundingBox(of pathData: String) throws -> CGRect {
        try SVGPathParser.parse(pathData).bounds
    }

    private func makeShapeOutcome(
        _ args: [String: Any],
        transform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1)
    ) -> DrawOutcome<AnnotationKind> {
        MCPServer.shared.makeShapeKind(args, coordinateTransform: transform)
    }

    /// Unwraps a successful `draw_shape` outcome down to its path string and
    /// stored coordinate scale, failing the test with a readable message on
    /// any other shape or on failure.
    private func expectPathData(
        _ args: [String: Any],
        transform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1),
        file: StaticString = #filePath, line: UInt = #line
    ) -> (data: String, scaleX: Double, scaleY: Double)? {
        switch makeShapeOutcome(args, transform: transform) {
        case .success(.vectorPath(let data, _, _, _, _, _, _, _, let scaleX, let scaleY)):
            return (data, scaleX, scaleY)
        case .success:
            XCTFail("draw_shape produced a non-path AnnotationKind", file: file, line: line)
            return nil
        case .failure(let message):
            XCTFail("draw_shape unexpectedly failed: \(message)", file: file, line: line)
            return nil
        }
    }

    private func expectFailure(
        _ args: [String: Any],
        transform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1),
        file: StaticString = #filePath, line: UInt = #line
    ) -> String? {
        switch makeShapeOutcome(args, transform: transform) {
        case .success:
            XCTFail("draw_shape unexpectedly succeeded", file: file, line: line)
            return nil
        case .failure(let message):
            return message
        }
    }

    // MARK: - ellipsePathData: bounding-box geometry (items 1-2)

    func testEllipsePathDataCircleBoundingBoxIsCenteredWithDiameterTwiceRadius() throws {
        let data = ellipsePathData(centerX: 100, centerY: 50, radiusX: 26, radiusY: 26)
        let box = try boundingBox(of: data)
        XCTAssertEqual(box.minX, 74, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 126, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 24, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 76, accuracy: 1e-6)
        XCTAssertEqual(box.width, 52, accuracy: 1e-6)
        XCTAssertEqual(box.height, 52, accuracy: 1e-6)
    }

    func testEllipsePathDataGenuineEllipseBoundingBoxUsesEachAxisRadiusIndependently() throws {
        // rx != ry: the width and height of the bounding box must each come
        // from their OWN radius, not get accidentally swapped or averaged.
        let data = ellipsePathData(centerX: 200, centerY: 80, radiusX: 60, radiusY: 15)
        let box = try boundingBox(of: data)
        XCTAssertEqual(box.minX, 140, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 260, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 65, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 95, accuracy: 1e-6)
        XCTAssertEqual(box.width, 120, accuracy: 1e-6)
        XCTAssertEqual(box.height, 30, accuracy: 1e-6)
    }

    /// The exact real-world case documented on `ellipsePathData`'s doc
    /// comment: a circle centred at (2722, 284) with radius 26 on a
    /// 3024x1964 display, verified pixel-for-pixel against the live
    /// DaVinci Resolve renderer. Large, off-origin coordinates are the case
    /// that actually motivated this feature -- a hand-written arc pair is
    /// easy to mis-center at these magnitudes, which is the bug this
    /// function exists to close.
    func testEllipsePathDataLargeOffOriginCenterMatchesTheVerifiedRealWorldCase() throws {
        let data = ellipsePathData(centerX: 2722, centerY: 284, radiusX: 26, radiusY: 26)
        let box = try boundingBox(of: data)
        XCTAssertEqual(box.minX, 2696, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 2748, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 258, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 310, accuracy: 1e-6)
    }

    func testEllipsePathDataLargeOffOriginGenuineEllipseStaysCentered() throws {
        // Same large-coordinate regime as above, but with independent radii,
        // to rule out a bug that only shows up once rx != ry AND the center
        // is far from the origin (e.g. an accidental relative-vs-absolute
        // arc command mixing up which axis gets which large coordinate).
        let data = ellipsePathData(centerX: 2722, centerY: 284, radiusX: 40, radiusY: 12)
        let box = try boundingBox(of: data)
        XCTAssertEqual(box.midX, 2722, accuracy: 1e-6)
        XCTAssertEqual(box.midY, 284, accuracy: 1e-6)
        XCTAssertEqual(box.width, 80, accuracy: 1e-6)
        XCTAssertEqual(box.height, 24, accuracy: 1e-6)
    }

    // MARK: - highlight_element: padded outline geometry

    /// BYTE-IDENTICAL, not merely equivalent geometry: `highlight_element`
    /// stores this exact string as the annotation's path, and an existing
    /// caller reads it back verbatim through list_annotations /
    /// verify_annotation / update_annotation. A 300x80 element at (100, 200)
    /// with the default padding_px=8 has padded bounds (92, 192) 316x96.
    func testHighlightOutlineRectTracesThePaddedBoundsInTheHistoricalFormat() {
        let data = highlightOutlinePathData(
            shape: .rect, frameX: 100, frameY: 200, frameWidth: 300, frameHeight: 80, padding: 8
        )
        XCTAssertEqual(data, "M 92.0 192.0 H 408.0 V 288.0 H 92.0 Z")
    }

    /// Inscribed: tangent to all four edges of the same padded bounds the rect
    /// pin above traces -- centre (250, 240), radii 316/2 and 96/2. This is
    /// the shape that deliberately does NOT contain a rectangular element's
    /// corners; it traces a round or pill control's silhouette instead.
    func testHighlightOutlineEllipseIsInscribedInThePaddedBounds() {
        let data = highlightOutlinePathData(
            shape: .ellipse, frameX: 100, frameY: 200, frameWidth: 300, frameHeight: 80, padding: 8
        )
        XCTAssertEqual(data, ellipsePathData(centerX: 250.0, centerY: 240.0, radiusX: 158.0, radiusY: 48.0))
    }

    /// The 44x44 icon button from the defect report, at the default
    /// padding_px=8: radius = half the ELEMENT's diagonal plus the padding,
    /// and the ring stays concentric with the element.
    func testHighlightOutlineCircleRadiusIsHalfTheElementDiagonalPlusPadding() throws {
        let radius = (44.0 * 44.0 + 44.0 * 44.0).squareRoot() / 2 + 8
        XCTAssertEqual(radius, 39.11269837220809, accuracy: 1e-9, "the formula this test pins, spelled out")
        let data = highlightOutlinePathData(
            shape: .circle, frameX: 500, frameY: 300, frameWidth: 44, frameHeight: 44, padding: 8
        )
        let box = try boundingBox(of: data)
        // The WIDTH is exact to the last bit: `ellipsePathData` splits the
        // outline at the left and right poles, so those two extrema are
        // literal path endpoints. The HEIGHT is not -- the vertical extrema
        // fall in the middle of the cubic segments `SVGPathParser` reduces
        // each arc to, and a cubic only approximates a circular arc (how
        // closely depends on how many segments the arc's sweep is divided
        // into, so it varies by case). Microns of slack there, not more; an
        // outline that had actually become an ellipse would miss by pixels.
        XCTAssertEqual(Double(box.width), 2 * radius, accuracy: 1e-9)
        XCTAssertEqual(Double(box.height), 2 * radius, accuracy: 1e-4, "a circle, not an ellipse")
        XCTAssertEqual(Double(box.midX), 522, accuracy: 1e-9, "concentric with the element: 500 + 44/2")
        XCTAssertEqual(Double(box.midY), 322, accuracy: 1e-9, "concentric with the element: 300 + 44/2")
    }

    /// THE regression test for the shipped defect: the ring must clear the
    /// element by at least `padding` EVERYWHERE, corners included -- the
    /// corners being exactly where the old radius failed. The sizes below span
    /// square, wide, tall, large, and extremely elongated elements, because the
    /// old max(paddedWidth, paddedHeight)/2 radius was only ever adequate for
    /// the last of those.
    func testHighlightOutlineCircleKeepsEveryElementCornerAtLeastThePaddingInside() throws {
        for (width, height) in [(44.0, 44.0), (120.0, 32.0), (32.0, 120.0), (200.0, 200.0), (5.0, 300.0)] {
            for padding in [0.0, 8.0, 24.0] {
                let data = highlightOutlinePathData(
                    shape: .circle, frameX: 640, frameY: 480,
                    frameWidth: width, frameHeight: height, padding: padding
                )
                let box = try boundingBox(of: data)
                // Read back off the EMITTED path rather than recomputed, so
                // this really does test what a caller would be drawn. The
                // width is the exact diameter (see the radius pin above for
                // why the width is bit-exact and the height is not).
                let radius = Double(box.width) / 2
                // All four corners of the element are the same distance from
                // the shared centre -- half the element's diagonal -- so this
                // one number is the worst case for the whole outline.
                let cornerDistance = (width * width + height * height).squareRoot() / 2
                XCTAssertLessThanOrEqual(
                    cornerDistance, radius - padding + 1e-9,
                    "\(width)x\(height) at padding \(padding): the ring comes closer to a corner than the requested padding"
                )
                XCTAssertEqual(Double(box.height), 2 * radius, accuracy: 1e-4, "\(width)x\(height): must stay round")
                XCTAssertEqual(Double(box.midX), 640 + width / 2, accuracy: 1e-9)
                XCTAssertEqual(Double(box.midY), 480 + height / 2, accuracy: 1e-9)
            }
        }

        // Stated as the OLD formula's failure rather than the new one's
        // success, so this pins WHY the radius changed: a 44x44 button padded
        // by 8 has 60x60 padded bounds, giving max(60, 60)/2 = 30 -- while the
        // button's own corners sit ~31.11px from the centre. The ring drawn to
        // enclose the button passed straight through it, which is exactly what
        // the user reported seeing.
        let paddedWidth: Double = 44 + 2 * 8
        let paddedHeight: Double = 44 + 2 * 8
        let oldRadius = max(paddedWidth, paddedHeight) / 2
        let cornerDistance = (44.0 * 44.0 + 44.0 * 44.0).squareRoot() / 2
        XCTAssertEqual(oldRadius, 30)
        XCTAssertEqual(cornerDistance, 31.11269837220809, accuracy: 1e-9)
        XCTAssertGreaterThan(cornerDistance, oldRadius)
    }

    // MARK: - draw_shape: coordinate semantics (item 5)

    func testDrawShapeCircleUnderIdentityTransformIsExactlyRound() throws {
        let result = try XCTUnwrap(expectPathData(["shape": "circle", "center_x": 100, "center_y": 50, "radius": 26]))
        let box = try boundingBox(of: result.data)
        XCTAssertEqual(box.width, box.height, accuracy: 1e-6, "identity transform must yield a true circle")
        XCTAssertEqual(box.midX, 100, accuracy: 1e-6)
        XCTAssertEqual(box.midY, 50, accuracy: 1e-6)
        XCTAssertEqual(box.width, 52, accuracy: 1e-6)
        // The resolved path is stored pre-scaled into backing pixels, so it
        // is always handed to makeVectorPathKind under an IDENTITY transform
        // -- regardless of the coordinate_space the caller actually chose.
        XCTAssertEqual(result.scaleX, 1)
        XCTAssertEqual(result.scaleY, 1)
    }

    func testDrawShapeCircleUnderAnisotropicNormalizedTransformBecomesAnEllipse() throws {
        // coordinate_space='normalized' on a 3840x2160 display: X and Y scale
        // by different factors, so a single `radius` must become rx = r*scaleX
        // and ry = r*scaleY -- an ellipse, not a circle.
        let normalized4K = DrawRequest.CoordinateTransform(scaleX: 3840, scaleY: 2160, requiresUnitInterval: true)
        let result = try XCTUnwrap(expectPathData(
            ["shape": "circle", "center_x": 0.5, "center_y": 0.5, "radius": 0.01],
            transform: normalized4K
        ))
        let box = try boundingBox(of: result.data)
        XCTAssertEqual(box.midX, 1920, accuracy: 1e-6, "center_x=0.5 on a 3840-wide display")
        XCTAssertEqual(box.midY, 1080, accuracy: 1e-6, "center_y=0.5 on a 2160-tall display")
        XCTAssertEqual(box.width, 76.8, accuracy: 1e-6, "rx = 0.01 * 3840")
        XCTAssertEqual(box.height, 43.2, accuracy: 1e-6, "ry = 0.01 * 2160")
        XCTAssertNotEqual(box.width, box.height, "anisotropic scale must NOT stay round")
    }

    // MARK: - draw_shape: rect corner vs. centre forms (item 6)

    func testDrawShapeRectCornerAndCenterFormsProduceTheIdenticalPath() throws {
        // A non-uniform, non-identity transform, so an accidental x/y-scale
        // mixup would be visible: backingX only ever depends on scaleX and
        // backingY only ever depends on scaleY, for BOTH position forms.
        let transform = DrawRequest.CoordinateTransform(scaleX: 2, scaleY: 3)
        let corner = try XCTUnwrap(expectPathData(
            ["shape": "rect", "width": 40, "height": 20, "x": 80, "y": 40], transform: transform
        ))
        // center_x/center_y = corner + half the size, so the two forms
        // describe the SAME rectangle.
        let center = try XCTUnwrap(expectPathData(
            ["shape": "rect", "width": 40, "height": 20, "center_x": 100, "center_y": 50], transform: transform
        ))
        XCTAssertEqual(corner.data, center.data)
        XCTAssertEqual(corner.data, "M 160.0 120.0 H 240.0 V 180.0 H 160.0 Z")
    }

    func testDrawShapeRectRejectsSupplyingBothPositionForms() throws {
        let message = try XCTUnwrap(expectFailure([
            "shape": "rect", "width": 40, "height": 20,
            "x": 80, "y": 40, "center_x": 100, "center_y": 50
        ]))
        XCTAssertEqual(message, "shape='rect' accepts EITHER x/y (top-left corner) OR center_x/center_y (centre), not both; remove one pair.")
    }

    func testDrawShapeRectRejectsSupplyingNeitherPositionForm() throws {
        let message = try XCTUnwrap(expectFailure(["shape": "rect", "width": 40, "height": 20]))
        XCTAssertEqual(message, "shape='rect' requires EITHER x/y (top-left corner) OR center_x/center_y (centre); neither was supplied.")
    }

    // MARK: - draw_shape: rejections (item 7)

    func testDrawShapeMissingShapeIsRejected() throws {
        XCTAssertEqual(expectFailure([:]), "Missing required parameter: shape (one of 'circle', 'ellipse', 'rect').")
    }

    func testDrawShapeBlankShapeIsRejected() throws {
        // Matches `Missing required parameter`, not `shape must be ...`: an
        // all-whitespace string is treated the same as omission, not as an
        // unknown value.
        XCTAssertEqual(expectFailure(["shape": "   "]), "Missing required parameter: shape (one of 'circle', 'ellipse', 'rect').")
    }

    func testDrawShapeUnknownShapeIsRejected() throws {
        XCTAssertEqual(expectFailure(["shape": "triangle"]), "shape must be 'circle', 'ellipse', or 'rect'.")
    }

    func testDrawShapeShapeMatchingIsCaseInsensitive() throws {
        let result = try XCTUnwrap(expectPathData(["shape": "CIRCLE", "center_x": 0, "center_y": 0, "radius": 5]))
        XCTAssertTrue(result.data.hasPrefix("M "))
    }

    func testDrawShapeCircleRejectsZeroAndNegativeRadius() throws {
        XCTAssertEqual(expectFailure(["shape": "circle", "center_x": 0, "center_y": 0, "radius": 0]), "radius must be greater than 0.")
        XCTAssertEqual(expectFailure(["shape": "circle", "center_x": 0, "center_y": 0, "radius": -5]), "radius must be greater than 0.")
    }

    func testDrawShapeCircleTreatsNonFiniteRadiusAsMissing() throws {
        // MCPArgument.double rejects "nan"/"inf" before this function ever
        // sees a radius value to range-check, so a non-finite radius reports
        // the same "missing required parameters" message a fully omitted
        // radius would -- not a separate "must be finite" message that does
        // not exist for this parameter.
        let message = "Missing required parameters for shape='circle': center_x, center_y, radius."
        XCTAssertEqual(expectFailure(["shape": "circle", "center_x": 0, "center_y": 0, "radius": "nan"]), message)
        XCTAssertEqual(expectFailure(["shape": "circle", "center_x": 0, "center_y": 0, "radius": "inf"]), message)
        XCTAssertEqual(expectFailure(["shape": "circle", "center_x": 0, "center_y": 0, "radius": Double.infinity]), message)
    }

    func testDrawShapeCircleMissingRequiredParameterIsRejected() throws {
        XCTAssertEqual(
            expectFailure(["shape": "circle", "center_x": 0, "center_y": 0]),
            "Missing required parameters for shape='circle': center_x, center_y, radius."
        )
    }

    func testDrawShapeEllipseRejectsNonPositiveRadii() throws {
        XCTAssertEqual(
            expectFailure(["shape": "ellipse", "center_x": 0, "center_y": 0, "radius_x": 5, "radius_y": 0]),
            "radius_x and radius_y must be greater than 0."
        )
        XCTAssertEqual(
            expectFailure(["shape": "ellipse", "center_x": 0, "center_y": 0, "radius_x": -1, "radius_y": 5]),
            "radius_x and radius_y must be greater than 0."
        )
    }

    func testDrawShapeEllipseMissingRequiredParameterIsRejected() throws {
        XCTAssertEqual(
            expectFailure(["shape": "ellipse", "center_x": 0, "center_y": 0, "radius_x": 5]),
            "Missing required parameters for shape='ellipse': center_x, center_y, radius_x, radius_y."
        )
    }

    func testDrawShapeRectRejectsNonPositiveWidthOrHeight() throws {
        XCTAssertEqual(
            expectFailure(["shape": "rect", "width": 0, "height": 10, "x": 0, "y": 0]),
            "width and height must be greater than 0."
        )
        XCTAssertEqual(
            expectFailure(["shape": "rect", "width": 10, "height": -1, "x": 0, "y": 0]),
            "width and height must be greater than 0."
        )
    }

    func testDrawShapeRectMissingRequiredParameterIsRejected() throws {
        XCTAssertEqual(
            expectFailure(["shape": "rect", "width": 10, "x": 0, "y": 0]),
            "Missing required parameters for shape='rect': width, height."
        )
    }

    // MARK: - rect position-form exclusivity treats JSON null as absent

    /// A schema-driven client that serialises every declared property, nulling
    /// the ones it is not using, sends an unambiguous corner-form rect as
    /// x/y/width/height plus `center_x: null, center_y: null`.
    /// JSONSerialization turns those nulls into real `NSNull` dictionary
    /// entries, so a bare key-presence check read them as "the caller also
    /// chose the centre form" and rejected a perfectly well-formed request
    /// with "not both; remove one pair" -- naming a pair the caller never
    /// meaningfully supplied.
    func testRectCornerFormIsAcceptedWhenTheUnusedCentreKeysAreExplicitNull() {
        let args: [String: Any] = [
            "shape": "rect", "x": 80, "y": 40, "width": 40, "height": 20,
            "center_x": NSNull(), "center_y": NSNull()
        ]
        switch MCPServer.shared.makeShapeKind(args, coordinateTransform: .init(scaleX: 1, scaleY: 1)) {
        case .failure(let error):
            XCTFail("a corner-form rect with null centres must be accepted; got: \(error)")
        case .success(let kind):
            guard case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = kind else {
                return XCTFail("expected a vector path")
            }
            XCTAssertEqual(data, "M 80.0 40.0 H 120.0 V 60.0 H 80.0 Z")
        }
    }

    /// The mirror case: centre form with the corner pair nulled out.
    func testRectCentreFormIsAcceptedWhenTheUnusedCornerKeysAreExplicitNull() {
        let args: [String: Any] = [
            "shape": "rect", "center_x": 100, "center_y": 50, "width": 40, "height": 20,
            "x": NSNull(), "y": NSNull()
        ]
        switch MCPServer.shared.makeShapeKind(args, coordinateTransform: .init(scaleX: 1, scaleY: 1)) {
        case .failure(let error):
            XCTFail("a centre-form rect with null corners must be accepted; got: \(error)")
        case .success(let kind):
            guard case .vectorPath(let data, _, _, _, _, _, _, _, _, _) = kind else {
                return XCTFail("expected a vector path")
            }
            XCTAssertEqual(data, "M 80.0 40.0 H 120.0 V 60.0 H 80.0 Z")
        }
    }

    /// All four position keys present but null means NEITHER form was chosen,
    /// so the message must say a pair is missing -- not that one should be
    /// removed.
    func testRectWithEveryPositionKeyNullReportsNeitherFormSupplied() {
        let args: [String: Any] = [
            "shape": "rect", "width": 40, "height": 20,
            "x": NSNull(), "y": NSNull(), "center_x": NSNull(), "center_y": NSNull()
        ]
        switch MCPServer.shared.makeShapeKind(args, coordinateTransform: .init(scaleX: 1, scaleY: 1)) {
        case .success:
            XCTFail("a rect with no usable position must be rejected")
        case .failure(let error):
            XCTAssertTrue(error.contains("neither was supplied"), "got: \(error)")
            XCTAssertFalse(error.contains("remove one pair"),
                           "must not tell the caller to remove a pair it never supplied: \(error)")
        }
    }

    /// Regression guard: a genuinely ambiguous request -- both forms with real
    /// values -- must STILL be rejected.
    func testRectWithBothPositionFormsSuppliedIsStillRejected() {
        let args: [String: Any] = [
            "shape": "rect", "x": 1, "y": 1, "center_x": 2, "center_y": 2, "width": 10, "height": 10
        ]
        switch MCPServer.shared.makeShapeKind(args, coordinateTransform: .init(scaleX: 1, scaleY: 1)) {
        case .success: XCTFail("both position forms must be rejected")
        case .failure(let error): XCTAssertTrue(error.contains("not both"), "got: \(error)")
        }
    }

    /// And an unparsable (but non-null) corner value must still be read as
    /// "the corner form was chosen", producing the specific x/y message.
    func testRectWithUnparsableCornerStillSelectsTheCornerFormMessage() {
        let args: [String: Any] = ["shape": "rect", "x": "abc", "y": 40, "width": 40, "height": 20]
        switch MCPServer.shared.makeShapeKind(args, coordinateTransform: .init(scaleX: 1, scaleY: 1)) {
        case .success: XCTFail("an unparsable x must be rejected")
        case .failure(let error):
            XCTAssertTrue(error.contains("corner"), "expected the corner-specific message; got: \(error)")
        }
    }

}
