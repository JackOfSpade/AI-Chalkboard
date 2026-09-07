import Foundation

/// Pure geometry/validation helpers behind `get_annotation_bounds`
/// (`MCPServer.handleGetAnnotationBounds` below), split out so each piece is
/// directly unit-testable with no MCP transport, no store, and no live
/// display in play -- the same "decision separate from the runtime plumbing"
/// precedent `ScreenshotGeometry`, `PaintedBounds`, and `DrawRequest`'s own
/// static helpers already follow in this package.
enum AnnotationBoundsSupport {
    /// `screenshot_width`/`screenshot_height` must be supplied TOGETHER or
    /// NOT AT ALL -- one is meaningless without the other for mapping a
    /// backing-pixel rect into that screenshot's pixel space, matching the
    /// "supplying one argument alone is unambiguous evidence of a
    /// contradiction, so reject rather than guess" rule this repo applies
    /// everywhere else a coordinate space is paired with dimensions (see
    /// `DrawRequest.coordinateTransform`'s `screenshot_pixels` branch).
    ///
    /// When supplied, both must be positive integers whose aspect ratio is a
    /// plausible full-display capture of `screen` -- reusing
    /// `ScreenshotGeometry.fullDisplayScale`, the EXACT rule
    /// `coordinate_space='screenshot_pixels'` and `verify_annotation` already
    /// enforce, rather than restating a fourth copy of it.
    static func resolveScreenshotDimensions(
        _ args: [String: Any], screen: ScreenInfo
    ) -> DrawOutcome<(width: Int, height: Int)?> {
        // A JSON `null` does not count as supplied -- same reasoning as
        // `DrawRequest.coordinateTransform`'s identical `isSupplied` helper:
        // a schema-driven client that serializes every declared property and
        // nulls the ones it is not using is an ordinary way to build a
        // request.
        func isSupplied(_ key: String) -> Bool {
            guard let value = args[key] else { return false }
            return !(value is NSNull)
        }
        let hasWidth = isSupplied("screenshot_width")
        let hasHeight = isSupplied("screenshot_height")
        guard hasWidth == hasHeight else {
            return .failure("screenshot_width and screenshot_height must be supplied together (both, or neither): one is meaningless without the other for mapping bounds into that screenshot's pixel space.")
        }
        guard hasWidth else { return .success(nil) }
        guard let width = MCPArgument.integer(args["screenshot_width"]), width > 0,
              let height = MCPArgument.integer(args["screenshot_height"]), height > 0 else {
            return .failure("screenshot_width and screenshot_height must be positive integers when supplied.")
        }
        guard ScreenshotGeometry.fullDisplayScale(
            screenshotWidth: Double(width), screenshotHeight: Double(height),
            screenWidth: Double(screen.widthPx), screenHeight: Double(screen.heightPx)
        ) != nil else {
            let sourceScaleX = Double(width) / Double(screen.widthPx)
            let sourceScaleY = Double(height) / Double(screen.heightPx)
            return .failure("screenshot_width/screenshot_height (\(width)x\(height)) do not match display \(screen.id)'s aspect ratio (\(screen.widthPx)x\(screen.heightPx) backing pixels, scales \(sourceScaleX)x\(sourceScaleY)) within pixel-rounding tolerance. Supply the exact dimensions of an uncropped full-display screenshot of that display, or omit both for backing-pixel bounds only.")
        }
        return .success((width, height))
    }

    /// `target_bounds_screenshot_px` -- the rect the caller measured for the
    /// UI element it wanted annotated, in ITS OWN screenshot's pixels.
    /// Requires all four fields as finite numbers with a non-negative size;
    /// absent or JSON-null means "not supplied".
    static func parseTargetBounds(_ args: [String: Any]) -> DrawOutcome<CGRect?> {
        guard let raw = args["target_bounds_screenshot_px"], !(raw is NSNull) else { return .success(nil) }
        guard let dict = raw as? [String: Any] else {
            return .failure("target_bounds_screenshot_px must be an object with numeric x, y, width, and height when supplied.")
        }
        guard let x = MCPArgument.double(dict["x"]), let y = MCPArgument.double(dict["y"]),
              let width = MCPArgument.double(dict["width"]), let height = MCPArgument.double(dict["height"]) else {
            return .failure("target_bounds_screenshot_px requires finite numeric x, y, width, and height fields.")
        }
        guard width >= 0, height >= 0 else {
            return .failure("target_bounds_screenshot_px width and height must not be negative.")
        }
        return .success(CGRect(x: x, y: y, width: width, height: height))
    }

    /// Scales a backing-pixel rect into screenshot pixels. Both spaces share
    /// the same top-left origin -- a display-local physical-pixel rect on one
    /// side, that same display's own screenshot on the other -- so this is a
    /// pure per-axis multiply with no translate term, exactly like
    /// `AnnotationVerificationCompositor`'s own `scaleToScreenshot` metadata.
    static func screenshotRect(backingRect: CGRect, scale: (x: Double, y: Double)) -> CGRect {
        CGRect(
            x: backingRect.minX * scale.x, y: backingRect.minY * scale.y,
            width: backingRect.width * scale.x, height: backingRect.height * scale.y
        )
    }

    /// The exact `offset_x`/`offset_y` ABSOLUTE value -- not a delta --
    /// that closes a centre-to-centre gap of `(deltaScreenshotX,
    /// deltaScreenshotY)` SCREENSHOT pixels. `update_annotation`'s
    /// `offset_x`/`offset_y` REPLACE the stored offset (see
    /// `MCPToolHandlers+Drawing.swift`'s `patchedAnnotation`: `MCPArgument
    /// .double(args["offset_x"]) ?? current.offsetX`), so a caller that
    /// applies this value directly must receive the new absolute number, not
    /// an amount to add to whatever it currently has -- an agent that reads
    /// the field name and adds a delta on top would move the drawing twice.
    ///
    /// TWO conversions compose here, not one:
    ///   1. screenshot pixels -> backing pixels, via `screenshotToBackingScale`
    ///      (the display's backing size divided by the screenshot's own --
    ///      the RECIPROCAL of `screenshotRect`'s scale above).
    ///   2. backing-pixel MOVEMENT -> a CHANGE IN `offset_x`/`offset_y`, via
    ///      dividing by `adjustment.scaleX`/`scaleY`. This division exists
    ///      because `AnnotationRenderer.drawAnnotations` does not add the
    ///      offset to the painted position directly -- it computes
    ///      `annotation.offsetX * adjustment.scaleX + adjustment.translateX`
    ///      (see that method), so ONE unit of `offset_x` moves the painted
    ///      result by `adjustment.scaleX` backing pixels whenever the
    ///      annotation is anchored with a non-1 scale (a `.scale`-resize
    ///      anchor whose window has grown or shrunk since creation). Moving
    ///      the PAINTED position by `deltaBackingX` therefore requires
    ///      changing `offset_x` by `deltaBackingX / adjustment.scaleX`, not
    ///      by `deltaBackingX` itself.
    ///
    /// For an UNANCHORED annotation `adjustment` is `.identity`
    /// (scaleX == scaleY == 1), so both divisions are by exactly 1.0 and this
    /// reduces to the "obvious" `currentOffset + deltaBacking` answer --
    /// reached here by the SAME formula, not a special case, so the division
    /// is not dead code a future reader might "simplify" away: it is exactly
    /// what makes the anchored case correct too.
    ///
    /// Returns `nil` -- omit `correctionBackingPx` entirely rather than emit
    /// an infinity or NaN -- when `adjustment.scaleX`/`scaleY` is zero,
    /// non-finite, or otherwise degenerate. `AnchorAdjustment.mapping` is
    /// written so a LIVE adjustment should never carry such a scale, but a
    /// hand-built or frozen `staticAdjustment` is not covered by that
    /// guarantee, so this checks rather than assumes it.
    static func correctedOffset(
        currentOffsetX: Double,
        currentOffsetY: Double,
        deltaScreenshotX: Double,
        deltaScreenshotY: Double,
        screenshotToBackingScale: (x: Double, y: Double),
        adjustment: AnchorAdjustment
    ) -> (offsetX: Double, offsetY: Double)? {
        guard deltaScreenshotX.isFinite, deltaScreenshotY.isFinite,
              screenshotToBackingScale.x.isFinite, screenshotToBackingScale.y.isFinite else { return nil }
        let deltaBackingX = deltaScreenshotX * screenshotToBackingScale.x
        let deltaBackingY = deltaScreenshotY * screenshotToBackingScale.y
        guard adjustment.scaleX.isFinite, adjustment.scaleX != 0,
              adjustment.scaleY.isFinite, adjustment.scaleY != 0 else { return nil }
        let offsetX = currentOffsetX + deltaBackingX / adjustment.scaleX
        let offsetY = currentOffsetY + deltaBackingY / adjustment.scaleY
        guard offsetX.isFinite, offsetY.isFinite else { return nil }
        return (offsetX, offsetY)
    }
}

extension MCPServer {
    /// `get_annotation_bounds` -- answers "where would this annotation be in
    /// a screenshot of its display at these dimensions?" with NO image in
    /// either direction and NO Screen Recording permission, closing the gap
    /// `verify_annotation`/`verify_presentation` cannot: an agent whose OWN
    /// screenshot tool never shows Chalkboard's overlay (a different capture
    /// surface, an accessory-app filter, or a missing permission on
    /// Chalkboard's own side) still needs a placement answer, and this tool
    /// gives one without depending on the overlay reaching ANY capture
    /// pipeline's pixels. See CAPTURE_GAP.md's "Remedy (a)".
    ///
    /// Painted bounds come from the EXACT live renderer via
    /// `AnnotationVerificationCompositor.renderedPaintedBounds(of:on:
    /// rasterLease:)` -- the SAME render-this-annotation-alone-and-scan
    /// implementation `verify_annotation`'s compositor uses internally, not a
    /// second, independent geometry estimate -- so the answer is correct for
    /// text (real glyph metrics), a rotated image, `offset_x`/`offset_y`, and
    /// a live anchor adjustment. See that method's doc comment for the full
    /// "touches no capture API" contract this tool depends on.
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleGetAnnotationBounds(id: Any, args: [String: Any]) {
        guard let annotationId = (args["annotation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !annotationId.isEmpty else {
            sendErrorResult(id: id, text: "Missing required parameter: annotation_id")
            return
        }

        guard let renderSnapshot = AnnotationStore.shared.renderSnapshot(id: annotationId) else {
            sendErrorResult(id: id, text: "Annotation \(annotationId) was not found. It may already have been cleared; call list_annotations for a current ID.")
            return
        }
        let annotation = renderSnapshot.annotation

        // EFFECTIVE screen, not the creation screen: anchoring may have moved
        // this annotation onto a different display than the one it was
        // originally drawn on (see `Annotation.effectiveScreenId`'s doc
        // comment), and that current display's backing pixels are what this
        // tool must report bounds against.
        let effectiveScreenId = annotation.effectiveScreenId
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        guard let screen = snapshot.screens.first(where: { $0.id == effectiveScreenId }) else {
            sendErrorResult(id: id, text: "Annotation \(annotationId)'s current display (\(effectiveScreenId)) is no longer connected. Nothing was computed; call get_screens for the current display list.")
            return
        }

        let screenshotDimensions: (width: Int, height: Int)?
        switch AnnotationBoundsSupport.resolveScreenshotDimensions(args, screen: screen) {
        case .failure(let error):
            sendErrorResult(id: id, text: error)
            return
        case .success(let value):
            screenshotDimensions = value
        }

        let targetBounds: CGRect?
        switch AnnotationBoundsSupport.parseTargetBounds(args) {
        case .failure(let error):
            sendErrorResult(id: id, text: error)
            return
        case .success(let value):
            targetBounds = value
        }

        guard targetBounds == nil || screenshotDimensions != nil else {
            sendErrorResult(id: id, text: "target_bounds_screenshot_px requires screenshot_width and screenshot_height: its coordinates are only meaningful in that screenshot's pixel space, and there is nothing to convert them against otherwise.")
            return
        }

        let paintedBoundsBacking: CGRect?
        do {
            // NO screen capture, NO Screen Recording permission: this call
            // renders the annotation alone into an offscreen transparent
            // bitmap and scans it for non-transparent pixels. It never calls
            // CGDisplayCreateImage, CGWindowListCreateImage, ScreenCaptureKit,
            // `screencapture`, or any other capture entry point -- see
            // `renderedPaintedBounds`'s own doc comment.
            paintedBoundsBacking = try AnnotationVerificationCompositor.renderedPaintedBounds(
                of: annotation, on: screen, rasterLease: renderSnapshot.rasterLease
            )
        } catch {
            sendErrorResult(id: id, text: error.localizedDescription)
            return
        }
        guard let paintedBoundsBacking else {
            sendErrorResult(id: id, text: "The annotation rendered without error but painted no pixels anywhere on its \(screen.widthPx)x\(screen.heightPx) screen (\(screen.id)), so there is no region to report. Check that its coordinates fall inside that screen and that its stroke/fill colors, opacity, and path data are not empty or fully transparent.")
            return
        }

        var payload: [String: Any] = [
            "annotationId": annotation.id,
            "screenId": screen.id,
            "screenBackingPx": ["width": screen.widthPx, "height": screen.heightPx],
            "paintedBoundsBackingPx": rectPayload(paintedBoundsBacking)
        ]

        if let screenshotDimensions {
            let scaleX = Double(screenshotDimensions.width) / Double(screen.widthPx)
            let scaleY = Double(screenshotDimensions.height) / Double(screen.heightPx)
            payload["screenshotScale"] = ["x": scaleX, "y": scaleY]
            let paintedScreenshotRect = AnnotationBoundsSupport.screenshotRect(
                backingRect: paintedBoundsBacking, scale: (scaleX, scaleY)
            )
            payload["paintedBoundsScreenshotPx"] = rectPayload(paintedScreenshotRect)

            if let targetBounds {
                let dx = Double(targetBounds.midX - paintedScreenshotRect.midX)
                let dy = Double(targetBounds.midY - paintedScreenshotRect.midY)
                payload["targetDeltaScreenshotPx"] = ["dx": dx, "dy": dy]

                let adjustment = annotation.effectiveAdjustment
                if let corrected = AnnotationBoundsSupport.correctedOffset(
                    currentOffsetX: annotation.offsetX, currentOffsetY: annotation.offsetY,
                    deltaScreenshotX: dx, deltaScreenshotY: dy,
                    screenshotToBackingScale: (1 / scaleX, 1 / scaleY),
                    adjustment: adjustment
                ) {
                    payload["correctionBackingPx"] = ["offsetX": corrected.offsetX, "offsetY": corrected.offsetY]
                } else {
                    payload["correctionUnavailableReason"] = "The annotation's current anchor adjustment scale is zero, non-finite, or otherwise degenerate, so a single offset_x/offset_y correction cannot be computed safely. Check anchor.state before retrying."
                }
            }
        }

        // Reuses DrawRequest.anchorResponsePayload so this tool's `anchor`
        // object is byte-for-byte the same shape draw_*/highlight_element/
        // update_annotation/list_annotations already emit -- see
        // MCP_SURFACE.md's "Success payload -- the anchor object".
        if let anchor = annotation.anchor, let projection = annotation.anchorProjection {
            payload["anchor"] = DrawRequest.anchorResponsePayload(
                DrawRequest.DrawAnchorResolution(anchor: anchor, projection: projection)
            )
        }

        payload["evidence"] = "This is renderer geometry, not captured pixels: the exact live AnnotationRenderer painted this annotation ALONE into an offscreen transparent bitmap sized to display \(screen.id)'s backing pixels (\(screen.widthPx)x\(screen.heightPx)), and paintedBoundsBackingPx is that render's non-transparent pixel bounds. No screen-capture API and no Screen Recording permission was used or required to produce this answer -- it does NOT prove any pixel reached a framebuffer, was actually displayed, or would appear in any capture pipeline's output. For that kind of evidence use verify_presentation (window-registration proof) or verify_annotation (a composited proof against an actual screenshot)."

        guard let text = jsonString(payload) else {
            sendErrorResult(id: id, text: "Failed to encode annotation bounds.")
            return
        }
        sendTextResult(id: id, text: text)
    }

    private func rectPayload(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
}
