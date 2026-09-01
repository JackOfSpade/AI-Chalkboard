#if os(Windows)
import CChalkboardWin
import Foundation

/// Errors `WindowsRasterImage.decode(path:)` can throw, one case per
/// distinct `chalk_image_decode_file` failure mode a caller needs to tell
/// apart -- mirrors the granularity chalkboard_win.h's `ChalkErrorCode`
/// deliberately preserves for Section 2 (Images / WIC) rather than
/// collapsing everything into one generic "couldn't load image" case.
///
/// `.unsupportedFormat` is kept SEPARATE from `.decodeFailed` on purpose:
/// per `CHALK_ERR_UNSUPPORTED_FORMAT`'s doc comment in the header, this is
/// specifically the code WIC returns for a file whose container format it
/// has no decoder for at all on this machine -- the common real-world case
/// being HEIC/HEIF when the user has not installed Microsoft's "HEIF Image
/// Extensions" from the Microsoft Store. That is an actionable, specific
/// diagnosis ("install a codec") completely different from `.decodeFailed`
/// ("this file is corrupt/truncated"), so a caller surfacing this to the
/// user (e.g. through MCP) must be able to distinguish them and say the
/// right thing -- collapsing the two back into one case here would throw
/// that distinction away right before it reaches the one place equipped to
/// use it.
enum WindowsRasterImageError: Error, Equatable {
    /// `CHALK_ERR_INVALID_ARGUMENT`: the path was empty/malformed, or an
    /// out-parameter was unexpectedly null (should not happen from this
    /// file's own call site; kept distinct rather than folded into
    /// `.unknown` so a future caller passing a bad path sees a precise
    /// error instead of a mystery status number).
    case invalidArgument
    /// `CHALK_ERR_FILE_NOT_FOUND`: the path does not exist or is not
    /// readable.
    case fileNotFound
    /// `CHALK_ERR_UNSUPPORTED_FORMAT`: WIC has no decoder installed for this
    /// file's container format on this machine (the HEIC-without-HEIF-
    /// Extensions case -- see this type's doc comment above). Report this to
    /// the user as "unsupported format on this system", never as a generic
    /// decode failure.
    case unsupportedFormat
    /// `CHALK_ERR_DECODE_FAILED`: WIC opened the file and recognizes its
    /// format, but could not decode pixel data from it (corrupt/truncated
    /// file).
    case decodeFailed
    /// `CHALK_ERR_IMAGE_TOO_LARGE`: WIC successfully decoded the file's
    /// pixel dimensions, but they exceed the shim's safety bound (16,384px
    /// per axis, or 20,000,000px total -- see the check's comment in
    /// chalk_image.cpp). The path and every argument to the call were fine;
    /// it is the image's own content that is too large. Kept distinct from
    /// `.invalidArgument` on purpose -- see that code's doc comment above,
    /// and `CHALK_ERR_IMAGE_TOO_LARGE` in chalkboard_win.h.
    case imageTooLarge
    /// `CHALK_ERR_WIC_INIT_FAILED`: the WIC imaging factory itself could not
    /// be created -- not specific to this one file; no image can decode
    /// right now.
    case wicInitFailed
    /// `CHALK_ERR_OUT_OF_MEMORY`: a heap/COM allocation failed while
    /// decoding.
    case outOfMemory
    /// Any other status the shim returned. Carries the raw code (see
    /// chalkboard_win.h's `ChalkErrorCode` for what it means) rather than
    /// silently discarding it, since every code the shim can actually return
    /// from this call is already named above -- reaching `.unknown` would
    /// itself be a sign this mapping has drifted from the header.
    case unknown(Int32)
}

/// Wraps the `ChalkImage` `chalk_image_decode_file` vends so it can be
/// handed to `AnnotationRenderer` as an opaque `RasterImageHandle` -- the
/// renderer itself never sees `ChalkImage`, exactly as it never sees
/// `NSImage` on macOS (see `NSImageRasterHandle`'s matching doc comment).
///
/// `public`, not `internal`: `RasterAssetStore`'s Windows branch returns
/// this type directly from its own `public` API (`image(id:)`,
/// `Lease.image(id:)`) to mirror macOS returning `NSImage?` from the same
/// call sites one-for-one -- see that file's Windows `Lease.image(id:)` doc
/// comment. A `public` function cannot return an `internal` type, so this
/// class (and the two stored properties `RasterImageHandle` itself
/// requires as public) must be `public` too; `image` stays internal, since
/// its only other reader (`GDIPlusDrawingContext`) is in this same module.
public final class WindowsRasterImage: RasterImageHandle {
    /// The decoded image handle. Not `private` -- `GDIPlusDrawingContext`,
    /// the only other file in this module allowed to touch platform image
    /// types, reaches through this to call `chalk_rt_draw_image`.
    let image: ChalkImage

    public let pixelWidth: Int
    public let pixelHeight: Int

    private init(image: ChalkImage, pixelWidth: Int, pixelHeight: Int) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    deinit {
        chalk_image_destroy(image)
    }

    /// Decodes the image file at `path` via `chalk_image_decode_file` (WIC
    /// under the hood) into a new `WindowsRasterImage`. Throws
    /// `WindowsRasterImageError` on any failure -- see that type's doc
    /// comment for why `.unsupportedFormat` in particular must never be
    /// folded into `.decodeFailed` by a caller.
    static func decode(path: String) throws -> WindowsRasterImage {
        var utf16 = Array(path.utf16)
        utf16.append(0)

        var outImage: ChalkImage?
        var outWidth: Int32 = 0
        var outHeight: Int32 = 0
        let status: Int32 = utf16.withUnsafeBufferPointer { buf in
            chalk_image_decode_file(buf.baseAddress, &outImage, &outWidth, &outHeight)
        }

        guard status == 0, let decoded = outImage else {
            throw WindowsRasterImageError(shimStatus: status)
        }
        return WindowsRasterImage(image: decoded, pixelWidth: Int(outWidth), pixelHeight: Int(outHeight))
    }
}

// `internal`, not `private`: `RasterAssetStoreTests` (in the
// `AIChalkboardCoreTests` target, via `@testable import`) calls
// `init(shimStatus:)` directly to pin the -206 -> `.imageTooLarge` mapping
// without needing to decode a genuinely 16,384px+ fixture image.
extension WindowsRasterImageError {
    /// Maps a `chalk_image_decode_file` status to the matching case, using
    /// the literal numeric values chalkboard_win.h documents (see
    /// `GDIPlusDrawingContext`'s path-op-code comment for why this file
    /// deliberately does not depend on how ClangImporter shapes the
    /// imported `ChalkErrorCode` C enum).
    init(shimStatus: Int32) {
        switch shimStatus {
        case -1: self = .invalidArgument
        case -201: self = .fileNotFound
        case -203: self = .unsupportedFormat
        case -202: self = .decodeFailed
        case -206: self = .imageTooLarge
        case -200: self = .wicInitFailed
        case -2: self = .outOfMemory
        default: self = .unknown(shimStatus)
        }
    }
}
#endif
