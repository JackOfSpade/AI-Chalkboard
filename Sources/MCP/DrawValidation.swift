import Foundation

/// Pure geometry/limit validators shared by the `draw_*` tool bodies in
/// `MCPToolHandlers.swift`.
///
/// Each function returns `nil` for a valid value or the exact error string
/// the corresponding tool call hands back to the MCP client. These used to
/// be inline `guard`s inside `MCPToolHandlers.handleToolsCall`'s `switch`,
/// which meant the only way to exercise them was through
/// `MCPServer.shared` -- a singleton that writes real JSON-RPC responses to
/// real stdout and therefore cannot be driven from a headless CI test.
/// Pulling them out here, with no AppKit and no singleton touched, is what
/// makes them `@testable`. Mirrors `MCPArgument`'s reasoning exactly.
enum DrawValidation {
    /// `draw_circle`'s `radius > 0` check.
    static func positiveRadius(_ radius: Double) -> String? {
        guard radius > 0 else { return "radius must be > 0." }
        return nil
    }

    /// `draw_box`'s `width > 0 && height > 0` check.
    static func positiveDimensions(width: Double, height: Double) -> String? {
        guard width > 0, height > 0 else { return "width and height must both be > 0." }
        return nil
    }

    /// `draw_grid`'s `step_px >= DrawingDefaults.minGridStepPx` check. See
    /// that constant's doc comment for why this is a hang guard against a
    /// runaway renderer loop, not merely a cosmetic minimum.
    static func gridStep(_ stepPx: Double) -> String? {
        guard stepPx >= DrawingDefaults.minGridStepPx else {
            return "step_px must be >= \(DrawingDefaults.minGridStepPx) physical pixel(s); smaller values can make the grid renderer's line loop run effectively forever and wedge the main thread."
        }
        return nil
    }

    /// `draw_path`'s cap on point count.
    ///
    /// MUST be called with the count of points that actually PARSED
    /// successfully -- i.e. what will actually reach `AnnotationStore` and
    /// therefore get re-walked on every repaint -- NOT the raw `points`
    /// argument's array length. `DrawingDefaults.maxPathPoints`'s own doc
    /// comment ("every stored point is re-walked on each repaint") and the
    /// README both justify this limit purely in terms of the STORED count.
    /// Checking the raw length instead (as this used to, before parsing had
    /// even happened) could reject a perfectly acceptable request: parsing
    /// silently drops malformed entries, so an array of `maxPathPoints + 1`
    /// raw entries containing even one malformed one produces fewer than
    /// `maxPathPoints` stored points, and there is no reason to refuse that.
    ///
    /// No separate guard against an enormous RAW array is needed to make
    /// this safe: `LineFramer.maxBufferBytes` already caps a single
    /// JSON-RPC line (and therefore the entire request, `points` included)
    /// at 4 MB before this code ever sees it, so the parse loop that
    /// produces the count passed in here cannot run unbounded either. A
    /// future reader should not re-add a raw-length check for that reason.
    static func pathPointCount(_ count: Int) -> String? {
        guard count <= DrawingDefaults.maxPathPoints else {
            return "'points' array resolved to \(count) valid point(s) after parsing, exceeding the \(DrawingDefaults.maxPathPoints)-point limit."
        }
        return nil
    }
}
