// This entire suite is macOS-only, guarded as a whole: every type it
// exercises (`ScreenCapturePermissionDecision`, `ScreenCaptureApplicationIdentity`,
// `ScreenCaptureProvider.shouldExclude(_:for:)`,
// `ScreenCaptureProvider.exclusionScope(for:)`) is declared inside
// `ScreenCaptureProvider.swift`'s `#if os(macOS)` branch with no Windows
// counterpart at all -- per that file's own contract notes, Windows has no
// TCC-style permission model to decide between (`permissionStatus()` always
// reports `granted: true` there) and `chalk_capture_monitor` cannot exclude
// any window, including this process's own overlay, from its captures (see
// `ScreenCaptureExclusionScope`'s Windows doc comment), so there is no
// sibling-identity-matching or exclusion-scope-reporting logic on that
// platform for an equivalent test to exercise.
#if os(macOS)
import XCTest
@testable import AIChalkboardCore

final class ScreenCaptureProviderTests: XCTestCase {
    func testPermissionDecisionNeverPromptsWhenPreflightAlreadySucceeds() {
        XCTAssertEqual(
            ScreenCapturePermissionDecision.resolve(preflightGranted: true, requestPermission: false),
            .granted
        )
        XCTAssertEqual(
            ScreenCapturePermissionDecision.resolve(preflightGranted: true, requestPermission: true),
            .granted
        )
    }

    func testPermissionDecisionRequiresExplicitPromptRequest() {
        XCTAssertEqual(
            ScreenCapturePermissionDecision.resolve(preflightGranted: false, requestPermission: false),
            .deniedWithoutPrompt
        )
        XCTAssertEqual(
            ScreenCapturePermissionDecision.resolve(preflightGranted: false, requestPermission: true),
            .promptRequested
        )
    }

    func testCaptureExcludesCurrentProcessWithoutBundleIdentity() {
        let own = ScreenCaptureApplicationIdentity(processID: 42, bundleIdentifier: nil)
        XCTAssertTrue(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(processID: 42, bundleIdentifier: nil), for: own
        ))
        XCTAssertFalse(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(processID: 99, bundleIdentifier: nil), for: own
        ))
    }

    func testCaptureExcludesSiblingInstancesWithSameBundleIdentity() {
        let own = ScreenCaptureApplicationIdentity(processID: 42, bundleIdentifier: "com.aichalkboard.overlay")
        XCTAssertTrue(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(processID: 99, bundleIdentifier: "com.aichalkboard.overlay"), for: own
        ))
        XCTAssertFalse(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(processID: 100, bundleIdentifier: "com.example.other"), for: own
        ))
    }

    func testCaptureExcludesSiblingUnbundledInstancesWithSameExecutablePath() {
        let own = ScreenCaptureApplicationIdentity(
            processID: 42, bundleIdentifier: nil, executablePath: "/tmp/AIChalkboard"
        )
        XCTAssertTrue(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(
                processID: 99, bundleIdentifier: nil, executablePath: "/tmp/AIChalkboard"
            ), for: own
        ))
        XCTAssertFalse(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(
                processID: 100, bundleIdentifier: nil, executablePath: "/tmp/a-different-binary"
            ), for: own
        ))
    }

    func testCaptureExcludesSiblingWhoseExecutablePathDiffersOnlyByPathAlias() {
        let own = ScreenCaptureApplicationIdentity(
            processID: 42, bundleIdentifier: nil, executablePath: "/tmp/AIChalkboard/./bin"
        )

        XCTAssertTrue(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(
                processID: 99, bundleIdentifier: nil, executablePath: "/tmp/AIChalkboard/bin"
            ), for: own
        ))
    }

    func testCaptureExcludesSiblingWhenDevelopmentArgvZeroIsRelative() {
        let own = ScreenCaptureApplicationIdentity(
            processID: 42, bundleIdentifier: nil, executablePath: "./.build/debug/AIChalkboard"
        )
        let candidatePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AIChalkboard")
            .path

        XCTAssertTrue(ScreenCaptureProvider.shouldExclude(
            ScreenCaptureApplicationIdentity(
                processID: 99, bundleIdentifier: nil, executablePath: candidatePath
            ), for: own
        ))
    }

    func testExclusionScopeReportsEveryEnabledIdentityDimension() {
        let scope = ScreenCaptureProvider.exclusionScope(for: .init(
            processID: 42,
            bundleIdentifier: "com.aichalkboard.overlay",
            executablePath: "/Applications/AI Chalkboard.app/Contents/MacOS/AIChalkboard"
        ))
        XCTAssertTrue(scope.processID)
        XCTAssertTrue(scope.bundleIdentifier)
        XCTAssertTrue(scope.executablePath)
        XCTAssertTrue(scope.note.contains("executable path"))
    }
}
#endif
