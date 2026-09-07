import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `get_overlay_state`'s new `anchorTracking` object (MCP_SURFACE.md's
/// `get_overlay_state` section), sourced from `AnchorTracker.shared
/// .statusSummary()` and serialized by `MCPServer.anchorTrackingJSON(_:)`.
///
/// `anchorTrackingJSON` is exercised directly with hand-built
/// `AnchorTrackerStatus` values rather than through the live `handleToolsCall`
/// switch, for the same reason the rest of this suite avoids `send*`-adjacent
/// code (see `MCPShapeGeometryTests`' header comment): it writes straight to
/// stdout and is not a usable test seam. The one thing this file cares most
/// about -- that `sampleIntervalMs`/`lastSampleAgeMs` serialize as a REAL
/// JSON `null`, not an absent key or the four-character string `"null"` --
/// is only provable by actually running the value through
/// `JSONSerialization`, so every test here does that via `jsonString`.
final class GetOverlayStateAnchorTrackingTests: XCTestCase {

    private func status(
        isRunning: Bool, anchored: Int = 0, tracking: Int = 0, hidden: Int = 0, lost: Int = 0,
        sampleIntervalMs: Int? = nil, lastSampleAgeMs: Int? = nil
    ) -> AnchorTrackerStatus {
        AnchorTrackerStatus(
            isRunning: isRunning, anchoredCount: anchored, trackingCount: tracking,
            hiddenCount: hidden, lostCount: lost,
            sampleIntervalMs: sampleIntervalMs, lastSampleAgeMs: lastSampleAgeMs
        )
    }

    /// Serializes `anchorTrackingJSON`'s output nested under a single top-level
    /// key, mirroring exactly how `get_overlay_state`'s payload embeds it, and
    /// returns the resulting JSON text for literal substring assertions.
    private func serialized(_ status: AnchorTrackerStatus) throws -> String {
        let object: [String: Any] = ["anchorTracking": MCPServer.shared.anchorTrackingJSON(status)]
        return try XCTUnwrap(MCPServer.shared.jsonString(object))
    }

    // MARK: - No anchors at all: both null cases together

    func testNoAnchorsSerializesZeroCountsAndBothFieldsAsRealJSONNull() throws {
        let text = try serialized(status(isRunning: false, sampleIntervalMs: nil, lastSampleAgeMs: nil))
        XCTAssertTrue(text.contains("\"anchored\":0"), text)
        XCTAssertTrue(text.contains("\"tracking\":0"), text)
        XCTAssertTrue(text.contains("\"hidden\":0"), text)
        XCTAssertTrue(text.contains("\"lost\":0"), text)
        XCTAssertTrue(text.contains("\"sampleIntervalMs\":null"), "no timer running must serialize as JSON null, not an absent key or the string \"null\": \(text)")
        XCTAssertTrue(text.contains("\"lastSampleAgeMs\":null"), "no sample taken yet must serialize as JSON null: \(text)")
    }

    /// Round-trips through `JSONSerialization`'s OWN parser (not just a
    /// substring check) to prove the value is a true `NSNull`, not the
    /// four-character string `"null"` that a naive `"\(value)"` interpolation
    /// would have produced.
    func testNullFieldsRoundTripAsNSNullNotAsAStringLiteral() throws {
        let object: [String: Any] = ["anchorTracking": MCPServer.shared.anchorTrackingJSON(status(isRunning: false))]
        let text = try XCTUnwrap(MCPServer.shared.jsonString(object))
        let data = try XCTUnwrap(text.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tracking = try XCTUnwrap(parsed["anchorTracking"] as? [String: Any])
        XCTAssertTrue(tracking["sampleIntervalMs"] is NSNull)
        XCTAssertTrue(tracking["lastSampleAgeMs"] is NSNull)
    }

    // MARK: - Timer running, first sample not completed yet

    /// A timer can be scheduled (anchors exist) before its first tick has
    /// ever fired -- `sampleIntervalMs` is already known, but
    /// `lastSampleAgeMs` has nothing to measure from yet.
    func testTimerRunningButNoSampleYetOnlyNullsLastSampleAge() throws {
        let text = try serialized(status(isRunning: true, anchored: 1, tracking: 0, sampleIntervalMs: 33, lastSampleAgeMs: nil))
        XCTAssertTrue(text.contains("\"sampleIntervalMs\":33"), text)
        XCTAssertTrue(text.contains("\"lastSampleAgeMs\":null"), text)
    }

    // MARK: - Fully live: every field a real value

    func testFullyLiveTrackingSerializesEveryFieldAsANumber() throws {
        let text = try serialized(status(
            isRunning: true, anchored: 3, tracking: 2, hidden: 1, lost: 0,
            sampleIntervalMs: 33, lastSampleAgeMs: 12
        ))
        XCTAssertTrue(text.contains("\"anchored\":3"), text)
        XCTAssertTrue(text.contains("\"tracking\":2"), text)
        XCTAssertTrue(text.contains("\"hidden\":1"), text)
        XCTAssertTrue(text.contains("\"lost\":0"), text)
        XCTAssertTrue(text.contains("\"sampleIntervalMs\":33"), text)
        XCTAssertTrue(text.contains("\"lastSampleAgeMs\":12"), text)
        XCTAssertFalse(text.contains("null"), "every field has a real value here; \"null\" should not appear anywhere: \(text)")
    }

    // MARK: - anchorTrackingJSON is a pure function of its input

    func testAnchorTrackingJSONReadsCountsVerbatimFromTheStatusItIsGiven() {
        let object = MCPServer.shared.anchorTrackingJSON(status(isRunning: true, anchored: 5, tracking: 4, hidden: 1, lost: 0, sampleIntervalMs: 250, lastSampleAgeMs: 5))
        XCTAssertEqual(object["anchored"] as? Int, 5)
        XCTAssertEqual(object["tracking"] as? Int, 4)
        XCTAssertEqual(object["hidden"] as? Int, 1)
        XCTAssertEqual(object["lost"] as? Int, 0)
        XCTAssertEqual(object["sampleIntervalMs"] as? Int, 250)
        XCTAssertEqual(object["lastSampleAgeMs"] as? Int, 5)
    }

    // MARK: - get_overlay_state's live payload actually carries the key

    /// One integration check that the real `get_overlay_state` case body
    /// (not a hand-assembled stand-in) embeds `anchorTracking` sourced from
    /// the SAME `AnchorTracker.shared` this whole feature runs against. This
    /// does not call `handleToolsCall` (see this file's header comment on
    /// stdout); instead it reproduces the one relevant line the way
    /// `MCPToolCatalogTests` reproduces catalog shape checks without
    /// spinning up the transport.
    func testAnchorTrackerSharedStatusSummaryProducesAWellFormedAnchorTrackingObject() throws {
        let liveStatus = AnchorTracker.shared.statusSummary()
        let text = try serialized(liveStatus)
        let data = try XCTUnwrap(text.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tracking = try XCTUnwrap(parsed["anchorTracking"] as? [String: Any])
        XCTAssertNotNil(tracking["anchored"] as? Int)
        XCTAssertNotNil(tracking["tracking"] as? Int)
        XCTAssertNotNil(tracking["hidden"] as? Int)
        XCTAssertNotNil(tracking["lost"] as? Int)
        // sampleIntervalMs/lastSampleAgeMs are present as a KEY either way
        // (a real number or NSNull); this asserts presence, not value, since
        // whether anything is anchored in the shared process at test time is
        // not something this test controls.
        XCTAssertTrue(tracking.keys.contains("sampleIntervalMs"))
        XCTAssertTrue(tracking.keys.contains("lastSampleAgeMs"))
    }
}
