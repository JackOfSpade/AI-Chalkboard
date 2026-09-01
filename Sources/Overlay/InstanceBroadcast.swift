import Foundation
#if os(macOS)
import AppKit
#elseif os(Windows)
import WinSDK
#endif

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

    /// A wake-up hint that durable suspension state changed. It carries no
    /// command: a receiver always re-reads the protected lease registry.
    static var chalkboardSuspensionInvalidated: Notification.Name {
        struct Name {
            static let value: Notification.Name = {
                let suffix = ProcessInfo.processInfo.environment["AI_CHALKBOARD_SUSPENSION_NAMESPACE"]
                    .map { "." + $0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.map(String.init).joined() } ?? ""
                return Notification.Name("com.aichalkboard.overlay.suspensionLeaseInvalidated.v2\(suffix)")
            }()
        }
        return Name.value
    }
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
    static let generation = "generation"
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

#if os(macOS)
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
        center.addObserver(
            self,
            selector: #selector(handleSuspensionInvalidatedBroadcast(_:)),
            name: .chalkboardSuspensionInvalidated,
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
        Logger.shared.log("InstanceBroadcast: registered cross-process observers for clear, quit, capture visibility, and durable suspension-lease invalidation. Suspension notifications are wake-up hints only; canonical state is read from the lease registry.", level: "INFO")
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

    /// Broadcasts only a durable-state wake-up hint. It deliberately contains
    /// no requested presentation state and needs no ACK transport.
    public func postSuspensionInvalidation(generation: UInt64) {
        DistributedNotificationCenter.default().postNotificationName(
            .chalkboardSuspensionInvalidated,
            object: nil,
            userInfo: [BroadcastKey.generation: String(generation)],
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

    @objc private func handleSuspensionInvalidatedBroadcast(_ notification: Notification) {
        let generation = (notification.userInfo?[BroadcastKey.generation] as? String).flatMap(UInt64.init)
        // A malformed or hostile hint is harmless: reconcile reads canonical
        // state and never executes a desired state supplied by DNC.
        _ = SuspensionLeaseCoordinator.shared.reconcile(announcedGeneration: generation)
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

        // `MainThread.async` runs this inline when delivery is already on main
        // (the measured behaviour), so the quit is not deferred by a run-loop
        // turn -- the same synchronous-when-already-there semantics the old
        // local `onMain(_:)` helper had.
        MainThread.async { [weak self] in
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
}

#elseif os(Windows)

// MARK: - Windows wire payload

/// The Windows transport (message-only-window `WM_COPYDATA`, see
/// `InstanceBroadcast` below) has no built-in notion of a named channel with
/// a typed `userInfo` dictionary the way `DistributedNotificationCenter`
/// does, so every broadcast this process sends or receives is one JSON
/// object of this shape. JSON, not a packed binary struct, on purpose: an
/// unrecognized/missing field decodes to `nil` rather than a hard failure,
/// which is the same forward/backward tolerance
/// `ClearBroadcastRequest.init(notification:)` already relies on for a
/// legacy or malformed payload on macOS (see its "Legacy/malformed payloads
/// meant 'clear all'" comment above) -- a future build that adds a field
/// must not become undecodable by an older sibling still running the
/// previous build, and vice versa.
private struct WindowsBroadcastEnvelope: Codable {
    enum Kind: String, Codable {
        case clear, quit, setCaptureVisible, suspensionInvalidated
    }
    let kind: Kind
    let scope: String?
    let appId: String?
    let appName: String?
    let visible: Bool?
    let generation: String?
}

/// Heap box carrying one JSON payload through the async, non-reentrant
/// self-delivery path (`InstanceBroadcast.deliverLocally`). `PostMessageW`
/// cannot carry `WM_COPYDATA`'s pointer-to-caller's-stack payload safely
/// (the sender may have already returned by the time the message is
/// dequeued), so self-delivery uses a private `WM_APP`-range message whose
/// `LPARAM` is a retained pointer to one of these boxes instead; the pump
/// thread takes ownership (`takeRetainedValue()`) when it dequeues the
/// message. File-scope (not nested in `InstanceBroadcast`) purely so the
/// free-function `WNDPROC` below -- which cannot capture `self` -- can name
/// it directly.
private final class WindowsLocalBroadcastPayload {
    let json: String
    init(_ json: String) { self.json = json }
}

/// The `WNDPROC` for `InstanceBroadcast`'s Windows message-only broadcast
/// window. Must be a capture-free, file-scope function (or the Swift
/// compiler cannot treat it as the `@convention(c)` function pointer
/// `WNDCLASSEXW.lpfnWndProc` requires) -- there is no way to bind it to a
/// particular `InstanceBroadcast` instance the way an `@objc` selector target
/// would on macOS, so it recovers the instance from `GWLP_USERDATA`, which
/// `InstanceBroadcast` stashes on the window immediately after creating it.
private func chalkboardBroadcastWndProc(_ hWnd: HWND?, _ uMsg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch uMsg {
    case UINT(WM_COPYDATA):
        // WM_COPYDATA is the one Win32 message whose payload the OS itself
        // marshals into this process's address space for the duration of
        // this call (unlike an ordinary LPARAM, which is just an integer);
        // reading `lParam` as a `COPYDATASTRUCT*` here is the documented,
        // correct way to receive it, and `dataPtr`/`cbData` are valid only
        // until this function returns -- hence copying them into a `Data`
        // immediately rather than retaining the pointer.
        guard let hWnd,
              let structPtr = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam))) else {
            return 0
        }
        let cds = structPtr.assumingMemoryBound(to: COPYDATASTRUCT.self).pointee
        guard let dataPtr = cds.lpData else { return 0 }
        let payload = Data(bytes: dataPtr, count: Int(cds.cbData))
        guard let json = String(data: payload, encoding: .utf8) else { return 0 }
        InstanceBroadcast.windowsInstance(for: hWnd)?.dispatchIncoming(json: json)
        // A nonzero return is the documented convention for "this receiver
        // accepted the WM_COPYDATA"; nothing on the sending side currently
        // inspects it (SendMessageTimeoutW is used for its timeout, not its
        // result value), but returning it correctly costs nothing and keeps
        // this receiver well-behaved for any future sender that does check.
        return 1

    case InstanceBroadcast.localDeliveryMessage:
        guard let hWnd,
              let boxPtr = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam))) else {
            return 0
        }
        // `takeRetainedValue()`, not `takeUnretainedValue()`: this consumes
        // the +1 retain `InstanceBroadcast.deliverLocally` created when it
        // posted the message, so the box is released exactly once, here,
        // when the pump thread actually dequeues it -- never on the posting
        // thread, which is the whole point of routing self-delivery through
        // `PostMessageW` instead of calling the handler inline.
        let box = Unmanaged<WindowsLocalBroadcastPayload>.fromOpaque(boxPtr).takeRetainedValue()
        InstanceBroadcast.windowsInstance(for: hWnd)?.dispatchIncoming(json: box.json)
        return 0

    default:
        return DefWindowProcW(hWnd, uMsg, wParam, lParam)
    }
}

/// Cross-process fan-out for the two menu-bar actions ("Clear All
/// Annotations" and "Quit AI Chalkboard"), Windows twin.
///
/// Same reasons to exist as the macOS branch above (read its doc comment for
/// the full "two MCP processes, one status item, one AnnotationStore per
/// process" rationale -- none of that changes on Windows) but built on a
/// completely different transport, because `DistributedNotificationCenter`
/// is a Darwin-only wrapper around `distnoted` and Swift on Windows has no
/// Objective-C runtime for `@objc`/`#selector`-based observer registration
/// even if a cross-process pub/sub bus like it existed here.
///
/// THE WINDOWS TRANSPORT: each instance creates one `HWND_MESSAGE` window
/// (invisible, never painted, costs no taskbar/Alt-Tab presence) under a
/// well-known window class name, on a dedicated thread that runs nothing but
/// a `GetMessage`/`DispatchMessage` pump for it. Broadcasting means walking
/// every OTHER window registered under that same class name (`FindWindowExW`
/// with `HWND_MESSAGE` as the parent, repeated until it returns `nil`) and
/// sending each one a `WM_COPYDATA` carrying this broadcast's JSON payload.
/// `WM_COPYDATA` is the right primitive here -- unlike
/// `RegisterWindowMessage` + `PostMessage(HWND_BROADCAST)`, which can only
/// carry two integers (`WPARAM`/`LPARAM`) and has no way to attach the
/// scope/appId/appName/generation payload this channel needs -- it is the
/// documented Win32 mechanism for handing an arbitrary-length buffer to
/// another process's window procedure.
///
/// SESSION SCOPING -- READ BEFORE ASSUMING THIS "JUST WORKS" LIKE macOS:
/// macOS's login session has no equivalent of Remote Desktop, Fast User
/// Switching, or Session 0 service isolation putting multiple, mutually
/// invisible desktop sessions on ONE machine at once. Windows does. Two
/// users RDP'd into the same box, or one user's interactive session next to
/// Session 0's service session, must never have one session's Clear/Quit
/// reach the other's overlay instances. In practice this is largely enforced
/// by the OS already -- each interactive session gets its own Window
/// Station (`WinSta0`), and `FindWindowExW` only searches windows on the
/// calling thread's own desktop/window station -- but this file does not
/// rely on that alone as an unverified assumption about window-station
/// behaviour across every Windows version and Group Policy configuration it
/// will ever run under. `discoverSiblingWindows()` below additionally reads
/// each candidate window's owning PID (`GetWindowThreadProcessId`) and maps
/// it to a session id (`ProcessIdToSessionId`), and skips any candidate
/// whose session does not match this process's own -- making the scoping an
/// explicit, provable property of this code, not folklore about Windows
/// Terminal Services isolation.
///
/// SELF-DELIVERY, ASYNC AND NON-REENTRANT (matching the macOS branch's
/// documented contract, see its "IMPORTANT -- WHY THE POSTERS DO NO LOCAL
/// WORK" comment): `WM_COPYDATA` can only be sent with the blocking
/// `SendMessageW`/`SendMessageTimeoutW` -- there is no way to `PostMessage`
/// it safely, because the receiver must finish reading the sender's buffer
/// before the sender's stack frame (or, here, the local byte array) goes
/// away. Sending it to THIS process's own broadcast window would therefore
/// make every post block until this process's own handler finished running
/// -- exactly the reentrant-looking, "did not return first" behaviour macOS
/// explicitly avoids. So self-delivery is special-cased: `deliverLocally`
/// posts (never sends) a private `WM_APP`-range message carrying a small
/// heap-allocated payload box, which the pump thread only picks up on its
/// own next loop iteration -- genuinely asynchronous, and never reentrant
/// with respect to the calling thread, the same as `postNotificationName`
/// returning before the local observer fires ~2ms later on macOS.
///
/// LAUNCH-MODE SCOPING is identical in spirit to the macOS branch: `postQuit
/// All(scopedToLaunchMode:)` still carries `QuitScope.current` (or `nil` for
/// an unscoped, all-instances quit) inside the JSON payload's `scope` field,
/// and `handleQuitAllBroadcast` still compares it against this process's own
/// `QuitScope.current` before terminating. That logic is entirely
/// platform-neutral (`QuitScope`/`ClearBroadcastRequest`/`BroadcastKey`
/// above have no AppKit or WinSDK dependency) and is reused verbatim, not
/// reimplemented.
///
/// ECHO SUPPRESSION FOR CAPTURE-VISIBLE STATE: exactly as on macOS, this file
/// does no de-duplication of its own for a self-delivered
/// `setCaptureVisible` broadcast -- `handleSetCaptureVisibleBroadcast` calls
/// `OverlayWindowController.shared.setCaptureVisible(visible)`
/// unconditionally, the same call the macOS branch makes, and relies on that
/// method's own documented no-op-when-unchanged behaviour (see the macOS
/// branch's comment on `handleSetCaptureVisibleBroadcast`) to make a
/// self-delivered copy free. This file intentionally does not duplicate that
/// idempotency locally; doing so would risk it drifting out of sync with the
/// real state `OverlayWindowController` tracks.
public final class InstanceBroadcast {
    public static let shared = InstanceBroadcast()

    /// Reverse-DNS-style and version-suffixed for the same reason the macOS
    /// branch's `Notification.Name`s are: it is a session-wide namespace (any
    /// process in this Windows session can, in principle, create a window
    /// under this class name), and `.v1` leaves room to change the wire
    /// schema later without an old and a new build silently misinterpreting
    /// each other's payloads -- an old build simply will not find (or be
    /// found by) a differently-versioned class name.
    private static let windowClassName = "com.aichalkboard.overlay.broadcast.v1"
    private static let windowClassNameWide: [UInt16] = Array(windowClassName.utf16) + [0]

    /// The `HWND_MESSAGE` sentinel (`(HWND)-3`), used as every broadcast
    /// window's parent so it never appears in the taskbar, Alt-Tab, or
    /// `EnumWindows`'s top-level enumeration -- message-only windows exist
    /// purely to have a `WNDPROC` and a message queue.
    private static let hwndMessageOnly = HWND(bitPattern: -3)

    /// Private, process-local message used only for the async self-delivery
    /// path described in this class's doc comment above. `WM_APP` (0x8000)
    /// is the documented start of the range Win32 reserves for
    /// application-defined messages.
    // `fileprivate`, not `private`: the free-function `WNDPROC`
    // (`chalkboardBroadcastWndProc`, file-scope above -- it cannot be a
    // method and capture `self`) switches on this value, and a top-level
    // function is outside a `private` member's access scope even in the
    // same file. `fileprivate` is still as narrow as Swift allows while
    // remaining visible to that function.
    fileprivate static let localDeliveryMessage: UINT = UINT(WM_APP) + 1

    // THREADING: `hwnd`/`isRegistered`/`isQuitting` are read and written from
    // multiple threads by construction -- the pump thread that owns the
    // message-only window, whatever thread calls `postX`, and the 1s
    // watchdog's background queue -- unlike the macOS branch, which can get
    // away with "everything is main-thread-only" because AppKit and
    // DistributedNotificationCenter delivery are both main-thread affairs
    // here. `stateLock` guards exactly these three fields.
    private let stateLock = NSLock()
    private var hwnd: HWND?
    private var isRegistered = false
    private var isQuitting = false

    /// Signalled once the pump thread has either created its broadcast
    /// window (success) or given up (failure, already logged). `register
    /// Observers()` waits on it so a `postX` call immediately afterward never
    /// races an unset `hwnd` -- matching the macOS branch's `addObserver`
    /// calls, which are synchronous by the time `registerObservers()`
    /// returns.
    private let readySemaphore = DispatchSemaphore(value: 0)

    /// Retained for the process lifetime so the pump thread is never
    /// deallocated out from under its own running loop.
    private var pumpThread: Thread?

    /// Set by whichever Windows lifecycle owner eventually exists (the
    /// Windows analogue of `AppDelegate`) to run its own graceful shutdown --
    /// closing overlay windows, flushing logs -- before the process actually
    /// exits. By the time this is invoked, `InstanceBroadcast` has already
    /// decided termination must happen, already set `isQuitting`, and already
    /// logged why; this closure's only job is the actual shutdown action.
    ///
    /// WHY A CLOSURE, NOT A DIRECT CALL LIKE THE macOS BRANCH'S
    /// `AppDelegate.markInternalTermination` + `NSApp.terminate(nil)`: there
    /// is no Windows lifecycle owner in this codebase yet (no Windows
    /// `AppDelegate`), and hard-wiring a call to a type that does not exist
    /// would make this file itself uncompilable rather than merely pending
    /// the rest of the Windows port. This mirrors a pattern already used
    /// elsewhere in this codebase for the same kind of cross-module wiring --
    /// `OverlayWindowController.onCaptureVisibleChanged`, set from
    /// `AppDelegate.applicationDidFinishLaunching` -- rather than inventing a
    /// new one. When the Windows lifecycle owner lands, it should set this to
    /// its own graceful-shutdown routine (and end that routine by returning
    /// from its message loop, or calling `ExitProcess`).
    ///
    /// If nothing has set this -- including today, since it does not exist
    /// yet -- the fallback in `terminate(reason:)` below still terminates the
    /// process. A user's Quit must never be silently ignored merely because
    /// the graceful-shutdown hook has not been wired up yet; it just skips
    /// whatever window teardown the eventual owner would have performed.
    public var onQuitRequested: ((_ reason: String) -> Void)?

    private init() {}

    // MARK: - Registration

    /// Windows counterpart to the macOS branch's `registerObservers()`: see
    /// its doc comment for why this MUST be called by every instance
    /// (primary and secondary alike) and MUST NOT be gated on
    /// `InstanceLock.shared.acquire()`. That reasoning is unchanged here.
    ///
    /// Unlike the macOS branch (which registers four `@objc` selectors
    /// against an already-running AppKit main run loop), this spins up its
    /// OWN dedicated thread with its own `GetMessage` pump -- there is no
    /// guarantee this process's main thread runs a Win32 message loop at
    /// all, and even if the eventual Windows overlay window owner runs one
    /// on main, coupling this channel's delivery to that loop's health would
    /// be an unwanted dependency in both directions. Blocks (briefly, sub-
    /// millisecond in the ordinary case) until the broadcast window exists or
    /// setup has definitively failed, so that a `postX` call immediately
    /// afterward behaves the same as it does on macOS: it never races a
    /// not-yet-registered channel.
    public func registerObservers() {
        stateLock.lock()
        guard !isRegistered else { stateLock.unlock(); return }
        isRegistered = true
        stateLock.unlock()

        let thread = Thread { [self] in runBroadcastPump() }
        thread.name = "AIChalkboard.InstanceBroadcast.Pump"
        pumpThread = thread
        thread.start()

        // A generous but bounded wait: this runs once, at startup, and must
        // not hang application launch forever if window-class registration
        // is somehow broken on this machine. `runBroadcastPump()` signals
        // this semaphore on every exit path, success or failure.
        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            Logger.shared.log("InstanceBroadcast: timed out waiting for the Windows broadcast window to initialize. Cross-process clear/quit/capture-visibility/suspension broadcasts may not work in this process.", level: "ERROR")
        }
    }

    /// Runs entirely on the dedicated pump thread started by
    /// `registerObservers()`. Registers the well-known window class (once
    /// per process; `ERROR_CLASS_ALREADY_EXISTS` on a second attempt in the
    /// same process is not expected given the `isRegistered` guard above, but
    /// is tolerated rather than treated as fatal), creates this instance's
    /// `HWND_MESSAGE` window, stashes `self` on it via `GWLP_USERDATA` so the
    /// free-function `WNDPROC` above can recover it, then pumps messages
    /// until the window is destroyed (which, in practice, is never -- the
    /// window and this thread are both process-lifetime, exactly like the
    /// macOS branch's observer registration).
    private func runBroadcastPump() {
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = chalkboardBroadcastWndProc
        windowClass.hInstance = GetModuleHandleW(nil)

        let atom: ATOM = Self.windowClassNameWide.withUnsafeBufferPointer { buffer in
            var classToRegister = windowClass
            classToRegister.lpszClassName = buffer.baseAddress
            return RegisterClassExW(&classToRegister)
        }
        if atom == 0 {
            let registrationError = GetLastError()
            guard registrationError == DWORD(ERROR_CLASS_ALREADY_EXISTS) else {
                Logger.shared.log("InstanceBroadcast: RegisterClassExW failed (Win32 error \(registrationError)); this process cannot send or receive cross-process clear/quit/capture-visibility/suspension broadcasts.", level: "ERROR")
                readySemaphore.signal()
                return
            }
        }

        let createdWindow: HWND? = Self.windowClassNameWide.withUnsafeBufferPointer { buffer in
            CreateWindowExW(0, buffer.baseAddress, nil, 0, 0, 0, 0, 0,
                             Self.hwndMessageOnly, nil, GetModuleHandleW(nil), nil)
        }
        guard let createdWindow else {
            Logger.shared.log("InstanceBroadcast: CreateWindowExW failed (Win32 error \(GetLastError())); this process cannot send or receive cross-process clear/quit/capture-visibility/suspension broadcasts.", level: "ERROR")
            readySemaphore.signal()
            return
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        // `LONG_PTR` is `Int64` on this toolchain (a distinct typealias, not
        // interchangeable with plain `Int` for overload resolution), so the
        // pointer must round-trip through `UInt64` explicitly rather than
        // `UInt`/`Int`'s own `bitPattern:` initializers.
        _ = SetWindowLongPtrW(createdWindow, GWLP_USERDATA,
                               LONG_PTR(bitPattern: UInt64(UInt(bitPattern: selfPointer))))

        stateLock.lock()
        hwnd = createdWindow
        stateLock.unlock()

        Logger.shared.log("InstanceBroadcast: registered Windows message-only broadcast window (class \(Self.windowClassName)) for clear, quit, capture visibility, and durable suspension-lease invalidation. Suspension notifications are wake-up hints only; canonical state is read from the lease registry.", level: "INFO")
        readySemaphore.signal()

        // Blocks this dedicated thread until the window is destroyed, which
        // in practice is never (see this method's doc comment) -- this is
        // the Windows analogue of the macOS branch's "delivery requires a
        // running main run loop" note, except this loop belongs entirely to
        // `InstanceBroadcast` rather than depending on AppKit's.
        // `GetMessageW` bridges to Swift `Bool` on this toolchain (unlike
        // the raw three-state `BOOL`/`WINBOOL` -1-on-error C contract), so
        // the loop below cannot distinguish WM_QUIT (`false`) from a genuine
        // `GetLastError` failure the way idiomatic C Win32 code can -- both
        // simply end the pump. That is an acceptable loss here: this loop's
        // only job is to keep dispatching for the lifetime of the process
        // (the window is never explicitly destroyed -- see this method's
        // doc comment), so either outcome means the same thing in practice,
        // "stop pumping".
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }

    /// Recovers the owning `InstanceBroadcast` from a broadcast window's
    /// `GWLP_USERDATA`, for use by the free-function `WNDPROC` above (which
    /// cannot capture `self`). Returns `nil` before `runBroadcastPump()` has
    /// stashed it (the brief window between `CreateWindowExW` returning and
    /// `SetWindowLongPtrW` running, during which `WM_CREATE`/`WM_NCCREATE`
    /// etc. can already reach the `WNDPROC`) or if `hWnd` is not one of this
    /// process's own broadcast windows.
    fileprivate static func windowsInstance(for hWnd: HWND) -> InstanceBroadcast? {
        let raw = GetWindowLongPtrW(hWnd, GWLP_USERDATA)
        guard raw != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(raw))) else { return nil }
        return Unmanaged<InstanceBroadcast>.fromOpaque(pointer).takeUnretainedValue()
    }

    // MARK: - Posting

    /// See the macOS branch's identical-in-spirit doc comment on why the
    /// scope must be resolved once, by the poster, and travel in the
    /// payload rather than be re-derived by each receiver.
    public func postClear(scope: ClearScope, appId: String?, appName: String?) {
        Logger.shared.log("InstanceBroadcast: posting CLEAR broadcast (scope=\(scope.rawValue), app=\(appName ?? appId ?? "n/a")) to all AI Chalkboard instances.", level: "INFO")
        broadcast(WindowsBroadcastEnvelope(kind: .clear, scope: scope.rawValue, appId: appId, appName: appName, visible: nil, generation: nil))
    }

    public func postSetCaptureVisible(_ visible: Bool) {
        Logger.shared.log("InstanceBroadcast: posting SET-CAPTURE-VISIBLE broadcast (visible=\(visible)) to all AI Chalkboard instances.", level: "INFO")
        broadcast(WindowsBroadcastEnvelope(kind: .setCaptureVisible, scope: nil, appId: nil, appName: nil, visible: visible, generation: nil))
    }

    /// Broadcasts only a durable-state wake-up hint, exactly like the macOS
    /// branch: no requested presentation state travels here, and no ACK
    /// transport is needed -- see that branch's identical doc comment.
    public func postSuspensionInvalidation(generation: UInt64) {
        broadcast(WindowsBroadcastEnvelope(kind: .suspensionInvalidated, scope: nil, appId: nil, appName: nil, visible: nil, generation: String(generation)))
    }

    /// Posts "quit" to every instance, including this one. See the macOS
    /// branch's doc comment for the scoping contract
    /// (`scopedToLaunchMode`/`QuitScope`), which is unchanged here.
    public func postQuitAll(scopedToLaunchMode: Bool = false) {
        let scope = scopedToLaunchMode ? QuitScope.current : nil
        Logger.shared.log("InstanceBroadcast: posting QUIT broadcast (scope=\(scope ?? "<all instances>")) to \(scopedToLaunchMode ? "AI Chalkboard instances launched in the same mode" : "all coexisting AI Chalkboard instances") (user-initiated quit).", level: "INFO")
        broadcast(WindowsBroadcastEnvelope(kind: .quit, scope: scope, appId: nil, appName: nil, visible: nil, generation: nil))

        // Watchdog, quit only -- same fail-safe purpose as the macOS
        // branch's identically-named watchdog (read its long comment for the
        // full "a quit that visibly quits beats a quit that appears to be
        // ignored" reasoning, which is unchanged here), but the failure mode
        // it guards against is narrower and platform-specific: on macOS the
        // risk is `distnoted`, an OS daemon entirely OUTSIDE this process,
        // silently failing to loop the notification back. Here, self-
        // delivery is entirely IN-PROCESS (`deliverLocally` -> `PostMessageW`
        // to this process's own pump thread), so the realistic failure modes
        // are narrower still -- `PostMessageW` itself failing, or the pump
        // thread having died -- but the consequence (a Quit that silently
        // does nothing) would be exactly as bad, so the same fail-safe
        // applies.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let alreadyQuitting = self.isQuitting
            if !alreadyQuitting { self.isQuitting = true }
            self.stateLock.unlock()
            guard !alreadyQuitting else { return }

            Logger.shared.log("InstanceBroadcast: QUIT broadcast could not be confirmed after 1s -- this process never received its own local delivery back, so something about the in-process broadcast window is broken. Terminating THIS process anyway so the user's Quit is not silently ignored; any sibling that DID receive the broadcast is already dying independently, and any sibling that missed it re-elects itself primary the same way the macOS branch's watchdog comment describes.", level: "WARN")
            self.terminate(reason: "quit broadcast unconfirmed; terminating locally")
        }
    }

    /// Encodes `envelope` once, delivers it to this process asynchronously
    /// and non-reentrantly (see this class's doc comment), then sends it to
    /// every sibling window this session's `discoverSiblingWindows()` finds.
    private func broadcast(_ envelope: WindowsBroadcastEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8) else {
            Logger.shared.log("InstanceBroadcast: failed to encode a \(envelope.kind.rawValue) broadcast payload; nothing was sent.", level: "ERROR")
            return
        }

        deliverLocally(json)

        for sibling in discoverSiblingWindows() {
            sendCopyData(json, to: sibling)
        }
    }

    /// The async, non-reentrant self-delivery path described in this class's
    /// doc comment: posts (never sends) a private message carrying a
    /// retained pointer to a heap-allocated payload box, which the pump
    /// thread decodes and releases when it actually dequeues the message.
    private func deliverLocally(_ json: String) {
        stateLock.lock()
        let target = hwnd
        stateLock.unlock()

        guard let target else {
            Logger.shared.log("InstanceBroadcast: cannot deliver a broadcast to this process -- no broadcast window exists (registerObservers() was not called, or failed). This process will not see its own action take effect.", level: "ERROR")
            return
        }

        let box = WindowsLocalBroadcastPayload(json)
        let boxPointer = Unmanaged.passRetained(box).toOpaque()
        let lparam = LPARAM(bitPattern: UInt64(UInt(bitPattern: boxPointer)))
        guard PostMessageW(target, Self.localDeliveryMessage, 0, lparam) else {
            // Nobody will ever dequeue this box -- release it here rather
            // than leaking it, and log loudly: this specifically means the
            // poster will not see its own Clear/Quit/etc. take effect.
            Unmanaged<WindowsLocalBroadcastPayload>.fromOpaque(boxPointer).release()
            Logger.shared.log("InstanceBroadcast: PostMessageW failed to queue a local self-delivery (Win32 error \(GetLastError())).", level: "ERROR")
            return
        }
    }

    /// Walks every `HWND_MESSAGE` child window registered under this
    /// process's own well-known broadcast class, EXCLUDING this process's
    /// own window (self-delivery goes through `deliverLocally` instead) and
    /// any window whose owning process is not in this same Windows session
    /// (see this class's "SESSION SCOPING" doc comment above).
    private func discoverSiblingWindows() -> [HWND] {
        stateLock.lock()
        let selfWindow = hwnd
        stateLock.unlock()

        var ourSessionId: DWORD = 0
        guard ProcessIdToSessionId(GetCurrentProcessId(), &ourSessionId) else {
            Logger.shared.log("InstanceBroadcast: ProcessIdToSessionId failed for this process (Win32 error \(GetLastError())); cannot safely confirm sibling discovery is scoped to this session, so no siblings will be contacted this round.", level: "ERROR")
            return []
        }

        var siblings: [HWND] = []
        var previous: HWND?
        while true {
            let found: HWND? = Self.windowClassNameWide.withUnsafeBufferPointer { buffer in
                FindWindowExW(Self.hwndMessageOnly, previous, buffer.baseAddress, nil)
            }
            guard let found else { break }
            previous = found
            if found == selfWindow { continue }

            var ownerPID: DWORD = 0
            _ = GetWindowThreadProcessId(found, &ownerPID)
            var ownerSessionId: DWORD = 0
            guard ProcessIdToSessionId(ownerPID, &ownerSessionId), ownerSessionId == ourSessionId else { continue }

            siblings.append(found)
        }
        return siblings
    }

    /// Sends one already-encoded payload to one sibling window.
    ///
    /// `SendMessageTimeoutW`, deliberately not the plain, unbounded
    /// `SendMessageW`: `WM_COPYDATA` is inherently a blocking cross-process
    /// call -- the receiving thread must finish processing it before this
    /// call can return, unlike `distnoted`'s fire-and-forget fan-out on
    /// macOS -- so one hung, debugger-suspended, or SIGSTOP-equivalent
    /// sibling must not be able to stall a Clear/Quit broadcast to every
    /// OTHER sibling indefinitely. `SMTO_ABORTIFHUNG` lets Windows itself
    /// bail out as soon as it considers the target unresponsive; the fixed
    /// 2-second ceiling is a backstop beyond that. THIS IS AN HONEST,
    /// DELIBERATE DIVERGENCE FROM macOS, not an oversight -- see
    /// contractChanges for the precise statement of what is and is not
    /// guaranteed here.
    private func sendCopyData(_ json: String, to target: HWND) {
        stateLock.lock()
        let selfWindow = hwnd
        stateLock.unlock()

        var bytes = Array(json.utf8)
        let delivered: Bool = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            var copyData = COPYDATASTRUCT()
            // Unused: the envelope's own `kind` field carries the meaning,
            // so there is nothing else worth tagging this with.
            copyData.dwData = 0
            copyData.cbData = DWORD(buffer.count)
            copyData.lpData = UnsafeMutableRawPointer(buffer.baseAddress)
            return withUnsafeMutablePointer(to: &copyData) { copyDataPointer -> Bool in
                let lparam = LPARAM(bitPattern: UInt64(UInt(bitPattern: copyDataPointer)))
                let wparam: WPARAM = selfWindow.map { WPARAM(UInt64(UInt(bitPattern: $0))) } ?? 0
                var sendResult: DWORD_PTR = 0
                let completed = SendMessageTimeoutW(
                    target, UINT(WM_COPYDATA), wparam, lparam,
                    UINT(SMTO_ABORTIFHUNG), 2000, &sendResult
                )
                return completed != 0
            }
        }

        if !delivered {
            Logger.shared.log("InstanceBroadcast: WM_COPYDATA send to a sibling broadcast window timed out or failed (Win32 error \(GetLastError())); that sibling instance did not receive this broadcast.", level: "WARN")
        }
    }

    /// Terminates this process, routing through `onQuitRequested` when a
    /// Windows lifecycle owner has installed one (see that property's doc
    /// comment) and falling back to an immediate `ExitProcess` when none has.
    private func terminate(reason: String) {
        if let onQuitRequested {
            onQuitRequested(reason)
        } else {
            Logger.shared.log("InstanceBroadcast: no Windows termination handler is installed (onQuitRequested); falling back to an immediate ExitProcess. Reason: \(reason)", level: "WARN")
            ExitProcess(0)
        }
    }

    // MARK: - Receiving

    /// Decodes one JSON payload (from either `WM_COPYDATA` or the local
    /// self-delivery path) and dispatches it to the matching handler below.
    /// Runs on the pump thread for BOTH paths -- see this class's doc
    /// comment on why self-delivery is routed back through the same
    /// `WNDPROC` rather than, say, a raw `DispatchQueue.global().async` --
    /// which gives every handler the same threading guarantees a
    /// `WM_COPYDATA` delivery from a sibling process would have.
    fileprivate func dispatchIncoming(json: String) {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WindowsBroadcastEnvelope.self, from: data) else {
            Logger.shared.log("InstanceBroadcast: RECEIVED a broadcast payload that could not be decoded; ignoring it. A malformed or hostile payload is harmless here -- every handler below only re-reads canonical local/durable state, never executes a command carried solely by the payload's shape.", level: "WARN")
            return
        }
        switch envelope.kind {
        case .clear: handleClearAllBroadcast(envelope)
        case .setCaptureVisible: handleSetCaptureVisibleBroadcast(envelope)
        case .suspensionInvalidated: handleSuspensionInvalidatedBroadcast(envelope)
        case .quit: handleQuitAllBroadcast(envelope)
        }
    }

    private func handleClearAllBroadcast(_ envelope: WindowsBroadcastEnvelope) {
        let request = ClearBroadcastRequest(
            scope: envelope.scope.flatMap(ClearScope.init(rawValue:)) ?? .all,
            appId: envelope.appId,
            appName: envelope.appName
        )

        switch request.scope {
        case .all:
            let removed = request.apply(to: AnnotationStore.shared)
            Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=CLEAR scope=all. Removed \(removed) annotation(s) from this process's store and repainting its overlays.", level: "INFO")
        case .active:
            let removed = request.apply(to: AnnotationStore.shared)
            Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=CLEAR scope=active app=\(request.appName ?? request.appId ?? "<none: global annotations only>"). Removed \(removed) annotation(s) from this process's store; annotations linked to other apps were left untouched.", level: "INFO")
        }

        OverlayWindowController.shared.refreshViews()
    }

    private func handleSetCaptureVisibleBroadcast(_ envelope: WindowsBroadcastEnvelope) {
        let visible = envelope.visible == true

        Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=SET-CAPTURE-VISIBLE visible=\(visible). Applying to this process's overlay windows.", level: "INFO")
        OverlayWindowController.shared.setCaptureVisible(visible)
    }

    private func handleSuspensionInvalidatedBroadcast(_ envelope: WindowsBroadcastEnvelope) {
        let generation = envelope.generation.flatMap(UInt64.init)
        // A malformed or hostile hint is harmless: reconcile reads canonical
        // state and never executes a desired state supplied by this channel.
        _ = SuspensionLeaseCoordinator.shared.reconcile(announcedGeneration: generation)
    }

    private func handleQuitAllBroadcast(_ envelope: WindowsBroadcastEnvelope) {
        let senderScope = envelope.scope

        // MainThread.async here for the same reason the macOS branch hops
        // before touching `isQuitting`/terminating: whichever Windows
        // lifecycle owner eventually installs `onQuitRequested` will need to
        // perform window teardown, and Win32 windows -- like AppKit -- are
        // thread-affine to whatever thread created them. Dispatching here
        // keeps that contract true regardless of which thread this handler
        // itself runs on (today, always the pump thread; see
        // `dispatchIncoming`'s doc comment).
        MainThread.async { [weak self] in
            guard let self else { return }

            let ownScope = QuitScope.current
            if let senderScope, senderScope != ownScope {
                Logger.shared.log("InstanceBroadcast: IGNORING scoped QUIT broadcast from a '\(senderScope)' instance -- this process is '\(ownScope)'. A launch-mode-scoped quit does not cross launch modes.", level: "INFO")
                return
            }

            Logger.shared.log("InstanceBroadcast: RECEIVED broadcast action=QUIT (scope=\(senderScope ?? "<legacy: unscoped>"), this process=\(ownScope)). Terminating this process.", level: "INFO")

            self.stateLock.lock()
            self.isQuitting = true
            self.stateLock.unlock()

            self.terminate(reason: "received QUIT broadcast from another instance (or from this process's own menu)")
        }
    }
}

#endif
