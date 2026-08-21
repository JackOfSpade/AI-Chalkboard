import Foundation
import AppKit

/// How wide a "clear" reaches.
///
/// WHY `.active` IS THE DEFAULT everywhere (the MCP `clear` tool, the status
/// menu's first item): annotations are now per-app, so the store routinely
/// holds drawings for apps that are not on screen right now -- notes left on
/// DaVinci Resolve while the user is reading a Terminal window. A blanket
/// "clear everything" as the default would silently destroy work the user
/// cannot even see, with no undo, every time they only meant "get this off my
/// current screen". Defaulting to `.active` makes the destructive blast radius
/// equal to the visible blast radius: you can only clear what you are looking
/// at. `.all` remains one explicit argument (or one extra menu item) away.
public enum ClearScope: String {
    /// Clear only what is currently VISIBLE: annotations linked to the
    /// frontmost app, plus global (`appId == nil`) ones, which are on screen
    /// over that app too. "Clear what I can see."
    case active
    /// Clear every annotation for every app, visible or not.
    case all
}

/// Aggregate non-raster work retained by `AnnotationStore`.  Paths and text
/// are stored verbatim and parsed/shaped again on every repaint, so bounding
/// only the number of top-level annotations leaves a large resource gap for
/// many individually-valid payloads or batches.
public struct AnnotationStoreResourceUsage: Equatable, Sendable {
    public let payloadBytes: Int
    public let primitiveCount: Int

    public init(payloadBytes: Int, primitiveCount: Int) {
        self.payloadBytes = payloadBytes
        self.primitiveCount = primitiveCount
    }
}

/// The exact retained-resource constraint that rejected a candidate mutation.
/// This is intentionally distinct from a missing annotation or count-cap
/// eviction so MCP callers can give an actionable error without guessing.
public enum AnnotationStoreResourceLimit: Equatable, Sendable {
    case payloadBytes(limit: Int, attempted: Int)
    case primitiveCount(limit: Int, attempted: Int)
}

/// Outcome for insertion.  Existing count-cap behavior remains an accepted
/// insertion with an eviction count; resource exhaustion is never represented
/// as a successful insertion with a misleading zero eviction count.
public enum AnnotationStoreAddResult: Equatable, Sendable {
    case added(evicted: Int)
    case rejected(AnnotationStoreResourceLimit)
}

/// Outcome for replacement.  Keeping `notFound` distinct from `rejected`
/// lets the update handler retain its current race/expiry message while also
/// reporting an aggregate-resource failure accurately.
public enum AnnotationStoreUpdateResult: Equatable, Sendable {
    case updated
    case notFound
    /// The caller patched a stale snapshot. Re-fetch and rebuild the patch
    /// rather than silently overwriting a newer update.
    case stale
    case rejected(AnnotationStoreResourceLimit)
}

public final class AnnotationStore: @unchecked Sendable {
    public static let shared = AnnotationStore()
    
    private let lock = NSLock()
    private var annotations: [Annotation] = []
    private var revisionCounter: UInt64 = 0

    /// Running totals mirroring `Self.resourceUsage(of: annotations)`,
    /// maintained incrementally so `addWithOutcome`/`updateWithOutcome` don't
    /// have to re-walk every stored annotation (up to
    /// `DrawingDefaults.maxStoredAnnotations` of them, recursively for
    /// batches) on every single mutation. Every place that adds or removes an
    /// annotation from `annotations` MUST route through `trackAdded`/
    /// `trackRemoved` (or reset both to 0 when clearing everything) so these
    /// never drift from what a full recompute would report --
    /// `assertResourceUsageConsistent` is the debug-only tripwire for that.
    private var runningPayloadBytes: Int = 0
    private var runningPrimitiveCount: Int = 0

    public var onStoreChanged: (() -> Void)?

    /// Internal so tests and in-process simulations can own isolated stores;
    /// production continues to use `shared`.
    init() {}

    /// Runs `body` with `lock` held, releasing it via `defer` no matter how
    /// `body` returns.
    ///
    /// Every locking method in this class used to pair `lock.lock()` /
    /// `lock.unlock()` by hand, which deadlocks the whole process the moment
    /// any future edit adds an early `return` between the two calls. Routing
    /// everything through here makes that class of bug impossible instead of
    /// merely avoided-by-convention.
    ///
    /// Deliberately does NOT call `notifyChange()` -- callers that need to
    /// notify must do so AFTER `withLock` returns, once the lock is released.
    /// `notifyChange()` hops to the main thread and invokes
    /// `onStoreChanged`, which repaints; doing that while still holding
    /// `lock` would risk a reentrant call back into this store (e.g. from a
    /// repaint that reads annotations) blocking on a lock this same thread
    /// already holds.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Returns a snapshot containing only annotations whose absolute deadline
    /// has not elapsed. Expiry timers are an optimization for repaint latency,
    /// never the authority for whether an annotation is live: the main queue
    /// may be busy for an arbitrary amount of time.
    private func withLiveAnnotations<T>(_ body: ([Annotation]) -> T) -> T {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        var expired: [Annotation] = []
        let result = withLock {
            defer { assertResourceUsageConsistent() }
            expired = sweepExpiredLocked(now: now, uptime: uptime)
            return body(annotations)
        }

        if !expired.isEmpty {
            releaseRasterAssets(in: expired)
            notifyChange()
        }
        return result
    }

    /// Removes every expired annotation from `annotations` and decrements
    /// the running resource total to match, so the two never fall out of
    /// sync with each other. Must be called with `lock` held; the caller is
    /// responsible for releasing raster assets for the returned annotations
    /// AFTER the lock is released (see `releaseRasterAssets`'s doc comment).
    private func sweepExpiredLocked(now: Date, uptime: TimeInterval) -> [Annotation] {
        let expired = annotations.filter { $0.hasExpired(now: now, uptime: uptime) }
        guard !expired.isEmpty else { return [] }
        annotations.removeAll { $0.hasExpired(now: now, uptime: uptime) }
        for annotation in expired {
            trackRemoved(annotation)
        }
        return expired
    }

    /// Appends `annotation`, evicting the oldest stored annotations first if
    /// doing so would exceed `DrawingDefaults.maxStoredAnnotations`.
    ///
    /// Returns the number of annotations evicted to enforce that cap (0 in
    /// the normal case) so the MCP layer can report it back to the caller.
    ///
    /// WHY THE CAP EXISTS: free-draw annotations may deliberately persist
    /// until explicitly cleared -- that is
    /// documented design intent (see `ClearScope`'s doc comment) and this
    /// change does not touch it -- but this is a long-lived background
    /// server, so a caller that never passes `duration_seconds` and never
    /// calls `clear` grows this store without bound, and every repaint's
    /// O(n) filter (`getForScreen`) gets steadily more expensive as it does.
    /// Eviction is reported rather than silent -- logged at WARN and handed
    /// back as a return value -- specifically so a runaway caller is visible
    /// instead of just slowly degrading.
    @discardableResult
    public func add(_ annotation: Annotation, durationSeconds: Double? = nil) -> Int {
        switch addWithOutcome(annotation, durationSeconds: durationSeconds) {
        case .added(let evicted): return evicted
        case .rejected:
            // Compatibility wrapper for the original integer-returning API.
            // New MCP paths must use `addWithOutcome` so rejection cannot be
            // mistaken for a successful no-eviction insertion.
            return 0
        }
    }

    /// Atomically inserts an annotation subject to both the existing count
    /// cap and aggregate vector/text retention caps.  On resource rejection,
    /// no live annotation is inserted, replaced, or evicted.  Expired items
    /// may still be reaped as normal lifecycle cleanup.
    @discardableResult
    public func addWithOutcome(_ annotation: Annotation, durationSeconds: Double? = nil) -> AnnotationStoreAddResult {
        var storedAnnotation = annotation
        if storedAnnotation.expiresAt == nil,
           let duration = durationSeconds,
           duration > 0 {
            // The MCP layer rejects excessive durations. This defensive cap
            // protects direct/in-process callers too, before Date and
            // DispatchTime receive a finite-but-overflowing interval.
            let bounded = min(duration, DrawingDefaults.maxAnnotationDurationSeconds)
            storedAnnotation.expiresAt = Date().addingTimeInterval(bounded)
            storedAnnotation.expiresAtUptime = ProcessInfo.processInfo.systemUptime + bounded
        }
        // A caller may also supply `expiresAt` directly (no durationSeconds).
        // Derive the monotonic twin from the remaining wall-clock interval at
        // insertion time, so liveness decisions stay off the wall clock no
        // matter which way the deadline arrived. Anything already past due
        // pins to now rather than going negative.
        if storedAnnotation.expiresAtUptime == nil, let wallDeadline = storedAnnotation.expiresAt {
            let remaining = max(0, wallDeadline.timeIntervalSinceNow)
            if remaining.isFinite {
                storedAnnotation.expiresAtUptime = ProcessInfo.processInfo.systemUptime + remaining
            }
        }

        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        var expiredAnnotations: [Annotation] = []
        let mutation: (evicted: [Annotation], rejection: AnnotationStoreResourceLimit?) = withLock {
            defer { assertResourceUsageConsistent() }
            expiredAnnotations = sweepExpiredLocked(now: now, uptime: uptime)
            var candidate = annotations
            candidate.append(storedAnnotation)
            let overflow = candidate.count - DrawingDefaults.maxStoredAnnotations
            let evicted = overflow > 0 ? Array(candidate.prefix(overflow)) : []
            if overflow > 0 { candidate.removeFirst(overflow) }
            // O(evicted.count + 1), not a full re-walk of `candidate`: project
            // what the running total would become if this insertion (and any
            // cap eviction that comes with it) actually happened, WITHOUT
            // mutating the real running total yet -- a rejection below must
            // leave it exactly as it was.
            let candidateUsage = usageAfter(removing: evicted, adding: [storedAnnotation])
            if let rejection = resourceLimit(for: candidateUsage) {
                return ([], rejection)
            }
            storedAnnotation.revision = nextRevision()
            candidate[candidate.count - 1] = storedAnnotation
            annotations = candidate
            for evictedAnnotation in evicted {
                trackRemoved(evictedAnnotation)
            }
            trackAdded(storedAnnotation)
            return (evicted, nil)
        }
        releaseRasterAssets(in: expiredAnnotations + mutation.evicted)

        if let rejection = mutation.rejection {
            if !expiredAnnotations.isEmpty { notifyChange() }
            return .rejected(rejection)
        }
        let evicted = mutation.evicted.count

        if evicted > 0 {
            Logger.shared.log(
                "AnnotationStore: exceeded maxStoredAnnotations cap (\(DrawingDefaults.maxStoredAnnotations)); evicted \(evicted) oldest annotation(s) to stay under it.",
                level: "WARN"
            )
        }

        notifyChange()

        if let remaining = storedAnnotation.remainingSeconds(
            now: Date(), uptime: ProcessInfo.processInfo.systemUptime
        ) {
            if remaining.isFinite, remaining <= DrawingDefaults.maxAnnotationDurationSeconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    _ = self?.remove(id: storedAnnotation.id)
                }
            }
        }

        return .added(evicted: evicted)
    }

    public func remove(id: String) -> Bool {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let result: (removedLive: [Annotation], expired: [Annotation]) = withLock {
            defer { assertResourceUsageConsistent() }
            // Sweep expiry first so the id-match below can never double-count
            // (or double-decrement) an annotation that is both expired and a
            // match for `id`.
            let expired = sweepExpiredLocked(now: now, uptime: uptime)
            let removedLive = annotations.filter { $0.id == id }
            if !removedLive.isEmpty {
                annotations.removeAll { $0.id == id }
                for annotation in removedLive {
                    trackRemoved(annotation)
                }
            }
            return (removedLive, expired)
        }
        releaseRasterAssets(in: result.expired + result.removedLive)
        let removed = !result.removedLive.isEmpty
        if removed || !result.expired.isEmpty {
            notifyChange()
        }
        return removed
    }

    /// Replaces one live annotation at its existing array slot.  Retaining the
    /// slot is what makes equal-z annotations stable after a restyle.  The MCP
    /// layer validates/builds the complete replacement before calling this, so
    /// a failed validation cannot leave a partially edited annotation behind.
    @discardableResult
    public func update(id: String, with replacement: Annotation) -> Bool {
        if case .updated = updateWithOutcome(id: id, with: replacement) {
            return true
        }
        return false
    }

    /// Atomically replaces a live annotation only when the replacement still
    /// fits the aggregate retained-resource budgets.  A rejected replacement
    /// leaves the old annotation (and all of its raster ownership) intact.
    @discardableResult
    public func updateWithOutcome(
        id: String,
        with replacement: Annotation,
        expectedRevision: UInt64? = nil
    ) -> AnnotationStoreUpdateResult {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let result: (old: Annotation?, expired: [Annotation], rejection: AnnotationStoreResourceLimit?, stale: Bool) = withLock {
            defer { assertResourceUsageConsistent() }
            let expired = sweepExpiredLocked(now: now, uptime: uptime)
            guard let index = annotations.firstIndex(where: { $0.id == id }) else {
                return (nil, expired, nil, false)
            }
            guard expectedRevision == nil || annotations[index].revision == expectedRevision else {
                return (nil, expired, nil, true)
            }
            let old = annotations[index]
            // O(1): subtract `old`'s usage and add `replacement`'s, instead of
            // re-walking the whole store. A rejection below must leave the
            // real running total untouched, so this is a projection only.
            let candidateUsage = usageAfter(removing: [old], adding: [replacement])
            if let rejection = resourceLimit(for: candidateUsage) {
                return (nil, expired, rejection, false)
            }
            var storedReplacement = replacement
            storedReplacement.revision = nextRevision()
            annotations[index] = storedReplacement
            trackRemoved(old)
            trackAdded(storedReplacement)
            return (old, expired, nil, false)
        }
        releaseRasterAssets(in: result.expired)
        if let rejection = result.rejection {
            if !result.expired.isEmpty { notifyChange() }
            return .rejected(rejection)
        }
        if result.stale {
            if !result.expired.isEmpty { notifyChange() }
            return .stale
        }
        if let old = result.old {
            let retained = Set(replacement.kind.rasterAssetIds)
            for assetId in old.kind.rasterAssetIds where !retained.contains(assetId) {
                _ = RasterAssetStore.shared.release(id: assetId)
            }
            notifyChange()
            return .updated
        }
        if !result.expired.isEmpty { notifyChange() }
        return .notFound
    }

    @discardableResult
    public func clearAll() -> Int {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let result: (live: [Annotation], expired: [Annotation]) = withLock {
            defer { assertResourceUsageConsistent() }
            let removed = annotations
            annotations.removeAll()
            // Everything is gone, so the running total is exactly zero --
            // no need to subtract usage annotation-by-annotation.
            runningPayloadBytes = 0
            runningPrimitiveCount = 0
            return (
                removed.filter { !($0.hasExpired(now: now, uptime: uptime)) },
                removed.filter { $0.hasExpired(now: now, uptime: uptime) }
            )
        }
        releaseRasterAssets(in: result.expired + result.live)
        let removed = result.live.count
        if removed > 0 || !result.expired.isEmpty {
            notifyChange()
        }
        return removed
    }

    /// Removes exactly the annotations that are currently VISIBLE over
    /// `activeAppId`: the ones linked to it, plus the global ones (`appId ==
    /// nil`), which are drawn over every app and are therefore on screen too.
    ///
    /// The predicate is deliberately identical to
    /// `getForScreen(_:visibleForApp:)`'s, minus the screen filter -- "clear"
    /// removes what the user can see, on every screen. Anything linked to a
    /// DIFFERENT app is left untouched: that is the whole point of scoping.
    ///
    /// Returns the number of annotations removed, for the tool/menu log line.
    @discardableResult
    public func clearVisible(forApp activeAppId: String?) -> Int {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let result: (removedLive: [Annotation], expired: [Annotation]) = withLock {
            defer { assertResourceUsageConsistent() }
            // Sweep expiry first so the visibility filter below never needs
            // its own "and not expired" clause -- nothing expired survives
            // in `annotations` past this point.
            let expired = sweepExpiredLocked(now: now, uptime: uptime)
            let removedLive = annotations.filter { annotation in
                annotation.appId == nil || annotation.appId == activeAppId
            }
            if !removedLive.isEmpty {
                annotations.removeAll { annotation in
                    annotation.appId == nil || annotation.appId == activeAppId
                }
                for annotation in removedLive {
                    trackRemoved(annotation)
                }
            }
            return (removedLive, expired)
        }
        releaseRasterAssets(in: result.expired + result.removedLive)
        let removed = result.removedLive.count
        if removed > 0 || !result.expired.isEmpty {
            notifyChange()
        }
        return removed
    }

    public func getAll() -> [Annotation] {
        return withLiveAnnotations { $0 }
    }

    /// Exact snapshot lookup used by verification and targeted diagnostics.
    /// Returning a value copy lets a compositor finish deterministically even
    /// if the annotation expires on the main queue while its image is being
    /// encoded.
    public func get(id: String) -> Annotation? {
        return withLiveAnnotations { $0.first(where: { $0.id == id }) }
    }

    /// Atomically snapshots an annotation and leases all raster pixels it
    /// references before another thread can remove the annotation. Removal
    /// releases store ownership only after this store's lock is dropped, so
    /// acquiring the raster lease while the lock is held closes the lookup →
    /// compositor handoff race without introducing a lock-order cycle.
    func renderSnapshot(id: String) -> (annotation: Annotation, rasterLease: RasterAssetStore.Lease)? {
        withLiveAnnotations { liveAnnotations in
            guard let annotation = liveAnnotations.first(where: { $0.id == id }) else { return nil }
            let lease = RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)
            return (annotation, lease)
        }
    }

    /// Every annotation on `screenId`, with NO per-app filtering.
    ///
    /// Its one caller is `OverlayView.draw(_:)` while capture visibility is ON:
    /// that debug mode must render everything, because the app whose
    /// annotations are being verified is by definition NOT the frontmost one at
    /// the moment Claude takes the screenshot. Filtering here would prevent the
    /// overlay from drawing them even on compatible capture paths. Normal
    /// painting uses `getForScreen(_:visibleForApp:)`.
    public func getForScreen(_ screenId: String) -> [Annotation] {
        return withLiveAnnotations { ordered($0.filter { $0.screenId == screenId }) }
    }

    /// The annotations that should actually be painted on `screenId` right now:
    /// those on that screen AND (global OR linked to `activeAppId`).
    ///
    /// This is the single definition of "visible". `OverlayView.draw(_:)` calls
    /// it with the CURRENT frontmost app -- never the untagged-draw fallback --
    /// because display must follow what is genuinely on screen this instant,
    /// whereas the fallback is a guess about what the user *meant* when they
    /// asked Claude to draw.
    ///
    /// A `nil` `activeAppId` (nothing frontmost is known yet) shows only the
    /// global annotations, never everything: showing every app's annotations at
    /// once would be worse than showing none.
    public func getForScreen(_ screenId: String, visibleForApp activeAppId: String?) -> [Annotation] {
        return withLiveAnnotations {
            ordered($0.filter { annotation in
                guard annotation.screenId == screenId else { return false }
                guard let annotationAppId = annotation.appId else { return true } // global
                return annotationAppId == activeAppId
            })
        }
    }

    /// Swift's general `sort` does not promise stability.  Carry the original
    /// array position as an explicit secondary key so z-index ties continue to
    /// paint in insertion order, exactly like annotations did before z-index
    /// existed.
    private func ordered(_ values: [Annotation]) -> [Annotation] {
        values.enumerated().sorted { lhs, rhs in
            lhs.element.zIndex == rhs.element.zIndex
                ? lhs.offset < rhs.offset
                : lhs.element.zIndex < rhs.element.zIndex
        }.map(\.element)
    }

    /// Notifies `onStoreChanged`, always via `MainThread.enqueue` -- NOT
    /// `MainThread.async`.
    ///
    /// The difference matters here specifically: `MainThread.async` runs
    /// inline when already on the main thread, but every mutating method
    /// above (`add`, `remove`, `clearAll`, `clearVisible`) can itself be
    /// called FROM the main thread (e.g. the status-bar menu's "Clear"
    /// action), and `onStoreChanged` repaints the overlay. Running that
    /// repaint inline, re-entrantly, from inside the very call stack that is
    /// still mutating `annotations` is exactly what `enqueue`'s unconditional
    /// hop avoids: it always schedules the repaint as a NEW main-thread turn,
    /// after the mutating call has fully returned, never nested inside it.
    private func notifyChange() {
        MainThread.enqueue { [weak self] in
            self?.onStoreChanged?()
        }
    }

    /// Raster pixels are owned by their containing annotation, including
    /// recursively nested batch items. Release outside the store lock: image
    /// decoding/storage has its own lock and must never participate in a lock
    /// ordering cycle with AnnotationStore.
    private func releaseRasterAssets(in removed: [Annotation]) {
        for annotation in removed {
            for assetId in annotation.kind.rasterAssetIds {
                _ = RasterAssetStore.shared.release(id: assetId)
            }
        }
    }

    /// Reports the live aggregate resource usage for diagnostics/tests.  The
    /// same expiry authority as every read is used, so the result never counts
    /// an annotation merely waiting for its main-queue expiry callback.
    ///
    /// Reads the incrementally maintained running total (after sweeping
    /// expiry) rather than re-walking every stored annotation -- see the
    /// running-total doc comment on `runningPayloadBytes` for why that is
    /// safe to trust.
    public var retainedResourceUsage: AnnotationStoreResourceUsage {
        withLiveAnnotations { _ in
            AnnotationStoreResourceUsage(payloadBytes: runningPayloadBytes, primitiveCount: runningPrimitiveCount)
        }
    }

    /// Test-only verification hook: an independent full recompute over the
    /// live annotations, exposed (internal, not `public`) purely so
    /// `@testable`-importing tests can assert the incrementally maintained
    /// running total never drifts from a true from-scratch recompute --
    /// without duplicating the byte/primitive-counting logic in the test
    /// target, which would only prove the test's own copy stayed in sync
    /// with itself. This mirrors, for tests, the same comparison
    /// `assertResourceUsageConsistent` performs on every mutation in DEBUG
    /// builds; it does not replace that check, which remains the mandatory
    /// safety net for catching a missed `trackAdded`/`trackRemoved` call.
    func fullRecomputeResourceUsageForTesting() -> AnnotationStoreResourceUsage {
        withLiveAnnotations { Self.resourceUsage(of: $0) }
    }

    /// Thresholds a precomputed usage snapshot against the aggregate
    /// retained-resource caps. Split out from usage computation so callers
    /// can pass a cheaply/incrementally derived usage (see `usageAfter`)
    /// instead of re-walking every stored annotation just to check a limit.
    private func resourceLimit(for usage: AnnotationStoreResourceUsage) -> AnnotationStoreResourceLimit? {
        if usage.payloadBytes > DrawingDefaults.maxRetainedAnnotationPayloadBytes {
            return .payloadBytes(
                limit: DrawingDefaults.maxRetainedAnnotationPayloadBytes,
                attempted: usage.payloadBytes
            )
        }
        if usage.primitiveCount > DrawingDefaults.maxRetainedAnnotationPrimitives {
            return .primitiveCount(
                limit: DrawingDefaults.maxRetainedAnnotationPrimitives,
                attempted: usage.primitiveCount
            )
        }
        return nil
    }

    /// Projects what the running total would become after removing every
    /// annotation in `removed` and adding every annotation in `added`,
    /// WITHOUT mutating `runningPayloadBytes`/`runningPrimitiveCount`.  Used
    /// to check a candidate mutation against the resource caps before
    /// committing to it -- `addWithOutcome` and `updateWithOutcome` must be
    /// able to reject a candidate while leaving the real running total
    /// exactly as it was.  Cost is O(removed.count + added.count), never a
    /// full walk of `annotations`.
    private func usageAfter(removing removed: [Annotation], adding added: [Annotation]) -> AnnotationStoreResourceUsage {
        var payloadBytes = runningPayloadBytes
        var primitiveCount = runningPrimitiveCount
        for annotation in removed {
            let usage = Self.resourceUsage(of: annotation)
            payloadBytes = Self.saturatedSubtract(payloadBytes, usage.payloadBytes)
            primitiveCount = Self.saturatedSubtract(primitiveCount, usage.primitiveCount)
        }
        for annotation in added {
            let usage = Self.resourceUsage(of: annotation)
            payloadBytes = Self.saturatedAdd(payloadBytes, usage.payloadBytes)
            primitiveCount = Self.saturatedAdd(primitiveCount, usage.primitiveCount)
        }
        return AnnotationStoreResourceUsage(payloadBytes: payloadBytes, primitiveCount: primitiveCount)
    }

    /// Adds `annotation`'s resource usage to the running total.  Must be
    /// called with `lock` held, exactly once per annotation actually
    /// inserted into `annotations`.
    private func trackAdded(_ annotation: Annotation) {
        let usage = Self.resourceUsage(of: annotation)
        runningPayloadBytes = Self.saturatedAdd(runningPayloadBytes, usage.payloadBytes)
        runningPrimitiveCount = Self.saturatedAdd(runningPrimitiveCount, usage.primitiveCount)
    }

    /// Removes `annotation`'s resource usage from the running total.  Must
    /// be called with `lock` held, exactly once per annotation actually
    /// removed from `annotations` -- every removal/replacement path
    /// (`remove`, `clearVisible`, the expiry sweep in `sweepExpiredLocked`,
    /// cap eviction and rejection-safe replace in `addWithOutcome`/
    /// `updateWithOutcome`) must call this so the running total never drifts.
    /// `clearAll` is the one exception: it resets both counters to 0 directly
    /// since nothing survives it.
    private func trackRemoved(_ annotation: Annotation) {
        let usage = Self.resourceUsage(of: annotation)
        runningPayloadBytes = Self.saturatedSubtract(runningPayloadBytes, usage.payloadBytes)
        runningPrimitiveCount = Self.saturatedSubtract(runningPrimitiveCount, usage.primitiveCount)
    }

    /// Debug-only invariant: the incrementally maintained running total must
    /// always equal a full recompute over the live `annotations`.  This is
    /// the tripwire for a missed `trackAdded`/`trackRemoved` call on any
    /// mutation path -- a silent drift here would slowly make the store
    /// reject perfectly valid draws (or under-count a caller that is
    /// genuinely over budget), degrading for a long time before anyone
    /// noticed, so any mismatch crashes immediately in debug/test builds
    /// instead.  Called with `lock` already held (every call site uses
    /// `defer { assertResourceUsageConsistent() }` at the top of its
    /// `withLock` closure), so it only ever observes a fully-settled state,
    /// never a torn intermediate one, and cannot fire spuriously just
    /// because another thread is concurrently using the store -- concurrent
    /// callers are simply serialized by the same lock this check runs under.
    /// Compiled out entirely in release builds, so it costs nothing in
    /// production, exactly where the O(n)-per-mutation cost this file
    /// removes needed to stop mattering.
    private func assertResourceUsageConsistent() {
        #if DEBUG
        let recomputed = Self.resourceUsage(of: annotations)
        assert(
            recomputed.payloadBytes == runningPayloadBytes,
            "AnnotationStore running payloadBytes drifted from a full recompute: incremental=\(runningPayloadBytes) recomputed=\(recomputed.payloadBytes)"
        )
        assert(
            recomputed.primitiveCount == runningPrimitiveCount,
            "AnnotationStore running primitiveCount drifted from a full recompute: incremental=\(runningPrimitiveCount) recomputed=\(recomputed.primitiveCount)"
        )
        #endif
    }

    /// Full recompute over every stored annotation.  Kept -- rather than
    /// replaced outright by the incremental running total -- specifically to
    /// serve as the independent oracle `assertResourceUsageConsistent`
    /// checks the running total against.
    private static func resourceUsage(of annotations: [Annotation]) -> AnnotationStoreResourceUsage {
        annotations.reduce(into: AnnotationStoreResourceUsage(payloadBytes: 0, primitiveCount: 0)) { usage, annotation in
            addPayload(&usage, annotation.id)
            addPayload(&usage, annotation.screenId)
            addPayload(&usage, annotation.colorHex)
            addPayload(&usage, annotation.label)
            addPayload(&usage, annotation.appId)
            addPayload(&usage, annotation.appName)
            addKindUsage(&usage, annotation.kind)
        }
    }

    /// Same computation as `resourceUsage(of: [Annotation])`, for exactly one
    /// annotation.  Used by the incremental add/remove tracking so a single
    /// annotation's contribution can be added to or subtracted from the
    /// running total without touching any other stored annotation.
    private static func resourceUsage(of annotation: Annotation) -> AnnotationStoreResourceUsage {
        var usage = AnnotationStoreResourceUsage(payloadBytes: 0, primitiveCount: 0)
        addPayload(&usage, annotation.id)
        addPayload(&usage, annotation.screenId)
        addPayload(&usage, annotation.colorHex)
        addPayload(&usage, annotation.label)
        addPayload(&usage, annotation.appId)
        addPayload(&usage, annotation.appName)
        addKindUsage(&usage, annotation.kind)
        return usage
    }

    /// Iterative rather than recursive to keep a programmatically constructed
    /// nested batch from consuming the process stack before its primitive cap
    /// can reject it.
    private static func addKindUsage(_ usage: inout AnnotationStoreResourceUsage, _ root: AnnotationKind) {
        var stack = [root]
        while let kind = stack.popLast() {
            switch kind {
            case .vectorPath(let data, let strokeColor, _, _, let fillColor, _, _, _, _, _):
                addPrimitive(&usage)
                addPayload(&usage, data)
                addPayload(&usage, strokeColor)
                addPayload(&usage, fillColor)
            case .image(let assetId, _, _, _, _, _, _):
                addPrimitive(&usage)
                addPayload(&usage, assetId)
            case .text(let text, _, _, _, let textColor, let backgroundColor, _, _, _):
                addPrimitive(&usage)
                addPayload(&usage, text)
                addPayload(&usage, textColor)
                addPayload(&usage, backgroundColor)
            case .batch(let items):
                for item in items {
                    addPayload(&usage, item.colorHex)
                    addPayload(&usage, item.label)
                    stack.append(item.kind)
                }
            }
        }
    }

    private static func addPayload(_ usage: inout AnnotationStoreResourceUsage, _ value: String?) {
        guard let value else { return }
        usage = AnnotationStoreResourceUsage(
            payloadBytes: saturatedAdd(usage.payloadBytes, value.lengthOfBytes(using: .utf8)),
            primitiveCount: usage.primitiveCount
        )
    }

    private static func addPrimitive(_ usage: inout AnnotationStoreResourceUsage) {
        usage = AnnotationStoreResourceUsage(
            payloadBytes: usage.payloadBytes,
            primitiveCount: saturatedAdd(usage.primitiveCount, 1)
        )
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    /// Mirrors `saturatedAdd`'s overflow protection for the subtraction side
    /// of the running total: clamps at 0 instead of going negative. Every
    /// caller only ever subtracts usage that was previously added for the
    /// same annotation, so this should be an exact subtraction in practice --
    /// the clamp is defense in depth, not a correctness dependency.
    private static func saturatedSubtract(_ lhs: Int, _ rhs: Int) -> Int {
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? 0 : max(0, difference)
    }

    /// Called with `lock` held. Wraparound would require 2^64 successful
    /// mutations in one process lifetime; a newly stored annotation still has
    /// a distinct revision from ordinary stale snapshots.
    private func nextRevision() -> UInt64 {
        revisionCounter &+= 1
        return revisionCounter
    }
}
