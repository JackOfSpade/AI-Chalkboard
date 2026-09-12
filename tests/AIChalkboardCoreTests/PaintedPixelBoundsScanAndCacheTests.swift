import XCTest
@testable import AIChalkboardCore
#if os(macOS)
import AppKit
#endif

// Covers the two halves of the painted-bounds performance fix in
// `AnnotationVerificationCompositor`:
//
//  * `paintedPixelBounds(bytes:width:height:bytesPerPixel:bytesPerRow:)` --
//    the shared word-scanning core both platforms' scans delegate to. Its
//    contract is BIT-IDENTICAL results to the byte-at-a-time scalar loop it
//    replaced, for every input; `PaintedPixelBoundsWordScanTests` holds it
//    to that by re-implementing the original scalar loop verbatim as a
//    reference and comparing on the shapes most likely to break a word
//    scan: corner pixels, single-pixel paint, odd widths, sub-word rows,
//    misaligned base addresses, paint confined to one channel, and rows
//    whose padding bytes are deliberately non-zero.
//  * `PaintedBoundsCacheKey` / `PaintedBoundsRenderCache` -- the bounded
//    cache `renderedPaintedBounds` consults so repeat measurements of
//    unchanged annotations cost zero renders. `PaintedBoundsRenderCacheTests`
//    verifies the key changes whenever any render input changes (revision,
//    content, adjustment, screen geometry) and that the LRU bound holds.
//
// Everything here is synthetic buffers and hand-built values; the only
// tests that render at all are the macOS-guarded end-to-end ones at the
// bottom, which use the same offscreen `renderedPaintedBounds` path
// `AnnotationVerificationCompositorTests` already exercises headlessly --
// no live display, no capture API.
final class PaintedPixelBoundsWordScanTests: XCTestCase {
    // MARK: - Reference implementation and harness

    /// Deterministic pseudo-random stream (splitmix64) so the fuzz cases
    /// below are reproducible byte for byte on every run and platform --
    /// a failure here must be re-runnable, never a flake.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The ORIGINAL scalar scan, kept verbatim as the oracle: any non-zero
    /// byte among a pixel's `bytesPerPixel` bytes marks it painted, and the
    /// result is the min/max painted x/y as a top-left-origin rect. The
    /// production word scan must agree with this on every input.
    private func referenceScalarBounds(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int,
        baseOffset: Int = 0
    ) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let pixelStart = baseOffset + y * bytesPerRow + x * bytesPerPixel
                var painted = false
                for channel in 0..<bytesPerPixel where pixels[pixelStart + channel] != 0 {
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

    private func wordScanBounds(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int,
        baseOffset: Int = 0
    ) -> CGRect? {
        pixels.withUnsafeBytes { raw in
            AnnotationVerificationCompositor.paintedPixelBounds(
                bytes: raw.baseAddress! + baseOffset,
                width: width,
                height: height,
                bytesPerPixel: bytesPerPixel,
                bytesPerRow: bytesPerRow
            )
        }
    }

    /// Runs both implementations on the same buffer and asserts they agree;
    /// returns the shared answer so callers can additionally pin it to an
    /// expected rect.
    @discardableResult
    private func assertScansAgree(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerPixel: Int = 4,
        bytesPerRow: Int? = nil,
        baseOffset: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect? {
        let stride = bytesPerRow ?? width * bytesPerPixel
        let fast = wordScanBounds(
            pixels, width: width, height: height,
            bytesPerPixel: bytesPerPixel, bytesPerRow: stride, baseOffset: baseOffset
        )
        let reference = referenceScalarBounds(
            pixels, width: width, height: height,
            bytesPerPixel: bytesPerPixel, bytesPerRow: stride, baseOffset: baseOffset
        )
        XCTAssertEqual(fast, reference, "word scan diverged from the scalar oracle", file: file, line: line)
        return fast
    }

    // MARK: - Equivalence cases

    func testFullyTransparentBitmapIsNil() {
        let width = 64, height = 16
        let pixels = [UInt8](repeating: 0, count: width * height * 4)
        XCTAssertNil(assertScansAgree(pixels, width: width, height: height))
    }

    /// Corner pixels are the classic word-scan off-by-one victims: the very
    /// first byte of the buffer, the last byte of a row, and the last byte
    /// of the whole buffer each sit at a prologue/word/epilogue boundary.
    /// Each corner is tried once per channel, which also covers "non-zero
    /// only in the alpha channel" (channel 3) explicitly.
    func testSingleCornerPixelsInEachChannelMatchReferenceExactly() {
        let width = 61, height = 9 // odd width: rows are not whole words
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            for channel in 0..<4 {
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                pixels[(y * width + x) * 4 + channel] = 1
                let bounds = assertScansAgree(pixels, width: width, height: height)
                XCTAssertEqual(
                    bounds, CGRect(x: x, y: y, width: 1, height: 1),
                    "corner (\(x), \(y)) channel \(channel)"
                )
            }
        }
    }

    func testSinglePixelBitmapPaintedAndUnpainted() {
        XCTAssertNil(assertScansAgree([0, 0, 0, 0], width: 1, height: 1))
        for channel in 0..<4 {
            var pixels: [UInt8] = [0, 0, 0, 0]
            pixels[channel] = 255
            XCTAssertEqual(
                assertScansAgree(pixels, width: 1, height: 1),
                CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        }
    }

    /// min-x and max-x must be taken across ALL rows, not from any single
    /// row: row 2 paints x 5...9 and row 7 paints x 1...3, so the union
    /// rect's x span comes from two different rows.
    func testExtentsUniteAcrossRowsWithDifferentSpans() {
        let width = 13, height = 10
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for x in 5...9 { pixels[(2 * width + x) * 4 + 1] = 7 }
        for x in 1...3 { pixels[(7 * width + x) * 4 + 3] = 9 }
        let bounds = assertScansAgree(pixels, width: width, height: height)
        XCTAssertEqual(bounds, CGRect(x: 1, y: 2, width: 9, height: 6))
    }

    /// Row padding bytes (bytesPerRow beyond width * bytesPerPixel) belong
    /// to no pixel and must never influence the answer -- the scalar loop
    /// never read them, so the word scan must not either. The padding here
    /// is deliberately saturated with 0xFF to catch any scan that runs to
    /// the row stride instead of the row's payload width.
    func testSaturatedRowPaddingBytesAreIgnored() {
        let width = 5, height = 4
        let bytesPerRow = width * 4 + 12
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for pad in (width * 4)..<bytesPerRow {
                pixels[y * bytesPerRow + pad] = 0xFF
            }
        }
        XCTAssertNil(assertScansAgree(pixels, width: width, height: height, bytesPerRow: bytesPerRow))

        pixels[1 * bytesPerRow + 2 * 4 + 0] = 1
        XCTAssertEqual(
            assertScansAgree(pixels, width: width, height: height, bytesPerRow: bytesPerRow),
            CGRect(x: 2, y: 1, width: 1, height: 1)
        )
    }

    /// The prologue/epilogue exist purely for base-address alignment, so
    /// the SAME pixel pattern must produce the SAME answer from every one
    /// of the eight possible byte misalignments of the row base.
    func testEveryBaseAlignmentProducesTheSameAnswerAsTheReference() {
        let width = 9, height = 3
        let bytesPerRow = width * 4
        var pattern = [UInt8](repeating: 0, count: bytesPerRow * height)
        pattern[(1 * width + 0) * 4 + 2] = 5
        pattern[(2 * width + 8) * 4 + 3] = 6
        let expected = CGRect(x: 0, y: 1, width: 9, height: 2)
        for misalignment in 0..<8 {
            let padded = [UInt8](repeating: 0, count: misalignment) + pattern
            let bounds = assertScansAgree(
                padded, width: width, height: height,
                bytesPerRow: bytesPerRow, baseOffset: misalignment
            )
            XCTAssertEqual(bounds, expected, "misalignment \(misalignment)")
        }
    }

    /// The core takes `bytesPerPixel` as a parameter (macOS bitmaps can
    /// legally report more than 4), so the byte-index-to-pixel division
    /// must hold for wider pixels too -- including paint confined to the
    /// very last byte of a pixel.
    func testWiderThanFourBytePixelsMapByteIndicesToPixelsCorrectly() {
        let width = 7, height = 2, bytesPerPixel = 8
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        pixels[(1 * width + 4) * bytesPerPixel + 7] = 3
        let bounds = assertScansAgree(pixels, width: width, height: height, bytesPerPixel: bytesPerPixel)
        XCTAssertEqual(bounds, CGRect(x: 4, y: 1, width: 1, height: 1))
    }

    /// Deterministic fuzz across the widths that stress every partition of
    /// the word scan (sub-word rows, exact-word rows, word-plus-tail rows),
    /// with sparse random paint, occasional all-zero buffers, and varying
    /// row padding. The assertion is pure equivalence with the scalar
    /// oracle -- the strongest statement of the "bit-identical" contract.
    func testDeterministicFuzzMatchesScalarOracle() {
        var rng = SplitMix64(state: 0x5EED_C0DE_D00D_F00D)
        for width in [1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 31, 33, 61, 64] {
            for round in 0..<6 {
                let height = 1 + Int(rng.next() % 7)
                let padding = [0, 4, 12][Int(rng.next() % 3)]
                let bytesPerRow = width * 4 + padding
                var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
                // Round 0 stays fully transparent to keep exercising the
                // nil answer; later rounds paint each byte with ~1/48
                // probability so most rows stay zero, like a real overlay.
                if round > 0 {
                    for y in 0..<height {
                        for byte in 0..<(width * 4) where rng.next() % 48 == 0 {
                            pixels[y * bytesPerRow + byte] = UInt8(truncatingIfNeeded: rng.next() | 1)
                        }
                    }
                }
                assertScansAgree(pixels, width: width, height: height, bytesPerRow: bytesPerRow)
            }
        }
    }
}

final class PaintedBoundsRenderCacheTests: XCTestCase {
    // MARK: - Fixtures

    private func screen(width: Int = 200, height: Int = 100, scale: Double = 1,
                        id: String = "screen-1", index: Int = 0) -> ScreenInfo {
        ScreenInfo(id: id, index: index, name: "Test Screen", widthPx: width, heightPx: height,
                   widthPt: Double(width) / scale, heightPt: Double(height) / scale,
                   backingScaleFactor: scale, isMain: index == 0)
    }

    /// A filled axis-aligned rectangle with no stroke: translating its path
    /// data by whole pixels translates its painted pixels exactly, which is
    /// what lets the end-to-end tests below assert shifted bounds without
    /// depending on antialiasing details.
    private func filledRectKind(x: Int = 20, y: Int = 10, width: Int = 40, height: Int = 30) -> AnnotationKind {
        .vectorPath(
            data: "M \(x) \(y) H \(x + width) V \(y + height) H \(x) Z",
            strokeColorHex: nil, strokeWidth: 0, strokeOpacity: 1,
            fillColorHex: "#FF0000", fillOpacity: 1, dash: [],
            usesEvenOddFillRule: false, coordinateScaleX: 1, coordinateScaleY: 1
        )
    }

    private func annotation(
        id: String = UUID().uuidString,
        revision: UInt64 = 1,
        kind: AnnotationKind? = nil,
        colorHex: String = "#00FF00",
        opacity: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0,
        staticAdjustment: AnchorAdjustment = .identity
    ) -> Annotation {
        Annotation(
            id: id, screenId: "screen-1", kind: kind ?? filledRectKind(),
            colorHex: colorHex, opacity: opacity, offsetX: offsetX, offsetY: offsetY,
            staticAdjustment: staticAdjustment, revision: revision
        )
    }

    private func key(_ annotation: Annotation, on screen: ScreenInfo,
                     file: StaticString = #filePath, line: UInt = #line) throws
        -> AnnotationVerificationCompositor.PaintedBoundsCacheKey {
        try XCTUnwrap(
            AnnotationVerificationCompositor.paintedBoundsCacheKey(for: annotation, on: screen),
            file: file, line: line
        )
    }

    // MARK: - Key sensitivity

    func testIndependentlyBuiltIdenticalInputsProduceEqualKeys() throws {
        let id = UUID().uuidString
        let first = try key(annotation(id: id), on: screen())
        let second = try key(annotation(id: id), on: screen())
        XCTAssertEqual(first, second)
    }

    func testRevisionChangeChangesKey() throws {
        let id = UUID().uuidString
        XCTAssertNotEqual(
            try key(annotation(id: id, revision: 1), on: screen()),
            try key(annotation(id: id, revision: 2), on: screen())
        )
    }

    /// The content fingerprint is what keeps the key total for values that
    /// never passed through a store (revision 0 candidates, hand-built test
    /// annotations): the SAME id at the SAME revision with different
    /// rendering payload must never share a key.
    func testContentChangeAtSameIdAndRevisionChangesKey() throws {
        let id = UUID().uuidString
        let base = try key(annotation(id: id), on: screen())
        XCTAssertNotEqual(base, try key(annotation(id: id, kind: filledRectKind(x: 50)), on: screen()))
        XCTAssertNotEqual(base, try key(annotation(id: id, colorHex: "#0000FF"), on: screen()))
        XCTAssertNotEqual(base, try key(annotation(id: id, opacity: 0.5), on: screen()))
        XCTAssertNotEqual(base, try key(annotation(id: id, offsetX: 12), on: screen()))
        XCTAssertNotEqual(base, try key(annotation(id: id, offsetY: -3), on: screen()))
    }

    /// `applyAnchorProjections` is the one store mutation that changes a
    /// render WITHOUT bumping `revision`; its entire rendering effect is the
    /// effective adjustment, so the adjustment components must each be
    /// key-bearing on their own.
    func testEffectiveAdjustmentComponentsChangeKey() throws {
        let id = UUID().uuidString
        let base = try key(annotation(id: id), on: screen())
        let moved = AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 30, translateY: 0)
        let scaled = AnchorAdjustment(scaleX: 1.5, scaleY: 1, translateX: 0, translateY: 0)
        XCTAssertNotEqual(base, try key(annotation(id: id, staticAdjustment: moved), on: screen()))
        XCTAssertNotEqual(base, try key(annotation(id: id, staticAdjustment: scaled), on: screen()))
    }

    func testScreenIdentityAndGeometryChangeKey() throws {
        let base = annotation()
        let reference = try key(base, on: screen())
        XCTAssertNotEqual(reference, try key(base, on: screen(id: "screen-2")))
        XCTAssertNotEqual(reference, try key(base, on: screen(width: 400)))
        XCTAssertNotEqual(reference, try key(base, on: screen(height: 200)))
        XCTAssertNotEqual(reference, try key(base, on: screen(scale: 2)))
    }

    /// JSON cannot encode non-finite doubles, so fingerprinting fails and
    /// the key builder fails OPEN (nil key, no caching) rather than caching
    /// under a key that dropped part of the content.
    func testNonFiniteContentFailsOpenToNoKey() {
        XCTAssertNil(AnnotationVerificationCompositor.paintedBoundsCacheKey(
            for: annotation(offsetX: .infinity), on: screen()
        ))
    }

    // MARK: - Cache behavior (fresh instances; the shared static is untouched)

    func testNilBoundsAreACachedAnswerDistinctFromAMiss() throws {
        let cache = AnnotationVerificationCompositor.PaintedBoundsRenderCache(capacity: 4)
        let k = try key(annotation(), on: screen())
        XCTAssertNil(cache.lookup(k), "an empty cache must miss")
        cache.store(nil, for: k)
        let hit = try XCTUnwrap(cache.lookup(k), "a stored nil answer must HIT")
        XCTAssertNil(hit.bounds, "and carry nil bounds as the answer")
    }

    func testEvictionDropsTheLeastRecentlyUsedEntryAtCapacity() throws {
        let cache = AnnotationVerificationCompositor.PaintedBoundsRenderCache(capacity: 3)
        let id = UUID().uuidString
        let keys = try (1...4).map { try key(annotation(id: id, revision: UInt64($0)), on: screen()) }
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cache.store(rect, for: keys[0])
        cache.store(rect, for: keys[1])
        cache.store(rect, for: keys[2])
        // Freshen keys[0] so keys[1] becomes the least recently USED --
        // proving eviction follows use order, not insertion order.
        XCTAssertNotNil(cache.lookup(keys[0]))
        cache.store(rect, for: keys[3])
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.lookup(keys[1]), "least recently used entry must be evicted")
        XCTAssertNotNil(cache.lookup(keys[0]))
        XCTAssertNotNil(cache.lookup(keys[2]))
        XCTAssertNotNil(cache.lookup(keys[3]))
    }

    func testRestoringAnExistingKeyDoesNotEvict() throws {
        let cache = AnnotationVerificationCompositor.PaintedBoundsRenderCache(capacity: 2)
        let id = UUID().uuidString
        let k1 = try key(annotation(id: id, revision: 1), on: screen())
        let k2 = try key(annotation(id: id, revision: 2), on: screen())
        cache.store(CGRect(x: 0, y: 0, width: 1, height: 1), for: k1)
        cache.store(CGRect(x: 0, y: 0, width: 2, height: 2), for: k2)
        cache.store(CGRect(x: 0, y: 0, width: 3, height: 3), for: k1)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.lookup(k1)?.bounds, CGRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertNotNil(cache.lookup(k2))
    }

    // MARK: - End-to-end through the real renderer (macOS offscreen; no display)

    #if os(macOS)
    /// Proves `renderedPaintedBounds` consults the shared cache FIRST by
    /// planting a sentinel rect under the annotation's own key and observing
    /// it come back verbatim -- deterministic evidence of a cache hit, with
    /// no timing or render counting involved. Uses a fresh UUID id, so the
    /// shared static cache is never left holding anything another test
    /// could collide with.
    func testRenderedPaintedBoundsConsultsAndPopulatesTheSharedCache() throws {
        let target = annotation()
        let display = screen()
        let firstAnswer = try XCTUnwrap(
            AnnotationVerificationCompositor.renderedPaintedBounds(of: target, on: display)
        )
        let cacheKey = try key(target, on: display)
        let populated = try XCTUnwrap(
            AnnotationVerificationCompositor.paintedBoundsCache.lookup(cacheKey),
            "a render must populate the cache under the annotation's key"
        )
        XCTAssertEqual(populated.bounds, firstAnswer)

        let sentinel = CGRect(x: 1, y: 2, width: 3, height: 4)
        AnnotationVerificationCompositor.paintedBoundsCache.store(sentinel, for: cacheKey)
        XCTAssertEqual(
            try AnnotationVerificationCompositor.renderedPaintedBounds(of: target, on: display),
            sentinel,
            "a repeat measurement must be answered from the cache, not a re-render"
        )
        // Leave the truthful answer behind rather than the sentinel.
        AnnotationVerificationCompositor.paintedBoundsCache.store(firstAnswer, for: cacheKey)
    }

    /// Same id, bumped revision, translated geometry: the stale entry must
    /// be bypassed and the fresh render must show exactly the translation.
    /// A whole-pixel translate of the same filled rect paints the identical
    /// pixel pattern shifted, so the +30 x assertion is exact -- no
    /// antialiasing tolerance needed.
    func testRevisionBumpBypassesTheStaleCachedEntry() throws {
        let id = UUID().uuidString
        let display = screen()
        let original = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: annotation(id: id, revision: 1), on: display
        ))
        let shifted = try XCTUnwrap(AnnotationVerificationCompositor.renderedPaintedBounds(
            of: annotation(id: id, revision: 2, kind: filledRectKind(x: 50)), on: display
        ))
        XCTAssertEqual(shifted, original.offsetBy(dx: 30, dy: 0))
    }

    /// "Painted nothing" (nil) is itself cached: the second measurement of
    /// a fully off-screen annotation hits the stored nil answer instead of
    /// re-rendering, and both agree.
    func testPaintedNothingAnswerIsCached() throws {
        let offscreen = annotation(kind: filledRectKind(x: 5_000, y: 5_000))
        let display = screen()
        XCTAssertNil(try AnnotationVerificationCompositor.renderedPaintedBounds(of: offscreen, on: display))
        let cacheKey = try key(offscreen, on: display)
        let hit = try XCTUnwrap(AnnotationVerificationCompositor.paintedBoundsCache.lookup(cacheKey))
        XCTAssertNil(hit.bounds)
        XCTAssertNil(try AnnotationVerificationCompositor.renderedPaintedBounds(of: offscreen, on: display))
    }
    #endif
}
