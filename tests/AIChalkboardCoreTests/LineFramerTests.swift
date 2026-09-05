import Foundation
import XCTest
@testable import AIChalkboardCore

/// `LineFramer` reassembles arbitrary stdin byte chunks into complete
/// newline-terminated JSON-RPC messages. It is deliberately dependency-free
/// (no `FileHandle`, no real stdio) so these tests can feed it hand-built
/// `Data` chunks directly.
final class LineFramerTests: XCTestCase {
    private func strings(_ result: LineFramer.FeedResult) -> [String] {
        result.lines.map { String(data: $0, encoding: .utf8) ?? "<invalid utf8>" }
    }

    func testSingleCompleteLine() {
        var framer = LineFramer()
        let result = framer.feed(Data("hello\n".utf8))
        XCTAssertEqual(strings(result), ["hello"])
        XCTAssertFalse(result.overflow)
    }

    func testSeveralLinesArrivingInOneChunk() {
        var framer = LineFramer()
        let result = framer.feed(Data("one\ntwo\nthree\n".utf8))
        XCTAssertEqual(strings(result), ["one", "two", "three"])
        XCTAssertFalse(result.overflow)
    }

    func testLineSplitAcrossChunksIsReassembled() {
        var framer = LineFramer()
        let first = framer.feed(Data("hel".utf8))
        XCTAssertEqual(strings(first), [])

        let second = framer.feed(Data("lo\n".utf8))
        XCTAssertEqual(strings(second), ["hello"])
    }

    func testCRLFIsStrippedToMatchBareLFSenders() {
        var framer = LineFramer()
        let result = framer.feed(Data("hello\r\n".utf8))
        XCTAssertEqual(strings(result), ["hello"])
    }

    func testEmptyLinesAreSkipped() {
        var framer = LineFramer()
        // A bare "\n" and a CRLF-only line ("\r\n", which becomes empty once
        // its trailing \r is stripped) must both be dropped, not returned as
        // empty messages.
        let result = framer.feed(Data("\n\r\nhello\n\n".utf8))
        XCTAssertEqual(strings(result), ["hello"])
    }

    func testTrailingPartialLineIsRetainedUntilItsNewlineArrives() {
        var framer = LineFramer()
        let first = framer.feed(Data("first\npartial".utf8))
        XCTAssertEqual(strings(first), ["first"])
        XCTAssertFalse(first.overflow)

        let second = framer.feed(Data(" done\n".utf8))
        XCTAssertEqual(strings(second), ["partial done"])
    }

    func testUnterminatedFloodBeyondTheByteCapReportsOverflowRatherThanGrowingForever() {
        var framer = LineFramer()
        let flood = Data(repeating: UInt8(ascii: "x"), count: LineFramer.maxBufferBytes + 1)
        let result = framer.feed(flood)
        XCTAssertEqual(result.lines, [])
        XCTAssertTrue(result.overflow)
    }

    func testCompleteOversizedLineIsRejectedBeforeItCanReachTheServer() {
        var framer = LineFramer()
        let complete = Data(repeating: UInt8(ascii: "x"), count: LineFramer.maxBufferBytes + 1)
            + Data("\n".utf8)
        let result = framer.feed(complete)
        XCTAssertTrue(result.overflow)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testOversizedLineDropsEarlierSameChunkLinesUntilFatalShutdown() {
        var framer = LineFramer()
        var chunk = Data("{\"safe-looking\":true}\n".utf8)
        chunk.append(Data(repeating: UInt8(ascii: "x"), count: LineFramer.maxBufferBytes + 1))
        chunk.append(UInt8(ascii: "\n"))
        let result = framer.feed(chunk)
        XCTAssertTrue(result.overflow)
        XCTAssertTrue(result.lines.isEmpty, "MCPServer must see the fatal oversized line before dispatching an earlier same-chunk request")
    }

    func testOversizedUnterminatedTailAlsoDropsEarlierSameChunkLines() {
        var framer = LineFramer()
        var chunk = Data("{\"safe-looking\":true}\n".utf8)
        chunk.append(Data(repeating: UInt8(ascii: "x"), count: LineFramer.maxBufferBytes + 1))

        let result = framer.feed(chunk)

        XCTAssertTrue(result.overflow)
        XCTAssertTrue(
            result.lines.isEmpty,
            "an oversized unterminated tail is fatal too, so earlier same-chunk requests must not dispatch"
        )
    }

    func testOverflowIsTerminalAfterAnUnterminatedFlood() {
        // `MCPServer` stops on overflow, but the framer itself must not
        // silently recover if another caller accidentally keeps feeding it.
        var framer = LineFramer()
        _ = framer.feed(Data(repeating: UInt8(ascii: "x"), count: LineFramer.maxBufferBytes + 1))
        let again = framer.feed(Data("y".utf8))
        XCTAssertTrue(again.overflow)
        XCTAssertTrue(again.lines.isEmpty)
    }

    func testOverflowIsTerminalAfterACompleteOversizedLine() {
        // This was the missing counterpart to the unterminated-flood case:
        // the old implementation removed the oversized line, then accepted a
        // later request if a caller continued feeding after the fatal result.
        var framer = LineFramer()
        let oversized = Data(repeating: UInt8(ascii: "x"), count: LineFramer.maxBufferBytes + 1)
            + Data("\n".utf8)
        XCTAssertTrue(framer.feed(oversized).overflow)

        let later = framer.feed(Data("{\"method\":\"tools/call\"}\n".utf8))
        XCTAssertTrue(later.overflow)
        XCTAssertTrue(later.lines.isEmpty, "no request may be emitted after a terminal framing violation")
    }
}
