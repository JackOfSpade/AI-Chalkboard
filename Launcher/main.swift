import Foundation
import AppKit
import AIChalkboardCore

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
