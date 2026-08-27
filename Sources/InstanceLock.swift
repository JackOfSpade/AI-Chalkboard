import Foundation
import Darwin

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
/// `OverlayWindowController.shared.setup()`; those must run in every
/// process regardless of who wins the lock.
public final class InstanceLock: @unchecked Sendable {
    public static let shared = InstanceLock()

    /// Test-only path override. Production resolves the user's Application
    /// Support path; isolated tests use a unique temporary file and therefore
    /// never contend with or mutate the live app's lock.
    private let lockURLOverride: URL?
    private let logHandler: (String, String) -> Void

    /// Kept open for the lifetime of the process. Closing this descriptor
    /// (or letting it be deallocated) would release the flock, so it is
    /// intentionally never closed once acquired.
    private var lockFileDescriptor: Int32 = -1

    /// Cached outcome of the first `acquire()` call, so subsequent calls are
    /// idempotent. `flock` locks are scoped to the *open file description*
    /// (the kernel object `open()` creates), not to the process. A naive
    /// second call would `open()` a brand-new descriptor on the same path
    /// and then `flock()` it -- contending against the lock this very
    /// process already holds via the first descriptor. That self-contention
    /// reports EWOULDBLOCK, so an uncached `acquire()` would lie and say
    /// "secondary" even though this process is (and remains) primary.
    /// Caching the first result avoids ever re-opening/re-locking.
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
    ///     primary exited, or the whole Application Support folder was wiped),
    ///     nobody will ever recreate it, and refusing forever would strand this
    ///     process exactly the way losing the election permanently used to:
    ///     no status item, no Dock icon in MCP mode, no window.
    /// Four polls is ~12s: several times the repair window, and a delay the
    /// user reads as "it came back" rather than "it is broken".
    private static let missingLockFilePollsBeforeRecreate = 4

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
    /// primary with no descriptor must retain its UI, while only a proven owner
    /// of the repaired path should make this process relinquish it.
    public enum RevalidationResult: Equatable {
        case retainPrimary
        case relinquishToPathOwner
    }

    private init() {
        // A subprocess integration test needs each pair of test servers to
        // elect within its own temporary namespace rather than contend with a
        // live desktop agent. Never accept an arbitrary production path from
        // the environment: the override is restricted to the current process'
        // temporary directory and must name an ordinary file beneath it.
        lockURLOverride = Self.testLockURLFromEnvironment()
        logHandler = { message, level in
            Logger.shared.log(message, level: level)
        }
    }

    init(lockURL: URL, logHandler: @escaping (String, String) -> Void = { _, _ in }) {
        lockURLOverride = lockURL
        self.logHandler = logHandler
    }

    deinit {
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
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
    /// a watchdog fires. The kernel ALWAYS releases its flock when it dies --
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
    ///   already has a working menu, so an unexpected errno (EMFILE, ENOLCK,
    ///   EINTR, a transient createDirectory failure) says nothing about the
    ///   primary being gone. Returning true on those would latch
    ///   `acquired = true`, invalidate the retry timer and install a SECOND
    ///   status item next to the live one -- permanently, with no
    ///   self-correction, and with ~28,800 chances a day per secondary to hit
    ///   it. So: keep polling instead of self-promoting.
    /// * VALIDATES THE INODE it locked (`verifyInode`), because winning an
    ///   flock on a lock file that has been REPLACED proves nothing. See
    ///   `performAcquire`.
    /// * NEVER CREATES the lock file (`createIfMissing: false`) on an ordinary
    ///   poll. Creating it is how a secondary used to manufacture a fresh inode
    ///   and promote itself beside a live primary that still held the unlinked
    ///   original -- measured: two permanent status-bar items, ~3s after the
    ///   lock file was deleted. It escalates to creating only after the file has
    ///   been missing for `missingLockFilePollsBeforeRecreate` polls, i.e.
    ///   longer than a live primary's own repair takes.
    /// * No descriptor leak: `performAcquire` closes the probe fd on every
    ///   path that does not become the lock holder, so polling every few
    ///   seconds for hours cannot exhaust the fd table.
    ///
    /// Main-thread only (driven by AppDelegate's re-election timer); the
    /// state it touches is not synchronized.
    @discardableResult
    public func retryAcquire() -> Bool {
        // Already holding the lock -- from the original `acquire()` or from an
        // earlier winning retry. Return true WITHOUT touching the filesystem:
        // re-`open()`ing the path here would create a second open file
        // description and `flock()` it against the one this very process
        // already holds, which reports EWOULDBLOCK and would make us
        // self-demote. See the `acquired` doc comment.
        if lockFileDescriptor >= 0 {
            return true
        }

        // `logContention: false` keeps the routine "still secondary" line out
        // of the log: this runs every few seconds for as long as the primary
        // lives, and Logger has no level filtering (every line hits stderr and
        // the rotating file). Genuine anomalies (fail-open paths) still log.
        //
        // `failOpen: false`, `verifyInode: true` and `createIfMissing: false`
        // are what make repeated polling safe -- see this method's doc comment
        // and `performAcquire`.
        switch performAcquire(logContention: false, failOpen: false, verifyInode: true, createIfMissing: false) {
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

            log("InstanceLock: the lock file has been missing for \(Self.missingLockFilePollsBeforeRecreate) consecutive polls -- long enough that a live primary would have recreated it. Assuming no primary exists (deleted lock file plus an exited primary, or a wiped Application Support folder) and recreating it now, so this process is not left with no status item, no Dock icon and no window.", level: "INFO")

            if performAcquire(logContention: false, failOpen: false, verifyInode: true, createIfMissing: true) == .primary {
                acquired = true
                return true
            }
            return false
        }
    }

    /// Primary-only self-check, driven by the same 3s timer that secondaries use
    /// for re-election: is the descriptor this process holds still the file that
    /// lives at the lock path? If not, RE-CREATE and re-lock the file.
    ///
    /// WHY A PRIMARY HAS TO REPAIR ITS OWN LOCK -- this is the other half of the
    /// "deleted lock file" fix, and neither half works alone:
    ///
    /// `flock` is held on an open file DESCRIPTION; the path is just how you
    /// find one. Delete `instance.lock` (uninstaller, "clear app data", manual
    /// troubleshooting) and the primary keeps a perfectly valid lock on an
    /// inode that no longer has a name. Nothing on disk then connects the
    /// primary to the lock path, so a secondary polling that path has NO way to
    /// discover the primary -- whatever it does with that path, it is reasoning
    /// about a different file. Only the primary can restore the link, so only
    /// the primary can fix it.
    ///
    /// With `retryAcquire()` no longer creating the file, the two halves give:
    ///   * file deleted, primary alive  -> secondary finds ENOENT and keeps
    ///     polling; primary recreates the file within 3s; secondary then
    ///     contends against it normally and stays secondary. No second menu.
    ///   * file deleted, primary dies   -> the repaired file (or, if the
    ///     primary died first, the original) is present and unlocked, so the
    ///     secondary promotes as designed. Nothing is stranded.
    ///
    /// Cheap: two `stat` calls per tick, and it only does real work on the
    /// (essentially never) mismatch path. No-ops in a process that is primary
    /// only because locking failed open (`lockFileDescriptor < 0`): there is no
    /// lock to validate, and re-testing could only produce a false alarm.
    @discardableResult
    public func revalidatePrimaryLock() -> RevalidationResult {
        // Initial acquisition deliberately fails open when locking itself is
        // unavailable. No descriptor is not proof that somebody else owns the
        // role, so the only safe result is to keep the sole user-facing UI.
        guard lockFileDescriptor >= 0 else { return .retainPrimary }

        guard let lockURL = resolveLockURL(failureWording: "cannot revalidate the primary lock this tick", logFailures: false) else {
            logRetryAnomalyOnce(
                key: "primary-resolve-lock-url",
                message: "InstanceLock: could not resolve or create the primary lock path. Retaining the primary role and suppressing repeats until the condition changes."
            )
            return .retainPrimary
        }

        var fdInfo = stat()
        guard fstat(lockFileDescriptor, &fdInfo) == 0 else {
            let err = errno
            logRetryAnomalyOnce(
                key: "primary-fstat-\(err)",
                message: "InstanceLock: could not inspect the primary lock descriptor (errno \(err) \(String(cString: strerror(err)))). Retaining the primary role because this does not prove another process owns it; will retry next tick."
            )
            return .retainPrimary
        }

        var pathInfo = stat()
        let pathOK = stat(lockURL.path, &pathInfo) == 0
        let pathErr = pathOK ? 0 : errno

        if pathOK && fdInfo.st_dev == pathInfo.st_dev && fdInfo.st_ino == pathInfo.st_ino {
            clearRetryAnomaly()
            return .retainPrimary
        }

        guard pathOK || pathErr == ENOENT else {
            logRetryAnomalyOnce(
                key: "primary-stat-\(pathErr)",
                message: "InstanceLock: could not inspect the primary lock path at \(lockURL.path) (errno \(pathErr) \(String(cString: strerror(pathErr)))). Retaining the primary role because this does not prove replacement; will retry next tick."
            )
            return .retainPrimary
        }

        let newFd = openLockFile(at: lockURL.path, createIfMissing: true)
        guard newFd >= 0 else {
            let err = errno
            logRetryAnomalyOnce(
                key: "primary-repair-open-\(err)",
                message: "InstanceLock: could not recreate \(lockURL.path) (errno \(err) \(String(cString: strerror(err)))). Retaining the existing primary role; will retry next tick."
            )
            return .retainPrimary
        }

        guard flock(newFd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            let replacementIsPathVisible = descriptor(newFd, matchesPath: lockURL.path)
            close(newFd)

            if err == EWOULDBLOCK && replacementIsPathVisible {
                log("InstanceLock: another process holds the path-visible replacement at \(lockURL.path). Relinquishing this process's orphaned lock and primary role so there cannot be two permanent status-bar owners.", level: "WARN")
                close(lockFileDescriptor)
                lockFileDescriptor = -1
                acquired = false
                clearRetryAnomaly()
                return .relinquishToPathOwner
            }

            logRetryAnomalyOnce(
                key: "primary-repair-flock-\(err)-visible-\(replacementIsPathVisible)",
                message: "InstanceLock: could not lock the replacement at \(lockURL.path) (errno \(err) \(String(cString: strerror(err))), path-visible=\(replacementIsPathVisible)). Retaining the existing primary role because this is not proof of a competing path owner; will retry next tick."
            )
            return .retainPrimary
        }

        // The path can be replaced between open() and flock(). Never exchange
        // one orphaned descriptor for another that secondaries cannot discover.
        guard descriptor(newFd, matchesPath: lockURL.path) else {
            close(newFd)
            logRetryAnomalyOnce(
                key: "primary-repair-inode-race",
                message: "InstanceLock: locked a replacement descriptor, but it no longer matches \(lockURL.path). Retaining the existing primary role and retrying next tick."
            )
            return .retainPrimary
        }

        // Release the orphan only after its discoverable replacement is held.
        close(lockFileDescriptor)
        lockFileDescriptor = newFd
        clearRetryAnomaly()
        log("InstanceLock: primary lock repaired -- now holding \(lockURL.path) (fd \(newFd)).", level: "INFO")
        return .retainPrimary
    }

    /// The result of asking "is this descriptor still the file at that path?".
    ///
    /// Carries the raw stats, not just the verdict, because the retry path in
    /// `performAcquire` logs the exact dev/ino pair it saw -- that detail is
    /// what makes a rare "lock file was replaced under us" race diagnosable
    /// after the fact. A bare Bool would have forced that call site to keep
    /// its own open-coded copy of this comparison, which is precisely what it
    /// used to do.
    private struct DescriptorPathComparison {
        let fdOK: Bool
        let pathOK: Bool
        let fdInfo: stat
        let pathInfo: stat

        var matches: Bool {
            fdOK && pathOK
                && fdInfo.st_dev == pathInfo.st_dev
                && fdInfo.st_ino == pathInfo.st_ino
        }
    }

    private func compare(_ fd: Int32, toPath path: String) -> DescriptorPathComparison {
        var fdInfo = stat()
        var pathInfo = stat()
        let fdOK = fstat(fd, &fdInfo) == 0
        let pathOK = stat(path, &pathInfo) == 0
        return DescriptorPathComparison(fdOK: fdOK, pathOK: pathOK, fdInfo: fdInfo, pathInfo: pathInfo)
    }

    private func descriptor(_ fd: Int32, matchesPath path: String) -> Bool {
        compare(fd, toPath: path).matches
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

    /// Opens only a path-owned regular file for the advisory lock.
    ///
    /// The lock is an election primitive, not a general file lock. Following
    /// a symlink could silently lock an unrelated file and leave the actual
    /// lock path undiscoverable to other instances. FIFOs and devices are
    /// likewise invalid election targets, so reject them before `flock`.
    private func openLockFile(at path: String, createIfMissing: Bool) -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
        let fd = open(path, flags, 0o644)
        guard fd >= 0 else { return -1 }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            errno = EINVAL
            return -1
        }
        return fd
    }

    private static func testLockURLFromEnvironment() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["AI_CHALKBOARD_INSTANCE_LOCK_PATH"],
              raw.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let parent = candidate.deletingLastPathComponent().standardizedFileURL.path
        guard candidate.lastPathComponent == "instance.lock",
              parent == temporaryRoot || parent.hasPrefix(temporaryRoot + "/") else { return nil }
        return candidate
    }

    /// Resolves the lock file's URL, creating its directory if needed.
    /// `nil` (with a WARN naming `failureWording`) when that is not possible.
    private func resolveLockURL(failureWording: String, logFailures: Bool = true) -> URL? {
        if let lockURLOverride {
            return lockURLOverride
        }

        let fileManager = FileManager.default

        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            if logFailures {
                log("InstanceLock: could not resolve Application Support directory; \(failureWording).", level: "WARN")
            }
            return nil
        }

        let appDir = supportDir.appendingPathComponent("AIChalkboard", isDirectory: true)

        do {
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            if logFailures {
                log("InstanceLock: failed to create lock directory at \(appDir.path): \(error.localizedDescription); \(failureWording).", level: "WARN")
            }
            return nil
        }

        return appDir.appendingPathComponent("instance.lock")
    }

    /// - Parameters:
    ///   - logContention: whether a plain "someone else holds it" outcome is
    ///     worth a log line (false for the every-3s poll).
    ///   - failOpen: what an UNEXPECTED failure (no Application Support dir,
    ///     createDirectory error, open() error, non-EWOULDBLOCK flock errno)
    ///     should return. `true` for the t=0 election -- if locking is broken
    ///     somebody has to own the UI. `false` for the retry poll -- another
    ///     instance is known to be primary already, so an unrelated errno must
    ///     not promote this process into a second menu-bar owner.
    ///   - verifyInode: whether a WINNING flock must additionally prove that the
    ///     descriptor it locked is still the file at `lockURL`.
    ///   - createIfMissing: whether a missing lock file may be CREATED. True for
    ///     the t=0 election (first run ever; somebody has to make it). FALSE for
    ///     the retry poll: creating it there is precisely how a secondary used
    ///     to manufacture a brand-new inode, lock it trivially and promote
    ///     itself next to a live primary that still held the unlinked original.
    ///     A missing file on the retry path means "the primary's lock is
    ///     unreachable", not "the primary is gone" -- so report
    ///     `.lockFileMissing` and let `revalidatePrimaryLock()` on the primary
    ///     side restore the file. `retryAcquire()` escalates back to
    ///     `createIfMissing: true` if the file stays missing for several polls,
    ///     which is the only way to tell "a primary is repairing it" from
    ///     "nobody is left to repair it"; see
    ///     `missingLockFilePollsBeforeRecreate`.
    private func performAcquire(logContention: Bool = true, failOpen: Bool = true, verifyInode: Bool = false, createIfMissing: Bool = true) -> AcquireOutcome {
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

        // Raw POSIX open() rather than FileHandle, since flock() needs the
        // underlying file descriptor directly. `openLockFile` also rejects a
        // symlink or non-regular file before it can influence the election.
        let fd = openLockFile(at: lockURL.path, createIfMissing: createIfMissing)
        guard fd >= 0 else {
            // Capture errno immediately: any Foundation call can clobber it.
            let err = errno
            if !createIfMissing && err == ENOENT {
                // Expected on the retry path when the lock file has been
                // deleted. NOT evidence that the primary died -- see
                // `createIfMissing` above. Do not log this recurring retry
                // condition: Logger intentionally has no level filtering.
                return .lockFileMissing
            }
            if logContention {
                log("InstanceLock: failed to open lock file at \(lockURL.path) (errno \(err) \(String(cString: strerror(err)))); \(failureWording).", level: "WARN")
            } else {
                logRetryAnomalyOnce(
                    key: "retry-open-\(err)",
                    message: "InstanceLock: retry could not open \(lockURL.path) (errno \(err) \(String(cString: strerror(err)))); staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }

        // Non-blocking exclusive advisory lock: returns immediately with
        // EWOULDBLOCK if another live process already holds it, rather than
        // hanging this process waiting for it.
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result == 0 {
            // WINNING THE FLOCK IS NOT ENOUGH ON A RETRY. `flock` is held on an
            // open file DESCRIPTION (the kernel object), but `open()` above
            // resolves a PATH. If instance.lock is unlinked or replaced while
            // the real primary is running -- an uninstaller, "clear app data",
            // a user troubleshooting by deleting Application Support files --
            // then this open() creates a BRAND NEW inode that nobody holds, the
            // flock trivially succeeds, and this process would promote itself
            // while the live primary still holds its lock on the now-unlinked
            // inode and still owns the status item. Result: two menu-bar icons,
            // forever, with no self-correction -- and the 3s re-election timer
            // re-armed that race continuously.
            //
            // So compare the descriptor we just locked against the path it was
            // supposed to be: same device AND same inode, or this lock is
            // meaningless. Only the retry path needs it (at t=0 there is no
            // incumbent to duplicate, and failing there would leave nobody with
            // a menu).
            if verifyInode {
                let comparison = compare(fd, toPath: lockURL.path)
                let fdOK = comparison.fdOK
                let pathOK = comparison.pathOK
                let fdInfo = comparison.fdInfo
                let pathInfo = comparison.pathInfo

                if !comparison.matches {
                    // Deliberately leaves `lockFileDescriptor` at -1: this
                    // process did NOT become the lock holder, so a later
                    // `retryAcquire()` must go through the whole probe again
                    // rather than short-circuiting on a held descriptor.
                    close(fd)
                    if logContention {
                        log("InstanceLock: won an flock at \(lockURL.path) but the locked descriptor is NOT the file at that path any more (fstat ok=\(fdOK) dev/ino \(fdInfo.st_dev)/\(fdInfo.st_ino) vs stat ok=\(pathOK) dev/ino \(pathInfo.st_dev)/\(pathInfo.st_ino)) -- the lock file was deleted or replaced, so this win proves nothing about the incumbent primary, which may still be alive and owning the status item. Declining the promotion and continuing to poll.", level: "WARN")
                    } else {
                        logRetryAnomalyOnce(
                            key: "retry-inode-mismatch",
                            message: "InstanceLock: a retry locked a descriptor that no longer matches \(lockURL.path). Declining promotion; repeats are suppressed until the outcome changes."
                        )
                    }
                    return .secondary
                }
            }

            // Primary instance. Hold the descriptor open for the process
            // lifetime -- see comment on lockFileDescriptor above.
            lockFileDescriptor = fd
            log("InstanceLock: acquired primary instance lock at \(lockURL.path) (fd \(fd)).", level: "INFO")
            return .primary
        }

        // Capture errno on the very next line, before any other call
        // (including Logger/Foundation work) can clobber it -- `errno` is
        // the real C global, not a Swift-managed value, so anything run
        // between the failing flock() call and reading it here could
        // silently overwrite it with an unrelated value.
        let err = errno
        if err == EWOULDBLOCK {
            // EAGAIN == EWOULDBLOCK on Darwin. Genuine contention: another
            // live process already holds the lock, so this one is secondary.
            // Closing the probe descriptor is what makes repeated
            // `retryAcquire()` polling safe: without it every retry would
            // leak an fd until the process hit its descriptor limit.
            close(fd)
            if logContention {
                log("InstanceLock: lock at \(lockURL.path) already held by another process; this process is secondary.", level: "INFO")
            } else {
                clearRetryAnomaly()
            }
            return .secondary
        } else {
            // Any other errno (e.g. ENOLCK, EBADF, ...) means the locking
            // mechanism itself failed for a reason unrelated to contention --
            // NOT that another instance holds the lock.
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
            //     day to trip over a transient EMFILE/EINTR/ENOLCK.
            close(fd)
            if logContention {
                log("InstanceLock: flock() failed at \(lockURL.path) with unexpected errno \(err) (\(String(cString: strerror(err)))); \(failureWording).", level: "WARN")
            } else {
                logRetryAnomalyOnce(
                    key: "retry-flock-\(err)",
                    message: "InstanceLock: retry flock() failed at \(lockURL.path) with unexpected errno \(err) (\(String(cString: strerror(err)))); staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }
    }
}
