import Foundation
import AppKit

private struct HighlightStyle {
    let strokeColor: String
    let strokeWidth: Double
    let strokeOpacity: Double
    let fillColor: String?
    let fillOpacity: Double
    let padding: Double
}

/// Renderer-visible alpha includes a color's own RGBA alpha.  Named colors
/// carry alpha too, so checking only a separately supplied opacity would let
/// `#RRGGBB00` create an annotation that can never paint a pixel.
private func colorHasVisibleAlpha(_ color: String?) -> Bool {
    guard let color else { return false }
    return ColorParser.parse(color).alphaComponent > 0
}

/// Pure policy for the MCP `isError` bit. A release can durably remove its
/// token yet still be unsafe to report as successful when another lease keeps
/// suspension active and peer presentation did not settle off screen.
enum SuspensionLeaseResponsePolicy {
    static func isError(operation: String, operationSucceeded: Bool,
                        annotationsSuspended: Bool, peerPresentationSettled: Bool) -> Bool {
        !operationSucceeded
            || (operation == "release" && annotationsSuspended && !peerPresentationSettled)
    }
}

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

        if name == "suspend_annotations" || name == "resume_annotations" {
            // A lease token can release another caller's suspension, and an
            // idempotency key can retrieve its active token.  Treat both as
            // capabilities: MCP request logging must never persist them.
            var redactedArgs = args
            if redactedArgs["lease_token"] != nil { redactedArgs["lease_token"] = "<redacted capability>" }
            if redactedArgs["idempotency_key"] != nil { redactedArgs["idempotency_key"] = "<redacted capability>" }
            log("Calling tool: \(name) with sensitive arguments redacted: \(redactedArgs)")
        } else if name == "verify_annotation", args["screenshot_path"] != nil {
            var redactedArgs = args
            redactedArgs["screenshot_path"] = "<redacted local path>"
            log("Calling tool: \(name) with args: \(redactedArgs)")
        } else if name == "draw_image" || name == "draw_batch" {
            // Local asset paths can expose usernames/project names. The tool
            // result only retains opaque in-memory IDs, and logs do the same.
            log("Calling tool: \(name) with local asset paths redacted")
        } else {
            log("Calling tool: \(name) with args: \(args)")
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
            let payload: [String: Any] = [
                "screens": screenArray,
                "coordinateSpace": "AppKit backing pixels: widthPx/heightPx are NSScreen.frame point dimensions multiplied by that same screen's NSScreen.backingScaleFactor. Drawing uses this same scale source.",
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
            if args.keys.contains("app"), !(args["app"] is String) {
                sendErrorResult(id: id, text: "Invalid clear request: 'app' must be a string bundle id/display name, or an empty string for global annotations only.")
                return
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

            if scope == .all, args["app"] != nil {
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

                if args.keys.contains("app") {
                    guard let rawApp = args["app"] as? String else {
                        sendErrorResult(id: id, text: "Invalid clear request: 'app' must be a string bundle id/display name, or an empty string for global annotations only.")
                        return
                    }
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
                    let tracker = ActiveAppTracker.shared
                    activeId = tracker.fallbackAppId
                    activeName = tracker.fallbackAppName
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

    /// Validates and acquires a bounded, token-scoped suspension lease.  The
    /// strict boundary matters: a malformed retry must not quietly acquire a
    /// fresh lease that its caller cannot later release.
    private func handleAcquireAnnotationSuspensionLease(id: Any, args: [String: Any]) {
        let allowed: Set<String> = ["lease_seconds", "idempotency_key"]
        guard args.keys.allSatisfy(allowed.contains) else {
            sendErrorResult(id: id, text: "suspend_annotations accepts only lease_seconds and idempotency_key.")
            return
        }

        let seconds: Int
        if args.keys.contains("lease_seconds") {
            // Deliberately stricter than every other integer argument in this
            // file (z_index, occurrence, offset, limit), which accept a
            // numeric STRING such as "15" through `MCPArgument.integer` alone.
            // lease_seconds additionally requires `is NSNumber` here because
            // it is a security-sensitive suspension-duration input and
            // MCPToolCatalog advertises it as JSON Schema `"type": "integer"`,
            // which does not admit strings -- the handler must match what the
            // schema promises, not silently be more permissive than it.
            // tests/mcp_wire_snapshot.py pins this exact asymmetry with its
            // `call_suspend_numeric_string_duration` fixture. Do not relax
            // this to match the other integer args.
            guard args["lease_seconds"] is NSNumber,
                  let supplied = MCPArgument.integer(args["lease_seconds"]),
                  (1...60).contains(supplied) else {
                sendErrorResult(id: id, text: "lease_seconds must be an integer from 1 through 60 when supplied.")
                return
            }
            seconds = supplied
        } else {
            seconds = 15
        }

        let idempotencyKey: String?
        if args.keys.contains("idempotency_key") {
            guard let raw = args["idempotency_key"] as? String,
                  let uuid = UUID(uuidString: raw),
                  raw == uuid.uuidString.lowercased() else {
                sendErrorResult(id: id, text: "idempotency_key must be a lowercase canonical UUID when supplied.")
                return
            }
            idempotencyKey = raw
        } else {
            idempotencyKey = nil
        }

        let result = SuspensionLeaseCoordinator.shared.acquireLease(
            seconds: seconds,
            idempotencyKey: idempotencyKey
        )
        sendSuspensionLeaseResult(id: id, operation: "acquire", result: result)
    }

    /// Releases only the caller's exact lease.  A token is deliberately
    /// required so an old client cannot resume a different client's active
    /// click workflow by issuing a global toggle.
    private func handleReleaseAnnotationSuspensionLease(id: Any, args: [String: Any]) {
        guard Set(args.keys) == Set(["lease_token"]),
              let token = args["lease_token"] as? String,
              isCanonicalSuspensionLeaseToken(token) else {
            sendErrorResult(id: id, text: "resume_annotations requires exactly one lease_token returned by suspend_annotations.")
            return
        }
        let result = SuspensionLeaseCoordinator.shared.releaseLease(token: token)
        sendSuspensionLeaseResult(id: id, operation: "release", result: result)
    }

    private func isCanonicalSuspensionLeaseToken(_ token: String) -> Bool {
        guard token.utf8.count == 43 else { return false }
        return token.utf8.allSatisfy { character in
            (character >= 65 && character <= 90)
                || (character >= 97 && character <= 122)
                || (character >= 48 && character <= 57)
                || character == 45 || character == 95
        }
    }

    /// All success and failure operation responses deliberately remain JSON so
    /// a cleanup caller can inspect the final lease state without parsing
    /// human prose.  The coordinator owns durable state and cross-process
    /// synchronization; this boundary adds the MCP protocol/build identity
    /// and the conservative limitation language that a dispatcher needs.
    private func sendSuspensionLeaseResult(id: Any,
                                           operation: String,
                                           result: SuspensionLeaseOperationResult) {
        let clickSafeAtObservation = operation == "acquire"
            && result.success
            && result.annotationsSuspended
            && (result.leaseExpiresInSeconds ?? 0) > 0
            && result.peerPresentationSettled
            && result.clickSafeAtObservation
        let releaseWithRemainingLeaseUnsettled = operation == "release"
            && result.success
            && result.annotationsSuspended
            && !result.peerPresentationSettled
        let responseIsError = SuspensionLeaseResponsePolicy.isError(
            operation: operation,
            operationSucceeded: result.success,
            annotationsSuspended: result.annotationsSuspended,
            peerPresentationSettled: result.peerPresentationSettled
        )
        let note: String
        if let error = result.error {
            note = error
        } else if operation == "acquire" {
            note = clickSafeAtObservation
                ? "A suspension lease is active and two consecutive conservative WindowServer samples observed no candidate AI Chalkboard overlay windows. This is point-in-time click-workaround evidence only; it is not raw-framebuffer or occlusion proof. Release this exact leaseToken promptly."
                : "A suspension lease is active, but conservative WindowServer observation was not quiescent. Do not click through yet; retry or let the short lease expire."
        } else {
            if releaseWithRemainingLeaseUnsettled {
                note = "This lease was durably released, but another active lease remains and bounded WindowServer observation did not confirm that every discovered Chalkboard overlay settled off screen. Treat this response as an error and do not click through yet."
            } else if result.annotationsSuspended {
                note = "This lease was released. Another active lease keeps overlays suspended, and bounded observation confirmed the current generation was settled off screen at response time."
            } else {
                note = "This lease was released and the linearized registry snapshot has no active lease. Chalkboard requested normal presentation restoration; this response does not prove global peer/window convergence."
            }
        }
        // The WindowServer evidence is diagnostic, not an unbounded process
        // or window inventory. Bound it here as a second line of defence even
        // if a future discovery implementation accidentally returns more.
        let evidence = boundedSuspensionEvidence(result)
        var payload: [String: Any] = [
            "protocolVersion": 2,
            "buildIdentifier": BuildMetadata.buildIdentifier,
            "operation": operation,
            "state": result.annotationsSuspended ? "suspended" : "not_suspended",
            "annotationsSuspended": result.annotationsSuspended,
            "activeLeaseCount": result.activeLeaseCount,
            "generation": result.generation,
            "leaseExpiresInSeconds": result.leaseExpiresInSeconds ?? NSNull(),
            "leaseReused": result.reused,
            "clickSafeAtObservation": clickSafeAtObservation,
            "peerPresentationSettled": result.peerPresentationSettled,
            "scope": result.scope,
            "candidatePids": evidence.candidatePIDs,
            "candidatePidsTruncated": result.candidatePIDsTruncated || evidence.candidatePIDsTruncated,
            "visibleOwnerPids": evidence.visibleOwnerPIDs,
            "visibleOwnerPidsTruncated": evidence.visibleOwnerPIDsTruncated,
            "visibleWindowNumbers": evidence.visibleWindowNumbers,
            "visibleWindowNumbersTruncated": evidence.visibleWindowNumbersTruncated,
            "discoveryErrors": evidence.discoveryErrors,
            "discoveryErrorsTruncated": evidence.discoveryErrorsTruncated,
            "evidenceTruncated": result.candidatePIDsTruncated || evidence.anyTruncated,
            "limitation": "WindowServer metadata is not raw-framebuffer or occlusion proof. A future process/window can appear after this bounded observation; true visible-highlight-while-clicking still requires the click dispatcher to honor ignoresMouseEvents.",
            "note": note
        ]
        if let token = result.leaseToken { payload["leaseToken"] = token }
        if operation == "release" { payload["alreadyReleased"] = result.alreadyReleased }
        if let error = result.error { payload["error"] = error }
        if releaseWithRemainingLeaseUnsettled {
            payload["error"] = "A remaining suspension lease exists, but peer presentation did not settle within the bounded observation."
        }
        guard let text = jsonString(payload) else {
            sendErrorResult(id: id, text: "Failed to encode bounded suspension-lease result.")
            return
        }
        sendTextResult(id: id, text: text, isError: responseIsError)
    }

    private func boundedSuspensionEvidence(_ result: SuspensionLeaseOperationResult) ->
        (candidatePIDs: [Int], candidatePIDsTruncated: Bool,
         visibleOwnerPIDs: [Int], visibleOwnerPIDsTruncated: Bool,
         visibleWindowNumbers: [Int], visibleWindowNumbersTruncated: Bool,
         discoveryErrors: [String], discoveryErrorsTruncated: Bool, anyTruncated: Bool) {
        let maximumItems = 64
        let maximumErrorCharacters = 512
        let candidatePIDs = result.candidatePIDs.map(Int.init)
        let visibleOwnerPIDs = result.visibleOwnerPIDs.map(Int.init)
        let candidateTruncated = candidatePIDs.count > maximumItems
        let ownersTruncated = visibleOwnerPIDs.count > maximumItems
        let windowsTruncated = result.visibleWindowNumbers.count > maximumItems
        let errorsTruncated = result.discoveryErrors.count > maximumItems
            || result.discoveryErrors.contains { $0.utf8.count > maximumErrorCharacters }
        let errors = result.discoveryErrors.prefix(maximumItems).map {
            truncateUTF8($0, maximumBytes: maximumErrorCharacters)
        }
        return (Array(candidatePIDs.prefix(maximumItems)), candidateTruncated,
                Array(visibleOwnerPIDs.prefix(maximumItems)), ownersTruncated,
                Array(result.visibleWindowNumbers.prefix(maximumItems)), windowsTruncated,
                errors, errorsTruncated,
                candidateTruncated || ownersTruncated || windowsTruncated || errorsTruncated)
    }

    /// Keep a valid Unicode prefix while enforcing the byte budget used by the
    /// MCP transport. `String.prefix(_:)` is character-counted and could let a
    /// small number of multi-byte scalars bypass this evidence cap.
    private func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var used = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let count = value[end..<next].utf8.count
            guard used + count <= maximumBytes else { break }
            used += count
            end = next
        }
        return String(value[..<end])
    }

    // MARK: - Accessibility and verification

    private func handleHighlightElement(id: Any, args: [String: Any]) {
        guard let suppliedLabel = args["label"] as? String else {
            sendErrorResult(id: id, text: "Missing required string parameter: label")
            return
        }
        let label = suppliedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= DrawingDefaults.maxHighlightLabelCharacters else {
            sendErrorResult(id: id, text: "label must be a non-empty string containing at most \(DrawingDefaults.maxHighlightLabelCharacters) characters.")
            return
        }
        if args.keys.contains("role"), !(args["role"] is String) {
            sendErrorResult(id: id, text: "role must be a string when supplied.")
            return
        }
        if let role = args["role"] as? String,
           role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendErrorResult(id: id, text: "role must be non-empty when supplied.")
            return
        }
        if args.keys.contains("match"), !(args["match"] is String) {
            sendErrorResult(id: id, text: "match must be 'exact' or 'contains' when supplied.")
            return
        }
        let matchMode: AccessibilityLabelMatchMode
        switch (args["match"] as? String)?.lowercased() ?? "exact" {
        case "exact": matchMode = .exact
        case "contains": matchMode = .contains
        default:
            sendErrorResult(id: id, text: "match must be 'exact' or 'contains'.")
            return
        }
        if args.keys.contains("occurrence"), MCPArgument.integer(args["occurrence"]) == nil {
            sendErrorResult(id: id, text: "occurrence must be a one-based integer when supplied.")
            return
        }
        if let occurrence = MCPArgument.integer(args["occurrence"]), occurrence < 1 {
            sendErrorResult(id: id, text: "occurrence must be one-based and greater than zero.")
            return
        }

        // Validate every local/style argument before resolving a process or
        // touching the Accessibility hierarchy. A malformed highlight must not
        // trigger a TCC check or cross-process AX IPC merely to fail later.
        if args.keys.contains("z"), MCPArgument.integer(args["z"]) == nil {
            sendErrorResult(id: id, text: "z must be an integer when supplied.")
            return
        }
        if args.keys.contains("z_index"), MCPArgument.integer(args["z_index"]) == nil {
            sendErrorResult(id: id, text: "z_index must be an integer when supplied.")
            return
        }
        var finishArgs = args
        if let z = MCPArgument.integer(args["z"]) {
            if let zIndex = MCPArgument.integer(args["z_index"]), zIndex != z {
                sendErrorResult(id: id, text: "z and z_index must match when both are supplied.")
                return
            }
            finishArgs["z_index"] = z
        }
        if let error = DrawRequest.validateDurationSeconds(args: args) {
            sendErrorResult(id: id, text: error)
            return
        }
        let style: HighlightStyle
        switch makeHighlightStyle(args: args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): style = value
        }

        let target: (app: AppRef, running: NSRunningApplication)
        switch resolveRunningHighlightTarget(args) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): target = value
        }

        let screens = OverlayWindowController.shared.screenSnapshot().screens
        let match: AccessibilityElementMatch
        do {
            match = try AccessibilityElementResolver.resolve(
                processID: target.running.processIdentifier,
                request: AccessibilityElementRequest(
                    label: label,
                    role: args["role"] as? String,
                    matchMode: matchMode,
                    occurrence: MCPArgument.integer(args["occurrence"])
                ),
                screens: screens
            )
        } catch {
            sendErrorResult(id: id, text: error.localizedDescription)
            return
        }
        guard let screen = screens.first(where: { $0.id == match.backingFrame.screenId }) else {
            sendErrorResult(id: id, text: "The resolved accessibility element belongs to a display that is no longer connected. Retry the lookup.")
            return
        }

        let kind: AnnotationKind
        switch makeHighlightKind(style: style, frame: match.backingFrame) {
        case .failure(let error): sendErrorResult(id: id, text: error); return
        case .success(let value): kind = value
        }

        var created: Annotation?
        let request = DrawRequest(screen: screen)
        switch request.finish(
            args: finishArgs,
            defaultColor: DrawingDefaults.pathColor,
            label: "Accessibility highlight: \(match.matchedLabel)",
            defaultsToGlobal: false,
            kind: kind,
            noun: "Accessibility element highlight",
            resolvedTargetApp: target.app,
            onAnnotationCreated: { created = $0 }
        ) {
        case .failure(let error):
            sendErrorResult(id: id, text: error)
        case .success(let message):
            var payload: [String: Any] = [
                "message": message,
                "annotationId": created?.id ?? NSNull(),
                "targetApp": ["bundleId": target.app.bundleId, "name": target.app.name],
                "anchorBehavior": "resolved once at draw time; call highlight_element again after the UI moves"
            ]
            payload["matchedElement"] = jsonObject(match) ?? NSNull()
            guard let text = jsonString(payload) else {
                sendErrorResult(id: id, text: "Created the highlight but failed to encode its accessibility metadata.")
                return
            }
            sendTextResult(id: id, text: text)
        }
    }

    private func resolveRunningHighlightTarget(_ args: [String: Any]) -> DrawOutcome<(app: AppRef, running: NSRunningApplication)> {
        if args.keys.contains("app"), !(args["app"] is String) {
            return .failure("app must be a running app's bundle id or display name when supplied.")
        }
        let app: AppRef
        if let supplied = args["app"] as? String {
            let raw = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                return .failure("highlight_element cannot target GLOBAL visibility; app must resolve to one running application so its Accessibility hierarchy can be queried.")
            }
            switch ActiveAppTracker.shared.resolve(raw) {
            case .resolved(let value): app = value
            case .ambiguous(let matches):
                let candidates = matches.map { "'\($0.name)' [\($0.bundleId)]" }.joined(separator: ", ")
                return .failure("App '\(raw)' is AMBIGUOUS across running applications: \(candidates). Retry with an exact bundle id or display name.")
            case .notFound:
                return .failure("App '\(raw)' is not running or could not be resolved. highlight_element requires a running target application with a PID.")
            }
        } else {
            guard let bundleId = ActiveAppTracker.shared.fallbackAppId else {
                return .failure("No fallback running app is available. Pass app with an exact running app bundle id or display name; GLOBAL highlighting is not supported.")
            }
            app = AppRef(bundleId: bundleId, name: ActiveAppTracker.shared.fallbackAppName ?? bundleId)
        }

        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == app.bundleId && !$0.isTerminated
        }
        guard running.count == 1, let target = running.first else {
            return running.isEmpty
                ? .failure("App '\(app.name)' [\(app.bundleId)] is no longer running, so its Accessibility hierarchy cannot be queried.")
                : .failure("App '\(app.name)' [\(app.bundleId)] has \(running.count) running processes. highlight_element refuses to guess which PID to inspect.")
        }
        return .success((app, target))
    }

    private func makeHighlightStyle(args: [String: Any]) -> DrawOutcome<HighlightStyle> {
        if let key = MCPArgument.firstInvalidSuppliedDouble(args, keys: ["padding_px", "stroke_width", "stroke_opacity", "fill_opacity"]) {
            return .failure("\(key) must be a finite number when supplied.")
        }
        if let key = MCPArgument.firstNonStringSupplied(args, keys: ["stroke_color", "color", "fill_color"]) {
            return .failure("\(key) must be a string when supplied.")
        }
        let explicitStroke = args["stroke_color"] as? String
        let colorAlias = args["color"] as? String
        if let explicitStroke, let colorAlias, explicitStroke != colorAlias {
            return .failure("stroke_color and color are aliases for highlight_element and must match when both are supplied.")
        }
        let strokeColor = explicitStroke ?? colorAlias ?? DrawingDefaults.pathColor
        let strokeWidth = MCPArgument.double(args["stroke_width"]) ?? 4
        let strokeOpacity = MCPArgument.double(args["stroke_opacity"]) ?? 1
        let fillColor = args["fill_color"] as? String
        let fillOpacity = MCPArgument.double(args["fill_opacity"]) ?? (fillColor == nil ? 0 : 0.15)
        let padding = MCPArgument.double(args["padding_px"]) ?? 8
        guard strokeWidth.isFinite, strokeWidth > 0, strokeWidth <= DrawingDefaults.maxStyleDimensionPx,
              strokeOpacity.isFinite, (0...1).contains(strokeOpacity),
              fillOpacity.isFinite, (0...1).contains(fillOpacity),
              padding.isFinite, padding >= 0, padding <= DrawingDefaults.maxStyleDimensionPx else {
            return .failure("stroke_width must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)); opacity values must be 0...1; and padding_px must be 0...\(Int(DrawingDefaults.maxStyleDimensionPx)).")
        }
        guard (colorHasVisibleAlpha(strokeColor) && strokeOpacity > 0)
                || (colorHasVisibleAlpha(fillColor) && fillOpacity > 0) else {
            return .failure("The highlight must have a visible stroke or fill.")
        }
        return .success(HighlightStyle(
            strokeColor: strokeColor, strokeWidth: strokeWidth, strokeOpacity: strokeOpacity,
            fillColor: fillColor, fillOpacity: fillOpacity, padding: padding
        ))
    }

    private func makeHighlightKind(style: HighlightStyle, frame: AccessibilityBackingRect) -> DrawOutcome<AnnotationKind> {
        let x = frame.x - style.padding
        let y = frame.y - style.padding
        let width = frame.width + 2 * style.padding
        let height = frame.height + 2 * style.padding
        guard [x, y, width, height].allSatisfy(\.isFinite),
              [x, y, width, height].allSatisfy({ abs($0) <= DrawingDefaults.maxCoordinateMagnitudePx }),
              width > 0, height > 0 else {
            return .failure("Resolved accessibility bounds are not usable for a highlight.")
        }
        let data = "M \(x) \(y) H \(x + width) V \(y + height) H \(x) Z"
        return .success(.vectorPath(
            data: data,
            strokeColorHex: style.strokeColor,
            strokeWidth: style.strokeWidth,
            strokeOpacity: style.strokeOpacity,
            fillColorHex: style.fillColor,
            fillOpacity: style.fillOpacity,
            dash: [],
            usesEvenOddFillRule: false,
            coordinateScaleX: 1,
            coordinateScaleY: 1
        ))
    }

    private func handleVerifyAnnotation(id: Any, args: [String: Any]) {
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
            let rawStoredGeometry = jsonObject(annotation.kind) ?? NSNull()
            let rawGeometryBytes = jsonString(rawStoredGeometry)?.lengthOfBytes(using: .utf8) ?? 0
            if rawGeometryBytes <= 16 * 1_024 {
                metadata["storedGeometry"] = rawStoredGeometry
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

    // MARK: - Free-draw primitives

    private func makeVectorPathKind(_ args: [String: Any], coordinateTransform: DrawRequest.CoordinateTransform = .init(scaleX: 1, scaleY: 1)) -> DrawOutcome<AnnotationKind> {
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

        let intrinsicWidth = Double(handle.widthPx)
        let intrinsicHeight = Double(handle.heightPx)
        let width: Double
        let height: Double
        if let requestedWidth, let requestedHeight {
            width = requestedWidth; height = requestedHeight
        } else if let requestedWidth {
            width = requestedWidth; height = intrinsicHeight * requestedWidth / intrinsicWidth
        } else if let requestedHeight {
            height = requestedHeight; width = intrinsicWidth * requestedHeight / intrinsicHeight
        } else {
            width = intrinsicWidth; height = intrinsicHeight
        }
        let usesRequestedSize = requestedWidth != nil || requestedHeight != nil
        let backingWidth = usesRequestedSize ? coordinateTransform.transformedX(width) : width
        let backingHeight = usesRequestedSize ? coordinateTransform.transformedY(height) : height
        guard let backingWidth, let backingHeight,
              backingWidth.isFinite, backingHeight.isFinite,
              backingWidth > 0, backingHeight > 0,
              backingWidth <= DrawingDefaults.maxImageDimensionPx,
              backingHeight <= DrawingDefaults.maxImageDimensionPx,
              rotation.isFinite, abs(rotation) <= DrawingDefaults.maxRotationDegrees,
              opacity.isFinite, (0...1).contains(opacity) else {
            _ = RasterAssetStore.shared.release(id: handle.id)
            return .failure("Image geometry must be finite with width/height > 0 and at most \(Int(DrawingDefaults.maxImageDimensionPx)) backing pixels; rotation must be within ±\(Int(DrawingDefaults.maxRotationDegrees)) degrees; opacity must be between 0 and 1.")
        }
        // An omitted size means the raster's own decoded backing-pixel size,
        // regardless of the coordinate space selected for its position. Once
        // either dimension is supplied, both resolved dimensions are geometry
        // in that selected space (including aspect-ratio-derived sibling).
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

    private func handleDrawImage(id: Any, args: [String: Any]) {
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

    private func handleDrawText(id: Any, args: [String: Any]) {
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

    private func handleDrawBatch(id: Any, args: [String: Any]) {
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
            let outcome: DrawOutcome<AnnotationKind>
            switch (item["type"] as? String)?.lowercased() {
            case "path": outcome = makeVectorPathKind(item, coordinateTransform: transform)
            case "image": outcome = loadImageKind(item, coordinateTransform: transform)
            case "text": outcome = makeTextKind(item, coordinateTransform: transform)
            default: fail("items[\(index)].type must be 'path', 'image', or 'text'."); return
            }
            switch outcome {
            case .failure(let err): fail("items[\(index)]: \(err)"); return
            case .success(let kind):
                let newAssetIDs = kind.rasterAssetIds
                if !newAssetIDs.isEmpty {
                    let newBytes = newAssetIDs.reduce(UInt64(0)) { total, assetID in
                        guard let handle = RasterAssetStore.shared.descriptor(for: assetID) else { return total }
                        return total + UInt64(handle.widthPx) * UInt64(handle.heightPx) * 4
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

    private func handleUpdateAnnotation(id: Any, args: [String: Any]) {
        guard let annotationID = (args["annotation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !annotationID.isEmpty else {
            sendErrorResult(id: id, text: "Missing required parameter: annotation_id")
            return
        }
        guard let current = AnnotationStore.shared.get(id: annotationID) else {
            sendErrorResult(id: id, text: "Annotation \(annotationID) was not found or has already expired.")
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
            sendErrorResult(id: id, text: "Annotation \(annotationID) was not found or expired while it was being updated.")
        case .stale:
            sendErrorResult(id: id, text: "Annotation \(annotationID) changed while this update was being prepared. It was left unchanged; re-fetch it with list_annotations and retry the patch.")
        case .rejected(.payloadBytes(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because retained vector/text payload would become \(attempted) bytes, exceeding the \(limit)-byte session limit. The existing annotation was left unchanged.")
        case .rejected(.primitiveCount(let limit, let attempted)):
            sendErrorResult(id: id, text: "The update was not applied because retained primitive count would become \(attempted), exceeding the \(limit)-primitive session limit. The existing annotation was left unchanged.")
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
        return .success(Annotation(
            id: current.id, screenId: current.screenId, kind: kind, colorHex: current.colorHex,
            label: current.label, appId: current.appId, appName: current.appName,
            expiresAt: current.expiresAt, opacity: opacity,
            offsetX: offsetX, offsetY: offsetY,
            zIndex: MCPArgument.integer(args["z_index"]) ?? current.zIndex,
            createdAt: current.createdAt
        ))
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

    // MARK: - Diagnostic payload builders

    /// `JSONSerialization` cannot encode Swift's `nil`; it needs `NSNull`. And
    /// `optional ?? NSNull()` does not type-check (mismatched operand types), so
    /// this does the widening to `Any` explicitly. Used so that an absent app
    /// link serialises as an explicit JSON `null` -- which is meaningful here
    /// ("global, visible everywhere") -- rather than the key vanishing.
    private func jsonValue(_ value: String?) -> Any {
        guard let value = value else { return NSNull() }
        return value
    }

    /// Encodes a `Codable` value and immediately decodes it back through
    /// `JSONSerialization`, producing plain `[String: Any]`/`[Any]`-shaped
    /// data. Used where an `Encodable` model (`[ScreenInfo]`, an
    /// `Annotation`) needs to be embedded inside a hand-built
    /// `JSONSerialization` payload alongside sibling keys that are not
    /// themselves `Codable` -- `get_screens` and `list_annotations` both did
    /// this exact two-step conversion by hand; this is the one copy.
    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Serializes a `JSONSerialization`-compatible object (built from
    /// `[String: Any]`/`[Any]`/`String`/`Bool`/`NSNumber`/`NSNull`) to a
    /// UTF-8 JSON string. `get_screens`, `list_annotations`, and
    /// `get_active_app` each built and threw away this exact
    /// `data(withJSONObject:)` -> `String(data:encoding:)` pair individually;
    /// this is the one copy.
    private func jsonString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Records precisely how the serialized annotation geometry should be
    /// interpreted. Vector SVG retains the caller's source-space coordinates
    /// plus a renderer scale; text/image positions have already been converted
    /// to backing pixels. Calling all of this `BackingPx` was false for paths.
    private func storedGeometryCoordinateSemantics(_ kind: AnnotationKind) -> [String: Any] {
        switch kind {
        case let .vectorPath(_, _, _, _, _, _, _, _, scaleX, scaleY):
            return [
                "storedCoordinateValues": "SVG source coordinates selected at creation time",
                "rendererScaleToBackingPixels": ["x": scaleX, "y": scaleY],
                "styleDimensions": "backing pixels"
            ]
        case .image:
            return [
                "storedCoordinateValues": "backing pixels",
                "styleDimensions": "backing pixels"
            ]
        case .text:
            return [
                "storedCoordinateValues": "backing pixels",
                "styleDimensions": "backing pixels"
            ]
        case let .batch(items):
            return [
                "storedCoordinateValues": "each item uses its own kind semantics",
                "items": items.map { storedGeometryCoordinateSemantics($0.kind) }
            ]
        }
    }

    /// `list_annotations` is deliberately paged and response-budgeted. A
    /// persistent batch can legally retain megabytes of SVG, so returning every
    /// raw annotation in one MCP text block would otherwise exceed transport
    /// limits even though storage itself is bounded.
    private func buildAnnotationListJSON(args: [String: Any]) -> DrawOutcome<String> {
        if args.keys.contains("offset"), MCPArgument.integer(args["offset"]) == nil {
            return .failure("offset must be a non-negative integer when supplied.")
        }
        if args.keys.contains("limit"), MCPArgument.integer(args["limit"]) == nil {
            return .failure("limit must be an integer between 1 and \(DrawingDefaults.maxAnnotationListPageItems) when supplied.")
        }
        let requestedOffset = MCPArgument.integer(args["offset"]) ?? 0
        let requestedLimit = MCPArgument.integer(args["limit"]) ?? DrawingDefaults.maxAnnotationListPageItems
        guard requestedOffset >= 0 else {
            return .failure("offset must be a non-negative integer when supplied.")
        }
        guard requestedLimit >= 1, requestedLimit <= DrawingDefaults.maxAnnotationListPageItems else {
            return .failure("limit must be an integer between 1 and \(DrawingDefaults.maxAnnotationListPageItems) when supplied.")
        }
        let annotations = AnnotationStore.shared.getAll()
        let activeId = ActiveAppTracker.shared.currentAppId
        let captureVisible = OverlayWindowController.shared.isCaptureVisible
        let annotationsSuspended = OverlayWindowController.shared.isAnnotationsSuspended

        // `ActiveAppTracker.displayName(forBundleId:)` is only consulted as a
        // fallback for annotations whose `appName` was never captured at
        // creation time (see `Annotation.appName`'s doc comment), but each
        // call independently hops to the main thread to enumerate
        // `NSWorkspace.runningApplications`. With N such annotations that was
        // N main-thread round trips per `list_annotations` call. This memo
        // resolves each DISTINCT bundle id at most once per call by caching
        // as it goes, rather than changing `ActiveAppTracker` itself.
        var displayNameMemo: [String: String?] = [:]
        func resolvedDisplayName(forBundleId bundleId: String) -> String? {
            if let cached = displayNameMemo[bundleId] { return cached }
            let name = ActiveAppTracker.shared.displayName(forBundleId: bundleId)
            displayNameMemo[bundleId] = name
            return name
        }

        var entries: [[String: Any]] = []
        let expiryFormatter = ISO8601DateFormatter()
        expiryFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let start = min(requestedOffset, annotations.count)
        let requestedEnd = min(annotations.count, start + requestedLimit)

        func enrichedEntry(for annotation: Annotation) -> [String: Any]? {
            // Round-tripping through the existing Codable encoding keeps the
            // `kind` payload byte-identical to its existing Codable shape.
            guard var object = jsonObject(annotation) as? [String: Any] else {
                return nil
            }
            // Optionals are omitted entirely by the synthesized encoder, so set
            // them explicitly (JSONSerialization needs NSNull, not nil).
            object["appId"] = jsonValue(annotation.appId)
            object["appName"] = jsonValue(
                annotation.appName ?? annotation.appId.flatMap(resolvedDisplayName(forBundleId:))
            )
            object["type"] = annotation.kind.typeName
            object["scope"] = annotation.appId == nil ? "global" : "app-linked"
            let wouldBeVisibleWithoutSuspension = captureVisible || annotation.appId == nil || annotation.appId == activeId
            object["wouldBeVisibleWithoutSuspension"] = wouldBeVisibleWithoutSuspension
            object["isVisibleNow"] = !annotationsSuspended && wouldBeVisibleWithoutSuspension
            if let expiresAt = annotation.expiresAt {
                object["expiresAt"] = expiryFormatter.string(from: expiresAt)
                object["remainingSeconds"] = annotation.remainingSeconds(
                    now: now, uptime: ProcessInfo.processInfo.systemUptime
                ) ?? NSNull()
            } else {
                object["expiresAt"] = NSNull()
                object["remainingSeconds"] = NSNull()
            }
            guard let fullEntryText = jsonString(object) else { return nil }
            guard fullEntryText.lengthOfBytes(using: .utf8) <= DrawingDefaults.maxAnnotationListEntryBytes else {
                let geometry = object.removeValue(forKey: "kind")
                let geometryBytes = geometry.flatMap(jsonString)?.lengthOfBytes(using: .utf8) ?? 0
                object["geometryOmitted"] = true
                object["geometryByteCount"] = geometryBytes
                object["geometryNote"] = "Geometry was omitted from this list page to keep the bounded MCP response safe. Use verify_annotation with this ID for a rendered, bounded crop."
                return object
            }
            return object
        }

        func payload(for page: [[String: Any]], nextOffset: Int) -> [String: Any] {
            let hasMore = nextOffset < annotations.count
            return [
                "activeApp": [
                    "bundleId": jsonValue(activeId),
                    "name": jsonValue(ActiveAppTracker.shared.currentAppName)
                ] as [String: Any],
                "captureVisible": captureVisible,
                "annotationsSuspended": annotationsSuspended,
                // `count` remains the number in this response, matching the
                // old field when the entire list fits. `totalCount` exposes
                // the full store for callers that page.
                "count": page.count,
                "totalCount": annotations.count,
                "offset": start,
                "limit": requestedLimit,
                "returnedCount": page.count,
                "nextOffset": hasMore ? nextOffset : NSNull(),
                "truncated": hasMore,
                "annotations": page,
                "note": "With captureVisible=false, an annotation is drawn only when scope='global' or its appId equals activeApp.bundleId. With captureVisible=true, every annotation is drawn for capture-debug placement checks. When annotationsSuspended=true, every retained annotation has isVisibleNow=false because all overlay windows are ordered out; wouldBeVisibleWithoutSuspension reports its normal filter result. External capture filters still decide whether the overlay is included. expiresAt is RFC 3339 and remainingSeconds are null for persistent annotations. list_annotations is paged (offset/limit); oversized individual geometry is summarized so this response remains bounded."
            ]
        }

        // NOTE on what this loop still does the expensive way: each iteration
        // below re-serializes the ENTIRE growing `candidate` array through
        // `JSONSerialization` purely to size-check it against
        // maxAnnotationListTextBytes, which is O(n^2) work bounded only by
        // maxAnnotationListPageItems (100). An incremental byte-accounting
        // rewrite that tracks the running serialized size without
        // re-serializing already-included entries was deliberately NOT done
        // here: producing an exact byte count without calling
        // `JSONSerialization` again would mean manually reconstructing its
        // compact-mode output (concatenating each entry's own serialized
        // text with "," separators) and trusting that (a) `JSONSerialization`
        // never inserts incidental whitespace in non-pretty-printed mode and
        // (b) a dictionary with a fixed key set serializes its keys in the
        // same relative order every time within one process run. Both are
        // true in practice, but neither is a documented Foundation contract,
        // and this function is covered by the wire-snapshot fixtures'
        // byte-for-byte pin plus the maxAnnotationListTextBytes cutoff being
        // NON-NEGOTIABLE (same last-included item, same nextOffset). Getting
        // this wrong would be silent and hard to notice by inspection, so
        // the redundant re-serialization stays; only the one PROVABLY
        // byte-identical redundancy below (reusing the last iteration's own
        // already-computed text instead of recomputing it once more after
        // the loop) is removed.
        var next = start
        var lastCandidateText: String?
        while next < requestedEnd {
            guard let entry = enrichedEntry(for: annotations[next]) else {
                return .failure("Failed to encode annotation \(annotations[next].id) for list_annotations.")
            }
            let candidate = entries + [entry]
            guard let candidateText = jsonString(payload(for: candidate, nextOffset: next + 1)) else {
                return .failure("Failed to encode annotation list.")
            }
            if candidateText.lengthOfBytes(using: .utf8) > DrawingDefaults.maxAnnotationListTextBytes {
                // One summarized entry is always far below the cap; if even it
                // cannot fit, return a normal tool error rather than handing a
                // potentially oversized payload to the transport layer.
                if entries.isEmpty {
                    return .failure("The requested annotation summary could not fit in the bounded list response.")
                }
                break
            }
            entries = candidate
            next += 1
            lastCandidateText = candidateText
        }
        // When the loop above ran to completion by exhausting `requestedEnd`
        // (as opposed to exiting early via `break`), `lastCandidateText` was
        // already computed for this EXACT (entries, nextOffset: next) pair on
        // the final iteration -- reuse it instead of re-serializing the same
        // page a second time. `next == requestedEnd` only holds on that
        // normal-exit path: `break` always fires while `next < requestedEnd`
        // still holds, and `next` is never advanced on the failing iteration
        // that triggers it.
        if let lastCandidateText, next == requestedEnd {
            return .success(lastCandidateText)
        }
        guard let text = jsonString(payload(for: entries, nextOffset: next)) else {
            return .failure("Failed to encode annotation list.")
        }
        return .success(text)
    }

    /// `get_active_app` output.
    private func buildActiveAppJSON() -> String {
        let tracker = ActiveAppTracker.shared
        let raw = tracker.rawFrontmostApp()

        let payload: [String: Any] = [
            "frontmost": [
                "bundleId": jsonValue(tracker.currentAppId),
                "name": jsonValue(tracker.currentAppName)
            ] as [String: Any],
            "fallback": [
                "bundleId": jsonValue(tracker.fallbackAppId),
                "name": jsonValue(tracker.fallbackAppName)
            ] as [String: Any],
            "rawFrontmost": [
                "bundleId": jsonValue(raw?.bundleId),
                "name": jsonValue(raw?.name)
            ] as [String: Any],
            "captureVisible": OverlayWindowController.shared.isCaptureVisible,
            "annotationsSuspended": OverlayWindowController.shared.isAnnotationsSuspended,
            "note": "'frontmost' is the app whose app-linked annotations would normally be eligible to appear. When annotationsSuspended=true, this process has intentionally ordered its overlay windows out, so no retained annotation is on screen from this process even if it matches frontmost. 'fallback' is what an untagged draw_* call links to: the last app that was frontmost excluding AI Chalkboard and Claude -- because when you receive a draw request, Claude's own window is frontmost, so tagging the true frontmost app would link every annotation to Claude and it would never show over the app the user meant. 'rawFrontmost' is the unfiltered NSWorkspace value, for debugging only. A null fallback means an untagged draw becomes GLOBAL."
        ]

        guard let text = jsonString(payload) else {
            return "Error: failed to encode active app info."
        }
        return text
    }
}
