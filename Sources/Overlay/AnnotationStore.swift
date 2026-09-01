import Foundation

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
/// This is intentionally distinct from "no annotation with this id" so MCP
/// callers can give an actionable error without guessing which failure mode
/// produced it.
public enum AnnotationStoreResourceLimit: Equatable, Sendable {
    case payloadBytes(limit: Int, attempted: Int)
    case primitiveCount(limit: Int, attempted: Int)
    /// Inserting would exceed `DrawingDefaults.maxStoredAnnotations`. Unlike
    /// the other two cases, this one is about COUNT, not aggregate payload
    /// size -- an insertion can be rejected here while both the byte and
    /// primitive budgets still have room to spare.
    case annotationCount(limit: Int, attempted: Int)
}

/// Outcome for insertion.  An insertion either succeeds outright or is
/// rejected outright -- see `AnnotationStore.addWithOutcome`'s doc comment
/// for why the count cap (`DrawingDefaults.maxStoredAnnotations`) now
/// rejects a candidate insertion instead of evicting older annotations to
/// make room for it, exactly like the two aggregate-resource caps already
/// did.
public enum AnnotationStoreAddResult: Equatable, Sendable {
    case added
    case rejected(AnnotationStoreResourceLimit)
}

/// Outcome for replacement.  Keeping `notFound` distinct from `rejected`
/// lets the update handler retain its current no-such-id message while also
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

    /// Runs `body` with `lock` held and returns its result. Every read-only
    /// accessor below routes through here -- mutating methods call `withLock`
    /// directly -- purely to name that shared read shape in one place.
    private func withAnnotations<T>(_ body: ([Annotation]) -> T) -> T {
        withLock { body(annotations) }
    }

    /// Rebuilds a public `Annotation` with the store-selected identity. The
    /// model deliberately makes `id` immutable, so keeping an update's target
    /// id requires an explicit copy rather than a post-hoc assignment.
    private static func preservingIdentity(_ annotation: Annotation, id: String) -> Annotation {
        Annotation(
            id: id,
            screenId: annotation.screenId,
            kind: annotation.kind,
            colorHex: annotation.colorHex,
            label: annotation.label,
            appId: annotation.appId,
            appName: annotation.appName,
            opacity: annotation.opacity,
            offsetX: annotation.offsetX,
            offsetY: annotation.offsetY,
            zIndex: annotation.zIndex,
            revision: annotation.revision,
            createdAt: annotation.createdAt
        )
    }

    /// Appends `annotation`, subject to `AnnotationStore`'s resource caps --
    /// including the count cap `DrawingDefaults.maxStoredAnnotations` -- via
    /// `addWithOutcome`.
    ///
    /// Returns whether the annotation was actually stored. `false` means the
    /// insertion was rejected outright and nothing changed: no annotation was
    /// evicted, trimmed, or otherwise sacrificed to make room. See
    /// `addWithOutcome`'s doc comment for why a full store now refuses new
    /// work instead of making room for it.
    ///
    /// Compatibility wrapper for callers that only need a stored/not-stored
    /// answer. New MCP paths must use `addWithOutcome`, whose
    /// `AnnotationStoreResourceLimit` return value carries the specific
    /// reason so a caller can build an actionable error message.
    @discardableResult
    public func add(_ annotation: Annotation) -> Bool {
        switch addWithOutcome(annotation) {
        case .added: return true
        case .rejected: return false
        }
    }

    /// Atomically inserts an annotation subject to the count cap
    /// (`DrawingDefaults.maxStoredAnnotations`) and the aggregate vector/text
    /// retention caps (`maxRetainedAnnotationPayloadBytes` /
    /// `maxRetainedAnnotationPrimitives`). All three are rejection caps: on
    /// any of them, nothing is inserted, and nothing already stored is
    /// evicted, trimmed, or otherwise removed to make room.
    ///
    /// WHY REJECTION AND NOT EVICTION: this store used to evict the oldest
    /// annotations to stay under the count cap once it was full -- a second,
    /// silent way (alongside the now-deleted TTL/expiry mechanism) for a
    /// drawing to vanish without the AI or the user asking for it. The
    /// product decision is that an annotation stays until the AI or the user
    /// explicitly clears it (see `ClearScope`'s doc comment for the
    /// user-initiated half of that). A bounded store that refuses new work
    /// once it is full is honest about its own limit; one that quietly drops
    /// old work to make room for new work is not. Rejecting here also matches
    /// the behavior the payload-bytes and primitive-count caps already had,
    /// which is the inconsistency this resolves.
    @discardableResult
    public func addWithOutcome(_ annotation: Annotation) -> AnnotationStoreAddResult {
        var storedAnnotation = annotation

        let rejection: AnnotationStoreResourceLimit? = withLock {
            defer { assertResourceUsageConsistent() }
            // Checked before the aggregate-resource caps below so a caller
            // who is already at the ceiling gets the specific "too many
            // annotations" reason rather than a payload/primitive rejection
            // that happens to also be true.
            let attemptedCount = annotations.count + 1
            if attemptedCount > DrawingDefaults.maxStoredAnnotations {
                return .annotationCount(limit: DrawingDefaults.maxStoredAnnotations, attempted: attemptedCount)
            }
            // O(1), not a full re-walk of `annotations`: project what the
            // running total would become, WITHOUT mutating the real running
            // total yet, so a rejection below leaves it exactly as it was.
            let candidateUsage = usageAfter(removing: [], adding: [storedAnnotation])
            if let limit = resourceLimit(for: candidateUsage) {
                return limit
            }
            storedAnnotation.revision = nextRevision()
            annotations.append(storedAnnotation)
            trackAdded(storedAnnotation)
            return nil
        }

        if let rejection {
            return .rejected(rejection)
        }

        notifyChange()
        return .added
    }

    public func remove(id: String) -> Bool {
        let removedAnnotations: [Annotation] = withLock {
            defer { assertResourceUsageConsistent() }
            let matches = annotations.filter { $0.id == id }
            if !matches.isEmpty {
                annotations.removeAll { $0.id == id }
                for annotation in matches {
                    trackRemoved(annotation)
                }
            }
            return matches
        }
        releaseRasterAssets(in: removedAnnotations)
        let removed = !removedAnnotations.isEmpty
        if removed {
            notifyChange()
        }
        return removed
    }

    /// Replaces one existing annotation at its existing array slot.  Retaining
    /// the slot is what makes equal-z annotations stable after a restyle.  The
    /// MCP layer validates/builds the complete replacement before calling
    /// this, so a failed validation cannot leave a partially edited
    /// annotation behind.
    @discardableResult
    public func update(id: String, with replacement: Annotation) -> Bool {
        if case .updated = updateWithOutcome(id: id, with: replacement) {
            return true
        }
        return false
    }

    /// Atomically replaces an existing annotation only when the replacement
    /// still fits the aggregate retained-resource budgets.  A rejected
    /// replacement leaves the old annotation (and all of its raster
    /// ownership) intact.
    @discardableResult
    public func updateWithOutcome(
        id: String,
        with replacement: Annotation,
        expectedRevision: UInt64? = nil
    ) -> AnnotationStoreUpdateResult {
        let result: (old: Annotation?, rejection: AnnotationStoreResourceLimit?, stale: Bool) = withLock {
            defer { assertResourceUsageConsistent() }
            guard let index = annotations.firstIndex(where: { $0.id == id }) else {
                return (nil, nil, false)
            }
            guard expectedRevision == nil || annotations[index].revision == expectedRevision else {
                return (nil, nil, true)
            }
            let old = annotations[index]
            var storedReplacement = Self.preservingIdentity(replacement, id: id)
            // O(1): subtract `old`'s usage and add the normalized replacement's
            // instead of re-walking the whole store. A rejection below must leave the
            // real running total untouched, so this is a projection only.
            let candidateUsage = usageAfter(removing: [old], adding: [storedReplacement])
            if let rejection = resourceLimit(for: candidateUsage) {
                return (nil, rejection, false)
            }
            // The `id` argument selects the existing annotation. A
            // replacement is a new rendering payload for that stable object,
            // not an opportunity to change its identity: accepting a different
            // `replacement.id` made a successful update orphan the id the
            // caller was just told had been updated. Normalizing before the
            // budget projection also prevents an unretained replacement id
            // from incorrectly consuming payload budget.
            storedReplacement.revision = nextRevision()
            annotations[index] = storedReplacement
            trackRemoved(old)
            trackAdded(storedReplacement)
            return (old, nil, false)
        }
        if let rejection = result.rejection {
            return .rejected(rejection)
        }
        if result.stale {
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
        return .notFound
    }

    @discardableResult
    public func clearAll() -> Int {
        let removedAnnotations: [Annotation] = withLock {
            defer { assertResourceUsageConsistent() }
            let removed = annotations
            annotations.removeAll()
            // Everything is gone, so the running total is exactly zero --
            // no need to subtract usage annotation-by-annotation.
            runningPayloadBytes = 0
            runningPrimitiveCount = 0
            return removed
        }
        releaseRasterAssets(in: removedAnnotations)
        let removed = removedAnnotations.count
        if removed > 0 {
            notifyChange()
        }
        return removed
    }

    /// Removes exactly the annotations that are currently VISIBLE over
    /// `activeAppId`: the ones linked to it, plus the global ones (`appId ==
    /// nil`), which are drawn over every app and are therefore on screen too.
    ///
    /// The predicate is deliberately identical to
    /// `isVisible(_:onScreen:forApp:)`'s app clause, minus the screen filter
    /// -- "clear" removes what the user can see, on every screen, which is why
    /// it cannot simply call that predicate. Anything linked to a DIFFERENT
    /// app is left untouched: that is the whole point of scoping.
    ///
    /// Returns the number of annotations removed, for the tool/menu log line.
    @discardableResult
    public func clearVisible(forApp activeAppId: String?) -> Int {
        let removedAnnotations: [Annotation] = withLock {
            defer { assertResourceUsageConsistent() }
            let matches = annotations.filter { annotation in
                annotation.appId == nil || annotation.appId == activeAppId
            }
            if !matches.isEmpty {
                annotations.removeAll { annotation in
                    annotation.appId == nil || annotation.appId == activeAppId
                }
                for annotation in matches {
                    trackRemoved(annotation)
                }
            }
            return matches
        }
        releaseRasterAssets(in: removedAnnotations)
        let removed = removedAnnotations.count
        if removed > 0 {
            notifyChange()
        }
        return removed
    }

    public func getAll() -> [Annotation] {
        return withAnnotations { $0 }
    }

    /// Exact snapshot lookup used by verification and targeted diagnostics.
    /// Returning a value copy lets a compositor finish deterministically even
    /// if the annotation is removed on the main queue while its image is being
    /// encoded.
    public func get(id: String) -> Annotation? {
        return withAnnotations { $0.first(where: { $0.id == id }) }
    }

    /// Atomically snapshots an annotation and leases all raster pixels it
    /// references before another thread can remove the annotation. Removal
    /// releases store ownership only after this store's lock is dropped, so
    /// acquiring the raster lease while the lock is held closes the lookup →
    /// compositor handoff race without introducing a lock-order cycle.
    func renderSnapshot(id: String) -> (annotation: Annotation, rasterLease: RasterAssetStore.Lease)? {
        withAnnotations { storedAnnotations in
            guard let annotation = storedAnnotations.first(where: { $0.id == id }) else { return nil }
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
        return withAnnotations { ordered($0.filter { $0.screenId == screenId }) }
    }

    /// The single definition of "this annotation is visible on `screenId`
    /// while `activeAppId` is frontmost": it is on that screen AND (global OR
    /// linked to that app).
    ///
    /// Every caller that needs the answer -- `getForScreen(_:visibleForApp:)`
    /// (WHAT to paint) and `hasVisibleAnnotations(forScreenId:visibleForApp:)`
    /// (WHETHER the overlay window belongs on screen at all) -- is expressed
    /// on top of this one predicate, so those two questions cannot be answered
    /// inconsistently by two slightly different filters that drift apart.
    ///
    /// A `nil` `activeAppId` (nothing frontmost is known yet) matches only the
    /// global annotations, never everything: showing every app's annotations at
    /// once would be worse than showing none.
    public static func isVisible(_ annotation: Annotation, onScreen screenId: String, forApp activeAppId: String?) -> Bool {
        guard annotation.screenId == screenId else { return false }
        guard let annotationAppId = annotation.appId else { return true } // global
        return annotationAppId == activeAppId
    }

    /// The annotations that should actually be painted on `screenId` right now,
    /// per `isVisible(_:onScreen:forApp:)`, in paint order.
    ///
    /// `OverlayView.draw(_:)` calls it with the CURRENT frontmost app -- never
    /// the untagged-draw fallback -- because display must follow what is
    /// genuinely on screen this instant, whereas the fallback is a guess about
    /// what the user *meant* when they asked Claude to draw.
    public func getForScreen(_ screenId: String, visibleForApp activeAppId: String?) -> [Annotation] {
        return withAnnotations {
            ordered($0.filter { Self.isVisible($0, onScreen: screenId, forApp: activeAppId) })
        }
    }

    /// Whether ANY annotation is currently visible on `screenId` for
    /// `activeAppId`, by exactly the same predicate
    /// `getForScreen(_:visibleForApp:)` paints by.
    ///
    /// Exists because the emptiness question has one hot caller --
    /// `OverlayWindowController.refreshViewsNow`, deciding per screen whether
    /// the overlay window belongs on WindowServer's on-screen list at all --
    /// that previously materialised AND SORTED the whole filtered array just
    /// to read `.isEmpty`, once per screen per repaint, moments before
    /// `OverlayView.draw(_:)` rebuilt the identical array. `contains(where:)`
    /// short-circuits on the first match and allocates nothing.
    public func hasVisibleAnnotations(forScreenId screenId: String, visibleForApp activeAppId: String?) -> Bool {
        return withAnnotations { storedAnnotations in
            storedAnnotations.contains { Self.isVisible($0, onScreen: screenId, forApp: activeAppId) }
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

    /// Reports the aggregate resource usage for diagnostics/tests.
    ///
    /// Reads the incrementally maintained running total rather than
    /// re-walking every stored annotation -- see the running-total doc
    /// comment on `runningPayloadBytes` for why that is safe to trust.
    public var retainedResourceUsage: AnnotationStoreResourceUsage {
        withAnnotations { _ in
            AnnotationStoreResourceUsage(payloadBytes: runningPayloadBytes, primitiveCount: runningPrimitiveCount)
        }
    }

    /// Test-only verification hook: an independent full recompute over the
    /// stored annotations, exposed (internal, not `public`) purely so
    /// `@testable`-importing tests can assert the incrementally maintained
    /// running total never drifts from a true from-scratch recompute --
    /// without duplicating the byte/primitive-counting logic in the test
    /// target, which would only prove the test's own copy stayed in sync
    /// with itself. This mirrors, for tests, the same comparison
    /// `assertResourceUsageConsistent` performs on every mutation in DEBUG
    /// builds; it does not replace that check, which remains the mandatory
    /// safety net for catching a missed `trackAdded`/`trackRemoved` call.
    func fullRecomputeResourceUsageForTesting() -> AnnotationStoreResourceUsage {
        withAnnotations { Self.resourceUsage(of: $0) }
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
    /// (`remove`, `clearVisible`, the replace in `updateWithOutcome`) must
    /// call this so the running total never drifts. `clearAll` is the one
    /// exception: it resets both counters to 0 directly since nothing
    /// survives it.
    private func trackRemoved(_ annotation: Annotation) {
        let usage = Self.resourceUsage(of: annotation)
        runningPayloadBytes = Self.saturatedSubtract(runningPayloadBytes, usage.payloadBytes)
        runningPrimitiveCount = Self.saturatedSubtract(runningPrimitiveCount, usage.primitiveCount)
    }

    /// Debug-only invariant: the incrementally maintained running total must
    /// always equal a full recompute over the stored `annotations`.  This is
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
    ///
    /// What the two actually duplicate is the six top-level field lines; the
    /// kind walk is shared (`addKindUsage`) on purpose, since an iterative
    /// walk over a nested batch is not worth writing twice.  So the oracle is
    /// independent of the running total only in those six lines, and that is
    /// exactly what `AnnotationStoreTests`'
    /// `testFullRecomputeEqualsSumOfPerAnnotationUsage` can pin: adding a
    /// top-level field to one copy and forgetting the other fails a test
    /// instead of quietly disabling `assertResourceUsageConsistent`.  A
    /// mistake inside `addKindUsage` is made identically on both sides and no
    /// comparison between them can see it.
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
