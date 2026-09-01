import Foundation
import XCTest
@testable import AIChalkboardCore

/// `OverlayDrawingMetrics` is the pure pixel-to-point and Y-flip math shared
/// by every `AnnotationRenderer.draw*` method. These tests exercise it
/// directly with no `NSView`/`NSGraphicsContext`/`DrawingContext` involved, so
/// a future edit that inverts the flip or breaks the zero-scale fallback
/// fails here instead of only being visible as a subtly-wrong on-screen
/// render.
final class OverlayDrawingMetricsTests: XCTestCase {
    func testPointsForPhysicalPixelsAt1xScale() {
        XCTAssertEqual(OverlayDrawingMetrics.points(forPhysicalPixels: 100, backingScaleFactor: 1), 100)
    }

    func testPointsForPhysicalPixelsAt2xScale() {
        XCTAssertEqual(OverlayDrawingMetrics.points(forPhysicalPixels: 100, backingScaleFactor: 2), 50)
    }

    func testZeroOrNegativeScaleFallsBackTo1x() {
        XCTAssertEqual(OverlayDrawingMetrics.points(forPhysicalPixels: 42, backingScaleFactor: 0), 42)
        XCTAssertEqual(OverlayDrawingMetrics.points(forPhysicalPixels: 42, backingScaleFactor: -2), 42)
    }

    func testYFlipMapsTopOfMCPSpaceNearViewHeightNotNearZero() {
        // MCP coordinates are top-left origin: y=0 is the TOP of the screen.
        // AppKit is bottom-left origin, so the top of the screen must land
        // near viewHeightPoints, not near 0. This is the easiest thing for a
        // future edit to invert, and nothing else catches it.
        let viewHeight: CGFloat = 800
        let flipped = OverlayDrawingMetrics.viewY(forPhysicalPixelY: 0, backingScaleFactor: 1, viewHeightPoints: viewHeight)
        XCTAssertEqual(flipped, viewHeight)
    }

    func testYFlipMapsBottomOfMCPSpaceToZero() {
        let viewHeight: CGFloat = 800
        let flipped = OverlayDrawingMetrics.viewY(forPhysicalPixelY: 800, backingScaleFactor: 1, viewHeightPoints: viewHeight)
        XCTAssertEqual(flipped, 0)
    }

    func testYFlipRoundTripsThroughBothEndsAt2xScale() {
        // At 2x scale, physical pixel 0 is still the top and physical pixel
        // 1600 (== viewHeightPoints * scale) is still the bottom.
        let viewHeight: CGFloat = 800
        let top = OverlayDrawingMetrics.viewY(forPhysicalPixelY: 0, backingScaleFactor: 2, viewHeightPoints: viewHeight)
        let bottom = OverlayDrawingMetrics.viewY(forPhysicalPixelY: 1600, backingScaleFactor: 2, viewHeightPoints: viewHeight)
        XCTAssertEqual(top, viewHeight)
        XCTAssertEqual(bottom, 0)
    }

    func testPointCombinesXScalingAndYFlip() {
        let viewHeight: CGFloat = 800
        let point = OverlayDrawingMetrics.point(forPhysicalPixelX: 200, y: 0, backingScaleFactor: 2, viewHeightPoints: viewHeight)
        XCTAssertEqual(point.x, 100) // 200px / 2x scale
        XCTAssertEqual(point.y, viewHeight) // top of MCP space -> near viewHeight, not near 0
    }
}
