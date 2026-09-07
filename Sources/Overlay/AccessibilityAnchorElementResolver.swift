import Foundation

/// Production `AnchorElementResolving` conformance (see `AnchorTracker.swift`
/// for that protocol): re-runs `highlight_element`'s Accessibility/UI
/// Automation lookup for one `.element`-mode anchor once its target window
/// has settled, and turns a fresh match into a rebuilt highlight kind via
/// `HighlightOutlineGeometry.rebuiltKind(from:spec:newFrame:)`.
///
/// ONE CONFORMANCE, BOTH PLATFORMS. This lives next to
/// `AccessibilityElementResolver` (same directory) because that type already
/// presents ONE shape on both macOS and Windows -- same type names
/// (`AccessibilityElementResolver`, `AccessibilityElementRequest`,
/// `AccessibilityElementMatch`, `AccessibilityElementResolverError`,
/// `AccessibilityLabelMatchMode`), same static members, same `resolve(
/// processID:request:screens:) throws -> AccessibilityElementMatch` shape
/// modulo the process-id type (see that method's own doc comment on each
/// platform). The only platform split this file needs at all is therefore
/// the one-line widening of `AnchorWindowTarget.processId` (`Int64`) to
/// whichever concrete process-id type `resolve` expects here (`pid_t` on
/// macOS, `UInt32` on Windows) -- everything else, including the entire
/// reason-code mapping below, is written once and compiles unchanged on
/// both.
///
/// THREAD SAFETY / CRITICAL FINDING: `AnchorTracker` calls `reresolve` from
/// its own dedicated `elementQueue`, never from `samplingQueue` (see that
/// class's "THREAD SAFETY" doc comment for why an AX/UIA walk must never
/// share a queue with the sampler). This is safe because
/// `AccessibilityElementResolver.resolve` ALREADY runs off the main thread
/// in production today, unchanged by this file: `MCPServer`'s `start()`
/// dispatches `readLoop`/`handleToolsCall` (and therefore
/// `handleHighlightElement`, which calls this exact `resolve`) onto
/// `DispatchQueue.global(qos: .userInitiated)` (see MCPServer.swift), never
/// the main thread. `resolve` itself performs no main-thread hop of its
/// own: on macOS it is entirely synchronous, read-only, cross-process AX IPC
/// (`AXUIElementCopyAttributeValue` and friends) plus pure arithmetic
/// against an already-captured `screens` snapshot -- it registers no
/// `AXObserver` notification, which is the one AX facility that genuinely
/// needs a run loop; on Windows it is a single synchronous call into
/// `chalk_uia_find_element`, likewise with no thread affinity. Its
/// wall-clock budget (`timeoutSeconds`, capped at `maxTraversalTimeoutSeconds`
/// = 10s) is enforced via `ProcessInfo.processInfo.systemUptime` on macOS
/// (checked at each BFS step, plus a bounded per-element AX messaging
/// timeout) and via the shim's own deadline on Windows -- neither depends on
/// a run loop, a timer, or any particular thread, so the caller's timeout is
/// honoured from `elementQueue` exactly as it already is from
/// `DispatchQueue.global` today. In short: this was already being called
/// off the main thread before this file existed, and nothing about calling
/// it again from a second background queue changes that.
public struct AccessibilityAnchorElementResolver: AnchorElementResolving {
    public init() {}

    public func reresolve(
        annotation: Annotation, spec: AnchorElementSpec,
        target: AnchorWindowTarget, screens: [ScreenInfo]
    ) -> AnchorElementReresolution {
        #if os(macOS)
        guard let processID = pid_t(exactly: target.processId) else { return .issue("not_found") }
        #elseif os(Windows)
        guard let processID = UInt32(exactly: target.processId) else { return .issue("not_found") }
        #endif

        guard let matchMode = AccessibilityLabelMatchMode(rawValue: spec.matchMode) else {
            // `spec.matchMode` is written only by this codebase's own
            // `makeAnchorElementSpec` (MCPToolHandlers+Highlight.swift) from
            // an already-validated `match` argument, so this is unreachable
            // in practice -- but a fixed reason code beats trapping on a
            // value this type does not otherwise expect.
            return .issue("unavailable")
        }
        // `0` is `makeAnchorElementSpec`'s own sentinel for "the original
        // call did not supply `occurrence`" -- translate it back to `nil`
        // here to reproduce that call's uniqueness requirement exactly. This
        // is the SAME 0-means-"require exactly one" convention
        // `AccessibilityElementRequest.occurrence == nil` already has on
        // macOS and `chalk_uia_find_element`'s `occurrence` parameter
        // already has on Windows.
        let occurrence = spec.occurrence > 0 ? spec.occurrence : nil
        let request = AccessibilityElementRequest(
            label: spec.label,
            role: spec.role,
            matchMode: matchMode,
            occurrence: occurrence,
            maxNodes: spec.maxNodes,
            timeoutSeconds: spec.timeoutSeconds
        )

        let match: AccessibilityElementMatch
        do {
            match = try AccessibilityElementResolver.resolve(processID: processID, request: request, screens: screens)
        } catch let error as AccessibilityElementResolverError {
            return .issue(Self.reasonCode(for: error))
        } catch {
            // Not `AccessibilityElementResolverError` at all -- unreachable
            // today (both platforms' `resolve` only ever throws that type),
            // but a fixed reason code is still required over crashing or
            // forwarding whatever this unexpected error's text says.
            return .issue("unavailable")
        }

        let newFrame = CGRect(
            x: match.backingFrame.x, y: match.backingFrame.y,
            width: match.backingFrame.width, height: match.backingFrame.height
        )
        guard let kind = HighlightOutlineGeometry.rebuiltKind(from: annotation.kind, spec: spec, newFrame: newFrame) else {
            // A match was found, but it could not be turned into paintable
            // geometry (e.g. `annotation.kind` is no longer `.vectorPath`, or
            // the freshly matched bounds fail `HighlightOutlineGeometry
            // .pathData`'s own finite/magnitude/positive-extent guard).
            // Neither is a lookup failure, so none of "ambiguous"/
            // "not_found"/"permission"/"timeout" describes it; "unavailable"
            // is the closest fit among the fixed set.
            return .issue("unavailable")
        }
        return .resolved(kind: kind, screenId: match.backingFrame.screenId)
    }

    /// Maps every `AccessibilityElementResolverError` case onto ONE of
    /// `AnchorElementReresolution.issue`'s five fixed reason codes --
    /// `"ambiguous"`, `"not_found"`, `"unavailable"`, `"permission"`,
    /// `"timeout"` -- NEVER the case's own `errorDescription`, which is
    /// caller-facing prose built (in several cases, e.g. `.noMatches`,
    /// `.ambiguous`) directly from the caller's label/role and even sampled
    /// UI text. That is exactly the caller/UI text `Logger`'s existing
    /// privacy rule forbids persisting (see `AnchorElementSpec`'s own doc
    /// comment: "`label` in particular is caller-supplied, app-specific
    /// text... never logged", and `AnchorTracker`'s "the element label is
    /// caller text and a UI string: it must never reach the log"). This
    /// mapping is the one place that boundary is enforced: `AnchorTracker`
    /// only ever logs the fixed code this function returns, never anything
    /// derived from the thrown error itself.
    ///
    /// Grouping rationale (both platforms):
    /// - `"permission"`: the AX/UIA permission or privilege-boundary cases
    ///   (`accessibilityNotTrusted`, Windows' `elevationBoundary`).
    /// - `"timeout"`: the target app failed to answer in time
    ///   (`applicationBusy`, macOS's `traversalTimedOut`) -- transient by
    ///   nature, worth another attempt on the tracker's own retry cadence.
    /// - `"ambiguous"`: more than one element now matches.
    /// - `"not_found"`: the label no longer resolves to a single
    ///   highlightable element under this search (`noMatches`,
    ///   `occurrenceOutOfRange`, `matchesHaveNoUsableFrame`, and macOS's
    ///   `labelSeenUnderOtherRoles` -- exposed under a different role than
    ///   the one this spec pinned).
    /// - `"unavailable"`: everything else blocking a resolve for reasons
    ///   unrelated to the above -- the process/app itself
    ///   (`invalidProcessID`, `applicationUnavailable`), a structural
    ///   traversal-budget exhaustion (`traversalLimitReached`) rather than a
    ///   wall-clock timeout, a geometry that cannot be placed
    ///   (`frameCannotBeMapped`), a malformed request (`invalidRequest`,
    ///   practically unreachable -- see `reresolve`'s validation above),
    ///   Windows' `roleFilterNotSupported` (practically unreachable too:
    ///   `spec.role` can only be non-nil here if the ORIGINAL
    ///   `highlight_element` call had already succeeded with a role on this
    ///   platform, which `roleFilterNotSupported` itself would have
    ///   prevented), and Windows' `workerPoolExhausted` -- deliberately NOT
    ///   grouped with `"timeout"` even though it is also a hung-provider
    ///   condition: the header documents `CHALK_ERR_UIA_TOO_MANY_PENDING` as
    ///   NON-retryable (retrying only adds another stuck worker thread to an
    ///   already-saturated pool), whereas `"timeout"` is reserved for
    ///   conditions worth another attempt on the tracker's own retry
    ///   cadence. It groups instead with `traversalLimitReached`: both are a
    ///   structural resource budget exhausted, not a wall-clock timeout.
    ///
    /// Exhaustive `switch`, no `default:`: `AccessibilityElementResolverError`
    /// is declared in this same module (`AccessibilityElementResolver.swift`,
    /// this directory), so a case this mapping forgets fails the BUILD, not
    /// a caller at runtime.
    static func reasonCode(for error: AccessibilityElementResolverError) -> String {
        switch error {
        #if os(macOS)
        case .accessibilityNotTrusted:
            return "permission"
        case .applicationBusy, .traversalTimedOut:
            return "timeout"
        case .ambiguous:
            return "ambiguous"
        case .noMatches, .labelSeenUnderOtherRoles, .occurrenceOutOfRange, .matchesHaveNoUsableFrame:
            return "not_found"
        case .invalidRequest, .invalidProcessID, .applicationUnavailable, .traversalLimitReached, .frameCannotBeMapped:
            return "unavailable"
        #elseif os(Windows)
        case .accessibilityNotTrusted, .elevationBoundary:
            return "permission"
        case .applicationBusy:
            return "timeout"
        case .ambiguous:
            return "ambiguous"
        case .noMatches, .occurrenceOutOfRange, .matchesHaveNoUsableFrame:
            return "not_found"
        case .invalidRequest, .invalidProcessID, .applicationUnavailable, .traversalLimitReached,
             .frameCannotBeMapped, .roleFilterNotSupported, .workerPoolExhausted:
            return "unavailable"
        #endif
        }
    }
}
