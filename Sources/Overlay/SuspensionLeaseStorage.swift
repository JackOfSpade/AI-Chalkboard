import Foundation
import Darwin

// The hardened POSIX/persistence layer for `SuspensionLeaseCoordinator`'s
// durable registry: directory and lock-file acquisition hardened against
// symlink and ownership attacks, TOCTOU-safe inode verification, and atomic
// state read/write. This file contains no lease business logic -- see
// `SuspensionLeaseCoordinator.swift` for the public API and state machine.
extension SuspensionLeaseCoordinator {
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
}
