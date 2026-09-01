import Foundation

/// An opaque platform image a raster store vends to a `DrawingContext`.
///
/// `AnnotationRenderer` never sees `NSImage`, a GDI+ bitmap, or any other
/// platform image type directly -- it only ever holds one of these, obtained
/// from the caller-supplied `imageForAssetId` closure passed into
/// `AnnotationRenderer.drawAnnotations`, and hands it straight back to
/// `DrawingContext.drawImage(_:in:alpha:)` for the platform layer to unwrap.
/// This is exactly what lets the render algorithm in `AnnotationRenderer`
/// stay Foundation-only: the raster store (`RasterAssetStore` on macOS today)
/// remains a platform-layer concern that never has to be imported by shared
/// code.
public protocol RasterImageHandle: AnyObject {
    /// The image's width in decoded pixels (not points).
    var pixelWidth: Int { get }
    /// The image's height in decoded pixels (not points).
    var pixelHeight: Int { get }
}

/// The drawing surface `AnnotationRenderer` paints annotations through.
///
/// One implementation exists per platform: `CoreGraphicsDrawingContext` wraps
/// a `CGContext` on macOS; a Windows implementation would wrap GDI+/Direct2D
/// (or whichever native surface `CChalkboardWin` exposes). `AnnotationRenderer`
/// is written entirely against this protocol -- plus the platform-neutral
/// `ChalkPath`/`ChalkColor`/`ChalkTransform` types -- and never imports
/// AppKit, CoreGraphics, or any other platform graphics framework.
///
/// COORDINATE SPACE -- READ BEFORE IMPLEMENTING THIS ON WINDOWS:
/// Every method here is defined in a BOTTOM-LEFT-origin point space with Y
/// increasing UPWARD -- AppKit's native drawing convention. `AnnotationRenderer`
/// deliberately keeps that exact model rather than switching to a top-left,
/// Y-down space: `canvasSize` passed into `AnnotationRenderer.drawAnnotations`
/// is the size of this bottom-left-origin canvas, `OverlayDrawingMetrics.viewY`
/// flips MCP's top-left, physical-pixel Y into this space before any drawing
/// call is made, and every rect/point this protocol's methods receive is
/// already expressed in it.
///
/// A Windows `DrawingContext` implementation is responsible for PRESENTING a
/// bottom-left-origin, Y-up context to `AnnotationRenderer` -- either by
/// flipping GDI+/Direct2D's native top-left/Y-down space itself once per
/// frame (e.g. concatenating a `scale(1, -1)` + `translate(0, canvasHeight)`
/// transform before any drawing call) or by translating every incoming
/// coordinate at the call site before handing it to the native API. Getting
/// this wrong will not fail to compile or obviously crash -- it will silently
/// mirror every annotation vertically on screen, which is exactly the class
/// of bug this comment exists to prevent.
public protocol DrawingContext: AnyObject {
    /// Pushes a copy of the current graphics state (transform, alpha, clip)
    /// onto a stack. Must be paired with a matching `restore()`.
    func save()

    /// Pops the graphics state stack, undoing everything since the matching
    /// `save()`.
    func restore()

    /// Sets the alpha multiplier applied to every subsequent drawing
    /// operation until the next `restore()`. `AnnotationRenderer` sets this
    /// once per top-level annotation, for that annotation's container-wide
    /// opacity.
    func setGlobalAlpha(_ alpha: Double)

    /// Translates the current transformation matrix by `(x, y)` in this
    /// context's bottom-left-origin point space. Used for an annotation's
    /// backing-pixel offset, and (paired with `rotate(radians:)`) for
    /// rotating an image about its own center: translate to the center,
    /// rotate, translate back.
    func translate(x: Double, y: Double)

    /// Rotates the current transformation matrix by `radians` about the
    /// current origin. Positive values rotate counterclockwise in this
    /// bottom-left-origin, Y-up space -- a caller wanting the CLOCKWISE
    /// rotation `AnnotationKind.image`'s `rotationDegrees` documents (public,
    /// top-left/Y-down coordinates) negates the angle before calling this.
    func rotate(radians: Double)

    /// Fills `path` with `color`, using the even-odd fill rule when
    /// `evenOdd` is true and the nonzero-winding rule otherwise.
    func fill(path: ChalkPath, color: ChalkColor, evenOdd: Bool)

    /// Strokes `path` with `color`, `lineWidth` points wide. Round line cap
    /// and round line join are the FIXED stroke style every caller in this
    /// codebase always wants -- they are not parameters here, and every
    /// implementation of this method must bake them in rather than exposing
    /// a configurable cap/join. `dash` is a phase-0 dash pattern in the same
    /// point units as `lineWidth`; an empty array means a solid stroke (no
    /// dash pattern applied at all, not a degenerate zero-length one).
    func stroke(path: ChalkPath, color: ChalkColor, lineWidth: Double, dash: [Double])

    /// Fills the axis-aligned rect `rect` with the solid color `color`. Used
    /// for a text annotation's background box.
    func fill(rect: CGRect, color: ChalkColor)

    /// Draws `handle`'s full image, scaled to exactly fill `rect`, modulated
    /// by `alpha`.
    func drawImage(_ handle: RasterImageHandle, in rect: CGRect, alpha: Double)

    /// Measures the tight (integral) bounding size `text` would occupy if
    /// drawn at `fontSize` in this context's default system font, with no
    /// wrapping. `AnnotationRenderer` uses this to size a text annotation's
    /// background box before any drawing happens, so it must match
    /// `drawText`'s own layout exactly.
    func measureText(_ text: String, fontSize: Double) -> CGSize

    /// Draws `text` in `color`, at `fontSize`, laid out inside `rect` (which
    /// a prior `measureText` call sized).
    func drawText(_ text: String, in rect: CGRect, fontSize: Double, color: ChalkColor)
}
