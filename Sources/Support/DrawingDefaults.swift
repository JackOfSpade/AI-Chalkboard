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

    /// Hard ceiling for every serialized JSON-RPC response line, including
    /// base64 and JSON framing.  The MCP process never writes a larger line:
    /// `MCPServer` replaces an oversized result with a compact error response.
    static let maxMCPResponseBytes = 8 * 1_024 * 1_024

    /// `list_annotations` is intentionally paged.  Keeping its embedded JSON
    /// well below the transport ceiling leaves room for JSON string escaping
    /// in the outer MCP response even when SVG data contains many quotes or
    /// backslashes.
    static let maxAnnotationListPageItems = 100
    static let maxAnnotationListTextBytes = 2 * 1_024 * 1_024
    static let maxAnnotationListEntryBytes = 512 * 1_024

    /// Rendering values become AppKit/Core Graphics scalars.  These broad
    /// caps prevent finite-but-pathological input from creating enormous text
    /// layouts, stroke/dash state, images, or rotations that can destabilize a
    /// repaint.  Coordinates have a separate cap because positions naturally
    /// exceed style dimensions on multi-display desktops.
    static let maxStyleDimensionPx = 100_000.0
    static let maxImageDimensionPx = 1_000_000.0
    static let maxCoordinateMagnitudePx = 10_000_000.0
    static let maxRotationDegrees = 360_000.0

    /// `draw_path`'s line thickness, in physical pixels.
    static let pathStrokeWidthPx: Double = 3.5

    // MARK: - Per-tool default colors
    //
    // Each draw tool has its own default so that an agent drawing several kinds
    // of annotation at once gets a visually distinguishable result without
    // having to pick colors.

    static let pathColor = "#FF9500"

    static let textColor = "#FFFFFF"
    static let maxTextCharacters = 20_000

    /// `highlight_element`'s `label` argument, matched against Accessibility
    /// title/description/value strings rather than rendered as drawn text.
    /// Bounded far below `maxTextCharacters` because it is a lookup key, not
    /// canvas content.
    static let maxHighlightLabelCharacters = 1_024

    /// SVG path strings are parsed once at the API boundary and again by the
    /// renderer. The MCP line framer already caps requests at 4 MB; this lower
    /// per-path ceiling keeps one persistent shape from monopolizing repaint
    /// work while still allowing very detailed vector art.
    static let maxSVGPathCharacters = 200_000

    /// Atomic batches are intentionally broad enough for diagrams but bounded
    /// because every component is redrawn together on every repaint.
    static let maxBatchItems = 100

    /// Raster items have a second, stricter batch budget.  Vector components
    /// remain limited solely by `maxBatchItems`; decoded bitmap memory is what
    /// needs a byte budget because every image is retained for the annotation's
    /// full lifetime.
    static let maxRasterImagesPerBatch = 16
    static let maxRasterDecodedBytesPerBatch: UInt64 = 128 * 1_024 * 1_024

    /// Dash arrays longer than this have no practical display benefit and can
    /// make Core Graphics path setup needlessly expensive.
    static let maxDashElements = 64

    /// Largest number of annotations one process will hold at once.
    ///
    /// Free-draw tools deliberately allow annotations to persist until
    /// explicitly cleared (see `AnnotationStore`'s type comment and
    /// `ClearScope`'s doc comment), and this is a long-lived background
    /// server, so a caller that keeps drawing and never calls `clear` grows
    /// the store without bound and makes every repaint's O(n) filter
    /// (`getForScreen`) steadily more expensive. The cap is far above any
    /// plausible real session; hitting it means something is wrong, so an
    /// insertion that would exceed it is rejected outright -- see
    /// `AnnotationStore.addWithOutcome` -- rather than silently evicting
    /// older annotations to make room for it.
    static let maxStoredAnnotations = 2_000

    /// Bounds the UTF-8 payload retained by persistent vector/text drawings.
    /// Per-item limits are not enough here: 2,000 individually valid SVG
    /// paths can otherwise retain hundreds of megabytes and make every
    /// repaint parse an unbounded aggregate.  This is deliberately separate
    /// from the decoded-raster budget in `RasterAssetStore`.
    static let maxRetainedAnnotationPayloadBytes = 16 * 1_024 * 1_024

    /// Bounds the total number of renderer primitives retained across all
    /// annotations.  A batch is counted through each of its children, so this
    /// protects the renderer even when every path/text payload is tiny.
    static let maxRetainedAnnotationPrimitives = 10_000
}
