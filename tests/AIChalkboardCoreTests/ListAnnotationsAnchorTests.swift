import Foundation
import XCTest
@testable import AIChalkboardCore

/// Covers `list_annotations`' new per-entry `anchor` object (MCP_SURFACE.md's
/// "Success payload" section, shared byte-for-byte with `draw_*`/
/// `highlight_element`/`update_annotation` via
/// `DrawRequest.anchorResponsePayload`): present, correctly shaped, when an
/// annotation is anchored; omitted entirely -- never `null`, never a
/// `{"mode":"none"}` placeholder -- when it is not. Also covers the existing
/// response-size/summarisation budget still holding with the new field
/// folded in.
///
/// Necessarily exercises `AnnotationStore.shared` and
/// `MCPServer.shared.buildAnnotationListJSON`, because that function has no
/// injectable store (see `AppBehaviorTests.swift` for the established
/// precedent of testing directly against `.shared` with careful `defer`
/// cleanup). One consequence documented here rather than hidden: adding an
/// ANCHORED annotation to `AnnotationStore.shared` can wake the real,
/// production `AnchorTracker.shared` (it is wired to
/// `AnnotationStore.shared.onAnchoredSetChanged` the first time anything in
/// this process touches `AnchorTracker.shared`, which `GetOverlayStateAnchorTrackingTests`
/// in this same test bundle deliberately does) and sample this fixture's
/// made-up window in the background. That sampling can only ever move this
/// fixture's reported `state` (`tracking` -> `hidden`, and only after
/// several ticks, `lost`) -- see `AnchorTracker.buildCandidateProjection`'s
/// `.hidden`/`.lost` branches, which both carry the PREVIOUS `adjustment`/
/// `currentWindowFrame`/`effectiveScreenId` forward unchanged when no fresh
/// sample is found. Assertions below therefore pin every field except
/// `state` (checked only for being one of the three legal values), and each
/// test uses a target identity (`processId`/`windowId`) not shared with any
/// other test file, so one test's fixture can never race against another's.
final class ListAnnotationsAnchorTests: XCTestCase {

    private static let legalStates: Set<String> = ["tracking", "hidden", "lost"]

    // MARK: - Fixtures

    private func annotation(
        id: String, appId: String? = "com.example.list-annotations-anchor-tests",
        anchor: AnnotationAnchor? = nil, anchorProjection: AnchorProjection? = nil,
        pathData: String = "M0 0 L10 10"
    ) -> Annotation {
        Annotation(
            id: id, screenId: "1",
            kind: .vectorPath(
                data: pathData, strokeColorHex: "#FF0000", strokeWidth: 2, strokeOpacity: 1,
                fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                coordinateScaleX: 1, coordinateScaleY: 1
            ),
            appId: appId, appName: nil,
            anchor: anchor, anchorProjection: anchorProjection
        )
    }

    private func windowAnchor(processId: Int64, windowId: UInt64, referenceFrame: CGRect) -> AnnotationAnchor {
        AnnotationAnchor(
            mode: .window, resize: .scale,
            target: AnchorWindowTarget(processId: processId, windowId: windowId, appId: "com.example.list-annotations-anchor-tests"),
            referenceWindowFrame: AnchorRect(referenceFrame),
            referenceScreenId: "1"
        )
    }

    /// Fetches `list_annotations` pages, starting at `offset`, until an entry
    /// with `id` is found or the store is exhausted. Robust to any
    /// leftover/concurrent state in the shared store -- this suite never
    /// assumes its own fixture is the only annotation present, or lands on
    /// page one.
    private func findEntry(id: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var offset = 0
        while true {
            let outcome = MCPServer.shared.buildAnnotationListJSON(args: ["offset": offset, "limit": DrawingDefaults.maxAnnotationListPageItems])
            guard case .success(let text) = outcome else {
                if case .failure(let message) = outcome {
                    XCTFail("buildAnnotationListJSON failed: \(message)", file: file, line: line)
                }
                throw XCTSkip("buildAnnotationListJSON did not succeed")
            }
            let data = try XCTUnwrap(text.data(using: .utf8), file: file, line: line)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
            let entries = try XCTUnwrap(parsed["annotations"] as? [[String: Any]], file: file, line: line)
            if let match = entries.first(where: { ($0["id"] as? String) == id }) {
                return match
            }
            guard (parsed["truncated"] as? Bool) == true, let nextOffset = parsed["nextOffset"] as? Int else {
                XCTFail("annotation \(id) never appeared in list_annotations", file: file, line: line)
                throw XCTSkip("annotation not found")
            }
            offset = nextOffset
        }
    }

    // MARK: - Anchored entries gain the flat `anchor` object

    func testAnchoredEntryGainsTheFlatAnchorObjectAndDropsInternalBookkeepingKeys() throws {
        let store = AnnotationStore.shared
        let id = "list-annotations-anchor-tests-anchored-\(UUID().uuidString)"
        let anchor = windowAnchor(processId: 424_242, windowId: 424_243, referenceFrame: CGRect(x: 0, y: 130, width: 6_048, height: 3_508))
        let projection = AnchorProjection(
            state: .tracking,
            adjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0),
            effectiveScreenId: "69733382",
            currentWindowFrame: AnchorRect(x: 0, y: 130, width: 6_048, height: 3_508),
            sampledAt: Date()
        )
        store.add(annotation(id: id, anchor: anchor, anchorProjection: projection))
        defer { _ = store.remove(id: id) }

        let entry = try findEntry(id: id)
        let anchorObject = try XCTUnwrap(entry["anchor"] as? [String: Any])
        XCTAssertEqual(anchorObject["mode"] as? String, "window")
        XCTAssertEqual(anchorObject["resize"] as? String, "scale")
        XCTAssertEqual(anchorObject["windowId"] as? Int, 424_243)
        XCTAssertEqual(anchorObject["processId"] as? Int, 424_242)
        let referenceFrame = try XCTUnwrap(anchorObject["referenceWindowFrame"] as? [String: Any])
        XCTAssertEqual(referenceFrame["width"] as? Double, 6_048)
        XCTAssertEqual(referenceFrame["height"] as? Double, 3_508)
        let adjustment = try XCTUnwrap(anchorObject["adjustment"] as? [String: Any])
        XCTAssertEqual(adjustment["scaleX"] as? Double, 1)
        XCTAssertEqual(adjustment["translateX"] as? Double, 0)
        let state = try XCTUnwrap(anchorObject["state"] as? String)
        XCTAssertTrue(Self.legalStates.contains(state), "unexpected state value: \(state)")

        // Internal frozen-adjustment/projection bookkeeping must not leak
        // through as separate top-level keys once the flat `anchor` object
        // has absorbed everything a caller needs.
        XCTAssertNil(entry["staticAdjustment"])
        XCTAssertNil(entry["anchorProjection"])
    }

    // MARK: - Unanchored entries omit the key entirely

    func testUnanchoredEntryOmitsTheAnchorKeyEntirely() throws {
        let store = AnnotationStore.shared
        let id = "list-annotations-anchor-tests-unanchored-\(UUID().uuidString)"
        store.add(annotation(id: id, anchor: nil, anchorProjection: nil))
        defer { _ = store.remove(id: id) }

        let entry = try findEntry(id: id)
        XCTAssertNil(entry["anchor"], "an unanchored annotation must omit the anchor key -- never null, never a {\"mode\":\"none\"} placeholder")
        XCTAssertNil(entry["staticAdjustment"])
        XCTAssertNil(entry["anchorProjection"])
    }

    // MARK: - Response-size budget: an oversized anchored entry

    /// An anchored annotation whose geometry alone exceeds
    /// `DrawingDefaults.maxAnnotationListEntryBytes` must still be summarized
    /// (its `kind` dropped, `geometryOmitted: true` reported) exactly as an
    /// unanchored oversized entry already is -- AND the `anchor` object,
    /// which is tiny and computed independently of `kind`, must survive that
    /// summarisation. Losing anchor state on exactly the annotations large
    /// enough to be summarized would be a silent regression for the callers
    /// most likely to need it (a big traced outline is a plausible thing to
    /// anchor).
    func testOversizedAnchoredEntryKeepsTheAnchorObjectAfterGeometryIsSummarized() throws {
        let store = AnnotationStore.shared
        let id = "list-annotations-anchor-tests-oversized-\(UUID().uuidString)"
        // Comfortably past `maxAnnotationListEntryBytes` (512 KiB) on its own.
        let hugePathData = "M0 0 " + String(repeating: "L1 1 ", count: 130_000)
        let anchor = windowAnchor(processId: 424_244, windowId: 424_245, referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let projection = AnchorProjection(
            state: .tracking, adjustment: .identity, effectiveScreenId: "1",
            currentWindowFrame: AnchorRect(x: 0, y: 0, width: 100, height: 100), sampledAt: Date()
        )
        store.add(annotation(id: id, anchor: anchor, anchorProjection: projection, pathData: hugePathData))
        defer { _ = store.remove(id: id) }

        let entry = try findEntry(id: id)
        XCTAssertEqual(entry["geometryOmitted"] as? Bool, true, "the oversized path must still trigger the existing geometry-omission summary")
        XCTAssertNil(entry["kind"], "omitted geometry must not still be present")
        let anchorObject = try XCTUnwrap(entry["anchor"] as? [String: Any], "the anchor object must survive geometry summarization")
        XCTAssertEqual(anchorObject["windowId"] as? Int, 424_245)
        XCTAssertEqual(anchorObject["mode"] as? String, "window")
    }

    // MARK: - A page of anchored annotations stays within the total budget

    /// Not a single oversized entry this time, but MANY ordinary-sized
    /// anchored ones in the same page -- proving the per-entry `anchor`
    /// object's extra bytes, multiplied across a full page, do not blow the
    /// existing total response cap (`maxAnnotationListTextBytes`) or break
    /// the paging arithmetic. The existing incremental byte-check loop in
    /// `buildAnnotationListJSON` already accounts for whatever each entry
    /// adds; this is a regression guard proving that remains true with the
    /// new field folded in, not a new mechanism.
    func testAPageOfManyAnchoredAnnotationsStaysWithinBudgetAndEachKeepsItsAnchor() throws {
        let store = AnnotationStore.shared
        let count = 25
        var ids: [String] = []
        for index in 0..<count {
            let id = "list-annotations-anchor-tests-bulk-\(index)-\(UUID().uuidString)"
            ids.append(id)
            let anchor = windowAnchor(
                processId: Int64(424_300 + index), windowId: UInt64(424_400 + index),
                referenceFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
            let projection = AnchorProjection(
                state: .tracking, adjustment: .identity, effectiveScreenId: "1",
                currentWindowFrame: AnchorRect(x: 0, y: 0, width: 100, height: 100), sampledAt: Date()
            )
            store.add(annotation(id: id, anchor: anchor, anchorProjection: projection))
        }
        defer { for id in ids { _ = store.remove(id: id) } }

        for (index, id) in ids.enumerated() {
            let entry = try findEntry(id: id)
            let anchorObject = try XCTUnwrap(entry["anchor"] as? [String: Any], "entry \(index) lost its anchor object")
            XCTAssertEqual(anchorObject["windowId"] as? Int, 424_400 + index)
        }
    }
}
