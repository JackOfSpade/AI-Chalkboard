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

    // MARK: - Text render budget

    func testTextRenderBudgetAcceptsNormalAndReasonablyLargeText() {
        XCTAssertTrue(DrawingDefaults.isWithinTextRenderBudget(
            text: "A useful label", fontSizePx: 24, paddingPx: 8
        ))
        XCTAssertTrue(DrawingDefaults.isWithinTextRenderBudget(
            text: String(repeating: "x", count: 10_000), fontSizePx: 12, paddingPx: 8
        ))
    }

    func testTextRenderBudgetRejectsPathologicalFontPaddingAndInlineExtent() {
        XCTAssertFalse(DrawingDefaults.isWithinTextRenderBudget(
            text: "x", fontSizePx: 100_000, paddingPx: 100_000
        ), "a single giant glyph plus background must not reach native text layout")
        XCTAssertFalse(DrawingDefaults.isWithinTextRenderBudget(
            text: String(repeating: "x", count: DrawingDefaults.maxTextCharacters),
            fontSizePx: 100_000, paddingPx: 0
        ), "a legal string/style pair can still have an unsafe unwrapped extent")
    }

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

    // MARK: - DrawRequest.rejectDurationSecondsIfSupplied
    //
    // `duration_seconds` is not a tool parameter any more: an annotation
    // persists until the AI or the user explicitly clears it. The old
    // `validateDurationSeconds` accepted a supplied value inside (0, cap] and
    // only rejected the rest; `rejectDurationSecondsIfSupplied` replaces it
    // and rejects the key's mere PRESENCE, independent of whatever value
    // accompanies it -- there is no longer a "valid" duration to accept.

    func testDurationOmittedIsAccepted() {
        XCTAssertNil(DrawRequest.rejectDurationSecondsIfSupplied(args: [:]))
    }

    func testAnySuppliedDurationIsRejectedRegardlessOfValue() {
        // Formerly-valid values (a plain positive number), formerly-invalid
        // values (zero, negative, non-numeric), and a boolean all take the
        // same path now: presence alone is disqualifying.
        let suppliedValues: [Any] = [3.0, 0, -1, "soon", true]
        for value in suppliedValues {
            XCTAssertNotNil(DrawRequest.rejectDurationSecondsIfSupplied(args: ["duration_seconds": value]),
                             "expected rejection for duration_seconds = \(value)")
        }
    }

    func testRejectionMessageNamesTheParameterAndHowToClearInstead() throws {
        // Errors in this codebase are full sentences aimed at an AI caller
        // naming the parameter and saying what was not done; this pins that
        // the rejection text actually does so, not just that it is non-nil.
        let message = try XCTUnwrap(DrawRequest.rejectDurationSecondsIfSupplied(args: ["duration_seconds": 5]))
        XCTAssertTrue(message.contains("duration_seconds"), "expected the parameter to be named in: \(message)")
        XCTAssertTrue(message.contains("Nothing was drawn"), "expected what was NOT done in: \(message)")
        XCTAssertTrue(message.contains("clear"), "expected the alternative (clear) in: \(message)")
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

    // MARK: - duration_seconds is rejected per batch ITEM, not only per call

    /// A batch item has no independent lifetime -- every item shares one
    /// annotation id -- so `duration_seconds` never meant anything there. The
    /// top-level check in `finish` only sees the BATCH's own arguments, so an
    /// item carrying `duration_seconds` slipped past it entirely and was
    /// silently ignored: the drawing was created and stored permanently while
    /// the caller believed that item would clean itself up. That is exactly
    /// the false belief the top-level rejection exists to prevent.
    func testRejectDurationSecondsFiresForABatchItemsOwnArguments() throws {
        let item: [String: Any] = ["type": "path", "path_data": "M 0 0 L 100 100", "duration_seconds": 30]
        let error = try XCTUnwrap(DrawRequest.rejectDurationSecondsIfSupplied(args: item),
                                  "an item-level duration_seconds must be rejected, not ignored")
        XCTAssertTrue(error.contains("duration_seconds is no longer supported"), "got: \(error)")
        XCTAssertTrue(error.contains("clear"), "the message must point the caller at clear: \(error)")
    }

    func testRejectDurationSecondsPassesWhenTheKeyIsAbsent() {
        let item: [String: Any] = ["type": "path", "path_data": "M 0 0 L 100 100"]
        XCTAssertNil(DrawRequest.rejectDurationSecondsIfSupplied(args: item))
    }

    /// Presence alone is the trigger -- a null or malformed value must not
    /// slip through as "not really supplied".
    func testRejectDurationSecondsTriggersOnPresenceRegardlessOfValue() {
        for value: Any in [0, -1, "abc", NSNull(), 3.5] {
            XCTAssertNotNil(DrawRequest.rejectDurationSecondsIfSupplied(args: ["duration_seconds": value]),
                            "presence of duration_seconds must be rejected for value \(value)")
        }
    }

}
