import Foundation
// Foundation re-exports Darwin on Apple platforms, which is where open(2),
// flock(2), fstat(2)/stat(2), openat(2)/fstatat(2)/renameat(2)/unlinkat(2),
// and close(2) come from below.
#if os(macOS)
import Darwin
#elseif os(Windows)
// Windows has no POSIX layer for Foundation to re-export, and no public
// directory-relative open (openat's Win32 analogue is an internal NT API,
// not one WinSDK exposes). The analogous file-identity, locking, ownership,
// and durability primitives used below (CreateFileW, LockFileEx/UnlockFileEx,
// GetFileInformationByHandle, GetSecurityInfo, OpenProcessToken /
// GetTokenInformation, MoveFileExW, FlushFileBuffers, CloseHandle,
// GetLastError) come from the plain-C Win32 surface that WinSDK exposes
// directly.
import WinSDK
#endif

// The hardened persistence layer for `SuspensionLeaseCoordinator`'s durable
// registry, split into a platform-neutral policy layer and a small
// per-platform primitive layer -- the same shape `AnnotationRenderer` /
// `DrawingContext` use in this directory. This file contains no lease
// business logic (the lease/generation/tombstone model and expiry
// reconciliation live in `SuspensionLeaseCoordinator.swift`); it owns only
// the durable registry's on-disk encoding/decoding and boot-session
// staleness rule (both platform-neutral, see the `LeaseStorageBackend`
// extension below), plus the filesystem primitives those rules are built on
// (directory/lock acquisition hardened against symlink and ownership
// attacks, TOCTOU-safe identity verification, and atomic state read/write).
//
// `LeaseStorageBackend` names exactly those filesystem primitives: opening
// and validating the storage directory (including its ownership), taking
// the exclusive per-directory lock, reading a file, comparing directory/file
// identity, and atomically replacing a file. `POSIXLeaseStorageBackend` and
// `Win32LeaseStorageBackend` below are the two conformances -- same
// primitive shape, platform-specific implementation -- and neither is ever
// compiled on the other platform (`#if os(macOS)` / `#elseif os(Windows)`).
// Windows has no uid/mode-bit ownership model, no directory-relative open,
// and no kern.boottime-equivalent syscall, so each of those three defenses
// is reimplemented with the closest honest Windows equivalent rather than
// weakened silently -- see the doc comment on each Windows primitive below
// for exactly what is, and is not, proven on this platform.

// MARK: - Platform primitive protocol

/// The minimal filesystem primitive surface the durable suspension-lease
/// registry's policy (below, as a `LeaseStorageBackend` extension) is built
/// on: opening/validating the storage directory and its ownership, taking
/// the exclusive per-directory lock, reading a file, comparing directory/file
/// identity, and atomically replacing a file. `SuspensionLeaseCoordinator`
/// itself never talks to a conformance directly -- it calls the thin,
/// per-platform wrapper methods in the `SuspensionLeaseCoordinator` extension
/// at the bottom of this file, which forward to `SuspensionLeaseCoordinator
/// .backend`.
///
/// One conformance exists per platform: `POSIXLeaseStorageBackend` wraps
/// Darwin's `open`/`flock`/`fstat`/`openat`/`renameat` family on macOS;
/// `Win32LeaseStorageBackend` wraps `CreateFileW`/`LockFileEx`/
/// `GetFileInformationByHandle`/`MoveFileExW` on Windows. Every method in the
/// `LeaseStorageBackend` extension below -- the registry's actual policy --
/// is written entirely against this protocol and has no AppKit, Darwin, or
/// WinSDK dependency of any kind.
protocol LeaseStorageBackend {
    /// An opaque, validated handle to the storage directory, as produced by
    /// `acquireDirectoryAndLockedFile(named:)`.
    associatedtype Directory
    /// An opaque, open file handle -- used both for the exclusive lock file
    /// (returned locked by `acquireDirectoryAndLockedFile(named:)`) and,
    /// separately and never locked, internally by `readFile(named:in:maxBytes:)`
    /// for the state file.
    associatedtype Handle

    /// Opens (creating if necessary) and validates the storage directory's
    /// identity and ownership, then opens (creating if necessary), locks
    /// (waiting up to a short bounded timeout for a concurrent holder to
    /// release it), and validates `lockName` within it as a safe regular
    /// file to trust. Returns both already-locked and ready to use, or
    /// throws with every resource opened along the way cleaned up.
    ///
    /// Deliberately ONE primitive, not decomposed into separate open/lock
    /// primitives with policy-level retry/cleanup glue on top: the two
    /// platforms' resource-lifetime mechanics differ enough (raw POSIX file
    /// descriptors needing symmetric open/close pairing on every failure
    /// path vs. a process-lifetime-cached Win32 directory handle that must
    /// never be closed by an individual lock attempt) that forcing one
    /// shared retry/cleanup skeleton over both would risk leaking a handle
    /// on one platform or double-closing it on the other.
    func acquireDirectoryAndLockedFile(named lockName: String) throws -> (Directory, Handle)

    /// Releases a lock handle returned by `acquireDirectoryAndLockedFile`,
    /// unlocking and closing it and (on platforms that do not cache the
    /// directory handle across calls) `directory` too. Never throws:
    /// failure here can only mean the process is about to exit anyway.
    func releaseLock(_ file: Handle, directory: Directory)

    /// Re-verifies, right now, that `directory` still identifies the same
    /// safely-owned directory it did when it was opened -- the TOCTOU
    /// re-check run around every locked operation.
    func validateDirectoryIdentity(_ directory: Directory) throws

    /// Re-verifies, right now, that the open handle `file` still identifies
    /// the same file on disk at `name` within `directory` as when it was
    /// opened.
    func validateFileIdentity(_ file: Handle, named name: String, in directory: Directory) throws

    /// Reads the entirety of `name`'s contents within `directory`, or `nil`
    /// if it does not exist. Fails closed with `.malformedState` the moment
    /// more than `maxBytes` have been read, rather than fully buffering an
    /// oversized file before rejecting it.
    func readFile(named name: String, in directory: Directory, maxBytes: Int) throws -> Data?

    /// Atomically installs `data` as `finalName` within `directory`: writes
    /// to a fresh temp file named `temporaryName`, flushes it durably,
    /// invokes `beforeInstall` (the shared policy below uses this for the
    /// storage precommit hook and a final lock-identity revalidation), then
    /// atomically renames the temp file onto `finalName`. `beforeInstall`
    /// always runs after the data is durably flushed and strictly before
    /// the rename, matching the original ordering both platforms already
    /// used; each conformance is free to decide, around that fixed point,
    /// exactly when its own OS handle must close.
    func atomicallyReplace(tempNamed temporaryName: String, installingAs finalName: String, in directory: Directory,
                            data: Data, beforeInstall: () throws -> Void) throws
}

// MARK: - Shared registry types and identifiers (platform-neutral)

extension SuspensionLeaseCoordinator {
    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState hold a `HeldLock` across their body
    // closures and read its `.directoryFD`.
    struct HeldLock<Backend: LeaseStorageBackend> {
        let directoryFD: Backend.Directory
        let file: Backend.Handle
        let backend: Backend

        func release() { backend.releaseLock(file, directory: directoryFD) }
    }

    // internal: SuspensionLeaseCoordinator.swift's withLockedState,
    // withLockedPresentationState, and readCanonicalState return this type.
    struct LockedResult<Value> {
        let value: Value
        let state: PersistedState
        let didPersist: Bool
    }

    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState read `.state` and `.needsRewrite` from the
    // result of `readState`.
    struct StateRead {
        let state: PersistedState
        /// An old-boot registry was decoded successfully but must be replaced
        /// before this operation returns, so the reboot recovery is durable
        /// rather than merely a process-local interpretation.
        let needsRewrite: Bool
    }

    // internal: thrown and caught throughout SuspensionLeaseCoordinator.swift's
    // business logic (acquireLease, releaseLease, withLockedState,
    // withLockedPresentationState, validateState, ...).
    enum CoordinatorError: LocalizedError {
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

    // internal: SuspensionLeaseCoordinator.init() uses this to build `lockURL`.
    static let lockName = "annotations-suspension-v3.lock"
    // internal: SuspensionLeaseCoordinator.init() uses this to build `stateURL`.
    static let stateName = "annotations-suspension-v3.json"
    // internal: not `private` -- `LeaseStorageBackend.writeRegistryState`
    // below (a different type) enforces this same cap while encoding.
    static let maximumSerializedBytes = 65_536

    // internal: SuspensionLeaseCoordinator.acquireLease() calls this to mint
    // a new lease token. Platform-neutral: it uses only cross-platform
    // Foundation APIs (SystemRandomNumberGenerator, Data, base64), so there
    // is nothing platform-specific here on either platform.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // internal: SuspensionLeaseCoordinator.releaseLease() and .validateState()
    // call this to validate tokens. Platform-neutral for the same reason as
    // `makeToken()` above.
    static func isCanonicalToken(_ token: String) -> Bool {
        token.count == 43 && token.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_"
        }
    }
}

// MARK: - Shared registry policy (platform-neutral)

extension LeaseStorageBackend {
    /// Acquires the exclusive per-directory lock via
    /// `acquireDirectoryAndLockedFile(named:)`, then validates the resulting
    /// directory and lock file's identity before handing back a `HeldLock`.
    /// On any failure after the lock is held, releases it before rethrowing.
    func acquireHeldLock(lockName: String) throws -> SuspensionLeaseCoordinator.HeldLock<Self> {
        let (directory, file) = try acquireDirectoryAndLockedFile(named: lockName)
        do {
            try validateDirectoryIdentity(directory)
            try validateFileIdentity(file, named: lockName, in: directory)
            return SuspensionLeaseCoordinator.HeldLock(directoryFD: directory, file: file, backend: self)
        } catch {
            releaseLock(file, directory: directory)
            throw error
        }
    }

    /// Re-validates a previously acquired `held`'s directory and lock file
    /// identity -- the TOCTOU re-check run around body execution and after
    /// the durable write.
    func validateHeld(_ held: SuspensionLeaseCoordinator.HeldLock<Self>, lockName: String) throws {
        try validateDirectoryIdentity(held.directoryFD)
        try validateFileIdentity(held.file, named: lockName, in: held.directoryFD)
    }

    /// Reads and decodes the durable registry, applying the boot-session
    /// staleness rule and every schema migration. This is a literal
    /// extraction of the on-disk registry's encoding/decoding and
    /// boot-session staleness policy -- previously duplicated verbatim
    /// between the macOS and Windows branches of this file -- built on top
    /// of `readFile(named:in:maxBytes:)`, the one platform primitive it
    /// needs.
    func readRegistryState(named stateName: String, bootSessionIdentifier: String, maxBytes: Int,
                            in directory: Directory) throws -> SuspensionLeaseCoordinator.StateRead {
        typealias StateRead = SuspensionLeaseCoordinator.StateRead
        typealias PersistedState = SuspensionLeaseCoordinator.PersistedState
        typealias Lease = SuspensionLeaseCoordinator.Lease
        typealias CoordinatorError = SuspensionLeaseCoordinator.CoordinatorError

        guard let data = try readFile(named: stateName, in: directory, maxBytes: maxBytes), !data.isEmpty else {
            // A file that does not exist and a file that exists but is empty
            // are treated identically here, and both are synthesized with
            // the STABLE `absentFileEpoch` sentinel rather than a fresh
            // UUID: repeated reads of the same absent/empty file must be
            // indistinguishable, or the generation ratchet resets on every
            // reconcile tick (AppDelegate runs one twice a second). It is
            // still an identity, though, so a registry that disappears (or
            // is truncated) mid-session reads as a real epoch change and
            // resets the ratchet exactly once -- which is what lets a
            // snapshot pinned to a file that no longer exists self-heal
            // instead of ordering the overlays out for the rest of the
            // session. See `PersistedState.instanceEpoch`.
            return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier,
                                                   instanceEpoch: PersistedState.absentFileEpoch),
                             needsRewrite: false)
        }
        do {
            var state = try JSONDecoder().decode(PersistedState.self, from: data)
            // A valid old-boot registry is safely replaced, never revived.
            // Unlike the missing/empty case above this genuinely IS a new
            // registry file about to overwrite a different one, so mint its
            // identity now rather than leaving peers unable to tell the
            // replacement apart from the state it replaced.
            if state.bootSessionIdentifier != bootSessionIdentifier {
                return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier,
                                                       instanceEpoch: UUID().uuidString),
                                 needsRewrite: true)
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
                try SuspensionLeaseCoordinator.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
                return StateRead(state: state, needsRewrite: true)
            }
            // An EXISTING same-boot file whose optional `instanceEpoch`
            // decoded as nil -- written by a build that predates the field, or
            // before the epoch was minted at persist time -- must be upgraded
            // exactly once here. Returning it unchanged left the file without
            // an identity for the whole boot, which permanently disables the
            // ratchet reset: a later read the ratchet rejects then pins
            // `cachedSnapshot` to state that may no longer exist on disk.
            // This is deliberately distinct from a MISSING file, which carries
            // the `absentFileEpoch` sentinel until something actually persists
            // it and mints a real UUID.
            if state.instanceEpoch == nil {
                state.instanceEpoch = UUID().uuidString
                try SuspensionLeaseCoordinator.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
                return StateRead(state: state, needsRewrite: true)
            }
            try SuspensionLeaseCoordinator.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
            return StateRead(state: state, needsRewrite: false)
        } catch let error as CoordinatorError { throw error
        } catch { throw CoordinatorError.malformedState }
    }

    /// Encodes and durably installs `state`, enforcing the same serialized-
    /// size cap `readRegistryState` reads under. `precommitHook` and a final
    /// lock-identity revalidation run via `atomicallyReplace`'s
    /// `beforeInstall`, at the exact point (after the data is durably
    /// flushed, strictly before the rename) both platforms already used.
    func writeRegistryState(_ state: SuspensionLeaseCoordinator.PersistedState,
                             held: SuspensionLeaseCoordinator.HeldLock<Self>,
                             stateName: String, lockName: String, maxBytes: Int,
                             precommitHook: (() -> Void)?) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= maxBytes else { throw SuspensionLeaseCoordinator.CoordinatorError.malformedState }
        let temporaryName = ".annotations-suspension-v3.\(UUID().uuidString).tmp"
        try atomicallyReplace(tempNamed: temporaryName, installingAs: stateName, in: held.directoryFD, data: data) {
            precommitHook?()
            try validateHeld(held, lockName: lockName)
        }
    }
}

// MARK: - macOS backend

#if os(macOS)
/// POSIX/Darwin conformance of `LeaseStorageBackend`: directory and
/// lock-file acquisition hardened against symlink and ownership attacks,
/// TOCTOU-safe inode verification, and atomic state read/write via
/// `openat`/`fstatat`/`renameat`/`unlinkat`, all resolved relative to an
/// already-validated directory descriptor rather than by re-walking a path
/// string.
struct POSIXLeaseStorageBackend: LeaseStorageBackend {
    let storageDirectory: URL

    /// The validated (parentFD, directoryFD) pair `openSecureDirectory()`
    /// produces. `parentFD` is carried alongside `directoryFD` purely so
    /// `releaseLock(_:directory:)` can close it symmetrically with how it
    /// was opened.
    struct Directory {
        let parentFD: Int32
        let directoryFD: Int32
    }

    // MARK: LeaseStorageBackend

    func acquireDirectoryAndLockedFile(named lockName: String) throws -> (Directory, Int32) {
        let opened = try openSecureDirectory()
        let parentFD = opened.parentFD
        let directoryFD = opened.directoryFD
        var descriptor: Int32 = -1
        do {
            descriptor = try openValidatedRegularFile(named: lockName, in: directoryFD, create: true)
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let error = errno
                guard error == EWOULDBLOCK || error == EAGAIN || error == EINTR else {
                    close(descriptor)
                    descriptor = -1
                    throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not lock suspension state (errno \(error)).")
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    close(descriptor)
                    descriptor = -1
                    throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("Another annotation suspension operation is still in progress.")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return (Directory(parentFD: parentFD, directoryFD: directoryFD), descriptor)
        } catch {
            // `validateDirectoryIdentity`/`validateFileIdentity` run in the
            // shared `acquireHeldLock` policy AFTER this primitive returns,
            // and their failure is cleaned up there via `releaseLock`; this
            // catch only needs to cover a failure from this primitive's own
            // open-and-lock sequence.
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            close(directoryFD)
            close(parentFD)
            throw error
        }
    }

    func releaseLock(_ file: Int32, directory: Directory) {
        _ = flock(file, LOCK_UN)
        close(file)
        close(directory.directoryFD)
        close(directory.parentFD)
    }

    func validateDirectoryIdentity(_ directory: Directory) throws {
        var descriptorInfo = stat(), parentEntry = stat(), absoluteEntry = stat()
        guard fstat(directory.directoryFD, &descriptorInfo) == 0,
              fstatat(directory.parentFD, storageDirectory.lastPathComponent, &parentEntry, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(storageDirectory.path, &absoluteEntry) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
              descriptorInfo.st_dev == parentEntry.st_dev, descriptorInfo.st_ino == parentEntry.st_ino,
              descriptorInfo.st_dev == absoluteEntry.st_dev, descriptorInfo.st_ino == absoluteEntry.st_ino,
              descriptorInfo.st_uid == getuid() else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state directory; overlays remain hidden.")
        }
    }

    func validateFileIdentity(_ file: Int32, named name: String, in directory: Directory) throws {
        var descriptorInfo = stat(), pathInfo = stat()
        guard fstat(file, &descriptorInfo) == 0,
              fstatat(directory.directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino,
              descriptorInfo.st_uid == getuid(), descriptorInfo.st_nlink == 1 else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
    }

    func readFile(named name: String, in directory: Directory, maxBytes: Int) throws -> Data? {
        var pathInfo = stat()
        if fstatat(directory.directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not inspect suspension lease state (errno \(errno)).")
        }
        let fd = try openValidatedRegularFile(named: name, in: directory.directoryFD, create: false)
        defer { close(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not read suspension lease state (errno \(errno)).") }
            data.append(buffer, count: count)
            guard data.count <= maxBytes else { throw SuspensionLeaseCoordinator.CoordinatorError.malformedState }
        }
        return data
    }

    func atomicallyReplace(tempNamed temporaryName: String, installingAs finalName: String, in directory: Directory,
                            data: Data, beforeInstall: () throws -> Void) throws {
        let fd = openat(directory.directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not create temporary suspension state (errno \(errno)).") }
        var installed = false
        defer {
            close(fd)
            if !installed { _ = unlinkat(directory.directoryFD, temporaryName, 0) }
        }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not write suspension state (errno \(errno)).") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not sync suspension state (errno \(errno)).") }
        try beforeInstall()
        guard renameat(directory.directoryFD, temporaryName, directory.directoryFD, finalName) == 0 else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not install suspension state (errno \(errno)).")
        }
        installed = true
        guard fsync(directory.directoryFD) == 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not sync suspension-state directory (errno \(errno)).") }
    }

    // MARK: Private primitives

    private func openSecureDirectory() throws -> (parentFD: Int32, directoryFD: Int32) {
        let path = storageDirectory.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not create its private suspension-state directory (errno \(errno)).")
        }
        let parentPath = storageDirectory.deletingLastPathComponent().path
        let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not open the suspension-state parent directory (errno \(errno)).") }
        let fd = openat(parentFD, storageDirectory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { close(parentFD); throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not open its private suspension-state directory (errno \(errno)).") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
            close(fd); close(parentFD); throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state directory.")
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
                close(fd); close(parentFD); throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not secure its suspension-state directory.")
            }
        }
        return (parentFD, fd)
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
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state file.")
        }
        if !existed && errno != ENOENT { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not inspect suspension state (errno \(errno)).") }
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
                    throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state file.")
                }
                beforeIsValidated = true
                fd = openat(directoryFD, name, baseFlags)
            }
        } else {
            fd = openat(directoryFD, name, baseFlags)
        }
        guard fd >= 0 else {
            let role = name == SuspensionLeaseCoordinator.lockName ? "suspension-operation lock" : "suspension lease state"
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not open its \(role) (errno \(errno)).")
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0,
              fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (after.st_mode & S_IFMT) == S_IFREG, after.st_uid == getuid(), after.st_nlink == 1,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              (!beforeIsValidated || (before.st_dev == after.st_dev && before.st_ino == after.st_ino)) else {
            close(fd); throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state file.")
        }
        guard fchmod(fd, 0o600) == 0 else { close(fd); throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not secure suspension state.") }
        return fd
    }
}
#endif

// MARK: - Windows backend

#if os(Windows)
/// Win32 conformance of `LeaseStorageBackend`: directory and lock-file
/// acquisition hardened with owner-SID verification and reparse-point
/// rejection, TOCTOU identity re-checks via `GetFileInformationByHandle`,
/// and atomic state read/write via `CreateFileW`/`MoveFileExW`.
struct Win32LeaseStorageBackend: LeaseStorageBackend {
    let storageDirectory: URL

    // Guards `cachedDirectoryHandles` below. A plain NSLock -- static
    // because the cache itself is process-wide, shared by every
    // `Win32LeaseStorageBackend` value that happens to point at the same
    // directory path (the test suite routinely constructs several
    // coordinators against one shared temporary directory to model multiple
    // Chalkboard processes).
    private static let directoryHandleLock = NSLock()
    // internal: process-lifetime cache of validated directory handles,
    // keyed by `storageDirectory.path`. See `openSecureDirectory()`'s doc
    // comment for why this exists and what it does and does not prove.
    private static var cachedDirectoryHandles: [String: HANDLE] = [:]

    // MARK: LeaseStorageBackend

    // internal: `directoryHandle` returned here is NOT opened fresh by this
    // call -- it is a long-lived handle to `storageDirectory`, opened once
    // per distinct directory path and cached for the rest of the process's
    // life (see `openSecureDirectory()` below). `descriptor` is the
    // per-operation handle to the lock file, opened and byte-range-locked
    // fresh by every call, exactly like the POSIX conformance's descriptor.
    func acquireDirectoryAndLockedFile(named lockName: String) throws -> (HANDLE, HANDLE) {
        let directoryHandle = try openSecureDirectory()
        let descriptor = try openValidatedRegularFile(named: lockName, create: true)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while true {
            var overlapped = OVERLAPPED()
            if LockFileEx(descriptor, DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
                          0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped) {
                break
            }
            let lastError = GetLastError()
            // ERROR_LOCK_VIOLATION is Win32's "another handle already holds
            // this byte range" -- the direct analogue of POSIX flock's
            // EWOULDBLOCK/EAGAIN, and the only failure this loop retries on.
            guard lastError == DWORD(ERROR_LOCK_VIOLATION) else {
                CloseHandle(descriptor)
                throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not lock suspension state (Win32 error \(lastError)).")
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                CloseHandle(descriptor)
                throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("Another annotation suspension operation is still in progress.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return (directoryHandle, descriptor)
    }

    func releaseLock(_ file: HANDLE, directory: HANDLE) {
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(file, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped)
        CloseHandle(file)
        // `directory` is the shared, process-lifetime cached handle -- see
        // `openSecureDirectory()` -- and outlives every individual lock
        // acquisition, so it is deliberately not closed here.
    }

    func validateDirectoryIdentity(_ directory: HANDLE) throws {
        guard let handleInfo = Self.fileInformation(ofOpenHandle: directory),
              (handleInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0,
              (handleInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0 else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state directory; overlays remain hidden.")
        }
        // See `openSecureDirectory()`'s doc comment: this re-resolves the
        // path fresh, right now, and requires the SAME identity as the
        // cached handle validated when this directory was first opened.
        guard let pathInfo = Self.fileInformation(atPath: storageDirectory.path, openReparsePoint: true),
              (pathInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0,
              handleInfo.dwVolumeSerialNumber == pathInfo.dwVolumeSerialNumber,
              handleInfo.nFileIndexHigh == pathInfo.nFileIndexHigh,
              handleInfo.nFileIndexLow == pathInfo.nFileIndexLow else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state directory; overlays remain hidden.")
        }
        // Re-checked on every call, matching the POSIX conformance's
        // `descriptorInfo.st_uid == getuid()` re-check -- see
        // `validateOwnerIsCurrentUser`'s doc comment for exactly what this
        // does and does not prove on Windows.
        try Self.validateOwnerIsCurrentUser(directory)
    }

    func validateFileIdentity(_ file: HANDLE, named name: String, in directory: HANDLE) throws {
        guard let descriptorInfo = Self.fileInformation(ofOpenHandle: file) else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
        let path = storageDirectory.appendingPathComponent(name).path
        guard let pathInfo = Self.fileInformation(atPath: path, openReparsePoint: true) else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
        guard (descriptorInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0,
              (pathInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0,
              descriptorInfo.dwVolumeSerialNumber == pathInfo.dwVolumeSerialNumber,
              descriptorInfo.nFileIndexHigh == pathInfo.nFileIndexHigh,
              descriptorInfo.nFileIndexLow == pathInfo.nFileIndexLow,
              // `nNumberOfLinks` is Windows' analogue of POSIX `st_nlink`,
              // exposed by the very same GetFileInformationByHandle call
              // used for the identity check above -- rejecting a
              // hard-linked replacement lock is not a POSIX-only property.
              descriptorInfo.nNumberOfLinks == 1 else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
    }

    func readFile(named name: String, in directory: HANDLE, maxBytes: Int) throws -> Data? {
        let path = storageDirectory.appendingPathComponent(name).path
        guard Self.fileInformation(atPath: path, openReparsePoint: true) != nil else {
            let lastError = GetLastError()
            // ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND is this platform's
            // ENOENT.
            if lastError == DWORD(ERROR_FILE_NOT_FOUND) || lastError == DWORD(ERROR_PATH_NOT_FOUND) {
                return nil
            }
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not inspect suspension lease state (Win32 error \(lastError)).")
        }
        let fd = try openValidatedRegularFile(named: name, create: false)
        defer { CloseHandle(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            var bytesRead: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
                ReadFile(fd, rawBuffer.baseAddress, DWORD(rawBuffer.count), &bytesRead, nil)
            }
            guard ok else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not read suspension lease state (Win32 error \(GetLastError())).") }
            if bytesRead == 0 { break }
            data.append(buffer, count: Int(bytesRead))
            guard data.count <= maxBytes else { throw SuspensionLeaseCoordinator.CoordinatorError.malformedState }
        }
        return data
    }

    func atomicallyReplace(tempNamed temporaryName: String, installingAs finalName: String, in directory: HANDLE,
                            data: Data, beforeInstall: () throws -> Void) throws {
        let temporaryPath = storageDirectory.appendingPathComponent(temporaryName).path
        let finalPath = storageDirectory.appendingPathComponent(finalName).path

        let rawHandle: HANDLE? = temporaryPath.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(widePath, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ),
                        nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let fd = rawHandle, fd != INVALID_HANDLE_VALUE else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not create temporary suspension state (Win32 error \(GetLastError())).")
        }
        var installed = false
        // Tracks whether `fd` has already been closed by the explicit
        // `CloseHandle(fd)` below, so this `defer` (which must still run to
        // clean up on every early-`throw` path above that point) never
        // double-closes it.
        var fdClosed = false
        defer {
            if !fdClosed { CloseHandle(fd) }
            if !installed {
                _ = temporaryPath.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            }
        }
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                var bytesWritten: DWORD = 0
                let ok = WriteFile(fd, raw.baseAddress!.advanced(by: offset), DWORD(raw.count - offset), &bytesWritten, nil)
                guard ok, bytesWritten > 0 else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not write suspension state (Win32 error \(GetLastError())).") }
                offset += Int(bytesWritten)
            }
        }
        guard FlushFileBuffers(fd) else { throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not sync suspension state (Win32 error \(GetLastError())).") }
        // MUST close before MoveFileExW below: `fd` was opened with only
        // FILE_SHARE_READ (see the CreateFileW call above), not
        // FILE_SHARE_DELETE, so a rename of this SAME path while `fd` is
        // still open fails with ERROR_SHARING_VIOLATION (Win32 error 32) --
        // this was a real bug here (caught by
        // SuspensionLeaseCoordinatorTests.testOverlappingLeasesIdempotentRetryAndExactRelease
        // and several sibling tests genuinely failing on this exact path,
        // not a pre-existing/theoretical concern). Closing here, rather than
        // widening the share mode to include FILE_SHARE_DELETE, keeps the
        // written bytes' only ever having exactly one owner at a time (this
        // function while writing, then whatever the rename below makes it)
        // and matches the file's designed lifetime -- nothing else needs to
        // keep this handle open past the flush.
        CloseHandle(fd)
        fdClosed = true
        try beforeInstall()
        // MoveFileExW with MOVEFILE_REPLACE_EXISTING is NTFS's atomic
        // rename-onto-existing-name, the same durability/atomicity property
        // POSIX renameat gives the macOS conformance above.
        let moved = temporaryPath.withCString(encodedAs: UTF16.self) { wideSrc in
            finalPath.withCString(encodedAs: UTF16.self) { wideDst in
                MoveFileExW(wideSrc, wideDst, DWORD(MOVEFILE_REPLACE_EXISTING))
            }
        }
        guard moved else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not install suspension state (Win32 error \(GetLastError())).")
        }
        installed = true
        // WINDOWS NOTE: the macOS conformance additionally fsyncs its
        // directory descriptor here to flush the rename's directory-entry
        // metadata. `directory` on Windows is the process-lifetime cached
        // handle from `openSecureDirectory()`, opened with GENERIC_READ only
        // (it is used solely for identity checks, never for writes), so
        // FlushFileBuffers cannot be called on it -- Win32 requires a handle
        // opened with write access. There is no separate directory-metadata
        // flush to perform here in any case: NTFS journals rename operations
        // as part of its own metadata transaction log, and the temp file's
        // data was already flushed above before this rename ran, so the
        // durability this call would add on macOS is provided here by
        // NTFS's own journaling of the MoveFileExW transaction instead.
    }

    // MARK: Private primitives

    /// Opens (creating if necessary) and validates `storageDirectory`, then
    /// caches the resulting handle for the rest of the process's life,
    /// keyed by path.
    ///
    /// TOCTOU HARDENING -- WEAKER THAN macOS, DOCUMENTED PRECISELY: the
    /// POSIX conformance's `openSecureDirectory()`/`validateDirectoryIdentity()`
    /// open the directory once *relative to its already-validated parent*
    /// (`openat`/`fstatat`), so no step after the parent is opened ever
    /// re-resolves a path component an attacker could have swapped out from
    /// under it. Win32 has no public directory-relative open (`openat`'s
    /// equivalent is an undocumented native NT API, not part of the surface
    /// WinSDK exposes), so every lock/state file open in this file is
    /// unavoidably PATH-based and re-resolves `storageDirectory`'s path
    /// components fresh, through the ordinary filesystem namespace, on every
    /// single call.
    ///
    /// The mitigation actually used here is a HANDLE IDENTITY RE-CHECK, not
    /// re-resolution avoidance: this directory is opened and fully validated
    /// (real directory, not a reparse point, owned by the current user) only
    /// ONCE per path, and that handle is kept open and cached for the
    /// process's lifetime. A Windows handle -- like a POSIX fd -- follows the
    /// underlying file object across a rename, not the path string used to
    /// open it, so this cached handle's own identity can never silently
    /// become "some other directory" out from under it. Every subsequent
    /// operation (`validateDirectoryIdentity`, called from `acquireHeldLock`
    /// and `validateHeld`) re-resolves `storageDirectory.path` fresh and
    /// requires the result to carry the SAME (volume serial, file index)
    /// identity as the cached handle. A mismatch means the path no longer
    /// leads to the directory this process is entitled to trust -- e.g. it
    /// was deleted and replaced -- and every such call fails closed rather
    /// than silently operating on whatever now sits there. This is
    /// materially weaker than directory-fd-relative opens (there IS a path
    /// re-resolution on every call, whereas macOS has none after the parent
    /// is opened), but it converts "operate on a swapped directory" into
    /// "detect the swap and fail closed," which is the property this
    /// hardening exists to provide.
    private func openSecureDirectory() throws -> HANDLE {
        let path = storageDirectory.path
        let created = path.withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
        guard created || GetLastError() == DWORD(ERROR_ALREADY_EXISTS) else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not create its private suspension-state directory (Win32 error \(GetLastError())).")
        }

        Self.directoryHandleLock.lock()
        defer { Self.directoryHandleLock.unlock() }
        if let cached = Self.cachedDirectoryHandles[path] {
            return cached
        }

        // FILE_FLAG_BACKUP_SEMANTICS is required to open a directory (rather
        // than a file) with CreateFileW at all. FILE_FLAG_OPEN_REPARSE_POINT
        // is this platform's O_NOFOLLOW: if `path` is a symlink or a
        // directory junction, this opens the reparse point object itself
        // rather than transparently following it into whatever it points
        // at, so the FILE_ATTRIBUTE_REPARSE_POINT check below can reject it
        // before this directory is ever trusted.
        let flags = DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
        // NOTE: on this toolchain's WinSDK overlay, `HANDLE` itself resolves
        // to a plain non-optional `UnsafeMutableRawPointer` (not
        // already-optional), so the intermediate is annotated `HANDLE?`
        // explicitly, matching Logger.swift's `openAppendHandle(at:)`.
        let rawHandle: HANDLE? = path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(widePath, DWORD(GENERIC_READ),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), flags, nil)
        }
        guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not open its private suspension-state directory (Win32 error \(GetLastError())).")
        }
        guard let info = Self.fileInformation(ofOpenHandle: handle),
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0,
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0 else {
            CloseHandle(handle)
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state directory.")
        }
        do {
            try Self.validateOwnerIsCurrentUser(handle)
        } catch {
            CloseHandle(handle)
            throw error
        }

        Self.cachedDirectoryHandles[path] = handle
        return handle
    }

    private func openValidatedRegularFile(named name: String, create: Bool) throws -> HANDLE {
        let fullPath = storageDirectory.appendingPathComponent(name).path
        // OPEN_ALWAYS ("create if missing, else open the existing file
        // without truncating it") is atomic in a single Win32 call, unlike
        // POSIX O_CREAT|O_EXCL -- there is no equivalent here to the POSIX
        // conformance's O_EXCL-loser re-inspect-and-reopen dance above,
        // because there is no race to resolve: two processes racing
        // OPEN_ALWAYS both get a handle to whichever file the filesystem
        // settles on, atomically.
        let disposition: DWORD = create ? DWORD(OPEN_ALWAYS) : DWORD(OPEN_EXISTING)
        // FILE_FLAG_OPEN_REPARSE_POINT is this platform's O_NOFOLLOW -- see
        // `openSecureDirectory()`'s doc comment for the same reasoning
        // applied to a file instead of a directory.
        let flags = DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
        let rawHandle: HANDLE? = fullPath.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(widePath, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, disposition, flags, nil)
        }
        guard let fd = rawHandle, fd != INVALID_HANDLE_VALUE else {
            let role = name == SuspensionLeaseCoordinator.lockName ? "suspension-operation lock" : "suspension lease state"
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not open its \(role) (Win32 error \(GetLastError())).")
        }
        guard let info = Self.fileInformation(ofOpenHandle: fd),
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0,
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) == 0,
              // See `validateFileIdentity`'s comment: nNumberOfLinks == 1
              // rejects a hard-linked replacement, matching the POSIX
              // conformance's st_nlink check.
              info.nNumberOfLinks == 1 else {
            CloseHandle(fd)
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state file.")
        }
        return fd
    }

    /// Best-effort analogue of `stat`/`fstat`'s (st_dev, st_ino) identity
    /// pair for a file already known to still be OPEN, used throughout this
    /// file for TOCTOU identity comparisons. See Logger.swift's identical
    /// helper and its doc comment for the one honest gap versus a POSIX
    /// inode (the file-index portion is not guaranteed stable on every
    /// filesystem) -- the same caveat and the same safe failure direction
    /// (an unnecessary close-and-reopen, never trusting two different files
    /// as one) apply to every use of it here.
    private static func fileInformation(ofOpenHandle handle: HANDLE) -> BY_HANDLE_FILE_INFORMATION? {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        return info
    }

    /// Opens a short-lived, attributes-only handle purely to identify
    /// whatever currently sits at `path` -- the Windows analogue of POSIX
    /// `stat(path)`/`lstat(path)`, which need no open file descriptor at
    /// all. Works for both files and directories (FILE_FLAG_BACKUP_SEMANTICS
    /// is required for the latter and harmless for the former).
    /// `openReparsePoint: true` is this platform's O_NOFOLLOW/AT_SYMLINK_NOFOLLOW
    /// -- callers doing TOCTOU/identity comparisons always pass it, so a
    /// symlink or junction at `path` is identified as itself, never silently
    /// followed into whatever it points at.
    private static func fileInformation(atPath path: String, openReparsePoint: Bool) -> BY_HANDLE_FILE_INFORMATION? {
        var flags = DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_BACKUP_SEMANTICS)
        if openReparsePoint { flags |= DWORD(FILE_FLAG_OPEN_REPARSE_POINT) }
        let rawHandle: HANDLE? = path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(widePath, 0,
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), flags, nil)
        }
        guard let probe = rawHandle, probe != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(probe) }
        return fileInformation(ofOpenHandle: probe)
    }

    /// Verifies that `handle`'s file/directory is OWNED by the identity this
    /// process is running as, the Windows analogue of the POSIX
    /// conformance's `info.st_uid == getuid()` checks above.
    ///
    /// OWNERSHIP HARDENING -- WEAKER THAN macOS, DOCUMENTED PRECISELY: the
    /// POSIX conformance's `(info.st_mode & 0o022) == 0` /
    /// `(info.st_mode & 0o777) == 0o700` checks prove something POSIX mode
    /// bits make cheap to prove: that NO OTHER PRINCIPAL ON THE SYSTEM --
    /// not the owner's own group, not "other" -- has write access to this
    /// directory, because write permission for every principal except the
    /// owner is encoded directly in the three mode-bit fields being checked.
    /// Windows access control (DACLs, an ordered list of per-principal
    /// ALLOW/DENY access control entries, evaluated against arbitrary
    /// security groups) has no equivalent fixed-width encoding to check
    /// three bits against. This function proves only OWNERSHIP: that the
    /// SID recorded as this object's owner is the SID of the user this
    /// process is running as (via GetSecurityInfo's
    /// OWNER_SECURITY_INFORMATION and OpenProcessToken+GetTokenInformation
    /// (TokenUser), compared with EqualSid). It deliberately does NOT walk
    /// the DACL to prove no other principal has been granted write access --
    /// e.g. a misconfigured inherited ACE granting Everyone or a custom
    /// group Modify rights on this specific directory would pass this check
    /// even though it defeats the isolation the check exists to provide.
    /// What this DOES prove: an attacker who is not running as this same
    /// Windows user account cannot have created, and cannot silently
    /// replace, the directory this process is about to trust, absent a
    /// separate DACL misconfiguration. What it does NOT prove: that no other
    /// principal on the machine has been granted write access to it. A full
    /// DACL audit (enumerating every ACE, resolving group membership, and
    /// rejecting anything broader than the owner) is not implemented here.
    private static func validateOwnerIsCurrentUser(_ handle: HANDLE) throws {
        // NOTE: on this toolchain's WinSDK overlay, PSID/PSECURITY_DESCRIPTOR/
        // HANDLE each resolve to a plain non-optional `UnsafeMutableRawPointer`
        // (not already-optional), so each out-parameter local below is
        // declared explicitly `?` to match the `PSID?`/`PSECURITY_DESCRIPTOR?`/
        // `HANDLE?`-typed out-parameters these APIs actually expect. Matches
        // Logger.swift's `HANDLE?` convention.
        var ownerSid: PSID?
        var securityDescriptor: PSECURITY_DESCRIPTOR?
        let status = GetSecurityInfo(handle, SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION),
                                     &ownerSid, nil, nil, nil, &securityDescriptor)
        guard status == 0, let ownerSid, let securityDescriptor, IsValidSid(ownerSid) else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not determine the suspension-state directory's owner.")
        }
        defer { LocalFree(securityDescriptor) }

        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not open its own process token.")
        }
        defer { CloseHandle(token) }

        var requiredSize: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &requiredSize)
        guard requiredSize > 0 else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not size its own user token.")
        }
        var tokenBuffer = [UInt8](repeating: 0, count: Int(requiredSize))
        // `EqualSid` runs INSIDE this closure, not after it returns: the SID
        // pointer `TOKEN_USER.User.Sid` exposes points into `tokenBuffer`'s
        // own storage, and that pointer must never be used once the buffer
        // it points into could have been deallocated.
        let isSameOwner: Bool = try tokenBuffer.withUnsafeMutableBytes { rawBuffer in
            guard GetTokenInformation(token, TokenUser, rawBuffer.baseAddress, requiredSize, &requiredSize) else {
                throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard could not read its own user token.")
            }
            let tokenUser = rawBuffer.load(as: TOKEN_USER.self)
            guard let userSid = tokenUser.User.Sid, IsValidSid(userSid) else { return false }
            return EqualSid(ownerSid, userSid)
        }
        guard isSameOwner else {
            throw SuspensionLeaseCoordinator.CoordinatorError.unavailable("AI Chalkboard refused a suspension-state directory owned by another Windows account.")
        }
    }
}
#endif

// MARK: - Per-coordinator wiring

extension SuspensionLeaseCoordinator {
#if os(macOS)
    /// The concrete `LeaseStorageBackend` this build is compiled against.
    typealias PlatformBackend = POSIXLeaseStorageBackend
#elseif os(Windows)
    typealias PlatformBackend = Win32LeaseStorageBackend
#endif

    /// A fresh backend value bound to this coordinator's `storageDirectory`.
    /// Cheap to construct on every access: the POSIX conformance carries
    /// only that URL, and the Windows conformance's directory-handle cache
    /// is process-wide `static` state on `Win32LeaseStorageBackend` itself,
    /// not held here.
    private var backend: PlatformBackend { PlatformBackend(storageDirectory: storageDirectory) }

    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState hold the returned `HeldLock` across their
    // body closures and read its `.directoryFD`.
    func acquireLock() throws -> HeldLock<PlatformBackend> {
        try backend.acquireHeldLock(lockName: Self.lockName)
    }

    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState call this to re-validate around body
    // execution and after the durable write.
    func validateHeldLock(_ held: HeldLock<PlatformBackend>) throws {
        try backend.validateHeld(held, lockName: Self.lockName)
    }

    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState.
    func readState(in directory: PlatformBackend.Directory, bootSessionIdentifier: String) throws -> StateRead {
        try backend.readRegistryState(named: Self.stateName, bootSessionIdentifier: bootSessionIdentifier,
                                      maxBytes: Self.maximumSerializedBytes, in: directory)
    }

    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState.
    func writeState(_ state: PersistedState, held: HeldLock<PlatformBackend>) throws {
        try backend.writeRegistryState(state, held: held, stateName: Self.stateName, lockName: Self.lockName,
                                       maxBytes: Self.maximumSerializedBytes, precommitHook: storagePrecommitHook)
    }

#if os(macOS)
    // internal: SuspensionLeaseCoordinator.init() calls this when no boot
    // session id override is supplied.
    static func currentBootSessionIdentifier() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size else { return nil }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }
#elseif os(Windows)
    // internal: SuspensionLeaseCoordinator.init() calls this when no boot
    // session id override is supplied.
    //
    // REBOOT-SESSION IDENTITY -- WEAKER THAN macOS, DOCUMENTED PRECISELY:
    // kern.boottime is read directly from the XNU kernel and is exact: two
    // processes started minutes or days apart, in the same boot, always read
    // back the identical value, and a genuine reboot always changes it.
    // Windows has no equivalent syscall. The closest approximation is
    // `now - uptime`, computed from GetTickCount64() (milliseconds since
    // boot; monotonic, but not guaranteed by Microsoft to include every
    // sleep/hibernate interval on every Windows version) and the current
    // wall-clock time. Two processes computing this at different real
    // moments within the SAME boot can get slightly different raw results,
    // because the wall clock can be nudged by NTP discipline between their
    // two measurements even though the boot itself never changed -- this is
    // the ambiguity rounding to a coarse bucket exists to absorb.
    //
    // FAILURE DIRECTION IS DELIBERATELY SAFE: a computed value that drifts
    // across the bucket boundary for the SAME boot does not honour a stale
    // lease -- it does the opposite. `readState()`'s
    // `state.bootSessionIdentifier != bootSessionIdentifier` branch treats
    // ANY identifier mismatch, spurious or genuine, identically: replace the
    // registry with a fresh, EMPTY, unsuspended state (see that branch's
    // comment). So every ambiguity here degrades to "treat the existing
    // lease as stale, restore the annotations," which is always the safe
    // direction for a tool whose entire purpose is to guarantee overlays are
    // never left stuck hidden. It is never able to do the unsafe thing --
    // honour a lease that should have died with the previous boot -- as a
    // result of clock jitter.
    //
    // The 2-second bucket width is chosen to make the UNSAFE direction --
    // two DIFFERENT boots computing the SAME rounded identifier, which
    // WOULD let a stale pre-reboot lease be wrongly honoured -- vanishingly
    // unlikely: it would require the machine's wall-clock-minus-uptime value
    // to land in the same 2-second bucket across two genuinely separate
    // boots, which in practice requires the two boot instants themselves to
    // coincide within about 2 seconds. The cost of choosing a narrow bucket
    // is only ever paid in the safe direction: it tolerates less wall-clock
    // jitter before two same-boot computations diverge and trigger the
    // harmless extra reset described above.
    static func currentBootSessionIdentifier() -> String? {
        let tickMillis = GetTickCount64()
        var fileTime = FILETIME()
        GetSystemTimeAsFileTime(&fileTime)
        let hundredNanosSinceEpoch = (UInt64(fileTime.dwHighDateTime) << 32) | UInt64(fileTime.dwLowDateTime)
        let nowMillisSinceEpoch = hundredNanosSinceEpoch / 10_000
        guard nowMillisSinceEpoch > tickMillis else { return nil }
        let bootEpochMillis = nowMillisSinceEpoch - tickMillis
        let bucketWidthMillis: UInt64 = 2_000
        let bucketed = (bootEpochMillis / bucketWidthMillis) * bucketWidthMillis
        return "winboot-\(bucketed)"
    }
#endif
}
