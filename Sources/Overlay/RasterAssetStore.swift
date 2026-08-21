import AppKit
import Foundation
import ImageIO

/// A path-free description of a raster image retained by `RasterAssetStore`.
///
/// The identifier is generated when the image is decoded.  In particular, it
/// is not derived from, and does not reveal, the caller's file-system path.
public struct RasterAssetHandle: Equatable, Sendable {
    public let id: String
    public let widthPx: Int
    public let heightPx: Int

    public init(id: String, widthPx: Int, heightPx: Int) {
        self.id = id
        self.widthPx = widthPx
        self.heightPx = heightPx
    }

    /// Decoded RGBA bytes this asset costs once materialized.
    ///
    /// Computed, not stored, so it cannot drift from the dimensions it is
    /// derived from and the memberwise init keeps its existing shape. Every
    /// accounting site -- the store's aggregate budget and `draw_batch`'s
    /// per-batch budget -- must measure the SAME thing, so the formula lives
    /// here once instead of being open-coded at each of them.
    public var decodedByteCount: UInt64 { UInt64(widthPx) * UInt64(heightPx) * 4 }
}

public enum RasterAssetStoreError: LocalizedError, Equatable {
    case invalidPath
    case unreadableFile
    case unsupportedImage
    case imageTooLarge
    case invalidDimensions
    case storeCapacityExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "image_path must be an absolute path to a local raster image."
        case .unreadableFile:
            return "The image file does not exist, is not a regular readable file, or exceeds the input-size limit."
        case .unsupportedImage:
            return "The image must be a single-frame PNG, JPEG, HEIC, or TIFF file."
        case .imageTooLarge:
            return "The image exceeds the decoded-pixel safety limit. Downsample it before drawing."
        case .invalidDimensions:
            return "The image has invalid decoded pixel dimensions."
        case .storeCapacityExceeded:
            return "The retained raster-image budget is full. Clear existing image annotations before adding more."
        }
    }
}

/// Owns decoded raster images for image annotations.
///
/// Loading intentionally does not keep a URL, bookmark, file name, or other
/// source-path data: after `load(path:)` returns, callers can only address an
/// image through its random opaque id.  Call `remove(id:)` when an annotation
/// no longer needs an image, or `removeAll()` during a broader cleanup.
///
/// The store serializes its small dictionary with an `NSLock`.  Decoding is
/// done before taking that lock, so a slow image read never blocks drawing a
/// previously loaded asset.
public final class RasterAssetStore: @unchecked Sendable {
    public static let shared = RasterAssetStore()

    /// Bounds intentionally apply before and after ImageIO decoding.  The
    /// metadata check avoids decoding an obvious image bomb; the CGImage check
    /// is authoritative for the image eventually retained by the store.
    public static let defaultMaxInputFileBytes: UInt64 = 50 * 1_024 * 1_024
    public static let defaultMaxDecodedPixels = 20_000_000
    public static let defaultMaxDecodedDimension = 16_384
    /// The store is process-wide and long lived.  Bounding the aggregate is
    /// just as important as bounding an individual image: a batch of valid
    /// images must not turn into an aggregate image bomb.
    public static let defaultMaxStoredAssets = 256
    public static let defaultMaxTotalDecodedBytes: UInt64 = 512 * 1_024 * 1_024

    private struct StoredAsset {
        let descriptor: RasterAssetHandle
        let cgImage: CGImage
        let nsImage: NSImage
        let decodedByteCount: UInt64
    }

    /// A strong, immutable snapshot of one or more decoded assets.  Holding a
    /// lease keeps pixels alive even if the owning annotation is cleared or
    /// expires on another thread while a renderer/verifier is using them.
    ///
    /// The lease deliberately exposes only images by opaque id; source paths
    /// and store mutation remain unavailable to rendering code.
    public final class Lease: @unchecked Sendable {
        private let images: [String: NSImage]

        fileprivate init(images: [String: NSImage]) {
            self.images = images
        }

        public func image(id: String) -> NSImage? {
            images[id]
        }
    }

    private let lock = NSLock()
    private let maxInputFileBytes: UInt64
    private let maxDecodedPixels: Int
    private let maxDecodedDimension: Int
    private let maxStoredAssets: Int
    private let maxTotalDecodedBytes: UInt64
    private var assets: [String: StoredAsset] = [:]
    private var retainedDecodedBytes: UInt64 = 0

    public init(
        maxInputFileBytes: UInt64 = RasterAssetStore.defaultMaxInputFileBytes,
        maxDecodedPixels: Int = RasterAssetStore.defaultMaxDecodedPixels,
        maxDecodedDimension: Int = RasterAssetStore.defaultMaxDecodedDimension,
        maxStoredAssets: Int = RasterAssetStore.defaultMaxStoredAssets,
        maxTotalDecodedBytes: UInt64 = RasterAssetStore.defaultMaxTotalDecodedBytes
    ) {
        self.maxInputFileBytes = maxInputFileBytes
        self.maxDecodedPixels = maxDecodedPixels
        self.maxDecodedDimension = maxDecodedDimension
        self.maxStoredAssets = max(1, maxStoredAssets)
        self.maxTotalDecodedBytes = maxTotalDecodedBytes
    }

    /// Decodes a local raster exactly once and retains it until explicit
    /// removal. The supplied path is used only for this synchronous read and
    /// is never stored or returned.
    @discardableResult
    public func load(path: String) throws -> RasterAssetHandle {
        let image = try decode(path: path)
        let descriptor = RasterAssetHandle(
            id: UUID().uuidString,
            widthPx: image.width,
            heightPx: image.height
        )
        let stored = StoredAsset(
            descriptor: descriptor,
            cgImage: image,
            nsImage: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            ),
            decodedByteCount: descriptor.decodedByteCount
        )

        let retained = withLock {
            guard assets.count < maxStoredAssets,
                  retainedDecodedBytes <= maxTotalDecodedBytes,
                  stored.decodedByteCount <= maxTotalDecodedBytes - retainedDecodedBytes else {
                return false
            }
            assets[descriptor.id] = stored
            retainedDecodedBytes += stored.decodedByteCount
            return true
        }
        guard retained else { throw RasterAssetStoreError.storeCapacityExceeded }
        return descriptor
    }

    /// Returns the retained image for Core Graphics drawing, if it exists.
    /// `CGImage` is immutable, so sharing this retained reference is safe.
    public func cgImage(for id: String) -> CGImage? {
        withLock { assets[id]?.cgImage }
    }

    /// Returns the retained AppKit image for callers already drawing through
    /// AppKit. Prefer `cgImage(for:)` for renderer code that can use either.
    public func nsImage(for id: String) -> NSImage? {
        withLock { assets[id]?.nsImage }
    }

    /// The compact drawing-facing spelling: fetch an AppKit image by its
    /// opaque handle id.  The store retains one reference from `load(path:)`
    /// until the matching `release(id:)`.
    public func image(id: String) -> NSImage? {
        nsImage(for: id)
    }

    /// Atomically snapshots the requested images into a lease.  A later
    /// release removes the store's ownership but cannot invalidate the
    /// renderer's strong references held by this object.
    public func lease(ids: [String]) -> Lease {
        withLock {
            let uniqueIDs = Set(ids)
            var snapshot: [String: StoredAsset] = [:]
            snapshot.reserveCapacity(uniqueIDs.count)
            for id in uniqueIDs {
                if let asset = assets[id] {
                    snapshot[id] = asset
                }
            }
            return Lease(images: snapshot.mapValues(\.nsImage))
        }
    }

    /// Returns dimensions and opaque id without exposing image or source data.
    public func descriptor(for id: String) -> RasterAssetHandle? {
        withLock { assets[id]?.descriptor }
    }

    /// Explicitly releases the decoded image retained for an id.
    @discardableResult
    public func remove(id: String) -> Bool {
        withLock {
            guard let removed = assets.removeValue(forKey: id) else { return false }
            retainedDecodedBytes -= removed.decodedByteCount
            return true
        }
    }

    /// Releases the one reference created by `load(path:)`.
    @discardableResult
    public func release(id: String) -> Bool {
        remove(id: id)
    }

    /// Releases every retained decoded image and returns the number removed.
    @discardableResult
    public func removeAll() -> Int {
        withLock {
            let count = assets.count
            assets.removeAll(keepingCapacity: false)
            retainedDecodedBytes = 0
            return count
        }
    }

    public var count: Int {
        withLock { assets.count }
    }

    /// Retained decoded RGBA bytes, excluding short-lived decoder buffers.
    public var totalDecodedBytes: UInt64 {
        withLock { retainedDecodedBytes }
    }

    private func decode(path: String) throws -> CGImage {
        // Open once, validate that opened descriptor, then decode the exact
        // bounded byte snapshot read from it.  This avoids validating one
        // pathname and asking ImageIO to reopen a different replacement file.
        let data: Data
        do {
            data = try BoundedLocalFile.read(path: path, maxBytes: maxInputFileBytes)
        } catch BoundedLocalFileError.invalidPath {
            throw RasterAssetStoreError.invalidPath
        } catch {
            throw RasterAssetStoreError.unreadableFile
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              Self.supportedTypeIdentifiers.contains(type) else {
            throw RasterAssetStoreError.unsupportedImage
        }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let declaredWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let declaredHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw RasterAssetStoreError.invalidDimensions
        }
        try validate(width: declaredWidth.intValue, height: declaredHeight.intValue)

        guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw RasterAssetStoreError.unsupportedImage
        }
        try validate(width: decodedImage.width, height: decodedImage.height)
        return try materialize(decodedImage)
    }

    private func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw RasterAssetStoreError.invalidDimensions
        }
        guard width <= maxDecodedDimension,
              height <= maxDecodedDimension,
              width <= maxDecodedPixels / height else {
            throw RasterAssetStoreError.imageTooLarge
        }
    }

    /// Detaches the retained asset from ImageIO's file-backed provider.  This
    /// both guarantees that loading has finished before `load` returns and
    /// means the store retains pixels only -- never the caller's source URL.
    private func materialize(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RasterAssetStoreError.unsupportedImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let materialized = context.makeImage() else {
            throw RasterAssetStoreError.unsupportedImage
        }
        return materialized
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static let supportedTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.tiff"
    ]
}
