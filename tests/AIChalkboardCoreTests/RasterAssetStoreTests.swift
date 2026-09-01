#if os(macOS)
import AppKit
#elseif os(Windows)
import CChalkboardWin
#endif
import XCTest
@testable import AIChalkboardCore

final class RasterAssetStoreTests: XCTestCase {
    func testHandleByteAccountingNeverTrapsOnInvalidOrExtremePublicDimensions() {
        XCTAssertEqual(RasterAssetHandle(id: "negative-width", widthPx: -1, heightPx: 10).decodedByteCount, 0)
        XCTAssertEqual(RasterAssetHandle(id: "zero-height", widthPx: 10, heightPx: 0).decodedByteCount, 0)
        XCTAssertEqual(RasterAssetHandle(id: "normal", widthPx: 10, heightPx: 20).decodedByteCount, 800)
        XCTAssertEqual(RasterAssetHandle(id: "extreme", widthPx: .max, heightPx: .max).decodedByteCount, .max)
    }

    #if os(macOS)
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
    #elseif os(Windows)
    /// Windows analogue of the macOS fixture above -- see
    /// `AnnotationStoreTests.png(width:height:)` for why a flat opaque
    /// premultiplied-BGRA buffer encoded via `chalk_image_encode_png` is the
    /// simplest true "loadable raster" available here (no `NSBitmapImageRep`
    /// on this platform).
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
            .appendingPathComponent("ai-chalkboard-raster-asset-\(UUID().uuidString).png")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    #endif

    /// Platform-neutral accessor for a loaded asset's decoded pixel width,
    /// via whichever image type `RasterAssetStore.image(id:)` returns on
    /// this platform (`NSImage.representations.first?.pixelsWide` on macOS,
    /// `WindowsRasterImage.pixelWidth` on Windows) -- both are read-throughs
    /// of the same decoded-image dimensions, so this keeps every test below
    /// asserting the same thing on both platforms.
    private func loadedImageWidth(_ store: RasterAssetStore, id: String) -> Int? {
        #if os(macOS)
        return store.image(id: id)?.representations.first?.pixelsWide
        #elseif os(Windows)
        return store.image(id: id)?.pixelWidth
        #endif
    }

    /// Same as `loadedImageWidth`, but reading through a `Lease` instead of
    /// the store directly (`Lease.image(id:)` returns the same platform
    /// image type `RasterAssetStore.image(id:)` does).
    private func leasedImageWidth(_ lease: RasterAssetStore.Lease, id: String) -> Int? {
        #if os(macOS)
        return lease.image(id: id)?.representations.first?.pixelsWide
        #elseif os(Windows)
        return lease.image(id: id)?.pixelWidth
        #endif
    }

    func testLoadRetainsImageWithOpaqueIDAndIntrinsicPixelDimensions() throws {
        let source = try png(width: 13, height: 7)
        let store = RasterAssetStore()

        let asset = try store.load(path: source.path)

        XCTAssertEqual(asset.widthPx, 13)
        XCTAssertEqual(asset.heightPx, 7)
        XCTAssertNotEqual(asset.id, source.path)
        XCTAssertEqual(store.descriptor(for: asset.id), asset)
        #if os(macOS)
        XCTAssertEqual(store.cgImage(for: asset.id)?.width, 13)
        XCTAssertEqual(store.cgImage(for: asset.id)?.height, 7)
        #elseif os(Windows)
        XCTAssertEqual(store.image(id: asset.id)?.pixelWidth, 13)
        XCTAssertEqual(store.image(id: asset.id)?.pixelHeight, 7)
        #endif
        XCTAssertEqual(loadedImageWidth(store, id: asset.id), 13)
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
        #if os(macOS)
        XCTAssertNil(store.cgImage(for: first.id))
        #elseif os(Windows)
        XCTAssertNil(store.image(id: first.id))
        #endif
        XCTAssertEqual(store.removeAll(), 1)
        XCTAssertEqual(store.count, 0)
        #if os(macOS)
        XCTAssertNil(store.nsImage(for: second.id))
        #elseif os(Windows)
        XCTAssertNil(store.image(id: second.id))
        #endif
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
            // macOS's ImageIO reports "recognized no container format at
            // all" the same way it reports "recognized container, corrupt
            // pixels" -- both collapse to `.unsupportedImage`. Windows's WIC
            // distinguishes them: a `.txt` file matches NO installed
            // decoder's content signature at all, which maps to the more
            // precise `.unsupportedFormatOnSystem` (see
            // RasterAssetStoreError's Windows mapping doc comment) rather
            // than `.unsupportedImage` (reserved there for a recognized-but-
            // corrupt file). This is a real, intentional platform
            // difference, not a defect.
            #if os(macOS)
            XCTAssertEqual(error as? RasterAssetStoreError, .unsupportedImage)
            #elseif os(Windows)
            XCTAssertEqual(error as? RasterAssetStoreError, .unsupportedFormatOnSystem)
            #endif
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
            #if os(macOS)
            _ = store.cgImage(for: asset.id)
            #elseif os(Windows)
            _ = store.image(id: asset.id)
            #endif
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
        XCTAssertEqual(leasedImageWidth(lease, id: asset.id), 13)
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
        XCTAssertEqual(leasedImageWidth(snapshot.rasterLease, id: asset.id), 13)
    }
}
