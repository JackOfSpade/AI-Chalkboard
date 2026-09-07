import Foundation
import XCTest
@testable import AIChalkboardCore

/// `AnchorAdjustment` sits underneath every anchored annotation's paint step
/// (`Annotation.effectiveAdjustment`) and, unlike a general-purpose affine,
/// is required to fail CLOSED -- returning nil rather than a
/// plausible-looking wrong transform -- whenever a sampled window frame
/// cannot be trusted (the design contract's "no drift" invariant: a caller
/// that gets nil back must hold the previous adjustment, never substitute
/// `.identity`, which would teleport a drawing back to its raw stored
/// position). This suite pins down every branch of
/// `mapping(reference:current:behavior:)`'s degenerate/non-finite handling,
/// the exact self-then-other order `concatenating(_:)` must preserve (a
/// silently swapped order would misplace every annotation that has been
/// both frozen once and re-anchored), `apply(to:)` for both points and
/// rects, and `AnchorRect`'s flat wire shape -- which exists only because
/// `CGRect`'s own synthesized `Codable` form is unreadable JSON (see
/// `PresentationRect` in `Sources/Overlay/PresentationDiagnostics.swift` for
/// the precedent this follows). It also proves an `Annotation` payload
/// written before anchoring existed still decodes today, with the
/// documented defaults standing in for the three new fields.
final class AnchorAdjustmentTests: XCTestCase {

    // MARK: - identity / apply

    func testIdentityIsScaleOneTranslateZero() {
        let identity = AnchorAdjustment.identity
        XCTAssertEqual(identity.scaleX, 1)
        XCTAssertEqual(identity.scaleY, 1)
        XCTAssertEqual(identity.translateX, 0)
        XCTAssertEqual(identity.translateY, 0)
        XCTAssertTrue(identity.isIdentity)
    }

    func testIsIdentityUsesExactEqualityNotAnEpsilon() {
        // A value that is extremely close to, but not exactly, identity
        // must NOT report as identity -- the renderer's "skip the
        // adjustment entirely" fast path depends on this being exact.
        let almostIdentity = AnchorAdjustment(scaleX: 1.0000001, scaleY: 1, translateX: 0, translateY: 0)
        XCTAssertFalse(almostIdentity.isIdentity)
    }

    func testApplyToPointScalesThenTranslatesPerAxis() {
        let adjustment = AnchorAdjustment(scaleX: 2, scaleY: 0.5, translateX: 10, translateY: -5)
        let mapped = adjustment.apply(to: CGPoint(x: 4, y: 8))
        XCTAssertEqual(mapped, CGPoint(x: 4 * 2 + 10, y: 8 * 0.5 - 5))
    }

    func testApplyToRectMapsOriginAndScalesSizePerAxis() {
        let adjustment = AnchorAdjustment(scaleX: 2, scaleY: 0.5, translateX: 10, translateY: -5)
        let rect = CGRect(x: 4, y: 8, width: 6, height: 20)
        let mapped = adjustment.apply(to: rect)
        // Origin maps exactly like a point; width/height scale per axis and
        // stay positive because the adjustment's scales are positive here,
        // so no corner reordering is needed.
        XCTAssertEqual(mapped, CGRect(x: 18, y: -1, width: 12, height: 10))
    }

    /// No LIVE adjustment can carry a negative scale today (see
    /// `apply(to rect:)`'s doc comment), but a hand-built/frozen
    /// `staticAdjustment` is not covered by that guarantee. This proves the
    /// function is structurally safe anyway: the returned rect must always
    /// have a non-negative size, standardized to the same two corners the
    /// raw (unstandardized) arithmetic would have produced.
    func testApplyToRectUnderNegativeScaleReturnsAStandardizedRect() {
        let adjustment = AnchorAdjustment(scaleX: -2, scaleY: -3, translateX: 100, translateY: 200)
        let rect = CGRect(x: 10, y: 10, width: 5, height: 4)
        let mapped = adjustment.apply(to: rect)

        // Raw (pre-standardization) arithmetic: origin = (10*-2+100, 10*-3+200)
        // = (80, 170); raw width/height = 5*-2=-10, 4*-3=-12. Standardizing
        // that shifts the origin to the actual minimum corner, (70, 158),
        // with a positive (10, 12) size -- the SAME rectangle, just
        // canonically expressed.
        XCTAssertEqual(mapped, CGRect(x: 70, y: 158, width: 10, height: 12))
        XCTAssertGreaterThanOrEqual(mapped.size.width, 0)
        XCTAssertGreaterThanOrEqual(mapped.size.height, 0)
    }

    /// A negative scale on only ONE axis must standardize independently per
    /// axis, not treat the rect as either fully standardized or not.
    func testApplyToRectUnderSingleAxisNegativeScaleStandardizesOnlyThatAxis() {
        let adjustment = AnchorAdjustment(scaleX: -1, scaleY: 2, translateX: 50, translateY: 0)
        let rect = CGRect(x: 0, y: 0, width: 10, height: 5)
        let mapped = adjustment.apply(to: rect)

        // origin = (0*-1+50, 0*2+0) = (50, 0); raw size = (10*-1, 5*2) = (-10, 10).
        // Standardized: x shifts left by 10 to 40; y/height untouched.
        XCTAssertEqual(mapped, CGRect(x: 40, y: 0, width: 10, height: 10))
    }

    // MARK: - concatenating: order and associativity

    func testConcatenatingAppliesSelfFirstThenOtherAgainstManualArithmetic() {
        // Two arbitrary, unequal adjustments so a swapped order would
        // produce a visibly different result (see the companion
        // non-commutativity test below).
        let a = AnchorAdjustment(scaleX: 2, scaleY: 3, translateX: 5, translateY: -4)
        let b = AnchorAdjustment(scaleX: 0.5, scaleY: 2, translateX: 1, translateY: 10)
        let point = CGPoint(x: 10, y: 6)

        // Manual arithmetic, worked by hand: a(10,6) = (10*2+5, 6*3-4) =
        // (25, 14); b(25,14) = (25*0.5+1, 14*2+10) = (13.5, 38).
        let manuallyChained = b.apply(to: a.apply(to: point))
        XCTAssertEqual(manuallyChained, CGPoint(x: 13.5, y: 38))

        let combined = a.concatenating(b)
        XCTAssertEqual(combined.apply(to: point), manuallyChained)
        XCTAssertEqual(combined.apply(to: point), CGPoint(x: 13.5, y: 38))
    }

    func testConcatenatingOrderIsNotCommutative() {
        let a = AnchorAdjustment(scaleX: 2, scaleY: 3, translateX: 5, translateY: -4)
        let b = AnchorAdjustment(scaleX: 0.5, scaleY: 2, translateX: 1, translateY: 10)
        let point = CGPoint(x: 10, y: 6)

        // a then b: (10,6) -> (25,14) -> (13.5, 38)
        XCTAssertEqual(a.concatenating(b).apply(to: point), CGPoint(x: 13.5, y: 38))
        // b then a: (10,6) -> (6,22) -> (17, 62)
        XCTAssertEqual(b.concatenating(a).apply(to: point), CGPoint(x: 17, y: 62))
    }

    func testConcatenatingIsAssociative() {
        // Small exact (binary-representable) coefficients so every
        // intermediate value below is exact, not merely close, and the
        // final `XCTAssertEqual` is not masking a rounding difference.
        let a = AnchorAdjustment(scaleX: 2, scaleY: 3, translateX: 5, translateY: -4)
        let b = AnchorAdjustment(scaleX: 0.5, scaleY: 2, translateX: 1, translateY: 10)
        let c = AnchorAdjustment(scaleX: 4, scaleY: -2, translateX: -3, translateY: 7)

        let leftAssociated = a.concatenating(b).concatenating(c)
        let rightAssociated = a.concatenating(b.concatenating(c))
        XCTAssertEqual(leftAssociated, rightAssociated)

        // And confirm both actually agree with the same point mapped
        // through the full three-step chain directly.
        let point = CGPoint(x: 10, y: 6)
        let chained = c.apply(to: b.apply(to: a.apply(to: point)))
        XCTAssertEqual(leftAssociated.apply(to: point), chained)
    }

    // MARK: - mapping: pin

    func testPinMappingTranslatesByOriginDeltaAndIgnoresSizeChange() {
        let reference = CGRect(x: 100, y: 50, width: 200, height: 150)
        let current = CGRect(x: 130, y: 20, width: 400, height: 10) // size ignored by pin
        let adjustment = try? XCTUnwrap(AnchorAdjustment.mapping(reference: reference, current: current, behavior: .pin))
        XCTAssertEqual(adjustment, AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 30, translateY: -30))
    }

    func testPinMappingSucceedsWithADegenerateReferenceThatWouldRejectScale() {
        // Zero width and negative height -- both finite, both degenerate.
        // Pin never divides, so neither disqualifies it.
        let reference = CGRect(x: 10, y: 20, width: 0, height: -5)
        let current = CGRect(x: 40, y: 15, width: 999, height: 999)

        let pinned = AnchorAdjustment.mapping(reference: reference, current: current, behavior: .pin)
        XCTAssertEqual(pinned, AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 30, translateY: -5))

        // The same reference DOES disqualify `.scale`, proving the
        // difference is specifically pin's lack of a divisor, not some
        // blanket tolerance for this reference rect.
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: current, behavior: .scale))
    }

    // MARK: - mapping: scale

    func testScaleMappingComputesPerAxisScaleAndTranslate() {
        let reference = CGRect(x: 100, y: 50, width: 200, height: 100)
        let current = CGRect(x: 150, y: 80, width: 400, height: 50)
        let adjustment = AnchorAdjustment.mapping(reference: reference, current: current, behavior: .scale)

        // scaleX = 400/200 = 2, scaleY = 50/100 = 0.5
        // translateX = 150 - 100*2 = -50, translateY = 80 - 50*0.5 = 55
        XCTAssertEqual(adjustment, AnchorAdjustment(scaleX: 2, scaleY: 0.5, translateX: -50, translateY: 55))

        // The reference rect's own corner must map exactly onto the
        // current rect's corner -- the whole point of the formula.
        XCTAssertEqual(adjustment?.apply(to: reference.origin), current.origin)
    }

    func testScaleMappingReturnsNilForZeroReferenceWidth() {
        let reference = CGRect(x: 0, y: 0, width: 0, height: 100)
        let current = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: current, behavior: .scale))
    }

    func testScaleMappingReturnsNilForZeroReferenceHeight() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 0)
        let current = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: current, behavior: .scale))
    }

    func testScaleMappingReturnsNilForNegativeReferenceSize() {
        let negativeWidth = CGRect(x: 0, y: 0, width: -10, height: 100)
        let negativeHeight = CGRect(x: 0, y: 0, width: 100, height: -10)
        let current = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertNil(AnchorAdjustment.mapping(reference: negativeWidth, current: current, behavior: .scale))
        XCTAssertNil(AnchorAdjustment.mapping(reference: negativeHeight, current: current, behavior: .scale))
    }

    // MARK: - mapping: scale, degenerate CURRENT frame

    // Unlike the reference guards above, `current` is never a divisor, so a
    // degenerate value here is guarded for a different reason: it would
    // otherwise collapse the mapped geometry to a zero-size line (zero) or
    // mirror it across an axis (negative), rather than divide by zero. Both
    // are still rejected -- `apply(to rect:)` documents that its positive-
    // scale assumption depends on `mapping` never handing out a zero or
    // negative scale.

    func testScaleMappingReturnsNilForZeroCurrentWidth() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let current = CGRect(x: 0, y: 0, width: 0, height: 50)
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: current, behavior: .scale))
    }

    func testScaleMappingReturnsNilForZeroCurrentHeight() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let current = CGRect(x: 0, y: 0, width: 50, height: 0)
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: current, behavior: .scale))
    }

    func testScaleMappingReturnsNilForNegativeCurrentSize() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let negativeWidth = CGRect(x: 0, y: 0, width: -50, height: 50)
        let negativeHeight = CGRect(x: 0, y: 0, width: 50, height: -50)
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: negativeWidth, behavior: .scale))
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: negativeHeight, behavior: .scale))
    }

    func testPinMappingSucceedsWithADegenerateCurrentFrameThatWouldRejectScale() {
        // Mirrors `testPinMappingSucceedsWithADegenerateReferenceThatWouldRejectScale`,
        // but the degenerate rect is `current` this time: pin has no scale
        // to collapse or mirror, so it maps a zero/negative-size current
        // frame exactly as it would map any other frame.
        let reference = CGRect(x: 10, y: 20, width: 50, height: 50)
        let zeroWidthCurrent = CGRect(x: 40, y: 15, width: 0, height: 999)
        let negativeHeightCurrent = CGRect(x: 40, y: 15, width: 999, height: -30)

        XCTAssertEqual(
            AnchorAdjustment.mapping(reference: reference, current: zeroWidthCurrent, behavior: .pin),
            AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 30, translateY: -5)
        )
        XCTAssertEqual(
            AnchorAdjustment.mapping(reference: reference, current: negativeHeightCurrent, behavior: .pin),
            AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 30, translateY: -5)
        )

        // Both current frames DO disqualify `.scale`, proving the
        // difference is specifically pin's lack of a scale, not some
        // blanket tolerance for these particular rects.
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: zeroWidthCurrent, behavior: .scale))
        XCTAssertNil(AnchorAdjustment.mapping(reference: reference, current: negativeHeightCurrent, behavior: .scale))
    }

    // MARK: - mapping: non-finite input, both behaviors

    func testMappingReturnsNilWhenAnyFieldIsNaN() {
        let nanOrigin = CGRect(x: Double.nan, y: 0, width: 100, height: 100)
        let plain = CGRect(x: 0, y: 0, width: 50, height: 50)
        // NaN disqualifies pin too, even though pin does not divide --
        // "non-finite value anywhere" is checked before either behavior
        // branches, not folded into the scale-only divide-by-zero guard.
        XCTAssertNil(AnchorAdjustment.mapping(reference: nanOrigin, current: plain, behavior: .pin))
        XCTAssertNil(AnchorAdjustment.mapping(reference: plain, current: nanOrigin, behavior: .pin))
        XCTAssertNil(AnchorAdjustment.mapping(reference: nanOrigin, current: plain, behavior: .scale))
        XCTAssertNil(AnchorAdjustment.mapping(reference: plain, current: nanOrigin, behavior: .scale))
    }

    func testMappingReturnsNilWhenAnyFieldIsInfinite() {
        let infiniteSize = CGRect(x: 0, y: 0, width: Double.infinity, height: 100)
        let plain = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertNil(AnchorAdjustment.mapping(reference: infiniteSize, current: plain, behavior: .pin))
        XCTAssertNil(AnchorAdjustment.mapping(reference: plain, current: infiniteSize, behavior: .pin))
        XCTAssertNil(AnchorAdjustment.mapping(reference: infiniteSize, current: plain, behavior: .scale))
        XCTAssertNil(AnchorAdjustment.mapping(reference: plain, current: infiniteSize, behavior: .scale))
    }

    // MARK: - AnchorRect

    func testAnchorRectRoundTripsThroughCGRectPreservingRawNegativeSize() {
        let original = CGRect(x: 12.5, y: -3, width: 640, height: 480)
        XCTAssertEqual(AnchorRect(original).cgRect, original)

        // A negative width/height must survive as-is, not get silently
        // standardized -- an `AnchorRect` round trip must never change what
        // `mapping(reference:current:behavior:)` would compute from the
        // original rect.
        let negativeSize = CGRect(x: 5, y: 5, width: -10, height: -20)
        let roundTripped = AnchorRect(negativeSize)
        XCTAssertEqual(roundTripped.width, -10)
        XCTAssertEqual(roundTripped.height, -20)
        XCTAssertEqual(roundTripped.cgRect, negativeSize)
    }

    func testAnchorRectEncodesAsFlatNumericKeysNotCGRectsNestedArrayShape() throws {
        let rect = AnchorRect(x: 1, y: 2, width: 3, height: 4)
        let data = try JSONEncoder().encode(rect)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json.count, 4, "AnchorRect must encode as exactly x/y/width/height -- no extra nesting")
        XCTAssertEqual(json["x"] as? Double, 1)
        XCTAssertEqual(json["y"] as? Double, 2)
        XCTAssertEqual(json["width"] as? Double, 3)
        XCTAssertEqual(json["height"] as? Double, 4)
    }

    // MARK: - Annotation decode compatibility

    /// A hand-written stand-in for a payload written before anchoring
    /// existed: it has every field `Annotation` carried previously and
    /// none of the three new ones. Decoding it must still succeed, with
    /// `anchor`/`anchorProjection` defaulting to nil and `staticAdjustment`
    /// defaulting to `.identity` -- exactly the values a freshly created
    /// unanchored `Annotation` already carries, so an old drawing keeps
    /// behaving exactly as it did before this feature existed.
    func testDecodingAnOlderAnnotationPayloadWithoutTheNewAnchorFieldsUsesTheDocumentedDefaults() throws {
        let olderPayload: [String: Any] = [
            "id": "old-annotation",
            "screenId": "screen-1",
            "kind": [
                "text": [
                    "text": "hello",
                    "x": 10,
                    "y": 20,
                    "fontSize": 18,
                    "textColorHex": "#FFFFFF",
                    "backgroundColorHex": "#000000",
                    "backgroundOpacity": 0.5,
                    "paddingPx": 3,
                    "opacity": 1
                ]
            ],
            "colorHex": "#ABCDEF",
            "createdAt": 750_000_000.0,
            "opacity": 1.0,
            "offsetX": 0.0,
            "offsetY": 0.0,
            "zIndex": 0
            // Deliberately absent: "anchor", "staticAdjustment",
            // "anchorProjection", "label", "appId", "appName" -- exactly
            // the shape a payload predating anchoring would have.
        ]

        let data = try JSONSerialization.data(withJSONObject: olderPayload)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)

        XCTAssertEqual(decoded.id, "old-annotation")
        XCTAssertNil(decoded.anchor)
        XCTAssertEqual(decoded.staticAdjustment, .identity)
        XCTAssertNil(decoded.anchorProjection)
        XCTAssertEqual(decoded.effectiveScreenId, decoded.screenId, "unanchored: effective screen falls back to screenId")
        XCTAssertTrue(decoded.effectiveAdjustment.isIdentity)
        XCTAssertTrue(decoded.anchorPermitsPainting, "an unanchored annotation must always be permitted to paint")
    }
}
