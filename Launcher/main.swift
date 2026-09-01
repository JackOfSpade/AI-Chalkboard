import Foundation
import AIChalkboardCore

#if os(macOS)
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// MARK: - Signal handling
//
// Without this, SIGTERM -- the normal way a parent process (Claude Desktop)
// asks a child process to shut down -- kills this process instantly via the
// POSIX default disposition: no unwind, no destructors, no log line. That is
// why the app's log was completely silent about process death even though
// the MCP host clearly observed the transport closing.
//
// We deliberately use DispatchSource.makeSignalSource(signal:queue:) rather
// than the raw signal() C callback. Raw signal handlers may only call
// async-signal-safe functions; calling into Swift/Foundation (Logger, NSApp)
// from one is undefined behavior. DispatchSource instead redelivers the
// signal as a normal event on a GCD queue, where logging and AppKit calls
// are safe.

/// Strong references to the active signal sources. A DispatchSource that is
/// deallocated stops delivering events, so these must be kept alive for the
/// lifetime of the process.
private var signalSources: [DispatchSourceSignal] = []

private func installSignalHandler(_ sig: Int32, name: String) {
    // The default disposition for these signals is immediate termination.
    // We must explicitly ignore that default *before* creating the
    // DispatchSource, otherwise the process is killed before the source
    // ever gets a chance to fire.
    signal(sig, SIG_IGN)

    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Logger.shared.log("Received signal \(name) (\(sig)). Initiating clean shutdown.", level: "SIGNAL")
        if NSApp != nil && NSApp.isRunning {
            // LIFECYCLE shutdown, NOT a user quit: a signal is addressed to
            // THIS pid only (Claude Desktop tearing down one child, a `kill`,
            // a shell Ctrl-C). Marking it internal keeps
            // AppDelegate.applicationShouldTerminate from fanning a quit
            // broadcast out to a sibling instance nobody asked to stop. The
            // flag only ever short-circuits that broadcast, so this shutdown
            // is not delayed by it. (This handler runs on the main queue --
            // see the `queue: .main` on the DispatchSource created above --
            // which is where markInternalTermination must be called from.)
            AppDelegate.markInternalTermination(reason: "signal \(name)")
            NSApp.terminate(nil)
        } else {
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

installSignalHandler(SIGTERM, name: "SIGTERM")
installSignalHandler(SIGINT, name: "SIGINT")
installSignalHandler(SIGHUP, name: "SIGHUP")

// SIGPIPE: writing to a closed pipe -- here, specifically, the MCP client's
// end of this process's stdout going away -- raises SIGPIPE at its POSIX
// default disposition, which terminates this process IMMEDIATELY: no unwind,
// no log line, and critically, no chance for MCPServer.sendResponse's
// do/catch around `FileHandle.standardOutput.write(contentsOf:)` to ever run.
// Ignoring SIGPIPE converts that fatal signal into an ordinary `EPIPE` Error
// on the write call that would have raised it, which sendResponse already
// handles: it logs the failure and, in MCP mode, routes into the same
// graceful shutdown used for stdin EOF (see
// MCPServer.terminateAfterTransportFailure). This is reachable in normal
// operation specifically because this process's stdout IS the MCP client's
// pipe, and the client can close it at any time (crash, force-quit, the user
// closing Claude Desktop). Unlike SIGTERM/SIGINT/SIGHUP above, SIGPIPE is
// simply ignored here (not redelivered via a DispatchSource) -- there is no
// "clean shutdown" action to take in response to a single failed write, only
// a normal Swift `Error` to hand back to the caller that attempted it.
signal(SIGPIPE, SIG_IGN)

// MARK: - Uncaught exception logging
//
// Objective-C style exceptions (many AppKit failures surface this way)
// bypass Swift's normal error handling and would otherwise crash with
// nothing in our own log to explain why. Record what we can before the
// process dies.
NSSetUncaughtExceptionHandler { exception in
    let stack = exception.callStackSymbols.joined(separator: "\n")
    // Use logSync, not log(): the runtime calls abort() immediately after
    // this handler returns, and log()'s file write is queue.async'd, so it
    // can lose the race and never make it to disk (it would still reach
    // stderr). logSync writes to the file synchronously on this thread and
    // fsyncs before returning, so the one line explaining the crash is
    // durable by the time abort() runs. This handler runs on its own
    // thread, not inside Logger's serial queue, so calling logSync here is
    // safe (see the "MUST NOT" note on logSync).
    Logger.shared.logSync(
        "Uncaught exception: \(exception.name.rawValue) reason: \(exception.reason ?? "<none>")\n\(stack)",
        level: "FATAL"
    )
}

// Launch main NSApplication run loop
app.run()

#elseif os(Windows)
import WinSDK

// MARK: - Windows entry point
//
// This is the Windows counterpart to the macOS branch above: it wires up
// process-level shutdown and crash logging exactly like that branch, then
// constructs the Windows `AppDelegate` (tray icon, election/watchdog/
// reconcile timers, MCP server, overlay) and runs the Win32 message loop
// that hosts it all, mirroring `app.run()` at the bottom of the macOS
// branch.

// MARK: DPI awareness -- MUST run before any window is created
//
// Windows resolves a process's DPI-awareness mode once, effectively "the
// first time it matters" (in practice: before the first window is created,
// including a message-only one) -- a call made after `AppDelegate.launch()`
// creates its tray window below would be too late. `PER_MONITOR_AWARE_V2`
// (Windows 10 version 1703+) is the modern per-monitor mode: each window is
// DPI-scaled according to the specific monitor it is actually on, rather
// than one system-wide value, which is what the per-screen backing-scale
// handling in OverlayWindowController.swift needs to place annotations
// correctly on a mixed-DPI multi-monitor desktop. No fallback to the older
// `PROCESS_PER_MONITOR_DPI_AWARE` / `SetProcessDPIAware` APIs is
// implemented here: this app already assumes a reasonably current Windows
// 10/11 installation elsewhere (AppDelegate.swift's tray icon uses modern
// `Shell_NotifyIconW` flags with the same assumption), so adding a fallback
// path would be complexity for a case this port does not otherwise support,
// not a real gap.
if !SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) {
    Logger.shared.log("SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) failed (Win32 error \(GetLastError())). Continuing without explicit per-monitor DPI awareness -- overlay placement may be off on non-100%-scaled or mixed-DPI multi-monitor setups.", level: "WARN")
}

// MARK: Console control handler (SIGTERM/SIGINT/SIGHUP equivalent)
//
// Windows console processes do not receive POSIX signals. The analogous
// mechanism is SetConsoleCtrlHandler: Windows calls our handler on a new
// thread it creates for the purpose when the user presses Ctrl+C, presses
// Ctrl+Break, closes the console window, the user logs off, or the system
// shuts down (CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
// CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT respectively). This plays the same
// role that installSignalHandler(SIGTERM/SIGINT/SIGHUP) plays on macOS:
// make sure a shutdown request produces a clean, logged exit instead of the
// OS silently killing the process. Unlike the DispatchSource approach used
// on macOS (chosen there because raw POSIX signal handlers may only call
// async-signal-safe functions), a console control handler on Windows runs
// as an ordinary thread -- calling into Logger/Foundation from it is safe.
//
// For CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, and CTRL_SHUTDOWN_EVENT, Windows
// only grants the process a short grace period (on the order of a few
// seconds, historically ~5s, and shorter still for logoff/shutdown) after
// the handler returns TRUE before it force-terminates -- so this handler
// must log and exit quickly rather than doing extended cleanup.
private func consoleCtrlHandler(_ ctrlType: DWORD) -> WindowsBool {
    let name: String
    switch ctrlType {
    case DWORD(CTRL_C_EVENT):
        name = "CTRL_C_EVENT"
    case DWORD(CTRL_BREAK_EVENT):
        name = "CTRL_BREAK_EVENT"
    case DWORD(CTRL_CLOSE_EVENT):
        name = "CTRL_CLOSE_EVENT"
    case DWORD(CTRL_LOGOFF_EVENT):
        name = "CTRL_LOGOFF_EVENT"
    case DWORD(CTRL_SHUTDOWN_EVENT):
        name = "CTRL_SHUTDOWN_EVENT"
    default:
        name = "UNKNOWN(\(ctrlType))"
    }
    // Use logSync, not log(): the process may be torn down within a few
    // seconds of this handler returning (see comment above), and log()'s
    // file write is queue.async'd and can lose that race. logSync writes
    // synchronously and fsyncs before returning, mirroring the rationale
    // for using it in NSSetUncaughtExceptionHandler on the macOS branch.
    Logger.shared.logSync("Received console control event \(name) (\(ctrlType)). Initiating clean shutdown.", level: "SIGNAL")

    // Mirrors the macOS branch's installSignalHandler(SIGTERM/SIGINT/SIGHUP):
    // mark this a LIFECYCLE shutdown (this event targets only this
    // process/console session, not a deliberate "Quit AI Chalkboard" from
    // the tray menu), then route through the same AppHost.terminate() choke
    // point every other lifecycle shutdown path uses.
    //
    // HONEST LIMITATIONS vs. macOS's SIGTERM handling -- read before
    // assuming this always completes cleanly:
    //
    //   * This handler runs on a thread Windows creates for the purpose, NOT
    //     the UI thread running the message loop below. AppHost.terminate()
    //     -> AppDelegate.terminate() therefore marshals the actual shutdown
    //     work back onto the UI thread via a posted message (see that
    //     method's doc comment) rather than running inline here -- it
    //     completes asynchronously, after this function returns, not before.
    //
    //   * For CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, and CTRL_SHUTDOWN_EVENT
    //     specifically, Windows grants only a short grace period (on the
    //     order of a few seconds, shorter still for logoff/shutdown) after
    //     THIS FUNCTION RETURNS before force-terminating the process. There
    //     is no guarantee the posted message is ever drained by the UI
    //     thread inside that window, so the sibling-quit broadcast this
    //     triggers may not complete -- or may never even start running.
    //
    //   * If the MCP host tears this process down with TerminateProcess (a
    //     hard kill, no console event delivered at all -- unlike SIGKILL on
    //     POSIX, this is the ONLY forceful kill primitive Windows exposes to
    //     a parent process, and it is what most MCP host implementations
    //     reach for), NONE of this runs: there is no graceful-shutdown
    //     opportunity whatsoever. This is a genuine termination-safety
    //     difference from macOS, where SIGTERM is always delivered first --
    //     not a bug in this handler. In that path the sibling-quit fan-out
    //     is simply skipped; a sibling instance left running self-heals via
    //     InstanceLock's primary re-election instead (see AppDelegate
    //     .swift's primaryElectionRetryTick()), which does not depend on
    //     this process having shut down cleanly, or at all.
    AppDelegate.markInternalTermination(reason: "console control event \(name)")
    AppHost.terminate()

    return true
}

SetConsoleCtrlHandler({ ctrlType in
    consoleCtrlHandler(ctrlType)
}, true)

// NOTE on SIGPIPE: Windows has no SIGPIPE. There is no default-disposition
// signal that kills this process when the MCP client's end of our stdout
// pipe goes away. A write to a closed pipe on Windows instead simply fails
// the write call (surfaces to Swift as an ordinary `Error` off
// FileHandle.standardOutput.write(contentsOf:), e.g. reflecting
// ERROR_BROKEN_PIPE/ERROR_NO_DATA), which MCPServer.sendResponse's existing
// do/catch already handles the same way it handles the ignored-SIGPIPE case
// on macOS. So unlike the macOS branch, there is nothing to install here --
// this comment exists so a future reader doesn't go looking for a
// SIGPIPE-equivalent call that was simply forgotten.

// MARK: Unhandled exception logging
//
// SetUnhandledExceptionFilter is the Windows analogue of
// NSSetUncaughtExceptionHandler above: it runs when a structured exception
// (access violation, stack overflow, etc.) would otherwise crash the
// process with nothing in our own log to explain why. We record what we
// can before the default handler runs and the process dies.
SetUnhandledExceptionFilter({ exceptionInfo in
    let code = exceptionInfo?.pointee.ExceptionRecord?.pointee.ExceptionCode ?? 0
    // logSync for the same reason as NSSetUncaughtExceptionHandler's use of
    // it on macOS: the process is about to die and log()'s async file write
    // could lose that race.
    Logger.shared.logSync(
        "Unhandled exception: code 0x\(String(code, radix: 16))",
        level: "FATAL"
    )
    return LONG(EXCEPTION_CONTINUE_SEARCH)
})

// MARK: - App construction
//
// Mirrors the macOS branch's `let delegate = AppDelegate(); app.delegate =
// delegate` pair: construct the Windows delegate and publish it via
// `AppDelegate.current` BEFORE anything (the console-control handler
// above included, since it can fire at any time once installed) might try
// to reach it through `AppHost.terminate()`.
let delegate = AppDelegate()
AppDelegate.current = delegate
delegate.launch()

// MARK: - DispatchQueue.main audit note
//
// READ THIS BEFORE ADDING ANY `DispatchQueue.main.async`/`.sync` CALL THAT
// CAN RUN ON WINDOWS. This entry point runs a raw
// `GetMessageW`/`TranslateMessage`/`DispatchMessageW` pump below, NOT
// `dispatchMain()` and NOT `RunLoop.main.run()`. Neither of those was
// called anywhere in this port, which matters because swift-corelibs-
// libdispatch's `DispatchQueue.main` is only ever serviced by one of those
// two mechanisms -- there is no ambient "main thread" servicing on
// non-Darwin platforms the way AppKit's `app.run()` provides for free on
// macOS. A `DispatchQueue.main.async` closure queued anywhere in code that
// also runs on Windows would therefore simply sit forever, unexecuted.
//
// This was audited for across every file this Windows port touches or
// depends on:
//   * MCPServer.swift's `terminateAfterTransportFailure()` (shared,
//     platform-neutral code, reachable on both platforms) used to wrap its
//     shutdown call in `DispatchQueue.main.async { ... NSApp.terminate(nil) }`
//     directly. Fixed: it now goes through `AppHost.runOnMain { ... }` (see
//     AppHost.swift), which is `DispatchQueue.main.async` on macOS and a
//     posted-message hand-off to THIS message loop's thread on Windows.
//   * AppDelegate.swift's Windows branch deliberately uses Win32
//     `SetTimer`/`WM_TIMER` for its election-retry/lock-watchdog/
//     suspension-reconcile timers, specifically INSTEAD OF Foundation's
//     `Timer`/`RunLoop.main` (which the macOS branch uses) -- a `Timer`
//     scheduled on `RunLoop.main` has exactly the same "nothing services it"
//     problem as `DispatchQueue.main` here, since `RunLoop.main.run()` is
//     never called either.
//   * NOT fixed, and out of this task's ownership: `Sources/Support/
//     MainThread.swift`'s `async(_:)`/`enqueue(_:)` helpers fall back to
//     `DispatchQueue.main.async` on their non-inline path (when called from
//     a thread other than the one they were built to target), and multiple
//     macOS-only files this port depends on but does not own --
//     `InstanceBroadcast.swift`'s QUIT-watchdog (`DispatchQueue.main
//     .asyncAfter`) among them -- share the same pattern. Both will need
//     the equivalent of `AppHost.runOnMain` (or to be told about the UI
//     thread this loop owns some other way) once they are Windows-ported;
//     flagged here rather than fixed, since neither file is in this
//     Windows-port task's ownership.

// MARK: - Win32 message loop (the Windows analogue of `app.run()`)
//
// Blocks this thread until `AppDelegate`'s termination path (see
// `AppDelegate.terminate()`/`shutdownNow()`) destroys the tray window and
// its `WM_DESTROY` handler posts `WM_QUIT` -- `GetMessageW` then returns 0
// and this loop, and the process, exits.
//
// NOTE ON THE (RARE) `GetMessageW` ERROR RETURN: the raw Win32 contract
// returns -1, not just 0/nonzero, if the call itself fails (e.g. an
// invalid `hwnd` filter -- not reachable here, since `nil` is passed).
// This toolchain's WinSDK overlay types `GetMessageW` as returning a plain
// `Bool`, which cannot distinguish that -1 case from an ordinary `TRUE`, so
// an unexpected internal failure here would look identical to "keep
// pumping messages" rather than being distinguishable from success. Given
// the fixed, always-valid arguments passed below, this is a theoretical
// gap rather than an expected failure mode, but it is a real, honest
// limit of what this loop can detect -- recorded here rather than silently
// assumed away.
var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}

#endif
