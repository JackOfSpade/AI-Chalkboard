#if os(macOS)
import AppKit
#elseif os(Windows)
import CChalkboardWin
#endif
import XCTest
@testable import AIChalkboardCore

final class AnnotationStoreTests: XCTestCase {
    private func annotation(id: String, screen: String = "1", appId: String?) -> Annotation {
        Annotation(
            id: id,
            screenId: screen,
            kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1),
            appId: appId,
            appName: appId
        )
    }

    #if os(macOS)
    /// A minimal decodable PNG on disk, for annotations whose kind owns a
    /// raster asset. Mirrors `RasterAssetStoreTests`' fixture -- see that
    /// file for why an in-memory `NSBitmapImageRep` round-tripped through a
    /// temp file is the simplest true "loadable raster" this test suite has.
    private func png(width: Int = 13, height: Int = 7) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-store-raster-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    #elseif os(Windows)
    /// Windows analogue of the macOS fixture above: a minimal decodable PNG
    /// on disk, built via the same `chalk_image_encode_png` WIC-backed
    /// encoder `AnnotationVerificationCompositor`'s Windows branch already
    /// uses, rather than round-tripping through `NSBitmapImageRep` (which
    /// does not exist on this platform). A flat, fully-opaque premultiplied
    /// BGRA buffer is the simplest true "loadable raster" this test suite
    /// needs -- the actual pixel content is never asserted on, only that the
    /// file decodes.
    private func png(width: Int = 13, height: Int = 7) throws -> URL {
        let stride = width * 4
        let bgra = [UInt8](repeating: 0xFF, count: stride * height)
        var outBytes: UnsafeMutablePointer<UInt8>?
        var outLen: Int32 = 0
        let status: Int32 = bgra.withUnsafeBufferPointer { buf in
            chalk_image_encode_png(buf.baseAddress, Int32(width), Int32(height), Int32(stride), &outBytes, &outLen)
        }
        guard status == 0, let encoded = outBytes else {
            throw XCTSkip("chalk_image_encode_png failed with status \(status); cannot build PNG fixture")
        }
        let data = Data(bytes: encoded, count: Int(outLen))
        chalk_image_free_bytes(encoded)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-store-raster-\(UUID().uuidString).png")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    #endif

    /// A raster-backed annotation loaded into the SHARED `RasterAssetStore`
    /// (the same instance `AnnotationStore.releaseRasterAssets` releases
    /// into), so a test can assert the asset is gone after the annotation is.
    private func rasterBackedAnnotation(id: String, screen: String = "1") throws -> Annotation {
        let source = try png()
        let asset = try RasterAssetStore.shared.load(path: source.path)
        return Annotation(
            id: id,
            screenId: screen,
            kind: .image(assetId: asset.id, x: 0, y: 0, width: 13, height: 7, rotationDegrees: 0, opacity: 1)
        )
    }

    /// Builds an indirect batch tree without recursive test helpers. `depth`
    /// is the number of `.batch` containers from root to its leaf, matching
    /// AnnotationStore's intake definition exactly.
    private func nestedBatch(depth: Int, leaf: AnnotationKind) -> AnnotationKind {
        precondition(depth >= 0)
        var kind = leaf
        for _ in 0..<depth {
            kind = .batch(items: [AnnotationComponent(kind: kind)])
        }
        return kind
    }

    func testClearVisibleReturnsLiveRemovalCountAndPreservesRemainder() {
        let store = AnnotationStore()
        store.add(annotation(id: "global", appId: nil))
        store.add(annotation(id: "finder", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal", appId: "com.apple.Terminal"))

        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 2)
        XCTAssertEqual(store.getAll().map(\.id), ["terminal"])
    }

    func testRemoveByIDPreservesPeerAnnotations() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: "com.apple.finder"))
        store.add(annotation(id: "target", appId: "com.apple.finder"))
        store.add(annotation(id: "third", appId: nil))

        XCTAssertTrue(store.remove(id: "target"))
        XCTAssertEqual(store.getAll().map(\.id), ["first", "third"])
    }

    func testGetByIDReturnsAnExactSnapshotWithoutChangingTheStore() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: nil))
        store.add(annotation(id: "target", appId: "com.apple.finder"))

        XCTAssertEqual(store.get(id: "target")?.id, "target")
        XCTAssertNil(store.get(id: "missing"))
        XCTAssertEqual(store.getAll().map(\.id), ["first", "target"])
    }

    // MARK: - Annotations persist until explicitly cleared (no more expiry)
    //
    // This store used to hold a TTL/expiry mechanism (`Annotation.expiresAt`
    // / `expiresAtUptime`, `AnnotationStore.sweepExpiredLocked`, and an
    // `asyncAfter` removal timer per timed annotation) that silently removed
    // an annotation once its deadline passed. The product decision is that
    // an annotation now persists until the AI or the user explicitly clears
    // it -- there is no duration argument left to accept, and nothing sweeps
    // a read path for "expired" entries any more. The tests below pin the
    // REPLACEMENT guarantee: an annotation added with no expiry-like
    // mechanism at all stays exactly where it was put, through every read
    // path that used to perform that sweep, until something explicitly
    // removes it.

    func testAnnotationSurvivesEveryReadPathThatUsedToSweepExpiredEntries() {
        let store = AnnotationStore()
        store.add(annotation(id: "persistent", appId: nil))

        // A real deadline-based sweep would have reaped this by now; the
        // sleep exists only to make that contrast concrete for a reader of
        // this test, not because any code here still races a clock.
        Thread.sleep(forTimeInterval: 0.05)

        // Every one of these methods routed through `withLiveAnnotations` /
        // `sweepExpiredLocked` before this change, so each one was a
        // separate opportunity for a "expired" annotation to silently
        // disappear. All must still report it.
        XCTAssertEqual(store.get(id: "persistent")?.id, "persistent")
        XCTAssertEqual(store.getAll().map(\.id), ["persistent"])
        XCTAssertEqual(store.getForScreen("1").map(\.id), ["persistent"])
        XCTAssertEqual(store.getForScreen("1", visibleForApp: nil).map(\.id), ["persistent"])
        XCTAssertTrue(store.hasVisibleAnnotations(forScreenId: "1", visibleForApp: nil))
        XCTAssertNotNil(store.renderSnapshot(id: "persistent"))
    }

    func testOnlyAnExplicitRemoveOrClearEverTakesAnAnnotationOutOfTheStore() {
        let store = AnnotationStore()
        store.add(annotation(id: "still-here", appId: nil))
        Thread.sleep(forTimeInterval: 0.05)

        // Nothing but an explicit mutation changes the count -- in
        // particular, plain reads (already exercised above) are not
        // mutations, and there is no background timer left to race.
        XCTAssertEqual(store.getAll().count, 1)

        XCTAssertTrue(store.remove(id: "still-here"), "an explicit remove is still how an annotation goes away")
        XCTAssertTrue(store.getAll().isEmpty)
    }

    func testClearVisibleWithNoAppRemovesGlobalsOnly() {
        let store = AnnotationStore()
        store.add(annotation(id: "global", appId: nil))
        store.add(annotation(id: "finder", appId: "com.apple.finder"))

        XCTAssertEqual(store.clearVisible(forApp: nil), 1)
        XCTAssertEqual(store.getAll().map(\.id), ["finder"])
    }

    func testVisibleFilterMatchesClearPredicateAndScreen() {
        let store = AnnotationStore()
        store.add(annotation(id: "global-1", appId: nil))
        store.add(annotation(id: "finder-1", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal-1", appId: "com.apple.Terminal"))
        store.add(annotation(id: "global-2", screen: "2", appId: nil))

        XCTAssertEqual(
            Set(store.getForScreen("1", visibleForApp: "com.apple.finder").map(\.id)),
            Set(["global-1", "finder-1"])
        )
        XCTAssertEqual(
            store.getForScreen("1", visibleForApp: nil).map(\.id),
            ["global-1"]
        )
    }

    func testEmptinessQueryAgreesWithTheFilteredArrayItAvoidsBuilding() {
        // `hasVisibleAnnotations` exists so the repaint path can answer "is
        // there anything to paint on this screen" without materialising and
        // sorting the array.
        //
        // The EXPECTED answer is written out by hand below, because both
        // queries delegate to the same `isVisible(_:onScreen:forApp:)`:
        // comparing them only against each other would agree just as happily on
        // a wrong visibility rule, and would pin nothing beyond "neither has
        // re-inlined its own filter". The agreement assertion is kept as that
        // secondary property.
        let store = AnnotationStore()
        store.add(annotation(id: "global-1", appId: nil))
        store.add(annotation(id: "finder-1", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal-2", screen: "2", appId: "com.apple.Terminal"))

        // Screen 1 holds the global annotation, which is visible under EVERY
        // active app (including none); screen 2 holds only a Terminal-tagged
        // annotation; screen 3 holds nothing at all.
        let expectations: [(screen: String, app: String?, visible: Bool)] = [
            ("1", nil, true),
            ("1", "com.apple.finder", true),
            ("1", "com.apple.Terminal", true),
            ("1", "com.apple.Safari", true),
            ("2", nil, false),
            ("2", "com.apple.finder", false),
            ("2", "com.apple.Terminal", true),
            ("2", "com.apple.Safari", false),
            ("3", nil, false),
            ("3", "com.apple.finder", false),
            ("3", "com.apple.Terminal", false),
            ("3", "com.apple.Safari", false),
        ]
        for expectation in expectations {
            let context = "screen \(expectation.screen) / app \(expectation.app ?? "nil")"
            XCTAssertEqual(
                store.hasVisibleAnnotations(forScreenId: expectation.screen, visibleForApp: expectation.app),
                expectation.visible,
                context
            )
            XCTAssertEqual(
                !store.getForScreen(expectation.screen, visibleForApp: expectation.app).isEmpty,
                expectation.visible,
                "\(context) -- the array the emptiness query avoids building must agree"
            )
        }
    }

    func testUpdatePreservesIdentityAndStableSlotWhileChangingPaintOrder() throws {
        let store = AnnotationStore()
        let first = annotation(id: "first", appId: nil)
        let second = annotation(id: "second", appId: nil)
        store.add(first)
        store.add(second)

        let changed = Annotation(
            id: first.id, screenId: first.screenId, kind: first.kind, colorHex: first.colorHex,
            label: first.label, appId: first.appId, appName: first.appName,
            opacity: 0.5, offsetX: 10, offsetY: 20, zIndex: 2, createdAt: first.createdAt
        )
        XCTAssertTrue(store.update(id: first.id, with: changed))
        let stored = try XCTUnwrap(store.get(id: first.id))
        XCTAssertEqual(stored.id, first.id)
        XCTAssertEqual(stored.createdAt, first.createdAt)
        XCTAssertEqual(stored.offsetX, 10)
        XCTAssertEqual(stored.opacity, 0.5)
        XCTAssertEqual(store.getForScreen("1", visibleForApp: nil).map(\.id), ["second", "first"])
    }

    func testStaleRevisionCannotOverwriteANewerInPlaceUpdate() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        let firstSnapshot = try XCTUnwrap(store.get(id: initial.id))
        let staleSnapshot = try XCTUnwrap(store.get(id: initial.id))

        let newer = Annotation(
            id: firstSnapshot.id, screenId: firstSnapshot.screenId, kind: firstSnapshot.kind,
            colorHex: firstSnapshot.colorHex, label: firstSnapshot.label,
            appId: firstSnapshot.appId, appName: firstSnapshot.appName,
            opacity: 0.8, offsetX: 10, offsetY: 0,
            zIndex: firstSnapshot.zIndex, createdAt: firstSnapshot.createdAt
        )
        XCTAssertEqual(
            store.updateWithOutcome(id: initial.id, with: newer, expectedRevision: firstSnapshot.revision),
            .updated
        )

        let staleReplacement = Annotation(
            id: staleSnapshot.id, screenId: staleSnapshot.screenId, kind: staleSnapshot.kind,
            colorHex: staleSnapshot.colorHex, label: staleSnapshot.label,
            appId: staleSnapshot.appId, appName: staleSnapshot.appName,
            opacity: 0.4, offsetX: 99, offsetY: 0,
            zIndex: staleSnapshot.zIndex, createdAt: staleSnapshot.createdAt
        )
        XCTAssertEqual(
            store.updateWithOutcome(id: initial.id, with: staleReplacement, expectedRevision: staleSnapshot.revision),
            .stale
        )
        let retained = try XCTUnwrap(store.get(id: initial.id))
        XCTAssertEqual(retained.offsetX, 10)
        XCTAssertEqual(retained.opacity, 0.8)
        XCTAssertGreaterThan(retained.revision, staleSnapshot.revision)
    }

    func testUpdatePreservesTheSelectedAnnotationIdentity() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "stable-id", appId: nil)
        store.add(initial)

        let replacement = Annotation(
            id: "unexpected-replacement-id",
            screenId: initial.screenId,
            kind: .text(text: "updated", x: 0, y: 0, fontSize: 12,
                        textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1)
        )

        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: replacement), .updated)
        XCTAssertEqual(try XCTUnwrap(store.get(id: initial.id)).kind.typeName, "text")
        XCTAssertNil(store.get(id: replacement.id))
    }

    func testAggregatePayloadBudgetRejectsWithoutEvictingOrInserting() {
        let store = AnnotationStore()
        let halfBudgetPlusMargin = DrawingDefaults.maxRetainedAnnotationPayloadBytes / 2 + 4_096
        let first = Annotation(
            id: "first-large", screenId: "1",
            kind: .text(text: String(repeating: "a", count: halfBudgetPlusMargin), x: 0, y: 0,
                        fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1)
        )
        let second = Annotation(
            id: "second-large", screenId: "1",
            kind: .vectorPath(data: String(repeating: "M0 0 L1 1 ", count: halfBudgetPlusMargin / 10 + 1),
                              strokeColorHex: "#FFFFFF", strokeWidth: 1, strokeOpacity: 1,
                              fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                              coordinateScaleX: 1, coordinateScaleY: 1)
        )

        guard case .added = store.addWithOutcome(first) else {
            return XCTFail("first annotation should fit the aggregate payload budget")
        }
        let before = store.getAll().map(\.id)
        let outcome = store.addWithOutcome(second)
        guard case .rejected(.payloadBytes(let limit, let attempted)) = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxRetainedAnnotationPayloadBytes)
        XCTAssertGreaterThan(attempted, limit)
        XCTAssertEqual(store.getAll().map(\.id), before)
        XCTAssertLessThanOrEqual(store.retainedResourceUsage.payloadBytes, limit)
    }

    func testAggregateBudgetRejectsUpdateAndLeavesExistingAnnotationUntouched() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        let oversized = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: .text(text: String(repeating: "x", count: DrawingDefaults.maxRetainedAnnotationPayloadBytes),
                        x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            createdAt: initial.createdAt
        )

        let outcome = store.updateWithOutcome(id: initial.id, with: oversized)
        guard case .rejected(.payloadBytes) = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }
        let stored = try XCTUnwrap(store.get(id: initial.id))
        XCTAssertEqual(stored.kind.typeName, "path")
        XCTAssertEqual(stored.createdAt, initial.createdAt)
    }

    func testBatchChildrenCountTowardAggregatePrimitiveBudget() {
        let store = AnnotationStore()
        let component = AnnotationComponent(kind: .vectorPath(
            data: "M0 0 L1 1", strokeColorHex: "#FFFFFF", strokeWidth: 1, strokeOpacity: 1,
            fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
            coordinateScaleX: 1, coordinateScaleY: 1
        ))
        let oversizedBatch = Annotation(
            id: "oversized-batch", screenId: "1",
            kind: .batch(items: Array(repeating: component, count: DrawingDefaults.maxRetainedAnnotationPrimitives + 1))
        )

        let outcome = store.addWithOutcome(oversizedBatch)
        guard case .rejected(.primitiveCount(let limit, let attempted)) = outcome else {
            return XCTFail("expected primitive-budget rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxRetainedAnnotationPrimitives)
        XCTAssertEqual(attempted, DrawingDefaults.maxRetainedAnnotationPrimitives + 1)
        XCTAssertTrue(store.getAll().isEmpty)
    }

    func testBatchNestingAtSafetyLimitIsStoredAndCodable() throws {
        let store = AnnotationStore()
        let candidate = Annotation(
            id: "deep-but-safe", screenId: "1",
            kind: nestedBatch(
                depth: DrawingDefaults.maxAnnotationBatchNestingDepth,
                leaf: annotation(id: "leaf", appId: nil).kind
            )
        )

        XCTAssertEqual(store.addWithOutcome(candidate), .added)
        let stored = try XCTUnwrap(store.get(id: candidate.id))
        XCTAssertNoThrow(try JSONEncoder().encode(stored),
                          "the store cap keeps public Codable/list exposure safely bounded")
        XCTAssertEqual(
            store.retainedResourceUsage.primitiveCount,
            DrawingDefaults.maxAnnotationBatchNestingDepth,
            "one direct/nested component remains one work unit, preserving ordinary batch accounting"
        )
    }

    func testOverdeepBatchAddIsRejectedWithoutMutationOrStackGrowth() {
        let store = AnnotationStore()
        let existing = annotation(id: "existing", appId: nil)
        XCTAssertEqual(store.addWithOutcome(existing), .added)
        let beforeUsage = store.retainedResourceUsage

        // Much deeper than the cap proves the iterative intake walk rejects a
        // programmatic tree before recursive renderer/Codable paths can see it.
        // The separate iterative asset traversal must be just as defensive,
        // because cleanup code can receive a rejected caller-owned candidate.
        //
        // Kept well under ~2,475 on purpose. Nothing this test exercises walks
        // the tree recursively, but the deinit the compiler synthesizes for the
        // `.batch([AnnotationComponent])` chain does, and it runs when this
        // tree is released -- overflowing Windows' default 1 MB thread stack
        // past roughly that depth, which macOS's 8 MB main thread hides. The
        // depth only has to dwarf the cap, and 1,024 is 16x it; no client can
        // reach even that, since Foundation's JSON parser rejects beyond ~126
        // nested objects and the store caps retained trees at 64.
        let deepRasterTree = nestedBatch(
            depth: 1_024,
            leaf: .image(assetId: "unretained-deep-raster", x: 0, y: 0, width: 1, height: 1,
                         rotationDegrees: 0, opacity: 1)
        )
        XCTAssertEqual(deepRasterTree.rasterAssetIds, ["unretained-deep-raster"])
        let candidate = Annotation(
            id: "too-deep", screenId: "1",
            kind: deepRasterTree
        )
        let outcome = store.addWithOutcome(candidate)
        guard case .rejected(.batchNestingDepth(let limit, let attempted)) = outcome else {
            return XCTFail("expected nesting-depth rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxAnnotationBatchNestingDepth)
        XCTAssertEqual(attempted, DrawingDefaults.maxAnnotationBatchNestingDepth + 1)
        XCTAssertEqual(store.getAll().map(\.id), [existing.id])
        XCTAssertEqual(store.retainedResourceUsage, beforeUsage)
    }

    func testOverdeepBatchUpdateIsRejectedAndKeepsExistingRasterOwnership() throws {
        let store = AnnotationStore()
        let initial = try rasterBackedAnnotation(id: "raster-target")
        let assetID = try XCTUnwrap(initial.kind.rasterAssetIds.first)
        XCTAssertEqual(store.addWithOutcome(initial), .added)

        let replacement = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: nestedBatch(depth: DrawingDefaults.maxAnnotationBatchNestingDepth + 1, leaf: initial.kind),
            createdAt: initial.createdAt
        )
        let outcome = store.updateWithOutcome(id: initial.id, with: replacement)
        guard case .rejected(.batchNestingDepth(let limit, let attempted)) = outcome else {
            return XCTFail("expected nesting-depth rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxAnnotationBatchNestingDepth)
        XCTAssertEqual(attempted, DrawingDefaults.maxAnnotationBatchNestingDepth + 1)
        XCTAssertEqual(store.get(id: initial.id)?.kind.typeName, "image")
        XCTAssertNotNil(RasterAssetStore.shared.descriptor(for: assetID),
                        "a rejected replacement must not release the raster still owned by the old annotation")

        XCTAssertEqual(store.clearAll(), 1)
        XCTAssertNil(RasterAssetStore.shared.descriptor(for: assetID),
                     "the original raster remains owned until its stored annotation is explicitly removed")
    }

    func testNestedEmptyBatchComponentsCountTowardRetainedWorkBudget() {
        let store = AnnotationStore()
        let emptyBatch = AnnotationKind.batch(items: [])
        let nestedEmpty = AnnotationKind.batch(items: Array(
            repeating: AnnotationComponent(kind: emptyBatch),
            count: DrawingDefaults.maxBatchItems
        ))
        let broadTree = Annotation(
            id: "broad-empty-tree", screenId: "1",
            kind: .batch(items: Array(
                repeating: AnnotationComponent(kind: nestedEmpty),
                count: DrawingDefaults.maxBatchItems
            ))
        )

        let outcome = store.addWithOutcome(broadTree)
        guard case .rejected(.primitiveCount(let limit, let attempted)) = outcome else {
            return XCTFail("expected retained-work rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxRetainedAnnotationPrimitives)
        XCTAssertEqual(attempted, DrawingDefaults.maxBatchItems * (DrawingDefaults.maxBatchItems + 1))
        XCTAssertTrue(store.getAll().isEmpty,
                      "container-only trees must not bypass the aggregate work cap")
    }

    // MARK: - Incremental running-total accounting
    //
    // `AnnotationStore` used to recompute `retainedResourceUsage` from
    // scratch (walking every stored annotation, recursively for batches) on
    // every add/update. It now maintains a running total incrementally and
    // only falls back to a full recompute as a DEBUG-only invariant check
    // (`assertResourceUsageConsistent`, which fires automatically on every
    // mutation these tests perform) plus the `fullRecomputeResourceUsageForTesting()`
    // hook these tests call explicitly. Every test below asserts
    // `retainedResourceUsage` (the incremental total) equals
    // `fullRecomputeResourceUsageForTesting()` (an independent from-scratch
    // recompute) after the mutation under test.

    func testRunningResourceUsageMatchesFullRecomputeAfterAdds() {
        let store = AnnotationStore()
        store.add(annotation(id: "a", appId: nil))
        store.add(annotation(id: "b", appId: "com.apple.finder"))
        store.add(annotation(id: "c", appId: "com.apple.Terminal"))

        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 3)
        XCTAssertGreaterThan(store.retainedResourceUsage.payloadBytes, 0)
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterUpdate() {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        store.add(annotation(id: "other", appId: "com.apple.finder"))

        let replacement = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: .text(text: "a fairly different payload than the original path", x: 0, y: 0,
                        fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            createdAt: initial.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: replacement), .updated)

        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRejectedAddLeavesRunningResourceUsageExactlyUnchanged() {
        let store = AnnotationStore()
        let halfBudgetPlusMargin = DrawingDefaults.maxRetainedAnnotationPayloadBytes / 2 + 4_096
        let first = Annotation(
            id: "first-large", screenId: "1",
            kind: .text(text: String(repeating: "a", count: halfBudgetPlusMargin), x: 0, y: 0,
                        fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1)
        )
        let second = Annotation(
            id: "second-large", screenId: "1",
            kind: .vectorPath(data: String(repeating: "M0 0 L1 1 ", count: halfBudgetPlusMargin / 10 + 1),
                              strokeColorHex: "#FFFFFF", strokeWidth: 1, strokeOpacity: 1,
                              fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                              coordinateScaleX: 1, coordinateScaleY: 1)
        )
        guard case .added = store.addWithOutcome(first) else {
            return XCTFail("first annotation should fit the aggregate payload budget")
        }

        let before = store.retainedResourceUsage
        let outcome = store.addWithOutcome(second)
        guard case .rejected = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }

        XCTAssertEqual(store.retainedResourceUsage, before)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRejectedUpdateLeavesRunningResourceUsageExactlyUnchanged() {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        store.add(annotation(id: "bystander", appId: "com.apple.finder"))
        let oversized = Annotation(
            id: initial.id, screenId: initial.screenId,
            kind: .text(text: String(repeating: "x", count: DrawingDefaults.maxRetainedAnnotationPayloadBytes),
                        x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF", backgroundColorHex: nil,
                        backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            createdAt: initial.createdAt
        )

        let before = store.retainedResourceUsage
        let outcome = store.updateWithOutcome(id: initial.id, with: oversized)
        guard case .rejected = outcome else {
            return XCTFail("expected payload-budget rejection, got \(outcome)")
        }

        XCTAssertEqual(store.retainedResourceUsage, before)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterRemove() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: nil))
        store.add(annotation(id: "second", appId: "com.apple.finder"))

        XCTAssertTrue(store.remove(id: "first"))

        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 1)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageIsZeroAfterClearAllAndMatchesFullRecompute() {
        let store = AnnotationStore()
        store.add(annotation(id: "first", appId: nil))
        store.add(annotation(id: "second", appId: "com.apple.finder"))

        XCTAssertEqual(store.clearAll(), 2)

        XCTAssertEqual(store.retainedResourceUsage, AnnotationStoreResourceUsage(payloadBytes: 0, primitiveCount: 0))
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    func testRunningResourceUsageMatchesFullRecomputeAfterClearVisible() {
        let store = AnnotationStore()
        store.add(annotation(id: "global", appId: nil))
        store.add(annotation(id: "finder", appId: "com.apple.finder"))
        store.add(annotation(id: "terminal", appId: "com.apple.Terminal"))

        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 2)

        XCTAssertEqual(store.retainedResourceUsage.primitiveCount, 1)
        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    /// One annotation with EVERY top-level optional string field populated and
    /// one with all of them nil.
    ///
    /// Deliberately no longer a tour of every `AnnotationKind`: the two
    /// `resourceUsage` overloads duplicate only the six top-level
    /// `addPayload(&usage, annotation.<field>)` lines and then both delegate
    /// the kind walk to the SAME `addKindUsage`, so a fixture of nested batches
    /// and mixed kinds reads like coverage while being unable to fail -- both
    /// sides of the comparison walk it through the identical function.
    private func topLevelFieldAnnotations() -> [Annotation] {
        [
            Annotation(
                id: "path-every-field", screenId: "1",
                kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: "#112233",
                                  strokeWidth: 2, strokeOpacity: 1, fillColorHex: "#445566", fillOpacity: 0.5,
                                  dash: [2, 3], usesEvenOddFillRule: true, coordinateScaleX: 1, coordinateScaleY: 1),
                colorHex: "#778899", label: "path label",
                appId: "com.apple.finder", appName: "Finder"
            ),
            // Optional fields all nil: both implementations must skip them
            // identically rather than one of them counting something.
            Annotation(
                id: "path-no-optional-fields", screenId: "1",
                kind: .vectorPath(data: "M0 0 L1 1", strokeColorHex: nil, strokeWidth: 1, strokeOpacity: 1,
                                  fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
                                  coordinateScaleX: 1, coordinateScaleY: 1)
            )
        ]
    }

    /// `AnnotationStore.resourceUsage(of:)` exists in two forms: the array
    /// version, which is the oracle `assertResourceUsageConsistent` (and
    /// `fullRecomputeResourceUsageForTesting`) checks against, and the
    /// single-annotation version the incremental running total is built from.
    ///
    /// Only the six top-level field lines are genuinely duplicated between
    /// them, and only those can this test discriminate: editing one copy and
    /// forgetting the other would otherwise silently disable the invariant
    /// check instead of failing. The kind walk is SHARED (`addKindUsage`) by
    /// design, so no kind-accounting mistake can be caught here -- it would be
    /// made identically on both sides. This claims exactly the first property
    /// and no more.
    func testFullRecomputeEqualsSumOfPerAnnotationUsage() {
        let annotations = topLevelFieldAnnotations()

        // Each per-annotation figure comes from a store holding exactly one
        // annotation, whose running total is by construction the
        // SINGLE-annotation implementation; the combined store's
        // `fullRecomputeResourceUsageForTesting()` is the ARRAY one. Summing
        // the former and comparing with the latter is what ties the two
        // copies together.
        var summed = AnnotationStoreResourceUsage(payloadBytes: 0, primitiveCount: 0)
        for annotation in annotations {
            let isolated = AnnotationStore()
            isolated.add(annotation)
            let usage = isolated.retainedResourceUsage
            summed = AnnotationStoreResourceUsage(
                payloadBytes: summed.payloadBytes + usage.payloadBytes,
                primitiveCount: summed.primitiveCount + usage.primitiveCount
            )
        }

        let combined = AnnotationStore()
        for annotation in annotations { combined.add(annotation) }

        XCTAssertEqual(combined.fullRecomputeResourceUsageForTesting(), summed)
        XCTAssertEqual(combined.retainedResourceUsage, summed)
        XCTAssertGreaterThan(summed.payloadBytes, 0)
        XCTAssertEqual(summed.primitiveCount, 2, "one primitive per path annotation")
    }

    func testRunningResourceUsageMatchesFullRecomputeAcrossMixedOperations() {
        let store = AnnotationStore()
        for i in 0..<25 {
            store.add(annotation(id: "seed-\(i)", appId: i.isMultiple(of: 2) ? nil : "com.apple.finder"))
        }
        XCTAssertTrue(store.remove(id: "seed-3"))
        XCTAssertGreaterThan(store.clearVisible(forApp: "com.apple.finder"), 0)
        store.add(annotation(id: "post-clear", appId: "com.apple.Terminal"))
        let replacement = Annotation(
            id: "post-clear", screenId: "1",
            kind: .text(text: "replacement payload", x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF",
                        backgroundColorHex: nil, backgroundOpacity: 0, paddingPx: 0, opacity: 1)
        )
        XCTAssertEqual(store.updateWithOutcome(id: "post-clear", with: replacement), .updated)

        XCTAssertEqual(store.retainedResourceUsage, store.fullRecomputeResourceUsageForTesting())
    }

    // MARK: - clearAll / clearVisible still remove annotations and release raster assets
    //
    // Deleting the expiry mechanism did not touch raster ownership: an
    // `.image`-kind (or batch containing one) annotation still leases a
    // decoded bitmap out of `RasterAssetStore.shared` for as long as it is
    // stored, and `AnnotationStore.releaseRasterAssets` still must run on
    // every path that actually removes an annotation. These tests follow the
    // same before/after `RasterAssetStore.shared.image(id:)` pattern
    // `RasterAssetStoreTests.testAnnotationRenderSnapshotClosesLookupToClearRace`
    // already uses for `remove(id:)`, extended to the two clear methods.

    func testClearAllRemovesAnnotationsAndReleasesTheirRasterAssets() throws {
        let store = AnnotationStore()
        let raster = try rasterBackedAnnotation(id: "raster-global")
        guard case .image(let assetId, _, _, _, _, _, _) = raster.kind else {
            return XCTFail("fixture must be an image-kind annotation")
        }
        store.add(raster)
        store.add(annotation(id: "vector-global", appId: nil))
        XCTAssertNotNil(RasterAssetStore.shared.image(id: assetId), "sanity: the asset must be loaded before clearAll")

        XCTAssertEqual(store.clearAll(), 2)

        XCTAssertTrue(store.getAll().isEmpty)
        XCTAssertNil(RasterAssetStore.shared.image(id: assetId),
                     "clearAll must release raster assets owned by every annotation it removes")
    }

    func testClearVisibleRemovesMatchingAnnotationsAndReleasesOnlyTheirRasterAssets() throws {
        let store = AnnotationStore()
        let clearedRaster = try rasterBackedAnnotation(id: "cleared-raster")
        guard case .image(let clearedAssetId, _, _, _, _, _, _) = clearedRaster.kind else {
            return XCTFail("fixture must be an image-kind annotation")
        }
        let clearedForFinder = Annotation(
            id: clearedRaster.id, screenId: clearedRaster.screenId, kind: clearedRaster.kind,
            appId: "com.apple.finder", appName: "Finder"
        )
        let survivingRaster = try rasterBackedAnnotation(id: "surviving-raster")
        guard case .image(let survivingAssetId, _, _, _, _, _, _) = survivingRaster.kind else {
            return XCTFail("fixture must be an image-kind annotation")
        }
        let survivingForTerminal = Annotation(
            id: survivingRaster.id, screenId: survivingRaster.screenId, kind: survivingRaster.kind,
            appId: "com.apple.Terminal", appName: "Terminal"
        )

        store.add(clearedForFinder)
        store.add(survivingForTerminal)

        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 1)

        XCTAssertEqual(store.getAll().map(\.id), ["surviving-raster"])
        XCTAssertNil(RasterAssetStore.shared.image(id: clearedAssetId),
                     "clearVisible must release the raster asset of the annotation it actually removed")
        XCTAssertNotNil(RasterAssetStore.shared.image(id: survivingAssetId),
                        "clearVisible must NOT release a raster asset still owned by a surviving annotation")

        // Clean up the surviving asset so this test does not leak into the
        // shared store's accounting for any test that runs after it.
        _ = store.clearAll()
        XCTAssertNil(RasterAssetStore.shared.image(id: survivingAssetId))
    }

    // MARK: - Count cap rejects rather than evicts (new guarantee)

    /// Old behaviour (now deleted): once the store held
    /// `DrawingDefaults.maxStoredAnnotations`, the OLDEST annotation was
    /// silently evicted to make room for a new insertion -- a second, silent
    /// way for a drawing to disappear, alongside the deleted TTL/expiry
    /// mechanism. It now REJECTS the new insertion outright and changes
    /// nothing already stored. `AnnotationStoreConcurrencyTests` exercises
    /// this across the full cap and every rejected attempt past it; this
    /// pins the same guarantee with the two assertions that matter most: the
    /// specific rejection reason, and that the store's count and existing
    /// contents did not move.
    func testCountCapRejectsInsteadOfEvictingAndLeavesPriorAnnotationsIntact() {
        let store = AnnotationStore()
        for i in 0..<DrawingDefaults.maxStoredAnnotations {
            store.add(annotation(id: "cap-\(i)", appId: nil))
        }
        let idsBeforeRejectedAttempt = store.getAll().map(\.id)
        XCTAssertEqual(idsBeforeRejectedAttempt.count, DrawingDefaults.maxStoredAnnotations)

        let outcome = store.addWithOutcome(annotation(id: "one-too-many", appId: nil))
        guard case .rejected(.annotationCount(let limit, let attempted)) = outcome else {
            return XCTFail("expected an annotationCount rejection, got \(outcome)")
        }
        XCTAssertEqual(limit, DrawingDefaults.maxStoredAnnotations)
        XCTAssertEqual(attempted, DrawingDefaults.maxStoredAnnotations + 1)

        XCTAssertEqual(store.getAll().map(\.id), idsBeforeRejectedAttempt,
                       "a rejected insertion must not change the store's count OR evict any existing annotation")
        XCTAssertNil(store.get(id: "one-too-many"), "the rejected annotation must not have been stored")
    }

    // MARK: - Window anchoring
    //
    // `Annotation.effectiveScreenId`/`effectiveAdjustment`/`anchorPermitsPainting`
    // let an anchored annotation follow its target window onto a different
    // display and stop being PAINTED while that window is hidden or lost,
    // without ever being removed from the store (the design contract's
    // "no auto-clear" invariant survives anchoring intact). The tests below
    // pin the store-side half of that contract:
    //   * `isVisible`/`getForScreen` must read the EFFECTIVE screen and
    //     painting permission, not the stored ones a window may have long
    //     since moved away from.
    //   * `update` must carry the tracker's last sampled projection forward
    //     from the EXISTING annotation through an unrelated restyle, while
    //     still replacing `anchor`/`staticAdjustment` wholesale from the
    //     replacement, exactly like every other caller-supplied property.
    //   * `applyAnchorProjections` must write only what actually changed,
    //     notify at most once per call, and never touch `revision` -- a
    //     tracker tick is not a caller edit and must not invalidate a
    //     caller's compare-and-swap token.
    //   * `onAnchoredSetChanged` must fire exactly when the SET of anchored
    //     ids changes (an id gaining or losing an anchor), never for a
    //     projection-only refresh or a same-anchored-ness update.

    private func windowAnchor(
        windowId: UInt64 = 1,
        referenceScreenId: String = "1",
        resize: AnchorResizeBehavior = .pin
    ) -> AnnotationAnchor {
        AnnotationAnchor(
            mode: .window,
            resize: resize,
            target: AnchorWindowTarget(processId: 100, windowId: windowId, appId: "com.example.target"),
            referenceWindowFrame: AnchorRect(x: 0, y: 0, width: 200, height: 100),
            referenceScreenId: referenceScreenId
        )
    }

    private func anchorProjection(
        state: AnchorTrackingState = .tracking,
        adjustment: AnchorAdjustment = .identity,
        effectiveScreenId: String = "1"
    ) -> AnchorProjection {
        AnchorProjection(
            state: state,
            adjustment: adjustment,
            effectiveScreenId: effectiveScreenId,
            currentWindowFrame: AnchorRect(x: 0, y: 0, width: 200, height: 100),
            sampledAt: Date()
        )
    }

    /// An annotation anchored to a window, with an already-sampled
    /// projection -- the state the design contract says a "real" anchor is
    /// never observed without (the store installs an identity projection in
    /// the same update that creates the anchor; a bare `anchor` with no
    /// projection is covered separately below).
    private func anchoredAnnotation(id: String, screen: String = "1", appId: String? = nil, projection: AnchorProjection) -> Annotation {
        Annotation(
            id: id,
            screenId: screen,
            kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1),
            appId: appId,
            appName: appId,
            anchor: windowAnchor(referenceScreenId: screen),
            anchorProjection: projection
        )
    }

    func testIsVisibleComparesEffectiveScreenIdNotStoredScreenId() {
        let store = AnnotationStore()
        let movedToScreen2 = anchoredAnnotation(id: "moved", screen: "1", projection: anchorProjection(effectiveScreenId: "2"))
        store.add(movedToScreen2)

        XCTAssertFalse(store.getForScreen("1", visibleForApp: nil).map(\.id).contains("moved"),
                       "the annotation's ORIGINAL screen must no longer see it once its window has moved off it")
        XCTAssertEqual(store.getForScreen("2", visibleForApp: nil).map(\.id), ["moved"],
                       "the window's CURRENT display is where an anchored annotation must paint")
        XCTAssertTrue(store.hasVisibleAnnotations(forScreenId: "2", visibleForApp: nil))
        XCTAssertFalse(store.hasVisibleAnnotations(forScreenId: "1", visibleForApp: nil))
    }

    func testHiddenOrLostAnchorSuppressesPaintingButLeavesTheAnnotationFullyStored() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "hidden-window", projection: anchorProjection(state: .hidden)))
        store.add(anchoredAnnotation(id: "lost-window", projection: anchorProjection(state: .lost)))

        XCTAssertTrue(store.getForScreen("1", visibleForApp: nil).isEmpty,
                      "a hidden or lost anchor must not be painted")
        XCTAssertFalse(store.hasVisibleAnnotations(forScreenId: "1", visibleForApp: nil))

        // "No auto-clear": both annotations remain fully present and listable.
        XCTAssertEqual(Set(store.getAll().map(\.id)), Set(["hidden-window", "lost-window"]))
        XCTAssertNotNil(store.get(id: "hidden-window"))
        XCTAssertNotNil(store.get(id: "lost-window"))
    }

    func testAnAnchorWithNoProjectionYetPermitsPaintingAtItsStoredScreen() {
        // The tracker has not ticked since the anchor was created -- the
        // store must fail OPEN (paint at the stored screen), not treat
        // "not yet sampled" as "suppressed".
        let store = AnnotationStore()
        store.add(Annotation(
            id: "just-anchored", screenId: "1",
            kind: .vectorPath(data: "M0 0 L10 10", strokeColorHex: nil, strokeWidth: 2, strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1),
            anchor: windowAnchor()
        ))

        XCTAssertEqual(store.getForScreen("1", visibleForApp: nil).map(\.id), ["just-anchored"])
    }

    func testCaptureDebugGetForScreenAlsoUsesEffectiveScreenId() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "moved", screen: "1", projection: anchorProjection(effectiveScreenId: "2")))

        // The capture-debug overload skips per-app filtering, but must still
        // resolve the annotation onto the display it is CURRENTLY on --
        // otherwise capture-debug mode paints an anchored annotation on the
        // display it left instead of the one it is actually on.
        XCTAssertEqual(store.getForScreen("2").map(\.id), ["moved"])
        XCTAssertTrue(store.getForScreen("1").isEmpty)
    }

    // MARK: - Capture-debug overload also honors anchorPermitsPainting
    //
    // `getForScreen(_:)` (no `visibleForApp:`) exists specifically to bypass
    // the per-app filter for capture-debug mode -- see its doc comment. It
    // now ALSO filters on `anchorPermitsPainting`, for a different reason
    // than the app filter it deliberately skips: a `hidden`/`lost` anchor
    // means the window this drawing is pinned to is minimised, on another
    // Space, or gone, so its stored coordinates point at unrelated content.
    // Painting it into the very capture-debug frame an agent uses to verify
    // placement would be worse than leaving it out. The tests below pin
    // that this new gate (a) actually suppresses painting for `.hidden`/
    // `.lost`, (b) never makes suppression look like deletion, and (c) did
    // not accidentally reintroduce the app filtering this overload exists to
    // skip.

    func testCaptureDebugGetForScreenPaintsTrackingButNotHiddenOrLostAnchoredAnnotations() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "tracking", projection: anchorProjection(state: .tracking)))
        store.add(anchoredAnnotation(id: "hidden", projection: anchorProjection(state: .hidden)))
        store.add(anchoredAnnotation(id: "lost", projection: anchorProjection(state: .lost)))

        XCTAssertEqual(
            store.getForScreen("1").map(\.id), ["tracking"],
            "a hidden or lost anchor must not be painted even in capture-debug mode, which otherwise bypasses the app filter"
        )

        // Suppression from painting must never look like removal from the
        // store: "a drawing persists until explicitly cleared" is a
        // documented product guarantee (see `ClearScope`'s doc comment), and
        // it must hold for this new gate exactly as it already does for the
        // ordinary `hasVisibleAnnotations`/`getForScreen(_:visibleForApp:)`
        // path.
        XCTAssertEqual(Set(store.getAll().map(\.id)), Set(["tracking", "hidden", "lost"]))
        XCTAssertNotNil(store.get(id: "tracking"))
        XCTAssertNotNil(store.get(id: "hidden"))
        XCTAssertNotNil(store.get(id: "lost"))
    }

    func testCaptureDebugGetForScreenStillIgnoresAppFilterForATrackingAnchoredAnnotation() {
        let store = AnnotationStore()
        let nonFrontmostApp = "com.apple.finder"
        store.add(anchoredAnnotation(id: "finder-anchored", appId: nonFrontmostApp, projection: anchorProjection(state: .tracking)))

        // Sanity: the app-filtered overload, told a DIFFERENT app is
        // frontmost, hides this annotation -- that is the very behavior
        // capture-debug mode exists to bypass.
        XCTAssertTrue(store.getForScreen("1", visibleForApp: "com.apple.Terminal").isEmpty)

        // The new anchor gate must be layered ON TOP of "no app filtering",
        // not a reintroduction of it: a correctly-placed, `.tracking`
        // annotation belonging to a non-frontmost app must still show up
        // here. Losing this would silently break capture-debug mode.
        XCTAssertEqual(store.getForScreen("1").map(\.id), ["finder-anchored"])
    }

    func testUpdateReplacesAnchorAndStaticAdjustmentWholesaleFromTheReplacement() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)

        let newAnchor = windowAnchor(windowId: 42)
        let newStaticAdjustment = AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 5, translateY: 7)
        let replacement = Annotation(
            id: initial.id, screenId: initial.screenId, kind: initial.kind,
            appId: initial.appId, appName: initial.appName,
            anchor: newAnchor, staticAdjustment: newStaticAdjustment,
            createdAt: initial.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: replacement), .updated)

        let stored = try XCTUnwrap(store.get(id: initial.id))
        XCTAssertEqual(stored.anchor, newAnchor)
        XCTAssertEqual(stored.staticAdjustment, newStaticAdjustment)
    }

    func testUpdateCarriesTheExistingAnnotationsAnchorProjectionForwardIgnoringTheReplacements() throws {
        let store = AnnotationStore()
        let liveProjection = anchorProjection(
            state: .tracking,
            adjustment: AnchorAdjustment(scaleX: 1.5, scaleY: 1.5, translateX: 3, translateY: 4)
        )
        let initial = anchoredAnnotation(id: "tracked", projection: liveProjection)
        store.add(initial)

        // Built the way an unrelated MCP restyle would be -- a new opacity,
        // the SAME anchor -- and carrying no projection of its own (the
        // default `nil`). If projection carry-over lived anywhere but the
        // store, this update would silently reset live tracking back to
        // "never sampled".
        let replacement = Annotation(
            id: initial.id, screenId: initial.screenId, kind: initial.kind,
            appId: initial.appId, appName: initial.appName, opacity: 0.4,
            anchor: initial.anchor, staticAdjustment: initial.staticAdjustment,
            createdAt: initial.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: replacement), .updated)

        let stored = try XCTUnwrap(store.get(id: initial.id))
        XCTAssertEqual(stored.anchorProjection, liveProjection,
                       "an unrelated restyle must not reset the tracker's last sampled projection")
        XCTAssertEqual(stored.opacity, 0.4, "the restyle itself must still take effect")
    }

    func testApplyAnchorProjectionsWritesOnlyDifferingAnnotationsAndReportsWhetherAnythingChanged() throws {
        let store = AnnotationStore()
        let unchangedProjection = anchorProjection(effectiveScreenId: "1")
        store.add(anchoredAnnotation(id: "unchanged", projection: unchangedProjection))
        store.add(anchoredAnnotation(id: "moves", projection: anchorProjection(effectiveScreenId: "1")))

        let freshProjection = anchorProjection(effectiveScreenId: "2")
        let outcome = store.applyAnchorProjections([
            "unchanged": unchangedProjection,     // identical -- must not be rewritten
            "moves": freshProjection,             // differs -- must be written
            "no-such-annotation": freshProjection // must be silently ignored
        ])

        XCTAssertTrue(outcome)
        XCTAssertEqual(try XCTUnwrap(store.get(id: "unchanged")).anchorProjection, unchangedProjection)
        XCTAssertEqual(try XCTUnwrap(store.get(id: "moves")).anchorProjection, freshProjection)
    }

    func testApplyAnchorProjectionsReturnsFalseWhenEveryProjectionAlreadyMatches() {
        let store = AnnotationStore()
        let current = anchorProjection()
        store.add(anchoredAnnotation(id: "steady", projection: current))

        XCTAssertFalse(store.applyAnchorProjections(["steady": current]))
    }

    func testApplyAnchorProjectionsNeverBumpsRevision() throws {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "tracked", projection: anchorProjection(effectiveScreenId: "1")))
        let revisionBefore = try XCTUnwrap(store.get(id: "tracked")).revision

        XCTAssertTrue(store.applyAnchorProjections(["tracked": anchorProjection(effectiveScreenId: "2")]))

        let revisionAfter = try XCTUnwrap(store.get(id: "tracked")).revision
        XCTAssertEqual(revisionAfter, revisionBefore,
                       "a tracker refresh must not invalidate a caller's expectedRevision compare-and-swap token")
    }

    func testApplyAnchorProjectionsNotifiesExactlyOnceForABatchOfChanges() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "first", projection: anchorProjection(effectiveScreenId: "1")))
        store.add(anchoredAnnotation(id: "second", projection: anchorProjection(effectiveScreenId: "1")))

        // Drain the two adds' own pending `notifyChange()` calls BEFORE
        // attaching the listener below. `MainThread.enqueue` captures
        // `[weak self]`, not the callback itself, so each pending block
        // resolves `self?.onStoreChanged` at EXECUTION time -- if left
        // queued, both would run only once the listener below is attached
        // and be miscounted as notifications from the call under test.
        // `onStoreChanged` is still nil here, so draining now is a no-op.
        let setupDrained = expectation(description: "setup notifications drained")
        DispatchQueue.main.async { setupDrained.fulfill() }
        wait(for: [setupDrained], timeout: 2)

        var notifyCount = 0
        let notified = expectation(description: "store change notified")
        store.onStoreChanged = {
            notifyCount += 1
            notified.fulfill()
        }

        XCTAssertTrue(store.applyAnchorProjections([
            "first": anchorProjection(effectiveScreenId: "2"),
            "second": anchorProjection(effectiveScreenId: "2")
        ]))
        wait(for: [notified], timeout: 2)

        // Drain one more main-queue turn: a second, erroneous notification
        // would also have been enqueued via `MainThread.enqueue` by now.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertEqual(notifyCount, 1, "one tick's worth of change must produce exactly one repaint")
    }

    func testApplyAnchorProjectionsDoesNotNotifyWhenNothingChanged() {
        let store = AnnotationStore()
        let current = anchorProjection()
        store.add(anchoredAnnotation(id: "steady", projection: current))

        // Drain the add's own pending notification first -- see the sibling
        // test's comment for why an unflushed one would otherwise be
        // miscounted once the listener below is attached.
        let setupDrained = expectation(description: "setup notification drained")
        DispatchQueue.main.async { setupDrained.fulfill() }
        wait(for: [setupDrained], timeout: 2)

        var notified = false
        store.onStoreChanged = { notified = true }
        XCTAssertFalse(store.applyAnchorProjections(["steady": current]))

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(notified, "re-sampling a window that has not moved must not trigger a repaint")
    }

    func testOnAnchoredSetChangedFiresWhenAnAnchoredAnnotationIsAddedButNotForAnUnanchoredOne() {
        let store = AnnotationStore()
        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }

        store.add(annotation(id: "plain", appId: nil))
        XCTAssertEqual(fireCount, 0, "an unanchored addition must not grow the anchored set")

        store.add(anchoredAnnotation(id: "anchored", projection: anchorProjection()))
        XCTAssertEqual(fireCount, 1)
    }

    func testOnAnchoredSetChangedDoesNotFireWhenAnUpdateRepointsAnExistingAnchorToADifferentWindow() throws {
        let store = AnnotationStore()
        let initial = anchoredAnnotation(id: "anchored", projection: anchorProjection())
        store.add(initial)

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }
        let reanchored = Annotation(
            id: initial.id, screenId: initial.screenId, kind: initial.kind,
            anchor: windowAnchor(windowId: 999), createdAt: initial.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: reanchored), .updated)

        XCTAssertEqual(fireCount, 0, "the id stays anchored -- only its target window changed, not set MEMBERSHIP")
    }

    func testOnAnchoredSetChangedFiresWhenAnUpdateDetachesAnAnchor() throws {
        let store = AnnotationStore()
        let initial = anchoredAnnotation(id: "anchored", projection: anchorProjection())
        store.add(initial)

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }
        let detached = Annotation(id: initial.id, screenId: initial.screenId, kind: initial.kind, createdAt: initial.createdAt)
        XCTAssertEqual(store.updateWithOutcome(id: initial.id, with: detached), .updated)

        XCTAssertEqual(fireCount, 1)
    }

    func testOnAnchoredSetChangedFiresWhenAnAnchoredAnnotationIsRemovedButNotForAnUnanchoredOne() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "anchored", projection: anchorProjection()))
        store.add(annotation(id: "plain", appId: nil))

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }

        XCTAssertTrue(store.remove(id: "plain"))
        XCTAssertEqual(fireCount, 0)

        XCTAssertTrue(store.remove(id: "anchored"))
        XCTAssertEqual(fireCount, 1)
    }

    func testOnAnchoredSetChangedFiresExactlyOnceWhenClearAllRemovesAMixOfAnchoredAndUnanchoredAnnotations() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "anchored-1", projection: anchorProjection()))
        store.add(anchoredAnnotation(id: "anchored-2", projection: anchorProjection()))
        store.add(annotation(id: "plain", appId: nil))

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }
        XCTAssertEqual(store.clearAll(), 3)
        XCTAssertEqual(fireCount, 1, "clearing several anchored annotations in one call is still ONE set-membership change")
    }

    func testOnAnchoredSetChangedDoesNotFireWhenClearAllRemovesOnlyUnanchoredAnnotations() {
        let store = AnnotationStore()
        store.add(annotation(id: "plain", appId: nil))

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }
        XCTAssertEqual(store.clearAll(), 1)
        XCTAssertEqual(fireCount, 0)
    }

    func testOnAnchoredSetChangedFiresOnClearVisibleOnlyWhenAnAnchoredAnnotationIsActuallyRemoved() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "finder-anchored", appId: "com.apple.finder", projection: anchorProjection()))
        store.add(annotation(id: "terminal-plain", appId: "com.apple.Terminal"))

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }
        XCTAssertEqual(store.clearVisible(forApp: "com.apple.finder"), 1)
        XCTAssertEqual(fireCount, 1)

        XCTAssertEqual(store.clearVisible(forApp: "com.apple.Terminal"), 1)
        XCTAssertEqual(fireCount, 1, "removing only unanchored survivors must not fire again")
    }

    func testOnAnchoredSetChangedDoesNotFireForAProjectionOnlyRefresh() {
        let store = AnnotationStore()
        store.add(anchoredAnnotation(id: "tracked", projection: anchorProjection(effectiveScreenId: "1")))

        var fireCount = 0
        store.onAnchoredSetChanged = { fireCount += 1 }
        XCTAssertTrue(store.applyAnchorProjections(["tracked": anchorProjection(effectiveScreenId: "2")]))

        XCTAssertEqual(fireCount, 0, "a tracker resample keeps the same annotation anchored -- the SET did not change")
    }

    func testAnchoredAnnotationsReturnsOneSnapshotPerAnchoredAnnotationAndFlagsVectorPathKind() throws {
        let store = AnnotationStore()
        let pathProjection = anchorProjection(effectiveScreenId: "1")
        store.add(anchoredAnnotation(id: "path-anchor", projection: pathProjection))
        store.add(Annotation(
            id: "text-anchor", screenId: "1",
            kind: .text(text: "hi", x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF",
                        backgroundColorHex: nil, backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            anchor: windowAnchor(windowId: 7), anchorProjection: pathProjection
        ))
        store.add(annotation(id: "unanchored", appId: nil))

        let snapshots = store.anchoredAnnotations()
        XCTAssertEqual(Set(snapshots.map(\.id)), Set(["path-anchor", "text-anchor"]))

        let pathSnapshot = try XCTUnwrap(snapshots.first { $0.id == "path-anchor" })
        XCTAssertTrue(pathSnapshot.kindIsHighlightPath)
        XCTAssertEqual(pathSnapshot.currentProjection, pathProjection)
        XCTAssertEqual(pathSnapshot.revision, store.get(id: "path-anchor")?.revision)

        let textSnapshot = try XCTUnwrap(snapshots.first { $0.id == "text-anchor" })
        XCTAssertFalse(textSnapshot.kindIsHighlightPath)
    }
    // MARK: - updateWithOutcome(id:expectedRevision:transform:) -- the
    // transform-based overload BUG 1's fix is built on.
    //
    // These pin the primitive's OWN contract in isolation, independent of
    // `update_annotation`'s anchor-freeze use of it (see
    // `UpdateAnnotationAnchorTests.swift` for that): CAS behaves identically
    // to the by-replacement overload, `transform` sees the LIVE annotation
    // (not a snapshot), a non-nil returned projection REPLACES while `nil`
    // carries the LIVE `anchorProjection` forward, and rejection/notFound
    // paths never call `transform`'s result into the store.

    func testTransformOverloadReturnsNotFoundAndNeverCallsTransformForAMissingId() {
        let store = AnnotationStore()
        var transformCalled = false
        let outcome = store.updateWithOutcome(id: "does-not-exist", expectedRevision: nil) { old in
            transformCalled = true
            return (old, nil)
        }
        XCTAssertEqual(outcome, .notFound)
        XCTAssertFalse(transformCalled, "a missing id has nothing to hand the transform")
    }

    func testTransformOverloadReturnsStaleAndNeverCallsTransformOnARevisionMismatch() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        let stale = try XCTUnwrap(store.get(id: "target")).revision &+ 1

        var transformCalled = false
        let outcome = store.updateWithOutcome(id: "target", expectedRevision: stale) { old in
            transformCalled = true
            return (old, nil)
        }
        XCTAssertEqual(outcome, .stale)
        XCTAssertFalse(transformCalled, "a caller with the wrong CAS token has nothing valid to freeze against")
    }

    /// THE core property `finalizeAnchorPatch` (MCPToolHandlers+Drawing.swift)
    /// depends on: `transform` must see whatever is ACTUALLY stored right
    /// now, including a write that landed after the caller's own last read,
    /// not a value threaded in from outside.
    func testTransformSeesTheLiveAnnotationIncludingAWriteThatLandedAfterTheCallersOwnRead() throws {
        let store = AnnotationStore()
        let projection = anchorProjection(adjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0))
        store.add(anchoredAnnotation(id: "target", projection: projection))
        let callerSnapshot = try XCTUnwrap(store.get(id: "target"))

        // A write landing AFTER the caller's own snapshot but BEFORE the
        // transform-based commit -- exactly the race window BUG 1 exploited.
        let racingProjection = anchorProjection(adjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 150, translateY: 0))
        XCTAssertTrue(store.applyAnchorProjections(["target": racingProjection]))

        var observedProjection: AnchorProjection?
        let outcome = store.updateWithOutcome(id: "target", expectedRevision: callerSnapshot.revision) { live in
            observedProjection = live.anchorProjection
            return (live, nil)
        }
        XCTAssertEqual(outcome, .updated, "applyAnchorProjections must not bump revision, or this CAS would spuriously fail")
        XCTAssertEqual(observedProjection, racingProjection, "transform must see the LIVE (raced) projection, not the caller's stale snapshot")
    }

    func testTransformOverloadNonNilProjectionReplacesTheLiveOne() throws {
        let store = AnnotationStore()
        let original = anchorProjection(adjustment: .identity)
        store.add(anchoredAnnotation(id: "target", projection: original))
        let snapshot = try XCTUnwrap(store.get(id: "target"))

        let override = anchorProjection(state: .hidden, adjustment: AnchorAdjustment(scaleX: 2, scaleY: 2, translateX: 9, translateY: 9))
        let outcome = store.updateWithOutcome(id: "target", expectedRevision: snapshot.revision) { live in
            (live, override)
        }
        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(try XCTUnwrap(store.get(id: "target")).anchorProjection, override)
    }

    func testTransformOverloadNilProjectionCarriesTheLiveOneForwardUnconditionally() throws {
        let store = AnnotationStore()
        let live = anchorProjection(adjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 4, translateY: 4))
        store.add(anchoredAnnotation(id: "target", projection: live))
        let snapshot = try XCTUnwrap(store.get(id: "target"))

        let restyled = Annotation(
            id: snapshot.id, screenId: snapshot.screenId, kind: snapshot.kind, colorHex: "#00FF00",
            label: snapshot.label, appId: snapshot.appId, appName: snapshot.appName,
            opacity: snapshot.opacity, offsetX: snapshot.offsetX, offsetY: snapshot.offsetY,
            zIndex: snapshot.zIndex, anchor: snapshot.anchor, staticAdjustment: snapshot.staticAdjustment,
            createdAt: snapshot.createdAt
        )
        let outcome = store.updateWithOutcome(id: "target", expectedRevision: snapshot.revision) { _ in
            (restyled, nil)
        }
        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(
            try XCTUnwrap(store.get(id: "target")).anchorProjection, live,
            "a nil transform projection must carry the LIVE anchorProjection forward, exactly like the by-replacement overload"
        )
    }

    func testTransformOverloadRejectionInstallsNothing() throws {
        let store = AnnotationStore()
        let initial = annotation(id: "target", appId: nil)
        store.add(initial)
        let snapshot = try XCTUnwrap(store.get(id: "target"))

        let oversizedText = String(repeating: "x", count: DrawingDefaults.maxRetainedAnnotationPayloadBytes + 1)
        let oversized = Annotation(
            id: snapshot.id, screenId: snapshot.screenId,
            kind: .text(text: oversizedText, x: 0, y: 0, fontSize: 12, textColorHex: "#FFFFFF",
                        backgroundColorHex: nil, backgroundOpacity: 0, paddingPx: 0, opacity: 1),
            colorHex: snapshot.colorHex, appId: snapshot.appId, appName: snapshot.appName,
            createdAt: snapshot.createdAt
        )
        let outcome = store.updateWithOutcome(id: "target", expectedRevision: snapshot.revision) { _ in
            (oversized, nil)
        }
        guard case .rejected(.payloadBytes) = outcome else {
            return XCTFail("expected a payloadBytes rejection, got \(outcome)")
        }
        let retained = try XCTUnwrap(store.get(id: "target"))
        XCTAssertEqual(retained.revision, snapshot.revision, "a rejected transform result must leave the stored annotation completely untouched")
    }

    /// `updateWithOutcome(id:with:expectedRevision:)` is now implemented on
    /// top of the transform-based overload; this pins that the delegation
    /// preserves its documented "ignore the replacement's own
    /// `anchorProjection`, carry the LIVE one forward" behavior exactly --
    /// the one property a naive refactor of this wrapper could most easily
    /// break.
    func testByReplacementOverloadStillIgnoresTheReplacementsOwnAnchorProjection() throws {
        let store = AnnotationStore()
        let live = anchorProjection(adjustment: AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 7, translateY: 7))
        store.add(anchoredAnnotation(id: "target", projection: live))
        let snapshot = try XCTUnwrap(store.get(id: "target"))

        let replacementWithItsOwnProjection = Annotation(
            id: snapshot.id, screenId: snapshot.screenId, kind: snapshot.kind, colorHex: snapshot.colorHex,
            label: snapshot.label, appId: snapshot.appId, appName: snapshot.appName,
            opacity: snapshot.opacity, offsetX: snapshot.offsetX, offsetY: snapshot.offsetY,
            zIndex: snapshot.zIndex, anchor: snapshot.anchor, staticAdjustment: snapshot.staticAdjustment,
            anchorProjection: anchorProjection(adjustment: AnchorAdjustment(scaleX: 9, scaleY: 9, translateX: 9, translateY: 9)),
            createdAt: snapshot.createdAt
        )
        XCTAssertEqual(store.updateWithOutcome(id: "target", with: replacementWithItsOwnProjection, expectedRevision: snapshot.revision), .updated)
        XCTAssertEqual(try XCTUnwrap(store.get(id: "target")).anchorProjection, live)
    }
}
