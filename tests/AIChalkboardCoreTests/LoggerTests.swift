import XCTest
@testable import AIChalkboardCore

final class LoggerTests: XCTestCase {
    #if os(macOS)
    func testApplicationLogsDirectoryUsesResolvedLibraryDirectory() {
        let result = Logger.applicationLogsDirectory(
            libraryDirectory: URL(fileURLWithPath: "/custom/Library", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/unused-home", isDirectory: true)
        )

        XCTAssertEqual(result.path, "/custom/Library/Logs/AIChalkboard")
    }

    func testApplicationLogsDirectoryFallsBackToStandardHomeLibraryLocation() {
        let result = Logger.applicationLogsDirectory(
            libraryDirectory: nil,
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(result.path, "/Users/example/Library/Logs/AIChalkboard")
    }
    #endif

    func testShortMessageIsUnchanged() {
        XCTAssertEqual(Logger.boundedMessage("placement rejected"), "placement rejected")
    }

    func testOversizedMessageIsBoundedAndMarked() {
        let result = Logger.boundedMessage(String(repeating: "x", count: Logger.maxMessageBytes + 1_000))
        XCTAssertLessThanOrEqual(result.utf8.count, Logger.maxMessageBytes)
        XCTAssertTrue(result.hasSuffix("... <truncated to \(Logger.maxMessageBytes) bytes>"))
    }

    func testMessageBoundNeverSplitsUnicode() {
        let result = Logger.boundedMessage(String(repeating: "😀", count: Logger.maxMessageBytes))
        XCTAssertLessThanOrEqual(result.utf8.count, Logger.maxMessageBytes)
        XCTAssertTrue(result.hasSuffix("bytes>"))
        XCTAssertFalse(result.contains("�"))
    }

    func testShortStderrLineIsUnchanged() {
        let line = "[INFO] healthy diagnostic\n"
        XCTAssertEqual(Logger.boundedStderrLine(line), line)
    }

    func testOversizedStderrLineIsPipeAtomicAndKeepsNewline() {
        let result = Logger.boundedStderrLine(String(repeating: "😀", count: 1_000) + "\n")
        XCTAssertLessThanOrEqual(result.utf8.count, Logger.maxStderrRecordBytes)
        XCTAssertTrue(result.hasSuffix("... <stderr truncated>\n"))
        XCTAssertFalse(result.contains("�"))
    }

    // MARK: - Test-harness detection

    // These guard the ONLY working test-harness signal the Windows branch of
    // resolveLogsDirectory has. Its environment-variable checks are documented
    // as never firing under `swift test` on this toolchain, so if this matcher
    // regresses, the suite silently goes back to writing synthetic records into
    // the user's real production log and evicting genuine diagnostics from the
    // 5 MB rotation budget.

    func testSwiftPMWindowsTestRunnerIsRecognized() {
        // The exact shape observed in a polluted production log's Build: line.
        XCTAssertTrue(Logger.isTestBundleExecutablePath(
            #"C:\repo\.build\x86_64-unknown-windows-msvc\debug\AIChalkboardPackageTests.xctest"#))
    }

    func testTestRunnerIsRecognizedThroughEitherPathSeparator() {
        // Must not depend on the host's path flavour: the rule is shared code
        // and its answer has to be identical on macOS and Windows.
        XCTAssertTrue(Logger.isTestBundleExecutablePath("/Users/x/Build/AIChalkboardPackageTests.xctest"))
        XCTAssertTrue(Logger.isTestBundleExecutablePath(#"D:\build\AIChalkboardPackageTests.xctest"#))
    }

    func testTestRunnerIsRecognizedWithATrailingExecutableExtension() {
        // Some toolchains append .exe after .xctest, which is why the match is
        // `contains` rather than `hasSuffix`.
        XCTAssertTrue(Logger.isTestBundleExecutablePath(#"C:\build\AIChalkboardPackageTests.xctest.exe"#))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(Logger.isTestBundleExecutablePath(#"C:\Build\AIChalkboardPackageTests.XCTest"#))
    }

    func testBareRunnerNameWithNoDirectoryIsRecognized() {
        XCTAssertTrue(Logger.isTestBundleExecutablePath("AIChalkboardPackageTests.xctest"))
    }

    func testProductionExecutableIsNotMistakenForATestRunner() {
        // The case that matters most in the other direction: a false positive
        // here would silently redirect a REAL user's logs into a temp
        // directory, losing the diagnostics they are told to attach to reports.
        XCTAssertFalse(Logger.isTestBundleExecutablePath(
            #"C:\Users\Someone\Desktop\AI-Chalkboard\dist\AIChalkboard\AIChalkboard.exe"#))
        XCTAssertFalse(Logger.isTestBundleExecutablePath("/Applications/AI Chalkboard.app/Contents/MacOS/AIChalkboard"))
        XCTAssertFalse(Logger.isTestBundleExecutablePath(""))
    }

    func testXctestAppearingOnlyInADirectoryNameDoesNotMatch() {
        // Only the LAST path component is considered, so a user whose project
        // happens to live under a directory containing ".xctest" does not lose
        // their production logs.
        XCTAssertFalse(Logger.isTestBundleExecutablePath(#"C:\my.xctest.stuff\AIChalkboard.exe"#))
        XCTAssertFalse(Logger.isTestBundleExecutablePath("/home/me/.xctest/AIChalkboard"))
    }
}
