import Foundation
import AppKit

// MARK: - Cross-process broadcast names
//
// These names are global to the entire login session -- ANY process on the
// session can post or observe them -- so they are namespaced reverse-DNS off
// the app's bundle identifier to avoid colliding with unrelated software.
// Do not shorten them to bare words like "clearAll".
//
// SECURITY MODEL -- a deliberate choice, not an oversight. Distributed
// notifications are an UNAUTHENTICATED, session-global control channel: there
// is no sender identity, no entitlement check and no way to restrict who may
// post. Any process running as this user in this login session can therefore
// post these two names and make every AI Chalkboard instance wipe its
// annotations or quit. That is accepted here because the blast radius is
// exactly "a local drawing overlay stops drawing" -- no data is destroyed
// beyond transient on-screen annotations, no privilege is granted, nothing is
// read back out of the app -- and because any process able to post this could
// equally just `kill` these PIDs. Do NOT extend this channel to carry
// anything with a larger blast radius (file paths, shell arguments, anything
// that mutates disk); that would need a real authenticated transport (e.g. a
// sandbox-scoped XPC service with a code-signing requirement on the peer).
extension Notification.Name {
    /// "Every AI Chalkboard process: wipe your AnnotationStore and repaint."
    ///
    /// Carries a `userInfo` payload since per-app scoping was added -- see
    /// `postClear(scope:appId:appName:)`. The NAME is unchanged on purpose: it
    /// is the verified-working channel, and a payload-less post from an older
    /// build still means exactly what it always meant (clear everything).
    static let chalkboardClearAll = Notification.Name("com.aichalkboard.overlay.clearAllAnnotations")

    /// "Every AI Chalkboard process: terminate yourself."
    static let chalkboardQuitAll = Notification.Name("com.aichalkboard.overlay.quitAllInstances")

    /// "Every AI Chalkboard process: set your overlay windows' sharingType."
    ///
    /// Needs the same fan-out as clear, and for the same reason: EVERY instance
    /// creates its own per-screen overlay windows, so a capture-debug request
    /// applied in one process would leave the other process using a different
    /// sharing preference and render filter. Half-applied would make placement
    /// checks show an arbitrary subset on capture paths that include overlays.
    static let chalkboardSetCaptureVisible = Notification.Name("com.aichalkboard.overlay.setCaptureVisible")
}

/// The QUIT broadcast's `object`, used only to scope Dock/Cmd-Q quits to
/// instances launched the same way as the poster.
///
/// WHY THE QUIT IS SCOPED AND THE CLEAR IS NOT:
///
/// A user can have both kinds of instance alive at once: Claude Desktop's two
/// `--mcp` servers, and a copy they double-clicked in Finder (which is
/// `.regular`, has a Dock icon and a Cmd-Q). Before scoping, pressing Cmd-Q in
/// that hand-launched window posted an unscoped quit and killed BOTH MCP
/// servers mid-session. The user closed a window they opened by hand; they did
/// not ask to terminate the agent's servers. Conversely, quitting from an MCP
/// instance's status menu is an explicit "Quit AI Chalkboard" command, so it
/// intentionally reaches every coexisting instance. The status menu is the
/// cross-mode control surface; only Dock/Cmd-Q is scoped to its launch mode.
///
/// CLEAR stays unscoped deliberately: clearing across modes is harmless (it
/// destroys only transient on-screen drawings) and desirable (whichever
/// instance drew it, the user wants it gone).
private enum QuitScope {
    /// This process's own mode, and the value it posts.
    static var current: String { LaunchMode.isMCPMode ? "mcp" : "gui" }
}

/// `userInfo` keys for the broadcasts above.
///
/// DistributedNotificationCenter requires `userInfo` to be property-list
/// serializable -- it is encoded and shipped through the `distnoted` daemon to
/// other processes, so arbitrary objects (and even NSNumber in some macOS
/// versions) are unreliable. Everything here is therefore a plain `String`,
/// including the boolean, which travels as "true"/"false".
private enum BroadcastKey {
    static let scope = "scope"
    static let appId = "appId"
    static let appName = "appName"
    static let visible = "visible"
}

/// Canonical encoding and application of a clear broadcast. Keeping payload
/// parsing here makes the sender and every receiver share one definition and
/// lets tests simulate multiple process-local stores without touching the
/// session-global DistributedNotificationCenter.
struct ClearBroadcastRequest {
    let scope: ClearScope
    let appId: String?
    let appName: String?

    init(scope: ClearScope, appId: String?, appName: String?) {
        self.scope = scope
        self.appId = appId
        self.appName = appName
    }

    init(notification: Notification) {
        let rawScope = notification.userInfo?[BroadcastKey.scope] as? String
        // Legacy/malformed payloads meant "clear all" before scopes existed;
        // preserve that fail-safe compatibility contract.
        scope = ClearScope(rawValue: rawScope ?? "") ?? .all
        appId = notification.userInfo?[BroadcastKey.appId] as? String
        appName = notification.userInfo?[BroadcastKey.appName] as? String
    }

    var userInfo: [String: String] {
        var result = [BroadcastKey.scope: scope.rawValue]
        if let appId { result[BroadcastKey.appId] = appId }
        if let appName { result[BroadcastKey.appName] = appName }
        return result
    }

    @discardableResult
    func apply(to store: AnnotationStore) -> Int {
        switch scope {
        case .all:
            return store.clearAll()
        case .active:
            return store.clearVisible(forApp: appId)
        }
    }
}

/// Cross-process fan-out for the two menu-bar actions ("Clear All Annotations"
/// and "Quit AI Chalkboard").
///
/// WHY THIS EXISTS -- read before simplifying any of it away:
///
/// 1. Claude Desktop spawns **two** `AIChalkboard --mcp` processes for a single
///    MCP server config entry (verified live: two PIDs, both completing the MCP
///    handshake, both serving tools). Neither may exit -- Claude Desktop talks
///    to each over its own stdin/stdout pipe, so an early exit looks like a
///    dropped server connection. See InstanceLock's doc comment.
///
/// 2. `AnnotationStore.shared` is a **per-process** singleton. Each process
///    holds and renders only the annotations that arrived over *its own* MCP
///    pipe. There is no shared store, no shared database, no IPC between them.
///
/// 3. The status-bar item is an OS-level singleton and is therefore installed
///    only by the **primary** instance (the one that wins
///    `InstanceLock.shared.acquire()`). The secondary has no menu-bar item,
///    and in MCP mode it also has no Dock icon (`.accessory` activation policy)
///    and, since the floating Clear/Quit window was removed, no window either.
///
/// Put those three together and a purely local menu action is broken in two
/// ways:
///
///   (a) The primary's "Clear All Annotations" would clear only the primary's
///       store, leaving every annotation the SECONDARY process drew stuck on
///       screen with no way to remove it.
///   (b) The primary's "Quit" would terminate only the primary, leaving the
///       secondary alive with no Dock icon, no menu-bar item and no window --
///       an invisible, unquittable process still painting on the user's screen.
///
/// So both menu actions must reach *every* instance. `DistributedNotification-
/// Center` does that: it fans a notification out through the session's
/// `distnoted` daemon to all observing processes in the same login session
/// (both instances are children of Claude Desktop in the Aqua session).
/// Measured delivery latency between these processes is ~1.4-2.6 ms, on the
/// main thread, and works while the app is non-frontmost and never activated.
///
/// STDOUT SAFETY: this process is an MCP stdio server speaking JSON-RPC over
/// stdout. `DistributedNotificationCenter` communicates over Mach/XPC and never
/// touches fd 1, and every diagnostic below goes through `Logger.shared.log`
/// (stderr + rotating file). Never add a Swift `print` call to this file -- it
/// writes to stdout and would corrupt the JSON-RPC stream.
public final class InstanceBroadcast: NSObject {
    public static let shared = InstanceBroadcast()

    // THREADING: every stored property below is main-thread-only. Callers are
    // `registerObservers()` (from applicationDidFinishLaunching), the posters
    // (menu actions / applicationShouldTerminate) and the receive handlers,
    // which hop to main before touching anything. Keep it that way rather than
    // adding a lock -- the state exists purely to coordinate with AppKit,
    // which is main-thread-only anyway.

    /// Guards against double registration (which would make every handler run
    /// twice per broadcast). `registerObservers()` is only called once today,
    /// but this makes it safe to call defensively.
    private var isRegistered = false

    /// Set by the quit handler so the poster-side watchdog below can tell
    /// "the broadcast came back to me and I'm already terminating" from
    /// "nothing ever came back".
    private var isQuitting = false

    override private init() {
        super.init()
    }

    // MARK: - Registration

    /// Registers this process as a receiver of both broadcasts.
    ///
    /// MUST be called by EVERY instance -- primary and secondary alike -- and
    /// therefore must NEVER be gated on `InstanceLock.shared.acquire()`. Gating
    /// it would re-create exactly the bug this class exists to fix: the
    /// secondary would stop receiving clears and quits, i.e. it would again be
    /// unclearable and unquittable. Only the *posting* side (the menu action)
    /// is primary-only, because only the primary has a menu.
    ///
    /// Call this from `applicationDidFinishLaunching`, BEFORE
    /// `MCPServer.shared.start()`: distributed notifications are not persisted
    /// or replayed, so anything posted before an observer registers is simply
    /// lost. Registering as early as possible shrinks that startup race to
    /// nothing that matters (both actions are idempotent anyway).
    public func registerObservers() {
        guard !isRegistered else { return }
        isRegistered = true

        let center = DistributedNotificationCenter.default()

        // `object:` on DistributedNotificationCenter is a `String?` matched by
        // string equality -- it is NOT an object identity like the local
        // NotificationCenter. `nil` on both the observe and post side means
        // "wildcard: match everything", which is what we want. Passing a
        // non-String object here does not work.
        //
        // `.deliverImmediately` opts out of coalescing and of delivery being
        // deferred while the app is in the background. Neither actually bit in
        // testing (even a SIGSTOP'd process received everything once resumed),
        // but it costs nothing and removes the question entirely.
        center.addObserver(
            self,
            selector: #selector(handleClearAllBroadcast(_:)),
            name: .chalkboardClearAll,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // OBSERVE THE QUIT WITH `object: nil` (wildcard) EVEN THOUGH IT IS NOW
        // SCOPED. `DistributedNotificationCenter` matches `object` by exact
        // String equality with no wildcard on the OBSERVER side beyond nil, so
        // registering `object: QuitScope.current` here would silently drop a
        // legacy payload-less post (`object: nil`) from an older build. Observe
        // everything and filter inside `handleQuitAllBroadcast`, where the
        // decision can be logged.
        center.addObserver(
            self,
            selector: #selector(handleQuitAllBroadcast(_:)),
            name: .chalkboardQuitAll,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(handleSetCaptureVisibleBroadcast(_:)),
            name: .chalkboardSetCaptureVisible,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // No matching removeObserver: `self` is a process-lifetime singleton,
        // so the registration is meant to live as long as the process. (The
        // selector-based distributed API does not zero out on dealloc, so
        // registering a short-lived object here would be a dangling-observer
        // hazard -- another reason this lives on a singleton.)
        //
        // Delivery requires a running main run loop. That is satisfied here:
        // `app.run()` in the launcher entry point runs it, and MCPServer reads stdin on a
        // background queue (`DispatchQueue.global()`), so the main run loop is
        // never blocked by the protocol read. A process that registered and
        // then blocked the main thread without running a run loop would
        // receive nothing at all.
        Logger.shared.log("InstanceBroadcast: registered cross-process observers for '\(Notification.Name.chalkboardClearAll.rawValue)' and '\(Notification.Name.chalkboardQuitAll.rawValue)'.", level: "INFO")
    }

    // MARK: - Posting (menu-bar side, primary instance only)

    // IMPORTANT -- WHY THE POSTERS DO NO LOCAL WORK:
    //
    // DistributedNotificationCenter delivers a notification back to the POSTING
    // process's own observers as well. That is not optional and cannot be
    // disabled. So the posting process is just another receiver, and the
    // correct shape is: the menu action posts and does NOTHING else; all the
    // real work lives in the handler, which every instance (including the
    // poster) runs exactly once. Adding a local `AnnotationStore.shared
    // .clearAll()` / `NSApp.terminate(nil)` next to the post would double-handle
    // the action in the posting process.
    //
    // There is no notification loop, because handlers never re-post.
    //
    // Self-delivery is ASYNCHRONOUS, not re-entrant: `postNotificationName`
    // returns first and the local observer fires ~2 ms later on the next main
    // run loop turn.

    /// Posts a clear to every instance, including this one.
    ///
    /// THE SCOPE MUST TRAVEL IN THE PAYLOAD. Each instance owns a separate
    /// `AnnotationStore`, so each receiver has to run the clear against its own
    /// annotations -- but "which app is active" must be decided ONCE, by the
    /// poster, and shipped along. If every receiver instead re-queried
    /// `NSWorkspace` for itself, two processes handling the same broadcast a few
    /// milliseconds apart could straddle an app switch and clear two different
    /// apps' annotations from one menu click.
    ///
    /// `appId` is the app whose annotations (plus the global ones) `.active`
    /// should remove; `appName` rides along purely so the receiver's log line is
    /// readable. Both are omitted for `.all`.
    public func postClear(scope: ClearScope, appId: String?, appName: String?) {
        let request = ClearBroadcastRequest(scope: scope, appId: appId, appName: appName)

        Logger.shared.log("InstanceBroadcast: posting CLEAR broadcast (scope=\(scope.rawValue), app=\(appName ?? appId ?? "n/a")) to all AI Chalkboard instances.", level: "INFO")
        DistributedNotificationCenter.default().postNotificationName(
            .chalkboardClearAll,
            object: nil,
            userInfo: request.userInfo,
            deliverImmediately: true
        )
    }

    /// Posts "clear everything, every app" to every instance, including this
    /// one. Retained as the name for the unscoped case.
    public func postClearAll() {
        postClear(scope: .all, appId: nil, appName: nil)
    }

    /// Posts a capture-visibility change to every instance, including this one.
    ///
    /// Like the clear posters, this does NO local work: the notification comes
    /// back to this process too and the handler applies it here as well.
    public func postSetCaptureVisible(_ visible: Bool) {
        Logger.shared.log("InstanceBroadcast: posting SET-CAPTURE-VISIBLE broadcast (visible=\(visible)) to all AI Chalkboard instances.", level: "INFO")
        DistributedNotificationCenter.default().postNotificationName(
            .chalkboardSetCaptureVisible,
            object: nil,
            userInfo: [BroadcastKey.visible: visible ? "true" : "false"],
            deliverImmediately: true
        )
    }

    /// Posts "quit" to every instance, including this one.
    ///
    /// The status-menu item uses the unscoped default, because its explicit
    /// "Quit AI Chalkboard" wording means all coexisting instances. Dock and
    /// Cmd-Q pass `scopedToLaunchMode: true`, so a hand-launched GUI copy does
    /// not terminate Claude Desktop's MCP servers. Lifecycle shutdowns (stdin
    /// EOF, signals, obeying someone else's quit broadcast) must NOT call this.
    public func postQuitAll(scopedToLaunchMode: Bool = false) {
        let scope = scopedToLaunchMode ? QuitScope.current : nil
        Logger.shared.log("InstanceBroadcast: posting QUIT broadcast (scope=\(scope ?? "<all instances>")) to \(scopedToLaunchMode ? "AI Chalkboard instances launched in the same mode" : "all coexisting AI Chalkboard instances") (user-initiated quit).", level: "INFO")

        // `object:` carries the launch mode only for Dock/Cmd-Q. A nil object
        // is deliberately an all-instance status-menu quit.
        DistributedNotificationCenter.default().postNotificationName(
            .chalkboardQuitAll,
            object: scope,
            userInfo: nil,
            deliverImmediately: true
        )

        // Watchdog, quit only -- LETHAL, and that is a REVERSAL of the previous
        // "deliberately non-lethal" design. This comment supersedes it.
        //
        // It fires when the self-delivered notification never came back after
        // 1s. The old reasoning was: "if I didn't receive it, nobody did, so
        // terminating here would kill the only process with a menu and strand
        // an invisible sibling". Two things are wrong with that:
        //
        //   * "If I didn't receive it, nobody did" is an assumption, not a
        //     guarantee. `distnoted` can deliver to the sibling while this
        //     process's own copy is lost or delayed. In that case the siblings
        //     die, this process does not, and the ONLY trace is a WARN line in
        //     a log file the user will never open -- from their seat, the Quit
        //     menu item silently did nothing.
        //   * Stranding is no longer possible ANYWAY, which is what makes
        //     terminating safe now: primary re-election exists
        //     (`InstanceLock.retryAcquire()` polled from AppDelegate every 3s).
        //     Either the sibling received the broadcast and is already dying,
        //     or it did not and it promotes itself to primary within ~3s and
        //     installs its own status-bar menu. Neither branch leaves an
        //     invisible, unquittable process behind.
        //
        // So: honour the user's Quit locally. A quit that visibly quits, with a
        // possible sibling that self-heals into a usable primary, beats a quit
        // that appears to be ignored.
        //
        // In the normal case the self-delivered notification arrives in ~2 ms,
        // `isQuitting` is already true, and this closure does nothing -- so
        // this path costs nothing when delivery is healthy, and the 1s delay is
        // generous enough that a merely-slow delivery still wins the race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, !self.isQuitting else { return }
            self.isQuitting = true
            Logger.shared.log("InstanceBroadcast: QUIT broadcast could not be confirmed after 1s -- this process never received its own notification back, so distributed notification delivery may be degraded. Terminating THIS process anyway so the user's Quit is not silently ignored; any sibling that missed the broadcast re-elects itself primary within a few seconds (InstanceLock.retryAcquire) and gets its own status-bar menu, so nothing is stranded.", level: "WARN")

            // Already on the main thread (asyncAfter on .main), which is where
            // both of these must be called.
            AppDelegate.markInternalTermination(reason: "quit broadcast unconfirmed; terminating locally")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Receiving (every instance: primary AND secondary)

    @objc private func handleClearAllBroadcast(_ notification: Notification) {
        let request = ClearBroadcastRequest(notification: notification)

        // Safe from any thread: AnnotationStore's mutations are NSLock-guarded
        // and its change notification hops to the main queue itself. (In
        // practice distributed notifications are delivered on the main thread.)
        switch request.scope {
        case .all:
            let removed = request.apply(to: AnnotationStore.shared)
            Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=CLEAR scope=all. Removed \(removed) annotation(s) from this process's store and repainting its overlays.", level: "INFO")

        case .active:
            // The poster resolved the target app; this process must NOT
            // re-derive it (see postClear's doc comment). A missing appId means
            // the poster could not determine a frontmost app, in which case
            // only the global annotations are removed.
            let removed = request.apply(to: AnnotationStore.shared)
            Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=CLEAR scope=active app=\(request.appName ?? request.appId ?? "<none: global annotations only>"). Removed \(removed) annotation(s) from this process's store; annotations linked to other apps were left untouched.", level: "INFO")
        }

        // `clearAll()` already triggers `onStoreChanged` -> `refreshViews()`.
        // This explicit repaint is belt-and-braces for the startup window in
        // which `OverlayWindowController.setup()`'s async block has not yet
        // assigned that closure. `refreshViews()` only sets `needsDisplay`, so
        // running it twice is free.
        OverlayWindowController.shared.refreshViews()
    }

    @objc private func handleSetCaptureVisibleBroadcast(_ notification: Notification) {
        // Anything that is not the literal string "true" is treated as false,
        // so a malformed payload fails CLOSED -- back to `.none`, the private
        // default -- rather than accidentally exposing the overlay to screen
        // recording.
        let visible = (notification.userInfo?[BroadcastKey.visible] as? String) == "true"

        Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=SET-CAPTURE-VISIBLE visible=\(visible). Applying to this process's overlay windows.", level: "INFO")

        // `setCaptureVisible` is thread-safe (NSLock around the flag, main-queue
        // hop for the window mutation) and no-ops when the value is unchanged,
        // which is what makes the self-delivered copy of this notification free.
        OverlayWindowController.shared.setCaptureVisible(visible)
    }

    @objc private func handleQuitAllBroadcast(_ notification: Notification) {
        // The ENTIRE body runs on the main thread -- nothing outside this hop.
        //
        // `isQuitting` is read by the poster-side watchdog on main. Writing it
        // here on whatever thread `distnoted` happened to deliver on, and only
        // then hopping to main, gave the two accesses no happens-before edge:
        // a data race by the letter of the memory model, and inconsistent with
        // this method's own defensive "am I on the main thread?" check --
        // which is itself an admission that delivery might not be on main.
        // (Measured delivery is on main today, so it never bit in practice.)
        // Hopping first makes every access to this class's state main-only.

        // Read the sender's launch mode BEFORE the hop, so the closure captures
        // one small value rather than the whole notification.
        let senderScope = notification.object as? String

        onMain { [weak self] in
            guard let self = self else { return }

            // A non-nil scope is a Dock/Cmd-Q quit, which reaches only the
            // same launch mode. A nil scope is the status-menu's deliberate
            // all-instance quit (and is also compatible with older builds).
            //
            let ownScope = QuitScope.current
            if let senderScope = senderScope, senderScope != ownScope {
                Logger.shared.log("InstanceBroadcast: IGNORING scoped QUIT broadcast from a '\(senderScope)' instance -- this process is '\(ownScope)'. Dock/Cmd-Q does not cross launch modes.", level: "INFO")
                return
            }

            Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=QUIT (scope=\(senderScope ?? "<legacy: unscoped>"), this process=\(ownScope)). Terminating this process.", level: "INFO")
            self.isQuitting = true

            // Obeying someone else's quit is a LIFECYCLE shutdown, not a user
            // quit: whoever posted this already fanned it out to every
            // instance. Without this marker, applicationShouldTerminate would
            // treat it as user-initiated and post a SECOND quit broadcast --
            // a needless echo between instances.
            AppDelegate.markInternalTermination(reason: "received QUIT broadcast from another instance (or from this process's own menu)")

            // Route through NSApp.terminate rather than exit(): it runs the
            // normal AppKit shutdown, which includes applicationWillTerminate
            // and its shutdown log line. Must happen on the main thread.
            NSApp.terminate(nil)
        }
    }

    /// Runs `work` on the main thread, synchronously if already there.
    ///
    /// Kept as a plain re-entrancy-safe helper rather than
    /// `DispatchQueue.main.async` unconditionally: when delivery already is on
    /// main (the measured behaviour), the handler stays synchronous, so the
    /// quit is not deferred by a run-loop turn.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
