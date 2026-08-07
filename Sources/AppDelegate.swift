import Foundation
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

        // The overlay is the entire reason the MCP server exists (it's what
        // draw_circle/draw_arrow/etc. actually render into), so it must be set up in
        // BOTH modes, never skipped.
        OverlayWindowController.shared.setup()
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
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "AI Chalkboard Overlay")
            } else {
                button.title = "🎨"
            }
            button.toolTip = "AI Chalkboard (MCP Overlay Agent)"
        }
        
        statusItem?.menu = makeStatusMenu()
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
        // annotations AND every GLOBAL one (`appId == nil`) -- including a
        // `draw_grid`, which the MCP tool documents as global precisely so it
        // SURVIVES app switches. A title that named only the app was a lie
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
        let appId = ActiveAppTracker.shared.currentAppId
        let appName = ActiveAppTracker.shared.currentAppName
        InstanceBroadcast.shared.postClear(scope: .active, appId: appId, appName: appName)
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
