import Foundation

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
            sendErrorResult(id: id, text: "capture_source must be 'chalkboard' when supplied.")
            return
        }
        if args.keys.contains("request_permission"), MCPArgument.bool(args["request_permission"]) == nil {
            sendErrorResult(id: id, text: "request_permission must be a boolean when supplied.")
            return
        }
        let screenshotPath = (args["screenshot_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureSource = (args["capture_source"] as? String)?.lowercased()
        guard screenshotPath?.isEmpty != true else {
            sendErrorResult(id: id, text: "screenshot_path cannot be empty when supplied.")
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
        // string other than "chalkboard") is already rejected right here,
        // with no further "captureSource != 'chalkboard'" branch reachable
        // afterward.
        guard screenshotPath != nil || captureSource == "chalkboard" else {
            sendErrorResult(id: id, text: "Supply screenshot_path, or capture_source='chalkboard' (no other capture_source value is accepted), for verification.")
            return
        }
        if screenshotPath != nil, args.keys.contains("request_permission") {
            sendErrorResult(id: id, text: "request_permission is only valid with capture_source='chalkboard'.")
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
            sendErrorResult(id: id, text: "Annotation \(annotationId) was not found or has already expired. Call list_annotations and retry with a live ID.")
            return
        }
        let annotation = renderSnapshot.annotation
        let snapshot = OverlayWindowController.shared.screenSnapshot()
        guard let screen = snapshot.screens.first(where: { $0.id == annotation.screenId }) else {
            sendErrorResult(id: id, text: "Annotation \(annotationId) belongs to screen \(annotation.screenId), which is no longer connected. Nothing was rendered.")
            return
        }

        do {
            let composite: AnnotationVerificationComposite
            var sourceMetadata: [String: Any] = [:]
            if let screenshotPath {
                composite = try AnnotationVerificationCompositor.composite(
                    annotation: annotation, screen: screen, screenshotPath: screenshotPath,
                    paddingPx: padding, rasterLease: renderSnapshot.rasterLease
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
            let visibility = AnnotationVisibilityDiagnostic(
                annotationsSuspended: OverlayWindowController.shared.isAnnotationsSuspended,
                captureVisible: OverlayWindowController.shared.isCaptureVisible,
                annotationAppId: annotation.appId,
                activeAppId: ActiveAppTracker.shared.currentAppId
            )
            metadata["annotationsSuspended"] = visibility.annotationsSuspended
            metadata["wouldBeVisibleWithoutSuspension"] = visibility.wouldBeVisibleWithoutSuspension
            metadata["isVisibleNow"] = visibility.isVisibleNow
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
            if let expiresAt = annotation.expiresAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                metadata["expiresAt"] = formatter.string(from: expiresAt)
                // Monotonic when available (see Annotation.remainingSeconds);
                // the RFC 3339 expiresAt above stays wall-clock for the wire.
                metadata["remainingSeconds"] = annotation.remainingSeconds(
                    now: Date(), uptime: ProcessInfo.processInfo.systemUptime
                ) ?? NSNull()
            } else {
                metadata["expiresAt"] = NSNull()
                metadata["remainingSeconds"] = NSNull()
            }
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
}
