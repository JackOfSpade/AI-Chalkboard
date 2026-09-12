import Foundation

// MARK: - `update_annotation` anchor-patch types

/// `patchedAnnotation`'s result: the fully built replacement `Annotation`,
/// plus -- for the anchor operations that must REPLACE the tracker's
/// last-known projection outright (detach, re-anchor, and a resize-policy
/// change) -- the exact `AnchorProjection` override to install, ATOMICALLY
/// alongside the replacement itself, through
/// `AnnotationStore.updateWithOutcome(id:expectedRevision:transform:)`.
///
/// WHY THIS EXISTS AT ALL: `AnnotationStore.updateWithOutcome` unconditionally
/// carries the OLD annotation's `anchorProjection` forward onto ANY
/// replacement, regardless of what the replacement itself carries (see that
/// method's own doc comment: exactly right for an ordinary restyle, which has
/// nothing to say about tracking state). Detaching, re-anchoring, and
/// rebaselining a resize policy all DO have something to say about it -- each
/// must make the drawing's painted position hold exactly steady across the
/// change, which requires either neutralizing the carried-forward projection
/// (detach) or replacing it with a freshly computed one (re-anchor, resize
/// rebaseline) -- and the plain replacement has no field that can express
/// that. `handleUpdateAnnotation` supplies this override via the
/// transform-based overload's return value, so the store installs both the
/// replacement and the override in the SAME locked section instead of a
/// second, later write -- see `finalizeAnchorPatch` below for why a later
/// write (this type's OWN previous behavior, before this fix) can race a
/// tracker sample and silently discard it.
struct AnnotationPatchResult {
    let annotation: Annotation
    let projectionOverride: AnchorProjection?
    /// The anchor intent this patch resolved. `annotation`'s anchor-related
    /// fields (`screenId`, `anchor`, `staticAdjustment`) and
    /// `projectionOverride` above are only PROVISIONAL for `.detach`/
    /// `.reanchor`/`.changeResizePolicy`: they were computed from whatever
    /// snapshot `patchedAnnotation` was handed, which is not necessarily
    /// what `AnnotationStore` still holds by the time this patch actually
    /// commits. `handleUpdateAnnotation` threads this intent into
    /// `finalizeAnchorPatch`, which RECOMPUTES those fields against the
    /// live store annotation at commit time -- seeing whatever
    /// `AnchorTracker` most recently wrote instead of a stale read -- which
    /// is the actual fix for BUG 1 in the adversarial review this addresses.
    let anchorIntent: AnchorPatchIntent
    /// `.reanchor` only: the already-sampled candidate windows (plus the
    /// pid/appId/resize policy needed to re-run the pick) from
    /// `resolveAnchorPatch`'s pre-lock work. `finalizeAnchorPatch` uses this
    /// to RE-RUN window SELECTION -- pure, and therefore legal inside
    /// `AnnotationStore`'s lock -- against the live annotation's CURRENT
    /// painted bounds, instead of trusting `annotation.anchor` above, which
    /// was picked against a pre-lock (and therefore potentially stale)
    /// snapshot. See `finalizeAnchorPatch`'s doc comment for the race this
    /// closes. `nil` for every other intent, which has no window to
    /// reselect.
    let reanchorContext: ReanchorWindowContext?
}

/// `.reanchor`'s sampled window candidates, carried forward from
/// `resolveAnchorPatch`'s pre-lock, impure sampling
/// (`TargetWindowProbe.shared.windows(forProcessId:screens:)`) to
/// `finalizeAnchorPatch`, where the PURE selection step
/// (`DrawRequest.buildWindowAnchor` / `TargetWindowSelection
/// .selectWindow(forRect:among:)`) is re-run against the live annotation --
/// see `finalizeAnchorPatch`'s doc comment for why selection must be re-run
/// there while the sampling that produced `samples` must not.
struct ReanchorWindowContext {
    let processId: Int64
    let appId: String
    let resize: AnchorResizeBehavior
    let samples: [TargetWindowSample]
    /// The screen snapshot `samples` was probed against, carried forward for
    /// the same reason `samples` is: `finalizeAnchorPatch` runs inside the
    /// store's lock and must stay pure, and `buildWindowAnchor` uses this
    /// only to record the selected window's display backing scale
    /// (`AnnotationAnchor.referenceScreenScale`) for pin-mode density
    /// compensation -- see that property's doc comment.
    let screens: [ScreenInfo]
}

/// The four `update_annotation` anchor behaviors, decided purely from
/// `anchor`/`anchor_resize`'s STRING values plus whether the annotation is
/// CURRENTLY anchored -- no process lookup, no window sampling. See
/// `MCPServer.parseAnchorPatch`.
enum AnchorPatchIntent: Equatable {
    /// Neither `anchor` nor `anchor_resize` was supplied: every anchor field
    /// carries forward untouched, exactly as MCP_SURFACE.md's
    /// `update_annotation` section requires.
    case unchanged
    /// `anchor: "none"`: detach and freeze in place.
    case detach
    /// `anchor: "window"`, with the effective resize policy -- `.pin` when
    /// `anchor_resize` was not also supplied, matching every other tool's
    /// documented default.
    case reanchor(resize: AnchorResizeBehavior)
    /// `anchor_resize` alone, with no `anchor` argument, on an ALREADY
    /// anchored annotation: change the policy in place.
    case changeResizePolicy(resize: AnchorResizeBehavior)
}

/// One `update_annotation` anchor operation's resolved effect on the three
/// fields it can change, plus the projection override to write AFTER the
/// store update (see `AnnotationPatchResult`'s doc comment for why that
/// second write exists at all).
struct AnchorPatchResolution {
    let screenId: String
    let anchor: AnnotationAnchor?
    let staticAdjustment: AnchorAdjustment
    let projectionOverride: AnchorProjection?
    /// Populated only by `.reanchor`'s branch of `resolveAnchorPatch`; `nil`
    /// for every other intent. See `AnnotationPatchResult.reanchorContext`'s
    /// doc comment -- this is the same value, just threaded one layer
    /// earlier, before `patchedAnnotation` copies it onto the
    /// `AnnotationPatchResult` it returns.
    let reanchorContext: ReanchorWindowContext?
}

extension MCPServer {
    // MARK: - Free-draw primitives

    // internal: called from handleToolsCall's draw_path case in MCPToolHandlers.swift.
    func makeVectorPathKind(_ args: [String: Any], coordinateTransform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1)) -> DrawOutcome<AnnotationKind> {
        guard let data = (args["path_data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !data.isEmpty else {
            return .failure("Missing required parameter: path_data (SVG M/L/H/V/C/S/Q/T/A/Z syntax).")
        }
        guard data.count <= DrawingDefaults.maxSVGPathCharacters else {
            return .failure("path_data exceeds the \(DrawingDefaults.maxSVGPathCharacters)-character limit.")
        }
        let geometry: SVGPathGeometry
        do { geometry = try SVGPathParser.parseGeometry(data) }
        catch { return .failure("Invalid SVG path_data: \(error.localizedDescription)") }
        guard geometry.hasDrawableGeometry else {
            return .failure("path_data must contain at least one non-degenerate drawable segment; a moveto-only or zero-length path cannot be shown.")
        }
        guard coordinateTransform.canTransform(geometry) else {
            return .failure("path_data contains coordinates that cannot be represented safely in the selected display's backing-pixel space.")
        }
        // Screenshot-grid sanity: a path measured on the declared screenshot
        // must at least TOUCH it. Control points legitimately swing outside
        // an image, so this uses the lax entirely-outside rule
        // (`positionIsBounds: true` -- see `sourceGeometryRejection`'s doc
        // comment) over the min/max of every point INCLUDING controls: that
        // envelope only ever over-covers, so a rejection here means no part
        // of the path could have come from the declared image.
        if coordinateTransform.screenshotGrid != nil {
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            func cover(_ point: CGPoint) {
                minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
                minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
            }
            for element in geometry.elements {
                switch element {
                case let .move(point), let .line(point): cover(point)
                case let .quad(control, to: point): cover(control); cover(point)
                case let .cubic(control1, control2, to: point): cover(control1); cover(control2); cover(point)
                case .close: break
                }
            }
            if minX <= maxX, let rejection = coordinateTransform.sourceGeometryRejection(
                minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                what: "path_data's geometry", positionIsBounds: true
            ) {
                return .failure(rejection)
            }
        }

        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["stroke_width", "stroke_opacity", "fill_opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        if let key = MCPArgument.firstNonStringSupplied(args, keys: ["stroke_color", "fill_color", "fill_rule"]) {
            return .failure("\(key) must be a string when supplied.")
        }

        let fillColor = args["fill_color"] as? String
        let hasExplicitStroke = args.keys.contains("stroke_color") || args.keys.contains("stroke_width")
        let strokeWidth = MCPArgument.double(args["stroke_width"])
            ?? ((fillColor == nil || hasExplicitStroke) ? DrawingDefaults.pathStrokeWidthPx : 0)
        guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= DrawingDefaults.maxStyleDimensionPx else {
            return .failure("stroke_width must be a finite number between 0 and \(Int(DrawingDefaults.maxStyleDimensionPx)) backing pixels.")
        }
        let strokeColor = strokeWidth > 0
            ? ((args["stroke_color"] as? String) ?? DrawingDefaults.pathColor)
            : nil
        let strokeOpacity = MCPArgument.double(args["stroke_opacity"]) ?? 1
        guard strokeOpacity.isFinite, (0...1).contains(strokeOpacity) else {
            return .failure("stroke_opacity must be between 0 and 1.")
        }
        let fillOpacity = MCPArgument.double(args["fill_opacity"]) ?? 1
        guard fillOpacity.isFinite, (0...1).contains(fillOpacity) else {
            return .failure("fill_opacity must be between 0 and 1.")
        }
        guard !args.keys.contains("dash") || args["dash"] is [Any] else {
            return .failure("dash must be an array of finite positive numbers when supplied.")
        }
        let rawDash = args["dash"] as? [Any] ?? []
        guard rawDash.count <= DrawingDefaults.maxDashElements else {
            return .failure("dash may contain at most \(DrawingDefaults.maxDashElements) lengths.")
        }
        let dash = rawDash.compactMap(MCPArgument.double)
        guard dash.count == rawDash.count,
              dash.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= DrawingDefaults.maxStyleDimensionPx }) else {
            return .failure("Every dash length must be a finite number greater than 0 and no greater than \(Int(DrawingDefaults.maxStyleDimensionPx)) backing pixels.")
        }
        let fillRule = (args["fill_rule"] as? String)?.lowercased() ?? "nonzero"
        guard fillRule == "nonzero" || fillRule == "evenodd" else {
            return .failure("fill_rule must be 'nonzero' or 'evenodd'.")
        }
        let hasVisibleStroke = colorHasVisibleAlpha(strokeColor) && strokeWidth > 0 && strokeOpacity > 0
        let hasVisibleFill = colorHasVisibleAlpha(fillColor) && fillOpacity > 0
        guard hasVisibleStroke || hasVisibleFill else {
            return .failure("The path must have a visible stroke or a fill with opacity greater than 0.")
        }

        return .success(.vectorPath(
            data: data,
            strokeColorHex: strokeColor,
            strokeWidth: strokeWidth,
            strokeOpacity: strokeOpacity,
            fillColorHex: fillColor,
            fillOpacity: fillOpacity,
            dash: dash,
            usesEvenOddFillRule: fillRule == "evenodd",
            coordinateScaleX: coordinateTransform.scaleX,
            coordinateScaleY: coordinateTransform.scaleY
        ))
    }

    /// Resolves `draw_image`'s optional `width`/`height` into backing pixels.
    ///
    /// Returns nil when a SUPPLIED dimension cannot be represented in the
    /// display's backing-pixel space; the caller turns that into its geometry
    /// error. Bounds other than representability (finite, > 0,
    /// `maxImageDimensionPx`) stay with the caller so every resolved dimension
    /// meets them the same way.
    ///
    /// Omitting BOTH dimensions means the raster's own decoded backing-pixel
    /// size, regardless of the coordinate space selected for its position.
    /// Supplying BOTH means geometry in that selected space, one axis each.
    ///
    /// Supplying exactly one is the aspect-ratio case, and the order here is
    /// load-bearing: the SUPPLIED dimension is transformed into backing pixels
    /// FIRST, then the sibling is derived from the raster's pixel aspect ratio
    /// IN BACKING SPACE. Deriving the sibling in caller space and then
    /// transforming it would run it through the OTHER axis's scale, which under
    /// an anisotropic transform is a different number --
    /// coordinate_space='normalized' on a 3840x2160 display scales x by 3840
    /// and y by 2160, so a square raster asked for width 0.1 would render
    /// 384x216 instead of 384x384. That silently stretches the very thing the
    /// caller asked us to preserve.
    ///
    /// The derived sibling deliberately never goes through `transformedX/Y`, so
    /// it also skips the transform's unit-interval check. That is intended: an
    /// aspect-correct dimension may legitimately exceed the display (a tall
    /// raster pinned to the full display width runs off the bottom), and
    /// normalized siblings > 1.0 must not be rejected.
    ///
    /// internal, and pure, so `MCPPureHelperTests` can pin all four shapes
    /// without a real raster file or a display: `loadImageKind` is private and
    /// every image fixture in the wire-snapshot harness is an error path that
    /// never reaches this arithmetic.
    static func resolveBackingSize(requestedWidth: Double?, requestedHeight: Double?,
                                   intrinsicWidth: Double, intrinsicHeight: Double,
                                   transform: DrawRequest.CoordinateTransform) -> (width: Double, height: Double)? {
        if let requestedWidth, let requestedHeight {
            guard let width = transform.transformedX(requestedWidth),
                  let height = transform.transformedY(requestedHeight) else { return nil }
            return (width, height)
        }
        if let requestedWidth {
            guard let width = transform.transformedX(requestedWidth) else { return nil }
            return (width, width * intrinsicHeight / intrinsicWidth)
        }
        if let requestedHeight {
            guard let height = transform.transformedY(requestedHeight) else { return nil }
            return (height * intrinsicWidth / intrinsicHeight, height)
        }
        return (intrinsicWidth, intrinsicHeight)
    }

    private func loadImageKind(_ args: [String: Any], coordinateTransform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1)) -> DrawOutcome<AnnotationKind> {
        guard let path = args["image_path"] as? String, !path.isEmpty,
              let x = MCPArgument.double(args["x"]),
              let y = MCPArgument.double(args["y"]) else {
            return .failure("Missing required parameters: image_path, x, y")
        }
        // Same declared-screenshot position check as `makeTextKind`; see
        // `sourceGeometryRejection`'s doc comment.
        if let rejection = coordinateTransform.sourceGeometryRejection(
            minX: x, minY: y, maxX: x, maxY: y, what: "x/y"
        ) {
            return .failure(rejection)
        }
        guard let backingX = coordinateTransform.transformedX(x),
              let backingY = coordinateTransform.transformedY(y) else {
            return .failure("Image coordinates cannot be represented safely in the selected display's backing-pixel space.")
        }
        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["width", "height", "rotation_degrees", "opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        let requestedWidth = MCPArgument.double(args["width"])
        let requestedHeight = MCPArgument.double(args["height"])
        let rotation = MCPArgument.double(args["rotation_degrees"]) ?? 0
        let opacity = MCPArgument.double(args["opacity"]) ?? 1
        guard rotation.isFinite, abs(rotation) <= DrawingDefaults.maxRotationDegrees,
              opacity.isFinite, (0...1).contains(opacity) else {
            return .failure("Image rotation must be within ±\(Int(DrawingDefaults.maxRotationDegrees)) degrees and opacity must be between 0 and 1.")
        }
        guard opacity > 0 else {
            return .failure("opacity must be greater than 0; a fully transparent image cannot be shown or verified.")
        }
        let handle: RasterAssetHandle
        do { handle = try RasterAssetStore.shared.load(path: path) }
        catch { return .failure(error.localizedDescription) }

        let resolved = Self.resolveBackingSize(
            requestedWidth: requestedWidth, requestedHeight: requestedHeight,
            intrinsicWidth: Double(handle.widthPx), intrinsicHeight: Double(handle.heightPx),
            transform: coordinateTransform
        )
        // Rotation and opacity were already validated above; re-checking them
        // here would only make this message describe conditions it cannot
        // actually reject.
        guard let (backingWidth, backingHeight) = resolved,
              backingWidth.isFinite, backingHeight.isFinite,
              backingWidth > 0, backingHeight > 0,
              backingWidth <= DrawingDefaults.maxImageDimensionPx,
              backingHeight <= DrawingDefaults.maxImageDimensionPx else {
            _ = RasterAssetStore.shared.release(id: handle.id)
            return .failure("Image width/height must resolve to finite backing-pixel values greater than 0 and at most \(Int(DrawingDefaults.maxImageDimensionPx)).")
        }
        return .success(.image(
            assetId: handle.id, x: backingX, y: backingY,
            width: backingWidth, height: backingHeight,
            rotationDegrees: rotation, opacity: opacity
        ))
    }

    private func makeTextKind(_ args: [String: Any], coordinateTransform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1)) -> DrawOutcome<AnnotationKind> {
        guard let text = args["text"] as? String,
              !text.isEmpty,
              let x = MCPArgument.double(args["x"]),
              let y = MCPArgument.double(args["y"]),
              let fontSize = MCPArgument.double(args["font_size"]) else {
            return .failure("Missing required parameters: text, x, y, font_size")
        }
        guard text.count <= DrawingDefaults.maxTextCharacters else {
            return .failure("text exceeds the \(DrawingDefaults.maxTextCharacters)-character limit.")
        }
        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["background_opacity", "padding_px", "opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        if let key = MCPArgument.firstNonStringSupplied(args, keys: ["color", "background_color"]) {
            return .failure("\(key) must be a string when supplied.")
        }
        let backgroundOpacity = MCPArgument.double(args["background_opacity"]) ?? 1
        let padding = MCPArgument.double(args["padding_px"]) ?? 0
        let opacity = MCPArgument.double(args["opacity"]) ?? 1
        // A text POSITION beyond the declared screenshot cannot have been
        // measured on it -- see `sourceGeometryRejection`'s doc comment for
        // the mistake this catches (full-res coordinates declared at
        // client-resized dimensions, silently doubling every position).
        if let rejection = coordinateTransform.sourceGeometryRejection(
            minX: x, minY: y, maxX: x, maxY: y, what: "x/y"
        ) {
            return .failure(rejection)
        }
        guard let backingX = coordinateTransform.transformedX(x),
              let backingY = coordinateTransform.transformedY(y) else {
            return .failure("Text coordinates cannot be represented safely in the selected display's backing-pixel space.")
        }
        guard x.isFinite, y.isFinite, fontSize.isFinite, fontSize > 0,
              fontSize <= DrawingDefaults.maxStyleDimensionPx,
              backgroundOpacity.isFinite, (0...1).contains(backgroundOpacity),
              padding.isFinite, padding >= 0, padding <= DrawingDefaults.maxStyleDimensionPx,
              opacity.isFinite, (0...1).contains(opacity), opacity > 0 else {
            return .failure("Text geometry must be finite; font_size must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)); padding_px must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)); and opacity values must be between 0 and 1 (text opacity > 0).")
        }
        guard DrawingDefaults.isWithinTextRenderBudget(text: text, fontSizePx: fontSize, paddingPx: padding) else {
            return .failure("Text render extent exceeds the safe layout budget. Reduce text length, font_size, or padding_px.")
        }
        let textColor = (args["color"] as? String) ?? DrawingDefaults.textColor
        let backgroundColor = args["background_color"] as? String
        guard colorHasVisibleAlpha(textColor)
                || (colorHasVisibleAlpha(backgroundColor) && backgroundOpacity > 0) else {
            return .failure("Text must have a visible text color or background color after RGBA alpha and opacity are applied.")
        }
        return .success(.text(
            text: text,
            x: backingX, y: backingY,
            fontSize: fontSize,
            textColorHex: textColor,
            backgroundColorHex: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            paddingPx: padding,
            opacity: opacity
        ))
    }

    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleDrawImage(id: Any, args: [String: Any]) {
        let request: DrawRequest
        let transform: DrawRequest.CoordinateTransform
        switch DrawRequest.resolveDrawContext(args: args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let resolved): (request, transform) = resolved
        }
        let kind: AnnotationKind
        switch loadImageKind(args, coordinateTransform: transform) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let loaded): kind = loaded
        }
        switch request.finish(
            args: args, defaultColor: "#FFFFFF", label: nil, defaultsToGlobal: false,
            kind: kind, noun: "free-draw raster image", transform: transform
        ) {
        case .failure(let err):
            for assetId in kind.rasterAssetIds { _ = RasterAssetStore.shared.release(id: assetId) }
            sendErrorResult(id: id, text: err)
        case .success(let message): sendTextResult(id: id, text: message)
        }
    }

    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleDrawText(id: Any, args: [String: Any]) {
        let request: DrawRequest
        let transform: DrawRequest.CoordinateTransform
        switch DrawRequest.resolveDrawContext(args: args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let resolved): (request, transform) = resolved
        }
        let kind: AnnotationKind
        switch makeTextKind(args, coordinateTransform: transform) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let parsed): kind = parsed
        }
        switch request.finish(
            args: args, defaultColor: DrawingDefaults.textColor, label: nil, defaultsToGlobal: false,
            kind: kind, noun: "text", transform: transform
        ) {
        case .failure(let err): sendErrorResult(id: id, text: err)
        case .success(let message): sendTextResult(id: id, text: message)
        }
    }

    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleDrawBatch(id: Any, args: [String: Any]) {
        guard let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty,
              rawItems.count <= DrawingDefaults.maxBatchItems else {
            sendErrorResult(id: id, text: "items must contain 1...\(DrawingDefaults.maxBatchItems) path/image/text/shape primitives.")
            return
        }
        let request: DrawRequest
        let transform: DrawRequest.CoordinateTransform
        switch DrawRequest.resolveDrawContext(args: args) {
        case .failure(let err): sendErrorResult(id: id, text: err); return
        case .success(let resolved): (request, transform) = resolved
        }

        var components: [AnnotationComponent] = []
        var ownedAssetIds: [String] = []
        var rasterImageCount = 0
        var rasterDecodedBytes: UInt64 = 0
        func fail(_ message: String) {
            for assetId in ownedAssetIds { _ = RasterAssetStore.shared.release(id: assetId) }
            sendErrorResult(id: id, text: message)
        }
        for (index, item) in rawItems.enumerated() {
            // A batch item has no independent lifetime -- every item in a
            // batch shares ONE annotation id and is cleared together -- so
            // `duration_seconds` was never meaningful here even when
            // annotations still had durations. It must still be rejected
            // rather than ignored, and rejected PER ITEM: the top-level check
            // in `finish` only sees the batch's own arguments, so an item that
            // carries `duration_seconds` slips past it entirely. Silently
            // accepting it would leave the caller believing that item cleans
            // itself up, which is exactly the false belief the top-level
            // rejection exists to prevent.
            if let error = DrawRequest.rejectDurationSecondsIfSupplied(args: item) {
                fail("items[\(index)]: \(error)")
                return
            }
            let outcome: DrawOutcome<AnnotationKind>
            switch (item["type"] as? String)?.lowercased() {
            case "path": outcome = makeVectorPathKind(item, coordinateTransform: transform)
            case "image": outcome = loadImageKind(item, coordinateTransform: transform)
            case "text": outcome = makeTextKind(item, coordinateTransform: transform)
            case "shape": outcome = makeShapeKind(item, coordinateTransform: transform)
            default: fail("items[\(index)].type must be 'path', 'image', 'text', or 'shape'."); return
            }
            switch outcome {
            case .failure(let err): fail("items[\(index)]: \(err)"); return
            case .success(let kind):
                let newAssetIDs = kind.rasterAssetIds
                if !newAssetIDs.isEmpty {
                    let newBytes = newAssetIDs.reduce(UInt64(0)) { total, assetID in
                        guard let handle = RasterAssetStore.shared.descriptor(for: assetID) else { return total }
                        return total + handle.decodedByteCount
                    }
                    // `maxRasterDecodedBytesPerBatch - rasterDecodedBytes` is only a
                    // safe UInt64 subtraction because this loop's own accumulation
                    // just below keeps `rasterDecodedBytes <= maxRasterDecodedBytesPerBatch`
                    // on every iteration. Compute it as an explicit saturating
                    // subtraction instead of relying on that invariant holding
                    // forever, so a future refactor that breaks it (or reorders this
                    // loop) fails closed -- rejecting the batch -- rather than
                    // underflowing to a huge remaining-budget value that would
                    // silently disable this memory cap.
                    let remainingRasterBudget = rasterDecodedBytes <= DrawingDefaults.maxRasterDecodedBytesPerBatch
                        ? DrawingDefaults.maxRasterDecodedBytesPerBatch - rasterDecodedBytes
                        : 0
                    guard rasterImageCount + newAssetIDs.count <= DrawingDefaults.maxRasterImagesPerBatch,
                          newBytes <= remainingRasterBudget else {
                        for assetID in newAssetIDs { _ = RasterAssetStore.shared.release(id: assetID) }
                        fail("items contains too many raster images or exceeds the \(DrawingDefaults.maxRasterDecodedBytesPerBatch / (1_024 * 1_024)) MB decoded-raster batch budget.")
                        return
                    }
                    rasterImageCount += newAssetIDs.count
                    rasterDecodedBytes += newBytes
                }
                ownedAssetIds.append(contentsOf: kind.rasterAssetIds)
                components.append(AnnotationComponent(
                    kind: kind,
                    colorHex: (item["stroke_color"] as? String) ?? DrawingDefaults.pathColor,
                    label: nil
                ))
            }
        }

        let kind = AnnotationKind.batch(items: components)
        switch request.finish(
            args: args, defaultColor: DrawingDefaults.pathColor, label: nil, defaultsToGlobal: false,
            kind: kind, noun: "atomic free-draw batch (\(components.count) items)", transform: transform
        ) {
        case .failure(let err): fail(err)
        case .success(let message): sendTextResult(id: id, text: message)
        }
    }

    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleUpdateAnnotation(id: Any, args: [String: Any]) {
        guard let annotationID = (args["annotation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !annotationID.isEmpty else {
            sendErrorResult(id: id, text: "Missing required parameter: annotation_id")
            return
        }
        guard let current = AnnotationStore.shared.get(id: annotationID) else {
            sendErrorResult(id: id, text: "Annotation \(annotationID) was not found. It may already have been cleared; call list_annotations for the current set.")
            return
        }
        let patch: AnnotationPatchResult
        switch patchedAnnotation(current, args: args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let result): patch = result
        }
        // Committing through the transform-based overload -- not
        // `updateWithOutcome(id:with:expectedRevision:)` -- is what fixes
        // BUG 1: `finalizeAnchorPatch` recomputes `patch`'s freeze-dependent
        // fields against whatever `AnnotationStore` is ACTUALLY holding for
        // this id at commit time, under its own lock, instead of trusting
        // `patch` as built from `current` (a snapshot read before this call
        // even started). `committedAnchor`/`committedProjection` capture
        // what the transform decided, purely for the response text below --
        // the closure runs synchronously, at most once, before
        // `updateWithOutcome` returns, so reading them afterward is safe.
        var committedAnchor = patch.annotation.anchor
        var committedProjection = patch.projectionOverride ?? current.anchorProjection
        let outcome = AnnotationStore.shared.updateIfPossibleWithOutcome(
            id: annotationID, expectedRevision: current.revision, transform: { live in
                guard let finalized = finalizeAnchorPatch(patch, live: live) else {
                    return nil
                }
                committedAnchor = finalized.annotation.anchor
                committedProjection = finalized.projection ?? live.anchorProjection
                return finalized
            }
        )
        switch outcome {
        case .updated:
            // Nudges `AnchorTracker` off whatever cadence it had already
            // decayed to, rather than leaving a freshly (re-)anchored or
            // rebaselined target to wait for the timer's own next scheduled
            // tick -- up to its 1 s `.idle` cadence (see that class's doc
            // comment). Only reached on `.updated`, never on a
            // stale/rejected outcome that left the store untouched.
            if anchorPatchShouldKickTracker(patch.anchorIntent) {
                AnchorTracker.shared.kick()
            }
            sendTextResult(id: id, text: updateAnnotationResponseText(
                annotationID: annotationID, anchor: committedAnchor, projection: committedProjection
            ))
        case .notFound:
            sendErrorResult(id: id, text: "Annotation \(annotationID) was not found; it may have been cleared while this update was being prepared.")
        case .stale:
            sendErrorResult(id: id, text: "Annotation \(annotationID) changed while this update was being prepared. It was left unchanged; re-fetch it with list_annotations and retry the patch.")
        case .aborted:
            sendErrorResult(id: id, text: "Annotation \(annotationID) was left unchanged because its live tracked position no longer resolves to a safe sampled window for this re-anchor. Retry after the target window is stable.")
        case .rejected(.payloadBytes(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because retained vector/text payload would become \(attempted) bytes, exceeding the \(limit)-byte session limit. The existing annotation was left unchanged.")
        case .rejected(.primitiveCount(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because retained primitive count would become \(attempted), exceeding the \(limit)-primitive session limit. The existing annotation was left unchanged.")
        case .rejected(.batchNestingDepth(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because its batch nesting depth is \(attempted), exceeding the \(limit)-level safety limit. Flatten nested batches and retry; the existing annotation was left unchanged.")
        case .rejected(.annotationCount(let limit, let attempted)):
            // `updateWithOutcome` replaces an existing annotation in place, so
            // the store's total count never actually changes across an
            // update -- this branch exists only because `AnnotationStoreResourceLimit`
            // is the one shared type `addWithOutcome` and `updateWithOutcome`
            // both return, and the count-cap case Swift requires this switch
            // to handle exhaustively. Worded the same as the others in case a
            // future change ever makes it reachable.
            sendErrorResult(id: id, text: "The update was not applied because it would push the store to \(attempted) annotations, exceeding the \(limit)-annotation session limit. The existing annotation was left unchanged.")
        }
    }

    /// Whether a successfully committed `update_annotation` anchor patch
    /// should nudge `AnchorTracker` with a `kick()` -- split out as a pure
    /// decision, separate from `AnchorTracker.shared` itself, so it is
    /// testable without touching that real singleton's global sampling
    /// state (matching this package's standing "decision separate from the
    /// runtime plumbing" precedent -- see `TargetWindowSelection`/
    /// `PaintedBounds`/`AnnotationVisibilityDiagnostic` for the same split).
    ///
    /// `true` for `.reanchor` and `.changeResizePolicy`: both install a
    /// FRESH reference frame (a newly picked window, or a rebaseline to the
    /// current one), and `AnnotationStore.updateWithOutcome` only fires
    /// `onAnchoredSetChanged` -- which would otherwise restart the tracker's
    /// timer -- on a nil<->non-nil anchor TRANSITION (see that method's own
    /// comment on its `notifyAnchoredSetChanged()` call). Membership
    /// genuinely does NOT change here, so without this kick a tracker that
    /// had already decayed to its 1 s `.idle` cadence could leave the freshly
    /// (re-)anchored target waiting up to a second for its first real sample
    /// against the new reference. This is deliberately a `kick()` (one extra
    /// sample, off the caller's thread) rather than a membership-hook fire:
    /// firing the membership hook instead would also reset cadence
    /// bookkeeping for every OTHER tracked target for no reason, since it
    /// forces `.active` cadence process-wide, not just for this one id.
    ///
    /// `false` for `.detach` (there is no window left to sample) and
    /// `.unchanged` (nothing about tracking changed).
    ///
    /// A brand-new anchored annotation (`draw_*`'s own anchor resolution)
    /// needs no equivalent kick: `AnnotationStore.addWithOutcome` fires
    /// `onAnchoredSetChanged` unconditionally whenever the freshly stored
    /// annotation is anchored (nil -> non-nil is guaranteed for a brand-new
    /// id), which already forces `.active` cadence immediately -- see that
    /// method's own comment.
    func anchorPatchShouldKickTracker(_ intent: AnchorPatchIntent) -> Bool {
        switch intent {
        case .reanchor, .changeResizePolicy: return true
        case .unchanged, .detach: return false
        }
    }

    /// `internal`, not `private`, so it can be exercised directly by
    /// `UpdateAnnotationAnchorTests` -- matching `MCPShapeGeometryTests`'
    /// precedent of calling MCPServer's own pure validation helpers
    /// (`makeShapeKind` et al.) directly rather than only through the live
    /// stdout transport `handleUpdateAnnotation` writes to (see that test
    /// file's header comment on why `send*`-adjacent code is not a usable
    /// test seam).
    func patchedAnnotation(_ current: Annotation, args: [String: Any]) -> DrawOutcome<AnnotationPatchResult> {
        let commonFields: Set<String> = ["annotation_id", "offset_x", "offset_y", "opacity", "z_index", "anchor", "anchor_resize"]
        let kindFields: Set<String>
        switch current.kind {
        case .text:
            kindFields = ["text", "x", "y", "font_size", "color", "background_color", "background_opacity", "padding_px"]
        case .vectorPath:
            kindFields = ["stroke_color", "stroke_width", "stroke_opacity", "fill_color", "fill_opacity"]
        case .image, .batch:
            kindFields = []
        }
        let supplied = Set(args.keys)
        let unsupported = supplied.subtracting(commonFields.union(kindFields))
        guard unsupported.isEmpty else {
            let names = unsupported.sorted().joined(separator: ", ")
            return .failure("These update fields are not supported for a \(current.kind.typeName) annotation: \(names).")
        }
        guard !supplied.subtracting(["annotation_id"]).isEmpty else {
            return .failure("update_annotation requires at least one patch field in addition to annotation_id.")
        }

        // Pure string validation of `anchor`/`anchor_resize`, BEFORE any of
        // the heavier per-kind/process/window work below -- the same
        // "cheap checks first" ordering `DrawRequest.parseAnchorArguments`
        // documents for draw_*, and for the identical reason: a typo'd enum
        // value must never trigger a process lookup only to fail afterward
        // anyway.
        let anchorIntent: AnchorPatchIntent
        switch parseAnchorPatch(args, currentlyAnchored: current.anchor != nil) {
        case .failure(let error): return .failure(error)
        case .success(let intent): anchorIntent = intent
        }

        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["offset_x", "offset_y", "opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        if args.keys.contains("z_index"), MCPArgument.integer(args["z_index"]) == nil {
            return .failure("z_index must be an integer when supplied.")
        }
        let offsetX = MCPArgument.double(args["offset_x"]) ?? current.offsetX
        let offsetY = MCPArgument.double(args["offset_y"]) ?? current.offsetY
        let opacity = MCPArgument.double(args["opacity"]) ?? current.opacity
        guard offsetX.isFinite, offsetY.isFinite,
              abs(offsetX) <= DrawingDefaults.maxCoordinateMagnitudePx,
              abs(offsetY) <= DrawingDefaults.maxCoordinateMagnitudePx else {
            return .failure("offset_x and offset_y must remain within ±\(Int(DrawingDefaults.maxCoordinateMagnitudePx)) backing pixels.")
        }
        guard opacity > 0, opacity <= 1 else {
            return .failure("opacity must be greater than 0 and no greater than 1; fully invisible annotations are rejected.")
        }
        let kind: AnnotationKind
        switch patchKind(current.kind, args: args) {
        case .failure(let error): return .failure(error)
        case .success(let value): kind = value
        }

        // Heavy anchor work (process resolution, window sampling) only NOW
        // -- after every cheap validation above has already passed --
        // mirroring `DrawRequest.finish`'s identical ordering rationale.
        let anchorResolution: AnchorPatchResolution
        switch resolveAnchorPatch(anchorIntent, current: current) {
        case .failure(let error): return .failure(error)
        case .success(let value): anchorResolution = value
        }

        let patched = Annotation(
            id: current.id, screenId: anchorResolution.screenId, kind: kind, colorHex: current.colorHex,
            label: current.label, appId: current.appId, appName: current.appName,
            opacity: opacity,
            offsetX: offsetX, offsetY: offsetY,
            zIndex: MCPArgument.integer(args["z_index"]) ?? current.zIndex,
            anchor: anchorResolution.anchor,
            staticAdjustment: anchorResolution.staticAdjustment,
            createdAt: current.createdAt
        )
        return .success(AnnotationPatchResult(
            annotation: patched, projectionOverride: anchorResolution.projectionOverride, anchorIntent: anchorIntent,
            reanchorContext: anchorResolution.reanchorContext
        ))
    }

    /// MCP_SURFACE.md's literal text for "`anchor_resize` is REJECTED
    /// whenever the effective anchor mode is `"none"`" -- the source document
    /// names THREE trigger conditions for this ONE shared string: an absent
    /// `anchor` (paired here with an UNANCHORED annotation -- an absent
    /// `anchor` on an already-anchored one is `.changeResizePolicy`, not a
    /// rejection), an explicit `anchor="none"`, and `update_annotation`
    /// detaching. All three ship this exact string, "Nothing was drawn"
    /// included, because MCP_SURFACE.md gives one literal for every tool
    /// rather than a per-tool variant.
    private static let anchorResizeRequiresWindowRejection =
        "anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to its anchor window being resized, and there is no anchor window without one. Nothing was drawn; remove anchor_resize, or add anchor=\"window\"."

    /// Validates ONLY the `anchor`/`anchor_resize` argument STRINGS for
    /// `update_annotation` -- no process lookup, no window enumeration.
    /// Mirrors `DrawRequest.parseAnchorArguments`'s "reject before heavier
    /// work" precedent (see that function's doc comment) for the identical
    /// reason. `internal`, not `private`, for the same direct-testability
    /// reason as `patchedAnnotation` above.
    func parseAnchorPatch(_ args: [String: Any], currentlyAnchored: Bool) -> DrawOutcome<AnchorPatchIntent> {
        if args.keys.contains("anchor"), !(args["anchor"] is String) {
            return .failure("anchor must be one of \"none\", \"window\" when supplied.")
        }
        let anchorRaw = args["anchor"] as? String
        if let anchorRaw, anchorRaw != "none", anchorRaw != "window" {
            return .failure("anchor must be one of \"none\", \"window\" when supplied.")
        }
        if args.keys.contains("anchor_resize"), !(args["anchor_resize"] is String) {
            return .failure("anchor_resize must be one of \"pin\", \"scale\" when supplied.")
        }
        let resizeRaw = args["anchor_resize"] as? String
        if let resizeRaw, resizeRaw != "pin", resizeRaw != "scale" {
            return .failure("anchor_resize must be one of \"pin\", \"scale\" when supplied.")
        }
        let resize: AnchorResizeBehavior? = resizeRaw.map { $0 == "scale" ? .scale : .pin }

        switch anchorRaw {
        case "none":
            // `anchor_resize` names a policy for reacting to the anchor
            // window's resize; detaching leaves no anchor window for it to
            // apply to, so supplying it here is unambiguous evidence of an
            // intent this call cannot honour (same reject-over-ignore rule
            // as `DrawRequest.parseAnchorArguments`).
            guard resize == nil else {
                return .failure(Self.anchorResizeRequiresWindowRejection)
            }
            return .success(.detach)
        case "window":
            return .success(.reanchor(resize: resize ?? .pin))
        default:
            // `anchor` was not supplied at all.
            guard let resize else { return .success(.unchanged) }
            guard currentlyAnchored else {
                return .failure(Self.anchorResizeRequiresWindowRejection)
            }
            return .success(.changeResizePolicy(resize: resize))
        }
    }

    /// The impure half of anchor patching: `.reanchor` resolves a running
    /// process and samples its windows. This cannot simply call
    /// `DrawRequest.resolveWindowAnchor` -- that method is `private` to
    /// `DrawRequest` and is shaped around a brand-NEW annotation being
    /// created right now (it takes the draw call's own resolved screen and
    /// freshly parsed `kind`), whereas this call is re-anchoring an EXISTING
    /// annotation from its current, already-adjusted painted position. The
    /// pure decision underneath both (`DrawRequest.buildWindowAnchor`) and
    /// the shared process lookup (`MCPServer.runningProcessIds(forAppId:)`)
    /// ARE reused, so the two paths cannot silently diverge on which window
    /// wins or what gets written into the resulting anchor. `internal`, not
    /// `private`, for the same direct-testability reason as
    /// `patchedAnnotation` above.
    func resolveAnchorPatch(_ intent: AnchorPatchIntent, current: Annotation) -> DrawOutcome<AnchorPatchResolution> {
        switch intent {
        case .unchanged:
            return .success(AnchorPatchResolution(
                screenId: current.screenId, anchor: current.anchor,
                staticAdjustment: current.staticAdjustment, projectionOverride: nil,
                reanchorContext: nil
            ))

        case .detach:
            // DETACH AND FREEZE IN PLACE. Folding the live adjustment into
            // `staticAdjustment` -- rather than simply dropping `anchor` and
            // leaving `staticAdjustment` at whatever it was -- is what keeps
            // `effectiveAdjustment` (and therefore every painted pixel)
            // numerically IDENTICAL immediately before and after this call:
            // see `AnchorAdjustment.concatenating(_:)`'s own doc comment for
            // why composing with `.identity` cannot introduce drift. Also
            // freezes the current EFFECTIVE screen (not the annotation's
            // original `screenId`, which is stale if the tracked window had
            // crossed onto a different display) so the frozen geometry keeps
            // being interpreted on the display it is actually sitting on.
            let frozenAdjustment = current.effectiveAdjustment
            let frozenScreenId = current.effectiveScreenId
            // `updateWithOutcome` carries the OLD `anchorProjection` forward
            // unconditionally (see `AnnotationPatchResult`'s doc comment),
            // which -- left alone -- would double-apply the very adjustment
            // just folded into `staticAdjustment` above (`effectiveAdjustment`
            // = `staticAdjustment.concatenating(anchorProjection.adjustment)`
            // would compose the same delta twice, moving the drawing instead
            // of freezing it). The override is skipped only when there is
            // nothing to neutralize: an annotation that was ALREADY
            // unanchored has no live projection whose composition could
            // double anything.
            let override: AnchorProjection? = current.anchor == nil ? nil : AnchorProjection(
                state: .tracking, adjustment: .identity, effectiveScreenId: frozenScreenId,
                currentWindowFrame: nil, sampledAt: Date(), elementResolutionIssue: nil
            )
            return .success(AnchorPatchResolution(
                screenId: frozenScreenId, anchor: nil,
                staticAdjustment: frozenAdjustment, projectionOverride: override,
                reanchorContext: nil
            ))

        case .reanchor(let resize):
            guard let appId = current.appId else {
                return .failure("anchor=\"window\" cannot be applied to a global annotation: it has no target application whose window to anchor to. Re-create the drawing with an app link, or leave it unanchored.")
            }
            let displayName = current.appName ?? appId
            let pids = MCPServer.shared.runningProcessIds(forAppId: appId)
            guard pids.count == 1, let pid = pids.first else {
                if pids.isEmpty {
                    return .failure("anchor=\"window\" requires \(displayName) to be a running application so its windows can be sampled, but no running process matches. The annotation was left unchanged; bring that application to the front and retry, or omit anchor.")
                }
                return .failure("anchor=\"window\" cannot choose a window for \(displayName) because it has \(pids.count) running processes and anchoring refuses to guess which one owns the intended window. The annotation was left unchanged; quit the extra instance(s) and retry, or omit anchor.")
            }
            let screens = OverlayWindowController.shared.screenSnapshot().screens
            let samples = TargetWindowProbe.shared.windows(forProcessId: pid, screens: screens)
            let frozenAdjustment = current.effectiveAdjustment
            let frozenScreenId = current.effectiveScreenId
            // The window that should win this contest is whichever one the
            // drawing is ACTUALLY over right now -- not where it was
            // originally created, and not its raw stored geometry, which is
            // pre-adjustment. `PaintedBounds.paintedBounds` gives the stored
            // (pre-offset, pre-adjustment) bounds; adding the offset and then
            // applying the CURRENT effective adjustment reproduces exactly
            // what the renderer paints today (see
            // `AnnotationRenderer.drawAnnotations`'s "stored geometry ->
            // + offset -> adjustment" ordering).
            //
            // THIS PICK IS PROVISIONAL. `current` is a snapshot read before
            // this call even started, and `frozenAdjustment` -- therefore
            // `currentPaintedBounds`, therefore WHICH WINDOW WINS -- depends
            // on `current.anchorProjection`, which `AnchorTracker` can
            // overwrite at any moment via `applyAnchorProjections` (a write
            // that deliberately never bumps `revision`, so it cannot fail a
            // caller's CAS). `finalizeAnchorPatch` re-runs the SELECTION
            // half of this same computation against the LIVE annotation,
            // inside `AnnotationStore`'s lock, using `samples` carried
            // forward via `reanchorContext` below -- see that function's doc
            // comment for the full race this closes. Only the ERROR paths
            // computed from this provisional pick (no eligible window, and
            // the app/process checks above) are trusted as final: none of
            // them depend on `current.anchorProjection`, so a racing
            // projection write cannot change their answer.
            let storedBounds = PaintedBounds.paintedBounds(of: current.kind) ?? .zero
            let currentPaintedBounds = frozenAdjustment.apply(
                to: storedBounds.offsetBy(dx: current.offsetX, dy: current.offsetY)
            )
            guard let resolution = DrawRequest.buildWindowAnchor(
                processId: pid, appId: appId, samples: samples,
                paintedBounds: currentPaintedBounds, resize: resize, now: Date(),
                screenId: frozenScreenId, screens: screens
            ) else {
                return .failure("anchor=\"window\" found no eligible on-screen window for \(displayName) (pid \(pid)). The annotation was left unchanged: a window anchor with no window would silently behave like an unanchored drawing. Bring a window of that application on screen and retry, or omit anchor.")
            }
            // Freeze the PRE-re-anchor position into `staticAdjustment`
            // FIRST: `buildWindowAnchor` always starts a fresh anchor's
            // projection at `.identity` (see that function's own doc
            // comment), so without this fold the drawing would snap back to
            // its raw, un-adjusted stored position the instant it re-anchors.
            return .success(AnchorPatchResolution(
                screenId: frozenScreenId, anchor: resolution.anchor,
                staticAdjustment: frozenAdjustment, projectionOverride: resolution.projection,
                reanchorContext: ReanchorWindowContext(processId: pid, appId: appId, resize: resize, samples: samples, screens: screens)
            ))

        case .changeResizePolicy(let resize):
            guard let existingAnchor = current.anchor else {
                // Unreachable: `parseAnchorPatch`'s `currentlyAnchored` guard
                // already rejects this combination before this method is
                // ever called. Kept as an actionable fallback rather than
                // `fatalError`, matching this file's standing preference for
                // failing loudly with text over trapping on a state a future
                // refactor might make reachable by accident.
                return .failure("anchor_resize requires an existing anchor, or anchor=\"window\" in the same call. The annotation was left unchanged.")
            }
            // Re-baselines `referenceWindowFrame`/`referenceScreenId` to the
            // window's CURRENT sampled frame (not its ORIGINAL reference
            // frame) so a resize-policy change does not retroactively
            // reinterpret however much the window has moved/resized since
            // the anchor was created, under the NEW policy -- e.g. switching
            // pin -> scale after the window has doubled in size must not
            // suddenly double the drawing too. `current.anchorProjection` is
            // the tracker's live sample; falling back to the anchor's own
            // reference is only for a hand-built annotation that skipped
            // ever being sampled (see `Annotation.anchorPermitsPainting`'s
            // doc comment -- a real anchor never observes this).
            let referenceFrame = current.anchorProjection?.currentWindowFrame ?? existingAnchor.referenceWindowFrame
            let referenceScreen = current.anchorProjection?.effectiveScreenId ?? existingAnchor.referenceScreenId
            let rebaselined = AnnotationAnchor(
                mode: existingAnchor.mode, resize: resize, target: existingAnchor.target,
                referenceWindowFrame: referenceFrame, referenceScreenId: referenceScreen,
                // The recorded density (see `AnnotationAnchor
                // .referenceScreenScale`) is only carried forward while it
                // still describes the SAME display this re-baseline anchors
                // to; re-baselining onto a different display makes the old
                // recording wrong by exactly the ratio the pin compensation
                // exists to fix, so it is dropped and the tracker's live
                // lookup by referenceScreenId takes over.
                referenceScreenScale: referenceScreen == existingAnchor.referenceScreenId
                    ? existingAnchor.referenceScreenScale : nil,
                element: existingAnchor.element, createdAt: existingAnchor.createdAt
            )
            // Same "freeze then reset to identity against the NEW reference"
            // shape as `.detach`/`.reanchor` above: folding the live
            // adjustment into `staticAdjustment` and reporting a fresh
            // identity projection (reference == current, by construction)
            // keeps `effectiveAdjustment` numerically unchanged RIGHT NOW,
            // and lets the very next tracker tick compute a correct delta
            // from the NEW policy/reference instead of one more tick's worth
            // of stale drift measured under the OLD policy.
            let frozenAdjustment = current.effectiveAdjustment
            let preservedState = current.anchorProjection?.state ?? .tracking
            let override = AnchorProjection(
                state: preservedState, adjustment: .identity, effectiveScreenId: referenceScreen,
                currentWindowFrame: referenceFrame, sampledAt: Date(),
                elementResolutionIssue: current.anchorProjection?.elementResolutionIssue
            )
            return .success(AnchorPatchResolution(
                screenId: current.effectiveScreenId, anchor: rebaselined,
                staticAdjustment: frozenAdjustment, projectionOverride: override,
                reanchorContext: nil
            ))
        }
    }

    /// Re-finalizes an anchor patch's freeze-dependent fields against
    /// `live` -- the annotation `AnnotationStore` is handing this transform
    /// right now, under its OWN lock -- instead of trusting `patch`, which
    /// `patchedAnnotation` built from whatever snapshot
    /// `handleUpdateAnnotation` read BEFORE this commit even started. THIS
    /// IS THE FIX FOR BUG 1: without it, `staticAdjustment`/the projection
    /// override were baked from a stale read, so a tracker sample landing in
    /// the gap between that read and this commit was silently discarded the
    /// instant the old two-write pattern (see `AnnotationPatchResult`'s doc
    /// comment) installed the stale numbers over it.
    ///
    /// Only called from inside `AnnotationStore.updateWithOutcome(id:
    /// expectedRevision:transform:)`'s transform, so it MUST stay pure --
    /// see that method's doc comment for why: no store calls, no
    /// `notifyChange()`, nothing that could call back into the store while
    /// its lock is held.
    ///
    /// `.reanchor`'s WINDOW SELECTION IS RE-RUN HERE, against `live` -- an
    /// earlier version of this comment claimed the opposite ("that resolved
    /// window does not depend on `current.anchorProjection` at all"), and
    /// that claim was wrong, which was BUG 2 in the review that produced
    /// this fix. `resolveAnchorPatch`'s `.reanchor` case picks a window via
    /// `DrawRequest.buildWindowAnchor(paintedBounds:...)`, and
    /// `paintedBounds` there is `current`'s STORED bounds, offset, then run
    /// through `current.effectiveAdjustment` -- which depends on
    /// `current.anchorProjection`. `AnchorTracker` writes projections via
    /// `applyAnchorProjections`, which deliberately never bumps `revision`
    /// (see that method's own doc comment), so such a write CANNOT fail this
    /// call's CAS. The gap it can land in is not microseconds:
    /// `resolveAnchorPatch(.reanchor)` does real I/O before the lock --
    /// `runningProcessIds`, `OverlayWindowController.shared.screenSnapshot()`
    /// (which hops to the main thread), then window sampling -- so
    /// milliseconds. With two overlapping candidate windows, a tracker
    /// sample landing in that gap can move the drawing's true painted
    /// position onto the OTHER window while the pre-lock pick still names
    /// the first one. The pixel position would not jump either way (the
    /// freeze below always uses `live.effectiveAdjustment`), but the
    /// annotation would silently start TRACKING THE WRONG WINDOW from that
    /// point on -- wrong not in position, but in which window's future
    /// moves it follows.
    ///
    /// The fix: `patch.reanchorContext` carries `resolveAnchorPatch`'s
    /// already-sampled `[TargetWindowSample]` (plus the pid/appId/resize
    /// policy) forward from before the lock, and SELECTION alone --
    /// `DrawRequest.buildWindowAnchor` / `TargetWindowSelection
    /// .selectWindow(forRect:among:)`, pure arithmetic over an array already
    /// in hand -- is re-run here against `live`'s CURRENT painted bounds.
    /// That is legal inside this transform precisely because selection is
    /// pure; the SAMPLING that produced the candidate array is not, and it
    /// stays where it already ran, before the lock, in `resolveAnchorPatch`.
    /// `patch`'s pre-lock resolution keeps sole authority over every ERROR
    /// path (no app, app not running, ambiguous pids, no eligible window at
    /// all) -- none of those depend on `current.anchorProjection`, so a
    /// racing projection write cannot change their answer, and they must
    /// still fail before commit with their existing wording.
    ///
    /// One staleness survives this fix, and is not worth chasing: the
    /// sampled window FRAMES inside `reanchorContext.samples` are still
    /// exactly as old as the pre-lock sample that produced them -- a few
    /// milliseconds stale if the winning window itself moved or resized
    /// meanwhile. This is benign and self-correcting: the freshly built
    /// anchor's `referenceWindowFrame` is set from that same sample, so if
    /// the window has since moved, `AnchorTracker`'s very next tick maps
    /// reference -> current and the drawing picks up that movement
    /// correctly on its next paint -- exactly like any other anchored
    /// drawing whose window moves after it was created.
    ///
    /// `.unchanged`/`.detach`/`.changeResizePolicy` never perform I/O at
    /// all, so their entire resolution is simply re-run against `live`
    /// through `resolveAnchorPatch` -- cheap, pure, and the single existing
    /// source of truth for that freeze arithmetic instead of a second copy
    /// of it living here. `resolveAnchorPatch`'s only failure path among
    /// these three (`.changeResizePolicy` when `current.anchor == nil`)
    /// cannot fire here: `AnnotationStore.updateWithOutcome(id:
    /// expectedRevision:transform:)` only calls this transform once its own
    /// compare-and-swap has proven `live` agrees with the snapshot
    /// `patchedAnnotation` validated against on every field a genuine MCP
    /// edit (as opposed to a tracker sample) can change -- `anchor`'s
    /// nil-ness included.
    func finalizeAnchorPatch(
        _ patch: AnnotationPatchResult,
        live: Annotation
    ) -> (annotation: Annotation, projection: AnchorProjection?)? {
        let resolution: AnchorPatchResolution
        if case .reanchor = patch.anchorIntent {
            guard let reanchored = reanchorResolution(patch: patch, live: live) else {
                // The target display may have changed since the pre-lock
                // sample. Never commit its old-display provisional anchor:
                // the optional store transform turns this into an atomic
                // no-op rather than installing a stale cross-display link.
                return nil
            }
            resolution = reanchored
        } else {
            switch resolveAnchorPatch(patch.anchorIntent, current: live) {
            case .success(let value):
                resolution = value
            case .failure:
                // Unreachable in practice -- see this function's own doc
                // comment for why. Falls back to a true no-op (`live`'s own
                // anchor state, untouched) rather than a trap, matching this
                // file's standing preference for failing safe over failing
                // loud on a state a future refactor might make reachable by
                // accident (see `resolveAnchorPatch`'s own
                // `.changeResizePolicy` fallback for the identical
                // precedent).
                resolution = AnchorPatchResolution(
                    screenId: live.effectiveScreenId, anchor: live.anchor,
                    staticAdjustment: live.staticAdjustment, projectionOverride: nil,
                    reanchorContext: nil
                )
            }
        }
        let finalAnnotation = Annotation(
            id: patch.annotation.id, screenId: resolution.screenId, kind: patch.annotation.kind,
            colorHex: patch.annotation.colorHex, label: patch.annotation.label,
            appId: patch.annotation.appId, appName: patch.annotation.appName,
            opacity: patch.annotation.opacity, offsetX: patch.annotation.offsetX, offsetY: patch.annotation.offsetY,
            zIndex: patch.annotation.zIndex, anchor: resolution.anchor, staticAdjustment: resolution.staticAdjustment,
            createdAt: patch.annotation.createdAt
        )
        return (finalAnnotation, resolution.projectionOverride)
    }

    /// `finalizeAnchorPatch`'s `.reanchor` branch: re-runs window SELECTION
    /// against `live`, inside `AnnotationStore`'s lock -- see that
    /// function's doc comment for the full race this closes. Split out as
    /// its own function only for readability; it has no life of its own
    /// outside that one call site.
    private func reanchorResolution(patch: AnnotationPatchResult, live: Annotation) -> AnchorPatchResolution? {
        guard let context = patch.reanchorContext else {
            // A re-anchor cannot be safely reconstructed without its sampled
            // candidates. In particular, using the pre-lock anchor here can
            // bind the live drawing to a different display, so fail closed.
            return nil
        }
        // Same formula `resolveAnchorPatch`'s `.reanchor` case used
        // pre-lock, against `current` -- reproduced here against `live`
        // instead: the renderer's own "stored geometry -> + offset ->
        // adjustment" ordering (see that case's own comment for why).
        let storedBounds = PaintedBounds.paintedBounds(of: live.kind) ?? .zero
        let livePaintedBounds = live.effectiveAdjustment.apply(
            to: storedBounds.offsetBy(dx: live.offsetX, dy: live.offsetY)
        )
        guard let reselected = DrawRequest.buildWindowAnchor(
            processId: context.processId, appId: context.appId, samples: context.samples,
            paintedBounds: livePaintedBounds, resize: context.resize, now: Date(),
            screenId: live.effectiveScreenId, screens: context.screens
        ) else {
            // A tracker sample can change the effective display between the
            // pre-lock pick and this locked re-selection. Since samples are
            // deliberately filtered to the live display, no candidate means
            // there is no safe replacement to commit.
            return nil
        }
        return AnchorPatchResolution(
            screenId: live.effectiveScreenId,
            anchor: reselected.anchor,
            staticAdjustment: live.effectiveAdjustment,
            projectionOverride: reselected.projection,
            reanchorContext: nil
        )
    }

    /// Builds `update_annotation`'s success text: today's exact plain string
    /// when the patched annotation is unanchored (byte-for-byte, matching
    /// `DrawRequest.finish`'s identical "unanchored keeps today's response"
    /// rule -- see that method's own doc comment), or a JSON object carrying
    /// the same message plus the shared `anchor` block (MCP_SURFACE.md's
    /// "Success payload" section) when it is anchored, exactly like
    /// `draw_*`'s own anchored response -- reusing
    /// `DrawRequest.anchorResponsePayload` so the shape can never drift
    /// between tools. `projection` is resolved by the caller (the fresh
    /// override when this call produced one, else whatever was already on
    /// record), never fabricated here.
    private func updateAnnotationResponseText(
        annotationID: String, anchor: AnnotationAnchor?, projection: AnchorProjection?
    ) -> String {
        let baseText = "Updated annotation \(annotationID) in place."
        guard let anchor, let projection else {
            // `projection == nil` alongside a non-nil `anchor` is
            // unreachable for a REAL anchor (see
            // `Annotation.anchorPermitsPainting`'s doc comment: "a real
            // anchor is never observed with a nil projection"); falls back
            // to the plain response rather than fabricating placeholder
            // geometry for a state this type never actually produces on its
            // own.
            return baseText
        }
        let payload: [String: Any] = [
            "message": baseText,
            "annotationId": annotationID,
            "anchor": DrawRequest.anchorResponsePayload(DrawRequest.DrawAnchorResolution(anchor: anchor, projection: projection))
        ]
        guard let jsonText = jsonString(payload) else {
            return "\(baseText) It is anchored, but the anchor metadata failed to encode in this response. Call list_annotations to inspect it."
        }
        return jsonText
    }

    private func patchKind(_ current: AnnotationKind, args: [String: Any]) -> DrawOutcome<AnnotationKind> {
        switch current {
        case let .text(existingText, x, y, fontSize, textColor, backgroundColor, backgroundOpacity, padding, opacity):
            if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["x", "y", "font_size", "background_opacity", "padding_px"]) {
                return .failure("\(key) must be a finite number when supplied.")
            }
            if let key = MCPArgument.firstNonStringSupplied(args, keys: ["text", "color", "background_color"]) {
                return .failure("\(key) must be a string when supplied.")
            }
            let nextText = (args["text"] as? String) ?? existingText
            let nextX = MCPArgument.double(args["x"]) ?? x
            let nextY = MCPArgument.double(args["y"]) ?? y
            let nextFont = MCPArgument.double(args["font_size"]) ?? fontSize
            let nextBackgroundOpacity = MCPArgument.double(args["background_opacity"]) ?? backgroundOpacity
            let nextPadding = MCPArgument.double(args["padding_px"]) ?? padding
            guard !nextText.isEmpty, nextText.count <= DrawingDefaults.maxTextCharacters,
                  nextX.isFinite, nextY.isFinite,
                  abs(nextX) <= DrawingDefaults.maxCoordinateMagnitudePx,
                  abs(nextY) <= DrawingDefaults.maxCoordinateMagnitudePx,
                  nextFont > 0, nextFont <= DrawingDefaults.maxStyleDimensionPx,
                  nextBackgroundOpacity >= 0, nextBackgroundOpacity <= 1,
                  nextPadding >= 0, nextPadding <= DrawingDefaults.maxStyleDimensionPx else {
                return .failure("Updated text must be non-empty; x/y must be within ±\(Int(DrawingDefaults.maxCoordinateMagnitudePx)); font_size must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)); background_opacity must be 0...1; padding_px must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)).")
            }
            guard DrawingDefaults.isWithinTextRenderBudget(
                text: nextText, fontSizePx: nextFont, paddingPx: nextPadding
            ) else {
                return .failure("Text render extent exceeds the safe layout budget. Reduce text length, font_size, or padding_px.")
            }
            let nextBackground: String?
            if let supplied = args["background_color"] as? String {
                nextBackground = supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : supplied
            } else {
                nextBackground = backgroundColor
            }
            let nextTextColor = (args["color"] as? String) ?? textColor
            guard colorHasVisibleAlpha(nextTextColor)
                    || (colorHasVisibleAlpha(nextBackground) && nextBackgroundOpacity > 0) else {
                return .failure("Updated text must have a visible text color or background color after RGBA alpha and opacity are applied.")
            }
            return .success(.text(
                text: nextText, x: nextX, y: nextY,
                fontSize: nextFont, textColorHex: nextTextColor,
                backgroundColorHex: nextBackground, backgroundOpacity: nextBackgroundOpacity,
                paddingPx: nextPadding, opacity: opacity
            ))

        case let .vectorPath(data, strokeColor, strokeWidth, strokeOpacity, fillColor, fillOpacity, dash, fillRule, scaleX, scaleY):
            if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["stroke_width", "stroke_opacity", "fill_opacity"]) {
                return .failure("\(key) must be a finite number when supplied.")
            }
            if let key = MCPArgument.firstNonStringSupplied(args, keys: ["stroke_color", "fill_color"]) {
                return .failure("\(key) must be a string when supplied.")
            }
            let nextWidth = MCPArgument.double(args["stroke_width"]) ?? strokeWidth
            let nextStrokeOpacity = MCPArgument.double(args["stroke_opacity"]) ?? strokeOpacity
            let nextFillOpacity = MCPArgument.double(args["fill_opacity"]) ?? fillOpacity
            let nextStrokeColor: String?
            if let supplied = args["stroke_color"] as? String {
                nextStrokeColor = supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : supplied
            } else {
                nextStrokeColor = strokeColor
            }
            let nextFillColor: String?
            if let supplied = args["fill_color"] as? String {
                nextFillColor = supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : supplied
            } else {
                nextFillColor = fillColor
            }
            guard nextWidth >= 0, nextWidth <= DrawingDefaults.maxStyleDimensionPx,
                  nextStrokeOpacity >= 0, nextStrokeOpacity <= 1,
                  nextFillOpacity >= 0, nextFillOpacity <= 1 else {
                return .failure("stroke_width must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)) and path opacity values must be 0...1.")
            }
            if let suppliedStroke = args["stroke_color"] as? String,
               suppliedStroke.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               nextWidth > 0 {
                return .failure("An empty stroke_color removes the stroke; also set stroke_width to 0 (and retain a visible fill) instead of allowing the renderer fallback color to reappear.")
            }
            guard (colorHasVisibleAlpha(nextStrokeColor) && nextWidth > 0 && nextStrokeOpacity > 0)
                    || (colorHasVisibleAlpha(nextFillColor) && nextFillOpacity > 0) else {
                return .failure("The path must have a visible stroke or a fill with opacity greater than 0.")
            }
            return .success(.vectorPath(
                data: data, strokeColorHex: nextStrokeColor,
                strokeWidth: nextWidth, strokeOpacity: nextStrokeOpacity,
                fillColorHex: nextFillColor, fillOpacity: nextFillOpacity,
                dash: dash, usesEvenOddFillRule: fillRule, coordinateScaleX: scaleX, coordinateScaleY: scaleY
            ))

        case .image, .batch:
            // `patchedAnnotation` rejects kind-specific keys for these kinds;
            // only common offset/opacity/z fields can reach this branch.
            return .success(current)
        }
    }
}
