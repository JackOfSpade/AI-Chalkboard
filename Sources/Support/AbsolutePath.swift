import Foundation

/// Is a path absolute in the running platform's own syntax?
///
/// Callers use this to gate *environment-variable path overrides*, whose whole
/// point is to be independent of wherever the process happened to be launched
/// from. A value that is not absolute would be resolved against the current
/// directory, silently scattering state somewhere unpredictable.
///
/// Foundation's `NSString.isAbsolutePath` is NOT sufficient for that job on
/// Windows: it accepts the DRIVE-RELATIVE form `C:relative` (a path relative to
/// the current directory *of drive C:*), which `URL(fileURLWithPath:)` then
/// resolves against the process's current directory. Verified on Swift 6.3.3
/// for x86_64-unknown-windows-msvc, where `C:relative` resolved to
/// `<current directory>/C:relative` -- exactly the outcome these guards exist
/// to prevent.
///
/// Absolute here means:
/// - **macOS**: a leading `/`.
/// - **Windows**: a UNC path (`\\server\share\...`, which also covers the
///   long-path `\?\C:\...` form), or a drive-letter path that actually
///   carries a separator (`C:\...` or `C:/...`).
///
/// This is a narrow, defense-in-depth guard for trusted-ish internal overrides,
/// not a general-purpose Windows path validator.
enum AbsolutePath {
    static func isAbsolute(_ path: String) -> Bool {
        #if os(Windows)
        if path.hasPrefix("\\\\") { return true }
        let bytes = Array(path.utf8)
        guard bytes.count >= 3 else { return false }
        let drive = bytes[0]
        let isLetter = (drive >= UInt8(ascii: "A") && drive <= UInt8(ascii: "Z"))
            || (drive >= UInt8(ascii: "a") && drive <= UInt8(ascii: "z"))
        return isLetter
            && bytes[1] == UInt8(ascii: ":")
            && (bytes[2] == UInt8(ascii: "\\") || bytes[2] == UInt8(ascii: "/"))
        #else
        return path.hasPrefix("/")
        #endif
    }
}
