import XCTest
@testable import AIChalkboardCore

/// Covers the memoisation that keeps `OverlayView.drawVectorPath` from
/// re-tokenising path data on every repaint. The properties that matter are
/// that a cache hit is indistinguishable from a fresh parse, that hits are
/// actually reused, and that the retained budget is genuinely enforced --
/// an unbounded content-keyed cache would be a memory leak.
final class SVGPathCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SVGPathCache.removeAll()
    }

    override func tearDown() {
        SVGPathCache.removeAll()
        super.tearDown()
    }

    func testCachedPathEqualsFreshParse() throws {
        let data = "M 10 10 L 100 100 C 120 120 140 80 160 100 Z"
        let fresh = try SVGPathParser.parse(data)
        let cached = try SVGPathCache.path(for: data)
        XCTAssertEqual(cached, fresh, "A cache hit must be interchangeable with a fresh parse.")
    }

    func testArcCommandRoundTripsThroughCache() throws {
        // Arcs are the expensive case (trig-heavy arc-to-Bezier conversion),
        // so they are the reason the cache exists at all.
        let data = "M 0 0 A 50 50 0 1 1 100 0"
        let fresh = try SVGPathParser.parse(data)
        XCTAssertEqual(try SVGPathCache.path(for: data), fresh)
    }

    func testRepeatedLookupReusesOneEntry() throws {
        let data = "M 0 0 L 50 50"
        _ = try SVGPathCache.path(for: data)
        _ = try SVGPathCache.path(for: data)
        _ = try SVGPathCache.path(for: data)
        XCTAssertEqual(SVGPathCache.count, 1, "The same path data must not create additional entries.")
    }

    func testDistinctPathsCreateDistinctEntries() throws {
        _ = try SVGPathCache.path(for: "M 0 0 L 1 1")
        _ = try SVGPathCache.path(for: "M 0 0 L 2 2")
        XCTAssertEqual(SVGPathCache.count, 2)
    }

    func testInvalidPathDataStillThrowsAndIsNotCached() {
        XCTAssertThrowsError(try SVGPathCache.path(for: "M oops"))
        XCTAssertEqual(SVGPathCache.count, 0, "A rejected parse must not occupy the cache.")
    }

    func testExceedingTheBudgetEvictsLeastRecentlyUsed() throws {
        // Each path is ~1 MiB of key bytes, so the fifth insertion must push
        // the retained total past the 4 MiB budget and evict.
        let chunk = 1024 * 1024
        var keys: [String] = []
        for index in 0..<5 {
            let filler = String(repeating: " ", count: chunk)
            keys.append("M 0 0 L \(index) \(index)\(filler)")
        }
        for key in keys { _ = try SVGPathCache.path(for: key) }

        XCTAssertLessThan(SVGPathCache.count, keys.count, "The budget must evict something.")
        XCTAssertLessThanOrEqual(
            SVGPathCache.currentRetainedBytes,
            SVGPathCache.maximumRetainedBytes,
            "Retained bytes must stay within the configured budget."
        )
    }

    func testSingleOversizedPathIsStillCached() throws {
        // A path larger than the entire budget is exactly the one whose
        // re-parse cost most justifies caching, so it must be retained rather
        // than evicting itself immediately.
        let filler = String(repeating: " ", count: SVGPathCache.maximumRetainedBytes + 1024)
        let key = "M 0 0 L 10 10\(filler)"
        _ = try SVGPathCache.path(for: key)
        XCTAssertEqual(SVGPathCache.count, 1, "An oversized path must not evict itself.")
    }
}

/// `clampedAlpha` replaced six open-coded clamps in `OverlayView`; these pin
/// the edges, including the non-finite case that used to be able to reach a
/// `CGColor` alpha as NaN.
final class OverlayDrawingMetricsAlphaTests: XCTestCase {

    func testInRangeValuePassesThrough() {
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(0.5), 0.5, accuracy: 1e-9)
    }

    func testBelowRangeClampsToZero() {
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(-3), 0)
    }

    func testAboveRangeClampsToOne() {
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(42), 1)
    }

    func testBoundsAreInclusive() {
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(0), 0)
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(1), 1)
    }

    func testNonFiniteCollapsesToZero() {
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(.nan), 0)
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(.infinity), 0)
        XCTAssertEqual(OverlayDrawingMetrics.clampedAlpha(-.infinity), 0)
    }
}
