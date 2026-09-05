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

        // Reject misspelled or cross-tool arguments before dispatch. Several
        // handlers intentionally default omitted values (notably clear's
        // active-app selector), so treating an unrecognised key as omission
        // could otherwise turn a typo into a destructive or misplaced action.
        if let error = MCPToolCatalog.validateArguments(toolName: name, args: args) {
            sendErrorResult(id: id, text: error)
            return
        }

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
            // PLATFORM-ACCURATE PROSE, not a cosmetic detail. These strings are
            // read by the AI agent deciding how to compute coordinates, so
            // describing macOS's AppKit/NSScreen model to a Windows caller is a
            // correctness problem, not a wording nit: there is no NSScreen and
            // no sharingType there, and a reader told otherwise cannot reason
            // about what widthPx actually is. The MECHANISM and the numbers are
            // the same on both platforms (top-left-origin physical pixels); only
            // the API these values are sourced from differs.
            //
            // The ORIGIN half of each string is not documentation padding: an
            // agent that read a secondary display's appKitFrame.x = 1512,
            // concluded drawing coordinates were desktop-global, and added
            // that offset drew 1512 px off the intended control -- and nothing
            // downstream can reject it, because a coordinate that has had a
            // display offset added to it is still a perfectly valid in-bounds
            // coordinate on the selected display. Stating the screen-LOCAL
            // contract here, next to the frame fields that invite the mistake,
            // is the only place it can be caught. The field names are the
            // emitted wire-format keys (ScreenInfo is one Codable struct for
            // both platforms) and must be named exactly as sent.
            #if os(macOS)
            let coordinateSpaceNote = "AppKit backing pixels: widthPx/heightPx are NSScreen.frame point dimensions multiplied by that same screen's NSScreen.backingScaleFactor. Drawing uses this same scale source. All drawing coordinates are relative to the SELECTED display's OWN top-left corner: (0,0) is that display's top-left and widthPx/heightPx are its extent. appKitFrame (AppKit points, bottom-left desktop origin) and windowServerFrame (CGDisplayBounds, global top-left points -- the same space as kCGWindowBounds, NOT backing pixels) only describe where the display sits on the desktop, in OTHER units; they must NEVER be added to drawing coordinates."
            let backingScaleSource = "NSScreen.backingScaleFactor"
            let captureOnNote = "Capture-debug mode is ON: overlay windows request sharingType=.readOnly and render every annotation. A capture tool may still omit these windows through its own app/window filter. Call set_capture_visible(false) to restore normal filtering."
            let captureOffNote = "Capture-debug mode is OFF (default): overlay windows request legacy sharingType=.none and render only annotations visible for the active app. This is not a security guarantee; modern capture tools control their own inclusion filters."
            #elseif os(Windows)
            let coordinateSpaceNote = "Physical device pixels: widthPx/heightPx are the monitor's rectangle as reported by GetMonitorInfoW under PER_MONITOR_AWARE_V2 DPI awareness, which is already in physical pixels. backingScaleFactor is that monitor's effective DPI divided by 96 and is reported for scaling stroke widths and font sizes; it is NOT applied again to widthPx/heightPx. Drawing uses this same scale source. All drawing coordinates are relative to the SELECTED display's OWN top-left corner: (0,0) is that display's top-left and widthPx/heightPx are its extent. appKitFrame and windowServerFrame (the same virtual-desktop rectangle under both names on this platform) only describe where the monitor sits on the virtual desktop, whose origin is the PRIMARY monitor's top-left and whose coordinates can be negative; they must NEVER be added to drawing coordinates."
            let backingScaleSource = "GetDpiForMonitor effective DPI / 96.0"
            let captureOnNote = "Capture-debug mode is ON: overlay windows clear SetWindowDisplayAffinity (WDA_NONE) and render every annotation. A capture tool may still omit these windows through its own filter. Call set_capture_visible(false) to restore normal filtering."
            let captureOffNote = "Capture-debug mode is OFF (default): overlay windows request SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) and render only annotations visible for the active app. This is not a security guarantee, it requires Windows 10 version 2004 or later, and it excludes only THIS process's own windows -- Windows has no way to exclude another process's windows from a capture."
            #endif

            let payload: [String: Any] = [
                "screens": screenArray,
                "coordinateSpace": coordinateSpaceNote,
                "drawingFromScreenshot": "Use coordinate_space='screenshot_pixels' and the exact width/height of the uncropped full-display image version you measured, after any client/model resize. Detectable cropped/window aspect mismatches are rejected. A same-aspect crop cannot be distinguished from a downsampled full-display image, so preserve full-display provenance. Never send resized-image coordinates as backing_pixels.",
                "backingScaleSource": backingScaleSource,
                "captureVisible": captureVisible,
                "annotationsSuspended": annotationsSuspended,
                "captureNote": captureVisible ? captureOnNote : captureOffNote,
                "suspensionNote": annotationsSuspended
                    ? "Annotations are suspended: all overlay windows are ordered out while store entries are retained. Release the exact suspension lease token with resume_annotations to restore normal presentation once no other lease remains."
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
                // PLATFORM-ACCURATE PROSE, same reasoning as the
                // coordinateSpaceNote block above: overlays[].isOnScreen is
                // sourced from AppKit on macOS but from this process's own
                // Win32 window state (IsWindowVisible) on Windows.
                #if os(macOS)
                suspensionNote = "Annotations are suspended: Chalkboard has ordered every overlay window in this process out, while retaining annotation store entries. Each overlays[].isOnScreen value is this process's AppKit state only; it is not proof that a sibling process is also off screen. For a click workaround, use a live suspension lease whose suspend_annotations result says clickSafeAtObservation=true."
                #elseif os(Windows)
                suspensionNote = "Annotations are suspended: Chalkboard has ordered every overlay window in this process out, while retaining annotation store entries. Each overlays[].isOnScreen value is this process's Win32 window-visibility state (IsWindowVisible) only; it is not proof that a sibling process is also off screen. For a click workaround, use a live suspension lease whose suspend_annotations result says clickSafeAtObservation=true."
                #endif
            } else {
                // ignoresMouseEvents itself is read very differently per
                // platform: AppKit exposes NSWindow.ignoresMouseEvents as a
                // live, mutable per-window property, while this app bakes
                // WS_EX_TRANSPARENT into every Windows overlay window once at
                // creation and never re-queries it (see
                // OverlayWindowController+Diagnostics.swift's
                // overlayInputPolicySnapshot() Windows branch), so it is
                // reported here as a constant, not a live read.
                #if os(macOS)
                suspensionNote = "ignoresMouseEvents and overlays[].isOnScreen are this process's live AppKit state. They do not prove sibling-process state, raw framebuffer pixels, or occlusion. macOS WindowServer metadata does not expose ignoresMouseEvents, so a click dispatcher that blocks merely because an overlay window is present must explicitly consult and honor this state. suspend_annotations is a fallback workaround, not true simultaneous click-through."
                #elseif os(Windows)
                suspensionNote = "overlays[].isOnScreen is this process's live Win32 window-visibility state (IsWindowVisible). ignoresMouseEvents is always true here: WS_EX_TRANSPARENT is baked into every overlay window at creation and never queried live, unlike macOS's mutable NSWindow.ignoresMouseEvents. Neither value proves sibling-process state, raw framebuffer pixels, or occlusion, so a click dispatcher that blocks merely because an overlay window is present must explicitly consult and honor this state. suspend_annotations is a fallback workaround, not true simultaneous click-through."
                #endif
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

        case "draw_shape":
            handleDrawShape(id: id, args: args)

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
                    // Same platform-noun reasoning as resolveTargetApp's own
                    // guard in DrawRequest.swift: a Windows caller has no
                    // bundle id to supply.
                    #if os(macOS)
                    sendErrorResult(id: id, text: "Invalid clear request: 'app' must be a string bundle id/display name, or an empty string for global annotations only.")
                    #elseif os(Windows)
                    sendErrorResult(id: id, text: "Invalid clear request: 'app' must be a string executable name/display name, or an empty string for global annotations only.")
                    #endif
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
                let zeroNote = removed == 0 ? " No matching annotations were present; check list_annotations for app linkage." : ""
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
            // Name the mechanism this platform actually used. Reporting
            // `NSWindowSharingType` to a Windows caller describes an API that
            // does not exist there; the Windows overlay toggles
            // SetWindowDisplayAffinity instead. Same reasoning as the
            // platform-split prose in MCPToolCatalog.
            #if os(macOS)
            let appliedMechanism = visible ? "sharingType = NSWindowSharingType.readOnly" : "sharingType = NSWindowSharingType.none"
            #elseif os(Windows)
            let appliedMechanism = visible ? "display affinity = WDA_NONE" : "display affinity = WDA_EXCLUDEFROMCAPTURE"
            #endif
            sendTextResult(id: id, text: "capture_visible = \(visible) (\(appliedMechanism)), applied locally before this response; a broadcast has been sent to sibling AI Chalkboard instances. \(explanation)")

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
