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
        fillConverted(cgPath(from: path), color: color, evenOdd: evenOdd)
    }

    func stroke(path: ChalkPath, color: ChalkColor, lineWidth: Double, dash: [Double]) {
        strokeConverted(cgPath(from: path), color: color, lineWidth: lineWidth, dash: dash)
    }

    /// The body `fill(path:color:evenOdd:)` has always had, split out to take
    /// an ALREADY-converted `CGPath` so `fillAndStroke` below can reuse one
    /// conversion for both operations. Behavior is byte-for-byte the old
    /// `fill`: add path, set fill color, draw with the requested fill rule.
    private func fillConverted(_ path: CGPath, color: ChalkColor, evenOdd: Bool) {
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.drawPath(using: evenOdd ? .eoFill : .fill)
    }

    /// The body `stroke(path:color:lineWidth:dash:)` has always had, split
    /// out for the same converted-path reuse as `fillConverted`.
    private func strokeConverted(_ path: CGPath, color: ChalkColor, lineWidth: Double, dash: [Double]) {
        context.addPath(path)
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
        // Memoised through `TextMeasurementCache` below: this runs inside
        // every repaint for every text annotation on screen, and
        // `boundingRect` re-runs full glyph layout each time for a result
        // that is a pure function of `(text, fontSize)` -- see the cache's
        // own doc comment for why that purity holds and how it is bounded.
        TextMeasurementCache.size(text: text, fontSize: fontSize) {
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

/// The macOS adoption of `AnnotationRenderer`'s convert-once fast path: a
/// filled-AND-stroked vector path used to arrive here as `fill(path:...)`
/// then `stroke(path:...)`, each of which rebuilt the same `CGMutablePath`
/// element-by-element via `cgPath(from:)` -- twice per annotation per frame.
/// Here the conversion happens ONCE and the resulting `CGPath` (immutable,
/// so adding it to the context twice is safe) is added for the fill and
/// again for the stroke, through the exact same private bodies the separate
/// `fill`/`stroke` entry points use. Pixel-identical to the two-call form by
/// construction -- same Core Graphics calls in the same order, only the
/// redundant second conversion is gone -- which is precisely the contract
/// `CombinedFillStrokeDrawingContext` demands of an adopter.
extension CoreGraphicsDrawingContext: CombinedFillStrokeDrawingContext {
    func fillAndStroke(
        path: ChalkPath, fillColor: ChalkColor, evenOdd: Bool,
        strokeColor: ChalkColor, lineWidth: Double, dash: [Double]
    ) {
        let converted = cgPath(from: path)
        fillConverted(converted, color: fillColor, evenOdd: evenOdd)
        strokeConverted(converted, color: strokeColor, lineWidth: lineWidth, dash: dash)
    }
}

/// Memoises `CoreGraphicsDrawingContext.measureText` results so glyph layout
/// runs at most once per distinct `(text, fontSize)` pair, instead of once
/// per repaint per text annotation. `SVGPathCache` is the house pattern this
/// deliberately mirrors (content-keyed, `NSLock`-protected, LRU-bounded by
/// retained key bytes, expensive work done OUTSIDE the lock); see that
/// type's doc comment for the full rationale each piece inherits.
///
/// WHY CACHING IS SAFE: the measurement is a pure function of `(text,
/// fontSize)` for the lifetime of the process -- it never reads the wrapped
/// `CGContext` (which is exactly why this cache can be `static`: a fresh
/// `CoreGraphicsDrawingContext` is constructed around every frame's
/// `CGContext`, so a per-instance cache would never see a second hit), and
/// `NSFont.systemFont(ofSize:)` resolves the same font for the same size
/// for as long as the process runs. Keying on content means there is
/// nothing to invalidate.
///
/// WHY IT IS BOUNDED: text content is caller-supplied and may approach
/// `DrawingDefaults.maxTextCharacters` (20,000) per string, so an unbounded
/// dictionary is a slow memory leak. The budget comfortably holds thousands
/// of typical short labels while capping the pathological case at a few
/// worst-case strings.
private enum TextMeasurementCache {
    private struct Key: Hashable {
        let text: String
        let fontSize: Double
    }

    /// Retained budget for cached text keys, counted in UTF-8 bytes like
    /// `SVGPathCache.maximumRetainedBytes` (the `CGSize` payloads and the
    /// `Double` half of each key are constant-size noise by comparison).
    private static let maximumRetainedBytes = 512 * 1024

    private static let lock = NSLock()
    private static var entries: [Key: (size: CGSize, lastUsed: UInt64)] = [:]
    /// Logical recency clock, exactly as in `SVGPathCache`: smallest
    /// `lastUsed` is the least recently used entry.
    private static var useCounter: UInt64 = 0
    private static var retainedBytes = 0

    /// Returns the cached size for `(text, fontSize)`, calling `measure`
    /// only on a miss. `measure` runs OUTSIDE the lock -- layout is the
    /// expensive part, and a duplicate concurrent measurement of the same
    /// string is harmless (both produce the same value; the second store
    /// finds the entry already present and just refreshes recency).
    static func size(text: String, fontSize: Double, measure: () -> CGSize) -> CGSize {
        let key = Key(text: text, fontSize: fontSize)
        lock.lock()
        if let cached = entries[key] {
            touch(key)
            lock.unlock()
            return cached.size
        }
        lock.unlock()

        let measured = measure()

        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            useCounter &+= 1
            entries[key] = (size: measured, lastUsed: useCounter)
            retainedBytes += key.text.utf8.count
            evictIfNeeded()
        } else {
            touch(key)
        }
        return measured
    }

    // MARK: - Private (all callers already hold `lock`)

    private static func touch(_ key: Key) {
        useCounter &+= 1
        entries[key]?.lastUsed = useCounter
    }

    private static func evictIfNeeded() {
        guard retainedBytes > maximumRetainedBytes, entries.count > 1 else { return }
        // One ordering pass for the whole eviction, and the `entries.count
        // > 1` guard keeps a single over-budget string cached rather than
        // re-measured every frame -- both for the same reasons
        // `SVGPathCache.evictIfNeeded` documents at length.
        let leastRecentlyUsedFirst = entries.map { (key: $0.key, lastUsed: $0.value.lastUsed) }
            .sorted { $0.lastUsed < $1.lastUsed }
        for victim in leastRecentlyUsedFirst {
            guard retainedBytes > maximumRetainedBytes, entries.count > 1 else { return }
            if entries.removeValue(forKey: victim.key) != nil {
                retainedBytes -= victim.key.text.utf8.count
            }
        }
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
