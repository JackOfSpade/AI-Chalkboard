#if os(macOS)
import AppKit
#endif
import Foundation
import XCTest
@testable import AIChalkboardCore

final class AppBehaviorTests: XCTestCase {
    /// Absolute path of this suite's throwaway suspension registry.
    /// `processIdentifier` rather than a UUID so a crashed run leaves one
    /// predictable directory behind instead of an unbounded pile.
    private static let isolatedSuspensionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-chalkboard-appbehavior-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)
        .standardizedFileURL

    /// This is the only suite that drives the process-wide
    /// `OverlayWindowController.shared`, and that controller's presentation
    /// state is driven in turn by `SuspensionLeaseCoordinator.shared`:
    /// `recordAndApply` calls `setAnnotationsSuspended(_:generation:)` whenever
    /// `controlsPresentation` is true, which is true precisely for the shared
    /// instance (it is `storageDirectory == nil`).
    ///
    /// Left alone that singleton resolves to the REAL per-user registry --
    /// `%LOCALAPPDATA%\AIChalkboard` on Windows, `~/Library/Application
    /// Support/AIChalkboard` on macOS -- which is the very file a live AI
    /// Chalkboard connector is using. The two processes then contend for its
    /// lock, and when this one loses, `refreshViewsNow` fails closed and forces
    /// `annotationsSuspended = true` in the middle of a test. That is the
    /// intermittent failure this suite exhibited: `setAnnotationsSuspended(true)`
    /// returning false because something else had already suspended it.
    ///
    /// So point the process at a throwaway root before the lazy singleton is
    /// ever touched. The value must be absolute in the platform's own syntax
    /// (see `AbsolutePath.isAbsolute`); until that guard was fixed this had no
    /// effect on Windows at all.
    override class func setUp() {
        super.setUp()
        // Start from an empty directory. `createDirectory` succeeds silently on
        // an existing one without clearing it, and the name is keyed by PID --
        // so a run that crashed before tearDown could otherwise hand its
        // leftover registry state to a later run that Windows happened to give
        // the same PID.
        try? FileManager.default.removeItem(at: isolatedSuspensionRoot)
        try? FileManager.default.createDirectory(at: isolatedSuspensionRoot,
                                                 withIntermediateDirectories: true)
        TestEnvironment.set("AI_CHALKBOARD_SUSPENSION_ROOT", isolatedSuspensionRoot.path)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: isolatedSuspensionRoot)
        // Clear the override too, rather than leaving the rest of the process
        // pointed at a directory that no longer exists. Nothing later in the
        // target reads it today, but a future test constructing a bare
        // SuspensionLeaseCoordinator(storageDirectory: nil) would silently
        // inherit a dangling root.
        TestEnvironment.set("AI_CHALKBOARD_SUSPENSION_ROOT", nil)
        super.tearDown()
    }

    /// Guards the isolation above. `SuspensionLeaseCoordinator.shared` is a
    /// lazy `static let`, so it binds its directory at whatever moment it is
    /// first touched. Nothing else in this target reaches it today, but if that
    /// ever changes this fails loudly here instead of resurfacing as a rare,
    /// confusing suspension flake somewhere else in the suite.
    func testThisSuiteIsIsolatedFromTheRealSuspensionRegistry() {
        XCTAssertEqual(
            SuspensionLeaseCoordinator.shared.storageDirectory.standardizedFileURL.path,
            Self.isolatedSuspensionRoot.path,
            "the shared coordinator bound the real per-user registry before this suite's class setUp ran"
        )
    }

    #if os(macOS)
    // Windows-only note: the Windows `AppDelegate` builds its tray context
    // menu from raw Win32 `CreatePopupMenu`/`AppendMenuW` calls (see
    // `AppDelegate.swift`'s Windows branch, "Windows analogue of the macOS
    // class's makeStatusMenu()") rather than an `NSMenu` of `NSMenuItem`s
    // with Objective-C `target`/`action` pairs -- there is no Swift-visible
    // menu-item/selector object graph to introspect the way this test does
    // on macOS (no Objective-C runtime on Windows at all, per this port's
    // ground rules), so an equivalent structural assertion would need a
    // live HMENU walked via `GetMenuItemCount`/`GetMenuItemInfoW`, a
    // meaningfully different test left as unwritten follow-up rather than
    // approximated here.
    func testStatusMenuItemsHaveExplicitDelegateTargetsAndExpectedActions() {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()

        let expected: [(index: Int, action: String)] = [
            (0, "clearAnnotationsForActiveApp"),
            (1, "clearEverything"),
            (3, "toggleCaptureVisible"),
            (5, "quitApp")
        ]

        XCTAssertEqual(menu.items.count, 6)
        for entry in expected {
            let item = menu.items[entry.index]
            XCTAssertTrue(item.target === delegate, "\(item.title) must target AppDelegate directly")
            XCTAssertEqual(item.action.map(NSStringFromSelector), entry.action)
            XCTAssertTrue(delegate.responds(to: item.action!), "AppDelegate must expose \(entry.action) to Objective-C action dispatch")
            XCTAssertTrue(item.isEnabled)
        }
    }
    #endif

    func testBundleIdentifierSyntaxRejectsPrefixesAndAcceptsCompleteIds() {
        XCTAssertTrue(BundleIdentifierSyntax.looksComplete("com.apple.Safari"))
        XCTAssertTrue(BundleIdentifierSyntax.looksComplete("org.example.product.helper"))
        XCTAssertFalse(BundleIdentifierSyntax.looksComplete("com.apple"))
        XCTAssertFalse(BundleIdentifierSyntax.looksComplete("com..Safari"))
        XCTAssertFalse(BundleIdentifierSyntax.looksComplete("com.apple.Safari Beta"))
    }

    // `ActiveAppTracker.isSystemSessionApp` takes a bundle id on macOS
    // ("com.apple.loginwindow") but an executable file name on Windows
    // ("LockApp.exe"/"LogonUI.exe" -- see that method's Windows doc
    // comment), so the two platforms need different literal identity
    // strings; the underlying property under test (session/lock-screen UI
    // is never an untagged-draw fallback target, case-insensitively) is the
    // same on both.
    func testLoginwindowIsNeverAnUntaggedDrawFallback() {
        #if os(macOS)
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("com.apple.loginwindow"))
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("COM.APPLE.LOGINWINDOW"))
        XCTAssertFalse(ActiveAppTracker.isSystemSessionApp("com.apple.finder"))
        #elseif os(Windows)
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("LockApp.exe"))
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("lockapp.exe"))
        XCTAssertTrue(ActiveAppTracker.isSystemSessionApp("LogonUI.exe"))
        XCTAssertFalse(ActiveAppTracker.isSystemSessionApp("explorer.exe"))
        #endif
    }

    func testPhysicalStrokeWidthIsStableAcrossBackingScales() {
        XCTAssertEqual(
            OverlayDrawingMetrics.points(forPhysicalPixels: 6, backingScaleFactor: 1),
            6
        )
        XCTAssertEqual(
            OverlayDrawingMetrics.points(forPhysicalPixels: 6, backingScaleFactor: 2),
            3
        )
        XCTAssertEqual(
            OverlayDrawingMetrics.points(forPhysicalPixels: 6, backingScaleFactor: 0),
            6,
            "invalid scale factors must safely fall back to 1x"
        )
    }

    func testCaptureAutoRevertIntervalIsPositiveAndSelfHealsWithinAWorkSession() {
        XCTAssertGreaterThan(OverlayWindowController.captureAutoRevertInterval, 0)
        XCTAssertLessThanOrEqual(
            OverlayWindowController.captureAutoRevertInterval,
            30 * 60,
            "a forgotten capture-debug toggle must self-heal within a reasonable work session, not linger for hours"
        )
    }

    #if os(macOS)
    // Windows-only note: `overlayWindowAnimationBehavior` (an
    // `NSWindow.AnimationBehavior`) has no declared counterpart on the
    // Windows `OverlayWindowController` -- `SetWindowPos`'s
    // `SWP_HIDEWINDOW`/`SWP_SHOWWINDOW | SWP_NOACTIVATE` combination (the
    // actual suspend/resume mechanism there, see that class's Windows
    // `setVisible(_:)`) has no separate "implicit ordering animation" to
    // disable in the first place, so there is nothing analogous to assert.
    func testOverlayWindowsDisableImplicitOrderingAnimation() {
        XCTAssertEqual(
            OverlayWindowController.overlayWindowAnimationBehavior,
            .none,
            "suspend/resume must not leave a transient, partially visible WindowServer overlay"
        )
    }
    #endif

    func testOnCaptureVisibleChangedFiresOnlyOnActualStateChanges() {
        addTeardownBlock {
            OverlayWindowController.shared.onCaptureVisibleChanged = nil
            OverlayWindowController.shared.setCaptureVisible(false)
        }

        XCTAssertFalse(OverlayWindowController.shared.isCaptureVisible, "tests assume the default/prior state is off")

        var observedValues: [Bool] = []
        OverlayWindowController.shared.onCaptureVisibleChanged = { visible in
            observedValues.append(visible)
        }

        // Already false: a same-value request must not fire the observer.
        OverlayWindowController.shared.setCaptureVisible(false)
        XCTAssertEqual(observedValues, [])

        OverlayWindowController.shared.setCaptureVisible(true)
        XCTAssertEqual(observedValues, [true])

        // Renewal while already true (the "still debugging" keep-alive) must
        // not fire the observer again -- only the timer restarts.
        OverlayWindowController.shared.setCaptureVisible(true)
        XCTAssertEqual(observedValues, [true])

        OverlayWindowController.shared.setCaptureVisible(false)
        XCTAssertEqual(observedValues, [true, false])
    }

    func testTemporarySuspensionIsIdempotentPresentationStateAndRetainsAnnotationIdentity() throws {
        let controller = OverlayWindowController.shared
        let id = "suspension-retention-\(UUID().uuidString)"
        let annotation = Annotation(
            id: id,
            screenId: "suspension-test-screen",
            kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1)
        )

        addTeardownBlock {
            _ = AnnotationStore.shared.remove(id: id)
            _ = controller.setAnnotationsSuspended(false)
        }

        // Start clean even when a previous failure skipped its normal resume.
        _ = controller.setAnnotationsSuspended(false)
        AnnotationStore.shared.add(annotation)
        let before = try XCTUnwrap(AnnotationStore.shared.get(id: id))

        XCTAssertTrue(controller.setAnnotationsSuspended(true))
        XCTAssertTrue(controller.isAnnotationsSuspended)
        XCTAssertFalse(controller.setAnnotationsSuspended(true), "repeat suspension must be idempotent")

        let whileSuspended = try XCTUnwrap(AnnotationStore.shared.get(id: id))
        XCTAssertEqual(whileSuspended.id, before.id)
        XCTAssertEqual(whileSuspended.createdAt, before.createdAt)

        XCTAssertTrue(controller.setAnnotationsSuspended(false))
        XCTAssertFalse(controller.isAnnotationsSuspended)
        XCTAssertFalse(controller.setAnnotationsSuspended(false), "repeat resume must be idempotent")
        XCTAssertEqual(AnnotationStore.shared.get(id: id)?.id, id)
    }

    func testBackgroundCaptureRequestReturnsOnlyAfterLocalStateIsApplied() {
        addTeardownBlock {
            OverlayWindowController.shared.setCaptureVisible(false)
        }

        let applied = expectation(description: "background request applied on main")
        DispatchQueue.global().async {
            _ = OverlayWindowController.shared.setCaptureVisible(true)
            XCTAssertTrue(
                OverlayWindowController.shared.isCaptureVisible,
                "a caller that received success must not observe the pre-toggle local state"
            )
            applied.fulfill()
        }

        wait(for: [applied], timeout: 2)
        XCTAssertTrue(OverlayWindowController.shared.isCaptureVisible)
    }

    func testCurrentlyVisibleAnnotationsHidesOtherAppsButShowsGlobalsAndRespectsCaptureDebugOverride() {
        let screenId = "test-screen-\(UUID().uuidString)"
        let globalId = "global-\(UUID().uuidString)"
        let appLinkedId = "app-linked-\(UUID().uuidString)"

        addTeardownBlock {
            _ = AnnotationStore.shared.remove(id: globalId)
            _ = AnnotationStore.shared.remove(id: appLinkedId)
            OverlayWindowController.shared.setCaptureVisible(false)
            _ = OverlayWindowController.shared.setAnnotationsSuspended(false)
        }

        // The controller intentionally starts fail-closed until the durable
        // coordinator bootstraps. This unit test exercises app filtering, not
        // that global safety gate, so establish its explicit ready state.
        _ = OverlayWindowController.shared.setAnnotationsSuspended(false)

        XCTAssertTrue(
            OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).isEmpty,
            "a screen nothing was ever drawn on must report no visible annotations -- this is what lets refreshViews() order its window off screen entirely"
        )

        AnnotationStore.shared.add(Annotation(id: globalId, screenId: screenId, kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1), appId: nil))
        XCTAssertEqual(
            OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).map(\.id),
            [globalId],
            "global annotations must be visible regardless of which app is frontmost"
        )

        AnnotationStore.shared.add(Annotation(id: appLinkedId, screenId: screenId, kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1), appId: "com.aichalkboard.test-fixture.never-frontmost"))
        XCTAssertEqual(
            OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).map(\.id),
            [globalId],
            "an annotation linked to an app that is not frontmost must stay hidden under normal (non-debug) filtering"
        )

        OverlayWindowController.shared.setCaptureVisible(true)
        XCTAssertEqual(
            Set(OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId).map(\.id)),
            Set([globalId, appLinkedId]),
            "capture-debug mode must bypass the per-app filter and report every annotation on the screen as visible"
        )
    }

    func testAnnotationKindsExposeStableMCPTypeNames() {
        let kinds: [(AnnotationKind, String)] = [
            (.vectorPath(data: "M1 2 L3 4", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1), "path"),
            (.image(assetId: "asset", x: 1, y: 2, width: 3, height: 4, rotationDegrees: 0, opacity: 1), "image"),
            (.text(text: "Text", x: 1, y: 2, fontSize: 12, textColorHex: "white", backgroundColorHex: nil, backgroundOpacity: 1, paddingPx: 0, opacity: 1), "text"),
            (.batch(items: [AnnotationComponent(kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1))]), "batch")
        ]

        for (kind, expectedType) in kinds {
            XCTAssertEqual(kind.typeName, expectedType)
        }
    }
}
