import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `AnnotationGeometryVerdict` -- the pure painted-vs-target rectangle
/// comparison behind the geometry-only "did my highlight land on the
/// control?" answer (Sources/MCP/AnnotationGeometryVerdict.swift). Every
/// function here is a plain static func over `CGRect`/`Int` values, so this
/// suite drives it directly with no renderer, no accessibility resolver, and
/// no live display -- matching `AnnotationBoundsSupportTests`'s and
/// `DrawRequestScreenshotMappingTests`'s "decision separate from the runtime
/// plumbing" precedent.
final class AnnotationGeometryVerdictTests: XCTestCase {
    /// Every non-degenerate `Comparison` field this suite produces must be
    /// finite -- this is the exact defect `AnnotationGeometryVerdict.compare`
    /// exists to prevent, because a NaN or infinite `Double` cannot be
    /// encoded by `JSONSerialization`, which would fail this tool's WHOLE
    /// response, not just one field.
    private func assertAllFieldsFinite(_ comparison: AnnotationGeometryVerdict.Comparison, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(comparison.coverageOfTarget.isFinite, "coverageOfTarget must never be NaN/infinite", file: file, line: line)
        XCTAssertTrue(comparison.intersectionOverUnion.isFinite, "intersectionOverUnion must never be NaN/infinite", file: file, line: line)
        XCTAssertTrue(comparison.centerDeltaX.isFinite, "centerDeltaX must never be NaN/infinite", file: file, line: line)
        XCTAssertTrue(comparison.centerDeltaY.isFinite, "centerDeltaY must never be NaN/infinite", file: file, line: line)
    }

    // MARK: - Exact containment

    /// The simplest "on target" case: painted bounds exactly equal the
    /// target's rect. Full containment, coverage of exactly 1, and IoU of
    /// exactly 1.
    func testExactContainmentIsOnTargetWithFullCoverage() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 100)
        let comparison = AnnotationGeometryVerdict.compare(painted: rect, target: rect)
        XCTAssertTrue(comparison.containsTarget, "identical rects must contain each other")
        XCTAssertEqual(comparison.coverageOfTarget, 1, accuracy: 1e-9)
        XCTAssertEqual(comparison.intersectionOverUnion, 1, accuracy: 1e-9)
        XCTAssertEqual(comparison.centerDeltaX, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.centerDeltaY, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "on_target")
        assertAllFieldsFinite(comparison)
    }

    // MARK: - Padded ring: the realistic on_target case that is NOT exact containment

    /// THE case the 0.9 threshold exists for: a highlight drawn with
    /// deliberate padding legitimately does not touch every corner of the
    /// control it targets. Here `painted` is inset 2px on every side of a
    /// 100x100 target -- 96x96 = 9216 of 10000 target-area px covered
    /// (92.16%), comfortably over 0.9, but `painted` does NOT fully enclose
    /// `target` (the outer 2px border of the target is not covered), so
    /// `containsTarget` is false. A hard "must fully contain" test would
    /// wrongly call this well-aimed highlight a failure.
    func testPaddedRingInsideTargetIsOnTargetByCoverageNotContainment() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let painted = CGRect(x: 2, y: 2, width: 96, height: 96)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertFalse(comparison.containsTarget, "an inset painted rect does not fully enclose the target")
        XCTAssertEqual(comparison.coverageOfTarget, 0.9216, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "on_target", "0.9216 coverage clears the 0.9 threshold even without containment")
        assertAllFieldsFinite(comparison)
    }

    // MARK: - Partial overlap

    /// A painted rect overlapping exactly half of the target's area lands
    /// squarely in "partial": some coverage, but nowhere near the 0.9
    /// threshold and no containment.
    func testHalfOverlapIsPartial() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let painted = CGRect(x: 50, y: 0, width: 100, height: 100)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertFalse(comparison.containsTarget)
        XCTAssertEqual(comparison.coverageOfTarget, 0.5, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "partial")
        assertAllFieldsFinite(comparison)
    }

    // MARK: - Disjoint rects

    /// Rectangles that do not intersect at all: zero coverage, zero IoU
    /// (not an undefined 0/0 -- the union area here is positive), and
    /// "off_target".
    func testDisjointRectsAreOffTargetWithZeroIoU() {
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)
        let painted = CGRect(x: 100, y: 100, width: 10, height: 10)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertFalse(comparison.containsTarget)
        XCTAssertEqual(comparison.coverageOfTarget, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.intersectionOverUnion, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "off_target")
        assertAllFieldsFinite(comparison)
    }

    // MARK: - Degenerate rectangles

    /// A zero-area TARGET is the one case that could otherwise divide
    /// `intersectionArea / targetArea` by zero. `compare` defines coverage
    /// of a zero-area target as 0 rather than computing it -- asserted here
    /// alongside the finiteness check that is this test's real point.
    func testZeroAreaTargetProducesZeroCoverageNotNaN() {
        let target = CGRect(x: 10, y: 10, width: 0, height: 5)
        let painted = CGRect(x: 0, y: 0, width: 50, height: 50)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertEqual(comparison.coverageOfTarget, 0, "a zero-area target's coverage is defined as 0, not divided out")
        XCTAssertEqual(comparison.intersectionOverUnion, 0, accuracy: 1e-9)
        XCTAssertFalse(comparison.containsTarget, "a zero-area target cannot be reported as contained while its own coverage is defined as 0")
        XCTAssertEqual(comparison.verdict, "off_target")
        assertAllFieldsFinite(comparison)
    }

    /// A zero-area PAINTED rect never appears as a division's denominator,
    /// so it needs no special-case definition -- but this pins that the
    /// ordinary arithmetic still produces finite, sensible values (zero
    /// coverage of a positive-area target) rather than anything unexpected.
    func testZeroAreaPaintedRectProducesZeroCoverageNotNaN() {
        let target = CGRect(x: 0, y: 0, width: 50, height: 50)
        let painted = CGRect(x: 10, y: 10, width: 0, height: 5)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertEqual(comparison.coverageOfTarget, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.intersectionOverUnion, 0, accuracy: 1e-9)
        XCTAssertFalse(comparison.containsTarget, "a zero-area painted rect cannot enclose a positive-area target")
        XCTAssertEqual(comparison.verdict, "off_target")
        assertAllFieldsFinite(comparison)
    }

    /// Both rects zero-area: `intersectionOverUnion`'s own denominator
    /// (`unionArea`) is zero here, the second division this function must
    /// guard explicitly.
    func testBothRectsZeroAreaProducesZeroIoUNotNaN() {
        let target = CGRect(x: 5, y: 5, width: 0, height: 0)
        let painted = CGRect(x: 5, y: 5, width: 0, height: 0)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertEqual(comparison.coverageOfTarget, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.intersectionOverUnion, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "off_target")
        assertAllFieldsFinite(comparison)
    }

    /// Non-finite inputs on the PAINTED side must not let a NaN/infinity
    /// reach any field: `compare` short-circuits before any arithmetic runs.
    func testNonFinitePaintedRectIsRejectedWithoutProducingNaN() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let painted = CGRect(x: Double.nan, y: 0, width: 50, height: 50)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertEqual(comparison.coverageOfTarget, 0)
        XCTAssertEqual(comparison.intersectionOverUnion, 0)
        XCTAssertFalse(comparison.containsTarget)
        XCTAssertEqual(comparison.verdict, "off_target")
        assertAllFieldsFinite(comparison)
    }

    /// Same as above, but the non-finite value is an infinity on the TARGET
    /// side, and in a size field rather than an origin field.
    func testNonFiniteTargetSizeIsRejectedWithoutProducingNaN() {
        let target = CGRect(x: 0, y: 0, width: Double.infinity, height: 100)
        let painted = CGRect(x: 0, y: 0, width: 50, height: 50)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertEqual(comparison.coverageOfTarget, 0)
        XCTAssertEqual(comparison.intersectionOverUnion, 0)
        XCTAssertFalse(comparison.containsTarget)
        XCTAssertEqual(comparison.verdict, "off_target")
        assertAllFieldsFinite(comparison)
    }

    // MARK: - The 0.9 threshold boundary, exactly

    /// Exactly at the threshold: intersection area is exactly 90% of the
    /// target's area (10x9 of 10x10), with no containment (the target's
    /// full 10-tall edge is not covered). `coverageOfTarget >= 0.9` must
    /// admit this as "on_target".
    func testCoverageExactlyAtNinetyPercentIsOnTarget() {
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)
        let painted = CGRect(x: 0, y: 0, width: 10, height: 9)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertFalse(comparison.containsTarget)
        XCTAssertEqual(comparison.coverageOfTarget, 0.9, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "on_target", "exactly 0.9 coverage must clear the >= 0.9 threshold")
        assertAllFieldsFinite(comparison)
    }

    /// Just below the threshold: 8.9 of 10 height covered is 0.89, which
    /// must NOT clear the threshold and must read as "partial", not
    /// "on_target".
    func testCoverageJustBelowNinetyPercentIsPartial() {
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)
        let painted = CGRect(x: 0, y: 0, width: 10, height: 8.9)
        let comparison = AnnotationGeometryVerdict.compare(painted: painted, target: target)
        XCTAssertFalse(comparison.containsTarget)
        XCTAssertEqual(comparison.coverageOfTarget, 0.89, accuracy: 1e-9)
        XCTAssertEqual(comparison.verdict, "partial", "0.89 coverage must fall short of the >= 0.9 threshold")
        assertAllFieldsFinite(comparison)
    }

    // MARK: - payload

    /// The MCP wire payload must use exactly the field names the type's own
    /// properties use, with no renaming.
    func testPayloadUsesExactFieldNames() {
        let comparison = AnnotationGeometryVerdict.compare(
            painted: CGRect(x: 0, y: 0, width: 10, height: 10),
            target: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let payload = comparison.payload
        XCTAssertEqual(payload["coverageOfTarget"] as? Double, comparison.coverageOfTarget)
        XCTAssertEqual(payload["intersectionOverUnion"] as? Double, comparison.intersectionOverUnion)
        XCTAssertEqual(payload["containsTarget"] as? Bool, comparison.containsTarget)
        XCTAssertEqual(payload["centerDeltaX"] as? Double, comparison.centerDeltaX)
        XCTAssertEqual(payload["centerDeltaY"] as? Double, comparison.centerDeltaY)
        XCTAssertEqual(payload["verdict"] as? String, comparison.verdict)
    }

    // MARK: - clippedAtScreenEdge

    /// A rect comfortably inside a 1920x1080 display, nowhere near any edge,
    /// must NOT be reported as clipped.
    func testRectComfortablyInsideScreenIsNotClipped() {
        let painted = CGRect(x: 100, y: 100, width: 50, height: 50)
        XCTAssertFalse(AnnotationGeometryVerdict.clippedAtScreenEdge(painted: painted, screenWidthPx: 1_920, screenHeightPx: 1_080))
    }

    /// Touching the LEFT edge (minX == 0) counts as clipped: a renderer that
    /// clips at the display boundary produces bounds that stop exactly at
    /// the edge for anything that would have extended further.
    func testRectTouchingLeftEdgeIsClipped() {
        let painted = CGRect(x: 0, y: 100, width: 50, height: 50)
        XCTAssertTrue(AnnotationGeometryVerdict.clippedAtScreenEdge(painted: painted, screenWidthPx: 1_920, screenHeightPx: 1_080))
    }

    /// Touching the TOP edge (minY == 0).
    func testRectTouchingTopEdgeIsClipped() {
        let painted = CGRect(x: 100, y: 0, width: 50, height: 50)
        XCTAssertTrue(AnnotationGeometryVerdict.clippedAtScreenEdge(painted: painted, screenWidthPx: 1_920, screenHeightPx: 1_080))
    }

    /// Touching the RIGHT edge (maxX == screenWidthPx).
    func testRectTouchingRightEdgeIsClipped() {
        let painted = CGRect(x: 1_870, y: 100, width: 50, height: 50)
        XCTAssertTrue(AnnotationGeometryVerdict.clippedAtScreenEdge(painted: painted, screenWidthPx: 1_920, screenHeightPx: 1_080))
    }

    /// Touching the BOTTOM edge (maxY == screenHeightPx).
    func testRectTouchingBottomEdgeIsClipped() {
        let painted = CGRect(x: 100, y: 1_030, width: 50, height: 50)
        XCTAssertTrue(AnnotationGeometryVerdict.clippedAtScreenEdge(painted: painted, screenWidthPx: 1_920, screenHeightPx: 1_080))
    }
}
