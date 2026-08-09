import Foundation
import XCTest
@testable import AIChalkboardCore

final class MCPResponseTransportTests: XCTestCase {
    func testOversizedSerializedResponseIsRejectedAndFallbackRemainsBounded() throws {
        let oversized: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "result": ["content": [["type": "text", "text": String(repeating: "x", count: DrawingDefaults.maxMCPResponseBytes)]]]
        ]
        XCTAssertNil(MCPResponseTransport.serializedLine(oversized))
        let fallback = try XCTUnwrap(MCPResponseTransport.compactOversizeErrorLine(id: 1))
        XCTAssertLessThanOrEqual(fallback.count, DrawingDefaults.maxMCPResponseBytes)
        let decoded = try JSONSerialization.jsonObject(with: Data(fallback.dropLast())) as? [String: Any]
        let result = try XCTUnwrap(decoded?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testCaptureFlightGateAllowsOnlyOneOutstandingCapture() {
        let gate = CaptureFlightGate()
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
        gate.release()
        XCTAssertTrue(gate.tryAcquire())
        gate.release()
    }
}
