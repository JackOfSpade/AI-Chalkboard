import XCTest
@testable import AIChalkboardCore

/// `ActiveAppTracker.resolve(_:among:)` is the pure overload documented as
/// carrying the fix history for several real shipped wrong-app bugs (see its
/// doc comment). These tests build hand-made `Candidate` lists -- never
/// touching `NSWorkspace.runningApplications` -- and lock in the matching
/// order and the exclusion rules so a future edit cannot silently reintroduce
/// one of those bugs.
final class ActiveAppTrackerResolveTests: XCTestCase {
    private typealias Candidate = ActiveAppTracker.Candidate

    private func candidate(
        bundleId: String,
        name: String? = nil,
        hasDisplayName: Bool = true,
        canBeFrontmost: Bool = true,
        isRegularApp: Bool = true
    ) -> Candidate {
        Candidate(
            ref: AppRef(bundleId: bundleId, name: name ?? bundleId),
            hasDisplayName: hasDisplayName,
            canBeFrontmost: canBeFrontmost,
            isRegularApp: isRegularApp
        )
    }

    private func resolve(_ query: String, among candidates: [Candidate]) -> AppResolution {
        ActiveAppTracker.shared.resolve(query, among: candidates)
    }

    // MARK: - Exact matches

    func testExactBundleIdWins() {
        let candidates = [
            candidate(bundleId: "com.apple.Terminal", name: "Terminal"),
            candidate(bundleId: "com.apple.Safari", name: "Safari")
        ]
        guard case .resolved(let app) = resolve("com.apple.Terminal", among: candidates) else {
            return XCTFail("expected an exact bundle id match to resolve")
        }
        XCTAssertEqual(app.bundleId, "com.apple.Terminal")
    }

    func testExactBundleIdMatchIsCaseInsensitive() {
        let candidates = [candidate(bundleId: "com.apple.Terminal", name: "Terminal")]
        guard case .resolved(let app) = resolve("COM.APPLE.TERMINAL", among: candidates) else {
            return XCTFail("expected a case-insensitive bundle id match to resolve")
        }
        XCTAssertEqual(app.bundleId, "com.apple.Terminal")
    }

    func testExactDisplayNameWinsWhenUnique() {
        let candidates = [
            candidate(bundleId: "com.apple.Terminal", name: "Terminal"),
            candidate(bundleId: "com.apple.Safari", name: "Safari")
        ]
        guard case .resolved(let app) = resolve("Terminal", among: candidates) else {
            return XCTFail("expected the unique exact display name match to resolve")
        }
        XCTAssertEqual(app.bundleId, "com.apple.Terminal")
    }

    // MARK: - Ambiguity

    func testVagueBundleIdPrefixIsAmbiguousAndNeverResolved() {
        let candidates = [
            candidate(bundleId: "com.apple.Terminal", name: "Terminal"),
            candidate(bundleId: "com.apple.Safari", name: "Safari"),
            candidate(bundleId: "com.example.Widget", name: "Widget")
        ]
        guard case .ambiguous(let matches) = resolve("com", among: candidates) else {
            return XCTFail("a vague prefix like 'com' must never resolve to a single app")
        }
        XCTAssertEqual(matches.count, 3)
    }

    func testGoogleAcrossChromeAndDriveIsAmbiguous() {
        let candidates = [
            candidate(bundleId: "com.google.Chrome", name: "Google Chrome"),
            candidate(bundleId: "com.google.drivefs", name: "Google Drive")
        ]
        guard case .ambiguous(let matches) = resolve("Google", among: candidates) else {
            return XCTFail("'Google' must be ambiguous across Chrome and Drive, never guessed")
        }
        XCTAssertEqual(Set(matches.map(\.bundleId)), Set(["com.google.Chrome", "com.google.drivefs"]))
    }

    func testAmbiguousCandidateListOrdersRegularAppsBeforeNonRegular() {
        // Both share the "com.example" bundle-id prefix, so this is resolved
        // via the fuzzy bundle-id pass -- but with two hits it is ambiguous,
        // and the helper (non-regular) is deliberately listed after the
        // regular app regardless of the candidates' original order.
        let helper = candidate(bundleId: "com.example.helper", name: "Example Helper", isRegularApp: false)
        let regularApp = candidate(bundleId: "com.example.App", name: "Example App", isRegularApp: true)
        let candidates = [helper, regularApp]

        guard case .ambiguous(let matches) = resolve("com.example", among: candidates) else {
            return XCTFail("expected an ambiguous result across the two com.example candidates")
        }
        XCTAssertEqual(matches.map(\.bundleId), ["com.example.App", "com.example.helper"],
                       "regular (Dock-icon) apps must be listed before non-regular ones")
    }

    // MARK: - Fuzzy name-substring pass

    func testChromeResolvesViaNameSubstringPassDespiteNoPrefixMatch() {
        // Bundle id is "com.google.Chrome" (no "chrome" prefix) and display
        // name is "Google Chrome" (no "Chrome" prefix): neither prefix pass
        // can find this, only the display-name-contains pass can.
        let candidates = [
            candidate(bundleId: "com.google.Chrome", name: "Google Chrome"),
            candidate(bundleId: "com.apple.Safari", name: "Safari")
        ]
        guard case .resolved(let app) = resolve("Chrome", among: candidates) else {
            return XCTFail("expected 'Chrome' to resolve via the name-substring pass")
        }
        XCTAssertEqual(app.bundleId, "com.google.Chrome")
    }

    // MARK: - notFound / verbatim acceptance

    func testCompleteButAbsentBundleIdReturnsNotFound() {
        guard case .notFound = resolve("com.apple.Safari", among: []) else {
            return XCTFail("a complete bundle id with no running match must be .notFound, so the caller can accept it verbatim")
        }
    }

    // MARK: - Prohibited processes

    func testProhibitedCandidateIsExcludedFromExactNamePass() {
        let candidates = [
            candidate(bundleId: "com.apple.AutoFillHelper", name: "AutoFill (Google Chrome)", canBeFrontmost: false)
        ]
        guard case .notFound = resolve("AutoFill (Google Chrome)", among: candidates) else {
            return XCTFail(".prohibited candidates must never be resolved to, even via an exact display-name match")
        }
    }

    func testProhibitedCandidateIsExcludedFromFuzzyNamePass() {
        // If the prohibited helper were allowed into the fuzzy name pass, two
        // candidates would contain "chrome" and this would be .ambiguous
        // instead of resolving cleanly to the one real, activatable app.
        let candidates = [
            candidate(bundleId: "com.google.Chrome.AutoFillHelper", name: "AutoFill Chrome Helper", canBeFrontmost: false),
            candidate(bundleId: "com.google.Chrome", name: "Google Chrome", canBeFrontmost: true)
        ]
        guard case .resolved(let app) = resolve("Chrome", among: candidates) else {
            return XCTFail("the prohibited helper must not participate in the fuzzy name pass")
        }
        XCTAssertEqual(app.bundleId, "com.google.Chrome")
    }

    // MARK: - Nameless candidates

    func testCandidateWithNoDisplayNameNeverMatchesANameQuery() {
        // hasDisplayName is false even though `ref.name` holds a value here --
        // this specifically exercises resolve(_:among:)'s own hasDisplayName
        // filter rather than relying on production's "name == bundle id"
        // convention for nameless apps.
        let candidates = [
            candidate(bundleId: "com.example.hidden", name: "Ghost App", hasDisplayName: false)
        ]
        guard case .notFound = resolve("Ghost App", among: candidates) else {
            return XCTFail("a candidate with no display name must never match a name query")
        }
    }

    // MARK: - Deduplication

    func testDuplicateEntriesForOneBundleIdAreNotAmbiguous() {
        // Simulates an app that owns several NSRunningApplication entries
        // (helper processes, `open -n`).
        let candidates = [
            candidate(bundleId: "com.apple.Terminal", name: "Terminal"),
            candidate(bundleId: "com.apple.Terminal", name: "Terminal")
        ]
        guard case .resolved(let app) = resolve("Terminal", among: candidates) else {
            return XCTFail("duplicate entries for the same bundle id must not count as ambiguity")
        }
        XCTAssertEqual(app.bundleId, "com.apple.Terminal")
    }
}
