#if os(macOS)
import AppKit
import Foundation

/// `DrawingContext` implementation backed by a Core Graphics `CGContext`.
/// Both the live `OverlayView` and `AnnotationVerificationCompositor` wrap
/// their `CGContext` in one of these and hand it to `AnnotationRenderer`, so
/// every macOS drawing call the renderer makes is the exact same Core
/// Graphics call the pre-port `OverlayView` used to make directly -- see each
/// method below for the specific call it replaces. This is the ONLY file
/// that is allowed to convert a `ChalkPath`/`ChalkColor` into a
/// `CGPath`/`CGColor`/`NSColor`; `AnnotationRenderer` itself never does.
final class CoreGraphicsDrawingContext: DrawingContext {
    private let context: CGContext

    init(context: CGContext) {
        self.context = context
    }

    func save() {
        context.saveGState()
    }

    func restore() {
        context.restoreGState()
    }

    func setGlobalAlpha(_ alpha: Double) {
        context.setAlpha(CGFloat(alpha))
    }

    func translate(x: Double, y: Double) {
        context.translateBy(x: CGFloat(x), y: CGFloat(y))
    }

    func rotate(radians: Double) {
        context.rotate(by: CGFloat(radians))
    }

    func fill(path: ChalkPath, color: ChalkColor, evenOdd: Bool) {
        context.addPath(cgPath(from: path))
        context.setFillColor(color.cgColor)
        context.drawPath(using: evenOdd ? .eoFill : .fill)
    }

    func stroke(path: ChalkPath, color: ChalkColor, lineWidth: Double, dash: [Double]) {
        context.addPath(cgPath(from: path))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(CGFloat(lineWidth))
        // Round cap and round join are the fixed, non-configurable stroke
        // style every stroked primitive in this app has always used -- see
        // `DrawingContext.stroke`'s doc comment.
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if !dash.isEmpty {
            context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
        }
        context.strokePath()
    }

    func fill(rect: CGRect, color: ChalkColor) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    func drawImage(_ handle: RasterImageHandle, in rect: CGRect, alpha: Double) {
        // `NSImageRasterHandle` is the only `RasterImageHandle` this platform
        // ever vends (see `OverlayView.draw(_:)` and
        // `AnnotationVerificationCompositor`, its only two call sites), so
        // this cast cannot fail in practice; failing closed rather than
        // force-casting keeps a future second handle type from crashing here.
        guard let handle = handle as? NSImageRasterHandle else { return }
        handle.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(alpha))
    }

    func measureText(_ text: String, fontSize: Double) -> CGSize {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: CGFloat(fontSize))]
        )
        let bounds = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
        return bounds.size
    }

    func drawText(_ text: String, in rect: CGRect, fontSize: Double, color: ChalkColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(fontSize)),
            .foregroundColor: color.nsColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// Rebuilds a Core Graphics path from a `ChalkPath`'s resolved elements.
    /// Mirrors `SVGPathParser`'s deleted `makeCGPath(from:)` element-for-
    /// element (see git history on `Sources/Overlay/SVGPathParser.swift`):
    /// now that `ChalkPath` carries only the platform-neutral element list,
    /// any macOS drawing call that still needs a `CGPath` needs this same
    /// conversion at the point it hands geometry to Core Graphics.
    private func cgPath(from chalkPath: ChalkPath) -> CGPath {
        let path = CGMutablePath()
        for element in chalkPath.elements {
            switch element {
            case let .move(point): path.move(to: point)
            case let .line(point): path.addLine(to: point)
            case let .quad(control, to): path.addQuadCurve(to: to, control: control)
            case let .cubic(control1, control2, to): path.addCurve(to: to, control1: control1, control2: control2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// Adapts a `ChalkColor` to `NSColor`/`CGColor` at the point macOS drawing
/// code actually needs one. Shared code never carries `NSColor` any further
/// upstream than this (see `ChalkColor`'s header comment) -- constructing it
/// here, right before handing it to Core Graphics/AppKit, is the one place
/// that conversion happens.
private extension ChalkColor {
    var nsColor: NSColor {
        NSColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    var cgColor: CGColor {
        nsColor.cgColor
    }
}

/// Wraps the `NSImage` an `RasterAssetStore.Lease` vends so it can be handed
/// to `AnnotationRenderer` as an opaque `RasterImageHandle` -- the renderer
/// itself never sees `NSImage`. Pixel dimensions come from the image's
/// `size`, which `RasterAssetStore.load` constructs directly from the
/// decoded `CGImage`'s `width`/`height` in pixels (see that method's
/// `NSImage(cgImage:size:)` construction), so `size` already IS the pixel
/// size here, not a point size scaled by some other factor.
final class NSImageRasterHandle: RasterImageHandle {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
    }

    var pixelWidth: Int { Int(image.size.width) }
    var pixelHeight: Int { Int(image.size.height) }
}
#endif
