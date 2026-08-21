import XCTest
@testable import AIChalkboardCore

/// Covers pure MCP-layer logic that previously had no unit test at all and was
/// only ever reached through the GUI-gated Python stdio harnesses (which CI
/// cannot run). Everything here is deliberately free of AppKit, displays, and
/// macOS permission prompts so it runs headless.
///
/// `MCPServer.shared` is used only to reach instance methods that are pure
/// computation. None of these call a `send*` method, so nothing is written to
/// stdout — which matters, because stdout is the live JSON-RPC transport.
final class MCPPureHelperTests: XCTestCase {

    // MARK: - truncateUTF8

    func testTruncateLeavesShortStringUntouched() {
        XCTAssertEqual(MCPServer.shared.truncateUTF8("hello", maximumBytes: 64), "hello")
    }

    func testTruncateAtExactByteBudgetKeepsEverything() {
        // "hello" is 5 ASCII bytes; a budget of exactly 5 must not truncate.
        XCTAssertEqual(MCPServer.shared.truncateUTF8("hello", maximumBytes: 5), "hello")
    }

    func testTruncateNeverSplitsAMultiByteScalar() {
        // Each emoji is 4 UTF-8 bytes. A 6-byte budget must yield one emoji,
        // not one emoji plus half of the next -- a split would produce
        // invalid UTF-8 on the wire.
        let value = "😀😀"
        let truncated = MCPServer.shared.truncateUTF8(value, maximumBytes: 6)
        XCTAssertEqual(truncated, "😀")
        XCTAssertEqual(truncated.utf8.count, 4, "one whole emoji, never a partial scalar")
    }

    func testTruncateBudgetSmallerThanFirstScalarYieldsEmpty() {
        // No prefix fits, and the result must still be valid UTF-8 (empty).
        XCTAssertEqual(MCPServer.shared.truncateUTF8("😀", maximumBytes: 3), "")
    }

    func testTruncateHandlesZeroBudget() {
        XCTAssertEqual(MCPServer.shared.truncateUTF8("anything", maximumBytes: 0), "")
    }

    func testTruncateResultAlwaysWithinBudget() {
        let value = "aé😀b日本語"
        for budget in 0...value.utf8.count + 4 {
            let truncated = MCPServer.shared.truncateUTF8(value, maximumBytes: budget)
            XCTAssertLessThanOrEqual(truncated.utf8.count, max(budget, 0),
                                     "budget \(budget) produced \(truncated.utf8.count) bytes")
            XCTAssertTrue(value.hasPrefix(truncated), "truncation must yield a prefix")
        }
    }

    // MARK: - isCanonicalSuspensionLeaseToken

    func testCanonicalTokenAccepted() {
        // 43 URL-safe base64 characters, the documented token shape.
        let token = String(repeating: "A", count: 43)
        XCTAssertTrue(MCPServer.shared.isCanonicalSuspensionLeaseToken(token))
    }

    func testTokenLengthIsEnforcedOnBothSides() {
        XCTAssertFalse(MCPServer.shared.isCanonicalSuspensionLeaseToken(String(repeating: "A", count: 42)))
        XCTAssertFalse(MCPServer.shared.isCanonicalSuspensionLeaseToken(String(repeating: "A", count: 44)))
        XCTAssertFalse(MCPServer.shared.isCanonicalSuspensionLeaseToken(""))
    }

    func testTokenRejectsCharactersOutsideTheURLSafeAlphabet() {
        // A capability must not be accepted with padding, slashes, plus signs,
        // or whitespace smuggled in.
        for bad in ["=", "/", "+", " ", "\n", "é"] {
            let token = String(repeating: "A", count: 42) + bad
            XCTAssertFalse(MCPServer.shared.isCanonicalSuspensionLeaseToken(token),
                           "must reject a token containing \(bad.debugDescription)")
        }
    }

    func testTokenAcceptsTheFullURLSafeAlphabet() {
        let token = "abcXYZ019-_" + String(repeating: "z", count: 32)
        XCTAssertEqual(token.count, 43)
        XCTAssertTrue(MCPServer.shared.isCanonicalSuspensionLeaseToken(token))
    }

    // MARK: - SuspensionLeaseResponsePolicy

    func testFailedOperationIsAlwaysAnError() {
        XCTAssertTrue(SuspensionLeaseResponsePolicy.isError(
            operation: "acquire", operationSucceeded: false,
            annotationsSuspended: false, peerPresentationSettled: true))
    }

    func testSuccessfulAcquireIsNotAnError() {
        XCTAssertFalse(SuspensionLeaseResponsePolicy.isError(
            operation: "acquire", operationSucceeded: true,
            annotationsSuspended: true, peerPresentationSettled: false))
    }

    func testReleaseIsAnErrorWhenAPeerStaysSuspendedWithoutSettling() {
        // The token was durably removed, but another lease keeps suspension
        // active and peer presentation did not settle -- reporting plain
        // success would tell a caller it is safe to click when it is not.
        XCTAssertTrue(SuspensionLeaseResponsePolicy.isError(
            operation: "release", operationSucceeded: true,
            annotationsSuspended: true, peerPresentationSettled: false))
    }

    func testReleaseIsNotAnErrorOnceThePeerSettled() {
        XCTAssertFalse(SuspensionLeaseResponsePolicy.isError(
            operation: "release", operationSucceeded: true,
            annotationsSuspended: true, peerPresentationSettled: true))
    }

    func testReleaseIsNotAnErrorWhenNothingRemainsSuspended() {
        XCTAssertFalse(SuspensionLeaseResponsePolicy.isError(
            operation: "release", operationSucceeded: true,
            annotationsSuspended: false, peerPresentationSettled: false))
    }

    // MARK: - MCPArgument scan helpers

    func testFirstInvalidSuppliedDoubleReportsTheOffendingKey() {
        let args: [String: Any] = ["a": 1.0, "b": "oops", "c": 3]
        XCTAssertEqual(MCPArgument.firstInvalidSuppliedDouble(args, keys: ["a", "b", "c"]), "b")
    }

    func testFirstInvalidSuppliedDoubleIgnoresOmittedKeys() {
        // Defaults are for OMITTED parameters; only supplied ones are checked.
        let args: [String: Any] = ["a": 1.0]
        XCTAssertNil(MCPArgument.firstInvalidSuppliedDouble(args, keys: ["a", "missing"]))
    }

    func testFirstInvalidSuppliedDoubleAcceptsNumericStrings() {
        let args: [String: Any] = ["a": "2.5"]
        XCTAssertNil(MCPArgument.firstInvalidSuppliedDouble(args, keys: ["a"]))
    }

    func testFirstInvalidSuppliedDoubleRejectsBooleansAndNonFinite() {
        XCTAssertEqual(MCPArgument.firstInvalidSuppliedDouble(["a": true], keys: ["a"]), "a")
        XCTAssertEqual(MCPArgument.firstInvalidSuppliedDouble(["a": "nan"], keys: ["a"]), "a")
        XCTAssertEqual(MCPArgument.firstInvalidSuppliedDouble(["a": "inf"], keys: ["a"]), "a")
    }

    func testFirstInvalidSuppliedDoubleScansInGivenOrder() {
        let args: [String: Any] = ["b": "bad", "c": "worse"]
        XCTAssertEqual(MCPArgument.firstInvalidSuppliedDouble(args, keys: ["b", "c"]), "b")
        XCTAssertEqual(MCPArgument.firstInvalidSuppliedDouble(args, keys: ["c", "b"]), "c")
    }

    func testFirstNonStringSuppliedReportsTheOffendingKey() {
        let args: [String: Any] = ["color": "#FF0000", "app": 42]
        XCTAssertEqual(MCPArgument.firstNonStringSupplied(args, keys: ["color", "app"]), "app")
    }

    func testFirstNonStringSuppliedIgnoresOmittedKeys() {
        XCTAssertNil(MCPArgument.firstNonStringSupplied(["color": "#FFF"], keys: ["color", "missing"]))
    }

    func testFirstNonStringSuppliedAcceptsEmptyString() {
        // "" is meaningful for `app` (it means global) and must not be
        // rejected as a type error.
        XCTAssertNil(MCPArgument.firstNonStringSupplied(["app": ""], keys: ["app"]))
    }

    // MARK: - DrawRequest.validateDurationSeconds

    func testDurationOmittedIsValid() {
        XCTAssertNil(DrawRequest.validateDurationSeconds(args: [:]))
    }

    func testPositiveDurationIsValid() {
        XCTAssertNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": 3.0]))
    }

    func testZeroAndNegativeDurationsAreRejected() {
        XCTAssertNotNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": 0]))
        XCTAssertNotNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": -1]))
    }

    func testNonNumericDurationIsRejected() {
        XCTAssertNotNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": "soon"]))
        XCTAssertNotNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": true]))
    }

    func testDurationBeyondTheSevenDayCapIsRejected() {
        let overCap = DrawingDefaults.maxAnnotationDurationSeconds + 1
        XCTAssertNotNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": overCap]))
    }

    func testDurationExactlyAtTheCapIsAccepted() {
        let atCap = DrawingDefaults.maxAnnotationDurationSeconds
        XCTAssertNil(DrawRequest.validateDurationSeconds(args: ["duration_seconds": atCap]))
    }

    // MARK: - linkageSuffix

    func testLinkageSuffixForGlobalAnnotation() {
        // A global annotation has no app linkage; the suffix must say so
        // rather than naming an app.
        let suffix = MCPServer.shared.linkageSuffix(appId: nil, appName: nil)
        XCTAssertFalse(suffix.isEmpty)
    }

    func testLinkageSuffixPrefersTheHumanReadableName() {
        let suffix = MCPServer.shared.linkageSuffix(appId: "com.example.Thing", appName: "Thing")
        XCTAssertTrue(suffix.contains("Thing"), "expected the display name in: \(suffix)")
    }

    func testLinkageSuffixFallsBackToBundleIdWhenNameIsUnknown() {
        // A non-running app targeted by bundle id has no display name to
        // resolve, so the bundle id must still appear.
        let suffix = MCPServer.shared.linkageSuffix(appId: "com.example.Thing", appName: nil)
        XCTAssertTrue(suffix.contains("com.example.Thing"), "expected the bundle id in: \(suffix)")
    }

    // MARK: - resolveBackingSize (draw_image geometry)

    /// `coordinate_space='normalized'` on a 3840x2160 display: the two axes
    /// scale by different factors, which is what makes the order of the
    /// aspect-ratio arithmetic observable.
    private var normalized4K: DrawRequest.CoordinateTransform {
        DrawRequest.CoordinateTransform(scaleX: 3840, scaleY: 2160, requiresUnitInterval: true)
    }

    func testBackingSizeWithBothDimensionsUsesOneAxisEach() throws {
        let resolved = try XCTUnwrap(MCPServer.resolveBackingSize(
            requestedWidth: 0.1, requestedHeight: 0.5,
            intrinsicWidth: 512, intrinsicHeight: 512, transform: normalized4K
        ))
        XCTAssertEqual(resolved.width, 384, accuracy: 1e-9)
        XCTAssertEqual(resolved.height, 1080, accuracy: 1e-9)
    }

    func testBackingSizeDerivesTheSiblingInBackingSpaceNotCallerSpace() throws {
        // THE regression this exists for: a SQUARE raster asked for width 0.1.
        // Deriving the sibling in caller space (0.1) and then transforming it
        // runs it through the y scale, yielding 384x216 -- a stretched image
        // from a request that explicitly asked to preserve the aspect ratio.
        let resolved = try XCTUnwrap(MCPServer.resolveBackingSize(
            requestedWidth: 0.1, requestedHeight: nil,
            intrinsicWidth: 512, intrinsicHeight: 512, transform: normalized4K
        ))
        XCTAssertEqual(resolved.width, 384, accuracy: 1e-9)
        XCTAssertEqual(resolved.height, 384, accuracy: 1e-9,
                       "the sibling must come from the raster's pixel ratio in BACKING space")
    }

    func testBackingSizeWithHeightOnlyDerivesTheWidthTheSameWay() throws {
        let resolved = try XCTUnwrap(MCPServer.resolveBackingSize(
            requestedWidth: nil, requestedHeight: 0.5,
            intrinsicWidth: 1000, intrinsicHeight: 500, transform: normalized4K
        ))
        XCTAssertEqual(resolved.height, 1080, accuracy: 1e-9)
        XCTAssertEqual(resolved.width, 2160, accuracy: 1e-9, "2:1 raster, so twice the resolved height")
    }

    func testBackingSizeWithNeitherDimensionUsesTheRastersOwnPixelSize() throws {
        // The decoded size wins regardless of the coordinate space chosen for
        // the image's POSITION -- 1024 backing pixels, not 1024 * 3840.
        let resolved = try XCTUnwrap(MCPServer.resolveBackingSize(
            requestedWidth: nil, requestedHeight: nil,
            intrinsicWidth: 1024, intrinsicHeight: 768, transform: normalized4K
        ))
        XCTAssertEqual(resolved.width, 1024, accuracy: 1e-9)
        XCTAssertEqual(resolved.height, 768, accuracy: 1e-9)
    }

    func testBackingSizeAcceptsADerivedSiblingBeyondTheNormalizedUnitInterval() throws {
        // A tall raster pinned to the FULL display width runs off the bottom on
        // purpose. As a normalized value the derived height would be 15360/2160
        // = 7.1, so routing it through `transformedY` would reject a perfectly
        // legitimate request. The derived sibling must skip that check.
        let resolved = try XCTUnwrap(MCPServer.resolveBackingSize(
            requestedWidth: 1.0, requestedHeight: nil,
            intrinsicWidth: 1000, intrinsicHeight: 4000, transform: normalized4K
        ))
        XCTAssertEqual(resolved.width, 3840, accuracy: 1e-9)
        XCTAssertEqual(resolved.height, 15360, accuracy: 1e-9,
                       "an aspect-correct sibling may legitimately exceed the display")
    }

    func testBackingSizeRejectsASuppliedDimensionTheTransformRefuses() {
        // The SUPPLIED dimension still goes through the transform, so
        // normalized 1.5 is out of range and the caller must report a geometry
        // error rather than silently clamping.
        XCTAssertNil(MCPServer.resolveBackingSize(
            requestedWidth: 1.5, requestedHeight: nil,
            intrinsicWidth: 512, intrinsicHeight: 512, transform: normalized4K
        ))
    }
}
