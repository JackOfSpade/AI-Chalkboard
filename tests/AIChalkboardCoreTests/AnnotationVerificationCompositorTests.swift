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
}
#endif
