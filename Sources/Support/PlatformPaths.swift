import Foundation

/// Cross-platform filesystem locations this app writes to outside its own
/// bundle/install directory: diagnostic logs and persisted application
/// state.
///
/// Both are derived from `FileManager`'s platform search-path APIs rather
/// than hardcoding a home directory or user name, so resolution is correct
/// under any account -- including a Windows machine where `%LOCALAPPDATA%`
/// has been redirected by policy, or a macOS machine with a non-default
/// home directory.
public enum PlatformPaths {

    /// Directory where diagnostic logs are written.
    ///
    /// - **macOS**: `~/Library/Logs/AIChalkboard`. This exact path is a
    ///   user-facing contract documented in the README's "Bounded
    ///   Diagnostics" section, so it must never change on macOS.
    /// - **Windows**: `%LOCALAPPDATA%\AIChalkboard\Logs` (typically
    ///   `C:\Users\<user>\AppData\Local\AIChalkboard\Logs`). There is no
    ///   Windows analogue of `~/Library/Logs`, so this follows the ordinary
    ///   Windows convention of a per-app subdirectory under the local
    ///   (non-roaming) app-data root -- the same root
    ///   `applicationSupportDirectory` below resolves to.
    public static var logDirectory: URL {
        #if os(macOS)
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("AIChalkboard")
        #elseif os(Windows)
        return applicationSupportDirectory.appendingPathComponent("Logs")
        #endif
    }

    /// Directory where persisted, non-log application state is written.
    ///
    /// - **macOS**: `~/Library/Application Support/AIChalkboard`.
    /// - **Windows**: `%LOCALAPPDATA%\AIChalkboard` (typically
    ///   `C:\Users\<user>\AppData\Local\AIChalkboard`). Verified against the
    ///   installed Windows Swift toolchain: `FileManager`'s
    ///   `.applicationSupportDirectory` search path resolves directly to
    ///   `%LOCALAPPDATA%` on Windows -- there is no nested "Application
    ///   Support" folder the way there is under macOS's `~/Library` -- so
    ///   this needs no platform branch of its own: the same
    ///   `FileManager` call already returns the platform-correct base on
    ///   both operating systems, and only the app-name component is
    ///   appended here.
    public static var applicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AIChalkboard")
    }
}
