import Foundation

/// Finds a nearby, non-overlapping placement for an already-sized annotation
/// rectangle.
///
/// This deliberately knows nothing about annotations, rendering, or MCP. Its
/// inputs and result are all in one caller-selected coordinate space (normally
/// display backing pixels), which makes it suitable both for a prospective
/// draw and for a future layout-only tool. The caller is responsible for
/// obtaining exact painted bounds when an avoided item needs them; this helper
/// only decides where a supplied rectangle may go.
///
/// Rectangles that merely touch are *not* collisions. `padding` is applied to
/// a moved placement, so a positive value leaves a visible gap instead of
/// placing the new annotation flush against the avoided item's edge.
enum AnnotationCollisionLayout {
    enum Placement: String, Equatable {
        case unchanged
        case below
        case above
        case right
        case left
    }

    struct Resolution: Equatable {
        let proposed: CGRect
        let placed: CGRect
        let placement: Placement

        var offset: CGPoint {
            CGPoint(x: placed.origin.x - proposed.origin.x, y: placed.origin.y - proposed.origin.y)
        }
    }

    /// Returns a non-overlapping placement, or `nil` if the input geometry is
    /// invalid or no candidate can satisfy `within`.
    ///
    /// Candidate exploration is intentionally bounded. Every emitted result
    /// is checked against *all* avoid rectangles, so reaching the bound can
    /// only produce `nil` (which lets the draw be rejected), never an
    /// overlapping placement. The normal highlight-plus-label case resolves
    /// in the first four candidates; the generous bound also supports a
    /// modest cluster of existing annotations without allowing a hostile
    /// request to turn a draw into unbounded geometry work.
    static func resolve(
        proposed: CGRect,
        avoiding rawAvoidedRects: [CGRect],
        padding: Double = 8,
        within rawContainer: CGRect? = nil
    ) -> Resolution? {
        guard isUsable(proposed), padding.isFinite, padding >= 0 else { return nil }
        guard rawContainer.map(isUsable) ?? true else { return nil }

        // Empty avoided rectangles cannot overlap a positive-area annotation.
        // Rejecting an invalid candidate is useful; silently ignoring a
        // malformed *avoid* rectangle is intentional defensive behavior for
        // callers combining bounds from a live store where an item may have
        // become empty or unavailable between collection and layout.
        let avoidedRects = rawAvoidedRects.filter(isUsable)
        let isAcceptable: (CGRect) -> Bool = { candidate in
            (rawContainer.map { contains($0, candidate) } ?? true)
                && !avoidedRects.contains(where: { intersects(candidate, $0) })
        }

        if isAcceptable(proposed) {
            return Resolution(proposed: proposed, placed: proposed, placement: .unchanged)
        }

        // A candidate only needs to move one edge immediately beyond an
        // intersecting rectangle. Further conflicts are expanded in the same
        // way, which handles a row or stack of avoided annotations while
        // retaining a deterministic, local search.
        struct Candidate {
            let rect: CGRect
            let placement: Placement
        }
        let directionOrder: [Placement] = [.below, .above, .right, .left]
        let maximumCandidates = 512
        var pending: [Candidate] = []
        var visited: [CGRect] = [proposed]
        var accepted: [Candidate] = []

        func appendCandidates(from candidate: Candidate, around obstacle: CGRect) {
            let positions: [(Placement, CGPoint)] = [
                (.below, CGPoint(x: candidate.rect.minX, y: obstacle.maxY + padding)),
                (.above, CGPoint(x: candidate.rect.minX, y: obstacle.minY - padding - candidate.rect.height)),
                (.right, CGPoint(x: obstacle.maxX + padding, y: candidate.rect.minY)),
                (.left, CGPoint(x: obstacle.minX - padding - candidate.rect.width, y: candidate.rect.minY))
            ]
            for direction in directionOrder {
                guard visited.count < maximumCandidates,
                      let position = positions.first(where: { $0.0 == direction })?.1 else { break }
                let rect = CGRect(origin: position, size: candidate.rect.size)
                guard !visited.contains(rect) else { continue }
                visited.append(rect)
                // Retain the first adjustment direction for useful reporting
                // even if a later obstacle needs a second nudge.
                pending.append(Candidate(
                    rect: rect,
                    placement: candidate.placement == .unchanged ? direction : candidate.placement
                ))
            }
        }

        let initial = Candidate(rect: proposed, placement: .unchanged)
        for obstacle in avoidedRects where intersects(proposed, obstacle) {
            appendCandidates(from: initial, around: obstacle)
        }

        var cursor = 0
        while cursor < pending.count, visited.count <= maximumCandidates {
            let candidate = pending[cursor]
            cursor += 1

            if isAcceptable(candidate.rect) {
                accepted.append(candidate)
                continue
            }
            // A candidate outside its optional containing rect cannot become
            // valid by moving farther in the same collision direction. Other
            // candidates (such as above instead of below) remain eligible.
            guard rawContainer.map({ contains($0, candidate.rect) }) ?? true,
                  let obstacle = avoidedRects.first(where: { intersects(candidate.rect, $0) }) else {
                continue
            }
            appendCandidates(from: candidate, around: obstacle)
        }

        guard let best = accepted.min(by: {
            isPreferred($0.rect, placement: $0.placement,
                        to: $1.rect, placement: $1.placement,
                        relativeTo: proposed)
        }) else {
            return nil
        }
        return Resolution(proposed: proposed, placed: best.rect, placement: best.placement)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    /// Positive-area rectangle intersection. Edge-touching is deliberately
    /// accepted: there is no painted overlap at the shared edge, and moved
    /// placements receive `padding` separately.
    static func intersects(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.minX < rhs.maxX && lhs.maxX > rhs.minX
            && lhs.minY < rhs.maxY && lhs.maxY > rhs.minY
    }

    static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX
            && inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }

    /// Prefer the least movement, with a stable below/above/right/left tie
    /// break. This makes a one-obstacle label land below its highlight when
    /// the four choices are equidistant, while still favoring a genuinely
    /// closer side in non-square layouts.
    private static func isPreferred(
        _ lhs: CGRect, placement lhsPlacement: Placement,
        to rhs: CGRect, placement rhsPlacement: Placement,
        relativeTo proposed: CGRect
    ) -> Bool {
        let lhsDistance = abs(lhs.minX - proposed.minX) + abs(lhs.minY - proposed.minY)
        let rhsDistance = abs(rhs.minX - proposed.minX) + abs(rhs.minY - proposed.minY)
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

        let lhsRank = directionRank(lhsPlacement)
        let rhsRank = directionRank(rhsPlacement)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        // An explicit coordinate tie-break makes the result independent of
        // the input order of `avoiding`. (The standard library's `min` keeps
        // the first equal element, which would otherwise leak that order.)
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        return lhs.minX < rhs.minX
    }

    private static func directionRank(_ placement: Placement) -> Int {
        switch placement {
        case .unchanged: return 0
        case .below: return 1
        case .above: return 2
        case .right: return 3
        case .left: return 4
        }
    }
}
