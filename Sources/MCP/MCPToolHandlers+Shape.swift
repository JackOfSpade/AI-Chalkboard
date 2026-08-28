import Foundation

/// Emits a closed ellipse centred on `(centerX, centerY)` with radii
/// `(radiusX, radiusY)`, as two half-arcs.
///
/// WHY TWO ARCS: a single SVG `A` command cannot close a full ellipse on its
/// own. An elliptical arc is defined by its START point, END point, and
/// radii; to trace the WHOLE ellipse the end point would have to coincide
/// with the start point, and SVG defines a coincident-endpoint arc as
/// degenerate -- it draws nothing at all, because the renderer has no way to
/// tell "sweep all the way around" from "don't move." Splitting the ellipse
/// into two half-arcs -- left pole to right pole, then right pole back to
/// left pole -- gives each `A` command a start and end point that are
/// genuinely distinct (opposite ends of the same diameter), so both halves
/// have somewhere to sweep and the full outline renders.
///
/// The exact format below (including the `1 0` large-arc/sweep flags and the
/// left-then-right traversal) was verified pixel-for-pixel against the live
/// renderer and the real DaVinci Resolve binary this feature exists for: a
/// requested circle centred at (2722, 284) with radius 26 rendered with
/// `paintedBoundsScreenshotPx` x:2694 y:256 56x56 -- dead on. Do not
/// "improve" the formatting or flag digits; any change here is a change to
/// verified-correct geometry.
///
/// A free, internal, pure function -- no `MCPServer`, no AppKit, no display
/// -- so `MCPPureHelperTests` can pin this exact string with nothing but a
/// few doubles. Both call sites that need a closed ellipse (`makeShapeKind`
/// below, and `makeHighlightKind` in MCPToolHandlers+Highlight.swift) share
/// it rather than each hand-rolling their own two-arc path, which is exactly
/// the kind of hand-assembly this feature exists to remove from callers.
func ellipsePathData(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double) -> String {
    "M \(centerX - radiusX) \(centerY) A \(radiusX) \(radiusY) 0 1 0 \(centerX + radiusX) \(centerY) A \(radiusX) \(radiusY) 0 1 0 \(centerX - radiusX) \(centerY) Z"
}

extension MCPServer {
    // MARK: - `draw_shape`: circle/ellipse/rect by centre+radius, not hand-written arcs

    /// Parses `draw_shape`'s (and `draw_batch`'s `type: "shape"` item's)
    /// `shape`/geometry arguments into a closed vector path, then hands that
    /// path to `makeVectorPathKind` for the styling half of the work
    /// (stroke/fill/opacity/dash/fill_rule -- every argument `draw_path`
    /// already accepts passes straight through unchanged, since it is read
    /// directly out of `args` by `makeVectorPathKind` itself).
    ///
    /// RATIONALE: an agent that wants "a circle centred at (2722, 284) with
    /// radius 26" should be able to say exactly that. Today it has to
    /// hand-assemble two SVG arc commands with four flag digits apiece, and
    /// every hand-written arc is a chance to mistype or mis-center it --
    /// which is how the bug this tool exists to close actually happened.
    ///
    /// COORDINATE SEMANTICS: every point (a circle/ellipse centre, or a
    /// rect's corner or centre) is transformed through
    /// `coordinateTransform.transformedPoint(x:y:)`, so `coordinate_space`
    /// works exactly as it does for every other draw_* tool, including the
    /// 'normalized' 0...1 unit-interval check on the POSITION. Every LENGTH
    /// (`radius`, `radius_x`, `radius_y`, `width`, `height`) is instead
    /// scaled per-axis by multiplying directly by `coordinateTransform.scaleX`
    /// / `.scaleY` -- deliberately NOT through `transformedX`/`transformedY`.
    /// This is the same choice `MCPServer.resolveBackingSize` documents for
    /// `draw_image`'s derived sibling dimension: a length is not a point, so
    /// routing it through the position transform would also impose that
    /// transform's unit-interval check, which exists to keep a *coordinate*
    /// inside the display -- not to bound a *radius*. This function performs
    /// that same per-axis scaling and then validates the RESULT itself
    /// (finite, > 0, and at most `DrawingDefaults.maxCoordinateMagnitudePx`),
    /// exactly the way `resolveBackingSize`'s caller validates its resolved
    /// dimensions.
    ///
    /// `circle`'s single `radius` is scaled by `scaleX` for its X radius and
    /// by `scaleY` for its Y radius. Under `coordinate_space='backing_pixels'`
    /// (scaleX == scaleY == 1) that is an exact circle. Under
    /// `'screenshot_pixels'` the two scales can differ, but only by the
    /// amount `ScreenshotGeometry.fullDisplayScale` already tolerates as
    /// rounding noise from an integer-pixel screenshot -- at most one output
    /// pixel of difference across the whole display -- so the result stays a
    /// circle for any practical radius. Under `'normalized'` the two axes
    /// genuinely differ (a 3840x2160 display scales X and Y differently), and
    /// a single `radius` there deliberately produces an ELLIPSE whose radius
    /// is that fraction of EACH axis -- which is the only sensible reading of
    /// "radius 0.05" on a non-square display. There is no error path for
    /// this; it is documented behaviour, mirrored in draw_shape's JSON schema
    /// description for `radius`.
    ///
    /// The finished path is emitted directly in BACKING PIXELS (every point
    /// and length above is already resolved before this function builds the
    /// path string), so it is handed to `makeVectorPathKind` with an IDENTITY
    /// transform (`scaleX: 1, scaleY: 1`). That keeps the annotation's stored
    /// geometry unambiguous for `verify_annotation` / `update_annotation` /
    /// `list_annotations` -- exactly the same reason `highlight_element`'s
    /// vector paths (see `makeHighlightKind` in
    /// MCPToolHandlers+Highlight.swift) are always stored pre-resolved into
    /// backing pixels rather than carrying a stored scale factor.
    // internal: called from handleDrawShape below and from handleDrawBatch's
    // "shape" case in MCPToolHandlers+Drawing.swift.
    func makeShapeKind(_ args: [String: Any], coordinateTransform: DrawRequest.CoordinateTransform) -> DrawOutcome<AnnotationKind> {
        guard let rawShape = (args["shape"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawShape.isEmpty else {
            return .failure("Missing required parameter: shape (one of 'circle', 'ellipse', 'rect').")
        }
        let shape = rawShape.lowercased()
        guard ["circle", "ellipse", "rect"].contains(shape) else {
            return .failure("shape must be 'circle', 'ellipse', or 'rect'.")
        }

        let pathData: String
        switch shape {
        case "circle":
            guard let centerX = MCPArgument.double(args["center_x"]),
                  let centerY = MCPArgument.double(args["center_y"]),
                  let radius = MCPArgument.double(args["radius"]) else {
                return .failure("Missing required parameters for shape='circle': center_x, center_y, radius.")
            }
            guard radius > 0 else {
                return .failure("radius must be greater than 0.")
            }
            guard let center = coordinateTransform.transformedPoint(x: centerX, y: centerY) else {
                return .failure("draw_shape's center_x/center_y contains coordinates that cannot be represented safely in the selected display's backing-pixel space.")
            }
            // Per-axis, not through transformedX/Y -- see this function's
            // doc comment above.
            let rx = radius * coordinateTransform.scaleX
            let ry = radius * coordinateTransform.scaleY
            guard rx.isFinite, ry.isFinite, rx > 0, ry > 0,
                  rx <= DrawingDefaults.maxCoordinateMagnitudePx,
                  ry <= DrawingDefaults.maxCoordinateMagnitudePx else {
                return .failure("radius must resolve to a finite backing-pixel value greater than 0 and at most \(Int(DrawingDefaults.maxCoordinateMagnitudePx)).")
            }
            pathData = ellipsePathData(centerX: center.x, centerY: center.y, radiusX: rx, radiusY: ry)

        case "ellipse":
            guard let centerX = MCPArgument.double(args["center_x"]),
                  let centerY = MCPArgument.double(args["center_y"]),
                  let radiusX = MCPArgument.double(args["radius_x"]),
                  let radiusY = MCPArgument.double(args["radius_y"]) else {
                return .failure("Missing required parameters for shape='ellipse': center_x, center_y, radius_x, radius_y.")
            }
            guard radiusX > 0, radiusY > 0 else {
                return .failure("radius_x and radius_y must be greater than 0.")
            }
            guard let center = coordinateTransform.transformedPoint(x: centerX, y: centerY) else {
                return .failure("draw_shape's center_x/center_y contains coordinates that cannot be represented safely in the selected display's backing-pixel space.")
            }
            // See the 'circle' branch above: lengths are scaled per-axis
            // directly, deliberately not through transformedX/Y.
            let rx = radiusX * coordinateTransform.scaleX
            let ry = radiusY * coordinateTransform.scaleY
            guard rx.isFinite, ry.isFinite, rx > 0, ry > 0,
                  rx <= DrawingDefaults.maxCoordinateMagnitudePx,
                  ry <= DrawingDefaults.maxCoordinateMagnitudePx else {
                return .failure("radius_x and radius_y must resolve to finite backing-pixel values greater than 0 and at most \(Int(DrawingDefaults.maxCoordinateMagnitudePx)).")
            }
            pathData = ellipsePathData(centerX: center.x, centerY: center.y, radiusX: rx, radiusY: ry)

        case "rect":
            guard let width = MCPArgument.double(args["width"]),
                  let height = MCPArgument.double(args["height"]) else {
                return .failure("Missing required parameters for shape='rect': width, height.")
            }
            guard width > 0, height > 0 else {
                return .failure("width and height must be greater than 0.")
            }
            // Lengths, scaled per-axis directly -- same reasoning as radius
            // in the 'circle'/'ellipse' branches above.
            let backingWidth = width * coordinateTransform.scaleX
            let backingHeight = height * coordinateTransform.scaleY
            guard backingWidth.isFinite, backingHeight.isFinite, backingWidth > 0, backingHeight > 0,
                  backingWidth <= DrawingDefaults.maxCoordinateMagnitudePx,
                  backingHeight <= DrawingDefaults.maxCoordinateMagnitudePx else {
                return .failure("width and height must resolve to finite backing-pixel values greater than 0 and at most \(Int(DrawingDefaults.maxCoordinateMagnitudePx)).")
            }

            // Exactly one of the two position forms is accepted. Deliberately
            // NOT decided by a successful parse: "x supplied but unparsable"
            // must still count as the corner form having been chosen, so the
            // caller gets the specific x/y message below rather than being
            // told no form was supplied at all.
            //
            // A JSON `null` is the one value that does NOT count as supplied.
            // JSONSerialization turns it into a real `NSNull` dictionary
            // entry, so a plain `args.keys.contains` check treats
            // `"center_x": null` as "the caller chose the centre form" -- and
            // a schema-driven client that serialises every declared property,
            // nulling the ones it is not using, is a completely ordinary way
            // to build a request. That made an unambiguous corner-form rect
            // (`x`, `y`, `width`, `height`, plus null centres) fail with "not
            // both; remove one pair", which is not merely strict: it is FALSE,
            // and it names a pair the caller never meaningfully sent. This
            // check is where a key's mere presence flips OTHER keys between
            // required and forbidden, which is why null has to be read as
            // absence here specifically.
            func isSupplied(_ key: String) -> Bool {
                guard let value = args[key] else { return false }
                return !(value is NSNull)
            }
            let hasCorner = isSupplied("x") || isSupplied("y")
            let hasCenter = isSupplied("center_x") || isSupplied("center_y")
            guard hasCorner || hasCenter else {
                return .failure("shape='rect' requires EITHER x/y (top-left corner) OR center_x/center_y (centre); neither was supplied.")
            }
            guard hasCorner != hasCenter else {
                return .failure("shape='rect' accepts EITHER x/y (top-left corner) OR center_x/center_y (centre), not both; remove one pair.")
            }

            let backingX: Double
            let backingY: Double
            if hasCorner {
                guard let x = MCPArgument.double(args["x"]), let y = MCPArgument.double(args["y"]) else {
                    return .failure("Missing required parameters for shape='rect' with a corner: x, y.")
                }
                guard let corner = coordinateTransform.transformedPoint(x: x, y: y) else {
                    return .failure("draw_shape's x/y contains coordinates that cannot be represented safely in the selected display's backing-pixel space.")
                }
                backingX = corner.x
                backingY = corner.y
            } else {
                guard let centerX = MCPArgument.double(args["center_x"]), let centerY = MCPArgument.double(args["center_y"]) else {
                    return .failure("Missing required parameters for shape='rect' with a centre: center_x, center_y.")
                }
                guard let center = coordinateTransform.transformedPoint(x: centerX, y: centerY) else {
                    return .failure("draw_shape's center_x/center_y contains coordinates that cannot be represented safely in the selected display's backing-pixel space.")
                }
                backingX = center.x - backingWidth / 2
                backingY = center.y - backingHeight / 2
            }
            // Same closed-rectangle format `highlight_element`'s rect branch
            // uses (see makeHighlightKind in MCPToolHandlers+Highlight.swift).
            pathData = "M \(backingX) \(backingY) H \(backingX + backingWidth) V \(backingY + backingHeight) H \(backingX) Z"

        default:
            // Unreachable: `shape` was already checked against exactly these
            // three values above.
            return .failure("shape must be 'circle', 'ellipse', or 'rect'.")
        }

        var injectedArgs = args
        injectedArgs["path_data"] = pathData
        return makeVectorPathKind(injectedArgs, coordinateTransform: .init(scaleX: 1, scaleY: 1))
    }

    // internal: called from handleToolsCall's draw_shape case in MCPToolHandlers.swift.
    func handleDrawShape(id: Any, args: [String: Any]) {
        let request: DrawRequest
        let transform: DrawRequest.CoordinateTransform
        switch DrawRequest.resolveDrawContext(args: args) {
        case .failure(let err):
            sendErrorResult(id: id, text: err)
            return
        case .success(let resolved):
            (request, transform) = resolved
        }
        let kind: AnnotationKind
        switch makeShapeKind(args, coordinateTransform: transform) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let parsed): kind = parsed
        }
        switch request.finish(
            args: args,
            defaultColor: DrawingDefaults.pathColor,
            label: nil,
            defaultsToGlobal: false,
            kind: kind,
            noun: "free-draw shape"
        ) {
        case .failure(let err):
            sendErrorResult(id: id, text: err)
        case .success(let message):
            sendTextResult(id: id, text: message)
        }
    }
}
