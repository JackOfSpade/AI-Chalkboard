import XCTest
@testable import AIChalkboardCore

final class LoggerTests: XCTestCase {
    func testApplicationLogsDirectoryUsesResolvedLibraryDirectory() {
        let result = Logger.applicationLogsDirectory(
            libraryDirectory: URL(fileURLWithPath: "/custom/Library", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/unused-home", isDirectory: true)
        )

        XCTAssertEqual(result.path, "/custom/Library/Logs/AIChalkboard")
    }

    func testApplicationLogsDirectoryFallsBackToStandardHomeLibraryLocation() {
        let result = Logger.applicationLogsDirectory(
            libraryDirectory: nil,
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(result.path, "/Users/example/Library/Logs/AIChalkboard")
    }

    func testShortMessageIsUnchanged() {
        XCTAssertEqual(Logger.boundedMessage("placement rejected"), "placement rejected")
    }

    func testOversizedMessageIsBoundedAndMarked() {
        let result = Logger.boundedMessage(String(repeating: "x", count: Logger.maxMessageBytes + 1_000))
        XCTAssertLessThanOrEqual(result.utf8.count, Logger.maxMessageBytes)
        XCTAssertTrue(result.hasSuffix("... <truncated to \(Logger.maxMessageBytes) bytes>"))
    }

    func testMessageBoundNeverSplitsUnicode() {
        let result = Logger.boundedMessage(String(repeating: "😀", count: Logger.maxMessageBytes))
        XCTAssertLessThanOrEqual(result.utf8.count, Logger.maxMessageBytes)
        XCTAssertTrue(result.hasSuffix("bytes>"))
        XCTAssertFalse(result.contains("�"))
    }

    func testShortStderrLineIsUnchanged() {
        let line = "[INFO] healthy diagnostic\n"
        XCTAssertEqual(Logger.boundedStderrLine(line), line)
    }

    func testOversizedStderrLineIsPipeAtomicAndKeepsNewline() {
        let result = Logger.boundedStderrLine(String(repeating: "😀", count: 1_000) + "\n")
        XCTAssertLessThanOrEqual(result.utf8.count, Logger.maxStderrRecordBytes)
        XCTAssertTrue(result.hasSuffix("... <stderr truncated>\n"))
        XCTAssertFalse(result.contains("�"))
    }
}
