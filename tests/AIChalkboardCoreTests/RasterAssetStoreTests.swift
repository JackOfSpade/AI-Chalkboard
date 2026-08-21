import AppKit
import XCTest
@testable import AIChalkboardCore

final class RasterAssetStoreTests: XCTestCase {
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
            .appendingPathComponent("ai-chalkboard-raster-asset-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoadRetainsImageWithOpaqueIDAndIntrinsicPixelDimensions() throws {
        let source = try png(width: 13, height: 7)
        let store = RasterAssetStore()

        let asset = try store.load(path: source.path)

        XCTAssertEqual(asset.widthPx, 13)
        XCTAssertEqual(asset.heightPx, 7)
        XCTAssertNotEqual(asset.id, source.path)
        XCTAssertEqual(store.descriptor(for: asset.id), asset)
        XCTAssertEqual(store.cgImage(for: asset.id)?.width, 13)
        XCTAssertEqual(store.cgImage(for: asset.id)?.height, 7)
        XCTAssertEqual(store.image(id: asset.id)?.representations.first?.pixelsWide, 13)
        XCTAssertEqual(store.count, 1)
        // The store's aggregate accounting and draw_batch's per-batch budget
        // both charge `RasterAssetHandle.decodedByteCount`; pin that the handle
        // reports the materialized RGBA size the store actually retained, so
        // the two budgets cannot silently start measuring different things.
        XCTAssertEqual(asset.decodedByteCount, 13 * 7 * 4)
        XCTAssertEqual(store.totalDecodedBytes, asset.decodedByteCount)
    }

    func testExplicitRemoveAndCleanupReleaseAssets() throws {
        let source = try png()
        let store = RasterAssetStore()
        let first = try store.load(path: source.path)
        let second = try store.load(path: source.path)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(store.release(id: first.id))
        XCTAssertFalse(store.release(id: first.id))
        XCTAssertNil(store.cgImage(for: first.id))
        XCTAssertEqual(store.removeAll(), 1)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.nsImage(for: second.id))
    }

    func testRejectsRelativeDirectoryAndUnsupportedInputs() throws {
        let store = RasterAssetStore()
        XCTAssertThrowsError(try store.load(path: "relative.png")) { error in
            XCTAssertEqual(error as? RasterAssetStoreError, .invalidPath)
        }
        XCTAssertThrowsError(try store.load(path: FileManager.default.temporaryDirectory.path)) { error in
            XCTAssertEqual(error as? RasterAssetStoreError, .unreadableFile)
        }

        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-raster-asset-\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: text)
        addTeardownBlock { try? FileManager.default.removeItem(at: text) }
        XCTAssertThrowsError(try store.load(path: text.path)) { error in
            XCTAssertEqual(error as? RasterAssetStoreError, .unsupportedImage)
        }
    }

    func testRejectsDecodedImageAboveConfiguredPixelLimit() throws {
        let source = try png(width: 13, height: 7)
        let store = RasterAssetStore(maxDecodedPixels: 90)
        XCTAssertThrowsError(try store.load(path: source.path)) { error in
            XCTAssertEqual(error as? RasterAssetStoreError, .imageTooLarge)
        }
    }

    func testConcurrentLookupsAndCleanupRemainConsistent() throws {
        let source = try png()
        let store = RasterAssetStore()
        let asset = try store.load(path: source.path)

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            _ = store.cgImage(for: asset.id)
            _ = store.descriptor(for: asset.id)
        }

        XCTAssertEqual(store.removeAll(), 1)
        XCTAssertNil(store.descriptor(for: asset.id))
    }

    func testAggregateAssetCountAndDecodedByteBudgetsAreEnforced() throws {
        let source = try png(width: 10, height: 10) // materialized RGBA = 400 bytes
        let countLimited = RasterAssetStore(maxStoredAssets: 1, maxTotalDecodedBytes: 1_000)
        _ = try countLimited.load(path: source.path)
        XCTAssertThrowsError(try countLimited.load(path: source.path)) { error in
            XCTAssertEqual(error as? RasterAssetStoreError, .storeCapacityExceeded)
        }

        let byteLimited = RasterAssetStore(maxStoredAssets: 10, maxTotalDecodedBytes: 700)
        let first = try byteLimited.load(path: source.path)
        XCTAssertEqual(byteLimited.totalDecodedBytes, 400)
        XCTAssertThrowsError(try byteLimited.load(path: source.path)) { error in
            XCTAssertEqual(error as? RasterAssetStoreError, .storeCapacityExceeded)
        }
        XCTAssertTrue(byteLimited.release(id: first.id))
        XCTAssertEqual(byteLimited.totalDecodedBytes, 0)
        XCTAssertNoThrow(try byteLimited.load(path: source.path))
    }

    func testLeaseRetainsImageAfterStoreOwnershipIsReleased() throws {
        let source = try png(width: 13, height: 7)
        let store = RasterAssetStore()
        let asset = try store.load(path: source.path)

        let lease = store.lease(ids: [asset.id])
        XCTAssertTrue(store.release(id: asset.id))

        XCTAssertNil(store.image(id: asset.id))
        XCTAssertEqual(lease.image(id: asset.id)?.representations.first?.pixelsWide, 13)
    }

    func testAnnotationRenderSnapshotClosesLookupToClearRace() throws {
        let source = try png(width: 13, height: 7)
        let asset = try RasterAssetStore.shared.load(path: source.path)
        addTeardownBlock { _ = RasterAssetStore.shared.release(id: asset.id) }
        let store = AnnotationStore()
        let annotation = Annotation(
            id: "leased-verification",
            screenId: "screen-1",
            kind: .image(
                assetId: asset.id,
                x: 0,
                y: 0,
                width: 13,
                height: 7,
                rotationDegrees: 0,
                opacity: 1
            )
        )
        store.add(annotation)

        let snapshot = try XCTUnwrap(store.renderSnapshot(id: annotation.id))
        XCTAssertTrue(store.remove(id: annotation.id))

        XCTAssertNil(RasterAssetStore.shared.image(id: asset.id))
        XCTAssertEqual(snapshot.rasterLease.image(id: asset.id)?.representations.first?.pixelsWide, 13)
    }
}
