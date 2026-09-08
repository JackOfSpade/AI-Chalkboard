import XCTest
@testable import AIChalkboardCore

/// Exercises the pure `avoid` boundary: structural request validation and
/// response serialization.  Rendering existing annotations and committing a
/// collision-free draw deliberately remain outside this suite because those
/// steps need the live off-screen compositor/store; the parser and response
/// contract do not.
final class DrawRequestAvoidanceTests: XCTestCase {
    // MARK: - parseAvoidanceArguments

    func testAvoidanceParserAcceptsIDsInCallerOrder() {
        switch DrawRequest.parseAvoidanceArguments([
            "avoid": ["first-annotation", "second-annotation", "third-annotation"]
        ]) {
        case .success(let request):
            XCTAssertEqual(request?.annotationIds, ["first-annotation", "second-annotation", "third-annotation"])
        case .failure(let message):
            XCTFail("valid ordered annotation IDs unexpectedly failed: \(message)")
        }
    }

    func testAvoidanceParserTreatsOmissionAsNoAvoidanceRequest() {
        switch DrawRequest.parseAvoidanceArguments([:]) {
        case .success(let request): XCTAssertNil(request)
        case .failure(let message): XCTFail("omitted avoid unexpectedly failed: \(message)")
        }
    }

    func testAvoidanceParserRejectsNonArrayAndEmptyArray() {
        assertFailure(DrawRequest.parseAvoidanceArguments(["avoid": "annotation-id"]), contains: "array")
        assertFailure(DrawRequest.parseAvoidanceArguments(["avoid": [Any]()]), contains: "1...")
    }

    func testAvoidanceParserRejectsMoreThanTheMaximumNumberOfIDs() {
        let ids = (0...DrawingDefaults.maxAvoidedAnnotations).map { "annotation-\($0)" }
        assertFailure(DrawRequest.parseAvoidanceArguments(["avoid": ids]), contains: "1...\(DrawingDefaults.maxAvoidedAnnotations)")
    }

    func testAvoidanceParserRejectsANonStringID() {
        assertFailure(DrawRequest.parseAvoidanceArguments(["avoid": [42]]), contains: "avoid[0]")
    }

    func testAvoidanceParserRejectsBlankAndOverlengthIDs() {
        assertFailure(DrawRequest.parseAvoidanceArguments(["avoid": [" \n\t "]]), contains: "non-whitespace")
        assertFailure(DrawRequest.parseAvoidanceArguments(["avoid": [String(repeating: "a", count: 129)]]), contains: "1...128")
    }

    func testAvoidanceParserRejectsDuplicatesAfterWhitespaceNormalization() {
        assertFailure(
            DrawRequest.parseAvoidanceArguments(["avoid": ["existing", "  existing  "]]),
            contains: "duplicate"
        )
    }

    // MARK: - avoidanceResponsePayload

    func testAvoidanceResponseReportsExactRequestedAndFinalPlacement() throws {
        let requested = CGRect(x: 12.5, y: 24.25, width: 100.75, height: 30.5)
        let final = CGRect(x: 12.5, y: 62.25, width: 100.75, height: 30.5)
        let resolution = DrawRequest.AvoidanceResolution(
            annotationIds: ["highlight-a", "highlight-b"],
            avoidanceTokens: [],
            requestedPaintedBounds: requested,
            finalPaintedBounds: final,
            offsetX: 0,
            offsetY: 38,
            placement: .below
        )

        let payload = DrawRequest.avoidanceResponsePayload(resolution)
        XCTAssertEqual(payload["avoidedAnnotationIds"] as? [String], ["highlight-a", "highlight-b"])
        XCTAssertEqual(try rectPayload(payload, key: "requestedPaintedBoundsBackingPx"), requested)
        XCTAssertEqual(try rectPayload(payload, key: "paintedBoundsBackingPx"), final)
        XCTAssertEqual(try XCTUnwrap(payload["offsetBackingPx"] as? [String: Double]), ["x": 0, "y": 38])
        XCTAssertEqual(payload["moved"] as? Bool, true)
        XCTAssertEqual(payload["placement"] as? String, "below")
        XCTAssertEqual(payload["gapPx"] as? Double, DrawingDefaults.annotationAvoidanceGapPx)
        XCTAssertEqual(payload["scope"] as? String, "draw_time_snapshot")
        let note = try XCTUnwrap(payload["note"] as? String)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("creation time"), note)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("later"), note)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("overlap"), note)
    }

    func testAvoidanceResponseMarksAnUnmovedPlacementFalse() {
        let bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        let resolution = DrawRequest.AvoidanceResolution(
            annotationIds: ["already-clear"], avoidanceTokens: [],
            requestedPaintedBounds: bounds, finalPaintedBounds: bounds,
            offsetX: 0, offsetY: 0, placement: .unchanged
        )
        let payload = DrawRequest.avoidanceResponsePayload(resolution)
        XCTAssertEqual(payload["moved"] as? Bool, false)
        XCTAssertEqual(payload["placement"] as? String, "unchanged")
    }

    // MARK: - Helpers

    private func assertFailure(
        _ outcome: DrawOutcome<DrawRequest.AvoidanceArgumentRequest?>,
        contains expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case .success(let request):
            XCTFail("expected avoidance parse failure containing \(expectedSubstring), got \(String(describing: request))", file: file, line: line)
        case .failure(let message):
            XCTAssertTrue(message.contains(expectedSubstring), "expected \(message) to contain \(expectedSubstring)", file: file, line: line)
        }
    }

    private func rectPayload(
        _ payload: [String: Any], key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        let rect = try XCTUnwrap(payload[key] as? [String: Double], "missing or malformed \(key)", file: file, line: line)
        guard let x = rect["x"], let y = rect["y"],
              let width = rect["width"], let height = rect["height"] else {
            XCTFail("\(key) must contain x, y, width, and height", file: file, line: line)
            return .zero
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
