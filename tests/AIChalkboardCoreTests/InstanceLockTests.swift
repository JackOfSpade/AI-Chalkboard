import Foundation
import XCTest
@testable import AIChalkboardCore

final class InstanceLockTests: XCTestCase {
    private func withTemporaryLockFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("instance.lock"))
    }

    func testOnePrimaryAndOneSecondary() throws {
        try withTemporaryLockFile { lockURL in
            let primary = InstanceLock(lockURL: lockURL)
            let secondary = InstanceLock(lockURL: lockURL)

            XCTAssertTrue(primary.acquire())
            XCTAssertFalse(secondary.acquire())
            XCTAssertEqual(primary.revalidatePrimaryLock(), .retainPrimary)
            XCTAssertFalse(secondary.retryAcquire())
        }
    }

    func testLivePrimaryRepairsDeletedLockBeforeSecondaryPromotes() throws {
        try withTemporaryLockFile { lockURL in
            let primary = InstanceLock(lockURL: lockURL)
            let secondary = InstanceLock(lockURL: lockURL)
            XCTAssertTrue(primary.acquire())
            XCTAssertFalse(secondary.acquire())

            try FileManager.default.removeItem(at: lockURL)
            XCTAssertEqual(primary.revalidatePrimaryLock(), .retainPrimary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
            XCTAssertFalse(secondary.retryAcquire())
        }
    }

    func testOrphanedPrimaryRelinquishesWhenSecondaryOwnsReplacementPath() throws {
        try withTemporaryLockFile { lockURL in
            let originalPrimary = InstanceLock(lockURL: lockURL)
            let secondary = InstanceLock(lockURL: lockURL)
            XCTAssertTrue(originalPrimary.acquire())
            XCTAssertFalse(secondary.acquire())

            try FileManager.default.removeItem(at: lockURL)
            XCTAssertFalse(secondary.retryAcquire())
            XCTAssertFalse(secondary.retryAcquire())
            XCTAssertFalse(secondary.retryAcquire())
            XCTAssertTrue(secondary.retryAcquire(), "four missing polls should promote the survivor")

            XCTAssertEqual(originalPrimary.revalidatePrimaryLock(), .relinquishToPathOwner)
            XCTAssertFalse(originalPrimary.retryAcquire(), "the former primary must now contend as a secondary")
        }
    }

    func testFailOpenPrimaryWithoutDescriptorRetainsPrimaryRole() throws {
        try withTemporaryLockFile { lockURL in
            let invalidParent = lockURL.deletingLastPathComponent().appendingPathComponent("not-a-directory")
            try Data("x".utf8).write(to: invalidParent)
            let impossibleLock = invalidParent.appendingPathComponent("instance.lock")
            let failOpenPrimary = InstanceLock(lockURL: impossibleLock)

            XCTAssertTrue(failOpenPrimary.acquire())
            XCTAssertEqual(failOpenPrimary.revalidatePrimaryLock(), .retainPrimary)
        }
    }

    func testSymlinkLockPathCannotLockItsTarget() throws {
        try withTemporaryLockFile { lockURL in
            let targetURL = lockURL.deletingLastPathComponent().appendingPathComponent("unrelated.lock")
            try Data().write(to: targetURL)
            try FileManager.default.createSymbolicLink(
                atPath: lockURL.path,
                withDestinationPath: targetURL.path
            )

            // The unsafe path still follows acquire()'s documented fail-open
            // policy, but it must not acquire an advisory lock on the symlink
            // target. A normal lock on that target must remain available.
            let unsafePath = InstanceLock(lockURL: lockURL)
            XCTAssertTrue(unsafePath.acquire())

            let targetLock = InstanceLock(lockURL: targetURL)
            XCTAssertTrue(targetLock.acquire(), "instance.lock must not follow and lock an unrelated symlink target")
        }
    }
}
