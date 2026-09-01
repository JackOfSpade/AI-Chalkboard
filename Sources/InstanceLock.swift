import Foundation

// `InstanceLock` is the platform-neutral election policy in
// `InstanceLockPolicy` (see that file for the full design and doc comments
// that apply identically on both platforms), specialized over the primitive
// this file defines for each OS. Only the primitive -- opening/validating
// the lock file, taking a non-blocking exclusive lock, and reading a
// comparable file identity -- differs by platform; see `FileLockPrimitive`
// in Sources/Support/FileLockPrimitive.swift for exactly what that primitive
// covers.

#if os(macOS)
import Darwin

/// `FileLockPrimitive` conformance backed by POSIX `flock`/file descriptors.
///
/// This Windows-vs-macOS pair implements the IDENTICAL election policy (see
/// `InstanceLockPolicy`) over two real semantic differences in what the
/// underlying primitive guarantees. Both are documented on the Windows
/// conformance (`Win32FileLockPrimitive`) below, since macOS's `flock` is the
/// less restrictive, "reference" behavior the policy was originally written
/// against:
///
/// (a) `flock()` is ADVISORY: a process that never calls `flock` on the lock
///     path can read/write/delete it freely, and only a fellow *participant*
///     in this election ever observes contention.
/// (b) `(st_dev, st_ino)` is a hard kernel guarantee for a live file: two
///     `stat`/`fstat` calls on the same underlying file always agree, with
///     no "eventually consistent" caveat.
public enum PosixFileLockPrimitive: FileLockPrimitive {
    public typealias Handle = Int32

    /// `(st_dev, st_ino)`: the standard POSIX identity for a live file,
    /// stable across any number of opens/closes/stats of the same inode.
    public struct Identity: Equatable, CustomStringConvertible {
        let dev: dev_t
        let ino: ino_t
        public var description: String { "dev/ino \(dev)/\(ino)" }
    }

    /// Opens only a path-owned regular file for the advisory lock.
    ///
    /// The lock is an election primitive, not a general file lock. Following
    /// a symlink could silently lock an unrelated file and leave the actual
    /// lock path undiscoverable to other instances. FIFOs and devices are
    /// likewise invalid election targets, so reject them before `flock`.
    public static func openLockFile(at path: String, createIfMissing: Bool) -> LockOpenOutcome<Int32> {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
        let fd = open(path, flags, 0o644)
        guard fd >= 0 else {
            // Capture errno immediately: any Foundation call can clobber it.
            let err = errno
            if !createIfMissing && err == ENOENT {
                return .notFound
            }
            return .failed(posixErrorDescription(err))
        }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            // Deliberately reports EINVAL here even when fstat() itself is
            // what failed (rather than the regular-file check) -- this is a
            // literal extraction of the pre-refactor macOS behavior
            // (`errno = EINVAL` was unconditional in this guard's else
            // branch), preserved as-is rather than "improved" during the
            // hoist. See this file's top-level comment.
            close(fd)
            return .failed(posixErrorDescription(EINVAL))
        }
        return .opened(fd)
    }

    /// Non-blocking exclusive advisory lock: returns immediately with
    /// EWOULDBLOCK if another live process already holds it, rather than
    /// hanging this process waiting for it.
    public static func tryLock(_ handle: Int32) -> LockAttempt {
        let result = flock(handle, LOCK_EX | LOCK_NB)
        if result == 0 { return .acquired }

        // Capture errno on the very next line, before any other call
        // (including Logger/Foundation work) can clobber it -- `errno` is
        // the real C global, not a Swift-managed value, so anything run
        // between the failing flock() call and reading it here could
        // silently overwrite it with an unrelated value.
        let err = errno
        // EAGAIN == EWOULDBLOCK on Darwin. Genuine contention: another live
        // process already holds the lock.
        if err == EWOULDBLOCK { return .contended }
        return .failed(posixErrorDescription(err))
    }

    /// Closing the descriptor releases the `flock` held on it -- `flock` is
    /// scoped to the open file DESCRIPTION (the kernel object `open()`
    /// creates), and closing the last reference to that description is what
    /// releases the lock. No separate unlock call is needed or exists.
    public static func releaseAndClose(_ handle: Int32) {
        close(handle)
    }

    public static func identity(ofOpenHandle handle: Int32) -> HandleIdentityLookup<Identity> {
        var info = stat()
        guard fstat(handle, &info) == 0 else {
            return .error(posixErrorDescription(errno))
        }
        return .found(Identity(dev: info.st_dev, ino: info.st_ino))
    }

    public static func identity(atPath path: String) -> PathIdentityLookup<Identity> {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let err = errno
            return err == ENOENT ? .missing : .error(posixErrorDescription(err))
        }
        return .found(Identity(dev: info.st_dev, ino: info.st_ino))
    }

    public static func resolveDefaultLockDirectory() -> LockDirectoryResolution {
        let fileManager = FileManager.default
        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .failure("could not resolve Application Support directory")
        }

        let appDir = supportDir.appendingPathComponent("AIChalkboard", isDirectory: true)
        do {
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            return .failure("failed to create lock directory at \(appDir.path): \(error.localizedDescription)")
        }
        return .success(appDir)
    }

    public static func testLockURLFromEnvironment() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["AI_CHALKBOARD_INSTANCE_LOCK_PATH"],
              raw.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let parent = candidate.deletingLastPathComponent().standardizedFileURL.path
        guard candidate.lastPathComponent == "instance.lock",
              parent == temporaryRoot || parent.hasPrefix(temporaryRoot + "/") else { return nil }
        return candidate
    }

    private static func posixErrorDescription(_ err: Int32) -> String {
        "errno \(err) \(String(cString: strerror(err)))"
    }
}

/// Advisory single-instance guard. See `InstanceLockPolicy` for the shared
/// election policy this specializes, and `PosixFileLockPrimitive` for the
/// POSIX `flock`/file-descriptor mechanism it runs over on macOS.
///
/// A concrete subclass rather than a `typealias`: `InstanceLockPolicy` is
/// generic, and `shared` needs a genuine stored singleton, which this
/// Swift toolchain does not support inside a generic type (see
/// `InstanceLockPolicy`'s header comment). Declares no initializer of its
/// own, so it automatically inherits both of `InstanceLockPolicy`'s
/// designated initializers unchanged.
/// `@unchecked Sendable` is restated here for the SAME reason, and with the
/// same justification, as the Windows `InstanceLock` further down this file --
/// see that declaration's comment, which deliberately documents BOTH platforms'
/// call sites rather than just its own. Swift treats `@unchecked` as a
/// per-declaration audit marker that does not propagate from
/// `InstanceLockPolicy` down to a subclass, so each concrete class must restate
/// it.
///
/// Restated on this macOS class too even though the warning that prompted it
/// was only observable on a Windows build (this branch never compiles there):
/// the soundness argument is symmetric -- every mutating entry point runs on
/// the AppKit main thread, via `applicationDidFinishLaunching` and
/// `AppLifecycleCoordinator`'s `RunLoop.main` timers -- so leaving it off would
/// just defer an identical warning to whoever next builds on a Mac.
public final class InstanceLock: InstanceLockPolicy<PosixFileLockPrimitive>, @unchecked Sendable {
    public static let shared = InstanceLock()
}

#elseif os(Windows)
import WinSDK

/// `FileLockPrimitive` conformance backed by Win32 `LockFileEx`/`HANDLE`.
///
/// Implements the IDENTICAL election policy as the macOS conformance (see
/// `InstanceLockPolicy` for the shared rationale: idempotent caching in
/// `acquire()`, the fail-open-at-t=0 vs fail-closed-on-retry split, the
/// four-poll grace window before a secondary recreates a missing lock file,
/// and the self-healing repair in `revalidatePrimaryLock()`). Only the
/// low-level mechanism differs -- `LockFileEx`/`HANDLE` in place of
/// `flock`/file descriptor -- and this header documents exactly the two
/// places where that substitution changes an observable guarantee. Both are
/// acceptable weakenings, and each is shaped so it can only fail toward
/// "re-elect a primary", never toward "two primaries":
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
/// (b) FILE IDENTITY IS BEST-EFFORT, NOT GUARANTEED. Several checks in
///     `InstanceLockPolicy` need to prove "the handle I just locked is still
///     the file this path names" (POSIX does this with `st_dev`/`st_ino`, a
///     hard kernel guarantee for a live file). The closest Windows analogue
///     -- `GetFileInformationByHandle`'s
///     (dwVolumeSerialNumber, nFileIndexHigh, nFileIndexLow) -- is
///     documented by Microsoft as NOT guaranteed stable across a close and
///     reopen on every filesystem (some remote and FAT-family volumes can
///     hand back a different file index for what is, on disk, the same
///     file). Every identity check built on this conformance's `Identity` is
///     deliberately shaped so the only possible consequence of that
///     instability is an unnecessary "looks replaced" verdict -- a harmless
///     extra close+reopen (primary side) or an extra declined promotion
///     followed by a retry (secondary side) -- and NEVER the unsafe
///     direction of two different underlying files being mistaken for one
///     and treated as proof of a single, legitimate incumbent.
public enum Win32FileLockPrimitive: FileLockPrimitive {
    public typealias Handle = HANDLE

    /// The Windows analogue of a POSIX (st_dev, st_ino) pair: what
    /// `GetFileInformationByHandle` reports about the file a HANDLE refers
    /// to. See this file's header comment, point (b), for the one honest gap
    /// against a POSIX inode.
    public struct Identity: Equatable, CustomStringConvertible {
        let volumeSerialNumber: DWORD
        let fileIndexHigh: DWORD
        let fileIndexLow: DWORD
        public var description: String { "volume \(volumeSerialNumber) file index \(fileIndexHigh):\(fileIndexLow)" }
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
    public static func identity(atPath path: String) -> PathIdentityLookup<Identity> {
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
            return .error(win32ErrorDescription(err))
        }
        defer { CloseHandle(handle) }
        switch identity(ofOpenHandle: handle) {
        case .found(let identity): return .found(identity)
        case .error(let description): return .error(description)
        }
    }

    public static func identity(ofOpenHandle handle: HANDLE) -> HandleIdentityLookup<Identity> {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else {
            return .error(win32ErrorDescription(GetLastError()))
        }
        return .found(Identity(
            volumeSerialNumber: info.dwVolumeSerialNumber,
            fileIndexHigh: info.nFileIndexHigh,
            fileIndexLow: info.nFileIndexLow
        ))
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
    /// of the macOS conformance's `O_NOFOLLOW`: rather than transparently
    /// following a reparse point to its target the way a plain `CreateFileW`
    /// call would, this atomically opens the reparse point itself as a
    /// handle, so its attributes can be inspected and rejected BEFORE
    /// anything is locked -- there is no window where a symlink swapped in
    /// between a check and an open could redirect this to an unrelated file.
    /// When the target is an ordinary file (the overwhelmingly common case),
    /// this flag has no effect and the returned handle is the real file,
    /// ready to use directly.
    public static func openLockFile(at path: String, createIfMissing: Bool) -> LockOpenOutcome<HANDLE> {
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
        guard handle != INVALID_HANDLE_VALUE else {
            let err = GetLastError()
            if !createIfMissing && (err == DWORD(ERROR_FILE_NOT_FOUND) || err == DWORD(ERROR_PATH_NOT_FOUND)) {
                return .notFound
            }
            return .failed(win32ErrorDescription(err))
        }

        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else {
            let err = GetLastError()
            CloseHandle(handle)
            return .failed(win32ErrorDescription(err))
        }

        let attrs = info.dwFileAttributes
        guard attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
              GetFileType(handle) == DWORD(FILE_TYPE_DISK) else {
            CloseHandle(handle)
            return .failed(win32ErrorDescription(DWORD(ERROR_INVALID_PARAMETER)))
        }
        return .opened(handle)
    }

    /// Non-blocking exclusive lock over the whole file's byte range:
    /// LOCKFILE_FAIL_IMMEDIATELY returns immediately with
    /// ERROR_LOCK_VIOLATION if another live process already holds it, rather
    /// than hanging this process waiting for it -- the Windows analogue of
    /// `flock(LOCK_EX | LOCK_NB)` on the macOS conformance.
    public static func tryLock(_ handle: HANDLE) -> LockAttempt {
        var overlapped = OVERLAPPED()
        let locked = LockFileEx(
            handle,
            DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
            0,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            &overlapped
        )
        if locked { return .acquired }

        // Capture the Win32 error on the very next line, before any other
        // call (including Logger/Foundation work) can clobber it -- the same
        // discipline the macOS conformance applies to `errno`.
        let err = GetLastError()
        if err == DWORD(ERROR_LOCK_VIOLATION) { return .contended }
        return .failed(win32ErrorDescription(err))
    }

    /// Releases a HANDLE this process holds an exclusive lock on: an
    /// explicit `UnlockFileEx` followed by `CloseHandle`. `CloseHandle`
    /// alone would already release any lock the handle holds (Win32
    /// releases byte-range locks when the last handle referencing them
    /// closes, or the process exits, mirroring `flock`'s
    /// open-file-description scoping closely enough for this design), but
    /// the explicit unlock makes the release point visible at every call
    /// site rather than implicit in a close.
    public static func releaseAndClose(_ handle: HANDLE) {
        var overlapped = OVERLAPPED()
        UnlockFileEx(handle, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped)
        CloseHandle(handle)
    }

    public static func resolveDefaultLockDirectory() -> LockDirectoryResolution {
        let fileManager = FileManager.default
        let appDir = PlatformPaths.applicationSupportDirectory
        do {
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            return .failure("failed to create lock directory at \(appDir.path): \(error.localizedDescription)")
        }
        return .success(appDir)
    }

    /// Windows equivalent of the macOS conformance's `raw.hasPrefix("/")`
    /// check: is `raw` an absolute Windows path (a drive-letter path such as
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

    public static func testLockURLFromEnvironment() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["AI_CHALKBOARD_INSTANCE_LOCK_PATH"],
              isAbsoluteWindowsPath(raw) else { return nil }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let parent = candidate.deletingLastPathComponent().standardizedFileURL.path
        // Windows paths are case-insensitive on the filesystem, unlike the
        // POSIX comparison on the macOS conformance.
        guard candidate.lastPathComponent.caseInsensitiveCompare("instance.lock") == .orderedSame,
              parent.caseInsensitiveCompare(temporaryRoot) == .orderedSame
                || parent.lowercased().hasPrefix(temporaryRoot.lowercased() + "\\")
                || parent.lowercased().hasPrefix(temporaryRoot.lowercased() + "/") else { return nil }
        return candidate
    }

    private static func win32ErrorDescription(_ err: DWORD) -> String {
        "Win32 error \(err)"
    }
}

/// Advisory* single-instance guard. See `InstanceLockPolicy` for the shared
/// election policy this specializes, and `Win32FileLockPrimitive`'s header
/// comment for the two honest semantic differences from the macOS
/// conformance (mandatory vs advisory locking, and best-effort file
/// identity).
///
/// A concrete subclass rather than a `typealias`: `InstanceLockPolicy` is
/// generic, and `shared` needs a genuine stored singleton, which this
/// Swift toolchain does not support inside a generic type (see
/// `InstanceLockPolicy`'s header comment). Declares no initializer of its
/// own, so it automatically inherits both of `InstanceLockPolicy`'s
/// designated initializers unchanged.
// Swift requires an `@unchecked Sendable` conformance to be restated on
// every subclass, even though `InstanceLockPolicy` already declares it --
// unlike an ordinary protocol, `@unchecked` is a per-declaration audit
// marker, not something that silently propagates down a class hierarchy.
// Restating it here (rather than silencing the warning some other way) is
// the correct call: it is TRUE, for the same reason `InstanceLockPolicy`
// documents it as sound for itself, and for one further reason specific to
// this concrete subclass.
//
// This class's whole mutable state (`lockFileHandle`, `acquired`,
// `consecutiveMissingLockFilePolls`, `lastRetryAnomaly`, all declared on
// `InstanceLockPolicy`) is genuinely unsynchronized -- there is no lock, no
// `os_unfair_lock`/`SRWLOCK`, no actor isolation anywhere in this type or its
// superclass. `@unchecked Sendable` is sound here NOT because concurrent
// access is safe, but because it never happens: every mutating entry point
// (`acquire()`, `retryAcquire()`, `revalidatePrimaryLock()`) is called only
// from this process's single UI/message-loop thread, by construction:
//   * macOS: `AppDelegate.applicationDidFinishLaunching` calls `acquire()`
//     directly (main thread), and `retryAcquire()`/`revalidatePrimaryLock()`
//     run only from `AppLifecycleCoordinator`'s repeating timers, which
//     `AppDelegate.scheduleRepeatingCallback` arms via `Timer` on
//     `RunLoop.main`.
//   * Windows: `AppDelegate.launch()` calls `acquire()` directly, on the
//     thread it captures as `Self.mainThreadId` at the top of that same
//     method, and `retryAcquire()`/`revalidatePrimaryLock()` again run only
//     from `AppLifecycleCoordinator`'s timers, which
//     `AppDelegate.scheduleRepeatingCallback` arms via `SetTimer`/`WM_TIMER`
//     on that identical thread.
// `InstanceLock.shared`'s lazy `static let` initialization itself is
// separately thread-safe (Swift guarantees a `static let` initializer runs
// exactly once even under concurrent first access), so the ONLY way this
// type's mutable state could actually race is if some future call site
// invoked `acquire()`/`retryAcquire()`/`revalidatePrimaryLock()` off that one
// thread -- at which point this conformance would stop being sound and
// would need to gain real synchronization (or move to an actor), not just
// keep this comment. If you are adding such a call site, stop and add a lock
// first.
public final class InstanceLock: InstanceLockPolicy<Win32FileLockPrimitive>, @unchecked Sendable {
    public static let shared = InstanceLock()
}
#endif
