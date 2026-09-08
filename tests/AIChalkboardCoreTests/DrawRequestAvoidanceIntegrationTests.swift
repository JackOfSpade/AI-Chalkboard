import Foundation
import XCTest
@testable import AIChalkboardCore

/// End-to-end draw-time avoidance coverage using an isolated real store and
/// the same off-screen renderer that powers `get_annotation_bounds`.  This is
/// deliberately platform-neutral: assertions compare renderer geometry and
/// annotation offsets rather than hard-coding a system font's glyph metrics.
final class DrawRequestAvoidanceIntegrationTests: XCTestCase {
    private func screen(id: String = "avoid-screen", width: Int = 300, height: Int = 200) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: "Avoidance Test Screen",
            widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: true
        )
    }

    private func filledRect(x: Double = 50, y: Double = 50, width: Double = 140, height: Double = 50) -> AnnotationKind {
        .vectorPath(
            data: "M \(x) \(y) H \(x + width) V \(y + height) H \(x) Z",
            strokeColorHex: nil, strokeWidth: 0, strokeOpacity: 0,
            fillColorHex: "#FF5500", fillOpacity: 1, dash: [], usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        )
    }

    private func labelKind() -> AnnotationKind {
        .text(
            text: "Read this control", x: 70, y: 60, fontSize: 18,
            textColorHex: "#FFFFFF", backgroundColorHex: "#000000",
            backgroundOpacity: 1, paddingPx: 6, opacity: 1
        )
    }

    private func renderedBounds(_ annotation: Annotation, on screen: ScreenInfo) throws -> CGRect {
        try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(of: annotation, on: screen))
    }

    private func finish(
        _ request: DrawRequest, args: [String: Any], kind: AnnotationKind, noun: String = "test"
    ) -> DrawOutcome<String> {
        request.finish(
            args: args, defaultColor: "#FFFFFF", label: nil, defaultsToGlobal: false,
            kind: kind, noun: noun
        )
    }

    private func successfulText(_ outcome: DrawOutcome<String>, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        switch outcome {
        case .success(let text): return text
        case .failure(let message):
            XCTFail("expected draw success, got: \(message)", file: file, line: line)
            return ""
        }
    }

    private func assertFailure(
        _ outcome: DrawOutcome<String>, contains expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch outcome {
        case .success(let text): XCTFail("expected failure containing \(expected), got success: \(text)", file: file, line: line)
        case .failure(let message): XCTAssertTrue(message.contains(expected), message, file: file, line: line)
        }
    }

    private func payloadRect(_ payload: [String: Any], key: String) throws -> CGRect {
        let values = try XCTUnwrap(payload[key] as? [String: Any], "missing \(key)")
        return CGRect(
            x: try XCTUnwrap((values["x"] as? NSNumber)?.doubleValue),
            y: try XCTUnwrap((values["y"] as? NSNumber)?.doubleValue),
            width: try XCTUnwrap((values["width"] as? NSNumber)?.doubleValue),
            height: try XCTUnwrap((values["height"] as? NSNumber)?.doubleValue)
        )
    }

    private func assertEqualRects(_ actual: CGRect, _ expected: CGRect,
                                  accuracy: Double = 0.001,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    func testAvoidanceMovesTextBackgroundAndReportsTheExactFinalRendererBounds() throws {
        let targetScreen = screen()
        let store = AnnotationStore()
        let highlight = Annotation(id: "highlight", screenId: targetScreen.id, kind: filledRect())
        XCTAssertEqual(store.addWithOutcome(highlight), .added)
        let request = DrawRequest(screen: targetScreen, annotationStore: store)

        let responseText = try successfulText(finish(
            request, args: ["app": "", "avoid": [highlight.id]], kind: labelKind(), noun: "text"
        ))
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseText.utf8)) as? [String: Any]
        )
        let placement = try XCTUnwrap(response["placement"] as? [String: Any])
        XCTAssertEqual(placement["moved"] as? Bool, true)
        XCTAssertEqual(placement["avoidedAnnotationIds"] as? [String], [highlight.id])

        let stored = try XCTUnwrap(store.getAll().last)
        XCTAssertEqual(response["annotationId"] as? String, stored.id)
        XCTAssertTrue(stored.offsetX != 0 || stored.offsetY != 0,
                      "avoidance must persist its annotation-wide nudge")

        let finalBounds = try renderedBounds(stored, on: targetScreen)
        let highlightBounds = try renderedBounds(highlight, on: targetScreen)
        XCTAssertFalse(AnnotationCollisionLayout.intersects(finalBounds, highlightBounds),
                       "the exact final renderer bounds must not have positive-area overlap")
        assertEqualRects(try payloadRect(placement, key: "paintedBoundsBackingPx"), finalBounds)
    }

    func testOmittingAvoidKeepsIntentionalOverlapAtZeroOffsetAndLegacyTextResponse() throws {
        let targetScreen = screen()
        let store = AnnotationStore()
        let highlight = Annotation(id: "highlight", screenId: targetScreen.id, kind: filledRect())
        XCTAssertEqual(store.addWithOutcome(highlight), .added)
        let request = DrawRequest(screen: targetScreen, annotationStore: store)

        let responseText = try successfulText(finish(
            request, args: ["app": ""], kind: labelKind(), noun: "text"
        ))
        XCTAssertTrue(responseText.hasPrefix("Created text annotation: "), responseText)
        XCTAssertFalse(responseText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                       "without avoid, legacy callers must continue receiving plain text")

        let stored = try XCTUnwrap(store.getAll().last)
        XCTAssertEqual(stored.offsetX, 0)
        XCTAssertEqual(stored.offsetY, 0)
        XCTAssertTrue(AnnotationCollisionLayout.intersects(
            try renderedBounds(stored, on: targetScreen), try renderedBounds(highlight, on: targetScreen)
        ), "omitting avoid must keep deliberate stacking available")
    }

    func testCreationCallbackReceivesTheRevisionAssignedToTheStoredAnnotation() throws {
        let targetScreen = screen()
        let store = AnnotationStore()
        let request = DrawRequest(screen: targetScreen, annotationStore: store)
        var created: Annotation?

        switch request.finish(
            args: ["app": ""], defaultColor: "#FFFFFF", label: nil,
            defaultsToGlobal: false, kind: labelKind(), noun: "text",
            onAnnotationCreated: { created = $0 }
        ) {
        case .failure(let message):
            return XCTFail("expected successful insertion, got: \(message)")
        case .success:
            break
        }

        let callbackAnnotation = try XCTUnwrap(created)
        let storedAnnotation = try XCTUnwrap(store.get(id: callbackAnnotation.id))
        XCTAssertGreaterThan(callbackAnnotation.revision, 0,
                             "callbacks that issue a follow-up CAS need the store-assigned revision")
        XCTAssertEqual(callbackAnnotation.revision, storedAnnotation.revision,
                       "the callback must receive the inserted snapshot, not the pre-insert revision-0 value")
    }

    func testMissingAndCrossScreenAvoidTargetsRejectWithoutInserting() {
        let targetScreen = screen()
        let missingStore = AnnotationStore()
        let missingRequest = DrawRequest(screen: targetScreen, annotationStore: missingStore)
        assertFailure(
            finish(missingRequest, args: ["app": "", "avoid": ["missing"]], kind: labelKind()),
            contains: "do not exist"
        )
        XCTAssertTrue(missingStore.getAll().isEmpty)

        let crossScreenStore = AnnotationStore()
        let otherScreenHighlight = Annotation(id: "other-screen", screenId: "different-screen", kind: filledRect())
        XCTAssertEqual(crossScreenStore.addWithOutcome(otherScreenHighlight), .added)
        let crossScreenRequest = DrawRequest(screen: targetScreen, annotationStore: crossScreenStore)
        assertFailure(
            finish(crossScreenRequest, args: ["app": "", "avoid": [otherScreenHighlight.id]], kind: labelKind()),
            contains: "currently on display"
        )
        XCTAssertEqual(crossScreenStore.getAll().map(\.id), [otherScreenHighlight.id],
                       "a failed cross-screen avoidance request must not insert its candidate")
    }

    func testAvoidanceMovesABatchThroughOneAnnotationOffsetAndPreservesComponentGeometry() throws {
        let targetScreen = screen()
        let store = AnnotationStore()
        let highlight = Annotation(id: "highlight", screenId: targetScreen.id, kind: filledRect())
        XCTAssertEqual(store.addWithOutcome(highlight), .added)
        let first = filledRect(x: 75, y: 65, width: 24, height: 14)
        let second = filledRect(x: 135, y: 72, width: 30, height: 14)
        let batch = AnnotationKind.batch(items: [
            AnnotationComponent(kind: first, colorHex: "#FF5500"),
            AnnotationComponent(kind: second, colorHex: "#FF5500")
        ])
        let request = DrawRequest(screen: targetScreen, annotationStore: store)

        _ = try successfulText(finish(
            request, args: ["app": "", "avoid": [highlight.id]], kind: batch, noun: "batch"
        ))
        let stored = try XCTUnwrap(store.getAll().last)
        XCTAssertTrue(stored.offsetX != 0 || stored.offsetY != 0)
        guard case let .batch(items) = stored.kind else {
            return XCTFail("expected stored batch")
        }
        XCTAssertEqual(items.count, 2)
        guard case let .vectorPath(firstData, _, _, _, _, _, _, _, _, _) = items[0].kind,
              case let .vectorPath(secondData, _, _, _, _, _, _, _, _, _) = items[1].kind,
              case let .vectorPath(expectedFirstData, _, _, _, _, _, _, _, _, _) = first,
              case let .vectorPath(expectedSecondData, _, _, _, _, _, _, _, _, _) = second else {
            return XCTFail("batch components should retain their original vector geometry")
        }
        XCTAssertEqual(firstData, expectedFirstData)
        XCTAssertEqual(secondData, expectedSecondData)

        let finalBounds = try renderedBounds(stored, on: targetScreen)
        XCTAssertFalse(AnnotationCollisionLayout.intersects(finalBounds, try renderedBounds(highlight, on: targetScreen)))
        let componentOneBefore = try renderedBounds(Annotation(screenId: targetScreen.id, kind: first), on: targetScreen)
        let componentOneAfter = try renderedBounds(
            Annotation(screenId: targetScreen.id, kind: first, offsetX: stored.offsetX, offsetY: stored.offsetY),
            on: targetScreen
        )
        XCTAssertEqual(componentOneAfter.minX - componentOneBefore.minX, stored.offsetX, accuracy: 0.001)
        XCTAssertEqual(componentOneAfter.minY - componentOneBefore.minY, stored.offsetY, accuracy: 0.001)
    }
}
