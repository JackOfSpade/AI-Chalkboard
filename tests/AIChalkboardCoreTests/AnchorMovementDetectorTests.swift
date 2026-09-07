import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `AnchorMovementDetector.moved(before:after:)` -- the pure
/// before/after `AnchorProjection` comparison behind `verify_annotation`'s
/// `anchorMovedDuringVerification` flag (`MCPToolHandlers+Verification.swift`).
/// The flag exists to tell a caller that the tracker resampled the anchor's
/// target window WHILE the verification image was being produced, so the
/// composited `paintedBoundsScreenshotPx` may already describe a placement
/// that has since changed -- evidence, not a failure (see that flag's own
/// doc comment for why an agent must not retry on `true`).
final class AnchorMovementDetectorTests: XCTestCase {
    private func projection(
        state: AnchorTrackingState = .tracking,
        scaleX: Double = 1, translateX: Double = 0,
        frame: AnchorRect? = AnchorRect(x: 0, y: 0, width: 400, height: 200),
        sampledAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AnchorProjection {
        AnchorProjection(
            state: state,
            adjustment: AnchorAdjustment(scaleX: scaleX, scaleY: 1, translateX: translateX, translateY: 0),
            effectiveScreenId: "screen-1",
            currentWindowFrame: frame,
            sampledAt: sampledAt
        )
    }

    func testIdenticalProjectionsAreNotReportedAsMoved() {
        let sample = projection()
        XCTAssertFalse(AnchorMovementDetector.moved(before: sample, after: sample))
    }

    func testAChangedAdjustmentIsReportedAsMoved() {
        let before = projection(translateX: 0)
        let after = projection(translateX: 50)
        XCTAssertTrue(AnchorMovementDetector.moved(before: before, after: after),
                      "a window that dragged mid-verification changes the adjustment and must be reported as moved")
    }

    func testAStateTransitionIsReportedAsMoved() {
        let before = projection(state: .tracking)
        let after = projection(state: .hidden)
        XCTAssertTrue(AnchorMovementDetector.moved(before: before, after: after),
                      "the target window minimising mid-verification is itself a movement worth flagging")
    }

    func testBothUnanchoredIsNotReportedAsMoved() {
        XCTAssertFalse(AnchorMovementDetector.moved(before: nil, after: nil))
    }

    /// A `nil` on only one side (the annotation was cleared mid-verification,
    /// or had no projection sampled yet) is a genuine, if unusual, difference
    /// and must not be silently treated as "unchanged".
    func testOneSidedNilIsReportedAsMoved() {
        XCTAssertTrue(AnchorMovementDetector.moved(before: projection(), after: nil))
        XCTAssertTrue(AnchorMovementDetector.moved(before: nil, after: projection()))
    }
}
