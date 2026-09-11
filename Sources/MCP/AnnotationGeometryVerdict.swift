import Foundation

/// A pure comparison between an annotation's PAINTED bounds and a TARGET
/// control's bounds -- no screenshot, no capture, no Screen Recording
/// permission, on either side of the comparison.
///
/// WHY THIS EXISTS: proving a drawing landed where it was meant to currently
/// requires either a screenshot the calling agent supplies itself, or
/// Chalkboard's own capture -- and the latter needs macOS Screen Recording
/// permission that may not have been granted. But the question an agent is
/// actually asking -- "does my highlight actually cover the control I aimed
/// at?" -- is a GEOMETRY question, and both rectangles it needs are already
/// available with no capture and no permission at all: the annotation's
/// painted bounds come from the exact live renderer painting it ALONE into
/// an offscreen bitmap
/// (`AnnotationVerificationCompositor.renderedPaintedBounds`, the same
/// method `get_annotation_bounds` in `MCPToolHandlers+AnnotationBounds.swift`
/// already uses -- see that file's `screenshotRect`/`correctedOffset` for its
/// sibling geometry helpers), and a target control's bounds come from the
/// platform accessibility resolver (AX on macOS, UI Automation on Windows)
/// or the window prober. This type is the pure comparison between those two
/// already-known rectangles.
///
/// It is deliberately NOT evidence that any pixel reached a framebuffer -- it
/// is renderer geometry compared against resolver geometry, and every
/// message this type's caller emits must keep saying so rather than letting
/// an agent upgrade "the rectangles overlap" to "I saw it on screen". That is
/// exactly the same posture `get_annotation_bounds`'s `evidence` string
/// takes, and for the same reason: this tool's honesty depends on never
/// quietly promising more than geometry can prove.
enum AnnotationGeometryVerdict {
    /// The result of comparing one PAINTED rectangle against one TARGET
    /// rectangle, both already in the same coordinate space (the caller is
    /// responsible for that -- e.g. both in screenshot pixels, as
    /// `get_annotation_bounds` already produces via `screenshotRect`).
    struct Comparison: Equatable {
        /// Fraction of the TARGET rect's area covered by the painted bounds,
        /// clamped into 0...1 by construction (it is an intersection-over-
        /// target-area ratio, and an intersection can never exceed either
        /// operand's area). `0` for a zero-area target -- see `compare`'s
        /// doc comment for why that is a definition, not a fallback.
        let coverageOfTarget: Double
        /// Standard intersection-over-union: intersection area divided by
        /// the union of both rects' areas. `0` when the union area is itself
        /// zero (both rects degenerate), never divided out to NaN.
        let intersectionOverUnion: Double
        /// True only when the painted bounds fully enclose the target AND
        /// the target has positive area. A zero-area target is excluded on
        /// purpose: `coverageOfTarget` is defined as 0 for it (nothing was
        /// meaningfully covered), and letting `containsTarget` report `true`
        /// for the same rect would hand a caller `coverageOfTarget: 0` next
        /// to `containsTarget: true` -- two fields disagreeing about whether
        /// anything was actually covered.
        let containsTarget: Bool
        /// Target centre X minus painted centre X (and, for the Y field,
        /// target centre Y minus painted centre Y). The sign matches
        /// `get_annotation_bounds`'s existing `targetDeltaScreenshotPx`
        /// convention (`target.mid - painted.mid`):
        /// a positive value means the target sits to the painted bounds'
        /// right/below, i.e. "the painted annotation needs to move by this
        /// much, in this coordinate space's own units, to land on target."
        let centerDeltaX: Double
        let centerDeltaY: Double
        /// "on_target" | "partial" | "off_target" -- see `compare`'s doc
        /// comment for the exact rule each threshold encodes.
        let verdict: String

        /// The MCP wire shape, field-for-field identical to this struct's
        /// own properties -- no renaming, no derived fields -- so a caller
        /// reading this tool's JSON response sees exactly what this type
        /// computed, with nothing lost or added in translation.
        var payload: [String: Any] {
            [
                "coverageOfTarget": coverageOfTarget,
                "intersectionOverUnion": intersectionOverUnion,
                "containsTarget": containsTarget,
                "centerDeltaX": centerDeltaX,
                "centerDeltaY": centerDeltaY,
                "verdict": verdict
            ]
        }
    }

    /// Compares `painted` (an annotation's rendered bounds) against `target`
    /// (a resolved control's bounds), both assumed to already share one
    /// coordinate space.
    ///
    /// DEGENERATE INPUT HANDLING -- every branch below exists to guarantee no
    /// field of the returned `Comparison` is ever NaN or infinite, because
    /// `JSONSerialization` cannot encode either and a single bad field would
    /// fail the WHOLE response's encoding, not just that one field:
    ///
    /// - Non-finite `painted`/`target` coordinates (NaN or infinite origin or
    ///   size) short-circuit to an all-zero, "off_target" `Comparison` before
    ///   any arithmetic runs, so a NaN input can never propagate into a
    ///   division or a comparison whose result silently becomes NaN too.
    /// - A zero-area TARGET makes `coverageOfTarget` a 0/0 division if
    ///   computed naively (`intersectionArea / targetArea` with
    ///   `targetArea == 0`). This is the one place in this function a NaN
    ///   could otherwise reach the payload, so it is special-cased: coverage
    ///   of a target with no area is DEFINED as 0, not left undefined,
    ///   because "fully covered" should imply the caller can trust the
    ///   highlight landed ON something, and a target with no area was never
    ///   a real place to land.
    /// - A zero-area PAINTED rect needs no special case: it never appears as
    ///   a division's denominator (only `targetArea` and `unionArea` do), so
    ///   the ordinary intersection-area arithmetic already produces a finite
    ///   (usually zero) `coverageOfTarget` and `intersectionOverUnion` for
    ///   it without help.
    /// - `intersectionOverUnion`'s own denominator, `unionArea`, is zero
    ///   exactly when BOTH rects are zero-area, so it gets the same
    ///   "guard the denominator, define the ratio as 0" treatment.
    static func compare(painted: CGRect, target: CGRect) -> Comparison {
        guard painted.origin.x.isFinite, painted.origin.y.isFinite,
              painted.size.width.isFinite, painted.size.height.isFinite,
              target.origin.x.isFinite, target.origin.y.isFinite,
              target.size.width.isFinite, target.size.height.isFinite else {
            return Comparison(
                coverageOfTarget: 0, intersectionOverUnion: 0, containsTarget: false,
                centerDeltaX: 0, centerDeltaY: 0, verdict: "off_target"
            )
        }

        let paintedArea = abs(painted.width) * abs(painted.height)
        let targetArea = abs(target.width) * abs(target.height)
        let intersectionArea = overlapArea(painted, target)

        // See the doc comment above: coverage of a zero-area target is
        // DEFINED as 0 rather than computed, since computing it would divide
        // by zero.
        let coverageOfTarget = targetArea > 0 ? min(1, intersectionArea / targetArea) : 0

        let unionArea = paintedArea + targetArea - intersectionArea
        let intersectionOverUnion = unionArea > 0 ? min(1, intersectionArea / unionArea) : 0

        // Reuses `AnnotationCollisionLayout.contains`'s exact "every edge of
        // inner falls within outer" rule -- the same containment semantics
        // this package already applies elsewhere -- rather than restating a
        // second copy of it. `targetArea > 0` is required IN ADDITION,
        // per the doc comment on `Comparison.containsTarget` above: it keeps
        // a zero-area target from reporting containment while its own
        // coverage is defined as 0.
        let containsTarget = targetArea > 0 && AnnotationCollisionLayout.contains(painted, target)

        let centerDeltaX = target.midX - painted.midX
        let centerDeltaY = target.midY - painted.midY

        // The 0.9 coverage threshold: a highlight drawn as a ring/box with
        // deliberate padding around a control -- the normal, correct way to
        // draw a highlight -- legitimately does not cover the control's own
        // corners exactly (the ring sits just outside, or a rounded/inset
        // shape's bounding box does not flush against every edge). A hard
        // "must fully contain the target" test would call that perfectly
        // good highlight a failure. 90% coverage of the target's area is
        // close enough that the drawing is clearly aimed at, and landed on,
        // the control -- while still catching a highlight that is mostly
        // adjacent to the target rather than actually over it.
        let verdict: String
        if containsTarget || coverageOfTarget >= 0.9 {
            verdict = "on_target"
        } else if coverageOfTarget > 0 {
            verdict = "partial"
        } else {
            verdict = "off_target"
        }

        return Comparison(
            coverageOfTarget: coverageOfTarget,
            intersectionOverUnion: intersectionOverUnion,
            containsTarget: containsTarget,
            centerDeltaX: centerDeltaX,
            centerDeltaY: centerDeltaY,
            verdict: verdict
        )
    }

    /// True when `painted` touches or crosses any of the four edges of a
    /// `screenWidthPx` x `screenHeightPx` display, so at least some of the
    /// drawing is clipped away by the display's own boundary and
    /// `compare`'s result describes geometry that is not all actually
    /// paintable -- an annotation whose true extent is cut off cannot be
    /// fairly judged against a target by the geometry that remains.
    ///
    /// "Touch" (an edge exactly at 0 or at the display's own size), not only
    /// "cross" (an edge past it), counts as clipped: a renderer that clips at
    /// the display boundary produces painted bounds that stop exactly AT the
    /// edge for anything that would have extended further, so touching the
    /// edge is already indistinguishable from having been cut off there.
    ///
    /// A non-finite `painted` rect cannot be verified as safely inside the
    /// display, so it is reported as clipped rather than silently treated as
    /// "comfortably on screen" -- a false NEGATIVE here (calling clipped
    /// geometry safe) is the dangerous direction for a caller that trusts
    /// this answer before trusting `compare`'s numbers.
    ///
    /// COORDINATE SPACE REQUIREMENT, STATED EXPLICITLY: `minX <= 0 || maxX
    /// >= screenWidthPx` (and the Y equivalent) is only a correct edge test
    /// for `painted` in DISPLAY-LOCAL BACKING PIXELS with origin `(0, 0)` at
    /// that display's own top-left corner -- exactly what
    /// `AnnotationVerificationCompositor.renderedPaintedBounds` produces,
    /// and the only intended source of `painted` for this function. A caller
    /// that instead passes GLOBAL multi-display coordinates (where a
    /// secondary display's origin is not `(0, 0)`) would get a silently
    /// wrong answer: a rect entirely on-screen but far from that display's
    /// own edges could compare as clipped, or a rect actually off the near
    /// edge could compare as safely inside, depending on where the global
    /// origin happens to land relative to zero. Convert to display-local
    /// backing pixels (or use `renderedPaintedBounds` directly) before
    /// calling this.
    static func clippedAtScreenEdge(painted: CGRect, screenWidthPx: Int, screenHeightPx: Int) -> Bool {
        guard painted.origin.x.isFinite, painted.origin.y.isFinite,
              painted.size.width.isFinite, painted.size.height.isFinite else {
            return true
        }
        let width = Double(screenWidthPx)
        let height = Double(screenHeightPx)
        return painted.minX <= 0 || painted.minY <= 0
            || painted.maxX >= width || painted.maxY >= height
    }

    /// The area of the axis-aligned overlap between `a` and `b`, computed
    /// directly from each edge rather than via `CGRect.intersection(_:)` --
    /// matching `AnnotationCollisionLayout`'s own choice to hand-roll rect
    /// arithmetic in this package rather than depend on a CoreGraphics-style
    /// convenience method. `max(0, ...)` on each axis makes disjoint rects
    /// (a negative raw overlap on either axis) contribute exactly 0 rather
    /// than a spurious negative area.
    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> Double {
        let overlapWidth = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let overlapHeight = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return overlapWidth * overlapHeight
    }
}
