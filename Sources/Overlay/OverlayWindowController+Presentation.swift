import Foundation
import AppKit

extension OverlayWindowController {
    /// Whether this process has temporarily ordered all overlay windows out.
    /// Kept as a synchronous query because MCP diagnostics must describe the
    /// state that is already in effect, not a pending main-queue mutation.
    public var isAnnotationsSuspended: Bool {
        MainThread.sync { annotationsSuspended }
    }

    /// Requested capture-debug mode. This controls rendering and the legacy
    /// NSWindow sharing preference, not an external capture tool's filters.
    public var isCaptureVisible: Bool {
        captureLock.lock(); defer { captureLock.unlock() }
        return _captureVisible
    }

    /// The `sharingType` newly created windows must be born with, so that a
    /// `rebuildOverlayWindows()` triggered by anything else (display connected,
    /// resolution change) does not silently revert the user's choice.
    // internal (not private): OverlayWindowController.swift's
    // createOverlayWindow(for:screenId:) reads this when birthing a window.
    var desiredSharingType: NSWindow.SharingType {
        return isCaptureVisible ? .readOnly : .none
    }

    /// Turns the capture-debug request on/off across every overlay window.
    ///
    /// APPROACH: assigns `sharingType` on the LIVE windows -- no teardown, no
    /// `rebuildOverlayWindows()`. This was verified empirically rather than
    /// assumed (see the probe in this change's notes): a window was created with
    /// `.none`, ordered onto the window server, then flipped at runtime, and the
    /// WINDOW SERVER'S OWN copy of the flag -- `kCGWindowSharingState` read back
    /// via `CGWindowListCopyWindowInfo`, not just the Cocoa-side property --
    /// tracked every flip within one run-loop turn (0 -> 1 -> 0 -> 1). So the
    /// value is not latched at window-creation time and recreation is
    /// unnecessary. Avoiding the rebuild matters: a rebuild closes and reopens
    /// every overlay, which flickers and briefly drops the annotations off
    /// screen, on what is meant to be an instant debugging toggle.
    ///
    /// The early return when the value is unchanged is load-bearing: this is
    /// driven by a distributed notification that is also delivered back to the
    /// process that posted it, so the no-op guard is what keeps the echo free.
    @discardableResult
    public func setCaptureVisible(_ visible: Bool) -> Bool {
        // MCP success must mean the local AppKit state has already changed.
        // `MainThread.sync` executes inline for menu/broadcast delivery and
        // otherwise waits for the main run loop; it therefore avoids both the
        // old acknowledgement race and a main-thread self-deadlock.
        MainThread.sync {
            captureLock.lock()
            let changed = (_captureVisible != visible)
            _captureVisible = visible
            captureLock.unlock()

            // Renewed on EVERY request for `true`, including a same-value
            // renewal where the mode was already on -- not gated behind
            // `changed` below. A caller re-requesting capture-debug mode
            // mid-session means "I'm still debugging, push the deadline out".
            scheduleCaptureAutoRevert(visible: visible)

            guard changed else { return changed }

            let sharingType: NSWindow.SharingType = visible ? .readOnly : .none
            // `overlayWindows` is a flat array now (one entry per real
            // display), so each window is visited exactly once here.
            for window in overlayWindows {
                window.sharingType = sharingType
            }

            // This intentionally runs synchronously with the sharing-type
            // mutation. A caller may safely inspect capture/debug state after
            // this method returns; no extra main-run-loop turn is required.
            refreshViewsNow()

            Logger.shared.log(
                "OverlayWindowController: capture-debug request set to \(visible) (sharingType = \(visible ? ".readOnly" : ".none")) on \(overlayWindows.count) window reference(s), applied live without rebuilding. External capture tools retain independent app/window filters, so final inclusion is not guaranteed.",
                level: "INFO"
            )

            onCaptureVisibleChanged?(visible)
            return changed
        }
    }

    /// Temporarily removes or restores this process's overlay windows without
    /// mutating `AnnotationStore`. Suspending makes every full-screen overlay
    /// disappear from WindowServer's on-screen list, which is a practical
    /// workaround for click dispatchers that reject a point merely because an
    /// overlay window is present. It is not simultaneous visual click-through:
    /// annotations are absent until a later resume.
    ///
    /// This intentionally reapplies the requested ordering even on a same
    /// value call. The state transition is idempotent, while re-ordering makes
    /// a repeated suspend/resume self-heal after a display rebuild or another
    /// AppKit ordering event.
    ///
    /// Delegates to the generation-aware overload rather than hand-rolling the
    /// transition. Doing it by hand set `annotationsSuspended = false` and then
    /// called the private no-arg `refreshViewsNow()`, which fails CLOSED (orders
    /// every window out) while `annotationsSuspensionGeneration` is still nil --
    /// so a caller arriving before the first durable generation was applied
    /// would be told "resumed" while every overlay stayed off screen. Reusing
    /// the one real implementation makes that divergence unrepresentable.
    @discardableResult
    public func setAnnotationsSuspended(_ suspended: Bool) -> Bool {
        MainThread.sync {
            setAnnotationsSuspended(suspended, generation: annotationsSuspensionGeneration ?? 0)
        }
    }

    /// Applies the only authoritative presentation decision: one read from
    /// the durable lease registry.  This is intentionally separate from the
    /// unversioned compatibility method above, which is used only by older
    /// in-process tests.  Calls with an older generation are ignored on the
    /// main thread, where window ordering occurs, so queue reordering cannot
    /// resurrect an overlay after a later suspension.
    @discardableResult
    public func setAnnotationsSuspended(_ suspended: Bool, generation: UInt64) -> Bool {
        MainThread.sync {
            if let applied = annotationsSuspensionGeneration, generation < applied {
                return false
            }
            annotationsSuspensionGeneration = generation
            let changed = annotationsSuspended != suspended
            annotationsSuspended = suspended

            if suspended {
                orderAllOverlayWindowsOut()
            } else {
                refreshViewsNow()
            }

            Logger.shared.log(
                "OverlayWindowController: applied durable annotations suspension generation=\(generation) suspended=\(suspended) on \(overlayWindows.count) overlay window reference(s).",
                level: "INFO"
            )
            return changed
        }
    }

    /// Storage/lock failures are deliberately more conservative than ordinary
    /// generation changes: the only safe action is to remove our windows.
    /// This does not advance the durable generation, so the next successful
    /// reconciliation (including one with the same generation) can restore
    /// the registry's actual decision.
    public func forceAnnotationsSuspendedFailClosed() {
        MainThread.sync {
            annotationsSuspended = true
            orderAllOverlayWindowsOut()
            Logger.shared.log("OverlayWindowController: suspension registry unavailable; ordered overlays out fail-closed.", level: "ERROR")
        }
    }

    /// Invalidates any pending auto-revert timer and, if `visible` is true,
    /// starts a fresh one. MAIN-THREAD-ONLY (see `captureAutoRevertTimer`'s
    /// doc comment).
    ///
    /// On fire, this BROADCASTS the revert (`InstanceBroadcast
    /// .postSetCaptureVisible(false)`) rather than flipping `_captureVisible`
    /// locally, matching every other state change in this app ("every
    /// instance owns its own overlay windows" -- see `AppDelegate`'s menu
    /// actions). Claude Desktop runs two `AIChalkboard --mcp` processes per
    /// config entry, each with its own timer started from the same broadcast
    /// that turned capture-debug mode on, so both fire within moments of each
    /// other regardless -- but broadcasting keeps that synchronization exact
    /// instead of relying on the coincidence, and reuses the same code path
    /// (and log line) as a manual toggle-off.
    private func scheduleCaptureAutoRevert(visible: Bool) {
        captureAutoRevertTimer?.invalidate()
        captureAutoRevertTimer = nil

        guard visible else { return }

        let interval = Self.captureAutoRevertInterval
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Logger.shared.log(
                "OverlayWindowController: capture-debug mode auto-reverting to OFF after \(Int(interval))s with no renewal (call set_capture_visible(true) again if still debugging).",
                level: "WARN"
            )
            InstanceBroadcast.shared.postSetCaptureVisible(false)
        }
        // `.common` keeps the timer firing while a menu is tracking or a
        // window is being live-resized, matching the other main-run-loop
        // timers in this app (see `AppDelegate`'s election/watchdog timers).
        RunLoop.main.add(timer, forMode: .common)
        captureAutoRevertTimer = timer
    }

    /// Single source of truth for "what should currently be painted on
    /// `screenId`" -- used by `OverlayView.draw(_:)` (what to paint) and by
    /// the diagnostics in `OverlayWindowController+Diagnostics`.
    ///
    /// `refreshViewsNow(under:)` needs only the EMPTINESS of this answer, and
    /// asks `hasCurrentlyVisibleAnnotations(forScreenId:)` below instead. The
    /// two share the annotation-level predicate they are ultimately built on
    /// (`AnnotationStore.isVisible(_:onScreen:forApp:)`), which is what makes
    /// "what to paint" and "does the window belong on screen at all"
    /// impossible to answer inconsistently with each other.
    public func currentlyVisibleAnnotations(forScreenId screenId: String) -> [Annotation] {
        // Suspension is an explicit presentation override. Returning no
        // visible annotations here keeps OverlayView, input-policy diagnostics,
        // and presentation checks truthful while the retained store remains
        // completely unchanged for resume.
        if isAnnotationsSuspended {
            return []
        }
        if isCaptureVisible {
            return AnnotationStore.shared.getForScreen(screenId)
        }
        return AnnotationStore.shared.getForScreen(screenId, visibleForApp: ActiveAppTracker.shared.currentAppId)
    }

    /// The emptiness half of `currentlyVisibleAnnotations(forScreenId:)`,
    /// answered WITHOUT materialising (or z-sorting) the filtered array.
    ///
    /// `refreshViewsNow(under:)` asks this once per screen on every repaint
    /// purely to decide whether that screen's overlay window belongs on
    /// WindowServer's on-screen list -- and `OverlayView.draw(_:)` then
    /// rebuilds the identical array moments later anyway, so building and
    /// sorting it here was pure duplicated work on the repaint path.
    ///
    /// What is duplicated here is only the suspension/capture-visibility
    /// BRANCHING (kept deliberately in lockstep with the method above, and
    /// covered by the same reasoning in its comments); the per-annotation
    /// visibility predicate is NOT duplicated -- both sides bottom out in
    /// `AnnotationStore.isVisible(_:onScreen:forApp:)`.
    func hasCurrentlyVisibleAnnotations(forScreenId screenId: String) -> Bool {
        if isAnnotationsSuspended {
            return false
        }
        if isCaptureVisible {
            // Capture-debug mode paints everything on this screen, so there is
            // no app predicate to apply on either side. It is a short-lived,
            // auto-reverting debug toggle, so the array build that answers this
            // is not on any hot path worth its own store method.
            return !AnnotationStore.shared.getForScreen(screenId).isEmpty
        }
        return AnnotationStore.shared.hasVisibleAnnotations(
            forScreenId: screenId, visibleForApp: ActiveAppTracker.shared.currentAppId
        )
    }

    /// Repaints every overlay AND decides, per screen, whether its window
    /// belongs on screen at all.
    ///
    /// WHY THE WINDOW ITSELF MUST BE ORDERED OUT WHEN THERE IS NOTHING TO
    /// PAINT, not merely left on screen and transparent -- this used to
    /// unconditionally `orderFrontRegardless()` every overlay window at
    /// creation and leave it there for the rest of the process's life,
    /// regardless of whether anything was ever drawn:
    ///
    /// `ignoresMouseEvents = true` (set once, at window creation -- see
    /// `createOverlayWindow`) only affects REAL OS mouse-event delivery: the
    /// window server correctly skips this window and hands a genuine click to
    /// whatever is underneath it. It does nothing for a DIFFERENT class of
    /// query -- "which app's window is topmost at this point" -- answered by
    /// walking the on-screen window list (what `CGWindowListCopyWindowInfo`
    /// reports, and almost certainly what any tool doing its own
    /// click-safety/ownership pre-check against an app allowlist is really
    /// asking, since `ignoresMouseEvents` is not exposed by that API at all).
    /// A window is either on that list or it is not; there is no
    /// "on the list but see-through" state to ask for.
    ///
    /// This app's overlay windows are, by design, full-screen and at
    /// `.statusBar` level specifically so an annotation can sit above the
    /// Dock and the menu bar (see `createOverlayWindow`'s window-level
    /// comment). That means an always-on-screen overlay window is ALWAYS the
    /// topmost thing at every point on every screen -- so a caller doing that
    /// kind of ownership check would conclude every single point on screen
    /// belongs to AI Chalkboard, forever, whether or not an annotation was
    /// ever drawn. That is exactly the bug this fixes: computer-use refused
    /// to click ANYWHERE, including with zero annotations on screen, because
    /// the overlay window was on screen (and therefore "topmost everywhere")
    /// even though it was painting nothing.
    ///
    /// Ordering the window fully off screen when
    /// `hasCurrentlyVisibleAnnotations(forScreenId:)` is false removes it from
    /// that window list too, so an idle AI
    /// Chalkboard -- the common case between draws -- is invisible to that
    /// kind of check, not just harmlessly click-through to it. This does NOT
    /// fix the remaining case where an annotation genuinely IS on screen: the
    /// window still has to cover the full screen to be positionable anywhere
    /// on it, so a topmost-window ownership check still finds AI Chalkboard
    /// covering the whole screen, not just the annotated region, for as long
    /// as that annotation is visible. Shrinking the window to each
    /// annotation's bounding box would be a materially bigger redesign (it
    /// would break screen-spanning free-draw paths/images, and every
    /// draw/move/clear would need its own window resize) and is out of scope
    /// here.
    public func refreshViews() {
        MainThread.async { [weak self] in
            self?.refreshViewsNow()
        }
    }

    /// Main-thread half of `refreshViews()`.  Kept separate so
    /// `presentationStatus(for:)` can synchronously settle the app's own
    /// ordering/repaint work before asking WindowServer what it registered.
    /// This is intentionally not public: callers outside this controller must
    /// retain the ordinary asynchronous repaint behaviour.
    // internal (not private): OverlayWindowController+Diagnostics.swift's
    // presentationStatus(for:) calls this to settle ordering before sampling.
    func refreshViewsNow() {
        precondition(Thread.isMainThread, "Overlay window ordering is AppKit-main-thread-only")
        // No state read is sufficient on its own: a concurrent acquire could
        // persist after the read but before `orderFrontRegardless()`.  The
        // coordinator keeps the registry operation lock across the short
        // AppKit closure below, so an acquire cannot cross that gap.  Before
        // launch reconciliation has installed a durable generation we fail
        // closed and never order a newly-created overlay on screen.
        guard annotationsSuspensionGeneration != nil else {
            orderAllOverlayWindowsOut()
            return
        }
        _ = SuspensionLeaseCoordinator.shared.withPresentationPermit { [weak self] permit in
            self?.refreshViewsNow(under: permit)
        }
    }

    /// Runs only from `withPresentationPermit`, while its durable flock is
    /// held.  Keep this limited to immediate AppKit ordering and invalidation:
    /// calling back into the coordinator here would self-contend on flock.
    private func refreshViewsNow(under permit: SuspensionLeaseSnapshot) {
        precondition(Thread.isMainThread, "Overlay window ordering is AppKit-main-thread-only")
        if permit.error != nil || permit.annotationsSuspended {
            // A failed durable read is deliberately indistinguishable from a
            // live lease at presentation time: both leave every local overlay
            // absent from WindowServer ownership scans.
            if permit.error == nil {
                if let applied = annotationsSuspensionGeneration {
                    if permit.generation >= applied {
                        annotationsSuspensionGeneration = permit.generation
                    }
                } else {
                    annotationsSuspensionGeneration = permit.generation
                }
            }
            annotationsSuspended = true
            orderAllOverlayWindowsOut()
            return
        }

        // A permit that is older than the state this process already applied
        // must not resurrect a window. This should be unreachable for a valid
        // registry, but failing closed is the correct response to a replaced
        // or otherwise non-monotonic state file.
        if let applied = annotationsSuspensionGeneration, permit.generation < applied {
            annotationsSuspended = true
            orderAllOverlayWindowsOut()
            return
        }
        annotationsSuspensionGeneration = permit.generation
        annotationsSuspended = false

        for (window, view) in zip(overlayWindows, overlayViews) {
            let hasContent = hasCurrentlyVisibleAnnotations(forScreenId: view.screenId)
            if hasContent {
                window.orderFrontRegardless()
            } else {
                window.orderOut(nil)
            }
            view.needsDisplay = true
        }
    }

    private func orderAllOverlayWindowsOut() {
        precondition(Thread.isMainThread, "Overlay window ordering is AppKit-main-thread-only")
        // An externally implemented ownership heuristic can only see an
        // absent overlay when *every* process-local window is fully ordered
        // out. Do this before consulting per-app/capture filters: suspension
        // is an absolute presentation override.
        for (window, view) in zip(overlayWindows, overlayViews) {
            window.orderOut(nil)
            view.needsDisplay = true
        }
    }
}
