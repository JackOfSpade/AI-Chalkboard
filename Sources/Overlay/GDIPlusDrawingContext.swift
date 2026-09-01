#if os(Windows)
import CChalkboardWin
import Foundation

/// `DrawingContext` implementation backed by the GDI+ render target the
/// `CChalkboardWin` C shim exposes (`ChalkRenderTarget` / `chalk_rt_*`).
/// This is the Windows analogue of `CoreGraphicsDrawingContext`: the ONLY
/// file allowed to convert a `ChalkPath`/`ChalkColor` into the shim's
/// `ChalkPathElement`/raw r,g,b,a doubles, or a `RasterImageHandle` into a
/// `ChalkImage`; `AnnotationRenderer` itself never does.
///
/// ===========================================================================
/// COORDINATE CONTRACT -- READ THIS BEFORE TOUCHING ANY TRANSFORM CODE BELOW
/// ===========================================================================
///
/// `AnnotationRenderer` (and the `DrawingContext` protocol it is written
/// against) works in a BOTTOM-LEFT-origin, Y-UP point space -- AppKit's
/// native convention. GDI+'s `ChalkRenderTarget` is TOP-LEFT-origin, Y-DOWN
/// (row 0 of `chalk_rt_pixels` is the top row -- see chalkboard_win.h
/// Section 1's banner comment). This class bridges that gap exactly ONCE, at
/// construction, by concatenating the flip
///
///     chalk_rt_concat_transform(target, 1, 0, 0, -1, 0, height)
///
/// onto the target's transform before this object is ever handed to a
/// caller. That single matrix maps a renderer-space point `(x, y)` to the
/// device pixel `(x, height - y)` -- exactly the Y-up-to-Y-down conversion --
/// and because `chalk_rt_concat_transform` uses `MatrixOrderPrepend` (new
/// transforms compose UNDER the existing ones, the same nesting order
/// `CGContext.translateBy`/`.rotate` use), every `translate(x:y:)` and
/// `rotate(radians:)` the renderer issues afterward keeps composing
/// correctly on top of this base flip, with no per-call flipping anywhere
/// else in this file for VECTOR content (paths, rects): a filled/stroked
/// path is just a list of points, and re-mapping every one of those points
/// through the same flip that repositions everything else reproduces the
/// correct shape at the correct place -- there is no separate "content" to
/// mirror.
///
/// `save()`/`restore()` can never discard this base flip. It is baked into
/// the target's transform via `chalk_rt_concat_transform`, never pushed
/// through `chalk_rt_save` -- so it does not live on the shim's internal
/// save/restore stack at all. Every `save()` this class performs on the
/// renderer's behalf happens strictly AFTER construction (the renderer only
/// ever sees this object once `init?` has already returned), so the base
/// flip is always the bottom of whatever transform state is in effect, and
/// even a hypothetical unbalanced `restore()` (more restores than saves)
/// cannot pop it away: `chalk_rt_restore` on an empty stack fails with
/// `CHALK_ERR_INVALID_ARGUMENT` (logged, not silently eaten) rather than
/// reaching past the baseline transform, because there is nothing on the
/// stack past the baseline TO pop.
///
/// ---------------------------------------------------------------------
/// THE GOTCHA: images and text are NOT "just points" -- they are ORIENTED
/// raster/glyph content, and GDI+ does not treat that content
/// flip-awarely the way AppKit's `NSImage.draw(in:)` does.
/// ---------------------------------------------------------------------
///
/// `Graphics::DrawImage(image, destRect)` and `Graphics::DrawString(text,
/// font, destRect, ...)` both anchor their content at `destRect`'s `(x, y)`
/// UNCONDITIONALLY as the "top" -- image source row 0, or the first line of
/// text -- and lay it out growing in GDI+'s own fixed "+y is down" sense in
/// the coordinate frame the call is made in, and only THEN map that whole
/// laid-out shape through the current transform to device pixels. Under our
/// base flip (or any transform with negative determinant), that means the
/// image/glyph content itself comes out MIRRORED top-to-bottom, not merely
/// repositioned -- the same class of bug the `DrawingContext` protocol's own
/// header comment warns about ("silently mirror every annotation
/// vertically"), just confined to raster/text content instead of the whole
/// frame. Vector fills/strokes do not have this problem (see above) --
/// ONLY `drawImage` and `drawText` do.
///
/// The fix, applied by `withUprightContentTransform(around:)` below: wrap
/// just the `chalk_rt_draw_image`/`chalk_rt_draw_text` call in its own
/// `chalk_rt_save`/local flip-about-the-content-rect's-own-vertical-center/
/// `chalk_rt_restore`. Composing a SECOND Y-reflection (about `rect.midY`)
/// with the ambient transform's existing reflection (the base flip, or the
/// base flip further composed with the renderer's own translate/rotate
/// calls -- rotation and translation are both determinant +1, so they never
/// change how many reflections are "in effect") always yields a NET
/// determinant of `(-1) * (+1)^n * (-1) = +1` for the two-reflection stack:
/// an orientation-PRESERVING map. Concretely, composing the local flip
/// `y1 = -y0 + 2*midY` with the base flip `y2 = -y1 + height` collapses to
/// `y2 = y0 + (height - 2*midY)` -- a pure Y TRANSLATION, no reflection left
/// at all -- which is exactly "reposition this content correctly, draw it
/// upright, do not mirror it." This is why the same helper works for both
/// `drawImage` and `drawText`, and why it stays correct even when the
/// renderer has already applied its own rotate/translate for an image's
/// `rotationDegrees` (rotation does not reintroduce or remove a reflection,
/// so the two-flip cancellation above holds regardless of what rotation is
/// already in effect).
///
/// Verified empirically against the real shim: see the `bridgeverify`
/// scratch package built alongside this file, which renders a fill and a
/// glyph and inspects the actual pixel rows (reported in this change's
/// summary) rather than trusting this derivation on paper alone.
final class GDIPlusDrawingContext: DrawingContext {
    private let target: ChalkRenderTarget

    /// The render target's pixel dimensions -- exposed (alongside
    /// `pixelBuffer`/`bytesPerRow`) because the overlay window needs the raw
    /// premultiplied-BGRA bits and their stride to hand to
    /// `UpdateLayeredWindow` after every repaint.
    let pixelWidth: Int
    let pixelHeight: Int

    /// Creates a `width` x `height` GDI+ render target and seeds it with the
    /// bottom-left-origin/Y-up base flip described above. Returns `nil` if
    /// the shim could not create the target (invalid size, or a GDI+/GDI
    /// allocation failure -- see `chalk_rt_create`'s doc comment) or, in the
    /// practically-unreachable case that concatenating the seed transform
    /// onto a just-created target fails, in which case the half-built target
    /// is destroyed here rather than handed to a caller in a state where the
    /// coordinate contract does not hold.
    convenience init?(width: Int, height: Int) {
        self.init(width: width, height: height, scaleX: 1, scaleY: 1)
    }

    /// Creates a `width` x `height` GDI+ render target seeded with the SAME
    /// bottom-left-origin/Y-up coordinate contract as `init(width:height:)`,
    /// but additionally scales each renderer-space unit by `(scaleX, scaleY)`
    /// device pixels as part of that same base transform, before the Y-flip.
    ///
    /// USED BY: `AnnotationVerificationCompositor`'s Windows path, which
    /// draws `AnnotationRenderer`'s shared POINT-space canvas
    /// (`screen.widthPt` x `screen.heightPt`) directly at screenshot-PIXEL
    /// resolution -- the exact same two-step "point-space transform, then
    /// device-scale" macOS's compositor performs via
    /// `cgContext.scaleBy(imageWidth/widthPt, imageHeight/heightPt)`
    /// immediately before wrapping its `CGContext` in
    /// `CoreGraphicsDrawingContext` (see that file's call site). `scaleX`/
    /// `scaleY` are deliberately independent, not required to be equal:
    /// `ScreenshotGeometry.fullDisplayScale` only guarantees they differ by
    /// at most a fraction of a pixel per axis, and preserving that (rather
    /// than rounding both axes to one shared ratio) is what keeps this path
    /// equivalent to the anisotropic `scaleBy` call it mirrors.
    ///
    /// WHY THIS STAYS SAFE ON TOP OF THE COORDINATE-CONTRACT DERIVATION
    /// ABOVE: the base transform becomes `x' = scaleX*x`,
    /// `y' = height - scaleY*y` instead of `x' = x`, `y' = height - y`.
    /// Composing `withUprightContentTransform`'s local flip
    /// `y1 = -y0 + 2*midY` with this scaled base gives
    /// `y2 = height - scaleY*(-y0 + 2*midY) = scaleY*y0 + (height - 2*scaleY*midY)`
    /// -- still a pure Y SCALE-AND-TRANSLATE with a POSITIVE coefficient
    /// (`scaleY > 0`), i.e. still orientation-preserving, for the same
    /// reason the unscaled derivation collapses to a pure translation: a
    /// positive scale factor has positive determinant, so it changes
    /// magnitude, never which way is "up". The two-reflection cancellation
    /// argument in the class doc comment therefore goes through completely
    /// unchanged with an anisotropic scale folded into the base transform,
    /// and every existing call site keeps its exact current behavior via the
    /// `scaleX: 1, scaleY: 1` convenience initializer above.
    init?(width: Int, height: Int, scaleX: Double, scaleY: Double) {
        guard width > 0, height > 0,
              scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        guard let target = chalk_rt_create(Int32(width), Int32(height)) else {
            Logger.shared.log("GDIPlusDrawingContext: chalk_rt_create(\(width), \(height)) returned NULL", level: "ERROR")
            return nil
        }
        // Seed the Y-up/Y-down (and, here, scaled) base flip BEFORE this
        // object is returned to any caller, and therefore before the
        // renderer can possibly call save()/translate()/rotate() -- see the
        // coordinate-contract doc comment above for why that ordering is
        // what keeps this flip un-discardable.
        let flipStatus = chalk_rt_concat_transform(target, scaleX, 0, 0, -scaleY, 0, Double(height))
        guard flipStatus == 0 else {
            Logger.shared.log("GDIPlusDrawingContext: seeding scaled base Y-flip (scaleX=\(scaleX), scaleY=\(scaleY)) failed with shim status \(flipStatus); destroying half-built target rather than returning one with a broken coordinate contract", level: "ERROR")
            chalk_rt_destroy(target)
            return nil
        }
        self.target = target
        self.pixelWidth = width
        self.pixelHeight = height
    }

    deinit {
        chalk_rt_destroy(target)
    }

    // MARK: - Pixel access (for UpdateLayeredWindow)

    /// The target's premultiplied-BGRA pixel buffer, top-down (row 0 = top
    /// row), suitable to pass directly as `UpdateLayeredWindow`'s bitmap
    /// bits. `nil` only if the target became invalid (should not happen for
    /// a target this class itself owns and never lets outlive `deinit`).
    var pixelBuffer: UnsafeMutablePointer<UInt8>? {
        chalk_rt_pixels(target)
    }

    /// Row pitch of `pixelBuffer`, in bytes.
    var bytesPerRow: Int {
        Int(chalk_rt_stride(target))
    }

    /// Clears the entire backing buffer to fully transparent pixels. Not
    /// part of `DrawingContext` -- `AnnotationRenderer` never needs to clear
    /// a surface, only draw into one -- but the Windows overlay window
    /// (which, unlike a macOS `CGContext` handed a fresh bitmap each frame,
    /// owns this target across repaints) needs an explicit way to reset it
    /// before redrawing the next frame.
    func clear() {
        let status = chalk_rt_clear(target)
        if status != 0 {
            logShimFailure("chalk_rt_clear", status)
        }
    }

    // MARK: - DrawingContext

    func save() {
        let status = chalk_rt_save(target)
        if status != 0 {
            logShimFailure("chalk_rt_save", status)
        }
    }

    func restore() {
        let status = chalk_rt_restore(target)
        if status != 0 {
            logShimFailure("chalk_rt_restore", status)
        }
    }

    func setGlobalAlpha(_ alpha: Double) {
        let status = chalk_rt_set_global_alpha(target, alpha)
        if status != 0 {
            logShimFailure("chalk_rt_set_global_alpha", status)
        }
    }

    func translate(x: Double, y: Double) {
        concat(ChalkTransform.translation(x: x, y: y))
    }

    func rotate(radians: Double) {
        concat(ChalkTransform.rotation(radians: radians))
    }

    func fill(path: ChalkPath, color: ChalkColor, evenOdd: Bool) {
        let elements = makeElements(path)
        let status: Int32 = elements.withUnsafeBufferPointer { buf in
            chalk_rt_fill_path(target, buf.baseAddress, Int32(buf.count),
                                color.red, color.green, color.blue, color.alpha,
                                evenOdd ? 1 : 0)
        }
        if status != 0 {
            logShimFailure("chalk_rt_fill_path", status)
        }
    }

    func stroke(path: ChalkPath, color: ChalkColor, lineWidth: Double, dash: [Double]) {
        let elements = makeElements(path)
        // Round cap and round join are FIXED inside the shim itself (see
        // chalk_rt_stroke_path's doc comment) -- this call never has a
        // parameter for them, matching CoreGraphicsDrawingContext's own
        // hard-coded `.round`/`.round`.
        let status: Int32 = elements.withUnsafeBufferPointer { pathBuf in
            if dash.isEmpty {
                return chalk_rt_stroke_path(target, pathBuf.baseAddress, Int32(pathBuf.count),
                                             color.red, color.green, color.blue, color.alpha,
                                             lineWidth, nil, 0)
            } else {
                return dash.withUnsafeBufferPointer { dashBuf in
                    chalk_rt_stroke_path(target, pathBuf.baseAddress, Int32(pathBuf.count),
                                          color.red, color.green, color.blue, color.alpha,
                                          lineWidth, dashBuf.baseAddress, Int32(dashBuf.count))
                }
            }
        }
        if status != 0 {
            logShimFailure("chalk_rt_stroke_path", status)
        }
    }

    func fill(rect: CGRect, color: ChalkColor) {
        // A solid rectangle fill has no oriented "content" to mirror (see
        // the class-level doc comment) -- pass the rect through unchanged,
        // exactly like fill(path:)/stroke(path:) do.
        let status = chalk_rt_fill_rect(target, Double(rect.minX), Double(rect.minY),
                                         Double(rect.width), Double(rect.height),
                                         color.red, color.green, color.blue, color.alpha)
        if status != 0 {
            logShimFailure("chalk_rt_fill_rect", status)
        }
    }

    func drawImage(_ handle: RasterImageHandle, in rect: CGRect, alpha: Double) {
        // `WindowsRasterImage` is the only `RasterImageHandle` this platform
        // ever vends -- see `CoreGraphicsDrawingContext.drawImage`'s
        // matching comment for why failing closed on a cast miss (rather
        // than force-casting) is the right call here too.
        guard let handle = handle as? WindowsRasterImage else { return }
        withUprightContentTransform(around: rect) {
            let status = chalk_rt_draw_image(target, handle.image,
                                              Double(rect.minX), Double(rect.minY),
                                              Double(rect.width), Double(rect.height),
                                              alpha)
            if status != 0 {
                logShimFailure("chalk_rt_draw_image", status)
            }
        }
    }

    func measureText(_ text: String, fontSize: Double) -> CGSize {
        var w: Double = 0
        var h: Double = 0
        let status: Int32 = withWideString(text) { wtext in
            chalk_rt_measure_text(wtext, fontSize, &w, &h)
        }
        if status != 0 {
            logShimFailure("chalk_rt_measure_text", status)
            return .zero
        }
        return CGSize(width: w, height: h)
    }

    func drawText(_ text: String, in rect: CGRect, fontSize: Double, color: ChalkColor) {
        // chalk_rt_draw_text's (x, y) is the TOP-LEFT corner of the text box
        // in GDI+'s own "y = top, grows downward" sense -- the SAME sense
        // chalk_rt_draw_image's destRect uses (see the class-level doc
        // comment) -- so this passes (rect.minX, rect.minY) UNCHANGED and
        // relies on `withUprightContentTransform(around:)` to both
        // reposition and un-mirror the glyphs, exactly as it does for
        // images. `rect` here is `AnnotationRenderer`'s `textRect`, whose
        // origin.y is `topY - padding - height` -- i.e. `rect.minY` is the
        // visual BOTTOM of the box and `rect.maxY` is the visual TOP in the
        // renderer's Y-up space (ordinary CGRect convention: origin is the
        // minimum corner). It is tempting to instead pass `rect.maxY`
        // thinking of it as "the visual top, so that must be GDI+'s
        // top-left corner" -- that would be wrong: `withUprightContentTransform`
        // already accounts for the flip between GDI+'s "top" convention and
        // this frame's Y-up convention, and it does so by reflecting about
        // `rect.midY`, which requires the UNREFLECTED rect (i.e. the same
        // `rect.minY` used for images) as input. Passing `rect.maxY` here
        // would double-correct and draw the text `rect.height` points too
        // high.
        withUprightContentTransform(around: rect) {
            let status: Int32 = withWideString(text) { wtext in
                chalk_rt_draw_text(target, wtext, Double(rect.minX), Double(rect.minY), fontSize,
                                    color.red, color.green, color.blue, color.alpha)
            }
            if status != 0 {
                logShimFailure("chalk_rt_draw_text", status)
            }
        }
    }

    // MARK: - Transform helpers

    private func concat(_ t: ChalkTransform) {
        let status = chalk_rt_concat_transform(target, t.a, t.b, t.c, t.d, t.tx, t.ty)
        if status != 0 {
            logShimFailure("chalk_rt_concat_transform", status)
        }
    }

    /// Wraps `body` (a single `chalk_rt_draw_image`/`chalk_rt_draw_text`
    /// call) in a save/local-flip/restore that cancels the ambient
    /// transform's mirroring for ORIENTED content -- see the class-level
    /// doc comment's "THE GOTCHA" section for the full derivation. The flip
    /// is about `rect`'s own vertical center (`midY`), which is what makes
    /// this correct regardless of `rect`'s position or of any translate/
    /// rotate the renderer already applied (e.g. for `AnnotationKind.image`'s
    /// `rotationDegrees`).
    private func withUprightContentTransform(around rect: CGRect, _ body: () -> Void) {
        let midY = Double(rect.midY)
        let saveStatus = chalk_rt_save(target)
        if saveStatus != 0 {
            logShimFailure("chalk_rt_save (upright-content)", saveStatus)
        }
        let flipStatus = chalk_rt_concat_transform(target, 1, 0, 0, -1, 0, 2 * midY)
        if flipStatus != 0 {
            logShimFailure("chalk_rt_concat_transform (upright-content)", flipStatus)
        }
        body()
        let restoreStatus = chalk_rt_restore(target)
        if restoreStatus != 0 {
            logShimFailure("chalk_rt_restore (upright-content)", restoreStatus)
        }
    }

    // MARK: - Path conversion

    /// Path-element op codes, mirrored from `ChalkPathOp` in
    /// chalkboard_win.h as our own local `Int32` constants rather than
    /// referencing the imported C enum's cases by name: `ChalkPathOp` is a
    /// plain (non-`NS_ENUM`) C enum with a fixed underlying type, and
    /// exactly how ClangImporter shapes that (a Swift enum, a struct of
    /// static members, or a bare `Int32`) is an implementation detail this
    /// file should not depend on. The header documents these numeric values
    /// as a stable ABI contract, so using them directly is exactly as
    /// correct and considerably more robust to import-shape differences.
    private static let pathMove: Int32 = 0
    private static let pathLine: Int32 = 1
    private static let pathQuad: Int32 = 2
    private static let pathCubic: Int32 = 3
    private static let pathClose: Int32 = 4

    /// Converts a `ChalkPath`'s resolved element list into the flat
    /// `[ChalkPathElement]` array `chalk_rt_fill_path`/`chalk_rt_stroke_path`
    /// take. Runs on every repaint (mirrors `CoreGraphicsDrawingContext`'s
    /// `cgPath(from:)` in that respect), so this is a single linear pass
    /// with a capacity-reserved allocation and no intermediate collections.
    private func makeElements(_ path: ChalkPath) -> [ChalkPathElement] {
        var elements: [ChalkPathElement] = []
        elements.reserveCapacity(path.elements.count)
        for element in path.elements {
            switch element {
            case let .move(point):
                elements.append(ChalkPathElement(op: Self.pathMove,
                                                  x0: Double(point.x), y0: Double(point.y),
                                                  x1: 0, y1: 0, x2: 0, y2: 0))
            case let .line(point):
                elements.append(ChalkPathElement(op: Self.pathLine,
                                                  x0: Double(point.x), y0: Double(point.y),
                                                  x1: 0, y1: 0, x2: 0, y2: 0))
            case let .quad(control, to):
                elements.append(ChalkPathElement(op: Self.pathQuad,
                                                  x0: Double(control.x), y0: Double(control.y),
                                                  x1: Double(to.x), y1: Double(to.y),
                                                  x2: 0, y2: 0))
            case let .cubic(control1, control2, to):
                elements.append(ChalkPathElement(op: Self.pathCubic,
                                                  x0: Double(control1.x), y0: Double(control1.y),
                                                  x1: Double(control2.x), y1: Double(control2.y),
                                                  x2: Double(to.x), y2: Double(to.y)))
            case .close:
                elements.append(ChalkPathElement(op: Self.pathClose,
                                                  x0: 0, y0: 0, x1: 0, y1: 0, x2: 0, y2: 0))
            }
        }
        return elements
    }

    // MARK: - String bridging

    /// Converts a Swift `String` to the NUL-terminated UTF-16 buffer every
    /// text-taking shim call expects (`const uint16_t*`, per
    /// chalkboard_win.h's boundary-conventions comment).
    private func withWideString<R>(_ text: String, _ body: (UnsafePointer<UInt16>) -> R) -> R {
        var utf16 = Array(text.utf16)
        utf16.append(0)
        return utf16.withUnsafeBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }

    private func logShimFailure(_ call: String, _ status: Int32) {
        Logger.shared.log("GDIPlusDrawingContext: \(call) failed with shim status \(status)", level: "ERROR")
    }
}
#endif
