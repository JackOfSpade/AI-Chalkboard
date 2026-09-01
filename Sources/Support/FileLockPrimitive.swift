import Foundation

/// The platform-specific mechanism `InstanceLockPolicy` elects a primary
/// instance over.
///
/// This protocol captures ONLY the primitive: opening a lock file safely
/// (rejecting a symlink/reparse-point target and anything that is not an
/// ordinary regular disk file), taking a non-blocking exclusive lock,
/// releasing it, and reading a comparable identity for an open handle or for
/// whatever currently sits at a path. `InstanceLockPolicy` is written
/// entirely against this protocol -- plus `Foundation` -- and never imports
/// Darwin, WinSDK, or any other platform framework. This is the same split
/// `DrawingContext`/`AnnotationRenderer` use for rendering: a small
/// platform-neutral protocol underneath a much larger shared policy.
///
/// Every conformance lives in its own `#if os(...)`-gated file (see
/// `InstanceLock.swift`), because every method here is one that legitimately
/// differs by platform: `flock`/file descriptors on macOS, `LockFileEx`/
/// `HANDLE` on Windows.
public protocol FileLockPrimitive {
    /// An opaque, platform-native reference to an open lock file. `Int32` (a
    /// POSIX file descriptor) on macOS, `HANDLE` on Windows.
    associatedtype Handle

    /// A comparable identity for whatever file a `Handle` or a path
    /// currently refers to -- `(st_dev, st_ino)` on macOS,
    /// `(dwVolumeSerialNumber, nFileIndexHigh, nFileIndexLow)` on Windows.
    /// Two identities being equal is this primitive's answer to "is this the
    /// same underlying file", used to detect the lock path being deleted and
    /// replaced out from under a live holder.
    ///
    /// `CustomStringConvertible` is REQUIRED, not a convenience: the identity
    /// values are what make the "won a lock but the handle is no longer the
    /// file at that path" diagnostic actionable. That message is rare and
    /// fires exactly when the election is behaving strangely, so whoever reads
    /// it needs the two concrete identities that failed to match, not just the
    /// news that they differed. The shared policy cannot format them itself
    /// without naming a platform type, so each conformance renders its own
    /// (`dev/ino 16777232/1234`, `volume 3735928559 file index 0:5678`).
    associatedtype Identity: Equatable & CustomStringConvertible

    /// Opens the lock file at `path` for exclusive-locking use, REJECTING a
    /// symlink/reparse-point target and anything that is not an ordinary
    /// regular disk file before it can influence the election. This is the
    /// lock-acquisition open -- distinct from `identity(atPath:)`, which
    /// reads identity without needing (or granting) any access rights and
    /// therefore may follow a symlink/reparse point the way a plain `stat`
    /// would, since it never risks locking through one.
    static func openLockFile(at path: String, createIfMissing: Bool) -> LockOpenOutcome<Handle>

    /// Attempts to take an exclusive lock on `handle` without blocking.
    static func tryLock(_ handle: Handle) -> LockAttempt

    /// Releases whatever lock `handle` holds and closes it. Never called on
    /// a handle this primitive did not hand back from `openLockFile`.
    static func releaseAndClose(_ handle: Handle)

    /// The identity of the file `handle` currently refers to. Distinct from
    /// `identity(atPath:)`: this asks about the open file OBJECT, not
    /// whatever a path currently names -- the whole reason the two can
    /// diverge (and therefore the reason this method and `identity(atPath:)`
    /// both exist) is that the lock this file elects over is scoped to that
    /// open object, not to the path used to reach it.
    static func identity(ofOpenHandle handle: Handle) -> HandleIdentityLookup<Identity>

    /// The identity of whatever file currently sits at `path`, without
    /// opening it for locking. Three-way on purpose: `InstanceLockPolicy`'s
    /// state machine genuinely distinguishes "some file is there" from "the
    /// path is empty" (expected after the lock file is deleted; not evidence
    /// the primary is gone) from "the lookup itself failed" (inconclusive;
    /// never treated as either of the other two).
    static func identity(atPath path: String) -> PathIdentityLookup<Identity>

    /// Resolves (creating if necessary) the directory production lock files
    /// live in. Platform-specific because macOS and Windows resolve their
    /// per-app data directory through different `FileManager` search paths
    /// and different failure handling; see each conformance.
    static func resolveDefaultLockDirectory() -> LockDirectoryResolution

    /// Parses the `AI_CHALKBOARD_INSTANCE_LOCK_PATH` test-override
    /// environment variable into a URL, or `nil` if it is absent or does not
    /// pass this platform's safety check restricting it to an ordinary file
    /// beneath the process' own temporary directory. Platform-specific
    /// because "is this an absolute path" and path-component comparison mean
    /// different things on POSIX versus Windows (drive letters/UNC paths,
    /// case-insensitivity).
    static func testLockURLFromEnvironment() -> URL?
}

/// What opening the lock file at a path concluded.
public enum LockOpenOutcome<Handle> {
    /// The file was opened (and validated as an ordinary regular file not
    /// reached through a symlink/reparse point).
    case opened(Handle)
    /// No file exists at the path AND the caller did not permit creating
    /// one. Distinct from a general failure because the caller's policy, not
    /// this primitive, decides what a missing lock file means.
    case notFound
    /// Opening or validating failed for any other reason. Carries an
    /// already-formatted, platform-native description (`"errno 13 ..."` /
    /// `"Win32 error 5"`) so `InstanceLockPolicy` never has to know whether
    /// it is looking at an `errno` or a `DWORD`.
    case failed(String)
}

/// What a non-blocking exclusive-lock attempt concluded.
public enum LockAttempt {
    /// This handle now holds the exclusive lock.
    case acquired
    /// Another live holder already has it -- genuine contention, not an
    /// error.
    case contended
    /// The locking call itself failed for a reason unrelated to contention.
    /// Carries an already-formatted, platform-native description; see
    /// `LockOpenOutcome.failed`.
    case failed(String)
}

/// The result of asking a primitive for the identity of an OPEN handle.
public enum HandleIdentityLookup<Identity: Equatable & CustomStringConvertible> {
    case found(Identity)
    /// Inspecting the handle failed. Carries an already-formatted,
    /// platform-native description; see `LockOpenOutcome.failed`. Every
    /// caller of this method treats `.error` exactly like a non-match --
    /// see `FileLockPrimitive`'s doc comment on identity being best-effort.
    case error(String)
}

/// The result of asking a primitive for the identity of whatever currently
/// sits at a PATH. See `FileLockPrimitive.identity(atPath:)` for why this is
/// three-way rather than a plain optional.
public enum PathIdentityLookup<Identity: Equatable & CustomStringConvertible> {
    case found(Identity)
    case missing
    case error(String)
}

/// The result of resolving (and creating) the directory production lock
/// files live in.
public enum LockDirectoryResolution {
    case success(URL)
    /// Carries an already-formatted, human-readable reason (never a raw
    /// error code -- this one is read directly into a log line by
    /// `InstanceLockPolicy`, not compared against anything).
    case failure(String)
}
