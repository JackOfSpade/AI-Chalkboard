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

    /// THE one definition of the `scaleFactor` that
    /// `AnnotationRenderer.drawAnnotations` must be given for a canvas
    /// covering one whole display. All FOUR full-display call sites read it:
    /// the two LIVE overlays (`OverlayView.draw(_:)` on macOS,
    /// `WindowsOverlayWindow.repaint(annotations:imageForAssetId:)` on
    /// Windows) and BOTH platform branches of
    /// `AnnotationVerificationCompositor`.
    ///
    /// WHY IT IS PLATFORM-CONDITIONAL AT ALL: MCP coordinates are always
    /// physical backing pixels, but the two platforms hand the renderer
    /// canvases measured in different units, so the divisor that converts one
    /// into the other differs.
    ///   * macOS overlays draw on a POINT canvas (`NSScreen.frame` points;
    ///     the verifier scales that same point canvas into the screenshot),
    ///     so MCP backing pixels DIVIDE by the display's backing scale.
    ///   * Windows overlays draw on a PHYSICAL-PIXEL canvas whose coordinates
    ///     already ARE the MCP coordinates (see `ScreenSnapshot.swift`'s
    ///     Windows `buildScreenInfos()` note and `GDIPlusDrawingContext`'s
    ///     coordinate contract), so the divisor is exactly 1 no matter what
    ///     DPI that monitor runs at.
    ///
    /// WHY ONE SHARED DEFINITION AND NOT A LITERAL PER CALL SITE: a
    /// verification rendered at a different scale than the live overlay
    /// reports a placement NOTHING EVER PAINTED, and the agent loop then
    /// AMPLIFIES that error by "correcting" a correct annotation. That is
    /// precisely what the Windows verifier used to do -- it passed the
    /// display's `backingScaleFactor` against the same physical-pixel canvas
    /// the live window paints 1:1. On a 150%-DPI monitor, a circle drawn live
    /// at (1920, 1080) r=200 composited into the verification image at
    /// (1280, 720) r=133: displaced and undersized by the whole DPI factor,
    /// in a picture whose entire job is to be believed. The live path and the
    /// verification path must therefore resolve the SAME number from the SAME
    /// code, not from two literals that agree only until one is edited.
    ///
    /// - Parameter displayBackingScaleFactor: the display's
    ///   `ScreenInfo.backingScaleFactor`. IGNORED on Windows, where the answer
    ///   is the constant 1 above; a Windows caller that has no `ScreenInfo` in
    ///   hand at paint time may therefore pass anything (see
    ///   `WindowsOverlayWindow.repaint`, which does exactly that and says so).
    static func rendererScaleFactor(displayBackingScaleFactor: CGFloat) -> CGFloat {
        #if os(Windows)
        return 1.0
        #else
        // No clamping of a non-positive scale here: `drawAnnotations`
        // already substitutes 1.0 for one, and giving the same input two
        // separate places to be corrected is how the two drift apart.
        return displayBackingScaleFactor
        #endif
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

/// Optional fast path a `DrawingContext` can adopt when it can paint a fill
/// and a stroke of the SAME path more cheaply than two independent calls.
///
/// WHY THIS EXISTS: a filled-AND-stroked vector path used to reach the
/// platform context as `fill(path:...)` followed by `stroke(path:...)`, and
/// the macOS implementation converts a `ChalkPath` into a `CGMutablePath`
/// element-by-element at the top of EACH call -- so every filled+stroked
/// annotation rebuilt the same converted path twice per frame, on the render
/// hot path `SVGPathCache` already exists to keep cheap. Adopting this
/// protocol lets a context do that conversion once and reuse it for both
/// operations.
///
/// WHY A SEPARATE REFINEMENT PROTOCOL, NOT A `DrawingContext` REQUIREMENT OR
/// A PLAIN EXTENSION METHOD: a non-requirement method added in a protocol
/// extension is STATICALLY dispatched through the `DrawingContext`
/// existential the renderer holds, so a platform's own `fillAndStroke` would
/// be silently ignored -- the exact bug class this comment exists to
/// prevent. A conditional cast to a refinement protocol restores dynamic
/// adoption while leaving `DrawingContext`'s surface -- and every existing
/// conformance (`GDIPlusDrawingContext` keeps its two-call rendering
/// byte-for-byte, without edits) -- completely unchanged.
///
/// CONTRACT: `fillAndStroke` must paint EXACTLY what
/// `fill(path:color:evenOdd:)` followed by `stroke(path:color:lineWidth:dash:)`
/// would paint -- fill first, stroke composited on top, same fixed round
/// cap/join the `stroke` doc comment requires. This is purely a
/// "convert the geometry once" optimisation; any adopter for which the two
/// forms could differ by a pixel must not adopt it.
public protocol CombinedFillStrokeDrawingContext: DrawingContext {
    func fillAndStroke(
        path: ChalkPath, fillColor: ChalkColor, evenOdd: Bool,
        strokeColor: ChalkColor, lineWidth: Double, dash: [Double]
    )
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
            // `effectiveAdjustment` is `.identity` (scaleX/Y 1, translateX/Y
            // 0) for every unanchored annotation, and multiplying by that
            // exact 1.0 / adding that exact 0.0 is bit-for-bit exact in IEEE
            // 754 -- see `AnnotationVerificationCompositorTests`'
            // `testUnanchoredAndIdentityAdjustedAnchoredAnnotationsRenderBitForBitIdentically`
            // -- so one unconditional formula serves both the anchored
            // and unanchored cases with no branch to keep in sync. Folding
            // the adjustment into the OFFSET here (rather than leaving the
            // offset alone and only scaling primitive geometry below) is
            // what makes a caller's offset_x/offset_y translate WITH the
            // tracked window exactly like the geometry it displaces --
            // see RENDERER_MATH.md's derivation for why the adjustment has
            // to be applied outermost, in the same backing-pixel space the
            // offset itself is stored in, before either is converted to
            // points.
            let adjustment = annotation.effectiveAdjustment
            context.translate(
                x: Double(OverlayDrawingMetrics.points(
                    forPhysicalPixels: annotation.offsetX * adjustment.scaleX + adjustment.translateX,
                    backingScaleFactor: scale
                )),
                y: -Double(OverlayDrawingMetrics.points(
                    forPhysicalPixels: annotation.offsetY * adjustment.scaleY + adjustment.translateY,
                    backingScaleFactor: scale
                ))
            )
            drawKind(annotation.kind, colorHex: annotation.colorHex,
                     scale: scale, viewHeight: viewHeight, context: context,
                     adjustment: adjustment,
                     imageForAssetId: imageForAssetId)
            context.restore()
        }
    }

    /// Recursive renderer used for both a top-level annotation and every item
    /// inside an atomic batch. Keeping dispatch here means live drawing and
    /// synthetic verification support exactly the same primitive set.
    ///
    /// `adjustment` carries only the SCALE half of `annotation.effectiveAdjustment`
    /// into each primitive's own coordinates -- the translate half is already
    /// baked into the graphics context by `drawAnnotations`' `context.translate`
    /// call before this is ever reached, for both a top-level annotation and
    /// every recursive `.batch` item (a `context.translate` composes onto the
    /// current transform, so nested items inherit it for free). Applying the
    /// scale again here, per primitive, is what keeps a caller's `offset_x`/
    /// `offset_y` and the drawing's own geometry both moving and resizing
    /// together as one placement, rather than the geometry silently staying
    /// unscaled while only the offset tracked the window.
    ///
    /// Deliberately does NOT touch `strokeWidth`, `dash`, `fontSize`, or
    /// `paddingPx` anywhere below: those are STYLE dimensions, always backing
    /// pixels regardless of `coordinateScaleX`/`coordinateScaleY` (see
    /// `AnnotationKind`'s existing `normalized`-coordinates precedent), and
    /// the design contract requires the same rule survive anchoring -- a 2px
    /// hairline must still be 2px after its window doubles in size. Scaling
    /// them here would have been the wrong fix at the wrong layer (see
    /// `RENDERER_MATH.md`'s "why not a `DrawingContext` scale instead").
    private static func drawKind(_ kind: AnnotationKind, colorHex: String,
                                  scale: CGFloat, viewHeight: CGFloat, context: DrawingContext,
                                  adjustment: AnchorAdjustment,
                                  imageForAssetId: (String) -> RasterImageHandle?) {
        switch kind {
            case .vectorPath(let data, let strokeColorHex, let strokeWidth, let strokeOpacity,
                             let fillColorHex, let fillOpacity, let dash, let usesEvenOddFillRule,
                             let coordinateScaleX, let coordinateScaleY):
                drawVectorPath(data: data, strokeColorHex: strokeColorHex, strokeWidth: strokeWidth,
                               strokeOpacity: strokeOpacity, fillColorHex: fillColorHex, fillOpacity: fillOpacity, dash: dash,
                               usesEvenOddFillRule: usesEvenOddFillRule,
                               coordinateScaleX: coordinateScaleX * adjustment.scaleX,
                               coordinateScaleY: coordinateScaleY * adjustment.scaleY,
                               fallbackColorHex: colorHex, scale: scale, viewHeight: viewHeight, context: context)

            case .image(let assetId, let x, let y, let width, let height, let rotationDegrees, let opacity):
                // Rotation applies about the ALREADY-scaled rect's own centre
                // (see `drawImage` below), so a non-uniform `adjustment` on a
                // rotated image is only an approximation of what genuinely
                // shearing the rotated result would look like -- the intended,
                // documented tradeoff (see RENDERER_MATH.md), not a bug.
                drawImage(assetId: assetId, x: x * adjustment.scaleX, y: y * adjustment.scaleY,
                          width: width * adjustment.scaleX, height: height * adjustment.scaleY,
                          rotationDegrees: rotationDegrees, opacity: opacity,
                          scale: scale, viewHeight: viewHeight, context: context,
                          imageForAssetId: imageForAssetId)

            case .text(let text, let x, let y, let fontSize, let textColorHex, let backgroundColorHex,
                       let backgroundOpacity, let paddingPx, let opacity):
                drawText(text: text, x: x * adjustment.scaleX, y: y * adjustment.scaleY, fontSize: fontSize,
                         textColorHex: textColorHex,
                         backgroundColorHex: backgroundColorHex, backgroundOpacity: backgroundOpacity,
                         paddingPx: paddingPx, opacity: opacity, scale: scale, viewHeight: viewHeight,
                         context: context)

            case .batch(let items):
                for item in items {
                    context.save()
                    drawKind(item.kind, colorHex: item.colorHex,
                             scale: scale, viewHeight: viewHeight, context: context,
                             adjustment: adjustment,
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

        var fillColor: ChalkColor?
        if let fillColorHex, fillOpacity > 0 {
            let parsedFill = ColorParser.parse(fillColorHex)
            fillColor = parsedFill.multiplyingAlpha(by: Double(OverlayDrawingMetrics.clampedAlpha(fillOpacity)))
        }

        var strokeParameters: (color: ChalkColor, lineWidth: Double, dash: [Double])?
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
            strokeParameters = (color: strokeColor, lineWidth: Double(lineWidth), dash: dashLengths)
        }

        if let fillColor, let strokeParameters,
           let combined = context as? CombinedFillStrokeDrawingContext {
            // Both operations apply and the context can share the converted
            // path between them (see `CombinedFillStrokeDrawingContext` for
            // why this is a pure convert-once optimisation, guaranteed
            // pixel-identical to the two-call branch below). Fill first,
            // stroke on top -- the same order the two-call branch has always
            // painted in.
            combined.fillAndStroke(
                path: path, fillColor: fillColor, evenOdd: usesEvenOddFillRule,
                strokeColor: strokeParameters.color,
                lineWidth: strokeParameters.lineWidth, dash: strokeParameters.dash
            )
        } else {
            if let fillColor {
                context.fill(path: path, color: fillColor, evenOdd: usesEvenOddFillRule)
            }
            if let strokeParameters {
                context.stroke(
                    path: path, color: strokeParameters.color,
                    lineWidth: strokeParameters.lineWidth, dash: strokeParameters.dash
                )
            }
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
