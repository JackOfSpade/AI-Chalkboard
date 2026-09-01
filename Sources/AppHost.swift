import Foundation
#if os(macOS)
import AppKit
#endif

/// Platform seam isolating the two AppKit-shaped assumptions that shared,
/// platform-neutral code (today: `MCPServer.swift`) would otherwise bake in
/// directly: "terminate the app" and "run this on the UI thread".
///
/// WHY THIS EXISTS: `MCPServer.swift` is compiled into the single
/// `AIChalkboardCore` target on BOTH platforms -- it has no `#if os(macOS)`
/// branches of its own, and per the porting rules for that file its
/// transport/framing/shutdown-on-EOF logic must stay byte-for-byte identical
/// across the port. Its only AppKit dependency was two calls,
/// `DispatchQueue.main.async { ... NSApp.terminate(nil) }`, used to hop onto
/// the main thread and then terminate the app after a transport failure.
/// Both calls route through this enum instead, so `MCPServer.swift` itself
/// needs no `import AppKit` and no `#if os(Windows)` branch of its own.
///
/// `AppDelegate.markInternalTermination(reason:)` (see AppDelegate.swift) is
/// the other half of every non-user termination path: every caller here and
/// elsewhere marks the shutdown internal BEFORE calling `AppHost.terminate()`,
/// exactly as the macOS `AppDelegate`'s doc comments already require -- this
/// seam does not change that contract, it only replaces the platform call
/// beneath it.
public enum AppHost {
    /// Requests process termination through the platform's normal
    /// application-lifecycle shutdown path, so the platform-specific
    /// "is this a user quit or a lifecycle shutdown" bookkeeping in
    /// `AppDelegate` still runs.
    ///
    /// macOS: forwards to `NSApp.terminate(nil)`, which AppKit dispatches to
    /// `AppDelegate.applicationShouldTerminate(_:)`.
    ///
    /// Windows: forwards to `AppDelegate.current`'s termination entry point.
    /// SAFE TO CALL FROM ANY THREAD -- unlike `NSApp.terminate`, which AppKit
    /// itself expects on the main thread, there is no framework enforcing
    /// that here, so `AppDelegate.terminate()` hops to the Win32
    /// message-loop thread itself when called from elsewhere (e.g. the
    /// `SetConsoleCtrlHandler` callback in Launcher/main.swift, which always
    /// runs on a Windows-created thread of its own). See that method's doc
    /// comment for the mechanism and its honest limits.
    public static func terminate() {
        #if os(macOS)
        NSApp.terminate(nil)
        #elseif os(Windows)
        AppDelegate.current?.terminate()
        #else
        // No other platform is targeted by this package today. A silent
        // no-op here would hide a real gap the moment one is added; fail
        // loudly instead so a future port notices immediately rather than
        // discovering a process that never exits.
        fatalError("AppHost.terminate() has no implementation for this platform.")
        #endif
    }

    /// Runs `work` on this process's UI/main thread.
    ///
    /// NOT a synonym for `DispatchQueue.main.async` -- that is precisely the
    /// trap this function exists to avoid. On macOS, AppKit's `app.run()`
    /// (in Launcher/main.swift) services `DispatchQueue.main` as a side
    /// effect of running the main run loop, so `DispatchQueue.main.async`
    /// works there. On Windows, Launcher/main.swift's entry point runs a raw
    /// `GetMessageW`/`TranslateMessage`/`DispatchMessageW` pump instead of
    /// calling `dispatchMain()` or `RunLoop.main.run()` -- nothing services
    /// libdispatch's main queue, so a `DispatchQueue.main.async` closure
    /// posted there would simply never execute. (This was found by auditing
    /// every `DispatchQueue.main` use reachable from code that also runs on
    /// Windows; see Launcher/main.swift's Windows branch for the full note.)
    /// Route any such closure through here instead, on both platforms, so it
    /// keeps working if the Windows entry point's pumping mechanism ever
    /// changes.
    public static func runOnMain(_ work: @escaping () -> Void) {
        #if os(macOS)
        DispatchQueue.main.async(execute: work)
        #elseif os(Windows)
        if let delegate = AppDelegate.current {
            delegate.runOnUIThread(work)
        } else {
            // No delegate constructed yet -- reachable only in the sliver of
            // startup before Launcher/main.swift builds one and assigns
            // `AppDelegate.current`. There is no UI thread to hand this off
            // to yet, and every real call site today only reaches this
            // function well after that assignment, so this is a defensive
            // fallback, not an expected path. Running inline is the honest
            // choice: silently dropping the work would be strictly worse,
            // and nothing here is main-thread-only before any window exists.
            work()
        }
        #else
        fatalError("AppHost.runOnMain(_:) has no implementation for this platform.")
        #endif
    }
}
