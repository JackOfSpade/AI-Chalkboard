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
}
