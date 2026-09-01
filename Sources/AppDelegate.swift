import Foundation

#if os(macOS)
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    /// "Clear Annotations for <App>" -- retained because its title is rewritten
    /// on every menu open to name whatever app is frontmost at that moment.
    private var clearActiveAppItem: NSMenuItem?

    /// "Capture Debug Mode" -- retained so its checkmark can be synced with
    /// the real `OverlayWindowController` state on every menu open (that state
    /// can also be changed by the MCP `set_capture_visible` tool or by a sibling
    /// instance's broadcast, neither of which goes through this menu).
    private var captureVisibleItem: NSMenuItem?

    /// Re-election poll, installed ONLY in a process that lost the initial
    /// `InstanceLock` election. Invalidated the moment this process is
    /// promoted to primary. See `startPrimaryElectionRetry()`.
    private var primaryElectionTimer: Timer?

    /// Lock-integrity poll, installed ONLY in the process that owns the status
    /// item. The mirror image of `primaryElectionTimer`: that one asks "has the
    /// primary slot come free?", this one asks "do I still hold it?".
    /// See `startPrimaryLockWatchdog()`.
    private var primaryLockWatchdog: Timer?

    /// Reconciles the durable suspension lease registry often enough that an
    /// abandoned short lease restores retained annotations promptly. The
    /// registry uses monotonic uptime; this timer is merely a wake-up, never a
    /// clock source.
    private var suspensionLeaseReconcileTimer: Timer?

    /// How often a secondary re-tests whether the primary slot has come free.
    /// Cheap (one `open` + one non-blocking `flock` + one `close`) and the
    /// contention case is not logged, so a few seconds is a good trade between
    /// "user notices the menu bar icon is gone" and pointless wakeups.
    private static let primaryElectionRetryInterval: TimeInterval = 3.0

    /// True once a shutdown that is NOT a user asking this app to quit has
    /// begun -- i.e. a lifecycle shutdown: the QUIT broadcast handler (a
    /// sibling already told everyone to quit), MCP stdin EOF (this process's
    /// own client hung up), or a POSIX signal (SIGTERM/SIGINT/SIGHUP aimed at
    /// this PID). `applicationShouldTerminate` reads it to decide whether it
    /// must fan the quit out to sibling instances; see that method and
    /// `markInternalTermination(reason:)`.
    ///
    /// Unsynchronized on purpose: every reader and writer is on the main
    /// thread (AppKit termination is main-thread-only, and all three internal
    /// paths hop to main before calling `NSApp.terminate`).
    private var isInternalTermination = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchMode.isMCPMode {
            // MCP mode (Claude Desktop launches us as `AIChalkboard --mcp`): hide the
            // Dock icon and Cmd-Tab entry. We deliberately use `.accessory`, NOT
            // `.prohibited`. `.prohibited` would prevent the app from ever activating,
            // and an app that cannot activate cannot run an NSStatusItem's menu --
            // clicking the menu-bar icon would do nothing. In MCP mode there is no
            // Dock icon and (since the floating Clear/Quit window was removed) no
            // window either, so that status-bar menu is the ONLY user interface this
            // app has: breaking it would leave the user with no way to clear
            // annotations or quit. `.accessory` removes the Dock presence (the actual
            // bug being fixed: Claude Desktop spawns two processes per config entry,
            // so the user saw two "AIChalkboard" Dock icons) while keeping the status
            // menu working and the overlay windows fully visible.
            //
            // Note: build_app.sh's Info.plist keeps `LSUIElement` = `false` on purpose.
            // Info.plist is static per app bundle and can't branch on argv, so this
            // runtime setActivationPolicy call is the only mechanism that can tell the
            // two launch modes apart. Do not "fix" this by flipping LSUIElement.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // GUI mode (e.g. launched directly from Finder/Dock): unchanged behavior --
            // show the Dock icon so the user can right-click -> Quit.
            NSApp.setActivationPolicy(.regular)
        }

        // Cross-process control channel. Registered UNCONDITIONALLY in every
        // process -- primary and secondary alike -- and deliberately NOT inside the
        // `InstanceLock.shared.acquire()` branch below. Only the primary owns a
        // menu-bar item, so only the primary can *originate* a Clear/Quit; every
        // instance must be able to *receive* one, otherwise the secondary's
        // annotations stay on screen forever and the secondary itself (no Dock icon
        // in MCP mode, no menu-bar item, no window) can never be quit. See
        // InstanceBroadcast for the full rationale.
        //
        // Registered before MCPServer.shared.start() because distributed
        // notifications are never replayed: anything posted before we observe is
        // lost.
        InstanceBroadcast.shared.registerObservers()

        // Must start BEFORE the overlay and the MCP server: the overlay's very
        // first paint filters on `currentAppId`, and the first `draw_*` call can
        // arrive within milliseconds of the MCP handshake and needs
        // `fallbackAppId` already seeded. Starting it late would make the first
        // annotation of a session land on the wrong app (or on none).
        ActiveAppTracker.shared.start()

        // Fail closed until this synchronous registry read completes. A newly
        // launched sibling must not briefly put a full-screen overlay back on
        // WindowServer while another client still owns a suspension lease.
        let suspensionBootstrap = SuspensionLeaseCoordinator.shared.bootstrapAndReconcile()
        if let error = suspensionBootstrap.error {
            Logger.shared.log("Suspension lease bootstrap failed; overlays remain ordered out: \(error)", level: "ERROR")
        }
        startSuspensionLeaseReconciliation()

        // The overlay is the entire reason the MCP server exists (it's what
        // draw_path/draw_image/draw_batch actually render into), so it must be set up in
        // BOTH modes, never skipped.
        OverlayWindowController.shared.setup()

        // Assigned unconditionally (not inside `setupStatusMenu()`) so a
        // process that starts as secondary and is later promoted to primary
        // (see `startPrimaryElectionRetry`) does not need this re-wired at
        // promotion time -- `applyCaptureIndicator` already no-ops until
        // `statusItem` exists. Single-closure property: see its doc comment
        // on why this must stay one slot, not a list.
        OverlayWindowController.shared.onCaptureVisibleChanged = { [weak self] visible in
            self?.applyCaptureIndicator(visible: visible)
        }

        MCPServer.shared.start()

        // The status-bar item is gated to the primary instance only (see
        // InstanceLock). In MCP mode there is no Dock icon, so for the primary
        // instance this menu becomes the ONLY remaining way to quit the app or clear
        // annotations manually -- it must still be installed here, not removed.
        if InstanceLock.shared.acquire() {
            setupStatusMenu()
        } else {
            // CRITICAL: a secondary instance must NOT exit and must NOT skip the
            // overlay/MCP setup above -- those already ran unconditionally. Claude
            // Desktop spawns two independent MCP stdio processes for one config entry,
            // each talking to Claude over its own stdin/stdout pipe; exiting here would
            // make Claude Desktop see a dropped/failed server connection, which is
            // strictly worse than a duplicate menu-bar icon. Only the status-bar item
            // is a true OS-level singleton, so only it is gated.
            Logger.shared.log("Another AI Chalkboard instance already owns the status-bar item; skipping menu bar setup in this process. MCP server and overlay continue running normally here.", level: "INFO")

            // ...but losing the election must not be PERMANENT. Start polling
            // for the primary slot to come free. See startPrimaryElectionRetry.
            startPrimaryElectionRetry()
        }

        MCPServer.shared.log("AI Chalkboard background agent initialized.")
    }

    private func startSuspensionLeaseReconciliation() {
        guard suspensionLeaseReconcileTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            _ = SuspensionLeaseCoordinator.shared.reconcile()
        }
        RunLoop.main.add(timer, forMode: .common)
        suspensionLeaseReconcileTimer = timer
    }

    // MARK: - Primary re-election (secondary instances only)

    /// Polls `InstanceLock.retryAcquire()` until this process wins the primary
    /// slot, then installs the status-bar menu.
    ///
    /// WHY: without this a secondary is stranded the moment the primary dies by
    /// any path other than the menu's Quit (crash, `kill`, Claude Desktop
    /// closing only that one pipe). The kernel releases the dead primary's
    /// flock, but nothing here ever re-tested it, so the survivor kept its
    /// t=0 answer forever and was left with NO control surface at all:
    /// `.accessory` policy means no Dock icon in MCP mode, it never installed a
    /// status item, and the floating Clear/Quit window that used to be the
    /// fallback (it simply became the frontmost clickable panel when the
    /// primary's disappeared) was deleted as redundant with the menu bar.
    /// Its `AnnotationStore` meanwhile may still be full, so the user is left
    /// staring at stale annotations on every screen with no way to clear them
    /// and no way to quit the invisible process painting them.
    private func startPrimaryElectionRetry() {
        // `Timer` on the main run loop in `.common` modes rather than the
        // `.default`-only `Timer.scheduledTimer`: `.common` keeps firing while
        // a menu is tracking or a window is being live-resized. The block runs
        // on the main thread, which `setupStatusMenu()` requires.
        let timer = Timer(timeInterval: Self.primaryElectionRetryInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // retryAcquire() (unlike acquire()) does not consult the cached
            // t=0 answer, and on success it keeps the lock descriptor open for
            // the rest of this process's life -- exactly like an
            // originally-primary instance.
            guard InstanceLock.shared.retryAcquire() else { return }

            timer.invalidate()
            self.primaryElectionTimer = nil

            Logger.shared.log("Promoted to PRIMARY instance: the previous primary released the instance lock (it exited, crashed or was killed). Installing the status-bar menu so this process regains a user-facing way to clear annotations and quit.", level: "INFO")
            self.setupStatusMenu()
        }
        RunLoop.main.add(timer, forMode: .common)
        primaryElectionTimer = timer

        Logger.shared.log("Secondary instance: polling every \(Self.primaryElectionRetryInterval)s to take over as primary if the current primary dies (otherwise this process would be left with no status item, no Dock icon and no window).", level: "INFO")
    }

    /// Polls `InstanceLock.revalidatePrimaryLock()` in whichever process owns
    /// the status item, so a lock file that gets deleted underneath a LIVE
    /// primary is recreated within one tick.
    ///
    /// WHY THE PRIMARY NEEDS ITS OWN POLL: `flock` lives on an open file
    /// description, not on a path. If `instance.lock` is deleted -- an
    /// uninstaller, "clear app data", a user cleaning out Application Support --
    /// this process keeps a valid lock on an inode with no name, and nothing on
    /// disk connects it to the lock path any more. A secondary polling that path
    /// cannot see this process at all: it is looking at a file that no longer
    /// exists. Only the process that owns the lock can restore that link, which
    /// is why the repair cannot live in `retryAcquire()` on the secondary side.
    /// Measured before this existed: deleting the lock file promoted the
    /// secondary within 3s and produced two permanent menu-bar icons.
    ///
    /// Runs at the same interval as the election retry and costs two `stat`
    /// calls a tick, doing real work only on mismatch. It is never invalidated:
    /// unlike the election poll it has no terminal state -- the invariant it
    /// maintains has to hold for as long as this process is primary.
    private func startPrimaryLockWatchdog() {
        guard primaryLockWatchdog == nil else { return }

        let timer = Timer(timeInterval: Self.primaryElectionRetryInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard InstanceLock.shared.revalidatePrimaryLock() == .relinquishToPathOwner else { return }

            // Another process repaired and locked the path before this orphaned
            // primary could. It now owns the only trustworthy election result;
            // remove our UI rather than leave two permanent status items.
            timer.invalidate()
            self.primaryLockWatchdog = nil
            if let statusItem = self.statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            Logger.shared.log("Demoted from PRIMARY instance: another process owns the repaired instance lock. Removed this process's status-bar item and resumed secondary election polling.", level: "WARN")
            self.startPrimaryElectionRetry()
        }
        RunLoop.main.add(timer, forMode: .common)
        primaryLockWatchdog = timer
    }

    // MARK: - Termination

    /// Marks the shutdown now beginning as INTERNAL / lifecycle-driven, so
    /// `applicationShouldTerminate` does not treat it as "the user asked to
    /// quit the app" and does not fan a QUIT broadcast out to siblings.
    ///
    /// Call immediately before `NSApp.terminate(nil)` from every path that is
    /// not a user quit:
    ///   * the QUIT-broadcast handler (a sibling already told everyone),
    ///   * MCP stdin EOF (only THIS process's client pipe closed),
    ///   * the SIGTERM/SIGINT/SIGHUP handlers (this PID was signalled).
    ///
    /// Main thread only -- all of those callers already hop to main, and the
    /// flag it sets is unsynchronized.
    public static func markInternalTermination(reason: String) {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            Logger.shared.log("markInternalTermination(\(reason)): no AppDelegate available; termination will be treated as user-initiated.", level: "WARN")
            return
        }
        delegate.isInternalTermination = true
        Logger.shared.log("Internal termination path: \(reason). This process will terminate WITHOUT broadcasting quit to sibling instances.", level: "INFO")
    }

    /// The single choke point through which every `NSApp.terminate` in this
    /// process passes -- Dock right-click -> Quit, Cmd-Q, the status menu, the
    /// signal handlers, MCP stdin EOF and the quit broadcast alike.
    ///
    /// A USER-initiated quit must take the sibling instance with it. Claude
    /// Desktop spawns two `AIChalkboard --mcp` processes per config entry and
    /// only one of them owns the menu bar, so quitting just this one leaves an
    /// invisible orphan still painting annotations -- exactly the split brain
    /// InstanceBroadcast exists to prevent. Before this method existed only the
    /// status-menu item broadcast; Dock -> Quit and Cmd-Q went straight to
    /// `NSApp.terminate` and killed one process.
    ///
    /// An INTERNAL quit must NOT: a closed MCP pipe, a signal aimed at this
    /// PID, or a broadcast we are already obeying all concern this process
    /// alone (or have already been fanned out by whoever posted them).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isInternalTermination {
            // Lifecycle shutdown -- already accounted for by whoever set the
            // flag. Return immediately: the signal handlers and the stdin-EOF
            // path must not be delayed or second-guessed here.
            //
            // This line is also the only runtime evidence that AppKit really
            // dispatches to this method (it is an @objc protocol requirement
            // on a Swift class -- if it ever stopped being visible to the
            // Objective-C runtime, quitting would silently stop broadcasting
            // and BUG 3 would come back unnoticed). Keep it.
            Logger.shared.log("applicationShouldTerminate: internal/lifecycle shutdown already flagged; terminating this process only, no quit broadcast.", level: "INFO")
            return .terminateNow
        }

        // Set before posting so the broadcast we are about to send cannot come
        // back around into a second post via this same method.
        isInternalTermination = true

        Logger.shared.log("User-initiated Dock/Cmd-Q quit. Broadcasting a launch-mode-scoped QUIT, then terminating this process.", level: "INFO")
        InstanceBroadcast.shared.postQuitAll(scopedToLaunchMode: true)

        // Safe to terminate right away: postNotificationName hands the message
        // to the session's distnoted daemon before it returns, so the fan-out
        // to siblings does not depend on this process still being alive.
        return .terminateNow
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // TRAP -- do NOT post the QUIT broadcast from here.
        //
        // This method runs for EVERY termination, including the internal ones:
        // MCP stdin EOF fires it too. Claude Desktop gives each of the two
        // spawned processes its own pipe, so one pipe closing (or one PID being
        // SIGTERM'd) is routine and says nothing about the other process. A
        // broadcast from here would turn that routine single-process shutdown
        // into "kill every instance", destroying a perfectly healthy sibling --
        // and, in the reverse direction, a sibling obeying a quit broadcast
        // would re-broadcast it on the way out.
        //
        // Quit fan-out belongs in applicationShouldTerminate, which can still
        // tell a user quit apart from a lifecycle shutdown.
        Logger.shared.log("applicationWillTerminate: AI Chalkboard shutting down cleanly.", level: "INFO")
    }

    private func setupStatusMenu() {
        // Owning the status item and owning the instance lock are the same role,
        // so the lock-integrity poll starts here rather than at either call
        // site: both paths into primary (winning at t=0, and being promoted by
        // the election retry) come through this method, and starting it here is
        // what keeps them from drifting apart. Idempotent.
        startPrimaryLockWatchdog()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "AI Chalkboard Overlay")
            // Explicit, not assumed: `contentTintColor` (used by
            // `applyCaptureIndicator` below to flag capture-debug mode)
            // only recolors TEMPLATE images. SF Symbols images are
            // template by default on most systems, but this makes the
            // dependency load-bearing rather than incidental.
            image?.isTemplate = true
            button.image = image
        }

        // Picks up whatever capture-debug state is already live -- relevant
        // when THIS process is promoted to primary mid-session (see
        // `startPrimaryElectionRetry`) rather than starting as primary with
        // the mode already off.
        applyCaptureIndicator(visible: OverlayWindowController.shared.isCaptureVisible)

        statusItem?.menu = makeStatusMenu()
    }

    /// Tints the menu-bar icon and updates its tooltip so capture-debug mode
    /// being left on is visible AT A GLANCE, without opening the menu.
    ///
    /// WHY THIS EXISTS: `captureVisibleItem`'s checkmark (set in
    /// `menuNeedsUpdate(_:)`) only answers the question once the menu is
    /// already open -- exactly backwards for a mode whose entire failure case
    /// is "left on and forgotten" (see `OverlayWindowController
    /// .captureAutoRevertInterval`'s doc comment for the incident that
    /// motivated both this and the auto-revert timer). This is the single
    /// place that state is rendered into the icon; it runs both from here
    /// (initial/promotion state) and from `OverlayWindowController
    /// .onCaptureVisibleChanged` (live updates from the MCP tool, the menu
    /// toggle, or a sibling instance's broadcast).
    ///
    /// No-ops when this process has no status item: `statusItem` is nil for
    /// every non-primary instance, and that is exactly the case in which
    /// there is no icon to update.
    private func applyCaptureIndicator(visible: Bool) {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = visible ? .systemOrange : nil
        button.toolTip = visible
            ? "AI Chalkboard (MCP Overlay Agent) — CAPTURE DEBUG MODE ON: every annotation renders on every app. Auto-reverts in \(Int(OverlayWindowController.captureAutoRevertInterval / 60)) min if not renewed."
            : "AI Chalkboard (MCP Overlay Agent)"
    }

    /// Builds the menu independently of installing an `NSStatusItem`. Keeping
    /// construction separate makes target/action wiring deterministic and
    /// testable without touching the live menu bar.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        // Scoped clear FIRST and bound to Cmd-K (the shortcut the old "Clear All
        // Annotations" item had), because it is now the everyday action: with
        // per-app annotations, "get this off the thing I'm looking at" is what
        // the user almost always means, and it cannot destroy notes left on an
        // app they can't currently see. Its title is filled in by
        // `menuNeedsUpdate(_:)` before the menu is ever drawn.
        let clearActive = NSMenuItem(title: "Clear Annotations for Current App + Global", action: #selector(clearAnnotationsForActiveApp), keyEquivalent: "k")
        menu.addItem(clearActive)
        clearActiveAppItem = clearActive

        // The nuclear option, deliberately given NO key equivalent: it wipes
        // annotations for apps that are not on screen, so it should take a
        // conscious click rather than being one fumbled keystroke away.
        menu.addItem(NSMenuItem(title: "Clear Everything (All Apps)", action: #selector(clearEverything), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        let capture = NSMenuItem(title: "Capture Debug Mode", action: #selector(toggleCaptureVisible), keyEquivalent: "")
        menu.addItem(capture)
        captureVisibleItem = capture

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit AI Chalkboard", action: #selector(quitApp), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        // Drives `menuNeedsUpdate(_:)`. Without a delegate the first item's
        // title would freeze at whatever app was frontmost when the menu was
        // built, and the checkmark would drift out of sync with the real
        // capture state whenever it was changed via MCP or by a sibling process.
        menu.delegate = self

        return menu
    }

    // MARK: - NSMenuDelegate

    /// Called by AppKit immediately before the menu is displayed -- the only
    /// moment at which "the current frontmost app" is a meaningful question to
    /// answer, since the user may have switched apps any number of times since
    /// the menu was constructed.
    ///
    /// `ActiveAppTracker.currentAppName` is used rather than
    /// `NSWorkspace.frontmostApplication` on purpose: clicking a status item
    /// activates its owning app, so by the time this runs the literal frontmost
    /// app can be AI Chalkboard itself. The tracker ignores self-activations, so
    /// it still reports the app the user was actually working in -- which is
    /// also exactly the app whose annotations the click will clear, keeping the
    /// label and the action in agreement.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        // "+ Global" is not decoration. This item clears the frontmost app's
        // annotations AND every GLOBAL one (`appId == nil`). A title that named only the app was a lie
        // about the blast radius: the user would click it expecting to lose
        // Safari's circles and silently lose their calibration grid too.
        //
        // Only the LABEL is fixed here. The predicate stays as it is: clearing
        // what is currently visible is the intended model ("only clear drawings
        // linked to the currently active app aka currently what's seen on
        // screen"), and globals are, by definition, on screen.
        let appName = ActiveAppTracker.shared.currentAppName
        clearActiveAppItem?.title = appName.map { "Clear Annotations for \($0) + Global" } ?? "Clear Annotations for Current App + Global"

        let visible = OverlayWindowController.shared.isCaptureVisible
        captureVisibleItem?.state = visible ? .on : .off
    }

    // Every menu action BROADCASTS rather than acting locally.
    //
    // WHY: `AnnotationStore` is a per-process singleton and Claude Desktop spawns
    // two `AIChalkboard --mcp` processes per config entry, each rendering the
    // annotations that arrived over its own MCP pipe. Only the primary instance
    // has this menu (the status item is gated on InstanceLock). A local
    // `AnnotationStore.shared.clearAll()` here would therefore leave every
    // annotation drawn by the SECONDARY process stuck on screen, and a local
    // `NSApp.terminate(nil)` would leave the secondary running invisibly --
    // no Dock icon, no menu-bar item, no window -- with no way to quit it.
    //
    // The posting process receives its own distributed notification, so these
    // methods must NOT also do the work locally: the observers in
    // InstanceBroadcast do it, in this process and in every other instance,
    // exactly once each. That is how the primary still clears its own store and
    // still quits itself.

    /// Clears only what is currently on screen: the frontmost app's annotations
    /// plus the global ones. Notes left on other apps survive.
    ///
    /// USES `currentAppId`, AND THAT DIFFERS FROM THE MCP `clear` TOOL ON
    /// PURPOSE -- the two must not be "unified":
    ///   * Here a HUMAN clicked a menu item, so the request means "clear what I
    ///     am looking at", and what they are looking at is the true frontmost
    ///     app. (`ActiveAppTracker` ignores activations of AI Chalkboard
    ///     itself, so opening this menu does not change the answer.)
    ///   * The MCP `clear` tool instead targets `fallbackAppId`, because it is
    ///     invoked by Claude while Claude Desktop is frontmost and it has to
    ///     remove what the untagged `draw_*` calls in that same conversation
    ///     created -- which were also tagged with `fallbackAppId`. See the
    ///     comment on that tool's `.active` case.
    ///
    /// The app is resolved HERE, in the posting process, and shipped in the
    /// broadcast payload -- receivers must not re-derive it, or two instances
    /// handling the same click a few milliseconds apart could target different
    /// apps. See `InstanceBroadcast.postClear(scope:appId:appName:)`.
    @objc private func clearAnnotationsForActiveApp() {
        // One paired read, not two acquisitions: the id and the name travel in
        // a single payload, so they must describe the same app even if an
        // activation lands between them. See `ActiveAppTracker.currentApp`.
        let active = ActiveAppTracker.shared.currentApp
        InstanceBroadcast.shared.postClear(scope: .active, appId: active.bundleId, appName: active.name)
    }

    @objc private func clearEverything() {
        InstanceBroadcast.shared.postClear(scope: .all, appId: nil, appName: nil)
    }

    /// Toggles AI Chalkboard's capture eligibility request and debug renderer.
    /// Broadcast, not local: every instance draws its own overlay windows, so a
    /// local-only flip would leave processes with inconsistent preferences.
    ///
    /// The checkmark is NOT set here -- `menuNeedsUpdate(_:)` reads the real
    /// state back from `OverlayWindowController` on the next menu open, so the
    /// UI can never claim a state the windows did not actually reach.
    @objc private func toggleCaptureVisible() {
        let newValue = !OverlayWindowController.shared.isCaptureVisible
        InstanceBroadcast.shared.postSetCaptureVisible(newValue)
    }

    // No double broadcast: this posts, the quit handler in InstanceBroadcast
    // receives it (in this process too) and calls
    // `AppDelegate.markInternalTermination(reason:)` before `NSApp.terminate`,
    // so by the time `applicationShouldTerminate` runs the flag is already set
    // and it does not post a second time.
    @objc private func quitApp() {
        InstanceBroadcast.shared.postQuitAll()
    }
}

#elseif os(Windows)
import WinSDK

// MARK: - Windows lifecycle policy shared with the macOS class above
//
// The macOS `AppDelegate` above must not be touched by this port (its
// election-retry/lock-watchdog/reconcile intervals and its
// internal-termination-flag semantics are working, verified behavior). The
// values below restate that SAME policy for the Windows class further down
// this file, rather than duplicating the reasoning silently -- see each
// constant's use site for how it plays the identical role its macOS
// namesake plays on the class above. A true shared type both platforms
// drive is left as follow-up work once the Windows port has landed
// end-to-end and the macOS class can be safely re-verified alongside a
// change to use it; see this file's Windows header comment for why that
// unification is not attempted here.
enum AppLifecyclePolicy {
    /// Matches the macOS class's `primaryElectionRetryInterval`, and is also
    /// reused for the primary-lock-watchdog cadence exactly as that class
    /// reuses the same constant for both timers. Typed `UInt32` directly
    /// (rather than `TimeInterval`, which the macOS constant uses) because
    /// this is consumed only by `SetTimer`'s millisecond `UINT` parameter.
    static let primaryElectionRetryIntervalMs: UInt32 = 3000
    /// Matches the macOS class's `startSuspensionLeaseReconciliation`
    /// literal (`timeInterval: 0.5`).
    static let suspensionLeaseReconcileIntervalMs: UInt32 = 500
}

/// Windows counterpart of the macOS `AppDelegate` class above. Same file, a
/// sibling `#elseif os(Windows)` branch rather than a separate type
/// implementing a shared protocol -- there is no Windows analogue of
/// `NSApplicationDelegate` to conform to, and Swift on Windows has no
/// Objective-C runtime, so there is also no `@objc`/`#selector` target-action
/// dispatch available for a menu or a notification observer the way the
/// macOS class uses both. Every `@objc` method and `NSMenuDelegate` callback
/// on the macOS class becomes a plain Swift closure or WndProc `case` below.
///
/// OWNS THE SAME FIVE RESPONSIBILITIES the macOS class's header comment
/// lists: activation policy (a documented no-op here -- see `launch()`),
/// the tray icon (the Windows analogue of the status-bar item, and, in MCP
/// mode, the ONLY user-facing control surface), the primary-election retry
/// timer, the primary-lock watchdog, the suspension-lease reconcile timer,
/// and the internal-vs-user termination distinction that decides whether to
/// broadcast QUIT to siblings. Every one of those five is gated to the
/// primary instance / shared across instances the exact same way the macOS
/// class gates them -- see each method's doc comment for the one-line
/// pointer back to its macOS twin rather than re-deriving the reasoning.
///
/// THREADING: every stored property below is UI-THREAD-ONLY, where "the UI
/// thread" means the single thread in Launcher/main.swift's Windows branch
/// that runs `GetMessageW`/`DispatchMessageW` -- the Windows analogue of "the
/// main thread" the macOS class's doc comments refer to throughout. Timers
/// are Win32 `SetTimer`/`WM_TIMER` (delivered through that same message
/// pump) rather than `Timer`/`RunLoop.main`, and any call arriving from a
/// different thread (the `SetConsoleCtrlHandler` callback in
/// Launcher/main.swift is the one real example today) is marshaled onto the
/// UI thread via `runOnUIThread(_:)` before touching any of this state --
/// see that method's doc comment.
public final class AppDelegate {
    /// The Windows analogue of `NSApp.delegate as? AppDelegate`: there is no
    /// `NSApplication` singleton to hang a delegate reference off on
    /// Windows, so Launcher/main.swift assigns this the moment it
    /// constructs the delegate -- mirroring `app.delegate = delegate` in the
    /// macOS entry point -- and every call site that would otherwise read
    /// `NSApp.delegate as? AppDelegate` (chiefly `AppHost.swift`) reads this
    /// instead.
    public static var current: AppDelegate?

    /// Captured at the very start of `launch()`, before the tray window
    /// exists, so `runOnUIThread(_:)` can recognize "already on the UI
    /// thread" even in that narrow startup window. See `runOnUIThread(_:)`.
    private static var mainThreadId: DWORD = 0

    // MARK: - Tray icon state (see the macOS class's `statusItem` and its
    // sibling properties for the role each of these plays; comments here
    // focus only on what differs mechanically)

    private var trayWindow: HWND?
    private var trayIconAdded = false

    private static let windowClassName = "AIChalkboardTrayWindow"

    /// Registered as `Shell_NotifyIconW`'s `uCallbackMessage`: how the shell
    /// tells this window's WndProc "the tray icon was clicked", since unlike
    /// `NSStatusItem`, a Win32 tray icon has no built-in click-to-open-menu
    /// behavior at all.
    private static let trayCallbackMessage: UInt32 = UInt32(WM_APP) + 1
    /// Registered custom message used by `runOnUIThread(_:)` to marshal an
    /// arbitrary closure onto the UI thread from any other thread.
    private static let runOnUIThreadMessage: UInt32 = UInt32(WM_APP) + 2

    /// Menu command identifiers, dispatched from `WM_COMMAND`. Matches the
    /// macOS menu's four items one-for-one, in the same order, with the same
    /// wording -- see `showTrayMenu()`.
    private enum MenuCommand: UInt32 {
        case clearActiveApp = 1001
        case clearEverything = 1002
        case toggleCaptureVisible = 1003
        case quit = 1004
    }

    /// `IDI_APPLICATION`/`IDI_WARNING` are C macros
    /// (`MAKEINTRESOURCEW(32512)`/`MAKEINTRESOURCEW(32515)`) that encode a
    /// numeric built-in resource id as a pointer VALUE rather than a real
    /// string pointer -- the Swift/Clang importer cannot represent that
    /// macro as a usable constant (it reports the macro "unavailable:
    /// structure not supported"), so the two ids are reproduced here
    /// directly from their documented, stable `winuser.h` values and
    /// encoded the same way `MAKEINTRESOURCEW` does. See
    /// `applyCaptureIndicator(visible:)`'s doc comment for why stock icons
    /// (rather than a custom `.ico` resource) are used at all.
    private static let idiApplication: UInt16 = 32512
    private static let idiWarning: UInt16 = 32515
    private static func systemIconName(_ id: UInt16) -> UnsafePointer<WCHAR>? {
        UnsafePointer<WCHAR>(bitPattern: UInt(id))
    }

    private enum TimerId: UINT_PTR {
        case primaryElectionRetry = 1
        case primaryLockWatchdog = 2
        case suspensionLeaseReconcile = 3
    }

    private var primaryElectionTimerRunning = false
    private var primaryLockWatchdogRunning = false

    /// Same role and same unsynchronized-on-purpose reasoning as the macOS
    /// class's `isInternalTermination`: every reader and writer here runs on
    /// the UI thread (see this class's THREADING note above), which is this
    /// platform's equivalent of "the main thread" for that guarantee.
    private var isInternalTermination = false

    public init() {}

    // MARK: - Lifecycle entry point (the Windows analogue of
    // `applicationDidFinishLaunching`)

    /// Called once from Launcher/main.swift's Windows branch, on the UI
    /// thread, before the Win32 message loop starts. Mirrors
    /// `applicationDidFinishLaunching`'s ordering exactly -- see that
    /// method's inline comments for WHY each step is ordered the way it is;
    /// none of that reasoning is platform-specific and it is not repeated
    /// here. What genuinely differs is called out inline below.
    public func launch() {
        Self.mainThreadId = GetCurrentThreadId()

        // ACTIVATION POLICY -- DOCUMENTED NO-OP, NOT AN OMISSION. The
        // macOS class's `.accessory` vs `.regular` `NSApplication` policy
        // switch exists to hide a Dock icon / Cmd-Tab entry in MCP mode
        // while keeping the status-bar menu usable. Windows has no Dock and
        // no Cmd-Tab-equivalent global switcher that a background helper
        // process needs to hide itself from by request: this process never
        // creates a taskbar-visible top-level window at all (the tray
        // helper window created below is a message-only window, and the
        // per-monitor overlay windows OverlayWindowController.swift creates
        // are `WS_EX_TOOLWINDOW`, which already keeps them out of the
        // taskbar and Alt-Tab). So there is no second "GUI mode" Windows
        // presentation to switch into here, and no policy call belongs in
        // this method at all -- the distinction the macOS branch makes
        // simply does not arise on this platform.
        createTrayWindow()

        InstanceBroadcast.shared.registerObservers()

        ActiveAppTracker.shared.start()

        let suspensionBootstrap = SuspensionLeaseCoordinator.shared.bootstrapAndReconcile()
        if let error = suspensionBootstrap.error {
            Logger.shared.log("Suspension lease bootstrap failed; overlays remain ordered out: \(error)", level: "ERROR")
        }
        startSuspensionLeaseReconciliation()

        OverlayWindowController.shared.setup()
        OverlayWindowController.shared.onCaptureVisibleChanged = { [weak self] visible in
            self?.applyCaptureIndicator(visible: visible)
        }

        MCPServer.shared.start()

        if InstanceLock.shared.acquire() {
            setupTrayIcon()
        } else {
            Logger.shared.log("Another AI Chalkboard instance already owns the tray icon; skipping tray setup in this process. MCP server and overlay continue running normally here.", level: "INFO")
            startPrimaryElectionRetry()
        }

        MCPServer.shared.log("AI Chalkboard background agent initialized.")
    }

    private func startSuspensionLeaseReconciliation() {
        guard let hwnd = trayWindow else { return }
        SetTimer(hwnd, TimerId.suspensionLeaseReconcile.rawValue, AppLifecyclePolicy.suspensionLeaseReconcileIntervalMs, nil)
    }

    // MARK: - Primary re-election (secondary instances only)
    //
    // See the macOS class's `startPrimaryElectionRetry()` for the full "why
    // does a secondary need this at all" rationale -- unchanged here, only
    // `Timer`/`RunLoop.main` becomes `SetTimer`/`WM_TIMER`.

    private func startPrimaryElectionRetry() {
        guard let hwnd = trayWindow, !primaryElectionTimerRunning else { return }
        primaryElectionTimerRunning = true
        SetTimer(hwnd, TimerId.primaryElectionRetry.rawValue, AppLifecyclePolicy.primaryElectionRetryIntervalMs, nil)
        Logger.shared.log("Secondary instance: polling every \(AppLifecyclePolicy.primaryElectionRetryIntervalMs / 1000)s to take over as primary if the current primary dies (otherwise this process would be left with no tray icon and no window).", level: "INFO")
    }

    private func stopPrimaryElectionRetry() {
        guard primaryElectionTimerRunning, let hwnd = trayWindow else { return }
        KillTimer(hwnd, TimerId.primaryElectionRetry.rawValue)
        primaryElectionTimerRunning = false
    }

    private func primaryElectionRetryTick() {
        guard InstanceLock.shared.retryAcquire() else { return }
        stopPrimaryElectionRetry()
        Logger.shared.log("Promoted to PRIMARY instance: the previous primary released the instance lock (it exited, crashed or was killed). Installing the tray icon so this process regains a user-facing way to clear annotations and quit.", level: "INFO")
        setupTrayIcon()
    }

    /// See the macOS class's `startPrimaryLockWatchdog()` for why the
    /// primary needs its own repair poll, distinct from the secondary's
    /// election poll -- identical reasoning, `SetTimer`/`WM_TIMER` in place
    /// of `Timer`/`RunLoop.main`.
    private func startPrimaryLockWatchdog() {
        guard let hwnd = trayWindow, !primaryLockWatchdogRunning else { return }
        primaryLockWatchdogRunning = true
        SetTimer(hwnd, TimerId.primaryLockWatchdog.rawValue, AppLifecyclePolicy.primaryElectionRetryIntervalMs, nil)
    }

    private func stopPrimaryLockWatchdog() {
        guard primaryLockWatchdogRunning, let hwnd = trayWindow else { return }
        KillTimer(hwnd, TimerId.primaryLockWatchdog.rawValue)
        primaryLockWatchdogRunning = false
    }

    private func primaryLockWatchdogTick() {
        guard InstanceLock.shared.revalidatePrimaryLock() == .relinquishToPathOwner else { return }
        stopPrimaryLockWatchdog()
        tearDownTrayIcon()
        Logger.shared.log("Demoted from PRIMARY instance: another process owns the repaired instance lock. Removed this process's tray icon and resumed secondary election polling.", level: "WARN")
        startPrimaryElectionRetry()
    }

    // MARK: - Termination
    //
    // See the macOS class's "Termination" section for the full
    // user-vs-internal rationale this mirrors throughout.

    /// Same contract as the macOS class's static method of the same name:
    /// call immediately before `AppHost.terminate()` from every path that is
    /// NOT a user quit. `AppHost.terminate()` on Windows forwards to
    /// `AppDelegate.current`, so this simply looks that instance up and sets
    /// its flag -- see the macOS twin for why a missing delegate only WARNs
    /// rather than failing.
    public static func markInternalTermination(reason: String) {
        guard let delegate = current else {
            Logger.shared.log("markInternalTermination(\(reason)): no AppDelegate available; termination will be treated as user-initiated.", level: "WARN")
            return
        }
        delegate.isInternalTermination = true
        Logger.shared.log("Internal termination path: \(reason). This process will terminate WITHOUT broadcasting quit to sibling instances.", level: "INFO")
    }

    /// Entry point for `AppHost.terminate()`. SAFE TO CALL FROM ANY THREAD:
    /// hops to the UI thread via `runOnUIThread(_:)` when necessary (the
    /// `SetConsoleCtrlHandler` callback in Launcher/main.swift always runs
    /// off the UI thread), mirroring the implicit main-thread requirement
    /// `NSApp.terminate` carries on the macOS branch -- `AppHost.terminate()`
    /// there is called AFTER an explicit `DispatchQueue.main`/`AppHost
    /// .runOnMain` hop at every existing call site, so giving this one the
    /// same "just works from anywhere" contract keeps the two platforms'
    /// call sites symmetric.
    func terminate() {
        runOnUIThread { [weak self] in
            self?.requestTermination()
        }
    }

    /// The Windows analogue of the macOS class's
    /// `applicationShouldTerminate(_:)` choke point: every termination path
    /// funnels through here via `terminate()` above. See that method's doc
    /// comment for the full user-vs-internal reasoning, which this restates
    /// rather than departs from.
    private func requestTermination() {
        if isInternalTermination {
            // Lifecycle shutdown -- already accounted for by whoever set the
            // flag (MCPServer's transport-failure path, or
            // Launcher/main.swift's console-control handler). Proceed
            // straight to shutdown: nothing here should delay or
            // second-guess that decision.
            Logger.shared.log("requestTermination: internal/lifecycle shutdown already flagged; terminating this process only, no quit broadcast.", level: "INFO")
            shutdownNow()
            return
        }

        // Reaching here with the flag still false means `terminate()` was
        // invoked by a path this port does not expect to originate a user
        // quit. The one genuine user-quit path today, the tray menu's
        // "Quit AI Chalkboard" (`quitApp()` below), deliberately does NOT
        // call `terminate()` directly -- it posts a QUIT broadcast, exactly
        // like the macOS status menu's `quitApp()`, and expects the
        // broadcast's own receive handler to call
        // `markInternalTermination(reason:)` before ever reaching here (see
        // `quitApp()`'s doc comment; `InstanceBroadcast` has no Windows
        // implementation yet, which is a tracked gap, not a design choice
        // made here). Fail safe rather than silently skipping the fan-out
        // that gap would otherwise cause: mark and broadcast anyway,
        // mirroring the macOS class's Dock/Cmd-Q branch, so an unanticipated
        // caller still takes sibling instances down with it instead of
        // stranding them.
        isInternalTermination = true
        Logger.shared.log("requestTermination: reached with no internal-termination flag set; broadcasting QUIT before terminating (see doc comment on this method).", level: "WARN")
        InstanceBroadcast.shared.postQuitAll(scopedToLaunchMode: true)
        shutdownNow()
    }

    /// Tears down this process's own tray icon and window, then posts
    /// `WM_QUIT` so Launcher/main.swift's message loop exits and the process
    /// terminates. The Windows analogue of `NSApp.terminate`'s effect once
    /// `applicationShouldTerminate` returns `.terminateNow` -- there is no
    /// `applicationWillTerminate` callback to log from separately here, so
    /// this method's own log line plays that role.
    private func shutdownNow() {
        Logger.shared.log("AppDelegate (Windows): shutting down cleanly.", level: "INFO")
        tearDownTrayIcon()
        if let hwnd = trayWindow {
            DestroyWindow(hwnd)
        } else {
            PostQuitMessage(0)
        }
    }

    // MARK: - UI-thread marshaling

    /// Runs `work` on the UI thread: inline if already there, otherwise
    /// marshaled across via a posted window message -- the Windows analogue
    /// of `MainThread.async` (see that type's doc comment for why "run
    /// inline when already on the target thread" matters: it is what keeps
    /// a call made FROM the UI thread from being deferred by a full message-
    /// loop turn). Used by `AppHost.runOnMain` and by `terminate()` above.
    ///
    /// MECHANISM: boxes the closure in a small reference type, hands
    /// `Unmanaged.passRetained` ownership of it across the process's own
    /// message queue as the posted message's `lParam`, and releases it (via
    /// `takeRetainedValue`) when the UI thread's WndProc handles
    /// `runOnUIThreadMessage`. `PostMessageW` is the documented
    /// cross-thread-safe way to hand work back to a specific window's owning
    /// thread; doing the equivalent HWND/timer/tray work directly from a
    /// foreign thread would not be.
    ///
    /// NARROW STARTUP RACE, documented rather than engineered around: if
    /// this is called from a foreign thread before `createTrayWindow()` has
    /// produced a `trayWindow` (only reachable if something calls
    /// `AppHost.terminate()` in the few instructions between `launch()`
    /// starting and that window existing), there is no HWND to post to yet.
    /// This runs `work` inline on the CALLING thread in that case instead of
    /// silently dropping it -- an honest "best effort, no thread-safety
    /// guarantee" fallback for a startup window measured in microseconds,
    /// not a claim that this method is safe to call before `launch()` runs.
    func runOnUIThread(_ work: @escaping () -> Void) {
        if GetCurrentThreadId() == Self.mainThreadId {
            work()
            return
        }
        guard let hwnd = trayWindow else {
            work()
            return
        }
        let box = Unmanaged.passRetained(ClosureBox(work))
        let payload = LPARAM(Int(bitPattern: UInt(bitPattern: box.toOpaque())))
        guard PostMessageW(hwnd, Self.runOnUIThreadMessage, 0, payload) else {
            // Posting failed (e.g. the message queue is already gone during
            // shutdown). Release what we retained above and fall back to
            // running inline rather than leaking the box or dropping the
            // work silently.
            box.release()
            work()
            return
        }
    }

    private final class ClosureBox {
        let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    // MARK: - Tray window / icon

    /// Creates a hidden, message-only (`HWND_MESSAGE`-parented) window that
    /// exists purely to own the tray icon and receive its callback,
    /// `WM_COMMAND`, and `WM_TIMER` messages. Message-only windows never
    /// appear in the taskbar or Alt-Tab and need no `ShowWindow` call at
    /// all -- the direct Windows analogue of the invisible `NSStatusItem`
    /// plumbing on the macOS side (a status item's backing window is not
    /// something that class manages directly either).
    private func createTrayWindow() {
        let hInstance = GetModuleHandleW(nil)

        Self.windowClassName.withCString(encodedAs: UTF16.self) { classNamePtr in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = chalkboardAppDelegateWndProc
            wc.hInstance = hInstance
            wc.lpszClassName = classNamePtr
            // No failure check: RegisterClassW fails with
            // ERROR_CLASS_ALREADY_EXISTS if this process ever calls this
            // twice (it doesn't -- `launch()` runs once), and any other
            // failure surfaces immediately below when CreateWindowExW itself
            // fails to find the class.
            RegisterClassW(&wc)
        }

        let hwnd: HWND? = Self.windowClassName.withCString(encodedAs: UTF16.self) { classNamePtr in
            "AI Chalkboard".withCString(encodedAs: UTF16.self) { titlePtr in
                CreateWindowExW(
                    0, classNamePtr, titlePtr, 0,
                    0, 0, 0, 0,
                    HWND(bitPattern: -3) /* HWND_MESSAGE */, nil, hInstance,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }

        guard let hwnd else {
            Logger.shared.log("AppDelegate (Windows): failed to create the tray message window (Win32 error \(GetLastError())). Tray icon and menu will be unavailable in this process; MCP server and overlay continue running normally.", level: "ERROR")
            return
        }
        trayWindow = hwnd
    }

    /// The status-bar item is gated to the primary instance only (see
    /// InstanceLock). In MCP mode the tray icon is the ONLY remaining UI
    /// affordance to Clear/Quit, mirroring the macOS class's
    /// `setupStatusMenu()` exactly.
    private func setupTrayIcon() {
        guard let hwnd = trayWindow, !trayIconAdded else { return }

        // Owning the tray icon and owning the instance lock are the same
        // role, so the lock-integrity poll starts here rather than at
        // either call site -- see the macOS class's `setupStatusMenu()` for
        // why. Idempotent.
        startPrimaryLockWatchdog()

        var data = NOTIFYICONDATAW()
        data.cbSize = UInt32(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        data.uFlags = UInt32(NIF_ICON) | UInt32(NIF_MESSAGE) | UInt32(NIF_TIP)
        data.uCallbackMessage = Self.trayCallbackMessage
        data.hIcon = LoadIconW(nil, Self.systemIconName(Self.idiApplication))
        Self.copyToFixedWideBuffer("AI Chalkboard (MCP Overlay Agent)", into: &data.szTip)

        trayIconAdded = Shell_NotifyIconW(DWORD(NIM_ADD), &data)
        if trayIconAdded {
            Logger.shared.log("AppDelegate (Windows): tray icon installed.", level: "INFO")
        } else {
            Logger.shared.log("AppDelegate (Windows): Shell_NotifyIconW(NIM_ADD) failed (Win32 error \(GetLastError())). This process has no user-facing control surface until the next successful retry.", level: "WARN")
        }

        // Picks up whatever capture-debug state is already live -- relevant
        // when THIS process is promoted to primary mid-session, exactly as
        // the macOS class's identical call documents.
        applyCaptureIndicator(visible: OverlayWindowController.shared.isCaptureVisible)
    }

    private func tearDownTrayIcon() {
        guard trayIconAdded, let hwnd = trayWindow else { return }
        var data = NOTIFYICONDATAW()
        data.cbSize = UInt32(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        trayIconAdded = false
    }

    /// Windows analogue of the macOS class's `applyCaptureIndicator(visible:)`
    /// -- see that method's doc comment for WHY a glanceable, always-visible
    /// signal matters here (capture-debug mode's failure case is "left on and
    /// forgotten").
    ///
    /// NO CUSTOM ICON ASSET: this SwiftPM Windows target has no `.ico`
    /// resource-embedding pipeline set up yet, so unlike the macOS branch's
    /// `contentTintColor` recolor, the on/off signal here is carried by
    /// swapping between two STOCK Win32 icons (`IDI_APPLICATION` /
    /// `IDI_WARNING`) plus the tooltip text. A dedicated embedded icon would
    /// be a strictly nicer follow-up once this app ships an `.ico` resource;
    /// stock icons are an honest, always-available substitute in the
    /// meantime, not a permanent design choice.
    ///
    /// TOOLTIP TRUNCATION: `NOTIFYICONDATAW.szTip` holds at most 128 WCHAR
    /// including the terminator. The capture-debug-ON tooltip text below is
    /// longer than that budget and is therefore silently truncated by
    /// `copyToFixedWideBuffer` -- an honest platform limit (the Win32 tray
    /// tooltip field itself is fixed-size), unlike the macOS branch's
    /// `NSStatusItem.button.toolTip`, which is an unbounded `String`.
    private func applyCaptureIndicator(visible: Bool) {
        guard trayIconAdded, let hwnd = trayWindow else { return }
        var data = NOTIFYICONDATAW()
        data.cbSize = UInt32(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        data.uFlags = UInt32(NIF_ICON) | UInt32(NIF_TIP)
        data.hIcon = LoadIconW(nil, visible ? Self.systemIconName(Self.idiWarning) : Self.systemIconName(Self.idiApplication))
        let tooltip = visible
            ? "AI Chalkboard (MCP Overlay Agent) — CAPTURE DEBUG MODE ON: every annotation renders on every app. Auto-reverts in \(Int(OverlayWindowController.captureAutoRevertInterval / 60)) min if not renewed."
            : "AI Chalkboard (MCP Overlay Agent)"
        Self.copyToFixedWideBuffer(tooltip, into: &data.szTip)
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
    }

    /// Writes as much of `string` as fits (UTF-16, NUL-terminated) into a
    /// fixed-size C `WCHAR` array represented in Swift as a tuple -- the
    /// shape `NOTIFYICONDATAW.szTip` and similar WinSDK fields take. Generic
    /// over `T` so it works for that field without hard-coding its exact
    /// tuple arity (128 elements today; this stays correct if a future SDK
    /// changes it).
    private static func copyToFixedWideBuffer<T>(_ string: String, into buffer: inout T) {
        withUnsafeMutableBytes(of: &buffer) { raw in
            let capacity = raw.count / MemoryLayout<WCHAR>.size
            guard capacity > 0 else { return }
            let ptr = raw.bindMemory(to: WCHAR.self)
            let scalars = Array(string.utf16.prefix(capacity - 1))
            for i in 0..<scalars.count { ptr[i] = WCHAR(scalars[i]) }
            ptr[scalars.count] = 0
        }
    }

    // MARK: - Tray context menu

    /// Windows analogue of the macOS class's `makeStatusMenu()` +
    /// `menuNeedsUpdate(_:)` combined into one call, since a Win32 popup
    /// menu is rebuilt fresh on every open rather than mutated in place --
    /// there is no persistent `NSMenu` here to keep item references into,
    /// so the "current app" title and the checkmark are simply computed at
    /// build time instead of patched in by a delegate callback.
    private func showTrayMenu() {
        guard let hwnd = trayWindow, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }

        // Scoped clear FIRST, matching the macOS menu's ordering and the
        // same "+ Global" wording -- see that menu's `clearActive` item for
        // why the wording is load-bearing, not decoration.
        let appName = ActiveAppTracker.shared.currentAppName
        let clearTitle = appName.map { "Clear Annotations for \($0) + Global" } ?? "Clear Annotations for Current App + Global"
        appendMenuItem(menu, id: .clearActiveApp, title: clearTitle)
        appendMenuItem(menu, id: .clearEverything, title: "Clear Everything (All Apps)")
        AppendMenuW(menu, UInt32(MF_SEPARATOR), 0, nil)
        appendMenuItem(menu, id: .toggleCaptureVisible, title: "Capture Debug Mode", checked: OverlayWindowController.shared.isCaptureVisible)
        AppendMenuW(menu, UInt32(MF_SEPARATOR), 0, nil)
        appendMenuItem(menu, id: .quit, title: "Quit AI Chalkboard")

        var cursor = POINT()
        GetCursorPos(&cursor)

        // Required Win32 idiom for a tray icon's popup menu: without
        // bringing this window to the foreground first, TrackPopupMenu's
        // implicit mouse capture can fail to dismiss the menu when the user
        // clicks away from it.
        SetForegroundWindow(hwnd)
        TrackPopupMenu(menu, UInt32(TPM_RIGHTBUTTON), cursor.x, cursor.y, 0, hwnd, nil)
        // The other half of that same idiom: post a harmless message to this
        // window so it reliably receives the notification the menu was
        // dismissed (a documented workaround for a long-standing shell
        // quirk where the menu can otherwise stick around).
        PostMessageW(hwnd, UInt32(WM_NULL), 0, 0)
    }

    private func appendMenuItem(_ menu: HMENU, id: MenuCommand, title: String, checked: Bool = false) {
        var flags = UInt32(MF_STRING)
        if checked { flags |= UInt32(MF_CHECKED) }
        _ = title.withCString(encodedAs: UTF16.self) { wide in
            AppendMenuW(menu, flags, UINT_PTR(id.rawValue), wide)
        }
    }

    private func handleCommand(wParam: WPARAM) {
        let commandId = UInt32(truncatingIfNeeded: wParam) & 0xFFFF
        switch MenuCommand(rawValue: commandId) {
        case .clearActiveApp: clearAnnotationsForActiveApp()
        case .clearEverything: clearEverything()
        case .toggleCaptureVisible: toggleCaptureVisible()
        case .quit: quitApp()
        case nil: break
        }
    }

    private func handleTimer(id: WPARAM) {
        switch TimerId(rawValue: UINT_PTR(id)) {
        case .primaryElectionRetry: primaryElectionRetryTick()
        case .primaryLockWatchdog: primaryLockWatchdogTick()
        case .suspensionLeaseReconcile: _ = SuspensionLeaseCoordinator.shared.reconcile()
        case nil: break
        }
    }

    /// Dispatch target for `chalkboardAppDelegateWndProc` below, once it has
    /// resolved the `HWND` back to `self`. Runs entirely on the UI thread by
    /// construction (it is only ever reached via the message pump).
    fileprivate func handleWindowMessage(hwnd: HWND, message: UInt32, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch message {
        case Self.trayCallbackMessage:
            // The low word of lParam carries the originating mouse message
            // (WM_RBUTTONUP, WM_LBUTTONUP, ...) for the classic
            // NOTIFYICONDATA shape used here. Opening the menu on a LEFT
            // click too, in addition to the spec'd right click, is a
            // deliberate small addition beyond a literal reading of "right-
            // click context menu": this tray icon is the sole control
            // surface in MCP mode, and every mainstream Windows tray app
            // opens its menu on either button for exactly that reason.
            let mouseEvent = UInt32(truncatingIfNeeded: lParam) & 0xFFFF
            if mouseEvent == UInt32(WM_RBUTTONUP) || mouseEvent == UInt32(WM_LBUTTONUP) || mouseEvent == UInt32(WM_CONTEXTMENU) {
                showTrayMenu()
            }
            return 0

        case UInt32(WM_COMMAND):
            handleCommand(wParam: wParam)
            return 0

        case UInt32(WM_TIMER):
            handleTimer(id: wParam)
            return 0

        case Self.runOnUIThreadMessage:
            // `LPARAM` is `Int64`, distinct from plain `Int` even though both
            // are 64-bit here -- `UInt(bitPattern:)` only overloads for `Int`
            // (and for pointer types), not arbitrary fixed-width integers, so
            // the `Int64 -> Int` step below is required, not decorative.
            if let raw = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam))) {
                Unmanaged<ClosureBox>.fromOpaque(raw).takeRetainedValue().work()
            }
            return 0

        case UInt32(WM_DESTROY):
            // Reached only via shutdownNow()'s DestroyWindow(hwnd) call.
            // Posting WM_QUIT here (rather than from shutdownNow() directly)
            // is the standard Win32 idiom -- it guarantees the message loop
            // sees it only after this window has genuinely finished being
            // torn down.
            PostQuitMessage(0)
            return 0

        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    // Every menu action BROADCASTS rather than acting locally -- see the
    // macOS class's identical block comment above its own action methods for
    // the full "why": the same Claude-Desktop-spawns-two-processes,
    // AnnotationStore-is-per-process reasoning applies unchanged on Windows.
    // `InstanceBroadcast` itself has no Windows implementation yet (a
    // tracked gap in a different file, outside this port's scope); these
    // methods are written against its existing cross-platform-neutral API
    // surface so they start working the moment that lands.

    private func clearAnnotationsForActiveApp() {
        let active = ActiveAppTracker.shared.currentApp
        InstanceBroadcast.shared.postClear(scope: .active, appId: active.bundleId, appName: active.name)
    }

    private func clearEverything() {
        InstanceBroadcast.shared.postClear(scope: .all, appId: nil, appName: nil)
    }

    private func toggleCaptureVisible() {
        let newValue = !OverlayWindowController.shared.isCaptureVisible
        InstanceBroadcast.shared.postSetCaptureVisible(newValue)
    }

    /// Posts a QUIT broadcast rather than terminating locally, exactly like
    /// the macOS status menu's `quitApp()` -- see `requestTermination()`'s
    /// doc comment above for how the broadcast is expected to loop back into
    /// an actual termination once `InstanceBroadcast` has a Windows port.
    private func quitApp() {
        InstanceBroadcast.shared.postQuitAll()
    }
}

/// Free function, not a method: Win32's `WNDPROC` is a plain
/// `@convention(c)` function pointer, and Swift only allows a global
/// function with no captured context to satisfy that -- an instance method
/// or closure capturing `self` cannot be used here. This resolves the
/// `HWND` back to the owning `AppDelegate` (stashed in `GWLP_USERDATA` on
/// `WM_NCCREATE`, the earliest message a window receives, before
/// `CreateWindowExW` even returns) and forwards every other message to
/// `AppDelegate.handleWindowMessage(hwnd:message:wParam:lParam:)`.
private func chalkboardAppDelegateWndProc(_ hwnd: HWND?, _ message: UInt32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }

    if message == UInt32(WM_NCCREATE) {
        // See the identical `Int64 -> Int` note on the runOnUIThreadMessage
        // case above -- `LPARAM`/`LONG_PTR` are `Int64`, and `UInt(bitPattern:)`
        // has no overload for that, only for `Int`.
        if let createParamsPointer = UnsafeMutablePointer<CREATESTRUCTW>(bitPattern: UInt(bitPattern: Int(lParam))),
           let instancePointer = createParamsPointer.pointee.lpCreateParams {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: instancePointer)))
        }
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }

    let stored = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
    guard stored != 0, let instancePointer = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(stored))) else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(instancePointer).takeUnretainedValue()
    return delegate.handleWindowMessage(hwnd: hwnd, message: message, wParam: wParam, lParam: lParam)
}

#endif
