import Foundation
#if os(Windows)
import WinSDK
#endif

/// Release identity exposed to MCP clients so a desktop session can identify
/// exactly which bundled Chalkboard process it is talking to.
///
/// - **macOS**: build_app.sh embeds the identifier into the .app bundle's
///   Info.plist, and `buildIdentifier(infoDictionary:)` below reads it back
///   out of `Bundle.main`.
/// - **Windows**: there is no bundle and no Info.plist. build_app.ps1 instead
///   writes a small sidecar text file (`windowsSidecarFileName`) next to
///   `AIChalkboard.exe` in the deployable layout, and
///   `buildIdentifier(sidecarDirectory:)` below reads it from the directory
///   containing the CURRENTLY RUNNING executable (resolved via
///   `GetModuleFileNameW`, not the process's working directory -- Claude
///   Desktop launches this server with an unrelated cwd, so a relative
///   lookup would silently miss it).
///
/// Either way, a bare `swift build` output -- no Info.plist key on macOS, no
/// sidecar file on Windows -- intentionally falls back to the stable
/// `source` identifier rather than pretending to know a Git revision.
enum BuildMetadata {
    static let productVersion = "2.1.0"
    static let buildIdentifierInfoKey = "AIChalkboardBuildIdentifier"
    static let sourceBuildIdentifier = "source"
    /// Name of the sidecar file build_app.ps1 writes next to the .exe. Must
    /// match that script's own literal exactly.
    static let windowsSidecarFileName = "build-identifier.txt"
    /// Generous cap for the sidecar read -- the file holds one short token,
    /// so anything near this size means something is wrong, and per Task
    /// requirement it is treated as absent rather than thrown.
    private static let windowsSidecarMaxBytes: UInt64 = 4_096

    static var buildIdentifier: String {
        #if os(Windows)
        return buildIdentifier(sidecarDirectory: currentExecutableDirectory())
        #else
        return buildIdentifier(infoDictionary: Bundle.main.infoDictionary)
        #endif
    }

    static func buildIdentifier(infoDictionary: [String: Any]?) -> String {
        guard let rawIdentifier = infoDictionary?[buildIdentifierInfoKey] as? String else {
            return sourceBuildIdentifier
        }
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? sourceBuildIdentifier : identifier
    }

    #if os(Windows)
    /// Windows counterpart of `buildIdentifier(infoDictionary:)` above: a
    /// pure function over an injected directory so it is unit-testable
    /// without a real dist\AIChalkboard deployment or a running
    /// GetModuleFileNameW lookup -- callers pass a real directory path (or
    /// `nil`, mirroring a `GetModuleFileNameW` failure) and get back the
    /// fully-resolved identifier, fallback included.
    ///
    /// An unreadable, missing, or oversized sidecar (`BoundedLocalFile.read`
    /// enforces `windowsSidecarMaxBytes`) is treated as absent, exactly like
    /// a missing Info.plist key on macOS -- never thrown.
    static func buildIdentifier(sidecarDirectory: String?) -> String {
        guard let directory = sidecarDirectory, !directory.isEmpty else {
            return sourceBuildIdentifier
        }
        let separator = directory.hasSuffix("\\") || directory.hasSuffix("/") ? "" : "\\"
        let sidecarPath = directory + separator + windowsSidecarFileName
        guard let data = try? BoundedLocalFile.read(path: sidecarPath, maxBytes: windowsSidecarMaxBytes),
              let raw = String(data: data, encoding: .utf8) else {
            return sourceBuildIdentifier
        }
        let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? sourceBuildIdentifier : identifier
    }

    /// Directory containing the currently running executable, resolved via
    /// `GetModuleFileNameW(nil, ...)` -- the same API/idiom
    /// `InstanceBroadcast.ownExecutablePath` and
    /// `SuspensionQuiescence` already use to find this process's own image
    /// path. `nil` only when the call itself fails or truncates, which
    /// `buildIdentifier(sidecarDirectory:)` treats as "no sidecar" (fail to
    /// the `source` fallback), same as any other absent sidecar.
    private static func currentExecutableDirectory() -> String? {
        var buffer = [UInt16](repeating: 0, count: 1024)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0, Int(length) < buffer.count else { return nil }
        let path = String(decoding: buffer[0..<Int(length)], as: UTF16.self)
        guard let lastSeparator = path.lastIndex(of: "\\") else { return nil }
        return String(path[path.startIndex..<lastSeparator])
    }
    #endif
}
