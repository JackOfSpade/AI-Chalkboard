import XCTest
@testable import AIChalkboardCore

/// Pins `ScreenSnapshotCache` -- the lock box behind
/// `OverlayWindowController.screenSnapshot(freshness:)` on macOS. The cache's
/// correctness story rests on three claims its doc comment makes, and each
/// gets a test that fails if that claim stops being true:
///
///   1. A `.cached` read serves EXACTLY the stored immutable value, with no
///      rebuild -- the "one coherent snapshot per call, by construction"
///      claim, and the entire performance win.
///   2. `store(_:)` is the ONLY writer: neither a cold-start fallback build
///      nor a `.live` rebuild leaks into the cache. That single-writer
///      discipline is what makes "the cache is exactly as old as the overlay
///      windows" true, and what keeps a mid-reconfiguration degenerate
///      reading (momentarily-empty `NSScreen.screens`) from poisoning every
///      later call.
///   3. `.live` bypasses a populated cache unconditionally -- the contract
///      the post-walk display-change guards depend on.
///
/// The notification path itself (`didChangeScreenParametersNotification` ->
/// `rebuildOverlayWindows()` -> `store(_:)`) cannot run headlessly -- it
/// creates real `NSWindow`s -- so its cache half is pinned here at the seam:
/// `store(_:)` replacing the previous value IS what that handler contributes
/// to the cache, and `testStoreReplacesThePreviousSnapshot` covers it.
final class ScreenSnapshotCacheTests: XCTestCase {
    /// Same fixture style as `ScreenSnapshotTests.screen`: pixel dimensions
    /// and the WindowServer rect derived from the point frame and scale.
    private func screen(
        id: String,
        index: Int,
        isMain: Bool,
        appKitFrame: ScreenCoordinateRect = ScreenCoordinateRect(x: 0, y: 0, width: 1_512, height: 982),
        scale: Double = 2
    ) -> ScreenInfo {
        ScreenInfo(
            id: id,
            index: index,
            name: id,
            widthPx: Int(appKitFrame.width * scale),
            heightPx: Int(appKitFrame.height * scale),
            widthPt: appKitFrame.width,
            heightPt: appKitFrame.height,
            backingScaleFactor: scale,
            isMain: isMain,
            appKitFrame: appKitFrame,
            windowServerFrame: ScreenCoordinateRect(
                x: appKitFrame.x * scale, y: appKitFrame.y * scale,
                width: appKitFrame.width * scale, height: appKitFrame.height * scale
            ),
            displayID: UInt32(id)
        )
    }

    /// Whole-value equality for snapshots without adding an `Equatable`
    /// conformance to production code this change does not otherwise need:
    /// `ScreenInfo` is `Codable`, so two snapshots are compared by their
    /// sorted-keys JSON encodings, which covers every stored field.
    private func encoded(_ snapshot: ScreenSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot.screens)
    }

    private func makeSnapshotA() -> ScreenSnapshot {
        ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: true),
            screen(id: "77", index: 1, isMain: false,
                   appKitFrame: ScreenCoordinateRect(x: 1_512, y: 0, width: 1_920, height: 1_080), scale: 1),
        ])
    }

    private func makeSnapshotB() -> ScreenSnapshot {
        // A one-display layout, so no field-level coincidence with A can make
        // an "which snapshot did I get?" assertion pass by accident.
        ScreenSnapshot(screens: [
            screen(id: "42", index: 0, isMain: true,
                   appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 2_560, height: 1_440), scale: 2),
        ])
    }

    /// Claim 1, plus the cached-vs-fresh equivalence the change promises:
    /// given the same inputs, the value a `.cached` read hands out is
    /// byte-identical to the value a fresh build from those inputs produces
    /// -- and producing it costs zero rebuilds.
    func testCachedReadServesTheStoredValueWithoutRebuilding() throws {
        let cache = ScreenSnapshotCache()
        cache.store(makeSnapshotA())

        var rebuilds = 0
        let served = cache.read(freshness: .cached) {
            rebuilds += 1
            return self.makeSnapshotB()
        }

        XCTAssertEqual(rebuilds, 0, "a populated cache must answer .cached reads with no rebuild")
        XCTAssertEqual(try encoded(served), try encoded(makeSnapshotA()),
                       "the cached value must equal a fresh build from the same inputs, field for field")
    }

    /// Claim 2, cold-start half: an empty cache falls through to the rebuild
    /// EVERY time -- the fallback build must not become the cached value, so
    /// a degenerate mid-reconfiguration reading is consumed once, by the one
    /// call that was unlucky, and nobody else.
    func testColdCacheRebuildsEveryTimeAndRetainsNothing() throws {
        let cache = ScreenSnapshotCache()

        var rebuilds = 0
        let first = cache.read(freshness: .cached) {
            rebuilds += 1
            // The degenerate reading the discipline exists for: an empty
            // screen list, which is exactly what a build racing a display
            // reconfiguration can see.
            return ScreenSnapshot(screens: [])
        }
        let second = cache.read(freshness: .cached) {
            rebuilds += 1
            return self.makeSnapshotA()
        }

        XCTAssertEqual(rebuilds, 2, "a cold cache must rebuild per read; the fallback result must not be retained")
        XCTAssertTrue(first.screens.isEmpty)
        XCTAssertEqual(try encoded(second), try encoded(makeSnapshotA()),
                       "the second read must NOT have been served the first read's empty fallback")
    }

    /// Claim 3 plus claim 2's live half: `.live` rebuilds even when the cache
    /// is populated (the post-walk guards' contract), and the rebuilt value
    /// does not overwrite the cache -- a later `.cached` read still sees what
    /// the display-change handler stored.
    func testLiveBypassesThePopulatedCacheAndDoesNotOverwriteIt() throws {
        let cache = ScreenSnapshotCache()
        cache.store(makeSnapshotA())

        var rebuilds = 0
        let live = cache.read(freshness: .live) {
            rebuilds += 1
            return self.makeSnapshotB()
        }
        XCTAssertEqual(rebuilds, 1, ".live must rebuild even with a populated cache")
        XCTAssertEqual(try encoded(live), try encoded(makeSnapshotB()))

        let cachedAfter = cache.read(freshness: .cached) {
            XCTFail("the cache should still be populated; .live must not have cleared or replaced it")
            return self.makeSnapshotB()
        }
        XCTAssertEqual(try encoded(cachedAfter), try encoded(makeSnapshotA()),
                       "single-writer discipline: only store(_:) may change what .cached serves")
    }

    /// The notification path's cache half, at the headless seam (see the
    /// class doc comment): a second `store(_:)` -- what
    /// `rebuildOverlayWindows()` performs when
    /// `didChangeScreenParametersNotification` fires -- wholesale replaces
    /// the previous snapshot, and subsequent `.cached` reads serve the new
    /// layout with no rebuild.
    func testStoreReplacesThePreviousSnapshot() throws {
        let cache = ScreenSnapshotCache()
        cache.store(makeSnapshotA())
        cache.store(makeSnapshotB())

        var rebuilds = 0
        let served = cache.read(freshness: .cached) {
            rebuilds += 1
            return self.makeSnapshotA()
        }
        XCTAssertEqual(rebuilds, 0)
        XCTAssertEqual(try encoded(served), try encoded(makeSnapshotB()),
                       "after a display-change refresh, .cached must serve the NEW layout")
    }
}
