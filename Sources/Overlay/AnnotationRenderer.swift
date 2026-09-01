import Foundation

/// Pixel-to-point conversion shared by renderer code and deterministic tests.
/// MCP drawing dimensions are physical backing pixels; drawing APIs on both
/// platforms consume points, so lengths must be divided by the active backing
/// scale just like positions are.
///
/// Every function here is a pure, `enum`-namespaced static func with no
/// drawing-surface state (no `NSView`, no `bounds`, no `NSGraphicsContext`,
/// no platform window handle of any kind) -- that is deliberate, so unit
/// tests can call them directly with no GUI session. Every `AnnotationRenderer`
/// draw method routes its coordinate math through these rather than
/// open-coding the conversions themselves.
enum OverlayDrawingMetrics {
    static func points(forPhysicalPixels pixels: Double, backingScaleFactor: CGFloat) -> CGFloat {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1.0
        return CGFloat(pixels) / scale
    }

    /// Flips a Y coordinate from MCP's top-left-origin physical-pixel space
    /// into the renderer's bottom-left-origin point space for a canvas of
    /// height `viewHeightPoints`.
    ///
    /// MCP coordinates are top-left origin in physical pixels; the renderer's
    /// drawing space is bottom-left origin in points (see `DrawingContext`'s
    /// coordinate-space doc comment -- this is deliberately kept true on
    /// every platform, not just macOS). Every annotation kind needs this same
    /// flip for its Y (and only its Y) coordinate -- this replaces what used
    /// to be six separately open-coded `viewHeight - (CGFloat(py) / scale)`
    /// expressions in `OverlayView`.
    static func viewY(forPhysicalPixelY pixels: Double,
                       backingScaleFactor: CGFloat,
                       viewHeightPoints: CGFloat) -> CGFloat {
        return viewHeightPoints - points(forPhysicalPixels: pixels, backingScaleFactor: backingScaleFactor)
    }

    /// Convenience combining `points(forPhysicalPixels:)` for X and
    /// `viewY(forPhysicalPixelY:)` for Y, for the common case of converting a
    /// single MCP-space (top-left, physical pixels) point into a single
    /// renderer-space (bottom-left, points) point in one call.
    static func point(forPhysicalPixelX x: Double,
                       y: Double,
                       backingScaleFactor: CGFloat,
                       viewHeightPoints: CGFloat) -> CGPoint {
        return CGPoint(
            x: points(forPhysicalPixels: x, backingScaleFactor: backingScaleFactor),
            y: viewY(forPhysicalPixelY: y, backingScaleFactor: backingScaleFactor, viewHeightPoints: viewHeightPoints)
        )
    }

    /// Clamps a caller-supplied opacity into the 0...1 alpha range every
    /// drawing backend expects.
    ///
    /// Replaces six separately open-coded `CGFloat(min(max(x, 0), 1))`
    /// expressions in `OverlayView`. Non-finite input collapses to 0 rather
    /// than propagating NaN into a drawn color's alpha, where it would render
    /// unpredictably instead of simply invisibly.
    static func clampedAlpha(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }
}

/// Platform-neutral home for the entire annotation drawing algorithm.
///
/// This is the ENTIRE render algorithm that used to live directly on
/// `OverlayView` (`drawAnnotations`/`drawKind`/`drawVectorPath`/`drawImage`/
/// `drawText`), rewritten against `DrawingContext`, `ChalkPath`, `ChalkColor`,
/// and `ChalkTransform` instead of `CGContext`/`CGPath`/`NSColor`/
/// `CGAffineTransform`. It has no AppKit, CoreGraphics, or Windows dependency
/// of any kind, so it compiles and runs identically on both platforms; only
/// the `DrawingContext` implementation it is handed differs per platform.
public struct AnnotationRenderer {
    /// Draws an explicit annotation snapshot through `context`. The live
    /// overlay (`OverlayView.draw(_:)`, via `CoreGraphicsDrawingContext`) and
    /// `AnnotationVerificationCompositor` both funnel through this exact
    /// method, so the verification image cannot drift into a second,
    /// approximate implementation of vector paths, images, or batches.
    ///
    /// The caller owns filtering and the graphics-state transform. The live
    /// overlay passes its view bounds unchanged; the verifier scales a source
    /// screen-sized point canvas into the supplied screenshot before calling.
    ///
    /// `imageForAssetId` resolves an image annotation's raster asset id to a
    /// `RasterImageHandle`, or `nil` if it is unavailable (in which case that
    /// image annotation is skipped, exactly as a missing asset was before).
    /// The CALLER is responsible for snapshotting every raster this batch of
    /// annotations needs -- e.g. via `RasterAssetStore.shared.lease(ids:)` on
    /// macOS -- and keeping those handles strongly referenced (the closure
    /// capturing the lease is enough) for the full duration of this call. A
    /// concurrent clear can otherwise release the store's ownership mid-draw;
    /// snapshotting up front, before this method iterates any annotation, is
    /// what keeps every image reference alive through the entire recursive
    /// draw.
    public static func drawAnnotations(
        _ annotations: [Annotation],
        into context: DrawingContext,
        canvasSize: CGSize,
        scaleFactor: CGFloat,
        imageForAssetId: (String) -> RasterImageHandle?
    ) {
        let scale = scaleFactor > 0 ? scaleFactor : 1.0
        let viewHeight = canvasSize.height

        for annotation in annotations {
            context.save()
            context.setGlobalAlpha(Double(OverlayDrawingMetrics.clampedAlpha(annotation.opacity)))
            context.translate(
                x: Double(OverlayDrawingMetrics.points(forPhysicalPixels: annotation.offsetX, backingScaleFactor: scale)),
                y: -Double(OverlayDrawingMetrics.points(forPhysicalPixels: annotation.offsetY, backingScaleFactor: scale))
            )
            drawKind(annotation.kind, colorHex: annotation.colorHex,
                     scale: scale, viewHeight: viewHeight, context: context,
                     imageForAssetId: imageForAssetId)
            context.restore()
        }
    }

    /// Recursive renderer used for both a top-level annotation and every item
    /// inside an atomic batch. Keeping dispatch here means live drawing and
    /// synthetic verification support exactly the same primitive set.
    private static func drawKind(_ kind: AnnotationKind, colorHex: String,
                                  scale: CGFloat, viewHeight: CGFloat, context: DrawingContext,
                                  imageForAssetId: (String) -> RasterImageHandle?) {
        switch kind {
            case .vectorPath(let data, let strokeColorHex, let strokeWidth, let strokeOpacity,
                             let fillColorHex, let fillOpacity, let dash, let usesEvenOddFillRule,
                             let coordinateScaleX, let coordinateScaleY):
                drawVectorPath(data: data, strokeColorHex: strokeColorHex, strokeWidth: strokeWidth,
                               strokeOpacity: strokeOpacity, fillColorHex: fillColorHex, fillOpacity: fillOpacity, dash: dash,
                               usesEvenOddFillRule: usesEvenOddFillRule,
                               coordinateScaleX: coordinateScaleX, coordinateScaleY: coordinateScaleY,
                               fallbackColorHex: colorHex, scale: scale, viewHeight: viewHeight, context: context)

            case .image(let assetId, let x, let y, let width, let height, let rotationDegrees, let opacity):
                drawImage(assetId: assetId, x: x, y: y, width: width, height: height,
                          rotationDegrees: rotationDegrees, opacity: opacity,
                          scale: scale, viewHeight: viewHeight, context: context,
                          imageForAssetId: imageForAssetId)

            case .text(let text, let x, let y, let fontSize, let textColorHex, let backgroundColorHex,
                       let backgroundOpacity, let paddingPx, let opacity):
                drawText(text: text, x: x, y: y, fontSize: fontSize, textColorHex: textColorHex,
                         backgroundColorHex: backgroundColorHex, backgroundOpacity: backgroundOpacity,
                         paddingPx: paddingPx, opacity: opacity, scale: scale, viewHeight: viewHeight,
                         context: context)

            case .batch(let items):
                for item in items {
                    context.save()
                    drawKind(item.kind, colorHex: item.colorHex,
                             scale: scale, viewHeight: viewHeight, context: context,
                             imageForAssetId: imageForAssetId)
                    context.restore()
                }
        }
    }

    // MARK: - Universal free-draw rendering

    private static func drawVectorPath(
        data: String,
        strokeColorHex: String?,
        strokeWidth: Double,
        strokeOpacity: Double,
        fillColorHex: String?,
        fillOpacity: Double,
        dash: [Double],
        usesEvenOddFillRule: Bool,
        coordinateScaleX: Double,
        coordinateScaleY: Double,
        fallbackColorHex: String,
        scale: CGFloat,
        viewHeight: CGFloat,
        context: DrawingContext
    ) {
        // Routed through SVGPathCache rather than SVGPathParser directly:
        // this runs inside every repaint, so an uncached parse re-tokenised
        // (and re-converted every arc command) on every one. See
        // SVGPathCache for why reusing the parsed path is pixel-identical.
        guard let sourcePath = try? SVGPathCache.path(for: data) else { return }
        let transform = ChalkTransform(
            a: coordinateScaleX / Double(scale), b: 0,
            c: 0, d: -coordinateScaleY / Double(scale),
            tx: 0, ty: Double(viewHeight)
        )
        let path = sourcePath.transformed(by: transform)

        if let fillColorHex, fillOpacity > 0 {
            let parsedFill = ColorParser.parse(fillColorHex)
            let fill = parsedFill.multiplyingAlpha(by: Double(OverlayDrawingMetrics.clampedAlpha(fillOpacity)))
            context.fill(path: path, color: fill, evenOdd: usesEvenOddFillRule)
        }

        if strokeWidth > 0 {
            // The fallback hex is parsed HERE, lazily, rather than by the
            // caller: the annotation-level colour is a safety net that the MCP
            // layer works to keep unreachable (`patchKind` refuses to leave a
            // stroked path with no stroke colour -- "instead of allowing the
            // renderer fallback color to reappear"), so parsing it eagerly on
            // every repaint bought a colour that is essentially never used. It
            // stays as the fallback because in-process callers can still build
            // a stroked path with no stroke colour.
            let stroke = ColorParser.parse(strokeColorHex ?? fallbackColorHex)
            let strokeColor = stroke.multiplyingAlpha(by: Double(OverlayDrawingMetrics.clampedAlpha(strokeOpacity)))
            let lineWidth = OverlayDrawingMetrics.points(forPhysicalPixels: strokeWidth, backingScaleFactor: scale)
            let dashLengths = dash.map { Double(OverlayDrawingMetrics.points(forPhysicalPixels: $0, backingScaleFactor: scale)) }
            // Round cap and round join are baked into every `DrawingContext.stroke`
            // implementation -- see that protocol method's doc comment -- so
            // they are not parameters here.
            context.stroke(path: path, color: strokeColor, lineWidth: Double(lineWidth), dash: dashLengths)
        }
    }

    private static func drawImage(
        assetId: String,
        x xPx: Double,
        y yPx: Double,
        width widthPx: Double,
        height heightPx: Double,
        rotationDegrees: Double,
        opacity: Double,
        scale: CGFloat,
        viewHeight: CGFloat,
        context: DrawingContext,
        imageForAssetId: (String) -> RasterImageHandle?
    ) {
        guard let handle = imageForAssetId(assetId) else { return }
        let x = OverlayDrawingMetrics.points(forPhysicalPixels: xPx, backingScaleFactor: scale)
        let width = OverlayDrawingMetrics.points(forPhysicalPixels: widthPx, backingScaleFactor: scale)
        let height = OverlayDrawingMetrics.points(forPhysicalPixels: heightPx, backingScaleFactor: scale)
        let topY = OverlayDrawingMetrics.viewY(forPhysicalPixelY: yPx, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let rect = CGRect(x: x, y: topY - height, width: width, height: height)

        context.save()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.translate(x: Double(center.x), y: Double(center.y))
        // Public coordinates are top-left/y-down, so positive rotation is
        // documented as clockwise. The renderer's y-up context (see
        // `DrawingContext`'s coordinate-space doc comment) needs the negation.
        context.rotate(radians: Double(-rotationDegrees * .pi / 180))
        context.translate(x: -Double(center.x), y: -Double(center.y))
        context.drawImage(handle, in: rect, alpha: Double(OverlayDrawingMetrics.clampedAlpha(opacity)))
        context.restore()
    }

    private static func drawText(
        text: String,
        x xPx: Double,
        y yPx: Double,
        fontSize fontSizePx: Double,
        textColorHex: String,
        backgroundColorHex: String?,
        backgroundOpacity: Double,
        paddingPx: Double,
        opacity: Double,
        scale: CGFloat,
        viewHeight: CGFloat,
        context: DrawingContext
    ) {
        let fontSize = OverlayDrawingMetrics.points(forPhysicalPixels: fontSizePx, backingScaleFactor: scale)
        let padding = OverlayDrawingMetrics.points(forPhysicalPixels: paddingPx, backingScaleFactor: scale)
        guard fontSize > 0 else { return }
        let primitiveOpacity = OverlayDrawingMetrics.clampedAlpha(opacity)
        let textColor = ColorParser.parse(textColorHex)
        let glyphSize = context.measureText(text, fontSize: Double(fontSize))
        let width = max(1, glyphSize.width)
        let height = max(1, glyphSize.height)
        let x = OverlayDrawingMetrics.points(forPhysicalPixels: xPx, backingScaleFactor: scale)
        let topY = OverlayDrawingMetrics.viewY(forPhysicalPixelY: yPx, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let textRect = CGRect(x: x + padding, y: topY - padding - height, width: width, height: height)
        let backgroundRect = textRect.insetBy(dx: -padding, dy: -padding)
        if let backgroundColorHex, backgroundOpacity > 0 {
            let parsedBackground = ColorParser.parse(backgroundColorHex)
            let background = parsedBackground.multiplyingAlpha(
                by: Double(OverlayDrawingMetrics.clampedAlpha(backgroundOpacity)) * Double(primitiveOpacity)
            )
            context.fill(rect: backgroundRect, color: background)
        }
        context.drawText(text, in: textRect, fontSize: Double(fontSize), color: textColor.multiplyingAlpha(by: Double(primitiveOpacity)))
    }
}
