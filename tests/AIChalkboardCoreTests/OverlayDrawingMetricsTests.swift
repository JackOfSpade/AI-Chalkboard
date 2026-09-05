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

    /// `rendererScaleFactor` is the SINGLE definition of the divisor handed to
    /// `AnnotationRenderer.drawAnnotations` for a full-display canvas, read by
    /// both live overlays AND both `AnnotationVerificationCompositor`
    /// branches. Pinning it here is what keeps the two paths from drifting
    /// apart again: the Windows verifier used to pass the display's backing
    /// scale against the same physical-pixel canvas the live window paints
    /// 1:1, so on a 150%-DPI monitor a circle drawn live at (1920, 1080)
    /// r=200 was verified at (1280, 720) r=133 -- a picture of a placement
    /// nothing ever painted.
    func testRendererScaleFactorIsTheBackingScaleOnMacOSAndExactlyOneOnWindows() {
        #if os(Windows)
        // A Windows overlay draws on a PHYSICAL-PIXEL canvas whose
        // coordinates already ARE the MCP coordinates, so the divisor is 1 at
        // every DPI -- the argument is ignored by contract. This branch does
        // not run on macOS, but it must keep compiling here so the
        // cross-platform contract cannot rot unnoticed.
        XCTAssertEqual(OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 1), 1)
        XCTAssertEqual(OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 1.5), 1)
        XCTAssertEqual(OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 2), 1)
        #else
        // A macOS overlay draws on a POINT canvas, so MCP backing pixels
        // divide by the display's backing scale -- the value is passed
        // straight through.
        XCTAssertEqual(OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 1), 1)
        XCTAssertEqual(OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 2), 2)
        XCTAssertEqual(OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 3), 3)
        #endif
    }

    func testPointCombinesXScalingAndYFlip() {
        let viewHeight: CGFloat = 800
        let point = OverlayDrawingMetrics.point(forPhysicalPixelX: 200, y: 0, backingScaleFactor: 2, viewHeightPoints: viewHeight)
        XCTAssertEqual(point.x, 100) // 200px / 2x scale
        XCTAssertEqual(point.y, viewHeight) // top of MCP space -> near viewHeight, not near 0
    }
}
