#if os(macOS)
import AppKit
import ImageIO
#elseif os(Windows)
import CChalkboardWin
#endif
import Foundation

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
    public var decodedByteCount: UInt64 {
        // `RasterAssetHandle` is public, so callers can construct one without
        // first passing through `RasterAssetStore.decode(path:)`.  Converting a
        // negative `Int` to `UInt64` traps, and multiplying extreme (but valid
        // `Int`) dimensions can overflow too.  Treat invalid dimensions as
        // zero bytes and saturate impossible image sizes: the store validates
        // real decoded dimensions before it creates a handle, while this API
        // remains safe for diagnostics and direct callers.
        guard widthPx > 0, heightPx > 0 else { return 0 }
        let width = UInt64(widthPx)
        let height = UInt64(heightPx)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return .max }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        return byteOverflow ? .max : byteCount
    }
}

/// Platform-neutral. Every case here is reachable on macOS exactly as
/// before; `.unsupportedFormatOnSystem` and `.decodingUnavailable` are
/// reachable ONLY from the Windows `decode(path:)` branch below (WIC can
/// report failure classes ImageIO has no equivalent for -- see that branch's
/// doc comment) and are simply never thrown on macOS, so adding them here
/// changes nothing about macOS's existing error surface.
public enum RasterAssetStoreError: LocalizedError, Equatable {
    case invalidPath
    case unreadableFile
    case unsupportedImage
    case imageTooLarge
    case invalidDimensions
    case storeCapacityExceeded
    /// WINDOWS ONLY: the Windows Imaging Component has no decoder installed
    /// for this file's container format on this machine. The common
    /// real-world case is HEIC/HEIF without Microsoft's "HEIF Image
    /// Extensions" installed from the Microsoft Store -- kept distinct from
    /// `.unsupportedImage` because the fix ("install a codec") is completely
    /// different from "this file is malformed", and collapsing the two would
    /// send a user to re-export a file that was never the problem. See
    /// `CHALK_ERR_UNSUPPORTED_FORMAT` in chalkboard_win.h.
    case unsupportedFormatOnSystem
    /// WINDOWS ONLY: WIC itself could not be initialized, or a heap/COM
    /// allocation failed while decoding -- a systemic failure of the decoder
    /// subsystem, not a statement about this particular file. Kept distinct
    /// from `.unsupportedImage` for the same reason `.unsupportedFormatOnSystem`
    /// is: the two need different responses from a caller (retry / restart
    /// AI Chalkboard, versus fix or replace the file).
    case decodingUnavailable

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
        case .unsupportedFormatOnSystem:
            return "Windows has no image decoder installed for this file's format. This is the common outcome for HEIC/HEIF files when the Microsoft \"HEIF Image Extensions\" are not installed from the Microsoft Store. Install the codec, or convert/re-export the image to PNG, JPEG, TIFF, or BMP, then retry."
        case .decodingUnavailable:
            return "The Windows image decoder could not decode this image because of a system-level failure (decoder initialization or a memory allocation failure), not a problem with the file itself. Retry, or restart AI Chalkboard if the failure persists."
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
///
/// PLATFORM SPLIT: the budget accounting below (per-image size/dimension
/// limits, the aggregate asset-count/byte budget, the lease mechanism, batch
/// rollback via `remove`/`removeAll`) is pure policy over `Int`/`UInt64`
/// values and stays a SINGLE, unduplicated implementation on both platforms.
/// Only `decode(path:)` (what actually turns bytes on disk into pixels) and
/// `StoredAsset`'s image field are platform-specific: macOS decodes via
/// ImageIO into a `CGImage`/`NSImage` pair, Windows decodes via
/// `WindowsRasterImage` (WIC, through the `CChalkboardWin` shim). Every
/// limit and every rejection reason a caller can observe is identical
/// between the two, except where this file documents an honest, Windows-only
/// addition (`.unsupportedFormatOnSystem`, `.decodingUnavailable`) -- see
/// `RasterAssetStoreError`'s doc comment above.
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
        let decodedByteCount: UInt64
        #if os(macOS)
        let cgImage: CGImage
        let nsImage: NSImage
        #elseif os(Windows)
        let windowsImage: WindowsRasterImage
        #endif
    }

    /// A strong, immutable snapshot of one or more decoded assets.  Holding a
    /// lease keeps pixels alive even if the owning annotation is cleared on
    /// another thread while a renderer/verifier is using them.
    ///
    /// The lease deliberately exposes only images by opaque id; source paths
    /// and store mutation remain unavailable to rendering code.
    public final class Lease: @unchecked Sendable {
        #if os(macOS)
        private let images: [String: NSImage]

        fileprivate init(images: [String: NSImage]) {
            self.images = images
        }

        public func image(id: String) -> NSImage? {
            images[id]
        }
        #elseif os(Windows)
        private let images: [String: WindowsRasterImage]

        fileprivate init(images: [String: WindowsRasterImage]) {
            self.images = images
        }

        /// Mirrors macOS's `image(id:)` spelling, but returns
        /// `WindowsRasterImage` -- which, unlike `NSImage`, already conforms
        /// to `RasterImageHandle` on its own, so a Windows call site never
        /// needs the `NSImageRasterHandle`-style wrapping step macOS's
        /// `.map(NSImageRasterHandle.init)` call sites use.
        public func image(id: String) -> WindowsRasterImage? {
            images[id]
        }
        #endif
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
        #if os(macOS)
        let image = try decode(path: path)
        let descriptor = RasterAssetHandle(
            id: UUID().uuidString,
            widthPx: image.width,
            heightPx: image.height
        )
        return try retain(StoredAsset(
            descriptor: descriptor,
            decodedByteCount: descriptor.decodedByteCount,
            cgImage: image,
            nsImage: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        ))
        #elseif os(Windows)
        let image = try decode(path: path)
        let descriptor = RasterAssetHandle(
            id: UUID().uuidString,
            widthPx: image.pixelWidth,
            heightPx: image.pixelHeight
        )
        return try retain(StoredAsset(
            descriptor: descriptor,
            decodedByteCount: descriptor.decodedByteCount,
            windowsImage: image
        ))
        #endif
    }

    /// Applies the aggregate store budget (asset count + total decoded bytes)
    /// to an already-decoded, already-validated `StoredAsset` and inserts it
    /// on success. This is the SHARED half of `load(path:)` described in the
    /// class doc comment: identical guard, identical lock discipline,
    /// identical error on both platforms -- only what got decoded into
    /// `stored` differs, and this method never looks at that.
    private func retain(_ stored: StoredAsset) throws -> RasterAssetHandle {
        let retained = withLock {
            guard assets.count < maxStoredAssets,
                  retainedDecodedBytes <= maxTotalDecodedBytes,
                  stored.decodedByteCount <= maxTotalDecodedBytes - retainedDecodedBytes else {
                return false
            }
            assets[stored.descriptor.id] = stored
            retainedDecodedBytes += stored.decodedByteCount
            return true
        }
        guard retained else { throw RasterAssetStoreError.storeCapacityExceeded }
        return stored.descriptor
    }

    #if os(macOS)
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
    #elseif os(Windows)
    /// The compact drawing-facing spelling: fetch the retained decoded image
    /// by its opaque handle id. Mirrors macOS's `image(id:)` -- the store
    /// retains one reference from `load(path:)` until the matching
    /// `release(id:)` -- but returns `WindowsRasterImage` (already a
    /// `RasterImageHandle`) rather than a bare platform image type.
    public func image(id: String) -> WindowsRasterImage? {
        withLock { assets[id]?.windowsImage }
    }
    #endif

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
            #if os(macOS)
            return Lease(images: snapshot.mapValues(\.nsImage))
            #elseif os(Windows)
            return Lease(images: snapshot.mapValues(\.windowsImage))
            #endif
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

    #if os(macOS)
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
    #elseif os(Windows)
    /// WINDOWS NOTE, READ BEFORE CHANGING: this is NOT a line-for-line port of
    /// the macOS branch above, because `chalk_image_decode_file` (the only
    /// decode entry point `CChalkboardWin` exposes -- see chalkboard_win.h
    /// Section 2) takes a PATH, not an in-memory buffer; there is no
    /// decode-from-bytes call to hand pre-validated bytes to the way
    /// `CGImageSourceCreateWithData` lets the macOS branch do. Two real
    /// consequences follow, both recorded precisely rather than silently
    /// smoothed over:
    ///
    /// 1. TOCTOU: `BoundedLocalFile.read` below opens ITS OWN handle to
    ///    validate the path and the input-size cap (matching macOS's
    ///    behavior exactly), then `WindowsRasterImage.decode(path:)` has WIC
    ///    open the SAME path again to actually decode it. macOS's decode
    ///    reads bytes once, from one already-open, already-validated
    ///    descriptor, and hands those exact bytes to ImageIO -- no second
    ///    open, no gap. On Windows the file could theoretically be replaced
    ///    between these two opens. `BoundedLocalFile.read`'s own TOCTOU
    ///    defenses (O_NOFOLLOW-equivalent reparse-point rejection, a
    ///    trailing-byte grow check) still apply to ITS open, but they cannot
    ///    reach into WIC's separate one.
    /// 2. NO PRE-DECODE METADATA CHECK: macOS validates declared width/height
    ///    from image METADATA before ever asking ImageIO to fully decode
    ///    pixels -- an early rejection of an obvious image bomb that never
    ///    materializes its pixels at all. `chalk_image_decode_file` exposes
    ///    no metadata-only probe (only a single call that decodes and
    ///    returns final dimensions together), so on Windows the size/dimension
    ///    cap in `validate(width:height:)` can only be applied AFTER WIC has
    ///    already fully decoded the image -- the decode itself always runs to
    ///    completion first. The aggregate store budget in `retain(_:)` is
    ///    unaffected (that check is timing-independent), but a single
    ///    maliciously huge file costs one real WIC decode on Windows that
    ///    macOS's metadata pre-check can sometimes avoid.
    private func decode(path: String) throws -> WindowsRasterImage {
        do {
            _ = try BoundedLocalFile.read(path: path, maxBytes: maxInputFileBytes)
        } catch BoundedLocalFileError.invalidPath {
            throw RasterAssetStoreError.invalidPath
        } catch {
            throw RasterAssetStoreError.unreadableFile
        }

        let decoded: WindowsRasterImage
        do {
            decoded = try WindowsRasterImage.decode(path: path)
        } catch let error as WindowsRasterImageError {
            throw RasterAssetStoreError(windowsDecodeError: error)
        } catch {
            throw RasterAssetStoreError.decodingUnavailable
        }

        try validate(width: decoded.pixelWidth, height: decoded.pixelHeight)
        return decoded
    }
    #endif

    /// Platform-neutral: both branches' `decode(path:)` call this with the
    /// same declared-or-actual pixel dimensions and the same limits.
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

    #if os(macOS)
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
    #endif

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    #if os(macOS)
    private static let supportedTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.tiff"
    ]
    #endif
}

#if os(Windows)
private extension RasterAssetStoreError {
    /// Maps a `WindowsRasterImage.decode(path:)` failure to the closest
    /// honest `RasterAssetStoreError`. `.decodeFailed` maps to
    /// `.unsupportedImage` deliberately, not approximately: macOS's own
    /// `decode(path:)` above already throws that SAME case both when
    /// `CGImageSourceGetCount` rejects a multi-frame file and when
    /// `CGImageSourceCreateImageAtIndex` fails on a corrupt one -- i.e.
    /// "recognized container, pixels could not be decoded" is exactly what
    /// `.unsupportedImage` has always meant on macOS, so this is a faithful
    /// match, not a stretch.
    init(windowsDecodeError: WindowsRasterImageError) {
        switch windowsDecodeError {
        case .invalidArgument:
            // Should not happen: `path` was already validated as an absolute
            // Windows path by `BoundedLocalFile.read` immediately above this
            // call. Kept mapped to `.invalidPath` rather than `.unknown` so a
            // latent bug here still surfaces an actionable message instead of
            // a bare status number.
            self = .invalidPath
        case .fileNotFound:
            self = .unreadableFile
        case .unsupportedFormat:
            self = .unsupportedFormatOnSystem
        case .decodeFailed:
            self = .unsupportedImage
        case .wicInitFailed, .outOfMemory, .unknown:
            self = .decodingUnavailable
        }
    }
}
#endif
