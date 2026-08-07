import Foundation
import AppKit

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
        // `set_capture_visible(true)` exists for exactly one purpose: Claude
        // draws something, exposes the overlay to screen capture, screenshots
        // the display and checks that the box landed where it meant. But Claude
        // Desktop is frontmost at the moment it screenshots, so `currentAppId`
        // is Claude, while the annotation it just drew was tagged with
        // `fallbackAppId` (the OTHER app -- see ActiveAppTracker). Filtering
        // here would drop that annotation from the capture and hand back a
        // BLANK overlay: byte-for-byte the symptom that `sharingType = .none`
        // used to cause, reintroduced through a second mechanism, defeating the
        // very tool built to tell those two causes apart.
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
            case .circle(let x_px, let y_px, let r_px):
                let cx = CGFloat(x_px) / scale
                let cy_top = CGFloat(y_px) / scale
                let cy = viewHeight - cy_top
                let radius = CGFloat(r_px) / scale
                
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
                
                if let labelText = annotation.label, !labelText.isEmpty {
                    drawLabelBadge(text: labelText, at: CGPoint(x: cx + radius + 4, y: cy), color: color, context: context)
                }

            case .box(let x_px, let y_px, let w_px, let h_px):
                let minX = CGFloat(x_px) / scale
                let topY = CGFloat(y_px) / scale
                let width = CGFloat(w_px) / scale
                let height = CGFloat(h_px) / scale
                let minY = viewHeight - topY - height
                
                let rect = CGRect(x: minX, y: minY, width: width, height: height)
                
                // Fill
                context.setFillColor(color.withAlphaComponent(0.15).cgColor)
                context.fill(rect)
                
                // Stroke
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(3.0)
                context.stroke(rect)
                
                if let labelText = annotation.label, !labelText.isEmpty {
                    drawLabelBadge(text: labelText, at: CGPoint(x: minX, y: minY + height + 4), color: color, context: context)
                }

            case .arrow(let x1_px, let y1_px, let x2_px, let y2_px):
                let p1 = CGPoint(x: CGFloat(x1_px) / scale, y: viewHeight - (CGFloat(y1_px) / scale))
                let p2 = CGPoint(x: CGFloat(x2_px) / scale, y: viewHeight - (CGFloat(y2_px) / scale))
                
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
                
                if let labelText = annotation.label, !labelText.isEmpty {
                    let midPoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                    drawLabelBadge(text: labelText, at: midPoint, color: color, context: context)
                }

            case .label(let x_px, let y_px, let text):
                let x = CGFloat(x_px) / scale
                let y = viewHeight - (CGFloat(y_px) / scale)
                drawLabelBadge(text: text, at: CGPoint(x: x, y: y), color: color, context: context)

            case .grid(let stepPx):
                let stepPt = (CGFloat(stepPx) > 0 ? CGFloat(stepPx) : 200.0) / scale
                let gridColor = color.withAlphaComponent(0.35)
                context.setStrokeColor(gridColor.cgColor)
                context.setLineWidth(1.0)
                
                var x: CGFloat = stepPt
                while x < bounds.width {
                    context.move(to: CGPoint(x: x, y: 0))
                    context.addLine(to: CGPoint(x: x, y: viewHeight))
                    x += stepPt
                }
                
                var y: CGFloat = stepPt
                while y < viewHeight {
                    context.move(to: CGPoint(x: 0, y: y))
                    context.addLine(to: CGPoint(x: bounds.width, y: y))
                    y += stepPt
                }
                context.strokePath()

            case .path(let rawPoints, let strokeWidth, let isClosed):
                guard rawPoints.count >= 2 else { break }
                let stroke = strokeWidth > 0 ? CGFloat(strokeWidth) : 3.5
                
                var cgPoints: [CGPoint] = []
                for pt in rawPoints {
                    if pt.count >= 2 {
                        let x = CGFloat(pt[0]) / scale
                        let y = viewHeight - (CGFloat(pt[1]) / scale)
                        cgPoints.append(CGPoint(x: x, y: y))
                    }
                }
                
                guard cgPoints.count >= 2 else { break }
                
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(stroke)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                
                if isClosed {
                    context.move(to: cgPoints[0])
                    for i in 1..<cgPoints.count {
                        context.addLine(to: cgPoints[i])
                    }
                    context.closePath()
                    
                    // Fill translucent interior for closed shapes
                    context.setFillColor(color.withAlphaComponent(0.18).cgColor)
                    context.fillPath()
                }
                
                // Stroke stroke line
                context.move(to: cgPoints[0])
                for i in 1..<cgPoints.count {
                    context.addLine(to: cgPoints[i])
                }
                if isClosed {
                    context.closePath()
                }
                context.strokePath()
                
                if let labelText = annotation.label, !labelText.isEmpty, let firstPt = cgPoints.first {
                    drawLabelBadge(text: labelText, at: firstPt, color: color, context: context)
                }
            }
            
            context.restoreGState()
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

