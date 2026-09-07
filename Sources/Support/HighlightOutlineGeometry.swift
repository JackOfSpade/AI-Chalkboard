import Foundation

/// The outline traced around an Accessibility element's padded bounds, for
/// `highlight_element`. `.rect` is the historical, still-default behaviour;
/// `.ellipse` and `.circle` exist because a lot of real UI controls are round
/// or pill-shaped (radio buttons, circular icon buttons, dots), and ringing
/// one with a rectangle draws attention to its bounding box rather than its
/// actual silhouette.
///
/// This lives in Sources/Support, not beside `handleHighlightElement` in
/// `MCPToolHandlers+Highlight.swift`, so the element anchor tracker's
/// on-settle re-resolve (`rebuiltKind` below) can regenerate a highlight's
/// outline without reaching into MCP-layer, AX-resolving code -- and without
/// a second copy of this arithmetic drifting from the first. A second copy is
/// exactly the kind of drift that put a ring through the middle of a 44x44
/// button before (see `circleRadius` below). Platform-neutral and
/// Foundation-only, like the rest of this directory: no AppKit, no MCP types.
public enum HighlightOutlineGeometry {

    /// The raw values are the wire strings `highlight_element`'s `shape`
    /// argument accepts and are part of the published schema (see
    /// MCPToolCatalog.swift); do not rename them.
    /// `MCPToolHandlers+Highlight.swift` keeps `HighlightOutlineShape` as a
    /// typealias to this type rather than a second enum, so its own
    /// vocabulary can never drift from this one.
    public enum Shape: String {
        case rect, ellipse, circle
    }

    // MARK: - Circle radius

    /// The radius of the `.circle` outline, in one place because the range
    /// guard in `pathData` below and the path this radius is actually
    /// emitted into MUST be the same number -- a guard computing the radius
    /// its own way would be checking a value nothing draws.
    ///
    /// WHY HALF THE ELEMENT DIAGONAL PLUS PADDING: the region of points at least
    /// `padding` away from every point of a w x h rectangle is that rectangle
    /// grown by `padding` with ROUNDED corners, and the tightest circle that
    /// contains it is centred on the element with radius `hypot(w, h)/2 +
    /// padding`. Anything smaller crosses the rounded corner arcs, i.e. comes
    /// closer to the element than the caller's padding -- or worse.
    ///
    /// The previous formula, `max(paddedWidth, paddedHeight)/2`, only reached the
    /// padded rectangle's EDGE MIDPOINTS; its corners lay outside the ring. On a
    /// square element that failure is not cosmetic: a 44x44 icon button at the
    /// default padding_px=8 has padded bounds 60x60, so the old radius was 30 --
    /// while the button's OWN corners sit (44*44 + 44*44).squareRoot()/2 ~=
    /// 31.11px from centre. The ring passed through the button it was drawn to
    /// enclose. The formula below puts that same corner 8px inside the ring, as
    /// asked.
    ///
    /// `.squareRoot()` rather than `hypot()`: this file builds on both the macOS
    /// and the Windows toolchain, and the stdlib method needs no libc import to
    /// be in scope on either (same reason ChalkGeometry.swift's quadratic solver
    /// uses `discriminant.squareRoot()`).
    public static func circleRadius(frameWidth: Double, frameHeight: Double, padding: Double) -> Double {
        (frameWidth * frameWidth + frameHeight * frameHeight).squareRoot() / 2 + padding
    }

    // MARK: - Path arithmetic (no validation)

    /// Builds the exact path string `highlight_element` draws for one resolved
    /// element frame and `padding_px`, for each of the three outline shapes.
    ///
    /// ARITHMETIC ONLY, no validation: every finite/magnitude/positivity check
    /// stays in `pathData` below, which must reject bad bounds by returning
    /// nil before any path exists. Callers must validate first --
    /// `MCPToolHandlers+Highlight.swift`'s free `highlightOutlinePathData`
    /// forwards straight here for exactly that reason, and stays just as
    /// unvalidated as it always was, so its existing callers (notably
    /// `MCPShapeGeometryTests`, which pins this geometry with nothing but a
    /// few doubles) see no change.
    ///
    /// The `.rect` string is byte-identical to the pre-`shape` behaviour, and
    /// must stay that way: an existing caller's stored annotation geometry is
    /// compared verbatim by `verify_annotation`/`update_annotation`.
    static func rawPathData(
        shape: Shape,
        frameX: Double,
        frameY: Double,
        frameWidth: Double,
        frameHeight: Double,
        padding: Double
    ) -> String {
        let x = frameX - padding
        let y = frameY - padding
        let width = frameWidth + 2 * padding
        let height = frameHeight + 2 * padding
        // Padding is symmetric, so the element and its padded bounds share a
        // centre -- all three shapes are concentric with both.
        let centerX = x + width / 2
        let centerY = y + height / 2

        switch shape {
        case .rect:
            return "M \(x) \(y) H \(x + width) V \(y + height) H \(x) Z"

        case .ellipse:
            // Inscribed in the padded bounds -- the ellipse touches the padded
            // rectangle at the midpoint of each of its four edges. That is the
            // natural reading of "ellipse around this element" for the round and
            // pill-shaped controls this shape exists for: it traces the
            // silhouette. On a genuinely rectangular element it necessarily
            // clips the corners, which is why the schema tells callers to pick
            // rect or circle when containment is what they want.
            return ellipsePathData(centerX: centerX, centerY: centerY, radiusX: width / 2, radiusY: height / 2)

        case .circle:
            let radius = circleRadius(frameWidth: frameWidth, frameHeight: frameHeight, padding: padding)
            return ellipsePathData(centerX: centerX, centerY: centerY, radiusX: radius, radiusY: radius)
        }
    }

    // MARK: - Validated path data

    /// Validates a resolved element frame and, if usable, returns the same
    /// path string `rawPathData` would compute for it.
    ///
    /// nil under exactly the conditions `makeHighlightKind` (in
    /// `MCPToolHandlers+Highlight.swift`) used to reject directly, with
    /// "Resolved accessibility bounds are not usable for a highlight." --
    /// non-finite, over `DrawingDefaults.maxCoordinateMagnitudePx`, or
    /// non-positive extent, checked first on the padded bounds and then, per
    /// shape, on whatever derived radius the emitted path actually depends
    /// on. Moved here verbatim from that guard; `makeHighlightKind` now just
    /// calls this and keeps its own error text.
    public static func pathData(
        shape: Shape,
        frameX: Double,
        frameY: Double,
        frameWidth: Double,
        frameHeight: Double,
        padding: Double
    ) -> String? {
        let x = frameX - padding
        let y = frameY - padding
        let width = frameWidth + 2 * padding
        let height = frameHeight + 2 * padding
        guard [x, y, width, height].allSatisfy(\.isFinite),
              [x, y, width, height].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
              width > 0, height > 0 else {
            return nil
        }

        // Every derived value the emitted path depends on is range-checked
        // HERE, before `rawPathData` -- which deliberately does no
        // validation of its own -- turns it into a string. The centre is
        // shared by all three shapes (padding is symmetric).
        let cx = x + width / 2
        let cy = y + height / 2
        switch shape {
        case .rect:
            // The padded-bounds trace uses nothing but the four values the
            // guard above already covers; there is no derived radius to check.
            break

        case .ellipse:
            let rx = width / 2
            let ry = height / 2
            guard [cx, cy, rx, ry].allSatisfy(\.isFinite),
                  [cx, cy, rx, ry].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
                  rx > 0, ry > 0 else {
                return nil
            }

        case .circle:
            // Derived from the ELEMENT frame, not the padded bounds: see
            // `circleRadius` for why half the element's diagonal plus the
            // padding is the radius that actually encloses the element, and
            // for the 44x44 button the old max(w, h)/2 ring cut straight
            // through.
            let r = circleRadius(frameWidth: frameWidth, frameHeight: frameHeight, padding: padding)
            guard [cx, cy, r].allSatisfy(\.isFinite),
                  [cx, cy, r].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
                  r > 0 else {
                return nil
            }
        }

        return rawPathData(
            shape: shape, frameX: frameX, frameY: frameY,
            frameWidth: frameWidth, frameHeight: frameHeight, padding: padding
        )
    }

    // MARK: - Rebuild for the element anchor tracker

    /// Rebuilds a highlight annotation's kind around a freshly resolved
    /// element frame, preserving EVERY style field of the existing kind.
    ///
    /// Style is taken from the EXISTING kind, never from a stored copy of the
    /// original style, because a caller may have restyled the highlight with
    /// `update_annotation` after it was created -- regenerating from a stale
    /// copy would silently revert their edit.
    ///
    /// Returns nil unless `existing` is a `.vectorPath` and `pathData`
    /// succeeds for `newFrame`. Replaces only `data`; keeps
    /// strokeColorHex/strokeWidth/strokeOpacity/fillColorHex/fillOpacity/
    /// dash/usesEvenOddFillRule from `existing` untouched, and always writes
    /// the 1/1 coordinate scales `highlight_element` itself always stores
    /// (never carried over from `existing`, though they should already agree).
    /// Maps `spec.shape`'s raw wire string onto `Shape`, returning nil for an
    /// unrecognised value.
    public static func rebuiltKind(
        from existing: AnnotationKind,
        spec: AnchorElementSpec,
        newFrame: CGRect
    ) -> AnnotationKind? {
        guard case .vectorPath(
            _,
            let strokeColorHex,
            let strokeWidth,
            let strokeOpacity,
            let fillColorHex,
            let fillOpacity,
            let dash,
            let usesEvenOddFillRule,
            _,
            _
        ) = existing else {
            return nil
        }
        guard let shape = Shape(rawValue: spec.shape) else {
            return nil
        }
        guard let data = pathData(
            shape: shape,
            frameX: newFrame.origin.x,
            frameY: newFrame.origin.y,
            frameWidth: newFrame.size.width,
            frameHeight: newFrame.size.height,
            padding: spec.paddingPx
        ) else {
            return nil
        }
        return .vectorPath(
            data: data,
            strokeColorHex: strokeColorHex,
            strokeWidth: strokeWidth,
            strokeOpacity: strokeOpacity,
            fillColorHex: fillColorHex,
            fillOpacity: fillOpacity,
            dash: dash,
            usesEvenOddFillRule: usesEvenOddFillRule,
            coordinateScaleX: 1,
            coordinateScaleY: 1
        )
    }
}
