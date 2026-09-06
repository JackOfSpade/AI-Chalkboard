import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `TestHarness`, the single answer to "is this process a test bundle?"
/// that every per-user default path and every broadcast channel name now
/// consults. A regression here silently un-sandboxes the whole suite against
/// the user's live log, lease registry, election lock, and broadcast channel.
final class TestHarnessTests: XCTestCase {

    // MARK: - Test-harness detection

    // These guard the ONLY working test-harness signal the Windows branch of
    // resolveLogsDirectory has. Its environment-variable checks are documented
    // as never firing under `swift test` on this toolchain, so if this matcher
    // regresses, the suite silently goes back to writing synthetic records into
    // the user's real production log and evicting genuine diagnostics from the
    // 5 MB rotation budget.

    func testSwiftPMWindowsTestRunnerIsRecognized() {
        // The exact shape observed in a polluted production log's Build: line.
        XCTAssertTrue(TestHarness.isTestBundleExecutablePath(
            #"C:\repo\.build\x86_64-unknown-windows-msvc\debug\AIChalkboardPackageTests.xctest"#))
    }

    func testTestRunnerIsRecognizedThroughEitherPathSeparator() {
        // Must not depend on the host's path flavour: the rule is shared code
        // and its answer has to be identical on macOS and Windows.
        XCTAssertTrue(TestHarness.isTestBundleExecutablePath("/Users/x/Build/AIChalkboardPackageTests.xctest"))
        XCTAssertTrue(TestHarness.isTestBundleExecutablePath(#"D:\build\AIChalkboardPackageTests.xctest"#))
    }

    func testTestRunnerIsRecognizedWithATrailingExecutableExtension() {
        // Some toolchains append .exe after .xctest, which is why the match is
        // `contains` rather than `hasSuffix`.
        XCTAssertTrue(TestHarness.isTestBundleExecutablePath(#"C:\build\AIChalkboardPackageTests.xctest.exe"#))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(TestHarness.isTestBundleExecutablePath(#"C:\Build\AIChalkboardPackageTests.XCTest"#))
    }

    func testBareRunnerNameWithNoDirectoryIsRecognized() {
        XCTAssertTrue(TestHarness.isTestBundleExecutablePath("AIChalkboardPackageTests.xctest"))
    }

    func testProductionExecutableIsNotMistakenForATestRunner() {
        // The case that matters most in the other direction: a false positive
        // here would silently redirect a REAL user's logs into a temp
        // directory, losing the diagnostics they are told to attach to reports.
        XCTAssertFalse(TestHarness.isTestBundleExecutablePath(
            #"C:\Users\Someone\Desktop\AI-Chalkboard\dist\AIChalkboard\AIChalkboard.exe"#))
        XCTAssertFalse(TestHarness.isTestBundleExecutablePath("/Applications/AI Chalkboard.app/Contents/MacOS/AIChalkboard"))
        XCTAssertFalse(TestHarness.isTestBundleExecutablePath(""))
    }

    func testXctestAppearingOnlyInADirectoryNameDoesNotMatch() {
        // Only the LAST path component is considered, so a user whose project
        // happens to live under a directory containing ".xctest" does not lose
        // their production logs.
        XCTAssertFalse(TestHarness.isTestBundleExecutablePath(#"C:\my.xctest.stuff\AIChalkboard.exe"#))
        XCTAssertFalse(TestHarness.isTestBundleExecutablePath("/home/me/.xctest/AIChalkboard"))
    }

    // MARK: - isActive

    func testIsActiveIsTrueUnderThisTestBundle() {
        // SELF-VERIFYING, AND LOAD-BEARING FOR THE WHOLE SUITE. This test
        // class IS a test bundle, so the only correct answer here is `true`.
        // If it were ever `false`, every other isolation this commit added
        // -- the sandboxed log directory, the lease registry, the election
        // lock, and the broadcast namespace -- would silently fall through to
        // its LIVE, per-user default at singleton construction time, and the
        // rest of the suite would go back to contending for the same log,
        // registry, lock file and broadcast channel a running connector
        // uses. One assertion, but it is the one that proves the premise
        // every other test in this commit depends on.
        XCTAssertTrue(TestHarness.isActive)
    }

    // MARK: - processScopedNamespace

    func testProcessScopedNamespaceIsNonEmpty() {
        XCTAssertFalse(TestHarness.processScopedNamespace.isEmpty)
    }

    func testProcessScopedNamespaceContainsTheCurrentProcessIdentifier() {
        // Documented as scoped PER PID, not per run: siblings inside this one
        // process must keep talking to each other while every OTHER process
        // on the machine -- including the user's live connector -- is walled
        // off. Encoding the PID in the string is what makes that boundary
        // concrete rather than aspirational.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(TestHarness.processScopedNamespace.contains(String(pid)))
    }

    func testProcessScopedNamespaceIsStableAcrossRepeatedReads() {
        // Every consumer treats this as a fixed value consulted once during
        // singleton construction (see the source's doc comment on
        // `isActive`). Two reads disagreeing would mean two singletons in
        // the same process could resolve to two different sandbox
        // directories or broadcast suffixes.
        XCTAssertEqual(TestHarness.processScopedNamespace, TestHarness.processScopedNamespace)
    }

    func testProcessScopedNamespaceOnlyContainsCharactersSafeInBothANotificationNameAndAWin32WindowClassName() {
        // This exact string is concatenated into a Win32 window class name
        // (the message-only broadcast window `InstanceBroadcast` uses on
        // Windows) AND into a `Notification.Name`. A character legal in one
        // but not the other would silently break just one platform -- the
        // kind of asymmetry this suite exists to catch since it must run
        // identically on both.
        for character in TestHarness.processScopedNamespace {
            let isAllowed = character.isLetter || character.isNumber || character == "-" || character == "_"
            XCTAssertTrue(isAllowed, "unexpected character '\(character)' in processScopedNamespace")
        }
    }

    // MARK: - sandboxDirectory

    func testSandboxDirectoryIsAnAbsolutePath() {
        XCTAssertTrue(AbsolutePath.isAbsolute(TestHarness.sandboxDirectory.path))
    }

    func testSandboxDirectoryIsUnderTheSystemTemporaryDirectory() {
        // The source's doc comment justifies never cleaning this directory up
        // by leaving that job to the OS reclaiming the temp directory. That
        // argument only holds if the sandbox is actually located there.
        let tempPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(TestHarness.sandboxDirectory.path.hasPrefix(tempPath),
                      "\(TestHarness.sandboxDirectory.path) is not under \(tempPath)")
    }

    func testSandboxDirectoryContainsTheProcessScopedNamespace() {
        // This is what makes the sandbox per-process rather than shared by
        // every test bundle that has ever run on the machine: two concurrent
        // `swift test` invocations must not silently share one directory.
        XCTAssertTrue(TestHarness.sandboxDirectory.path.contains(TestHarness.processScopedNamespace))
    }

    func testSandboxDirectoryIsStableAcrossRepeatedReads() {
        // `SuspensionLeaseCoordinator` and `InstanceLockPolicy` both read this
        // once as a fallback default at construction time; two different
        // answers in one process would split them across two different
        // directories.
        XCTAssertEqual(TestHarness.sandboxDirectory, TestHarness.sandboxDirectory)
    }

    func testSandboxDirectoryIsNeitherEqualToNorAnAncestorOfTheLiveApplicationSupportDirectory() {
        // THE GUARANTEE THAT ACTUALLY MATTERS. `SuspensionLeaseCoordinator`'s
        // and `InstanceLockPolicy`'s per-user defaults fall back to
        // `TestHarness.sandboxDirectory` under test instead of
        // `PlatformPaths.applicationSupportDirectory` -- the SAME directory a
        // live, running connector reads and writes its lease registry and
        // election lock in. If the sandbox ever resolved onto, or above,
        // that directory, tests believed to be isolated would silently start
        // contending for the user's real state again -- exactly the failure
        // this whole type was introduced to close off.
        let sandboxPath = TestHarness.sandboxDirectory.standardizedFileURL.path
        let liveAppSupportPath = PlatformPaths.applicationSupportDirectory.standardizedFileURL.path

        XCTAssertNotEqual(sandboxPath, liveAppSupportPath)

        // "Not an ancestor of": the live path must not begin with the
        // sandbox path plus a path separator. Checked against both
        // separators since `URL.path` is not guaranteed to normalize to one
        // particular separator on every platform.
        let sandboxAsParentPrefixSlash = sandboxPath.hasSuffix("/") ? sandboxPath : sandboxPath + "/"
        let sandboxAsParentPrefixBackslash = sandboxPath.hasSuffix("\\") ? sandboxPath : sandboxPath + "\\"
        XCTAssertFalse(liveAppSupportPath.hasPrefix(sandboxAsParentPrefixSlash),
                       "\(liveAppSupportPath) is nested under sandbox directory \(sandboxPath)")
        XCTAssertFalse(liveAppSupportPath.hasPrefix(sandboxAsParentPrefixBackslash),
                       "\(liveAppSupportPath) is nested under sandbox directory \(sandboxPath)")
    }

    // MARK: - BroadcastNamespace

    // These guard the fix described at length in `InstanceBroadcast.swift`:
    // three of the four broadcast channels carry COMMANDS on a session-wide,
    // unauthenticated channel -- including `quitAll`, which terminates the
    // receiving process -- and used to be posted completely unscoped. A test
    // bundle posting one could terminate the user's live, running connector.

    func testSuffixShapeMatchesWhetherAnExplicitNamespaceOverrideIsSet() {
        // `BroadcastNamespace.suffix` is a `static let`, resolved once from
        // whatever this process's environment held at first access. Mirror
        // its own sanitize-and-prefix algorithm here instead of assuming a
        // fixed shape, so this test is correct in both cases: an explicit
        // `AI_CHALKBOARD_SUSPENSION_NAMESPACE` override (the two-process
        // subprocess-integration tests deliberately set this to share one
        // namespace) is documented to win outright over `TestHarness.isActive`.
        let sanitize: (String) -> String = { raw in
            String(String.UnicodeScalarView(raw.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }))
        }
        if let explicit = ProcessInfo.processInfo.environment["AI_CHALKBOARD_SUSPENSION_NAMESPACE"] {
            // This process was launched with an explicit override present.
            //
            // An override that sanitizes to nothing does NOT yield an empty
            // suffix: production deliberately falls through to the
            // test-harness namespace rather than short-circuiting, precisely
            // so a typo cannot put a test bundle back on the live channel.
            // Modelling that as "" here would have asserted the very bug the
            // fallthrough exists to prevent -- and passed anyway, because this
            // suite normally runs with no override set at all.
            let cleaned = sanitize(explicit)
            let expected = cleaned.isEmpty
                ? "." + sanitize(TestHarness.processScopedNamespace)
                : "." + cleaned
            XCTAssertEqual(BroadcastNamespace.suffix, expected)
        } else {
            // The ordinary case for this suite: no override, and
            // `TestHarness.isActive` is true (see the `isActive` section
            // above), so every channel must carry a non-empty, per-process
            // suffix -- an EMPTY suffix here would mean this test bundle
            // posts to the exact same unscoped, session-wide names the
            // user's live connector listens on.
            XCTAssertEqual(BroadcastNamespace.suffix, "." + TestHarness.processScopedNamespace)
        }
    }

    /// The safety property itself, stated without re-implementing any of the
    /// production algorithm -- so it stays true no matter what the ambient
    /// environment holds, and cannot be broken by the mirror above drifting
    /// out of sync with the code it mirrors.
    ///
    /// An empty suffix inside a test bundle means this process posts to the
    /// exact unscoped, session-wide channel names the user's live connector
    /// listens on, `quitAll` included.
    func testATestBundleNeverCarriesTheProductionSuffix() {
        XCTAssertTrue(TestHarness.isActive, "precondition: this assertion is only meaningful inside a test bundle")
        XCTAssertFalse(BroadcastNamespace.suffix.isEmpty,
                       "an empty suffix puts this test bundle on the live connector's channels")
        XCTAssertTrue(BroadcastNamespace.suffix.hasPrefix("."),
                      "the suffix must be dot-separated so it cannot merge into the base name")
    }

    func testScopedAppendsTheSuffixToTheBaseName() {
        XCTAssertEqual(BroadcastNamespace.scoped("base"), "base" + BroadcastNamespace.suffix)
    }

    func testQuitAllChannelNameDiffersFromItsUnscopedProductionLiteral() {
        // THE WHOLE POINT of this namespace. `quitAll` is the most dangerous
        // of the four channels: it tells every AI Chalkboard process on the
        // session to terminate itself. An unscoped `quitAll` posted from a
        // test bundle would terminate the user's own running connector. If
        // this ever again equals the bare production literal, that hazard is
        // back.
        XCTAssertNotEqual(Notification.Name.chalkboardQuitAll.rawValue, "com.aichalkboard.overlay.quitAllInstances")
    }

    func testAllFourChannelNamesDifferFromTheirUnscopedProductionLiterals() {
        // The general form of the assertion above, covering the other three
        // channels too: `clearAll` and `setCaptureVisible` also carry
        // commands on the same unauthenticated, session-wide transport (see
        // the source's SECURITY MODEL comment), and `suspensionInvalidated`
        // is included for completeness even though it carries no command.
        let unscopedLiterals = [
            "com.aichalkboard.overlay.clearAllAnnotations",
            "com.aichalkboard.overlay.quitAllInstances",
            "com.aichalkboard.overlay.setCaptureVisible",
            "com.aichalkboard.overlay.suspensionLeaseInvalidated.v2"
        ]
        let scopedValues = [
            Notification.Name.chalkboardClearAll.rawValue,
            Notification.Name.chalkboardQuitAll.rawValue,
            Notification.Name.chalkboardSetCaptureVisible.rawValue,
            Notification.Name.chalkboardSuspensionInvalidated.rawValue
        ]
        for (scoped, unscoped) in zip(scopedValues, unscopedLiterals) {
            XCTAssertNotEqual(scoped, unscoped)
        }
    }

    func testAllFourBroadcastChannelNamesAreDistinctFromEachOther() {
        // A collision here would mean two logically different channels --
        // say, the harmless wake-up hint and the process-terminating
        // `quitAll` -- would be observed as the SAME notification.
        let rawValues: Set<String> = [
            Notification.Name.chalkboardClearAll.rawValue,
            Notification.Name.chalkboardQuitAll.rawValue,
            Notification.Name.chalkboardSetCaptureVisible.rawValue,
            Notification.Name.chalkboardSuspensionInvalidated.rawValue
        ]
        XCTAssertEqual(rawValues.count, 4, "all four broadcast channel names must be distinct")
    }

    func testEveryChannelNameStartsWithItsOriginalUnscopedLiteral() {
        // The suffix must be strictly ADDITIVE. When it is empty -- the real,
        // non-test app -- every name must be BYTE-IDENTICAL to what it has
        // always been, so an existing build still talks to a new one (see
        // the source's doc comment: "this is not a wire-format change").
        // Asserting a PREFIX rather than exact equality is what still holds
        // true here, where the suffix is non-empty under test.
        XCTAssertTrue(Notification.Name.chalkboardClearAll.rawValue.hasPrefix("com.aichalkboard.overlay.clearAllAnnotations"))
        XCTAssertTrue(Notification.Name.chalkboardQuitAll.rawValue.hasPrefix("com.aichalkboard.overlay.quitAllInstances"))
        XCTAssertTrue(Notification.Name.chalkboardSetCaptureVisible.rawValue.hasPrefix("com.aichalkboard.overlay.setCaptureVisible"))
        XCTAssertTrue(Notification.Name.chalkboardSuspensionInvalidated.rawValue.hasPrefix("com.aichalkboard.overlay.suspensionLeaseInvalidated.v2"))
    }
}
