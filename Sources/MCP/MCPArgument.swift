import Foundation

/// Coerces raw MCP `tools/call` arguments to well-typed Swift values.
///
/// A free namespace rather than a method on `MCPServer`: `MCPServer`'s only
/// instance is the `MCPServer.shared` singleton, which writes JSON-RPC
/// responses straight to real stdout, so nothing hung off it can be driven
/// from a headless CI test. This type touches no AppKit and no singleton, so
/// `@testable import` can exercise the exact coercion logic every draw tool
/// relies on directly, with no process to spawn and no stdio to fake.
enum MCPArgument {
    /// Coerces an MCP tool argument to `Double`, accepting a JSON number or a
    /// numeric string and rejecting everything else. This is the single
    /// shared numeric helper for every draw tool (radius, coordinates,
    /// duration, step_px, stroke_width, path points), so fixing coercion here
    /// covers every call site at once.
    ///
    /// Two rejections beyond a plain `as?`/`Double(_:)` attempt:
    ///   * `value as? NSNumber` alone succeeds for JSON `true`/`false` -- a
    ///     JSON boolean bridges to `NSNumber` (backed by `CFBoolean`) just as
    ///     readily as a real number does, so without this check
    ///     `{"radius": true}` would silently become `1.0` instead of being
    ///     rejected as the wrong type.
    ///   * Both branches reject non-finite results. `NSNumber.doubleValue`
    ///     can itself be NaN/infinite, and `Double.init(String)` accepts
    ///     "nan"/"inf"/"infinity" (case-insensitively) -- either would
    ///     otherwise flow straight into stored geometry/duration values and
    ///     corrupt rendering or scheduling.
    static func double(_ value: Any?) -> Double? {
        if let num = value as? NSNumber {
            guard CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }
            let d = num.doubleValue
            return d.isFinite ? d : nil
        }
        if let str = value as? String, let d = Double(str) {
            return d.isFinite ? d : nil
        }
        return nil
    }
}
