import Foundation
import XCTest
@testable import AIChalkboardCore

/// Pure layout tests: no display, annotation store, or renderer is involved.
/// The eventual MCP surface can therefore use this exact policy for both a
/// prospective draw and a standalone layout helper.
final class AnnotationCollisionLayoutTests: XCTestCase {
    func testLeavesAnAlreadyClearPlacementAlone() throws {
        let proposed = CGRect(x: 10, y: 20, width: 30, height: 12)
        let resolution = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: proposed,
            avoiding: [CGRect(x: 100, y: 100, width: 20, height: 20)]
        ))

        XCTAssertEqual(resolution.placed, proposed)
        XCTAssertEqual(resolution.offset, .zero)
        XCTAssertEqual(resolution.placement, .unchanged)
    }

    func testMovesOverlappingSquareLabelBelowOnAnEqualDistanceTie() throws {
        // Every side requires a 28px translation: label 20 + gap 8. The
        // documented direction tie-break therefore selects below.
        let resolution = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 10, y: 10, width: 20, height: 20),
            avoiding: [CGRect(x: 10, y: 10, width: 20, height: 20)],
            padding: 8
        ))

        XCTAssertEqual(resolution.placed, CGRect(x: 10, y: 38, width: 20, height: 20))
        XCTAssertEqual(resolution.offset, CGPoint(x: 0, y: 28))
        XCTAssertEqual(resolution.placement, .below)
    }

    func testGapIsAppliedAndEdgeTouchWithoutGapIsNotACollision() throws {
        let withoutGap = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 0, y: 10, width: 10, height: 10),
            avoiding: [CGRect(x: 10, y: 10, width: 10, height: 10)],
            padding: 0
        ))
        XCTAssertEqual(withoutGap.placement, .unchanged)

        let withGap = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 10, y: 10, width: 10, height: 10),
            avoiding: [CGRect(x: 10, y: 10, width: 10, height: 10)],
            padding: 4
        ))
        XCTAssertEqual(withGap.placed, CGRect(x: 10, y: 24, width: 10, height: 10))
    }

    func testContinuesNudgingUntilItClearsAStackOfAvoidedRects() throws {
        let resolution = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 10, y: 10, width: 20, height: 20),
            avoiding: [
                CGRect(x: 10, y: 10, width: 20, height: 20),
                CGRect(x: 10, y: 30, width: 20, height: 20)
            ],
            padding: 2,
            // The label cannot go above the first item on this display, so
            // the search must continue its initial below nudge through the
            // second item instead of taking the otherwise-shorter above path.
            within: CGRect(x: 0, y: 0, width: 30, height: 100)
        ))

        // The first below candidate (y: 32) hits the second avoided rect;
        // expanding it again yields y: 52 with the requested 2px gap.
        XCTAssertEqual(resolution.placed, CGRect(x: 10, y: 52, width: 20, height: 20))
        XCTAssertEqual(resolution.placement, .below)
    }

    func testUsesAnotherSideWhenBelowWouldLeaveTheContainer() throws {
        let resolution = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 40, y: 70, width: 20, height: 20),
            avoiding: [CGRect(x: 40, y: 70, width: 20, height: 20)],
            padding: 5,
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))

        XCTAssertEqual(resolution.placed, CGRect(x: 40, y: 45, width: 20, height: 20))
        XCTAssertEqual(resolution.placement, .above)
    }

    func testMultipleObstaclesProduceTheSameResultRegardlessOfAvoidListOrder() throws {
        let proposed = CGRect(x: 10, y: 10, width: 20, height: 20)
        let obstacles = [
            CGRect(x: 10, y: 10, width: 20, height: 20),
            CGRect(x: 10, y: 32, width: 20, height: 20)
        ]
        let container = CGRect(x: 0, y: 0, width: 30, height: 100)

        let forward = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: proposed, avoiding: obstacles, padding: 2, within: container
        ))
        let reversed = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: proposed, avoiding: Array(obstacles.reversed()), padding: 2, within: container
        ))

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.placed, CGRect(x: 10, y: 54, width: 20, height: 20))
    }

    func testLargeCanvasCoordinatesRemainFiniteAndUseTheSamePolicy() throws {
        // This represents a very large virtual desktop. It catches accidental
        // integer conversion/overflow in the layout math while retaining the
        // normal below-first tie-break for equal-size rectangles.
        let proposed = CGRect(x: 9_000_000, y: 9_000_000, width: 1_000, height: 1_000)
        let resolution = try XCTUnwrap(AnnotationCollisionLayout.resolve(
            proposed: proposed,
            avoiding: [proposed],
            padding: 10,
            within: CGRect(x: 0, y: 0, width: 10_000_000, height: 10_000_000)
        ))

        XCTAssertEqual(resolution.placed, CGRect(x: 9_000_000, y: 9_001_010, width: 1_000, height: 1_000))
        XCTAssertTrue(resolution.placed.minX.isFinite)
        XCTAssertTrue(resolution.placed.minY.isFinite)
    }

    func testReturnsNilWhenContainerHasNoClearPlacement() {
        XCTAssertNil(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 0, y: 0, width: 20, height: 20),
            avoiding: [CGRect(x: 0, y: 0, width: 100, height: 100)],
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))
    }

    func testRejectsInvalidCandidateGeometry() {
        XCTAssertNil(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 0, y: 0, width: 0, height: 10),
            avoiding: []
        ))
        XCTAssertNil(AnnotationCollisionLayout.resolve(
            proposed: CGRect(x: 0, y: 0, width: 10, height: 10),
            avoiding: [],
            padding: -.leastNonzeroMagnitude
        ))
    }
}
