#if os(macOS)
import Foundation
import AppKit

public final class OverlayView: NSView {
    public var screenId: String = ""
    /// This display's `NSScreen.backingScaleFactor`, set once by
    /// `OverlayWindowController.makeOverlayWindow`. It is the DISPLAY's scale,
    /// not the renderer's divisor: `draw(_:)` below converts it through
    /// `OverlayDrawingMetrics.rendererScaleFactor` -- the single definition
    /// the verification compositor reads too -- rather than handing it to the
    /// renderer directly, so this live path and the verification path cannot
    /// drift apart. See that function for the full rationale.
    public var scaleFactor: CGFloat = 2.0

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }

    override public var isFlipped: Bool {
        // Keeping false (AppKit standard bottom-left origin) to make bounds.height calculations explicit and standard
        return false
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)

        // Per-app filtering: only annotations that are global, or linked to the
        // app that is frontmost RIGHT NOW, get painted. `ActiveAppTracker`
        // repaints every overlay on each app activation, so switching from
        // DaVinci Resolve to Terminal swaps one app's annotations out for the
        // other's. Note this uses `currentAppId` (what is on screen) and NOT
        // `fallbackAppId` (what an untagged draw call would target).
        //
        // EXCEPT while capture visibility is ON, which is a DEBUG MODE and is
        // deliberately exempt from the filter -- do not "simplify" this back to
        // a single unconditional call:
        //
        // `set_capture_visible(true)` exists for placement debugging: Claude
        // draws something, requests capture eligibility, screenshots the
        // display through a compatible capture path, and checks placement. But Claude
        // Desktop is frontmost at the moment it screenshots, so `currentAppId`
        // is Claude, while the annotation it just drew was tagged with
        // `fallbackAppId` (the OTHER app -- see ActiveAppTracker). Filtering
        // here would guarantee that annotation is absent even when the capture
        // path includes the overlay. Rendering it keeps AI Chalkboard's own
        // filtering from defeating the debug request; external capture filters
        // remain outside the app's control.
        //
        // So while the debug toggle is on, render EVERYTHING on this screen.
        // The user has explicitly asked to see the overlay as it really is;
        // showing another app's annotations for the duration is the intended,
        // reversible cost.
        //
        // Routed through `OverlayWindowController.currentlyVisibleAnnotations`
        // rather than querying `AnnotationStore`/`ActiveAppTracker` directly:
        // `refreshViews()` needs this EXACT same "what should be visible right
        // now" answer to decide whether the window itself belongs on screen at
        // all (see that method's doc comment), and computing it twice risked
        // the two independently drifting out of sync with each other.
        let annotations = OverlayWindowController.shared.currentlyVisibleAnnotations(forScreenId: screenId)

        // Snapshot every raster this frame needs before drawing any of it. A
        // concurrent clear can release the store's ownership mid-draw, but
        // this lease owns strong image references through the entire
        // recursive draw below -- the closure captures it, so it stays alive
        // for exactly as long as `AnnotationRenderer` needs it and no longer.
        let assetIDs = annotations.flatMap { $0.kind.rasterAssetIds }
        let rasterLease = RasterAssetStore.shared.lease(ids: assetIDs)

        let drawingContext = CoreGraphicsDrawingContext(context: context)
        AnnotationRenderer.drawAnnotations(
            annotations,
            into: drawingContext,
            canvasSize: bounds.size,
            // `bounds.size` is a POINT canvas, so the divisor this resolves to
            // on macOS is exactly the display's backing scale -- unchanged
            // behavior, now stated once in a place the verifier reads too.
            scaleFactor: OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: scaleFactor)
        ) { assetId in
            rasterLease.image(id: assetId).map(NSImageRasterHandle.init)
        }
    }
}
#endif
