import Foundation

// MARK: - SVGPathElement

/// The resolved drawing operations in an SVG path.  This is intentionally a
/// small, Foundation-free representation so callers can inspect a parsed path
/// (and unit tests can assert its geometry) without having to introspect a
/// `CGPath` callback.
public enum SVGPathElement: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(control: CGPoint, to: CGPoint)
    case cubic(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case close
}

// MARK: - ChalkTransform

/// A platform-neutral 2D affine transform, standing in for
/// `CGAffineTransform` wherever shared (non-macOS-only) code needs to
/// compose or apply one.
///
/// WHY THIS EXISTS: `CGAffineTransform` lives in CoreGraphics, which does not
/// exist on Windows (`canImport(CoreGraphics)` is false there). `CGPoint`,
/// `CGSize`, and `CGRect` DO exist on Windows via Foundation, so this type
/// keeps using them for its point/rect surface and replaces only the matrix
/// type itself.
///
/// The field names and their meaning match `CGAffineTransform` exactly --
/// `a`, `b`, `c`, `d`, `tx`, `ty` describe the same row-vector matrix
///
///     | a   b   0 |
///     | c   d   0 |
///     | tx  ty  1 |
///
/// applied to a point as `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty` -- so
/// any macOS-only code that still wants a real `CGAffineTransform` can
/// rebuild one from these six numbers with no reinterpretation, and
/// `concatenating(_:)` composes left-to-right exactly like
/// `CGAffineTransform.concatenating(_:)` does.
public struct ChalkTransform: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public static let identity = ChalkTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static func translation(x: Double, y: Double) -> ChalkTransform {
        ChalkTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scale(x: Double, y: Double) -> ChalkTransform {
        ChalkTransform(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    public static func rotation(radians: Double) -> ChalkTransform {
        let cosine = cos(radians)
        let sine = sin(radians)
        return ChalkTransform(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    /// Combines `self` with `other`, matching
    /// `CGAffineTransform.concatenating(_:)`'s order exactly: the returned
    /// transform applies `self` FIRST, then `other` -- i.e. mapping a point
    /// through `self.concatenating(other)` is equivalent to mapping it
    /// through `self` and then through `other` in sequence, not the reverse.
    public func concatenating(_ other: ChalkTransform) -> ChalkTransform {
        ChalkTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    /// Maps `point` through this transform, using the same
    /// `(a*x + c*y + tx, b*x + d*y + ty)` formula `CGPoint.applying(_:)` uses
    /// for a `CGAffineTransform`.
    public func apply(to point: CGPoint) -> CGPoint {
        CGPoint(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }
}

// MARK: - ChalkPath

/// A platform-neutral, immutable stand-in for `CGPath` wherever shared code
/// needs a parsed vector path without depending on CoreGraphics.
///
/// `elements` is the same resolved operation list `SVGPathParser` has always
/// produced. `bounds` is computed once at construction so every `ChalkPath`
/// -- fresh from the parser, or produced by `transformed(by:)` -- carries a
/// valid bounding box without callers ever needing to walk `elements`
/// themselves.
///
/// WHY `bounds` MATCHES `CGPath.boundingBoxOfPath`, NOT `CGPath.boundingBox`:
/// Core Graphics exposes two different bounding boxes for the same path --
/// `boundingBox`, which is the fast, LOOSE box that includes every Bézier/
/// quadratic CONTROL point even when a control point lies outside the
/// rendered curve, and `boundingBoxOfPath`, which is the TIGHT box of the
/// curve as actually drawn (curve extrema included, control points that
/// never lie on or affect the curve's true extent excluded). The code this
/// type replaces the `CGPath` half of has always used `boundingBoxOfPath` --
/// see the original `SVGPathGeometry(elements:path:bounds: path.boundingBoxOfPath)`
/// construction this type's `computeBounds` replaces, and
/// `MCPShapeGeometryTests.boundingBox(of:)`'s own doc comment, which
/// independently describes that same call as returning "its true geometric
/// bounding box (curve extrema included, not just control points)". Matching
/// the loose `boundingBox` instead would silently change every stored/
/// reported path bounding box the moment a curve's control point strayed
/// outside its rendered extent -- exactly the case `boundingBoxOfPath` was
/// chosen to get right. `computeBounds` therefore solves, per quadratic/
/// cubic segment, for the parametric points where that segment's tangent
/// goes horizontal or vertical (the only places a smooth curve's x or y can
/// be locally extreme), rather than taking the hull of its control points.
public struct ChalkPath: Equatable, Sendable {
    public let elements: [SVGPathElement]
    public let bounds: CGRect

    public init(elements: [SVGPathElement]) {
        self.elements = elements
        self.bounds = ChalkPath.computeBounds(elements)
    }

    /// Maps every point in `elements` through `transform` and recomputes
    /// `bounds` from the mapped geometry. `bounds` is never carried over or
    /// transformed as a rectangle, because an affine transform (rotation in
    /// particular) does not commute with taking a bounding box: the tight
    /// box of a rotated curve is not the rotated tight box of the original
    /// curve.
    public func transformed(by transform: ChalkTransform) -> ChalkPath {
        let mapped = elements.map { element -> SVGPathElement in
            switch element {
            case let .move(point):
                return .move(transform.apply(to: point))
            case let .line(point):
                return .line(transform.apply(to: point))
            case let .quad(control, to):
                return .quad(control: transform.apply(to: control), to: transform.apply(to: to))
            case let .cubic(control1, control2, to):
                return .cubic(
                    control1: transform.apply(to: control1),
                    control2: transform.apply(to: control2),
                    to: transform.apply(to: to)
                )
            case .close:
                return .close
            }
        }
        return ChalkPath(elements: mapped)
    }

    // MARK: Bounds

    private static func computeBounds(_ elements: [SVGPathElement]) -> CGRect {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var hasPoint = false

        func include(_ point: CGPoint) {
            hasPoint = true
            if point.x < minX { minX = point.x }
            if point.x > maxX { maxX = point.x }
            if point.y < minY { minY = point.y }
            if point.y > maxY { maxY = point.y }
        }

        // `current` is the running "current point" a real path cursor would
        // have -- the start of the NEXT segment. It is only read by quad/
        // cubic (to locate where their curve begins), so the placeholder
        // `.zero` before any `.move` is never actually observed: a path
        // produced by `SVGPathParser` never emits a curve or line before a
        // `.move` (see `missingInitialMove`). A `ChalkPath` assembled by hand
        // that violates that ordering is a caller contract this function has
        // no way to detect, exactly as `CGPath` itself would not detect it.
        var current = CGPoint.zero
        // `subpathStart` is where the OPEN subpath began -- the point a
        // `.close` snaps the cursor back to. Same placeholder caveat as
        // `current`: it is only ever read by `.close`, which cannot precede
        // the first `.move` in any parser-produced path.
        var subpathStart = CGPoint.zero

        for element in elements {
            switch element {
            case let .move(point):
                include(point)
                current = point
                subpathStart = point
            case let .line(point):
                include(point)
                current = point
            case let .quad(control, to):
                let ts = extrema(p0: current.x, p1: control.x, p2: to.x)
                    + extrema(p0: current.y, p1: control.y, p2: to.y)
                for t in ts { include(quadraticPoint(current, control, to, t)) }
                include(to)
                current = to
            case let .cubic(control1, control2, to):
                let ts = cubicExtrema(p0: current.x, p1: control1.x, p2: control2.x, p3: to.x)
                    + cubicExtrema(p0: current.y, p1: control1.y, p2: control2.y, p3: to.y)
                for t in ts { include(cubicPoint(current, control1, control2, to, t)) }
                include(to)
                current = to
            case .close:
                // A close draws a straight line back to the subpath's start,
                // a point already included by the `.move` that began it --
                // there is no new extremal geometry to add. But closepath
                // DOES move the cursor: SVG and `CGPath` both define the
                // current point after a close as the CLOSED SUBPATH'S START
                // (`SVGPathParser`'s own `Z` handler sets
                // `current = subpathStart`, and `CGMutablePath.closeSubpath`
                // does the same), so a curve that follows a `Z` without an
                // intervening `M` begins at the subpath's start. Leaving
                // `current` at the pre-close point here made that curve's
                // extrema get solved from the WRONG start point, breaking
                // this type's boundingBoxOfPath-match contract (see the
                // header comment) for exactly the "curve after Z" shape --
                // e.g. `M 100 100 L 200 100 L 200 200 Z Q 300 300 100 300`
                // overreported max X by 33px.
                current = subpathStart
            }
        }

        guard hasPoint else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func quadraticPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: Double) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
            y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y
        )
    }

    private static func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let mt = 1 - t
        let mt2 = mt * mt
        let t2 = t * t
        return CGPoint(
            x: mt2 * mt * p0.x + 3 * mt2 * t * p1.x + 3 * mt * t2 * p2.x + t2 * t * p3.x,
            y: mt2 * mt * p0.y + 3 * mt2 * t * p1.y + 3 * mt * t2 * p2.y + t2 * t * p3.y
        )
    }

    /// The `t` in (0, 1) where a quadratic Bézier's derivative along ONE
    /// axis is zero -- i.e. where that axis's coordinate is locally extreme.
    /// `t = 0` and `t = 1` (the segment's own endpoints) are deliberately
    /// excluded: they are already included by the `include(to)` call at
    /// every quad/cubic site, and by whichever prior element supplied the
    /// start point.
    ///
    /// A quadratic Bézier's derivative is linear in `t`
    /// (`B'(t)/2 = (p0 - 2p1 + p2)*t + (p1 - p0)`), so there is at most one
    /// root, hence at most one extremum, per axis.
    private static func extrema(p0: Double, p1: Double, p2: Double) -> [Double] {
        let denominator = p0 - 2 * p1 + p2
        guard denominator != 0 else { return [] }
        let t = (p0 - p1) / denominator
        return (t.isFinite && t > 0 && t < 1) ? [t] : []
    }

    /// The `t` in (0, 1) where a cubic Bézier's derivative along ONE axis is
    /// zero. A cubic's derivative is quadratic in `t`
    /// (`B'(t)/3 = a*t^2 + b*t + c` with `a = -p0+3p1-3p2+p3`,
    /// `b = 2*(p0-2p1+p2)`, `c = p1-p0`), so there are up to two roots per
    /// axis; `a == 0` is the EXACT (not approximate) case where that
    /// quadratic degenerates to linear, which the quadratic formula cannot
    /// handle (it would divide by zero).
    private static func cubicExtrema(p0: Double, p1: Double, p2: Double, p3: Double) -> [Double] {
        let a = -p0 + 3 * p1 - 3 * p2 + p3
        let b = 2 * (p0 - 2 * p1 + p2)
        let c = p1 - p0

        if a == 0 {
            guard b != 0 else { return [] }
            let t = -c / b
            return (t.isFinite && t > 0 && t < 1) ? [t] : []
        }

        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        let denominator = 2 * a
        return [(-b + root) / denominator, (-b - root) / denominator]
            .filter { $0.isFinite && $0 > 0 && $0 < 1 }
    }
}
