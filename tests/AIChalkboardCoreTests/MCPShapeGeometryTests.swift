import Foundation
#if os(macOS)
import CoreGraphics
#endif
import XCTest
@testable import AIChalkboardCore

/// Covers `ellipsePathData` (the two-half-arc closed-ellipse formula shared by
/// `draw_shape` and `highlight_element`) and `draw_shape`'s own geometry
/// parsing (`MCPServer.makeShapeKind`), all of it headless and display-free.
///
/// NOT covered here: `highlight_element`'s own `.rect`/`.ellipse`/`.circle`
/// dispatch (`makeHighlightKind`/`makeHighlightStyle` in
/// `MCPToolHandlers+Highlight.swift`). Both are `private` to that file, and
/// the only reachable entry point, `handleHighlightElement`, requires
/// resolving a live running application through the real Accessibility API
/// (no seam to inject a fake AX tree) and writes its result straight to
/// stdout -- the live JSON-RPC transport -- exactly the hazard
/// `MCPPureHelperTests`'s header comment calls out for `send*` methods. That
/// combination makes it untestable headlessly without widening those
/// declarations' access level, which is out of scope for a tests-only change.
/// `ellipsePathData` below is the one piece `makeHighlightKind` actually
/// delegates its ellipse/circle math to, so its correctness is still
/// exercised end to end; only the padding/circumscribe-vs-inscribe arithmetic
/// specific to the highlight code path is left unverified.
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
