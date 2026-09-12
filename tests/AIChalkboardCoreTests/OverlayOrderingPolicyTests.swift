import XCTest
@testable import AIChalkboardCore

/// Pins `OverlayOrderingPolicy.shouldOrderOnScreen(alreadyOnScreen:
/// lastAssertedAt:now:)` -- the pure decision behind `refreshViewsNow`'s
/// per-screen ordering step (house pattern: the policy is a pure function
/// precisely so it can be pinned here without constructing a live window).
///
/// The two behaviors worth guarding against are the two "obvious fixes" that
/// are each wrong in a different direction (see the policy's own doc comment
/// for the full story):
///
///   * regressing to the UNCONDITIONAL reassertion -- one synchronous
///     WindowServer transaction per repaint per display, 30/sec at anchor-
///     drag cadence;
///   * "simplifying" to a bare `!isOnScreen` guard -- which permanently
///     forfeits the same-level z-order tie with Control Center that
///     `orderFrontRegardless()` re-wins, because losing that tie never flips
///     `isOnScreen`.
///
/// Each test below fails under at least one of those two rewrites.
final class OverlayOrderingPolicyTests: XCTestCase {
    private let interval = OverlayOrderingPolicy.reassertInterval

    /// The off-screen -> on-screen transition must NEVER be throttled: it is
    /// how content first appears and how suspend/resume self-heals. A recent
    /// timestamp must not mute it -- after `orderOffScreen()` the stored
    /// timestamp (if any survived) describes a window state that no longer
    /// exists.
    func testOffScreenWindowIsAlwaysOrderedImmediately() {
        XCTAssertTrue(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: false, lastAssertedAt: nil, now: 100
        ))
        XCTAssertTrue(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: false, lastAssertedAt: 100, now: 100
        ))
    }

    /// On screen with no recorded assertion: this process cannot prove it
    /// ever fronted the window (rebuild cleared the map, or the entry was
    /// dropped on hide), so the policy must assert rather than assume. This
    /// is the branch that keeps "drop the timestamp on hide" safe.
    func testOnScreenWithNoRecordedAssertionOrders() {
        XCTAssertTrue(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: true, lastAssertedAt: nil, now: 100
        ))
    }

    /// The whole point of the change: within the interval, an already-on-
    /// screen window is NOT re-fronted. A regression to the unconditional
    /// reassertion fails here.
    func testOnScreenWithinIntervalSkipsTheReassertion() {
        XCTAssertFalse(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: true, lastAssertedAt: 100, now: 100
        ))
        XCTAssertFalse(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: true, lastAssertedAt: 100, now: 100 + interval - 0.001
        ))
    }

    /// The armor half: once the interval has elapsed the tie IS re-fought,
    /// boundary inclusive. A "simplification" to a bare `!isOnScreen` guard
    /// fails here -- that rewrite never reasserts for a visible window, so a
    /// lost same-level tie would last forever instead of at most one
    /// interval.
    func testOnScreenAtOrPastIntervalReasserts() {
        XCTAssertTrue(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: true, lastAssertedAt: 100, now: 100 + interval
        ))
        XCTAssertTrue(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: true, lastAssertedAt: 100, now: 100 + interval * 5
        ))
    }

    /// A timestamp from the future should be impossible with the monotonic
    /// uptime source the caller uses, but if one is ever observed the only
    /// safe reading is "this timestamp proves nothing" -- fail toward the
    /// behavior that was previously unconditional, not toward silence.
    func testNegativeElapsedFailsTowardReasserting() {
        XCTAssertTrue(OverlayOrderingPolicy.shouldOrderOnScreen(
            alreadyOnScreen: true, lastAssertedAt: 200, now: 100
        ))
    }
}
