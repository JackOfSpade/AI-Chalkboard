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

// The hardened POSIX/persistence layer for `SuspensionLeaseCoordinator`'s
// durable registry: directory and lock-file acquisition hardened against
// symlink and ownership attacks, TOCTOU-safe inode verification, and atomic
// state read/write. This file contains no lease business logic -- see
// `SuspensionLeaseCoordinator.swift` for the public API and state machine.
//
// WINDOWS PORT: the paragraph above describes the `#if os(macOS)` branch
// below, unchanged. A second, independent implementation of the exact same
// internal API sits in the `#elseif os(Windows)` branch: same type/method
// names and shapes, so `SuspensionLeaseCoordinator.swift`'s business logic
// does not need to know which platform it is running on. Windows has no
// uid/mode-bit ownership model, no directory-relative open, and no
// kern.boottime-equivalent syscall, so each of those three defenses is
// reimplemented with the closest honest Windows equivalent rather than
// weakened silently -- see the doc comment on each Windows primitive below
// for exactly what is, and is not, proven on this platform.
extension SuspensionLeaseCoordinator {
#if os(macOS)
    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState hold a `HeldLock` across their body
    // closures and read its `directoryFD`.
    struct HeldLock {
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
    private static let maximumSerializedBytes = 65_536

    // MARK: - Hardened storage

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState.
    func acquireLock() throws -> HeldLock {
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

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState to re-validate around body execution
    // and after the durable write.
    func validateHeldLock(_ held: HeldLock) throws {
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

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState.
    func readState(in directoryFD: Int32, bootSessionIdentifier: String) throws -> StateRead {
        var pathInfo = stat()
        if fstatat(directoryFD, Self.stateName, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            // A missing (and, below, an empty) file is synthesized with the
            // STABLE `absentFileEpoch` sentinel rather than a fresh UUID:
            // repeated reads of the same absent file must be indistinguishable,
            // or the generation ratchet resets on every reconcile tick. It is
            // still an identity, though, so a registry that disappears
            // mid-session reads as a real epoch change and resets the ratchet
            // exactly once. See `PersistedState.instanceEpoch`.
            if errno == ENOENT {
                return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier,
                                                       instanceEpoch: PersistedState.absentFileEpoch),
                                 needsRewrite: false)
            }
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
        guard !data.isEmpty else {
            // Same sentinel as the ENOENT branch above: an empty file carries
            // no identity of its own, and successive reads of it must not look
            // like successive recreations.
            return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier,
                                                   instanceEpoch: PersistedState.absentFileEpoch),
                             needsRewrite: false)
        }
        do {
            var state = try JSONDecoder().decode(PersistedState.self, from: data)
            // A valid old-boot registry is safely replaced, never revived.
            // Unlike the ENOENT/empty cases above this genuinely IS a new
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
                try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
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
                try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
                return StateRead(state: state, needsRewrite: true)
            }
            try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
            return StateRead(state: state, needsRewrite: false)
        } catch let error as CoordinatorError { throw error
        } catch { throw CoordinatorError.malformedState }
    }

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState.
    func writeState(_ state: PersistedState, held: HeldLock) throws {
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

    // internal: SuspensionLeaseCoordinator.init() calls this when no boot
    // session id override is supplied.
    static func currentBootSessionIdentifier() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size else { return nil }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }

    // internal: SuspensionLeaseCoordinator.acquireLease() calls this to mint
    // a new lease token.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // internal: SuspensionLeaseCoordinator.releaseLease() and .validateState()
    // call this to validate tokens.
    static func isCanonicalToken(_ token: String) -> Bool {
        token.count == 43 && token.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_"
        }
    }
#elseif os(Windows)
    // internal: SuspensionLeaseCoordinator.swift's withLockedState and
    // withLockedPresentationState hold a `HeldLock` across their body
    // closures and read its `directoryFD`.
    //
    // `directoryFD` here is NOT opened by `acquireLock()` -- it is a
    // long-lived handle to `storageDirectory`, opened once per distinct
    // directory path and cached for the rest of the process's life (see
    // `openSecureDirectory()` below). `descriptor` is the per-operation
    // handle to the lock file, opened and byte-range-locked fresh by every
    // `acquireLock()` call, exactly like the macOS branch's `descriptor`.
    struct HeldLock {
        let directoryFD: HANDLE
        let descriptor: HANDLE

        func release() {
            var overlapped = OVERLAPPED()
            _ = UnlockFileEx(descriptor, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped)
            CloseHandle(descriptor)
            // `directoryFD` is the shared, process-lifetime cached handle --
            // see `openSecureDirectory()` -- and outlives this `HeldLock`, so
            // it is deliberately not closed here.
        }
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
    private static let maximumSerializedBytes = 65_536

    // Guards `cachedDirectoryHandles` below. A plain NSLock, not `stateLock`
    // (that one lives on the coordinator instance and guards the in-memory
    // snapshot, an unrelated concern) -- this one is static because the
    // cache itself is process-wide, shared by every `SuspensionLeaseCoordinator`
    // instance that happens to point at the same directory path (the test
    // suite routinely constructs several coordinators against one shared
    // temporary directory to model multiple Chalkboard processes).
    private static let directoryHandleLock = NSLock()
    // internal: process-lifetime cache of validated directory handles,
    // keyed by `storageDirectory.path`. See `openSecureDirectory()`'s doc
    // comment for why this exists and what it does and does not prove.
    private static var cachedDirectoryHandles: [String: HANDLE] = [:]

    // MARK: - Hardened storage

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState.
    func acquireLock() throws -> HeldLock {
        let directoryHandle = try openSecureDirectory()
        let descriptor = try openValidatedRegularFile(named: Self.lockName, create: true)
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
                throw CoordinatorError.unavailable("AI Chalkboard could not lock suspension state (Win32 error \(lastError)).")
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                CloseHandle(descriptor)
                throw CoordinatorError.unavailable("Another annotation suspension operation is still in progress.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let held = HeldLock(directoryFD: directoryHandle, descriptor: descriptor)
        do {
            try validateHeldDirectory(held)
            try validateHeldLock(held)
        } catch {
            var overlapped = OVERLAPPED()
            _ = UnlockFileEx(descriptor, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped)
            CloseHandle(descriptor)
            throw error
        }
        return held
    }

    /// Opens (creating if necessary) and validates `storageDirectory`, then
    /// caches the resulting handle for the rest of the process's life,
    /// keyed by path.
    ///
    /// TOCTOU HARDENING -- WEAKER THAN macOS, DOCUMENTED PRECISELY: macOS's
    /// `openSecureDirectory()`/`validateHeldDirectory()` open the directory
    /// once *relative to its already-validated parent* (`openat`/`fstatat`),
    /// so no step after the parent is opened ever re-resolves a path
    /// component an attacker could have swapped out from under it. Win32
    /// has no public directory-relative open (`openat`'s equivalent is an
    /// undocumented native NT API, not part of the surface WinSDK exposes),
    /// so every lock/state file open in this file is unavoidably PATH-based
    /// and re-resolves `storageDirectory`'s path components fresh, through
    /// the ordinary filesystem namespace, on every single call.
    ///
    /// The mitigation actually used here is a HANDLE IDENTITY RE-CHECK, not
    /// re-resolution avoidance: this directory is opened and fully validated
    /// (real directory, not a reparse point, owned by the current user) only
    /// ONCE per path, and that handle is kept open and cached for the
    /// process's lifetime. A Windows handle -- like a POSIX fd -- follows the
    /// underlying file object across a rename, not the path string used to
    /// open it, so this cached handle's own identity can never silently
    /// become "some other directory" out from under it. Every subsequent
    /// operation (`validateHeldDirectory`, called from `acquireLock()` and
    /// `validateHeldLock()`) re-resolves `storageDirectory.path` fresh and
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
            throw CoordinatorError.unavailable("AI Chalkboard could not create its private suspension-state directory (Win32 error \(GetLastError())).")
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
            throw CoordinatorError.unavailable("AI Chalkboard could not open its private suspension-state directory (Win32 error \(GetLastError())).")
        }
        guard let info = Self.fileInformation(ofOpenHandle: handle),
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0,
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0 else {
            CloseHandle(handle)
            throw CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state directory.")
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

    private func validateHeldDirectory(_ held: HeldLock) throws {
        guard let handleInfo = Self.fileInformation(ofOpenHandle: held.directoryFD),
              (handleInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0,
              (handleInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0 else {
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state directory; overlays remain hidden.")
        }
        // See `openSecureDirectory()`'s doc comment: this re-resolves the
        // path fresh, right now, and requires the SAME identity as the
        // cached handle validated when this directory was first opened.
        guard let pathInfo = Self.fileInformation(atPath: storageDirectory.path, openReparsePoint: true),
              (pathInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0,
              handleInfo.dwVolumeSerialNumber == pathInfo.dwVolumeSerialNumber,
              handleInfo.nFileIndexHigh == pathInfo.nFileIndexHigh,
              handleInfo.nFileIndexLow == pathInfo.nFileIndexLow else {
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-state directory; overlays remain hidden.")
        }
        // Re-checked on every call, matching macOS's `descriptorInfo.st_uid
        // == getuid()` re-check in its own `validateHeldDirectory` -- see
        // `validateOwnerIsCurrentUser`'s doc comment for exactly what this
        // does and does not prove on Windows.
        try Self.validateOwnerIsCurrentUser(held.directoryFD)
    }

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState to re-validate around body execution
    // and after the durable write.
    func validateHeldLock(_ held: HeldLock) throws {
        try validateHeldDirectory(held)
        guard let descriptorInfo = Self.fileInformation(ofOpenHandle: held.descriptor) else {
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
        let lockPath = storageDirectory.appendingPathComponent(Self.lockName).path
        guard let pathInfo = Self.fileInformation(atPath: lockPath, openReparsePoint: true) else {
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
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
            throw CoordinatorError.unavailable("AI Chalkboard detected a replaced suspension-operation lock; annotations remain hidden.")
        }
    }

    private func openValidatedRegularFile(named name: String, create: Bool) throws -> HANDLE {
        let fullPath = storageDirectory.appendingPathComponent(name).path
        // OPEN_ALWAYS ("create if missing, else open the existing file
        // without truncating it") is atomic in a single Win32 call, unlike
        // POSIX O_CREAT|O_EXCL -- there is no equivalent here to macOS's
        // O_EXCL-loser re-inspect-and-reopen dance above, because there is
        // no race to resolve: two processes racing OPEN_ALWAYS both get a
        // handle to whichever file the filesystem settles on, atomically.
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
            let role = name == Self.lockName ? "suspension-operation lock" : "suspension lease state"
            throw CoordinatorError.unavailable("AI Chalkboard could not open its \(role) (Win32 error \(GetLastError())).")
        }
        guard let info = Self.fileInformation(ofOpenHandle: fd),
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) == 0,
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) == 0,
              // See `validateHeldLock`'s comment: nNumberOfLinks == 1 rejects
              // a hard-linked replacement, matching macOS's st_nlink check.
              info.nNumberOfLinks == 1 else {
            CloseHandle(fd)
            throw CoordinatorError.unavailable("AI Chalkboard refused an unsafe suspension-state file.")
        }
        return fd
    }

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState.
    func readState(in directoryFD: HANDLE, bootSessionIdentifier: String) throws -> StateRead {
        let statePath = storageDirectory.appendingPathComponent(Self.stateName).path
        guard Self.fileInformation(atPath: statePath, openReparsePoint: true) != nil else {
            let lastError = GetLastError()
            // ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND is this platform's
            // ENOENT. A missing (and, below, an empty) file is synthesized
            // with the STABLE `absentFileEpoch` sentinel rather than a fresh
            // UUID: repeated reads of the same absent file must be
            // indistinguishable, or the generation ratchet resets on every
            // reconcile tick. It is still an identity, though, so a registry
            // that disappears mid-session reads as a real epoch change and
            // resets the ratchet exactly once. See `PersistedState.instanceEpoch`.
            if lastError == DWORD(ERROR_FILE_NOT_FOUND) || lastError == DWORD(ERROR_PATH_NOT_FOUND) {
                return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier,
                                                       instanceEpoch: PersistedState.absentFileEpoch),
                                 needsRewrite: false)
            }
            throw CoordinatorError.unavailable("AI Chalkboard could not inspect suspension lease state (Win32 error \(lastError)).")
        }
        let fd = try openValidatedRegularFile(named: Self.stateName, create: false)
        defer { CloseHandle(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            var bytesRead: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
                ReadFile(fd, rawBuffer.baseAddress, DWORD(rawBuffer.count), &bytesRead, nil)
            }
            guard ok else { throw CoordinatorError.unavailable("AI Chalkboard could not read suspension lease state (Win32 error \(GetLastError())).") }
            if bytesRead == 0 { break }
            data.append(buffer, count: Int(bytesRead))
            guard data.count <= Self.maximumSerializedBytes else { throw CoordinatorError.malformedState }
        }
        guard !data.isEmpty else {
            // Same sentinel as the not-found branch above: an empty file
            // carries no identity of its own, and successive reads of it
            // must not look like successive recreations.
            return StateRead(state: PersistedState(bootSessionIdentifier: bootSessionIdentifier,
                                                   instanceEpoch: PersistedState.absentFileEpoch),
                             needsRewrite: false)
        }
        do {
            var state = try JSONDecoder().decode(PersistedState.self, from: data)
            // A valid old-boot registry is safely replaced, never revived.
            // Unlike the not-found/empty cases above this genuinely IS a new
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
                try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
                return StateRead(state: state, needsRewrite: true)
            }
            // An EXISTING same-boot file whose optional `instanceEpoch`
            // decoded as nil -- written by a build that predates the field, or
            // before the epoch was minted at persist time -- must be upgraded
            // exactly once here. See the macOS branch's identical comment for
            // the full reasoning; it is platform-independent.
            if state.instanceEpoch == nil {
                state.instanceEpoch = UUID().uuidString
                try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
                return StateRead(state: state, needsRewrite: true)
            }
            try Self.validateState(state, bootSessionIdentifier: bootSessionIdentifier)
            return StateRead(state: state, needsRewrite: false)
        } catch let error as CoordinatorError { throw error
        } catch { throw CoordinatorError.malformedState }
    }

    // internal: called by SuspensionLeaseCoordinator.swift's withLockedState
    // and withLockedPresentationState.
    func writeState(_ state: PersistedState, held: HeldLock) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumSerializedBytes else { throw CoordinatorError.malformedState }
        let temporaryName = ".annotations-suspension-v3.\(UUID().uuidString).tmp"
        let temporaryPath = storageDirectory.appendingPathComponent(temporaryName).path
        let finalPath = storageDirectory.appendingPathComponent(Self.stateName).path

        let rawHandle: HANDLE? = temporaryPath.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(widePath, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ),
                        nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let fd = rawHandle, fd != INVALID_HANDLE_VALUE else {
            throw CoordinatorError.unavailable("AI Chalkboard could not create temporary suspension state (Win32 error \(GetLastError())).")
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
                guard ok, bytesWritten > 0 else { throw CoordinatorError.unavailable("AI Chalkboard could not write suspension state (Win32 error \(GetLastError())).") }
                offset += Int(bytesWritten)
            }
        }
        guard FlushFileBuffers(fd) else { throw CoordinatorError.unavailable("AI Chalkboard could not sync suspension state (Win32 error \(GetLastError())).") }
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
        storagePrecommitHook?()
        try validateHeldLock(held)
        // MoveFileExW with MOVEFILE_REPLACE_EXISTING is NTFS's atomic
        // rename-onto-existing-name, the same durability/atomicity property
        // POSIX renameat gives macOS above.
        let moved = temporaryPath.withCString(encodedAs: UTF16.self) { wideSrc in
            finalPath.withCString(encodedAs: UTF16.self) { wideDst in
                MoveFileExW(wideSrc, wideDst, DWORD(MOVEFILE_REPLACE_EXISTING))
            }
        }
        guard moved else {
            throw CoordinatorError.unavailable("AI Chalkboard could not install suspension state (Win32 error \(GetLastError())).")
        }
        installed = true
        // WINDOWS NOTE: macOS additionally fsyncs `held.directoryFD` here to
        // flush the rename's directory-entry metadata. `held.directoryFD` on
        // Windows is the process-lifetime cached handle from
        // `openSecureDirectory()`, opened with GENERIC_READ only (it is used
        // solely for identity checks, never for writes), so FlushFileBuffers
        // cannot be called on it -- Win32 requires a handle opened with
        // write access. There is no separate directory-metadata flush to
        // perform here in any case: NTFS journals rename operations as part
        // of its own metadata transaction log, and the temp file's data was
        // already flushed above before this rename ran, so the durability
        // this call would add on macOS is provided here by NTFS's own
        // journaling of the MoveFileExW transaction instead.
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
    /// process is running as, the Windows analogue of macOS's
    /// `info.st_uid == getuid()` checks above.
    ///
    /// OWNERSHIP HARDENING -- WEAKER THAN macOS, DOCUMENTED PRECISELY: macOS's
    /// `(info.st_mode & 0o022) == 0` / `(info.st_mode & 0o777) == 0o700`
    /// checks prove something POSIX mode bits make cheap to prove: that NO
    /// OTHER PRINCIPAL ON THE SYSTEM -- not the owner's own group, not
    /// "other" -- has write access to this directory, because write
    /// permission for every principal except the owner is encoded directly
    /// in the three mode-bit fields being checked. Windows access control
    /// (DACLs, an ordered list of per-principal ALLOW/DENY access control
    /// entries, evaluated against arbitrary security groups) has no
    /// equivalent fixed-width encoding to check three bits against. This
    /// function proves only OWNERSHIP: that the SID recorded as this
    /// object's owner is the SID of the user this process is running as
    /// (via GetSecurityInfo's OWNER_SECURITY_INFORMATION and
    /// OpenProcessToken+GetTokenInformation(TokenUser), compared with
    /// EqualSid). It deliberately does NOT walk the DACL to prove no other
    /// principal has been granted write access -- e.g. a misconfigured
    /// inherited ACE granting Everyone or a custom group Modify rights on
    /// this specific directory would pass this check even though it defeats
    /// the isolation the check exists to provide. What this DOES prove: an
    /// attacker who is not running as this same Windows user account cannot
    /// have created, and cannot silently replace, the directory this
    /// process is about to trust, absent a separate DACL misconfiguration.
    /// What it does NOT prove: that no other principal on the machine has
    /// been granted write access to it. A full DACL audit (enumerating every
    /// ACE, resolving group membership, and rejecting anything broader than
    /// the owner) is not implemented here.
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
            throw CoordinatorError.unavailable("AI Chalkboard could not determine the suspension-state directory's owner.")
        }
        defer { LocalFree(securityDescriptor) }

        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else {
            throw CoordinatorError.unavailable("AI Chalkboard could not open its own process token.")
        }
        defer { CloseHandle(token) }

        var requiredSize: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &requiredSize)
        guard requiredSize > 0 else {
            throw CoordinatorError.unavailable("AI Chalkboard could not size its own user token.")
        }
        var tokenBuffer = [UInt8](repeating: 0, count: Int(requiredSize))
        // `EqualSid` runs INSIDE this closure, not after it returns: the SID
        // pointer `TOKEN_USER.User.Sid` exposes points into `tokenBuffer`'s
        // own storage, and that pointer must never be used once the buffer
        // it points into could have been deallocated.
        let isSameOwner: Bool = try tokenBuffer.withUnsafeMutableBytes { rawBuffer in
            guard GetTokenInformation(token, TokenUser, rawBuffer.baseAddress, requiredSize, &requiredSize) else {
                throw CoordinatorError.unavailable("AI Chalkboard could not read its own user token.")
            }
            let tokenUser = rawBuffer.load(as: TOKEN_USER.self)
            guard let userSid = tokenUser.User.Sid, IsValidSid(userSid) else { return false }
            return EqualSid(ownerSid, userSid)
        }
        guard isSameOwner else {
            throw CoordinatorError.unavailable("AI Chalkboard refused a suspension-state directory owned by another Windows account.")
        }
    }

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

    // internal: SuspensionLeaseCoordinator.acquireLease() calls this to mint
    // a new lease token. Identical to the macOS branch: token minting uses
    // only cross-platform Foundation APIs (SystemRandomNumberGenerator,
    // Data, base64), so there is nothing platform-specific to change here --
    // this is a plain duplicate, kept in this branch rather than factored
    // out, so the macOS implementation above stays untouched and
    // self-contained per file.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // internal: SuspensionLeaseCoordinator.releaseLease() and .validateState()
    // call this to validate tokens. Identical to the macOS branch -- see
    // `makeToken()`'s comment above.
    static func isCanonicalToken(_ token: String) -> Bool {
        token.count == 43 && token.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_"
        }
    }
#endif
}
