import Foundation

#if os(macOS)
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

#elseif os(Windows)
import WinSDK

/// Advisory* single-instance guard used to prevent duplicate status-bar items.
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
///
/// This Windows branch implements the IDENTICAL public API and the same
/// design as the `#if os(macOS)` branch above (see its doc comments for the
/// shared rationale: idempotent caching in `acquire()`, the fail-open-at-t=0
/// vs fail-closed-on-retry split, the four-poll grace window before a
/// secondary recreates a missing lock file, and the self-healing repair in
/// `revalidatePrimaryLock()`). Only the low-level mechanism differs --
/// `LockFileEx`/`HANDLE` in place of `flock`/file descriptor -- and this
/// header documents exactly the two places where that substitution changes
/// an observable guarantee. Both are acceptable weakenings, and each is
/// shaped so it can only fail toward "re-elect a primary", never toward "two
/// primaries":
///
/// (a) MANDATORY vs ADVISORY LOCKING. POSIX `flock()` is advisory: a process
///     that never calls `flock` on the lock path can read/write/delete it
///     freely, and only a fellow *participant* in this election ever
///     observes contention. Win32's `LockFileEx` is MANDATORY: the OS
///     enforces the locked byte range against ANY process attempting a
///     conflicting access, participant or not. A non-participating process
///     (antivirus, a backup tool, a user poking at the file in an editor)
///     that tries to open the lock file for conflicting access while a
///     primary holds it gets a hard I/O error on Windows where it would have
///     silently succeeded on macOS. This is strictly MORE restrictive than
///     the POSIX contract, not less, so it never weakens the single-primary
///     guarantee itself.
///
/// (b) FILE IDENTITY IS BEST-EFFORT, NOT GUARANTEED. Several checks below
///     need to prove "the handle I just locked is still the file this path
///     names" (POSIX does this with `st_dev`/`st_ino`, a hard kernel
///     guarantee for a live file). The closest Windows analogue --
///     `GetFileInformationByHandle`'s
///     (dwVolumeSerialNumber, nFileIndexHigh, nFileIndexLow) -- is
///     documented by Microsoft as NOT guaranteed stable across a close and
///     reopen on every filesystem (some remote and FAT-family volumes can
///     hand back a different file index for what is, on disk, the same
///     file). Every identity check in this file is deliberately shaped so
///     the only possible consequence of that instability is an unnecessary
///     "looks replaced" verdict -- a harmless extra close+reopen (primary
///     side) or an extra declined promotion followed by a retry (secondary
///     side) -- and NEVER the unsafe direction of two different underlying
///     files being mistaken for one and treated as proof of a single,
///     legitimate incumbent.
public final class InstanceLock: @unchecked Sendable {
    public static let shared = InstanceLock()

    /// Test-only path override. Production resolves the user's Application
    /// Support path; isolated tests use a unique temporary file and therefore
    /// never contend with or mutate the live app's lock.
    private let lockURLOverride: URL?
    private let logHandler: (String, String) -> Void

    /// Kept open for the lifetime of the process. Closing this HANDLE (or
    /// letting it be deallocated) releases the Win32 byte-range lock, so it
    /// is intentionally never closed once acquired. Stored as `HANDLE?`
    /// (unlike the raw, non-optional `HANDLE` this toolchain's WinSDK
    /// overlay uses for Win32 APIs, which signal failure via the
    /// `INVALID_HANDLE_VALUE` sentinel rather than `nil`): `nil` here means
    /// "not held", the same role `-1` plays for the POSIX descriptor on the
    /// macOS branch.
    private var lockFileHandle: HANDLE?

    /// Cached outcome of the first `acquire()` call, so subsequent calls are
    /// idempotent. See the macOS branch's identical field for why an
    /// uncached second call would self-contend and lie about the outcome --
    /// the same reasoning applies here with `LockFileEx` in place of
    /// `flock`: this process's own second HANDLE opened on the same path
    /// would report `ERROR_LOCK_VIOLATION` against the lock this very
    /// process already holds via the first HANDLE.
    private var acquired: Bool?

    /// How many consecutive retry polls have found NO lock file at all.
    /// See `missingLockFilePollsBeforeRecreate`.
    private var consecutiveMissingLockFilePolls = 0

    /// Last retry-only anomaly written to the log. Retry acquisition runs every
    /// three seconds and Logger has no level filtering, so an unresolved error
    /// is logged once per episode rather than once per poll.
    private var lastRetryAnomaly: String?

    /// How long a secondary tolerates a missing lock file before recreating it
    /// and promoting itself, expressed in retry polls. See the macOS branch's
    /// identical constant for the full race-resolution rationale (unchanged
    /// on Windows -- this is a design choice about polling cadence, not a
    /// platform-specific one): a live primary repairs a deleted lock file
    /// within about one poll via `revalidatePrimaryLock()`, and refusing
    /// forever if no primary is alive would strand this process with no
    /// status item, no Dock-equivalent affordance, and no window.
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
    /// primary with no held handle must retain its UI, while only a proven
    /// owner of the repaired path should make this process relinquish it.
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
        if let handle = lockFileHandle {
            releaseLock(handle)
        }
    }

    /// Releases a HANDLE this process holds an exclusive lock on: an explicit
    /// `UnlockFileEx` followed by `CloseHandle`. `CloseHandle` alone would
    /// already release any lock the handle holds (Win32 releases byte-range
    /// locks when the last handle referencing them closes, or the process
    /// exits, mirroring `flock`'s open-file-description scoping closely
    /// enough for this design), but the explicit unlock makes the release
    /// point visible at every call site rather than implicit in a close.
    private func releaseLock(_ handle: HANDLE) {
        var overlapped = OVERLAPPED()
        UnlockFileEx(handle, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped)
        CloseHandle(handle)
    }

    /// Attempts to become the primary instance.
    ///
    /// Returns `true` if this process should behave as primary -- either
    /// because it genuinely acquired the exclusive lock, or because
    /// something went wrong creating/opening/locking the lock file. Failures
    /// fail OPEN (return true): a broken lock file must never disable the
    /// app's UI for every instance.
    ///
    /// Same fail-open-only-at-t=0 policy as the macOS branch's `acquire()`;
    /// see its doc comment for the full rationale, which does not change on
    /// Windows.
    ///
    /// Idempotent: safe to call more than once; subsequent calls return the
    /// cached outcome of the first call without touching the filesystem or
    /// the lock again (see the `acquired` doc comment for why that matters).
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
    /// Same design as the macOS branch's `retryAcquire()` -- see its doc
    /// comment for the complete rationale (why this exists alongside a
    /// cached `acquire()`, why it never records a negative result, why it
    /// fails CLOSED unlike `acquire()`, and why it only creates the lock
    /// file after `missingLockFilePollsBeforeRecreate` consecutive misses).
    /// None of that reasoning is platform-specific. What differs
    /// mechanically on Windows:
    /// * "VALIDATES THE INODE" becomes "validates the file identity" via
    ///   `GetFileInformationByHandle` -- see this file's Windows header
    ///   comment, point (b).
    /// * No HANDLE leak: `performAcquire` closes the probe HANDLE on every
    ///   path that does not become the lock holder, so polling every few
    ///   seconds for hours cannot exhaust the process's handle table.
    ///
    /// Main-thread only (driven by AppDelegate's re-election timer); the
    /// state it touches is not synchronized.
    @discardableResult
    public func retryAcquire() -> Bool {
        // Already holding the lock -- from the original `acquire()` or from an
        // earlier winning retry. Return true WITHOUT touching the filesystem:
        // re-opening the path here would create a second HANDLE and
        // `LockFileEx` it against the one this very process already holds,
        // which reports ERROR_LOCK_VIOLATION and would make us self-demote.
        // See the `acquired` doc comment.
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

            log("InstanceLock: the lock file has been missing for \(Self.missingLockFilePollsBeforeRecreate) consecutive polls -- long enough that a live primary would have recreated it. Assuming no primary exists (deleted lock file plus an exited primary, or a wiped Application Support folder) and recreating it now, so this process is not left with no status item, no Dock icon and no window.", level: "INFO")

            if performAcquire(logContention: false, failOpen: false, verifyIdentity: true, createIfMissing: true) == .primary {
                acquired = true
                return true
            }
            return false
        }
    }

    /// Primary-only self-check, driven by the same 3s timer that secondaries use
    /// for re-election: is the HANDLE this process holds still the file that
    /// lives at the lock path? If not, RE-CREATE and re-lock the file.
    ///
    /// Same two-halves design as the macOS branch's `revalidatePrimaryLock()`
    /// -- see its doc comment for why a primary has to repair its own lock
    /// (a held lock follows the open file object, not the path, so deleting
    /// the path orphans the primary's lock and only the primary can restore
    /// the on-disk link a secondary needs to discover it). That reasoning is
    /// unchanged on Windows: a `HANDLE`, like a POSIX descriptor, follows the
    /// underlying file rather than the path string used to open it.
    ///
    /// No-ops in a process that is primary only because locking failed open
    /// (`lockFileHandle == nil`): there is no lock to validate, and
    /// re-testing could only produce a false alarm.
    @discardableResult
    public func revalidatePrimaryLock() -> RevalidationResult {
        // Initial acquisition deliberately fails open when locking itself is
        // unavailable. No held handle is not proof that somebody else owns
        // the role, so the only safe result is to keep the sole user-facing
        // UI.
        guard let currentHandle = lockFileHandle else { return .retainPrimary }

        guard let lockURL = resolveLockURL(failureWording: "cannot revalidate the primary lock this tick", logFailures: false) else {
            logRetryAnomalyOnce(
                key: "primary-resolve-lock-url",
                message: "InstanceLock: could not resolve or create the primary lock path. Retaining the primary role and suppressing repeats until the condition changes."
            )
            return .retainPrimary
        }

        guard let fdIdentity = Self.fileIdentity(ofOpenHandle: currentHandle) else {
            logRetryAnomalyOnce(
                key: "primary-handle-info",
                message: "InstanceLock: could not inspect the primary lock handle (Win32 error \(GetLastError())). Retaining the primary role because this does not prove another process owns it; will retry next tick."
            )
            return .retainPrimary
        }

        switch Self.lookupIdentity(atPath: lockURL.path) {
        case .found(let pathIdentity) where pathIdentity == fdIdentity:
            clearRetryAnomaly()
            return .retainPrimary

        case .found(_), .missing:
            // Path names a different file, or is gone entirely -- fall
            // through to the repair below. (`.missing` mirrors the macOS
            // branch's `pathErr == ENOENT` case: proceed to recreate.)
            break

        case .error(let err):
            logRetryAnomalyOnce(
                key: "primary-stat-\(err)",
                message: "InstanceLock: could not inspect the primary lock path at \(lockURL.path) (Win32 error \(err)). Retaining the primary role because this does not prove replacement; will retry next tick."
            )
            return .retainPrimary
        }

        guard let newHandle = openLockFile(at: lockURL.path, createIfMissing: true) else {
            let err = GetLastError()
            logRetryAnomalyOnce(
                key: "primary-repair-open-\(err)",
                message: "InstanceLock: could not recreate \(lockURL.path) (Win32 error \(err)). Retaining the existing primary role; will retry next tick."
            )
            return .retainPrimary
        }

        var overlapped = OVERLAPPED()
        guard LockFileEx(
            newHandle,
            DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
            0,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            &overlapped
        ) else {
            let err = GetLastError()
            let replacementIsPathVisible = Self.identity(newHandle, matchesPath: lockURL.path)
            CloseHandle(newHandle)

            if err == DWORD(ERROR_LOCK_VIOLATION) && replacementIsPathVisible {
                log("InstanceLock: another process holds the path-visible replacement at \(lockURL.path). Relinquishing this process's orphaned lock and primary role so there cannot be two permanent status-bar owners.", level: "WARN")
                releaseLock(currentHandle)
                lockFileHandle = nil
                acquired = false
                clearRetryAnomaly()
                return .relinquishToPathOwner
            }

            logRetryAnomalyOnce(
                key: "primary-repair-lock-\(err)-visible-\(replacementIsPathVisible)",
                message: "InstanceLock: could not lock the replacement at \(lockURL.path) (Win32 error \(err), path-visible=\(replacementIsPathVisible)). Retaining the existing primary role because this is not proof of a competing path owner; will retry next tick."
            )
            return .retainPrimary
        }

        // The path can be replaced between open() and LockFileEx(). Never
        // exchange one orphaned handle for another that secondaries cannot
        // discover.
        guard Self.identity(newHandle, matchesPath: lockURL.path) else {
            releaseLock(newHandle)
            logRetryAnomalyOnce(
                key: "primary-repair-identity-race",
                message: "InstanceLock: locked a replacement handle, but it no longer matches \(lockURL.path). Retaining the existing primary role and retrying next tick."
            )
            return .retainPrimary
        }

        // Release the orphan only after its discoverable replacement is held.
        releaseLock(currentHandle)
        lockFileHandle = newHandle
        clearRetryAnomaly()
        log("InstanceLock: primary lock repaired -- now holding \(lockURL.path).", level: "INFO")
        return .retainPrimary
    }

    /// The Windows analogue of a POSIX (st_dev, st_ino) pair: what
    /// `GetFileInformationByHandle` reports about the file a HANDLE refers
    /// to. See this file's Windows header comment, point (b), for the one
    /// honest gap against a POSIX inode.
    private struct FileIdentity: Equatable {
        let volumeSerialNumber: DWORD
        let fileIndexHigh: DWORD
        let fileIndexLow: DWORD
    }

    /// The three ways probing "what file currently sits at this path"
    /// (the Windows analogue of POSIX `stat(path)`) can come out. Distinct
    /// `.missing` and `.error` cases matter for the same reason
    /// `AcquireOutcome.lockFileMissing` is distinct from `.secondary` on the
    /// macOS branch: "the path is empty" and "something went wrong asking"
    /// call for different responses (proceed to repair vs. retain and
    /// retry).
    private enum PathIdentityLookup {
        case found(FileIdentity)
        case missing
        case error(DWORD)
    }

    private static func fileIdentity(ofOpenHandle handle: HANDLE) -> FileIdentity? {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        return FileIdentity(
            volumeSerialNumber: info.dwVolumeSerialNumber,
            fileIndexHigh: info.nFileIndexHigh,
            fileIndexLow: info.nFileIndexLow
        )
    }

    /// Opens a short-lived, attributes-only handle purely to identify
    /// whatever file currently sits at `path` -- the Windows analogue of
    /// POSIX `stat(path)`, which needs no open file descriptor at all.
    /// `dwDesiredAccess: 0` requests no read/write rights (a documented
    /// Win32 idiom for a metadata-only handle) and never contends with, or
    /// blocks, any other opener of the same path, including this process's
    /// own held lock. This probe deliberately does NOT pass
    /// `FILE_FLAG_OPEN_REPARSE_POINT`, so it follows a reparse point the
    /// same way plain POSIX `stat()` follows a symlink -- unlike
    /// `openLockFile(at:createIfMissing:)` below, which is the actual
    /// lock-acquisition open and must NOT follow one.
    private static func lookupIdentity(atPath path: String) -> PathIdentityLookup {
        let handle: HANDLE = path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(
                widePath,
                0,
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard handle != INVALID_HANDLE_VALUE else {
            let err = GetLastError()
            if err == DWORD(ERROR_FILE_NOT_FOUND) || err == DWORD(ERROR_PATH_NOT_FOUND) {
                return .missing
            }
            return .error(err)
        }
        defer { CloseHandle(handle) }
        guard let identity = fileIdentity(ofOpenHandle: handle) else {
            return .error(GetLastError())
        }
        return .found(identity)
    }

    /// Whether `handle`'s identity matches whatever currently sits at
    /// `path`. Any failure to determine either identity is treated as "no
    /// match" -- consistent with point (b) of this file's header comment:
    /// an inconclusive identity check must never be read as proof of a
    /// match.
    private static func identity(_ handle: HANDLE, matchesPath path: String) -> Bool {
        guard let handleIdentity = fileIdentity(ofOpenHandle: handle),
              case .found(let pathIdentity) = lookupIdentity(atPath: path) else { return false }
        return handleIdentity == pathIdentity
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

    /// Opens only a path-owned regular disk file for the advisory* lock.
    ///
    /// The lock is an election primitive, not a general file lock. Following
    /// a reparse point could silently lock an unrelated file and leave the
    /// actual lock path undiscoverable to other instances. Devices and
    /// directories are likewise invalid election targets, so reject them
    /// before `LockFileEx`.
    ///
    /// Opening with `FILE_FLAG_OPEN_REPARSE_POINT` is the Windows analogue
    /// of the macOS branch's `O_NOFOLLOW`: rather than transparently
    /// following a reparse point to its target the way a plain `CreateFileW`
    /// call would, this atomically opens the reparse point itself as a
    /// handle, so its attributes can be inspected and rejected BEFORE
    /// anything is locked -- there is no window where a symlink swapped in
    /// between a check and an open could redirect this to an unrelated file.
    /// When the target is an ordinary file (the overwhelmingly common case),
    /// this flag has no effect and the returned handle is the real file,
    /// ready to use directly.
    private func openLockFile(at path: String, createIfMissing: Bool) -> HANDLE? {
        let disposition: DWORD = createIfMissing ? DWORD(OPEN_ALWAYS) : DWORD(OPEN_EXISTING)
        let handle: HANDLE = path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(
                widePath,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                disposition,
                DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        guard handle != INVALID_HANDLE_VALUE else { return nil }

        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else {
            let err = GetLastError()
            CloseHandle(handle)
            SetLastError(err)
            return nil
        }

        let attrs = info.dwFileAttributes
        guard attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
              GetFileType(handle) == DWORD(FILE_TYPE_DISK) else {
            CloseHandle(handle)
            SetLastError(DWORD(ERROR_INVALID_PARAMETER))
            return nil
        }
        return handle
    }

    /// Windows equivalent of the macOS branch's `raw.hasPrefix("/")` check:
    /// is `raw` an absolute Windows path (a drive-letter path such as
    /// `C:\...` / `C:/...`, or a UNC path such as `\\server\share\...`)?
    /// This is intentionally a narrow, defense-in-depth guard restricting
    /// the test-only environment override to a path under the process' own
    /// temp directory -- not a general-purpose Windows path validator.
    private static func isAbsoluteWindowsPath(_ raw: String) -> Bool {
        if raw.hasPrefix("\\\\") { return true }
        let bytes = Array(raw.utf8)
        guard bytes.count >= 3 else { return false }
        let drive = bytes[0]
        let isLetter = (drive >= UInt8(ascii: "A") && drive <= UInt8(ascii: "Z"))
            || (drive >= UInt8(ascii: "a") && drive <= UInt8(ascii: "z"))
        return isLetter
            && bytes[1] == UInt8(ascii: ":")
            && (bytes[2] == UInt8(ascii: "\\") || bytes[2] == UInt8(ascii: "/"))
    }

    private static func testLockURLFromEnvironment() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["AI_CHALKBOARD_INSTANCE_LOCK_PATH"],
              isAbsoluteWindowsPath(raw) else { return nil }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let parent = candidate.deletingLastPathComponent().standardizedFileURL.path
        // Windows paths are case-insensitive on the filesystem, unlike the
        // POSIX comparison on the macOS branch.
        guard candidate.lastPathComponent.caseInsensitiveCompare("instance.lock") == .orderedSame,
              parent.caseInsensitiveCompare(temporaryRoot) == .orderedSame
                || parent.lowercased().hasPrefix(temporaryRoot.lowercased() + "\\")
                || parent.lowercased().hasPrefix(temporaryRoot.lowercased() + "/") else { return nil }
        return candidate
    }

    /// Resolves the lock file's URL, creating its directory if needed.
    /// `nil` (with a WARN naming `failureWording`) when that is not possible.
    private func resolveLockURL(failureWording: String, logFailures: Bool = true) -> URL? {
        if let lockURLOverride {
            return lockURLOverride
        }

        let fileManager = FileManager.default
        let appDir = PlatformPaths.applicationSupportDirectory

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
    ///     createDirectory error, CreateFileW error, non-ERROR_LOCK_VIOLATION
    ///     LockFileEx error) should return. `true` for the t=0 election -- if
    ///     locking is broken somebody has to own the UI. `false` for the
    ///     retry poll -- another instance is known to be primary already, so
    ///     an unrelated Win32 error must not promote this process into a
    ///     second menu-bar owner. Same policy as the macOS branch's
    ///     `failOpen`; see its doc comment for the full rationale.
    ///   - verifyIdentity: whether a WINNING lock must additionally prove
    ///     that the handle it locked is still the file at `lockURL`. The
    ///     Windows analogue of the macOS branch's `verifyInode`; see this
    ///     file's header comment, point (b).
    ///   - createIfMissing: whether a missing lock file may be CREATED. Same
    ///     policy and rationale as the macOS branch's `createIfMissing`.
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

        // `openLockFile` rejects a reparse point or non-regular-disk-file
        // before it can influence the election -- see its doc comment.
        guard let handle = openLockFile(at: lockURL.path, createIfMissing: createIfMissing) else {
            let err = GetLastError()
            if !createIfMissing && (err == DWORD(ERROR_FILE_NOT_FOUND) || err == DWORD(ERROR_PATH_NOT_FOUND)) {
                // Expected on the retry path when the lock file has been
                // deleted. NOT evidence that the primary died -- see
                // `createIfMissing` above. Do not log this recurring retry
                // condition: Logger intentionally has no level filtering.
                return .lockFileMissing
            }
            if logContention {
                log("InstanceLock: failed to open lock file at \(lockURL.path) (Win32 error \(err)); \(failureWording).", level: "WARN")
            } else {
                logRetryAnomalyOnce(
                    key: "retry-open-\(err)",
                    message: "InstanceLock: retry could not open \(lockURL.path) (Win32 error \(err)); staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }

        // Non-blocking exclusive lock over the whole file's byte range:
        // LOCKFILE_FAIL_IMMEDIATELY returns immediately with
        // ERROR_LOCK_VIOLATION if another live process already holds it,
        // rather than hanging this process waiting for it -- the Windows
        // analogue of flock(LOCK_EX | LOCK_NB) on the macOS branch.
        var overlapped = OVERLAPPED()
        let locked = LockFileEx(
            handle,
            DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
            0,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            &overlapped
        )

        if locked {
            // WINNING THE LOCK IS NOT ENOUGH ON A RETRY -- same race as the
            // macOS branch's identical comment on `performAcquire` describes,
            // with `LockFileEx`/HANDLE in place of `flock`/descriptor: a
            // HANDLE follows the open file object it was created from, not
            // the path string passed to `CreateFileW`. If instance.lock is
            // deleted or replaced while the real primary is running, this
            // open() creates a handle to a BRAND NEW, unlocked file that
            // nobody holds, the lock trivially succeeds, and this process
            // would promote itself while the live primary still holds its
            // lock on the now-unreachable original. So compare the handle we
            // just locked against whatever the path names right now -- same
            // volume AND same file index, or this lock is meaningless. Only
            // the retry path needs it (at t=0 there is no incumbent to
            // duplicate).
            if verifyIdentity {
                guard let fdIdentity = Self.fileIdentity(ofOpenHandle: handle),
                      case .found(let pathIdentity) = Self.lookupIdentity(atPath: lockURL.path),
                      fdIdentity == pathIdentity else {
                    // Deliberately leaves `lockFileHandle` at nil: this
                    // process did NOT become the lock holder, so a later
                    // `retryAcquire()` must go through the whole probe again
                    // rather than short-circuiting on a held handle.
                    releaseLock(handle)
                    if logContention {
                        log("InstanceLock: won a LockFileEx at \(lockURL.path) but the locked handle is NOT the file at that path any more -- the lock file was deleted or replaced, so this win proves nothing about the incumbent primary, which may still be alive and owning the status item. Declining the promotion and continuing to poll.", level: "WARN")
                    } else {
                        logRetryAnomalyOnce(
                            key: "retry-identity-mismatch",
                            message: "InstanceLock: a retry locked a handle that no longer matches \(lockURL.path). Declining promotion; repeats are suppressed until the outcome changes."
                        )
                    }
                    return .secondary
                }
            }

            // Primary instance. Hold the handle open for the process
            // lifetime -- see comment on lockFileHandle above.
            lockFileHandle = handle
            log("InstanceLock: acquired primary instance lock at \(lockURL.path).", level: "INFO")
            return .primary
        }

        // Capture the Win32 error on the very next line, before any other
        // call (including Logger/Foundation work) can clobber it -- the
        // same discipline the macOS branch applies to `errno`.
        let err = GetLastError()
        if err == DWORD(ERROR_LOCK_VIOLATION) {
            // Genuine contention: another live process already holds the
            // lock, so this one is secondary. Closing the probe handle is
            // what makes repeated `retryAcquire()` polling safe: without it
            // every retry would leak a handle until the process hit its
            // handle-table limit.
            CloseHandle(handle)
            if logContention {
                log("InstanceLock: lock at \(lockURL.path) already held by another process; this process is secondary.", level: "INFO")
            } else {
                clearRetryAnomaly()
            }
            return .secondary
        } else {
            // Any other Win32 error means the locking mechanism itself
            // failed for a reason unrelated to contention -- NOT that
            // another instance holds the lock. Which way to fail depends on
            // the caller (`failOpen`); see this method's doc comment and the
            // macOS branch's identical discussion of `failOpen`, which
            // applies unchanged here.
            CloseHandle(handle)
            if logContention {
                log("InstanceLock: LockFileEx() failed at \(lockURL.path) with unexpected Win32 error \(err); \(failureWording).", level: "WARN")
            } else {
                logRetryAnomalyOnce(
                    key: "retry-lock-\(err)",
                    message: "InstanceLock: retry LockFileEx() failed at \(lockURL.path) with unexpected Win32 error \(err); staying secondary. Repeats are suppressed until the outcome changes."
                )
            }
            return failureOutcome
        }
    }
}
#endif
