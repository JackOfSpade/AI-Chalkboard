#if os(macOS)
import ApplicationServices
#endif
import XCTest
@testable import AIChalkboardCore

final class AccessibilityElementResolverTests: XCTestCase {
    private func screen(
        id: String,
        appKitFrame: ScreenCoordinateRect,
        scale: Double
    ) -> ScreenInfo {
        ScreenInfo(
            id: id,
            index: 0,
            name: id,
            widthPx: Int(appKitFrame.width * scale),
            heightPx: Int(appKitFrame.height * scale),
            widthPt: appKitFrame.width,
            heightPt: appKitFrame.height,
            backingScaleFactor: scale,
            isMain: id == "main",
            appKitFrame: appKitFrame,
            windowServerFrame: ScreenCoordinateRect(
                x: appKitFrame.x * scale, y: appKitFrame.y * scale,
                width: appKitFrame.width * scale, height: appKitFrame.height * scale
            ),
            displayID: 1
        )
    }

    func testExactLabelMatchingIsCaseSensitive() {
        XCTAssertTrue(AccessibilityElementResolver.labelMatches("Fusion", query: "Fusion", mode: .exact))
        XCTAssertFalse(AccessibilityElementResolver.labelMatches("fusion", query: "Fusion", mode: .exact))
        XCTAssertFalse(AccessibilityElementResolver.labelMatches("Fusion Studio", query: "Fusion", mode: .exact))
    }

    func testContainsLabelMatchingIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(AccessibilityElementResolver.labelMatches("Open Fusion Studio", query: "fusion", mode: .contains))
        XCTAssertTrue(AccessibilityElementResolver.labelMatches("Café Settings", query: "cafe", mode: .contains))
        XCTAssertFalse(AccessibilityElementResolver.labelMatches("Color", query: "Fusion", mode: .contains))
    }

    // Windows-only note: every test below through
    // `testZeroOriginAnchorIsUsedEvenWhenItIsNeitherScreensFirstNorIsMain`
    // exercises macOS AX-only publishing behavior or coordinate-space
    // semantics. The first three tests use AX attribute constants and the
    // macOS resolver's `publishedMatchLabel`; Windows UIA never returns the
    // matched provider value to Swift and publishes the caller's query
    // instead, so there is no raw surrounding value to test there. The five
    // coordinate tests do not hold on Windows, confirmed by actually running
    // this suite there (all five failed with wrong numbers/unexpected nils
    // before this guard was added, not merely a hypothesized difference):
    //   * macOS AX reports element frames in POINTS, which `backingRect`
    //     must multiply by `backingScaleFactor` to reach physical backing
    //     pixels -- these fixtures build a `scale: 2` screen and an AX
    //     frame in points specifically to exercise that multiply. Windows
    //     UI Automation reports `BoundingRectangle` directly in PHYSICAL
    //     pixels already (Per-Monitor-v2 DPI awareness -- see
    //     `ScreenSnapshot.swift`'s Windows `buildScreenInfos()` doc
    //     comment), so the Windows `backingRect` deliberately does NOT
    //     multiply by scale (see that method's Windows doc comment) --
    //     applying these macOS fixtures' point-based expectations there
    //     would silently double the reported position/size.
    //   * macOS's conversion anchors to whichever display sits at AppKit
    //     global (0, 0) specifically because AX's own global coordinate
    //     space is anchored there too (a quirk of AppKit's bottom-left,
    //     Y-up screen model) -- see `testConversionAnchorsToZeroOriginDisplayNotTheFocusedMainScreen`/
    //     `testMissingZeroOriginDisplayReturnsNilInsteadOfAnchoringToAnArbitraryScreen`/
    //     `testZeroOriginAnchorIsUsedEvenWhenItIsNeitherScreensFirstNorIsMain`.
    //     Windows UI Automation and `GetMonitorInfoW` already share ONE
    //     common top-left-origin virtual-desktop space with no equivalent
    //     quirk to correct for, so the Windows `backingRect` does a plain
    //     per-screen origin subtraction with no "hunt for the zero-origin
    //     anchor display" step at all (see that method's Windows doc
    //     comment) -- there is no anchor-display invariant for these tests'
    //     "missing anchor" / "anchor is not first/main" scenarios to
    //     exercise there.
    #if os(macOS)
    func testValueMatchPublishesTheQueryNotSurroundingEditableContent() {
        // `contains` only establishes that the query occurs somewhere in an
        // editable field. The raw AXValue may contain a document, password,
        // or other user content on either side, none of which may reach the
        // annotation label or MCP result.
        let rawValue = "Private draft before needle and private draft after"
        let label = AccessibilityElementResolver.publishedMatchLabel(
            attribute: kAXValueAttribute,
            value: rawValue,
            query: "needle"
        )
        XCTAssertEqual(label, "needle")
        XCTAssertFalse(label.contains("Private"))
        XCTAssertFalse(label.contains("before"))
        XCTAssertFalse(label.contains("after"))
    }

    func testPublishedMatchedLabelIsBoundedWithoutSplittingUnicode() {
        let rawTitle = String(repeating: "😀", count: AccessibilityElementResolver.maxPublishedLabelCharacters + 10)
        let label = AccessibilityElementResolver.publishedMatchLabel(
            attribute: kAXTitleAttribute,
            value: rawTitle,
            query: "unused"
        )
        XCTAssertEqual(label.count, AccessibilityElementResolver.maxPublishedLabelCharacters)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertFalse(label.contains("�"))
    }

    func testLongValueQueryIsAlsoBoundedBeforeItCanBeStoredOrReturned() {
        let query = String(repeating: "x", count: AccessibilityElementResolver.maxPublishedLabelCharacters + 10)
        let label = AccessibilityElementResolver.publishedMatchLabel(
            attribute: kAXValueAttribute,
            value: "prefix \(query) suffix",
            query: query
        )
        XCTAssertEqual(label.count, AccessibilityElementResolver.maxPublishedLabelCharacters)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertFalse(label.contains("prefix"))
        XCTAssertFalse(label.contains("suffix"))
    }

    func testPrimaryDisplayAccessibilityFrameConvertsToLocalBackingPixels() throws {
        let primary = screen(
            id: "main",
            appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_512, height: 982),
            scale: 2
        )
        let result = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 100, y: 50, width: 120, height: 30),
            screens: [primary]
        ))
        XCTAssertEqual(result.screenId, "main")
        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 100)
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.height, 60)
    }

    func testSecondaryMixedScaleDisplayUsesDesktopTopAndItsOwnScale() throws {
        let main = screen(
            id: "main",
            appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800),
            scale: 1
        )
        let upperLeftRetina = screen(
            id: "upper-left",
            appKitFrame: ScreenCoordinateRect(x: -500, y: 800, width: 1_200, height: 600),
            scale: 2
        )
        let result = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            // AX's top-left global coordinates are anchored to the main
            // screen, so an element above it has a negative Y.
            forAccessibilityFrame: AccessibilityScreenRect(x: -400, y: -500, width: 40, height: 20),
            screens: [main, upperLeftRetina]
        ))
        XCTAssertEqual(result.screenId, "upper-left")
        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 200)
        XCTAssertEqual(result.width, 80)
        XCTAssertEqual(result.height, 40)
    }

    /// `ScreenInfo.isMain` is "the screen AppKit currently calls main", which
    /// tracks the focused window.  AX global coordinates are anchored to the
    /// ZERO-ORIGIN (menu-bar) display instead, so anchoring the conversion to
    /// `isMain` shifted every y-coordinate by the two displays' height
    /// difference -- and changed the answer for an unchanged UI whenever focus
    /// moved to another monitor.
    func testConversionAnchorsToZeroOriginDisplayNotTheFocusedMainScreen() throws {
        let zeroOrigin = screen(
            id: "zero-origin",
            appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_512, height: 982),
            scale: 2
        )
        // Focus currently sits on a taller display to the right, so AppKit
        // reports THIS screen as main even though it is not the AX anchor.
        let focusedTallerSecondary = screen(
            id: "main",
            appKitFrame: ScreenCoordinateRect(x: 1_512, y: -40, width: 1_920, height: 1_080),
            scale: 1
        )
        XCTAssertTrue(focusedTallerSecondary.isMain)
        XCTAssertFalse(zeroOrigin.isMain)

        let result = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 100, y: 50, width: 120, height: 30),
            screens: [zeroOrigin, focusedTallerSecondary]
        ))
        XCTAssertEqual(result.screenId, "zero-origin")
        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 100)
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.height, 60)
    }

    /// `?? screens.first` used to be the fallback here.  With no zero-origin
    /// display present at all -- an invariant violation, since macOS always
    /// places one display's AppKit frame at exactly (0, 0) -- the OLD code
    /// would have anchored `desktopTop` to `screens.first` ("a", maxY 800)
    /// and returned a silently-displaced-but-successful rect: screenId "a",
    /// x=100, y=100, width=50, height=20 (worked out by hand from this same
    /// frame and screen layout below). The fix removes that fallback, so the
    /// same inputs must now return nil instead.
    func testMissingZeroOriginDisplayReturnsNilInsteadOfAnchoringToAnArbitraryScreen() {
        let a = screen(id: "a", appKitFrame: ScreenCoordinateRect(x: 500, y: 0, width: 1_000, height: 800), scale: 1)
        let b = screen(id: "b", appKitFrame: ScreenCoordinateRect(x: -600, y: -100, width: 600, height: 400), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 600, y: 100, width: 50, height: 20),
            screens: [a, b]
        ))
    }

    /// The zero-origin display must be found by SEARCHING the whole list, not
    /// by being conflated with `screens.first` or with `ScreenInfo.isMain` --
    /// exactly the case the removed `?? screens.first` fallback could get
    /// wrong. Here the (0, 0) display is second in the array and is not the
    /// focused ("main") display, yet it must still be the anchor, with exact
    /// backing-pixel numbers.
    func testZeroOriginAnchorIsUsedEvenWhenItIsNeitherScreensFirstNorIsMain() throws {
        let focusedNonZeroOriginMain = screen(
            id: "main",
            appKitFrame: ScreenCoordinateRect(x: 1_200, y: -50, width: 1_920, height: 1_080),
            scale: 1
        )
        let zeroOriginSecondary = screen(
            id: "secondary-zero",
            appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_512, height: 982),
            scale: 2
        )
        XCTAssertTrue(focusedNonZeroOriginMain.isMain)
        XCTAssertFalse(zeroOriginSecondary.isMain)

        let result = try XCTUnwrap(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 100, y: 50, width: 120, height: 30),
            screens: [focusedNonZeroOriginMain, zeroOriginSecondary]
        ))
        XCTAssertEqual(result.screenId, "secondary-zero")
        XCTAssertEqual(result.x, 200)
        XCTAssertEqual(result.y, 100)
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.height, 60)
    }
    #endif

    func testFrameStraddlingDisplaysIsRejectedRatherThanSilentlyClipped() {
        let left = screen(id: "left", appKitFrame: ScreenCoordinateRect(x: -1_000, y: 0, width: 1_000, height: 800), scale: 1)
        let right = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: -10, y: 100, width: 30, height: 20),
            screens: [left, right]
        ))
    }

    func testInvalidAccessibilityFrameIsRejected() {
        let primary = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 0, y: 0, width: 0, height: 20),
            screens: [primary]
        ))
    }

    // Windows-only note: `traversalDeadlineExceeded`/`initialElements`/
    // `boundedAppendCount`/`isTransientAXFailure`/`resolveInitialElements`
    // (and the `AXError`/`AttributeFetch<Element>` types they use) are all
    // internal helpers of macOS's AXUIElement-based breadth-first walk, with
    // no declared counterpart in the Windows branch at all -- the Windows
    // resolver's traversal happens inside the C++ shim's own manual walk
    // (`chalk_uia.cpp`), opaque to Swift, so there is nothing here to unit
    // test on that platform. Every test below through
    // `testResolveInitialElementsThrowsBusyWhenChildrenTimesOutEvenIfWindowsAnsweredDefinitivelyEmpty`
    // that depends on one of these symbols is guarded macOS-only for that
    // reason; see each guard for the specific symbol.
    #if os(macOS)
    func testTraversalDeadlineUsesMonotonicElapsedTime() {
        XCTAssertFalse(AccessibilityElementResolver.traversalDeadlineExceeded(
            startedAt: 100, now: 101.999, timeout: 2
        ))
        XCTAssertTrue(AccessibilityElementResolver.traversalDeadlineExceeded(
            startedAt: 100, now: 102, timeout: 2
        ))
        XCTAssertTrue(AccessibilityElementResolver.traversalDeadlineExceeded(
            startedAt: 100, now: 105, timeout: 2
        ))
    }

    func testEmptyWindowsFallsBackToApplicationChildrenButNonEmptyWindowsWin() {
        XCTAssertEqual(
            AccessibilityElementResolver.initialElements(windows: [], children: [1, 2]),
            [1, 2]
        )
        XCTAssertEqual(
            AccessibilityElementResolver.initialElements(windows: [3], children: [1, 2]),
            [3]
        )
    }

    func testBoundedAppendOnlyUsesRemainingInspectionCapacity() {
        XCTAssertEqual(
            AccessibilityElementResolver.boundedAppendCount(
                candidateCount: 100_000, queuedUninspected: 0, inspected: 0, maxNodes: 3_000
            ),
            3_000
        )
        XCTAssertEqual(
            AccessibilityElementResolver.boundedAppendCount(
                candidateCount: 50, queuedUninspected: 4, inspected: 3, maxNodes: 10
            ),
            3
        )
        XCTAssertEqual(
            AccessibilityElementResolver.boundedAppendCount(
                candidateCount: 1, queuedUninspected: 0, inspected: 10, maxNodes: 10
            ),
            0
        )
    }
    #endif

    // MARK: - AccessibilityElementResolverError.applicationBusy (item 8)

    func testApplicationBusyIsDistinctFromApplicationUnavailable() {
        // Equatable-safe per the prior work's summary: confirm the two
        // failure modes this split exists to separate do not collapse back
        // into each other.
        XCTAssertNotEqual(AccessibilityElementResolverError.applicationBusy, .applicationUnavailable)
        XCTAssertEqual(AccessibilityElementResolverError.applicationBusy, .applicationBusy)
        XCTAssertNotEqual(
            AccessibilityElementResolverError.applicationBusy.errorDescription,
            AccessibilityElementResolverError.applicationUnavailable.errorDescription
        )
    }

    // Windows-only note: this test asserts exact macOS wording fragments
    // ("not a missing Accessibility implementation") against `applicationBusy`'s
    // `errorDescription`. The Windows branch's own `applicationBusy` message
    // makes the identical no-missing-implementation, retry-worthy point but
    // in different words ("not a missing UI Automation implementation") --
    // see that case's Windows doc comment -- so this exact-phrase assertion
    // does not carry over; a Windows-worded equivalent is not written here.
    #if os(macOS)
    func testApplicationBusyMessageDoesNotClaimTheAppLacksAccessibilityMetadata() throws {
        // THE bug `applicationBusy` exists to fix: a timed-out top-level AX
        // fetch used to be reported as `applicationUnavailable`, whose
        // wording ("Ensure the app is running and exposes Accessibility
        // metadata") reads as "this app doesn't implement Accessibility" --
        // which sent a calling agent off to eyeball a screenshot instead of
        // simply retrying a lookup that would likely have succeeded a moment
        // later. Assert the busy message never repeats that framing, and
        // instead says the opposite explicitly.
        let message = try XCTUnwrap(AccessibilityElementResolverError.applicationBusy.errorDescription)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("hierarchy is unavailable"),
                        "must not reuse applicationUnavailable's wording: \(message)")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("does not expose"),
                        "must not claim the app fails to expose Accessibility metadata: \(message)")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("does not have"),
                        "must not claim the app lacks an Accessibility implementation: \(message)")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("not a missing Accessibility implementation"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("transient"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retry"))
    }
    #endif

    // MARK: - AccessibilityElementResolverError.noMatches exposed-sample preview (item 9)

    private func candidate(_ label: String, role: String?,
                           backingFrame: AccessibilityBackingRect? = nil) -> AccessibilityElementCandidate {
        AccessibilityElementCandidate(matchedAttribute: "AXTitle", matchedLabel: label,
                                      role: role, backingFrame: backingFrame)
    }

    // Windows-only note: every test below through
    // `testNoMatchesPreviewFallsBackToUnknownRoleWhenRoleIsNil` asserts the
    // exact macOS `.noMatches` wording ("...to macOS Accessibility.",
    // "Labels that ARE exposed here..."). The Windows branch's `.noMatches`
    // case carries the same sample-ranking behavior but different wording
    // ("...to Windows UI Automation.", "Names that ARE exposed here...") --
    // see that case's Windows doc comment -- so these exact-string
    // assertions are macOS-specific.
    #if os(macOS)
    func testNoMatchesWithEmptySampleKeepsTheOriginalSentenceVerbatim() {
        XCTAssertEqual(
            AccessibilityElementResolverError.noMatches(label: "Foo", role: nil, exposedSample: []).errorDescription,
            "No accessibility element matched label 'Foo'. The UI may not expose that control to macOS Accessibility."
        )
        XCTAssertEqual(
            AccessibilityElementResolverError.noMatches(label: "Foo", role: "AXButton", exposedSample: []).errorDescription,
            "No accessibility element matched label 'Foo' with role 'AXButton'. The UI may not expose that control to macOS Accessibility."
        )
    }

    func testNoMatchesWithNonEmptySampleRanksRelatedLabelsFirstAndKeepsBFSOrderWithinEachGroup() throws {
        // "Unrelated1"/"Unrelated2" and "Tracking Panel"/"Track" are
        // interleaved in BFS discovery order; the related pair (case-
        // insensitive two-way `contains` against the query "Tracking") must
        // move to the front WITHOUT reordering relative to their own group,
        // proving the sort is stable.
        let sample = [
            candidate("Unrelated1", role: "AXButton"),
            candidate("Tracking Panel", role: "AXGroup"),
            candidate("Unrelated2", role: "AXButton"),
            candidate("Track", role: "AXStaticText")
        ]
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.noMatches(label: "Tracking", role: nil, exposedSample: sample).errorDescription
        )
        XCTAssertEqual(
            message,
            "No accessibility element matched label 'Tracking'. Labels that ARE exposed here include: "
                + "'Tracking Panel' [AXGroup], 'Track' [AXStaticText], 'Unrelated1' [AXButton], 'Unrelated2' [AXButton]. "
                + "Retry with one of those labels (optionally adding a role) instead of falling back to screen coordinates."
        )
    }

    func testNoMatchesPreviewShowsAtMostEightAndReportsTheRemainderCount() throws {
        let sample = (1...10).map { candidate("Item\($0)", role: "AXButton") }
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.noMatches(label: "Query", role: nil, exposedSample: sample).errorDescription
        )
        for index in 1...8 {
            XCTAssertTrue(message.contains("'Item\(index)' [AXButton]"), "expected Item\(index) in: \(message)")
        }
        XCTAssertFalse(message.contains("'Item9'"), "the 9th sample entry must be truncated away: \(message)")
        XCTAssertFalse(message.contains("'Item10'"), "the 10th sample entry must be truncated away: \(message)")
        XCTAssertTrue(message.contains("(and 2 more)"), "expected a truncation tail counting the remaining 2: \(message)")
    }

    func testNoMatchesPreviewFallsBackToUnknownRoleWhenRoleIsNil() throws {
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.noMatches(
                label: "Query", role: nil, exposedSample: [candidate("NoRole", role: nil)]
            ).errorDescription
        )
        XCTAssertTrue(message.contains("'NoRole' [unknown role]"), "expected in: \(message)")
    }
    #endif

    // MARK: - AccessibilityElementResolver.isTransientAXFailure (item 10)

    // Windows-only note: `isTransientAXFailure`/`AXError` are macOS-only
    // (see the guard at `testTraversalDeadlineUsesMonotonicElapsedTime`
    // above for why).
    #if os(macOS)
    func testTransientAXFailureClassificationPinsEveryCase() {
        // The measured-bug cases: the call could not get an answer, and a
        // retry may well succeed. `.cannotComplete` is the code Apple
        // documents for "messaging failed, or the application is busy or
        // unresponsive"; `.failure` is a generic system error.
        XCTAssertTrue(AccessibilityElementResolver.isTransientAXFailure(.cannotComplete))
        XCTAssertTrue(AccessibilityElementResolver.isTransientAXFailure(.failure))

        // `.notImplemented` is ALSO a "no answer" outcome but is NOT
        // transient: Apple defines it as "the process does not fully support
        // the accessibility API", a permanent property of that application.
        // Classifying it as busy would tell a caller to retry forever against
        // an app that will never answer -- the same misleading-error bug this
        // split exists to remove, merely inverted. It must fall through to
        // applicationUnavailable, whose advice about the app not exposing
        // Accessibility metadata is exactly right for this code.
        XCTAssertFalse(AccessibilityElementResolver.isTransientAXFailure(.notImplemented))

        // The call DID get a definitive answer of "nothing here".
        XCTAssertFalse(AccessibilityElementResolver.isTransientAXFailure(.attributeUnsupported))
        XCTAssertFalse(AccessibilityElementResolver.isTransientAXFailure(.noValue))
        XCTAssertFalse(AccessibilityElementResolver.isTransientAXFailure(.invalidUIElement))

        // Everything else falls through `default` to non-transient: a real,
        // non-busy condition (bad arguments, AX API disabled), not a
        // retry-worthy timeout.
        XCTAssertFalse(AccessibilityElementResolver.isTransientAXFailure(.illegalArgument))
        XCTAssertFalse(AccessibilityElementResolver.isTransientAXFailure(.apiDisabled))
    }
    #endif

    // MARK: - AccessibilityElementResolver.resolveInitialElements (item 10)
    // Windows-only note: `resolveInitialElements`/`AttributeFetch<Element>`
    // are macOS-only (see the guard at
    // `testTraversalDeadlineUsesMonotonicElapsedTime` above for why).
    #if os(macOS)

    private typealias Fetch = AccessibilityElementResolver.AttributeFetch<Int>

    /// Thin, explicitly-`Int`-typed wrapper around the generic
    /// `resolveInitialElements<Element>` so every call site below can pass
    /// plain `.values`/`.unreadable` case syntax without the compiler having
    /// nothing concrete to infer `Element` from (an empty array literal on
    /// both sides leaves `Element` completely unconstrained). The `children`
    /// parameter stays `@autoclosure` and is forwarded via `children()`,
    /// Swift's standard idiom for threading one `@autoclosure` parameter into
    /// another without eagerly evaluating it here -- the call expression
    /// becomes the inner parameter's own deferred thunk body, so laziness
    /// still composes through this wrapper. Verified directly by
    /// `testResolveInitialElementsPrefersNonEmptyWindowsWithoutEvaluatingChildren`.
    private func resolveInitial(windows: Fetch, children: @autoclosure () -> Fetch) throws -> [Int] {
        try AccessibilityElementResolver.resolveInitialElements(windows: windows, children: children())
    }

    func testResolveInitialElementsPrefersNonEmptyWindowsWithoutEvaluatingChildren() throws {
        // Mirrors `initialElements`'s own `@autoclosure` laziness contract: a
        // populated windows list must never pay for the children IPC at all.
        var childrenEvaluated = false
        func children() -> Fetch {
            childrenEvaluated = true
            return .values([9, 9])
        }
        let result = try resolveInitial(windows: .values([1, 2]), children: children())
        XCTAssertEqual(result, [1, 2])
        XCTAssertFalse(childrenEvaluated, "a non-empty windows list must short-circuit the children fetch")
    }

    func testResolveInitialElementsFallsBackToNonEmptyChildrenWhenWindowsIsEmpty() throws {
        let result = try resolveInitial(windows: .values([]), children: .values([1, 2]))
        XCTAssertEqual(result, [1, 2])
    }

    func testResolveInitialElementsTrustsADefinitiveEmptyChildrenAnswerWithoutThrowing() throws {
        // Both fetches genuinely succeeded and both said "nothing here" -- a
        // real, definitive empty tree, not a busy signal.
        let result = try resolveInitial(windows: .values([]), children: .values([]))
        XCTAssertEqual(result, [])
    }

    func testResolveInitialElementsThrowsBusyWhenBothFetchesTimeOut() {
        XCTAssertThrowsError(
            try resolveInitial(windows: .unreadable(.cannotComplete), children: .unreadable(.cannotComplete))
        ) { error in
            XCTAssertEqual(error as? AccessibilityElementResolverError, .applicationBusy)
        }
    }

    func testResolveInitialElementsDoesNotThrowWhenBothFetchesDefinitivelyAnswerNothing() throws {
        // Neither AXError is transient (both are "the call got an answer:
        // there is nothing here"), so this must read as a genuinely empty
        // hierarchy, not a busy app.
        let result = try resolveInitial(windows: .unreadable(.noValue), children: .unreadable(.attributeUnsupported))
        XCTAssertEqual(result, [])
    }

    func testResolveInitialElementsThrowsBusyWhenChildrenTimesOutRegardlessOfWindows() {
        // Children is the fetch that still had a chance to supply elements
        // once windows came back empty/unreadable -- if IT timed out, the
        // lookup must not silently report an empty tree, no matter how
        // windows' own (non-transient) failure reads.
        XCTAssertThrowsError(
            try resolveInitial(windows: .unreadable(.noValue), children: .unreadable(.cannotComplete))
        ) { error in
            XCTAssertEqual(error as? AccessibilityElementResolverError, .applicationBusy)
        }
    }

    func testResolveInitialElementsThrowsBusyWhenWindowsTimesOutAndChildrenIsAlsoUnreadable() {
        // The documented, deliberately-chosen resolution of the spec's
        // ambiguity (see the prior work's "Deviations"): children being
        // `.unreadable` at all (regardless of ITS OWN error's transience) is
        // the necessary condition; either side's fetch being transient is
        // sufficient. Here windows timed out and children came back
        // `.unreadable` for a non-transient reason -- this still throws
        // busy, because a windows timeout means the lookup never actually
        // got a trustworthy answer.
        XCTAssertThrowsError(
            try resolveInitial(windows: .unreadable(.cannotComplete), children: .unreadable(.noValue))
        ) { error in
            XCTAssertEqual(error as? AccessibilityElementResolverError, .applicationBusy)
        }
    }

    func testResolveInitialElementsThrowsBusyWhenChildrenTimesOutEvenIfWindowsAnsweredDefinitivelyEmpty() {
        // A real (non-`.unreadable`) empty windows answer does NOT count as
        // "windows had a chance and answered"; children is still the fetch
        // that mattered here, and it timed out.
        XCTAssertThrowsError(
            try resolveInitial(windows: .values([]), children: .unreadable(.cannotComplete))
        ) { error in
            XCTAssertEqual(error as? AccessibilityElementResolverError, .applicationBusy)
        }
    }
    #endif

    // MARK: - AccessibilityElementResolverError.matchesHaveNoUsableFrame
    //
    // Replaces the old, now-unreachable `selectedElementHasNoFrame`: once the
    // BFS loop reads a matched element's frame at match time and refuses to
    // let a frameless match enter `matches` at all, whichever element
    // `resolve()` goes on to select is guaranteed to already have a usable
    // frame. What remains reachable is the case where EVERY element that
    // matched the label lacked one, leaving nothing to select.

    func testMatchesHaveNoUsableFrameReportsTheCountAndDoesNotClaimNothingMatched() throws {
        let message = try XCTUnwrap(AccessibilityElementResolverError.matchesHaveNoUsableFrame(matchCount: 3).errorDescription)
        XCTAssertTrue(message.contains("3"), "expected the frameless match count in: \(message)")
        // The whole point of this case existing separately from `.noMatches`
        // is that these elements DID match the label -- a caller who can see
        // the control on screen must not be told (as `.noMatches` would say)
        // that the UI may not expose it at all.
        XCTAssertFalse(message.localizedCaseInsensitiveContains("no accessibility element matched"),
                        "must not claim nothing matched -- these elements DID match, just with no usable frame: \(message)")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("may not expose that control"),
                        "must not claim the control isn't exposed at all: \(message)")
    }

    func testMatchesHaveNoUsableFrameIsDistinctFromNoMatchesForTheSameLabel() throws {
        // Two different failures with two different fixes: "nothing matched"
        // invites a different label/role, while "matched but unhighlightable"
        // invites screenshot-measured coordinates instead. They must never
        // collapse into the same text or the same case.
        let framelessError = AccessibilityElementResolverError.matchesHaveNoUsableFrame(matchCount: 2)
        let noMatchesError = AccessibilityElementResolverError.noMatches(label: "Tracking", role: nil, exposedSample: [])
        XCTAssertNotEqual(framelessError, noMatchesError)
        let framelessMessage = try XCTUnwrap(framelessError.errorDescription)
        let noMatchesMessage = try XCTUnwrap(noMatchesError.errorDescription)
        XCTAssertNotEqual(framelessMessage, noMatchesMessage)
    }

    // Windows-only note: exact macOS `.noMatches` wording -- see the guard
    // above `testNoMatchesWithEmptySampleKeepsTheOriginalSentenceVerbatim`.
    #if os(macOS)
    func testNoMatchesIsStillThrownWithItsExposedSampleWhenNothingMatchedAtAll() throws {
        // Confirms the ordinary "the label was never seen" path is untouched
        // by the frame-usability split above: `.noMatches` keeps reporting
        // its exposed-label sample exactly as before.
        let sample = [candidate("Tracking Panel", role: "AXGroup")]
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.noMatches(label: "Tracking", role: nil, exposedSample: sample).errorDescription
        )
        XCTAssertEqual(
            message,
            "No accessibility element matched label 'Tracking'. Labels that ARE exposed here include: "
                + "'Tracking Panel' [AXGroup]. Retry with one of those labels (optionally adding a role) instead of falling back to screen coordinates."
        )
    }
    #endif

    // MARK: - AccessibilityElementResolverError.occurrenceOutOfRange framelessMatchCount

    func testOccurrenceOutOfRangeWithZeroFramelessMatchesOmitsTheFramelessNoteEntirely() {
        // A call site that never sees a frameless match (the overwhelming
        // common case) must get back exactly the base sentence, with no
        // trailing note about a phenomenon that did not happen here.
        XCTAssertEqual(
            AccessibilityElementResolverError.occurrenceOutOfRange(
                requested: 5, available: 2, framelessMatchCount: 0
            ).errorDescription,
            "Requested accessibility occurrence 5, but only 2 highlightable matching element(s) were found. Occurrence is one-based."
        )
    }

    // Windows-only note: this asserts the exact macOS frameless-note wording
    // ("matched the label", "no usable screen frame (no AXPosition/AXSize)").
    // The Windows branch's `occurrenceOutOfRange` frameless note makes the
    // identical point in different words ("matched the name", "no usable
    // bounding rectangle") -- see that case's Windows doc comment.
    #if os(macOS)
    func testOccurrenceOutOfRangeWithFramelessMatchesAppendsHowManyWereSkipped() {
        XCTAssertEqual(
            AccessibilityElementResolverError.occurrenceOutOfRange(
                requested: 5, available: 2, framelessMatchCount: 3
            ).errorDescription,
            "Requested accessibility occurrence 5, but only 2 highlightable matching element(s) were found. Occurrence is one-based."
                + " 3 additional element(s) also matched the label but were skipped because they published no usable screen frame"
                + " (no AXPosition/AXSize), so they could not be assigned an occurrence."
        )
    }
    #endif

    // MARK: - Traversal error messages name `occurrence` as the escape hatch first

    /// The traversal errors are the two places this codebase actively PUSHES a
    /// caller toward `occurrence` ("Try supplying occurrence FIRST"). That
    /// advice hands back a truncated walk, so it must ship with the check that
    /// covers what the truncation gave up -- otherwise the tool's own advice
    /// is what produces an unverified, possibly-wrong anchor. Shared (not
    /// macOS-only): the Windows `traversalLimitReached` carries this caveat
    /// in the identical words, deliberately, because the property being
    /// described belongs to `occurrence` rather than to either platform.
    func testTraversalLimitReachedPairsTheOccurrenceAdviceWithAUniquenessCaveat() throws {
        let message = try XCTUnwrap(AccessibilityElementResolverError.traversalLimitReached(3_000).errorDescription)
        XCTAssertTrue(message.contains("occurrence short-circuits uniqueness checking"),
                       "the occurrence advice must disclose what it gives up: \(message)")
        let occurrenceAdvice = try XCTUnwrap(message.range(of: "Try supplying occurrence FIRST"))
        let caveat = try XCTUnwrap(message.range(of: "occurrence short-circuits uniqueness checking"))
        XCTAssertLessThan(occurrenceAdvice.lowerBound, caveat.lowerBound,
                           "the caveat must follow the advice it qualifies, not precede it: \(message)")
        // `verify_annotation` already appears in the screenshot-fallback tail,
        // so pin that it ALSO appears alongside the occurrence advice rather
        // than only at the very end of the message.
        let verifyBeforeFallback = try XCTUnwrap(message.range(of: "verify_annotation"))
        XCTAssertLessThan(verifyBeforeFallback.lowerBound, message.range(of: "raise max_nodes")?.lowerBound ?? message.endIndex,
                           "verify_annotation must be paired with the occurrence advice: \(message)")
    }

    func testTraversalLimitReachedNamesOccurrenceBeforeRaisingMaxNodesAndKeepsTheScreenshotFallback() throws {
        let message = try XCTUnwrap(AccessibilityElementResolverError.traversalLimitReached(3_000).errorDescription)
        XCTAssertTrue(message.contains("occurrence: 1"), "expected the concrete occurrence example in: \(message)")
        XCTAssertTrue(message.contains("3000"), "expected the hit node budget named in: \(message)")
        XCTAssertTrue(message.contains("max_nodes"), "must still name its own budget parameter: \(message)")
        let occurrenceRange = try XCTUnwrap(message.range(of: "occurrence"))
        let maxNodesRange = try XCTUnwrap(message.range(of: "max_nodes"))
        XCTAssertLessThan(occurrenceRange.lowerBound, maxNodesRange.lowerBound,
                           "occurrence must be named as the FIRST thing to try, ahead of raising max_nodes: \(message)")
        XCTAssertTrue(message.contains("verify_annotation"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("screenshot"))
    }

    // Windows-only note: `AccessibilityElementResolverError.traversalTimedOut`
    // has no case on Windows at all -- `CHALK_ERR_UIA_RETRYABLE_TIMEOUT`
    // (a per-call COM RPC timeout) maps to `.applicationBusy` instead, and
    // the Windows shim's own overall traversal deadline is enforced
    // C++-side inside `chalk_uia_find_element`, surfaced (if ever hit) as
    // `.traversalLimitReached` there being the only node/time-budget
    // exhaustion case exposed to Swift. This test and the one below it both
    // reference `.traversalTimedOut` directly, so both are macOS-only.
    #if os(macOS)
    func testTraversalTimedOutNamesOccurrenceBeforeRaisingTimeoutSecondsAndKeepsTheScreenshotFallback() throws {
        let message = try XCTUnwrap(AccessibilityElementResolverError.traversalTimedOut(seconds: 2.0).errorDescription)
        XCTAssertTrue(message.contains("occurrence: 1"), "expected the concrete occurrence example in: \(message)")
        XCTAssertTrue(message.contains("2.0"), "expected the elapsed seconds named in: \(message)")
        XCTAssertTrue(message.contains("timeout_seconds"), "must still name its own budget parameter: \(message)")
        let occurrenceRange = try XCTUnwrap(message.range(of: "occurrence"))
        let timeoutRange = try XCTUnwrap(message.range(of: "timeout_seconds"))
        XCTAssertLessThan(occurrenceRange.lowerBound, timeoutRange.lowerBound,
                           "occurrence must be named as the FIRST thing to try, ahead of raising timeout_seconds: \(message)")
        XCTAssertTrue(message.contains("verify_annotation"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("screenshot"))
    }

    func testTraversalTimedOutPairsTheOccurrenceAdviceWithTheSameUniquenessCaveat() throws {
        // Same requirement as `traversalLimitReached`'s caveat test above,
        // and deliberately the same sentence: the two errors are two symptoms
        // of one limitation and must not drift into two different accounts of
        // what `occurrence` costs.
        let message = try XCTUnwrap(AccessibilityElementResolverError.traversalTimedOut(seconds: 2.0).errorDescription)
        let caveat = "Then confirm the result with verify_annotation, because occurrence short-circuits uniqueness checking: you get the first highlightable match, never a guarantee that it is the only one."
        XCTAssertTrue(message.contains(caveat), "missing verbatim uniqueness caveat in: \(message)")
        let limitMessage = try XCTUnwrap(AccessibilityElementResolverError.traversalLimitReached(3_000).errorDescription)
        XCTAssertTrue(limitMessage.contains(caveat), "missing verbatim uniqueness caveat in: \(limitMessage)")
    }

    func testTraversalLimitReachedAndTraversalTimedOutShareTheSameScreenshotFallbackSentenceVerbatim() throws {
        // Both errors are two different symptoms of the identical underlying
        // limitation (some applications publish trees no bounded read can
        // finish), so their escape-hatch advice must read as one voice, not
        // two independently-drifting explanations.
        let limitMessage = try XCTUnwrap(AccessibilityElementResolverError.traversalLimitReached(3_000).errorDescription)
        let timeoutMessage = try XCTUnwrap(AccessibilityElementResolverError.traversalTimedOut(seconds: 2.0).errorDescription)
        let fallbackSentence = "measure from an uncropped full-display screenshot instead and confirm the result with verify_annotation."
        XCTAssertTrue(limitMessage.contains(fallbackSentence), "missing verbatim fallback sentence in: \(limitMessage)")
        XCTAssertTrue(timeoutMessage.contains(fallbackSentence), "missing verbatim fallback sentence in: \(timeoutMessage)")
    }
    #endif

    // MARK: - AccessibilityElementResolver.backingRect frame-usability edge cases (isUsable)
    //
    // `isUsable` itself is private, so these pin its predicate indirectly
    // through the public `backingRect(forAccessibilityFrame:screens:)` entry
    // point it gates -- the same style `testInvalidAccessibilityFrameIsRejected`
    // above already uses for the zero-width case.

    func testZeroHeightAccessibilityFrameIsRejected() {
        let primary = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 0, y: 0, width: 20, height: 0),
            screens: [primary]
        ))
    }

    func testNegativeWidthOrHeightAccessibilityFrameIsRejected() {
        let primary = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 0, y: 0, width: -20, height: 20),
            screens: [primary]
        ))
        XCTAssertNil(AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: AccessibilityScreenRect(x: 0, y: 0, width: 20, height: -20),
            screens: [primary]
        ))
    }

    func testNonFiniteAccessibilityFrameComponentsAreEachRejected() {
        // Every one of the four fields is checked independently by `isUsable`
        // (`[x, y, width, height].allSatisfy(\.isFinite)`); cover NaN and
        // infinity on each field individually rather than only exercising one
        // combination, so a regression narrowed to a single field's check
        // cannot slip through unnoticed.
        let primary = screen(id: "main", appKitFrame: ScreenCoordinateRect(x: 0, y: 0, width: 1_000, height: 800), scale: 1)
        let nonFiniteFrames: [AccessibilityScreenRect] = [
            AccessibilityScreenRect(x: .nan, y: 0, width: 20, height: 20),
            AccessibilityScreenRect(x: .infinity, y: 0, width: 20, height: 20),
            AccessibilityScreenRect(x: 0, y: .nan, width: 20, height: 20),
            AccessibilityScreenRect(x: 0, y: -.infinity, width: 20, height: 20),
            AccessibilityScreenRect(x: 0, y: 0, width: .nan, height: 20),
            AccessibilityScreenRect(x: 0, y: 0, width: .infinity, height: 20),
            AccessibilityScreenRect(x: 0, y: 0, width: 20, height: .nan),
            AccessibilityScreenRect(x: 0, y: 0, width: 20, height: .infinity)
        ]
        for frame in nonFiniteFrames {
            XCTAssertNil(AccessibilityElementResolver.backingRect(forAccessibilityFrame: frame, screens: [primary]),
                         "expected nil for non-finite frame \(frame)")
        }
    }

    // MARK: - Ambiguity candidates carry geometry, so `occurrence` is not blind
    //
    // The BFS that POPULATES `AccessibilityElementCandidate.backingFrame` is a
    // live cross-process AX walk and is not reachable headlessly (it needs a
    // running target app plus a granted TCC Accessibility permission), so what
    // is pinned here is everything downstream of it that a caller actually
    // reads: the rendering of one candidate's geometry, and the whole
    // `.ambiguous` message built from a list of them. That is the part a
    // regression would silently break -- the resolver would keep computing
    // correct rects while the message stopped showing them, putting the caller
    // straight back to guessing an occurrence.
    //
    // Windows-only note: `.ambiguous` has a different SHAPE there
    // (`ambiguous(matchCount:)` -- `chalk_uia_find_element` reports a count
    // and no per-candidate list at all), and `geometryNote` exists only on the
    // macOS error type, so this whole section is macOS-only.
    #if os(macOS)
    private func backing(_ screenId: String, _ x: Double, _ y: Double,
                         _ width: Double, _ height: Double) -> AccessibilityBackingRect {
        AccessibilityBackingRect(screenId: screenId, x: x, y: y, width: width, height: height)
    }

    func testCandidateGeometryNoteRendersWholeBackingPixelsWithoutFloatingPointNoise() {
        XCTAssertEqual(
            AccessibilityElementResolverError.geometryNote(
                for: candidate("Tracking", role: "AXStaticText",
                               backingFrame: backing("S1", 4_200, 600, 240, 36))
            ),
            " -- screen S1 at 4200,600 240x36"
        )
    }

    func testCandidateGeometryNoteSaysSoWhenACandidateMapsOntoNoSingleDisplay() {
        // Reachable in real use: a match can publish a perfectly usable AX
        // frame that still straddles two displays, which `backingRect`
        // rejects. Selecting that occurrence would fail with
        // `frameCannotBeMapped`, so the list must say so rather than print a
        // silent gap that reads like "geometry unknown, probably fine".
        let note = AccessibilityElementResolverError.geometryNote(
            for: candidate("Tracking", role: "AXStaticText", backingFrame: nil)
        )
        XCTAssertEqual(note, " -- does not map onto a single display")
    }

    func testAmbiguousPreviewNumbersEachCandidateWithTheOccurrenceThatSelectsIt() throws {
        // THE BUG THIS FIXES: five identically-labelled candidates used to
        // render as five IDENTICAL strings, with no index and no geometry, so
        // the caller picked an `occurrence` blind -- a measured session ringed
        // a menu-bar item roughly 4,000 backing pixels from the Inspector row
        // it meant. The list position and the argument value must be visibly
        // the same number.
        let matches = [
            candidate("Tracking", role: "AXMenuItem", backingFrame: backing("S1", 120, 4, 80, 22)),
            candidate("Tracking", role: "AXStaticText", backingFrame: backing("S1", 4_200, 600, 240, 36))
        ]
        let message = try XCTUnwrap(AccessibilityElementResolverError.ambiguous(matches: matches).errorDescription)
        XCTAssertTrue(message.contains("occurrence 1: 'Tracking' [AXMenuItem] via AXTitle -- screen S1 at 120,4 80x22"),
                       "expected a numbered, geometry-carrying first entry in: \(message)")
        XCTAssertTrue(message.contains("occurrence 2: 'Tracking' [AXStaticText] via AXTitle -- screen S1 at 4200,600 240x36"),
                       "expected a numbered, geometry-carrying second entry in: \(message)")
        XCTAssertTrue(message.contains("ambiguous across 2 elements"), "expected the total count in: \(message)")
    }

    func testAmbiguousMessageStatesThatOccurrenceFollowsDiscoveryOrderNotVisualOrder() throws {
        // Without this, "occurrence 2" reads like "the second one down the
        // screen", which is exactly the assumption that put a highlight on a
        // menu-bar item instead of an Inspector row.
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.ambiguous(matches: [
                candidate("Tracking", role: "AXStaticText", backingFrame: backing("S1", 0, 0, 10, 10))
            ]).errorDescription
        )
        XCTAssertTrue(message.contains("BREADTH-FIRST DISCOVERY ORDER"), "expected in: \(message)")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("not visual top-to-bottom or left-to-right order"),
                       "must explicitly deny visual ordering: \(message)")
    }

    func testAmbiguousPreviewStillTruncatesAtEightAndKeepsOccurrenceNumbersAlignedWithTheList() throws {
        // Geometry made each entry longer, so the existing eight-entry bound
        // matters more, not less. The numbers must stay the real occurrence
        // values (1...8), never a renumbering of the truncated slice.
        let matches = (1...10).map {
            candidate("Item", role: "AXButton", backingFrame: backing("S1", Double($0) * 10, 0, 20, 20))
        }
        let message = try XCTUnwrap(AccessibilityElementResolverError.ambiguous(matches: matches).errorDescription)
        for index in 1...8 {
            XCTAssertTrue(message.contains("occurrence \(index): 'Item' [AXButton] via AXTitle -- screen S1 at \(index * 10),0 20x20"),
                           "expected occurrence \(index) in: \(message)")
        }
        XCTAssertFalse(message.contains("occurrence 9:"), "the 9th entry must be truncated away: \(message)")
        XCTAssertTrue(message.contains("(and 2 more)"), "expected a truncation tail counting the remaining 2: \(message)")
    }

    // MARK: - A wrong/mis-cased role must not be reported as "not exposed"

    func testLabelSeenUnderOtherRolesNamesEveryRoleAndNeverClaimsTheControlIsUnexposed() throws {
        // THE BUG: role comparison is verbatim String equality against the
        // app's own AXRole, so `role: "button"` matches nothing against a live
        // "AXButton" -- and the resulting error used to say the UI "may not
        // expose that control to macOS Accessibility", which is FALSE and
        // sends the caller off to eyeball a screenshot.
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.labelSeenUnderOtherRoles(
                label: "Render", requestedRole: "button", seenRoles: ["AXButton", "AXMenuItem"]
            ).errorDescription
        )
        XCTAssertTrue(message.contains("'AXButton'"), "must name the roles the label WAS seen under: \(message)")
        XCTAssertTrue(message.contains("'AXMenuItem'"), "must name every role seen, not just the first: \(message)")
        XCTAssertTrue(message.contains("'Render'"), "must echo the label that was searched for: \(message)")
        XCTAssertTrue(message.contains("'button'"), "must echo the role the caller actually supplied: \(message)")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("may not expose that control"),
                        "this wording is reserved for the genuinely-nothing-found case: \(message)")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retry without role"),
                       "must offer the two corrections that actually work: \(message)")
    }

    func testLabelSeenUnderOtherRolesUsesSingularWordingForASingleRole() throws {
        let message = try XCTUnwrap(
            AccessibilityElementResolverError.labelSeenUnderOtherRoles(
                label: "Render", requestedRole: "AXbutton", seenRoles: ["AXButton"]
            ).errorDescription
        )
        XCTAssertTrue(message.contains("under role: 'AXButton'"), "expected singular wording in: \(message)")
        XCTAssertFalse(message.contains("under roles:"), "expected singular wording in: \(message)")
    }

    func testLabelSeenUnderOtherRolesIsADistinctCaseFromNoMatchesWithAnEmptySample() throws {
        // These are opposite situations with opposite advice -- "the control
        // is exposed, fix your role string" versus "nothing like this label
        // was published at all" -- so they must never collapse into one case
        // or one message. The empty-sample `.noMatches` wording is pinned
        // verbatim by
        // `testNoMatchesWithEmptySampleKeepsTheOriginalSentenceVerbatim`; this
        // asserts the new case does not reuse it.
        let roleMismatch = AccessibilityElementResolverError.labelSeenUnderOtherRoles(
            label: "Render", requestedRole: "button", seenRoles: ["AXButton"]
        )
        let nothingFound = AccessibilityElementResolverError.noMatches(
            label: "Render", role: "button", exposedSample: []
        )
        XCTAssertNotEqual(roleMismatch, nothingFound)
        let roleMismatchMessage = try XCTUnwrap(roleMismatch.errorDescription)
        let nothingFoundMessage = try XCTUnwrap(nothingFound.errorDescription)
        XCTAssertNotEqual(roleMismatchMessage, nothingFoundMessage)
        XCTAssertTrue(nothingFoundMessage.localizedCaseInsensitiveContains("may not expose that control"),
                       "the genuinely-nothing-found wording must survive unchanged: \(nothingFoundMessage)")
    }
    #endif

    // MARK: - highlight_element discloses an occurrence-short-circuited search
    //
    // `highlightSearchDisclosureFields` lives in MCPToolHandlers+Highlight.swift
    // but is tested here, alongside the resolver's occurrence semantics,
    // because the thing it discloses IS a resolver behaviour: `resolve()`
    // returns the instant `matches.count == occurrence`, which makes its
    // post-walk uniqueness check unreachable on every occurrence-supplied
    // success path. The payload fields are the only place that fact ever
    // reaches a caller.

    func testNoDisclosureFieldsAreAddedWhenOccurrenceWasNotSupplied() {
        // A lookup with no occurrence walked the whole tree and PROVED
        // uniqueness, so there is nothing to disclose -- and adding two
        // permanent "nothing unusual happened" fields would train a reader to
        // skip exactly the fields that matter when they do appear.
        XCTAssertTrue(highlightSearchDisclosureFields(occurrence: nil).isEmpty)
    }

    func testOccurrenceDrivenSuccessFlagsTheShortCircuitAndDemandsVerifyAnnotation() throws {
        let fields = highlightSearchDisclosureFields(occurrence: 3)
        XCTAssertEqual(fields["searchWasShortCircuited"] as? Bool, true)
        let note = try XCTUnwrap(fields["searchShortCircuitNote"] as? String)
        XCTAssertTrue(note.contains("match 3"), "the note must name WHICH match the walk stopped at: \(note)")
        XCTAssertTrue(note.localizedCaseInsensitiveContains("uniqueness was NOT checked"),
                       "the note must say uniqueness checking was skipped: \(note)")
        XCTAssertTrue(note.localizedCaseInsensitiveContains("other elements may share this label"),
                       "the note must say the result may not be unique: \(note)")
        XCTAssertTrue(note.contains("verify_annotation"),
                       "the note must name the confirmation step: \(note)")
    }

    func testDisclosedMatchIndexTracksTheSuppliedOccurrence() {
        // The note is only useful if the number in it is the caller's own
        // occurrence; a hardcoded "1" would read as correct while describing
        // a different match every time.
        for occurrence in [1, 2, 17] {
            let note = highlightSearchDisclosureFields(occurrence: occurrence)["searchShortCircuitNote"] as? String
            XCTAssertEqual(note?.contains("match \(occurrence)"), true,
                           "expected match \(occurrence) named in: \(note ?? "<nil>")")
        }
    }
}
