import XCTest
@testable import AIChalkboardCore

/// Coverage for `ScreenshotSpace`'s pure helpers (`scaleX`/`scaleY`,
/// `payload`, `stalenessRejection`) and for `ScreenshotSpaceRegistry`'s
/// bounded, thread-safe storage.
///
/// `stalenessRejection` is exercised with zero registry involvement and zero
/// live displays, exactly per its own doc comment: it is a pure static
/// function of a `ScreenshotSpace` fixture and an optional `ScreenInfo`
/// fixture, both built by hand below.
final class ScreenshotSpaceTests: XCTestCase {
    // MARK: - Fixtures

    private func screen(id: String, width: Int, height: Int, isMain: Bool = true) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: id, widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: isMain
        )
    }

    private func space(
        id: String = "space-deadbeef",
        screenId: String = "display-1",
        widthPx: Int = 1_470,
        heightPx: Int = 956,
        screenWidthPx: Int = 2_940,
        screenHeightPx: Int = 1_912,
        provenance: ScreenshotSpace.Provenance = .measured,
        sourcePath: String? = nil
    ) -> ScreenshotSpace {
        ScreenshotSpace(
            id: id, screenId: screenId, widthPx: widthPx, heightPx: heightPx,
            screenWidthPx: screenWidthPx, screenHeightPx: screenHeightPx,
            provenance: provenance, sourcePath: sourcePath
        )
    }

    // MARK: - scaleX / scaleY

    /// Pinned against the exact downsample story `ScreenshotSpace`'s header
    /// doc comment exists to prevent: a 2940x1912 display captured as a
    /// 1470x956 image is a uniform 2x downsample on both axes.
    func testScaleXAndScaleYComputeTheScreenshotToBackingScale() {
        let sut = space(widthPx: 1_470, heightPx: 956, screenWidthPx: 2_940, screenHeightPx: 1_912)
        XCTAssertEqual(sut.scaleX, 2.0, accuracy: 1e-9)
        XCTAssertEqual(sut.scaleY, 2.0, accuracy: 1e-9)
    }

    // MARK: - payload

    func testPayloadIncludesSourcePathOnlyForMeasuredSpacesThatSupplyOne() {
        let measured = space(id: "space-11111111", provenance: .measured, sourcePath: "/Users/jack/Desktop/shot.png")
        let payload = measured.payload
        XCTAssertEqual(payload["screenshotSpace"] as? String, "space-11111111")
        XCTAssertEqual(payload["screenId"] as? String, "display-1")
        XCTAssertEqual(payload["provenance"] as? String, "measured")
        XCTAssertEqual(payload["sourcePath"] as? String, "/Users/jack/Desktop/shot.png")
        let screenshotPx = payload["screenshotPx"] as? [String: Int]
        XCTAssertEqual(screenshotPx?["width"], 1_470)
        XCTAssertEqual(screenshotPx?["height"], 956)
        let screenBackingPx = payload["screenBackingPx"] as? [String: Int]
        XCTAssertEqual(screenBackingPx?["width"], 2_940)
        XCTAssertEqual(screenBackingPx?["height"], 1_912)
        let scale = payload["scaleToBackingPx"] as? [String: Double]
        XCTAssertEqual(scale?["x"], 2.0)
        XCTAssertEqual(scale?["y"], 2.0)
    }

    func testPayloadOmitsSourcePathKeyEntirelyWhenNil() {
        let declared = space(provenance: .declared, sourcePath: nil)
        XCTAssertNil(declared.payload["sourcePath"], "sourcePath must be absent, not present-as-nil, when the space carries none")
        XCTAssertEqual(declared.payload["provenance"] as? String, "declared")
    }

    // MARK: - stalenessRejection: usable space

    func testStalenessRejectionIsNilWhenCurrentScreenMatchesExactly() {
        let sut = space(screenId: "display-1", screenWidthPx: 2_940, screenHeightPx: 1_912)
        let current = screen(id: "display-1", width: 2_940, height: 1_912)
        XCTAssertNil(ScreenshotSpace.stalenessRejection(space: sut, currentScreen: current))
    }

    // MARK: - stalenessRejection: disconnection

    /// THE FIRST staleness cause: the display is no longer present in the
    /// current snapshot at all (disconnected, or its reported id changed).
    func testStalenessRejectionOnDisconnectionNamesTheDisplayAndSaysNothingWasDone() {
        let sut = space(screenId: "display-1")
        let message = ScreenshotSpace.stalenessRejection(space: sut, currentScreen: nil)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("space-deadbeef"), message ?? "")
        XCTAssertTrue(message!.contains("display-1"), message ?? "")
        XCTAssertTrue(message!.contains("no longer present"), message ?? "")
        XCTAssertTrue(message!.contains("Nothing was drawn/computed"), message ?? "")
        XCTAssertTrue(message!.contains("register_screenshot_space") || message!.contains("calibrate_screenshot_space"), message ?? "")
    }

    // MARK: - stalenessRejection: resolution/scale-mode change

    /// THE SECOND staleness cause: the display is still present, but its
    /// backing pixels no longer match what was recorded at registration --
    /// exactly the case a resolution change or a Retina/HiDPI scale-mode
    /// change produces.
    func testStalenessRejectionOnResolutionChangeNamesRecordedAndCurrentNumbers() {
        let sut = space(screenId: "display-1", screenWidthPx: 2_940, screenHeightPx: 1_912)
        let current = screen(id: "display-1", width: 1_920, height: 1_080)
        let message = ScreenshotSpace.stalenessRejection(space: sut, currentScreen: current)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("2940x1912"), message ?? "")
        XCTAssertTrue(message!.contains("1920x1080"), message ?? "")
        XCTAssertTrue(message!.contains("Nothing was drawn/computed"), message ?? "")
        XCTAssertTrue(message!.contains("register_screenshot_space") || message!.contains("calibrate_screenshot_space"), message ?? "")
    }

    /// Only width OR height changing must still be caught -- the guard
    /// compares both fields independently, not just a combined equality that
    /// could theoretically miss a single-axis change under lucky arithmetic.
    func testStalenessRejectionFiresWhenOnlyHeightChanged() {
        let sut = space(screenId: "display-1", screenWidthPx: 2_940, screenHeightPx: 1_912)
        let current = screen(id: "display-1", width: 2_940, height: 1_080)
        XCTAssertNotNil(ScreenshotSpace.stalenessRejection(space: sut, currentScreen: current))
    }

    // MARK: - ScreenshotSpaceRegistry: id format

    func testRandomIdHasTheSpacePrefixAndEightLowercaseHexCharacters() {
        let id = ScreenshotSpaceRegistry.randomId()
        XCTAssertTrue(id.hasPrefix("space-"), id)
        let suffix = id.dropFirst("space-".count)
        XCTAssertEqual(suffix.count, 8, id)
        XCTAssertTrue(suffix.allSatisfy { "0123456789abcdef".contains($0) }, id)
    }

    // MARK: - ScreenshotSpaceRegistry: register / lookup / all

    func testRegisterReturnsALookupableSpaceCarryingEveryFieldSupplied() {
        let registry = ScreenshotSpaceRegistry()
        let registered = registry.register(
            screenId: "display-1", widthPx: 1_470, heightPx: 956,
            screenWidthPx: 2_940, screenHeightPx: 1_912,
            provenance: .measured, sourcePath: "/tmp/shot.png"
        )
        XCTAssertEqual(registry.lookup(id: registered.id), registered)
        XCTAssertEqual(registered.screenId, "display-1")
        XCTAssertEqual(registered.provenance, .measured)
        XCTAssertEqual(registered.sourcePath, "/tmp/shot.png")
    }

    func testLookupReturnsNilForAnIdThatWasNeverRegistered() {
        let registry = ScreenshotSpaceRegistry()
        XCTAssertNil(registry.lookup(id: "space-00000000"))
    }

    // MARK: - ScreenshotSpaceRegistry: id-collision retry

    /// A deterministic sequence: the second `register` call's generator
    /// first repeats the FIRST call's id (a live collision, since that entry
    /// has not been forgotten) before producing a fresh one. `register` must
    /// retry rather than either overwriting the first entry or returning a
    /// duplicate id.
    func testRegisterRetriesIdMintingOnCollisionWithAStillLiveEntry() {
        var sequence = ["space-aaaaaaaa", "space-aaaaaaaa", "space-bbbbbbbb"]
        let registry = ScreenshotSpaceRegistry(idGenerator: {
            sequence.removeFirst()
        })
        let first = registry.register(
            screenId: "display-1", widthPx: 100, heightPx: 100,
            screenWidthPx: 100, screenHeightPx: 100, provenance: .declared
        )
        XCTAssertEqual(first.id, "space-aaaaaaaa")

        let second = registry.register(
            screenId: "display-2", widthPx: 200, heightPx: 200,
            screenWidthPx: 200, screenHeightPx: 200, provenance: .declared
        )
        XCTAssertEqual(second.id, "space-bbbbbbbb", "a collision with the still-live first entry must be retried, not overwritten")
        // The first entry must survive untouched -- a collision retry must
        // never evict or replace the entry it collided with.
        XCTAssertEqual(registry.lookup(id: "space-aaaaaaaa")?.screenId, "display-1")
    }

    // MARK: - ScreenshotSpaceRegistry: bounded eviction

    /// `maxEntries`-plus-one registrations must evict exactly the
    /// least-recently-REGISTERED entry (the very first one), leaving every
    /// later registration, including the newest, intact.
    func testRegistryEvictsTheLeastRecentlyRegisteredEntryOnceOverTheBound() {
        var counter = 0
        let registry = ScreenshotSpaceRegistry(idGenerator: {
            counter += 1
            let hex = String(counter, radix: 16)
            let padded = String(repeating: "0", count: 8 - hex.count) + hex
            return "space-" + padded
        })

        var ids: [String] = []
        for i in 0..<(ScreenshotSpaceRegistry.maxEntries + 1) {
            let registered = registry.register(
                screenId: "display-\(i)", widthPx: 100, heightPx: 100,
                screenWidthPx: 100, screenHeightPx: 100, provenance: .declared
            )
            ids.append(registered.id)
        }

        XCTAssertEqual(registry.all().count, ScreenshotSpaceRegistry.maxEntries, "the store must never exceed its bound")
        XCTAssertNil(registry.lookup(id: ids[0]), "the first-registered entry must be evicted once the bound is exceeded")
        XCTAssertNotNil(registry.lookup(id: ids.last!), "the most recently registered entry must survive")
        // Every entry from the second registration onward must still be
        // present: only exactly one eviction should have happened.
        for id in ids.dropFirst() {
            XCTAssertNotNil(registry.lookup(id: id), "\(id) should not have been evicted")
        }
    }

    func testAllReturnsEntriesOldestRegisteredFirst() {
        let registry = ScreenshotSpaceRegistry()
        let first = registry.register(screenId: "a", widthPx: 1, heightPx: 1, screenWidthPx: 1, screenHeightPx: 1, provenance: .declared)
        let second = registry.register(screenId: "b", widthPx: 1, heightPx: 1, screenWidthPx: 1, screenHeightPx: 1, provenance: .declared)
        XCTAssertEqual(registry.all().map(\.id), [first.id, second.id])
    }

    // MARK: - ScreenshotSpaceRegistry: forget / removeAll

    func testForgetRemovesAnEntryAndReturnsFalseOnASecondCall() {
        let registry = ScreenshotSpaceRegistry()
        let registered = registry.register(screenId: "a", widthPx: 1, heightPx: 1, screenWidthPx: 1, screenHeightPx: 1, provenance: .declared)
        XCTAssertTrue(registry.forget(id: registered.id))
        XCTAssertNil(registry.lookup(id: registered.id))
        XCTAssertFalse(registry.forget(id: registered.id), "forgetting an already-gone id must report false, not error")
    }

    func testRemoveAllClearsEveryRegisteredSpace() {
        let registry = ScreenshotSpaceRegistry()
        _ = registry.register(screenId: "a", widthPx: 1, heightPx: 1, screenWidthPx: 1, screenHeightPx: 1, provenance: .declared)
        _ = registry.register(screenId: "b", widthPx: 1, heightPx: 1, screenWidthPx: 1, screenHeightPx: 1, provenance: .declared)
        registry.removeAll()
        XCTAssertTrue(registry.all().isEmpty)
    }
}
