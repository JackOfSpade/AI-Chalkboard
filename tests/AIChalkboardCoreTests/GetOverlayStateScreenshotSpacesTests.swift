import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `get_overlay_state`'s `screenshotSpaces` array, serialized by
/// `MCPServer.screenshotSpacesJSON(_:currentScreen:)`.
///
/// Exercised directly with hand-built `ScreenshotSpace` values and a stub
/// look-up closure rather than through the live `handleToolsCall` switch, for
/// exactly the reason `GetOverlayStateAnchorTrackingTests`' header states:
/// the case body writes straight to stdout and is not a usable test seam.
/// No `ScreenshotSpaceRegistry`, and no live display, appears anywhere here.
///
/// The property this file exists to pin down is the one that makes the
/// listing worth publishing at all: an entry's `stale` flag must agree,
/// verbatim, with what a draw call naming the same id would decide a moment
/// later -- because both go through `ScreenshotSpace.stalenessRejection`. A
/// listing allowed to drift from that decision would be worse than no
/// listing, since an agent would trust it and then be rejected anyway.
final class GetOverlayStateScreenshotSpacesTests: XCTestCase {

    // MCPServer.shared, matching GetOverlayStateAnchorTrackingTests: the
    // helper under test is pure, so the singleton is used purely as the
    // namespace its instance methods live in, exactly as that suite does.
    private let server = MCPServer.shared

    private func space(
        id: String = "space-aaaaaaaa",
        screenId: String = "display-1",
        widthPx: Int = 1512,
        heightPx: Int = 982,
        screenWidthPx: Int = 3024,
        screenHeightPx: Int = 1964,
        provenance: ScreenshotSpace.Provenance = .observed,
        sourcePath: String? = nil
    ) -> ScreenshotSpace {
        ScreenshotSpace(
            id: id, screenId: screenId, widthPx: widthPx, heightPx: heightPx,
            screenWidthPx: screenWidthPx, screenHeightPx: screenHeightPx,
            provenance: provenance, sourcePath: sourcePath
        )
    }

    private func screen(id: String = "display-1", width: Int, height: Int) -> ScreenInfo {
        ScreenInfo(
            id: id, index: 0, name: id, widthPx: width, heightPx: height,
            widthPt: Double(width), heightPt: Double(height),
            backingScaleFactor: 1, isMain: true
        )
    }

    // MARK: - Shape

    /// An empty registry must still produce a real, empty JSON array -- not an
    /// absent key and not `null`. An agent that has registered nothing should
    /// read "nothing is registered", which is a different and more useful
    /// answer than "this build does not report spaces".
    func testNoRegisteredSpacesSerializesAsAnEmptyArray() {
        let json = server.screenshotSpacesJSON([], currentScreen: { (_: String) -> ScreenInfo? in nil })
        XCTAssertTrue(json.isEmpty)
        let text = jsonStringForTest(["screenshotSpaces": json])
        XCTAssertTrue(text.contains("\"screenshotSpaces\":[]"), text)
    }

    /// A live entry is the space's OWN `payload` -- the identical shape the
    /// minting tool returned -- with exactly one key added. Asserted key by
    /// key so a future change to `ScreenshotSpace.payload` that silently drops
    /// a field from this listing fails here.
    func testLiveEntryIsTheSpacePayloadPlusStaleFalseAndNoReason() {
        let subject = space()
        let json = server.screenshotSpacesJSON(
            [subject],
            currentScreen: { _ in self.screen(width: 3024, height: 1964) }
        )
        XCTAssertEqual(json.count, 1)
        let entry = json[0]
        XCTAssertEqual(entry["stale"] as? Bool, false)
        XCTAssertNil(entry["staleReason"], "A live space must carry no reason at all, not an empty string.")
        XCTAssertEqual(entry["screenshotSpace"] as? String, "space-aaaaaaaa")
        XCTAssertEqual(entry["screenId"] as? String, "display-1")
        XCTAssertEqual(entry["provenance"] as? String, "observed")
        XCTAssertEqual((entry["screenshotPx"] as? [String: Int])?["width"], 1512)
        XCTAssertEqual((entry["screenBackingPx"] as? [String: Int])?["height"], 1964)
        XCTAssertEqual((entry["scaleToBackingPx"] as? [String: Double])?["x"], 2)
    }

    /// Provenance is carried through verbatim, including `declared` -- the
    /// listing must not quietly present a caller's assertion as though it were
    /// a measurement, which is the whole reason the field is on the wire.
    func testDeclaredProvenanceAndSourcePathSurviveIntoTheListing() {
        let json = server.screenshotSpacesJSON(
            [space(provenance: .measured, sourcePath: "/tmp/shot.png")],
            currentScreen: { _ in self.screen(width: 3024, height: 1964) }
        )
        XCTAssertEqual(json[0]["provenance"] as? String, "measured")
        XCTAssertEqual(json[0]["sourcePath"] as? String, "/tmp/shot.png")

        let declared = server.screenshotSpacesJSON(
            [space(provenance: .declared)],
            currentScreen: { _ in self.screen(width: 3024, height: 1964) }
        )
        XCTAssertEqual(declared[0]["provenance"] as? String, "declared")
        XCTAssertNil(declared[0]["sourcePath"])
    }

    // MARK: - Staleness agrees with the draw path

    /// The display is gone entirely. `staleReason` must be BYTE-IDENTICAL to
    /// what `ScreenshotSpace.stalenessRejection` -- the function the draw path
    /// itself calls -- produces, so the listing cannot drift from the decision
    /// a draw call would make.
    func testDisconnectedDisplayIsStaleWithTheExactDrawPathRejectionProse() {
        let subject = space()
        let json = server.screenshotSpacesJSON([subject], currentScreen: { (_: String) -> ScreenInfo? in nil })
        XCTAssertEqual(json[0]["stale"] as? Bool, true)
        let expected = ScreenshotSpace.stalenessRejection(space: subject, currentScreen: nil)
        XCTAssertNotNil(expected)
        XCTAssertEqual(json[0]["staleReason"] as? String, expected)
        XCTAssertTrue((json[0]["staleReason"] as? String ?? "").contains("no longer present"))
    }

    /// The display is still there but has been reconfigured. Same identity
    /// requirement, different cause -- and the two causes call for different
    /// agent action, so they must not collapse into one message.
    func testResolutionChangeIsStaleWithTheExactDrawPathRejectionProse() {
        let subject = space()
        let now = screen(width: 1920, height: 1080)
        let json = server.screenshotSpacesJSON([subject], currentScreen: { _ in now })
        XCTAssertEqual(json[0]["stale"] as? Bool, true)
        XCTAssertEqual(
            json[0]["staleReason"] as? String,
            ScreenshotSpace.stalenessRejection(space: subject, currentScreen: now)
        )
        let reason = json[0]["staleReason"] as? String ?? ""
        XCTAssertTrue(reason.contains("3024x1964"), reason)
        XCTAssertTrue(reason.contains("1920x1080"), reason)
    }

    /// Each space is judged against ITS OWN display, not against whichever
    /// display happened to be looked up first. A single stale space in the
    /// list must not contaminate a live one, and vice versa.
    func testEachSpaceIsJudgedAgainstItsOwnDisplayIndependently() {
        let live = space(id: "space-live", screenId: "display-1")
        let stale = space(id: "space-stale", screenId: "display-2")
        let json = server.screenshotSpacesJSON([live, stale], currentScreen: { id in
            id == "display-1" ? self.screen(id: id, width: 3024, height: 1964) : nil
        })
        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["screenshotSpace"] as? String, "space-live")
        XCTAssertEqual(json[0]["stale"] as? Bool, false)
        XCTAssertNil(json[0]["staleReason"])
        XCTAssertEqual(json[1]["screenshotSpace"] as? String, "space-stale")
        XCTAssertEqual(json[1]["stale"] as? Bool, true)
        XCTAssertNotNil(json[1]["staleReason"])
    }

    /// Registration order is preserved, so an id read out of this listing is
    /// stable to point at across two calls with nothing in between.
    func testOrderIsPreservedExactlyAsGiven() {
        let ids = ["space-1", "space-2", "space-3"]
        let json = server.screenshotSpacesJSON(
            ids.map { space(id: $0) },
            currentScreen: { _ in self.screen(width: 3024, height: 1964) }
        )
        XCTAssertEqual(json.compactMap { $0["screenshotSpace"] as? String }, ids)
    }

    /// The whole array must survive `JSONSerialization`, since that is what
    /// actually reaches the caller -- a payload that builds fine in Swift but
    /// cannot encode would take the ENTIRE `get_overlay_state` response down,
    /// not just this one field.
    func testTheWholeArrayRoundTripsThroughJSONSerialization() {
        let json = server.screenshotSpacesJSON(
            [space(id: "space-live"), space(id: "space-gone", screenId: "display-9")],
            currentScreen: { id in
                id == "display-1" ? self.screen(id: id, width: 3024, height: 1964) : nil
            }
        )
        let text = jsonStringForTest(["screenshotSpaces": json])
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = parsed["screenshotSpaces"] as? [[String: Any]] else {
            return XCTFail("screenshotSpaces did not round-trip through JSON: \(text)")
        }
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["stale"] as? Bool, false)
        XCTAssertEqual(array[1]["stale"] as? Bool, true)
        XCTAssertNotNil(array[1]["staleReason"] as? String)
    }

    private func jsonStringForTest(_ object: [String: Any]) -> String {
        MCPServer.shared.jsonString(object) ?? "<unencodable>"
    }
}
