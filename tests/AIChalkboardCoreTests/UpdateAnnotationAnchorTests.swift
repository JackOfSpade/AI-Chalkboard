import Foundation
import XCTest
@testable import AIChalkboardCore

/// Exercises `update_annotation`'s three anchor-touching operations --
/// detach (`anchor: "none"`), (re-)anchor (`anchor: "window"`), and an
/// in-place resize-policy change (`anchor_resize` alone on an already
/// anchored annotation) -- plus the shared string-validation rejection
/// matrix, matching the split `DrawRequestAnchorTests.swift` already
/// established for `draw_*`'s own `anchor`/`anchor_resize` arguments:
///
/// 1. `parseAnchorPatch` -- pure string/enum validation plus the
///    "is this annotation currently anchored" branch, no process or window
///    work at all.
/// 2. `resolveAnchorPatch` -- the DECISION half (what gets written into the
///    resulting `anchor`/`staticAdjustment`/projection-override), exercised
///    with hand-built `Annotation`s. `.reanchor`'s SUCCESS path (an actual
///    window get chosen) is NOT exercised here, for the same reason
///    `DrawRequestAnchorTests.swift` never calls the platform-specific
///    `TargetWindowSampling` conformances directly: it needs a real running
///    process and a real foreground window. Its REJECTION paths that occur
///    before any window is sampled (global annotation, app not running) are
///    fully deterministic and are covered.
/// 3. `patchedAnnotation` -- the full pipeline, proving the anchor patch
///    composes correctly with ordinary field patching (offset/opacity) and
///    that the "at least one field", "unsupported field", and numeric
///    validations still run.
/// 4. Two "through the real store" tests that additionally drive
///    `AnnotationStore.shared.updateWithOutcome` and `applyAnchorProjections`
///    exactly as `handleUpdateAnnotation` does, proving the documented
///    `updateWithOutcome`-carries-the-old-projection-forward interaction
///    (see `AnnotationPatchResult`'s doc comment) does not resurrect the
///    adjustment this feature just froze away.
final class UpdateAnnotationAnchorTests: XCTestCase {

    // MARK: - Fixtures

    private static let fixtureAppId = "com.example.target"

    private func windowAnchor(
        windowId: UInt64 = 42,
        resize: AnchorResizeBehavior = .pin,
        referenceScreenId: String = "1",
        referenceFrame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100),
        appId: String? = fixtureAppId
    ) -> AnnotationAnchor {
        AnnotationAnchor(
            mode: .window,
            resize: resize,
            target: AnchorWindowTarget(processId: 100, windowId: windowId, appId: appId),
            referenceWindowFrame: AnchorRect(referenceFrame),
            referenceScreenId: referenceScreenId
        )
    }

    /// A deliberately NON-identity live projection -- `adjustment` carries
    /// both a scale and a translate -- so folding it into `staticAdjustment`
    /// is a real, checkable composition rather than a no-op that would pass
    /// even with a bug in the fold.
    private func liveProjection(
        state: AnchorTrackingState = .tracking,
        adjustment: AnchorAdjustment = AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 100, translateY: 50),
        effectiveScreenId: String = "screen-9",
        currentFrame: CGRect? = CGRect(x: 50, y: 60, width: 300, height: 200),
        elementResolutionIssue: String? = nil
    ) -> AnchorProjection {
        AnchorProjection(
            state: state, adjustment: adjustment, effectiveScreenId: effectiveScreenId,
            currentWindowFrame: currentFrame.map(AnchorRect.init), sampledAt: Date(),
            elementResolutionIssue: elementResolutionIssue
        )
    }

    private func annotation(
        id: String = UUID().uuidString,
        appId: String? = fixtureAppId,
        appName: String? = nil,
        screenId: String = "1",
        offsetX: Double = 0,
        offsetY: Double = 0,
        anchor: AnnotationAnchor? = nil,
        staticAdjustment: AnchorAdjustment = .identity,
        anchorProjection: AnchorProjection? = nil
    ) -> Annotation {
        Annotation(
            id: id, screenId: screenId,
            kind: .vectorPath(
                data: "M0 0 L10 10", strokeColorHex: "#FF0000", strokeWidth: 2, strokeOpacity: 1,
                fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                coordinateScaleX: 1, coordinateScaleY: 1
            ),
            appId: appId, appName: appName,
            offsetX: offsetX, offsetY: offsetY,
            anchor: anchor, staticAdjustment: staticAdjustment, anchorProjection: anchorProjection
        )
    }

    // MARK: - Generic DrawOutcome helpers

    @discardableResult
    private func expectSuccess<T>(_ outcome: DrawOutcome<T>, file: StaticString = #filePath, line: UInt = #line) -> T? {
        switch outcome {
        case .success(let value): return value
        case .failure(let message):
            XCTFail("expected success but got failure(\(message))", file: file, line: line)
            return nil
        }
    }

    @discardableResult
    private func expectFailure<T>(_ outcome: DrawOutcome<T>, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch outcome {
        case .success:
            XCTFail("expected failure but got success", file: file, line: line)
            return nil
        case .failure(let message): return message
        }
    }

    // MARK: - parseAnchorPatch: valid values

    func testNeitherArgumentSuppliedIsUnchanged() {
        let intent = expectSuccess(MCPServer.shared.parseAnchorPatch([:], currentlyAnchored: true))
        XCTAssertEqual(intent, .unchanged)
        let intentUnanchored = expectSuccess(MCPServer.shared.parseAnchorPatch([:], currentlyAnchored: false))
        XCTAssertEqual(intentUnanchored, .unchanged)
    }

    func testAnchorNoneIsDetach() {
        let intent = expectSuccess(MCPServer.shared.parseAnchorPatch(["anchor": "none"], currentlyAnchored: true))
        XCTAssertEqual(intent, .detach)
    }

    func testAnchorWindowWithNoResizeDefaultsToPin() {
        let intent = expectSuccess(MCPServer.shared.parseAnchorPatch(["anchor": "window"], currentlyAnchored: false))
        XCTAssertEqual(intent, .reanchor(resize: .pin))
    }

    func testAnchorWindowWithExplicitScale() {
        let intent = expectSuccess(MCPServer.shared.parseAnchorPatch(["anchor": "window", "anchor_resize": "scale"], currentlyAnchored: true))
        XCTAssertEqual(intent, .reanchor(resize: .scale))
    }

    func testAnchorResizeAloneOnAnAlreadyAnchoredAnnotationChangesPolicy() {
        let intent = expectSuccess(MCPServer.shared.parseAnchorPatch(["anchor_resize": "scale"], currentlyAnchored: true))
        XCTAssertEqual(intent, .changeResizePolicy(resize: .scale))
    }

    // MARK: - parseAnchorPatch: wrong type / unknown value

    func testAnchorWrongTypeRejected() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor": 42], currentlyAnchored: false))
        XCTAssertEqual(message, "anchor must be one of \"none\", \"window\" when supplied.")
    }

    func testAnchorUnknownValueRejected() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor": "orbit"], currentlyAnchored: false))
        XCTAssertEqual(message, "anchor must be one of \"none\", \"window\" when supplied.")
    }

    func testAnchorResizeWrongTypeRejected() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor": "window", "anchor_resize": 1], currentlyAnchored: false))
        XCTAssertEqual(message, "anchor_resize must be one of \"pin\", \"scale\" when supplied.")
    }

    func testAnchorResizeUnknownValueRejected() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor": "window", "anchor_resize": "stretch"], currentlyAnchored: false))
        XCTAssertEqual(message, "anchor_resize must be one of \"pin\", \"scale\" when supplied.")
    }

    // MARK: - parseAnchorPatch: the rejection matrix's shared literal

    /// MCP_SURFACE.md ships ONE literal for every "effective anchor mode is
    /// none" rejection; these two update_annotation triggers -- an explicit
    /// `anchor="none"` alongside `anchor_resize`, and `anchor_resize` alone
    /// on an UNANCHORED annotation -- must produce the exact same string.
    private static let sharedNoAnchorWindowRejection =
        "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."

    func testAnchorResizeWithAnchorNoneRejected() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor": "none", "anchor_resize": "pin"], currentlyAnchored: true))
        XCTAssertEqual(message, Self.sharedNoAnchorWindowRejection)
    }

    func testAnchorResizeAloneOnAnUnanchoredAnnotationRejected() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor_resize": "pin"], currentlyAnchored: false))
        XCTAssertEqual(message, Self.sharedNoAnchorWindowRejection)
    }

    /// An unknown `anchor_resize` value must be named specifically even when
    /// it would otherwise also be rejected for lacking `anchor="window"" --
    /// same precedent as `DrawRequestAnchorTests
    /// .testAnchorResizeInvalidValueTakesPrecedenceOverTheAnchorNoneRejection`.
    func testAnchorResizeInvalidValueTakesPrecedenceOverTheNoAnchorRejection() {
        let message = expectFailure(MCPServer.shared.parseAnchorPatch(["anchor": "none", "anchor_resize": "bogus"], currentlyAnchored: true))
        XCTAssertEqual(message, "anchor_resize must be one of \"pin\", \"scale\" when supplied.")
    }

    // MARK: - resolveAnchorPatch: .detach freezes in place

    /// THE core invariant this whole feature exists to guarantee: detaching
    /// must not move the drawing by a single pixel. Folding the live
    /// adjustment into `staticAdjustment` is the mechanism; this test proves
    /// the arithmetic actually lands where the design says it must, and that
    /// reconstructing the resulting annotation (static + the projection
    /// override, exactly as `AnnotationStore` will after
    /// `applyAnchorProjections`) reproduces the SAME `effectiveAdjustment`
    /// bit for bit.
    func testDetachFreezesEffectiveAdjustmentAndClearsAnchor() throws {
        let original = annotation(
            anchor: windowAnchor(),
            staticAdjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 5, translateY: -3),
            anchorProjection: liveProjection(
                adjustment: AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 100, translateY: 50),
                effectiveScreenId: "screen-9"
            )
        )
        let beforeEffective = original.effectiveAdjustment
        // Sanity: this fixture's static/live composition is NOT trivially
        // identity, so a bug that dropped the fold (or dropped the
        // override) would show up as a real numeric mismatch below, not an
        // accidental pass.
        XCTAssertFalse(beforeEffective.isIdentity)

        let resolution = try XCTUnwrap(expectSuccess(
            MCPServer.shared.resolveAnchorPatch(.detach, current: original)
        ))
        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.screenId, "screen-9", "the frozen screenId must be the CURRENT effective screen, not the annotation's original (possibly stale) screenId")
        XCTAssertEqual(resolution.staticAdjustment, beforeEffective)

        let override = try XCTUnwrap(resolution.projectionOverride, "a real anchor's live projection must be neutralized, not merely dropped")
        XCTAssertEqual(override.adjustment, .identity)
        XCTAssertEqual(override.effectiveScreenId, "screen-9")

        // Reconstruct exactly what `AnnotationStore` will hold once
        // `updateWithOutcome` writes `resolution` and `applyAnchorProjections`
        // writes `override` -- see `AnnotationPatchResult`'s doc comment for
        // why both writes are necessary.
        let after = annotation(
            anchor: resolution.anchor, staticAdjustment: resolution.staticAdjustment,
            anchorProjection: override
        )
        XCTAssertEqual(after.effectiveAdjustment, beforeEffective, "detaching must not move the drawing by a single pixel")
        XCTAssertFalse(after.anchorProjection.map { $0.adjustment != .identity } ?? false)
    }

    /// Detaching an annotation that was never anchored is a harmless no-op:
    /// nothing to fold (the live adjustment is already `.identity`), and
    /// nothing to neutralize (there is no stale projection to double-count).
    func testDetachOnAnAlreadyUnanchoredAnnotationIsANoOp() throws {
        let original = annotation(staticAdjustment: .identity, anchorProjection: nil)
        let resolution = try XCTUnwrap(expectSuccess(
            MCPServer.shared.resolveAnchorPatch(.detach, current: original)
        ))
        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.staticAdjustment, .identity)
        XCTAssertEqual(resolution.screenId, original.screenId)
        XCTAssertNil(resolution.projectionOverride, "nothing to neutralize when there was no live projection to begin with")
    }

    // MARK: - resolveAnchorPatch: .reanchor rejections (no live window needed)

    func testReanchorRejectsAGlobalAnnotation() {
        let original = annotation(appId: nil, anchor: nil)
        let message = expectFailure(MCPServer.shared.resolveAnchorPatch(.reanchor(resize: .pin), current: original))
        XCTAssertEqual(message, "anchor=\"window\" cannot be applied to a global annotation: it has no target application whose window to anchor to. Re-create the drawing with an app link, or leave it unanchored.")
    }

    /// Fully deterministic without mocking `TargetWindowProbe`: a bundle id
    /// that is guaranteed not to be a running application makes
    /// `MCPServer.runningProcessIds(forAppId:)` reliably return an empty
    /// list, exercising the rejection BEFORE any window sampling happens --
    /// the same "test the process-resolution failure without a live window"
    /// approach `DrawRequestAnchorTests.swift` declines to attempt for the
    /// ambiguous/no-eligible-window cases (which genuinely need a live
    /// process). See this file's header comment.
    func testReanchorRejectsWhenTheLinkedAppIsNotRunning() {
        let appId = "com.aichalkboard.tests.update-annotation-reanchor-definitely-not-running"
        let original = annotation(appId: appId, appName: nil, anchor: nil)
        let message = expectFailure(MCPServer.shared.resolveAnchorPatch(.reanchor(resize: .pin), current: original))
        XCTAssertEqual(message, "anchor=\"window\" requires \(appId) to be a running application so its windows can be sampled, but no running process matches. The annotation was left unchanged; bring that application to the front and retry, or omit anchor.")
    }

    // MARK: - resolveAnchorPatch: .changeResizePolicy rebaselines without a jump

    func testChangeResizePolicyRebaselinesToTheCurrentWindowFrameWithoutJumping() throws {
        let existingAnchor = windowAnchor(windowId: 7, resize: .pin, referenceScreenId: "1", referenceFrame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let live = liveProjection(
            state: .tracking,
            adjustment: AnchorAdjustment(scaleX: 1.5, scaleY: 1.5, translateX: 30, translateY: 10),
            effectiveScreenId: "screen-3",
            currentFrame: CGRect(x: 50, y: 60, width: 300, height: 200)
        )
        let original = annotation(
            anchor: existingAnchor,
            staticAdjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 2, translateY: 4),
            anchorProjection: live
        )
        let beforeEffective = original.effectiveAdjustment

        let resolution = try XCTUnwrap(expectSuccess(
            MCPServer.shared.resolveAnchorPatch(.changeResizePolicy(resize: .scale), current: original)
        ))
        let newAnchor = try XCTUnwrap(resolution.anchor)
        XCTAssertEqual(newAnchor.resize, .scale)
        XCTAssertEqual(newAnchor.target, existingAnchor.target, "the target window itself must not change, only the policy")
        XCTAssertEqual(newAnchor.referenceWindowFrame, AnchorRect(x: 50, y: 60, width: 300, height: 200), "must rebaseline to the CURRENT sampled frame, not the original reference")
        XCTAssertEqual(newAnchor.referenceScreenId, "screen-3")
        XCTAssertEqual(resolution.staticAdjustment, beforeEffective)

        let override = try XCTUnwrap(resolution.projectionOverride)
        XCTAssertEqual(override.adjustment, .identity, "reference now equals current by construction, so the fresh live delta is identity")
        XCTAssertEqual(override.currentWindowFrame, AnchorRect(x: 50, y: 60, width: 300, height: 200))
        XCTAssertEqual(override.effectiveScreenId, "screen-3")
        XCTAssertEqual(override.state, .tracking, "the tracker's last-known state must be preserved, not fabricated")

        let after = annotation(anchor: newAnchor, staticAdjustment: resolution.staticAdjustment, anchorProjection: override)
        XCTAssertEqual(after.effectiveAdjustment, beforeEffective, "a resize-policy change must not move the drawing by a single pixel")
    }

    /// A `.hidden`/`.lost` annotation's `state` must be preserved through a
    /// resize-policy rebaseline, never upgraded to `.tracking` -- fabricating
    /// liveness here would violate the design contract's "honest reporting"
    /// invariant and could never be corrected later, because `AnchorTracker`
    /// permanently stops sampling a `.lost` target (see that class's own doc
    /// comment).
    func testChangeResizePolicyPreservesAHiddenOrLostState() throws {
        let existingAnchor = windowAnchor()
        let original = annotation(
            anchor: existingAnchor,
            anchorProjection: liveProjection(state: .hidden, currentFrame: CGRect(x: 1, y: 2, width: 3, height: 4))
        )
        let resolution = try XCTUnwrap(expectSuccess(
            MCPServer.shared.resolveAnchorPatch(.changeResizePolicy(resize: .scale), current: original)
        ))
        XCTAssertEqual(resolution.projectionOverride?.state, .hidden)
    }

    // MARK: - patchedAnnotation: the full pipeline

    func testPatchedAnnotationLeavesAnchorAndStaticAdjustmentUntouchedWhenNeitherArgumentIsSupplied() throws {
        let anchor = windowAnchor()
        let projection = liveProjection()
        let original = annotation(
            anchor: anchor,
            staticAdjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 9, translateY: 9),
            anchorProjection: projection
        )
        let result = try XCTUnwrap(expectSuccess(
            MCPServer.shared.patchedAnnotation(original, args: ["annotation_id": original.id, "opacity": 0.5])
        ))
        XCTAssertEqual(result.annotation.anchor, anchor)
        XCTAssertEqual(result.annotation.staticAdjustment, original.staticAdjustment)
        XCTAssertEqual(result.annotation.opacity, 0.5)
        XCTAssertNil(result.projectionOverride, "an ordinary restyle must not touch tracking state at all")
    }

    func testPatchedAnnotationRejectsAnchorResizeAloneOnAnUnanchoredAnnotation() {
        let original = annotation(anchor: nil, anchorProjection: nil)
        let message = expectFailure(
            MCPServer.shared.patchedAnnotation(original, args: ["annotation_id": original.id, "anchor_resize": "scale"])
        )
        XCTAssertEqual(message, Self.sharedNoAnchorWindowRejection)
    }

    func testPatchedAnnotationRejectsReanchoringAGlobalAnnotation() {
        let original = annotation(appId: nil, anchor: nil)
        let message = expectFailure(
            MCPServer.shared.patchedAnnotation(original, args: ["annotation_id": original.id, "anchor": "window"])
        )
        XCTAssertEqual(message, "anchor=\"window\" cannot be applied to a global annotation: it has no target application whose window to anchor to. Re-create the drawing with an app link, or leave it unanchored.")
    }

    /// `anchor: "none"` combined with an ordinary field in the SAME call:
    /// both effects must apply together, proving the anchor patch composes
    /// with the rest of `patchedAnnotation` rather than short-circuiting it.
    func testDetachComposesWithAnOrdinaryFieldPatchInTheSameCall() throws {
        let original = annotation(
            offsetX: 0, offsetY: 0,
            anchor: windowAnchor(), anchorProjection: liveProjection()
        )
        let result = try XCTUnwrap(expectSuccess(
            MCPServer.shared.patchedAnnotation(original, args: ["annotation_id": original.id, "anchor": "none", "offset_x": 42.0])
        ))
        XCTAssertNil(result.annotation.anchor)
        XCTAssertEqual(result.annotation.offsetX, 42.0)
        XCTAssertNotNil(result.projectionOverride)
    }

    // MARK: - Through the real store: no residual double-adjustment,
    // even with a racing AnchorTracker write interleaved (BUG 1)

    /// Commits `patch` through the SAME transform-based primitive
    /// `handleUpdateAnnotation` now uses (`finalizeAnchorPatch` +
    /// `AnnotationStore.updateWithOutcome(id:expectedRevision:transform:)`),
    /// instead of the old by-replacement overload plus a follow-up
    /// `applyAnchorProjections` -- this file's now-fixed BUG 1. Every
    /// "through the real store" test below drives this rather than
    /// reimplementing `handleUpdateAnnotation`'s commit step by hand, so
    /// they exercise the ACTUAL production code path.
    @discardableResult
    private func commit(_ patch: AnnotationPatchResult, id: String, expectedRevision: UInt64) -> AnnotationStoreUpdateResult {
        AnnotationStore.shared.updateWithOutcome(id: id, expectedRevision: expectedRevision) { live in
            MCPServer.shared.finalizeAnchorPatch(patch, live: live)
        }
    }

    /// Drives `AnnotationStore.shared` exactly as `handleUpdateAnnotation`
    /// does, without touching `sendTextResult`/`sendErrorResult` -- see this
    /// file's header comment on why the stdout-writing handler itself is not
    /// a usable test seam. No racing write here: this is the baseline
    /// "nothing else touched the annotation" case: `.reanchor`'s equivalent
    /// baseline lives below, right next to its racing counterpart, because
    /// building its patch needs a resolved window either way.
    func testDetachThroughTheRealStoreLeavesEffectiveAdjustmentExactlyUnchanged() throws {
        let store = AnnotationStore.shared
        let id = "update-annotation-anchor-tests-detach-\(UUID().uuidString)"
        let original = annotation(
            id: id,
            anchor: windowAnchor(),
            staticAdjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 5, translateY: -3),
            anchorProjection: liveProjection(adjustment: AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 100, translateY: 50))
        )
        XCTAssertEqual(store.addWithOutcome(original), .added)
        defer { _ = store.remove(id: id) }

        let stored = try XCTUnwrap(store.get(id: id))
        let beforeEffective = stored.effectiveAdjustment

        let patch = try XCTUnwrap(expectSuccess(
            MCPServer.shared.patchedAnnotation(stored, args: ["annotation_id": id, "anchor": "none"])
        ))
        XCTAssertEqual(commit(patch, id: id, expectedRevision: stored.revision), .updated)

        let after = try XCTUnwrap(store.get(id: id))
        XCTAssertNil(after.anchor)
        XCTAssertEqual(after.effectiveAdjustment, beforeEffective, "detaching through the real store must not move the drawing by even a fractional pixel")
    }

    /// BUG 1's exact reproduction, through the real store: a tracker sample
    /// lands AFTER `stored` is read (and the detach patch is built from it)
    /// but BEFORE this commits. `applyAnchorProjections` deliberately does
    /// not bump `revision` (see its own doc comment -- that property is
    /// load-bearing and must not change), so the CAS below still succeeds
    /// even though the annotation's tracked position moved since `stored`
    /// was captured. Before the fix, `handleUpdateAnnotation` froze
    /// `stored`'s (by-then-stale) `effectiveAdjustment` and then
    /// unconditionally overwrote the racing sample with it via a second
    /// `applyAnchorProjections` call -- discarding the tracker's newer
    /// sample and visibly jumping the drawing. The fix must freeze whatever
    /// is LIVE at commit time instead.
    func testDetachThroughTheRealStoreFreezesTheLiveAdjustmentEvenWithARacingTrackerWriteInterleaved() throws {
        let store = AnnotationStore.shared
        let id = "update-annotation-anchor-tests-detach-race-\(UUID().uuidString)"
        let original = annotation(
            id: id,
            anchor: windowAnchor(),
            staticAdjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 5, translateY: -3),
            anchorProjection: liveProjection(adjustment: .identity, effectiveScreenId: "screen-9")
        )
        XCTAssertEqual(store.addWithOutcome(original), .added)
        defer { _ = store.remove(id: id) }

        let stored = try XCTUnwrap(store.get(id: id))
        let patch = try XCTUnwrap(expectSuccess(
            MCPServer.shared.patchedAnnotation(stored, args: ["annotation_id": id, "anchor": "none"])
        ))

        let racingProjection = liveProjection(
            adjustment: AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 150, translateY: 0),
            effectiveScreenId: "screen-9"
        )
        XCTAssertTrue(store.applyAnchorProjections([id: racingProjection]))
        let expectedFrozenAdjustment = try XCTUnwrap(store.get(id: id)).effectiveAdjustment
        // Sanity: the race must actually change the answer, or this test
        // would pass even under the old, buggy freeze-from-a-stale-read
        // behavior.
        XCTAssertNotEqual(expectedFrozenAdjustment, stored.effectiveAdjustment)

        XCTAssertEqual(commit(patch, id: id, expectedRevision: stored.revision), .updated)

        let after = try XCTUnwrap(store.get(id: id))
        XCTAssertNil(after.anchor)
        XCTAssertEqual(
            after.effectiveAdjustment, expectedFrozenAdjustment,
            "detaching must freeze the LIVE adjustment at commit time -- including a tracker sample that landed after `stored` was read -- not the stale pre-race snapshot BUG 1 froze"
        )
    }

    func testChangeResizePolicyThroughTheRealStoreLeavesEffectiveAdjustmentExactlyUnchanged() throws {
        let store = AnnotationStore.shared
        let id = "update-annotation-anchor-tests-resize-\(UUID().uuidString)"
        let original = annotation(
            id: id,
            anchor: windowAnchor(resize: .pin),
            anchorProjection: liveProjection(
                adjustment: AnchorAdjustment(scaleX: 1.2, scaleY: 1.2, translateX: 8, translateY: 2),
                currentFrame: CGRect(x: 10, y: 20, width: 400, height: 300)
            )
        )
        XCTAssertEqual(store.addWithOutcome(original), .added)
        defer { _ = store.remove(id: id) }

        let stored = try XCTUnwrap(store.get(id: id))
        let beforeEffective = stored.effectiveAdjustment

        let patch = try XCTUnwrap(expectSuccess(
            MCPServer.shared.patchedAnnotation(stored, args: ["annotation_id": id, "anchor_resize": "scale"])
        ))
        XCTAssertEqual(commit(patch, id: id, expectedRevision: stored.revision), .updated)

        let after = try XCTUnwrap(store.get(id: id))
        XCTAssertEqual(after.anchor?.resize, .scale)
        XCTAssertEqual(after.effectiveAdjustment, beforeEffective, "a resize-policy change through the real store must not move the drawing")
    }

    /// BUG 1's reproduction for `anchor_resize`-only: same race as detach
    /// above, plus proof that the REBASELINE itself (`referenceWindowFrame`/
    /// `referenceScreenId`, not just `staticAdjustment`) picks up the racing
    /// sample -- a resize-policy change that rebaselined against the stale
    /// pre-race frame would make the very next tracker tick compute its
    /// delta from the wrong reference and jump on the FOLLOWING sample, even
    /// if this one's `effectiveAdjustment` happened to look right.
    func testChangeResizePolicyThroughTheRealStoreFreezesTheLiveAdjustmentEvenWithARacingTrackerWriteInterleaved() throws {
        let store = AnnotationStore.shared
        let id = "update-annotation-anchor-tests-resize-race-\(UUID().uuidString)"
        let original = annotation(
            id: id,
            anchor: windowAnchor(resize: .pin),
            anchorProjection: liveProjection(
                adjustment: AnchorAdjustment(scaleX: 1.2, scaleY: 1.2, translateX: 8, translateY: 2),
                currentFrame: CGRect(x: 10, y: 20, width: 400, height: 300)
            )
        )
        XCTAssertEqual(store.addWithOutcome(original), .added)
        defer { _ = store.remove(id: id) }

        let stored = try XCTUnwrap(store.get(id: id))
        let patch = try XCTUnwrap(expectSuccess(
            MCPServer.shared.patchedAnnotation(stored, args: ["annotation_id": id, "anchor_resize": "scale"])
        ))

        let racingProjection = liveProjection(
            adjustment: AnchorAdjustment(scaleX: 3, scaleY: 3, translateX: 500, translateY: -20),
            effectiveScreenId: "screen-42",
            currentFrame: CGRect(x: 99, y: 99, width: 111, height: 222)
        )
        XCTAssertTrue(store.applyAnchorProjections([id: racingProjection]))
        let expectedFrozenAdjustment = try XCTUnwrap(store.get(id: id)).effectiveAdjustment
        XCTAssertNotEqual(expectedFrozenAdjustment, stored.effectiveAdjustment)

        XCTAssertEqual(commit(patch, id: id, expectedRevision: stored.revision), .updated)

        let after = try XCTUnwrap(store.get(id: id))
        XCTAssertEqual(after.anchor?.resize, .scale)
        XCTAssertEqual(after.anchor?.referenceWindowFrame, AnchorRect(x: 99, y: 99, width: 111, height: 222), "the rebaseline must use the RACING sample's frame, not the pre-race one `patch` was built against")
        XCTAssertEqual(after.anchor?.referenceScreenId, "screen-42")
        XCTAssertEqual(
            after.effectiveAdjustment, expectedFrozenAdjustment,
            "a resize-policy change must freeze the LIVE adjustment at commit time -- including a tracker sample that landed after `stored` was read"
        )
    }

    /// BUG 1 (freeze) AND BUG 2 (selection) for `anchor: "window"`
    /// re-anchoring, together: with TWO non-overlapping candidate windows, a
    /// tracker sample landing between the pre-lock pick and this commit must
    /// not just leave the drawing's PIXEL POSITION correct (BUG 1) -- it
    /// must also make the committed `anchor` point at whichever window the
    /// drawing is ACTUALLY over once the race lands (BUG 2), not whichever
    /// window the pre-lock (by commit time, stale) sample happened to
    /// prefer. `AnchorTracker.applyAnchorProjections` deliberately never
    /// bumps `revision` (see its own doc comment), so this race's CAS still
    /// succeeds.
    ///
    /// `.reanchor` needs a resolved target window, which -- per this file's
    /// header comment -- is never driven through a real foreign process;
    /// instead this builds the SAME `AnnotationPatchResult` shape
    /// `patchedAnnotation` would have produced -- `reanchorContext` included
    /// -- using `DrawRequest.buildWindowAnchor` with two hand-built
    /// `TargetWindowSample`s (exactly `DrawRequestAnchorTests
    /// .testBuildWindowAnchorChoosesLargestIntersectionAndCapturesItsFrame`'s
    /// own pattern) in place of live process/window resolution. The window
    /// PICK is deterministic geometry over those two samples, so this is a
    /// faithful regression test of the actual fix without needing any
    /// OS-level window access.
    func testReanchorThroughTheRealStoreReselectsTheWindowMatchingTheLiveBoundsWhenARacingTrackerWriteInterleaves() throws {
        let store = AnnotationStore.shared
        let id = "update-annotation-anchor-tests-reanchor-race-\(UUID().uuidString)"
        let original = annotation(
            id: id,
            anchor: windowAnchor(windowId: 1, referenceScreenId: "1"),
            staticAdjustment: .identity,
            anchorProjection: liveProjection(adjustment: .identity, effectiveScreenId: "screen-9")
        )
        XCTAssertEqual(store.addWithOutcome(original), .added)
        defer { _ = store.remove(id: id) }

        let stored = try XCTUnwrap(store.get(id: id))

        // Two candidates, deliberately far apart and non-overlapping: which
        // one wins must be decided by where the drawing ACTUALLY is, never
        // a coin flip between two overlapping rects.
        let nearWindow = TargetWindowSample(
            windowId: 101, processId: 100,
            frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            screenId: "screen-near", isOnScreen: true
        )
        let farWindow = TargetWindowSample(
            windowId: 202, processId: 100,
            frame: CGRect(x: 500, y: 500, width: 50, height: 50),
            screenId: "screen-far", isOnScreen: true
        )
        let samples = [nearWindow, farWindow]

        // The PRE-lock (and, before this fix, final) pick: `stored`'s
        // painted bounds -- the fixture's "M0 0 L10 10" path, at offset
        // (0, 0), under `stored`'s identity `effectiveAdjustment` -- sit at
        // roughly (0, 0, 10, 10): squarely inside `nearWindow`, nowhere near
        // `farWindow`.
        let preRaceBounds = stored.effectiveAdjustment.apply(
            to: (PaintedBounds.paintedBounds(of: stored.kind) ?? .zero).offsetBy(dx: stored.offsetX, dy: stored.offsetY)
        )
        let provisionalPick = try XCTUnwrap(DrawRequest.buildWindowAnchor(
            processId: 100, appId: Self.fixtureAppId, samples: samples,
            paintedBounds: preRaceBounds, resize: .pin, now: Date()
        ))
        XCTAssertEqual(provisionalPick.anchor.target.windowId, 101, "sanity: the pre-race pick must actually favor the near window, or this test would not be exercising the race at all")

        // The "provisional" patch `patchedAnnotation` would hand
        // `handleUpdateAnnotation`, `reanchorContext` included -- see
        // `finalizeAnchorPatch`'s doc comment for why `.reanchor`'s window
        // SELECTION is re-run at commit time against `reanchorContext
        // .samples`, rather than reused verbatim from this provisional pick.
        let patch = AnnotationPatchResult(
            annotation: Annotation(
                id: stored.id, screenId: stored.screenId, kind: stored.kind, colorHex: stored.colorHex,
                label: stored.label, appId: stored.appId, appName: stored.appName, opacity: stored.opacity,
                offsetX: stored.offsetX, offsetY: stored.offsetY, zIndex: stored.zIndex,
                anchor: provisionalPick.anchor, staticAdjustment: stored.staticAdjustment,
                createdAt: stored.createdAt
            ),
            projectionOverride: provisionalPick.projection,
            anchorIntent: .reanchor(resize: .pin),
            reanchorContext: ReanchorWindowContext(processId: 100, appId: Self.fixtureAppId, resize: .pin, samples: samples)
        )

        // The race: a tracker sample lands AFTER `stored`/`provisionalPick`
        // were computed but BEFORE this commits, moving the drawing's LIVE
        // painted position from squarely over `nearWindow` to squarely over
        // `farWindow`.
        let racingProjection = liveProjection(
            adjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 500, translateY: 500),
            effectiveScreenId: "screen-9"
        )
        XCTAssertTrue(store.applyAnchorProjections([id: racingProjection]))
        let racedStored = try XCTUnwrap(store.get(id: id))
        let expectedFrozenAdjustment = racedStored.effectiveAdjustment
        XCTAssertNotEqual(expectedFrozenAdjustment, stored.effectiveAdjustment)

        // Sanity: the racing sample really did move the live painted bounds
        // onto `farWindow` and off `nearWindow` -- this race exercises a
        // DIFFERENT winner, not merely a moved position under the same one.
        let livePaintedBounds = racedStored.effectiveAdjustment.apply(
            to: (PaintedBounds.paintedBounds(of: racedStored.kind) ?? .zero).offsetBy(dx: racedStored.offsetX, dy: racedStored.offsetY)
        )
        XCTAssertGreaterThan(TargetWindowSelection.intersectionArea(livePaintedBounds, farWindow.frame), 0)
        XCTAssertEqual(TargetWindowSelection.intersectionArea(livePaintedBounds, nearWindow.frame), 0)

        XCTAssertEqual(commit(patch, id: id, expectedRevision: stored.revision), .updated)

        let after = try XCTUnwrap(store.get(id: id))
        XCTAssertEqual(after.anchor?.target.windowId, 202, "re-anchoring must select the window matching the LIVE painted bounds at commit time, not the stale pre-race pick -- this is BUG 2, the false doc-comment claim that selection could never depend on `current.anchorProjection`")
        XCTAssertEqual(after.anchor?.referenceScreenId, "screen-far")
        XCTAssertEqual(after.anchorProjection?.adjustment, .identity, "a freshly (re-)selected window starts tracking at identity, not the pre-commit racing sample")
        XCTAssertEqual(
            after.effectiveAdjustment, expectedFrozenAdjustment,
            "re-anchoring must still freeze the LIVE pixel position at commit time (BUG 1) even though the WINDOW it tracks also changed (BUG 2)"
        )
    }

    // MARK: - anchorPatchShouldKickTracker (FIX 3): which intents nudge AnchorTracker

    /// `.reanchor` and `.changeResizePolicy` both install a fresh reference
    /// frame that `AnnotationStore`'s nil<->non-nil membership hook will NOT
    /// restart the tracker's timer for (membership does not change), so both
    /// must ask for an explicit `kick()` instead -- see
    /// `anchorPatchShouldKickTracker`'s own doc comment for the full
    /// rationale. Deliberately asserted directly against the pure predicate,
    /// not by driving the real `AnchorTracker.shared` singleton's sampling
    /// queue/global target state from a test (which `AnchorTrackerTests`'
    /// own header comment on injected fakes exists specifically to avoid).
    func testAnchorPatchShouldKickTrackerForReanchorAndChangeResizePolicy() {
        XCTAssertTrue(MCPServer.shared.anchorPatchShouldKickTracker(.reanchor(resize: .pin)))
        XCTAssertTrue(MCPServer.shared.anchorPatchShouldKickTracker(.reanchor(resize: .scale)))
        XCTAssertTrue(MCPServer.shared.anchorPatchShouldKickTracker(.changeResizePolicy(resize: .pin)))
        XCTAssertTrue(MCPServer.shared.anchorPatchShouldKickTracker(.changeResizePolicy(resize: .scale)))
    }

    /// `.detach` leaves no window to sample, and `.unchanged` never touches
    /// tracking at all -- neither should wake the tracker early.
    func testAnchorPatchShouldNotKickTrackerForDetachOrUnchanged() {
        XCTAssertFalse(MCPServer.shared.anchorPatchShouldKickTracker(.detach))
        XCTAssertFalse(MCPServer.shared.anchorPatchShouldKickTracker(.unchanged))
    }
}
