import Foundation

/// Values that both the MCP tool layer and the renderer have to agree on.
///
/// WHY THIS FILE EXISTS: these numbers were previously written out as literals
/// in three places each -- the Swift default in `MCPServer`, the fallback in
/// `OverlayView`, and the human-readable "Default 200." in the tool's own JSON
/// schema description that Claude reads. Nothing tied them together, so a
/// change to one silently made the other two lie. The schema strings are now
/// interpolated from these constants, which makes drift impossible rather than
/// merely unlikely.
enum DrawingDefaults {

    /// `draw_grid`'s line spacing, in physical pixels.
    static let gridStepPx: Double = 200

    /// `draw_grid`'s auto-clear delay. The grid is a calibration aid, not a
    /// note: it is the one draw tool that expires by default.
    static let gridDurationSeconds: Double = 5

    /// `draw_path`'s line thickness, in physical pixels.
    static let pathStrokeWidthPx: Double = 3.5

    // MARK: - Per-tool default colors
    //
    // Each draw tool has its own default so that an agent drawing several kinds
    // of annotation at once gets a visually distinguishable result without
    // having to pick colors.

    static let circleColor = "#FF0000"
    static let arrowColor = "#00E0FF"
    static let boxColor = "#00FF66"
    static let labelColor = "#FFFF00"
    static let pathColor = "#FF9500"
    static let gridColor = "#00E0FF"

    // MARK: - Guard rails

    /// Smallest accepted `step_px`, in physical pixels.
    ///
    /// NOT a cosmetic minimum -- this is a hang guard. The renderer walks
    /// `for x in stride(from: step, to: width, by: step)`, so the iteration
    /// count is `width / step`. Below roughly `width * 2^-53` points the
    /// accumulator stops advancing at all (the increment is smaller than the
    /// ULP of the running total) and the loop never terminates, wedging the
    /// main thread permanently. Values merely *near* that threshold produce a
    /// finite but effectively infinite loop. One physical pixel is the smallest
    /// spacing that can possibly be meaningful on screen anyway.
    static let minGridStepPx: Double = 1

    /// Hard ceiling on grid lines per axis, enforced in the renderer as
    /// defense-in-depth independent of whatever the MCP layer validated.
    static let maxGridLinesPerAxis = 2_000

    /// Largest `points` array `draw_path` will accept.
    ///
    /// Every stored point is re-walked on every repaint of every screen the
    /// annotation is visible on, and repaints happen on each app switch -- so
    /// an oversized path is a permanent per-frame cost, not a one-off parse
    /// cost. Well above any legitimate freehand sketch.
    static let maxPathPoints = 10_000

    /// Largest number of annotations one process will hold at once.
    ///
    /// Five of the six draw tools deliberately create annotations that persist
    /// until explicitly cleared (see `AnnotationStore`'s type comment), and this
    /// is a long-lived background server, so "the caller never passed
    /// `duration_seconds` and never called `clear`" grows the store without
    /// bound and makes every repaint's O(n) filter steadily more expensive.
    /// The cap is far above any plausible real session; hitting it means
    /// something is wrong, so eviction is logged loudly and reported back in
    /// the tool result rather than done silently.
    static let maxStoredAnnotations = 2_000
}
