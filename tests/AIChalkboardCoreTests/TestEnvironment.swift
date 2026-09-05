#if os(Windows)
import WinSDK
#endif
import Foundation

/// Cross-platform environment writes for tests.
///
/// Windows has no POSIX `setenv`. `SetEnvironmentVariableW` is the Win32
/// equivalent, and it is the one `ProcessInfo.processInfo.environment` actually
/// observes: that property re-reads the live environment block rather than a
/// start-of-process snapshot, verified on Swift 6.3.3 for
/// x86_64-unknown-windows-msvc. (The CRT keeps a separate table, so a CRT-only
/// write would not be seen by Foundation.)
///
/// That live-read behaviour is what lets a test seed a variable before a lazy
/// `static let` singleton first resolves it.
enum TestEnvironment {
    /// Sets `name`, or removes it when `value` is nil.
    static func set(_ name: String, _ value: String?) {
        #if os(Windows)
        name.withCString(encodedAs: UTF16.self) { wideName in
            if let value {
                value.withCString(encodedAs: UTF16.self) { wideValue in
                    _ = SetEnvironmentVariableW(wideName, wideValue)
                }
            } else {
                _ = SetEnvironmentVariableW(wideName, nil)
            }
        }
        #else
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
        #endif
    }

    /// Runs `body` with `name` set to `value` (or removed when nil), restoring
    /// whatever was there before -- including restoring "absent" correctly.
    static func withValue<T>(_ name: String, _ value: String?, _ body: () throws -> T) rethrows -> T {
        let previous = ProcessInfo.processInfo.environment[name]
        set(name, value)
        defer { set(name, previous) }
        return try body()
    }
}
