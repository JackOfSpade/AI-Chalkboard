// This entire suite is macOS-only, guarded as a whole rather than
// test-by-test: every fixture and every assertion below is built directly
// on AppKit/CoreGraphics types that either do not exist on Windows or exist
// with a materially different shape there --
//   * `NSBitmapImageRep`/`NSGraphicsContext`/`NSBezierPath`/`NSColor` (used
//     throughout to build PNG fixtures AND to read back individual composited
//     pixels via `NSBitmapImageRep.colorAt(x:y:)`) have no counterpart at
//     all; the Windows renderer reads/writes raw premultiplied-BGRA buffers
//     through WIC (`chalk_image_encode_png`/`chalk_image_decode_file`) and
//     GDI+, not a bitmap-rep object with per-pixel `NSColor` accessors.
//   * `CoreGraphicsDrawingContext` (used directly by several tests below to
//     drive `AnnotationRenderer.drawAnnotations` outside the compositor) is
//     macOS-only; the Windows `DrawingContext` implementation is
//     `GDIPlusDrawingContext`, constructed and inspected differently.
//   * `AnnotationVerificationCompositor.composite(...screenshot: CGImage...)`
//     is a CGImage-typed overload that only exists on macOS -- the Windows
//     branch's in-memory overload takes `WindowsScreenCaptureImage` instead
//     (see `AnnotationVerificationCompositor.swift`'s Windows branch).
// A true Windows equivalent of this suite (built on `GDIPlusDrawingContext`,
// raw BGRA buffer sampling in place of `colorAt`, and
// `WindowsScreenCaptureImage` fixtures) is real, valuable, currently-missing
// coverage -- deliberately left as follow-up work rather than approximated
// here, since it amounts to a parallel test suite rather than a mechanical
// per-line port.
#if os(macOS)
import AppKit
import ImageIO
import XCTest
@testable import AIChalkboardCore

final class AnnotationVerificationCompositorTests: XCTestCase {
    private func screen(width: Int = 200, height: Int = 100, scale: Double = 1,
                        id: String = "screen-1", index: Int = 0) -> ScreenInfo {
        ScreenInfo(id: id, index: index, name: "Test Screen", widthPx: width, heightPx: height,
                   widthPt: Double(width) / scale, heightPt: Double(height) / scale,
                   backingScaleFactor: scale, isMain: index == 0)
    }

    private func png(width: Int, height: Int, color: NSColor = .blue) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [],
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-chalkboard-verification-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pathKind(_ data: String = "M40 20 L120 20 L80 70 Z") -> AnnotationKind {
        .vectorPath(data: data, strokeColorHex: "#FF0000", strokeWidth: 4, strokeOpacity: 1,
                    fillColorHex: "#FF0000", fillOpacity: 0.2, dash: [], usesEvenOddFillRule: false,
                    coordinateScaleX: 1, coordinateScaleY: 1)
    }

    private func annotation(_ kind: AnnotationKind) -> Annotation {
        Annotation(id: UUID().uuidString, screenId: "screen-1", kind: kind, colorHex: "#00FF00")
    }

    private func paintedBounds(_ result: AnnotationVerificationComposite) throws -> [String: Double] {
        try XCTUnwrap(result.metadata["paintedBoundsScreenshotPx"] as? [String: Double])
    }

    func testSVGPathCompositeMapsBackingCoordinatesAndReturnsPNG() throws {
        let source = try png(width: 100, height: 50)
        let result = try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshotPath: source.path, paddingPx: 5)
        XCTAssertTrue(result.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let painted = try paintedBounds(result)
        XCTAssertGreaterThan(painted["width"] ?? 0, 30)
        XCTAssertGreaterThan(painted["height"] ?? 0, 20)
        XCTAssertLessThan(painted["x"] ?? 1000, 30)
        let output = try XCTUnwrap(NSBitmapImageRep(data: result.pngData))
        XCTAssertGreaterThan(output.pixelsWide, Int(painted["width"] ?? 0))
    }

    func testSVGImageAndBatchUseSharedRendererAndBatchPathMatchesStandalonePath() throws {
        let source = try png(width: 200, height: 100)
        let rasterSource = try png(width: 12, height: 8, color: .red)
        let asset = try RasterAssetStore.shared.load(path: rasterSource.path)
        addTeardownBlock { _ = RasterAssetStore.shared.remove(id: asset.id) }

        let path = pathKind()
        let image = AnnotationKind.image(assetId: asset.id, x: 140, y: 20, width: 30, height: 20,
                                         rotationDegrees: 10, opacity: 0.8)
        let batch = AnnotationKind.batch(items: [
            AnnotationComponent(kind: path, colorHex: "#00FF00"),
            AnnotationComponent(kind: image, colorHex: "#FFFFFF")
        ])

        let standalonePath = try AnnotationVerificationCompositor.composite(annotation: annotation(path), screen: screen(), screenshotPath: source.path, paddingPx: 2)
        let standaloneImage = try AnnotationVerificationCompositor.composite(annotation: annotation(image), screen: screen(), screenshotPath: source.path, paddingPx: 2)
        let grouped = try AnnotationVerificationCompositor.composite(annotation: annotation(batch), screen: screen(), screenshotPath: source.path, paddingPx: 2)
        XCTAssertFalse(standalonePath.pngData.isEmpty)
        XCTAssertFalse(standaloneImage.pngData.isEmpty)
        XCTAssertFalse(grouped.pngData.isEmpty)
        XCTAssertEqual(standalonePath.metadata["annotationType"] as? String, "path")
        XCTAssertEqual(standaloneImage.metadata["annotationType"] as? String, "image")
        XCTAssertEqual(grouped.metadata["annotationType"] as? String, "batch")

        // A single-element batch must be visually identical to its direct SVG
        // counterpart, proving recursive batch dispatch shares the renderer.
        let singleBatch = AnnotationKind.batch(items: [AnnotationComponent(kind: path, colorHex: "#00FF00")])
        let batchPath = try AnnotationVerificationCompositor.composite(annotation: annotation(singleBatch), screen: screen(), screenshotPath: source.path, paddingPx: 2)
        XCTAssertEqual(try paintedBounds(standalonePath), try paintedBounds(batchPath))
    }

    func testTextAndScaledPathUseTheSharedVerificationRenderer() throws {
        let source = try png(width: 200, height: 100)
        let text = AnnotationKind.text(
            text: "Fusion", x: 40, y: 15, fontSize: 18, textColorHex: "#FFFFFF",
            backgroundColorHex: "#000000", backgroundOpacity: 0.7, paddingPx: 4, opacity: 1
        )
        let textResult = try AnnotationVerificationCompositor.composite(
            annotation: annotation(text), screen: screen(), screenshotPath: source.path, paddingPx: 1
        )
        XCTAssertEqual(textResult.metadata["annotationType"] as? String, "text")
        XCTAssertFalse(textResult.pngData.isEmpty)

        let normalizedPath = AnnotationKind.vectorPath(
            data: "M 0.1 0.1 L 0.5 0.5", strokeColorHex: "#FF0000", strokeWidth: 3,
            strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [], usesEvenOddFillRule: false,
            coordinateScaleX: 200, coordinateScaleY: 100
        )
        let pathResult = try AnnotationVerificationCompositor.composite(
            annotation: annotation(normalizedPath), screen: screen(), screenshotPath: source.path, paddingPx: 1
        )
        let bounds = try paintedBounds(pathResult)
        XCTAssertLessThan(bounds["x"] ?? 999, 30)
        XCTAssertGreaterThan(bounds["width"] ?? 0, 60)
    }

    func testTextPrimitiveOpacityMultipliesBackgroundAlpha() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 200, height: 100))
        let drawingContext = CoreGraphicsDrawingContext(context: graphics.cgContext)
        let text = AnnotationKind.text(
            text: "A", x: 20, y: 20, fontSize: 12, textColorHex: "white",
            backgroundColorHex: "black", backgroundOpacity: 1, paddingPx: 20, opacity: 0.5
        )
        AnnotationRenderer.drawAnnotations(
            [annotation(text)], into: drawingContext, canvasSize: CGSize(width: 200, height: 100), scaleFactor: 1
        ) { _ in nil }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // The sampled point is inside the padded background but outside the
        // glyph. Named black starts at alpha 0.9, then text opacity halves it.
        let alpha = try XCTUnwrap(rep.colorAt(x: 23, y: 70)).alphaComponent
        XCTAssertGreaterThan(alpha, 0.35)
        XCTAssertLessThan(alpha, 0.6)
    }

    func testPathFillOpacityMultipliesParsedColorAlpha() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 200, height: 100))
        let drawingContext = CoreGraphicsDrawingContext(context: graphics.cgContext)
        let filledSquare = AnnotationKind.vectorPath(
            data: "M 20 20 L 180 20 L 180 80 L 20 80 Z", strokeColorHex: nil, strokeWidth: 0,
            strokeOpacity: 0, fillColorHex: "black", fillOpacity: 0.5, dash: [],
            usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1
        )
        AnnotationRenderer.drawAnnotations(
            [annotation(filledSquare)], into: drawingContext, canvasSize: CGSize(width: 200, height: 100), scaleFactor: 1
        ) { _ in nil }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // Named black has alpha 0.9; fill_opacity 0.5 must yield roughly
        // 0.45, rather than replacing the parsed alpha with 0.5.
        let alpha = try XCTUnwrap(rep.colorAt(x: 100, y: 50)).alphaComponent
        XCTAssertGreaterThan(alpha, 0.40)
        XCTAssertLessThan(alpha, 0.49)
    }

    func testRawPNGBudgetIncludesBase64AndJSONReserve() {
        let raw = AnnotationVerificationCompositor.maxRawPNGBytes
        XCTAssertTrue(AnnotationVerificationCompositor.isWithinResponseBudget(rawPNGBytes: raw))
        XCTAssertFalse(AnnotationVerificationCompositor.isWithinResponseBudget(rawPNGBytes: raw + 1))

        let encodedBytes = ((raw + 2) / 3) * 4
        XCTAssertLessThanOrEqual(
            encodedBytes + AnnotationVerificationCompositor.maxTransportOverheadBytes,
            AnnotationVerificationCompositor.maxTransportResponseBytes
        )
    }

    func testOversizedImageMetadataIsRejectedBeforeDecodeArithmetic() throws {
        // This is deliberately synthetic: creating a real 20+ megapixel
        // bitmap would allocate the very resource this preflight protects.
        // The helper is the exact branch `loadScreenshot` runs before asking
        // ImageIO to decode a CGImage.
        let oversized: [CFString: Any] = [
            kCGImagePropertyPixelWidth: NSNumber(value: AnnotationVerificationCompositor.maxImagePixels + 1),
            kCGImagePropertyPixelHeight: NSNumber(value: 1)
        ]
        let oversizedDimensions = try XCTUnwrap(AnnotationVerificationCompositor.usableMetadataDimensions(oversized))
        XCTAssertFalse(AnnotationVerificationCompositor.imageDimensionsFitImageLimit(
            width: oversizedDimensions.width, height: oversizedDimensions.height
        ))

        let boundary: [CFString: Any] = [
            kCGImagePropertyPixelWidth: NSNumber(value: AnnotationVerificationCompositor.maxImagePixels),
            kCGImagePropertyPixelHeight: NSNumber(value: 1)
        ]
        let boundaryDimensions = try XCTUnwrap(AnnotationVerificationCompositor.usableMetadataDimensions(boundary))
        XCTAssertTrue(AnnotationVerificationCompositor.imageDimensionsFitImageLimit(
            width: boundaryDimensions.width, height: boundaryDimensions.height
        ))
        XCTAssertFalse(AnnotationVerificationCompositor.imageDimensionsFitImageLimit(width: Int.max, height: 2),
                       "overflow-safe division must reject dimensions without multiplying them")
        XCTAssertNil(AnnotationVerificationCompositor.usableMetadataDimensions([:]),
                     "missing metadata must not authorize a decode")
        let overflowing: [CFString: Any] = [
            kCGImagePropertyPixelWidth: NSNumber(value: UInt64.max),
            kCGImagePropertyPixelHeight: NSNumber(value: 1)
        ]
        XCTAssertNil(AnnotationVerificationCompositor.usableMetadataDimensions(overflowing),
                     "unrepresentable metadata must not authorize a decode")

        for invalidWidth: NSNumber in [
            NSNumber(value: 1.5), NSNumber(value: Double.nan), NSNumber(value: Double.infinity), NSNumber(value: true)
        ] {
            let invalid: [CFString: Any] = [
                kCGImagePropertyPixelWidth: invalidWidth,
                kCGImagePropertyPixelHeight: NSNumber(value: 1)
            ]
            XCTAssertNil(AnnotationVerificationCompositor.usableMetadataDimensions(invalid),
                         "non-integral/non-finite/boolean metadata must not authorize a decode: \(invalidWidth)")
        }
    }

    func testAspectMismatchRejectsCroppedOrWindowScreenshot() throws {
        let square = try png(width: 100, height: 100)
        XCTAssertThrowsError(try AnnotationVerificationCompositor.composite(annotation: annotation(pathKind()), screen: screen(), screenshotPath: square.path)) { error in
            guard case AnnotationVerificationError.aspectRatioMismatch = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testSmallButMaterialScaleMismatchIsRejected() throws {
        // 198x100 is a 1% discrepancy. The old fixed 2% tolerance and the
        // first over-broad rounding formula both accepted it, but no uniform
        // scale rounded to nearest pixels can produce it from 200x100.
        let source = try png(width: 198, height: 100)
        XCTAssertThrowsError(try AnnotationVerificationCompositor.composite(annotation: annotation(pathKind()), screen: screen(), screenshotPath: source.path)) { error in
            guard case AnnotationVerificationError.aspectRatioMismatch = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testRelativeScreenshotPathIsRejected() {
        XCTAssertThrowsError(try AnnotationVerificationCompositor.composite(annotation: annotation(pathKind()), screen: screen(), screenshotPath: "relative.png")) { error in
            guard case AnnotationVerificationError.invalidPath = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    /// PINS THE macOS SCALE CHAIN AGAINST REFACTOR DRIFT. The scale factor
    /// handed to `AnnotationRenderer` now comes from the shared
    /// `OverlayDrawingMetrics.rendererScaleFactor` definition (the Windows
    /// verifier was reading a different one than the Windows live overlay);
    /// macOS behavior had to stay bit-for-bit unchanged through that
    /// refactor, and nothing else in this suite exercises a backing scale
    /// other than 1.
    ///
    /// THE ARITHMETIC, so a future edit can tell a drift from a fix: a
    /// 400x200-backing-pixel display at 2x is a 200x100 POINT canvas, and the
    /// screenshot here is that display's full backing resolution (image-to-
    /// screen scale exactly 1.0). The path's MCP x=100 divides by the backing
    /// scale to point 50, which the compositor's point-canvas-to-screenshot
    /// scale (400/200 = 2) multiplies straight back to screenshot pixel 100.
    /// MCP y=40 flips to point 100 - 20 = 80 and lands at screenshot row
    /// 200 - 160 = 40. So the painted box must be the annotation's own MCP
    /// backing-pixel box, exactly: a wrong divisor anywhere in that chain
    /// moves and resizes it by the whole scale factor -- which is precisely
    /// the failure the Windows branch used to ship.
    func testCompositeAtBackingScaleTwoPinsPaintedBoundsToTheAnnotationsBackingPixels() throws {
        let source = try png(width: 400, height: 200)
        // Fill only, no stroke: a stroke's half-width would spread the
        // painted box past the geometry and blur what this test is pinning.
        let rect = AnnotationKind.vectorPath(
            data: "M 100 40 L 300 40 L 300 160 L 100 160 Z", strokeColorHex: nil, strokeWidth: 0,
            strokeOpacity: 0, fillColorHex: "#FF0000", fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1
        )
        let result = try AnnotationVerificationCompositor.composite(
            annotation: annotation(rect), screen: screen(width: 400, height: 200, scale: 2),
            screenshotPath: source.path, paddingPx: 0
        )
        XCTAssertEqual(result.metadata["backingScaleFactor"] as? Double, 2)
        XCTAssertEqual(try paintedBounds(result), ["x": 100, "y": 40, "width": 200, "height": 120])
    }

    /// THE DUAL-IDENTICAL-MONITOR FAILURE. `ScreenshotGeometry
    /// .fullDisplayScale` only ever compared the image against ONE screen's
    /// dimensions and carries no display identity, so a screenshot of the
    /// OTHER 200x100 display passed at scale 1.0 and the annotation was
    /// composited over unrelated UI -- a convincing picture of a placement
    /// error that does not exist.
    func testAmbiguousScreenshotIsRejectedWhenSeveralConnectedDisplaysAcceptIt() throws {
        let source = try png(width: 200, height: 100)
        let connected = [screen(), screen(id: "screen-2", index: 1)]
        XCTAssertThrowsError(try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshotPath: source.path,
            paddingPx: 2, ambiguityCandidateScreens: connected
        )) { error in
            guard case AnnotationVerificationError.ambiguousScreenshotDisplay = error else {
                return XCTFail("unexpected error: \(error)")
            }
            let message = error.localizedDescription
            // Both candidates must be NAMED: the correction is one argument
            // away only if the caller can see what it is choosing between.
            XCTAssertTrue(message.contains("screen-1"), message)
            XCTAssertTrue(message.contains("screen-2"), message)
            XCTAssertTrue(message.contains("screenshot_screen_id"), message)
            XCTAssertTrue(message.contains("capture_source='chalkboard'"), message)
        }
    }

    /// The ambiguity filter counts a candidate only when the image could
    /// PLAUSIBLY be a capture of it -- uniform mapping AND no upscale
    /// (`ScreenshotGeometry.isPlausibleFullDisplayCapture`) -- so a native
    /// capture of the annotation's display is NOT ambiguous against a
    /// same-aspect smaller sibling, which the image "fits" only via an
    /// enlargement no screenshot pipeline produces. Aspect-only counting
    /// rejected exactly this formerly-valid verification.
    func testNativeCaptureIsNotAmbiguousAgainstASameAspectSmallerSibling() throws {
        XCTAssertFalse(ScreenshotGeometry.isPlausibleFullDisplayCapture(
            screenshotWidth: 400, screenshotHeight: 200, screenWidth: 200, screenHeight: 100
        ), "an upscale is not a plausible capture")
        XCTAssertTrue(ScreenshotGeometry.isPlausibleFullDisplayCapture(
            screenshotWidth: 400, screenshotHeight: 200, screenWidth: 400, screenHeight: 200
        ), "a native capture is")
        XCTAssertTrue(ScreenshotGeometry.isPlausibleFullDisplayCapture(
            screenshotWidth: 200, screenshotHeight: 100, screenWidth: 400, screenHeight: 200
        ), "and so is a downsample")

        let source = try png(width: 400, height: 200)
        let big = screen(width: 400, height: 200)
        let smallSibling = screen(width: 200, height: 100, id: "screen-2", index: 1)
        let result = try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: big, screenshotPath: source.path,
            paddingPx: 2, ambiguityCandidateScreens: [big, smallSibling]
        )
        XCTAssertFalse(result.pngData.isEmpty)
    }

    /// The counterpart boundary: an image that is native for one display AND
    /// a clean half-resolution downsample of another is plausible for both,
    /// so it must still refuse to guess.
    func testDownsamplePlausibleForSeveralDisplaysIsStillAmbiguous() throws {
        let source = try png(width: 400, height: 200)
        let native = screen(width: 400, height: 200)
        let doubled = screen(width: 800, height: 400, id: "screen-2", index: 1)
        XCTAssertThrowsError(try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: native, screenshotPath: source.path,
            paddingPx: 2, ambiguityCandidateScreens: [native, doubled]
        )) { error in
            guard case AnnotationVerificationError.ambiguousScreenshotDisplay = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// The way out the rejection above advertises. A verified
    /// `screenshot_screen_id` (or Chalkboard's own capture) answers the
    /// which-display question BEFORE the compositor is called, which the
    /// handler expresses by passing no candidates at all -- see
    /// `handleVerifyAnnotation`.
    func testAssertedScreenshotDisplayLeavesNothingToDisambiguate() throws {
        let source = try png(width: 200, height: 100)
        let result = try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshotPath: source.path,
            paddingPx: 2, ambiguityCandidateScreens: []
        )
        XCTAssertFalse(result.pngData.isEmpty)
        XCTAssertEqual(result.metadata["screenId"] as? String, "screen-1")
        // Every verification must NAME the display it interpreted the
        // screenshot as, not merely carry it as a field a caller may skip.
        XCTAssertTrue((result.metadata["verificationNote"] as? String ?? "").contains("display screen-1"),
                      "the note must say which display this image was interpreted as")
    }

    /// THE ORDINARY SINGLE-DISPLAY SETUP MUST BE UNTOUCHED: one accepting
    /// display is not ambiguous, so the full connected-screen list changes
    /// nothing about the result.
    func testSingleConnectedDisplayCompositesExactlyAsBefore() throws {
        let source = try png(width: 200, height: 100)
        let guarded = try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshotPath: source.path,
            paddingPx: 2, ambiguityCandidateScreens: [screen()]
        )
        let unguarded = try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshotPath: source.path, paddingPx: 2
        )
        XCTAssertEqual(try paintedBounds(guarded), try paintedBounds(unguarded))
    }

    /// A screenshot whose dimensions fit NO connected display keeps its
    /// previous meaning (`aspectRatioMismatch`) even with several candidates
    /// in hand -- the mismatch guard runs first, exactly as it does on the
    /// draw path.
    func testDimensionMismatchStillOutranksTheAmbiguityGuard() throws {
        let square = try png(width: 100, height: 100)
        XCTAssertThrowsError(try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshotPath: square.path,
            ambiguityCandidateScreens: [screen(), screen(id: "screen-2", index: 1)]
        )) { error in
            guard case AnnotationVerificationError.aspectRatioMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// The `screenshot_screen_id`-names-the-wrong-display refusal. Pure text,
    /// reachable with no MCP transport, which is why it lives beside the
    /// ambiguity guard rather than inline in `handleVerifyAnnotation`.
    func testScreenshotOfAnotherDisplayIsRefusedAndNamesBothDisplays() throws {
        let rejection = try XCTUnwrap(AnnotationVerificationCompositor.screenshotDisplayMismatchRejection(
            annotationId: "annotation-9", annotationScreenId: "screen-1", screenshotScreenId: "screen-2"
        ))
        XCTAssertTrue(rejection.contains("lives on display screen-1"), rejection)
        XCTAssertTrue(rejection.contains("screenshot of display screen-2"), rejection)
        XCTAssertTrue(rejection.contains("cannot prove or refute"), rejection)
        XCTAssertTrue(rejection.contains("capture_source='chalkboard'"), rejection)
        XCTAssertNil(AnnotationVerificationCompositor.screenshotDisplayMismatchRejection(
            annotationId: "annotation-9", annotationScreenId: "screen-1", screenshotScreenId: "screen-1"
        ), "asserting the annotation's own display is the supported, non-rejected case")
    }

    func testInMemoryCGImageUsesTheSameCompositePathAsFileInput() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = try XCTUnwrap(rep.cgImage)
        let result = try AnnotationVerificationCompositor.composite(
            annotation: annotation(pathKind()), screen: screen(), screenshot: image, paddingPx: 2
        )
        XCTAssertFalse(result.pngData.isEmpty)
        XCTAssertEqual(result.metadata["screenshotPixels"] as? [String: Int], ["width": 200, "height": 100])
    }

    // MARK: - Renderer: `Annotation.effectiveAdjustment` integration
    //
    // `AnnotationRenderer.drawAnnotations`/`drawKind` fold an anchored
    // annotation's `effectiveAdjustment` (see RENDERER_MATH.md) into every
    // primitive's own coordinates and into the per-annotation offset
    // translate, while leaving the four STYLE dimensions -- `strokeWidth`,
    // `dash`, `fontSize`, `paddingPx` -- untouched. These tests call
    // `AnnotationRenderer.drawAnnotations` directly (bypassing the
    // compositor's crop/aspect-ratio machinery entirely, which has nothing
    // to do with this) to pin both halves of that contract: an identity
    // adjustment must be numerically indistinguishable from having no
    // adjustment at all, and a non-identity one must move/resize GEOMETRY
    // while leaving every style dimension's rendered extent unchanged.

    private func renderedBitmap(_ annotation: Annotation, width: Int = 400, height: Int = 100, scale: CGFloat = 1) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let drawingContext = CoreGraphicsDrawingContext(context: graphics.cgContext)
        AnnotationRenderer.drawAnnotations(
            [annotation], into: drawingContext, canvasSize: CGSize(width: width, height: height), scaleFactor: scale
        ) { _ in nil }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Bounding box of every non-transparent pixel in `rep`, in raw top-left
    /// bitmap row/column coordinates. A local, `colorAt`-based equivalent of
    /// `AnnotationVerificationCompositor`'s private byte-scanning
    /// `paintedPixelBounds(in:)` -- kept as its own small helper rather than
    /// widening that production method's access, since this suite has no
    /// other reason to reach into it.
    private func rendererPaintedBounds(in rep: NSBitmapImageRep) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0 else { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX, maxY)
    }

    private func dashedHorizontalLineKind(strokeWidth: Double = 4) -> AnnotationKind {
        .vectorPath(
            data: "M 10 50 L 100 50", strokeColorHex: "#000000", strokeWidth: strokeWidth,
            strokeOpacity: 1, fillColorHex: nil, fillOpacity: 0, dash: [10, 10],
            usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1
        )
    }

    private func rendererTestWindowAnchor(referenceScreenId: String = "screen-1") -> AnnotationAnchor {
        AnnotationAnchor(
            mode: .window, resize: .scale,
            target: AnchorWindowTarget(processId: 1, windowId: 1, appId: "com.example.target"),
            referenceWindowFrame: AnchorRect(x: 0, y: 0, width: 400, height: 100),
            referenceScreenId: referenceScreenId
        )
    }

    private func rendererTestProjection(scaleX: Double = 1, scaleY: Double = 1, translateX: Double = 0, translateY: Double = 0) -> AnchorProjection {
        AnchorProjection(
            state: .tracking,
            adjustment: AnchorAdjustment(scaleX: scaleX, scaleY: scaleY, translateX: translateX, translateY: translateY),
            effectiveScreenId: "screen-1",
            currentWindowFrame: AnchorRect(x: 0, y: 0, width: 400, height: 100),
            sampledAt: Date()
        )
    }

    /// PINS THE "NO BRANCH" CLAIM in RENDERER_MATH.md's Change 1: multiplying
    /// by the identity adjustment's literal 1.0/adding its literal 0.0 is
    /// exact in IEEE 754, so an anchored annotation whose CURRENT projection
    /// happens to be identity must render pixel-for-pixel identically to a
    /// plain unanchored annotation with the same geometry -- there is no
    /// separate "unanchored" code path left to drift out of sync with this
    /// one.
    func testUnanchoredAndIdentityAdjustedAnchoredAnnotationsRenderBitForBitIdentically() throws {
        let unanchored = Annotation(
            id: "unanchored", screenId: "screen-1", kind: dashedHorizontalLineKind(),
            offsetX: 3, offsetY: -2
        )
        let identityAnchored = Annotation(
            id: "identity-anchored", screenId: "screen-1", kind: dashedHorizontalLineKind(),
            offsetX: 3, offsetY: -2,
            anchor: rendererTestWindowAnchor(), anchorProjection: rendererTestProjection()
        )

        let plainBitmap = try renderedBitmap(unanchored)
        let adjustedBitmap = try renderedBitmap(identityAnchored)
        let plainBytes = try XCTUnwrap(plainBitmap.bitmapData).withMemoryRebound(to: UInt8.self, capacity: plainBitmap.bytesPerRow * plainBitmap.pixelsHigh) {
            Data(bytes: $0, count: plainBitmap.bytesPerRow * plainBitmap.pixelsHigh)
        }
        let adjustedBytes = try XCTUnwrap(adjustedBitmap.bitmapData).withMemoryRebound(to: UInt8.self, capacity: adjustedBitmap.bytesPerRow * adjustedBitmap.pixelsHigh) {
            Data(bytes: $0, count: adjustedBitmap.bytesPerRow * adjustedBitmap.pixelsHigh)
        }

        XCTAssertEqual(plainBytes, adjustedBytes,
                       "an identity effectiveAdjustment must be numerically indistinguishable from no adjustment at all")
    }

    /// PINS "STYLE DIMENSIONS NEVER SCALE" for `strokeWidth` and `dash`
    /// against a non-identity adjustment, using a single horizontal dashed
    /// stroke so both can be read off one pair of renders: the painted
    /// box's VERTICAL extent is governed only by `strokeWidth` (a horizontal
    /// line's thickness), and the number of dash on/off cycles along its
    /// length is governed only by the dash period -- neither may move when
    /// `adjustment.scaleX` triples the line's own length.
    func testEffectiveAdjustmentScalesGeometryButLeavesStrokeWidthAndDashUnscaled() throws {
        let identity = Annotation(id: "identity", screenId: "screen-1", kind: dashedHorizontalLineKind())
        let scaled = Annotation(
            id: "scaled", screenId: "screen-1", kind: dashedHorizontalLineKind(),
            anchor: rendererTestWindowAnchor(), anchorProjection: rendererTestProjection(scaleX: 3, scaleY: 1)
        )

        let identityBitmap = try renderedBitmap(identity)
        let scaledBitmap = try renderedBitmap(scaled)
        let identityBounds = try XCTUnwrap(rendererPaintedBounds(in: identityBitmap))
        let scaledBounds = try XCTUnwrap(rendererPaintedBounds(in: scaledBitmap))

        let identityWidth = identityBounds.maxX - identityBounds.minX + 1
        let scaledWidth = scaledBounds.maxX - scaledBounds.minX + 1
        let identityHeight = identityBounds.maxY - identityBounds.minY + 1
        let scaledHeight = scaledBounds.maxY - scaledBounds.minY + 1

        // GEOMETRY must scale: a 3x horizontal `adjustment.scaleX` roughly
        // triples the painted span (allowing slack for the stroke's own
        // round-cap extension at both ends, which does not itself scale) --
        // this is the sanity check that the adjustment is doing anything at
        // all, so the two assertions below actually mean something.
        XCTAssertGreaterThan(Double(scaledWidth), Double(identityWidth) * 2.5, "line length must scale with the adjustment")

        // STROKE WIDTH must not scale: the painted VERTICAL extent of a
        // horizontal line is governed only by `strokeWidth`, never by
        // `coordinateScaleX`/`adjustment.scaleX` -- if `strokeWidth` were
        // ever multiplied by `adjustment.scaleX` by mistake, this would
        // triple too, exactly like the width above just did.
        XCTAssertEqual(Double(scaledHeight), Double(identityHeight), accuracy: 2,
                       "strokeWidth is a backing-pixel STYLE dimension and must not scale with the adjustment")

        // DASH must not scale: count on/off transitions along the painted
        // row at the line's vertical center. An UNSCALED dash period means
        // roughly 3x as many dash cycles fit across the 3x-longer scaled
        // line; a dash that scaled along with geometry would keep the same
        // cycle count instead, since both the line and the period would
        // have grown together.
        func dashCycleCount(in rep: NSBitmapImageRep, atY y: Int, from minX: Int, to maxX: Int) -> Int {
            var cycles = 0
            var wasPainted = false
            for x in minX...maxX {
                let painted = (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
                if painted, !wasPainted { cycles += 1 }
                wasPainted = painted
            }
            return cycles
        }
        let identityCycles = dashCycleCount(
            in: identityBitmap, atY: (identityBounds.minY + identityBounds.maxY) / 2,
            from: identityBounds.minX, to: identityBounds.maxX
        )
        let scaledCycles = dashCycleCount(
            in: scaledBitmap, atY: (scaledBounds.minY + scaledBounds.maxY) / 2,
            from: scaledBounds.minX, to: scaledBounds.maxX
        )
        XCTAssertGreaterThan(scaledCycles, identityCycles * 2,
                             "an unscaled dash period must produce noticeably more cycles across a 3x-longer line")
    }

    /// PINS "STYLE DIMENSIONS NEVER SCALE" for `fontSize`/`paddingPx`: the
    /// text background box's own SIZE must be identical whether or not a
    /// non-identity adjustment is applied, even though the box's POSITION
    /// must move with that same adjustment.
    func testEffectiveAdjustmentScalesTextPositionButLeavesFontSizeAndPaddingUnscaled() throws {
        func textKind() -> AnnotationKind {
            .text(text: "Anchor", x: 20, y: 20, fontSize: 16, textColorHex: "#FFFFFF",
                  backgroundColorHex: "#000000", backgroundOpacity: 1, paddingPx: 6, opacity: 1)
        }
        let identity = Annotation(id: "identity-text", screenId: "screen-1", kind: textKind())
        let scaled = Annotation(
            id: "scaled-text", screenId: "screen-1", kind: textKind(),
            anchor: rendererTestWindowAnchor(), anchorProjection: rendererTestProjection(scaleX: 2, scaleY: 2, translateX: 50)
        )

        let identityBounds = try XCTUnwrap(rendererPaintedBounds(in: try renderedBitmap(identity)))
        let scaledBounds = try XCTUnwrap(rendererPaintedBounds(in: try renderedBitmap(scaled)))
        let identitySize = (
            width: identityBounds.maxX - identityBounds.minX + 1,
            height: identityBounds.maxY - identityBounds.minY + 1
        )
        let scaledSize = (
            width: scaledBounds.maxX - scaledBounds.minX + 1,
            height: scaledBounds.maxY - scaledBounds.minY + 1
        )

        XCTAssertEqual(Double(scaledSize.width), Double(identitySize.width), accuracy: 1,
                       "fontSize/paddingPx must not scale -- the text box's own size must be unaffected")
        XCTAssertEqual(Double(scaledSize.height), Double(identitySize.height), accuracy: 1,
                       "fontSize/paddingPx must not scale -- the text box's own size must be unaffected")

        // POSITION must scale: x=20 under scaleX=2, translateX=50 lands at
        // backing pixel 90 instead of 20, so the scaled box must start well
        // to the right of the identity box's -- proving the two boxes
        // matching in SIZE above is not simply because the adjustment did
        // nothing.
        XCTAssertGreaterThan(scaledBounds.minX, identityBounds.minX + 30,
                             "the text's own position must move with the adjustment even though its size does not")
    }

    // MARK: - `renderedPaintedBounds(of:on:)` -- `get_annotation_bounds`'s renderer

    /// PINS the exact same scale-chain arithmetic as
    /// `testCompositeAtBackingScaleTwoPinsPaintedBoundsToTheAnnotationsBackingPixels`
    /// above, but through `renderedPaintedBounds(of:on:)` -- the entry point
    /// `get_annotation_bounds` calls -- with NO screenshot involved at all.
    /// The two must agree exactly: both funnel through the same factored
    /// `renderAnnotationAlone` implementation (see that method's doc
    /// comment), so a 400x200-backing-pixel display at 2x backing scale
    /// (a 200x100 point canvas) must place this MCP-space rect at its own
    /// backing-pixel coordinates, unchanged, regardless of which of the two
    /// public entry points asked for it.
    func testRenderedPaintedBoundsMatchesCompositeAtTheSameBackingScale() throws {
        let rect = AnnotationKind.vectorPath(
            data: "M 100 40 L 300 40 L 300 160 L 100 160 Z", strokeColorHex: nil, strokeWidth: 0,
            strokeOpacity: 0, fillColorHex: "#FF0000", fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1
        )
        let target = screen(width: 400, height: 200, scale: 2)
        let bounds = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: annotation(rect), on: target
        ))
        XCTAssertEqual(bounds, CGRect(x: 100, y: 40, width: 200, height: 120))
    }

    /// A rotated image and a text annotation both need REAL rendering (glyph
    /// metrics; a rotated bounding box) to report correct bounds -- exactly
    /// the cases CAPTURE_GAP.md calls out as why `get_annotation_bounds` must
    /// share the compositor's renderer rather than recompute geometry from
    /// the stored fields (compare `PaintedBounds.swift`, which is
    /// EXPLICITLY only "good enough to pick a window", not pixel-exact, for
    /// precisely these two kinds). This only asserts the render PRODUCES
    /// bounds at all and that they differ from the unrotated/untextured
    /// stored rect, not exact pixels (which depend on font metrics).
    func testRenderedPaintedBoundsHandlesRotatedImageAndText() throws {
        let target = screen()
        let rasterSource = try png(width: 40, height: 20, color: .red)
        let asset = try RasterAssetStore.shared.load(path: rasterSource.path)
        addTeardownBlock { _ = RasterAssetStore.shared.remove(id: asset.id) }
        let rotatedImage = AnnotationKind.image(assetId: asset.id, x: 60, y: 20, width: 40, height: 20,
                                                 rotationDegrees: 45, opacity: 1)
        let imageBounds = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: annotation(rotatedImage), on: target
        ))
        // A 45-degree rotation of a 40x20 rect makes its axis-aligned
        // bounding box materially TALLER than the unrotated 20px height --
        // proof the renderer actually accounted for the rotation rather than
        // reporting the stored, unrotated rect back.
        XCTAssertGreaterThan(imageBounds.height, 25)

        let text = AnnotationKind.text(
            text: "Bounds", x: 10, y: 10, fontSize: 24, textColorHex: "#FFFFFF",
            backgroundColorHex: nil, backgroundOpacity: 0, paddingPx: 0, opacity: 1
        )
        let textBounds = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: annotation(text), on: target
        ))
        XCTAssertGreaterThan(textBounds.width, 0)
        XCTAssertGreaterThan(textBounds.height, 0)
    }

    // MARK: - `AnnotationBoundsSupport.correctedOffset` round trip through the LIVE renderer

    /// The end-to-end proof `AnnotationBoundsSupportTests`' arithmetic-only
    /// unit tests cannot give: applying the exact `correctionBackingPx`
    /// `get_annotation_bounds` would return, to a REAL anchored annotation's
    /// `offset_x`, and re-rendering through the live renderer, must land the
    /// painted result's centre on the caller's target -- not merely make the
    /// arithmetic self-consistent. This is what proves the sign and the
    /// division (by `adjustment.scaleX`/`scaleY`, not a multiplication) are
    /// actually correct, per the load-bearing correction the coordinator
    /// specified.
    func testCorrectedOffsetRoundTripLandsThePaintedCentreOnTheTarget() throws {
        // A 400x200-backing display at 2x -- the same scale-chain fixture
        // `testCompositeAtBackingScaleTwoPinsPaintedBoundsToTheAnnotationsBackingPixels`
        // uses above -- so this test is pinned against known-correct
        // backing-pixel arithmetic, not a fresh unverified fixture.
        let target = screen(width: 400, height: 200, scale: 2)
        // A small filled square, comfortably inside the 400x200 canvas even
        // after the anchor's 2x scale doubles its extent.
        let square = AnnotationKind.vectorPath(
            data: "M 50 30 L 90 30 L 90 70 L 50 70 Z", strokeColorHex: nil, strokeWidth: 0,
            strokeOpacity: 0, fillColorHex: "#FF0000", fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1
        )
        // The anchor's LIVE adjustment: the tracked window has grown 2x on
        // both axes since this annotation was created (a `.scale`-resize
        // anchor), with no translation -- exactly the case the coordinator's
        // note warns division, not addition, is required for.
        let anchor = rendererTestWindowAnchor()
        let projection = rendererTestProjection(scaleX: 2, scaleY: 2)

        let original = Annotation(
            id: "round-trip-original", screenId: "screen-1", kind: square,
            offsetX: 0, offsetY: 0, anchor: anchor, anchorProjection: projection
        )
        let originalBackingBounds = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: original, on: target
        ))
        // Sanity check on the fixture itself: the 40x40 square scales to
        // 80x80 at (100, 60) under the 2x adjustment with zero offset.
        XCTAssertEqual(originalBackingBounds, CGRect(x: 100, y: 60, width: 80, height: 80))

        // A caller-supplied screenshot half the display's backing size.
        let screenshotWidth = 200.0, screenshotHeight = 100.0
        let screenshotScale = (x: screenshotWidth / Double(target.widthPx), y: screenshotHeight / Double(target.heightPx))
        let paintedScreenshotRect = AnnotationBoundsSupport.screenshotRect(
            backingRect: originalBackingBounds, scale: screenshotScale
        )
        XCTAssertEqual(paintedScreenshotRect, CGRect(x: 50, y: 30, width: 40, height: 40))

        // The caller measured its target UI element 20 screenshot pixels to
        // the right of where the annotation actually painted (a same-size
        // rect, so only the centre needs to match).
        let targetRect = paintedScreenshotRect.offsetBy(dx: 20, dy: 0)
        let dx = Double(targetRect.midX - paintedScreenshotRect.midX)
        let dy = Double(targetRect.midY - paintedScreenshotRect.midY)
        XCTAssertEqual(dx, 20); XCTAssertEqual(dy, 0)

        let corrected = try XCTUnwrap(AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: original.offsetX, currentOffsetY: original.offsetY,
            deltaScreenshotX: dx, deltaScreenshotY: dy,
            screenshotToBackingScale: (x: 1 / screenshotScale.x, y: 1 / screenshotScale.y),
            adjustment: original.effectiveAdjustment
        ))

        // Apply the ABSOLUTE corrected offset exactly as `update_annotation`
        // would (REPLACING offsetX/offsetY, never adding to them) and
        // re-render through the SAME live renderer.
        let corrected1 = Annotation(
            id: "round-trip-corrected", screenId: "screen-1", kind: square,
            offsetX: corrected.offsetX, offsetY: corrected.offsetY, anchor: anchor, anchorProjection: projection
        )
        let correctedBackingBounds = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: corrected1, on: target
        ))
        let correctedScreenshotRect = AnnotationBoundsSupport.screenshotRect(
            backingRect: correctedBackingBounds, scale: screenshotScale
        )

        // THE PROOF: the re-rendered painted centre now sits on the target's
        // centre, in the caller's own screenshot pixel space.
        XCTAssertEqual(correctedScreenshotRect.midX, targetRect.midX, accuracy: 0.01)
        XCTAssertEqual(correctedScreenshotRect.midY, targetRect.midY, accuracy: 0.01)
    }
}
#endif
