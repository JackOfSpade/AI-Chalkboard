import Foundation
import XCTest
@testable import AIChalkboardCore

final class SuspensionLeaseCoordinatorTests: XCTestCase {
    /// `SuspensionLeaseCoordinator.withPresentationPermit(_:)` preconditions
    /// on `MainThread.isCurrentUIThread` (see that method's doc comment):
    /// production code only ever reaches it from the platform's real UI
    /// thread. On macOS that thread genuinely is the process's main thread,
    /// which is also the thread XCTest runs test methods on by default, so
    /// a test can call it directly. On Windows the UI thread is
    /// `WindowsUIThread` -- a dedicated thread distinct from whatever thread
    /// runs the test -- so calling `withPresentationPermit` directly from a
    /// test body trips the precondition and crashes the whole test process
    /// (confirmed: this is exactly what happened before this helper was
    /// added). This runs `body` on the real Windows UI thread to match what
    /// a production caller (e.g. `OverlayWindowController`'s Windows
    /// `setAnnotationsSuspended`) actually does; on macOS it is a no-op
    /// pass-through since the test is already on the right thread.
    private func runOnPlatformUIThread<T>(_ body: () -> T) -> T {
        #if os(macOS)
        return body()
        #elseif os(Windows)
        WindowsUIThread.shared.start()
        return WindowsUIThread.shared.sync(body)
        #endif
    }

    private func withTemporaryCoordinator(_ body: (SuspensionLeaseCoordinator, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Windows has no POSIX mode bits: the Windows storage layer hardens
        // this directory by owner SID rather than by 0o700 (see
        // SuspensionLeaseStorage.swift's `validateOwnerIsCurrentUser` for
        // what that does and does not prove), and a freshly created temp
        // directory is already owned by the current user, so there is
        // nothing to set here on that platform.
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SuspensionLeaseCoordinator(storageDirectory: directory), directory)
    }

    func testOverlappingLeasesIdempotentRetryAndExactRelease() throws {
        try withTemporaryCoordinator { coordinator, _ in
            XCTAssertFalse(coordinator.bootstrapAndReconcile().annotationsSuspended)

            let idempotencyKey = "a0b1c2d3-e4f5-4a6b-8c9d-0e1f2a3b4c5d"
            let first = coordinator.acquireLease(seconds: 60, idempotencyKey: idempotencyKey)
            let firstToken = try XCTUnwrap(first.leaseToken)
            XCTAssertTrue(first.success)
            XCTAssertFalse(first.reused)
            XCTAssertTrue(first.annotationsSuspended)
            XCTAssertEqual(first.activeLeaseCount, 1)

            let retry = coordinator.acquireLease(seconds: 60, idempotencyKey: idempotencyKey)
            XCTAssertTrue(retry.success)
            XCTAssertTrue(retry.reused)
            XCTAssertEqual(retry.leaseToken, firstToken)
            XCTAssertEqual(retry.activeLeaseCount, 1, "a retried idempotency key must not mint a second lease")
            XCTAssertEqual(retry.generation, first.generation, "a read-only retry must not create a state transition")

            let second = coordinator.acquireLease(seconds: 60)
            let secondToken = try XCTUnwrap(second.leaseToken)
            XCTAssertNotEqual(secondToken, firstToken)
            XCTAssertEqual(second.activeLeaseCount, 2)

            let releasedFirst = coordinator.releaseLease(token: firstToken)
            XCTAssertTrue(releasedFirst.success)
            XCTAssertFalse(releasedFirst.alreadyReleased)
            XCTAssertTrue(releasedFirst.annotationsSuspended, "the other client's lease must keep annotations hidden")
            XCTAssertEqual(releasedFirst.activeLeaseCount, 1)

            let releasedSecond = coordinator.releaseLease(token: secondToken)
            XCTAssertTrue(releasedSecond.success)
            XCTAssertFalse(releasedSecond.annotationsSuspended)
            XCTAssertEqual(releasedSecond.activeLeaseCount, 0)

            let cleanupRetry = coordinator.releaseLease(token: firstToken)
            XCTAssertTrue(cleanupRetry.success, "a lost response may safely retry the exact cleanup token")
            XCTAssertTrue(cleanupRetry.alreadyReleased)
            XCTAssertFalse(cleanupRetry.annotationsSuspended)
        }
    }

    // Windows has no POSIX mode bits, so there is no Windows analogue of
    // "repair a pre-existing 0o755 directory to 0o700" -- the equivalent
    // Windows hardening is ownership (SID), not mode, and is exercised by
    // the cross-platform tests above/below instead. See
    // SuspensionLeaseStorage.swift's `validateOwnerIsCurrentUser` doc
    // comment for what the Windows ownership check does and does not prove.
    #if os(macOS)
    func testBootstrapSecuresPreexistingNonWritableSupportDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseCoordinatorLegacyModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = SuspensionLeaseCoordinator(storageDirectory: directory)
        let bootstrap = coordinator.bootstrapAndReconcile()
        XCTAssertTrue(bootstrap.isBootstrapped)
        XCTAssertNil(bootstrap.error)
        XCTAssertFalse(bootstrap.annotationsSuspended)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let acquired = coordinator.acquireLease(seconds: 60)
        let token = try XCTUnwrap(acquired.leaseToken)
        XCTAssertTrue(acquired.success)
        XCTAssertTrue(acquired.annotationsSuspended)
        XCTAssertTrue(coordinator.releaseLease(token: token).success)
    }

    func testGroupOrWorldWritableSupportDirectoryStillFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseCoordinatorWritableModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bootstrap = SuspensionLeaseCoordinator(storageDirectory: directory).bootstrapAndReconcile()
        XCTAssertFalse(bootstrap.isBootstrapped)
        XCTAssertTrue(bootstrap.annotationsSuspended)
        XCTAssertNotNil(bootstrap.error)
    }
    #endif

    /// AppDelegate starts MCP from the asynchronous bootstrap completion, so
    /// a bad registry must still invoke that hand-off on the platform UI
    /// thread. Otherwise a secure fail-closed startup would turn into an
    /// invisible process that never reads its stdio transport at all.
    func testAsyncBootstrapCompletionRunsForFailClosedRegistry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardAsyncBootstrapFailureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        let coordinator = SuspensionLeaseCoordinator(storageDirectory: root)
        let completion = expectation(description: "async bootstrap completes even on registry failure")
        var completedSnapshot: SuspensionLeaseSnapshot?
        coordinator.bootstrapAndReconcileAsynchronously { snapshot in
            XCTAssertTrue(MainThread.isCurrentUIThread)
            completedSnapshot = snapshot
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        let snapshot = try XCTUnwrap(completedSnapshot)
        XCTAssertFalse(snapshot.isBootstrapped)
        XCTAssertTrue(snapshot.annotationsSuspended)
        XCTAssertNotNil(snapshot.error)
    }

    func testExpiryCreatesTombstoneAndCannotLeaveLeaseSuspended() throws {
        try withTemporaryCoordinator { coordinator, _ in
            _ = coordinator.bootstrapAndReconcile()
            let acquired = coordinator.acquireLease(seconds: 1)
            let token = try XCTUnwrap(acquired.leaseToken)
            XCTAssertTrue(acquired.annotationsSuspended)

            // This is intentionally just beyond the shortest externally
            // permitted lease. Reconcile is the deterministic unit-level
            // trigger; process integration covers the scheduled timer path.
            Thread.sleep(forTimeInterval: 1.15)
            let afterExpiry = coordinator.reconcile()
            XCTAssertFalse(afterExpiry.annotationsSuspended)
            XCTAssertEqual(afterExpiry.activeLeaseCount, 0)

            let releaseAfterExpiry = coordinator.releaseLease(token: token)
            XCTAssertTrue(releaseAfterExpiry.success)
            XCTAssertTrue(releaseAfterExpiry.alreadyReleased)
        }
    }

    func testOldBootRegistryIsResetRatherThanRevivingFutureUptimeLease() throws {
        try withTemporaryCoordinator { coordinator, directory in
            let token = String(repeating: "A", count: 43)
            let persisted: [String: Any] = [
                "schemaVersion": 4,
                "bootSessionIdentifier": "prior-boot-session",
                "generation": 999,
                "lastUpdatedUptime": ProcessInfo.processInfo.systemUptime + 86_400,
                "leases": [[
                    "token": token,
                    "ownerPID": 1,
                    "ownerInstanceNonce": "prior-process",
                    "expiresAtUptime": ProcessInfo.processInfo.systemUptime + 172_800,
                    "idempotencyKey": NSNull(),
                ]],
                "idempotencyTokens": [:],
                "releasedTokens": [:],
            ]
            let data = try JSONSerialization.data(withJSONObject: persisted)
            try data.write(to: directory.appendingPathComponent("annotations-suspension-v3.json"))

            let restored = coordinator.bootstrapAndReconcile()
            XCTAssertTrue(restored.isBootstrapped)
            XCTAssertFalse(restored.annotationsSuspended, "a future uptime proves this registry is from a prior boot")
            XCTAssertEqual(restored.activeLeaseCount, 0)
            XCTAssertLessThan(restored.generation, 999)
        }
    }

    func testStaleGenerationHintNeverRollsBackCanonicalNewerState() throws {
        try withTemporaryCoordinator { coordinator, _ in
            _ = coordinator.bootstrapAndReconcile()
            let acquired = coordinator.acquireLease(seconds: 60)
            let token = try XCTUnwrap(acquired.leaseToken)
            let released = coordinator.releaseLease(token: token)
            XCTAssertFalse(released.annotationsSuspended)
            XCTAssertGreaterThan(released.generation, acquired.generation)

            let afterDelayedOldPacket = coordinator.reconcile(announcedGeneration: acquired.generation)
            XCTAssertFalse(afterDelayedOldPacket.annotationsSuspended)
            XCTAssertEqual(afterDelayedOldPacket.generation, released.generation)
            XCTAssertEqual(afterDelayedOldPacket.activeLeaseCount, 0)
        }
    }

    // Symbolic-link creation on Windows requires either Developer Mode or an
    // elevated/SeCreateSymbolicLinkPrivilege process, neither of which a
    // normal CI/test run can assume, so this test's symlink-swap scenario
    // is macOS-only. The Windows storage layer applies the equivalent
    // FILE_FLAG_OPEN_REPARSE_POINT ("this platform's O_NOFOLLOW") defense to
    // both the directory and the lock/state files -- see
    // SuspensionLeaseStorage.swift's `openSecureDirectory()` and
    // `openValidatedRegularFile()` doc comments -- but it is not exercised
    // by an automated test here. The hard-linked-replacement half of this
    // same defense-in-depth IS covered cross-platform, by
    // `testHardLinkedReplacementLockFailsClosed` below.
    #if os(macOS)
    func testUnsafeCoordinatorDirectoryAndLockFilesFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseCoordinatorUnsafeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A file where the private directory must be is not repaired or used.
        try Data("not a directory".utf8).write(to: root)
        let badDirectory = SuspensionLeaseCoordinator(storageDirectory: root).bootstrapAndReconcile()
        XCTAssertFalse(badDirectory.isBootstrapped)
        XCTAssertTrue(badDirectory.annotationsSuspended)
        XCTAssertNotNil(badDirectory.error)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let outside = root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        let lock = root.appendingPathComponent("annotations-suspension-v3.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        let symlinkLock = SuspensionLeaseCoordinator(storageDirectory: root).bootstrapAndReconcile()
        XCTAssertFalse(symlinkLock.isBootstrapped)
        XCTAssertTrue(symlinkLock.annotationsSuspended)
        XCTAssertNotNil(symlinkLock.error)
    }
    #endif

    // Hard links (unlike symlinks) need no elevated privilege to create on
    // NTFS, and Windows exposes the same link-count concept POSIX does
    // (`BY_HANDLE_FILE_INFORMATION.nNumberOfLinks`, the analogue of
    // `st_nlink`), so this test's coverage carries over unchanged -- see
    // SuspensionLeaseStorage.swift's `openValidatedRegularFile()` and
    // `validateHeldLock()`.
    //
    // WINDOWS NOTE, discovered by actually running this test: on this
    // toolchain, `FileManager.linkItem(at:to:)` on Windows fails with the
    // exact same `ERROR_PRIVILEGE_NOT_HELD` (Win32 error 1314) this file's
    // `testUnsafeCoordinatorDirectoryAndLockFilesFailClosed` symlink case
    // hits on a machine without Developer Mode/elevation, matching
    // `InstanceLockTests.testReparsePointLockPathCannotLockItsTarget`'s
    // already-established skip pattern for the identical underlying
    // limitation. This is an environment/toolchain limitation of creating
    // the fixture, not a defect in `validateHeldLock()`'s own hard-link
    // rejection logic (untouched, still exercised whenever the fixture can
    // actually be created).
    func testHardLinkedReplacementLockFailsClosed() throws {
        try withTemporaryCoordinator { _, directory in
            let source = directory.appendingPathComponent("replacement-source")
            let lock = directory.appendingPathComponent("annotations-suspension-v3.lock")
            try Data("ordinary file".utf8).write(to: source)
            do {
                try FileManager.default.linkItem(at: source, to: lock)
            } catch {
                throw XCTSkip("Creating a hard link requires Developer Mode or elevation on this machine (\(error)); cannot exercise the replaced-lock path here.")
            }

            let snapshot = SuspensionLeaseCoordinator(storageDirectory: directory).bootstrapAndReconcile()
            XCTAssertFalse(snapshot.isBootstrapped)
            XCTAssertTrue(snapshot.annotationsSuspended)
            XCTAssertNotNil(snapshot.error, "a hard-linked/replaced lock inode must be rejected")
        }
    }

    func testStaleApplyCannotRegressCachedSnapshot() throws {
        try withTemporaryCoordinator { coordinator, _ in
            let newest = coordinator.testOnlyRecordAndApply(generation: 10, suspended: true)
            XCTAssertEqual(newest.generation, 10)
            let staleReturn = coordinator.testOnlyRecordAndApply(generation: 9, suspended: false)
            XCTAssertEqual(staleReturn.generation, 10)
            XCTAssertTrue(staleReturn.annotationsSuspended)
            XCTAssertEqual(coordinator.snapshot(), newest)
        }
    }

    /// The generation ratchet must reject a STALE read (same file, older
    /// generation) but must NOT reject a RECREATED file, which legitimately
    /// restarts at generation 0. Deleting the registry without rebooting used
    /// to freeze the cached snapshot -- including annotationsSuspended -- on
    /// stale data for an unbounded number of operations, because generation
    /// alone cannot tell those two cases apart.
    func testRecreatedRegistryEpochResetsTheGenerationRatchet() throws {
        try withTemporaryCoordinator { coordinator, _ in
            let high = coordinator.testOnlyRecordAndApply(generation: 42, suspended: true,
                                                          instanceEpoch: "epoch-one")
            XCTAssertEqual(high.generation, 42)
            XCTAssertTrue(high.annotationsSuspended)

            // Same file, older generation: still rejected.
            let stale = coordinator.testOnlyRecordAndApply(generation: 7, suspended: false,
                                                           instanceEpoch: "epoch-one")
            XCTAssertEqual(stale.generation, 42, "a stale read of the same file must not regress the cache")
            XCTAssertTrue(stale.annotationsSuspended)

            // A different file (deleted and recreated) starting over at 0:
            // must be accepted, or the cache stays frozen on data that no
            // longer exists anywhere.
            let recreated = coordinator.testOnlyRecordAndApply(generation: 0, suspended: false,
                                                               instanceEpoch: "epoch-two")
            XCTAssertEqual(recreated.generation, 0, "a recreated registry must reset the high-water mark")
            XCTAssertFalse(recreated.annotationsSuspended,
                           "the recreated registry holds no leases, so annotations must not stay suspended")
            XCTAssertEqual(coordinator.snapshot(), recreated)
        }
    }

    /// The absent registry file has to satisfy two opposing requirements at
    /// once, and this pins both halves.
    ///
    /// SELF-HEAL: a mark left behind by a registry file that has since been
    /// deleted (manual troubleshooting, a reset step, a reaped temp root)
    /// describes a file that no longer exists, so it must not be allowed to
    /// reject the generation-0 state that is now the truth -- otherwise
    /// `cachedSnapshot` stays `annotationsSuspended` forever and only an
    /// explicit acquire/release ever recovers.
    ///
    /// STABILITY: yet a state synthesized on EVERY read must not look like a
    /// NEWLY recreated file each time, or AppDelegate's 2 Hz reconcile zeroes
    /// the ratchet -- and re-applies presentation -- twice a second.
    ///
    /// The stable `absentFileEpoch` sentinel satisfies both: the transition
    /// into it fires the reset exactly once, and every later read compares
    /// equal.
    func testReconcileWithNoRegistryFileNeverRollsBackTheGenerationRatchet() throws {
        try withTemporaryCoordinator { coordinator, directory in
            let established = coordinator.testOnlyRecordAndApply(generation: 5, suspended: true,
                                                                 instanceEpoch: "epoch-one")
            XCTAssertEqual(established.generation, 5)
            XCTAssertTrue(established.annotationsSuspended)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("annotations-suspension-v3.json").path
                ),
                "this test is specifically about a registry file that is not there"
            )

            // The file backing generation 5 is gone, so the mark it left must
            // be released exactly once and the real, empty state applied.
            let healed = coordinator.reconcile()
            XCTAssertEqual(healed.generation, 0,
                           "a real epoch -> absent-file transition must reset the high-water mark")
            XCTAssertFalse(healed.annotationsSuspended,
                           "there is no registry and therefore no lease; the overlays must come back")

            // ...and it must stay released-once: further reads of the SAME
            // absent file are indistinguishable from each other.
            XCTAssertEqual(coordinator.reconcile(), healed,
                           "two successive reads of the same missing file must be indistinguishable")
            XCTAssertEqual(coordinator.reconcile(), healed)
            XCTAssertEqual(coordinator.snapshot(), healed)

            // Sharper than equality of two generation-0 snapshots: raise the
            // mark to 3 while keeping the absent file's own identity, then read
            // that same absent file again. A per-read epoch would look like
            // another recreation, reset the mark, and apply generation 0; the
            // stable sentinel leaves the ratchet doing its job.
            let raised = coordinator.testOnlyRecordAndApply(
                generation: 3, suspended: true,
                instanceEpoch: SuspensionLeaseCoordinator.PersistedState.absentFileEpoch
            )
            XCTAssertEqual(raised.generation, 3)
            XCTAssertEqual(coordinator.reconcile(), raised,
                           "the absent file must keep ONE identity, or the ratchet is zeroed on every tick")
        }
    }

    /// A same-boot registry written by a build that predates `instanceEpoch`
    /// decodes with nil, which permanently disables the ratchet reset for the
    /// rest of the boot. `readState` upgrades it in place instead -- once. This
    /// is the only storage-layer path that mints an epoch for an EXISTING file,
    /// and it is invisible from the in-memory `testOnlyRecordAndApply*` seams.
    func testExistingRegistryWithoutAnEpochIsUpgradedOnDiskExactlyOnce() throws {
        try withTemporaryCoordinator { coordinator, directory in
            let bootSession = try XCTUnwrap(SuspensionLeaseCoordinator.currentBootSessionIdentifier())
            let stateURL = directory.appendingPathComponent("annotations-suspension-v3.json")
            let persisted: [String: Any] = [
                "schemaVersion": 4,
                "bootSessionIdentifier": bootSession,
                "generation": 7,
                "lastUpdatedUptime": ProcessInfo.processInfo.systemUptime,
                "leases": [],
                "idempotencyTokens": [:],
                "releasedTokens": [:],
                // `instanceEpoch` is deliberately ABSENT: that is the shape a
                // pre-epoch build left behind.
            ]
            try JSONSerialization.data(withJSONObject: persisted).write(to: stateURL)

            func onDisk() throws -> [String: Any] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
            }

            let upgraded = coordinator.reconcile()
            let afterFirst = try onDisk()
            let mintedEpoch = try XCTUnwrap(afterFirst["instanceEpoch"] as? String,
                                            "the upgrade must be durable, not a process-local interpretation")
            XCTAssertFalse(mintedEpoch.isEmpty)
            XCTAssertEqual(afterFirst["generation"] as? Int, 8,
                           "the rewrite is a state transition and must advance the generation by exactly one")
            XCTAssertEqual(upgraded.generation, 8)

            // Nothing is left to upgrade, and `prune` on a lease-free state
            // reports no change, so a second reconcile must not rewrite.
            let second = coordinator.reconcile()
            let afterSecond = try onDisk()
            XCTAssertEqual(afterSecond["instanceEpoch"] as? String, mintedEpoch,
                           "a second read must not re-mint the epoch")
            XCTAssertEqual(afterSecond["generation"] as? Int, 8,
                           "a second read must not rewrite the file")
            XCTAssertEqual(second.generation, 8)
        }
    }

    /// A registry written before `instanceEpoch` existed decodes with nil.
    /// That must degrade to exactly the old ratchet behaviour rather than
    /// resetting on every read (which would defeat the ratchet entirely).
    func testMissingEpochNeverResetsTheRatchet() throws {
        try withTemporaryCoordinator { coordinator, _ in
            _ = coordinator.testOnlyRecordAndApplyWithoutEpoch(generation: 20, suspended: true)
            let stale = coordinator.testOnlyRecordAndApplyWithoutEpoch(generation: 3, suspended: false)
            XCTAssertEqual(stale.generation, 20, "a nil epoch must not reset the high-water mark")
            XCTAssertTrue(stale.annotationsSuspended)
        }
    }

    func testFailureKeepsGenerationHighWaterRejectsOlderStateAndRepairsAtSameGeneration() throws {
        try withTemporaryCoordinator { coordinator, _ in
            let generationTen = coordinator.testOnlyRecordAndApply(generation: 10, suspended: true)
            XCTAssertEqual(generationTen.generation, 10)

            let failed = coordinator.testOnlyInstallFailure()
            XCTAssertEqual(failed.generation, 10)
            XCTAssertTrue(failed.annotationsSuspended)
            XCTAssertFalse(failed.isBootstrapped)

            // A delayed pre-failure generation must remain rejected.  In
            // particular, installFailure must not clear the monotonic
            // high-water marker and accidentally make generation 9 eligible.
            let staleNine = coordinator.testOnlyRecordAndApply(generation: 9, suspended: false)
            XCTAssertEqual(staleNine, failed)
            XCTAssertEqual(coordinator.snapshot(), failed)

            // The same durable generation is the only safe repair path: it
            // proves the previous failure was local, without accepting a
            // rollback from an older state-file observation.
            let repairedTen = coordinator.testOnlyRecordAndApply(generation: 10, suspended: false)
            XCTAssertEqual(repairedTen.generation, 10)
            XCTAssertFalse(repairedTen.annotationsSuspended)
            XCTAssertTrue(repairedTen.isBootstrapped)
            XCTAssertNil(repairedTen.error)
        }
    }

    func testPresentationPermitKeepsAcquireOutsideReadToOrderFrontFence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardPermitRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        let presenter = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "presenter")
        XCTAssertFalse(presenter.bootstrapAndReconcile().annotationsSuspended)

        let acquireReachedCommit = DispatchSemaphore(value: 0)
        let acquirer = SuspensionLeaseCoordinator(
            storageDirectory: directory,
            instanceNonce: "acquirer",
            storagePrecommitHook: { acquireReachedCommit.signal() }
        )
        let acquireStarted = DispatchSemaphore(value: 0)
        let acquireFinished = expectation(description: "concurrent acquire finishes after presentation permit")
        let resultLock = NSLock()
        var acquired: SuspensionLeaseOperationResult?

        let firstPermit = runOnPlatformUIThread { presenter.withPresentationPermit { snapshot in
            XCTAssertFalse(snapshot.annotationsSuspended)
            DispatchQueue.global().async {
                acquireStarted.signal()
                let result = acquirer.acquireLease(seconds: 60)
                resultLock.lock(); acquired = result; resultLock.unlock()
                acquireFinished.fulfill()
            }
            XCTAssertEqual(acquireStarted.wait(timeout: .now() + 1), .success)

            // The competing acquire has started but cannot write its lease
            // until this closure completes, because the permit still owns the
            // exact same flock used by mutation persistence.
            XCTAssertEqual(acquireReachedCommit.wait(timeout: .now() + 0.15), .timedOut)
        } }
        XCTAssertFalse(firstPermit.annotationsSuspended)

        wait(for: [acquireFinished], timeout: 3)
        resultLock.lock(); let result = acquired; resultLock.unlock()
        XCTAssertTrue(result?.success == true)
        let token = try XCTUnwrap(result?.leaseToken)

        var nextPermit: SuspensionLeaseSnapshot?
        runOnPlatformUIThread { _ = presenter.withPresentationPermit { nextPermit = $0 } }
        XCTAssertTrue(nextPermit?.annotationsSuspended == true,
                      "the next permit must deny presentation after the acquire persisted")
        _ = acquirer.releaseLease(token: token)
    }

    /// A peer can hold the durable lock while it is atomically committing a
    /// lease. That must never turn a platform-UI repaint, timer tick, or
    /// cross-process notification handler into the old one-second UI-thread
    /// sleep loop. A busy permit is deliberately a fail-closed answer: the
    /// caller may order windows out, but cannot order one front until a later
    /// durable permit proves no acquisition crossed its decision.
    func testMainThreadPermitAndReconciliationSchedulingDoNotWaitForHeldPeerLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardPermitNonblockingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        let presenter = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "presenter")
        XCTAssertFalse(presenter.bootstrapAndReconcile().annotationsSuspended)

        let peerHasLock = DispatchSemaphore(value: 0)
        let releasePeer = DispatchSemaphore(value: 0)
        let peerFinished = expectation(description: "peer mutation finishes after lock release")
        let resultLock = NSLock()
        var peerResult: SuspensionLeaseOperationResult?
        let peer = SuspensionLeaseCoordinator(
            storageDirectory: directory,
            instanceNonce: "peer",
            storagePrecommitHook: {
                peerHasLock.signal()
                _ = releasePeer.wait(timeout: .now() + 3)
            }
        )
        DispatchQueue.global().async {
            let result = peer.acquireLease(seconds: 60)
            resultLock.lock(); peerResult = result; resultLock.unlock()
            peerFinished.fulfill()
        }
        XCTAssertEqual(peerHasLock.wait(timeout: .now() + 2), .success,
                       "the test must exercise a genuinely held flock")

        var bodySnapshot: SuspensionLeaseSnapshot?
        var permitElapsed = 0.0
        let permit = runOnPlatformUIThread {
            XCTAssertTrue(MainThread.isCurrentUIThread)
            let permitStarted = ProcessInfo.processInfo.systemUptime
            let result = presenter.withPresentationPermit { bodySnapshot = $0 }
            permitElapsed = ProcessInfo.processInfo.systemUptime - permitStarted
            return result
        }
        XCTAssertLessThan(permitElapsed, 0.25,
                          "a busy main-thread permit must fail immediately, not retry for one second")
        XCTAssertNotNil(permit.error)
        XCTAssertTrue(permit.annotationsSuspended)
        XCTAssertEqual(bodySnapshot, permit, "the fail-closed snapshot reaches the ordering closure")

        // The failed permit itself schedules one background repair worker.
        // Every subsequent timer/notification wake-up folds into it while the
        // peer still owns flock.  The scheduler does no directory I/O or
        // synchronous lock retry here, and prevents a notification flood from
        // queuing an unbounded number of reconciliation tasks.
        let scheduleStarted = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(presenter.reconcileAsynchronously(),
                       "the busy permit must already have enqueued its one repair worker")
        for generation in 1...32 {
            XCTAssertFalse(presenter.reconcileAsynchronously(announcedGeneration: UInt64(generation)))
        }
        let schedulingElapsed = ProcessInfo.processInfo.systemUptime - scheduleStarted
        XCTAssertLessThan(schedulingElapsed, 0.25,
                          "coalescing a held-lock reconciliation must return to the main run loop promptly")

        releasePeer.signal()
        wait(for: [peerFinished], timeout: 5)
        resultLock.lock(); let result = peerResult; resultLock.unlock()
        XCTAssertTrue(result?.success == true)
        let reconciliationDeadline = Date().addingTimeInterval(2)
        while !presenter.snapshot().annotationsSuspended && Date() < reconciliationDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(presenter.snapshot().annotationsSuspended,
                      "the coalesced worker must eventually apply the peer's durable lease")
        if let token = result?.leaseToken {
            _ = peer.releaseLease(token: token)
        }
    }

    func testReleaseFinalSettleReturnsConcurrentNewerAcquire() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstCoordinator = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "first")
        _ = firstCoordinator.bootstrapAndReconcile()
        let firstToken = try XCTUnwrap(firstCoordinator.acquireLease(seconds: 60).leaseToken)
        let releasePaused = DispatchSemaphore(value: 0)
        let allowReleaseSettle = DispatchSemaphore(value: 0)
        let releasingCoordinator = SuspensionLeaseCoordinator(
            storageDirectory: directory, instanceNonce: "releaser",
            mutationSettleHook: {
                releasePaused.signal()
                _ = allowReleaseSettle.wait(timeout: .now() + 3)
            }
        )
        let releaseFinished = expectation(description: "release returns final generation")
        let resultLock = NSLock()
        var releaseResult: SuspensionLeaseOperationResult?
        DispatchQueue.global().async {
            let result = releasingCoordinator.releaseLease(token: firstToken)
            resultLock.lock(); releaseResult = result; resultLock.unlock()
            releaseFinished.fulfill()
        }
        XCTAssertEqual(releasePaused.wait(timeout: .now() + 2), .success)
        let newerCoordinator = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "newer")
        let newer = newerCoordinator.acquireLease(seconds: 60)
        let newerToken = try XCTUnwrap(newer.leaseToken)
        allowReleaseSettle.signal()
        wait(for: [releaseFinished], timeout: 4)
        resultLock.lock(); let released = releaseResult; resultLock.unlock()
        XCTAssertEqual(released?.generation, newer.generation)
        XCTAssertTrue(released?.annotationsSuspended == true)
        XCTAssertEqual(released?.activeLeaseCount, 1)
        _ = newerCoordinator.releaseLease(token: newerToken)
    }

    func testIdempotencyKeyCannotRevealTokenAcrossInstanceNonces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardNonceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "a0b1c2d3-e4f5-4a6b-8c9d-0e1f2a3b4c5d"
        let owner = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "owner")
        let issued = owner.acquireLease(seconds: 60, idempotencyKey: key)
        let token = try XCTUnwrap(issued.leaseToken)
        let other = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "other")
        let refused = other.acquireLease(seconds: 60, idempotencyKey: key)
        XCTAssertFalse(refused.success)
        XCTAssertNil(refused.leaseToken)
        _ = owner.releaseLease(token: token)
    }

    func testDirectoryReplacementDuringCommitFailsClosed() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardDirectoryRaceTests-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("state", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: parent) }
        // Tracks whether the hook's swap actually took effect -- see the
        // Windows-only skip check below, added after this test genuinely
        // failed on Windows for a reason unrelated to `validateHeldLock`'s
        // own logic (confirmed by direct instrumentation): `FileManager
        // .moveItem` on this environment fails the directory move with
        // `ERROR_ACCESS_DENIED` while this process still holds its own open
        // directory/lock-file handles into it, so the swap this test relies
        // on to exercise the fail-closed path never actually happens here,
        // and the subsequent `createDirectory` then fails too
        // (`ERROR_ALREADY_EXISTS`, since the original directory never
        // moved). `validateHeldLock` cannot be "wrong" about a replacement
        // that never occurred -- it correctly saw an unchanged identity and
        // did not throw. On macOS this swap always succeeds (POSIX rename
        // never cares about open handles), so `swapSucceeded` is written
        // but never read there.
        var swapSucceeded = true
        let coordinator = SuspensionLeaseCoordinator(storageDirectory: directory, storagePrecommitHook: {
            do {
                try FileManager.default.moveItem(at: directory, to: moved)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                swapSucceeded = false
            }
            #if os(macOS)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #endif
        })
        let result = coordinator.acquireLease(seconds: 60)
        #if os(Windows)
        guard swapSucceeded else {
            throw XCTSkip("This environment does not allow replacing the storage directory while this process still holds its own directory/lock handles into it (FileManager.moveItem/createDirectory failed inside the precommit hook); cannot exercise the fail-closed directory-replacement path here.")
        }
        #endif
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.annotationsSuspended)
        XCTAssertNotNil(result.error)
    }

    // MARK: - Refusals are not registry failures

    /// A refused ARGUMENT must not be reported as a broken REGISTRY.
    ///
    /// Every refusal inside a mutation used to throw `.unavailable`, which
    /// landed in the fail-closed catch: the process ordered its overlays off
    /// screen, logged "suspension registry unavailable" about a registry it had
    /// just read successfully, and dropped `isBootstrapped`. Releasing an
    /// already-stale token -- an ordinary, expected thing for an agent to do --
    /// therefore blanked the user's annotations until a reconcile tick swept
    /// them back. Caught in the two-process integration log, where a
    /// deliberately-rejected cross-process idempotency key produced an ERROR
    /// line in an otherwise passing run.
    func testRefusedArgumentsDoNotFailTheRegistryClosed() throws {
        try withTemporaryCoordinator { coordinator, _ in
            XCTAssertFalse(coordinator.bootstrapAndReconcile().annotationsSuspended)
            let live = coordinator.acquireLease(seconds: 60)
            let liveToken = try XCTUnwrap(live.leaseToken)
            XCTAssertTrue(live.annotationsSuspended)

            // An unknown token is a bad argument, not a broken registry.
            let unknown = coordinator.releaseLease(token: String(repeating: "B", count: 43))
            XCTAssertFalse(unknown.success)
            XCTAssertNotNil(unknown.error)
            XCTAssertTrue(unknown.annotationsSuspended,
                          "the live lease still owns the presentation after an unrelated refusal")
            XCTAssertEqual(unknown.activeLeaseCount, 1, "a refusal must not report the registry as empty")

            let afterRefusal = coordinator.snapshot()
            XCTAssertTrue(afterRefusal.isBootstrapped,
                          "a refused argument must not mark the registry unbootstrapped")
            XCTAssertNil(afterRefusal.error, "a refusal is not a registry error")
            XCTAssertEqual(afterRefusal.activeLeaseCount, 1)

            // The real lease is untouched and still releasable.
            let released = coordinator.releaseLease(token: liveToken)
            XCTAssertTrue(released.success)
            XCTAssertFalse(released.alreadyReleased)
            XCTAssertFalse(released.annotationsSuspended)
        }
    }

    func testRefusalImmediatelyAppliesANewerPeerLease() throws {
        try withTemporaryCoordinator { coordinator, directory in
            XCTAssertFalse(coordinator.bootstrapAndReconcile().annotationsSuspended)

            let peer = SuspensionLeaseCoordinator(storageDirectory: directory, instanceNonce: "peer")
            let key = "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e"
            let acquired = peer.acquireLease(seconds: 60, idempotencyKey: key)
            let token = try XCTUnwrap(acquired.leaseToken)
            XCTAssertTrue(acquired.success)
            XCTAssertTrue(acquired.annotationsSuspended)

            // This coordinator has not reconciled the peer's mutation yet.
            XCTAssertFalse(coordinator.snapshot().annotationsSuspended)

            let refused = coordinator.acquireLease(seconds: 60, idempotencyKey: key)
            XCTAssertFalse(refused.success)
            XCTAssertNotNil(refused.error)
            XCTAssertTrue(refused.annotationsSuspended,
                          "the clean refusal read must still update presentation from canonical state")
            XCTAssertEqual(refused.activeLeaseCount, 1)
            XCTAssertTrue(coordinator.snapshot().annotationsSuspended)

            _ = peer.releaseLease(token: token)
        }
    }

    /// The counterpart: a genuine storage failure must STILL fail closed.
    func testGenuineRegistryFailureStillFailsClosed() throws {
        try withTemporaryCoordinator { coordinator, _ in
            XCTAssertFalse(coordinator.bootstrapAndReconcile().annotationsSuspended)
            let failed = coordinator.testOnlyInstallFailure("simulated storage failure")
            XCTAssertTrue(failed.annotationsSuspended, "an unknown state must hide the overlays")
            XCTAssertFalse(failed.isBootstrapped)
            XCTAssertNotNil(failed.error)
        }
    }

    // MARK: - Boot session identity

    #if os(Windows)
    func testWindowsAdjacentBootBucketsPreserveLiveLeaseAndConverge() throws {
        XCTAssertTrue(SuspensionLeaseCoordinator.isSameBootSession(
            stored: "winboot-100000", current: "winboot-102000", legacyBootSeconds: nil
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardWindowsBootBucketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let owner = SuspensionLeaseCoordinator(
            storageDirectory: directory, bootSessionIdentifier: "winboot-100000"
        )
        let adjacent = SuspensionLeaseCoordinator(
            storageDirectory: directory, bootSessionIdentifier: "winboot-102000"
        )
        let acquired = owner.acquireLease(seconds: 60)
        XCTAssertTrue(acquired.success)
        XCTAssertTrue(acquired.annotationsSuspended)

        let peer = adjacent.reconcile()
        XCTAssertTrue(peer.annotationsSuspended)
        XCTAssertEqual(peer.activeLeaseCount, 1)
        let settledGeneration = peer.generation
        XCTAssertEqual(owner.reconcile().generation, settledGeneration)
        XCTAssertEqual(adjacent.reconcile().generation, settledGeneration)

        if let token = acquired.leaseToken {
            _ = owner.releaseLease(token: token)
        }
    }
    #endif

    /// `kern.boottime` is DERIVED (wall clock minus uptime), not stored, so its
    /// microsecond field shifts by a few hundred microseconds every time the
    /// system clock is disciplined -- while `tv_sec` and the boot itself stay
    /// put. When the boot identity embedded that microsecond field, two live
    /// processes that sampled it either side of an NTP adjustment computed
    /// DIFFERENT identities for the SAME boot, and each read the other's
    /// registry as "written before the last reboot". The reboot-recovery path
    /// then replaced it with an empty state -- destroying every live lease --
    /// and rewrote the file, which broadcast a suspension invalidation, which
    /// made the peer reconcile, re-detect a foreign identity, and reset it
    /// straight back. Observed in production as a self-sustaining cross-process
    /// ping-pong that wrote ~150 registry generations per second and filled the
    /// entire 5 MB log with one repeated line.
    func testBootSessionIdentitySurvivesBoottimeMicrosecondDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardBootDriftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        // The exact pair observed on the reporting machine: same boot second,
        // 455 microseconds of clock-discipline drift between the two samples.
        let owner = SuspensionLeaseCoordinator(storageDirectory: directory,
                                               bootSessionIdentifier: "1787827823.287935")
        let drifted = SuspensionLeaseCoordinator(storageDirectory: directory,
                                                 bootSessionIdentifier: "1787827823.287480")

        let acquired = owner.acquireLease(seconds: 60)
        XCTAssertTrue(acquired.success)
        XCTAssertTrue(acquired.annotationsSuspended)
        XCTAssertEqual(acquired.activeLeaseCount, 1)

        let peer = drifted.reconcile()
        XCTAssertTrue(peer.annotationsSuspended,
                      "a peer whose boottime microseconds drifted must not read a live registry as a prior boot")
        XCTAssertEqual(peer.activeLeaseCount, 1, "the drifted peer destroyed another process's live lease")

        // ...and the two must converge instead of rewriting the registry at
        // each other forever. Generations advance only on a real state change.
        let settled = drifted.reconcile().generation
        XCTAssertEqual(drifted.reconcile().generation, settled, "the drifted peer keeps rewriting the registry")
        XCTAssertEqual(owner.reconcile().generation, settled, "the two processes are ping-ponging the registry")
        XCTAssertEqual(drifted.reconcile().generation, settled)
        XCTAssertTrue(owner.reconcile().annotationsSuspended)
    }

    /// A genuinely different boot must still be recovered from -- the drift
    /// tolerance above must not swallow a real reboot.
    func testRegistryFromAGenuinelyDifferentBootIsStillReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardBootResetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        let previousBoot = SuspensionLeaseCoordinator(storageDirectory: directory,
                                                      bootSessionIdentifier: "1787827823.287935")
        let previousLease = previousBoot.acquireLease(seconds: 60)
        XCTAssertTrue(previousLease.success)
        XCTAssertTrue(previousLease.annotationsSuspended)
        XCTAssertEqual(previousLease.activeLeaseCount, 1)

        // A reboot moves `kern.boottime` by far more than clock discipline can.
        let afterReboot = SuspensionLeaseCoordinator(storageDirectory: directory,
                                                     bootSessionIdentifier: "1787913344.100000")
        let recovered = afterReboot.bootstrapAndReconcile()
        XCTAssertFalse(recovered.annotationsSuspended,
                       "a lease from a previous boot must never keep this boot's overlays hidden")
        XCTAssertEqual(recovered.activeLeaseCount, 0)
    }

    /// The upgrade path on a machine that is already running: the registry on
    /// disk was written by the previous build, so it stores a `kern.boottime`
    /// NUMBER, while this build identifies the boot by `kern.bootsessionuuid`.
    /// A literal comparison would read that as a reboot on the very first read
    /// after the update and drop a suspension lease that is still live, so a
    /// stored number is matched against this boot's actual boot time instead.
    func testLegacyBoottimeRegistryIsAdoptedByTheUUIDIdentityWithoutAReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardBootUpgradeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exactly what the previous build wrote: "<tv_sec>.<tv_usec>" for the
        // boot this test process is itself running in.
        let legacyIdentifier = try XCTUnwrap(SuspensionLeaseCoordinator.testOnlyLegacyBoottimeIdentifier())
        let previousBuild = SuspensionLeaseCoordinator(storageDirectory: directory,
                                                       bootSessionIdentifier: legacyIdentifier)
        let acquired = previousBuild.acquireLease(seconds: 60)
        let token = try XCTUnwrap(acquired.leaseToken)
        XCTAssertTrue(acquired.annotationsSuspended)

        // The updated build takes its identity from `kern.bootsessionuuid`.
        let updatedBuild = SuspensionLeaseCoordinator(storageDirectory: directory)
        let afterUpgrade = updatedBuild.bootstrapAndReconcile()
        XCTAssertTrue(afterUpgrade.annotationsSuspended,
                      "the update must not read its own boot's registry as a prior boot")
        XCTAssertEqual(afterUpgrade.activeLeaseCount, 1)

        // The lease stays addressable across the identity change.
        let released = updatedBuild.releaseLease(token: token)
        XCTAssertTrue(released.success)
        XCTAssertFalse(released.alreadyReleased)
        XCTAssertFalse(released.annotationsSuspended)
    }

    /// The legacy identity is ADOPTED for the rest of the boot, not upgraded in
    /// place -- a same-boot write preserves whatever identifier the file already
    /// carries. So the number stays on disk until something genuinely replaces
    /// the registry, and the question that matters is whether it ever leaves.
    /// It does: the next reboot takes the replacement path, which stamps the
    /// running process's own identity. Pins that the tolerant comparison is a
    /// migration, not a permanent dependence on parsing numbers.
    func testTheLegacyIdentifierIsReplacedByThisBuildsOwnIdentityAtTheNextReboot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardBootHealTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("annotations-suspension-v3.json")

        func storedIdentifier() throws -> String {
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
            return try XCTUnwrap(raw["bootSessionIdentifier"] as? String)
        }

        // A registry left by the previous build, for the boot we are in.
        let legacyIdentifier = try XCTUnwrap(SuspensionLeaseCoordinator.testOnlyLegacyBoottimeIdentifier())
        let previousBuild = SuspensionLeaseCoordinator(storageDirectory: directory,
                                                       bootSessionIdentifier: legacyIdentifier)
        XCTAssertTrue(previousBuild.acquireLease(seconds: 60).success)
        XCTAssertEqual(try storedIdentifier(), legacyIdentifier)

        // This build adopts it and, because a same-boot write keeps the stored
        // identifier, deliberately leaves the number in place.
        let updated = SuspensionLeaseCoordinator(storageDirectory: directory)
        XCTAssertTrue(updated.bootstrapAndReconcile().annotationsSuspended)
        XCTAssertTrue(updated.acquireLease(seconds: 60).success)
        XCTAssertEqual(try storedIdentifier(), legacyIdentifier,
                       "a same-boot write must not churn the stored identity")

        // A reboot replaces the registry, and the replacement carries THIS
        // build's identity -- so the legacy number does not outlive the boot.
        let afterReboot = SuspensionLeaseCoordinator(storageDirectory: directory,
                                                     bootSessionIdentifier: "boot-after-restart")
        XCTAssertFalse(afterReboot.bootstrapAndReconcile().annotationsSuspended)
        XCTAssertTrue(afterReboot.acquireLease(seconds: 60).success)
        XCTAssertEqual(try storedIdentifier(), "boot-after-restart",
                       "the replacement must stamp the running process's own identity")
    }

    /// The residual worry after making the comparison tolerant: what if the
    /// stored anchor is EVENTUALLY left behind, by drift larger than the
    /// tolerance? That must cost exactly one replacement and then settle --
    /// never the self-sustaining rewrite loop the tolerance exists to prevent.
    /// Convergence is the real property; the tolerance only makes it rare.
    func testDriftBeyondToleranceCostsOneReplacementAndThenConverges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardBootConvergeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }

        // A stored anchor far enough away that no tolerance can absorb it.
        let stale = SuspensionLeaseCoordinator(storageDirectory: directory,
                                               bootSessionIdentifier: "1787827823.287935")
        XCTAssertTrue(stale.acquireLease(seconds: 60).success)

        // Two peers that agree with each other but not with the stored anchor:
        // the shape a fleet of Chalkboard processes has after any replacement.
        let peerA = SuspensionLeaseCoordinator(storageDirectory: directory,
                                               bootSessionIdentifier: "shared-identity")
        let peerB = SuspensionLeaseCoordinator(storageDirectory: directory,
                                               bootSessionIdentifier: "shared-identity")

        // First read replaces the registry once. Assert the replacement really
        // happened -- without this the test can pass by never taking the path
        // it is named after, which is exactly how its first version passed.
        let afterReplacement = peerA.bootstrapAndReconcile()
        XCTAssertFalse(afterReplacement.annotationsSuspended,
                       "the stale anchor's lease must not survive the replacement")
        XCTAssertEqual(afterReplacement.activeLeaseCount, 0)
        let replaced = afterReplacement.generation
        // After that, neither peer may write again: reconcile alternated
        // between them is exactly the loop that used to run at 150 Hz.
        for _ in 0..<12 {
            XCTAssertEqual(peerB.reconcile().generation, replaced, "peer B is rewriting the registry")
            XCTAssertEqual(peerA.reconcile().generation, replaced, "peer A is rewriting the registry")
        }
    }

    /// The identity itself must be stable when sampled repeatedly, which is the
    /// property the production defect violated.
    func testCurrentBootSessionIdentifierIsStableAcrossSamples() throws {
        let first = try XCTUnwrap(SuspensionLeaseCoordinator.currentBootSessionIdentifier())
        XCTAssertFalse(first.isEmpty)
        for _ in 0..<25 {
            XCTAssertEqual(SuspensionLeaseCoordinator.currentBootSessionIdentifier(), first,
                           "the boot identity must not vary between samples within one boot")
        }
    }

    // MARK: - AI_CHALKBOARD_SUSPENSION_ROOT override

    /// The override exists so a harness can point the shared registry at a
    /// throwaway directory. `test_mcp_stdio.py` and
    /// `test_suspension_two_process.py` both rely on it, handing over whatever
    /// `tempfile.mkdtemp()` returned -- a `C:\...` path on Windows. The guard
    /// used to be `hasPrefix("/")`, so on Windows every such value was
    /// rejected and those harnesses silently ran against the REAL per-user
    /// registry that a live connector shares, instead of their sandbox.
    func testAbsoluteSuspensionRootOverrideIsHonoredInThisPlatformsPathSyntax() {
        #if os(Windows)
        // Raw literal: a Windows path is all backslashes, and escaping them
        // here would obscure the exact shape mkdtemp actually hands over.
        let root = #"C:\Users\example\AppData\Local\Temp\ai-chalkboard-suspension-it-abc123"#
        #else
        let root = "/tmp/ai-chalkboard-suspension-it-abc123"
        #endif
        let resolved = SuspensionLeaseCoordinator.overrideStorageDirectory(fromEnvironmentValue: root)
        XCTAssertEqual(resolved,
                       URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL,
                       "a mkdtemp-shaped absolute path in this platform's own syntax must be honored")
    }

    /// A relative override would resolve against whatever directory the
    /// process happened to launch from, putting the shared registry somewhere
    /// unpredictable. Rejecting non-absolute values is the whole point of the
    /// guard, so widening it for Windows must not have widened it to these.
    func testNonAbsoluteSuspensionRootOverridesAreRejected() {
        XCTAssertNil(SuspensionLeaseCoordinator.overrideStorageDirectory(fromEnvironmentValue: nil))
        XCTAssertNil(SuspensionLeaseCoordinator.overrideStorageDirectory(fromEnvironmentValue: ""))
        XCTAssertNil(SuspensionLeaseCoordinator.overrideStorageDirectory(fromEnvironmentValue: "relative/dir"))
        XCTAssertNil(SuspensionLeaseCoordinator.overrideStorageDirectory(fromEnvironmentValue: "./relative"))
        #if os(Windows)
        // "C:relative" is drive-RELATIVE (relative to the current directory on
        // drive C:), not absolute, and must not be mistaken for the former.
        XCTAssertNil(SuspensionLeaseCoordinator.overrideStorageDirectory(fromEnvironmentValue: "C:relative"))
        #endif
    }

    /// With no override set, the coordinator must fall back to the real
    /// per-user directory rather than anything derived from the cwd -- the
    /// behaviour production depends on, and the reason the guard has to
    /// reject junk rather than pass it through.
    func testAbsentSuspensionRootOverrideLeavesTheRealPerUserDirectoryInPlace() {
        // AppBehaviorTests sets this variable process-wide to isolate itself,
        // so clear it just for this call rather than skipping -- skipping here
        // would silently drop the only coverage of the production fallback.
        // Only this freshly constructed instance is affected; the shared
        // coordinator resolved its own directory long before now.
        let coordinator = TestEnvironment.withValue("AI_CHALKBOARD_SUSPENSION_ROOT", nil) {
            SuspensionLeaseCoordinator(
                storageDirectory: nil,
                bootSessionIdentifier: "test-boot",
                instanceNonce: "test-nonce"
            )
        }
        XCTAssertEqual(coordinator.storageDirectory.lastPathComponent, "AIChalkboard")
        XCTAssertTrue((coordinator.storageDirectory.path as NSString).isAbsolutePath,
                      "the fallback must be absolute, never resolved against the current directory")
    }
}
