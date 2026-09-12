import Foundation
import XCTest
@testable import AIChalkboardCore

/// Pins `AnnotationRenderer.drawVectorPath`'s dispatch onto
/// `CombinedFillStrokeDrawingContext` -- the convert-once fast path a
/// platform context MAY adopt when it can share one converted path between
/// a fill and a stroke of the same geometry.
///
/// These tests are about WHICH drawing-context entry points the renderer
/// calls, not about pixels (`AnnotationVerificationCompositorTests` owns the
/// pixel-level coverage on macOS), so they use recording fakes and run
/// identically on both platforms. The three properties pinned here are the
/// ones a regression would silently break:
///   1. a filled+stroked path on an ADOPTING context makes exactly one
///      combined call -- the whole point of the fast path;
///   2. a filled+stroked path on a NON-adopting context still gets the
///      fill-then-stroke pair, in that order -- the Windows conformance
///      (`GDIPlusDrawingContext`) never adopts and must keep its behavior
///      byte-for-byte;
///   3. a fill-only or stroke-only path never takes the combined call even
///      on an adopting context -- the fast path exists solely for the
///      both-apply case.
final class AnnotationRendererTests: XCTestCase {

    // MARK: - Recording fakes

    private enum RecordedCall: Equatable {
        case fill
        case stroke
        case fillAndStroke
    }

    /// Minimal `DrawingContext` that records only the path-painting calls
    /// this suite dispatches on; every other requirement is a deliberate
    /// no-op.
    private class RecordingDrawingContext: DrawingContext {
        var calls: [RecordedCall] = []

        func save() {}
        func restore() {}
        func setGlobalAlpha(_ alpha: Double) {}
        func translate(x: Double, y: Double) {}
        func rotate(radians: Double) {}
        func fill(path: ChalkPath, color: ChalkColor, evenOdd: Bool) {
            calls.append(.fill)
        }
        func stroke(path: ChalkPath, color: ChalkColor, lineWidth: Double, dash: [Double]) {
            calls.append(.stroke)
        }
        func fill(rect: CGRect, color: ChalkColor) {}
        func drawImage(_ handle: RasterImageHandle, in rect: CGRect, alpha: Double) {}
        func measureText(_ text: String, fontSize: Double) -> CGSize {
            CGSize(width: 10, height: 10)
        }
        func drawText(_ text: String, in rect: CGRect, fontSize: Double, color: ChalkColor) {}
    }

    /// The same recorder, additionally adopting the combined fast path --
    /// standing in for `CoreGraphicsDrawingContext`'s adoption without
    /// needing a real `CGContext`.
    private final class CombinedRecordingDrawingContext: RecordingDrawingContext,
                                                         CombinedFillStrokeDrawingContext {
        func fillAndStroke(
            path: ChalkPath, fillColor: ChalkColor, evenOdd: Bool,
            strokeColor: ChalkColor, lineWidth: Double, dash: [Double]
        ) {
            calls.append(.fillAndStroke)
        }
    }

    // MARK: - Fixtures

    private func vectorAnnotation(fillColorHex: String?, strokeWidth: Double) -> Annotation {
        Annotation(
            id: UUID().uuidString, screenId: "screen-1",
            kind: .vectorPath(
                data: "M 10 10 L 90 10 L 90 90 Z",
                strokeColorHex: "#FF0000", strokeWidth: strokeWidth, strokeOpacity: 1,
                fillColorHex: fillColorHex, fillOpacity: 1, dash: [],
                usesEvenOddFillRule: false,
                coordinateScaleX: 1, coordinateScaleY: 1
            ),
            colorHex: "#00FF00"
        )
    }

    private func draw(_ annotation: Annotation, into context: DrawingContext) {
        AnnotationRenderer.drawAnnotations(
            [annotation], into: context,
            canvasSize: CGSize(width: 200, height: 200), scaleFactor: 1
        ) { _ in nil }
    }

    // MARK: - Dispatch

    func testFilledAndStrokedPathMakesExactlyOneCombinedCallOnAnAdoptingContext() {
        let context = CombinedRecordingDrawingContext()
        draw(vectorAnnotation(fillColorHex: "#0000FF", strokeWidth: 4), into: context)
        XCTAssertEqual(context.calls, [.fillAndStroke])
    }

    func testFilledAndStrokedPathFallsBackToFillThenStrokeOnAPlainContext() {
        let context = RecordingDrawingContext()
        draw(vectorAnnotation(fillColorHex: "#0000FF", strokeWidth: 4), into: context)
        // Order is part of the contract: fill first, stroke composited on
        // top, exactly as every frame has always painted.
        XCTAssertEqual(context.calls, [.fill, .stroke])
    }

    func testFillOnlyPathNeverTakesTheCombinedCall() {
        let context = CombinedRecordingDrawingContext()
        draw(vectorAnnotation(fillColorHex: "#0000FF", strokeWidth: 0), into: context)
        XCTAssertEqual(context.calls, [.fill])
    }

    func testStrokeOnlyPathNeverTakesTheCombinedCall() {
        let context = CombinedRecordingDrawingContext()
        draw(vectorAnnotation(fillColorHex: nil, strokeWidth: 4), into: context)
        XCTAssertEqual(context.calls, [.stroke])
    }
}
