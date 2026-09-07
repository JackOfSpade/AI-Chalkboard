import XCTest
@testable import AIChalkboardCore

/// Exercises `DrawRequest`'s `anchor`/`anchor_resize` argument handling in
/// two independently testable halves, matching the split the implementation
/// itself makes:
///
/// 1. `parseAnchorArguments` -- pure string/enum validation, no process or
///    window work at all. This is the full argument-validation matrix: valid
///    values, an unknown value, a wrong type, `anchor_resize` without
///    `anchor`, and `anchor_resize` with `anchor="none"`.
/// 2. `buildWindowAnchor` -- the pure DECISION half of window resolution
///    (which window wins, and what gets written into the resulting
///    `AnnotationAnchor`/`AnchorProjection`), exercised with hand-built
///    `TargetWindowSample`s so it needs no live foreign window, no running
///    process, and no `CGWindowListCopyWindowInfo`/`EnumWindows` call.
///
/// `resolveWindowAnchor` itself (the impure glue that calls
/// `MCPServer.runningProcessIds(forAppId:)` and `TargetWindowProbe.shared`)
/// is NOT exercised here for the same reason `TargetWindowProbeTests.swift`
/// never calls the platform-specific `TargetWindowSampling` conformances
/// directly: it needs a real running process and a real foreign window.
final class DrawRequestAnchorTests: XCTestCase {
    // MARK: - parseAnchorArguments: valid values

    func testAnchorAbsentDefaultsToNoAnchor() {
        assertSuccess(DrawRequest.parseAnchorArguments([:]), nil)
    }

    func testAnchorNoneIsExplicitlyNoAnchor() {
        assertSuccess(DrawRequest.parseAnchorArguments(["anchor": "none"]), nil)
    }

    func testAnchorWindowWithNoResizeDefaultsToPin() {
        assertSuccess(
            DrawRequest.parseAnchorArguments(["anchor": "window"]),
            DrawRequest.AnchorArgumentRequest(resize: .pin)
        )
    }

    func testAnchorWindowWithExplicitPin() {
        assertSuccess(
            DrawRequest.parseAnchorArguments(["anchor": "window", "anchor_resize": "pin"]),
            DrawRequest.AnchorArgumentRequest(resize: .pin)
        )
    }

    func testAnchorWindowWithExplicitScale() {
        assertSuccess(
            DrawRequest.parseAnchorArguments(["anchor": "window", "anchor_resize": "scale"]),
            DrawRequest.AnchorArgumentRequest(resize: .scale)
        )
    }

    // MARK: - parseAnchorArguments: wrong type

    func testAnchorWrongTypeIsRejected() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor": 42]),
            "anchor must be one of \"none\", \"window\" when supplied."
        )
    }

    func testAnchorResizeWrongTypeIsRejected() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor": "window", "anchor_resize": 1]),
            "anchor_resize must be one of \"pin\", \"scale\" when supplied."
        )
    }

    // MARK: - parseAnchorArguments: unknown value

    func testAnchorUnknownValueIsRejected() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor": "orbit"]),
            "anchor must be one of \"none\", \"window\" when supplied."
        )
    }

    func testAnchorResizeUnknownValueIsRejected() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor": "window", "anchor_resize": "stretch"]),
            "anchor_resize must be one of \"pin\", \"scale\" when supplied."
        )
    }

    // MARK: - parseAnchorArguments: anchor_resize without anchor

    func testAnchorResizeWithoutAnchorIsRejected() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor_resize": "pin"]),
            "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."
        )
    }

    // MARK: - parseAnchorArguments: anchor_resize with anchor="none"

    func testAnchorResizeWithAnchorNoneIsRejected() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor": "none", "anchor_resize": "scale"]),
            "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."
        )
    }

    /// `anchor_resize`'s own value must be validated even when it will end up
    /// rejected for lacking `anchor="window"`: an unknown value is the
    /// caller's own mistake and should be named specifically rather than
    /// masked by the "only valid with window" message.
    func testAnchorResizeInvalidValueTakesPrecedenceOverTheAnchorNoneRejection() {
        assertFailure(
            DrawRequest.parseAnchorArguments(["anchor": "none", "anchor_resize": "bogus"]),
            "anchor_resize must be one of \"pin\", \"scale\" when supplied."
        )
    }

    // MARK: - buildWindowAnchor: the window-selection decision

    private static let fixtureScreenId = "screen-1"

    private func sample(windowId: UInt64, x: Double, y: Double, width: Double, height: Double, processId: Int64 = 500) -> TargetWindowSample {
        TargetWindowSample(
            windowId: windowId, processId: processId,
            frame: CGRect(x: x, y: y, width: width, height: height),
            screenId: Self.fixtureScreenId, isOnScreen: true
        )
    }

    func testBuildWindowAnchorReturnsNilForNoCandidates() {
        XCTAssertNil(DrawRequest.buildWindowAnchor(
            processId: 500, appId: "com.example.App", samples: [],
            paintedBounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            resize: .pin, now: Date()
        ))
    }

    func testBuildWindowAnchorChoosesLargestIntersectionAndCapturesItsFrame() throws {
        let paintedBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let samples = [
            sample(windowId: 1, x: 90, y: 90, width: 100, height: 100),  // front-most, tiny overlap
            sample(windowId: 2, x: 0, y: 0, width: 200, height: 200)     // full overlap
        ]
        let now = Date()
        let resolution = try XCTUnwrap(DrawRequest.buildWindowAnchor(
            processId: 500, appId: "com.example.App", samples: samples,
            paintedBounds: paintedBounds, resize: .scale, now: now
        ))
        XCTAssertEqual(resolution.anchor.target.windowId, 2)
        XCTAssertEqual(resolution.anchor.target.processId, 500)
        XCTAssertEqual(resolution.anchor.target.appId, "com.example.App")
        XCTAssertEqual(resolution.anchor.mode, .window)
        XCTAssertEqual(resolution.anchor.resize, .scale)
        XCTAssertEqual(resolution.anchor.referenceWindowFrame, AnchorRect(CGRect(x: 0, y: 0, width: 200, height: 200)))
        XCTAssertEqual(resolution.anchor.referenceScreenId, Self.fixtureScreenId)
        XCTAssertEqual(resolution.anchor.createdAt, now)
        XCTAssertNil(resolution.anchor.element, "draw_* anchors are always .window mode, which never carries an element spec")

        // The identity projection every NEW anchor is stored with: state
        // .tracking, adjustment .identity, current frame == reference frame,
        // effective screen == reference screen -- per the design contract's
        // "a real anchor is never observed with a nil projection" rule.
        XCTAssertEqual(resolution.projection.state, .tracking)
        XCTAssertEqual(resolution.projection.adjustment, .identity)
        XCTAssertEqual(resolution.projection.effectiveScreenId, Self.fixtureScreenId)
        XCTAssertEqual(resolution.projection.currentWindowFrame, AnchorRect(CGRect(x: 0, y: 0, width: 200, height: 200)))
        XCTAssertEqual(resolution.projection.sampledAt, now)
        XCTAssertNil(resolution.projection.elementResolutionIssue)
    }

    func testBuildWindowAnchorFallsBackToFrontmostWhenNothingIntersects() throws {
        let paintedBounds = CGRect(x: 5_000, y: 5_000, width: 10, height: 10)
        let samples = [
            sample(windowId: 7, x: 0, y: 0, width: 50, height: 50),
            sample(windowId: 8, x: 200, y: 200, width: 50, height: 50)
        ]
        let resolution = try XCTUnwrap(DrawRequest.buildWindowAnchor(
            processId: 500, appId: "com.example.App", samples: samples,
            paintedBounds: paintedBounds, resize: .pin, now: Date()
        ))
        XCTAssertEqual(resolution.anchor.target.windowId, 7, "No intersection at all must fall back to the front-most candidate, exactly like TargetWindowSelection.selectWindow itself.")
    }

    // MARK: - Helpers

    private func assertSuccess(
        _ outcome: DrawOutcome<DrawRequest.AnchorArgumentRequest?>,
        _ expected: DrawRequest.AnchorArgumentRequest?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch outcome {
        case .success(let value):
            XCTAssertEqual(value, expected, file: file, line: line)
        case .failure(let message):
            XCTFail("expected success(\(String(describing: expected))) but got failure(\(message))", file: file, line: line)
        }
    }

    private func assertFailure(
        _ outcome: DrawOutcome<DrawRequest.AnchorArgumentRequest?>,
        _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch outcome {
        case .success(let value):
            XCTFail("expected failure(\(expected)) but got success(\(String(describing: value)))", file: file, line: line)
        case .failure(let message):
            XCTAssertEqual(message, expected, file: file, line: line)
        }
    }
}
