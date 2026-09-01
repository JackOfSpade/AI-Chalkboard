#if os(Windows)
import WinSDK
import Foundation

/// Executes work on AI Chalkboard's single dedicated Win32 UI thread.
///
/// WHY THIS EXISTS: Win32 windows are owned by the thread that creates them,
/// and require that SAME thread to keep pumping a message loop
/// (GetMessage/TranslateMessage/DispatchMessage) for the window to ever
/// receive paint/input/system messages -- there is no AppKit-style "any
/// thread may talk to the window system, the run loop just delivers
/// messages to whoever owns the window" model. `DispatchQueue.main` is not a
/// substitute for that message loop either: nothing on this app's Windows
/// entry point calls `dispatchMain()`, so work enqueued onto
/// `DispatchQueue.main` there is never executed at all -- the main thread
/// runs a Win32 message loop instead (see `Launcher/main.swift`'s Windows
/// branch), not GCD's main queue. `MainThread.sync`/`.async` -- which hop to
/// `DispatchQueue.main` -- are therefore the WRONG tool for anything that
/// touches an overlay `HWND` on Windows, even though they are exactly right
/// for the identical-looking AppKit code on macOS. This type is the Windows
/// analogue of `Support/MainThread.swift`, but backed by a real dedicated
/// thread and Win32 message loop instead of GCD's main queue -- every
/// overlay window this process owns is created on, and every mutation of one
/// is marshalled onto, this one thread.
///
/// Deliberately its own dedicated thread rather than "whichever thread turns
/// out to be Windows' notion of main": `Launcher/main.swift`'s Windows branch
/// currently blocks in a `Sleep` loop rather than running a message loop
/// itself (see its TODO), and MCP stdio handling needs the real process main
/// thread free to block on stdin reads. Owning a single private thread here
/// means this class's contract ("one thread owns every overlay HWND") holds
/// regardless of what the process's actual main thread ends up doing.
final class WindowsUIThread {
    static let shared = WindowsUIThread()

    /// The custom message this class posts to itself to mean "drain the
    /// pending-work queue" -- distinct from every real window/system message
    /// so `runLoop()` can tell "wake up and run Swift closures" apart from
    /// ordinary message dispatch. `WM_APP` is the first value the Win32
    /// documentation reserves for application-defined messages, so this
    /// cannot collide with any real system message the loop also has to
    /// dispatch (WM_DISPLAYCHANGE, WM_DPICHANGED, ...).
    private static let drainMessage: UInt32 = UInt32(WM_APP) + 1

    /// Guards `_win32ThreadId` and doubles as the "thread is ready" signal
    /// `start()` blocks on.
    private let startCondition = NSCondition()
    private var didStart = false
    private var _win32ThreadId: DWORD = 0

    private let queueLock = NSLock()
    private var pendingWork: [() -> Void] = []

    private init() {}

    /// The live thread id `GetMessageW`/`PostThreadMessageW` operate on.
    /// Only meaningful after `start()` has returned -- `runLoop()` publishes
    /// it, under `startCondition`, before doing anything else.
    private var win32ThreadId: DWORD {
        startCondition.lock()
        defer { startCondition.unlock() }
        return _win32ThreadId
    }

    /// True when called from this dedicated UI thread itself. Before
    /// `start()` has published a thread id this is unconditionally false, so
    /// `sync`/`async` correctly treat every caller as "not yet on the UI
    /// thread" (there is nothing to run inline against) rather than racing a
    /// zero/uninitialized id.
    var isCurrentThread: Bool {
        let id = win32ThreadId
        return id != 0 && GetCurrentThreadId() == id
    }

    /// Starts the dedicated thread and blocks until its message loop exists
    /// and is ready to receive posted work. Idempotent -- only the first call
    /// actually spawns the thread; later calls (e.g. a redundant `setup()`)
    /// return immediately.
    func start() {
        startCondition.lock()
        guard !didStart else {
            startCondition.unlock()
            return
        }
        didStart = true
        startCondition.unlock()

        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread.name = "AIChalkboard.OverlayUIThread"
        // Foundation's Thread defaults to a real (non-background) QoS-ish
        // priority already; called out explicitly here because this thread
        // owns every overlay window's paint / UpdateLayeredWindow path, and
        // getting starved behind unrelated background work would show up as
        // visibly laggy annotations.
        thread.start()

        startCondition.lock()
        while _win32ThreadId == 0 {
            startCondition.wait()
        }
        startCondition.unlock()
    }

    private func runLoop() {
        // A message posted to a thread with no message queue is silently
        // DROPPED, not queued for later delivery (Win32 does not create a
        // thread's queue until that thread makes its first message-queue
        // call). Forcing that creation with a no-op PeekMessageW BEFORE
        // publishing this thread's id closes the gap where a `sync`/`async`
        // caller wakes immediately after `start()` returns and posts to a
        // thread whose queue does not exist yet.
        var probe = MSG()
        _ = PeekMessageW(&probe, nil, 0, 0, UInt32(PM_NOREMOVE))

        startCondition.lock()
        _win32ThreadId = GetCurrentThreadId()
        startCondition.signal()
        startCondition.unlock()

        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) {
            if msg.message == Self.drainMessage {
                drainPendingWork()
            } else {
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
        }
    }

    private func drainPendingWork() {
        let work: [() -> Void] = {
            queueLock.lock()
            defer { queueLock.unlock() }
            let items = pendingWork
            pendingWork.removeAll(keepingCapacity: true)
            return items
        }()
        for item in work {
            item()
        }
    }

    /// Schedules `work` on the UI thread and returns immediately, unless the
    /// caller is already on that thread (in which case it runs inline rather
    /// than being deferred a full loop turn -- mirrors `MainThread.async`'s
    /// same inline-when-already-there behavior).
    func async(_ work: @escaping () -> Void) {
        if isCurrentThread {
            work()
            return
        }
        // Lazily starts the thread on first use from ANY call site, not only
        // ones (like `ActiveAppTracker.startForegroundHook()`) that already
        // call `start()` defensively themselves. Without this, a caller that
        // reaches `sync`/`async` before `OverlayWindowController.setup()`
        // has run -- the real app always calls `setup()` first, but a unit
        // test that exercises `OverlayWindowController.shared` directly
        // (never running app-launch lifecycle code) does not -- would post
        // to `win32ThreadId == 0` (`PostThreadMessageW` silently fails
        // against a nonexistent thread id) and `sync`'s caller would block
        // on `done.wait()` forever, since nothing would ever drain the
        // queued work and signal it. `start()` itself is idempotent (guarded
        // by `didStart`), so calling it unconditionally here costs nothing
        // once the thread is already running.
        start()
        queueLock.lock()
        pendingWork.append(work)
        queueLock.unlock()
        _ = PostThreadMessageW(win32ThreadId, Self.drainMessage, 0, 0)
    }

    /// Runs `work` on the UI thread and blocks until it finishes, unless the
    /// caller is already on that thread (in which case it runs inline --
    /// posting to this same thread and then waiting on it would deadlock,
    /// exactly like `DispatchQueue.main.sync` called from the main thread).
    ///
    /// `work` is declared NON-escaping (the ordinary default), matching
    /// `Support/MainThread.swift`'s `sync(_:)` -- deliberately, so every call
    /// site can read exactly like the `MainThread.sync { ... }` it replaces,
    /// with implicit `self` inside the closure, rather than forcing
    /// `self.propertyName` everywhere a Windows call site touches instance
    /// state. `async(_:)` below genuinely needs `@escaping` (its closure is
    /// stored and run later), so `withoutActuallyEscaping` bridges the two:
    /// it is sound here specifically because this function blocks on `done
    /// .wait()` until the posted closure has actually run, so `work` never
    /// truly outlives this call despite being handed to something
    /// `@escaping`-typed.
    @discardableResult
    func sync<T>(_ work: () -> T) -> T {
        if isCurrentThread {
            return work()
        }
        // Ensures the dedicated thread already exists (idempotent, see
        // `async(_:)`'s own call to this) before any cross-thread hand-off
        // is attempted -- otherwise the very first `sync`/`syncThrowing`
        // call from any code path that never itself called `start()` first
        // would post to a nonexistent thread id and block forever. `start()`
        // itself is idempotent, so calling it unconditionally here costs
        // nothing once the thread is already running.
        start()
        return withoutActuallyEscaping(work) { escapableWork in
            let done = NSCondition()
            var result: T?
            var finished = false
            // `slot` -- NOT `escapableWork` directly -- is what the posted
            // closure below captures and calls. This indirection is
            // load-bearing, not stylistic: `swift_isEscapingClosureAtFileLocation`
            // verifies, at the exact moment this trailing closure returns,
            // that no reference to `escapableWork`'s underlying closure
            // context survives beyond this closure's own parameter binding.
            // The posted closure runs on `WindowsUIThread`, a genuinely
            // DIFFERENT thread, and Array-backed `pendingWork`/`drainPendingWork`
            // (see `async(_:)`) keeps a strong reference to the WHOLE
            // posted closure alive for the length of that thread's drain
            // loop -- which does not end the instant `done.signal()` fires
            // inside it, only once the loop and its snapshot array finish
            // unwinding. A calling thread that wakes from `done.wait()`
            // immediately after the signal can therefore race ahead of that
            // teardown and find `escapableWork` still (transitively) alive,
            // which is exactly what was observed empirically on this
            // toolchain: `sync`/`syncThrowing` intermittently, ONLY under
            // real cross-thread execution (never when `isCurrentThread` took
            // the inline path), fatally trapped with "closure argument was
            // escaped in withoutActuallyEscaping block" -- nondeterministically,
            // consistent with a genuine data race rather than a deterministic
            // logic bug. Routing the call through `slot` and explicitly
            // nilling it (dropping ITS strong reference to escapableWork's
            // context) as the posted closure's OWN last act BEFORE signaling
            // `done` -- both on the SAME thread, in this program order --
            // means NSCondition's signal-establishes-happens-before guarantee
            // ensures the calling thread can only observe `finished == true`
            // AFTER that reference has already been released, regardless of
            // how long the enclosing `pendingWork` array itself survives.
            var slot: (() -> T)? = escapableWork
            async {
                let value = slot!()
                slot = nil
                done.lock()
                result = value
                finished = true
                done.signal()
                done.unlock()
            }
            done.lock()
            while !finished {
                done.wait()
            }
            done.unlock()
            return result!
        }
    }

    /// `sync(_:)` for work that can throw.
    ///
    /// WHY A SEPARATE ENTRY POINT: Swift's `rethrows` cannot be expressed
    /// through the `withoutActuallyEscaping` + `NSCondition` hand-off that
    /// `sync(_:)` uses, because the closure actually runs on the UI thread
    /// while this thread is blocked -- the error has to be carried across that
    /// boundary as a value rather than propagated up a call stack. So the
    /// error is captured on the far side and re-thrown here.
    ///
    /// This backs `MainThread.sync`, which is `rethrows` and is called by code
    /// that queries platform state and can fail (screen snapshots, presentation
    /// diagnostics). Keeping it here rather than at the call site means every
    /// Windows caller inherits the same "run inline when already on the UI
    /// thread" rule that makes the macOS version deadlock-safe.
    /// Declared `throws`, not `rethrows`: the closure runs on the UI thread
    /// while this thread is blocked, so its error must be carried back as a
    /// VALUE rather than propagated up a shared call stack. Swift cannot prove
    /// to `rethrows` that the error it finally re-throws originated in the
    /// parameter, so `rethrows` is rejected outright here. `MainThread` keeps
    /// the ergonomics intact by overloading instead -- see `MainThread.sync`.
    func syncThrowing<T>(_ work: () throws -> T) throws -> T {
        if isCurrentThread {
            return try work()
        }
        // See `sync(_:)`'s identical call for why the thread must already
        // be running before any cross-thread hand-off is attempted.
        start()
        // Result is carried across the thread boundary as a value: `throws`
        // cannot cross the closure hand-off directly.
        var outcome: Result<T, Error>!
        withoutActuallyEscaping(work) { escapableWork in
            let done = NSCondition()
            var finished = false
            // See `sync(_:)`'s identical `slot` indirection and its long
            // comment for why nilling this reference is the posted
            // closure's own last act BEFORE signaling `done` -- the fix for
            // an empirically observed, nondeterministic
            // `swift_isEscapingClosureAtFileLocation` trap under real
            // cross-thread execution.
            var slot: (() throws -> T)? = escapableWork
            async {
                let value = Result(catching: { try slot!() })
                slot = nil
                done.lock()
                outcome = value
                finished = true
                done.signal()
                done.unlock()
            }
            done.lock()
            while !finished {
                done.wait()
            }
            done.unlock()
        }
        // `try!`-free rethrow: `get()` throws exactly the error `work` threw,
        // and `rethrows` permits that because the only error source is `work`.
        return try outcome.get()
    }
}
#endif
