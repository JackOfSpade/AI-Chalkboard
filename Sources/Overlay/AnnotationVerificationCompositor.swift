#if os(macOS)
import AppKit
import ImageIO
#elseif os(Windows)
import CChalkboardWin
#endif
import Foundation

/// Platform-neutral. `.unsupportedFormatOnSystem` and `.decodingUnavailable`
/// are reachable ONLY from the Windows `loadScreenshot(path:)` branch below
/// (WIC can report failure classes ImageIO has no equivalent for -- see
/// `RasterAssetStoreError`'s matching cases, which this mirrors exactly for
/// the same reason) and are simply never thrown on macOS.
enum AnnotationVerificationError: LocalizedError {
    case invalidPath
    case unreadableFile
    case unsupportedImage
    case imageTooLarge
    case aspectRatioMismatch(scaleX: Double, scaleY: Double)
    /// The supplied screenshot's dimensions are accepted by MORE THAN ONE
    /// currently-connected display, and the caller did not say which display
    /// it actually photographed. Kept separate from `.aspectRatioMismatch`
    /// because the two mean opposite things: that one says the image fits NO
    /// plausible full-display capture of the annotation's screen, this one
    /// says it fits SEVERAL displays equally well and identity, not geometry,
    /// is the missing evidence.
    case ambiguousScreenshotDisplay(
        screenshotWidth: Int,
        screenshotHeight: Int,
        acceptingScreenIds: [String],
        annotationScreenId: String
    )
    case renderFailed
    /// The renderer ran to completion and produced a valid bitmap, it just
    /// contains no non-transparent pixel.  Kept separate from `renderFailed`
    /// because the two need opposite responses from an agent: this one means
    /// the annotation's own coordinates/colors put nothing on this screen,
    /// not that Core Graphics failed.
    case annotationPaintedNothing(screenWidthPx: Int, screenHeightPx: Int)
    case outputTooLarge
    /// WINDOWS ONLY: see `RasterAssetStoreError.unsupportedFormatOnSystem`.
    case unsupportedFormatOnSystem
    /// WINDOWS ONLY: see `RasterAssetStoreError.decodingUnavailable`.
    case decodingUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "screenshot_path must be an absolute path to a local raster image."
        case .unreadableFile:
            return "The screenshot file does not exist, is not a regular readable file, or exceeds the 50 MB input limit."
        case .unsupportedImage:
            return "The screenshot could not be decoded as a single-frame PNG, JPEG, HEIC, or TIFF image."
        case .imageTooLarge:
            return "The decoded screenshot exceeds the 20-megapixel safety limit. Downsample it before verification."
        case .aspectRatioMismatch(let scaleX, let scaleY):
            return String(
                format: "The screenshot does not look like a full-display capture of the annotation's screen (x scale %.6f, y scale %.6f). Supply the uncropped full-display screenshot; cropped/window screenshots cannot be mapped safely.",
                scaleX, scaleY
            )
        case .ambiguousScreenshotDisplay(let screenshotWidth, let screenshotHeight, let acceptingScreenIds, let annotationScreenId):
            return "Ambiguous verification screenshot rejected: source=\(screenshotWidth)x\(screenshotHeight) px matches \(acceptingScreenIds.count) connected displays (ids: \(acceptingScreenIds.joined(separator: ", "))) and no screenshot_screen_id was supplied. The annotation lives on display \(annotationScreenId), but a screenshot is the image of one specific display and its dimensions cannot say which, so this image may be of a different display entirely -- verifying against it would show the annotation over unrelated UI and report a placement error that does not exist. Nothing was verified; retry with screenshot_screen_id naming the display the screenshot was really taken from, or use capture_source='chalkboard' to have Chalkboard capture display \(annotationScreenId) itself."
        case .renderFailed:
            return "Failed to render the annotation verification image."
        case .annotationPaintedNothing(let screenWidthPx, let screenHeightPx):
            return "The annotation rendered without error but painted no pixels anywhere on its \(screenWidthPx)x\(screenHeightPx) screen, so there is no region to crop or verify. Check that its coordinates fall inside that screen and that its stroke/fill colors, opacity, and path data are not empty or fully transparent."
        case .outputTooLarge:
            return "The verification PNG exceeds the raw-image allowance for the 8 MB encoded MCP response limit. Use a smaller or more tightly cropped screenshot."
        case .unsupportedFormatOnSystem:
            return "Windows has no image decoder installed for this screenshot's format. This is the common outcome for HEIC/HEIF files when the Microsoft \"HEIF Image Extensions\" are not installed from the Microsoft Store. Install the codec, or convert/re-export the screenshot to PNG, JPEG, TIFF, or BMP, then retry."
        case .decodingUnavailable:
            return "The Windows image decoder could not decode this screenshot because of a system-level failure (decoder initialization or a memory allocation failure), not a problem with the file itself. Retry, or restart AI Chalkboard if the failure persists."
        }
    }
}

struct AnnotationVerificationComposite {
    let pngData: Data
    let metadata: [String: Any]
}

/// Produces the image an agent actually needs for placement verification:
/// the stored annotation composited into a clean, caller-supplied screenshot.
///
/// This deliberately does NOT capture the overlay window (macOS: computer-use
/// has proven it filters that window even when `sharingType == .readOnly`;
/// Windows: `chalk_capture_monitor` has no exclusion mechanism at all -- see
/// `ScreenCaptureExclusionScope`'s Windows doc comment -- so it would show
/// the LIVE overlay AND this synthetic one stacked together, which is worse,
/// not better). Instead, this uses `AnnotationRenderer` -- the SAME renderer
/// code the live overlay uses, wrapped in the platform's own `DrawingContext`
/// (`CoreGraphicsDrawingContext` on macOS, `GDIPlusDrawingContext` on
/// Windows) -- against the same screen point geometry, then scales the
/// result into the screenshot. The resulting crop proves coordinate
/// alignment against the UI pixels the agent saw without claiming that the
/// desktop compositor presented the separate live overlay window.
///
/// PLATFORM NOTE ON "THE SAME RENDERER": `AnnotationRenderer` is genuinely
/// the identical Swift source on both platforms -- the same draw calls, the
/// same coordinate math, the same primitive dispatch. What differs is the
/// RASTERIZER underneath it: Quartz/Core Graphics on macOS, GDI+ on Windows.
/// Different rasterizers legitimately produce different antialiasing,
/// hinting, and rounding, so a Windows verification PNG is NOT bit-identical
/// to a macOS verification PNG of the same annotation on the same geometry.
/// The honest claim is "the same renderer, verified by cross-check against
/// the platform's own screenshot", never "the same pixels" -- see
/// `verificationNote` in each branch's metadata below, which says this
/// directly rather than letting a caller infer bit-identity that was never
/// tested or true.
enum AnnotationVerificationCompositor {
    static let defaultPaddingPx = 120.0
    static let maxPaddingPx = 1_000.0
    static let maxInputFileBytes: UInt64 = 50 * 1_024 * 1_024
    static let maxImagePixels = 20_000_000
    /// Total JSON-RPC line budget reserved for a verification response.  MCP
    /// carries image data as base64, so an 8 MiB PNG would become more than
    /// 10 MiB before JSON framing and cannot actually fit in this limit.
    static let maxTransportResponseBytes = DrawingDefaults.maxMCPResponseBytes

    /// Conservative room for JSON-RPC/MCP structure, metadata text, MIME
    /// type, and line framing.  Annotation IDs are server-generated UUIDs,
    /// and verification metadata is bounded, so this leaves substantial room
    /// while keeping the raw-image calculation deterministic.
    static let maxTransportOverheadBytes = 64 * 1_024

    /// Largest raw PNG that can be base64 encoded while retaining the above
    /// transport reserve.  Base64 expands every 3 bytes into 4, hence the
    /// floor-to-a-multiple-of-four calculation.
    static let maxRawPNGBytes = ((maxTransportResponseBytes - maxTransportOverheadBytes) / 4) * 3

    /// - Parameter ambiguityCandidateScreens: the currently-connected displays
    ///   this image's dimensions must be checked against for
    ///   which-display ambiguity, or EMPTY when the caller has already
    ///   established which display it is of. See
    ///   `ambiguousDisplayRejection(...)`. It is deliberately a parameter of
    ///   the SCREENSHOT-PATH entry point only: the image's real dimensions are
    ///   not known until it is decoded, and this is the layer that decodes it
    ///   -- a probe in the MCP handler would have to open the file a second
    ///   time and could then disagree with the decode that actually renders
    ///   (the same second-open TOCTOU gap `loadScreenshot`'s Windows note
    ///   documents).
    static func composite(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshotPath: String,
        paddingPx: Double = defaultPaddingPx,
        rasterLease: RasterAssetStore.Lease? = nil,
        ambiguityCandidateScreens: [ScreenInfo] = []
    ) throws -> AnnotationVerificationComposite {
        #if os(macOS)
        let screenshot = try loadScreenshot(path: screenshotPath)
        return try composite(
            annotation: annotation,
            screen: screen,
            screenshot: screenshot,
            paddingPx: paddingPx,
            rasterLease: rasterLease,
            ambiguityCandidateScreens: ambiguityCandidateScreens
        )
        #elseif os(Windows)
        let decoded = try loadScreenshot(path: screenshotPath)
        // `chalkboard_win.h` exposes no "read a ChalkImage's raw pixels"
        // call (see `loadScreenshot`'s doc comment) -- the only way to get
        // WIC-decoded bytes back out is to draw the image through GDI+ into
        // a render target and read THAT target's buffer. This target is
        // sized 1:1 to the decoded image with NO extra scale (`scaleX: 1,
        // scaleY: 1`, i.e. the plain `init(width:height:)` below) -- unlike
        // the anisotropic-scaled target `compositeCore` builds for the
        // annotation layer, this one exists purely to materialize pixels
        // that are already at their final resolution.
        guard let rasterContext = GDIPlusDrawingContext(width: decoded.pixelWidth, height: decoded.pixelHeight) else {
            throw AnnotationVerificationError.renderFailed
        }
        rasterContext.drawImage(
            decoded,
            in: CGRect(x: 0, y: 0, width: decoded.pixelWidth, height: decoded.pixelHeight),
            alpha: 1
        )
        guard let pixels = rasterContext.pixelBuffer else { throw AnnotationVerificationError.renderFailed }
        // `rasterContext` (and therefore the buffer `pixels` points into)
        // must stay alive for as long as `compositeCore` reads from it.
        // Swift ARC keeps it alive here because `rasterContext` is still a
        // live local in this function's scope for the entire synchronous
        // `compositeCore` call below -- see `RawScreenshotBuffer`'s doc
        // comment for why the type itself does not retain anything.
        let buffer = RawScreenshotBuffer(
            bytes: UnsafePointer(pixels),
            width: decoded.pixelWidth,
            height: decoded.pixelHeight,
            stride: rasterContext.bytesPerRow
        )
        return try compositeCore(
            annotation: annotation, screen: screen, screenshot: buffer,
            paddingPx: paddingPx, rasterLease: rasterLease,
            ambiguityCandidateScreens: ambiguityCandidateScreens
        )
        #endif
    }

    #if os(macOS)
    /// In-memory sibling used by Chalkboard-owned ScreenCaptureKit capture.
    /// Keeping it on the same implementation as the path-based overload means
    /// the crop, coordinate validation, and exact OverlayView renderer cannot
    /// drift between external and internal verification sources.
    ///
    /// `ambiguityCandidateScreens` defaults to EMPTY here because the
    /// in-memory caller this overload exists for is Chalkboard-owned
    /// ScreenCaptureKit capture, which captures the annotation's own display
    /// by construction and so has no which-display question to answer. The
    /// path-based overload above forwards the handler's connected-screen list
    /// through it.
    static func composite(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshot: CGImage,
        paddingPx: Double = defaultPaddingPx,
        rasterLease: RasterAssetStore.Lease? = nil,
        ambiguityCandidateScreens: [ScreenInfo] = []
    ) throws -> AnnotationVerificationComposite {
        let imageWidth = screenshot.width
        let imageHeight = screenshot.height

        let scaleX = Double(imageWidth) / Double(screen.widthPx)
        let scaleY = Double(imageHeight) / Double(screen.heightPx)
        guard let screenshotScale = ScreenshotGeometry.fullDisplayScale(
            screenshotWidth: Double(imageWidth),
            screenshotHeight: Double(imageHeight),
            screenWidth: Double(screen.widthPx),
            screenHeight: Double(screen.heightPx)
        ) else {
            throw AnnotationVerificationError.aspectRatioMismatch(scaleX: scaleX, scaleY: scaleY)
        }
        // AFTER the scale check, exactly as the draw path orders its two
        // screenshot guards: an image that fits NO display is a mismatch
        // (unchanged behavior), and only an image that fits the annotation's
        // own display can go on to be ambiguous between it and another.
        if let ambiguous = ambiguousDisplayRejection(
            screenshotWidth: imageWidth,
            screenshotHeight: imageHeight,
            annotationScreenId: screen.id,
            candidates: ambiguityCandidateScreens
        ) {
            throw ambiguous
        }

        // Rendering the annotation onto its own transparent layer genuinely
        // needs the main thread -- it goes through AppKit/Core Graphics
        // state (NSGraphicsContext.current, the shared graphics-state
        // stack). Finding the painted bounding box afterwards is a plain
        // byte scan over an already-produced buffer -- up to
        // `maxImagePixels` of it -- so it deliberately runs AFTER this
        // block, on the calling thread, instead of inside it. Scanning 20
        // megapixels one byte at a time on the main thread would block
        // AppKit's run loop (window ordering, and any other queued
        // `MainThread.sync` work, including the overlay's own repaints) for
        // the scan's whole duration.
        //
        // `renderAnnotationAlone` is the SAME "render this one annotation
        // alone into a transparent bitmap the size of `screen`'s backing
        // pixels, then scan for its non-transparent bounds" implementation
        // `renderedPaintedBounds(of:on:rasterLease:)` below uses for
        // `get_annotation_bounds` -- factored into one place so the two can
        // never independently disagree about where an annotation paints.
        let lease = rasterLease ?? RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)
        let (overlayRep, paintedTopLeftOptional) = try renderAnnotationAlone(
            annotation,
            widthPx: imageWidth, heightPx: imageHeight,
            pointsSize: CGSize(width: screen.widthPt, height: screen.heightPt),
            backingScaleFactor: screen.backingScaleFactor,
            lease: lease
        )

        // Reaching here means the bitmap and its context were both created and
        // the renderer ran; an empty painted box is therefore a statement about
        // the annotation, not about the rendering machinery. Fully off-screen
        // coordinates, zero opacity, a transparent color, and an empty path are
        // all storable and all land exactly here.
        guard let paintedTopLeft = paintedTopLeftOptional else {
            throw AnnotationVerificationError.annotationPaintedNothing(
                screenWidthPx: screen.widthPx,
                screenHeightPx: screen.heightPx
            )
        }
        // NSBitmapImageRep's raw rows are top-to-bottom, while NSImage's
        // `draw(from:)` source rect uses AppKit's bottom-left coordinates.
        // Keep both explicit; conflating them crops the vertically mirrored
        // UI region even though the annotation itself rendered correctly.
        let paintedAppKit = CGRect(
            x: paintedTopLeft.minX,
            y: CGFloat(imageHeight) - paintedTopLeft.maxY,
            width: paintedTopLeft.width,
            height: paintedTopLeft.height
        )

        let safePadding = CGFloat(min(max(paddingPx, 0), maxPaddingPx))
        let fullBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let cropAppKit = paintedAppKit
            .insetBy(dx: -safePadding, dy: -safePadding)
            .integral
            .intersection(fullBounds)
        guard cropAppKit.width >= 1, cropAppKit.height >= 1 else {
            throw AnnotationVerificationError.renderFailed
        }

        let cropWidth = Int(cropAppKit.width)
        let cropHeight = Int(cropAppKit.height)

        // Compositing the crop is rendering too (NSImage.draw through
        // AppKit), so it goes back through the main thread -- this second,
        // short hop is cheap compared to the scan this restructuring just
        // moved out of the main thread's way.
        let pngData: Data = try MainThread.sync {
            guard let cropRep = makeBitmap(width: cropWidth, height: cropHeight),
                  let cropContext = NSGraphicsContext(bitmapImageRep: cropRep) else {
                throw AnnotationVerificationError.renderFailed
            }

            let screenshotImage = NSImage(
                cgImage: screenshot,
                size: NSSize(width: imageWidth, height: imageHeight)
            )
            let overlayImage = NSImage(size: NSSize(width: imageWidth, height: imageHeight))
            overlayImage.addRepresentation(overlayRep)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = cropContext
            let destination = CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight)
            screenshotImage.draw(in: destination, from: cropAppKit, operation: .copy, fraction: 1)
            overlayImage.draw(in: destination, from: cropAppKit, operation: .sourceOver, fraction: 1)
            cropContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            guard let pngData = cropRep.representation(using: .png, properties: [:]) else {
                throw AnnotationVerificationError.renderFailed
            }
            return pngData
        }

        guard isWithinResponseBudget(rawPNGBytes: pngData.count) else {
            throw AnnotationVerificationError.outputTooLarge
        }

        let cropTopLeftY = CGFloat(imageHeight) - cropAppKit.maxY
        let clipped = cropAppKit.minX == 0 || cropAppKit.minY == 0
            || cropAppKit.maxX == CGFloat(imageWidth) || cropAppKit.maxY == CGFloat(imageHeight)

        let metadata: [String: Any] = [
            "annotationId": annotation.id,
            "annotationType": annotation.kind.typeName,
            // `screen.id`, NOT `annotation.screenId`: the caller resolved
            // `screen` from `annotation.effectiveScreenId` precisely so an
            // anchored annotation whose window has been dragged onto a second
            // display is verified against the display it lives on NOW. This
            // metadata names the display this image was actually composited
            // and cropped against, so reporting the immutable creation-time
            // field here would hand back a screenId contradicting the very
            // picture it accompanies -- and, once the original display is
            // disconnected, one that no longer exists at all.
            "screenId": screen.id,
            "screenBackingPixels": ["width": screen.widthPx, "height": screen.heightPx],
            "screenPoints": ["width": screen.widthPt, "height": screen.heightPt],
            "backingScaleFactor": screen.backingScaleFactor,
            "screenshotPixels": ["width": imageWidth, "height": imageHeight],
            "scaleToScreenshot": ["x": scaleX, "y": scaleY],
            "scaleDifferencePercent": screenshotScale.relativeDifference * 100,
            "maximumScaleDifferencePercent": screenshotScale.maximumRelativeDifference * 100,
            "paintedBoundsScreenshotPx": rectObject(
                x: paintedTopLeft.minX,
                y: paintedTopLeft.minY,
                width: paintedTopLeft.width,
                height: paintedTopLeft.height
            ),
            "cropScreenshotPx": rectObject(
                x: cropAppKit.minX,
                y: cropTopLeftY,
                width: cropAppKit.width,
                height: cropAppKit.height
            ),
            "cropClippedAtScreenEdge": clipped,
            "verificationKind": "synthetic-composite",
            // The note NAMES the display (already carried structurally as
            // `screenId` above -- stated here too rather than added as a
            // second field) because that is the one assumption a verification
            // image cannot show: the screenshot was INTERPRETED as a
            // full-display capture of this display, and a screenshot of any
            // other display would compose a convincing picture that proves
            // nothing. See `ambiguousDisplayRejection`.
            "verificationNote": "This image uses the live OverlayView renderer composited into the selected clean screenshot source, interpreted as a full-display image of display \(screen.id) (see screenId) -- the display this annotation lives on, and the only display whose screenshot can prove or refute its placement. It verifies annotation-to-UI coordinate placement; it does not prove raw-framebuffer pixels, occlusion, or that WindowServer presented the separate overlay window."
        ]

        return AnnotationVerificationComposite(pngData: pngData, metadata: metadata)
    }

    private static func loadScreenshot(path: String) throws -> CGImage {
        let data: Data
        do {
            data = try BoundedLocalFile.read(path: path, maxBytes: maxInputFileBytes)
        } catch BoundedLocalFileError.invalidPath {
            throw AnnotationVerificationError.invalidPath
        } catch {
            throw AnnotationVerificationError.unreadableFile
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.tiff"].contains(type) else {
            throw AnnotationVerificationError.unsupportedImage
        }

        // ImageIO defers the expensive bitmap decode until
        // `CGImageSourceCreateImageAtIndex`. Read the container dimensions
        // first so a tiny compressed image that declares a huge raster is
        // rejected without allocating its decoded pixels. Missing or malformed
        // dimensions fail closed; valid metadata is still not a security
        // boundary, so keep the same check after decode for inconsistent
        // containers.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let metadataDimensions = usableMetadataDimensions(properties) else {
            // A decoder cannot safely authorize an allocation when its own
            // width/height metadata is absent, non-integral, or outside Swift
            // integer range. This has the same caller-facing meaning as any
            // other unsupported/unreadable image container.
            throw AnnotationVerificationError.unsupportedImage
        }
        guard imageDimensionsFitImageLimit(width: metadataDimensions.width, height: metadataDimensions.height) else {
            throw AnnotationVerificationError.imageTooLarge
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnnotationVerificationError.unsupportedImage
        }
        guard imageDimensionsFitImageLimit(width: image.width, height: image.height) else {
            throw AnnotationVerificationError.imageTooLarge
        }
        return image
    }

    /// Promoted from `loadScreenshot(path:)`'s own decode so
    /// `register_screenshot_space` (Sources/MCP/MCPToolHandlers+ScreenshotSpace.swift)
    /// can MEASURE a screenshot file's true pixel dimensions -- the
    /// strongest of the three provenances a `ScreenshotSpace` can carry (see
    /// that type's own header comment) -- without a second, independent
    /// decode path that could silently drift from the one `verify_annotation`
    /// already trusts for exactly the same file-format/size validation.
    /// Every guard `loadScreenshot` already applies (absolute-path check via
    /// `BoundedLocalFile`, the 50 MB input cap, single-frame PNG/JPEG/HEIC/
    /// TIFF only, the 20-megapixel decode cap) applies here for free, because
    /// this calls that exact function and only reads `width`/`height` off
    /// the fully validated result -- see `RasterAssetStore`'s own decoded-
    /// size cap for the identical "validate once, reuse everywhere"
    /// precedent this mirrors.
    static func screenshotPixelDimensions(path: String) throws -> (width: Int, height: Int) {
        let image = try loadScreenshot(path: path)
        return (image.width, image.height)
    }

    /// Pure dimension arithmetic used by the ImageIO metadata preflight and
    /// post-decode defense-in-depth check. Division avoids multiplying
    /// attacker-controlled dimensions, so the pixel-limit test cannot
    /// overflow before it rejects an oversized image.
    static func imageDimensionsFitImageLimit(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return width <= maxImagePixels / height
    }

    /// Returns the declared positive dimensions only when ImageIO supplied
    /// both as representable integers. The decode path treats `nil` as an
    /// unsupported image rather than guessing or allocating first.
    static func usableMetadataDimensions(_ properties: [CFString: Any]?) -> (width: Int, height: Int)? {
        guard let properties,
              let width = imageDimension(properties[kCGImagePropertyPixelWidth]),
              let height = imageDimension(properties[kCGImagePropertyPixelHeight]),
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func imageDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              // `stringValue` preserves NSNumber's integer spelling, so
              // `Int` accepts only an exact, in-range integer. In contrast,
              // `int64Value` silently truncates 1.5 and clamps non-finite or
              // out-of-range floating values, which could authorize a decode
              // under dimensions ImageIO did not actually declare.
              let dimension = Int(number.stringValue) else {
            return nil
        }
        return dimension
    }

    private static func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
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
        )
    }

    /// Renders `annotation` ALONE onto a fresh transparent `widthPx`x`heightPx`
    /// bitmap and returns both the bitmap and its non-transparent pixel bounds
    /// (raw bitmap row coordinates, top-left origin -- see `paintedPixelBounds
    /// (in:)`'s doc comment -- or `nil` if nothing painted). `pointsSize` is the
    /// point-space canvas `AnnotationRenderer` draws into (see its own
    /// coordinate-space doc comment); `widthPx`/`heightPx` is the PHYSICAL
    /// output resolution that canvas is scaled up to before drawing.
    ///
    /// THE ONE RENDER-AND-SCAN IMPLEMENTATION, shared by two callers that must
    /// never independently disagree about where an annotation paints:
    ///   * `composite(...)` above, which goes on to use the returned bitmap as
    ///     the top layer it composites over a caller-supplied screenshot.
    ///   * `renderedPaintedBounds(of:on:rasterLease:)` below, which
    ///     `get_annotation_bounds` (Sources/MCP/MCPToolHandlers+AnnotationBounds.swift)
    ///     calls for a placement answer with NO screenshot involved at all.
    /// Duplicating this render+scan into a second, independent implementation
    /// is exactly the drift this factoring exists to make impossible -- see
    /// `renderedPaintedBounds`'s own doc comment for why that matters for
    /// text, a rotated image, an `offset_x`/`offset_y`, and a live anchor
    /// adjustment.
    private static func renderAnnotationAlone(
        _ annotation: Annotation,
        widthPx: Int,
        heightPx: Int,
        pointsSize: CGSize,
        backingScaleFactor: Double,
        lease: RasterAssetStore.Lease
    ) throws -> (bitmap: NSBitmapImageRep, paintedBounds: CGRect?) {
        // Rendering genuinely needs the main thread -- it goes through
        // AppKit/Core Graphics state (NSGraphicsContext.current, the shared
        // graphics-state stack). The painted-bounds SCAN does not, so the
        // `MainThread.sync` block below ends at `flushGraphics()` and
        // returns only the bitmap; `paintedPixelBounds(in:)` then runs on
        // the CALLING thread, after the block. That split is the exact
        // promise `composite(...)`'s own comment above makes ("scanning 20
        // megapixels ... on the main thread would block AppKit's run
        // loop"): the scan reads up to `maxImagePixels` of buffer (a full
        // 5K display is ~14.7 million pixels), every caller reaches this
        // helper from the MCP background queue, and
        // `DrawRequest.resolveAvoidance` performs up to 32 avoided-id
        // measurements plus a bounded convergence loop of them per avoid=
        // draw -- scanning inside the sync block would stall window
        // ordering, all other queued `MainThread.sync` work, and the
        // overlay's own repaints for every one of those scans in turn.
        //
        // Handing the bitmap across threads is race-free: it is a freshly
        // allocated, self-owned `NSBitmapImageRep` (never a CGImage-backed
        // or otherwise lazily-produced one -- see `makeBitmap`), fully
        // written by `flushGraphics()` before this block returns it, and
        // nothing mutates it afterwards. Main thread to calling thread is a
        // one-way, one-time transfer, not concurrent access.
        let overlayRep: NSBitmapImageRep = try MainThread.sync {
            guard let overlayRep = makeBitmap(width: widthPx, height: heightPx),
                  let overlayContext = NSGraphicsContext(bitmapImageRep: overlayRep) else {
                throw AnnotationVerificationError.renderFailed
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = overlayContext
            let cgContext = overlayContext.cgContext
            let outputRect = CGRect(x: 0, y: 0, width: widthPx, height: heightPx)
            cgContext.clear(outputRect)
            cgContext.saveGState()
            cgContext.clip(to: outputRect)

            // OverlayView itself is sized in NSScreen.frame points. Scaling
            // that point canvas into the requested output resolution
            // preserves fixed-point strokes/fonts and physical-pixel paths
            // exactly as the live renderer would look after a screenshot's
            // resampling step.
            cgContext.scaleBy(
                x: CGFloat(widthPx) / pointsSize.width,
                y: CGFloat(heightPx) / pointsSize.height
            )
            let drawingContext = CoreGraphicsDrawingContext(context: cgContext)
            AnnotationRenderer.drawAnnotations(
                [annotation],
                into: drawingContext,
                canvasSize: pointsSize,
                // The SAME definition `OverlayView.draw(_:)` (the live macOS
                // overlay) reads -- see
                // `OverlayDrawingMetrics.rendererScaleFactor`. A verification
                // rendered at any other scale than the live overlay's would
                // report a placement nothing ever painted.
                scaleFactor: OverlayDrawingMetrics.rendererScaleFactor(
                    displayBackingScaleFactor: CGFloat(backingScaleFactor)
                )
            ) { assetId in
                lease.image(id: assetId).map(NSImageRasterHandle.init)
            }
            cgContext.restoreGState()
            overlayContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return overlayRep
        }
        return (overlayRep, paintedPixelBounds(in: overlayRep))
    }

    /// Renders `annotation` ALONE into a transparent bitmap the size of
    /// `screen`'s backing pixels using the exact live `AnnotationRenderer` --
    /// the SAME rendering `composite(...)` performs internally before ever
    /// touching a caller's screenshot -- and returns its non-transparent
    /// pixel bounds in TOP-LEFT-origin backing-pixel space of `screen` (the
    /// same coordinate convention every MCP drawing coordinate already uses),
    /// or `nil` if the annotation painted nothing.
    ///
    /// This is the single source of truth `get_annotation_bounds` reports
    /// (see Sources/MCP/MCPToolHandlers+AnnotationBounds.swift): it shares
    /// `renderAnnotationAlone` with `composite(...)` above rather than
    /// running a second, independently-computed geometry estimate (compare
    /// `PaintedBounds.swift`, which IS such an estimate but is explicitly
    /// documented as "good enough to pick a window", never pixel-exact) --
    /// which is what makes the answer correct for text (real glyph metrics,
    /// unavailable without a live drawing context), a rotated image, an
    /// `offset_x`/`offset_y`, and a live anchor adjustment.
    ///
    /// TOUCHES NO SCREEN-CAPTURE API AND NEEDS NO SCREEN RECORDING
    /// PERMISSION: every step is Core Graphics/AppKit OFFSCREEN bitmap
    /// rendering (`NSBitmapImageRep`, `NSGraphicsContext`, `CGContext`) --
    /// the same machinery `composite(...)` already uses for its own
    /// "annotation alone" pass. Nothing here calls `CGDisplayCreateImage`,
    /// `CGWindowListCreateImage`, ScreenCaptureKit, `screencapture`, or any
    /// other capture entry point.
    ///
    /// CACHED: an unchanged annotation's painted bounds are a pure function
    /// of the cache key (see `PaintedBoundsCacheKey`'s doc comment for the
    /// field-by-field invalidation reasoning), so this consults
    /// `paintedBoundsCache` before rendering and populates it after -- a
    /// repeat measurement of an unchanged annotation costs a dictionary
    /// lookup instead of a full-display render plus scan, which is what
    /// `DrawRequest.resolveAvoidance` pays up to 32 times per avoid= draw.
    /// `composite(...)` deliberately does NOT use this cache: it renders at
    /// the screenshot's dimensions, not the screen's, and needs the bitmap
    /// itself, not just the bounds.
    static func renderedPaintedBounds(
        of annotation: Annotation,
        on screen: ScreenInfo,
        rasterLease: RasterAssetStore.Lease? = nil
    ) throws -> CGRect? {
        let cacheKey = paintedBoundsCacheKey(for: annotation, on: screen)
        if let cacheKey, let cached = paintedBoundsCache.lookup(cacheKey) {
            return cached.bounds
        }
        let lease = rasterLease ?? RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)
        let (_, bounds) = try renderAnnotationAlone(
            annotation,
            widthPx: screen.widthPx, heightPx: screen.heightPx,
            pointsSize: CGSize(width: screen.widthPt, height: screen.heightPt),
            backingScaleFactor: screen.backingScaleFactor,
            lease: lease
        )
        if let cacheKey {
            paintedBoundsCache.store(bounds, for: cacheKey)
        }
        return bounds
    }

    /// Returns painted bounds in raw bitmap row coordinates (top-left origin).
    /// The bitmap starts transparent, so any non-zero byte identifies an
    /// antialiased annotation pixel regardless of channel byte ordering.
    /// Delegates to the platform-neutral word-scanning core -- see
    /// `paintedPixelBounds(bytes:width:height:bytesPerPixel:bytesPerRow:)`
    /// below for why eight-bytes-per-load scanning returns bit-identical
    /// answers to the byte-at-a-time loop it replaced.
    private static func paintedPixelBounds(in bitmap: NSBitmapImageRep) -> CGRect? {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel >= 4 else { return nil }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else { return nil }
        return paintedPixelBounds(
            bytes: UnsafeRawPointer(data),
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            bytesPerPixel: bytesPerPixel,
            bytesPerRow: bitmap.bytesPerRow
        )
    }
    #elseif os(Windows)
    /// A read-only view over a screenshot's raw premultiplied-BGRA pixel
    /// bytes, top-down, used only to unify the two Windows `composite()`
    /// entry points above/below (a WIC-decoded file, materialized through a
    /// throwaway GDI+ target; and `chalk_capture_monitor`'s live capture)
    /// onto ONE compositing implementation, `compositeCore`.
    ///
    /// Deliberately owns nothing: it borrows `bytes` from whichever object
    /// actually owns the memory (a `GDIPlusDrawingContext`'s render target,
    /// or a `WindowsScreenCaptureImage`), and both call sites keep that
    /// owner alive for this struct's entire (synchronous, non-escaping)
    /// lifetime -- see each call site's comment.
    ///
    /// `chalk_capture_monitor`'s buffer is documented STRAIGHT alpha, not
    /// premultiplied, while a GDI+ render target's buffer (the decoded-file
    /// path) genuinely is premultiplied. `compositeCore` copies either one's
    /// bytes directly into a premultiplied-BGRA render target as its
    /// background layer without converting -- exactly correct wherever
    /// alpha is 255, which chalk_capture_monitor's own doc comment says is
    /// "typical...for an opaque screen capture" (true for every real
    /// desktop capture) and which is also what a normal opaque screenshot
    /// file has. A screenshot with genuine partial transparency at the
    /// crop's edges is the one input this does not handle exactly -- see
    /// this port's contract notes for the precise, honest statement of that
    /// limitation.
    private struct RawScreenshotBuffer {
        let bytes: UnsafePointer<UInt8>
        let width: Int
        let height: Int
        let stride: Int
    }

    /// In-memory sibling used by Chalkboard-owned `chalk_capture_monitor`
    /// capture. Keeping it on the same `compositeCore` implementation as the
    /// path-based overload above means the crop, coordinate validation, and
    /// exact `AnnotationRenderer` call cannot drift between external and
    /// internal verification sources -- the same guarantee the macOS
    /// overload's doc comment makes.
    static func composite(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshot: WindowsScreenCaptureImage,
        paddingPx: Double = defaultPaddingPx,
        rasterLease: RasterAssetStore.Lease? = nil
    ) throws -> AnnotationVerificationComposite {
        // `screenshot` (the parameter) is a live local for this entire
        // synchronous call, which is what keeps `screenshot.bgra` valid for
        // as long as `buffer.bytes` (the same pointer, borrowed) is read
        // inside `compositeCore` -- see `RawScreenshotBuffer`'s doc comment.
        let buffer = RawScreenshotBuffer(
            bytes: UnsafePointer(screenshot.bgra),
            width: screenshot.width,
            height: screenshot.height,
            stride: screenshot.stride
        )
        return try compositeCore(
            annotation: annotation, screen: screen, screenshot: buffer,
            paddingPx: paddingPx, rasterLease: rasterLease,
            // No which-display candidates, for the same reason the macOS
            // CGImage overload defaults to none: `chalk_capture_monitor`
            // captured THIS annotation's own display, so its identity is
            // already established rather than inferred from dimensions.
            ambiguityCandidateScreens: []
        )
    }

    /// Shared Windows implementation both `composite()` overloads above
    /// funnel into once their respective screenshot source has been
    /// normalized to a `RawScreenshotBuffer`. Structured as TWO passes over
    /// one `GDIPlusDrawingContext`, mirroring the macOS implementation's
    /// two-pass structure (`overlayRep` then a fresh crop-sized composite)
    /// for the SAME reason: bounds detection needs a transparent
    /// background, so it cannot share a pass with the (fully opaque)
    /// screenshot layer.
    ///
    /// - Pass 1: the annotation ALONE, on a transparent canvas, purely to
    ///   locate its painted pixel bounds (`AnnotationVerificationError
    ///   .annotationPaintedNothing` if nothing painted).
    /// - Pass 2: the same target, cleared, with the screenshot's raw bytes
    ///   copied in as the background layer, then the annotation drawn again
    ///   on top -- GDI+'s normal alpha-blending composites it correctly over
    ///   whatever is already in the buffer, exactly as `chalk_rt_fill_path`
    ///   et al. always do. GDI+ exposes no "draw a SOURCE-RECT crop of an
    ///   image" call the way `NSImage.draw(in:from:)` does (`chalk_rt_draw_image`
    ///   always scales the WHOLE image into a destination rect), so unlike
    ///   the macOS branch's crop-sized `cropRep`, this composites the FULL
    ///   canvas and crops the finished pixel buffer afterward with a plain
    ///   per-row copy.
    ///
    /// Every metadata key/shape below matches the macOS branch's exactly
    /// (same field names, same units), so an MCP caller sees an identical
    /// response shape regardless of platform.
    private static func compositeCore(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshot: RawScreenshotBuffer,
        paddingPx: Double,
        rasterLease: RasterAssetStore.Lease?,
        ambiguityCandidateScreens: [ScreenInfo]
    ) throws -> AnnotationVerificationComposite {
        let imageWidth = screenshot.width
        let imageHeight = screenshot.height
        guard imageWidth > 0, imageHeight > 0 else { throw AnnotationVerificationError.renderFailed }

        let scaleX = Double(imageWidth) / Double(screen.widthPx)
        let scaleY = Double(imageHeight) / Double(screen.heightPx)
        guard let screenshotScale = ScreenshotGeometry.fullDisplayScale(
            screenshotWidth: Double(imageWidth),
            screenshotHeight: Double(imageHeight),
            screenWidth: Double(screen.widthPx),
            screenHeight: Double(screen.heightPx)
        ) else {
            throw AnnotationVerificationError.aspectRatioMismatch(scaleX: scaleX, scaleY: scaleY)
        }
        // Same ordering as the macOS branch above (and as the draw path's own
        // pair of screenshot guards): mismatch first, ambiguity second.
        if let ambiguous = ambiguousDisplayRejection(
            screenshotWidth: imageWidth,
            screenshotHeight: imageHeight,
            annotationScreenId: screen.id,
            candidates: ambiguityCandidateScreens
        ) {
            throw ambiguous
        }

        // Same point-space canvas AnnotationRenderer always draws in on both
        // platforms (see AnnotationRenderer's own doc comment); the render
        // target below scales it directly to screenshot-pixel resolution --
        // the Windows analogue of the macOS branch's `cgContext.scaleBy(...)`
        // call, made possible by `GDIPlusDrawingContext`'s scaleX/scaleY
        // initializer (see that file for the derivation of why this stays
        // safe on top of its base coordinate contract).
        let sourceSize = CGSize(width: screen.widthPt, height: screen.heightPt)
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw AnnotationVerificationError.renderFailed
        }

        // Snapshot the raster this annotation needs before drawing, exactly
        // as the live overlay does and exactly as the macOS branch above
        // does -- a concurrent clear could otherwise release the store's
        // ownership mid-render.
        let lease = rasterLease ?? RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)

        // PASS 1 -- see this method's doc comment. `renderAnnotationAlone` is
        // the SAME "render this one annotation alone, then scan for its
        // non-transparent bounds" implementation `renderedPaintedBounds
        // (of:on:rasterLease:)` below uses for `get_annotation_bounds`,
        // factored into one place so the two can never independently
        // disagree about where an annotation paints.
        let (renderContext, paintedBoundsOptional) = try renderAnnotationAlone(
            annotation, widthPx: imageWidth, heightPx: imageHeight,
            pointsSize: sourceSize, backingScaleFactor: screen.backingScaleFactor, lease: lease
        )
        guard let paintedTopLeft = paintedBoundsOptional else {
            throw AnnotationVerificationError.annotationPaintedNothing(
                screenWidthPx: screen.widthPx, screenHeightPx: screen.heightPx
            )
        }
        func drawAnnotationOnly() {
            AnnotationRenderer.drawAnnotations(
                [annotation], into: renderContext, canvasSize: sourceSize,
                // THE BUG THIS LINE USED TO BE: it passed
                // `CGFloat(screen.backingScaleFactor)` while the live Windows
                // overlay (`WindowsOverlayWindow.repaint`) paints the same
                // physical-pixel canvas at 1.0, because on this platform
                // `widthPt`/`heightPt` ARE `widthPx`/`heightPx` (see
                // `ScreenSnapshot.swift`'s Windows `buildScreenInfos()`), so
                // `sourceSize` above is a PHYSICAL-PIXEL canvas, not a point
                // canvas like macOS's. On a 150%-DPI monitor that shrank and
                // displaced every verified annotation by the whole DPI factor
                // -- a circle drawn live at (1920, 1080) r=200 was composited
                // at (1280, 720) r=133 -- so the agent "corrected" a correct
                // annotation and made it wrong. Reading the shared definition
                // is what makes that class of drift impossible; see
                // `OverlayDrawingMetrics.rendererScaleFactor`.
                scaleFactor: OverlayDrawingMetrics.rendererScaleFactor(
                    displayBackingScaleFactor: CGFloat(screen.backingScaleFactor)
                )
            ) { assetId in lease.image(id: assetId) }
        }

        let safePadding = CGFloat(min(max(paddingPx, 0), maxPaddingPx))
        let fullBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let cropRect = paintedTopLeft
            .insetBy(dx: -safePadding, dy: -safePadding)
            .integral
            .intersection(fullBounds)
        guard cropRect.width >= 1, cropRect.height >= 1 else {
            throw AnnotationVerificationError.renderFailed
        }
        let cropX = Int(cropRect.minX)
        let cropY = Int(cropRect.minY)
        let cropWidth = Int(cropRect.width)
        let cropHeight = Int(cropRect.height)

        // PASS 2 -- see this method's doc comment.
        renderContext.clear()
        guard let backgroundPixels = renderContext.pixelBuffer else { throw AnnotationVerificationError.renderFailed }
        let backgroundStride = renderContext.bytesPerRow
        let rowBytes = imageWidth * 4
        for row in 0..<imageHeight {
            let src = UnsafeRawBufferPointer(start: screenshot.bytes.advanced(by: row * screenshot.stride), count: rowBytes)
            let dst = UnsafeMutableRawBufferPointer(start: backgroundPixels.advanced(by: row * backgroundStride), count: rowBytes)
            dst.copyMemory(from: src)
        }
        drawAnnotationOnly()

        guard let finalPixels = renderContext.pixelBuffer else { throw AnnotationVerificationError.renderFailed }
        let finalStride = renderContext.bytesPerRow
        let cropRowBytes = cropWidth * 4
        var cropBuffer = [UInt8](repeating: 0, count: cropRowBytes * cropHeight)
        cropBuffer.withUnsafeMutableBytes { dst in
            for row in 0..<cropHeight {
                let srcOffset = (cropY + row) * finalStride + cropX * 4
                let src = UnsafeRawBufferPointer(start: finalPixels.advanced(by: srcOffset), count: cropRowBytes)
                let dstRow = UnsafeMutableRawBufferPointer(rebasing: dst[(row * cropRowBytes)..<((row + 1) * cropRowBytes)])
                dstRow.copyMemory(from: src)
            }
        }

        var outBytes: UnsafeMutablePointer<UInt8>?
        var outLen: Int32 = 0
        let encodeStatus: Int32 = cropBuffer.withUnsafeBufferPointer { buf in
            chalk_image_encode_png(buf.baseAddress, Int32(cropWidth), Int32(cropHeight), Int32(cropRowBytes), &outBytes, &outLen)
        }
        guard encodeStatus == 0, let encoded = outBytes else {
            throw AnnotationVerificationError.renderFailed
        }
        let pngData = Data(bytes: encoded, count: Int(outLen))
        chalk_image_free_bytes(encoded)

        guard isWithinResponseBudget(rawPNGBytes: pngData.count) else {
            throw AnnotationVerificationError.outputTooLarge
        }

        // Unlike the macOS branch, no bottom-left ("AppKit") round-trip is
        // needed here: `paintedTopLeft`/`cropRect` came directly from a
        // top-left-origin raw-buffer scan, which is already the convention
        // the "ScreenshotPx" metadata fields document -- macOS's own
        // `paintedBoundsScreenshotPx` field reports the SAME top-left
        // convention (see that branch), it just has to round-trip through
        // AppKit's bottom-left space internally first because `NSImage.draw
        // (from:)` requires it.
        let clipped = cropRect.minX == 0 || cropRect.minY == 0
            || cropRect.maxX == CGFloat(imageWidth) || cropRect.maxY == CGFloat(imageHeight)

        let metadata: [String: Any] = [
            "annotationId": annotation.id,
            "annotationType": annotation.kind.typeName,
            // `screen.id`, NOT `annotation.screenId`: the caller resolved
            // `screen` from `annotation.effectiveScreenId` precisely so an
            // anchored annotation whose window has been dragged onto a second
            // display is verified against the display it lives on NOW. This
            // metadata names the display this image was actually composited
            // and cropped against, so reporting the immutable creation-time
            // field here would hand back a screenId contradicting the very
            // picture it accompanies -- and, once the original display is
            // disconnected, one that no longer exists at all.
            "screenId": screen.id,
            "screenBackingPixels": ["width": screen.widthPx, "height": screen.heightPx],
            "screenPoints": ["width": screen.widthPt, "height": screen.heightPt],
            "backingScaleFactor": screen.backingScaleFactor,
            "screenshotPixels": ["width": imageWidth, "height": imageHeight],
            "scaleToScreenshot": ["x": scaleX, "y": scaleY],
            "scaleDifferencePercent": screenshotScale.relativeDifference * 100,
            "maximumScaleDifferencePercent": screenshotScale.maximumRelativeDifference * 100,
            "paintedBoundsScreenshotPx": rectObject(
                x: paintedTopLeft.minX, y: paintedTopLeft.minY,
                width: paintedTopLeft.width, height: paintedTopLeft.height
            ),
            "cropScreenshotPx": rectObject(
                x: cropRect.minX, y: cropRect.minY,
                width: cropRect.width, height: cropRect.height
            ),
            "cropClippedAtScreenEdge": clipped,
            "verificationKind": "synthetic-composite",
            // Names the display for the same reason the macOS branch does --
            // see that branch's comment on this field.
            "verificationNote": "This image uses the live AnnotationRenderer -- the same renderer code the live overlay uses -- composited into the selected clean screenshot source, interpreted as a full-display image of display \(screen.id) (see screenId) -- the display this annotation lives on, and the only display whose screenshot can prove or refute its placement. It verifies annotation-to-UI coordinate placement; it does not prove raw-framebuffer pixels, occlusion, or that the desktop compositor presented the separate overlay window. Rendered through GDI+ on this platform (not Core Graphics), so pixels are not bit-identical to a macOS verification image of the same annotation."
        ]

        return AnnotationVerificationComposite(pngData: pngData, metadata: metadata)
    }

    /// WINDOWS NOTE, READ BEFORE CHANGING: not a line-for-line port of the
    /// macOS `loadScreenshot(path:)` above, for exactly the two structural
    /// reasons `RasterAssetStore`'s Windows `decode(path:)` documents in
    /// full (a second-open TOCTOU gap, and no pre-decode metadata-only size
    /// probe -- `chalk_image_decode_file` takes a path, not a buffer, and
    /// exposes no metadata-only variant). They apply here identically.
    private static func loadScreenshot(path: String) throws -> WindowsRasterImage {
        do {
            _ = try BoundedLocalFile.read(path: path, maxBytes: maxInputFileBytes)
        } catch BoundedLocalFileError.invalidPath {
            throw AnnotationVerificationError.invalidPath
        } catch {
            throw AnnotationVerificationError.unreadableFile
        }

        let decoded: WindowsRasterImage
        do {
            decoded = try WindowsRasterImage.decode(path: path)
        } catch let error as WindowsRasterImageError {
            throw AnnotationVerificationError(windowsDecodeError: error)
        } catch {
            throw AnnotationVerificationError.decodingUnavailable
        }

        guard decoded.pixelWidth > 0, decoded.pixelHeight > 0,
              decoded.pixelWidth <= maxImagePixels / decoded.pixelHeight else {
            throw AnnotationVerificationError.imageTooLarge
        }
        return decoded
    }

    /// Windows twin of the macOS `screenshotPixelDimensions(path:)` above --
    /// same signature, same contract, same caller
    /// (`register_screenshot_space`). `WindowsRasterImage` already exposes
    /// `pixelWidth`/`pixelHeight` post-decode, so this is exactly as thin as
    /// the macOS branch: no second decode path, and every guard
    /// `loadScreenshot` applies on this platform (the 50 MB input cap, WIC
    /// decode failure mapping, the 20-megapixel cap) applies here for free.
    static func screenshotPixelDimensions(path: String) throws -> (width: Int, height: Int) {
        let decoded = try loadScreenshot(path: path)
        return (decoded.pixelWidth, decoded.pixelHeight)
    }

    /// Returns painted bounds in raw buffer row coordinates (top-left
    /// origin). The buffer starts fully transparent (`chalk_rt_create`), so
    /// any non-zero byte identifies an antialiased annotation pixel --
    /// channel-ordering-agnostic, exactly like the macOS branch's matching
    /// scan, so this works unchanged whether the buffer is BGRA (GDI+'s own
    /// format) or any other 4-byte-per-pixel layout. Delegates to the SAME
    /// platform-neutral word-scanning core the macOS branch uses -- see
    /// `paintedPixelBounds(bytes:width:height:bytesPerPixel:bytesPerRow:)`
    /// below -- so the two platforms cannot drift on what "painted" means,
    /// the same one-implementation guarantee `renderAnnotationAlone`'s doc
    /// comment makes for the render half.
    private static func paintedPixelBounds(bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGRect? {
        paintedPixelBounds(
            bytes: UnsafeRawPointer(bytes),
            width: width,
            height: height,
            bytesPerPixel: 4,
            bytesPerRow: stride
        )
    }

    /// Renders `annotation` ALONE onto a fresh `widthPx`x`heightPx`
    /// `GDIPlusDrawingContext` and returns both the context (so `compositeCore`
    /// above can clear and reuse it for its second, composited pass) and the
    /// non-transparent pixel bounds of that lone render (raw buffer row
    /// coordinates, top-left origin -- see `paintedPixelBounds(bytes:...)`'s
    /// doc comment -- or `nil` if nothing painted).
    ///
    /// THE ONE RENDER-AND-SCAN IMPLEMENTATION for this platform, shared by
    /// `compositeCore`'s PASS 1 above and `renderedPaintedBounds(of:on:
    /// rasterLease:)` below -- see the macOS branch's identically-named
    /// helper for why duplicating this into a second implementation is
    /// exactly the drift this factoring exists to make impossible.
    private static func renderAnnotationAlone(
        _ annotation: Annotation,
        widthPx: Int,
        heightPx: Int,
        pointsSize: CGSize,
        backingScaleFactor: Double,
        lease: RasterAssetStore.Lease
    ) throws -> (context: GDIPlusDrawingContext, paintedBounds: CGRect?) {
        guard pointsSize.width > 0, pointsSize.height > 0 else {
            throw AnnotationVerificationError.renderFailed
        }
        let pixelScaleX = Double(widthPx) / Double(pointsSize.width)
        let pixelScaleY = Double(heightPx) / Double(pointsSize.height)
        guard let renderContext = GDIPlusDrawingContext(
            width: widthPx, height: heightPx, scaleX: pixelScaleX, scaleY: pixelScaleY
        ) else {
            throw AnnotationVerificationError.renderFailed
        }
        AnnotationRenderer.drawAnnotations(
            [annotation], into: renderContext, canvasSize: pointsSize,
            // See `compositeCore`'s identical call for why this shared
            // definition, not a literal `backingScaleFactor`, is load-bearing
            // on this platform.
            scaleFactor: OverlayDrawingMetrics.rendererScaleFactor(
                displayBackingScaleFactor: CGFloat(backingScaleFactor)
            )
        ) { assetId in lease.image(id: assetId) }
        guard let pixels = renderContext.pixelBuffer else { throw AnnotationVerificationError.renderFailed }
        let bounds = Self.paintedPixelBounds(
            bytes: pixels, width: widthPx, height: heightPx, stride: renderContext.bytesPerRow
        )
        return (renderContext, bounds)
    }

    /// Windows twin of the macOS `renderedPaintedBounds(of:on:rasterLease:)`
    /// above -- SAME signature, same contract (renders `annotation` alone
    /// through the exact live `AnnotationRenderer` and returns its
    /// non-transparent pixel bounds in top-left-origin backing-pixel space of
    /// `screen`, with no screenshot involved and no capture API touched), so
    /// `get_annotation_bounds`'s one call site compiles and behaves
    /// identically on both platforms. See that overload's doc comment for
    /// the full contract, including the shared `paintedBoundsCache` this
    /// consults and populates for the same reason (the cache and its key are
    /// pure Foundation, so both platforms share one implementation of them).
    static func renderedPaintedBounds(
        of annotation: Annotation,
        on screen: ScreenInfo,
        rasterLease: RasterAssetStore.Lease? = nil
    ) throws -> CGRect? {
        let cacheKey = paintedBoundsCacheKey(for: annotation, on: screen)
        if let cacheKey, let cached = paintedBoundsCache.lookup(cacheKey) {
            return cached.bounds
        }
        let lease = rasterLease ?? RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)
        let (_, bounds) = try renderAnnotationAlone(
            annotation, widthPx: screen.widthPx, heightPx: screen.heightPx,
            pointsSize: CGSize(width: screen.widthPt, height: screen.heightPt),
            backingScaleFactor: screen.backingScaleFactor, lease: lease
        )
        if let cacheKey {
            paintedBoundsCache.store(bounds, for: cacheKey)
        }
        return bounds
    }
    #endif

    /// THE ONE PAINTED-BOUNDS SCAN, shared by both platforms' wrappers
    /// (macOS's `paintedPixelBounds(in:)` over an `NSBitmapImageRep`,
    /// Windows's `paintedPixelBounds(bytes:width:height:stride:)` over a
    /// GDI+ target's raw buffer) so the two can never disagree about what
    /// "painted" means -- the same one-implementation reasoning
    /// `renderAnnotationAlone`'s doc comment gives for the render half.
    /// Internal rather than private so the scalar-equivalence tests can
    /// drive it directly with synthetic buffers, the same pure-static,
    /// testable shape `ambiguousDisplayRejection` below uses.
    ///
    /// PREDICATE (unchanged from the byte-at-a-time loop this replaced):
    /// pixel `x` of a row is painted iff ANY of its `bytesPerPixel` bytes is
    /// non-zero. The canvas starts fully transparent (`CGContext.clear` on
    /// macOS, `chalk_rt_create` on Windows -- both zero every byte), so a
    /// non-zero byte in any channel, under any channel ordering, can only
    /// mean the renderer painted there.
    ///
    /// WHY WORD-SCANNING IS BIT-IDENTICAL TO THE SCALAR SCAN: almost every
    /// row of a full-display canvas is entirely zero, and per row this
    /// scan's job reduces to "index of the first non-zero byte and of the
    /// last" within the row's `width * bytesPerPixel` payload bytes (padding
    /// bytes beyond them, when `bytesPerRow` is larger, are never read --
    /// the scalar loop's per-pixel ranges never touched them either). A
    /// `UInt64` load reads exactly eight of those bytes and is non-zero IFF
    /// at least one of them is: endianness only permutes WHICH bit positions
    /// a byte's value lands in, never whether any bit is set. So the word
    /// loop accepts and rejects exactly the byte ranges the scalar loop did,
    /// and on the first non-zero word it drops back to bytes to recover the
    /// precise index. The short byte-at-a-time prologue/epilogue exist only
    /// because an aligned `UInt64` load requires an 8-byte-aligned address
    /// and a row tail can be narrower than a word. Mapping byte indices back
    /// to pixels is exact integer division: pixel `x` owns exactly bytes
    /// `[x * bytesPerPixel, (x + 1) * bytesPerPixel)`, so `firstNonZeroByte
    /// / bytesPerPixel` IS the row's minimum painted x and `lastNonZeroByte
    /// / bytesPerPixel` its maximum; scanning rows in the same ascending
    /// order yields the same minY/maxY.
    static func paintedPixelBounds(
        bytes: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int
    ) -> CGRect? {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return nil }
        let rowByteCount = width * bytesPerPixel
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = bytes + y * bytesPerRow
            guard let firstByte = firstNonZeroByteIndex(in: row, count: rowByteCount) else { continue }
            // A row with a first non-zero byte necessarily has a last one
            // (they coincide for a single painted byte), so the fallback
            // exists only to satisfy the optional, never to run.
            let lastByte = lastNonZeroByteIndex(in: row, count: rowByteCount) ?? firstByte
            minX = min(minX, firstByte / bytesPerPixel)
            maxX = max(maxX, lastByte / bytesPerPixel)
            minY = min(minY, y)
            maxY = y
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Forward half of the word scan: index of the first non-zero byte in
    /// `row[0..<count]`, or nil when every byte is zero. Layout: a scalar
    /// prologue walks up to the first 8-byte-aligned address, aligned
    /// `UInt64` loads cover the whole words, and a scalar epilogue covers
    /// the sub-word tail -- see `paintedPixelBounds(bytes:...)`'s doc
    /// comment for why this partition reads exactly the same bytes to
    /// exactly the same verdict as a plain byte loop.
    private static func firstNonZeroByteIndex(in row: UnsafeRawPointer, count: Int) -> Int? {
        let alignedStart = min((8 - (Int(bitPattern: row) & 7)) & 7, count)
        var index = 0
        while index < alignedStart {
            if row.load(fromByteOffset: index, as: UInt8.self) != 0 { return index }
            index += 1
        }
        let alignedEnd = alignedStart + ((count - alignedStart) & ~7)
        while index < alignedEnd {
            if row.load(fromByteOffset: index, as: UInt64.self) != 0 {
                for byteOffset in index..<(index + 8) where row.load(fromByteOffset: byteOffset, as: UInt8.self) != 0 {
                    return byteOffset
                }
            }
            index += 8
        }
        while index < count {
            if row.load(fromByteOffset: index, as: UInt8.self) != 0 { return index }
            index += 1
        }
        return nil
    }

    /// Backward twin of `firstNonZeroByteIndex(in:count:)`: index of the
    /// LAST non-zero byte, scanning tail-first so a row whose paint hugs its
    /// right edge is answered without touching the zero bytes before it.
    /// Same alignment partition as the forward scan, walked in reverse.
    private static func lastNonZeroByteIndex(in row: UnsafeRawPointer, count: Int) -> Int? {
        let alignedStart = min((8 - (Int(bitPattern: row) & 7)) & 7, count)
        let alignedEnd = alignedStart + ((count - alignedStart) & ~7)
        var index = count - 1
        while index >= alignedEnd {
            if row.load(fromByteOffset: index, as: UInt8.self) != 0 { return index }
            index -= 1
        }
        var wordIndex = alignedEnd - 8
        while wordIndex >= alignedStart {
            if row.load(fromByteOffset: wordIndex, as: UInt64.self) != 0 {
                var byteOffset = wordIndex + 7
                while byteOffset >= wordIndex {
                    if row.load(fromByteOffset: byteOffset, as: UInt8.self) != 0 { return byteOffset }
                    byteOffset -= 1
                }
            }
            wordIndex -= 8
        }
        index = alignedStart - 1
        while index >= 0 {
            if row.load(fromByteOffset: index, as: UInt8.self) != 0 { return index }
            index -= 1
        }
        return nil
    }

    /// Complete identity of one `renderedPaintedBounds` answer: EVERY input
    /// that can change where the lone render of an annotation paints is a
    /// stored property here, so key equality implies a pixel-identical
    /// render. The verified invalidation reasoning, field by field:
    ///
    /// * `annotationId` + `revision`: `AnnotationStore` assigns a fresh
    ///   `revision` (`nextRevision()`) on EVERY content mutation -- add,
    ///   replace, and all `updateWithOutcome` variants -- so any change to a
    ///   STORED annotation's kind, color, opacity, offsets, or anchor
    ///   retires its key. The single revision-preserving store mutation is
    ///   `applyAnchorProjections` (deliberately so; see its doc comment),
    ///   and the render consumes a projection ONLY through
    ///   `effectiveAdjustment` -- keyed below -- and `effectiveScreenId`,
    ///   which changes the `screen` a caller resolves and is keyed as
    ///   `screenId`. A projection's tracking `state` is deliberately NOT
    ///   keyed: `renderAnnotationAlone` renders unconditionally
    ///   (`AnnotationRenderer.drawAnnotations` never reads
    ///   `anchorPermitsPainting`; visibility filtering lives in callers), so
    ///   a `.tracking`/`.hidden`/`.lost` flip cannot change this answer.
    /// * `contentFingerprint`: a hash of the exact rendering payload --
    ///   `kind`, `colorHex`, `opacity`, `offsetX`, `offsetY`, the only
    ///   `Annotation` fields `drawAnnotations` reads besides
    ///   `effectiveAdjustment`. id+revision already identify a STORED
    ///   annotation's content, but this function also measures values that
    ///   never passed through a store -- `DrawRequest.resolveAvoidance`'s
    ///   prospective candidates and hand-built test annotations, all at
    ///   revision 0 -- where id+revision alone cannot identify content. The
    ///   fingerprint makes the key total instead of trusting provenance the
    ///   function signature cannot see.
    /// * Screen geometry (`screenId`, `widthPx`/`heightPx`,
    ///   `widthPt`/`heightPt`, `backingScaleFactor`): every geometric input
    ///   `renderAnnotationAlone` consumes -- the physical output resolution,
    ///   the point canvas it scales up from, and the stroke/font scale via
    ///   `OverlayDrawingMetrics.rendererScaleFactor`. `widthPt`/`heightPt`
    ///   are keyed in their own right rather than assumed derivable as
    ///   px / scale, so a display whose point size disagrees with that
    ///   arithmetic can never alias another display's key.
    /// * `adjustment*`: the four components of `effectiveAdjustment`
    ///   (static ∘ live) -- the exact composed transform the renderer
    ///   applies, however the tracker got there.
    ///
    /// RASTER ASSETS need no field of their own: an image kind's asset ids
    /// are part of `kind` (fingerprinted above, and revision-bumped when
    /// changed), and `RasterAssetStore` ids are server-generated UUIDs whose
    /// decoded pixels are immutable from `load(path:)` to `release(id:)` --
    /// the store has no replace-in-place. Every release site is either a
    /// draw request rolling back assets it loaded itself before any
    /// annotation stored them, or the store releasing a REMOVED/REPLACED
    /// annotation's assets -- itself a revision-assigning or id-retiring
    /// event -- so equal keys can never observe two different images behind
    /// one asset id. The one theoretical divergence: re-measuring a stale
    /// `Annotation` value AFTER its removal released its assets, WITHOUT the
    /// pinned lease every production caller captures atomically with its
    /// snapshot (`AnnotationStore.renderSnapshots`); a fresh render would
    /// then paint no image where the cached answer measured one. That is a
    /// race with no defined correct answer, every real call site pins the
    /// lease that prevents it, and the cached answer is the one the
    /// annotation actually had while it existed.
    struct PaintedBoundsCacheKey: Hashable {
        let annotationId: String
        let revision: UInt64
        let contentFingerprint: Int
        let screenId: String
        let widthPx: Int
        let heightPx: Int
        let widthPt: Double
        let heightPt: Double
        let backingScaleFactor: Double
        let adjustmentScaleX: Double
        let adjustmentScaleY: Double
        let adjustmentTranslateX: Double
        let adjustmentTranslateY: Double
    }

    /// The exact `Annotation` fields `renderAnnotationAlone`'s render reads
    /// besides `effectiveAdjustment` (which the key carries as explicit
    /// components) -- see `PaintedBoundsCacheKey`'s doc comment. `label`,
    /// `zIndex`, `appId`, `createdAt`, and the anchor payload are
    /// deliberately absent because a lone offscreen render never consumes
    /// them: labels are metadata (never painted), zIndex orders annotations
    /// against EACH OTHER, and app-visibility filtering happens in callers.
    private struct PaintedContentFingerprintPayload: Encodable {
        let kind: AnnotationKind
        let colorHex: String
        let opacity: Double
        let offsetX: Double
        let offsetY: Double
    }

    /// Builds the complete cache key for measuring `annotation` on `screen`,
    /// or nil when the rendering payload cannot be fingerprinted (JSON
    /// refuses non-finite doubles) -- callers then simply skip the cache,
    /// failing open to a fresh render rather than caching under a lossy key.
    /// `.sortedKeys` pins the encoded byte stream so equal payloads always
    /// fingerprint equal within a process; `Hasher`'s per-process seed is
    /// fine here because this cache never outlives the process, and a
    /// payload that somehow encoded differently on two calls could only
    /// cause a spurious MISS (a wasted render), never a false hit.
    static func paintedBoundsCacheKey(for annotation: Annotation, on screen: ScreenInfo) -> PaintedBoundsCacheKey? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(PaintedContentFingerprintPayload(
            kind: annotation.kind,
            colorHex: annotation.colorHex,
            opacity: annotation.opacity,
            offsetX: annotation.offsetX,
            offsetY: annotation.offsetY
        )) else { return nil }
        var hasher = Hasher()
        // `combine(bytes:)` over the WHOLE buffer, never `combine(encoded)`:
        // Foundation's `Data.hash(into:)` deliberately hashes only a bounded
        // prefix of its contents (~80 bytes) for performance, and this
        // payload's sorted-keys JSON puts `colorHex` and the `kind`
        // discriminator before the geometry -- so two vectorPaths differing
        // only in `data` (the exact field a fingerprint exists to see)
        // hashed IDENTICALLY through the prefix. That is a false cache HIT
        // waiting to hand one annotation another annotation's painted
        // bounds, the one failure mode this key must never allow.
        encoded.withUnsafeBytes { hasher.combine(bytes: $0) }
        let adjustment = annotation.effectiveAdjustment
        return PaintedBoundsCacheKey(
            annotationId: annotation.id,
            revision: annotation.revision,
            contentFingerprint: hasher.finalize(),
            screenId: screen.id,
            widthPx: screen.widthPx,
            heightPx: screen.heightPx,
            widthPt: screen.widthPt,
            heightPt: screen.heightPt,
            backingScaleFactor: screen.backingScaleFactor,
            adjustmentScaleX: adjustment.scaleX,
            adjustmentScaleY: adjustment.scaleY,
            adjustmentTranslateX: adjustment.translateX,
            adjustmentTranslateY: adjustment.translateY
        )
    }

    /// Bounded, `NSLock`-guarded, least-recently-used cache of
    /// `renderedPaintedBounds` answers, shared by both platform branches
    /// (pure Foundation throughout -- the same `final class ...
    /// @unchecked Sendable` + `NSLock` shape `ScreenshotSpaceRegistry`
    /// already establishes for exactly this cross-queue access pattern).
    ///
    /// WHY IT EXISTS: `renderedPaintedBounds` costs a full-display offscreen
    /// render plus a full-bitmap scan per call, and
    /// `DrawRequest.resolveAvoidance` performs one per avoided id (up to 32)
    /// on EVERY avoid= draw, while `verify_annotation` and
    /// `get_annotation_bounds` pay the same per call -- yet an unchanged
    /// annotation's bounds are a pure function of `PaintedBoundsCacheKey`,
    /// so every repeat measurement after the first should cost a dictionary
    /// lookup and zero renders.
    ///
    /// A `nil` VALUE is a real, cacheable answer ("rendered fine, painted
    /// nothing"), which is why `lookup` wraps its result in `CachedBounds?`:
    /// the outer optional is hit-or-miss, the inner one is the answer.
    /// Eviction is least-recently-USED at `capacity`, so the annotations an
    /// agent is actively avoiding or verifying stay resident while
    /// `resolveAvoidance`'s one-shot candidate measurements (fresh UUID ids,
    /// never re-measured) age out first; the O(capacity) eviction scan runs
    /// only on insert-when-full, immediately after a render that costs
    /// orders of magnitude more. Concurrent misses on one key may each
    /// render and each store, but they store the same pure-function value,
    /// so that race is benign by construction.
    final class PaintedBoundsRenderCache: @unchecked Sendable {
        /// See the class doc comment: wrapper distinguishing "cache hit
        /// whose answer is `nil` bounds" from "cache miss".
        struct CachedBounds {
            let bounds: CGRect?
        }

        private struct Entry {
            let bounds: CGRect?
            var lastUse: UInt64
        }

        private let lock = NSLock()
        private var entries: [PaintedBoundsCacheKey: Entry] = [:]
        private var useCounter: UInt64 = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        func lookup(_ key: PaintedBoundsCacheKey) -> CachedBounds? {
            lock.lock()
            defer { lock.unlock() }
            guard var entry = entries[key] else { return nil }
            useCounter &+= 1
            entry.lastUse = useCounter
            entries[key] = entry
            return CachedBounds(bounds: entry.bounds)
        }

        func store(_ bounds: CGRect?, for key: PaintedBoundsCacheKey) {
            lock.lock()
            defer { lock.unlock() }
            useCounter &+= 1
            if entries[key] == nil, entries.count >= capacity,
               let evictee = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                entries.removeValue(forKey: evictee)
            }
            entries[key] = Entry(bounds: bounds, lastUse: useCounter)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return entries.count
        }

        /// Test-isolation hook; production code never clears the cache
        /// because `PaintedBoundsCacheKey` already retires stale entries by
        /// construction (see its doc comment).
        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll()
        }
    }

    /// See `PaintedBoundsRenderCache`'s doc comment. 256 entries comfortably
    /// covers the working set that can be live at once (`avoid` accepts at
    /// most 32 ids per draw; keys are a few strings and doubles, entries one
    /// rect) while bounding memory no matter how many one-shot candidates
    /// `resolveAvoidance` measures over a long session.
    static let paintedBoundsCache = PaintedBoundsRenderCache(capacity: 256)

    /// Refuses to GUESS which display a caller-supplied screenshot is of when
    /// its dimensions fit several connected displays equally well. Pure
    /// arithmetic, shared by both platform branches (and callable directly
    /// from tests), so the two cannot answer this differently.
    ///
    /// WHY THIS EXISTS: the only geometric evidence a screenshot carries is
    /// its dimensions, and `ScreenshotGeometry.fullDisplayScale` -- the sole
    /// check that used to stand here -- compares them against ONE screen's
    /// size and carries no display identity whatsoever. On the standard
    /// dual-identical-monitor editing setup, a screenshot of the WRONG
    /// display therefore passed at scale 1.0, the annotation was composited
    /// over unrelated UI, and the agent "corrected" a correctly-placed
    /// annotation. This is the verification-side mirror of
    /// `DrawRequest.coordinateTransform`'s ambiguity guard -- deliberately the
    /// same philosophy and the same wording shape: one extra round trip beats
    /// a confidently-wrong picture, and the message names the candidates so
    /// the correction is a single argument away.
    ///
    /// EMPTY `candidates` means the caller has already established which
    /// display the image is of, so there is nothing to disambiguate:
    /// Chalkboard-owned capture (inherently of the annotation's own display)
    /// and an explicit, already-verified `screenshot_screen_id` both pass
    /// nothing here. Zero or one accepting display is likewise unambiguous --
    /// and zero is `.aspectRatioMismatch`, which every caller checks FIRST so
    /// that error keeps its exact previous meaning.
    ///
    /// A candidate counts only when the image could PLAUSIBLY be a capture
    /// of it -- `isPlausibleFullDisplayCapture`, i.e. uniform mapping AND no
    /// upscale -- not merely when its aspect ratio fits at some enlargement.
    /// Aspect-only counting made this guard reject a NATIVE capture of the
    /// annotation's 4K display because a same-aspect QHD sibling also "fit"
    /// at scale 1.5, an enlargement no screenshot pipeline produces; that
    /// turned a formerly-valid, genuinely unambiguous verification into an
    /// error. See that helper's doc comment for the full reasoning.
    static func ambiguousDisplayRejection(
        screenshotWidth: Int,
        screenshotHeight: Int,
        annotationScreenId: String,
        candidates: [ScreenInfo]
    ) -> AnnotationVerificationError? {
        guard !candidates.isEmpty else { return nil }
        let accepting = candidates.filter {
            ScreenshotGeometry.isPlausibleFullDisplayCapture(
                screenshotWidth: Double(screenshotWidth),
                screenshotHeight: Double(screenshotHeight),
                screenWidth: Double($0.widthPx),
                screenHeight: Double($0.heightPx)
            )
        }
        guard accepting.count > 1 else { return nil }
        return .ambiguousScreenshotDisplay(
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight,
            acceptingScreenIds: accepting.map(\.id),
            annotationScreenId: annotationScreenId
        )
    }

    /// The other half of the same question, for the case where the caller DID
    /// say which display its screenshot is of: returns the refusal text when
    /// that display is not the one the annotation lives on, or `nil` when the
    /// two agree.
    ///
    /// Kept here beside `ambiguousDisplayRejection` (rather than inline in
    /// `handleVerifyAnnotation`) so both "which display is this a picture
    /// of?" refusals state the same thing in the same voice and are both
    /// reachable from tests with no MCP transport -- the same pure-static,
    /// returns-the-message shape `DrawRequest.rejectDurationSecondsIfSupplied`
    /// uses.
    ///
    /// WHY REFUSE RATHER THAN VERIFY ANYWAY: a screenshot of a different
    /// display is not weak evidence about this annotation's placement, it is
    /// none at all. Compositing into it would return a perfectly convincing
    /// image of unrelated UI, and the agent would then "correct" a
    /// correctly-placed annotation -- the amplifying loop this whole tool
    /// exists to close.
    static func screenshotDisplayMismatchRejection(
        annotationId: String,
        annotationScreenId: String,
        screenshotScreenId: String
    ) -> String? {
        guard annotationScreenId != screenshotScreenId else { return nil }
        return "Annotation \(annotationId) lives on display \(annotationScreenId), and a screenshot of display \(screenshotScreenId) cannot prove or refute its placement. Nothing was verified; screenshot display \(annotationScreenId) instead (passing screenshot_screen_id='\(annotationScreenId)'), or use capture_source='chalkboard' to have Chalkboard capture that display itself."
    }

    /// Pure transport accounting used by the encoder and unit tests.  The
    /// encoded length rounds up to a whole four-byte base64 quantum.
    static func isWithinResponseBudget(rawPNGBytes: Int) -> Bool {
        guard rawPNGBytes >= 0 else { return false }
        let groups = rawPNGBytes / 3 + (rawPNGBytes % 3 == 0 ? 0 : 1)
        guard groups <= Int.max / 4 else { return false }
        let base64Bytes = groups * 4
        return base64Bytes <= maxTransportResponseBytes - maxTransportOverheadBytes
    }

    private static func rectObject(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [String: Double] {
        ["x": Double(x), "y": Double(y), "width": Double(width), "height": Double(height)]
    }
}

#if os(Windows)
private extension AnnotationVerificationError {
    /// Maps a `WindowsRasterImage.decode(path:)` failure to the closest
    /// honest `AnnotationVerificationError` -- mirrors
    /// `RasterAssetStoreError.init(windowsDecodeError:)` exactly; see that
    /// initializer's doc comment for why `.decodeFailed` maps to
    /// `.unsupportedImage` deliberately rather than approximately.
    init(windowsDecodeError: WindowsRasterImageError) {
        switch windowsDecodeError {
        case .invalidArgument:
            // Should not happen: `path` was already validated by
            // `BoundedLocalFile.read` immediately above this call, and an
            // oversized decoded image is reported separately as
            // `.imageTooLarge` below (CHALK_ERR_IMAGE_TOO_LARGE), not folded
            // into CHALK_ERR_INVALID_ARGUMENT -- so nothing on this call's
            // own path should be able to produce `.invalidArgument` here.
            self = .invalidPath
        case .fileNotFound:
            self = .unreadableFile
        case .unsupportedFormat:
            self = .unsupportedFormatOnSystem
        case .decodeFailed:
            self = .unsupportedImage
        case .imageTooLarge:
            self = .imageTooLarge
        case .wicInitFailed, .outOfMemory, .unknown:
            self = .decodingUnavailable
        }
    }
}
#endif
