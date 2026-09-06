import Foundation

/// Advisory single-instance guard used to prevent duplicate status-bar items.
///
/// Claude Desktop spawns TWO `AIChalkboard --mcp` processes for a single MCP
/// server config entry. Both are legitimate, independent MCP stdio servers --
/// Claude Desktop talks to each over its own stdin/stdout pipe -- so neither
/// process can simply exit or skip protocol handling; doing so would make
/// Claude Desktop see a dropped/failed connection, which is strictly worse
/// than a cosmetic duplicate menu-bar icon.
///
/// This lock exists ONLY to elect exactly one of the two processes as
/// "primary" so only ONE of them installs the status-bar item (a genuine
/// OS-level singleton resource -- two of them look broken/duplicated to the
/// user). It must never be used to gate `MCPServer.shared.start()` or
/// `OverlayWindowController.shared.setup()`; those must run in every process
/// regardless of who wins the lock.
///
/// This class holds the entire election policy and is Foundation-only: the
/// primitive it elects over (`Primitive`) is where every platform-specific
/// line lives -- see `FileLockPrimitive` and each conformance in
/// `InstanceLock.swift`. Everything below this point applies identically on
/// macOS and Windows; where the two platforms genuinely differ in what a
/// guarantee costs (mandatory vs advisory locking, how reliable an identity
/// check is), that is documented on the primitive conformance that makes the
/// difference real, not here.
// NOT `final`: this class is generic, and this Swift toolchain does not
// support a static STORED property inside a generic type ("static stored
// properties not supported in generic types") -- there is no per-`Primitive`
// storage to back a generic `shared`. Its one non-generic subclass in each
// of `InstanceLock.swift`'s platform branches (`InstanceLock`, unrelated to
// this class's own designated initializers otherwise) is what actually
// carries `public static let shared`; that subclass is concrete, so the
// restriction does not apply to it. Only that platform-specific subclass is
// ever compiled into a given build, so this is a purely structural
// accommodation, not a behavioral one -- see `InstanceLock.swift`.
public class InstanceLockPolicy<Primitive: FileLockPrimitive>: @unchecked Sendable {
    /// Test-only path override. Production resolves the user's per-app data
    /// directory; isolated tests use a unique temporary file and therefore
    /// never contend with or mutate the live app's lock.
    private let lockURLOverride: URL?
    private let logHandler: (String, String) -> Void

    /// Kept open for the lifetime of the process. Releasing this handle (or
    /// letting it be deallocated) would release the underlying lock, so it
    /// is intentionally never released once acquired. `nil` means "not
    /// held" -- see each primitive conformance's `releaseAndClose` doc for
    /// exactly what releasing does on that platform.
    private var lockFileHandle: Primitive.Handle?

    /// Cached outcome of the first `acquire()` call, so subsequent calls are
    /// idempotent. The underlying platform lock is scoped to the open
    /// handle/file description the primitive's `openLockFile` returns, not
    /// to the process or to the path. A naive second call would open a
    /// brand-new handle on the same path and then lock IT -- contending
    /// against the lock this very process already holds via the first
    /// handle. That self-contention reports back as "somebody else holds
    /// it", so an uncached `acquire()` would lie and say "secondary" even
    /// though this process is (and remains) primary. Caching the first
    /// result avoids ever re-opening/re-locking. See each primitive
    /// conformance's `tryLock` doc for the specific errno/Win32 code this
    /// self-contention reports.
    private var acquired: Bool?

    /// How many consecutive retry polls have found NO lock file at all.
    /// See `missingLockFilePollsBeforeRecreate`.
    private var consecutiveMissingLockFilePolls = 0

    /// Last retry-only anomaly written to the log. Retry acquisition runs every
    /// three seconds and Logger has no level filtering, so an unresolved error
    /// is logged once per episode rather than once per poll.
    private var lastRetryAnomaly: String?

    /// How long a secondary tolerates a missing lock file before recreating it
    /// and promoting itself, expressed in retry polls.
    ///
    /// This number is a race resolver, and it is why the value is not 1:
    ///   * If a primary is ALIVE, `revalidatePrimaryLock()` recreates a deleted
    ///     lock file on ITS timer -- the same 3s interval this poll runs at
    ///     (`AppDelegate.primaryElectionRetryInterval` drives both). So a live
    ///     primary makes the file reappear within about one poll. Waiting
    ///     several polls means a secondary never mistakes that repair window for
    ///     "the primary is gone".
    ///   * If NO primary is alive (the lock file was deleted and then the
    ///     primary exited, or the whole per-app data folder was wiped),
    ///     nobody will ever recreate it, and refusing forever would strand this
    ///     process exactly the way losing the election permanently used to:
    ///     no status item, no Dock icon in MCP mode, no window.
    /// Four polls is ~12s: several times the repair window, and a delay the
    /// user reads as "it came back" rather than "it is broken". This is a
    /// design choice about polling cadence, not a platform-specific one, so
    /// it is unchanged between macOS and Windows.
    private static var missingLockFilePollsBeforeRecreate: Int { 4 }

    /// What one `performAcquire` attempt concluded.
    private enum AcquireOutcome {
        /// This process holds the lock (or should behave as though it does).
        case primary
        /// Somebody else holds it, or an error said "do not promote".
        case secondary
        /// There is no lock file at the path AND this caller was not allowed to
        /// create one. Distinct from `.secondary` because it says nothing about
        /// whether a primary exists -- only the caller's policy can decide what
        /// to do about it.
        case lockFileMissing
    }

    /// A primary lock check has more than two meaningful outcomes: a fail-open
    /// primary with no handle must retain its UI, while only a proven owner
    /// of the repaired path should make this process relinquish it.
    public enum RevalidationResult: Equatable {
        case retainPrimary
        case relinquishToPathOwner
    }

    /// Not `private`: the platform-specific `InstanceLock` subclass in
    /// `InstanceLock.swift` (a different file) calls this via automatic
    /// initializer inheritance to build `.shared`. Still not `public`: no
    /// code outside this module can call it, so external callers are still
    /// limited to going through a platform's `InstanceLock.shared` or the
    /// explicit test initializer below, exactly as before this refactor.
    init() {
        // A subprocess integration test needs each pair of test servers to
        // elect within its own temporary namespace rather than contend with a
        // live desktop agent. Never accept an arbitrary production path from
        // the environment: the override is restricted to the current process'
        // temporary directory and must name an ordinary file beneath it. See
        // each primitive's `testLockURLFromEnvironment` for the platform-
        // specific path syntax this validates.
        //
        // Falling back to this process's own sandbox under a test bundle is
        // not cosmetic isolation. The production path is the SAME
        // `instance.lock` the user's running connector holds to stay primary,
        // so a test reaching `InstanceLock.shared` contended for it directly
        // and could demote the live primary -- taking its tray icon with it --
        // on a developer machine that happened to have the app running. The
        // explicit environment override still wins, so the subprocess
        // integration tests that deliberately share a namespace are
        // unaffected. See `TestHarness`.
        lockURLOverride = Primitive.testLockURLFromEnvironment()
            ?? (TestHarness.isActive
                ? TestHarness.sandboxDirectory.appendingPathComponent("instance.lock")
                : nil)
        logHandler = { message, level in
            Logger.shared.log(message, level: level)
        }
    }

    public init(lockURL: URL, logHandler: @escaping (String, String) -> Void = { _, _ in }) {
        lockURLOverride = lockURL
        self.logHandler = logHandler
    }

    deinit {
        if let handle = lockFileHandle {
            Primitive.releaseAndClose(handle)
        }
    }

    /// Attempts to become the primary instance.
    ///
    /// Returns `true` if this process should behave as primary -- either
    /// because it genuinely acquired the exclusive lock, or because
    /// something went wrong creating/opening/locking the lock file. Failures
    /// fail OPEN (return true): a broken lock file must never disable the
    /// app's UI for every instance.
    ///
    /// THE FAIL-OPEN POLICY IS SPECIFIC TO THIS METHOD -- it applies to the
    /// t=0 election only, where "nobody owns the UI" is the worst outcome.
    /// `retryAcquire()` passes `failOpen: false` and fails CLOSED instead,
    /// because by then an incumbent primary is known to exist and the worst
    /// outcome is a permanent second status-bar item. Do not restate this
    /// paragraph as "same policy as acquire()"; that is what it used to say and
    /// it no longer holds.
    ///
    /// Idempotent: safe to call more than once; subsequent calls return the
    /// cached outcome of the first call without touching the filesystem or
    /// the lock again (see the `acquired` doc comment for why that matters).
    ///
    /// A process that LOSES this election is not condemned to stay secondary
    /// forever -- see `retryAcquire()`.
    @discardableResult
    public func acquire() -> Bool {
        if let acquired {
            return acquired
        }
        // `createIfMissing` defaults to true here, so `.lockFileMissing` cannot
        // occur: on a first run the lock file legitimately does not exist yet
        // and somebody has to create it.
        let outcome = (performAcquire() == .primary)
        acquired = outcome
        return outcome
    }

    /// Non-caching re-election attempt: "is the primary slot free *now*?"
    ///
    /// WHY THIS EXISTS -- do not delete it as redundant with `acquire()`.
    /// `acquire()` caches its answer for the lifetime of the process, so a
    /// process that lost the election at t=0 could never win it later. But the
    /// primary can die by many paths other than the menu's Quit: it crashes,
    /// Claude Desktop closes only its pipe (stdin EOF), someone runs `kill`,
    /// a watchdog fires. The platform lock is ALWAYS released when it dies --
    /// the lock genuinely becomes free -- and with a cached answer nothing
    /// ever retried it.
    ///
    /// The surviving secondary would then have no user interface whatsoever:
    /// `.accessory` activation policy in MCP mode (no Dock icon), no
    /// status-bar item (it lost the election at t=0, and that answer was
    /// cached), and no window at all since the floating Clear/Quit panel was
    /// deleted as "redundant with the menu-bar item". Meanwhile its own
    /// `AnnotationStore` may still be FULL, so stale annotations stay painted
    /// across every screen with no way to clear them and no way to quit the
    /// process. Before the floating panel was removed, that panel became the
    /// frontmost clickable surface the instant the primary's vanished; this
    /// re-election is what replaces that lost fallback.
    ///
    /// Semantics, deliberately different from `acquire()`:
    /// * Never consults the cache -- the whole point is to re-test reality.
    /// * Never records a NEGATIVE result. Losing a retry says nothing about
    ///   the future, so the caller is expected to keep polling.
    /// * A WINNING retry does update the cached value, because from that
    ///   moment this process really is the primary and a later `acquire()`
    ///   must not keep insisting otherwise. (Corrects the cache upward only;
    ///   it can never poison it with a spurious "secondary".)
    /// * FAILS CLOSED, unlike `acquire()`. Failing open is right at t=0 (if
    ///   locking is broken, SOMEONE must own the UI) but wrong here: this
    ///   process already knows another instance won the election and therefore
    ///   already has a working menu, so an unexpected locking failure says
    ///   nothing about the primary being gone. Returning true on those would
    ///   latch `acquired = true`, invalidate the retry timer and install a
    ///   SECOND status item next to the live one -- permanently, with no
    ///   self-correction, and with ~28,800 chances a day per secondary to hit
    ///   it. So: keep polling instead of self-promoting.
    /// * VALIDATES THE IDENTITY of what it locked (`verifyIdentity`), because
    ///   winning a lock on a lock file that has been REPLACED proves nothing.
    ///   See `performAcquire` and each primitive conformance's `Identity` doc.
    /// * NEVER CREATES the lock file (`createIfMissing: false`) on an ordinary
    ///   poll. Creating it is how a secondary used to manufacture a fresh file
    ///   identity and promote itself beside a live primary that still held the
    ///   unlinked original -- measured: two permanent status-bar items, ~3s
    ///   after the lock file was deleted. It escalates to creating only after
    ///   the file has been missing for `missingLockFilePollsBeforeRecreate`
    ///   polls, i.e. longer than a live primary's own repair takes.
    /// * No handle leak: `performAcquire` closes the probe handle on every
    ///   path that does not become the lock holder, so polling every few
    ///   seconds for hours cannot exhaust the process' descriptor/handle
    ///   table.
    ///
    /// Main-thread only (driven by AppDelegate's re-election timer); the
    /// state it touches is not synchronized.
    @discardableResult
    public func retryAcquire() -> Bool {
        // Already holding the lock -- from the original `acquire()` or from an
        // earlier winning retry. Return true WITHOUT touching the filesystem:
        // re-opening the path here would create a second handle and lock IT
        // against the one this very process already holds, which reports
        // contention and would make us self-demote. See the `acquired` doc
        // comment.
        if lockFileHandle != nil {
            return true
        }

        // `logContention: false` keeps the routine "still secondary" line out
        // of the log: this runs every few seconds for as long as the primary
        // lives, and Logger has no level filtering (every line hits stderr and
        // the rotating file). Genuine anomalies (fail-open paths) still log.
        //
        // `failOpen: false`, `verifyIdentity: true` and `createIfMissing: false`
        // are what make repeated polling safe -- see this method's doc comment
        // and `performAcquire`.
        switch performAcquire(logContention: false, failOpen: false, verifyIdentity: true, createIfMissing: false) {
        case .primary:
            clearRetryAnomaly()
            consecutiveMissingLockFilePolls = 0
            acquired = true
            return true

        case .secondary:
            consecutiveMissingLockFilePolls = 0
            return false

        case .lockFileMissing:
            clearRetryAnomaly()
            // No lock file at all. A LIVE primary repairs that within about one
            // poll (`revalidatePrimaryLock`), so a single sighting proves
            // nothing -- but an indefinite refusal would strand this process if
            // the file was deleted and the primary then exited. Wait out the
            // repair window, then create it and take the role.
            consecutiveMissingLockFilePolls += 1
            guard consecutiveMissingLockFilePolls >= Self.missingLockFilePollsBeforeRecreate else {
                return false
            }
            consecutiveMissingLockFilePolls = 0

            log("InstanceLock: the lock file has been missing for \(Self.missingLockFilePollsBeforeRecreate) consecutive polls -- long enough that a live primary would have recreated it. Assuming no primary exists (deleted lock file plus an exited primary, or a wiped application data folder) and recreating it now, so this process is not left with no status item, no Dock icon and no window.", level: "INFO")

            if performAcquire(logContention: false, failOpen: false, verifyIdentity: true, createIfMissing: true) == .primary {
                acquired = true
                return true
            }
            return false
        }
    }

    /// Primary-only self-check, driven by the same 3s timer that secondaries use
    /// for re-election: is the handle this process holds still the file that
    /// lives at the lock path? If not, RE-CREATE and re-lock the file.
    ///
    /// WHY A PRIMARY HAS TO REPAIR ITS OWN LOCK -- this is the other half of the
    /// "deleted lock file" fix, and neither half works alone:
    ///
    /// The lock this primitive hands out is held on the open file OBJECT
    /// `openLockFile` returned, not on the path used to reach it -- true of a
    /// POSIX open file description and of a Win32 HANDLE alike (see each
    /// primitive conformance for the platform mechanism). Delete
    /// `instance.lock` (uninstaller, "clear app data", manual
    /// troubleshooting) and the primary keeps a perfectly valid lock on an
    /// object that no longer has a name. Nothing on disk then connects the
    /// primary to the lock path, so a secondary polling that path has NO way to
    /// discover the primary -- whatever it does with that path, it is reasoning
    /// about a different file. Only the primary can restore the link, so only
    /// the primary can fix it.
    ///
    /// With `retryAcquire()` no longer creating the file, the two halves give:
    ///   * file deleted, primary alive  -> secondary finds "missing" and keeps
    ///     polling; primary recreates the file within 3s; secondary then
    ///     contends against it normally and stays secondary. No second menu.
    ///   * file deleted, primary dies   -> the repaired file (or, if the
    ///     primary died first, the original) is present and unlocked, so the
    ///     secondary promotes as designed. Nothing is stranded.
    ///
    /// Cheap: two identity lookups per tick, and it only does real work on the
    /// (essentially never) mismatch path. No-ops in a process that is primary
    /// only because locking failed open (`lockFileHandle == nil`): there is no
    /// lock to validate, and re-testing could only produce a false alarm.
    @discardableResult
    public func revalidatePrimaryLock() -> RevalidationResult {
        // Initial acquisition deliberately fails open when locking itself is
        // unavailable. No handle is not proof that somebody else owns the
        // role, so the only safe result is to keep the sole user-facing UI.
        guard let currentHandle = lockFileHandle else { return .retainPrimary }

        guard let lockURL = resolveLockURL(failureWording: "cannot revalidate the primary lock this tick", logFailures: false) else {
            logRetryAnomalyOnce(
                key: "primary-resolve-lock-url",
                message: "InstanceLock: could not resolve or create the primary lock path. Retaining the primary role and suppressing repeats until the condition changes."
            )
            return .retainPrimary
        }

        let fdIdentityLookup = Primitive.identity(ofOpenHandle: currentHandle)
        guard case .found(let fdIdentity) = fdIdentityLookup else {
            let description: String
            if case .error(let d) = fdIdentityLookup { description = d } else { description = "unknown" }
            logRetryAnomalyOnce(
                key: "primary-handle-info-\(description)",
                message: "InstanceLock: could not inspect the primary lock handle (\(description)). Retaining the primary role because this does not prove another process owns it; will retry next tick."
            )
            return .retainPrimary
        }

        switch Primitive.identity(atPath: lockURL.path) {
        case .found(let pathIdentity) where pathIdentity == fdIdentity:
            clearRetryAnomaly()
            return .retainPrimary

        case .found, .missing:
            // Path names a different file, or is gone entirely -- fall
            // through to the repair below.
            break

        case .error(let description):
            logRetryAnomalyOnce(
                key: "primary-stat-\(description)",
                message: "InstanceLock: could not inspect the primary lock path at \(lockURL.path) (\(description)). Retaining the primary role because this does not prove replacement; will retry next tick."
            )
            return .retainPrimary
        }

        // `.notFound` cannot occur here: `createIfMissing: true` means the
        // primitive is only ever allowed to report `.opened` or `.failed`
        // (see `LockOpenOutcome.notFound`'s doc comment).
        let repairOpenOutcome = Primitive.openLockFile(at: lockURL.path, createIfMissing: true)
        guard case .opened(let newHandle) = repairOpenOutcome else {
            let description: String
            if case .failed(let d) = repairOpenOutcome { description = d } else { description = "unknown" }
            logRetryAnomalyOnce(
                key: "primary-repair-open-\(description)",
                message: "InstanceLock: could not recreate \(lockURL.path) (\(description)). Retaining the existing primary role; will retry next tick."
            )
            return .retainPrimary
        }

        switch Primitive.tryLock(newHandle) {
        case .acquired:
            break

        case .contended:
            let replacementIsPathVisible = identitiesMatch(newHandle, path: lockURL.path)
            Primitive.releaseAndClose(newHandle)

            if replacementIsPathVisible {
                log("InstanceLock: another process holds the path-visible replacement at \(lockURL.path). Relinquishing this process's orphaned lock and primary role so there cannot be two permanent status-bar owners.", level: "WARN")
                Primitive.releaseAndClose(currentHandle)
                lockFileHandle = nil
                acquired = false
                clearRetryAnomaly()
                return .relinquishToPathOwner
            }

            logRetryAnomalyOnce(
                key: "primary-repair-lock-contended-visible-\(replacementIsPathVisible)",
                message: "InstanceLock: could not lock the replacement at \(lockURL.path) (path-visible=\(replacementIsPathVisible)). Retaining the existing primary role because this is not proof of a competing path owner; will retry next tick."
            )
            return .retainPrimary

        case .failed(let description):
            let replacementIsPathVisible = identitiesMatch(newHandle, path: lockURL.path)
            Primitive.releaseAndClose(newHandle)
            logRetryAnomalyOnce(
                key: "primary-repair-lock-failed-\(description)-visible-\(replacementIsPathVisible)",
                message: "InstanceLock: could not lock the replacement at \(lockURL.path) (\(description), path-visible=\(replacementIsPathVisible)). Retaining the existing primary role because this is not proof of a competing path owner; will retry next tick."
            )
            return .retainPrimary
        }

        // The path can be replaced between open() and the lock call. Never
        // exchange one orphaned handle for another that secondaries cannot
        // discover.
        guard identitiesMatch(newHandle, path: lockURL.path) else {
            Primitive.releaseAndClose(newHandle)
            logRetryAnomalyOnce(
                key: "primary-repair-identity-race",
                message: "InstanceLock: locked a replacement handle, but it no longer matches \(lockURL.path). Retaining the existing primary role and retrying next tick."
            )
            return .retainPrimary
        }

        // Release the orphan only after its discoverable replacement is held.
        Primitive.releaseAndClose(currentHandle)
        lockFileHandle = newHandle
        clearRetryAnomaly()
        log("InstanceLock: primary lock repaired -- now holding \(lockURL.path).", level: "INFO")
        return .retainPrimary
    }

    /// Whether `handle`'s identity matches whatever currently sits at `path`.
    /// Any failure to determine either identity is treated as "no match" --
    /// an inconclusive identity check must never be read as proof of a
    /// match. See `FileLockPrimitive`'s doc comment on identity being
    /// best-effort on some platforms.
    /// Compares a locked handle against whatever currently sits at the path it
    /// was opened through, KEEPING both identities so a caller can say why they
    /// differed.
    ///
    /// The detail is not decoration. This comparison failing is the signal that
    /// the lock file was deleted or replaced under a live holder, and the
    /// resulting WARN is rare, fires only when the election is already behaving
    /// strangely, and is the sole record of what actually happened. The
    /// pre-consolidation macOS code logged both `(st_dev, st_ino)` pairs and
    /// whether each lookup succeeded, for exactly that reason; returning a bare
    /// `Bool` here would have quietly thrown that away for both platforms.
    private struct IdentityComparison {
        let matches: Bool
        /// Both sides rendered for a log line, e.g.
        /// `handle=dev/ino 16777232/1234 path=dev/ino 16777232/5678`, or with
        /// `<missing>` / `<error: ...>` where a lookup did not return one.
        let detail: String
    }

    private func compareIdentities(_ handle: Primitive.Handle, path: String) -> IdentityComparison {
        let handleLookup = Primitive.identity(ofOpenHandle: handle)
        let pathLookup = Primitive.identity(atPath: path)

        let handleDescription: String
        var handleIdentity: Primitive.Identity?
        switch handleLookup {
        case .found(let identity):
            handleIdentity = identity
            handleDescription = identity.description
        case .error(let description):
            handleDescription = "<error: \(description)>"
        }

        let pathDescription: String
        var pathIdentity: Primitive.Identity?
        switch pathLookup {
        case .found(let identity):
            pathIdentity = identity
            pathDescription = identity.description
        case .missing:
            pathDescription = "<missing>"
        case .error(let description):
            pathDescription = "<error: \(description)>"
        }

        // An unreadable identity on EITHER side is treated as a non-match,
        // exactly as the pre-consolidation code did on both platforms: the
        // point of this check is to PROVE the locked object is still the file
        // at the path, and a lookup that failed proves nothing.
        let matches: Bool
        if let handleIdentity, let pathIdentity {
            matches = handleIdentity == pathIdentity
        } else {
            matches = false
        }

        return IdentityComparison(
            matches: matches,
            detail: "handle=\(handleDescription) path=\(pathDescription)"
        )
    }

    private func identitiesMatch(_ handle: Primitive.Handle, path: String) -> Bool {
        compareIdentities(handle, path: path).matches
    }

    private func logRetryAnomalyOnce(key: String, message: String) {
        guard lastRetryAnomaly != key else { return }
        lastRetryAnomaly = key
        log(message, level: "WARN")
    }

    private func clearRetryAnomaly() {
        lastRetryAnomaly = nil
    }

    private func log(_ message: String, level: String) {
        logHandler(message, level)
    }

    /// Resolves the lock file's URL, creating its directory if needed.
    /// `nil` (with a WARN naming `failureWording`) when that is not possible.
    private func resolveLockURL(failureWording: String, logFailures: Bool = true) -> URL? {
        if let lockURLOverride {
            return lockURLOverride
        }

        switch Primitive.resolveDefaultLockDirectory() {
        case .success(let appDir):
            return appDir.appendingPathComponent("instance.lock")
        case .failure(let reason):
            if logFailures {
                log("InstanceLock: \(reason); \(failureWording).", level: "WARN")
            }
            return nil
        }
    }

    /// - Parameters:
    ///   - logContention: whether a plain "someone else holds it" outcome is
    ///     worth a log line (false for the every-3s poll).
    ///   - failOpen: what an UNEXPECTED failure (no application data
    ///     directory, createDirectory error, open error, non-contention lock
    ///     error) should return. `true` for the t=0 election -- if locking
    ///     is broken somebody has to own the UI. `false` for the retry poll
    ///     -- another instance is known to be primary already, so an
    ///     unrelated error must not promote this process into a second
    ///     menu-bar owner.
    ///   - verifyIdentity: whether a WINNING lock must additionally prove
    ///     that the handle it locked is still the file at `lockURL`.
    ///   - createIfMissing: whether a missing lock file may be CREATED. True
    ///     for the t=0 election (first run ever; somebody has to make it).
    ///     FALSE for the retry poll: creating it there is precisely how a
    ///     secondary used to manufacture a brand-new file identity, lock it
    ///     trivially and promote itself next to a live primary that still
    ///     held the unlinked original. A missing file on the retry path
    ///     means "the primary's lock is unreachable", not "the primary is
    ///     gone" -- so report `.lockFileMissing` and let
    ///     `revalidatePrimaryLock()` on the primary side restore the file.
    ///     `retryAcquire()` escalates back to `createIfMissing: true` if the
    ///     file stays missing for several polls, which is the only way to
    ///     tell "a primary is repairing it" from "nobody is left to repair
    ///     it"; see `missingLockFilePollsBeforeRecreate`.
    private func performAcquire(logContention: Bool = true, failOpen: Bool = true, verifyIdentity: Bool = false, createIfMissing: Bool = true) -> AcquireOutcome {
        let failureOutcome: AcquireOutcome = failOpen ? .primary : .secondary
        let failureWording = failOpen
            ? "failing open (treating this process as primary)"
            : "failing closed (staying secondary and continuing to poll; another instance is already primary)"

        guard let lockURL = resolveLockURL(failureWording: failureWording, logFailures: logContention) else {
            if !logContention {
                logRetryAnomalyOnce(
                    key: "retry-resolve-lock-url",
                    message: "InstanceLock: retry could not resolve or create the lock path; staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }

        // `openLockFile` rejects a symlink/reparse-point target or
        // non-regular file before it can influence the election -- see its
        // doc comment.
        let openOutcome = Primitive.openLockFile(at: lockURL.path, createIfMissing: createIfMissing)
        let handle: Primitive.Handle
        switch openOutcome {
        case .opened(let h):
            handle = h
        case .notFound:
            // Expected on the retry path when the lock file has been
            // deleted. NOT evidence that the primary died -- see
            // `createIfMissing` above. Do not log this recurring retry
            // condition: Logger intentionally has no level filtering.
            return .lockFileMissing
        case .failed(let description):
            if logContention {
                log("InstanceLock: failed to open lock file at \(lockURL.path) (\(description)); \(failureWording).", level: "WARN")
            } else {
                logRetryAnomalyOnce(
                    key: "retry-open-\(description)",
                    message: "InstanceLock: retry could not open \(lockURL.path) (\(description)); staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }

        // Non-blocking exclusive lock: reports contention immediately if
        // another live process already holds it, rather than hanging this
        // process waiting for it.
        switch Primitive.tryLock(handle) {
        case .acquired:
            // WINNING THE LOCK IS NOT ENOUGH ON A RETRY. The lock is held on
            // an open file OBJECT (what `openLockFile` returned), but
            // opening resolves a PATH. If instance.lock is deleted or
            // replaced while the real primary is running -- an uninstaller,
            // "clear app data", a user troubleshooting by deleting files --
            // then this open creates a handle to a BRAND NEW file that
            // nobody holds, the lock trivially succeeds, and this process
            // would promote itself while the live primary still holds its
            // lock on the now-unreachable original. Result: two menu-bar
            // icons, forever, with no self-correction -- and the 3s
            // re-election timer re-armed that race continuously.
            //
            // So compare the handle we just locked against the path it was
            // supposed to be: matching identity, or this lock is
            // meaningless. Only the retry path needs it (at t=0 there is no
            // incumbent to duplicate, and failing there would leave nobody
            // with a menu).
            let identityComparison = verifyIdentity
                ? compareIdentities(handle, path: lockURL.path)
                : nil
            if let identityComparison, !identityComparison.matches {
                // Deliberately leaves `lockFileHandle` at nil: this
                // process did NOT become the lock holder, so a later
                // `retryAcquire()` must go through the whole probe again
                // rather than short-circuiting on a held handle.
                Primitive.releaseAndClose(handle)
                if logContention {
                    log("InstanceLock: won a lock at \(lockURL.path) but the locked handle is NOT the file at that path any more (\(identityComparison.detail)) -- the lock file was deleted or replaced, so this win proves nothing about the incumbent primary, which may still be alive and owning the status item. Declining the promotion and continuing to poll.", level: "WARN")
                } else {
                    logRetryAnomalyOnce(
                        key: "retry-identity-mismatch",
                        message: "InstanceLock: a retry locked a handle that no longer matches \(lockURL.path) (\(identityComparison.detail)). Declining promotion; repeats are suppressed until the outcome changes."
                    )
                }
                return .secondary
            }

            // Primary instance. Hold the handle open for the process
            // lifetime -- see comment on lockFileHandle above.
            lockFileHandle = handle
            log("InstanceLock: acquired primary instance lock at \(lockURL.path).", level: "INFO")
            return .primary

        case .contended:
            // Genuine contention: another live process already holds the
            // lock, so this one is secondary. Closing the probe handle is
            // what makes repeated `retryAcquire()` polling safe: without it
            // every retry would leak a handle until the process hit its
            // descriptor/handle table limit.
            Primitive.releaseAndClose(handle)
            if logContention {
                log("InstanceLock: lock at \(lockURL.path) already held by another process; this process is secondary.", level: "INFO")
            } else {
                clearRetryAnomaly()
            }
            return .secondary

        case .failed(let description):
            // The locking mechanism itself failed for a reason unrelated to
            // contention -- NOT that another instance holds the lock.
            //
            // WHICH WAY TO FAIL DEPENDS ON THE CALLER, hence `failOpen`:
            //
            //   * t=0 election (`acquire()`, failOpen: true): fail OPEN.
            //     Failing closed would tell the ONLY running instance that it
            //     is secondary, so it would never install the status item. In
            //     MCP mode the app runs with `.accessory` activation policy --
            //     no Dock icon -- so the status-bar menu is the sole remaining
            //     UI affordance to Clear/Quit; wrongly suppressing it would
            //     leave that instance with no way to quit at all.
            //
            //   * retry poll (`retryAcquire()`, failOpen: false): fail CLOSED.
            //     By then this process has already been told another instance
            //     is primary and presumably has a working menu, so "locking
            //     misbehaved for an unrelated reason" is no evidence at all
            //     that the slot is free. Returning true here would latch
            //     `acquired`, kill the timer and add a permanent second
            //     status-bar item -- and the poll gets thousands of attempts a
            //     day to trip over a transient failure.
            Primitive.releaseAndClose(handle)
            if logContention {
                log("InstanceLock: locking failed at \(lockURL.path) with unexpected error (\(description)); \(failureWording).", level: "WARN")
            } else {
                logRetryAnomalyOnce(
                    key: "retry-lock-\(description)",
                    message: "InstanceLock: retry locking failed at \(lockURL.path) with unexpected error (\(description)); staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }
    }
}
