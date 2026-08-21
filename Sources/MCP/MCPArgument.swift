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

    /// Coerces a JSON boolean and rejects every other bridged Foundation
    /// value. In particular, JSON numbers arrive as `NSNumber` too, and a
    /// plain `as? Bool` accepts some of those NSNumber instances. Tool flags
    /// such as permission prompts must therefore use this rather than Swift's
    /// permissive bridge cast.
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// Returns true only when the caller supplied `key` with a value that is
    /// not a finite numeric value.  Draw-tool defaults are for *omitted*
    /// parameters, never for malformed parameters.  Keeping this distinction
    /// here prevents `opacity: "oops"` from being silently treated as the
    /// default opacity of 1, for example.
    static func hasInvalidSuppliedDouble(_ arguments: [String: Any], key: String) -> Bool {
        arguments.keys.contains(key) && double(arguments[key]) == nil
    }

    /// Scans `keys` in order and returns the first one that was supplied with
    /// a value that is not a finite double (via `hasInvalidSuppliedDouble`),
    /// or `nil` if every supplied key among `keys` parses. Several draw-tool
    /// argument parsers each validated their own short list of numeric-only
    /// keys with an identical `for key in [...] where hasInvalidSuppliedDouble(...)`
    /// loop; this is that loop, generalized so each call site keeps its own
    /// key list and error wording while sharing the scan itself.
    static func firstInvalidSuppliedDouble(_ args: [String: Any], keys: [String]) -> String? {
        keys.first { hasInvalidSuppliedDouble(args, key: $0) }
    }

    /// Scans `keys` in order and returns the first one that was supplied with
    /// a non-`String` value, or `nil` if every supplied key among `keys` is
    /// a string (or omitted). The string-argument counterpart to
    /// `firstInvalidSuppliedDouble`, for the equally repeated
    /// `for key in [...] where args.keys.contains(key) && !(args[key] is String)`
    /// loop.
    static func firstNonStringSupplied(_ args: [String: Any], keys: [String]) -> String? {
        keys.first { args.keys.contains($0) && !(args[$0] is String) }
    }

    /// JSON has only one numeric type at the protocol boundary.  `z_index`
    /// still needs integer semantics, so reject fractional and out-of-range
    /// doubles explicitly instead of silently truncating them.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }

            // JSONSerialization preserves integral JSON values as integral
            // NSNumbers where it can. Going through `doubleValue` first loses
            // precision above 2^53 (for example 9007199254740993 becomes
            // 9007199254740992), which is unacceptable for z/order and AX
            // occurrence semantics. Parse the NSNumber's exact decimal value
            // for integer-backed instances instead.
            let objcType = String(cString: number.objCType)
            if !["f", "d", "D"].contains(objcType) {
                return Int(number.stringValue)
            }

            // A floating JSON spelling has already crossed IEEE-754. Above
            // this threshold adjacent integers collapse together, so even an
            // integral-looking value cannot be accepted as an exact ordering
            // or occurrence index.
            let maxExactDoubleInteger = 9_007_199_254_740_991.0 // 2^53 - 1
            guard let floating = double(number), floating.rounded() == floating,
                  abs(floating) <= maxExactDoubleInteger else { return nil }
            // Checked conversion avoids the trap at Double(Int.max), whose
            // nearest representable Double is one integer beyond Int.max.
            return Int(exactly: floating)
        }

        if let string = value as? String {
            // Prefer an exact textual integer before accepting a floating
            // spelling such as "3.0". This preserves large textual integers.
            if let exact = Int(string) { return exact }
            let maxExactDoubleInteger = 9_007_199_254_740_991.0 // 2^53 - 1
            guard let floating = double(string), floating.rounded() == floating,
                  abs(floating) <= maxExactDoubleInteger else { return nil }
            return Int(exactly: floating)
        }
        return nil
    }
}
