import Foundation

// =============================================================================
// SHARED PRESENTATION POLICY
// =============================================================================
//
// Everything in this top section (and the unguarded `OverlayWindowController`
// extension right below `OverlayPresentationBackend`) is the PLATFORM-NEUTRAL
// presentation state machine: when annotations are suspended versus visible,
// the generation-guarded fail-closed ordering tied to `SuspensionLeaseCoordinator`,
// the capture-debug toggle with its auto-revert and echo suppression, per-app
// filtering (including the deliberate capture-visible bypass), and the
// decision -- on every repaint -- of whether a given screen's window belongs
// on screen at all. None of it may reference AppKit, Darwin, WinSDK, or any
// other platform framework.
//
// This mirrors the split `AnnotationRenderer`/`DrawingContext` already use
// for the DRAWING side of this app (see those two files): a Foundation-only
// algorithm written once, against a small protocol, with exactly one real
// implementation of that protocol per platform. `OverlayPresentationBackend`
// below is that protocol for the PRESENTATION side -- four operations on one
// overlay window: show it, hide it, report whether it is currently shown,
// and set its capture-affinity intent. The macOS conformance (`extension
// NSWindow`, further down) wraps `orderFrontRegardless()`/`orderOut(_:)`/
// `isVisible`/`sharingType`; the Windows conformance (`extension
// WindowsOverlayWindow`) wraps `setVisible(_:)`/`isWindowVisible`/
// `setExcludedFromCapture(_:)`. Actual pixel painting is deliberately NOT one
// of the four operations -- painting is `AnnotationRenderer`'s concern, not
// this file's -- so each platform gets its own small `presentPixels` hook
// instead (see each platform's section for why the two mechanisms differ:
// AppKit's deferred `NSView.draw(_:)` pass on macOS, a synchronous repaint
// here on Windows).
//
// macOS is the battle-tested reference this state machine was extracted
// from, verbatim, comments included; where anything below reads as a policy
// decision rather than a platform mechanism, it is macOS's decision and
// Windows now shares it.

/// The platform primitive the presentation state machine above is built on:
/// order one overlay window on screen, order it off, report whether it is
/// currently on screen, and set its capture-affinity intent. Nothing else --
/// suspension, generations, the capture-debug toggle, per-app filtering, or
/// the on/off decision itself -- belongs in a conformance to this protocol;
/// that is all shared policy living in the `OverlayWindowController`
/// extension immediately below.
public protocol OverlayPresentationBackend: AnyObject {
    /// Displays this window (or reasserts already-displayed state).
    func orderOnScreen()

    /// Removes this window from the window system's on-screen enumeration
    /// entirely -- not merely transparent or click-through. See
    /// `refreshViews()`'s doc comment below for why that distinction is
    /// load-bearing.
    func orderOffScreen()

    /// Whether the window system currently reports this window as on
    /// screen -- an honest read-back, not a cached assumption of the last
    /// `orderOnScreen()`/`orderOffScreen()` call.
    var isOnScreen: Bool { get }

    /// Expresses INTENT -- "include in external capture" vs "exclude from
    /// external capture" -- and lets each backend map that intent onto its
    /// own capture-affinity primitive. See each conformance for the mapping
    /// and its own caveats.
    func setCaptureAffinity(includeInCapture: Bool)
}

extension OverlayWindowController {
    /// Whether this process has temporarily ordered all overlay windows out.
    /// Kept as a synchronous query because MCP diagnostics must describe the
    /// state that is already in effect, not a pending main-queue mutation.
    public var isAnnotationsSuspended: Bool {
        MainThread.sync { annotationsSuspended }
    }

    /// Requested capture-debug mode. This controls rendering and each
    /// backend's capture-affinity primitive (`NSWindow.sharingType` on
    /// macOS, `WDA_EXCLUDEFROMCAPTURE` on Windows), not an external capture
    /// tool's own filters.
    public var isCaptureVisible: Bool {
        captureLock.lock(); defer { captureLock.unlock() }
        return _captureVisible
    }

    /// Turns the capture-debug request on/off across every overlay window.
    ///
    /// APPROACH: assigns capture affinity on the LIVE windows -- no teardown,
    /// no `rebuildOverlayWindows()`. Avoiding the rebuild matters: a rebuild
    /// closes and reopens every overlay, which flickers and briefly drops
    /// the annotations off screen, on what is meant to be an instant
    /// debugging toggle. See `NSWindow.setCaptureAffinity(includeInCapture:)`
    /// below for the empirical verification specific to macOS's mechanism.
    ///
    /// The early return when the value is unchanged is load-bearing: this is
    /// driven by a distributed notification that is also delivered back to
    /// the process that posted it, so the no-op guard is what keeps the echo
    /// free.
    @discardableResult
    public func setCaptureVisible(_ visible: Bool) -> Bool {
        // MCP success must mean the local platform state has already
        // changed. `MainThread.sync` executes inline for menu/broadcast
        // delivery and otherwise waits for this platform's presentation
        // thread (AppKit main thread on macOS, `WindowsUIThread` on
        // Windows); it therefore avoids both the old acknowledgement race
        // and a same-thread deadlock.
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

            // `presentationWindows` is a flat, index-aligned projection (one
            // entry per real display) -- see each platform's own
            // `presentationWindows` doc comment -- so each window is visited
            // exactly once here.
            for (_, window) in presentationWindows {
                window.setCaptureAffinity(includeInCapture: visible)
            }

            // This intentionally runs synchronously with the capture-affinity
            // mutation. A caller may safely inspect capture/debug state after
            // this method returns; no extra presentation-thread turn is
            // required.
            refreshViewsNow()

            Logger.shared.log(
                "OverlayWindowController: capture-debug request set to \(visible) on \(presentationWindows.count) overlay window(s), applied live without rebuilding. External capture tools retain independent app/window filters, so final inclusion is not guaranteed.",
                level: "INFO"
            )

            onCaptureVisibleChanged?(visible)
            return changed
        }
    }

    /// Temporarily removes or restores this process's overlay windows without
    /// mutating `AnnotationStore`. Suspending makes every full-screen overlay
    /// disappear from the window system's on-screen list, which is a
    /// practical workaround for click dispatchers that reject a point merely
    /// because an overlay window is present. It is not simultaneous visual
    /// click-through: annotations are absent until a later resume.
    ///
    /// This intentionally reapplies the requested ordering even on a same
    /// value call. The state transition is idempotent, while re-ordering
    /// makes a repeated suspend/resume self-heal after a display rebuild or
    /// another platform ordering event.
    ///
    /// Delegates to the generation-aware overload rather than hand-rolling
    /// the transition. Doing it by hand set `annotationsSuspended = false`
    /// and then called the private no-arg `refreshViewsNow()`, which fails
    /// CLOSED (orders every window out) while `annotationsSuspensionGeneration`
    /// is still nil -- so a caller arriving before the first durable
    /// generation was applied would be told "resumed" while every overlay
    /// stayed off screen. Reusing the one real implementation makes that
    /// divergence unrepresentable.
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
    /// presentation thread, where window ordering occurs, so queue reordering
    /// cannot resurrect an overlay after a later suspension.
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
                orderAllWindowsOffScreen()
            } else {
                refreshViewsNow()
            }

            Logger.shared.log(
                "OverlayWindowController: applied durable annotations suspension generation=\(generation) suspended=\(suspended) on \(presentationWindows.count) overlay window reference(s).",
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
            orderAllWindowsOffScreen()
            Logger.shared.log("OverlayWindowController: suspension registry unavailable; ordered overlays off screen fail-closed.", level: "ERROR")
        }
    }

    /// What actually happens when the capture-debug auto-revert countdown
    /// elapses with no renewal, common to both platforms' scheduling
    /// mechanisms (`Timer` on macOS, `DispatchWorkItem` on Windows -- see
    /// each platform's own `scheduleCaptureAutoRevert(visible:)`).
    ///
    /// BROADCASTS the revert (`InstanceBroadcast.postSetCaptureVisible(false)`)
    /// rather than flipping `_captureVisible` locally, matching every other
    /// state change in this app ("every instance owns its own overlay
    /// windows" -- see `AppDelegate`'s menu actions). Claude Desktop runs two
    /// `AIChalkboard --mcp` processes per config entry, each with its own
    /// timer/work-item started from the same broadcast that turned
    /// capture-debug mode on, so both fire within moments of each other
    /// regardless -- but broadcasting keeps that synchronization exact
    /// instead of relying on the coincidence, and reuses the same code path
    /// (and log line) as a manual toggle-off.
    private static func performCaptureAutoRevert() {
        let interval = Self.captureAutoRevertInterval
        Logger.shared.log(
            "OverlayWindowController: capture-debug mode auto-reverting to OFF after \(Int(interval))s with no renewal (call set_capture_visible(true) again if still debugging).",
            level: "WARN"
        )
        InstanceBroadcast.shared.postSetCaptureVisible(false)
    }

    /// Single source of truth for "what should currently be painted on
    /// `screenId`" -- used by each platform's paint step (`OverlayView
    /// .draw(_:)` on macOS, `presentPixels(window:screenId:isVisible:)` on
    /// Windows) and by the diagnostics in `OverlayWindowController+Diagnostics`.
    ///
    /// `refreshViewsNow(under:)` needs only the EMPTINESS of this answer, and
    /// asks `hasCurrentlyVisibleAnnotations(forScreenId:)` below instead. The
    /// two share the annotation-level predicate they are ultimately built on
    /// (`AnnotationStore.isVisible(_:onScreen:forApp:)`), which is what makes
    /// "what to paint" and "does the window belong on screen at all"
    /// impossible to answer inconsistently with each other.
    public func currentlyVisibleAnnotations(forScreenId screenId: String) -> [Annotation] {
        // Suspension is an explicit presentation override. Returning no
        // visible annotations here keeps every platform's paint step,
        // input-policy diagnostics, and presentation checks truthful while
        // the retained store remains completely unchanged for resume.
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
    /// purely to decide whether that screen's overlay window belongs on the
    /// window system's on-screen list -- and each platform's paint step then
    /// rebuilds the identical array moments later anyway (on macOS,
    /// asynchronously, the next time AppKit services the dirtied view; on
    /// Windows, synchronously, inside this same repaint pass), so building
    /// and sorting it here was pure duplicated work on the decision path.
    ///
    /// What is duplicated is only the suspension/capture-visibility
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
    /// WHY THE WINDOW ITSELF MUST BE ORDERED OFF SCREEN WHEN THERE IS NOTHING
    /// TO PAINT, not merely left on screen and transparent -- this used to
    /// unconditionally order every overlay window on screen at creation and
    /// leave it there for the rest of the process's life, regardless of
    /// whether anything was ever drawn:
    ///
    /// Each platform's click-through mechanism (`NSWindow.ignoresMouseEvents`
    /// on macOS, `WS_EX_TRANSPARENT` on Windows -- set once, at window
    /// creation) only affects REAL OS mouse-event delivery: the window
    /// system correctly skips this window and hands a genuine click to
    /// whatever is underneath it. It does nothing for a DIFFERENT class of
    /// query -- "which app's window is topmost at this point" -- answered by
    /// walking the on-screen window list (`CGWindowListCopyWindowInfo` on
    /// macOS, `EnumWindows`/`WindowFromPoint` on Windows, and almost
    /// certainly what any tool doing its own click-safety/ownership
    /// pre-check against an app allowlist is really asking, since a
    /// click-through flag is not exposed by that kind of API at all). A
    /// window is either on that list or it is not; there is no "on the list
    /// but see-through" state to ask for.
    ///
    /// This app's overlay windows are, by design, full-screen and at the
    /// highest ordinary window level on each platform specifically so an
    /// annotation can sit above the Dock/taskbar and the menu bar (see each
    /// platform's window-creation code for the level investigation). That
    /// means an always-on-screen overlay window is ALWAYS the topmost thing
    /// at every point on every screen -- so a caller doing that kind of
    /// ownership check would conclude every single point on screen belongs
    /// to AI Chalkboard, forever, whether or not an annotation was ever
    /// drawn. That is exactly the bug this fixes: computer-use refused to
    /// click ANYWHERE, including with zero annotations on screen, because
    /// the overlay window was on screen (and therefore "topmost everywhere")
    /// even though it was painting nothing.
    ///
    /// Ordering the window fully off screen when
    /// `hasCurrentlyVisibleAnnotations(forScreenId:)` is false removes it
    /// from that window list too, so an idle AI Chalkboard -- the common
    /// case between draws -- is invisible to that kind of check, not just
    /// harmlessly click-through to it. This does NOT fix the remaining case
    /// where an annotation genuinely IS on screen: the window still has to
    /// cover the full screen to be positionable anywhere on it, so a
    /// topmost-window ownership check still finds AI Chalkboard covering the
    /// whole screen, not just the annotated region, for as long as that
    /// annotation is visible. Shrinking the window to each annotation's
    /// bounding box would be a materially bigger redesign (it would break
    /// screen-spanning free-draw paths/images, and every draw/move/clear
    /// would need its own window resize) and is out of scope here.
    public func refreshViews() {
        MainThread.async { [weak self] in
            self?.refreshViewsNow()
        }
    }

    /// Main-thread half of `refreshViews()`.  Kept separate so
    /// `presentationStatus(for:)` (both platform conformances) can
    /// synchronously settle the app's own ordering/repaint work before
    /// asking the window system what it registered. This is intentionally
    /// not public: callers outside this controller must retain the ordinary
    /// asynchronous repaint behaviour.
    // internal (not private): OverlayWindowController+Diagnostics.swift's
    // presentationStatus(for:) calls this to settle ordering before sampling.
    func refreshViewsNow() {
        precondition(MainThread.isCurrentUIThread, "Overlay window ordering must run on this platform's presentation thread (AppKit main thread on macOS, WindowsUIThread on Windows).")
        // No state read is sufficient on its own: a concurrent acquire could
        // persist after the read but before the ordering call below.  The
        // coordinator keeps the registry operation lock across the short
        // closure below, so an acquire cannot cross that gap.  Before launch
        // reconciliation has installed a durable generation we fail closed
        // and never order a newly-created overlay on screen.
        guard annotationsSuspensionGeneration != nil else {
            orderAllWindowsOffScreen()
            return
        }
        _ = SuspensionLeaseCoordinator.shared.withPresentationPermit { [weak self] permit in
            self?.refreshViewsNow(under: permit)
        }
    }

    /// Runs only from `withPresentationPermit`, while its durable flock is
    /// held.  Keep this limited to immediate window ordering and
    /// invalidation: calling back into the coordinator here would
    /// self-contend on flock.
    private func refreshViewsNow(under permit: SuspensionLeaseSnapshot) {
        precondition(MainThread.isCurrentUIThread, "Overlay window ordering must run on this platform's presentation thread (AppKit main thread on macOS, WindowsUIThread on Windows).")
        if permit.error != nil || permit.annotationsSuspended {
            // A failed durable read is deliberately indistinguishable from a
            // live lease at presentation time: both leave every local overlay
            // absent from the window system's ownership scans.
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
            orderAllWindowsOffScreen()
            return
        }

        // A permit that is older than the state this process already applied
        // must not resurrect a window. This should be unreachable for a valid
        // registry, but failing closed is the correct response to a replaced
        // or otherwise non-monotonic state file.
        if let applied = annotationsSuspensionGeneration, permit.generation < applied {
            annotationsSuspended = true
            orderAllWindowsOffScreen()
            return
        }
        annotationsSuspensionGeneration = permit.generation
        annotationsSuspended = false

        for (screenId, window) in presentationWindows {
            let hasContent = hasCurrentlyVisibleAnnotations(forScreenId: screenId)
            // Painting is a rendering concern, not a presentation one (see
            // `AnnotationRenderer`/`DrawingContext`), so it is deliberately
            // NOT one of `OverlayPresentationBackend`'s four operations --
            // `presentPixels` is each platform's own hook instead, called
            // here BEFORE the ordering decision below so Windows (which
            // paints synchronously, with no AppKit-style deferred draw pass)
            // never shows a stale frame for an instant between becoming
            // visible and being repainted.
            presentPixels(window: window, screenId: screenId, isVisible: hasContent)
            if hasContent {
                window.orderOnScreen()
            } else {
                window.orderOffScreen()
            }
        }
    }

    private func orderAllWindowsOffScreen() {
        precondition(MainThread.isCurrentUIThread, "Overlay window ordering must run on this platform's presentation thread (AppKit main thread on macOS, WindowsUIThread on Windows).")
        // An externally implemented ownership heuristic can only see an
        // absent overlay when *every* process-local window is fully ordered
        // off screen. Do this before consulting per-app/capture filters:
        // suspension is an absolute presentation override.
        for (screenId, window) in presentationWindows {
            presentPixels(window: window, screenId: screenId, isVisible: false)
            window.orderOffScreen()
        }
    }
}

#if os(macOS)
import AppKit

// `NSWindow` is `open` (system framework), so satisfying `OverlayPresentationBackend`
// (a `public` protocol declared by this module) requires `public` witnesses
// here -- Swift will not let a less-accessible witness satisfy a protocol
// requirement declared at `public` scope, even though nothing outside this
// module is expected to actually use the conformance. This does not widen
// what NSWindow's OWN API surface exposes; it only adds these four members.
extension NSWindow: OverlayPresentationBackend {
    public func orderOnScreen() {
        orderFrontRegardless()
    }

    public func orderOffScreen() {
        orderOut(nil)
    }

    public var isOnScreen: Bool {
        isVisible
    }

    /// APPROACH: assigns `sharingType` on the LIVE window -- no teardown, no
    /// `rebuildOverlayWindows()`. This was verified empirically rather than
    /// assumed (see the probe in this change's notes): a window was created
    /// with `.none`, ordered onto the window server, then flipped at
    /// runtime, and the WINDOW SERVER'S OWN copy of the flag --
    /// `kCGWindowSharingState` read back via `CGWindowListCopyWindowInfo`,
    /// not just the Cocoa-side property -- tracked every flip within one
    /// run-loop turn (0 -> 1 -> 0 -> 1). So the value is not latched at
    /// window-creation time and recreation is unnecessary.
    public func setCaptureAffinity(includeInCapture: Bool) {
        sharingType = includeInCapture ? .readOnly : .none
    }
}

extension OverlayWindowController {
    /// The `sharingType` newly created windows must be born with, so that a
    /// `rebuildOverlayWindows()` triggered by anything else (display connected,
    /// resolution change) does not silently revert the user's choice.
    // internal (not private): OverlayWindowController.swift's
    // createOverlayWindow(for:screenId:) reads this when birthing a window.
    var desiredSharingType: NSWindow.SharingType {
        return isCaptureVisible ? .readOnly : .none
    }

    /// A flat, index-aligned projection over `overlayWindows`/`overlayViews`
    /// (one entry per real display) -- see `OverlayWindowController.swift`'s
    /// doc comment on those two arrays for the index-alignment invariant
    /// this relies on. Because it is flat, not nested/dictionary-keyed, each
    /// window is visited exactly once by the shared presentation state
    /// machine above.
    private var presentationWindows: [(screenId: String, window: NSWindow)] {
        zip(overlayViews, overlayWindows).map { view, window in (screenId: view.screenId, window: window) }
    }

    /// Marks the paired `OverlayView` dirty so AppKit's own deferred-draw
    /// pass (`OverlayView.draw(_:)`) repaints it from
    /// `currentlyVisibleAnnotations(forScreenId:)` on the next display cycle
    /// -- the actual pixel painting is NOT done here, or anywhere in this
    /// file; see `AnnotationRenderer`/`DrawingContext`. `isVisible` is
    /// unused: the view is marked dirty unconditionally, regardless of
    /// whether the window is being ordered on or off screen.
    private func presentPixels(window: NSWindow, screenId: String, isVisible: Bool) {
        if let index = overlayWindows.firstIndex(where: { $0 === window }) {
            overlayViews[index].needsDisplay = true
        }
    }

    /// Invalidates any pending auto-revert timer and, if `visible` is true,
    /// starts a fresh one. MAIN-THREAD-ONLY (see `captureAutoRevertTimer`'s
    /// doc comment on `OverlayWindowController`). See
    /// `performCaptureAutoRevert()` above for what actually happens when
    /// this fires, and why it broadcasts rather than mutating local state
    /// directly.
    private func scheduleCaptureAutoRevert(visible: Bool) {
        captureAutoRevertTimer?.invalidate()
        captureAutoRevertTimer = nil

        guard visible else { return }

        let timer = Timer(timeInterval: Self.captureAutoRevertInterval, repeats: false) { _ in
            Self.performCaptureAutoRevert()
        }
        // `.common` keeps the timer firing while a menu is tracking or a
        // window is being live-resized, matching the other main-run-loop
        // timers in this app (see `AppDelegate`'s election/watchdog timers).
        RunLoop.main.add(timer, forMode: .common)
        captureAutoRevertTimer = timer
    }
}

#elseif os(Windows)
import WinSDK

extension WindowsOverlayWindow: OverlayPresentationBackend {
    func orderOnScreen() {
        setVisible(true)
    }

    /// See `setVisible(_:)`'s own doc comment for why this must be
    /// `SetWindowPos`+`SWP_HIDEWINDOW`, never `ShowWindow` (which activates a
    /// DIFFERENT window and would steal focus) and never moving the window
    /// off-screen (which leaves it `IsWindowVisible`, still composited, and
    /// exposed to a later hot-plugged monitor landing on its old
    /// coordinates).
    func orderOffScreen() {
        setVisible(false)
    }

    var isOnScreen: Bool {
        isWindowVisible
    }

    /// UNLIKE macOS's three-state `NSWindow.SharingType` (`.none`/
    /// `.readOnly`/`.readWrite`), `SetWindowDisplayAffinity` is BINARY:
    /// excluded or not excluded. There is no Windows equivalent of
    /// `.readOnly` vs `.readWrite`, and `WDA_EXCLUDEFROMCAPTURE` requires
    /// Windows 10 version 2004 (build 19041) or later -- see
    /// `setExcludedFromCapture(_:)`'s own doc comment (and
    /// `chalk_window_set_excluded_from_capture`'s, in `chalkboard_win.h`)
    /// for the shim call this maps onto. This is a real, honest reduction
    /// from the macOS three-state contract, not a defect in this file.
    func setCaptureAffinity(includeInCapture: Bool) {
        setExcludedFromCapture(!includeInCapture)
    }
}

extension OverlayWindowController {
    /// Whether a newly (re)created window should be born with
    /// `WDA_EXCLUDEFROMCAPTURE` applied -- the Windows analogue of the
    /// macOS branch's `desiredSharingType`, so a `rebuildOverlayWindows()`
    /// triggered by a display change does not silently revert the user's
    /// capture-debug toggle.
    var desiredExcludedFromCapture: Bool {
        !isCaptureVisible
    }

    /// The Windows analogue of the macOS branch's identical projection --
    /// see its doc comment. Trivial here because `WindowsOverlayWindow`
    /// already combines window + screen id in one object (see that type's
    /// class-level doc comment for why there is no separate view array to
    /// keep aligned).
    private var presentationWindows: [(screenId: String, window: WindowsOverlayWindow)] {
        overlayWindows.map { (screenId: $0.screenId, window: $0) }
    }

    /// UNLIKE macOS, there is no deferred-draw pass to mark dirty here --
    /// this paints synchronously, right where the pre-hoist Windows
    /// implementation did. Only does anything when `isVisible` is true: an
    /// invisible window is never repainted just because the suspend/resume
    /// state machine touched it, matching the pre-hoist behaviour exactly.
    private func presentPixels(window: WindowsOverlayWindow, screenId: String, isVisible: Bool) {
        guard isVisible else { return }
        let annotations = currentlyVisibleAnnotations(forScreenId: screenId)
        guard !annotations.isEmpty else { return }
        // Snapshot every raster this frame needs before drawing any of it,
        // for exactly the reason the macOS branch's `OverlayView.draw(_:)`
        // leases one before calling `AnnotationRenderer` -- see that file's
        // doc comment. There is no `OverlayView` on Windows (this controller
        // paints directly, see `WindowsOverlayWindow.repaint(annotations:
        // imageForAssetId:)`), so this lease lives here instead.
        let assetIDs = annotations.flatMap { $0.kind.rasterAssetIds }
        let rasterLease = RasterAssetStore.shared.lease(ids: assetIDs)
        window.repaint(annotations: annotations) { assetId in
            rasterLease.image(id: assetId)
        }
    }

    /// Invalidates any pending auto-revert work item and, if `visible` is
    /// true, schedules a fresh one. See `captureAutoRevertWorkItem`'s doc
    /// comment on `OverlayWindowController` for why a `DispatchWorkItem` on
    /// a background queue -- not a `Timer` -- is the correct Windows
    /// substitute for the macOS branch's `Timer`-based version. See
    /// `performCaptureAutoRevert()` above for what actually happens when
    /// this fires.
    private func scheduleCaptureAutoRevert(visible: Bool) {
        captureAutoRevertWorkItem?.cancel()
        captureAutoRevertWorkItem = nil

        guard visible else { return }

        let item = DispatchWorkItem {
            Self.performCaptureAutoRevert()
        }
        captureAutoRevertWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.captureAutoRevertInterval, execute: item)
    }
}
#endif
