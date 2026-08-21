import AppKit
import Foundation
import ImageIO

enum AnnotationVerificationError: LocalizedError {
    case invalidPath
    case unreadableFile
    case unsupportedImage
    case imageTooLarge
    case aspectRatioMismatch(scaleX: Double, scaleY: Double)
    case renderFailed
    case outputTooLarge

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
        case .outputTooLarge:
            return "The verification PNG exceeds the raw-image allowance for the 8 MB encoded MCP response limit. Use a smaller or more tightly cropped screenshot."
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
/// This deliberately does NOT capture the overlay window. Computer-use has
/// proven that it filters that window even when `sharingType == .readOnly`.
/// Instead, this uses `OverlayView.drawAnnotations` -- the live overlay's exact
/// renderer -- against the same screen point geometry, then scales the result
/// into the screenshot. The resulting crop proves coordinate alignment against
/// the UI pixels the agent saw without claiming that WindowServer presented the
/// separate live overlay window.
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

    /// Compatibility spelling for callers/tests that previously consumed the
    /// raw output limit directly.
    static let maxOutputBytes = maxRawPNGBytes
    static let maxRelativeScaleDifference = 0.02

    static func composite(
        annotation: Annotation,
        screen: ScreenInfo,
        screenshotPath: String,
        paddingPx: Double = defaultPaddingPx,
        rasterLease: RasterAssetStore.Lease? = nil
    ) throws -> AnnotationVerificationComposite {
        let screenshot = try loadScreenshot(path: screenshotPath)
        return try composite(
            annotation: annotation,
            screen: screen,
            screenshot: screenshot,
            paddingPx: paddingPx,
            rasterLease: rasterLease
        )
    }

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
        let relativeDifference = abs(scaleX - scaleY) / max(scaleX, scaleY)
        guard relativeDifference <= maxRelativeScaleDifference else {
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
            let renderer = OverlayView(frame: CGRect(origin: .zero, size: sourceSize))
            renderer.scaleFactor = CGFloat(screen.backingScaleFactor)
            renderer.screenId = screen.id
            renderer.drawAnnotations(
                [annotation],
                in: cgContext,
                canvasSize: sourceSize,
                rasterLease: rasterLease
            )
            cgContext.restoreGState()
            overlayContext.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return overlayRep
        }

        guard let paintedTopLeft = paintedPixelBounds(in: overlayRep) else {
            throw AnnotationVerificationError.renderFailed
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
            "scaleDifferencePercent": relativeDifference * 100,
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

    /// Pure transport accounting used by the encoder and unit tests.  The
    /// encoded length rounds up to a whole four-byte base64 quantum.
    static func isWithinResponseBudget(rawPNGBytes: Int) -> Bool {
        guard rawPNGBytes >= 0 else { return false }
        let groups = rawPNGBytes / 3 + (rawPNGBytes % 3 == 0 ? 0 : 1)
        guard groups <= Int.max / 4 else { return false }
        let base64Bytes = groups * 4
        return base64Bytes <= maxTransportResponseBytes - maxTransportOverheadBytes
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

    private static func rectObject(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [String: Double] {
        ["x": Double(x), "y": Double(y), "width": Double(width), "height": Double(height)]
    }
}
