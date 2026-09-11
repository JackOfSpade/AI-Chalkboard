import Foundation
#if os(macOS)
import AppKit
#elseif os(Windows)
import WinSDK
#endif

#if os(macOS)
/// The process-id type `AccessibilityElementResolver.resolve(processID:...)`
/// expects on this platform, needed by `resolveExpectationTargetProcess`
/// below (the `expect_element` half of `verify_annotation`'s `expect_*`
/// support). A SEPARATE typealias from `MCPToolHandlers+Highlight.swift`'s
/// own identically-purposed `HighlightProcessID`, not a shared one: that one
/// is declared `private` inside a top-level extension in a DIFFERENT file,
/// and Swift's `private` access control scopes it to that file alone (SE-0169
/// widens `private` only as far as "other extensions of the same type in the
/// SAME file") -- so it is simply invisible here, and duplicating the one-line
/// declaration is the honest alternative to widening that file's access
/// control just for this one caller.
private typealias ExpectationProcessID = pid_t
#elseif os(Windows)
/// `pid_t` does not exist on the Windows Swift toolchain -- see
/// `MCPToolHandlers+Highlight.swift`'s identical `HighlightProcessID`
/// typealias for the confirmed compile error this avoids. `UInt32` is what
/// `AccessibilityElementResolver.resolve(processID:...)`'s Windows overload
/// actually declares.
private typealias ExpectationProcessID = UInt32
#endif

/// A timed-out ScreenCaptureKit operation can complete late (or, in the
/// worst case, never resume). Keep exactly one outstanding capture task so a
/// caller cannot turn repeated 30-second timeouts into an unbounded pile of
/// detached framework work. The task, not the waiting request, releases this
/// gate when it genuinely finishes.
final class CaptureFlightGate: @unchecked Sendable {
    static let shared = CaptureFlightGate()
    private let lock = NSLock()
    private var inFlight = false

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        inFlight = false
    }
}

/// Whether an anchored annotation's tracked window moved between two
/// `AnchorProjection` samples -- pure equality, but pulled out to its own
/// tiny, directly-testable unit rather than an inline `!=` at the one call
/// site, matching this file's existing "decision separate from the
/// MCP/AppKit plumbing" precedent (`AnnotationVerificationCompositor
/// .screenshotDisplayMismatchRejection`, `ambiguousDisplayRejection`).
enum AnchorMovementDetector {
    /// `true` means the tracker's live projection changed somewhere between
    /// `before` and `after` -- a different `currentWindowFrame`, a different
    /// `adjustment`, or a state transition such as `.tracking` -> `.hidden` --
    /// so geometry rendered against `before` may already describe a stale
    /// placement. This is EVIDENCE, not a failure: see
    /// `handleVerifyAnnotation`'s use of this for why an agent must not treat
    /// `true` as an error to retry against.
    static func moved(before: AnchorProjection?, after: AnchorProjection?) -> Bool {
        before != after
    }
}

extension MCPServer {
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleVerifyAnnotation(id: Any, args: [String: Any]) {
        guard let annotationId = (args["annotation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !annotationId.isEmpty else {
            sendErrorResult(id: id, text: "Missing required parameter: annotation_id")
            return
        }
        if args.keys.contains("screenshot_path"), !(args["screenshot_path"] is String) {
            sendErrorResult(id: id, text: "screenshot_path must be a string when supplied.")
            return
        }
        if args.keys.contains("capture_source"), !(args["capture_source"] is String) {
            sendErrorResult(id: id, text: "capture_source must be 'chalkboard' or 'none' when supplied.")
            return
        }
        if args.keys.contains("request_permission"), MCPArgument.bool(args["request_permission"]) == nil {
            sendErrorResult(id: id, text: "request_permission must be a boolean when supplied.")
            return
        }
        if args.keys.contains("screenshot_screen_id"), !(args["screenshot_screen_id"] is String) {
            sendErrorResult(id: id, text: "screenshot_screen_id must be a string when supplied.")
            return
        }
        if args.keys.contains("screenshot_space"), !(args["screenshot_space"] is String) {
            sendErrorResult(id: id, text: "screenshot_space must be a string id (as returned by register_screenshot_space or calibrate_screenshot_space) when supplied.")
            return
        }
        let screenshotPath = (args["screenshot_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureSource = (args["capture_source"] as? String)?.lowercased()
        // The caller's ASSERTION of which display the supplied
        // `screenshot_path` image was captured from -- identity evidence a
        // raster image simply does not carry (see
        // `AnnotationVerificationCompositor.ambiguousDisplayRejection`).
        let screenshotScreenId = (args["screenshot_screen_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The `screenshot_space` id string itself, kept as a local
        // (untouched by `ScreenshotSpaceExpansion.expand`, which is only
        // called further below once `screen` is known) purely so every
        // guard in this function that needs to know "was a space named at
        // all" can ask a plain `!= nil` question instead of re-deriving the
        // JSON-null-aware `isSupplied` rule at each call site.
        let screenshotSpaceId = (args["screenshot_space"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard screenshotPath?.isEmpty != true else {
            sendErrorResult(id: id, text: "screenshot_path cannot be empty when supplied.")
            return
        }
        guard screenshotScreenId?.isEmpty != true else {
            sendErrorResult(id: id, text: "screenshot_screen_id cannot be empty when supplied.")
            return
        }
        guard !(screenshotPath != nil && captureSource != nil) else {
            sendErrorResult(id: id, text: "screenshot_path and capture_source are mutually exclusive. Supply one clean screenshot source.")
            return
        }
        // By this point the mutual-exclusivity guard above has already forced
        // captureSource to nil whenever screenshotPath is non-nil, so the only
        // way to reach this guard with a non-nil captureSource is
        // screenshotPath == nil -- meaning an invalid capture_source (any
        // string other than "chalkboard"/"none") is already rejected right
        // here, with no further "captureSource != 'chalkboard'/'none'"
        // branch reachable afterward.
        //
        // "none" is the permission-free renderer-geometry verdict (see
        // `handleVerifyAnnotationGeometry` below) -- naming it HERE, in the
        // one rejection every caller who never supplies screenshot_path or
        // capture_source will see, is the single most important
        // discoverability fix in this change: that path already half-existed
        // via get_annotation_bounds, and callers denied Screen Recording had
        // no way to learn about it from this error alone.
        guard screenshotPath != nil || captureSource == "chalkboard" || captureSource == "none" else {
            sendErrorResult(id: id, text: AnnotationBoundsSupport.missingCaptureSourceRejection)
            return
        }
        if args.keys.contains("request_permission"), captureSource != "chalkboard" {
            sendErrorResult(id: id, text: "request_permission is only valid with capture_source='chalkboard'.")
            return
        }
        // The mirror image of the guard immediately above, and rejected rather
        // than ignored for the same reason: a caller that supplies
        // `screenshot_screen_id` alongside `capture_source` believes it is
        // steering which display gets verified. It is not -- Chalkboard
        // capture photographs the annotation's OWN display by construction --
        // so silently dropping the argument would leave that belief intact
        // and untested. This still applies to capture_source='none': there is
        // no picture at all in that verdict, so naming a display for one is
        // equally meaningless.
        if screenshotPath == nil, screenshotScreenId != nil {
            sendErrorResult(id: id, text: "screenshot_screen_id is only meaningful with screenshot_path: capture_source='chalkboard'/'none' both work against the annotation's OWN display, so there is no other display the image could be of. Nothing was verified; remove screenshot_screen_id.")
            return
        }
        // `screenshot_space` IS meaningful for capture_source='none' (it
        // supplies the screenshot pixel grid `paintedBoundsScreenshotPx`/
        // `screenshotScale`/`expect`'s target_bounds_screenshot_px are
        // measured in -- see `handleVerifyAnnotationGeometry`) and for
        // screenshot_path (it supplies `screenshot_screen_id`, checked
        // below). It is NOT meaningful for capture_source='chalkboard':
        // Chalkboard's own capture already returns the composited image
        // itself, at its own actual pixel size, with no separate pixel grid
        // to project bounds into -- so a space named here would be silently
        // ignored rather than doing anything, which this file rejects
        // instead, matching the identical `screenshot_screen_id` rule above.
        if captureSource == "chalkboard", screenshotSpaceId != nil {
            sendErrorResult(id: id, text: "screenshot_space is only meaningful with screenshot_path or capture_source='none': capture_source='chalkboard' returns the composited image itself at its own real pixel size, so there is no separate screenshot pixel grid to project bounds into. Nothing was verified; remove screenshot_space.")
            return
        }
        // `padding_px` widens the CROPPED IMAGE a composite returns.
        // capture_source='none' produces no image at all, so a padding value
        // would have nothing to pad -- silently accepting and ignoring it
        // would leave a caller believing it took effect.
        if captureSource == "none", args.keys.contains("padding_px") {
            sendErrorResult(id: id, text: "padding_px only applies to a composited screenshot image; capture_source='none' produces no image to pad. Nothing was verified; remove padding_px, or use screenshot_path/capture_source='chalkboard' for a padded composite.")
            return
        }
        if MCPArgument.hasInvalidSuppliedDouble(args, key: "padding_px") {
            sendErrorResult(id: id, text: "padding_px must be a finite number when supplied.")
            return
        }
        let padding = MCPArgument.double(args["padding_px"]) ?? AnnotationVerificationCompositor.defaultPaddingPx
        guard padding >= 0, padding <= AnnotationVerificationCompositor.maxPaddingPx else {
            sendErrorResult(id: id, text: "padding_px must be between 0 and \(Int(AnnotationVerificationCompositor.maxPaddingPx)).")
            return
        }
        guard let renderSnapshot = AnnotationStore.shared.renderSnapshot(id: annotationId) else {
            sendErrorResult(id: id, text: "Annotation \(annotationId) was not found. It may already have been cleared; call list_annotations for a current ID.")
            return
        }
        let annotation = renderSnapshot.annotation
        // The projection as it stood when this render started -- compared
        // against a fresh read taken after compositing finishes, below, to
        // detect whether the window moved mid-verification. See
        // `anchorMovedDuringVerification`'s assignment for why this has to
        // be read now, before any rendering or (for `capture_source=
        // 'chalkboard'`) a capture that can itself take up to 30 seconds.
        let anchorProjectionBeforeCompositing = annotation.anchorProjection
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        // EFFECTIVE screen, not the creation screen: an anchored annotation
        // whose tracked window has crossed onto another display now paints
        // THERE (see `Annotation.effectiveScreenId`'s doc comment), and that
        // is the display whose screenshot can actually verify it.
        let effectiveScreenId = annotation.effectiveScreenId
        guard let screen = snapshot.screens.first(where: { $0.id == effectiveScreenId }) else {
            sendErrorResult(id: id, text: "Annotation \(annotationId)'s current display (\(effectiveScreenId)) is no longer connected. Nothing was rendered.")
            return
        }

        // `screenshot_space`, expanded into `screen_id`/`screenshot_width`/
        // `screenshot_height` via the SAME `ScreenshotSpaceExpansion.expand`
        // every draw_* call and get_annotation_bounds already use -- see
        // that type's own doc comment for why expansion, not a second
        // parallel check, is what keeps a referenced space and a
        // hand-declared call agreeing. Only reached when captureSource is
        // nil (screenshot_path branch) or "none": "chalkboard" already
        // rejected a supplied screenshot_space above.
        var spaceScreenId: String?
        var spaceWidthPx: Int?
        var spaceHeightPx: Int?
        if screenshotSpaceId != nil {
            switch ScreenshotSpaceExpansion.expand(
                args: args,
                lookup: { ScreenshotSpaceRegistry.shared.lookup(id: $0) },
                currentScreen: { snapshot.resolve($0) }
            ) {
            case .failure(let error):
                sendErrorResult(id: id, text: error)
                return
            case .success(let value):
                spaceScreenId = value["screen_id"] as? String
                spaceWidthPx = value["screenshot_width"] as? Int
                spaceHeightPx = value["screenshot_height"] as? Int
            }
        }

        if captureSource == "none" {
            // `ScreenshotSpaceExpansion` only knows the space's OWN recorded
            // screenId -- it has no way to know which display THIS
            // annotation actually lives on. A screenshot_space registered
            // for a DIFFERENT display describes a picture of a different
            // monitor: scaling this annotation's backing-pixel bounds by
            // that space's scale would silently answer "where would this be
            // in a screenshot of a display this annotation is not even on".
            // Symmetric with get_annotation_bounds's identical guard (see
            // `AnnotationBoundsSupport.isScreenshotSpaceSupplied`'s doc
            // comment there).
            if let spaceScreenId, spaceScreenId != screen.id {
                sendErrorResult(id: id, text: AnnotationBoundsSupport.screenshotSpaceDisplayMismatchRejection(
                    toolName: "verify_annotation", annotationId: annotationId,
                    spaceId: screenshotSpaceId ?? "?", spaceScreenId: spaceScreenId, annotationScreenId: screen.id
                ))
                return
            }
            handleVerifyAnnotationGeometry(
                id: id, args: args, annotation: annotation, screen: screen, snapshot: snapshot,
                renderSnapshot: renderSnapshot, anchorProjectionBeforeCompositing: anchorProjectionBeforeCompositing,
                screenshotSpaceId: screenshotSpaceId, spaceWidthPx: spaceWidthPx, spaceHeightPx: spaceHeightPx
            )
            return
        }

        // Which connected displays must the caller's screenshot be
        // disambiguated against? EMPTY whenever that question is already
        // answered -- by `capture_source='chalkboard'` (Chalkboard captures
        // the annotation's own display) or by a `screenshot_screen_id` that
        // has been checked against the annotation's display just below. Only
        // the "a screenshot arrived and nobody said what it is a picture of"
        // case hands the compositor the full connected-screen list, because
        // only that case can be ambiguous. The check itself lives in the
        // compositor, next to the decode that learns the image's real
        // dimensions -- see `AnnotationVerificationCompositor.composite`'s
        // `ambiguityCandidateScreens` parameter for why probing them here
        // instead would open a second-open TOCTOU gap.
        var ambiguityCandidateScreens: [ScreenInfo] = []
        if screenshotPath != nil {
            // `screenshot_space` and an explicit `screenshot_screen_id` are
            // two different ways to assert the SAME fact -- which display
            // screenshot_path is a picture of. Both supplied and AGREEING is
            // a harmless restatement; both supplied and DISAGREEING is a
            // contradiction rejected outright, same as every other pair of
            // arguments in this file that can name conflicting answers to
            // one question rather than silently preferring one.
            var effectiveScreenshotScreenId = screenshotScreenId
            if let spaceScreenId {
                if let screenshotScreenId {
                    guard snapshot.resolve(screenshotScreenId)?.id == spaceScreenId else {
                        sendErrorResult(id: id, text: "screenshot_screen_id '\(screenshotScreenId)' conflicts with screenshot_space '\(screenshotSpaceId ?? "?")', which is registered for display \(spaceScreenId). Nothing was verified; supply only one, or make them name the same display.")
                        return
                    }
                }
                effectiveScreenshotScreenId = spaceScreenId
            }
            if let screenshotScreenId = effectiveScreenshotScreenId {
                // Resolved through the SAME `ScreenSnapshot.resolve` every
                // `screen_id` goes through (exact display id first, then an
                // in-bounds positional index), so a caller can spell this
                // argument exactly as it spells `screen_id` on the draw call
                // that created the annotation.
                guard let assertedScreen = snapshot.resolve(screenshotScreenId) else {
                    sendErrorResult(id: id, text: "Unknown screenshot_screen_id. Nothing was verified; call get_screens and use a current display id or in-bounds index, naming the display the screenshot was actually taken from.")
                    return
                }
                // The whole point of the argument. The refusal text itself
                // lives beside the ambiguity guard it belongs with (see
                // `AnnotationVerificationCompositor
                // .screenshotDisplayMismatchRejection`), which is also what
                // makes it testable without MCP transport.
                if let mismatch = AnnotationVerificationCompositor.screenshotDisplayMismatchRejection(
                    annotationId: annotationId,
                    annotationScreenId: screen.id,
                    screenshotScreenId: assertedScreen.id
                ) {
                    Logger.shared.log(
                        "Verification rejected: reason=screenshot_display_mismatch annotationScreenId=\(screen.id) screenshotScreenId=\(assertedScreen.id)",
                        level: "WARN"
                    )
                    sendErrorResult(id: id, text: mismatch)
                    return
                }
            } else {
                ambiguityCandidateScreens = snapshot.screens
            }
        }

        do {
            let composite: AnnotationVerificationComposite
            var sourceMetadata: [String: Any] = [:]
            if let screenshotPath {
                composite = try AnnotationVerificationCompositor.composite(
                    annotation: annotation, screen: screen, screenshotPath: screenshotPath,
                    paddingPx: padding, rasterLease: renderSnapshot.rasterLease,
                    ambiguityCandidateScreens: ambiguityCandidateScreens
                )
                sourceMetadata["captureSource"] = "caller_screenshot_path"
            } else {
                // The handler waits for the single capture before it sends a
                // response.  MCP stdout writes are intentionally serialized by
                // the read loop; returning later from an unstructured Task
                // could interleave a large base64 image with a later response.
                let capture = try captureSynchronously(
                    screen: screen,
                    requestPermission: MCPArgument.bool(args["request_permission"]) ?? false
                )
                composite = try AnnotationVerificationCompositor.composite(
                    annotation: annotation, screen: screen, screenshot: capture.image,
                    paddingPx: padding, rasterLease: renderSnapshot.rasterLease
                )
                sourceMetadata["captureSource"] = "chalkboard"
                sourceMetadata["captureExcludedProcessIDs"] = capture.excludedProcessIDs.map(Int.init)
                sourceMetadata["captureExclusionScope"] = jsonObject(capture.exclusionScope) ?? NSNull()
                sourceMetadata["captureNote"] = capture.exclusionScope.note
            }
            var metadata = composite.metadata
            for (key, value) in sourceMetadata { metadata[key] = value }
            metadata["appId"] = jsonValue(annotation.appId)
            metadata["appName"] = jsonValue(annotation.appName)
            // Reuses DrawRequest.anchorResponsePayload so this tool's `anchor`
            // object is byte-for-byte the same shape draw_*/highlight_element/
            // update_annotation/list_annotations/get_annotation_bounds already
            // emit. Built from the SNAPSHOT taken before compositing, matching
            // what the composited image itself actually depicts -- see
            // `anchorMovedDuringVerification` just below for whether that has
            // since gone stale.
            if let anchor = annotation.anchor, let projection = anchorProjectionBeforeCompositing {
                metadata["anchor"] = DrawRequest.anchorResponsePayload(
                    DrawRequest.DrawAnchorResolution(anchor: anchor, projection: projection)
                )
                // The tracker samples on its own cadence independent of this
                // call, so the anchored window can move between the moment
                // this render started and the moment compositing (screenshot
                // decode/main-thread render, or up to a 30-second Chalkboard
                // capture) actually finishes. `true` here is EVIDENCE for the
                // caller to interpret, NOT a failure: it means the reported
                // `paintedBoundsScreenshotPx` already describes a placement
                // that has changed, because the user is dragging or resizing
                // the anchor window right now. An agent that treats this as
                // an error and retries in a loop will simply keep re-catching
                // a window still in motion; the correct response is to wait
                // for the drag/resize to settle (or re-verify once
                // `anchor.state` in a fresh `list_annotations`/draw response
                // shows a stable `currentWindowFrame`) rather than treating
                // the number itself as wrong.
                metadata["anchorMovedDuringVerification"] = AnchorMovementDetector.moved(
                    before: anchorProjectionBeforeCompositing,
                    after: AnnotationStore.shared.get(id: annotationId)?.anchorProjection
                )
            }
            let visibility = AnnotationVisibilityDiagnostic(
                annotationsSuspended: OverlayWindowController.shared.isAnnotationsSuspended,
                captureVisible: OverlayWindowController.shared.isCaptureVisible,
                annotationAppId: annotation.appId,
                activeAppId: ActiveAppTracker.shared.currentAppId,
                anchorPermitsPainting: annotation.anchorPermitsPainting
            )
            metadata["annotationsSuspended"] = visibility.annotationsSuspended
            metadata["wouldBeVisibleWithoutSuspension"] = visibility.wouldBeVisibleWithoutSuspension
            metadata["isVisibleNow"] = visibility.isVisibleNow
            // `expect_element`/`expect_window`/`target_bounds_screenshot_px`
            // are meaningful here too, not only under capture_source="none":
            // the comparison is PURE GEOMETRY (the live renderer's painted
            // bounds versus a resolved target's bounds) that does not depend
            // on how the painted side's pixels were obtained, so the same
            // resolution/comparison code applies whether or not this
            // response ALSO happens to carry a composited proof image
            // alongside it. See `resolveExpectationVerdict`'s doc comment.
            //
            // `target_bounds_screenshot_px` needs a screenshot-pixel scale
            // to convert from; on THIS path (screenshot_path/chalkboard) the
            // compositor already measured/captured the real image and put
            // its scale in `metadata["scaleToScreenshot"]` -- the STRONGEST
            // available evidence (a measured/captured pixel size beats a
            // declared screenshot_space), so it is reused here rather than
            // requiring a redundant screenshot_space on top of an image
            // already being composited.
            let compositeScreenshotScale: (x: Double, y: Double)?
            if let scaleDict = metadata["scaleToScreenshot"] as? [String: Double],
               let sx = scaleDict["x"], let sy = scaleDict["y"] {
                compositeScreenshotScale = (sx, sy)
            } else {
                compositeScreenshotScale = nil
            }
            switch resolveExpectationVerdict(
                args: args, annotation: annotation, screen: screen, snapshot: snapshot,
                rasterLease: renderSnapshot.rasterLease, precomputedPaintedBoundsBacking: nil,
                screenshotToBackingScale: compositeScreenshotScale
            ) {
            case .failure(let error):
                sendErrorResult(id: id, text: error)
                return
            case .success(let expectPayload):
                if let expectPayload {
                    metadata["expect"] = expectPayload
                }
            }
            // Threshold the ENCODED bytes directly instead of round-tripping
            // through JSONSerialization first. Stored geometry is caller-sized
            // -- a persistent batch can hold megabytes of SVG -- and it is
            // being measured against a 16 KiB budget, so the oversized branch
            // used to build a full Foundation object graph and re-serialize it
            // to a String purely to discard all of it. Only the branch that
            // actually embeds the geometry needs that object.
            //
            // When encoding fails, `geometryData` is nil and the byte count is
            // 0, which lands on the small path and stores JSON null -- exactly
            // what the previous `jsonObject(...) ?? NSNull()` spelling did.
            let geometryData = try? JSONEncoder().encode(annotation.kind)
            let rawGeometryBytes = geometryData?.count ?? 0
            if rawGeometryBytes <= 16 * 1_024 {
                metadata["storedGeometry"] = geometryData
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            } else {
                metadata["storedGeometry"] = [
                    "omitted": true,
                    "byteCount": rawGeometryBytes,
                    "note": "Stored geometry is omitted from verification metadata to preserve the bounded 8 MiB MCP response. list_annotations may provide a bounded summary; this verification image remains an exact render."
                ]
            }
            metadata["storedGeometryCoordinateSemantics"] = storedGeometryCoordinateSemantics(annotation.kind)
            guard let metadataText = jsonString(metadata) else {
                sendErrorResult(id: id, text: "Failed to encode verification metadata.")
                return
            }
            guard metadataText.lengthOfBytes(using: .utf8) <= AnnotationVerificationCompositor.maxTransportOverheadBytes else {
                sendErrorResult(id: id, text: "Verification metadata exceeded its bounded transport reserve; the annotation was not rendered into an MCP response.")
                return
            }
            sendImageResult(id: id, metadataText: metadataText, imageData: composite.pngData)
        } catch {
            // Persist only fixed reason codes and numeric geometry. The
            // localized error text may contain caller/UI labels or local path
            // details and must remain in the live MCP response, not on disk.
            if let verificationError = error as? AnnotationVerificationError {
                switch verificationError {
                case .aspectRatioMismatch(let scaleX, let scaleY):
                    Logger.shared.log(
                        "Verification rejected: reason=aspect_ratio_mismatch annotationScreenWidth=\(screen.widthPx) annotationScreenHeight=\(screen.heightPx) screenshotScaleX=\(scaleX) screenshotScaleY=\(scaleY)",
                        level: "WARN"
                    )
                case .annotationPaintedNothing(let width, let height):
                    Logger.shared.log(
                        "Verification rejected: reason=annotation_painted_nothing screenWidth=\(width) screenHeight=\(height)",
                        level: "WARN"
                    )
                case .ambiguousScreenshotDisplay(let width, let height, let acceptingScreenIds, _):
                    // Display ids and pixel counts only -- no caller path, no
                    // UI labels -- keeping this line inside the same
                    // fixed-reason-code discipline as the two above. Mirrors
                    // the draw path's `reason=ambiguous_screenshot_display`.
                    Logger.shared.log(
                        "Verification rejected: reason=ambiguous_screenshot_display screenshotWidth=\(width) screenshotHeight=\(height) acceptingScreenCount=\(acceptingScreenIds.count) annotationScreenId=\(screen.id)",
                        level: "WARN"
                    )
                default:
                    Logger.shared.log("Verification rejected: reason=render_or_input_error", level: "WARN")
                }
            }
            // A missing Screen Recording grant must stay a LOUD, actionable
            // error -- never a silent fallback to renderer geometry labelled
            // as if it were the same kind of proof (design rule 2: a caller
            // that asked for pixel proof must not receive geometry instead
            // without being told). What this rewording adds is
            // DISCOVERABILITY: `ScreenCaptureProviderError.permissionDenied`'s
            // own message (Sources/Overlay/ScreenCaptureProvider.swift,
            // outside this file's ownership) correctly explains how to GRANT
            // the permission, but says nothing about the two paths that need
            // no grant at all -- so a caller stuck without Screen Recording
            // access had to already know capture_source='none' existed to
            // try it. Appending, rather than replacing, keeps the original
            // System-Settings instructions intact for a caller who does
            // intend to grant the permission.
            if let captureError = error as? ScreenCaptureProviderError, case .permissionDenied = captureError {
                sendErrorResult(id: id, text: error.localizedDescription + " " + AnnotationBoundsSupport.permissionDeniedDiscoverabilityAddendum)
                return
            }
            sendErrorResult(id: id, text: error.localizedDescription)
        }
    }

    private func captureSynchronously(screen: ScreenInfo, requestPermission: Bool) throws -> ScreenCaptureResult {
        final class ResultBox {
            private let lock = NSLock()
            private var result: Result<ScreenCaptureResult, Error>?

            func set(_ value: Result<ScreenCaptureResult, Error>) {
                lock.lock(); defer { lock.unlock() }
                result = value
            }

            func take() -> Result<ScreenCaptureResult, Error>? {
                lock.lock(); defer { lock.unlock() }
                return result
            }
        }
        guard CaptureFlightGate.shared.tryAcquire() else {
            throw ScreenCaptureProviderError.captureFailed("another Chalkboard capture is still in progress or winding down after a timeout; retry after it completes")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = Task.detached(priority: .userInitiated) {
            defer { CaptureFlightGate.shared.release() }
            do {
                box.set(.success(try await ScreenCaptureProvider.shared.capture(screen: screen, requestPermission: requestPermission)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        let timeout: DispatchTimeInterval = .seconds(30)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw ScreenCaptureProviderError.captureFailed("capture timed out after 30 seconds")
        }
        guard let result = box.take() else {
            throw ScreenCaptureProviderError.captureFailed("capture task completed without a result")
        }
        return try result.get()
    }

    /// `verify_annotation`'s `capture_source="none"` verdict: a
    /// PERMISSION-FREE, CAPTURE-FREE geometry answer. Split out of
    /// `handleVerifyAnnotation` (rather than left as one more branch inside
    /// it) because this is a genuinely different response SHAPE, not a
    /// variant of the same one: a bare JSON payload via `sendTextResult`,
    /// never an image via `sendImageResult` -- there is no image on this
    /// path at all.
    ///
    /// This shares the EXACT permission-free mechanism
    /// `get_annotation_bounds` already uses --
    /// `AnnotationVerificationCompositor.renderedPaintedBounds`, reached via
    /// the `renderSnapshot` `AnnotationStore.shared.renderSnapshot(id:)`
    /// already produced in `handleVerifyAnnotation` -- never
    /// `ScreenCaptureProvider`, so it needs no Screen Recording grant and
    /// touches no capture API of any kind. See that method's own doc
    /// comment for the "touches no capture API" contract this depends on.
    private func handleVerifyAnnotationGeometry(
        id: Any,
        args: [String: Any],
        annotation: Annotation,
        screen: ScreenInfo,
        snapshot: ScreenSnapshot,
        renderSnapshot: (annotation: Annotation, rasterLease: RasterAssetStore.Lease),
        anchorProjectionBeforeCompositing: AnchorProjection?,
        screenshotSpaceId: String?,
        spaceWidthPx: Int?,
        spaceHeightPx: Int?
    ) {
        let paintedBoundsBacking: CGRect?
        do {
            // NO screen capture, NO Screen Recording permission: renders the
            // annotation alone into an offscreen transparent bitmap and
            // scans it for non-transparent pixels. See
            // `renderedPaintedBounds`'s own doc comment for the full
            // "touches no capture API" contract.
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
            "paintedBoundsBackingPx": AnnotationBoundsSupport.rectPayload(paintedBoundsBacking),
            // `renderedPaintedBounds` is display-local backing pixels with
            // origin (0,0) -- exactly what `clippedAtScreenEdge` requires;
            // see that function's doc comment for why that requirement
            // matters and why this is the source it names.
            "onScreenClipped": AnnotationGeometryVerdict.clippedAtScreenEdge(
                painted: paintedBoundsBacking, screenWidthPx: screen.widthPx, screenHeightPx: screen.heightPx
            )
        ]

        // A referenced screenshot_space supplies the ONLY screenshot pixel
        // grid this permission-free path can know about -- there is no
        // image here to measure, unlike the screenshot_path/chalkboard
        // paths. Absent one, this stays backing-pixels-only, exactly like
        // get_annotation_bounds without screenshot_width/screenshot_height.
        var screenshotToBackingScale: (x: Double, y: Double)?
        if let spaceWidthPx, let spaceHeightPx {
            let scaleX = Double(spaceWidthPx) / Double(screen.widthPx)
            let scaleY = Double(spaceHeightPx) / Double(screen.heightPx)
            payload["screenshotScale"] = ["x": scaleX, "y": scaleY]
            payload["paintedBoundsScreenshotPx"] = AnnotationBoundsSupport.rectPayload(
                AnnotationBoundsSupport.screenshotRect(backingRect: paintedBoundsBacking, scale: (scaleX, scaleY))
            )
            if let screenshotSpaceId {
                payload["screenshotSpace"] = screenshotSpaceId
            }
            screenshotToBackingScale = (scaleX, scaleY)
        }

        // Reuses DrawRequest.anchorResponsePayload so this tool's `anchor`
        // object is byte-for-byte the same shape draw_*/highlight_element/
        // update_annotation/list_annotations/get_annotation_bounds already
        // emit. Built from the projection captured BEFORE this render, same
        // discipline `handleVerifyAnnotation`'s composited paths follow.
        if let anchor = annotation.anchor, let projection = anchorProjectionBeforeCompositing {
            payload["anchor"] = DrawRequest.anchorResponsePayload(
                DrawRequest.DrawAnchorResolution(anchor: anchor, projection: projection)
            )
        }

        // `evidenceLevel` and the prose sentence are shared VERBATIM with
        // `get_annotation_bounds` (`AnnotationBoundsSupport
        // .rendererGeometryEvidenceSentence`) -- both tools report the exact
        // same kind of answer here, and repeating the sentence by hand in a
        // second file is exactly the drift this package's reuse discipline
        // exists to prevent.
        payload["evidenceLevel"] = "renderer_geometry"
        var evidence = AnnotationBoundsSupport.rendererGeometryEvidenceSentence(
            screenId: screen.id, screenWidthPx: screen.widthPx, screenHeightPx: screen.heightPx
        )
        if let disclosure = AnnotationBoundsSupport.notPaintedDisclosure(
            isAnchored: annotation.anchor != nil, state: annotation.anchorProjection?.state
        ) {
            evidence += disclosure
        }
        payload["evidence"] = evidence

        switch resolveExpectationVerdict(
            args: args, annotation: annotation, screen: screen, snapshot: snapshot,
            rasterLease: renderSnapshot.rasterLease, precomputedPaintedBoundsBacking: paintedBoundsBacking,
            screenshotToBackingScale: screenshotToBackingScale
        ) {
        case .failure(let error):
            sendErrorResult(id: id, text: error)
            return
        case .success(let expectPayload):
            if let expectPayload {
                payload["expect"] = expectPayload
            }
        }

        guard let text = jsonString(payload) else {
            sendErrorResult(id: id, text: "Failed to encode verification geometry.")
            return
        }
        sendTextResult(id: id, text: text)
    }

    /// The pure DECISION half of `expect_element`/`expect_window`/
    /// `target_bounds_screenshot_px`: resolves whichever ONE was supplied to
    /// a target rectangle in `screen`'s backing pixels, compares it against
    /// the annotation's own painted bounds via
    /// `AnnotationGeometryVerdict.compare`, and returns the MCP `expect`
    /// payload. `.success(nil)` means no expectation was supplied at all --
    /// this is an OPTIONAL addition to every `verify_annotation` response,
    /// not a new required argument.
    ///
    /// DELIBERATELY available on EVERY `capture_source`/`screenshot_path`
    /// path, not only `capture_source="none"`: the comparison is
    /// `AnnotationGeometryVerdict.compare`, pure geometry between two
    /// rectangles that are already known once resolved, and neither
    /// rectangle's resolution depends on how (or whether) a screenshot was
    /// captured. Gating it to `capture_source="none"` only would have meant
    /// a caller composing a real screenshot proof could not ALSO ask "and
    /// does this land on the control I meant?" in the same call -- exactly
    /// the question this whole feature exists to answer. See
    /// `AnnotationGeometryVerdict`'s own doc comment for why this is still
    /// geometry, not itself proof any pixel reached a framebuffer, even when
    /// it rides alongside a composited image that IS such proof.
    ///
    /// The comparison always runs in `screen`'s BACKING pixels: `expect_element`/
    /// `expect_window` resolve directly into that space already,
    /// `target_bounds_screenshot_px` is converted INTO it via
    /// `screenshotToBackingScale` (screenshot-px-per-backing-px, the SAME
    /// convention `AnnotationBoundsSupport.screenshotRect`'s `scale`
    /// parameter uses -- this divides where that one multiplies), and the
    /// painted side is `precomputedPaintedBoundsBacking` when the caller
    /// already has it (capture_source="none" always does) or is rendered
    /// fresh here via the SAME permission-free `renderedPaintedBounds` when
    /// it does not (the screenshot_path/chalkboard paths, which only have a
    /// SCREENSHOT-pixel painted rect on hand, not a backing-pixel one) --
    /// either way it is the live renderer's own answer, never a second,
    /// independently-computed estimate.
    private func resolveExpectationVerdict(
        args: [String: Any],
        annotation: Annotation,
        screen: ScreenInfo,
        snapshot: ScreenSnapshot,
        rasterLease: RasterAssetStore.Lease,
        precomputedPaintedBoundsBacking: CGRect?,
        screenshotToBackingScale: (x: Double, y: Double)? = nil
    ) -> DrawOutcome<[String: Any]?> {
        // Both the "which keys were supplied" question and the "more than
        // one is a contradiction" rejection text live in
        // `AnnotationBoundsSupport` (a pure, directly-testable predicate)
        // rather than here, where this function's `private`/MCPServer-scoped
        // visibility would put the rule out of a unit test's reach -- see
        // that function's own doc comment.
        if let rejection = AnnotationBoundsSupport.atMostOneExpectationRejection(args) {
            return .failure(rejection)
        }
        guard let onlyKey = AnnotationBoundsSupport.suppliedExpectationKeys(args).first else { return .success(nil) }

        // Resolved ONCE, up front, rather than after the target is picked:
        // `expect_window`'s own tie-break (`TargetWindowSelection
        // .selectWindow(forRect:among:)`, below) needs the annotation's REAL
        // painted bounds to pick the most-overlapping window, exactly like
        // `DrawRequest.buildWindowAnchor` does for a brand-new anchor -- a
        // placeholder rect there would silently fall back to "front-most
        // window wins" instead of "the window this annotation actually
        // overlaps wins".
        let paintedBoundsBacking: CGRect
        if let precomputedPaintedBoundsBacking {
            paintedBoundsBacking = precomputedPaintedBoundsBacking
        } else {
            do {
                guard let rendered = try AnnotationVerificationCompositor.renderedPaintedBounds(
                    of: annotation, on: screen, rasterLease: rasterLease
                ) else {
                    return .failure("expect_*: the annotation painted no pixels anywhere on its \(screen.widthPx)x\(screen.heightPx) screen (\(screen.id)), so there is no painted region to compare against.")
                }
                paintedBoundsBacking = rendered
            } catch {
                return .failure("expect_*: \(error.localizedDescription)")
            }
        }

        let targetBoundsBacking: CGRect
        var details: [String: Any] = [:]
        let targetSource: String

        switch onlyKey {
        case "expect_element":
            guard let dict = args["expect_element"] as? [String: Any] else {
                return .failure("expect_element must be an object with a required label field, and optional app/role/match/occurrence fields.")
            }
            guard let rawLabel = dict["label"] as? String else {
                return .failure("expect_element.label is required and must be a string.")
            }
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else {
                return .failure("expect_element.label must not be empty.")
            }
            let matchMode: AccessibilityLabelMatchMode
            switch (dict["match"] as? String)?.lowercased() ?? "exact" {
            case "exact": matchMode = .exact
            case "contains": matchMode = .contains
            default: return .failure("expect_element.match must be 'exact' or 'contains' when supplied.")
            }
            let occurrence = MCPArgument.integer(dict["occurrence"])
            let role = dict["role"] as? String
            let process: (app: AppRef, pid: Int64)
            switch resolveExpectationTargetProcess(appName: dict["app"] as? String) {
            case .failure(let error): return .failure("expect_element: \(error)")
            case .success(let value): process = value
            }
            guard let narrowedPID = ExpectationProcessID(exactly: process.pid) else {
                return .failure("expect_element: App '\(process.app.name)' [\(process.app.bundleId)]'s process id could not be represented on this platform.")
            }
            let match: AccessibilityElementMatch
            do {
                match = try AccessibilityElementResolver.resolve(
                    processID: narrowedPID,
                    request: AccessibilityElementRequest(label: label, role: role, matchMode: matchMode, occurrence: occurrence),
                    screens: snapshot.screens
                )
            } catch {
                return .failure("expect_element: \(error.localizedDescription)")
            }
            // RE-READ the display layout AFTER the walk, exactly like
            // `handleHighlightElement` (MCPToolHandlers+Highlight.swift)
            // does for the identical reason: the walk can legitimately run
            // for several seconds, and a display reconfiguration in between
            // would silently move the answer if converted against the
            // pre-walk snapshot.
            let screensAfterWalk = OverlayWindowController.shared.screenSnapshot().screens
            guard let confirmedFrame = AccessibilityElementResolver.backingRect(
                      forAccessibilityFrame: match.accessibilityFrame, screens: screensAfterWalk
                  ), confirmedFrame == match.backingFrame else {
                return .failure("expect_element: the display layout changed while \(process.app.name)'s accessibility tree was being walked, so the matched element's coordinates cannot be converted safely. This is transient; retry.")
            }
            guard confirmedFrame.screenId == screen.id else {
                return .failure("expect_element resolved on display \(confirmedFrame.screenId), but annotation \(annotation.id) lives on display \(screen.id) -- bounds on two different displays cannot be compared. Nothing was verified.")
            }
            targetBoundsBacking = CGRect(
                x: confirmedFrame.x, y: confirmedFrame.y, width: confirmedFrame.width, height: confirmedFrame.height
            )
            details = ["matchedLabel": match.matchedLabel, "role": jsonValue(match.role), "app": process.app.bundleId]
            targetSource = "element"

        case "expect_window":
            guard let dict = args["expect_window"] as? [String: Any] else {
                return .failure("expect_window must be an object with an optional app field.")
            }
            let process: (app: AppRef, pid: Int64)
            switch resolveExpectationTargetProcess(appName: dict["app"] as? String) {
            case .failure(let error): return .failure("expect_window: \(error)")
            case .success(let value): process = value
            }
            let samples = TargetWindowProbe.shared.windows(forProcessId: process.pid, screens: snapshot.screens)
            // Only windows already on the ANNOTATION's own display are
            // eligible -- a window's frame on a different display cannot be
            // compared against this annotation's backing-pixel bounds any
            // more meaningfully than `expect_element`'s cross-display guard
            // just above allows for an element. Mirrors
            // `DrawRequest.buildWindowAnchor`'s identical `screenId` filter.
            let eligible = samples.filter { $0.screenId == screen.id }
            guard let selected = TargetWindowSelection.selectWindow(forRect: paintedBoundsBacking, among: eligible) else {
                return .failure("expect_window found no eligible on-screen window for \(process.app.name) [\(process.app.bundleId)] on display \(screen.id). Nothing was verified.")
            }
            targetBoundsBacking = selected.frame
            details = [
                "windowId": Int(selected.windowId), "processId": Int(selected.processId), "app": process.app.bundleId
            ]
            targetSource = "window"

        default: // "target_bounds_screenshot_px"
            let parsedTarget: CGRect?
            switch AnnotationBoundsSupport.parseTargetBounds(args) {
            case .failure(let error): return .failure(error)
            case .success(let value): parsedTarget = value
            }
            // `onlyKey` already proved this argument was supplied and
            // non-null, so `parsedTarget` cannot be nil here --
            // `parseTargetBounds` only returns nil for an absent/null value.
            guard let screenshotRect = parsedTarget else { return .success(nil) }
            guard let scale = screenshotToBackingScale else {
                return .failure("target_bounds_screenshot_px requires a screenshot pixel space to convert from: reference screenshot_space, or supply screenshot_path/capture_source='chalkboard' (whose real screenshot dimensions supply one automatically). Nothing was verified.")
            }
            guard scale.x.isFinite, scale.x > 0, scale.y.isFinite, scale.y > 0 else {
                return .failure("target_bounds_screenshot_px cannot be converted: the current screenshot scale is zero, non-finite, or otherwise degenerate.")
            }
            targetBoundsBacking = CGRect(
                x: screenshotRect.minX / scale.x, y: screenshotRect.minY / scale.y,
                width: screenshotRect.width / scale.x, height: screenshotRect.height / scale.y
            )
            targetSource = "target_bounds_screenshot_px"
        }

        let comparison = AnnotationGeometryVerdict.compare(painted: paintedBoundsBacking, target: targetBoundsBacking)
        var payload: [String: Any] = comparison.payload
        payload["targetSource"] = targetSource
        payload["targetBoundsBackingPx"] = AnnotationBoundsSupport.rectPayload(targetBoundsBacking)
        payload["paintedBoundsBackingPx"] = AnnotationBoundsSupport.rectPayload(paintedBoundsBacking)
        for (key, value) in details { payload[key] = value }
        // `AnnotationGeometryVerdict`'s own doc comment: this is renderer
        // geometry compared against resolver geometry, not itself proof any
        // pixel reached a framebuffer -- restated here so a caller reading
        // ONLY this nested `expect` object (skipping the surrounding
        // response's own `evidence`/`evidenceLevel`) still sees the caveat.
        payload["evidenceLevel"] = "renderer_geometry"

        // The delta above is already in BACKING pixels (both operands to
        // `compare` were converted into that space before comparing), so the
        // screenshot-to-backing half of `correctedOffset`'s two-step
        // conversion is already done -- passing scale (1, 1) makes its first
        // multiply a no-op and leaves only the anchor-adjustment division,
        // which is still needed exactly as `get_annotation_bounds` needs it.
        if let corrected = AnnotationBoundsSupport.correctedOffset(
            currentOffsetX: annotation.offsetX, currentOffsetY: annotation.offsetY,
            deltaScreenshotX: comparison.centerDeltaX, deltaScreenshotY: comparison.centerDeltaY,
            screenshotToBackingScale: (1, 1), adjustment: annotation.effectiveAdjustment
        ) {
            payload["correctionBackingPx"] = ["offsetX": corrected.offsetX, "offsetY": corrected.offsetY]
        } else {
            payload["correctionUnavailableReason"] = "The annotation's current anchor adjustment scale is zero, non-finite, or otherwise degenerate, so a single offset_x/offset_y correction cannot be computed safely. Check anchor.state before retrying."
        }

        return .success(payload)
    }

    /// Resolves the `app` field nested inside `expect_element`/
    /// `expect_window` to exactly one running process, via the SAME
    /// `ActiveAppTracker` resolution and single-running-instance rule
    /// `resolveRunningHighlightTarget` (`MCPToolHandlers+Highlight.swift`)
    /// applies to its own top-level `app` argument. That function is
    /// `private` to its own file -- Swift's same-file `private` visibility
    /// rule (SE-0169 widens `private` only to other extensions of the same
    /// type in the SAME file) keeps it out of reach here -- so this
    /// duplicates its STEPS deliberately, adapted to a nested object field
    /// and this file's own wording, rather than exporting it just for this
    /// one caller.
    private func resolveExpectationTargetProcess(appName raw: String?) -> DrawOutcome<(app: AppRef, pid: Int64)> {
        let app: AppRef
        if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch ActiveAppTracker.shared.resolve(trimmed) {
            case .resolved(let value): app = value
            case .ambiguous(let matches):
                let candidates = matches.map { "'\($0.name)' [\($0.bundleId)]" }.joined(separator: ", ")
                return .failure("app '\(trimmed)' is AMBIGUOUS across running applications: \(candidates). Retry with an exact bundle id or display name.")
            case .notFound:
                return .failure("app '\(trimmed)' is not running or could not be resolved.")
            }
        } else {
            let fallback = ActiveAppTracker.shared.fallbackApp
            guard let bundleId = fallback.bundleId else {
                return .failure("No fallback running app is available; pass app explicitly.")
            }
            app = AppRef(bundleId: bundleId, name: fallback.name ?? bundleId)
        }
        let pids = MCPServer.shared.runningProcessIds(forAppId: app.bundleId)
        guard pids.count == 1, let pid = pids.first else {
            return pids.isEmpty
                ? .failure("App '\(app.name)' [\(app.bundleId)] is no longer running.")
                : .failure("App '\(app.name)' [\(app.bundleId)] has \(pids.count) running processes; refusing to guess which one to inspect.")
        }
        return .success((app, pid))
    }
}
