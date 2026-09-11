import XCTest
@testable import AIChalkboardCore

/// Coverage for `ScreenshotSpaceExpansion.expand(args:lookup:currentScreen:)`,
/// exercising every distinct rejection by name plus the happy path, entirely
/// against hand-built `ScreenshotSpace`/`ScreenInfo` fixtures -- no registry
/// singleton, no live display, no MCP transport.
final class ScreenshotSpaceExpansionTests: XCTestCase {
    // MARK: - Fixtures

    private func screen(id: String, width: Int, height: Int) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: id, widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: true
        )
    }

    private let fixtureSpace = ScreenshotSpace(
        id: "space-deadbeef", screenId: "display-1",
        widthPx: 1_470, heightPx: 956,
        screenWidthPx: 2_940, screenHeightPx: 1_912,
        provenance: .measured, sourcePath: "/tmp/shot.png"
    )

    /// `lookup` resolves only `fixtureSpace`'s id; every other id is unknown.
    private func lookup(_ id: String) -> ScreenshotSpace? {
        id == fixtureSpace.id ? fixtureSpace : nil
    }

    /// `currentScreen` mirrors `ScreenSnapshot.resolve(_:)`'s id-then-index
    /// contract closely enough for these tests: an exact id match, or "0"
    /// resolving positionally to the space's own display -- the case rule 6
    /// exists to accept as a harmless restatement.
    private func currentScreenMatchingFixture(_ rawId: String) -> ScreenInfo? {
        let display1 = screen(id: "display-1", width: 2_940, height: 1_912)
        if rawId == "display-1" { return display1 }
        if rawId == "0" { return display1 } // positional index 0 == display-1
        return nil
    }

    private func currentScreenDisconnected(_ rawId: String) -> ScreenInfo? {
        nil
    }

    private func currentScreenResized(_ rawId: String) -> ScreenInfo? {
        rawId == "display-1" ? screen(id: "display-1", width: 1_920, height: 1_080) : nil
    }

    // MARK: - Rule 1: absent / JSON-null is not "supplied"

    func testAbsentScreenshotSpaceReturnsArgsUnchanged() {
        let args: [String: Any] = ["color": "#FF0000", "x": 10]
        switch ScreenshotSpaceExpansion.expand(args: args, lookup: lookup, currentScreen: currentScreenMatchingFixture) {
        case .success(let expanded):
            XCTAssertEqual(expanded.count, args.count)
            XCTAssertEqual(expanded["color"] as? String, "#FF0000")
            XCTAssertEqual(expanded["x"] as? Int, 10)
        case .failure(let message):
            XCTFail("an absent screenshot_space must be a no-op: \(message)")
        }
    }

    /// `JSONSerialization` materializes an explicit JSON null as a real
    /// `NSNull` entry -- a schema-driven client nulling an unused declared
    /// property is ordinary, and must not be treated as "supplied".
    func testJSONNullScreenshotSpaceIsNotTreatedAsSupplied() {
        let args: [String: Any] = ["screenshot_space": NSNull(), "x": 10]
        switch ScreenshotSpaceExpansion.expand(args: args, lookup: lookup, currentScreen: currentScreenMatchingFixture) {
        case .success(let expanded):
            XCTAssertNil(expanded["coordinate_space"], "a null screenshot_space must not trigger expansion")
            XCTAssertEqual(expanded["x"] as? Int, 10)
        case .failure(let message):
            XCTFail("a JSON null screenshot_space must be treated as absent, not rejected: \(message)")
        }
    }

    // MARK: - Rule 2: present but wrong type, or empty/whitespace

    func testNonStringScreenshotSpaceIsRejected() {
        assertFailure(
            ScreenshotSpaceExpansion.expand(args: ["screenshot_space": 42], lookup: lookup, currentScreen: currentScreenMatchingFixture),
            contains: "must be a string"
        )
    }

    func testEmptyStringScreenshotSpaceIsRejected() {
        assertFailure(
            ScreenshotSpaceExpansion.expand(args: ["screenshot_space": ""], lookup: lookup, currentScreen: currentScreenMatchingFixture),
            contains: "must not be empty"
        )
    }

    func testWhitespaceOnlyScreenshotSpaceIsRejected() {
        assertFailure(
            ScreenshotSpaceExpansion.expand(args: ["screenshot_space": "   "], lookup: lookup, currentScreen: currentScreenMatchingFixture),
            contains: "must not be empty"
        )
    }

    // MARK: - Rule 3: unknown id

    func testUnknownScreenshotSpaceIdIsRejectedWithRegistrationGuidance() {
        let message = assertFailure(
            ScreenshotSpaceExpansion.expand(args: ["screenshot_space": "space-00000000"], lookup: lookup, currentScreen: currentScreenMatchingFixture),
            contains: "Unknown screenshot_space"
        )
        XCTAssertTrue(message.contains("register_screenshot_space"), message)
        XCTAssertTrue(message.contains("calibrate_screenshot_space"), message)
    }

    // MARK: - Rule 4: staleness

    func testStaleSpaceOnDisconnectedDisplayIsRejected() {
        let message = assertFailure(
            ScreenshotSpaceExpansion.expand(args: ["screenshot_space": fixtureSpace.id], lookup: lookup, currentScreen: currentScreenDisconnected),
            contains: "no longer present"
        )
        XCTAssertTrue(message.contains("Nothing was drawn/computed"), message)
    }

    func testStaleSpaceOnResolutionChangeIsRejected() {
        let message = assertFailure(
            ScreenshotSpaceExpansion.expand(args: ["screenshot_space": fixtureSpace.id], lookup: lookup, currentScreen: currentScreenResized),
            contains: "2940x1912"
        )
        XCTAssertTrue(message.contains("1920x1080"), message)
    }

    // MARK: - Rule 5: screenshot_width/screenshot_height conflict

    func testScreenshotWidthSuppliedAlongsideSpaceIsRejected() {
        assertFailure(
            ScreenshotSpaceExpansion.expand(
                args: ["screenshot_space": fixtureSpace.id, "screenshot_width": 1_512],
                lookup: lookup, currentScreen: currentScreenMatchingFixture
            ),
            contains: "already carries its own dimensions"
        )
    }

    func testScreenshotHeightSuppliedAlongsideSpaceIsRejected() {
        assertFailure(
            ScreenshotSpaceExpansion.expand(
                args: ["screenshot_space": fixtureSpace.id, "screenshot_height": 850],
                lookup: lookup, currentScreen: currentScreenMatchingFixture
            ),
            contains: "already carries its own dimensions"
        )
    }

    /// A JSON null for these two keys is exactly as "not supplied" here as it
    /// is for `screenshot_space` itself.
    func testNullScreenshotWidthAlongsideSpaceIsNotRejected() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": fixtureSpace.id, "screenshot_width": NSNull(), "screenshot_height": NSNull()],
            lookup: lookup, currentScreen: currentScreenMatchingFixture
        ) {
        case .success: break
        case .failure(let message):
            XCTFail("null screenshot_width/height must not count as supplied: \(message)")
        }
    }

    // MARK: - Rule 6: screen_id conflict

    func testConflictingScreenIdIsRejectedNamingBoth() {
        let message = assertFailure(
            ScreenshotSpaceExpansion.expand(
                args: ["screenshot_space": fixtureSpace.id, "screen_id": "display-2"],
                lookup: lookup, currentScreen: currentScreenMatchingFixture
            ),
            contains: "conflicts with screenshot_space"
        )
        XCTAssertTrue(message.contains("display-2"), message)
        XCTAssertTrue(message.contains("display-1"), message)
    }

    /// A screen_id EQUAL to the space's own is a harmless restatement, not a
    /// conflict.
    func testScreenIdEqualToTheSpacesOwnIsAccepted() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": fixtureSpace.id, "screen_id": "display-1"],
            lookup: lookup, currentScreen: currentScreenMatchingFixture
        ) {
        case .success(let expanded):
            XCTAssertEqual(expanded["screen_id"] as? String, "display-1")
        case .failure(let message):
            XCTFail("an equal, restated screen_id must be accepted: \(message)")
        }
    }

    /// "0" is a POSITIONAL INDEX that happens to resolve, through
    /// `currentScreen`, to the exact same physical display the space names --
    /// this must be treated as equal, not as a conflict between a literal
    /// string and an id.
    func testPositionalIndexResolvingToTheSameDisplayIsAccepted() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": fixtureSpace.id, "screen_id": "0"],
            lookup: lookup, currentScreen: currentScreenMatchingFixture
        ) {
        case .success(let expanded):
            // The space's own screenId is still what gets injected -- "0" was
            // only ever a restatement, not a replacement.
            XCTAssertEqual(expanded["screen_id"] as? String, "display-1")
        case .failure(let message):
            XCTFail("a positional index resolving to the same physical display must be accepted: \(message)")
        }
    }

    func testNonStringScreenIdAlongsideSpaceIsRejected() {
        assertFailure(
            ScreenshotSpaceExpansion.expand(
                args: ["screenshot_space": fixtureSpace.id, "screen_id": 7],
                lookup: lookup, currentScreen: currentScreenMatchingFixture
            ),
            contains: "screen_id must be a string"
        )
    }

    // MARK: - Rule 6: a BLANK screen_id is the "default to main" fallback,
    // not a display assertion

    /// A space registered on a display that is NOT the main one -- the only
    /// configuration in which the blank-screen_id defect below is visible.
    private let nonMainSpace = ScreenshotSpace(
        id: "space-onsecondary", screenId: "display-2",
        widthPx: 1_470, heightPx: 956,
        screenWidthPx: 2_940, screenHeightPx: 1_912,
        provenance: .measured, sourcePath: "/tmp/secondary.png"
    )

    private func lookupNonMainSpace(_ id: String) -> ScreenshotSpace? {
        id == nonMainSpace.id ? nonMainSpace : nil
    }

    /// Mirrors `ScreenSnapshot.resolve(_:)` on a two-display machine where
    /// "display-1" is MAIN: an exact id resolves to that display, a positional
    /// index resolves by position, and -- the part that matters here -- a
    /// BLANK id resolves to the MAIN display, exactly as an omitted one does.
    private func currentScreenTwoDisplaysMainIsDisplay1(_ rawId: String) -> ScreenInfo? {
        let main = screen(id: "display-1", width: 3_840, height: 2_160)
        let secondary = screen(id: "display-2", width: 2_940, height: 1_912)
        switch rawId.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": return main // blank == "use the main display", never an assertion
        case "display-1", "0": return main
        case "display-2", "1": return secondary
        default: return nil
        }
    }

    /// Pins the defect where rule 6 treated `screen_id: ""` as an explicit
    /// display assertion: blank resolved through `ScreenSnapshot.resolve` to
    /// the MAIN display, which did not equal a space registered on a SECONDARY
    /// display, so a schema-driven client that serializes every declared
    /// property had its draw rejected with "screen_id '' conflicts with
    /// screenshot_space ...". Blank is the documented "default to main"
    /// fallback (see `DrawRequest.resolveScreen`'s `screenIsDetermined`), and
    /// the identical call with screen_id omitted always succeeded.
    func testBlankScreenIdAlongsideASpaceOnASecondaryDisplayIsNotTreatedAsAConflict() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": nonMainSpace.id, "screen_id": ""],
            lookup: lookupNonMainSpace, currentScreen: currentScreenTwoDisplaysMainIsDisplay1
        ) {
        case .success(let expanded):
            XCTAssertEqual(
                expanded["screen_id"] as? String, "display-2",
                "rule 8 must overwrite the blank screen_id with the space's own display"
            )
        case .failure(let message):
            XCTFail("a blank screen_id is the default-to-main fallback, not a display assertion: \(message)")
        }
    }

    /// Same defect, reached through a value that is only blank AFTER trimming
    /// -- rule 6 trims before comparing, so whitespace must land in the same
    /// "not an assertion" bucket as the empty string rather than resolving to
    /// main and manufacturing a conflict.
    func testWhitespaceOnlyScreenIdAlongsideASpaceOnASecondaryDisplayIsNotTreatedAsAConflict() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": nonMainSpace.id, "screen_id": "   \n\t "],
            lookup: lookupNonMainSpace, currentScreen: currentScreenTwoDisplaysMainIsDisplay1
        ) {
        case .success(let expanded):
            XCTAssertEqual(expanded["screen_id"] as? String, "display-2")
        case .failure(let message):
            XCTFail("a whitespace-only screen_id must be treated exactly like a blank one: \(message)")
        }
    }

    /// The other half of the same fix: skipping the check for BLANK must not
    /// weaken it for a screen_id the caller genuinely did assert. "display-1"
    /// is a real, resolvable display that is NOT the one the space was
    /// registered against, and it must still be rejected naming both.
    func testGenuinelyConflictingScreenIdAgainstASpaceOnASecondaryDisplayIsStillRejected() {
        let message = assertFailure(
            ScreenshotSpaceExpansion.expand(
                args: ["screenshot_space": nonMainSpace.id, "screen_id": "display-1"],
                lookup: lookupNonMainSpace, currentScreen: currentScreenTwoDisplaysMainIsDisplay1
            ),
            contains: "conflicts with screenshot_space"
        )
        XCTAssertTrue(message.contains("display-1"), message)
        XCTAssertTrue(message.contains("display-2"), message)
    }

    // MARK: - Rule 7: coordinate_space conflict

    func testExplicitConflictingCoordinateSpaceIsRejected() {
        let message = assertFailure(
            ScreenshotSpaceExpansion.expand(
                args: ["screenshot_space": fixtureSpace.id, "coordinate_space": "normalized"],
                lookup: lookup, currentScreen: currentScreenMatchingFixture
            ),
            contains: "defines a screenshot pixel grid"
        )
        XCTAssertTrue(message.contains("normalized"), message)
    }

    func testExplicitScreenshotPixelsCoordinateSpaceIsAccepted() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": fixtureSpace.id, "coordinate_space": "screenshot_pixels"],
            lookup: lookup, currentScreen: currentScreenMatchingFixture
        ) {
        case .success(let expanded):
            XCTAssertEqual(expanded["coordinate_space"] as? String, "screenshot_pixels")
        case .failure(let message):
            XCTFail("an explicit, matching coordinate_space must be accepted: \(message)")
        }
    }

    /// The comparison is case-insensitive, matching
    /// `DrawRequest.coordinateTransform`'s own `.lowercased()` handling of
    /// `coordinate_space`.
    func testCoordinateSpaceComparisonIsCaseInsensitive() {
        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": fixtureSpace.id, "coordinate_space": "Screenshot_Pixels"],
            lookup: lookup, currentScreen: currentScreenMatchingFixture
        ) {
        case .success: break
        case .failure(let message):
            XCTFail("coordinate_space matching must be case-insensitive: \(message)")
        }
    }

    // MARK: - Rule 8: happy path expansion

    func testHappyPathExpandsToTheExactArgumentsCoordinateTransformAccepts() {
        let args: [String: Any] = ["screenshot_space": fixtureSpace.id, "color": "#00FF00", "x": 100, "y": 200]
        switch ScreenshotSpaceExpansion.expand(args: args, lookup: lookup, currentScreen: currentScreenMatchingFixture) {
        case .success(let expanded):
            XCTAssertNil(expanded["screenshot_space"], "screenshot_space must be removed from the expanded arguments")
            XCTAssertEqual(expanded["coordinate_space"] as? String, "screenshot_pixels")
            XCTAssertEqual(expanded["screenshot_width"] as? Int, 1_470)
            XCTAssertEqual(expanded["screenshot_height"] as? Int, 956)
            XCTAssertEqual(expanded["screen_id"] as? String, "display-1")
            // Every argument unrelated to screenshot_space must survive untouched.
            XCTAssertEqual(expanded["color"] as? String, "#00FF00")
            XCTAssertEqual(expanded["x"] as? Int, 100)
            XCTAssertEqual(expanded["y"] as? Int, 200)
        case .failure(let message):
            XCTFail("the happy path must succeed: \(message)")
        }
    }

    /// PROOF that expansion produces exactly what
    /// `DrawRequest.coordinateTransform` independently accepts: build a
    /// `DrawRequest` around the same display the space names, feed it the
    /// expanded arguments, and confirm the resulting transform matches the
    /// space's own recorded scale -- exercising the REAL downstream
    /// validation pipeline, not a re-statement of this type's own logic.
    func testExpandedArgumentsAreAcceptedByDrawRequestCoordinateTransform() {
        let display1 = screen(id: "display-1", width: 2_940, height: 1_912)
        let request = DrawRequest(screen: display1, candidateScreens: [display1], screenIsDetermined: false)

        switch ScreenshotSpaceExpansion.expand(
            args: ["screenshot_space": fixtureSpace.id],
            lookup: lookup, currentScreen: currentScreenMatchingFixture
        ) {
        case .failure(let message):
            XCTFail("expansion must succeed before DrawRequest ever sees the arguments: \(message)")
        case .success(let expanded):
            switch request.coordinateTransform(args: expanded) {
            case .failure(let message):
                XCTFail("DrawRequest.coordinateTransform must accept the expanded arguments unchanged: \(message)")
            case .success(let transform):
                XCTAssertEqual(transform.scaleX, fixtureSpace.scaleX, accuracy: 1e-9)
                XCTAssertEqual(transform.scaleY, fixtureSpace.scaleY, accuracy: 1e-9)
            }
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func assertFailure(
        _ outcome: DrawOutcome<[String: Any]>,
        contains expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        switch outcome {
        case .success(let args):
            XCTFail("expected a failure containing '\(expectedSubstring)', got success with args \(args)", file: file, line: line)
            return ""
        case .failure(let message):
            XCTAssertTrue(message.contains(expectedSubstring), "expected \(message) to contain \(expectedSubstring)", file: file, line: line)
            return message
        }
    }
}

/// Coverage for `MCPServer.redactedArgumentSummary(name:args:)`'s local-path
/// redaction policy.
///
/// WHY THESE TESTS LIVE IN THIS FILE: `redactedArgumentSummary` had no unit
/// test anywhere in the suite when the `screenshot_path` leak on
/// `register_screenshot_space` was found -- which is precisely how that leak
/// survived review. The defect belongs to the same landed change as the
/// `screenshot_space` expansion above (`register_screenshot_space` is the tool
/// that mints the spaces this file's expansion consumes), so its regression
/// test is parked here rather than in a new one-test file. Move it to a
/// dedicated logging test file the moment one exists.
///
/// Nothing here calls `log` or any `send*` method: the summary is built and
/// inspected as a pure string, so no test writes to stderr or to stdout (which
/// is the live JSON-RPC transport).
final class MCPToolCallLogRedactionTests: XCTestCase {
    /// A path shaped like the real leak: it carries both the user's account
    /// name and a project name, the two things the policy exists to keep out
    /// of a log file that outlives the request.
    private let sensitivePath = "/Users/jack/Desktop/My Apps/AcmeCorp-Confidential/shot.png"

    /// Pins the defect: `register_screenshot_space` landed with a
    /// `screenshot_path` argument and NO case in `redactedArgumentSummary`, so
    /// the identical string that logs as `<redacted local path>` through
    /// `verify_annotation` fell to `default` and was written verbatim to
    /// stderr and to the persistent bounded 5 MiB log file.
    func testRegisterScreenshotSpaceScreenshotPathIsRedactedFromTheToolCallLogLine() {
        let summary = MCPServer.shared.redactedArgumentSummary(
            name: "register_screenshot_space",
            args: ["screenshot_path": sensitivePath, "screen_id": "1"]
        )
        XCTAssertFalse(
            summary.contains(sensitivePath),
            "the caller's absolute path must never reach the log line: \(summary)"
        )
        XCTAssertFalse(summary.contains("AcmeCorp-Confidential"), summary)
        XCTAssertFalse(summary.contains("/Users/jack"), summary)
        XCTAssertTrue(summary.contains("<redacted local path>"), summary)
        XCTAssertTrue(summary.contains("register_screenshot_space"), "the tool name stays unredacted: \(summary)")
    }

    /// The two tools now share one case; this is the half that already worked,
    /// asserted so a future edit to the shared case cannot silently drop it.
    func testVerifyAnnotationScreenshotPathIsStillRedactedFromTheToolCallLogLine() {
        let summary = MCPServer.shared.redactedArgumentSummary(
            name: "verify_annotation",
            args: ["screenshot_path": sensitivePath, "annotation_id": "ann-1"]
        )
        XCTAssertFalse(summary.contains(sensitivePath), summary)
        XCTAssertTrue(summary.contains("<redacted local path>"), summary)
    }

    /// Redaction is keyed on the ARGUMENT, not the tool: a call that carries
    /// no path at all must still log its arguments, so the declared-dimensions
    /// form of `register_screenshot_space` stays as debuggable as it is today.
    func testRegisterScreenshotSpaceWithoutAPathStillLogsItsDeclaredDimensions() {
        let summary = MCPServer.shared.redactedArgumentSummary(
            name: "register_screenshot_space",
            args: ["screenshot_width": 1_470, "screenshot_height": 956]
        )
        XCTAssertTrue(summary.contains("screenshot_width"), summary)
        XCTAssertTrue(summary.contains("1470"), summary)
        XCTAssertFalse(summary.contains("<redacted local path>"), summary)
    }

    /// A JSON null under `screenshot_path` is not a path, but it also is not
    /// worth a second code path: the shared case redacts whatever is present.
    /// This test exists to state that behaviour deliberately rather than let a
    /// future reader mistake it for an oversight.
    func testANullScreenshotPathIsHarmlesslyReportedAsRedacted() {
        let summary = MCPServer.shared.redactedArgumentSummary(
            name: "register_screenshot_space",
            args: ["screenshot_path": NSNull()]
        )
        XCTAssertTrue(summary.contains("<redacted local path>"), summary)
    }
}
