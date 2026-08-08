import Foundation
import XCTest
@testable import AIChalkboardCore

/// `list_annotations` re-encodes annotations through a plain `JSONEncoder()`
/// and hands the result straight to MCP clients, so this on-the-wire shape is
/// a contract other code (and other people's MCP clients) depends on. These
/// tests round-trip every one of the six `AnnotationKind` cases through
/// `JSONEncoder`/`JSONDecoder`, and separately inspect the raw JSON structure
/// (via `JSONSerialization`, not assumptions) to confirm `kind` encodes as the
/// nested `{"<type>": {...}}` shape `AnnotationKind`'s own doc comment
/// describes.
final class AnnotationCodableTests: XCTestCase {
    private func assertKindsEqual(
        _ lhs: AnnotationKind, _ rhs: AnnotationKind,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch (lhs, rhs) {
        case let (.circle(x1, y1, r1), .circle(x2, y2, r2)):
            XCTAssertEqual(x1, x2, file: file, line: line)
            XCTAssertEqual(y1, y2, file: file, line: line)
            XCTAssertEqual(r1, r2, file: file, line: line)
        case let (.arrow(x1, y1, x2, y2), .arrow(x3, y3, x4, y4)):
            XCTAssertEqual(x1, x3, file: file, line: line)
            XCTAssertEqual(y1, y3, file: file, line: line)
            XCTAssertEqual(x2, x4, file: file, line: line)
            XCTAssertEqual(y2, y4, file: file, line: line)
        case let (.box(x1, y1, w1, h1), .box(x2, y2, w2, h2)):
            XCTAssertEqual(x1, x2, file: file, line: line)
            XCTAssertEqual(y1, y2, file: file, line: line)
            XCTAssertEqual(w1, w2, file: file, line: line)
            XCTAssertEqual(h1, h2, file: file, line: line)
        case let (.label(x1, y1, t1), .label(x2, y2, t2)):
            XCTAssertEqual(x1, x2, file: file, line: line)
            XCTAssertEqual(y1, y2, file: file, line: line)
            XCTAssertEqual(t1, t2, file: file, line: line)
        case let (.grid(s1), .grid(s2)):
            XCTAssertEqual(s1, s2, file: file, line: line)
        case let (.path(p1, s1, c1), .path(p2, s2, c2)):
            XCTAssertEqual(p1, p2, file: file, line: line)
            XCTAssertEqual(s1, s2, file: file, line: line)
            XCTAssertEqual(c1, c2, file: file, line: line)
        default:
            XCTFail("kind mismatch: \(lhs) vs \(rhs)", file: file, line: line)
        }
    }

    private func assertRoundTrips(
        _ original: Annotation,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)

        XCTAssertEqual(decoded.id, original.id, file: file, line: line)
        XCTAssertEqual(decoded.screenId, original.screenId, file: file, line: line)
        XCTAssertEqual(decoded.colorHex, original.colorHex, file: file, line: line)
        XCTAssertEqual(decoded.label, original.label, file: file, line: line)
        XCTAssertEqual(decoded.appId, original.appId, file: file, line: line)
        XCTAssertEqual(decoded.appName, original.appName, file: file, line: line)
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970,
            accuracy: 0.001,
            file: file, line: line
        )
        assertKindsEqual(decoded.kind, original.kind, file: file, line: line)
    }

    // MARK: - Round trip, every kind

    func testRoundTripPreservesEveryFieldForEveryKind() throws {
        let kinds: [AnnotationKind] = [
            .circle(x: 10, y: 20, radius: 5),
            .arrow(x1: 1, y1: 2, x2: 3, y2: 4),
            .box(x: 5, y: 6, width: 7, height: 8),
            .label(x: 9, y: 10, text: "hello world"),
            .grid(stepPx: 150),
            .path(points: [[1, 2], [3, 4], [5, 6]], strokeWidth: 2.5, isClosed: true)
        ]

        for (index, kind) in kinds.enumerated() {
            // Alternate label/appId/appName present vs. nil so the optional
            // fields' round trip is exercised both ways, not just the
            // all-present or all-nil case.
            let withLinkage = index.isMultiple(of: 2)
            let annotation = Annotation(
                screenId: "screen-\(index)",
                kind: kind,
                colorHex: "#ABCDEF",
                label: withLinkage ? "label-\(index)" : nil,
                appId: withLinkage ? "com.example.app\(index)" : nil,
                appName: withLinkage ? "Example App \(index)" : nil
            )
            try assertRoundTrips(annotation)
        }
    }

    // MARK: - Wire shape: {"kind": {"<type>": {...}}}

    func testCircleKindEncodesAsNestedCircleObject() throws {
        let annotation = Annotation(screenId: "1", kind: .circle(x: 10, y: 20, radius: 5))
        let json = try wireJSON(for: annotation)
        let kindJSON = try XCTUnwrap(json["kind"] as? [String: Any])
        XCTAssertEqual(kindJSON.count, 1, "kind must encode as a single-key nested object")
        let circleJSON = try XCTUnwrap(kindJSON["circle"] as? [String: Any])
        XCTAssertEqual(circleJSON["x"] as? Double, 10)
        XCTAssertEqual(circleJSON["y"] as? Double, 20)
        XCTAssertEqual(circleJSON["radius"] as? Double, 5)
    }

    func testArrowKindEncodesAsNestedArrowObject() throws {
        let annotation = Annotation(screenId: "1", kind: .arrow(x1: 1, y1: 2, x2: 3, y2: 4))
        let json = try wireJSON(for: annotation)
        let kindJSON = try XCTUnwrap(json["kind"] as? [String: Any])
        let arrowJSON = try XCTUnwrap(kindJSON["arrow"] as? [String: Any])
        XCTAssertEqual(arrowJSON["x1"] as? Double, 1)
        XCTAssertEqual(arrowJSON["y1"] as? Double, 2)
        XCTAssertEqual(arrowJSON["x2"] as? Double, 3)
        XCTAssertEqual(arrowJSON["y2"] as? Double, 4)
    }

    func testBoxKindEncodesAsNestedBoxObject() throws {
        let annotation = Annotation(screenId: "1", kind: .box(x: 1, y: 2, width: 3, height: 4))
        let json = try wireJSON(for: annotation)
        let kindJSON = try XCTUnwrap(json["kind"] as? [String: Any])
        let boxJSON = try XCTUnwrap(kindJSON["box"] as? [String: Any])
        XCTAssertEqual(boxJSON["x"] as? Double, 1)
        XCTAssertEqual(boxJSON["y"] as? Double, 2)
        XCTAssertEqual(boxJSON["width"] as? Double, 3)
        XCTAssertEqual(boxJSON["height"] as? Double, 4)
    }

    func testLabelKindEncodesAsNestedLabelObject() throws {
        let annotation = Annotation(screenId: "1", kind: .label(x: 1, y: 2, text: "hi"))
        let json = try wireJSON(for: annotation)
        let kindJSON = try XCTUnwrap(json["kind"] as? [String: Any])
        let labelJSON = try XCTUnwrap(kindJSON["label"] as? [String: Any])
        XCTAssertEqual(labelJSON["x"] as? Double, 1)
        XCTAssertEqual(labelJSON["y"] as? Double, 2)
        XCTAssertEqual(labelJSON["text"] as? String, "hi")
    }

    func testGridKindEncodesAsNestedGridObject() throws {
        let annotation = Annotation(screenId: "1", kind: .grid(stepPx: 250))
        let json = try wireJSON(for: annotation)
        let kindJSON = try XCTUnwrap(json["kind"] as? [String: Any])
        let gridJSON = try XCTUnwrap(kindJSON["grid"] as? [String: Any])
        XCTAssertEqual(gridJSON["stepPx"] as? Double, 250)
    }

    func testPathKindEncodesAsNestedPathObject() throws {
        let annotation = Annotation(screenId: "1", kind: .path(points: [[1, 2], [3, 4]], strokeWidth: 2, isClosed: false))
        let json = try wireJSON(for: annotation)
        let kindJSON = try XCTUnwrap(json["kind"] as? [String: Any])
        let pathJSON = try XCTUnwrap(kindJSON["path"] as? [String: Any])
        XCTAssertEqual(pathJSON["points"] as? [[Double]], [[1, 2], [3, 4]])
        XCTAssertEqual(pathJSON["strokeWidth"] as? Double, 2)
        XCTAssertEqual(pathJSON["isClosed"] as? Bool, false)
    }

    private func wireJSON(for annotation: Annotation) throws -> [String: Any] {
        let data = try JSONEncoder().encode(annotation)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }
}
