import Foundation

/// A drawing's PAINTED bounds in stored backing-pixel space -- the same
/// space every `AnnotationKind` case is already resolved into by the time
/// `DrawRequest.finish` builds one (see `makeVectorPathKind`/`loadImageKind`/
/// `makeTextKind`/`makeShapeKind`, which all convert through a
/// `DrawRequest.CoordinateTransform` before an `AnnotationKind` exists at
/// all).
///
/// WHY THIS EXISTS: choosing which of a target app's windows a NEW
/// `anchor="window"` annotation should follow
/// (`DrawRequest.resolveWindowAnchor`) needs to know roughly where the
/// annotation sits, so `TargetWindowSelection.selectWindow(forRect:among:)`
/// can pick the window with the largest overlap. This is that "roughly
/// where" -- good enough to pick a window, never claimed to be pixel-exact
/// for every kind (see the `.text` case below).
///
/// Platform-neutral, Foundation-only, with no dependency on
/// `AnnotationStore`/`AnnotationRenderer`/MCP, so it is fully unit-testable
/// with hand-built `AnnotationKind` values and no display, renderer, or
/// store in play -- matching `ChalkGeometry.swift`'s and
/// `TargetWindowProbe.swift`'s own "decision separate from the platform/
/// runtime plumbing" precedent.
enum PaintedBounds {
    /// `nil` means "no bounds could be computed for this kind" -- currently
    /// only reachable if a `.vectorPath`'s `data` fails to re-parse (should
    /// never happen for a kind that already passed `makeVectorPathKind`/
    /// `makeShapeKind`/`makeHighlightKind`'s own parse+validate step before
    /// an `AnnotationKind` was ever constructed, but this function makes no
    /// assumption about its caller's history) or a `.batch` all of whose
    /// items independently return `nil`.
    static func paintedBounds(of kind: AnnotationKind) -> CGRect? {
        switch kind {
        case let .vectorPath(data, _, _, _, _, _, _, _, coordinateScaleX, coordinateScaleY):
            // `SVGPathCache` memoises the parse by content (see that type's
            // own doc comment), so re-parsing here is at worst a cache hit,
            // never a second full tokenisation of a path up to
            // `DrawingDefaults.maxSVGPathCharacters` long. The cached
            // `ChalkPath.bounds` is the TIGHT SVG-source-space box (curve
            // extrema included -- see `ChalkPath`'s own doc comment on why
            // it matches `boundingBoxOfPath`, not the looser `boundingBox`);
            // this function's only remaining job is to scale that box into
            // the same backing-pixel space every other kind below is
            // already stored in, exactly as `AnnotationRenderer` scales the
            // same path by the same two factors at paint time.
            guard let path = try? SVGPathCache.path(for: data) else { return nil }
            let bounds = path.bounds
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.size.width.isFinite, bounds.size.height.isFinite else { return nil }
            return CGRect(
                x: bounds.origin.x * coordinateScaleX,
                y: bounds.origin.y * coordinateScaleY,
                width: bounds.size.width * coordinateScaleX,
                height: bounds.size.height * coordinateScaleY
            )

        case let .image(_, x, y, width, height, _, _):
            // Already backing pixels by the time an `AnnotationKind` exists
            // (see `loadImageKind`): no scale to apply.
            return CGRect(x: x, y: y, width: width, height: height)

        case let .text(_, x, y, _, _, _, _, _, _):
            // A text annotation's TRUE painted extent depends on glyph
            // metrics (`DrawingContext.measureText`), which needs a live
            // drawing context this draw-request-time code does not have --
            // text is measured lazily, at PAINT time, not at store time.
            // Window selection only needs a POINT good enough to say "this
            // drawing sits over that window", never the label's true
            // rendered footprint, so a tiny rect anchored at the text's own
            // origin is sufficient.
            //
            // Deliberately 1x1, NOT a zero-size rect at the same origin:
            // `TargetWindowSelection.selectWindow` picks the window with the
            // LARGEST INTERSECTION AREA, and a zero-area rect has zero-area
            // intersection with every candidate window it happens to sit
            // inside -- tying every candidate at 0 and silently falling back
            // to "front-most window", exactly as if this text sat over NO
            // window at all. One backing pixel of extent is enough for the
            // intersection test to correctly favor whichever window
            // actually contains (x, y) over one that merely happens to be
            // frontmost.
            return CGRect(x: x, y: y, width: 1, height: 1)

        case let .batch(items):
            var union: CGRect?
            for item in items {
                guard let bounds = paintedBounds(of: item.kind) else { continue }
                union = union.map { unioned($0, bounds) } ?? bounds
            }
            return union
        }
    }

    /// Hand-rolled from min/max components rather than a CoreGraphics-shim
    /// `CGRect.union(_:)` method, matching `ChalkGeometry.swift`'s own
    /// bounding-box arithmetic style so this file relies on nothing beyond
    /// the `CGRect`/`CGPoint` shim `Foundation` already provides on every
    /// platform this package builds for.
    private static func unioned(_ a: CGRect, _ b: CGRect) -> CGRect {
        let minX = min(a.minX, b.minX)
        let minY = min(a.minY, b.minY)
        let maxX = max(a.maxX, b.maxX)
        let maxY = max(a.maxY, b.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
