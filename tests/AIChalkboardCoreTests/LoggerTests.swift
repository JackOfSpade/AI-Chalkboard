import XCTest
@testable import AIChalkboardCore

final class LoggerTests: XCTestCase {
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
}
