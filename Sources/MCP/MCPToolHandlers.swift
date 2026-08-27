import Foundation

/// `tools/call` dispatch and the body of every individual tool, plus the two
/// diagnostic JSON payload builders (`list_annotations`, `get_active_app`).
///
/// The free-draw tool bodies below each contribute only what is genuinely
/// tool-specific to the shared `DrawRequest` pipeline (see DrawRequest.swift):
/// their own geometry parsing/validation, their own default color, their
/// `AnnotationKind`, their noun for the success message, and whether they
/// default to global.
extension MCPServer {
    func handleToolsCall(id: Any?, params: [String: Any]) {
        guard let id = id else { return }
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        log(redactedArgumentSummary(name: name, args: args))

        switch name {
        case "get_screens":
            let screens = OverlayWindowController.shared.screenSnapshot().screens
            // The `screens` array is byte-identical to what this tool used to
            // return at the top level; it is now nested so the capture state can
            // ride along. Reporting that state here is what lets a caller who
            // turned capture on for a placement check notice it is still on and
            // put it back, instead of silently leaving every subsequent
            // compatible capture path eligible to include annotations.
            guard let screenArray = jsonObject(screens) as? [Any] else {
                sendErrorResult(id: id, text: "Failed to encode screen list.")
                return
            }
            let captureVisible = OverlayWindowController.shared.isCaptureVisible
            let annotationsSuspended = OverlayWindowController.shared.isAnnotationsSuspended
            let payload: [String: Any] = [
                "screens": screenArray,
                "coordinateSpace": "AppKit backing pixels: widthPx/heightPx are NSScreen.frame point dimensions multiplied by that same screen's NSScreen.backingScaleFactor. Drawing uses this same scale source.",
                "drawingFromScreenshot": "Use coordinate_space='screenshot_pixels' and the exact width/height of the uncropped full-display image version you measured, after any client/model resize. Detectable cropped/window aspect mismatches are rejected. A same-aspect crop cannot be distinguished from a downsampled full-display image, so preserve full-display provenance. Never send resized-image coordinates as backing_pixels.",
                "backingScaleSource": "NSScreen.backingScaleFactor",
                "captureVisible": captureVisible,
                "annotationsSuspended": annotationsSuspended,
                "captureNote": captureVisible
                    ? "Capture-debug mode is ON: overlay windows request sharingType=.readOnly and render every annotation. A capture tool may still omit these windows through its own app/window filter. Call set_capture_visible(false) to restore normal filtering."
                    : "Capture-debug mode is OFF (default): overlay windows request legacy sharingType=.none and render only annotations visible for the active app. This is not a security guarantee; modern capture tools control their own inclusion filters.",
                "suspensionNote": annotationsSuspended
                    ? "Annotations are suspended: all overlay windows are ordered out while store entries and TTLs are retained. Release the exact suspension lease token with resume_annotations to restore normal presentation once no other lease remains."
                    : "Annotations are not suspended. suspend_annotations is available as a temporary click-workaround, not simultaneous visual click-through."
            ]
            guard let text = jsonString(payload) else {
                sendErrorResult(id: id, text: "Failed to encode screen list.")
                return
            }
            sendTextResult(id: id, text: text)

        case "get_overlay_state":
            let overlays = OverlayWindowController.shared.overlayInputPolicySnapshot()
            let annotationsSuspended = OverlayWindowController.shared.isAnnotationsSuspended
            let leaseSnapshot = SuspensionLeaseCoordinator.shared.snapshot()
            let suspensionNote: String
            if !leaseSnapshot.isBootstrapped {
                suspensionNote = "Annotations are hidden because the shared suspension registry is unavailable, not because this process holds a valid lease. activeLeaseCount is not authoritative in this fail-closed state; do not click or attempt token cleanup until suspensionRegistryBootstrapped=true."
            } else if annotationsSuspended {
                suspensionNote = "Annotations are suspended: Chalkboard has ordered every overlay window in this process out, while retaining annotation store entries and TTLs. Each overlays[].isOnScreen value is this process's AppKit state only; it is not proof that a sibling process is also off screen. For a click workaround, use a live suspension lease whose suspend_annotations result says clickSafeAtObservation=true."
            } else {
                suspensionNote = "ignoresMouseEvents and overlays[].isOnScreen are this process's live AppKit state. They do not prove sibling-process state, raw framebuffer pixels, or occlusion. macOS WindowServer metadata does not expose ignoresMouseEvents, so a click dispatcher that blocks merely because an overlay window is present must explicitly consult and honor this state. suspend_annotations is a fallback workaround, not true simultaneous click-through."
            }
            guard let overlayJSON = jsonObject(overlays) as? [Any] else {
                sendErrorResult(id: id, text: "Failed to encode overlay input state.")
                return
            }
            let payload: [String: Any] = [
                "overlays": overlayJSON,
                "version": BuildMetadata.productVersion,
                "buildIdentifier": BuildMetadata.buildIdentifier,
                "suspensionProtocolVersion": 2,
                "rawFramebufferProof": false,
                "occlusionProof": false,
                "annotationsSuspended": annotationsSuspended,
                "activeLeaseCount": leaseSnapshot.activeLeaseCount,
                "suspensionGeneration": leaseSnapshot.generation,
                "suspensionRegistryBootstrapped": leaseSnapshot.isBootstrapped,
                "nextLeaseExpiryInSeconds": leaseSnapshot.nextExpiryInSeconds ?? NSNull(),
                "suspensionRegistryError": leaseSnapshot.error ?? NSNull(),
                "externalClickDispatcherMustHonorClickThrough": true,
                "note": suspensionNote
            ]
            guard let text = jsonString(payload) else {
                sendErrorResult(id: id, text: "Failed to encode overlay input state.")
                return
            }
            sendTextResult(id: id, text: text)

        case "get_accessibility_status":
            if args.keys.contains("request_permission"), MCPArgument.bool(args["request_permission"]) == nil {
                sendErrorResult(id: id, text: "request_permission must be a boolean when supplied.")
                return
            }
            let status = AccessibilityElementResolver.trustStatus(requestPrompt: MCPArgument.bool(args["request_permission"]) ?? false)
            guard let object = jsonObject(status), let text = jsonString(object) else {
                sendErrorResult(id: id, text: "Failed to encode Accessibility permission status.")
                return
            }
            sendTextResult(id: id, text: text)

        case "draw_path":
            let request: DrawRequest
            let transform: DrawRequest.CoordinateTransform
            switch DrawRequest.resolveDrawContext(args: args) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
                return
            case .success(let resolved):
                (request, transform) = resolved
            }
            let kind: AnnotationKind
            switch makeVectorPathKind(args, coordinateTransform: transform) {
            case .failure(let err): sendErrorResult(id: id, text: err); return
            case .success(let parsed): kind = parsed
            }
            switch request.finish(
                args: args,
                defaultColor: DrawingDefaults.pathColor,
                label: nil,
                defaultsToGlobal: false,
                kind: kind,
                noun: "free-draw SVG path"
            ) {
            case .failure(let err):
                sendErrorResult(id: id, text: err)
            case .success(let message):
                sendTextResult(id: id, text: message)
            }

        case "draw_image":
            handleDrawImage(id: id, args: args)

        case "draw_text":
            handleDrawText(id: id, args: args)

        case "highlight_element":
            handleHighlightElement(id: id, args: args)

        case "draw_batch":
            handleDrawBatch(id: id, args: args)

        case "update_annotation":
            handleUpdateAnnotation(id: id, args: args)

        case "suspend_annotations":
            handleAcquireAnnotationSuspensionLease(id: id, args: args)

        case "resume_annotations":
            handleReleaseAnnotationSuspensionLease(id: id, args: args)

        case "clear":
            // Validate every recognized selector before mutating anything. In
            // particular, never turn a malformed annotation_id or typoed scope
            // into the old default active clear.
            let scope: ClearScope
            if args.keys.contains("scope") {
                guard let rawScope = args["scope"] as? String else {
                    sendErrorResult(id: id, text: "Invalid clear request: 'scope' must be 'active' or 'all' when supplied.")
                    return
                }
                guard let parsedScope = ClearScope(rawValue: rawScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    sendErrorResult(id: id, text: "Invalid clear request: 'scope' must be 'active' or 'all' when supplied.")
                    return
                }
                scope = parsedScope
            } else {
                scope = .active
            }
            let annotationID: String?
            if args.keys.contains("annotation_id") {
                guard let rawID = args["annotation_id"] as? String,
                      !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    sendErrorResult(id: id, text: "Invalid clear request: 'annotation_id' must be a non-empty string when supplied.")
                    return
                }
                annotationID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                annotationID = nil
            }
            // `app` is parsed exactly once, here: this is the sole fail-closed
            // authority for its type, and the branches below consume the parsed
            // value instead of re-inspecting `args`. The previous second guard
            // inside the .active branch was unreachable (a non-String `app`
            // could never get past this point) while still carrying its own
            // copy of the error string -- two places to keep in sync for one
            // reachable message.
            let appArgument: String?
            if args.keys.contains("app") {
                guard let value = args["app"] as? String else {
                    sendErrorResult(id: id, text: "Invalid clear request: 'app' must be a string bundle id/display name, or an empty string for global annotations only.")
                    return
                }
                appArgument = value
            } else {
                appArgument = nil
            }

            // An explicit id wins over a valid scope/app selector: the caller
            // named one specific annotation, so its linkage is irrelevant.
            if let annId = annotationID {
                let removed = AnnotationStore.shared.remove(id: annId)
                if removed {
                    sendTextResult(id: id, text: "Cleared annotation \(annId)")
                } else {
                    sendTextResult(id: id, text: "Annotation \(annId) not found.")
                }
                return
            }

            if scope == .all, appArgument != nil {
                sendErrorResult(id: id, text: "Invalid clear request: 'app' cannot be combined with scope='all'. Remove app to clear everything, or use scope='active' to clear one app's annotations plus global annotations.")
                return
            }
            switch scope {
            case .all:
                AnnotationStore.shared.clearAll()
                sendTextResult(id: id, text: "Cleared ALL annotations, for every app, on every screen.")
            case .active:
                // Prefer the explicit `app` added for drift-proof targeting.
                // Omission deliberately preserves the old fallback behavior
                // for compatibility, but the fallback is mutable: another app
                // activation between draw and clear can change it. The response
                // therefore names both the resolved app and targetSource.
                // Clearing by annotation_id remains the exact undo path.
                let activeId: String?
                let activeName: String?
                let targetSource: String

                if let rawApp = appArgument {
                    var resolvedId: String?
                    var resolvedName: String?
                    if let err = resolveTargetApp(args, defaultsToGlobal: false, appId: &resolvedId, appName: &resolvedName) {
                        sendErrorResult(id: id, text: err)
                        return
                    }
                    activeId = resolvedId
                    activeName = resolvedName
                    targetSource = rawApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "explicit-global" : "explicit-app"
                } else {
                    // Paired read: the id selects what gets cleared and the
                    // name is reported back as that same target, so they must
                    // come from a single lock acquisition -- see
                    // `ActiveAppTracker.fallbackApp`.
                    let fallback = ActiveAppTracker.shared.fallbackApp
                    activeId = fallback.bundleId
                    activeName = fallback.name
                    targetSource = activeId == nil ? "fallback-unavailable/global-only" : "fallback"
                }
                let removed = AnnotationStore.shared.clearVisible(forApp: activeId)
                let target = activeName ?? activeId ?? "<global annotations only>"
                let zeroNote = removed == 0 ? " No matching live annotations were present; check list_annotations for expiry or app linkage." : ""
                sendTextResult(id: id, text: "Cleared \(removed) annotation(s) for target \(target) [targetSource=\(targetSource), appId=\(activeId ?? "null")] (target-app annotations plus global ones). Annotations linked to other apps were left in place.\(zeroNote)")
            }

        case "list_annotations":
            switch buildAnnotationListJSON(args: args) {
            case .success(let text): sendTextResult(id: id, text: text)
            case .failure(let error): sendErrorResult(id: id, text: error)
            }

        case "verify_annotation":
            handleVerifyAnnotation(id: id, args: args)

        case "verify_presentation":
            guard let annotationId = (args["annotation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !annotationId.isEmpty else {
                sendErrorResult(id: id, text: "Missing required parameter: annotation_id")
                return
            }
            let status = OverlayWindowController.shared.presentationStatus(for: annotationId)
            guard let object = jsonObject(status), let text = jsonString(object) else {
                sendErrorResult(id: id, text: "Failed to encode presentation diagnostics.")
                return
            }
            sendTextResult(id: id, text: text)

        case "get_active_app":
            sendTextResult(id: id, text: buildActiveAppJSON())

        case "set_capture_visible":
            guard let visible = MCPArgument.bool(args["visible"]) else {
                let message = args.keys.contains("visible")
                    ? "visible must be a boolean."
                    : "Missing required boolean parameter: visible"
                sendErrorResult(id: id, text: message)
                return
            }
            // Apply this process synchronously BEFORE replying. Distributed
            // notification self-delivery is intentionally asynchronous, so it
            // cannot be the acknowledgement mechanism for an MCP caller that
            // will immediately capture or verify the overlay. The following
            // broadcast still carries the same request to every sibling; our
            // self-delivered copy is an idempotent renewal.
            _ = OverlayWindowController.shared.setCaptureVisible(visible)
            InstanceBroadcast.shared.postSetCaptureVisible(visible)
            let explanation = visible
                ? "AI Chalkboard now requests capture eligibility and renders every annotation for placement checks. The capture program can still omit overlay windows through its own filters. Restore false when finished."
                : "AI Chalkboard now requests legacy capture exclusion and has restored normal per-app rendering. Modern capture programs may independently include or exclude these windows, so this is not a privacy guarantee."
            sendTextResult(id: id, text: "capture_visible = \(visible) (sharingType = \(visible ? "NSWindowSharingType.readOnly" : "NSWindowSharingType.none")), applied locally before this response; a broadcast has been sent to sibling AI Chalkboard instances. \(explanation)")

        default:
            sendErrorResult(id: id, text: "Unknown tool: \(name)")
        }
    }

    /// The single `tools/call` log line: redaction rules plus a hard byte
    /// budget on the argument description.
    ///
    /// THE BUDGET IS THE POINT. `log` writes synchronously on the MCP read-loop
    /// thread, and tool arguments are caller-sized: one `draw_path` can carry
    /// hundreds of kilobytes of SVG and a `draw_batch` request is bounded only
    /// by the ~4 MiB request cap. Interpolating the whole dictionary therefore
    /// (a) rotated the bounded 5 MiB log file away in a handful of calls,
    /// destroying the history anyone would actually want to read, and (b) made
    /// the stderr write proportional to request size, which can wedge the read
    /// loop outright when the parent process never drains that pipe. The cap
    /// applies to the redacted branches too: redaction replaces a couple of
    /// named values, it does not bound the remaining keys.
    ///
    /// The tool NAME stays outside the budget and unredacted, so a truncated
    /// line still says which call it belonged to. stderr is not part of the
    /// wire format, so nothing here is protocol-visible.
    private func redactedArgumentSummary(name: String, args: [String: Any]) -> String {
        let maximumArgumentBytes = 2 * 1_024
        func capped(_ arguments: [String: Any]) -> String {
            let description = "\(arguments)"
            let truncated = truncateUTF8(description, maximumBytes: maximumArgumentBytes)
            guard truncated.utf8.count < description.utf8.count else { return truncated }
            return "\(truncated)... <truncated to \(maximumArgumentBytes) bytes>"
        }

        switch name {
        case "suspend_annotations", "resume_annotations":
            // A lease token can release another caller's suspension, and an
            // idempotency key can retrieve its active token.  Treat both as
            // capabilities: MCP request logging must never persist them.
            var redactedArgs = args
            if redactedArgs["lease_token"] != nil { redactedArgs["lease_token"] = "<redacted capability>" }
            if redactedArgs["idempotency_key"] != nil { redactedArgs["idempotency_key"] = "<redacted capability>" }
            return "Calling tool: \(name) with sensitive arguments redacted: \(capped(redactedArgs))"
        case "verify_annotation" where args["screenshot_path"] != nil:
            var redactedArgs = args
            redactedArgs["screenshot_path"] = "<redacted local path>"
            return "Calling tool: \(name) with args: \(capped(redactedArgs))"
        case "draw_image", "draw_batch":
            // Local asset paths can expose usernames/project names. The tool
            // result only retains opaque in-memory IDs, and logs do the same.
            return "Calling tool: \(name) with local asset paths redacted"
        default:
            return "Calling tool: \(name) with args: \(capped(args))"
        }
    }
}
