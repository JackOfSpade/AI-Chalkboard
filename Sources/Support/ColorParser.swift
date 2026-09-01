import Foundation

/// Parses the color spellings every drawing tool accepts into a `ChalkColor`.
///
/// Lives in Support rather than in `Models/Annotation.swift`, where it used to
/// sit: it holds no annotation state, is used by the renderer and by MCP
/// argument validation alike, and already has its own dedicated test file
/// (`ColorParserTests`). Keeping it beside the annotation model implied a
/// coupling that does not exist.

public struct ColorParser {
    public static func parse(_ colorString: String?) -> ChalkColor {
        guard let colorString = colorString?.trimmingCharacters(in: .whitespacesAndNewlines), !colorString.isEmpty else {
            return ChalkColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9) // Default bright red
        }

        let lower = colorString.lowercased()
        switch lower {
        case "red": return ChalkColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        case "green": return ChalkColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 0.9)
        case "blue": return ChalkColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.9)
        case "yellow": return ChalkColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.9)
        case "orange": return ChalkColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.9)
        case "purple": return ChalkColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 0.9)
        case "pink": return ChalkColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 0.9)
        case "cyan": return ChalkColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 0.9)
        case "white": return ChalkColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9)
        case "black": return ChalkColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.9)
        default: break
        }

        var hex = lower
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        // Validate BEFORE trusting Scanner's parse. `scanHexInt64` stops at the
        // first character it can't consume and still reports success with
        // whatever prefix it DID consume -- `intVal` is pre-initialised to 0,
        // so an all-invalid string like "GGGGGG" silently parses to 0 instead
        // of failing. Branching on `hex.count` alone (below) would then treat
        // a garbage string as a well-formed value purely because it happened
        // to have the right length, e.g. "12GG56" is 6 characters and would be
        // read as a legitimate 6-digit RGB value despite only "12" of it ever
        // having been parsed.
        //
        // Requiring every remaining character to be an ASCII hex digit also
        // incidentally rejects a "0x"/"0X" prefix (Scanner's `scanHexInt64`
        // recognizes and skips one): "0xff0000" is 8 characters, which without
        // this check would be misrouted into the 8-digit RGBA branch below
        // reading only "ff0000" -- 'x' is not a hex digit, so it now correctly
        // falls through to the same red fallback other malformed strings get.
        let isPureHexDigits = !hex.isEmpty && hex.allSatisfy { "0123456789abcdef".contains($0) }
        guard isPureHexDigits, [3, 6, 8].contains(hex.count) else {
            return ChalkColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9) // Invalid colour: same red fallback as wrong-length strings
        }

        var intVal: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&intVal)

        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (intVal >> 8) * 17, (intVal >> 4 & 0xF) * 17, (intVal & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, intVal >> 16, intVal >> 8 & 0xFF, intVal & 0xFF)
        case 8: // ARGB or RGBA (32-bit) -> assume RGBA
            (r, g, b, a) = (intVal >> 24, intVal >> 16 & 0xFF, intVal >> 8 & 0xFF, intVal & 0xFF)
        default:
            return ChalkColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        }

        return ChalkColor(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            alpha: Double(a) / 255.0
        )
    }
}
