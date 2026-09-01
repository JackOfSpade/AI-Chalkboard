import Foundation

/// A handle returned by `AppHostUI.scheduleRepeatingCallback(interval:_:)`,
/// cancellable exactly once. macOS wraps `Timer.invalidate()`; Windows wraps
/// `KillTimer` -- see each platform's `AppDelegate` conformance to
/// `AppHostUI` in AppDelegate.swift.
public protocol CancellableTimer: AnyObject {
    func cancel()
}

/// The platform surface `AppLifecycleCoordinator` is built on: install/remove
/// this process's primary-only UI (the status-bar item on macOS, the tray
/// icon on Windows) and schedule a repeating callback on this platform's UI
/// thread. Nothing else -- WHEN to install/remove that UI, WHEN and how often
/// to poll, what a poll actually checks, or the internal-vs-user termination
/// distinction -- belongs in a conformance to this protocol; all of that is
/// shared policy living on `AppLifecycleCoordinator` below.
///
/// This mirrors the split `AnnotationRenderer`/`DrawingContext` already use
/// for the drawing side of this app, and `OverlayPresentationBackend` for the
/// window-presentation side (see Sources/Overlay/): a Foundation-only policy
/// object written once, against a small protocol, with exactly one real
/// conformance per platform.
public protocol AppHostUI: AnyObject {
    /// Schedules `callback` to run every `interval` seconds on this
    /// platform's UI/main thread, until the returned handle is cancelled.
    /// macOS: `Timer` on `RunLoop.main` in `.common` modes (keeps firing
    /// while a menu is tracking or a window is being live-resized). Windows:
    /// `SetTimer`/`WM_TIMER` on the Win32 UI thread.
    func scheduleRepeatingCallback(interval: TimeInterval, _ callback: @escaping () -> Void) -> CancellableTimer

    /// Installs this process's primary-only UI surface -- the status-bar
    /// item on macOS, the tray icon on Windows. Called exactly once per
    /// "primary episode" from `AppLifecycleCoordinator.becamePrimary()`:
    /// both the t=0 election win and a later promotion via the retry poll
    /// funnel through that one method, so this and the lock watchdog can
    /// never drift apart -- see that method's doc comment.
    func installPrimaryUI()

    /// Removes this process's primary-only UI surface. Called only from
    /// `AppLifecycleCoordinator`'s lock watchdog, when
    /// `InstanceLock.revalidatePrimaryLock()` reports another process now
    /// owns the repaired lock.
    func removePrimaryUI()
}

/// Platform-neutral home for `AppDelegate`'s entire lifecycle policy: the
/// primary-election retry poll, the primary-lock watchdog (including
/// demotion when another process owns the repaired lock), the
/// suspension-lease reconcile tick, and the internal-vs-user termination
/// distinction that decides whether a quit must be broadcast to sibling
/// instances.
///
/// This is a LITERAL extraction of what used to be the macOS `AppDelegate`
/// class's own implementation of all of the above (reasoning and comments
/// included). macOS is the battle-tested reference this state machine was
/// extracted from; every method below reproduces its exact behavior, timing
/// and ordering guarantees. Nothing here imports AppKit, Darwin, or WinSDK --
/// every platform-specific line lives behind `AppHostUI`, in each platform's
/// `AppDelegate` conformance in AppDelegate.swift.
///
/// THREADING: every method here must be called on -- and every timer
/// callback it schedules fires on -- this platform's UI/main thread (the
/// AppKit main thread on macOS, the Win32 message-pump thread on Windows).
/// `isInternalTermination` is deliberately unsynchronized on that basis, just
/// as it was on the pre-hoist macOS class; see that property's doc comment.
public final class AppLifecycleCoordinator {
    /// Not retained strongly: the host (a platform `AppDelegate`) owns this
    /// coordinator, so a strong back-reference would be a retain cycle.
    private weak var host: AppHostUI?

    /// How often a secondary re-tests whether the primary slot has come
    /// free, and (reused, see `startPrimaryLockWatchdog()`) how often the
    /// primary re-tests whether it still holds a path-visible lock. Cheap
    /// (one `open`/`CreateFile` + one non-blocking lock attempt + one
    /// close) and the contention case is not logged, so a few seconds is a
    /// good trade between "the user notices the primary UI is gone" and
    /// pointless wakeups.
    public static let primaryElectionRetryInterval: TimeInterval = 3.0

    /// Reconciles the durable suspension lease registry often enough that an
    /// abandoned short lease restores retained annotations promptly. The
    /// registry uses monotonic uptime; this timer is merely a wake-up, never
    /// a clock source.
    public static let suspensionLeaseReconcileInterval: TimeInterval = 0.5

    /// Re-election poll, installed ONLY in a process that lost the initial
    /// `InstanceLock` election. Invalidated the moment this process is
    /// promoted to primary. See `startPrimaryElectionRetry()`.
    private var primaryElectionTimer: CancellableTimer?

    /// Lock-integrity poll, installed ONLY in the process that owns the
    /// primary UI. The mirror image of `primaryElectionTimer`: that one asks
    /// "has the primary slot come free?", this one asks "do I still hold
    /// it?". See `startPrimaryLockWatchdog()`. NEVER invalidated once
    /// started -- unlike the election poll it has no terminal state, and the
    /// invariant it maintains has to hold for as long as this process is
    /// primary.
    private var primaryLockWatchdog: CancellableTimer?

    /// See `startSuspensionLeaseReconciliation()`.
    private var suspensionLeaseReconcileTimer: CancellableTimer?

    /// True once a shutdown that is NOT a user asking this app to quit has
    /// begun -- i.e. a lifecycle shutdown: the QUIT broadcast handler (a
    /// sibling already told everyone to quit), MCP stdin EOF (this
    /// process's own client hung up), or a POSIX signal / console-control
    /// event aimed at this process. `evaluateTermination()` reads it to
    /// decide whether a termination must fan a quit out to sibling
    /// instances; see that method and `markInternalTermination(reason:)`.
    ///
    /// Unsynchronized on purpose: every reader and writer runs on this
    /// platform's UI/main thread (AppKit termination is main-thread-only on
    /// macOS; every Windows path already hops to the UI thread before
    /// reaching a call into this coordinator -- see each platform's
    /// `AppDelegate` for how).
    private var isInternalTermination = false

    public init(host: AppHostUI) {
        self.host = host
    }

    // MARK: - Suspension-lease reconciliation

    public func startSuspensionLeaseReconciliation() {
        guard suspensionLeaseReconcileTimer == nil, let host else { return }
        suspensionLeaseReconcileTimer = host.scheduleRepeatingCallback(interval: Self.suspensionLeaseReconcileInterval) {
            _ = SuspensionLeaseCoordinator.shared.reconcile()
        }
    }

    // MARK: - Primary election / promotion

    /// Called from BOTH paths into the primary role -- winning the t=0
    /// election in `applicationDidFinishLaunching`/`launch()`, and being
    /// promoted later by the retry poll -- so that "owns the primary UI"
    /// and "runs the lock-integrity watchdog" can never drift apart. Both
    /// halves are idempotent: the watchdog only ever starts once (see its
    /// own guard), and each host's `installPrimaryUI()` is written to be
    /// safe to call more than once, matching the pre-hoist per-platform
    /// behavior.
    public func becamePrimary() {
        startPrimaryLockWatchdog()
        host?.installPrimaryUI()
    }

    /// Polls `InstanceLock.retryAcquire()` until this process wins the
    /// primary slot, then installs the primary UI.
    ///
    /// WHY: without this a secondary is stranded the moment the primary dies
    /// by any path other than a user quit (crash, `kill`, Claude Desktop
    /// closing only that one pipe). The kernel releases the dead primary's
    /// lock, but nothing here ever re-tested it, so the survivor kept its
    /// t=0 answer forever and was left with NO control surface at all: no
    /// Dock icon in MCP mode on macOS, no window on either platform (the
    /// floating Clear/Quit window was removed as redundant with the
    /// menu/tray). Its `AnnotationStore` meanwhile may still be full, so the
    /// user is left staring at stale annotations on every screen with no way
    /// to clear them and no way to quit the invisible process painting them.
    public func startPrimaryElectionRetry() {
        guard let host else { return }
        primaryElectionTimer = host.scheduleRepeatingCallback(interval: Self.primaryElectionRetryInterval) { [weak self] in
            self?.primaryElectionTick()
        }
        Logger.shared.log("Secondary instance: polling every \(Self.primaryElectionRetryInterval)s to take over as primary if the current primary dies (otherwise this process would be left with no primary UI surface and no window).", level: "INFO")
    }

    private func primaryElectionTick() {
        // retryAcquire() (unlike acquire()) does not consult the cached
        // t=0 answer, and on success it keeps the lock descriptor open for
        // the rest of this process's life -- exactly like an
        // originally-primary instance.
        guard InstanceLock.shared.retryAcquire() else { return }

        primaryElectionTimer?.cancel()
        primaryElectionTimer = nil

        Logger.shared.log("Promoted to PRIMARY instance: the previous primary released the instance lock (it exited, crashed or was killed). Installing the primary UI so this process regains a user-facing way to clear annotations and quit.", level: "INFO")
        becamePrimary()
    }

    /// Polls `InstanceLock.revalidatePrimaryLock()` in whichever process owns
    /// the primary UI, so a lock file that gets deleted underneath a LIVE
    /// primary is recreated within one tick.
    ///
    /// WHY THE PRIMARY NEEDS ITS OWN POLL: `flock`/the Windows lock lives on
    /// an open file description/handle, not on a path. If `instance.lock` is
    /// deleted -- an uninstaller, "clear app data", a user cleaning out
    /// application data -- this process keeps a valid lock on a file with no
    /// name any more, and nothing on disk connects it to the lock path any
    /// more. A secondary polling that path cannot see this process at all:
    /// it is looking at a file that no longer exists. Only the process that
    /// owns the lock can restore that link, which is why the repair cannot
    /// live in `retryAcquire()` on the secondary side.
    ///
    /// Runs at the same interval as the election retry and costs two
    /// identity lookups a tick, doing real work only on mismatch. It is
    /// never invalidated: unlike the election poll it has no terminal
    /// state -- the invariant it maintains has to hold for as long as this
    /// process is primary.
    private func startPrimaryLockWatchdog() {
        guard primaryLockWatchdog == nil, let host else { return }
        primaryLockWatchdog = host.scheduleRepeatingCallback(interval: Self.primaryElectionRetryInterval) { [weak self] in
            self?.primaryLockWatchdogTick()
        }
    }

    private func primaryLockWatchdogTick() {
        guard InstanceLock.shared.revalidatePrimaryLock() == .relinquishToPathOwner else { return }

        // Another process repaired and locked the path before this orphaned
        // primary could. It now owns the only trustworthy election result;
        // remove our UI rather than leave two permanent primary UI surfaces.
        primaryLockWatchdog?.cancel()
        primaryLockWatchdog = nil
        host?.removePrimaryUI()
        Logger.shared.log("Demoted from PRIMARY instance: another process owns the repaired instance lock. Removed this process's primary UI and resumed secondary election polling.", level: "WARN")
        startPrimaryElectionRetry()
    }

    // MARK: - Termination

    /// Marks the shutdown now beginning as INTERNAL / lifecycle-driven, so
    /// `evaluateTermination()` does not treat it as "the user asked to quit
    /// the app" and does not report that a QUIT broadcast is owed to
    /// siblings.
    ///
    /// Call immediately before actually terminating, from every path that is
    /// NOT a user quit:
    ///   * the QUIT-broadcast handler (a sibling already told everyone),
    ///   * MCP stdin EOF (only THIS process's client pipe closed),
    ///   * a POSIX signal (macOS) or console-control event (Windows) aimed
    ///     at this process.
    ///
    /// UI-thread only -- every caller already hops there before reaching
    /// this, and the flag it sets is unsynchronized (see its doc comment).
    public func markInternalTermination(reason: String) {
        isInternalTermination = true
        Logger.shared.log("Internal termination path: \(reason). This process will terminate WITHOUT broadcasting quit to sibling instances.", level: "INFO")
    }

    /// The single choke point every user-facing termination path (Dock/Cmd-Q
    /// on macOS, the tray menu's "Quit" reaching Windows's termination entry
    /// point with no internal flag set) must pass through before actually
    /// terminating. Returns whether THIS call is the one that must broadcast
    /// QUIT to sibling instances.
    ///
    /// A USER-initiated quit must take the sibling instance with it. Claude
    /// Desktop spawns two `AIChalkboard --mcp` processes per config entry and
    /// only one of them owns the primary UI, so quitting just this one would
    /// leave an invisible orphan still painting annotations -- exactly the
    /// split brain `InstanceBroadcast` exists to prevent.
    ///
    /// An INTERNAL quit must NOT broadcast: a closed MCP pipe, a signal
    /// aimed at this process, or a broadcast already being obeyed all
    /// concern this process alone (or have already been fanned out by
    /// whoever posted them).
    ///
    /// Sets `isInternalTermination` before returning `true`, so a broadcast
    /// sent as a result of this call cannot loop back into a second call
    /// that also thinks it must broadcast.
    public func evaluateTermination() -> Bool {
        if isInternalTermination {
            return false
        }
        isInternalTermination = true
        return true
    }
}
