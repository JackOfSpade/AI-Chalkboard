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

    func testRejectsRelativePath() {
        XCTAssertThrowsError(try BoundedLocalFile.read(path: "relative.bin", maxBytes: 1_024)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .invalidPath)
        }
    }
}
