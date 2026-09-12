import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Element re-resolve seam

/// Outcome of asking the element-resolve conformance to re-run
/// `highlight_element`'s lookup around a settled window and rebuild the
/// highlight geometry around whatever it finds.
///
/// Handing back the fully rebuilt `AnnotationKind` -- not a raw element frame
/// -- is what keeps THIS file free of both AX/UIA (the resolver's business)
/// AND `HighlightOutlineGeometry` (the pure-geometry rebuild's business): the
/// conformance owns calling `AccessibilityElementResolver.resolve` and then
/// `HighlightOutlineGeometry.rebuiltKind(from:spec:newFrame:)` end to end, and
/// this tracker only ever consumes the finished result.
public enum AnchorElementReresolution: Sendable {
    /// The kind that should REPLACE the annotation's existing kind, already
    /// rebuilt around the element's freshly resolved bounds, plus the display
    /// those coordinates are screen-local to.
    case resolved(kind: AnnotationKind, screenId: String)
    /// A fixed reason code only -- "ambiguous", "not_found", "unavailable",
    /// "permission", "timeout". Never caller text, never a UI label.
    case issue(String)
}

/// Conformances live next to `AccessibilityElementResolver`, wrapping its
/// `resolve` and mapping thrown errors onto `AnchorElementReresolution.issue`'s
/// fixed reason codes. `AnchorTracker.shared` is constructed with `nil` here
/// (see its doc comment) until that conformance exists; `nil` disables
/// `.element`-mode re-resolve entirely -- window-mode tracking is unaffected,
/// since it never consults this protocol.
public protocol AnchorElementResolving: Sendable {
    func reresolve(annotation: Annotation, spec: AnchorElementSpec,
                   target: AnchorWindowTarget, screens: [ScreenInfo]) -> AnchorElementReresolution
}

// MARK: - AnchorTrackerStatus

/// A point-in-time summary for `get_overlay_state` (wired up by a later
/// change) to report honestly whether anchored annotations are actually being
/// tracked right now, per the design contract's "honest reporting" invariant.
public struct AnchorTrackerStatus: Equatable, Sendable {
    /// Whether the sampling timer is currently scheduled. `false` whenever
    /// there are no anchored annotations, or every anchored annotation's
    /// target has become permanently `.lost` -- see `AnchorTracker`'s class
    /// doc comment for why an all-lost store must not poll forever either.
    public let isRunning: Bool
    public let anchoredCount: Int
    public let trackingCount: Int
    public let hiddenCount: Int
    public let lostCount: Int
    /// The cadence currently in effect, or nil while `isRunning` is false.
    public let sampleIntervalMs: Int?
    /// How long ago the last sampling tick completed, or nil before the
    /// first tick has ever run.
    public let lastSampleAgeMs: Int?

    public init(isRunning: Bool, anchoredCount: Int, trackingCount: Int, hiddenCount: Int,
                lostCount: Int, sampleIntervalMs: Int?, lastSampleAgeMs: Int?) {
        self.isRunning = isRunning
        self.anchoredCount = anchoredCount
        self.trackingCount = trackingCount
        self.hiddenCount = hiddenCount
        self.lostCount = lostCount
        self.sampleIntervalMs = sampleIntervalMs
        self.lastSampleAgeMs = lastSampleAgeMs
    }
}

// MARK: - AnchorTracker

/// Background sampler that keeps every anchored annotation's `AnchorProjection`
/// current by polling its target window's live geometry. See
/// `ANCHOR_DESIGN.md` section 5 and `ELEMENT_MODE.md` for the full contract
/// this implements; this comment covers the load-bearing WHY behind the
/// choices that are not obvious from the code alone.
///
/// MEASURED COSTS (this machine): `CGWindowListCopyWindowInfo(.optionIncludingWindow,
/// id)`, a single-window sample, costs **0.12 ms/call** (measured over 1000
/// iterations); a full `[.optionOnScreenOnly, .excludeDesktopElements]` sweep
/// of every on-screen window costs **0.43 ms/call** (measured over 200
/// iterations). This is why every tick samples each DISTINCT target with the
/// single-window call (`TargetWindowSampling.window(id:processId:screens:)`)
/// instead of taking one sweep and filtering it: a real session anchors to
/// 1-3 windows, so per-window sampling is already cheaper, and unlike a sweep
/// (which only enumerates on-screen windows) the single-window call can still
/// see a MINIMISED window -- exactly the distinction that separates `.hidden`
/// from a genuinely gone window. At the `.active` cadence (30 Hz) with 3
/// targets that is roughly 3 * 0.12 ms * 30 = ~1% of one CPU core, and only
/// while something is actually moving; see the cadence discussion below for
/// why it is not 30 Hz all the time.
///
/// ZERO COST WHEN UNUSED: this process is a long-lived background MCP daemon.
/// A permanent wakeup for a feature nobody used is not acceptable, so no
/// timer of any kind runs while `store.anchoredAnnotations()` is empty.
/// `AnnotationStore.onAnchoredSetChanged` is wired (in `init`) to `start()`/
/// `stop()` this tracker the instant that set becomes non-empty/empty, and
/// this file additionally treats "every anchored annotation's target has
/// become permanently `.lost`" as an equivalent stopping condition (see
/// `performTick()`) -- a store that is anchored in name only, with nothing
/// left to reacquire, must not poll forever either.
///
/// THREE CADENCES, entirely driven by how recently `applyAnchorProjections`
/// last reported an actual OBSERVABLE change (not merely a re-sample -- see
/// `makeProjection(...)`'s doc comment for why re-sampling alone must not
/// look like a change):
///   - `.active`  1/30 s -- something changed within the last 1 s (a live
///     drag/resize).
///   - `.settled` 0.25 s -- no change for 1 s.
///   - `.idle`    1.0 s  -- no change for 10 s.
/// Any observed change resets to `.active`. Sampling is therefore polled, not
/// event-driven: up to ~33 ms of lag while a window is actively being
/// dragged, landing correctly the moment it stops.
///
/// `DispatchSourceTimer`, NEVER `Foundation.Timer`: `Foundation.Timer` needs a
/// run loop to fire on, and the Windows branch has no main run loop to
/// schedule one against (see `OverlayWindowController.swift`'s doc comment on
/// `captureAutoRevertWorkItem`, which uses `DispatchWorkItem` for exactly this
/// reason). `DispatchSourceTimer` on a private serial queue works identically
/// on both platforms.
///
/// `.lost` IS A ONE-WAY, PERMANENT VERDICT, and is deliberately NOT reached by
/// a single failed sample. `TargetWindowSampling.window(id:processId:screens:)`
/// returning nil is not reliable evidence that a window is gone -- it is ALSO
/// returned for a frame that momentarily cannot be mapped onto any connected
/// display, which is exactly what happens for one or two samples while a
/// window is mid-drag across a display boundary (precisely the scenario this
/// whole feature exists to serve). A nil sample instead sets `.hidden`
/// (painting suppressed, the previous adjustment kept) and increments a
/// per-target consecutive-absence counter; only the THIRD consecutive nil
/// sample promotes the target to `.lost`. Any successful sample -- including
/// one that arrives after one or two absences -- resets the counter to zero.
/// This interacts with the cadence tiers on purpose: at `.active` (1/30 s)
/// three absences is ~100 ms, so a genuinely closed window is reported almost
/// immediately during interaction; at `.idle` (1 s) it is ~3 s, which is fine
/// because nothing is being interacted with. There is deliberately no
/// additional wall-clock timeout layered on top of the tick count -- a second,
/// independent deadline would only be a way for the two to disagree.
///
/// "PERMANENT" MEANS "for as long as the anchored SET does not change," NOT
/// "for the rest of the process's lifetime". Once a target is `.lost`, it is
/// excluded from sampling (a macOS window number is not reused for the same
/// window, and the probe's own pid re-check -- plus a per-tick re-check of
/// the sampled pid's LIVE OS app identity against `AnchorWindowTarget.appId`
/// via `ForeignProcessIdentity.matches`, when that field is non-nil -- rejects
/// a recycled id as a different window rather than as a live match) UNTIL
/// `handleAnchoredSetChanged()` clears `lostTargets` and the absence counters
/// on the very next add/remove of ANY anchored annotation, however unrelated
/// to the lost key. This reset is load-bearing, not incidental: a freshly
/// anchored annotation is, by construction, built from a window sampled
/// moments earlier (see `DrawRequest.buildWindowAnchor`), so it must never
/// inherit an OLDER, unrelated annotation's `.lost` verdict merely because
/// both happen to share one `(processId, windowId)` pair -- reachable
/// without exotic window-id reuse: a window sitting off every connected
/// display for 3 ticks (a monitor unplug/reconfiguration) is already enough
/// to mark it `.lost` even though the window itself is perfectly alive.
/// `handleDisplayReconfiguration()` performs the SAME reset when the display
/// arrangement changes -- see its own doc comment for why a reconfiguration
/// invalidates the evidence a `.lost` verdict was built on.
/// Without the reset, the new annotation's projection would freeze at its
/// creation-time value forever, AND the sampling timer could stop outright
/// while it sat there un-sampled (`allLost`, below, is satisfied by every
/// annotation whose key is in `lostTargets` -- it cannot tell "genuinely
/// dead" apart from "never actually got a chance to be sampled"). The cost
/// is that a genuinely dead target gets re-probed for up to 3 more
/// consecutive absences after any UNRELATED anchor add/remove before
/// `.lost` is reached again -- at this file's own measured 0.12 ms/sample
/// that is not a real cost, and a narrower "reset only the one affected
/// key" scheme is not available anyway: nothing at `handleAnchoredSetChanged`
/// time knows in advance which new target, if any, will collide with an old
/// lost one. Once EVERY anchored annotation's target is `.lost` (and stays
/// that way after the reset above re-samples it), the sampling timer stops
/// exactly as it does when there are no anchored annotations at all.
///
/// THREAD SAFETY: all sampling/cadence/element-scheduling bookkeeping
/// (`targetStates`, `targetAbsenceCounts`, `lostTargets`, `elementStates`,
/// `mappingFailureLogged`, `lastChangeAt`, `lastTickAt`, the timer itself) is
/// CONFINED to `samplingQueue`, a private serial queue -- never guarded by a
/// lock. Every read or mutation of that state happens inside a closure
/// running on `samplingQueue` (the timer's own event handler, or a
/// `samplingQueue.async`/`.sync` hop from a public method). `start()`,
/// `stop()`, and `kick()` are therefore safe to call from the AppKit main
/// thread or the Windows UI thread: each just enqueues work and returns
/// immediately, never blocking the caller. `statusSummary()` is the one
/// method that returns a value synchronously, so it uses `samplingQueue.sync`
/// -- safe because the queue only ever performs fast, non-blocking CPU work
/// and `statusSummary()` is never called reentrantly from inside a tick.
/// Element re-resolution runs on a SEPARATE serial queue, `elementQueue`: an
/// AX/UIA walk can block for up to the caller's `timeout_seconds` (ceiling
/// 10 s), and blocking the sampler behind it would freeze every other
/// anchored annotation on screen. The two queues never need a lock between
/// them because each piece of mutable state has exactly one queue that
/// touches it -- `elementQueue`'s work only ever calls back into
/// `samplingQueue`-owned state via `samplingQueue.async`.
///
/// EVERY WRITE TO A STORED `AnchorProjection` HAPPENS ON `samplingQueue`.
/// That includes the element-resolve pipeline's own writes: only the AX/UIA
/// WALK runs on `elementQueue` (it can block for up to the caller's
/// `timeout_seconds`, and stalling the sampler would freeze every other
/// anchored annotation on screen), while the resulting store write hops back
/// via `samplingQueue.async` before touching anything.
///
/// This is deliberate and load-bearing. An earlier form of this class let
/// `elementQueue` write `state`/`adjustment`/`currentWindowFrame` directly,
/// which meant two queues could race to be the last writer for one
/// annotation with no ordering guarantee between them. Because a resolve
/// write also re-baselines `referenceWindowFrame`, losing that race did not
/// corrupt state permanently -- the next tick recomputed correctly from the
/// new baseline -- but it could still paint one tick's worth of geometry
/// derived from a baseline the winning write had already replaced. Making
/// one queue own the writes removes the question rather than bounding it,
/// and costs nothing: the expensive part was never the write.
///
/// A resolve write therefore also reads the LIVE annotation -- inside
/// `AnnotationStore.updateIfPossibleWithOutcome`'s transform, under the
/// store's own lock -- instead of reusing the copy captured before the walk,
/// so a caller edit that landed during a multi-second walk is preserved
/// rather than reverted, and the rebuilt kind, the re-baselined anchor, and
/// the reset projection all land in ONE store transaction (one repaint, no
/// intermediate frame where new geometry pairs with a stale adjustment).
public final class AnchorTracker: @unchecked Sendable {

    /// Wires the real `TargetWindowProbe` and a screen snapshot sourced from
    /// `OverlayWindowController`'s single main-thread hop (see its
    /// `screenSnapshot()`), plus the `AccessibilityElementResolver`-backed
    /// `AccessibilityAnchorElementResolver` that makes `.element`-mode
    /// re-resolve live, and `ForeignProcessIdentity.appId(forProcessId:)`
    /// (in TargetWindowProbe.swift) for the recycled-pid guard described on
    /// `AnchorWindowTarget.appId`.
    ///
    /// The `elementResolver` parameter stays OPTIONAL rather than being
    /// hard-wired to that type, because every test in `AnchorTrackerTests`
    /// injects a fake one (or `nil`, to assert that `.element` mode is inert
    /// without a resolver) -- an AX/UIA tree walk cannot run in a unit test,
    /// and a tracker that could only be built against the real resolver
    /// would be untestable on exactly the paths most worth testing.
    public static let shared = AnchorTracker(
        store: AnnotationStore.shared,
        probe: TargetWindowProbe.shared,
        screens: { OverlayWindowController.shared.screenSnapshot().screens },
        elementResolver: AccessibilityAnchorElementResolver(),
        now: Date.init,
        appIdentity: ForeignProcessIdentity.appId(forProcessId:)
    )

    private let store: AnnotationStore
    private let probe: TargetWindowSampling
    private let screensProvider: () -> [ScreenInfo]
    private let elementResolver: AnchorElementResolving?
    private let now: () -> Date
    /// Resolves a pid's LIVE OS app identity for the recycled-pid guard (see
    /// the class doc comment's "`.lost` IS A ONE-WAY, PERMANENT VERDICT"
    /// section and `ForeignProcessIdentity` in TargetWindowProbe.swift).
    /// `nil` disables the check entirely: every existing test constructs a
    /// tracker without supplying this, so a fake pid (e.g. `100`) is never
    /// run through a REAL `NSRunningApplication`/`OpenProcess` lookup and
    /// spuriously rejected -- only `AnchorTracker.shared` and tests that
    /// specifically exercise this path supply a non-nil closure.
    private let appIdentity: ((Int64) -> String?)?

    /// Confines every sampling/cadence/element-scheduling decision to one
    /// thread. See the class doc comment's "THREAD SAFETY" section.
    private let samplingQueue = DispatchQueue(label: "com.aichalkboard.anchor-tracker.sampling", qos: .utility)
    /// Deliberately separate from `samplingQueue` -- see the class doc
    /// comment's "THREAD SAFETY" section for why an AX/UIA walk must never
    /// share a queue with the sampler.
    private let elementQueue = DispatchQueue(label: "com.aichalkboard.anchor-tracker.element-resolve", qos: .utility)

    // MARK: Sampling-queue-confined state

    private var timer: DispatchSourceTimer?
    /// Mirrors `timer != nil` in production. Kept as its own flag (rather than
    /// reading `timer` directly) so `testDisableRealTimer` below can exercise
    /// every cadence/stop decision this class makes WITHOUT ever creating a
    /// live `DispatchSourceTimer` -- see that property's doc comment for why
    /// a real background timer is actively dangerous to a deterministic test.
    private var isTimerRunning = false
    private var currentIntervalSeconds: TimeInterval?
    private var lastChangeAt: Date = .distantPast
    private var lastTickAt: Date?

    private struct TargetKey: Hashable {
        let processId: Int64
        let windowId: UInt64
        init(_ target: AnchorWindowTarget) {
            processId = target.processId
            windowId = target.windowId
        }
    }

    private struct ElementResolveState {
        var lastKnownFrame: CGRect?
        var frameChangedAt: Date
        var inFlight = false
        /// The window frame the currently in-flight resolve was TRIGGERED
        /// against. `finishElementResolve` compares it to `lastKnownFrame`
        /// to decide whether a success may arm `resolvedForCurrentFrame`:
        /// if the window moved while the walk ran, the success belongs to a
        /// frame that is no longer current, and gating on it would wrongly
        /// suppress the re-resolve the NEW frame is still owed.
        var inFlightFrame: CGRect?
        var consecutiveFailures = 0
        var lastResolveStartedAt: Date?
        /// The SUCCESS gate (the mirror image of the consecutive-failure
        /// backoff): set once a resolve for the current settled frame has
        /// been applied (or verified as already stored), cleared only by
        /// the next observed frame change. Without it, a resolved,
        /// stationary window re-triggers a full AX tree walk every time the
        /// 0.5 s rate limit re-arms -- `settledFor` keeps growing, the
        /// failure count sits at zero, and nothing else in the gate chain
        /// ever says "this frame is already done" -- costing a ~60% duty
        /// cycle of cross-process AX IPC against a window nothing is
        /// happening to, forever.
        var resolvedForCurrentFrame = false
    }

    private var targetStates: [TargetKey: AnchorTrackingState] = [:]
    private var targetAbsenceCounts: [TargetKey: Int] = [:]
    /// Permanent. A key, once inserted, is never removed except by the
    /// per-tick pruning step that drops keys no longer referenced by ANY
    /// currently anchored annotation (the annotation itself was cleared).
    private var lostTargets: Set<TargetKey> = []
    private var elementStates: [String: ElementResolveState] = [:]
    /// Annotation ids for which "adjustment mapping failed" has already been
    /// logged for the CURRENT failure streak, so a target stuck reporting a
    /// degenerate frame does not log on every tick. See `logMappingFailureIfNeeded`.
    private var mappingFailureLogged: Set<String> = []

    #if os(macOS)
    /// Token for the `NSApplication.didChangeScreenParametersNotification`
    /// observation registered in `init` -- see `handleDisplayReconfiguration()`
    /// for what it is FOR. Held only so `deinit` can unregister it; written
    /// once in `init`, never afterwards.
    private var displayReconfigurationObserver: NSObjectProtocol?
    #endif

    #if DEBUG
    /// Test-only escape hatch. When true, `ensureTimer`/`stopTimer` update
    /// only `isTimerRunning`/`currentIntervalSeconds` -- the bookkeeping
    /// `statusSummary()` reports -- without ever creating a real
    /// `DispatchSourceTimer`.
    ///
    /// WHY THIS EXISTS: tests drive every tick explicitly through
    /// `testOnlyTick()`, advancing the INJECTED fake clock between calls so
    /// cadence escalation/backoff is fully deterministic. A real
    /// `DispatchSourceTimer` scheduled at the `.active` cadence (1/30 s) fires
    /// on the ACTUAL wall clock, completely independent of the fake clock --
    /// if one fired even once during a slow CI run, it would silently add an
    /// extra `TargetWindowSampling.window(id:...)` call the "sampled exactly
    /// once" assertions exist specifically to count, turning a correct
    /// implementation into a flaky test. Production `AnchorTracker.shared`
    /// never sets this, so the real timer path stays fully exercised there.
    var testDisableRealTimer = false
    #endif

    // MARK: Cadence/threshold constants

    private static let activeInterval: TimeInterval = 1.0 / 30.0
    private static let settledInterval: TimeInterval = 0.25
    private static let idleInterval: TimeInterval = 1.0
    /// Below this age since the last observed change, the cadence is `.active`.
    private static let activeWindowSeconds: TimeInterval = 1.0
    /// Below this age (and at/above `activeWindowSeconds`), the cadence is
    /// `.settled`; at/above it, `.idle`.
    private static let idleWindowSeconds: TimeInterval = 10.0
    /// See the class doc comment's "`.lost` IS A ONE-WAY, PERMANENT VERDICT" section.
    private static let lostAfterConsecutiveAbsences = 3
    private static let elementSettleDelay: TimeInterval = 0.2
    private static let elementResolveRateLimit: TimeInterval = 0.5
    private static let elementResolveMaxConsecutiveFailures = 3

    public init(
        store: AnnotationStore,
        probe: TargetWindowSampling,
        screens: @escaping () -> [ScreenInfo],
        elementResolver: AnchorElementResolving?,
        now: @escaping () -> Date,
        appIdentity: ((Int64) -> String?)? = nil
    ) {
        self.store = store
        self.probe = probe
        self.screensProvider = screens
        self.elementResolver = elementResolver
        self.now = now
        self.appIdentity = appIdentity

        store.onAnchoredSetChanged = { [weak self] in
            self?.handleAnchoredSetChanged()
        }
        #if os(macOS)
        // Wired HERE, not in OverlayWindowController's own observation of
        // the same notification: that class's handler rebuilds overlay
        // windows and knows nothing about this tracker's liveness verdicts,
        // and threading a cross-object call through it would couple two
        // unrelated responsibilities to one selector. The block only
        // enqueues onto `samplingQueue` and returns, so it is safe on
        // whatever thread AppKit posts from.
        displayReconfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleDisplayReconfiguration()
        }
        #endif
        // Cover the case where anchors already exist at construction time
        // (a store populated some other way before this tracker was built)
        // rather than waiting for the next add/remove to fire the callback.
        if !store.anchoredAnnotations().isEmpty {
            start()
        }
    }

    deinit {
        #if os(macOS)
        if let displayReconfigurationObserver {
            NotificationCenter.default.removeObserver(displayReconfigurationObserver)
        }
        #endif
    }

    // MARK: Public control surface

    /// Ensures the sampling timer is running at the `.active` cadence.
    /// Idempotent, and safe to call whether or not the timer is already
    /// running: a fresh membership change (a new anchor, or one fewer) is
    /// itself treated as "something changed", so this always forces an
    /// immediate `.active` burst rather than leaving a newly added anchor
    /// waiting out whatever slower cadence was already in effect.
    public func start() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.lastChangeAt = self.now()
            self.ensureTimer(interval: Self.activeInterval)
        }
    }

    public func stop() {
        samplingQueue.async { [weak self] in
            self?.stopTimer()
        }
    }

    /// Samples once, right now, off the caller's thread. Called on app
    /// activation and on resume from suspension so a window that moved while
    /// the app was in the background is corrected promptly. Safe to call from
    /// the AppKit main thread or the Windows UI thread: this only enqueues
    /// work and returns immediately.
    public func kick() {
        samplingQueue.async { [weak self] in
            self?.performTick()
        }
    }

    public func statusSummary() -> AnchorTrackerStatus {
        samplingQueue.sync {
            let snapshots = store.anchoredAnnotations()
            var tracking = 0
            var hidden = 0
            var lost = 0
            for snap in snapshots {
                let key = TargetKey(snap.anchor.target)
                let state: AnchorTrackingState = lostTargets.contains(key) ? .lost : (targetStates[key] ?? .hidden)
                switch state {
                case .tracking: tracking += 1
                case .hidden: hidden += 1
                case .lost: lost += 1
                }
            }
            let intervalMs = currentIntervalSeconds.map { Int(($0 * 1000).rounded()) }
            let ageMs = lastTickAt.map { Int(now().timeIntervalSince($0) * 1000) }
            return AnchorTrackerStatus(
                isRunning: isTimerRunning,
                anchoredCount: snapshots.count,
                trackingCount: tracking,
                hiddenCount: hidden,
                lostCount: lost,
                sampleIntervalMs: intervalMs,
                lastSampleAgeMs: ageMs
            )
        }
    }

    #if DEBUG
    /// Runs exactly one sampling tick synchronously and returns once its
    /// whole projection batch has been applied. Production never calls this
    /// -- the timer's event handler and `kick()` are the only real callers of
    /// `performTick()`, both firing it asynchronously. Tests use this instead
    /// of waiting on real timer fires: advance the injected fake clock, then
    /// call this, and assert deterministically.
    func testOnlyTick() {
        samplingQueue.sync { self.performTick() }
    }

    /// A pure ordering barrier: blocks until every `samplingQueue` work item
    /// enqueued before this call (in particular, `start()`/`stop()`'s
    /// asynchronous hops fired by a real `AnnotationStore.onAnchoredSetChanged`
    /// callback) has finished, without itself running another tick.
    func testOnlyFlush() {
        samplingQueue.sync {}
    }

    /// Blocks until every `elementQueue` work item enqueued before this call
    /// (an in-flight `reresolve` call plus its store write) has finished.
    /// Callers that also need `finishElementResolve`'s follow-up
    /// `samplingQueue` hop to have completed must call `testOnlyFlush()`
    /// immediately afterward.
    func testOnlyWaitForElementQueueIdle() {
        elementQueue.sync {}
    }
    #endif

    // MARK: Store callback

    /// Re-derives whether the timer should be running, ON the sampling queue,
    /// from the store's own current state.
    ///
    /// WHY THE DECISION CANNOT BE MADE ON THE CALLING THREAD: this fires from
    /// `AnnotationStore.onAnchoredSetChanged`, which the store invokes on
    /// whichever thread mutated it -- and two threads can mutate it
    /// concurrently (an MCP call adding an anchored annotation while another
    /// clears the last remaining one). The store's lock serialises the
    /// MUTATIONS, but it does not serialise these callbacks, and two
    /// independent producer threads have no ordering guarantee on when their
    /// `samplingQueue.async` blocks land. Reading `isEmpty` here and then
    /// enqueuing a start-or-stop therefore lets a stale "stop" run after a
    /// newer "start", leaving the tracker silently not polling while an
    /// annotation is genuinely anchored -- recoverable only by the next
    /// `kick()` or membership change, which could be a whole drag later.
    ///
    /// Deciding INSIDE the serial queue removes the ordering question
    /// entirely: however the blocks interleave, the one that runs last reads
    /// the store's authoritative final state and leaves the timer in the
    /// matching condition. Both branches are idempotent (`ensureTimer`
    /// returns early when the interval already matches; `stopTimer` is a
    /// no-op when nothing is running), so redundant blocks are free.
    private func handleAnchoredSetChanged() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            // See the class doc comment's "`.lost` IS A ONE-WAY, PERMANENT
            // VERDICT" section: a `.lost` verdict (and the absence counters
            // that lead to one) must never survive past the anchored set
            // actually changing, or a brand-new annotation that happens to
            // share a `(processId, windowId)` pair with an old, unrelated
            // `.lost` target would inherit a verdict it never earned --
            // freezing its projection at its creation-time value forever
            // and potentially stranding the sampling timer via `allLost`.
            // Unconditional, regardless of which branch below runs: cheap
            // (two dictionary clears), and correct either way -- if the set
            // just went empty there is nothing left to poison anyway, and if
            // it is still non-empty the next tick re-derives every target's
            // liveness from fresh evidence.
            self.lostTargets.removeAll()
            self.targetAbsenceCounts.removeAll()
            if self.store.anchoredAnnotations().isEmpty {
                self.stopTimer()
            } else {
                self.lastChangeAt = self.now()
                self.ensureTimer(interval: Self.activeInterval)
            }
        }
    }

    /// Clears every `.lost` verdict and absence counter and forces an
    /// immediate `.active` re-probe, because a display reconfiguration
    /// invalidates the EVIDENCE those verdicts were built on.
    ///
    /// WHY THIS EXISTS: `.lost` is reached by 3 consecutive nil samples, and
    /// a nil sample only means "this window's frame currently maps onto no
    /// connected display" -- which is exactly what a monitor unplug, rescale,
    /// or rearrangement produces for every window parked on the affected
    /// display, for however long the reconfiguration takes. At the `.active`
    /// cadence (1/30 s) that is easily 3 ticks, so a perfectly alive window
    /// earns a verdict this class documents as permanent-until-membership-
    /// change: its annotation freezes at the last projection forever, and an
    /// all-lost store stops the sampling timer outright, with nothing left
    /// to notice the display coming back. Before this hook existed, NOTHING
    /// reacted to a reconfiguration here -- `OverlayWindowController`
    /// observes the same notification but only rebuilds its own overlay
    /// windows -- so the false verdict stuck until the next anchored
    /// add/remove, which could be never.
    ///
    /// Same reset `handleAnchoredSetChanged` performs, for the same reason
    /// its doc comment gives: the next tick re-derives every target's
    /// liveness from fresh evidence, and a genuinely dead target simply
    /// walks back to `.lost` within 3 samples (~0.1 ms each -- see the class
    /// doc's MEASURED COSTS). Unlike that callback this never stops the
    /// timer: an empty store already has no timer to stop, and
    /// `performTick()` re-stops an all-lost one on its own.
    ///
    /// Public so the notification block in `init` stays a one-liner and so
    /// tests can drive a reconfiguration deterministically without posting
    /// AppKit notifications. Safe from any thread: only enqueues onto
    /// `samplingQueue`.
    public func handleDisplayReconfiguration() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.lostTargets.removeAll()
            self.targetAbsenceCounts.removeAll()
            guard !self.store.anchoredAnnotations().isEmpty else { return }
            // The reconfiguration is itself "something changed": windows
            // shuffle displays and coordinates during one, so burst at
            // `.active` rather than letting a slower cadence lag the
            // correction.
            self.lastChangeAt = self.now()
            self.ensureTimer(interval: Self.activeInterval)
        }
    }

    // MARK: Timer management (samplingQueue-confined)

    private func ensureTimer(interval: TimeInterval) {
        if isTimerRunning, currentIntervalSeconds == interval { return }
        let wasRunning = isTimerRunning
        currentIntervalSeconds = interval
        isTimerRunning = true

        #if DEBUG
        guard !testDisableRealTimer else { return }
        #endif

        let leeway = DispatchTimeInterval.milliseconds(max(1, Int(interval * 100)))
        if wasRunning, let existing = timer {
            // Already ticking: just adjust the going-forward rhythm. Using
            // `.now() + interval` (not `.now()`) avoids an extra immediate
            // fire right on top of the tick that is choosing this cadence.
            existing.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
            return
        }
        let newTimer = DispatchSource.makeTimerSource(queue: samplingQueue)
        newTimer.setEventHandler { [weak self] in self?.performTick() }
        // A fresh start fires almost immediately, so a newly anchored
        // annotation gets its first real sample without waiting a full
        // interval.
        newTimer.schedule(deadline: .now(), repeating: interval, leeway: leeway)
        newTimer.resume()
        timer = newTimer
    }

    private func stopTimer() {
        isTimerRunning = false
        currentIntervalSeconds = nil
        #if DEBUG
        guard !testDisableRealTimer else { return }
        #endif
        timer?.cancel()
        timer = nil
    }

    private func desiredInterval(sinceLastChange: TimeInterval) -> TimeInterval {
        if sinceLastChange < Self.activeWindowSeconds { return Self.activeInterval }
        if sinceLastChange < Self.idleWindowSeconds { return Self.settledInterval }
        return Self.idleInterval
    }

    // MARK: One sampling tick (samplingQueue-confined)

    private func performTick() {
        let snapshots = store.anchoredAnnotations()
        guard !snapshots.isEmpty else {
            stopTimer()
            lastTickAt = now()
            return
        }

        let screens = screensProvider()
        let tickNow = now()

        // 1. Which distinct targets are still worth sampling? A target
        //    already `.lost` from an earlier tick is excluded until the
        //    anchored set changes (see `handleAnchoredSetChanged` and the
        //    class doc comment's "`.lost` IS A ONE-WAY, PERMANENT VERDICT"
        //    section).
        var distinctTargets: [TargetKey: AnchorWindowTarget] = [:]
        for snap in snapshots {
            let key = TargetKey(snap.anchor.target)
            guard !lostTargets.contains(key) else { continue }
            if distinctTargets[key] == nil {
                distinctTargets[key] = snap.anchor.target
            }
        }

        // 2. Sample each distinct target EXACTLY ONCE, however many
        //    annotations share it. A sample that names the right
        //    (pid, windowId) pair but whose pid's LIVE app identity no
        //    longer matches what was recorded at anchor time is a
        //    recycled-pid collision, not a live match -- reject it exactly
        //    like a nil sample (see `AnchorWindowTarget.appId`'s doc comment
        //    and `ForeignProcessIdentity`, both in TargetWindowProbe.swift,
        //    for the full rationale). `appIdentity` is nil in every test
        //    that has no reason to exercise this path -- see that
        //    property's own doc comment.
        var freshSamples: [TargetKey: TargetWindowSample] = [:]
        for (key, target) in distinctTargets {
            guard let sample = probe.window(id: target.windowId, processId: target.processId, screens: screens) else { continue }
            if let expectedAppId = target.appId, let appIdentity,
               !ForeignProcessIdentity.matches(resolved: appIdentity(target.processId), recorded: expectedAppId) {
                continue
            }
            freshSamples[key] = sample
        }

        // 3. Update per-target liveness via the consecutive-absence counter.
        var newlyLost: Set<TargetKey> = []
        for key in distinctTargets.keys {
            if let sample = freshSamples[key] {
                targetAbsenceCounts[key] = 0
                targetStates[key] = sample.isOnScreen ? .tracking : .hidden
            } else {
                let count = (targetAbsenceCounts[key] ?? 0) + 1
                targetAbsenceCounts[key] = count
                if count >= Self.lostAfterConsecutiveAbsences {
                    targetStates[key] = .lost
                    newlyLost.insert(key)
                } else {
                    targetStates[key] = .hidden
                }
            }
        }
        lostTargets.formUnion(newlyLost)

        // 4. One AnchorProjection per annotation, plus element re-resolve
        //    scheduling for settled `.element`-mode annotations.
        var projections: [String: AnchorProjection] = [:]
        for snap in snapshots {
            let key = TargetKey(snap.anchor.target)
            // A target already lost BEFORE this tick was excluded from
            // sampling above and its `.lost` projection was already written
            // (and logged) the tick it happened -- nothing left to do.
            if lostTargets.contains(key), !newlyLost.contains(key) { continue }
            guard let windowState = targetStates[key] else { continue }

            let previous = snap.currentProjection
            let newProjection = makeProjection(
                for: snap, windowState: windowState, freshSample: freshSamples[key],
                previous: previous, screens: screens, at: tickNow
            )
            projections[snap.id] = newProjection
            logTransitionIfNeeded(id: snap.id, target: snap.anchor.target,
                                  from: previous?.state, to: newProjection.state)

            if windowState == .tracking, let sample = freshSamples[key] {
                considerElementReresolve(
                    snap: snap, currentFrame: sample.frame, currentScreenId: sample.screenId,
                    screens: screens, at: tickNow
                )
            }
        }

        // 5. One store write for the whole batch -> one repaint at most.
        let changed = store.applyAnchorProjections(projections)

        // 6. Bound memory: drop bookkeeping for targets/annotations no
        //    longer referenced by anything currently anchored.
        let referencedKeys = Set(snapshots.map { TargetKey($0.anchor.target) })
        targetStates = targetStates.filter { referencedKeys.contains($0.key) }
        targetAbsenceCounts = targetAbsenceCounts.filter { referencedKeys.contains($0.key) }
        lostTargets = lostTargets.intersection(referencedKeys)
        let referencedIds = Set(snapshots.map(\.id))
        elementStates = elementStates.filter { referencedIds.contains($0.key) }
        mappingFailureLogged = mappingFailureLogged.intersection(referencedIds)

        // 7. Cadence + timer upkeep. An all-lost store must not poll forever,
        //    exactly like an empty one.
        lastTickAt = tickNow
        let allLost = snapshots.allSatisfy { lostTargets.contains(TargetKey($0.anchor.target)) }
        if allLost {
            stopTimer()
            return
        }
        if changed {
            lastChangeAt = tickNow
        }
        ensureTimer(interval: desiredInterval(sinceLastChange: tickNow.timeIntervalSince(lastChangeAt)))
    }

    /// Builds the projection this tick's evidence supports, then -- unless
    /// this is the annotation's very first sample -- returns `previous`
    /// UNCHANGED whenever every observable field (`state`, `adjustment`,
    /// `effectiveScreenId`, `currentWindowFrame`, `elementResolutionIssue`)
    /// would come out identical to what is already stored.
    ///
    /// THIS IS LOAD-BEARING, not a micro-optimisation. `AnchorProjection` is
    /// `Equatable` over ALL of its fields including `sampledAt`, and
    /// `AnnotationStore.applyAnchorProjections` decides "did anything change"
    /// by that same equality. If this method stamped a fresh `sampledAt` on
    /// every tick regardless of content, a window sitting perfectly still
    /// would look like a change on EVERY tick purely because it was
    /// re-sampled -- defeating `applyAnchorProjections`'s "one repaint per
    /// real change" guarantee, and permanently pinning the cadence at
    /// `.active` forever (since `performTick()` resets `lastChangeAt`
    /// whenever `applyAnchorProjections` reports a change). Reusing
    /// `previous` wholesale when nothing observable differs is what makes
    /// re-sampling and "did anything change" independent questions again.
    private func makeProjection(
        for snap: AnchoredAnnotationSnapshot,
        windowState: AnchorTrackingState,
        freshSample: TargetWindowSample?,
        previous: AnchorProjection?,
        screens: [ScreenInfo],
        at tickNow: Date
    ) -> AnchorProjection {
        let candidate = buildCandidateProjection(
            for: snap, windowState: windowState, freshSample: freshSample, previous: previous,
            screens: screens, at: tickNow
        )
        if let previous,
           previous.state == candidate.state,
           previous.adjustment == candidate.adjustment,
           previous.effectiveScreenId == candidate.effectiveScreenId,
           previous.currentWindowFrame == candidate.currentWindowFrame,
           previous.elementResolutionIssue == candidate.elementResolutionIssue {
            return previous
        }
        return candidate
    }

    /// Resolves the backing-scale pair `AnchorAdjustment.mapping` needs so a
    /// cross-density `.pin` move compensates the two displays' pixel
    /// densities (see that function's `.pin` branch for the worked failure).
    ///
    /// Reference side: the anchor's own recorded `referenceScreenScale`
    /// wins when present (it survives the reference display disconnecting);
    /// otherwise the reference screen is looked up LIVE in this tick's
    /// snapshot by id. Current side: always the sampled screen's snapshot
    /// entry -- the sample's frame was converted against this exact
    /// snapshot, so its screen id is present by construction.
    ///
    /// FALLBACK: when either side cannot be resolved (the reference display
    /// is no longer connected AND its scale was never recorded -- an anchor
    /// created before `referenceScreenScale` existed), this returns (1, 1),
    /// i.e. exactly the density-blind mapping every anchor got before this
    /// compensation existed. That is deliberate: the stored geometry's
    /// density is unknowable at that point -- it cannot be recovered from
    /// any current evidence -- and inventing a scale would misplace the
    /// drawing deterministically, whereas the legacy mapping is at worst
    /// exactly as wrong as it always was, and exactly right whenever the
    /// two displays happen to share a density (the common case).
    private static func densityScales(
        for anchor: AnnotationAnchor, currentScreenId: String, screens: [ScreenInfo]
    ) -> (reference: Double, current: Double) {
        let reference = anchor.referenceScreenScale
            ?? screens.first(where: { $0.id == anchor.referenceScreenId })?.backingScaleFactor
        let current = screens.first(where: { $0.id == currentScreenId })?.backingScaleFactor
        guard let reference, let current else { return (1, 1) }
        return (reference, current)
    }

    private func buildCandidateProjection(
        for snap: AnchoredAnnotationSnapshot,
        windowState: AnchorTrackingState,
        freshSample: TargetWindowSample?,
        previous: AnchorProjection?,
        screens: [ScreenInfo],
        at tickNow: Date
    ) -> AnchorProjection {
        switch windowState {
        case .lost:
            return AnchorProjection(
                state: .lost,
                adjustment: previous?.adjustment ?? .identity,
                effectiveScreenId: previous?.effectiveScreenId ?? snap.anchor.referenceScreenId,
                currentWindowFrame: nil,
                sampledAt: tickNow,
                elementResolutionIssue: previous?.elementResolutionIssue
            )
        case .hidden:
            // A fresh sample this tick (window found, just off-screen) is
            // real, current evidence and wins; otherwise (an absence still
            // under the `.lost` threshold) there is nothing fresh to report,
            // so the previous frame is kept rather than blanked.
            let frame = freshSample?.frame ?? previous?.currentWindowFrame?.cgRect
            let screenId = freshSample?.screenId ?? previous?.effectiveScreenId ?? snap.anchor.referenceScreenId
            return AnchorProjection(
                state: .hidden,
                adjustment: previous?.adjustment ?? .identity,
                effectiveScreenId: screenId,
                currentWindowFrame: frame.map(AnchorRect.init),
                sampledAt: tickNow,
                elementResolutionIssue: previous?.elementResolutionIssue
            )
        case .tracking:
            // `.tracking` is only ever assigned in performTick() alongside a
            // fresh, on-screen sample for this exact key.
            guard let sample = freshSample else {
                return previous ?? AnchorProjection(
                    state: .tracking, adjustment: .identity, effectiveScreenId: snap.anchor.referenceScreenId,
                    currentWindowFrame: nil, sampledAt: tickNow, elementResolutionIssue: nil
                )
            }
            let scales = Self.densityScales(for: snap.anchor, currentScreenId: sample.screenId, screens: screens)
            let mapped = AnchorAdjustment.mapping(
                reference: snap.anchor.referenceWindowFrame.cgRect, current: sample.frame,
                behavior: snap.anchor.resize,
                referenceScreenScale: scales.reference, currentScreenScale: scales.current
            )
            if mapped == nil {
                logMappingFailureIfNeeded(id: snap.id, anchor: snap.anchor, current: sample.frame)
            } else {
                mappingFailureLogged.remove(snap.id)
            }
            return AnchorProjection(
                state: .tracking,
                // A nil mapping means "not derivable this tick" -- keep the
                // previous adjustment. Falling back to `.identity` would
                // teleport the drawing to its raw stored position; see
                // `AnchorAdjustment.mapping`'s own doc comment.
                adjustment: mapped ?? (previous?.adjustment ?? .identity),
                effectiveScreenId: sample.screenId,
                currentWindowFrame: AnchorRect(sample.frame),
                sampledAt: tickNow,
                elementResolutionIssue: previous?.elementResolutionIssue
            )
        }
    }

    private func logTransitionIfNeeded(id: String, target: AnchorWindowTarget,
                                       from: AnchorTrackingState?, to: AnchorTrackingState) {
        guard let from, from != to else { return }
        let level = (to == .tracking) ? "INFO" : "WARN"
        Logger.shared.log(
            "AnchorTracker: anchor state changed id=\(id) from=\(from.rawValue) to=\(to.rawValue) " +
            "windowId=\(target.windowId) processId=\(target.processId)",
            level: level
        )
    }

    private func logMappingFailureIfNeeded(id: String, anchor: AnnotationAnchor, current: CGRect) {
        guard !mappingFailureLogged.contains(id) else { return }
        mappingFailureLogged.insert(id)
        let reference = anchor.referenceWindowFrame.cgRect
        Logger.shared.log(
            "AnchorTracker: adjustment mapping unavailable id=\(id) reason=mapping_unmappable " +
            "referenceWidth=\(reference.width) referenceHeight=\(reference.height) " +
            "currentWidth=\(current.width) currentHeight=\(current.height)",
            level: "WARN"
        )
    }

    // MARK: Element re-resolve scheduling (samplingQueue-confined decisions;
    // elementQueue-confined execution)

    /// Detects a frame change/settle for one `.element`-mode annotation and,
    /// when every gate passes, schedules a re-resolve attempt. Gates, per the
    /// design contract: 200 ms of stability since the last observed frame
    /// change (debounce, via `frameChangedAt`); at most one in flight
    /// (`!inFlight`); at most one attempt per 500 ms
    /// (`lastResolveStartedAt` rate limit); fewer than 3 CONSECUTIVE
    /// failures; and no SUCCESS already applied for the current frame
    /// (`resolvedForCurrentFrame` -- see below).
    ///
    /// THERE IS DELIBERATELY NO "one attempt per settle" GATE for FAILURES.
    /// As long as the
    /// frame stays put, a failed attempt is allowed to retry every 500 ms (a
    /// transient `.issue` such as "timeout" or "unavailable" is exactly the
    /// case a periodic retry against an UNCHANGED frame is meant to recover
    /// from) right up to the 3-failure cap. `consecutiveFailures` resets to
    /// zero on a genuine frame change -- which is what makes "stops after 3
    /// consecutive failures until the window frame changes again" a real,
    /// reachable state machine: 3 failures against ONE stable frame engage
    /// the backoff, and it is lifted by a NEW frame change starting a fresh
    /// count, not by merely waiting out the rate limit again. (An earlier
    /// draft of this method reset the counter on every frame change AND
    /// required a fresh frame change to unlock each retry -- that combination
    /// can never accumulate past one failure and made the threshold dead
    /// code; this is the fix.)
    ///
    /// A SUCCESS, by contrast, IS "one per settle": once a resolve for the
    /// current frame has been applied, `resolvedForCurrentFrame` blocks
    /// further attempts until a NEW frame change re-arms it -- the exact
    /// mirror of how the failure backoff is lifted. Without this gate a
    /// resolved, STATIONARY window kept walking the target app's whole AX
    /// tree every time the 500 ms rate limit re-armed (`settledFor` only
    /// grows on an unchanged frame, and success resets the failure count,
    /// so nothing else ever said "done") -- a permanent ~60% duty cycle of
    /// cross-process AX IPC, for zero new information. The documented
    /// contract is unchanged: element re-resolve exists to track
    /// intra-window reflow AFTER a real window change, and every real
    /// change still re-arms the gate the moment it is observed.
    private func considerElementReresolve(
        snap: AnchoredAnnotationSnapshot, currentFrame: CGRect, currentScreenId: String,
        screens: [ScreenInfo], at tickNow: Date
    ) {
        guard snap.anchor.mode == .element, snap.kindIsHighlightPath,
              let spec = snap.anchor.element, elementResolver != nil else { return }

        var state = elementStates[snap.id] ?? ElementResolveState(lastKnownFrame: nil, frameChangedAt: tickNow)
        if let last = state.lastKnownFrame, last != currentFrame {
            state.lastKnownFrame = currentFrame
            state.frameChangedAt = tickNow
            state.consecutiveFailures = 0
            // The one event that re-arms the success gate: a real window
            // change means the element may have reflowed, so the new frame
            // is owed its own resolve once it settles.
            state.resolvedForCurrentFrame = false
        } else if state.lastKnownFrame == nil {
            state.lastKnownFrame = currentFrame
            state.frameChangedAt = tickNow
        }

        let settledFor = tickNow.timeIntervalSince(state.frameChangedAt)
        let rateLimitOK = state.lastResolveStartedAt.map {
            tickNow.timeIntervalSince($0) >= Self.elementResolveRateLimit
        } ?? true
        let shouldTrigger = settledFor >= Self.elementSettleDelay
            && !state.inFlight
            && !state.resolvedForCurrentFrame
            && state.consecutiveFailures < Self.elementResolveMaxConsecutiveFailures
            && rateLimitOK

        if shouldTrigger {
            state.inFlight = true
            state.inFlightFrame = currentFrame
            state.lastResolveStartedAt = tickNow
        }
        elementStates[snap.id] = state

        if shouldTrigger {
            triggerElementReresolve(
                annotationId: snap.id, target: snap.anchor.target, spec: spec,
                settledWindowFrame: currentFrame, settledScreenId: currentScreenId, screens: screens
            )
        }
    }

    /// Runs the actual (potentially slow) resolve call and its follow-up
    /// store write entirely on `elementQueue`, then hops back to
    /// `samplingQueue` only to update this tracker's own bookkeeping
    /// (`finishElementResolve`). Must be called already confined to
    /// `samplingQueue` (it is only ever called from `considerElementReresolve`).
    private func triggerElementReresolve(
        annotationId: String, target: AnchorWindowTarget, spec: AnchorElementSpec,
        settledWindowFrame: CGRect, settledScreenId: String, screens: [ScreenInfo]
    ) {
        guard let resolver = elementResolver else { return }
        elementQueue.async { [weak self] in
            guard let self else { return }
            guard let existing = self.store.get(id: annotationId) else {
                // The annotation was cleared while this resolve was queued.
                self.samplingQueue.async { self.finishElementResolve(id: annotationId, succeeded: false) }
                return
            }
            let outcome = resolver.reresolve(annotation: existing, spec: spec, target: target, screens: screens)
            switch outcome {
            case .resolved(let kind, let screenId):
                // The WALK above had to happen off `samplingQueue` (it can
                // block for up to the caller's timeout_seconds, and stalling
                // the sampler would freeze every other anchored annotation on
                // screen). The WRITE, however, hops back: `samplingQueue` is
                // the only other writer of `state`/`adjustment`/
                // `currentWindowFrame`, so performing this write there makes
                // every projection write in this class serial by
                // construction, instead of two queues racing to be last.
                //
                // `existing` is deliberately NOT reused for the write: it was
                // captured BEFORE a walk that may have taken seconds, and
                // committing a replacement built from it would resurrect a
                // stale `offsetX`/`opacity`/`zIndex` a caller edited while
                // the walk ran. `applyResolvedElement` instead builds its
                // replacement from the LIVE annotation, inside the store's
                // own locked transform, so a mid-walk caller edit is
                // incorporated rather than either discarded or reverted.
                self.samplingQueue.async {
                    let outcome = self.applyResolvedElement(
                        annotationId: annotationId, kind: kind, screenId: screenId,
                        settledWindowFrame: settledWindowFrame
                    )
                    let succeeded: Bool
                    let word: String
                    switch outcome {
                    case .applied:
                        succeeded = true
                        word = "applied"
                    case .unchanged:
                        succeeded = true
                        word = "unchanged_skipped"
                    case .rejected(let reason):
                        succeeded = false
                        word = "not_applied reason=\(reason)"
                    }
                    Logger.shared.log(
                        "AnchorTracker: element re-resolve \(word) id=\(annotationId) " +
                        "frameX=\(settledWindowFrame.origin.x) frameY=\(settledWindowFrame.origin.y) " +
                        "frameWidth=\(settledWindowFrame.width) frameHeight=\(settledWindowFrame.height)",
                        level: succeeded ? "INFO" : "WARN"
                    )
                    self.finishElementResolve(id: annotationId, succeeded: succeeded)
                }
            case .issue(let code):
                // Same reasoning as the success branch: the issue write also
                // touches the stored projection, so it belongs on the one
                // queue that owns projection writes.
                self.samplingQueue.async {
                    self.recordElementIssue(id: annotationId, code: code)
                    Logger.shared.log(
                        "AnchorTracker: element re-resolve issue reason=\(code) id=\(annotationId)",
                        level: "WARN"
                    )
                    self.finishElementResolve(id: annotationId, succeeded: false)
                }
            }
        }
    }

    /// How one successful resolve's commit attempt ended -- the vocabulary
    /// `triggerElementReresolve`'s completion logging and
    /// `finishElementResolve`'s success gate consume.
    private enum ElementResolveApplyOutcome {
        /// A store write landed: the combined kind/anchor/projection commit,
        /// or -- when the resolve merely re-confirmed geometry the store
        /// already holds but the projection still needed patching (e.g. a
        /// stale issue code to clear) -- the projection-only write.
        case applied
        /// The resolve verified that EVERYTHING it would write is already
        /// stored (modulo `sampledAt`, which is deliberately not an
        /// observable difference -- the same rule `makeProjection`
        /// documents). Nothing was written: no repaint, no revision
        /// consumed, no spurious `.stale` handed to a concurrent
        /// `update_annotation` CAS.
        case unchanged
        /// Nothing was committed; the fixed token (never caller text) says
        /// why: "annotation_gone", "anchor_changed", "window_moved",
        /// "store_rejected".
        case rejected(String)
    }

    /// Below this per-component delta (backing pixels), the tracker's latest
    /// sampled frame and the settled frame a resolve was triggered against
    /// are considered the same window position. Sub-pixel slack only:
    /// samples flow through one deterministic conversion pipeline, so a
    /// genuinely stationary window reproduces bit-identical frames, and any
    /// REAL move is whole backing pixels.
    private static let resolveApplyFrameTolerancePx = 0.5

    private static func frames(_ a: CGRect, closeTo b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= resolveApplyFrameTolerancePx
            && abs(a.origin.y - b.origin.y) <= resolveApplyFrameTolerancePx
            && abs(a.size.width - b.size.width) <= resolveApplyFrameTolerancePx
            && abs(a.size.height - b.size.height) <= resolveApplyFrameTolerancePx
    }

    /// Structural equality over the ONE kind shape the element pipeline
    /// produces. `AnnotationKind` declares no `Equatable` conformance, and a
    /// synthesized retrofit is only possible in its own file (a cross-file
    /// `extension AnnotationKind: Equatable {}` cannot synthesize `==` for an
    /// enum with associated values); rather than reach into a file this
    /// tracker does not own, compare exactly the case that matters here:
    /// `HighlightOutlineGeometry.rebuiltKind` returns nil for anything but
    /// `.vectorPath`, so a resolved `kind` is `.vectorPath` by construction,
    /// and any non-`.vectorPath` stored kind conservatively reports
    /// "different" -- which merely writes, never skips.
    private static func highlightKindsIdentical(_ a: AnnotationKind, _ b: AnnotationKind) -> Bool {
        guard case .vectorPath(
            let aData, let aStrokeColor, let aStrokeWidth, let aStrokeOpacity,
            let aFillColor, let aFillOpacity, let aDash, let aEvenOdd, let aScaleX, let aScaleY
        ) = a,
        case .vectorPath(
            let bData, let bStrokeColor, let bStrokeWidth, let bStrokeOpacity,
            let bFillColor, let bFillOpacity, let bDash, let bEvenOdd, let bScaleX, let bScaleY
        ) = b else { return false }
        return aData == bData && aStrokeColor == bStrokeColor && aStrokeWidth == bStrokeWidth
            && aStrokeOpacity == bStrokeOpacity && aFillColor == bFillColor && aFillOpacity == bFillOpacity
            && aDash == bDash && aEvenOdd == bEvenOdd && aScaleX == bScaleX && aScaleY == bScaleY
    }

    /// Commits a successful element re-resolve -- the rebuilt kind, the
    /// re-baselined anchor, AND the reset (identity-adjustment, `.tracking`)
    /// projection -- in ONE `AnnotationStore.updateIfPossibleWithOutcome`
    /// transaction, via its explicit projection override.
    ///
    /// ONE TRANSACTION IS LOAD-BEARING, not tidiness. An earlier form of
    /// this method wrote twice: `updateWithOutcome` (which always carries
    /// the EXISTING projection forward) followed by a separate
    /// `applyAnchorProjections` to reset the adjustment. Each write
    /// notifies, so between the two the store held -- and a repaint could
    /// paint -- the REBUILT, absolutely-positioned geometry combined with
    /// the OLD, non-identity adjustment: one visible frame of double-offset
    /// highlight per resolve. The transform overload's `projectionOverride`
    /// exists precisely so a re-baseline can say "here is the new tracking
    /// state" atomically with the annotation it belongs to.
    ///
    /// THE TRANSFORM ALSO CLOSES THE MID-WALK EDIT RACE: it reads the LIVE
    /// annotation under the store's own lock, so a caller edit that landed
    /// during a multi-second walk is built upon rather than reverted, with
    /// no CAS to spuriously discard the resolve.
    ///
    /// GUARDS, in order:
    /// - The annotation must still exist and still carry an `.element`-mode
    ///   anchor (a mid-walk detach or re-anchor to `.window` retires the
    ///   contract this rebuild was produced under).
    /// - THE WINDOW MUST NOT HAVE MOVED SINCE THE WALK STARTED. The walk
    ///   was triggered against `settledWindowFrame`, but the element's
    ///   bounds were read live at some unknowable moment DURING it. If the
    ///   window moved mid-walk, the rebuilt geometry may already be
    ///   expressed at the NEW position while this method would re-baseline
    ///   the anchor to the OLD frame -- and the very next tick would then
    ///   add the move's delta ON TOP of geometry that already contains it,
    ///   painting the highlight double-shifted. The tracker's latest
    ///   sampled frame (the live projection's `currentWindowFrame`,
    ///   maintained by ticks that kept running throughout the walk) is
    ///   compared against `settledWindowFrame`; past tolerance the apply is
    ///   rejected, and the frame change that caused it has already re-armed
    ///   the scheduling gates, so a fresh resolve runs once the window
    ///   settles again. Detection is bounded by the sampling cadence, like
    ///   every other decision in this class -- a move the sampler has not
    ///   seen yet cannot be vetoed here.
    /// - NOTHING-CHANGED WRITES ARE SKIPPED. When the rebuilt kind, the
    ///   re-baselined anchor, and the reset projection are all identical to
    ///   what is stored (`sampledAt` freshness deliberately not counting,
    ///   and `staticAdjustment` already identity), there is nothing to say:
    ///   writing anyway would cost a repaint per resolve and a `revision`
    ///   bump that can spuriously `.stale` a concurrent `update_annotation`
    ///   CAS. When only the projection differs (say, an issue code to
    ///   clear), it is patched through `applyAnchorProjections` alone,
    ///   which never bumps `revision`.
    ///
    /// The full commit also RESETS `staticAdjustment` TO IDENTITY. The
    /// rebuilt kind is absolute geometry at the element's true bounds, and
    /// the renderer paints stored geometry through `staticAdjustment` FIRST,
    /// then the live adjustment (`Annotation.effectiveAdjustment`); with
    /// both the anchor and projection re-baselined so the live adjustment is
    /// identity, any surviving frozen adjustment -- e.g. one folded in by an
    /// `anchor_resize` policy change, which keeps `.element` mode -- would
    /// permanently offset the ring from the element it was just resolved
    /// onto. Identity is the only value consistent with "the stored
    /// geometry IS the element's current position".
    ///
    /// The re-baselined anchor additionally records the resolved screen's
    /// CURRENT backing scale as `referenceScreenScale`, so a later `.pin`
    /// projection can compensate a cross-density move even if this display
    /// is disconnected by then -- see that property's own doc comment.
    private func applyResolvedElement(
        annotationId: String, kind: AnnotationKind, screenId: String, settledWindowFrame: CGRect
    ) -> ElementResolveApplyOutcome {
        // Resolved OUTSIDE the store transform below: `screensProvider` hops
        // to the main thread, and the transform runs with the store's lock
        // held, where it must do nothing but compute (see that method's
        // "transform MUST BE PURE" contract). nil -- the resolved screen
        // vanished between the walk and this write, a razor-thin window the
        // resolver's own post-walk snapshot guard already narrows -- records
        // "unknown", which the per-tick density lookup then serves live by
        // screen id instead.
        let newReferenceScale = screensProvider().first(where: { $0.id == screenId })?.backingScaleFactor

        var outcome = ElementResolveApplyOutcome.rejected("annotation_gone")
        var projectionOnlyPatch: AnchorProjection?
        let result = store.updateIfPossibleWithOutcome(id: annotationId, expectedRevision: nil) { live in
            guard let oldAnchor = live.anchor, oldAnchor.mode == .element else {
                outcome = .rejected("anchor_changed")
                return nil
            }
            if let latestSampledFrame = live.anchorProjection?.currentWindowFrame?.cgRect,
               !Self.frames(latestSampledFrame, closeTo: settledWindowFrame) {
                outcome = .rejected("window_moved")
                return nil
            }
            let newAnchor = AnnotationAnchor(
                mode: oldAnchor.mode,
                resize: oldAnchor.resize,
                target: oldAnchor.target,
                referenceWindowFrame: AnchorRect(settledWindowFrame),
                referenceScreenId: screenId,
                referenceScreenScale: newReferenceScale
                    ?? (screenId == oldAnchor.referenceScreenId ? oldAnchor.referenceScreenScale : nil),
                element: oldAnchor.element,
                createdAt: oldAnchor.createdAt
            )
            let resetProjection = AnchorProjection(
                state: .tracking,
                adjustment: .identity,
                effectiveScreenId: screenId,
                currentWindowFrame: AnchorRect(settledWindowFrame),
                sampledAt: now(),
                elementResolutionIssue: nil
            )
            if live.staticAdjustment.isIdentity,
               newAnchor == oldAnchor,
               Self.highlightKindsIdentical(kind, live.kind) {
                if let current = live.anchorProjection,
                   current.state == resetProjection.state,
                   current.adjustment == resetProjection.adjustment,
                   current.effectiveScreenId == resetProjection.effectiveScreenId,
                   current.currentWindowFrame == resetProjection.currentWindowFrame,
                   current.elementResolutionIssue == resetProjection.elementResolutionIssue {
                    outcome = .unchanged
                } else {
                    projectionOnlyPatch = resetProjection
                    outcome = .applied
                }
                return nil
            }
            let replacement = Annotation(
                id: live.id,
                screenId: live.screenId,
                kind: kind,
                colorHex: live.colorHex,
                label: live.label,
                appId: live.appId,
                appName: live.appName,
                opacity: live.opacity,
                offsetX: live.offsetX,
                offsetY: live.offsetY,
                zIndex: live.zIndex,
                anchor: newAnchor,
                staticAdjustment: .identity,
                anchorProjection: live.anchorProjection,
                revision: live.revision,
                createdAt: live.createdAt
            )
            outcome = .applied
            return (replacement, resetProjection)
        }
        switch result {
        case .updated:
            return outcome
        case .aborted:
            // The transform declined the combined write. When it left a
            // projection-only patch behind, land it now: this pair of store
            // calls is not one transaction, but the exposure is identical to
            // the one `recordElementIssue` already documents and accepts --
            // the kind/anchor are untouched here, so no intermediate state
            // pairs new geometry with a stale adjustment.
            if let projectionOnlyPatch {
                _ = store.applyAnchorProjections([annotationId: projectionOnlyPatch])
            }
            return outcome
        case .notFound:
            return .rejected("annotation_gone")
        case .stale:
            // Unreachable: no `expectedRevision` was supplied.
            return .rejected("store_rejected")
        case .rejected:
            return .rejected("store_rejected")
        }
    }

    /// Records a failed re-resolve's reason code onto the annotation's
    /// CURRENT projection (read fresh, not from tick-start state) without
    /// disturbing `state`/`adjustment`/`currentWindowFrame`.
    ///
    /// NOT A `samplingQueue` RACE: this whole method runs synchronously ON
    /// `samplingQueue` (see the class doc comment's "EVERY WRITE TO A
    /// STORED `AnchorProjection` HAPPENS ON `samplingQueue`" section), which
    /// is serial, so no other tick or element-resolve completion can
    /// interleave its own store calls between this method's `store.get`
    /// and `store.applyAnchorProjections` below.
    ///
    /// THE REAL EXPOSURE IS EXTERNAL: those two calls are independently
    /// locked, not one atomic transaction, and an MCP request thread is
    /// free to run between them. `update_annotation`'s handler commits a
    /// detach/re-anchor/resize-policy change through `AnnotationStore
    /// .updateWithOutcome(id:expectedRevision:transform:)` with an explicit
    /// `projectionOverride`, entirely under the store's own lock, from that
    /// thread -- not from `samplingQueue`. If that commit lands in the gap
    /// between this method's `get` and its `applyAnchorProjections`, this
    /// method's write (built from the snapshot taken BEFORE that commit)
    /// overwrites the freshly committed projection with the old
    /// `state`/`adjustment`/`currentWindowFrame`, silently discarding it.
    /// This window is narrow (an MCP call must land inside one
    /// `samplingQueue`-confined synchronous method) and the cost of losing
    /// it is bounded -- the next sampling tick re-derives `state`/
    /// `adjustment` from live evidence within one cadence interval
    /// regardless -- so it is accepted rather than closed with a second
    /// lock or a compare-and-swap.
    private func recordElementIssue(id: String, code: String) {
        guard let projection = store.get(id: id)?.anchorProjection else { return }
        guard projection.elementResolutionIssue != code else { return }
        let patched = AnchorProjection(
            state: projection.state,
            adjustment: projection.adjustment,
            effectiveScreenId: projection.effectiveScreenId,
            currentWindowFrame: projection.currentWindowFrame,
            sampledAt: projection.sampledAt,
            elementResolutionIssue: code
        )
        _ = store.applyAnchorProjections([id: patched])
    }

    /// Runs on `samplingQueue` (hopped there by `triggerElementReresolve`'s
    /// completion) to update this tracker's own scheduling bookkeeping.
    private func finishElementResolve(id: String, succeeded: Bool) {
        guard var state = elementStates[id] else { return }
        state.inFlight = false
        let attemptedFrame = state.inFlightFrame
        state.inFlightFrame = nil
        if succeeded {
            state.consecutiveFailures = 0
            // Arm the success gate ONLY when the frame this resolve ran
            // against is still the current one. If the window moved during
            // the walk (a tick already updated `lastKnownFrame`), the new
            // frame is still owed its own resolve once it settles, and
            // gating on a success that belongs to the OLD frame would
            // wrongly suppress it.
            if attemptedFrame == state.lastKnownFrame {
                state.resolvedForCurrentFrame = true
            }
        } else {
            state.consecutiveFailures += 1
            if state.consecutiveFailures == Self.elementResolveMaxConsecutiveFailures {
                Logger.shared.log(
                    "AnchorTracker: element re-resolve backoff engaged id=\(id) consecutiveFailures=\(state.consecutiveFailures)",
                    level: "WARN"
                )
            }
        }
        elementStates[id] = state
    }
}
