import Foundation

/// A platform-neutral RGBA color.
///
/// Shared (Foundation-only) code cannot use `NSColor` -- it does not exist on
/// Windows -- so this is the color currency for everything that isn't
/// drawing-surface code confined to a `#if os(macOS)` block: `ColorParser`,
/// the annotation model, and any renderer-agnostic style math. macOS drawing
/// code converts a `ChalkColor` to `NSColor` at the point it actually needs
/// to paint; it does not carry `NSColor` any further upstream than that.
public struct ChalkColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Clamps every component into `0...1` and maps non-finite input (NaN,
    /// +/-infinity) to `0` rather than letting it propagate -- a malformed or
    /// out-of-range component should degrade to "no contribution", not to a
    /// value that corrupts downstream math (e.g. compositing) or fails to
    /// round-trip through serialization.
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = ChalkColor.clamped(red)
        self.green = ChalkColor.clamped(green)
        self.blue = ChalkColor.clamped(blue)
        self.alpha = ChalkColor.clamped(alpha)
    }

    private static func clamped(_ component: Double) -> Double {
        guard component.isFinite else { return 0 }
        return min(1, max(0, component))
    }

    /// Returns a copy with `alpha` replaced by `newAlpha`, clamped the same
    /// way the memberwise initializer clamps it. The other components are
    /// already clamped, so they pass through unchanged.
    public func withAlphaComponent(_ newAlpha: Double) -> ChalkColor {
        ChalkColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    /// Scales `alpha` by `factor` and clamps the result -- the renderer's
    /// recurring `color.alpha * someOpacity` pattern, expressed once so every
    /// call site clamps consistently instead of re-deriving it.
    public func multiplyingAlpha(by factor: Double) -> ChalkColor {
        withAlphaComponent(alpha * factor)
    }
}
