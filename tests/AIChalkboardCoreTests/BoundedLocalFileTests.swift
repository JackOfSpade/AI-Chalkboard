import Darwin
import XCTest
@testable import AIChalkboardCore

final class BoundedLocalFileTests: XCTestCase {
    private func writeTempFile(bytes: Int, byte: UInt8 = 0x41) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-bounded-local-file-\(UUID().uuidString).bin")
        try Data(repeating: byte, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsRegularFileWithinBudget() throws {
        let url = try writeTempFile(bytes: 128)
        let data = try BoundedLocalFile.read(path: url.path, maxBytes: 1_024)
        XCTAssertEqual(data, Data(repeating: 0x41, count: 128))
    }

    func testReadsFileExactlyAtTheByteCap() throws {
        let url = try writeTempFile(bytes: 64)
        let data = try BoundedLocalFile.read(path: url.path, maxBytes: 64)
        XCTAssertEqual(data.count, 64)
    }

    func testRejectsFileOverTheByteCap() throws {
        let url = try writeTempFile(bytes: 65)
        XCTAssertThrowsError(try BoundedLocalFile.read(path: url.path, maxBytes: 64)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
        }
    }

    func testRejectsNonRegularFile() {
        let directory = FileManager.default.temporaryDirectory.path
        XCTAssertThrowsError(try BoundedLocalFile.read(path: directory, maxBytes: 1_024)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
        }
    }

    /// A FIFO with no writer must be REJECTED, and must be rejected without
    /// blocking. This is the regression test for the open(2)-on-a-FIFO hang:
    /// with a blocking open, this test does not fail -- it never returns, and
    /// in production it took the MCP server's single read loop with it (the
    /// path is reachable from `draw_image`'s image_path and
    /// `verify_annotation`'s screenshot_path). The XCTest timeout below is
    /// therefore load-bearing: it is what turns "hung forever" into a failure.
    func testRejectsFifoWithoutBlocking() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-bounded-local-file-fifo-\(UUID().uuidString)")
        guard mkfifo(url.path, 0o600) == 0 else {
            throw XCTSkip("mkfifo failed (errno \(errno)); cannot exercise the FIFO path here.")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let finished = expectation(description: "BoundedLocalFile.read returned on a writer-less FIFO")
        DispatchQueue.global().async {
            do {
                _ = try BoundedLocalFile.read(path: url.path, maxBytes: 1_024)
                XCTFail("Expected a FIFO to be rejected as not-a-regular-file")
            } catch {
                XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    func testRejectsRelativePath() {
        XCTAssertThrowsError(try BoundedLocalFile.read(path: "relative.bin", maxBytes: 1_024)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .invalidPath)
        }
    }
}
