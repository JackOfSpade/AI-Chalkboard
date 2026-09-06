import Foundation
#if os(macOS)
import AppKit
import Darwin
#endif
// Nothing below this line needs AppKit or Darwin directly (both imports
// above exist only because macOS's `OverlayWindowController`/process-
// identity calls used to require them transitively); everything in this
// file is policy over `SuspensionLeaseStorage` (which has its own
// `#if os(macOS)/#elseif os(Windows)` split) plus plain Foundation types, so
// it is single-sourced across both platforms rather than duplicated into two
// `#if os(macOS)/#elseif os(Windows)` branches -- see the `pid_t` ->
// `Int32` note on `OperationResult` below for the one type-level adjustment
// that made that possible.

/// Durable, cross-process source of truth for temporary overlay suspension.
///
/// The registry is deliberately the authority; distributed notifications are
/// only wake-up hints.  That means a late, duplicated, or forged notification
/// can at most cause an extra read of the current state -- never replay a
/// presentation command.
public final class SuspensionLeaseCoordinator: @unchecked Sendable {
    public static let shared = SuspensionLeaseCoordinator()

    public struct Snapshot: Equatable {
        public let generation: UInt64
        public let annotationsSuspended: Bool
        public let activeLeaseCount: Int
        public let isBootstrapped: Bool
        public let nextExpiryInSeconds: Int?
        public let error: String?
    }

    public struct OperationResult: Equatable {
        public let success: Bool
        public let error: String?
        public let leaseToken: String?
        public let reused: Bool
        public let alreadyReleased: Bool
        public let generation: UInt64
        public let annotationsSuspended: Bool
        public let activeLeaseCount: Int
        public let leaseExpiresInSeconds: Int?
        /// True only when the final durable generation was stable across a
        /// conservative presentation observation. An unsuspended release is a
        /// linearized registry snapshot, not proof that every peer has painted.
        public let peerPresentationSettled: Bool
        public let scope: String
        // `Int32`, not `pid_t`: `pid_t` is a Darwin-only typealias (itself
        // just `Int32` under the hood) and this struct is shared, unmodified
        // source between the macOS and Windows branches of
        // `SuspensionQuiescence.swift`. Spelling the field as `Int32`
        // directly is not a behavior or ABI change on macOS -- `pid_t` IS
        // `Int32`, not a distinct type Swift enforces separately -- and it
        // is also exactly the type `GetWindowThreadProcessId`'s `DWORD` out-
        // parameter narrows to on the Windows branch (see that file), so one
        // struct definition serves both platforms.
        public let candidatePIDs: [Int32]
        public let candidatePIDsTruncated: Bool
        public let visibleOwnerPIDs: [Int32]
        public let visibleWindowNumbers: [Int]
        public let discoveryErrors: [String]
    }

    // internal: SuspensionLeaseStorage.swift's readState constructs this
    // during the schema-3 -> schema-4 migration.
    struct Lease: Codable, Equatable {
        let token: String
        let ownerPID: Int32
        let ownerInstanceNonce: String?
        let expiresAtUptime: Double
        let idempotencyKey: String?
    }

    // internal: SuspensionLeaseStorage.swift's readState/writeState decode
    // and encode this type.
    struct PersistedState: Codable {
        var schemaVersion = 4
        /// `kern.boottime`, not uptime, identifies the OS boot which created
        /// this registry. Uptime-only comparisons cannot distinguish a reboot
        /// from an old state whose values happen to be small.
        var bootSessionIdentifier: String
        /// Random identity for THIS registry file, minted immediately before
        /// the file is written (see `withLockedState` /
        /// `withLockedPresentationState`) and never when a state is merely
        /// synthesized during a read.
        ///
        /// BUG FIX (the generation ratchet froze permanently on a recreated
        /// file): `recordState` rejects any read whose generation is below the
        /// high-water mark, so a stale read cannot roll the cache backwards.
        /// But deleting the state file WITHOUT rebooting -- a documented
        /// manual-troubleshooting action -- makes every process start reading
        /// a brand-new file at generation 0, which is indistinguishable from a
        /// stale read by generation alone. The ratchet then rejected the real,
        /// current state indefinitely: `prune` on an empty state reports no
        /// change, so plain `reconcile()` never rewrites the file, and only
        /// acquire/release advance the generation, by one each. The cached
        /// `annotationsSuspended` could therefore stay wrong for an unbounded
        /// number of operations, and MCP callers kept reading that wrong value.
        ///
        /// A differing epoch can only mean the file was recreated, which is
        /// exactly the signal the generation alone could not carry.
        ///
        /// OPTIONAL for backward compatibility: a registry written by a build
        /// that predates this field decodes with `nil` here. A nil epoch on
        /// either side is treated as "no evidence of recreation" and never
        /// resets the ratchet, so an older file degrades to exactly the
        /// previous behaviour instead of failing closed or resetting
        /// spuriously. `bootSessionIdentifier` continues to cover the reboot
        /// case; this covers same-boot recreation, and the two are
        /// independent.
        ///
        /// BUG FIX (a 2 Hz ratchet rollback on a machine that has never
        /// written the registry): this used to be minted by
        /// `init(bootSessionIdentifier:)`, which `readState` calls to
        /// synthesize a state for a missing or empty file. Every reconcile --
        /// AppDelegate runs one twice a second -- therefore produced a
        /// DIFFERENT epoch for the very same absent file, `recordState` read
        /// that as "the file was recreated", and the high-water mark it exists
        /// to defend was zeroed on every tick. The generation-0 read was then
        /// applied unconditionally, repainting every overlay and re-logging
        /// twice a second. An absent file instead carries ONE stable identity,
        /// `absentFileEpoch`, so repeated reads of it are indistinguishable --
        /// while the real-epoch -> sentinel transition a DELETED registry
        /// produces still trips the reset exactly once, which is what lets a
        /// snapshot pinned to a file that no longer exists self-heal instead of
        /// ordering the overlays out for the rest of the session. A random
        /// epoch is minted only when a real file is about to be written.
        var instanceEpoch: String?

        /// The identity carried by a state synthesized for a MISSING or EMPTY
        /// registry file. Deliberately a constant rather than a fresh UUID (see
        /// `instanceEpoch`), and deliberately never persisted:
        /// `withLockedState`/`withLockedPresentationState` replace it with a
        /// real UUID immediately before `writeState`, because a file that
        /// exists must be distinguishable from the absence it replaced.
        static let absentFileEpoch = "<no-registry-file>"
        var generation: UInt64 = 0
        var lastUpdatedUptime: Double = 0
        var leases: [Lease] = []
        var idempotencyTokens: [String: String] = [:]
        /// Expired/released token -> monotonic expiry. Tombstones are bounded
        /// and intentionally short: they make lost cleanup responses safe,
        /// not arbitrary historical tokens valid forever.
        var releasedTokens: [String: Double] = [:]

        /// `instanceEpoch` defaults to nil, which is exactly the shape a
        /// pre-epoch registry decodes to; every synthesizing call site in
        /// `readState` passes one explicitly -- `absentFileEpoch` for a
        /// missing/empty file, a fresh UUID for the old-boot reset, which is a
        /// genuinely NEW file about to overwrite a different one.
        init(bootSessionIdentifier: String, instanceEpoch: String? = nil) {
            self.bootSessionIdentifier = bootSessionIdentifier
            self.instanceEpoch = instanceEpoch
        }
    }

    private static let tombstoneLifetime: Double = 120
    private static let maximumActiveLeases = 64
    private static let maximumTombstones = 64

    // internal: SuspensionLeaseStorage.swift's openSecureDirectory and
    // validateHeldDirectory read this to open/verify the registry directory.
    let storageDirectory: URL
    private let lockURL: URL
    private let stateURL: URL
    private let bootSessionIdentifier: String?
    /// The numeric (`kern.boottime`) identity of the boot `bootSessionIdentifier`
    /// names, used only to recognise a registry written by the previous build --
    /// see `isSameBootSession`.
    ///
    /// nil when the identity was SUPPLIED by a caller: an injected identity
    /// names a boot this process cannot measure, so a stored number must not be
    /// matched against the real machine's boot time on its behalf. That is what
    /// makes "a registry from a genuinely different boot" expressible in a test
    /// on a machine whose own boot time happens to sit next to the fixture.
    // internal: SuspensionLeaseStorage.swift's readState passes this to
    // isSameBootSession/validateState.
    let legacyBootSeconds: Double?
    private let instanceNonce: String
    private let mutationSettleHook: (() -> Void)?
    // internal: SuspensionLeaseStorage.swift's writeState calls this
    // immediately before the atomic rename that installs new state.
    let storagePrecommitHook: (() -> Void)?
    private let controlsPresentation: Bool
    private let stateLock = NSLock()
    /// Serializes only scheduling bookkeeping.  The actual durable read stays
    /// on `reconciliationQueue`, so a 2 Hz timer or a burst of distributed
    /// notifications cannot put filesystem work on the platform UI thread or
    /// build an unbounded queue of duplicate reads.
    private let reconciliationScheduleLock = NSLock()
    private let reconciliationQueue = DispatchQueue(
        label: "com.aichalkboard.suspension-reconciliation",
        qos: .utility
    )
    private var reconciliationWorkerScheduled = false
    private var reconciliationPending = false
    private var pendingReconciliationGeneration: UInt64?
    /// A launch-only readiness hand-off.  It is deliberately one slot rather
    /// than a growing completion list: ordinary timer/DNC calls do not need a
    /// callback, and MCP has exactly one startup gate per process.
    private var bootstrapCompletion: ((Snapshot) -> Void)?
    private var lastAppliedGeneration: UInt64 = 0
    private var hasAppliedGeneration = false
    /// The `instanceEpoch` the high-water mark above belongs to. See
    /// `PersistedState.instanceEpoch`.
    private var lastAppliedInstanceEpoch: String?
    private var bootstrapped = false
    private var cachedSnapshot = Snapshot(generation: 0, annotationsSuspended: true,
                                          activeLeaseCount: 0, isBootstrapped: false,
                                          nextExpiryInSeconds: nil, error: nil)

    /// Resolves the optional `AI_CHALKBOARD_SUSPENSION_ROOT` override into a
    /// storage directory, or nil when it is absent or unusable.
    ///
    /// Pure over its input -- the same shape as
    /// `BuildMetadata.buildIdentifier(sidecarDirectory:)` -- so both
    /// platforms' absolute-path rules stay unit-testable without mutating
    /// this process's environment.
    ///
    /// The override must be ABSOLUTE. A relative value would resolve against
    /// whatever directory the process happened to launch from, scattering the
    /// shared lease registry somewhere unpredictable instead of the sandbox
    /// the caller asked for.
    ///
    /// This used to test `raw.hasPrefix("/")`, which only recognises a POSIX
    /// absolute path. On Windows an absolute path is `C:\...`, `C:/...`, or a
    /// UNC `\\server\share`, so every Windows override was silently ignored
    /// and the process fell back to the real per-user registry under
    /// `%LOCALAPPDATA%` -- the same one a live connector uses. That cost
    /// `tests/test_suspension_two_process.py` and `test_mcp_stdio.py` the
    /// isolation they both ask for by setting this variable to a `mkdtemp`
    /// directory.
    ///
    /// `AbsolutePath.isAbsolute` is the platform-correct test. Foundation's
    /// `NSString.isAbsolutePath` is deliberately NOT used: on Windows it
    /// accepts the drive-relative form `C:relative`, which
    /// `URL(fileURLWithPath:)` then resolves against the current directory --
    /// precisely the outcome this guard exists to prevent.
    static func overrideStorageDirectory(fromEnvironmentValue raw: String?) -> URL? {
        guard let raw, AbsolutePath.isAbsolute(raw) else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    /// Production reads its optional root override exactly once at launch.
    /// Tests can inject both an isolated directory and a stable boot id.
    public init(storageDirectory: URL? = nil, bootSessionIdentifier: String? = nil,
                instanceNonce: String? = nil, mutationSettleHook: (() -> Void)? = nil,
                storagePrecommitHook: (() -> Void)? = nil) {
        controlsPresentation = storageDirectory == nil
        if let storageDirectory {
            self.storageDirectory = storageDirectory.standardizedFileURL
        } else if let override = Self.overrideStorageDirectory(
            fromEnvironmentValue: ProcessInfo.processInfo.environment["AI_CHALKBOARD_SUSPENSION_ROOT"]) {
            self.storageDirectory = override
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.storageDirectory = support.appendingPathComponent("AIChalkboard", isDirectory: true)
        } else {
            self.storageDirectory = URL(fileURLWithPath: "/var/empty/AIChalkboard", isDirectory: true)
        }
        lockURL = self.storageDirectory.appendingPathComponent(Self.lockName)
        stateURL = self.storageDirectory.appendingPathComponent(Self.stateName)
        if let bootSessionIdentifier {
            self.bootSessionIdentifier = bootSessionIdentifier
            self.legacyBootSeconds = nil
        } else {
            self.bootSessionIdentifier = Self.currentBootSessionIdentifier()
            self.legacyBootSeconds = Self.currentBootTimeSeconds()
        }
        self.instanceNonce = instanceNonce ?? UUID().uuidString.lowercased()
        self.mutationSettleHook = mutationSettleHook
        self.storagePrecommitHook = storagePrecommitHook
    }

    @discardableResult
    public func bootstrapAndReconcile() -> Snapshot { reconcile() }

    /// Starts the first durable reconciliation without blocking UI launch.
    /// The completion runs on the platform UI thread only after that background
    /// read has applied its snapshot through the normal generation gate. It runs
    /// even for a fail-closed result so an unavailable registry cannot leave
    /// the MCP transport permanently unstarted.
    public func bootstrapAndReconcileAsynchronously(completion: @escaping (Snapshot) -> Void) {
        _ = enqueueReconciliation(announcedGeneration: nil, bootstrapCompletion: completion)
    }

    /// Coalesces an ordinary registry refresh onto a serial background queue.
    ///
    /// This is the entry point for run-loop timers and distributed
    /// notification wake-up hints.  It intentionally returns before opening
    /// the secure registry directory or attempting `flock`; those can have
    /// filesystem latency and must never make a platform UI callback wait. At
    /// most one worker is running or queued at a time.  A hint which arrives
    /// while that worker runs is folded into one follow-up pass rather than
    /// creating another task for every timer tick/notification.
    ///
    /// `true` means this call created the worker; `false` means an existing
    /// worker absorbed it.  The value is mainly useful to deterministic tests
    /// and diagnostics; callers normally ignore it.
    @discardableResult
    public func reconcileAsynchronously(announcedGeneration: UInt64? = nil) -> Bool {
        enqueueReconciliation(announcedGeneration: announcedGeneration, bootstrapCompletion: nil)
    }

    /// Merges a wake-up into at most one running/queued worker.  The optional
    /// completion is reserved for launch readiness; allowing arbitrary
    /// completions here would turn a notification storm into an unbounded
    /// retained callback list, the very failure this coalescer prevents.
    @discardableResult
    private func enqueueReconciliation(announcedGeneration: UInt64?,
                                       bootstrapCompletion: ((Snapshot) -> Void)?) -> Bool {
        reconciliationScheduleLock.lock()
        if let bootstrapCompletion {
            precondition(self.bootstrapCompletion == nil,
                         "Suspension bootstrap completion may be installed only once")
            self.bootstrapCompletion = bootstrapCompletion
        }
        reconciliationPending = true
        if let announcedGeneration,
           pendingReconciliationGeneration.map({ $0 < announcedGeneration }) ?? true {
            pendingReconciliationGeneration = announcedGeneration
        }
        guard !reconciliationWorkerScheduled else {
            reconciliationScheduleLock.unlock()
            return false
        }
        reconciliationWorkerScheduled = true
        reconciliationScheduleLock.unlock()

        reconciliationQueue.async { [weak self] in
            self?.runScheduledReconciliation()
        }
        return true
    }

    @discardableResult
    public func acquireLease(seconds: Int, idempotencyKey: String? = nil) -> OperationResult {
        guard (1...60).contains(seconds) else {
            return failedOperation("lease_seconds must be an integer from 1 through 60.")
        }
        return mutate(requiresCallerLeaseLive: true) { state, now in
            if let idempotencyKey,
               let token = state.idempotencyTokens[idempotencyKey],
               let lease = state.leases.first(where: { $0.token == token }) {
                // An idempotency key is useful only to the MCP server process
                // that created it. Returning another process's bearer token
                // would turn a retry key into a second release capability.
                guard lease.ownerInstanceNonce == instanceNonce else {
                    throw CoordinatorError.rejected("That idempotency_key is already active in another Chalkboard process; choose a new key rather than exposing its lease token.")
                }
                return MutationOutcome(token: lease.token, reused: true, alreadyReleased: false, changed: false)
            }
            guard state.leases.count < Self.maximumActiveLeases else {
                throw CoordinatorError.rejected("Too many active annotation suspension leases; release an existing lease before acquiring another.")
            }
            let token = Self.makeToken()
            state.leases.append(Lease(token: token,
                                      ownerPID: ProcessInfo.processInfo.processIdentifier,
                                      ownerInstanceNonce: instanceNonce,
                                      expiresAtUptime: now + Double(seconds),
                                      idempotencyKey: idempotencyKey))
            if let idempotencyKey { state.idempotencyTokens[idempotencyKey] = token }
            return MutationOutcome(token: token, reused: false, alreadyReleased: false, changed: true)
        }
    }

    @discardableResult
    public func releaseLease(token: String) -> OperationResult {
        guard Self.isCanonicalToken(token) else {
            return failedOperation("lease_token must be exactly a 32-byte base64url token.")
        }
        return mutate(requiresCallerLeaseLive: false) { state, now in
            if let index = state.leases.firstIndex(where: { $0.token == token }) {
                let lease = state.leases.remove(at: index)
                if let key = lease.idempotencyKey, state.idempotencyTokens[key] == token {
                    state.idempotencyTokens.removeValue(forKey: key)
                }
                Self.recordTombstone(token, in: &state, now: now)
                return MutationOutcome(token: token, reused: false, alreadyReleased: false, changed: true)
            }
            if state.releasedTokens[token] != nil {
                return MutationOutcome(token: token, reused: false, alreadyReleased: true, changed: false)
            }
            throw CoordinatorError.rejected("Unknown suspension lease token. It was not issued by this current Chalkboard boot session.")
        }
    }

    /// Returns cached data only. It is intentionally safe to call on the main
    /// thread because it never waits for AppKit or disk I/O.
    public func snapshot() -> Snapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedSnapshot
    }

    @discardableResult
    public func reconcile(announcedGeneration: UInt64? = nil) -> Snapshot {
        // The number is deliberately unused for deciding state: DNC is not an
        // authority. Parsing it only keeps diagnostics honest and makes stale
        // hints harmless by construction.
        _ = announcedGeneration
        do {
            let locked = try withLockedState { state, now in
                let changed = Self.prune(&state, now: now)
                return ((), changed)
            }
            if locked.didPersist { InstanceBroadcast.shared.postSuspensionInvalidation(generation: locked.state.generation) }
            return recordAndApply(locked.state, error: nil)
        } catch {
            return installFailure(error.localizedDescription)
        }
    }

    /// Runs on `reconciliationQueue`.  Keep scheduling state separate from
    /// the registry lock: `reconcile()` may wait for a peer operation, while
    /// callers on the main run loop need only a short in-process mutex to
    /// merge their wake-up hint.
    private func runScheduledReconciliation() {
        reconciliationScheduleLock.lock()
        let announcedGeneration = pendingReconciliationGeneration
        pendingReconciliationGeneration = nil
        reconciliationPending = false
        reconciliationScheduleLock.unlock()

        let snapshot = reconcile(announcedGeneration: announcedGeneration)

        reconciliationScheduleLock.lock()
        let completion = bootstrapCompletion
        bootstrapCompletion = nil
        let scheduleFollowUp = reconciliationPending
        if !scheduleFollowUp {
            reconciliationWorkerScheduled = false
        }
        reconciliationScheduleLock.unlock()

        if scheduleFollowUp {
            // Keep the ownership flag set while queuing the single follow-up:
            // callers racing this hand-off coalesce into that task instead of
            // enqueueing their own work item.
            reconciliationQueue.async { [weak self] in
                self?.runScheduledReconciliation()
            }
        }
        if let completion {
            // `reconcile` already marshalled its generation-gated presentation
            // application synchronously before returning. Enqueue the
            // transport start behind that work, without ever making the
            // background registry worker wait for a launch callback.
            MainThread.enqueue { completion(snapshot) }
        }
    }

    /// Executes one AppKit ordering decision under the same durable-operation
    /// lock that serializes lease mutations.
    ///
    /// This is deliberately stronger than a read followed by an independent
    /// `orderFrontRegardless()`: an acquire must not persist a suspension
    /// lease between the read and the window-server action.  The closure is
    /// intentionally main-thread-only and must perform only the immediate
    /// AppKit ordering/repaint work -- it must not call back into the
    /// coordinator, do I/O, or wait on another queue.  Conversely, no normal
    /// lease mutation waits for the main thread while it holds this lock;
    /// `recordAndApply` runs only after its lock scope has ended.  Those two
    /// rules avoid the otherwise easy flock/main-thread ABBA deadlock.
    ///
    /// On registry failure the closure still runs with a fail-closed snapshot
    /// so the caller can order every local overlay out before returning.
    @discardableResult
    public func withPresentationPermit(_ body: (Snapshot) -> Void) -> Snapshot {
        // `MainThread.isCurrentUIThread`, NOT `Thread.isMainThread`: on Windows
        // the overlay's windows are owned by a dedicated Win32 message-loop
        // thread, not the process main thread, so the literal main-thread test
        // fails there for correctly-dispatched work. See MainThread.
        precondition(MainThread.isCurrentUIThread,
                     "Presentation permits must run on the platform UI thread (AppKit main thread on macOS, the Win32 message-loop thread on Windows)")

        // `refreshViewsNow` can be reached reentrantly by an AppKit update
        // while the outer permit is refreshing a view.  A second `flock` on a
        // fresh descriptor would self-contend, so the nested call inherits the
        // already-recorded outer decision instead of reopening the registry.
        let key = "AIChalkboard.SuspensionPresentationPermit.\(ObjectIdentifier(self).hashValue)"
        let threadDictionary = Thread.current.threadDictionary
        if (threadDictionary[key] as? Bool) == true {
            let inherited = snapshot()
            body(inherited)
            return inherited
        }
        threadDictionary[key] = true
        defer { threadDictionary.removeObject(forKey: key) }

        do {
            // Unlike background lease mutations, this is a platform-UI-thread
            // fence. It must be immediate: on any busy/unavailable lock the
            // catch below runs the caller's fail-closed ordering closure.
            let permit = try withLockedPresentationState(body)
            if permit.didPersist {
                // Notifications are wake-up hints, not part of the permit.
                // Post only after releasing flock so a peer receiver can
                // reconcile immediately rather than timing out behind us.
                InstanceBroadcast.shared.postSuspensionInvalidation(generation: permit.state.generation)
            }
            return permit.value
        } catch {
            let failed = installFailure(error.localizedDescription)
            body(failed)
            // A peer may have held flock only for its own short presentation
            // fence, which performs no durable write and therefore emits no
            // DNC wake-up.  Do not leave this process hidden until the 0.5 s
            // timer notices: queue one ordinary background reconciliation as
            // soon as the nonblocking main-thread permit fails.  The queue's
            // coalescer keeps a burst of repaints at one worker, and this
            // call itself opens no files or retries flock on main.
            _ = reconcileAsynchronously()
            return failed
        }
    }

    private struct MutationOutcome {
        let token: String?
        let reused: Bool
        let alreadyReleased: Bool
        let changed: Bool
    }

    /// `requiresCallerLeaseLive` does NOT gate whether quiescence is observed
    /// -- every mutation observes it while suspended.  It gates only whether
    /// the caller's own lease must still exist for the settle loop to accept a
    /// stable generation, and the two error strings that requirement produces.
    private func mutate(requiresCallerLeaseLive: Bool,
                        _ mutation: (inout PersistedState, Double) throws -> MutationOutcome) -> OperationResult {
        do {
            let locked = try withLockedState { state, now in
                let pruned = Self.prune(&state, now: now)
                let outcome = try mutation(&state, now)
                return (outcome, pruned || outcome.changed)
            }
            if locked.didPersist { InstanceBroadcast.shared.postSuspensionInvalidation(generation: locked.state.generation) }
            _ = recordAndApply(locked.state, error: nil)
            mutationSettleHook?()
            let expiry = locked.value.token.flatMap { token in
                locked.state.leases.first(where: { $0.token == token }).map {
                    max(0, Int(ceil($0.expiresAtUptime - ProcessInfo.processInfo.systemUptime)))
                }
            }

            var snapshot = snapshot()
            var observation = SuspensionQuiescenceObservation(quiescent: false, candidatePIDs: [], candidatePIDsTruncated: false,
                                                               visibleOwnerPIDs: [], visibleWindowNumbers: [], discoveryErrors: [],
                                                               sampleCount: 0, scope: "annotations are not suspended")
            var recheckError: String?
            var peerPresentationSettled = false
            // Every mutation ends with a fresh canonical read. If the final
            // state is suspended, require one stable generation across the
            // WindowServer observation; bounded retries tolerate a concurrent
            // lease acquire/release without returning stale state.
            for attempt in 0..<3 {
                let before = try readCanonicalState()
                if before.didPersist { InstanceBroadcast.shared.postSuspensionInvalidation(generation: before.state.generation) }
                snapshot = recordAndApply(before.state, error: nil)
                guard snapshot.annotationsSuspended else {
                    // This is only a linearized registry snapshot. There is no
                    // honest WindowServer proof that every peer has repainted.
                    break
                }
                // Unconditional by design: a release that leaves another lease
                // active must observe quiescence too, or it would report
                // peerPresentationSettled=false for a still-hidden desktop.
                // Pinned by tests/test_suspension_two_process.py's
                // release-with-remaining-lease assertion
                // (`released_a["peerPresentationSettled"]`); cited by name
                // because line numbers in that file move.
                observation = observeQuiescence(timeout: 1.0)
                let after = try readCanonicalState()
                if after.didPersist { InstanceBroadcast.shared.postSuspensionInvalidation(generation: after.state.generation) }
                snapshot = recordAndApply(after.state, error: nil)
                let callerLeaseLive: Bool
                if requiresCallerLeaseLive, let token = locked.value.token {
                    callerLeaseLive = after.state.leases.contains(where: { $0.token == token })
                } else {
                    callerLeaseLive = true
                }
                if after.state.generation == before.state.generation && callerLeaseLive {
                    peerPresentationSettled = observation.quiescent
                    break
                }
                if requiresCallerLeaseLive, let token = locked.value.token,
                   !after.state.leases.contains(where: { $0.token == token }) {
                    recheckError = "The caller's suspension lease ended while presentation was being sampled; do not click."
                    break
                }
                if attempt == 2 {
                    recheckError = requiresCallerLeaseLive
                        ? "Suspension state kept changing while click safety was sampled; do not click and retry."
                        : nil
                }
            }

            var discoveryErrors = observation.discoveryErrors
            if let recheckError { discoveryErrors.append(recheckError) }
            return OperationResult(success: recheckError == nil, error: recheckError,
                                   leaseToken: locked.value.token, reused: locked.value.reused,
                                   alreadyReleased: locked.value.alreadyReleased, generation: snapshot.generation,
                                   annotationsSuspended: snapshot.annotationsSuspended,
                                   activeLeaseCount: snapshot.activeLeaseCount, leaseExpiresInSeconds: expiry,
                                   peerPresentationSettled: peerPresentationSettled,
                                   scope: observation.scope, candidatePIDs: observation.candidatePIDs,
                                   candidatePIDsTruncated: observation.candidatePIDsTruncated,
                                   visibleOwnerPIDs: observation.visibleOwnerPIDs,
                                   visibleWindowNumbers: observation.visibleWindowNumbers,
                                   discoveryErrors: discoveryErrors)
        } catch let error as CoordinatorError {
            // A REFUSAL is not a failure of the registry: it was read cleanly
            // and nothing was written. The clean state may nevertheless be
            // newer than this process's cache (for example, a peer acquired a
            // lease before we rejected reuse of its idempotency key). Because
            // the throwing mutation cannot return that locked state, refresh
            // once after the lock is released before reporting the refusal.
            // A failed refresh still takes reconcile's ordinary fail-closed
            // path and is reported as a registry error.
            if case .rejected(let message) = error {
                let refreshed = reconcile()
                if let storageError = refreshed.error {
                    return failedOperation(storageError)
                }
                return failedOperation(message)
            }
            // Anything else -- a failed write, revalidation, or final durable
            // recheck -- means we cannot honestly preserve a visible
            // presentation decision. Order every local overlay out before
            // returning the error.
            _ = installFailure(error.localizedDescription)
            return failedOperation(error.localizedDescription)
        } catch {
            _ = installFailure(error.localizedDescription)
            return failedOperation(error.localizedDescription)
        }
    }

    /// The final read after WindowServer sampling closes the important logical
    /// race: point-in-time absence is useful only while this caller still owns
    /// the same durable lease generation.
    private func readCanonicalState() throws -> LockedResult<Void> {
        try withLockedState { state, now in
            let pruned = Self.prune(&state, now: now)
            return ((), pruned)
        }
    }

    private func failedOperation(_ error: String) -> OperationResult {
        let snapshot = snapshot()
        return OperationResult(success: false, error: error, leaseToken: nil, reused: false, alreadyReleased: false,
                               generation: snapshot.generation, annotationsSuspended: snapshot.annotationsSuspended,
                               activeLeaseCount: snapshot.activeLeaseCount, leaseExpiresInSeconds: nil,
                               peerPresentationSettled: false,
                               scope: "durable shared lease registry across this OS boot", candidatePIDs: [],
                               candidatePIDsTruncated: false, visibleOwnerPIDs: [], visibleWindowNumbers: [], discoveryErrors: [])
    }

    /// All filesystem mutation happens while `HeldLock` remains path-visible.
    /// Checking its inode immediately before the atomic rename fails closed if
    /// a same-UID process unlinked/recreated the lock path while we held flock.
    private func withLockedState<Value>(_ body: (inout PersistedState, Double) throws -> (Value, Bool)) throws -> LockedResult<Value> {
        guard let bootSessionIdentifier else {
            throw CoordinatorError.unavailable("AI Chalkboard could not determine the current macOS boot session; overlays remain hidden.")
        }
        // The storage helper automatically selects an immediate attempt when
        // this synchronous API is called from the platform UI thread. Ordinary
        // production reconciliation uses `reconcileAsynchronously`, so its
        // worker may use the bounded background wait instead.
        let held = try acquireLock()
        defer { held.release() }
        try validateHeldLock(held)
        let read = try readState(in: held.directoryFD, bootSessionIdentifier: bootSessionIdentifier)
        var state = read.state
        let now = ProcessInfo.processInfo.systemUptime
        let (value, bodyChanged) = try body(&state, now)
        try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier,
                               legacyBootSeconds: legacyBootSeconds)
        if bodyChanged || read.needsRewrite {
            state.generation &+= 1
            state.lastUpdatedUptime = now
            // Mint the file identity here, not when a read synthesizes a state
            // for a missing file: this is the first moment the file actually
            // exists. Skipping it would durably write a nil-epoch registry and
            // permanently disable the ratchet reset for this file. The
            // absent-file sentinel is treated exactly like nil, so it stays an
            // in-memory marker and never reaches disk.
            if state.instanceEpoch == nil || state.instanceEpoch == PersistedState.absentFileEpoch {
                state.instanceEpoch = UUID().uuidString
            }
            try writeState(state, held: held)
        }
        // A replacement after the write is just as unsafe as one before it:
        // report failure so callers fail closed and a later reconciliation has
        // to establish a clean, single path-visible lock again.
        try validateHeldLock(held)
        return LockedResult(value: value, state: state, didPersist: bodyChanged || read.needsRewrite)
    }

    /// How many times a presentation fence re-attempts the NONBLOCKING lock
    /// before it gives up and lets `withPresentationPermit` fail closed, and
    /// how long it pauses between attempts.
    ///
    /// WHY THIS EXISTS (bug fix -- overlay flicker on ordinary focus changes):
    /// every desktop-wide `EVENT_SYSTEM_FOREGROUND`/`didActivate` makes EVERY
    /// Chalkboard process refresh presentation, and Claude Desktop runs two
    /// `--mcp` children per config entry. Both therefore reach for the same
    /// registry lock in the same millisecond, and one of them loses. A loss
    /// here is not evidence that the registry is unavailable -- the peer holds
    /// it for the few milliseconds of its own presentation fence, which
    /// performs no durable write -- but the failure path treats the two
    /// identically: it hides EVERY overlay window (`orderAllWindowsOffScreen`)
    /// and logs at ERROR, and the background reconciliation only puts them
    /// back 30-90 ms later. With an annotation on screen that is a visible
    /// blink, and it fires on every alt-tab; a production log showed 82 such
    /// cycles in 14 minutes between two sibling PIDs.
    ///
    /// Retrying briefly collapses that whole class of false alarm without
    /// weakening anything: this stays a NONBLOCKING acquire (it never waits on
    /// the peer the way the background path's `waitForAvailability: true`
    /// does), the fail-closed behaviour is unchanged for a registry that is
    /// genuinely unavailable -- every attempt simply fails and the real error
    /// still propagates -- and the total worst case is an order of magnitude
    /// shorter than the flicker it replaces. It also cannot deadlock against
    /// the peer, because a presentation fence never waits on anything else
    /// while holding this lock.
    private static let presentationLockAttempts = 4
    private static let presentationLockRetryDelay: TimeInterval = 0.003

    /// Bounded-retry wrapper around the nonblocking acquire. Only the ACQUIRE
    /// is retried -- never the read/validate/write body below it, where a
    /// retry could turn one durable write into two.
    private func acquirePresentationLock() throws -> HeldLock<PlatformBackend> {
        var attempt = 1
        while true {
            do {
                return try acquireLock(waitForAvailability: false)
            } catch {
                // The last attempt rethrows verbatim, so `installFailure`
                // still reports the genuine underlying reason rather than a
                // synthesized "gave up retrying" message.
                guard attempt < Self.presentationLockAttempts else { throw error }
                attempt += 1
                // Blocks the UI thread for a few milliseconds by design. The
                // alternative -- returning to the caller -- costs a full
                // hide/show cycle of every overlay window, which is both
                // slower and visible.
                Thread.sleep(forTimeInterval: Self.presentationLockRetryDelay)
            }
        }
    }

    /// The presentation counterpart to `withLockedState`.  It intentionally
    /// keeps `held` alive while `body` performs its synchronous AppKit action;
    /// see `withPresentationPermit` for the lock-ordering contract.
    private func withLockedPresentationState(_ body: (Snapshot) -> Void) throws -> LockedResult<Snapshot> {
        guard let bootSessionIdentifier else {
            throw CoordinatorError.unavailable("AI Chalkboard could not determine the current macOS boot session; overlays remain hidden.")
        }
        // Presentation can only use a nonblocking lock attempt.  The caller
        // is on the platform UI thread and will order every overlay out if a
        // peer currently owns the durable operation lock.
        let held = try acquirePresentationLock()
        defer { held.release() }

        try validateHeldLock(held)
        let read = try readState(in: held.directoryFD, bootSessionIdentifier: bootSessionIdentifier)
        var state = read.state
        let now = ProcessInfo.processInfo.systemUptime
        let pruned = Self.prune(&state, now: now)
        try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier,
                               legacyBootSeconds: legacyBootSeconds)
        if pruned || read.needsRewrite {
            state.generation &+= 1
            state.lastUpdatedUptime = now
            // Same rule as `withLockedState`: a persist is what turns a
            // synthesized state into a real file, so it is what mints the
            // file's identity -- and the absent-file sentinel is as much "not
            // an identity yet" as nil is.
            if state.instanceEpoch == nil || state.instanceEpoch == PersistedState.absentFileEpoch {
                state.instanceEpoch = UUID().uuidString
            }
            try writeState(state, held: held)
        }
        try validateHeldLock(held)

        // `recordState` takes only the short in-process mutex.  It never hops
        // to the main thread (we are already there) and therefore cannot form
        // an ABBA cycle with a background mutation that is waiting to apply.
        let recorded = recordState(state, error: nil)
        body(recorded.snapshot)
        return LockedResult(value: recorded.snapshot, state: state,
                            didPersist: pruned || read.needsRewrite)
    }

    private struct RecordedState {
        let snapshot: Snapshot
        let shouldApplyPresentation: Bool
    }

    /// Updates local bookkeeping without ever holding `stateLock` across a
    /// main-thread hop. The controller itself gates by generation on main, so
    /// out-of-order background callers cannot roll presentation backwards.
    private func recordState(_ state: PersistedState, error: String?) -> RecordedState {
        let suspended = !state.leases.isEmpty
        let nextExpiry = state.leases.map { max(0, Int(ceil($0.expiresAtUptime - ProcessInfo.processInfo.systemUptime))) }.min()
        let snapshot = Snapshot(generation: state.generation, annotationsSuspended: suspended,
                                activeLeaseCount: state.leases.count, isBootstrapped: error == nil,
                                nextExpiryInSeconds: nextExpiry, error: error)
        stateLock.lock()
        // A changed epoch means this is a DIFFERENT registry file, so the
        // high-water mark from the previous one carries no meaning and must
        // not be allowed to reject the new file's genuinely-current state.
        // Requiring both sides to be non-nil keeps pre-epoch registries on
        // exactly the old behaviour rather than resetting on missing data.
        // `PersistedState.absentFileEpoch` participates like any other epoch:
        // a file that DISAPPEARS mid-session is a real transition and must
        // reset the mark once, after which every further read of that same
        // absent file compares equal and changes nothing.
        if let observed = state.instanceEpoch,
           let remembered = lastAppliedInstanceEpoch,
           observed != remembered {
            hasAppliedGeneration = false
            lastAppliedGeneration = 0
        }
        if hasAppliedGeneration && state.generation < lastAppliedGeneration {
            let current = cachedSnapshot
            stateLock.unlock()
            return RecordedState(snapshot: current, shouldApplyPresentation: false)
        }
        // A failed registry operation is fail-closed but it does NOT erase the
        // monotonic high-water mark.  Therefore only an equal generation can
        // repair the local fail-closed presentation.  An older successful
        // read remains stale and is rejected even after `installFailure`.
        let sameGenerationRepair = hasAppliedGeneration
            && state.generation == lastAppliedGeneration
            && !bootstrapped
        let shouldApply = !hasAppliedGeneration
            || state.generation > lastAppliedGeneration
            || sameGenerationRepair
        if !hasAppliedGeneration || state.generation > lastAppliedGeneration {
            hasAppliedGeneration = true
            lastAppliedGeneration = state.generation
        }
        // Track the epoch the mark belongs to, including the first read after
        // an upgrade (where it was previously nil).
        if let observed = state.instanceEpoch { lastAppliedInstanceEpoch = observed }
        bootstrapped = error == nil
        cachedSnapshot = snapshot
        stateLock.unlock()

        return RecordedState(snapshot: snapshot, shouldApplyPresentation: shouldApply)
    }

    private func recordAndApply(_ state: PersistedState, error: String?) -> Snapshot {
        let recorded = recordState(state, error: error)

        if recorded.shouldApplyPresentation && controlsPresentation {
            _ = OverlayWindowController.shared.setAnnotationsSuspended(
                recorded.snapshot.annotationsSuspended,
                generation: recorded.snapshot.generation
            )
        }
        return recorded.snapshot
    }

#if DEBUG
    /// `instanceEpoch` defaults to a FIXED value so successive calls model
    /// repeated reads of the SAME registry file -- otherwise each call would
    /// mint a new epoch, read as a recreated file, and reset the generation
    /// ratchet the stale-apply tests exist to pin. Pass a different epoch to
    /// model the file actually being replaced.
    func testOnlyRecordAndApply(generation: UInt64, suspended: Bool,
                                instanceEpoch: String = "test-epoch") -> Snapshot {
        var state = PersistedState(bootSessionIdentifier: bootSessionIdentifier ?? "test")
        state.instanceEpoch = instanceEpoch
        state.generation = generation
        if suspended {
            state.leases = [Lease(token: String(repeating: "A", count: 43), ownerPID: 1,
                                  ownerInstanceNonce: "test", expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60,
                                  idempotencyKey: nil)]
        }
        return recordAndApply(state, error: nil)
    }

    /// Models a registry written before `instanceEpoch` existed.
    func testOnlyRecordAndApplyWithoutEpoch(generation: UInt64, suspended: Bool) -> Snapshot {
        var state = PersistedState(bootSessionIdentifier: bootSessionIdentifier ?? "test")
        state.instanceEpoch = nil
        state.generation = generation
        if suspended {
            state.leases = [Lease(token: String(repeating: "A", count: 43), ownerPID: 1,
                                  ownerInstanceNonce: "test", expiresAtUptime: ProcessInfo.processInfo.systemUptime + 60,
                                  idempotencyKey: nil)]
        }
        return recordAndApply(state, error: nil)
    }

    func testOnlyInstallFailure(_ error: String = "test failure") -> Snapshot {
        installFailure(error)
    }
#endif

    private func installFailure(_ error: String) -> Snapshot {
        stateLock.lock()
        bootstrapped = false
        // Keep `hasAppliedGeneration` and `lastAppliedGeneration` intact. A
        // later canonical read at exactly this generation may repair the
        // fail-closed state, but an older delayed read must never roll it back.
        let snapshot = Snapshot(generation: lastAppliedGeneration, annotationsSuspended: true,
                                activeLeaseCount: 0, isBootstrapped: false,
                                nextExpiryInSeconds: nil, error: error)
        cachedSnapshot = snapshot
        stateLock.unlock()
        if controlsPresentation { OverlayWindowController.shared.forceAnnotationsSuspendedFailClosed() }
        return snapshot
    }

    // MARK: - Bounded state

    private static func prune(_ state: inout PersistedState, now: Double) -> Bool {
        let expired = state.leases.filter { $0.expiresAtUptime <= now }
        var changed = !expired.isEmpty
        if !expired.isEmpty {
            state.leases.removeAll { $0.expiresAtUptime <= now }
            for lease in expired {
                if let key = lease.idempotencyKey, state.idempotencyTokens[key] == lease.token {
                    state.idempotencyTokens.removeValue(forKey: key)
                }
                recordTombstone(lease.token, in: &state, now: now)
            }
        }
        let beforeTombstones = state.releasedTokens.count
        state.releasedTokens = state.releasedTokens.filter { $0.value > now }
        changed = changed || beforeTombstones != state.releasedTokens.count
        let validTokens = Set(state.leases.map(\.token))
        let beforeKeys = state.idempotencyTokens.count
        state.idempotencyTokens = state.idempotencyTokens.filter { validTokens.contains($0.value) }
        return changed || beforeKeys != state.idempotencyTokens.count
    }

    private static func recordTombstone(_ token: String, in state: inout PersistedState, now: Double) {
        state.releasedTokens[token] = now + tombstoneLifetime
        if state.releasedTokens.count > maximumTombstones {
            let doomed = state.releasedTokens.sorted { $0.value < $1.value }
                .prefix(state.releasedTokens.count - maximumTombstones).map(\.key)
            for key in doomed { state.releasedTokens.removeValue(forKey: key) }
        }
    }

    // internal: SuspensionLeaseStorage.swift's readState calls this after
    // decoding to fail closed on invalid/oversized state.
    static func validateState(_ state: PersistedState, bootSessionIdentifier: String,
                              legacyBootSeconds: Double?) throws {
        guard state.schemaVersion == 4,
              // Tolerant by design -- see `isSameBootSession`. A stored identity
              // from the previous build's `kern.boottime` scheme still names
              // this boot, and rejecting it here would fail every operation
              // closed instead of letting `readState` decide.
              isSameBootSession(stored: state.bootSessionIdentifier, current: bootSessionIdentifier,
                                legacyBootSeconds: legacyBootSeconds),
              state.leases.count <= maximumActiveLeases,
              state.idempotencyTokens.count <= maximumActiveLeases,
              state.releasedTokens.count <= maximumTombstones,
              Set(state.leases.map(\.token)).count == state.leases.count,
              state.leases.allSatisfy({ isCanonicalToken($0.token) && ($0.ownerInstanceNonce?.count ?? 0) > 0 && ($0.ownerInstanceNonce?.count ?? 0) <= 128 }) else { throw CoordinatorError.malformedState }
        let active = Set(state.leases.map(\.token))
        guard state.idempotencyTokens.values.allSatisfy({ active.contains($0) }) else { throw CoordinatorError.malformedState }
    }
}

typealias SuspensionLeaseSnapshot = SuspensionLeaseCoordinator.Snapshot
typealias SuspensionLeaseOperationResult = SuspensionLeaseCoordinator.OperationResult
