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
        // So while the debug toggle is on, render EVERYTHING on this screen
        // (this is the sole caller of the 1-arg `getForScreen`). The user has
        // explicitly asked to see the overlay as it really is; showing another
        // app's annotations for the duration is the intended, reversible cost.
        let annotations: [Annotation]
        if OverlayWindowController.shared.isCaptureVisible {
            annotations = AnnotationStore.shared.getForScreen(screenId)
        } else {
            annotations = AnnotationStore.shared.getForScreen(
                screenId,
                visibleForApp: ActiveAppTracker.shared.currentAppId
            )
        }
        let scale = scaleFactor > 0 ? scaleFactor : 1.0
        let viewHeight = bounds.height

        for annotation in annotations {
            let color = ColorParser.parse(annotation.colorHex)
            context.saveGState()

            switch annotation.kind {
            case .circle(let x, let y, let radius):
                drawCircle(x: x, y: y, radius: radius, label: annotation.label,
                           color: color, scale: scale, viewHeight: viewHeight, context: context)

            case .box(let x, let y, let width, let height):
                drawBox(x: x, y: y, width: width, height: height, label: annotation.label,
                        color: color, scale: scale, viewHeight: viewHeight, context: context)

            case .arrow(let x1, let y1, let x2, let y2):
                drawArrow(x1: x1, y1: y1, x2: x2, y2: y2, label: annotation.label,
                          color: color, scale: scale, viewHeight: viewHeight, context: context)

            case .label(let x, let y, let text):
                drawLabel(x: x, y: y, text: text,
                          color: color, scale: scale, viewHeight: viewHeight, context: context)

            case .grid(let stepPx):
                drawGrid(stepPx: stepPx, color: color, scale: scale,
                         viewWidth: bounds.width, viewHeight: viewHeight, context: context)

            case .path(let rawPoints, let strokeWidth, let isClosed):
                drawPath(rawPoints: rawPoints, strokeWidth: strokeWidth, isClosed: isClosed, label: annotation.label,
                         color: color, scale: scale, viewHeight: viewHeight, context: context)
            }

            context.restoreGState()
        }
    }

    // MARK: - Per-kind rendering
    //
    // UNIT ASYMMETRY IS INTENTIONAL, DO NOT "FIX" IT: the hardcoded stroke
    // widths and geometry constants below (circle/box outline `3.0`, arrow
    // line `3.5` and arrowhead length `16.0`) are in AppKit POINTS -- the
    // correct unit for a line weight that should look the same size on screen
    // regardless of display scale. `draw_path`'s `stroke_width` parameter, by
    // contrast, is documented and unit-tested as PHYSICAL PIXELS, so it is
    // deliberately converted via `OverlayDrawingMetrics.points(forPhysicalPixels:)`
    // before use while the other constants are not. Making these consistent
    // would change on-screen appearance; leave both units exactly as they are.

    private func drawCircle(x xPx: Double, y yPx: Double, radius rPx: Double, label: String?,
                             color: NSColor, scale: CGFloat, viewHeight: CGFloat, context: CGContext) {
        let center = OverlayDrawingMetrics.point(forPhysicalPixelX: xPx, y: yPx,
                                                  backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let cx = center.x
        let cy = center.y
        let radius = OverlayDrawingMetrics.points(forPhysicalPixels: rPx, backingScaleFactor: scale)

        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)

        // Semi-transparent fill
        context.setFillColor(color.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: rect)

        // Outer glow / stroke
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(3.0)
        context.strokeEllipse(in: rect)

        // Draw inner dot
        let centerDot = CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: centerDot)

        if let labelText = label, !labelText.isEmpty {
            drawLabelBadge(text: labelText, at: CGPoint(x: cx + radius + 4, y: cy), color: color, context: context)
        }
    }

    private func drawBox(x xPx: Double, y yPx: Double, width wPx: Double, height hPx: Double, label: String?,
                          color: NSColor, scale: CGFloat, viewHeight: CGFloat, context: CGContext) {
        let minX = OverlayDrawingMetrics.points(forPhysicalPixels: xPx, backingScaleFactor: scale)
        let width = OverlayDrawingMetrics.points(forPhysicalPixels: wPx, backingScaleFactor: scale)
        let height = OverlayDrawingMetrics.points(forPhysicalPixels: hPx, backingScaleFactor: scale)
        // Top-left corner flipped into AppKit space, then dropped down by the
        // (already-converted) box height to get the bottom-left corner CGRect wants.
        let topY = OverlayDrawingMetrics.viewY(forPhysicalPixelY: yPx, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let minY = topY - height

        let rect = CGRect(x: minX, y: minY, width: width, height: height)

        // Fill
        context.setFillColor(color.withAlphaComponent(0.15).cgColor)
        context.fill(rect)

        // Stroke
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(3.0)
        context.stroke(rect)

        if let labelText = label, !labelText.isEmpty {
            drawLabelBadge(text: labelText, at: CGPoint(x: minX, y: minY + height + 4), color: color, context: context)
        }
    }

    private func drawArrow(x1: Double, y1: Double, x2: Double, y2: Double, label: String?,
                            color: NSColor, scale: CGFloat, viewHeight: CGFloat, context: CGContext) {
        let p1 = OverlayDrawingMetrics.point(forPhysicalPixelX: x1, y: y1, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        let p2 = OverlayDrawingMetrics.point(forPhysicalPixelX: x2, y: y2, backingScaleFactor: scale, viewHeightPoints: viewHeight)

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(3.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw line
        context.move(to: p1)
        context.addLine(to: p2)
        context.strokePath()

        // Draw arrowhead at p2
        let angle = atan2(p2.y - p1.y, p2.x - p1.x)
        let arrowLength: CGFloat = 16.0
        let arrowAngle: CGFloat = .pi / 6.0

        let pArrow1 = CGPoint(
            x: p2.x - arrowLength * cos(angle - arrowAngle),
            y: p2.y - arrowLength * sin(angle - arrowAngle)
        )
        let pArrow2 = CGPoint(
            x: p2.x - arrowLength * cos(angle + arrowAngle),
            y: p2.y - arrowLength * sin(angle + arrowAngle)
        )

        context.setFillColor(color.cgColor)
        context.move(to: p2)
        context.addLine(to: pArrow1)
        context.addLine(to: pArrow2)
        context.closePath()
        context.fillPath()

        if let labelText = label, !labelText.isEmpty {
            let midPoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            drawLabelBadge(text: labelText, at: midPoint, color: color, context: context)
        }
    }

    private func drawLabel(x xPx: Double, y yPx: Double, text: String,
                            color: NSColor, scale: CGFloat, viewHeight: CGFloat, context: CGContext) {
        let point = OverlayDrawingMetrics.point(forPhysicalPixelX: xPx, y: yPx, backingScaleFactor: scale, viewHeightPoints: viewHeight)
        drawLabelBadge(text: text, at: point, color: color, context: context)
    }

    private func drawGrid(stepPx: Double, color: NSColor, scale: CGFloat,
                           viewWidth: CGFloat, viewHeight: CGFloat, context: CGContext) {
        // Guard rails -- DEFENSE IN DEPTH. The MCP layer now also rejects an
        // out-of-range `step_px` at the API boundary, but annotations can also
        // be built in-process (tests, future callers) without going through
        // that validation, so the renderer must not trust the value blindly.
        //
        // Two INDEPENDENT guards, per `DrawingDefaults.minGridStepPx`'s doc
        // comment:
        //   1. Clamp the step itself to at least `minGridStepPx` so it can
        //      never collapse into a floating-point no-op increment.
        //   2. Separately cap the number of lines drawn per axis at
        //      `maxGridLinesPerAxis`, so even a merely-tiny (not quite
        //      ULP-collapsing) step cannot wedge the main thread by drawing an
        //      effectively unbounded number of lines.
        //
        // Both guards use a bounded `for` loop over an Int line index that is
        // MULTIPLIED by the step, rather than the old `while` loop that
        // repeatedly ADDED the step to an accumulator -- that old form both
        // had no iteration cap (see the fix this replaces) and accumulated
        // floating-point drift across a wide screen; multiplying from an
        // integer index has neither problem.
        let rawStepPx = stepPx > 0 ? stepPx : DrawingDefaults.gridStepPx
        let clampedStepPx = max(rawStepPx, DrawingDefaults.minGridStepPx)
        let stepPt = OverlayDrawingMetrics.points(forPhysicalPixels: clampedStepPx, backingScaleFactor: scale)

        let gridColor = color.withAlphaComponent(0.35)
        context.setStrokeColor(gridColor.cgColor)
        context.setLineWidth(1.0)

        for lineIndex in 1...DrawingDefaults.maxGridLinesPerAxis {
            let x = CGFloat(lineIndex) * stepPt
            guard x < viewWidth else { break }
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: viewHeight))
        }

        for lineIndex in 1...DrawingDefaults.maxGridLinesPerAxis {
            let y = CGFloat(lineIndex) * stepPt
            guard y < viewHeight else { break }
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: viewWidth, y: y))
        }
        context.strokePath()
    }

    private func drawPath(rawPoints: [[Double]], strokeWidth: Double, isClosed: Bool, label: String?,
                           color: NSColor, scale: CGFloat, viewHeight: CGFloat, context: CGContext) {
        guard rawPoints.count >= 2 else { return }
        let physicalStroke = strokeWidth > 0 ? strokeWidth : DrawingDefaults.pathStrokeWidthPx
        let stroke = OverlayDrawingMetrics.points(
            forPhysicalPixels: physicalStroke,
            backingScaleFactor: scale
        )

        var cgPoints: [CGPoint] = []
        for pt in rawPoints {
            if pt.count >= 2 {
                let point = OverlayDrawingMetrics.point(forPhysicalPixelX: pt[0], y: pt[1],
                                                         backingScaleFactor: scale, viewHeightPoints: viewHeight)
                cgPoints.append(point)
            }
        }

        guard cgPoints.count >= 2 else { return }

        // Build the point sequence into a single CGPath ONCE and reuse it for
        // both the optional interior fill and the stroke below, instead of
        // re-walking `cgPoints` with a second identical sequence of
        // move/addLine calls (previously done once for the fill pass and
        // again, identically, for the stroke pass).
        let path = CGMutablePath()
        path.addLines(between: cgPoints)
        if isClosed {
            path.closeSubpath()
        }

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if isClosed {
            // Fill translucent interior for closed shapes
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(0.18).cgColor)
            context.fillPath()
        }

        context.addPath(path)
        context.strokePath()

        if let labelText = label, !labelText.isEmpty, let firstPt = cgPoints.first {
            drawLabelBadge(text: labelText, at: firstPt, color: color, context: context)
        }
    }

    private func drawLabelBadge(text: String, at point: CGPoint, color: NSColor, context: CGContext) {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let textSize = (text as NSString).size(withAttributes: textAttributes)
        let paddingX: CGFloat = 8.0
        let paddingY: CGFloat = 4.0

        let badgeRect = CGRect(
            x: point.x,
            y: point.y - (textSize.height / 2 + paddingY),
            width: textSize.width + (paddingX * 2),
            height: textSize.height + (paddingY * 2)
        )

        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        // Dark background pill with colored border
        context.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        context.addPath(path)
        context.fillPath()

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.addPath(path)
        context.strokePath()

        // Render text directly inside AppKit drawing context
        let textRect = CGRect(
            x: badgeRect.origin.x + paddingX,
            y: badgeRect.origin.y + paddingY,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: textAttributes)
    }
}
