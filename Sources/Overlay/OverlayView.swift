import Foundation
import AppKit

/// Pixel-to-point conversion shared by renderer code and deterministic tests.
/// MCP drawing dimensions are physical backing pixels; Core Graphics drawing
/// APIs consume AppKit points, so lengths must be divided by the active backing
/// scale just like positions are.
///
/// Every function here is a pure, `enum`-namespaced static func with no AppKit
/// view state (no `NSView`, no `bounds`, no `NSGraphicsContext`) -- that is
/// deliberate, so unit tests can call them directly with no GUI session. All
/// six `OverlayView.draw*` methods route their coordinate math through these
/// rather than open-coding the conversions themselves.
enum OverlayDrawingMetrics {
    static func points(forPhysicalPixels pixels: Double, backingScaleFactor: CGFloat) -> CGFloat {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1.0
        return CGFloat(pixels) / scale
    }

    /// Flips a Y coordinate from MCP's top-left-origin physical-pixel space
    /// into AppKit's bottom-left-origin point space for a view of height
    /// `viewHeightPoints`.
    ///
    /// MCP coordinates are top-left origin in physical pixels; AppKit's
    /// drawing space is bottom-left origin in points. Every annotation kind
    /// needs this same flip for its Y (and only its Y) coordinate -- this
    /// replaces what used to be six separately open-coded
    /// `viewHeight - (CGFloat(py) / scale)` expressions in `OverlayView`.
    static func viewY(forPhysicalPixelY pixels: Double,
                       backingScaleFactor: CGFloat,
                       viewHeightPoints: CGFloat) -> CGFloat {
        return viewHeightPoints - points(forPhysicalPixels: pixels, backingScaleFactor: backingScaleFactor)
    }

    /// Convenience combining `points(forPhysicalPixels:)` for X and
    /// `viewY(forPhysicalPixelY:)` for Y, for the common case of converting a
    /// single MCP-space (top-left, physical pixels) point into a single
    /// AppKit-space (bottom-left, points) point in one call.
    static func point(forPhysicalPixelX x: Double,
                       y: Double,
                       backingScaleFactor: CGFloat,
                       viewHeightPoints: CGFloat) -> CGPoint {
        return CGPoint(
            x: points(forPhysicalPixels: x, backingScaleFactor: backingScaleFactor),
            y: viewY(forPhysicalPixelY: y, backingScaleFactor: backingScaleFactor, viewHeightPoints: viewHeightPoints)
        )
    }

    /// Clamps a caller-supplied opacity into the 0...1 alpha range Core
    /// Graphics expects.
    ///
    /// Replaces six separately open-coded `CGFloat(min(max(x, 0), 1))`
    /// expressions in `OverlayView`. Non-finite input collapses to 0 rather
    /// than propagating NaN into a `CGColor` alpha, where it would render
    /// unpredictably instead of simply invisibly.
    static func clampedAlpha(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 1))
    }
}

public final class OverlayView: NSView {
    public var screenId: String = ""
    public var scaleFactor: CGFloat = 2.0

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }

    override public var isFlipped: Bool {
        // Keeping false (AppKit standard bottom-left origin) to make bounds.height calculations explicit and standard
        return false
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)

        // Per-app filtering: only annotations that are global, or linked to the
        // app that is frontmost RIGHT NOW, get painted. `ActiveAppTracker`
        // repaints every overlay on each app activation, so switching from
        // DaVinci Resolve to Terminal swaps one app's annotations out for the
        // other's. Note this uses `currentAppId` (what is on screen) and NOT
        // `fallbackAppId` (what an untagged draw call would target).
        //
        // EXCEPT while capture visibility is ON, which is a DEBUG MODE and is
        // deliberately exempt from the filter -- do not "simplify" this back to
        // a single unconditional call:
        //
        // `set_capture_visible(true)` exists for placement debugging: Claude
        // draws something, requests capture eligibility, screenshots the
        // display through a compatible capture path, and checks placement. But Claude
        // Desktop is frontmost at the moment it screenshots, so `currentAppId`
        // is Claude, while the annotation it just drew was tagged with
        // `fallbackAppId` (the OTHER app -- see ActiveAppTracker). Filtering
        // here would guarantee that annotation is absent even when the capture
        // path includes the overlay. Rendering it keeps AI Chalkboard's own
        // filtering from defeating the debug request; external capture filters
        // remain outside the app's control.
        //
        // So while the debug toggle is on, render EVERYTHING on this screen.
        // The user has explicitly asked to see the overlay as it really is;
        // showing another app's annotations for the duration is the intended,
        // reversible cost.
        //
        // Routed through `OverlayWindowController.currentlyVisibleAnnotations`
        // rather than querying `AnnotationStore`/`ActiveAppTracker` directly:
        // `refreshViews()` needs this EXACT same "what should be visible right
        // now" answer to decide whether the window itself belongs on screen at
        // all (see that method's doc comment), and computing it twice risked
        // the two independently drifting out of sync with each other.
        let annotations = OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId)
        drawAnnotations(annotations, in: context, canvasSize: bounds.size)
    }

    /// Draws an explicit annotation snapshot into an AppKit/Core Graphics
    /// canvas. The live overlay and `verify_annotation` both call this exact
    /// method, so the verification image cannot drift into a second,
    /// approximate implementation of vector paths, images, or batches.
    ///
    /// The caller owns filtering and the graphics-state transform. The live
    /// overlay passes its view bounds unchanged; the verifier scales a source
    /// screen-sized point canvas into the supplied screenshot before calling.
    func drawAnnotations(
        _ annotations: [Annotation],
        in context: CGContext,
        canvasSize: CGSize,
        rasterLease suppliedRasterLease: RasterAssetStore.Lease? = nil
    ) {
        let scale = scaleFactor > 0 ? scaleFactor : 1.0
        let viewHeight = canvasSize.height
        // Snapshot every raster before beginning a frame.  A concurrent
        // clear can release the store's ownership mid-draw, but this lease
        // owns strong image references through the entire recursive draw.
        let assetIDs = annotations.flatMap { $0.kind.rasterAssetIds }
        let rasterLease = suppliedRasterLease ?? RasterAssetStore.shared.lease(ids: assetIDs)

        for annotation in annotations {
            context.saveGState()
            context.setAlpha(OverlayDrawingMetrics.clampedAlpha(annotation.opacity))
            context.translateBy(
                x: OverlayDrawingMetrics.points(forPhysicalPixels: annotation.offsetX, backingScaleFactor: scale),
                y: -OverlayDrawingMetrics.points(forPhysicalPixels: annotation.offsetY, backingScaleFactor: scale)
            )
            drawKind(annotation.kind, colorHex: annotation.colorHex,
                     scale: scale, viewHeight: viewHeight, context: context,
                     rasterLease: rasterLease)
            context.restoreGState()
        }
    }

    /// Recursive renderer used for both a top-level annotation and every item
    /// inside an atomic batch. Keeping dispatch here means live drawing and
    /// synthetic verification support exactly the same primitive set.
    private func drawKind(_ kind: AnnotationKind, colorHex: String,
                          scale: CGFloat, viewHeight: CGFloat, context: CGContext,
                          rasterLease: RasterAssetStore.Lease) {
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
                          rasterLease: rasterLease)

            case .text(let text, let x, let y, let fontSize, let textColorHex, let backgroundColorHex,
                       let backgroundOpacity, let paddingPx, let opacity):
                drawText(text: text, x: x, y: y, fontSize: fontSize, textColorHex: textColorHex,
                         backgroundColorHex: backgroundColorHex, backgroundOpacity: backgroundOpacity,
                         paddingPx: paddingPx, opacity: opacity, scale: scale, viewHeight: viewHeight,
                         context: context)

            case .batch(let items):
                for item in items {
                    context.saveGState()
                    drawKind(item.kind, colorHex: item.colorHex,
                             scale: scale, viewHeight: viewHeight, context: context,
                             rasterLease: rasterLease)
                    context.restoreGState()
                }
        }
    }

    // MARK: - Universal free-draw rendering

    private func drawVectorPath(
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
        context: CGContext
    ) {
        // Routed through SVGPathCache rather than SVGPathParser directly:
        // this runs inside draw(_:), so an uncached parse re-tokenised (and
        // re-converted every arc command) on every repaint. See SVGPathCache
        // for why reusing the parsed path is pixel-identical.
        guard let sourcePath = try? SVGPathCache.path(for: data) else { return }
        var transform = CGAffineTransform(
            a: CGFloat(coordinateScaleX) / scale, b: 0,
            c: 0, d: -CGFloat(coordinateScaleY) / scale,
            tx: 0, ty: viewHeight
        )
        guard let path = sourcePath.copy(using: &transform) else { return }

        if let fillColorHex, fillOpacity > 0 {
            let parsedFill = ColorParser.parse(fillColorHex)
            let fill = parsedFill.withAlphaComponent(
                parsedFill.alphaComponent * OverlayDrawingMetrics.clampedAlpha(fillOpacity)
            )
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.drawPath(using: usesEvenOddFillRule ? .eoFill : .fill)
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
            context.addPath(path)
            context.setStrokeColor(stroke.withAlphaComponent(
                stroke.alphaComponent * OverlayDrawingMetrics.clampedAlpha(strokeOpacity)
            ).cgColor)
            context.setLineWidth(OverlayDrawingMetrics.points(forPhysicalPixels: strokeWidth, backingScaleFactor: scale))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if !dash.isEmpty {
                context.setLineDash(
                    phase: 0,
                    lengths: dash.map { OverlayDrawingMetrics.points(forPhysicalPixels: $0, backingScaleFactor: scale) }
                )
            }
            context.strokePath()
        }

    }

    private func drawImage(
        assetId: String,
        x xPx: Double,
        y yPx: Double,
        width widthPx: Double,
        height heightPx: Double,
        rotationDegrees: Double,
        opacity: Double,
        scale: CGFloat,
        viewHeight: CGFloat,
        context: CGContext,
        rasterLease: RasterAssetStore.Lease
    ) {
        guard let image = rasterLease.image(id: assetId) else { return }
        let x = OverlayDrawingMetrics.points(forPhysicalPixels: xPx, backingScaleFactor: scale)
        let width = OverlayDrawingMetrics.points(forPhysicalPixels: widthPx, backingScaleFactor: scale)
        let height = OverlayDrawingMetrics.points(forPhysicalPixels: heightPx, backingScaleFactor: scale)
        let topY = OverlayDrawingMetrics.viewY(forPhysicalPixelY: yPx, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let rect = CGRect(x: x, y: topY - height, width: width, height: height)

        context.saveGState()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.translateBy(x: center.x, y: center.y)
        // Public coordinates are top-left/y-down, so positive rotation is
        // documented as clockwise. AppKit's y-up context needs the negation.
        context.rotate(by: CGFloat(-rotationDegrees * .pi / 180))
        context.translateBy(x: -center.x, y: -center.y)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: OverlayDrawingMetrics.clampedAlpha(opacity))
        context.restoreGState()

    }

    private func drawText(
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
        context: CGContext
    ) {
        let fontSize = OverlayDrawingMetrics.points(forPhysicalPixels: fontSizePx, backingScaleFactor: scale)
        let padding = OverlayDrawingMetrics.points(forPhysicalPixels: paddingPx, backingScaleFactor: scale)
        guard fontSize > 0 else { return }
        let primitiveOpacity = OverlayDrawingMetrics.clampedAlpha(opacity)
        let textColor = ColorParser.parse(textColorHex)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor.withAlphaComponent(textColor.alphaComponent * primitiveOpacity)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let glyphBounds = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        let width = max(1, glyphBounds.width)
        let height = max(1, glyphBounds.height)
        let x = OverlayDrawingMetrics.points(forPhysicalPixels: xPx, backingScaleFactor: scale)
        let topY = OverlayDrawingMetrics.viewY(forPhysicalPixelY: yPx, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let textRect = CGRect(x: x + padding, y: topY - padding - height, width: width, height: height)
        let backgroundRect = textRect.insetBy(dx: -padding, dy: -padding)
        if let backgroundColorHex, backgroundOpacity > 0 {
            let parsedBackground = ColorParser.parse(backgroundColorHex)
            let background = parsedBackground.withAlphaComponent(
                parsedBackground.alphaComponent * OverlayDrawingMetrics.clampedAlpha(backgroundOpacity) * primitiveOpacity
            )
            context.setFillColor(background.cgColor)
            context.fill(backgroundRect)
        }
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
