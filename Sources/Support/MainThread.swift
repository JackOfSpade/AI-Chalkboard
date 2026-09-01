import Foundation

/// The one place this package expresses "this work must happen on the main
/// thread".
///
/// WHY THIS EXISTS: four separate copies of this logic had grown across the
/// codebase (`OverlayWindowController.onMain`, `ActiveAppTracker.onMainSync`,
/// `InstanceBroadcast.onMain`, plus an inline `Thread.isMainThread` branch in
/// `OverlayWindowController.getScreenInfos()`). They were NOT interchangeable
/// -- two were async and two were synchronous -- so the risk was never
/// duplication for its own sake, it was that a future edit would reach for the
/// wrong one. Naming the two behaviours separately makes the choice explicit at
/// every call site.
///
/// BOTH helpers run `work` INLINE when already on the main thread rather than
/// re-dispatching. For `sync` that is not an optimisation, it is a correctness
/// requirement: `DispatchQueue.main.sync` from the main thread deadlocks
/// instantly.
enum MainThread {

    /// Runs `work` on the main thread and waits for it to finish.
    ///
    /// Used for AppKit *queries* whose answer the caller needs right now --
    /// `NSScreen.screens`, `NSWorkspace.runningApplications` -- from the MCP
    /// server's background read queue.
    ///
    /// DEADLOCK CONTRACT, load-bearing: this is only safe because the main run
    /// loop is never blocked waiting on the caller. `MCPServer` reads stdin on
    /// `DispatchQueue.global()`, so the main thread is always free to service
    /// this hop. Never call this from code that the main thread is itself
    /// synchronously waiting on, and never call it from inside
    /// `OverlayView.draw(_:)` or any other AppKit callback -- those already run
    /// on main, which the `isMainThread` branch handles, but a *nested* sync
    /// hop from a background queue that main is waiting on would wedge the app.
    /// TWO OVERLOADS, deliberately -- exactly the shape `DispatchQueue.sync`
    /// itself uses. A single `rethrows` version cannot work on Windows: there
    /// the closure runs on a DIFFERENT thread while this one blocks, so its
    /// error has to be carried back as a value, and Swift will not accept a
    /// `rethrows` function that throws a value it cannot trace to the
    /// parameter. Overloading keeps every existing non-throwing call site
    /// (`MainThread.sync { ... }`, no `try`) compiling unchanged while letting
    /// throwing callers use `try MainThread.sync { try ... }`.
    static func sync<T>(_ work: () -> T) -> T {
        #if os(macOS)
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
        #elseif os(Windows)
        // See `isCurrentUIThread` below for why this is NOT the process's main
        // thread on Windows.
        return WindowsUIThread.shared.sync(work)
        #endif
    }

    /// Throwing counterpart of `sync(_:)`. See that overload's note.
    static func sync<T>(_ work: () throws -> T) throws -> T {
        #if os(macOS)
        if Thread.isMainThread {
            return try work()
        }
        return try DispatchQueue.main.sync(execute: work)
        #elseif os(Windows)
        return try WindowsUIThread.shared.syncThrowing(work)
        #endif
    }

    /// Schedules `work` on the main thread, returning immediately unless the
    /// caller is already on main (in which case it runs inline, so the caller
    /// is not deferred by a run-loop turn).
    ///
    /// Used for AppKit *mutations* that nobody is waiting on: repainting
    /// overlays, flipping window properties, terminating the app.
    static func async(_ work: @escaping () -> Void) {
        #if os(macOS)
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
        #elseif os(Windows)
        if WindowsUIThread.shared.isCurrentThread {
            work()
        } else {
            WindowsUIThread.shared.async(work)
        }
        #endif
    }

    /// Schedules `work` on the main thread unconditionally, even when the
    /// caller is already there.
    ///
    /// The difference from `async(_:)` matters in exactly one situation: when
    /// the work must not run re-entrantly inside whatever is currently
    /// executing on main. `AnnotationStore.notifyChange()` uses this so a
    /// store mutation performed on the main thread does not repaint from
    /// inside the mutating call.
    static func enqueue(_ work: @escaping () -> Void) {
        #if os(macOS)
        DispatchQueue.main.async(execute: work)
        #elseif os(Windows)
        WindowsUIThread.shared.async(work)
        #endif
    }

    /// True when the caller is already on the thread this type dispatches to.
    ///
    /// WHY THIS EXISTS AS ITS OWN QUESTION: callers used to spell this
    /// `Thread.isMainThread` inline, which is correct on macOS and WRONG on
    /// Windows. On macOS the UI thread genuinely is the process's main thread,
    /// because `NSApplication.run()` pumps AppKit there. On Windows the
    /// overlay's Win32 windows are owned by `WindowsUIThread` -- a dedicated
    /// thread running its own `GetMessageW` loop -- because a Win32 window may
    /// only be serviced by the thread that created it. The process main thread
    /// is a different thread, and nothing pumps `DispatchQueue.main` there at
    /// all (there is no `dispatchMain()` call; the main thread runs the host
    /// message loop instead), so a `DispatchQueue.main.sync` hop from Windows
    /// would never return.
    ///
    /// Any precondition that means "I must be on the UI thread" must ask THIS,
    /// not `Thread.isMainThread`.
    static var isCurrentUIThread: Bool {
        #if os(macOS)
        return Thread.isMainThread
        #elseif os(Windows)
        return WindowsUIThread.shared.isCurrentThread
        #endif
    }
}
