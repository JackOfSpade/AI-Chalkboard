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
    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try work()
        }
        return try DispatchQueue.main.sync(execute: work)
    }

    /// Schedules `work` on the main thread, returning immediately unless the
    /// caller is already on main (in which case it runs inline, so the caller
    /// is not deferred by a run-loop turn).
    ///
    /// Used for AppKit *mutations* that nobody is waiting on: repainting
    /// overlays, flipping window properties, terminating the app.
    static func async(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
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
        DispatchQueue.main.async(execute: work)
    }
}
