import XCTest
@testable import AIChalkboardCore

/// `ScreenSnapshot.resolve(_:)` had no coverage at all until the exact-id
/// precedence bug below was found by inspection. Its resolution order (exact
/// id -> in-bounds positional index -> main screen -> first screen) is a
/// contract callers depend on -- `get_screens` hands out ids and every
/// subsequent `draw_*` call passes one back -- so each step gets a test that
/// can only pass if that step ran, rather than one that a later fallback
/// would also satisfy.
final class ScreenSnapshotTests: XCTestCase {
    /// Same construction style as `AccessibilityElementResolverTests.screen`:
    /// the pixel dimensions and the WindowServer rectangle are derived from the
    /// AppKit point frame and the backing scale instead of being stated twice.
    ///
    /// `isMain` is an explicit parameter here rather than keyed off the id as
    /// it is there, because these fixtures deliberately use digit-shaped ids --
    /// that collision is the whole subject of this file -- and because several
    /// cases below need main to be a screen OTHER than the first one to tell
    /// the "main screen" and "first screen" fallbacks apart.
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
            // These ids ARE CGDirectDisplayIDs on a real machine, which is
            // precisely why they can collide with positional indices.
            displayID: UInt32(id)
        )
    }

    /// THE REGRESSION THIS FILE EXISTS FOR: `getScreenId` reports a display's
    /// real `CGDirectDisplayID`, and a small integer such as "1" is a
    /// perfectly ordinary one. With the positional-index interpretation
    /// checked first, that display was unreachable BY THE ID `get_screens`
    /// had just handed the caller -- the request silently landed on whichever
    /// monitor occupied position 1 instead, and reported success.
    func testExactIdWinsOverThePositionalIndexAlias() {
        let snapshot = ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: true),
            screen(id: "77", index: 1, isMain: false),
        ])

        let resolved = snapshot.resolve("1")

        XCTAssertEqual(resolved?.id, "1")
        // The assertion that actually distinguishes the fix: index 0, i.e. the
        // display that reports id "1" -- not screens[1], the "77" display the
        // positional reading would have returned.
        XCTAssertEqual(resolved?.index, 0)
    }

    /// The positional alias is still honoured when no screen claims the id.
    /// Main is deliberately the SECOND screen so that a regression collapsing
    /// this branch into the main-screen fallback cannot pass.
    func testNumericIdMatchingNoScreenIdResolvesPositionally() {
        let snapshot = ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: false),
            screen(id: "77", index: 1, isMain: true),
        ])

        let resolved = snapshot.resolve("0")

        XCTAssertEqual(resolved?.id, "1")
        XCTAssertEqual(resolved?.index, 0)
        XCTAssertEqual(resolved?.isMain, false)
    }

    /// A number that is neither an id nor a valid position is not silently
    /// clamped onto an edge screen; it takes the same fallback as any other
    /// unrecognised id.
    func testOutOfBoundsNumericIdFallsBackToTheMainScreen() {
        let snapshot = ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: false),
            screen(id: "77", index: 1, isMain: true),
        ])

        XCTAssertEqual(snapshot.resolve("2")?.id, "77")
        XCTAssertEqual(snapshot.resolve("-1")?.id, "77")
    }

    /// No id supplied at all -- including a string that is only whitespace,
    /// which is what an empty JSON field trimmed down to nothing looks like.
    func testMissingOrBlankIdResolvesToTheMainScreen() {
        let snapshot = ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: false),
            screen(id: "77", index: 1, isMain: true),
        ])

        for raw in [nil, "", "   ", "\n\t "] as [String?] {
            XCTAssertEqual(
                snapshot.resolve(raw)?.id, "77",
                "raw=\(String(describing: raw)) should resolve to the main screen"
            )
        }
    }

    /// `NSScreen.main` is optional, so a snapshot where nothing is flagged main
    /// is representable. The first screen is the last resort rather than nil --
    /// resolve returns nil ONLY for an empty snapshot.
    func testMissingIdFallsBackToTheFirstScreenWhenNoScreenIsMain() {
        let snapshot = ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: false),
            screen(id: "77", index: 1, isMain: false),
        ])

        XCTAssertEqual(snapshot.resolve(nil)?.id, "1")
    }

    func testUnrecognizedNonNumericIdFallsBackToTheMainScreen() {
        let snapshot = ScreenSnapshot(screens: [
            screen(id: "1", index: 0, isMain: false),
            screen(id: "77", index: 1, isMain: true),
        ])

        XCTAssertEqual(snapshot.resolve("not-a-display")?.id, "77")
        XCTAssertEqual(snapshot.resolve("77x")?.id, "77")
    }

    /// The one documented nil case. `NSScreen.screens` really can be
    /// momentarily empty across display reconfiguration and wake -- see
    /// `OverlayWindowController.screenSnapshot()`.
    func testEmptySnapshotResolvesToNil() {
        let snapshot = ScreenSnapshot(screens: [])

        XCTAssertNil(snapshot.resolve(nil))
        XCTAssertNil(snapshot.resolve("1"))
        XCTAssertNil(snapshot.resolve("0"))
    }
}
