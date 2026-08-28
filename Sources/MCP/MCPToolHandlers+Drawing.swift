import Foundation

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
            kind: kind, noun: "free-draw raster image"
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
            kind: kind, noun: "text"
        ) {
        case .failure(let err): sendErrorResult(id: id, text: err)
        case .success(let message): sendTextResult(id: id, text: message)
        }
    }

    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleDrawBatch(id: Any, args: [String: Any]) {
        guard let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty,
              rawItems.count <= DrawingDefaults.maxBatchItems else {
            sendErrorResult(id: id, text: "items must contain 1...\(DrawingDefaults.maxBatchItems) path/image/text primitives.")
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
            kind: kind, noun: "atomic free-draw batch (\(components.count) items)"
        ) {
        case .failure(let err): fail(err)
        case .success(let message): sendTextResult(id: id, text: message)
        }
    }

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
        let patched: Annotation
        switch patchedAnnotation(current, args: args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let annotation): patched = annotation
        }
        switch AnnotationStore.shared.updateWithOutcome(
            id: annotationID, with: patched, expectedRevision: current.revision
        ) {
        case .updated:
            sendTextResult(id: id, text: "Updated annotation \(annotationID) in place.")
        case .notFound:
            sendErrorResult(id: id, text: "Annotation \(annotationID) was not found; it may have been cleared while this update was being prepared.")
        case .stale:
            sendErrorResult(id: id, text: "Annotation \(annotationID) changed while this update was being prepared. It was left unchanged; re-fetch it with list_annotations and retry the patch.")
        case .rejected(.payloadBytes(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because retained vector/text payload would become \(attempted) bytes, exceeding the \(limit)-byte session limit. The existing annotation was left unchanged.")
        case .rejected(.primitiveCount(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because retained primitive count would become \(attempted), exceeding the \(limit)-primitive session limit. The existing annotation was left unchanged.")
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

    private func patchedAnnotation(_ current: Annotation, args: [String: Any]) -> DrawOutcome<Annotation> {
        let commonFields: Set<String> = ["annotation_id", "offset_x", "offset_y", "opacity", "z_index"]
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
        let patched = Annotation(
            id: current.id, screenId: current.screenId, kind: kind, colorHex: current.colorHex,
            label: current.label, appId: current.appId, appName: current.appName,
            opacity: opacity,
            offsetX: offsetX, offsetY: offsetY,
            zIndex: MCPArgument.integer(args["z_index"]) ?? current.zIndex,
            createdAt: current.createdAt
        )
        return .success(patched)
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
