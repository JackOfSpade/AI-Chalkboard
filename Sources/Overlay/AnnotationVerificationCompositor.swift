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

    static func composite(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshotPath: String,
        paddingPx: Double = defaultPaddingPx,
        rasterLease: RasterAssetStore.Lease? = nil
    ) throws -> AnnotationVerificationComposite {
        #if os(macOS)
        let screenshot = try loadScreenshot(path: screenshotPath)
        return try composite(
            annotation: annotation,
            screen: screen,
            screenshot: screenshot,
            paddingPx: paddingPx,
            rasterLease: rasterLease
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
            paddingPx: paddingPx, rasterLease: rasterLease
        )
        #endif
    }

    #if os(macOS)
    /// In-memory sibling used by Chalkboard-owned ScreenCaptureKit capture.
    /// Keeping it on the same implementation as the path-based overload means
    /// the crop, coordinate validation, and exact OverlayView renderer cannot
    /// drift between external and internal verification sources.
    static func composite(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshot: CGImage,
        paddingPx: Double = defaultPaddingPx,
        rasterLease: RasterAssetStore.Lease? = nil
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
        // This is race-free: `overlayRep` is a freshly allocated,
        // self-owned `NSBitmapImageRep` (never a CGImage-backed or
        // otherwise lazily-produced one -- see `makeBitmap`), it is fully
        // written by `flushGraphics()` before this block returns it, and
        // nothing mutates it afterwards. Handing it from the main thread to
        // the calling thread here is a one-way, one-time transfer, not
        // concurrent access.
        let overlayRep: NSBitmapImageRep = try MainThread.sync {
            guard let overlayRep = makeBitmap(width: imageWidth, height: imageHeight),
                  let overlayContext = NSGraphicsContext(bitmapImageRep: overlayRep) else {
                throw AnnotationVerificationError.renderFailed
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = overlayContext
            let cgContext = overlayContext.cgContext
            let outputRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
            cgContext.clear(outputRect)
            cgContext.saveGState()
            cgContext.clip(to: outputRect)

            // OverlayView itself is sized in NSScreen.frame points. Scaling
            // that point canvas into screenshot pixels preserves fixed-point
            // strokes/fonts and physical-pixel paths exactly as the live
            // renderer would look after the screenshot's resampling step.
            let sourceSize = CGSize(width: screen.widthPt, height: screen.heightPt)
            cgContext.scaleBy(
                x: CGFloat(imageWidth) / sourceSize.width,
                y: CGFloat(imageHeight) / sourceSize.height
            )
            // Snapshot the raster this annotation needs before drawing,
            // exactly as the live overlay does in `OverlayView.draw(_:)` --
            // a concurrent clear could otherwise release the store's
            // ownership mid-render. The `rasterLease` parameter lets an
            // in-process caller (e.g. Chalkboard-owned capture) reuse a lease
            // it is already holding instead of taking out a fresh one here.
            let lease = rasterLease ?? RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)
            let drawingContext = CoreGraphicsDrawingContext(context: cgContext)
            AnnotationRenderer.drawAnnotations(
                [annotation],
                into: drawingContext,
                canvasSize: sourceSize,
                scaleFactor: CGFloat(screen.backingScaleFactor)
            ) { assetId in
                lease.image(id: assetId).map(NSImageRasterHandle.init)
            }
            cgContext.restoreGState()
            overlayContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return overlayRep
        }

        // Reaching here means the bitmap and its context were both created and
        // the renderer ran; an empty painted box is therefore a statement about
        // the annotation, not about the rendering machinery. Fully off-screen
        // coordinates, zero opacity, a transparent color, and an empty path are
        // all storable and all land exactly here.
        guard let paintedTopLeft = paintedPixelBounds(in: overlayRep) else {
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
            "screenId": annotation.screenId,
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
            "verificationNote": "This image uses the live OverlayView renderer composited into the selected clean screenshot source. It verifies annotation-to-UI coordinate placement; it does not prove raw-framebuffer pixels, occlusion, or that WindowServer presented the separate overlay window."
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
              ["public.png", "public.jpeg", "public.heic", "public.tiff"].contains(type),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnnotationVerificationError.unsupportedImage
        }
        guard image.width > 0, image.height > 0,
              image.width <= maxImagePixels / image.height else {
            throw AnnotationVerificationError.imageTooLarge
        }
        return image
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

    /// Returns painted bounds in raw bitmap row coordinates (top-left origin).
    /// The bitmap starts transparent, so any non-zero byte identifies an
    /// antialiased annotation pixel regardless of channel byte ordering.
    private static func paintedPixelBounds(in bitmap: NSBitmapImageRep) -> CGRect? {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel >= 4 else { return nil }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        let bytesPerRow = bitmap.bytesPerRow
        guard bytesPerPixel >= 4 else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = data.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * bytesPerPixel)
                var painted = false
                for channel in 0..<bytesPerPixel where pixel[channel] != 0 {
                    painted = true
                    break
                }
                if painted {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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
            paddingPx: paddingPx, rasterLease: rasterLease
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
        rasterLease: RasterAssetStore.Lease?
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
        let pixelScaleX = Double(imageWidth) / Double(sourceSize.width)
        let pixelScaleY = Double(imageHeight) / Double(sourceSize.height)

        guard let renderContext = GDIPlusDrawingContext(
            width: imageWidth, height: imageHeight, scaleX: pixelScaleX, scaleY: pixelScaleY
        ) else {
            throw AnnotationVerificationError.renderFailed
        }

        // Snapshot the raster this annotation needs before drawing, exactly
        // as the live overlay does and exactly as the macOS branch above
        // does -- a concurrent clear could otherwise release the store's
        // ownership mid-render.
        let lease = rasterLease ?? RasterAssetStore.shared.lease(ids: annotation.kind.rasterAssetIds)
        func drawAnnotationOnly() {
            AnnotationRenderer.drawAnnotations(
                [annotation], into: renderContext, canvasSize: sourceSize,
                scaleFactor: CGFloat(screen.backingScaleFactor)
            ) { assetId in lease.image(id: assetId) }
        }

        // PASS 1 -- see this method's doc comment.
        drawAnnotationOnly()
        guard let overlayPixels = renderContext.pixelBuffer else { throw AnnotationVerificationError.renderFailed }
        guard let paintedTopLeft = Self.paintedPixelBounds(
            bytes: overlayPixels, width: imageWidth, height: imageHeight, stride: renderContext.bytesPerRow
        ) else {
            throw AnnotationVerificationError.annotationPaintedNothing(
                screenWidthPx: screen.widthPx, screenHeightPx: screen.heightPx
            )
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
            "screenId": annotation.screenId,
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
            "verificationNote": "This image uses the live AnnotationRenderer -- the same renderer code the live overlay uses -- composited into the selected clean screenshot source. It verifies annotation-to-UI coordinate placement; it does not prove raw-framebuffer pixels, occlusion, or that the desktop compositor presented the separate overlay window. Rendered through GDI+ on this platform (not Core Graphics), so pixels are not bit-identical to a macOS verification image of the same annotation."
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

    /// Returns painted bounds in raw buffer row coordinates (top-left
    /// origin). The buffer starts fully transparent (`chalk_rt_create`), so
    /// any non-zero byte identifies an antialiased annotation pixel --
    /// channel-ordering-agnostic, exactly like the macOS branch's matching
    /// scan, so this works unchanged whether the buffer is BGRA (GDI+'s own
    /// format) or any other 4-byte-per-pixel layout.
    private static func paintedPixelBounds(bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = bytes.advanced(by: y * stride)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                var painted = false
                for channel in 0..<4 where pixel[channel] != 0 {
                    painted = true
                    break
                }
                if painted {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }
    #endif

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
            // `BoundedLocalFile.read` immediately above this call.
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
