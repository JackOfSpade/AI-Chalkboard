import Foundation
import XCTest
@testable import AIChalkboardCore

/// Coverage for `DrawRequest.coordinateTransform(args:)`'s
/// `screenshot_pixels` guards against an AMBIGUOUS screenshot-to-display
/// mapping, on top of the pre-existing safety guard against an UNSAFE one
/// (see `MCPArgumentValidationTests`'s "Coordinate transform safety"
/// section for that older coverage).
///
/// `DrawRequest.candidateScreens` and `screenIsDetermined` exist because a
/// screenshot's dimensions alone cannot say which display produced it when
/// several connected displays share the same size -- a standard dual
/// identical-monitor desktop. Without `screen_id`, `ScreenSnapshot.resolve`
/// silently defaults to the main display, so an agent that screenshotted the
/// secondary monitor and omitted `screen_id` used to get a
/// successful-looking result with its annotation drawn on the WRONG
/// PHYSICAL MONITOR. `coordinateTransform` is a plain instance method on a
/// struct built only from `ScreenInfo` values, so it is exercised directly
/// here without any display, AppKit, or singleton involvement.
final class DrawRequestScreenshotMappingTests: XCTestCase {
    private func screen(id: String, width: Int, height: Int, isMain: Bool = false) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: id, widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: isMain
        )
    }

    // MARK: - Ambiguous mapping: identical displays, no screen_id

    /// THE bug this fix exists to prevent: two identically-sized displays,
    /// no `screen_id`, so `screen` silently defaulted to the main one. The
    /// dimensions fit both, so the old code drew on the defaulted display
    /// without ever telling the caller a choice was made.
    func testIdenticalDisplaysWithUndeterminedScreenAreRejectedAsAmbiguous() {
        let a = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let b = screen(id: "display-B", width: 3_840, height: 2_160)
        let request = DrawRequest(screen: a, candidateScreens: [a, b], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .success:
            XCTFail("Identical-size displays with no screen_id must not silently default to one of them.")
        case .failure(let message):
            XCTAssertTrue(message.contains("Ambiguous screenshot mapping rejected"), message)
            XCTAssertTrue(message.contains("display-A"), message)
            XCTAssertTrue(message.contains("display-B"), message)
        }
    }

    /// The ambiguity guard's candidate filter requires a PLAUSIBLE capture
    /// (uniform mapping AND no upscale -- see
    /// `ScreenshotGeometry.isPlausibleFullDisplayCapture`), not a bare
    /// aspect-ratio fit. A native 4K image "fits" a same-aspect QHD sibling
    /// only via a 1.5x enlargement no screenshot pipeline produces, so it
    /// identifies its display beyond reasonable doubt and must not be
    /// rejected -- aspect-only counting flagged exactly this setup.
    func testNativeDimensionsAreNotAmbiguousAgainstASameAspectSmallerSibling() {
        let selected = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let sibling = screen(id: "display-B", width: 2_560, height: 1_440)
        let request = DrawRequest(screen: selected, candidateScreens: [selected, sibling], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1)
            XCTAssertEqual(transform.scaleY, 1)
        case .failure(let message):
            XCTFail("A native-size screenshot can only be an upscale of the smaller sibling; it must map unambiguously: \(message)")
        }
    }

    /// The counterpart boundary: a downsample that is plausible for SEVERAL
    /// displays (native for one, half-resolution of another) really is
    /// ambiguous and must still refuse to guess.
    func testDownsampledDimensionsPlausibleForSeveralDisplaysAreStillAmbiguous() {
        let a = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let b = screen(id: "display-B", width: 7_680, height: 4_320)
        let request = DrawRequest(screen: a, candidateScreens: [a, b], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .success:
            XCTFail("An image that is a plausible capture of two displays must not silently default to one of them.")
        case .failure(let message):
            XCTAssertTrue(message.contains("Ambiguous screenshot mapping rejected"), message)
            XCTAssertTrue(message.contains("display-A"), message)
            XCTAssertTrue(message.contains("display-B"), message)
        }
    }

    func testIdenticalDisplaysWithExplicitScreenIdSucceedUnambiguously() {
        let a = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let b = screen(id: "display-B", width: 3_840, height: 2_160)
        // The caller named a display via `screen_id`, so `screenIsDetermined`
        // is true even though the dimensions still fit both displays -- an
        // explicit `screen_id` is already the caller's answer, leaving
        // nothing for the ambiguity guard to refuse.
        let request = DrawRequest(screen: a, candidateScreens: [a, b], screenIsDetermined: true)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .failure(let message):
            XCTFail("An explicit screen_id must not trigger the ambiguity guard: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1, accuracy: 1e-12)
            XCTAssertEqual(transform.scaleY, 1, accuracy: 1e-12)
        }
    }

    // MARK: - Differently sized displays: a single accepting candidate is unambiguous

    func testDifferentlySizedDisplaysWhereOnlySelectedAcceptsSucceedsEvenWithoutScreenId() {
        // 3840x2160 (16:9) and 1600x1200 (4:3) have different-enough aspect
        // ratios that neither can pass as a uniform downsample of the other,
        // so exactly one candidate accepts these dimensions.
        let selected = screen(id: "display-4k", width: 3_840, height: 2_160, isMain: true)
        let other = screen(id: "display-4x3", width: 1_600, height: 1_200)
        let request = DrawRequest(screen: selected, candidateScreens: [selected, other], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .failure(let message):
            XCTFail("Only one candidate display accepts these dimensions; the ambiguity guard must not fire: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1, accuracy: 1e-12)
            XCTAssertEqual(transform.scaleY, 1, accuracy: 1e-12)
        }
    }

    func testDifferentlySizedDisplaysWhereOnlyTheOtherAcceptsFailsWithHintNamingIt() {
        let selected = screen(id: "display-4k", width: 3_840, height: 2_160, isMain: true)
        let other = screen(id: "display-4x3", width: 1_600, height: 1_200)
        // No screen_id supplied, so `screen` defaulted to the main (4K)
        // display, but these dimensions are the OTHER display's image.
        let request = DrawRequest(screen: selected, candidateScreens: [selected, other], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 1_600,
            "screenshot_height": 1_200
        ]) {
        case .success:
            XCTFail("These dimensions do not match the selected 4K display and must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("Unsafe screenshot mapping rejected"), message)
            XCTAssertTrue(message.contains("display-4x3"), message)
        }
    }

    // MARK: - Single display: the overwhelmingly common case stays untouched

    func testSingleDisplayExactDimensionsSucceedsWithIdentityScale() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .failure(let message):
            XCTFail("A single display with exact-matching dimensions must succeed: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1, accuracy: 1e-12)
            XCTAssertEqual(transform.scaleY, 1, accuracy: 1e-12)
        }
    }

    /// A legitimately downsampled full-display screenshot (e.g. a Retina 4K
    /// display captured/exported at a smaller uniform size) must still map
    /// safely, with the resulting non-unit scales exact.
    func testSingleDisplayLegitimateFullDisplayDownsampleSucceedsWithExpectedScales() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 1_512,
            "screenshot_height": 850
        ]) {
        case .failure(let message):
            XCTFail("A uniformly downsampled full-display screenshot should map safely: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 3_840.0 / 1_512.0, accuracy: 1e-9)
            XCTAssertEqual(transform.scaleY, 2_160.0 / 850.0, accuracy: 1e-9)
        }
    }

    // MARK: - backing_pixels / normalized are unaffected by any of this

    func testBackingPixelsIsIdentityRegardlessOfMultipleIdenticalCandidateScreens() {
        let a = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let b = screen(id: "display-B", width: 3_840, height: 2_160)
        let c = screen(id: "display-C", width: 3_840, height: 2_160)
        let request = DrawRequest(screen: a, candidateScreens: [a, b, c], screenIsDetermined: false)
        switch request.coordinateTransform(args: ["coordinate_space": "backing_pixels"]) {
        case .failure(let message):
            XCTFail("backing_pixels must not be affected by candidateScreens or screenIsDetermined: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1)
            XCTAssertEqual(transform.scaleY, 1)
        }
    }

    func testNormalizedScalesToSelectedScreenRegardlessOfMultipleIdenticalCandidateScreens() {
        let a = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let b = screen(id: "display-B", width: 3_840, height: 2_160)
        let request = DrawRequest(screen: a, candidateScreens: [a, b], screenIsDetermined: false)
        switch request.coordinateTransform(args: ["coordinate_space": "normalized"]) {
        case .failure(let message):
            XCTFail("normalized must not be affected by candidateScreens or screenIsDetermined: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 3_840)
            XCTAssertEqual(transform.scaleY, 2_160)
            XCTAssertTrue(transform.requiresUnitInterval)
        }
    }

    // MARK: - Screenshot dimensions supplied in a space that ignores them

    /// The silent-misplacement bug this guard exists for: the dimensions are
    /// only read by the `screenshot_pixels` branch, so a caller that measured
    /// on a 1512x850 image and named `backing_pixels` had them dropped and its
    /// coordinates scaled 1:1 against a 3840x2160 display -- roughly 1200 px
    /// off, reported as success.
    func testExplicitBackingPixelsWithScreenshotWidthIsRejected() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "backing_pixels",
            "screenshot_width": 1_512
        ]) {
        case .success:
            XCTFail("Screenshot dimensions that would be silently ignored must be rejected, not dropped.")
        case .failure(let message):
            XCTAssertTrue(message.contains("would have been IGNORED"), message)
            XCTAssertTrue(message.contains("coordinate_space is 'backing_pixels'"), message)
            XCTAssertTrue(message.contains("Nothing was drawn"), message)
        }
    }

    /// The commonest shape of the bug in practice: `coordinate_space` omitted
    /// entirely, so it DEFAULTS to `backing_pixels` while the caller believed
    /// supplying the dimensions was enough to select the screenshot space.
    func testOmittedCoordinateSpaceWithBothScreenshotDimensionsIsRejected() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "screenshot_width": 1_512,
            "screenshot_height": 850
        ]) {
        case .success:
            XCTFail("An omitted coordinate_space defaults to backing_pixels and must not silently ignore the dimensions.")
        case .failure(let message):
            XCTAssertTrue(message.contains("would have been IGNORED"), message)
            XCTAssertTrue(message.contains("coordinate_space is 'backing_pixels'"), message)
        }
    }

    func testNormalizedWithScreenshotHeightIsRejected() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "normalized",
            "screenshot_height": 850
        ]) {
        case .success:
            XCTFail("normalized also ignores the screenshot dimensions, so supplying them must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("would have been IGNORED"), message)
            XCTAssertTrue(message.contains("coordinate_space is 'normalized'"), message)
        }
    }

    /// A JSON `null` is ABSENCE, not a supplied value -- a schema-driven
    /// client that serialises every declared property and nulls the unused
    /// ones is ordinary, and `JSONSerialization` hands those over as real
    /// `NSNull` entries. Same rule, same reason as `makeShapeKind`'s rect
    /// branch.
    func testBackingPixelsWithNullScreenshotWidthIsNotRejected() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "backing_pixels",
            "screenshot_width": NSNull(),
            "screenshot_height": NSNull()
        ]) {
        case .failure(let message):
            XCTFail("A null screenshot dimension means the caller supplied nothing: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1)
            XCTAssertEqual(transform.scaleY, 1)
        }
    }

    /// ORDERING PIN: the new guard covers only the two spaces that genuinely
    /// ignore the dimensions, so a misspelled `coordinate_space` must still
    /// produce the unknown-space error naming the three valid values --
    /// telling that caller its coordinates "were interpreted as bakcing_pixels"
    /// would be both untrue and unactionable.
    func testUnknownCoordinateSpaceWithScreenshotDimensionsStillReportsTheUnknownSpace() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "bakcing_pixels",
            "screenshot_width": 1_512,
            "screenshot_height": 850
        ]) {
        case .success:
            XCTFail("An unrecognised coordinate_space must never succeed.")
        case .failure(let message):
            XCTAssertTrue(message.contains("coordinate_space must be 'backing_pixels', 'normalized', or 'screenshot_pixels'"), message)
            XCTAssertFalse(message.contains("would have been IGNORED"), message)
        }
    }

    /// The type check on `coordinate_space` also stays ahead of the new
    /// guard: a non-string space is a type error, not an ignored-dimensions
    /// error.
    func testNonStringCoordinateSpaceWithScreenshotDimensionsStillReportsTheTypeError() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": 3,
            "screenshot_width": 1_512
        ]) {
        case .success:
            XCTFail("A non-string coordinate_space must never succeed.")
        case .failure(let message):
            XCTAssertTrue(message.contains("must be 'backing_pixels', 'normalized', or 'screenshot_pixels' when supplied"), message)
            XCTAssertFalse(message.contains("would have been IGNORED"), message)
        }
    }

    /// The guard must not disturb the space the dimensions are FOR: this is
    /// the same mapping `testSingleDisplayLegitimateFullDisplayDownsampleSucceedsWithExpectedScales`
    /// asserts, restated here as the positive half of the new rejection.
    func testScreenshotPixelsWithDimensionsStillMapsAsBefore() {
        let only = screen(id: "only", width: 3_840, height: 2_160, isMain: true)
        let request = DrawRequest(screen: only)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 1_512,
            "screenshot_height": 850
        ]) {
        case .failure(let message):
            XCTFail("screenshot_pixels is where these dimensions belong and must keep working: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 3_840.0 / 1_512.0, accuracy: 1e-9)
            XCTAssertEqual(transform.scaleY, 2_160.0 / 850.0, accuracy: 1e-9)
        }
    }

    // MARK: - `screenshot_space` wired into `resolveDrawContext`

    /// Registers a `.declared`, IDENTITY-MAPPED space (screenshot px ==
    /// backing px, so `scaleX == scaleY == 1`) against the REAL current main
    /// display, and returns it alongside that display's `ScreenInfo`. `nil`
    /// only in the pathological case of zero connected displays (see
    /// `resolveScreen`'s own doc comment on why that can happen momentarily).
    ///
    /// UNLIKE every fixture-built test above, the tests in this section
    /// exercise `DrawRequest.resolveDrawContext(args:)` itself, which -- by
    /// design (see that function's doc comment) -- resolves against the LIVE
    /// `OverlayWindowController.shared.screenSnapshot()` and
    /// `ScreenshotSpaceRegistry.shared`: `resolveScreen` has never taken an
    /// injectable snapshot provider, and this change deliberately keeps that
    /// shape unchanged rather than widening it. Registering an IDENTITY
    /// mapping means every assertion below can pin `scaleX`/`scaleY` to
    /// exactly `1` without ever asserting the test machine's actual
    /// resolution, and every test that registers a space forgets it again via
    /// `defer`, so this shared, process-wide registry is left exactly as it
    /// was found.
    private func registerIdentitySpaceForMainScreen() -> (space: ScreenshotSpace, mainScreen: ScreenInfo)? {
        guard let mainScreen = OverlayWindowController.shared.screenSnapshot().resolve(nil) else {
            return nil
        }
        let space = ScreenshotSpaceRegistry.shared.register(
            screenId: mainScreen.id,
            widthPx: mainScreen.widthPx,
            heightPx: mainScreen.heightPx,
            screenWidthPx: mainScreen.widthPx,
            screenHeightPx: mainScreen.heightPx,
            provenance: .declared
        )
        return (space, mainScreen)
    }

    /// THE POINT OF THIS CHANGE: a `screenshot_space` call and the equivalent
    /// hand-declared `screenshot_pixels` call must produce byte-for-byte the
    /// same transform, because `resolveDrawContext` feeds both through the
    /// identical `resolveScreen` -> `coordinateTransform` sequence -- see
    /// that function's doc comment on why expansion is a rewrite, not a
    /// second implementation.
    func testScreenshotSpaceProducesTheSameTransformAsTheEquivalentHandDeclaredCall() {
        guard let (space, mainScreen) = registerIdentitySpaceForMainScreen() else {
            XCTFail("this test requires at least one live display to resolve a main screen")
            return
        }
        defer { ScreenshotSpaceRegistry.shared.forget(id: space.id) }

        let viaSpace: DrawRequest.CoordinateTransform
        switch DrawRequest.resolveDrawContext(args: ["screenshot_space": space.id]) {
        case .failure(let message):
            XCTFail("a freshly registered, non-stale space must be accepted: \(message)")
            return
        case .success(let (_, transform)):
            viaSpace = transform
        }

        let viaHandDeclared: DrawRequest.CoordinateTransform
        switch DrawRequest.resolveDrawContext(args: [
            "screen_id": mainScreen.id,
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": mainScreen.widthPx,
            "screenshot_height": mainScreen.heightPx
        ]) {
        case .failure(let message):
            XCTFail("the equivalent hand-declared call must succeed identically: \(message)")
            return
        case .success(let (_, transform)):
            viaHandDeclared = transform
        }

        XCTAssertEqual(viaSpace.scaleX, viaHandDeclared.scaleX, accuracy: 1e-9)
        XCTAssertEqual(viaSpace.scaleY, viaHandDeclared.scaleY, accuracy: 1e-9)
        // Pins the VALUE too, not just agreement between the two paths: this
        // space was registered as an identity mapping.
        XCTAssertEqual(viaSpace.scaleX, 1, accuracy: 1e-9)
        XCTAssertEqual(viaSpace.scaleY, 1, accuracy: 1e-9)
    }

    /// A call that never mentions `screenshot_space` at all must be
    /// completely unaffected by the new expansion prologue -- `Rule 1` of
    /// `ScreenshotSpaceExpansion.expand` returns `args` unchanged, so
    /// `resolveDrawContext` must behave exactly as it did before this feature
    /// existed for every one of today's callers.
    func testResolveDrawContextWithNoScreenshotSpaceIsCompletelyUnaffected() {
        switch DrawRequest.resolveDrawContext(args: ["coordinate_space": "backing_pixels"]) {
        case .failure(let message):
            XCTFail("an ordinary backing_pixels call must be unaffected by the expansion prologue: \(message)")
        case .success(let (_, transform)):
            XCTAssertEqual(transform.scaleX, 1)
            XCTAssertEqual(transform.scaleY, 1)
        }
    }

    /// Rule 3 (unknown id) surfacing through the real pipeline, before either
    /// `resolveScreen` or `coordinateTransform` ever run.
    func testUnknownScreenshotSpaceIsRejectedThroughResolveDrawContext() {
        switch DrawRequest.resolveDrawContext(args: ["screenshot_space": "space-definitely-unregistered-00000000"]) {
        case .success:
            XCTFail("an unregistered screenshot_space must never succeed.")
        case .failure(let message):
            XCTAssertTrue(message.contains("Unknown screenshot_space"), message)
        }
    }

    /// Rule 4 (staleness) surfacing through the real pipeline: a space
    /// registered against a display id that is guaranteed not to be in the
    /// live snapshot (it is not a real display id and cannot resolve as a
    /// positional index either) must be rejected as stale, not passed through
    /// to `resolveScreen` -- which would otherwise report a confusing
    /// "Unknown screen_id" for a `screen_id` the caller never supplied.
    func testStaleScreenshotSpaceIsRejectedThroughResolveDrawContext() {
        let space = ScreenshotSpaceRegistry.shared.register(
            screenId: "definitely-nonexistent-screen-id-for-testing",
            widthPx: 1_920, heightPx: 1_080,
            screenWidthPx: 1_920, screenHeightPx: 1_080,
            provenance: .declared
        )
        defer { ScreenshotSpaceRegistry.shared.forget(id: space.id) }

        switch DrawRequest.resolveDrawContext(args: ["screenshot_space": space.id]) {
        case .success:
            XCTFail("a space registered against a display no longer present must be rejected as stale.")
        case .failure(let message):
            XCTAssertTrue(message.contains("no longer present"), message)
            XCTAssertTrue(message.contains("Nothing was drawn/computed"), message)
        }
    }

    /// Rule 6 (conflicting `screen_id`) surfacing through the real pipeline.
    func testConflictingScreenIdIsRejectedThroughResolveDrawContext() {
        guard let (space, _) = registerIdentitySpaceForMainScreen() else {
            XCTFail("this test requires at least one live display to resolve a main screen")
            return
        }
        defer { ScreenshotSpaceRegistry.shared.forget(id: space.id) }

        switch DrawRequest.resolveDrawContext(args: [
            "screenshot_space": space.id,
            "screen_id": "some-other-nonexistent-screen-id-xyz"
        ]) {
        case .success:
            XCTFail("a screen_id that conflicts with the space's own display must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("conflicts with screenshot_space"), message)
        }
    }

    /// Rule 7 (conflicting `coordinate_space`) surfacing through the real
    /// pipeline.
    func testConflictingCoordinateSpaceIsRejectedThroughResolveDrawContext() {
        guard let (space, _) = registerIdentitySpaceForMainScreen() else {
            XCTFail("this test requires at least one live display to resolve a main screen")
            return
        }
        defer { ScreenshotSpaceRegistry.shared.forget(id: space.id) }

        switch DrawRequest.resolveDrawContext(args: [
            "screenshot_space": space.id,
            "coordinate_space": "normalized"
        ]) {
        case .success:
            XCTFail("a coordinate_space that would discard the space's own mapping must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("defines a screenshot pixel grid"), message)
        }
    }

    /// Rule 5 (`screenshot_width`/`screenshot_height` alongside a space)
    /// surfacing through the real pipeline.
    func testDimensionsAlongsideSpaceAreRejectedThroughResolveDrawContext() {
        guard let (space, _) = registerIdentitySpaceForMainScreen() else {
            XCTFail("this test requires at least one live display to resolve a main screen")
            return
        }
        defer { ScreenshotSpaceRegistry.shared.forget(id: space.id) }

        switch DrawRequest.resolveDrawContext(args: [
            "screenshot_space": space.id,
            "screenshot_width": 999
        ]) {
        case .success:
            XCTFail("screenshot_width supplied alongside a space is a contradiction and must be rejected.")
        case .failure(let message):
            XCTAssertTrue(message.contains("already carries its own dimensions"), message)
        }
    }

    /// THE `screenIsDetermined` CLAIM, proved end to end without needing a
    /// real desktop with two identical displays (nothing here can guarantee
    /// one exists on the machine running this test).
    ///
    /// `resolveScreen` derives `screenIsDetermined` purely from whether the
    /// ARGUMENTS it receives carry a non-blank `screen_id` (see that
    /// function's own doc comment). `ScreenshotSpaceExpansion.expand`'s rule
    /// 8 unconditionally injects the space's OWN `screenId` into those
    /// arguments, so a space-referenced call is indistinguishable, from
    /// `resolveScreen`'s point of view, from an explicit hand-declared
    /// `screen_id` naming that same display -- which
    /// `testIdenticalDisplaysWithExplicitScreenIdSucceedUnambiguously` above
    /// already proves does not trip `coordinateTransform`'s ambiguity guard.
    ///
    /// This test chains the REAL `ScreenshotSpaceExpansion.expand` (against
    /// hand-built fixtures, exactly as `ScreenshotSpaceExpansionTests` does)
    /// into a hand-built `DrawRequest` whose `screenIsDetermined` (`true`)
    /// and `candidateScreens` (both twins) are exactly what `resolveScreen`
    /// would have produced had it resolved the space's injected `screen_id`
    /// against a live snapshot containing two identically sized displays --
    /// proving the composition end to end without depending on real
    /// hardware, the same reasoning `resolveDrawContext`'s own doc comment
    /// gives for why this case falls out correctly with no extra code.
    func testSpaceOnTwoIdenticallySizedDisplaysDoesNotTriggerAmbiguityRejection() {
        let a = screen(id: "display-A", width: 3_840, height: 2_160, isMain: true)
        let b = screen(id: "display-B", width: 3_840, height: 2_160)
        let fixtureSpace = ScreenshotSpace(
            id: "space-twins", screenId: "display-A",
            widthPx: 3_840, heightPx: 2_160,
            screenWidthPx: 3_840, screenHeightPx: 2_160,
            provenance: .declared
        )
        let lookup: (String) -> ScreenshotSpace? = { $0 == fixtureSpace.id ? fixtureSpace : nil }
        let currentScreen: (String) -> ScreenInfo? = { id in
            id == "display-A" ? a : (id == "display-B" ? b : nil)
        }

        let expandedArgs: [String: Any]
        switch ScreenshotSpaceExpansion.expand(args: ["screenshot_space": fixtureSpace.id], lookup: lookup, currentScreen: currentScreen) {
        case .failure(let message):
            XCTFail("expansion of a valid, non-stale space must succeed: \(message)")
            return
        case .success(let expanded):
            expandedArgs = expanded
        }

        let request = DrawRequest(screen: a, candidateScreens: [a, b], screenIsDetermined: true)
        switch request.coordinateTransform(args: expandedArgs) {
        case .failure(let message):
            XCTFail("a screenshot_space naming one of two identically sized displays must not trip the ambiguity guard: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 1, accuracy: 1e-12)
            XCTAssertEqual(transform.scaleY, 1, accuracy: 1e-12)
        }
    }

    // MARK: - Defaulted screen must itself be a plausible capture subject

    /// THE silent-wrong-monitor hole the audit demonstrated: a native 4K
    /// screenshot of the SECONDARY display, drawn with no screen_id on a
    /// QHD main. Exactly ONE display accepts these dimensions (the 4K
    /// sibling -- the QHD main fails the no-upscale rule), so the ambiguity
    /// guard (count > 1) never fired, and the upscale-tolerant target guard
    /// passed against the defaulted main (uniform 1.5, aspect exact). Every
    /// coordinate then painted on the WRONG PHYSICAL MONITOR at 2/3 scale
    /// with an ordinary success response.
    func testDefaultedScreenTheImageCannotDepictIsRejectedTowardTheAcceptingSibling() {
        let main = screen(id: "display-QHD", width: 2_560, height: 1_440, isMain: true)
        let secondary = screen(id: "display-4K", width: 3_840, height: 2_160)
        let request = DrawRequest(screen: main, candidateScreens: [main, secondary], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .success:
            XCTFail("A 3840x2160 image cannot be a screenshot of a 2560x1440 display; defaulting there paints on the wrong monitor.")
        case .failure(let message):
            XCTAssertTrue(message.contains("cannot be a full-display screenshot"), message)
            XCTAssertTrue(message.contains("display-4K"), message)
            XCTAssertTrue(message.contains("screen_id"), message)
        }
    }

    /// The same guard when the dimensions fit NO connected display: the
    /// rejection must say that plainly instead of pointing at an accepting
    /// display list that does not exist.
    func testDimensionsFittingNoDisplayAreRejectedWithoutAPhantomHint() {
        let main = screen(id: "display-QHD", width: 2_560, height: 1_440, isMain: true)
        let request = DrawRequest(screen: main, candidateScreens: [main], screenIsDetermined: false)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 5_000,
            "screenshot_height": 2_813
        ]) {
        case .success:
            XCTFail("Dimensions larger than every connected display cannot be a screenshot of any of them.")
        case .failure(let message):
            XCTAssertTrue(message.contains("NO connected display") || message.contains("Unsafe screenshot mapping"), message)
        }
    }

    /// An EXPLICIT screen_id keeps today's behavior: the caller answered the
    /// which-display question, and the upscale-tolerant target guard's
    /// documented rationale ("a draw call names its display") applies.
    func testExplicitScreenIdKeepsTheUpscaleTolerantMapping() {
        let main = screen(id: "display-QHD", width: 2_560, height: 1_440, isMain: true)
        let secondary = screen(id: "display-4K", width: 3_840, height: 2_160)
        let request = DrawRequest(screen: main, candidateScreens: [main, secondary], screenIsDetermined: true)
        switch request.coordinateTransform(args: [
            "coordinate_space": "screenshot_pixels",
            "screenshot_width": 3_840,
            "screenshot_height": 2_160
        ]) {
        case .failure(let message):
            XCTFail("An explicit screen_id is the caller's answer; the defaulted-screen guard must not fire: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.scaleX, 2_560.0 / 3_840.0, accuracy: 1e-12)
        }
    }

    // MARK: - ScreenshotGrid metadata

    func testScreenshotPixelsTransformRecordsItsGrid() {
        let main = screen(id: "display-A", width: 2_940, height: 1_912, isMain: true)
        let request = DrawRequest(screen: main, candidateScreens: [main], screenIsDetermined: false)
        switch request.coordinateTransform(
            args: [
                "coordinate_space": "screenshot_pixels",
                "screenshot_width": 1_470,
                "screenshot_height": 956
            ],
            screenshotSpaceId: "space-test1234"
        ) {
        case .failure(let message):
            XCTFail("A clean half-resolution downsample must map: \(message)")
        case .success(let transform):
            XCTAssertEqual(transform.screenshotGrid?.widthPx, 1_470)
            XCTAssertEqual(transform.screenshotGrid?.heightPx, 956)
            XCTAssertEqual(transform.screenshotGrid?.spaceId, "space-test1234")
        }
    }

    func testNonScreenshotSpacesRecordNoGrid() {
        let main = screen(id: "display-A", width: 2_940, height: 1_912, isMain: true)
        let request = DrawRequest(screen: main, candidateScreens: [main], screenIsDetermined: true)
        switch request.coordinateTransform(args: [:]) {
        case .failure(let message): XCTFail(message)
        case .success(let transform): XCTAssertNil(transform.screenshotGrid)
        }
        switch request.coordinateTransform(args: ["coordinate_space": "normalized"]) {
        case .failure(let message): XCTFail(message)
        case .success(let transform): XCTAssertNil(transform.screenshotGrid)
        }
    }

    // MARK: - Geometry provably not measured on the declared screenshot

    private func gridTransform(width: Double = 1_470, height: Double = 956) -> DrawRequest.CoordinateTransform {
        DrawRequest.CoordinateTransform(
            scaleX: 2, scaleY: 2,
            screenshotGrid: DrawRequest.CoordinateTransform.ScreenshotGrid(
                widthPx: width, heightPx: height, spaceId: nil
            )
        )
    }

    /// A POSITION beyond the declared image (plus the 5% edge tolerance)
    /// cannot have been measured on it -- the doubling signature of
    /// measuring on the full-resolution screenshot while declaring the
    /// client-resized dimensions.
    func testPositionBeyondTheDeclaredScreenshotIsRejected() {
        let rejection = gridTransform().sourceGeometryRejection(
            minX: 2_200, minY: 600, maxX: 2_200, maxY: 600, what: "x/y"
        )
        XCTAssertNotNil(rejection)
        XCTAssertTrue(rejection?.contains("measured on a DIFFERENT image") == true, rejection ?? "")
    }

    func testPositionWithinTheEdgeToleranceIsAccepted() {
        // 3% past the right edge: an honest edge-of-image read, not a
        // doubled coordinate.
        XCTAssertNil(gridTransform().sourceGeometryRejection(
            minX: 1_470 * 1.03, minY: 100, maxX: 1_470 * 1.03, maxY: 100, what: "x/y"
        ))
        XCTAssertNil(gridTransform().sourceGeometryRejection(
            minX: -20, minY: 0, maxX: -20, maxY: 0, what: "x/y"
        ))
    }

    /// Paths use the lax ENTIRELY-OUTSIDE rule: bounds that merely overshoot
    /// (an arrow's control points swinging wide) stay accepted; bounds with
    /// no intersection at all cannot have come from the image.
    func testPathBoundsMerelyOvershootingAreAcceptedButEntirelyOutsideAreRejected() {
        XCTAssertNil(gridTransform().sourceGeometryRejection(
            minX: 1_200, minY: 800, maxX: 1_900, maxY: 1_400, what: "path_data's geometry", positionIsBounds: true
        ))
        XCTAssertNotNil(gridTransform().sourceGeometryRejection(
            minX: 1_800, minY: 1_100, maxX: 2_600, maxY: 1_700, what: "path_data's geometry", positionIsBounds: true
        ))
    }

    func testNonScreenshotTransformNeverObjectsToGeometry() {
        let plain = DrawRequest.CoordinateTransform(scaleX: 1, scaleY: 1)
        XCTAssertNil(plain.sourceGeometryRejection(
            minX: 99_999, minY: 99_999, maxX: 99_999, maxY: 99_999, what: "x/y"
        ))
    }

    // MARK: - Placement-feedback argument parsing

    func testPlacementFeedbackRejectsNonBooleanReportPlacement() {
        switch DrawRequest.parsePlacementFeedbackArguments(["report_placement": "yes"], transform: nil) {
        case .success: XCTFail("A string is not a boolean; reject rather than coerce.")
        case .failure(let message): XCTAssertTrue(message.contains("report_placement"), message)
        }
    }

    func testPlacementFeedbackRejectsTwoExpectations() {
        let args: [String: Any] = [
            "expect_element": ["label": "OK"],
            "expect_window": ["app": "TextEdit"]
        ]
        switch DrawRequest.parsePlacementFeedbackArguments(args, transform: nil) {
        case .success: XCTFail("Two expectations contradict each other; at most one is accepted.")
        case .failure: break
        }
    }

    func testPlacementFeedbackRejectsTargetBoundsWithoutAScreenshotGrid() {
        let args: [String: Any] = [
            "target_bounds_screenshot_px": ["x": 10, "y": 10, "width": 100, "height": 40]
        ]
        switch DrawRequest.parsePlacementFeedbackArguments(args, transform: DrawRequest.CoordinateTransform(scaleX: 1, scaleY: 1)) {
        case .success: XCTFail("A screenshot-pixel target with no screenshot grid has nothing to convert against.")
        case .failure(let message): XCTAssertTrue(message.contains("screenshot"), message)
        }
    }

    func testPlacementFeedbackRejectsApplyCorrectionWithoutAnExpectation() {
        switch DrawRequest.parsePlacementFeedbackArguments(["apply_correction": true], transform: nil) {
        case .success: XCTFail("apply_correction with nothing to correct toward is a mistaken call shape.")
        case .failure(let message): XCTAssertTrue(message.contains("apply_correction"), message)
        }
    }

    func testPlacementFeedbackHappyPathParses() {
        let args: [String: Any] = [
            "report_placement": true,
            "expect_element": ["label": "OK", "app": "TextEdit"],
            "apply_correction": true
        ]
        switch DrawRequest.parsePlacementFeedbackArguments(args, transform: nil) {
        case .failure(let message): XCTFail(message)
        case .success(let feedback):
            XCTAssertTrue(feedback.reportPlacement)
            XCTAssertTrue(feedback.expectationSupplied)
            XCTAssertTrue(feedback.applyCorrection)
        }
    }
}
