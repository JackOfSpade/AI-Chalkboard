import Foundation
import XCTest
@testable import AIChalkboardCore

final class SuspensionLeaseCoordinatorTests: XCTestCase {
    private func withTemporaryCoordinator(_ body: (SuspensionLeaseCoordinator, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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

    func testHardLinkedReplacementLockFailsClosed() throws {
        try withTemporaryCoordinator { _, directory in
            let source = directory.appendingPathComponent("replacement-source")
            let lock = directory.appendingPathComponent("annotations-suspension-v3.lock")
            try Data("ordinary file".utf8).write(to: source)
            try FileManager.default.linkItem(at: source, to: lock)

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
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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

        let firstPermit = presenter.withPresentationPermit { snapshot in
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
        }
        XCTAssertFalse(firstPermit.annotationsSuspended)

        wait(for: [acquireFinished], timeout: 3)
        resultLock.lock(); let result = acquired; resultLock.unlock()
        XCTAssertTrue(result?.success == true)
        let token = try XCTUnwrap(result?.leaseToken)

        var nextPermit: SuspensionLeaseSnapshot?
        _ = presenter.withPresentationPermit { nextPermit = $0 }
        XCTAssertTrue(nextPermit?.annotationsSuspended == true,
                      "the next permit must deny presentation after the acquire persisted")
        _ = acquirer.releaseLease(token: token)
    }

    func testReleaseFinalSettleReturnsConcurrentNewerAcquire() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLeaseRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: parent) }
        let coordinator = SuspensionLeaseCoordinator(storageDirectory: directory, storagePrecommitHook: {
            try? FileManager.default.moveItem(at: directory, to: moved)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        })
        let result = coordinator.acquireLease(seconds: 60)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.annotationsSuspended)
        XCTAssertNotNil(result.error)
    }
}
