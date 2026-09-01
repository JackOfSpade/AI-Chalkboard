import Foundation

/// The compositor/window-state authority `sendSuspensionLeaseResult` cites as
/// evidence below. Named per platform for the same reason as
/// MCPToolCatalog's split prose: this note reaches the MCP caller, and
/// WindowServer does not exist on Windows, which instead samples this
/// process's own Win32 window state plus DWM's cloaking flag (see
/// SuspensionQuiescence's Windows branch).
#if os(macOS)
private let quiescenceObservationSource = "WindowServer"
#elseif os(Windows)
private let quiescenceObservationSource = "Win32/DWM window-state"
#endif

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

extension MCPServer {
    /// Validates and acquires a bounded, token-scoped suspension lease.  The
    /// strict boundary matters: a malformed retry must not quietly acquire a
    /// fresh lease that its caller cannot later release.
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleAcquireAnnotationSuspensionLease(id: Any, args: [String: Any]) {
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
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func handleReleaseAnnotationSuspensionLease(id: Any, args: [String: Any]) {
        guard Set(args.keys) == Set(["lease_token"]),
              let token = args["lease_token"] as? String,
              isCanonicalSuspensionLeaseToken(token) else {
            sendErrorResult(id: id, text: "resume_annotations requires exactly one lease_token returned by suspend_annotations.")
            return
        }
        let result = SuspensionLeaseCoordinator.shared.releaseLease(token: token)
        sendSuspensionLeaseResult(id: id, operation: "release", result: result)
    }

    // Internal rather than private so `@testable` can exercise it directly:
    // this is pure token-shape validation guarding a capability, and it is
    // worth pinning against a unit test rather than only reaching it through
    // a full tools/call round trip.
    //
    // The coordinator owns the canonical token shape (it mints and validates
    // every token). Forward rather than keeping a second byte-level copy here:
    // two independent implementations of the same rule can only drift, and the
    // permissive one wins at a capability boundary.
    func isCanonicalSuspensionLeaseToken(_ token: String) -> Bool {
        SuspensionLeaseCoordinator.isCanonicalToken(token)
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
                ? "A suspension lease is active and two consecutive conservative \(quiescenceObservationSource) samples observed no candidate AI Chalkboard overlay windows. This is point-in-time click-workaround evidence only; it is not raw-framebuffer or occlusion proof. Release this exact leaseToken promptly."
                : "A suspension lease is active, but conservative \(quiescenceObservationSource) observation was not quiescent. Do not click through yet; retry or let the short lease expire."
        } else {
            if releaseWithRemainingLeaseUnsettled {
                note = "This lease was durably released, but another active lease remains and bounded \(quiescenceObservationSource) observation did not confirm that every discovered Chalkboard overlay settled off screen. Treat this response as an error and do not click through yet."
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
            "limitation": "\(quiescenceObservationSource) metadata is not raw-framebuffer or occlusion proof. A future process/window can appear after this bounded observation; true visible-highlight-while-clicking still requires the click dispatcher to honor ignoresMouseEvents.",
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
    // Internal rather than private for the same reason as
    // isCanonicalSuspensionLeaseToken above: multi-byte boundary handling is
    // exactly the kind of logic that breaks silently, so it is unit tested.
    func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
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
}
