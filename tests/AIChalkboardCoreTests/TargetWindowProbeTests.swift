import XCTest
@testable import AIChalkboardCore

/// Exercises `TargetWindowProbe.swift`'s pure selection/conversion logic --
/// `TargetWindowAssembly.sample(from:...)`/`samples(from:...)` and
/// `TargetWindowSelection.selectWindow(forRect:among:)` -- with hand-built
/// `TargetWindowAssembly.Candidate`/`TargetWindowSample` values. None of this
/// touches `CGWindowListCopyWindowInfo`/`EnumWindows`, so it needs no live
/// foreign window, no Screen Recording permission, and runs identically on
/// macOS and Windows (the concrete `CGWindowListTargetWindowSampling`/
/// `Win32TargetWindowSampling` conformances that call these functions are
/// each compiled -- and therefore must be verified -- on their own
/// platform only).
///
/// The single fixture screen below is anchored at (0, 0) with scale 1 and is
/// large enough to fully contain every test rectangle. That specific shape
/// is deliberate: with a zero-origin, unit-scale screen,
/// `AccessibilityElementResolver.backingRect(forAccessibilityFrame:screens:)`
/// maps a top-left global rect onto IDENTICAL numbers on BOTH platforms (no
/// bottom-left flip term and no scale multiply survive), so this file's
/// expectations do not need a `#if os(macOS)` branch of their own even
/// though it exercises a platform-specific conversion helper underneath.
final class TargetWindowProbeTests: XCTestCase {
    private static let fixtureScreenId = "main"

    private func fixtureScreens() -> [ScreenInfo] {
        let frame = ScreenCoordinateRect(x: 0, y: 0, width: 4_000, height: 3_000)
        return [
            ScreenInfo(
                id: Self.fixtureScreenId,
                index: 0,
                name: Self.fixtureScreenId,
                widthPx: Int(frame.width),
                heightPx: Int(frame.height),
                widthPt: frame.width,
                heightPt: frame.height,
                backingScaleFactor: 1,
                isMain: true,
                appKitFrame: frame,
                windowServerFrame: frame,
                displayID: 1
            )
        ]
    }

    private func candidate(
        windowId: UInt64 = 1,
        ownerPID: Int64 = 100,
        layer: Int? = 0,
        x: Double = 100, y: Double = 100, width: Double = 200, height: Double = 150,
        isOnScreen: Bool = true
    ) -> TargetWindowAssembly.Candidate {
        TargetWindowAssembly.Candidate(
            windowId: windowId, ownerPID: ownerPID, layer: layer,
            bounds: AccessibilityScreenRect(x: x, y: y, width: width, height: height),
            isOnScreen: isOnScreen
        )
    }

    // MARK: - sample(from:matchingProcessId:requireLayerZero:screens:)

    func testMatchingCandidateConvertsToExpectedBackingFrame() {
        let result = TargetWindowAssembly.sample(
            from: candidate(windowId: 42, ownerPID: 100, x: 100, y: 100, width: 200, height: 150),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertEqual(result, TargetWindowSample(
            windowId: 42, processId: 100,
            frame: CGRect(x: 100, y: 100, width: 200, height: 150),
            screenId: Self.fixtureScreenId, isOnScreen: true
        ))
    }

    func testPidMismatchIsRejected() {
        let result = TargetWindowAssembly.sample(
            from: candidate(ownerPID: 111),
            matchingProcessId: 222, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result, "A window owned by a different process must never be reported -- this is the same check that must reject a recycled Win32 HWND now owned by an unrelated process.")
    }

    func testZeroWidthCandidateIsRejected() {
        let result = TargetWindowAssembly.sample(
            from: candidate(width: 0),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result)
    }

    func testZeroHeightCandidateIsRejected() {
        let result = TargetWindowAssembly.sample(
            from: candidate(height: 0),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result)
    }

    func testNegativeAreaCandidateIsRejected() {
        let result = TargetWindowAssembly.sample(
            from: candidate(width: -50, height: -50),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result)
    }

    func testNonFiniteBoundsAreRejected() {
        let result = TargetWindowAssembly.sample(
            from: candidate(width: .infinity),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result)
    }

    func testNonNormalLayerIsRejectedWhenLayerZeroIsRequired() {
        let result = TargetWindowAssembly.sample(
            from: candidate(layer: 25), // e.g. a menu/tooltip/panel plane on macOS
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result)
    }

    func testNonNormalLayerIsAcceptedWhenLayerZeroIsNotRequired() {
        // Mirrors both `window(id:processId:screens:)` conformances (which
        // never filter by layer -- the caller already knows the window's
        // identity) and every Windows candidate (`layer` is always `nil`
        // there).
        let result = TargetWindowAssembly.sample(
            from: candidate(layer: 25),
            matchingProcessId: 100, requireLayerZero: false, screens: fixtureScreens()
        )
        XCTAssertNotNil(result)
    }

    func testNilLayerIsAcceptedEvenWhenLayerZeroIsRequired() {
        // The Windows conformance always passes `requireLayerZero: false`,
        // but this documents the fallback explicitly: a candidate with no
        // layer information at all (nothing this platform can filter on)
        // must not be silently excluded.
        let result = TargetWindowAssembly.sample(
            from: candidate(layer: nil),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNotNil(result)
    }

    func testBoundsThatFitNoScreenAreRejected() {
        // Far outside the single 4000x3000 fixture screen -- straddles no
        // display and fits inside none, so `backingRect` must return nil and
        // this candidate must be dropped rather than clipped or guessed onto
        // the nearest monitor.
        let result = TargetWindowAssembly.sample(
            from: candidate(x: 50_000, y: 50_000, width: 100, height: 100),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertNil(result)
    }

    func testIsOnScreenIsPassedThroughUnchanged() {
        let hidden = TargetWindowAssembly.sample(
            from: candidate(isOnScreen: false),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertEqual(hidden?.isOnScreen, false)

        let visible = TargetWindowAssembly.sample(
            from: candidate(isOnScreen: true),
            matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertEqual(visible?.isOnScreen, true)
    }

    // MARK: - samples(from:matchingProcessId:requireLayerZero:screens:)

    func testSamplesPreservesFrontToBackOrderAndDropsOnlyNonMatchingEntries() {
        let candidates = [
            candidate(windowId: 1, ownerPID: 100, x: 0, y: 0, width: 100, height: 100),   // front-most, matches
            candidate(windowId: 2, ownerPID: 999, x: 0, y: 0, width: 100, height: 100),   // wrong pid, dropped
            candidate(windowId: 3, ownerPID: 100, width: 0, height: 0),                    // zero area, dropped
            candidate(windowId: 4, ownerPID: 100, x: 200, y: 0, width: 100, height: 100),  // matches
        ]
        let results = TargetWindowAssembly.samples(
            from: candidates, matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertEqual(results.map(\.windowId), [1, 4], "Order must be preserved and non-matching entries simply omitted, never reordered.")
    }

    func testSamplesReturnsEmptyArrayWhenNothingMatches() {
        let results = TargetWindowAssembly.samples(
            from: [candidate(ownerPID: 999)], matchingProcessId: 100, requireLayerZero: true, screens: fixtureScreens()
        )
        XCTAssertEqual(results, [])
    }

    // MARK: - TargetWindowSelection.selectWindow(forRect:among:)

    private func sample(windowId: UInt64, x: Double, y: Double, width: Double, height: Double) -> TargetWindowSample {
        TargetWindowSample(
            windowId: windowId, processId: 100,
            frame: CGRect(x: x, y: y, width: width, height: height),
            screenId: Self.fixtureScreenId, isOnScreen: true
        )
    }

    func testSelectWindowReturnsNilForEmptyCandidateList() {
        XCTAssertNil(TargetWindowSelection.selectWindow(forRect: CGRect(x: 0, y: 0, width: 10, height: 10), among: []))
    }

    func testSelectWindowChoosesLargestIntersectionEvenWhenNotFrontmost() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let candidates = [
            sample(windowId: 1, x: 90, y: 90, width: 100, height: 100),   // front-most, tiny overlap (10x10 = 100)
            sample(windowId: 2, x: 0, y: 0, width: 100, height: 100),     // full overlap (100x100 = 10000)
        ]
        let chosen = TargetWindowSelection.selectWindow(forRect: rect, among: candidates)
        XCTAssertEqual(chosen?.windowId, 2, "The window with the larger intersection area must win even though it is not first in front-to-back order.")
    }

    func testSelectWindowBreaksTiesByFrontmost() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let candidates = [
            sample(windowId: 1, x: 0, y: 0, width: 50, height: 50),  // front-most, area 2500
            sample(windowId: 2, x: 0, y: 0, width: 50, height: 50),  // identical area, behind
        ]
        let chosen = TargetWindowSelection.selectWindow(forRect: rect, among: candidates)
        XCTAssertEqual(chosen?.windowId, 1, "Equal intersection areas must resolve to the front-most (first) candidate.")
    }

    func testSelectWindowFallsBackToFrontmostWhenNothingIntersects() {
        let rect = CGRect(x: 1_000, y: 1_000, width: 10, height: 10)
        let candidates = [
            sample(windowId: 1, x: 0, y: 0, width: 50, height: 50),
            sample(windowId: 2, x: 100, y: 100, width: 50, height: 50),
        ]
        let chosen = TargetWindowSelection.selectWindow(forRect: rect, among: candidates)
        XCTAssertEqual(chosen?.windowId, 1, "With no intersection at all, the front-most candidate is chosen rather than reporting failure.")
    }

    func testSelectWindowSingleCandidateIsAlwaysChosen() {
        let rect = CGRect(x: 1_000, y: 1_000, width: 10, height: 10)
        let candidates = [sample(windowId: 7, x: 0, y: 0, width: 50, height: 50)]
        XCTAssertEqual(TargetWindowSelection.selectWindow(forRect: rect, among: candidates)?.windowId, 7)
    }

    // MARK: - Windows HWND<->windowId bit-pattern round trip

    /// The Windows conformance stores a window id as `UInt64(UInt(bitPattern:
    /// hwnd))` when enumerating (`Win32TargetWindowSampling
    /// .topLevelOnScreenCandidates`) and reconstructs an HWND from it via
    /// `HWND(bitPattern: Int(bitPattern: UInt(id)))` in `window(id:processId:
    /// screens:)`. Neither step is expressible without a real Win32 HWND
    /// (meaningless to fabricate on macOS), but the ARITHMETIC underneath --
    /// UInt64 -> UInt -> Int -> UInt -> UInt64 -- is ordinary bit-pattern
    /// reinterpretation, exactly as well-defined on this 64-bit platform as
    /// on a 64-bit Windows one. A regression here (e.g. swapping a
    /// `bitPattern:` conversion for a truncating/clamping one) would make
    /// every anchored annotation on Windows report `lost` immediately,
    /// because the reconstructed handle would never equal the one the
    /// enumeration path originally recorded.
    func testWindowIdBitPatternRoundTripIsExact() {
        let samples: [UInt64] = [
            0x0000_0000_0001_2345, // an ordinary small handle-shaped value
            0x0000_7FFF_FFFF_FFFF, // largest typical user-mode address
            0x8000_0000_0000_0000, // sign bit set -- the classic Int/UInt bitPattern gotcha
            0xFFFF_FFFF_FFFF_FFFF, // every bit set
        ]
        for original in samples {
            let reconstructed = UInt64(UInt(bitPattern: Int(bitPattern: UInt(original))))
            XCTAssertEqual(
                reconstructed, original,
                "Bit pattern must round-trip exactly for 0x\(String(original, radix: 16))."
            )
        }
    }

    // MARK: - ForeignProcessIdentity.matches (recycled-pid guard comparison rule)
    //
    // Only the macOS (plain `==`) branch is exercised here -- this file
    // compiles and runs on this (macOS) development machine only, exactly
    // like every other test in this suite; see `ForeignProcessIdentity
    // .matches`'s own doc comment for the case-INSENSITIVE Windows branch
    // this cannot exercise here.

    func testForeignProcessIdentityMatchesRequiresAnExactMatchOnAResolvedIdentity() {
        XCTAssertTrue(ForeignProcessIdentity.matches(resolved: "com.example.app", recorded: "com.example.app"))
        XCTAssertFalse(ForeignProcessIdentity.matches(resolved: "com.example.app", recorded: "com.other.app"),
                       "a different resolved identity must never match -- this is exactly the recycled-pid case the guard exists to catch")
    }

    func testForeignProcessIdentityMatchesFailsClosedWhenResolutionFailed() {
        XCTAssertFalse(ForeignProcessIdentity.matches(resolved: nil, recorded: "com.example.app"),
                       "an unresolved identity must never be treated as a match -- a lookup failure is not evidence the pid is still the one recorded")
    }
}
