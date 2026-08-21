import Foundation
import AppKit
import Darwin

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
        public let clickSafeAtObservation: Bool
        /// True only when the final durable generation was stable across a
        /// conservative presentation observation. An unsuspended release is a
        /// linearized registry snapshot, not proof that every peer has painted.
        public let peerPresentationSettled: Bool
        public let scope: String
        public let candidatePIDs: [pid_t]
        public let candidatePIDsTruncated: Bool
        public let visibleOwnerPIDs: [pid_t]
        public let visibleWindowNumbers: [Int]
        public let discoveryErrors: [String]
    }

    private struct Lease: Codable, Equatable {
        let token: String
        let ownerPID: Int32
        let ownerInstanceNonce: String?
        let expiresAtUptime: Double
        let idempotencyKey: String?
    }

    private struct PersistedState: Codable {
        var schemaVersion = 4
        /// `kern.boottime`, not uptime, identifies the OS boot which created
        /// this registry. Uptime-only comparisons cannot distinguish a reboot
        /// from an old state whose values happen to be small.
        var bootSessionIdentifier: String
        var generation: UInt64 = 0
        var lastUpdatedUptime: Double = 0
        var leases: [Lease] = []
        var idempotencyTokens: [String: String] = [:]
        /// Expired/released token -> monotonic expiry. Tombstones are bounded
        /// and intentionally short: they make lost cleanup responses safe,
        /// not arbitrary historical tokens valid forever.
        var releasedTokens: [String: Double] = [:]

        init(bootSessionIdentifier: String) {
            self.bootSessionIdentifier = bootSessionIdentifier
        }
    }

    private struct HeldLock {
        let parentFD: Int32
        let directoryFD: Int32
        let descriptor: Int32

        func release() {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            close(directoryFD)
            close(parentFD)
        }
    }

    private struct LockedResult<Value> {
        let value: Value
        let state: PersistedState
        let didPersist: Bool
    }

    private struct StateRead {
        let state: PersistedState
        /// An old-boot registry was decoded successfully but must be replaced
        /// before this operation returns, so the reboot recovery is durable
        /// rather than merely a process-local interpretation.
        let needsRewrite: Bool
    }

    private enum CoordinatorError: LocalizedError {
        case unavailable(String)
        case malformedState

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .malformedState:
                return "AI Chalkboard's suspension lease registry is invalid or exceeds its safety limits; annotations remain hidden until it is repaired."
            }
        }
    }

    private static let lockName = "annotations-suspension-v3.lock"
    private static let stateName = "annotations-suspension-v3.json"
    private static let tombstoneLifetime: Double = 120
    private static let maximumActiveLeases = 64
    private static let maximumTombstones = 64
    private static let maximumSerializedBytes = 65_536

    private let storageDirectory: URL
    private let lockURL: URL
    private let stateURL: URL
    private let bootSessionIdentifier: String?
    private let instanceNonce: String
    private let mutationSettleHook: (() -> Void)?
    private let storagePrecommitHook: (() -> Void)?
    private let controlsPresentation: Bool
    private let stateLock = NSLock()
    private var lastAppliedGeneration: UInt64 = 0
    private var hasAppliedGeneration = false
    private var bootstrapped = false
    private var cachedSnapshot = Snapshot(generation: 0, annotationsSuspended: true,
                                          activeLeaseCount: 0, isBootstrapped: false,
                                          nextExpiryInSeconds: nil, error: nil)

    /// Production reads its optional root override exactly once at launch.
    /// Tests can inject both an isolated directory and a stable boot id.
    public init(storageDirectory: URL? = nil, bootSessionIdentifier: String? = nil,
                instanceNonce: String? = nil, mutationSettleHook: (() -> Void)? = nil,
                storagePrecommitHook: (() -> Void)? = nil) {
        controlsPresentation = storageDirectory == nil
        if let storageDirectory {
            self.storageDirectory = storageDirectory.standardizedFileURL
        } else if let raw = ProcessInfo.processInfo.environment["AI_CHALKBOARD_SUSPENSION_ROOT"], raw.hasPrefix("/") {
            self.storageDirectory = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.storageDirectory = support.appendingPathComponent("AIChalkboard", isDirectory: true)
        } else {
            self.storageDirectory = URL(fileURLWithPath: "/var/empty/AIChalkboard", isDirectory: true)
        }
        lockURL = self.storageDirectory.appendingPathComponent(Self.lockName)
        stateURL = self.storageDirectory.appendingPathComponent(Self.stateName)
        self.bootSessionIdentifier = bootSessionIdentifier ?? Self.currentBootSessionIdentifier()
        self.instanceNonce = instanceNonce ?? UUID().uuidString.lowercased()
        self.mutationSettleHook = mutationSettleHook
        self.storagePrecommitHook = storagePrecommitHook
    }

    @discardableResult
    public func bootstrapAndReconcile() -> Snapshot { reconcile() }

    @discardableResult
    public func acquireLease(seconds: Int, idempotencyKey: String? = nil) -> OperationResult {
        guard (1...60).contains(seconds) else {
            return failedOperation("lease_seconds must be an integer from 1 through 60.")
        }
        return mutate(includeQuiescence: true) { state, now in
            if let idempotencyKey,
               let token = state.idempotencyTokens[idempotencyKey],
               let lease = state.leases.first(where: { $0.token == token }) {
                // An idempotency key is useful only to the MCP server process
                // that created it. Returning another process's bearer token
                // would turn a retry key into a second release capability.
                guard lease.ownerInstanceNonce == instanceNonce else {
                    throw CoordinatorError.unavailable("That idempotency_key is already active in another Chalkboard process; choose a new key rather than exposing its lease token.")
                }
                return MutationOutcome(token: lease.token, reused: true, alreadyReleased: false, changed: false)
            }
            guard state.leases.count < Self.maximumActiveLeases else {
                throw CoordinatorError.unavailable("Too many active annotation suspension leases; release an existing lease before acquiring another.")
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
        return mutate(includeQuiescence: false) { state, now in
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
            throw CoordinatorError.unavailable("Unknown suspension lease token. It was not issued by this current Chalkboard boot session.")
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
        precondition(Thread.isMainThread,
                     "Presentation permits must run on the AppKit main thread")

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
            return failed
        }
    }

    private struct MutationOutcome {
        let token: String?
        let reused: Bool
        let alreadyReleased: Bool
        let changed: Bool
    }

    private func mutate(includeQuiescence: Bool,
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
                observation = observeQuiescence(timeout: 1.0)
                let after = try readCanonicalState()
                if after.didPersist { InstanceBroadcast.shared.postSuspensionInvalidation(generation: after.state.generation) }
                snapshot = recordAndApply(after.state, error: nil)
                let callerLeaseLive: Bool
                if includeQuiescence, let token = locked.value.token {
                    callerLeaseLive = after.state.leases.contains(where: { $0.token == token })
                } else {
                    callerLeaseLive = true
                }
                if after.state.generation == before.state.generation && callerLeaseLive {
                    peerPresentationSettled = observation.quiescent
                    break
                }
                if includeQuiescence, let token = locked.value.token,
                   !after.state.leases.contains(where: { $0.token == token }) {
                    recheckError = "The caller's suspension lease ended while presentation was being sampled; do not click."
                    break
                }
                if attempt == 2 {
                    recheckError = includeQuiescence
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
                                   clickSafeAtObservation: peerPresentationSettled && recheckError == nil,
                                   peerPresentationSettled: peerPresentationSettled,
                                   scope: observation.scope, candidatePIDs: observation.candidatePIDs,
                                   candidatePIDsTruncated: observation.candidatePIDsTruncated,
                                   visibleOwnerPIDs: observation.visibleOwnerPIDs,
                                   visibleWindowNumbers: observation.visibleWindowNumbers,
                                   discoveryErrors: discoveryErrors)
        } catch {
            // A failed write, revalidation, or final durable recheck means we
            // cannot honestly preserve a visible presentation decision. Order
            // every local overlay out before returning the error.
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
                               clickSafeAtObservation: false,
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
        let held = try acquireLock()
        defer { held.release() }
        try validateHeldLock(held)
        let read = try readState(in: held.directoryFD, bootSessionIdentifier: bootSessionIdentifier)
        var state = read.state
        let now = ProcessInfo.processInfo.systemUptime
        let (value, bodyChanged) = try body(&state, now)
        try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
        if bodyChanged || read.needsRewrite {
            state.generation &+= 1
            state.lastUpdatedUptime = now
            try writeState(state, held: held)
        }
        // A replacement after the write is just as unsafe as one before it:
        // report failure so callers fail closed and a later reconciliation has
        // to establish a clean, single path-visible lock again.
        try validateHeldLock(held)
        return LockedResult(value: value, state: state, didPersist: bodyChanged || read.needsRewrite)
    }

    /// The presentation counterpart to `withLockedState`.  It intentionally
    /// keeps `held` alive while `body` performs its synchronous AppKit action;
    /// see `withPresentationPermit` for the lock-ordering contract.
    private func withLockedPresentationState(_ body: (Snapshot) -> Void) throws -> LockedResult<Snapshot> {
        guard let bootSessionIdentifier else {
            throw CoordinatorError.unavailable("AI Chalkboard could not determine the current macOS boot session; overlays remain hidden.")
        }
        let held = try acquireLock()
        defer { held.release() }

        try validateHeldLock(held)
        let read = try readState(in: held.directoryFD, bootSessionIdentifier: bootSessionIdentifier)
        var state = read.state
        let now = ProcessInfo.processInfo.systemUptime
        let pruned = Self.prune(&state, now: now)
        try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
        if pruned || read.needsRewrite {
            state.generation &+= 1
            state.lastUpdatedUptime = now
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
    func testOnlyRecordAndApply(generation: UInt64, suspended: Bool) -> Snapshot {
        var state = PersistedState(bootSessionIdentifier: bootSessionIdentifier ?? "test")
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

    private static func validateState(_ state: PersistedState, bootSessionIdentifier: String) throws {
        guard state.schemaVersion == 4, state.bootSessionIdentifier == bootSessionIdentifier,
              state.leases.count <= maximumActiveLeases,
              state.idempotencyTokens.count <= maximumActiveLeases,
              state.releasedTokens.count <= maximumTombstones,
              Set(state.leases.map(\.token)).count == state.leases.count,
              state.leases.allSatisfy({ isCanonicalToken($0.token) && ($0.ownerInstanceNonce?.count ?? 0) > 0 && ($0.ownerInstanceNonce?.count ?? 0) <= 128 }) else { throw CoordinatorError.malformedState }
        let active = Set(state.leases.map(\.token))
        guard state.idempotencyTokens.values.allSatisfy({ active.contains($0) }) else { throw CoordinatorError.malformedState }
    }

    // MARK: - Hardened storage

    private func acquireLock() throws -> HeldLock {
        let opened = try openSecureDirectory()
        let parentFD = opened.parentFD
        let directoryFD = opened.directoryFD
        var descriptor: Int32 = -1
        do {
            descriptor = try openValidatedRegularFile(named: Self.lockName, in: directoryFD, create: true)
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let error = errno
                guard error == EWOULDBLOCK || error == EAGAIN || error == EINTR else {
                    close(descriptor)
                    descriptor = -1
                    throw CoordinatorError.unavailable("AI Chalkboard could not lock suspension state (errno \(error)).")
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    close(descriptor)
                    descriptor = -1
                    throw CoordinatorError.unavailable("Another annotation suspension operation is still in progress.")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let held = HeldLock(parentFD: parentFD, directoryFD: directoryFD, descriptor: descriptor)
            try validateHeldDirectory(held)
            try validateHeldLock(held)
            return held
        } catch {
            // `validateHeldDirectory` / `validateHeldLock` can throw after a
            // successful open+flock.  The old catch released only the two
            // directory descriptors, leaking this fd on every such failed
            // validation.  Drop flock explicitly before close for clarity;
            // close would release it too, but this keeps the cleanup contract
            // symmetric with `HeldLock.release()`.
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            close(directoryFD)
            close(parentFD)
            throw error
        }
    }

    private func openSecureDirectory() throws -> (parentFD: Int32, directoryFD: Int32) {
        let path = storageDirectory.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw CoordinatorError.unavailable("AI Chalkboard could not create its private suspension-state directory (errno \(errno)).")
        }
        let parentPath = storageDirectory.deletingLastPathComponent().path
        let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not open the suspension-state parent directory (errno \(errno)).") }
        let fd = openat(parentFD, storageDirectory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { close(parentFD); throw CoordinatorError.unavailable("AI Chalkboard could not open its private suspension-state directory (errno \(errno)).") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
            close(fd); close(parentFD); throw CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state directory.")
        }
        // InstanceLock historically created the shared AIChalkboard support
        // directory with FileManager's default 0755 mode.  Read/execute bits
        // do not let another uid seed or replace registry files, so tighten
        // that legacy directory through the already-open, same-uid descriptor.
        // Never repair a group/world-writable directory: its contents may
        // already have been influenced by another user and cannot be trusted.
        if (info.st_mode & 0o777) != 0o700 {
            guard fchmod(fd, 0o700) == 0,
                  fstat(fd, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  (info.st_mode & 0o777) == 0o700 else {
                close(fd); close(parentFD); throw CoordinatorError.unavailable("AI Chalkboard could not secure its suspension-state directory.")
            }
        }
        return (parentFD, fd)
    }

    private func validateHeldDirectory(_ held: HeldLock) throws {
        var descriptorInfo = stat(), parentEntry = stat(), absoluteEntry = stat()
        guard fstat(held.directoryFD, &descriptorInfo) == 0,
              fstatat(held.parentFD, storageDirectory.lastPathComponent, &parentEntry, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(storageDirectory.path, &absoluteEntry) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
              descriptorInfo.st_dev == parentEntry.st_dev, descriptorInfo.st_ino == parentEntry.st_ino,
              descriptorInfo.st_dev == absoluteEntry.st_dev, descriptorInfo.st_ino == absoluteEntry.st_ino,
              descriptorInfo.st_uid == getuid() else {
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state directory; overlays remain hidden.")
        }
    }

    private func validateHeldLock(_ held: HeldLock) throws {
        try validateHeldDirectory(held)
        var descriptorInfo = stat(), pathInfo = stat()
        guard fstat(held.descriptor, &descriptorInfo) == 0,
              fstatat(held.directoryFD, Self.lockName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino,
              descriptorInfo.st_uid == getuid(), descriptorInfo.st_nlink == 1 else {
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
    }

    private func openValidatedRegularFile(named name: String, in directoryFD: Int32, create: Bool) throws -> Int32 {
        var before = stat()
        let existed = fstatat(directoryFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0
        // Tracks whether `before` currently holds a validated stat we are
        // entitled to compare the opened descriptor against.
        //
        // BUG FIX (the inode check was dead on the one path it exists for):
        // this used to reuse `existed` directly in the final guard below. On
        // the O_EXCL loser path we re-stat into `before` and then plainly
        // openat() the winner's file -- but `existed` was bound `let` BEFORE
        // that branch and stayed false, so `!existed` short-circuited the
        // dev/ino comparison to true and the verification the comment below
        // promises never actually ran. `existed` still answers "did it exist
        // before we tried to create it" for the control flow; this separate
        // flag answers "is `before` a stat worth comparing against", which is
        // the question the guard is really asking.
        var beforeIsValidated = existed
        if existed && ((before.st_mode & S_IFMT) != S_IFREG || before.st_uid != getuid() || before.st_nlink != 1) {
            throw CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state file.")
        }
        if !existed && errno != ENOENT { throw CoordinatorError.unavailable("AI Chalkboard could not inspect suspension state (errno \(errno)).") }
        let baseFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        var fd: Int32
        if create && !existed {
            // Two Chalkboard processes commonly launch together. Make the
            // first lock-file installation explicit and atomic; a loser of
            // the O_EXCL race re-inspects and opens the winner's inode.
            fd = openat(directoryFD, name, baseFlags | O_CREAT | O_EXCL, 0o600)
            if fd < 0 && errno == EEXIST {
                guard fstatat(directoryFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      (before.st_mode & S_IFMT) == S_IFREG,
                      before.st_uid == getuid(), before.st_nlink == 1 else {
                    throw CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state file.")
                }
                beforeIsValidated = true
                fd = openat(directoryFD, name, baseFlags)
            }
        } else {
            fd = openat(directoryFD, name, baseFlags)
        }
        guard fd >= 0 else {
            let role = name == Self.lockName ? "suspension-operation lock" : "suspension lease state"
            throw CoordinatorError.unavailable("AI Chalkboard could not open its \(role) (errno \(errno)).")
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0,
              fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (after.st_mode & S_IFMT) == S_IFREG, after.st_uid == getuid(), after.st_nlink == 1,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              (!beforeIsValidated || (before.st_dev == after.st_dev && before.st_ino == after.st_ino)) else {
            close(fd); throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state file.")
        }
        guard fchmod(fd, 0o600) == 0 else { close(fd); throw CoordinatorError.unavailable("AI Chalkboard could not secure suspension state.") }
        return fd
    }

    private func readState(in directoryFD: Int32, bootSessionIdentifier: String) throws -> StateRead {
        var pathInfo = stat()
        if fstatat(directoryFD, Self.stateName, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier), needsRewrite: false) }
            throw CoordinatorError.unavailable("AI Chalkboard could not inspect suspension lease state (errno \(errno)).")
        }
        let fd = try openValidatedRegularFile(named: Self.stateName, in: directoryFD, create: false)
        defer { close(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not read suspension lease state (errno \(errno)).") }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumSerializedBytes else { throw CoordinatorError.malformedState }
        }
        guard !data.isEmpty else { return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier), needsRewrite: false) }
        do {
            var state = try JSONDecoder().decode(PersistedState.self, from: data)
            // A valid old-boot registry is safely replaced, never revived.
            if state.bootSessionIdentifier != bootSessionIdentifier {
                return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier), needsRewrite: true)
            }
            if state.schemaVersion == 3 {
                // Pre-nonce v3 leases remain valid until their short expiry,
                // but their old global idempotency keys must never reveal a
                // bearer token. Give each an unreachable legacy owner and
                // durably upgrade the registry under the same lock.
                state.schemaVersion = 4
                state.leases = state.leases.map {
                    Lease(token: $0.token, ownerPID: $0.ownerPID,
                          ownerInstanceNonce: $0.ownerInstanceNonce ?? "legacy-\($0.token)",
                          expiresAtUptime: $0.expiresAtUptime, idempotencyKey: $0.idempotencyKey)
                }
                try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
                return StateRead(state: state, needsRewrite: true)
            }
            try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
            return StateRead(state: state, needsRewrite: false)
        } catch let error as CoordinatorError { throw error
        } catch { throw CoordinatorError.malformedState }
    }

    private func writeState(_ state: PersistedState, held: HeldLock) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumSerializedBytes else { throw CoordinatorError.malformedState }
        let temporaryName = ".annotations-suspension-v3.\(UUID().uuidString).tmp"
        let fd = openat(held.directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not create temporary suspension state (errno \(errno)).") }
        var installed = false
        defer {
            close(fd)
            if !installed { _ = unlinkat(held.directoryFD, temporaryName, 0) }
        }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not write suspension state (errno \(errno)).") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not sync suspension state (errno \(errno)).") }
        storagePrecommitHook?()
        try validateHeldLock(held)
        guard renameat(held.directoryFD, temporaryName, held.directoryFD, Self.stateName) == 0 else {
            throw CoordinatorError.unavailable("AI Chalkboard could not install suspension state (errno \(errno)).")
        }
        installed = true
        guard fsync(held.directoryFD) == 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not sync suspension-state directory (errno \(errno)).") }
    }

    private static func currentBootSessionIdentifier() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size else { return nil }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func isCanonicalToken(_ token: String) -> Bool {
        token.count == 43 && token.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_"
        }
    }
}

typealias SuspensionLeaseSnapshot = SuspensionLeaseCoordinator.Snapshot
typealias SuspensionLeaseOperationResult = SuspensionLeaseCoordinator.OperationResult
