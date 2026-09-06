import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `CaptureExclusionPolicy` -- the pure decision that governs whether
/// overlay windows ask the OS to hide themselves from other applications'
/// screen captures. The type takes every fact (environment override,
/// process list, Terminal Services flag, capture-debug flag) as a parameter
/// and is documented as deliberately platform-neutral, so every test here
/// must produce the same result on macOS and Windows: no platform API, no
/// real environment reads, no `#if os(...)`.
final class CaptureExclusionPolicyTests: XCTestCase {

    // MARK: - environmentVariableName

    func testEnvironmentVariableNameMatchesTheEstablishedAIChalkboardFamily() {
        XCTAssertEqual(CaptureExclusionPolicy.environmentVariableName, "AI_CHALKBOARD_CAPTURE_EXCLUSION")
    }

    // MARK: - parseOverride(fromEnvironmentValue:) -- unset

    func testUnsetEnvironmentValueParsesAsUnset() {
        XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: nil), .unset)
    }

    func testEmptyAndWhitespaceOnlyValuesParseAsUnset() {
        // A whitespace-only value must not fall through to `.unrecognized` --
        // an env var that is merely blank (e.g. exported as `FOO=` in a shell
        // script) should behave exactly like an absent one.
        XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: ""), .unset)
        XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: "   "), .unset)
    }

    // MARK: - parseOverride(fromEnvironmentValue:) -- accepted spellings

    func testEveryAcceptedNeverSpellingParsesToRecognizedNever() {
        // The table is deliberately generous (see the source's doc comment):
        // a user reaching for this knob while their screen is black should
        // not be rejected because they typed "0" instead of "never".
        let spellings = ["never", "no", "off", "false", "0", "include", "disabled"]
        for spelling in spellings {
            XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: spelling), .recognized(.never),
                           "spelling '\(spelling)' should parse to .never")
        }
    }

    func testEveryAcceptedAlwaysSpellingParsesToRecognizedAlways() {
        let spellings = ["always", "yes", "on", "true", "1", "exclude", "force", "forced"]
        for spelling in spellings {
            XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: spelling), .recognized(.always),
                           "spelling '\(spelling)' should parse to .always")
        }
    }

    func testAutoAndDefaultParseToRecognizedAuto() {
        XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: "auto"), .recognized(.auto))
        XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: "default"), .recognized(.auto))
    }

    func testParsingIsCaseInsensitiveAndTrimsSurroundingWhitespace() {
        XCTAssertEqual(CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: "  AlWaYs  "), .recognized(.always))
    }

    // MARK: - parseOverride(fromEnvironmentValue:) -- unrecognized

    func testUnrecognizedValuePreservesTheOriginalStringExactly() {
        // `.unrecognized` exists so a caller can log the operator's actual
        // typo. If this stored the trimmed/lowercased `normalized` value
        // instead of `raw`, that diagnostic would silently lose the exact
        // text the operator wrote -- assert the ORIGINAL casing and
        // whitespace survive untouched.
        let raw = "  BoGuS  "
        switch CaptureExclusionPolicy.parseOverride(fromEnvironmentValue: raw) {
        case .unrecognized(let preserved):
            XCTAssertEqual(preserved, raw)
        default:
            XCTFail("expected .unrecognized, got a different case")
        }
    }

    // MARK: - OverrideParse.resolved

    func testResolvedMapsUnsetAndUnrecognizedToAuto() {
        // A malformed or absent override must never be a startup failure --
        // both non-recognized states fall back to the same safe default.
        XCTAssertEqual(CaptureExclusionPolicy.OverrideParse.unset.resolved, .auto)
        XCTAssertEqual(CaptureExclusionPolicy.OverrideParse.unrecognized("garbage").resolved, .auto)
    }

    // MARK: - normalizedProcessName(_:)

    func testStripsAWindowsPathAndExeExtension() {
        // Written with a raw string literal so the backslashes in the path
        // are unambiguous rather than fighting Swift's normal escaping.
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName(#"C:\Windows\System32\ShadowStreamer.exe"#), "shadowstreamer")
    }

    func testStripsAPosixPathAndAppExtension() {
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("/Applications/AnyDesk.app"), "anydesk")
    }

    func testLowercasesTheResult() {
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("TEAMVIEWER_DESKTOP.EXE"), "teamviewer_desktop")
    }

    func testANameContainingInteriorDotsKeepsThemAndOnlyStripsTheKnownTrailingExtension() {
        // Truncating at the last "." unconditionally would mangle this into
        // "tv_x64" -- the source comment calls this out explicitly as the
        // reason only a known suffix (".exe"/".app") is stripped.
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("tv_x64.something.exe"), "tv_x64.something")
    }

    func testABareNameIsUnchangedApartFromCase() {
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("RustDesk"), "rustdesk")
    }

    func testEmptyStringNormalizesToEmptyString() {
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName(""), "")
    }

    // MARK: - remoteSessionSignals(runningProcessNames:isTerminalServicesSession:)

    func testOrdinaryDesktopWithNoMatchesAndNoTerminalServicesProducesNoSignals() {
        let signals = CaptureExclusionPolicy.remoteSessionSignals(runningProcessNames: ["explorer.exe", "chrome.exe"],
                                                                   isTerminalServicesSession: false)
        XCTAssertEqual(signals, [])
    }

    func testTerminalServicesSessionAloneProducesExactlyOneSignalMentioningSMRemoteSession() {
        let signals = CaptureExclusionPolicy.remoteSessionSignals(runningProcessNames: [],
                                                                   isTerminalServicesSession: true)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].contains("SM_REMOTESESSION"))
    }

    func testAShadowProcessIsDetectedAsExactlyOneSignalNamingTheVendor() {
        let signals = CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: ["ShadowStreamer.exe", "explorer.exe", "chrome.exe"],
            isTerminalServicesSession: false)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].contains("Shadow cloud PC"))
    }

    func testAllThreeShadowExecutablesDedupeToASingleSignalByVendor() {
        // A machine running the full Shadow client has all three services up
        // at once. Without vendor-level dedup this would report three
        // identical-looking "Shadow cloud PC" signals; the policy is
        // documented to collapse them into one.
        let signals = CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: ["ShadowStreamer.exe", "ShadowSvsManager.exe", "ShadowProcessator.exe"],
            isTerminalServicesSession: false)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].contains("Shadow cloud PC"))
    }

    func testMultipleDifferentVendorsProduceMultipleSignalsSortedDeterministically() {
        // Feed the vendors in a deliberately scrambled order so a passing
        // test can only mean the output was actually sorted, not that it
        // happened to match insertion order. Asserted twice against the same
        // exact array to prove the ordering is stable across repeated calls,
        // not merely a Set's traversal order landing right once.
        let processNames = ["rustdesk.exe", "anydesk.exe", "teamviewer_desktop.exe", "parsecd.exe"]
        let expected = [
            "AnyDesk (anydesk)",
            "Parsec (parsecd)",
            "RustDesk (rustdesk)",
            "TeamViewer (teamviewer_desktop)"
        ]
        XCTAssertEqual(CaptureExclusionPolicy.remoteSessionSignals(runningProcessNames: processNames,
                                                                    isTerminalServicesSession: false), expected)
        XCTAssertEqual(CaptureExclusionPolicy.remoteSessionSignals(runningProcessNames: processNames,
                                                                    isTerminalServicesSession: false), expected)
    }

    func testDeliberatelyExcludedNamesAreNeverMatched() {
        // REGRESSION GUARD. Each of these looks tempting to add but is
        // excluded on purpose (see `knownStreamingHosts`'s doc comment):
        //   - nvcontainer.exe: NVIDIA ShadowPlay's host process, present on
        //     every machine with an NVIDIA driver whether or not it is
        //     streaming -- matching it would false-positive on a huge share
        //     of ordinary gaming desktops.
        //   - steam.exe: Steam Remote Play streams from Steam's own main
        //     executable, which runs on machines that are not streaming
        //     anything; matching it would be similarly overbroad.
        //   - streaming_client.exe: the Steam Remote Play CLIENT side --
        //     its presence means THIS machine is watching another one, the
        //     opposite of what this policy cares about, so matching it would
        //     be a false positive with backwards reasoning.
        //   - moonlight.exe: the Moonlight CLIENT; only the self-hosted
        //     Sunshine server side is matched.
        //   - shadowlogger.exe / shadowmanager.exe: Shadow-adjacent-sounding
        //     names left out because "logger"/"manager" are common enough
        //     words to collide with unrelated software.
        let signals = CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: ["nvcontainer.exe", "steam.exe", "streaming_client.exe",
                                   "moonlight.exe", "shadowlogger.exe", "shadowmanager.exe"],
            isTerminalServicesSession: false)
        XCTAssertEqual(signals, [])
    }

    func testMatchingIsCaseInsensitiveAndPathInsensitive() {
        let signals = CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: [#"C:\Program Files\Shadow\ShAdOwStReAmEr.EXE"#],
            isTerminalServicesSession: false)
        XCTAssertEqual(signals, ["Shadow cloud PC (shadowstreamer)"])
    }

    // MARK: - decide(captureDebugVisible:override:remoteSessionSignals:)

    func testCaptureDebugVisibleWinsOverEveryOtherCombinationIncludingTheStrongestCompetingCase() {
        // `.always` + signals present is the strongest competing case --
        // it would otherwise win on its own (`.excludeForcedByEnvironment`).
        // captureDebugVisible must outrank it outright.
        let decision = CaptureExclusionPolicy.decide(captureDebugVisible: true,
                                                      override: .always,
                                                      remoteSessionSignals: ["Shadow cloud PC (shadowstreamer)"])
        XCTAssertEqual(decision, .includeForCaptureDebug)
        XCTAssertFalse(decision.excludesFromCapture)
    }

    func testOverrideNeverIncludesRegardlessOfSignals() {
        let withoutSignals = CaptureExclusionPolicy.decide(captureDebugVisible: false,
                                                            override: .never,
                                                            remoteSessionSignals: [])
        XCTAssertEqual(withoutSignals, .includeSuppressedByEnvironment)
        XCTAssertFalse(withoutSignals.excludesFromCapture)

        let withSignals = CaptureExclusionPolicy.decide(captureDebugVisible: false,
                                                         override: .never,
                                                         remoteSessionSignals: ["Shadow cloud PC (shadowstreamer)"])
        XCTAssertEqual(withSignals, .includeSuppressedByEnvironment)
        XCTAssertFalse(withSignals.excludesFromCapture)
    }

    func testOverrideAlwaysWithSignalsExcludesAndIsReportedAsForced() {
        let decision = CaptureExclusionPolicy.decide(captureDebugVisible: false,
                                                      override: .always,
                                                      remoteSessionSignals: ["Shadow cloud PC (shadowstreamer)"])
        XCTAssertEqual(decision, .excludeForcedByEnvironment)
        XCTAssertTrue(decision.excludesFromCapture)
    }

    func testOverrideAlwaysWithoutSignalsExcludesButIsNotReportedAsForced() {
        // Deliberate distinction: with no signals, `always` asked for the
        // behaviour that was already going to happen on an ordinary
        // desktop. Reporting `.excludeForcedByEnvironment` here would put a
        // false claim of a detected remote session into the explanation of
        // a machine where none was found -- so this must be plain `.exclude`.
        let decision = CaptureExclusionPolicy.decide(captureDebugVisible: false,
                                                      override: .always,
                                                      remoteSessionSignals: [])
        XCTAssertEqual(decision, .exclude)
        XCTAssertTrue(decision.excludesFromCapture)
    }

    func testOverrideAutoWithNoSignalsExcludes() {
        let decision = CaptureExclusionPolicy.decide(captureDebugVisible: false,
                                                      override: .auto,
                                                      remoteSessionSignals: [])
        XCTAssertEqual(decision, .exclude)
        XCTAssertTrue(decision.excludesFromCapture)
    }

    func testOverrideAutoWithSignalsSuppressesForRemoteSessionCarryingTheExactSignals() {
        let signals = ["Shadow cloud PC (shadowstreamer)", "Parsec (parsecd)"]
        let decision = CaptureExclusionPolicy.decide(captureDebugVisible: false,
                                                      override: .auto,
                                                      remoteSessionSignals: signals)
        XCTAssertEqual(decision, .includeSuppressedForRemoteSession(signals: signals))
        XCTAssertFalse(decision.excludesFromCapture)
    }

    // MARK: - Decision surface

    func testReasonCodeIsDistinctAndNonEmptyForAllFiveCases() {
        let decisions: [CaptureExclusionPolicy.Decision] = [
            .exclude,
            .excludeForcedByEnvironment,
            .includeForCaptureDebug,
            .includeSuppressedByEnvironment,
            .includeSuppressedForRemoteSession(signals: ["some signal"])
        ]
        for decision in decisions {
            XCTAssertFalse(decision.reasonCode.isEmpty)
        }
        let reasonCodes = Set(decisions.map { $0.reasonCode })
        XCTAssertEqual(reasonCodes.count, 5, "every case must have a distinct reasonCode")
    }

    func testSignalsIsEmptyForEveryCaseExceptIncludeSuppressedForRemoteSession() {
        XCTAssertEqual(CaptureExclusionPolicy.Decision.exclude.signals, [])
        XCTAssertEqual(CaptureExclusionPolicy.Decision.excludeForcedByEnvironment.signals, [])
        XCTAssertEqual(CaptureExclusionPolicy.Decision.includeForCaptureDebug.signals, [])
        XCTAssertEqual(CaptureExclusionPolicy.Decision.includeSuppressedByEnvironment.signals, [])

        let signals = ["some signal"]
        XCTAssertEqual(CaptureExclusionPolicy.Decision.includeSuppressedForRemoteSession(signals: signals).signals, signals)
    }

    func testExplanationIsNonEmptyForAllFiveCasesAndTheEnvironmentCasesNameTheVariable() {
        let decisions: [CaptureExclusionPolicy.Decision] = [
            .exclude,
            .excludeForcedByEnvironment,
            .includeForCaptureDebug,
            .includeSuppressedByEnvironment,
            .includeSuppressedForRemoteSession(signals: ["some signal"])
        ]
        for decision in decisions {
            XCTAssertFalse(decision.explanation.isEmpty)
        }

        // The two decisions that exist BECAUSE of the environment override
        // must name it -- an agent reading `get_overlay_state` needs to know
        // which knob to turn, not just that one exists somewhere.
        XCTAssertTrue(CaptureExclusionPolicy.Decision.excludeForcedByEnvironment.explanation
            .contains(CaptureExclusionPolicy.environmentVariableName))
        XCTAssertTrue(CaptureExclusionPolicy.Decision.includeSuppressedByEnvironment.explanation
            .contains(CaptureExclusionPolicy.environmentVariableName))
    }

    // MARK: - Whitespace around the executable name

    // REGRESSION GUARD. normalizedProcessName used to trim whitespace AFTER
    // stripping the extension, which cannot work: "anydesk.exe " ends in
    // "exe ", so hasSuffix(".exe") is false and nothing is stripped. The
    // result kept its extension, matched no table entry, and a running
    // remote-access host went undetected -- so capture exclusion would be
    // applied on a streamed session, the exact failure this type prevents.

    func testTrailingWhitespaceStillYieldsAnExtensionlessName() {
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("AnyDesk.exe "), "anydesk")
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("  ShadowStreamer.exe\t"), "shadowstreamer")
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("Parsec.app  "), "parsec")
    }

    func testAWhitespacePaddedHostNameIsStillDetected() {
        // The end-to-end consequence, not just the string helper: a padded
        // name must still produce a signal, or decide() silently falls through
        // to .exclude on a machine that is being streamed.
        let signals = CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: ["AnyDesk.exe "], isTerminalServicesSession: false)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals[0].contains("AnyDesk"))

        let decision = CaptureExclusionPolicy.decide(
            captureDebugVisible: false, override: .auto, remoteSessionSignals: signals)
        XCTAssertFalse(decision.excludesFromCapture)
    }

    func testWhitespaceLeftBehindByStrippingTheExtensionIsAlsoRemoved() {
        XCTAssertEqual(CaptureExclusionPolicy.normalizedProcessName("anydesk .exe"), "anydesk")
    }

    // MARK: - macOS-shaped names

    // REGRESSION GUARD, and the reason it exists is worth stating: every
    // vendor test in this file used to pass Windows-shaped names only
    // ("teamviewer_desktop.exe", "parsecd.exe"), so the suite was green while
    // macOS detection silently failed for those same vendors. macOS surfaces
    // an app through NSWorkspace as its CFBundleExecutable or bundle name --
    // the PRODUCT name -- so "TeamViewer.app" arrives as "teamviewer", which
    // matched no entry. These assert the shape macOS actually produces.
    //
    // Runs on both platforms on purpose: the policy is pure and platform
    // neutral, so a Windows-only CI must still catch a macOS-only regression.

    func testMacOSBundleNamesAreDetected() {
        let cases: [(String, String)] = [
            ("/Applications/TeamViewer.app", "TeamViewer"),
            ("/Applications/Parsec.app", "Parsec"),
            ("/Applications/AnyDesk.app", "AnyDesk"),
            ("/Applications/RustDesk.app", "RustDesk")
        ]
        for (bundlePath, vendorFragment) in cases {
            let signals = CaptureExclusionPolicy.remoteSessionSignals(
                runningProcessNames: [bundlePath], isTerminalServicesSession: false)
            XCTAssertEqual(signals.count, 1, "no signal for macOS bundle \(bundlePath)")
            XCTAssertTrue(signals.first?.localizedCaseInsensitiveContains(vendorFragment) == true,
                          "signal for \(bundlePath) did not name \(vendorFragment): \(signals)")
        }
    }

    func testMacOSExecutablePathsInsideABundleAreDetected() {
        // The other shape `NSWorkspace` can yield: executableURL, which points
        // at Contents/MacOS/<CFBundleExecutable> and carries no ".app".
        let executables = [
            "/Applications/TeamViewer.app/Contents/MacOS/TeamViewer",
            "/Applications/Parsec.app/Contents/MacOS/parsecd",
            "/Applications/AnyDesk.app/Contents/MacOS/AnyDesk"
        ]
        for path in executables {
            let signals = CaptureExclusionPolicy.remoteSessionSignals(
                runningProcessNames: [path], isTerminalServicesSession: false)
            XCTAssertEqual(signals.count, 1, "no signal for macOS executable \(path)")
        }
    }

    func testTheAddedProductNameAliasesDoNotDuplicateAVendorSignal() {
        // Both spellings of a vendor may legitimately be running at once. The
        // dedupe is by VENDOR, so that must still yield exactly one signal.
        let signals = CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: ["TeamViewer.app", "tv_x64.exe", "teamviewer_desktop.exe"],
            isTerminalServicesSession: false)
        XCTAssertEqual(signals.count, 1, "vendor dedupe broke once aliases were added: \(signals)")
    }

    // MARK: - isCaptureDebugVisible

    // This exists so a diagnostic can recover the capture-debug input from the
    // SAME snapshot the decision was built from, instead of re-reading the
    // live flag and risking a payload that says capture-debug is both on and
    // off. It is only correct while it agrees exactly with decide()'s input.

    func testIsCaptureDebugVisibleMatchesTheInputThatProducedTheDecision() {
        for override in [CaptureExclusionPolicy.Override.auto, .never, .always] {
            for signals in [[], ["Shadow cloud PC (shadowstreamer)"]] {
                for debugVisible in [true, false] {
                    let decision = CaptureExclusionPolicy.decide(
                        captureDebugVisible: debugVisible,
                        override: override,
                        remoteSessionSignals: signals)
                    XCTAssertEqual(decision.isCaptureDebugVisible, debugVisible,
                                   "debugVisible=\(debugVisible) override=\(override) signals=\(signals)")
                }
            }
        }
    }
}
