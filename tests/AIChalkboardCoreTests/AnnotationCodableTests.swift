import Foundation
import XCTest
@testable import AIChalkboardCore

/// Annotation JSON is the MCP-facing persistence shape.  These tests pin the
/// three free-drawing primitives and, critically, recursive batches.
final class AnnotationCodableTests: XCTestCase {
    private func path(_ data: String = "M10 20 L30 40") -> AnnotationKind {
        .vectorPath(
            data: data,
            strokeColorHex: "#123456",
            strokeWidth: 2.5,
            strokeOpacity: 0.8,
            fillColorHex: "#ABCDEF",
            fillOpacity: 0.35,
            dash: [3, 2],
            usesEvenOddFillRule: true,
            coordinateScaleX: 1.5,
            coordinateScaleY: 2.0
        )
    }

    private func assertKindsEqual(_ lhs: AnnotationKind, _ rhs: AnnotationKind,
                                  file: StaticString = #filePath, line: UInt = #line) {
        switch (lhs, rhs) {
        case let (.vectorPath(a, b, c, d, e, f, g, h, i, j), .vectorPath(k, l, m, n, o, p, q, r, s, t)):
            XCTAssertEqual(a, k, file: file, line: line)
            XCTAssertEqual(b, l, file: file, line: line)
            XCTAssertEqual(c, m, file: file, line: line)
            XCTAssertEqual(d, n, file: file, line: line)
            XCTAssertEqual(e, o, file: file, line: line)
            XCTAssertEqual(f, p, file: file, line: line)
            XCTAssertEqual(g, q, file: file, line: line)
            XCTAssertEqual(h, r, file: file, line: line)
            XCTAssertEqual(i, s, file: file, line: line)
            XCTAssertEqual(j, t, file: file, line: line)
        case let (.image(a, b, c, d, e, f, g), .image(h, i, j, k, l, m, n)):
            XCTAssertEqual(a, h, file: file, line: line)
            XCTAssertEqual(b, i, file: file, line: line)
            XCTAssertEqual(c, j, file: file, line: line)
            XCTAssertEqual(d, k, file: file, line: line)
            XCTAssertEqual(e, l, file: file, line: line)
            XCTAssertEqual(f, m, file: file, line: line)
            XCTAssertEqual(g, n, file: file, line: line)
        case let (.text(a, b, c, d, e, f, g, h, i), .text(j, k, l, m, n, o, p, q, r)):
            XCTAssertEqual(a, j, file: file, line: line)
            XCTAssertEqual(b, k, file: file, line: line)
            XCTAssertEqual(c, l, file: file, line: line)
            XCTAssertEqual(d, m, file: file, line: line)
            XCTAssertEqual(e, n, file: file, line: line)
            XCTAssertEqual(f, o, file: file, line: line)
            XCTAssertEqual(g, p, file: file, line: line)
            XCTAssertEqual(h, q, file: file, line: line)
            XCTAssertEqual(i, r, file: file, line: line)
        case let (.batch(left), .batch(right)):
            XCTAssertEqual(left.count, right.count, file: file, line: line)
            for (l, r) in zip(left, right) {
                XCTAssertEqual(l.colorHex, r.colorHex, file: file, line: line)
                XCTAssertEqual(l.label, r.label, file: file, line: line)
                assertKindsEqual(l.kind, r.kind, file: file, line: line)
            }
        default:
            XCTFail("kind mismatch: \(lhs) vs \(rhs)", file: file, line: line)
        }
    }

    private func assertRoundTrips(_ original: Annotation,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.id, original.id, file: file, line: line)
        XCTAssertEqual(decoded.screenId, original.screenId, file: file, line: line)
        XCTAssertEqual(decoded.colorHex, original.colorHex, file: file, line: line)
        XCTAssertEqual(decoded.label, original.label, file: file, line: line)
        XCTAssertEqual(decoded.appId, original.appId, file: file, line: line)
        XCTAssertEqual(decoded.appName, original.appName, file: file, line: line)
        XCTAssertEqual(decoded.opacity, original.opacity, file: file, line: line)
        XCTAssertEqual(decoded.offsetX, original.offsetX, file: file, line: line)
        XCTAssertEqual(decoded.offsetY, original.offsetY, file: file, line: line)
        XCTAssertEqual(decoded.zIndex, original.zIndex, file: file, line: line)
        XCTAssertEqual(decoded.revision, 0, "store revision is intentionally not part of MCP's annotation wire shape", file: file, line: line)
        if let expectedExpiry = original.expiresAt {
            XCTAssertEqual(try XCTUnwrap(decoded.expiresAt, file: file, line: line).timeIntervalSince1970,
                           expectedExpiry.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
        } else {
            XCTAssertNil(decoded.expiresAt, file: file, line: line)
        }
        assertKindsEqual(decoded.kind, original.kind, file: file, line: line)
    }

    func testRoundTripPreservesEveryFieldForEveryFreeDrawingKind() throws {
        let nested = AnnotationKind.batch(items: [
            AnnotationComponent(kind: path("M0 0 L20 20"), colorHex: "#00FF00", label: "inner-path"),
            AnnotationComponent(kind: .image(assetId: "asset-nested", x: 1, y: 2, width: 3, height: 4, rotationDegrees: 5, opacity: 0.6), colorHex: "#FFFFFF")
        ])
        let kinds: [AnnotationKind] = [
            path(),
            .image(assetId: "asset-1", x: 10, y: 20, width: 30, height: 40, rotationDegrees: 15, opacity: 0.75),
            .text(text: "Hello", x: 10, y: 20, fontSize: 18, textColorHex: "#FFFFFF", backgroundColorHex: "#000000", backgroundOpacity: 0.5, paddingPx: 3, opacity: 0.75),
            .batch(items: [
                AnnotationComponent(kind: path("M5 5 H25"), colorHex: "#FF0000", label: "path"),
                AnnotationComponent(kind: nested, colorHex: "#0000FF", label: "nested")
            ])
        ]
        for (index, kind) in kinds.enumerated() {
            try assertRoundTrips(Annotation(
                screenId: "screen-\(index)", kind: kind, colorHex: "#ABCDEF",
                label: index.isMultiple(of: 2) ? "annotation-\(index)" : nil,
                appId: index.isMultiple(of: 2) ? "com.example.app" : nil,
                appName: index.isMultiple(of: 2) ? "Example" : nil,
                expiresAt: index.isMultiple(of: 2) ? Date().addingTimeInterval(60) : nil,
                opacity: 0.8, offsetX: 3, offsetY: 4, zIndex: index
            ))
        }
    }

    func testVectorPathWireShapeCarriesStyleFields() throws {
        let json = try wireJSON(for: Annotation(screenId: "1", kind: path()))
        let kind = try XCTUnwrap(json["kind"] as? [String: Any])
        let vector = try XCTUnwrap(kind["vectorPath"] as? [String: Any])
        XCTAssertEqual(vector["data"] as? String, "M10 20 L30 40")
        XCTAssertEqual(vector["strokeWidth"] as? Double, 2.5)
        XCTAssertEqual(vector["strokeOpacity"] as? Double, 0.8)
        XCTAssertEqual(vector["fillOpacity"] as? Double, 0.35)
        XCTAssertEqual(vector["dash"] as? [Double], [3, 2])
        XCTAssertEqual(vector["usesEvenOddFillRule"] as? Bool, true)
        XCTAssertEqual(vector["coordinateScaleX"] as? Double, 1.5)
    }

    func testImageAndRecursiveBatchWireShapesRemainNested() throws {
        let kind = AnnotationKind.batch(items: [
            AnnotationComponent(kind: .image(assetId: "asset-2", x: 2, y: 3, width: 4, height: 5, rotationDegrees: 6, opacity: 0.7), colorHex: "#FFFFFF"),
            AnnotationComponent(kind: .batch(items: [AnnotationComponent(kind: path(), colorHex: "#000000")]), colorHex: "#00FF00")
        ])
        let json = try wireJSON(for: Annotation(screenId: "1", kind: kind))
        let top = try XCTUnwrap(json["kind"] as? [String: Any])
        let batch = try XCTUnwrap(top["batch"] as? [String: Any])
        let items = try XCTUnwrap(batch["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let imageKind = try XCTUnwrap(items[0]["kind"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(imageKind["image"] as? [String: Any]))["assetId"] as? String, "asset-2")
        let nestedKind = try XCTUnwrap(items[1]["kind"] as? [String: Any])
        XCTAssertNotNil(nestedKind["batch"] as? [String: Any])
    }

    private func wireJSON(for annotation: Annotation) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(annotation)) as? [String: Any])
    }
}
