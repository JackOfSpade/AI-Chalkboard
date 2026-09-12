#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// The two intentionally small text matching modes supported by accessibility
/// element lookup.  Exact matching is the safe default: UI trees commonly
/// contain several controls whose labels merely contain the same word.
public enum AccessibilityLabelMatchMode: String, Codable, Equatable {
    case exact
    case contains
}

/// Screen-space geometry returned by the Accessibility API.  Accessibility
/// hit-testing uses top-left-origin screen coordinates; the conversion into an
/// annotation's screen-local backing pixels is kept explicit below.
public struct AccessibilityScreenRect: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The output geometry that free-draw tools consume: top-left-origin backing
/// pixels local to one physical display.
public struct AccessibilityBackingRect: Codable, Equatable {
    public let screenId: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(screenId: String, x: Double, y: Double, width: Double, height: Double) {
        self.screenId = screenId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Result of a read-only AX lookup.  The element reference intentionally is
/// not retained: an `AXUIElement` can become stale as soon as the target app
/// changes its UI, while this immutable geometry is safe to store in an
/// annotation and expose in an MCP result.
public struct AccessibilityElementMatch: Codable, Equatable {
    public let matchedAttribute: String
    public let matchedLabel: String
    public let role: String?
    public let accessibilityFrame: AccessibilityScreenRect
    public let backingFrame: AccessibilityBackingRect

    public init(matchedAttribute: String, matchedLabel: String, role: String?,
                accessibilityFrame: AccessibilityScreenRect, backingFrame: AccessibilityBackingRect) {
        self.matchedAttribute = matchedAttribute
        self.matchedLabel = matchedLabel
        self.role = role
        self.accessibilityFrame = accessibilityFrame
        self.backingFrame = backingFrame
    }
}

/// A compact candidate description returned in an ambiguity error, and also
/// used to sample the labels an application DOES expose when a lookup finds
/// no match at all.  Either way it gives an MCP caller enough information to
/// correct a label, add a role, or add an occurrence without leaking an
/// entire application's accessibility tree.
public struct AccessibilityElementCandidate: Codable, Equatable {
    public let matchedAttribute: String
    public let matchedLabel: String
    public let role: String?
    /// Where this candidate actually IS, in screen-local backing pixels --
    /// the single most important field for picking an `occurrence`, and the
    /// reason this struct is no longer label/role only.
    ///
    /// Without it, five identically-labelled candidates render as five
    /// IDENTICAL strings, so a caller choosing between them is guessing: a
    /// measured session ringed a menu-bar item roughly 4,000 backing pixels
    /// away from the Inspector row it meant, then fell back to eyeballing a
    /// screenshot -- the exact misplacement path element anchoring exists to
    /// avoid. The BFS already holds this rect at match time, so carrying it
    /// here costs no extra cross-process IPC at all.
    ///
    /// `AccessibilityBackingRect?` rather than five loose optional numbers
    /// because that type ALREADY is exactly (screenId, x, y, width, height)
    /// in exactly these units, and because it is literally the same value
    /// `resolvedMatch` publishes if this candidate is the one selected --
    /// so the ambiguity list previews the rect that would really be drawn,
    /// not a separately-derived approximation of it.
    ///
    /// Optional for two distinct, genuinely reachable reasons: exposed-label
    /// SAMPLE entries (the `.noMatches` preview) describe nodes whose frame
    /// was never read at all, and a real match's frame can still fail to map
    /// onto one display (see `backingRect`'s straddling-display rejection),
    /// which is worth showing in the list rather than hiding.
    public let backingFrame: AccessibilityBackingRect?

    public init(matchedAttribute: String, matchedLabel: String, role: String?,
                backingFrame: AccessibilityBackingRect? = nil) {
        self.matchedAttribute = matchedAttribute
        self.matchedLabel = matchedLabel
        self.role = role
        self.backingFrame = backingFrame
    }
}

public struct AccessibilityElementRequest: Equatable {
    public let label: String
    public let role: String?
    public let matchMode: AccessibilityLabelMatchMode
    /// One-based match index.  Omit it to require exactly one candidate.
    public let occurrence: Int?
    public let maxNodes: Int
    /// Wall-clock budget for the whole traversal.
    ///
    /// Paired with `maxNodes` ON PURPOSE: the two bound the same walk from
    /// different directions, and raising only one is useless. A measured
    /// DaVinci Resolve session enumerates roughly 5,200 elements per second,
    /// so the 3,000-node default costs about 0.6s while the 10,000-node
    /// ceiling costs about 1.9s -- which the old fixed 2.0s deadline would
    /// have cut off right at the edge, turning a raised node budget into a
    /// timeout instead of an answer.
    public let timeoutSeconds: TimeInterval

    public init(label: String, role: String? = nil,
                matchMode: AccessibilityLabelMatchMode = .exact,
                occurrence: Int? = nil, maxNodes: Int = AccessibilityElementResolver.defaultMaxNodes,
                timeoutSeconds: TimeInterval = AccessibilityElementResolver.defaultTraversalTimeoutSeconds) {
        self.label = label
        self.role = role
        self.matchMode = matchMode
        self.occurrence = occurrence
        self.maxNodes = maxNodes
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct AccessibilityTrustStatus: Codable, Equatable {
    public let trusted: Bool
    public let promptRequested: Bool
    public let note: String

    public init(trusted: Bool, promptRequested: Bool, note: String) {
        self.trusted = trusted
        self.promptRequested = promptRequested
        self.note = note
    }
}

public enum AccessibilityElementResolverError: LocalizedError, Equatable {
    case accessibilityNotTrusted
    case invalidRequest(String)
    case invalidProcessID
    case applicationUnavailable
    /// The application element's `kAXWindows`/`kAXChildren` attribute request
    /// did not get an answer inside `perElementMessagingTimeout` -- distinct
    /// from `applicationUnavailable`, which means the request answered and
    /// the tree genuinely has nothing in it.  Conflating the two is what
    /// caused a real, measured bug: against a live DaVinci Resolve, a label
    /// that unambiguously IS exposed to Accessibility ("Tracking", an
    /// Inspector row label) still failed this way on 1 of 12 attempts,
    /// purely because Resolve was busy -- and the resulting
    /// `applicationUnavailable` message told the calling agent the app
    /// lacked Accessibility metadata, so it gave up on element anchoring and
    /// eyeballed a screenshot instead, placing its annotation inaccurately.
    case applicationBusy
    case traversalLimitReached(Int)
    case traversalTimedOut(seconds: Double)
    /// `exposedSample` is a bounded, de-duplicated sample of labels the
    /// traversal actually found published (see `AccessibilityElementResolver
    /// .recordExposedSample`); it is empty when the tree published nothing
    /// sample-worthy at all.
    case noMatches(label: String, role: String?, exposedSample: [AccessibilityElementCandidate])
    /// The label WAS found, under one or more roles -- just never under the
    /// `role` the caller supplied. Split out of `.noMatches` because the two
    /// need opposite advice and `.noMatches`'s "the UI may not expose that
    /// control to macOS Accessibility" is flatly FALSE here: the control is
    /// exposed, the role string simply did not match.
    ///
    /// Role comparison is verbatim `String` equality against the app's own
    /// `kAXRole` value, with no case folding and no "AX" prefixing, so
    /// `role: "button"` matches nothing at all against a live `AXButton` --
    /// the measured shape of this bug. Telling a caller in that situation
    /// that the UI lacks Accessibility metadata teaches it to abandon element
    /// anchoring entirely and eyeball a screenshot, which is precisely the
    /// misplacement path this tool exists to remove.
    case labelSeenUnderOtherRoles(label: String, requestedRole: String, seenRoles: [String])
    case ambiguous(matches: [AccessibilityElementCandidate])
    /// `framelessMatchCount` is how many ADDITIONAL elements matched the
    /// label but were skipped for publishing no usable screen frame (see
    /// `matchesHaveNoUsableFrame`). It is carried here too because a caller
    /// who can see, say, 5 "Inspector" labels on screen has no way to
    /// understand why occurrence 3 is out of range if the error only reports
    /// the smaller HIGHLIGHTABLE count -- it looks like a miscount rather
    /// than a deliberate exclusion.
    case occurrenceOutOfRange(requested: Int, available: Int, framelessMatchCount: Int)
    /// Replaces the old `selectedElementHasNoFrame`, which named exactly one
    /// already-selected element. That shape went unreachable once a
    /// frameless match can no longer be selected at all: `resolve()`'s BFS
    /// loop now reads each match's frame at match time and only lets a match
    /// with a usable frame enter `matches`, so whichever element `resolve()`
    /// goes on to select already has one. What remains reachable is the
    /// case where EVERY element that matched the label lacked a usable
    /// frame, leaving nothing to select at all -- `matchCount` is how many
    /// such elements were seen.
    case matchesHaveNoUsableFrame(matchCount: Int)
    case frameCannotBeMapped

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "AI Chalkboard does not have macOS Accessibility permission. Grant it in System Settings > Privacy & Security > Accessibility, then retry; request a system prompt explicitly instead of prompting during an ordinary lookup."
        case .invalidRequest(let message):
            return "Invalid accessibility lookup request: \(message)"
        case .invalidProcessID:
            return "The target app does not have a valid running process ID, so its accessibility tree cannot be inspected."
        case .applicationUnavailable:
            return "The target app's accessibility hierarchy is unavailable. Ensure the app is running and exposes Accessibility metadata."
        case .applicationBusy:
            return "The target app did not answer its accessibility attribute request within the messaging timeout. This is usually transient (the app was busy), not a missing Accessibility implementation; retry the lookup rather than assuming the UI is not exposed to macOS Accessibility."
        case .traversalLimitReached(let limit):
            // The old wording here said "Refine the app, label, or role and
            // retry", which is advice the caller CANNOT act on: this cap
            // counts elements VISITED by the breadth-first walk, and the walk
            // visits every element regardless of what is being searched for.
            // A narrower label or role changes which nodes MATCH, never how
            // many are inspected, so following that advice reproduced the
            // identical failure every time. Name the two budgets that
            // actually move, and be honest that for some applications no
            // bounded read is enough.
            //
            // The uniqueness caveat is attached to the occurrence advice
            // rather than left implicit: this message TELLS the caller to
            // short-circuit the walk, and a short-circuited walk provably
            // never learns whether a second element shares the label, so the
            // advice must ship with the check that covers what it gave up.
            return "Stopped after inspecting \(limit) accessibility elements without finishing the tree. This cap counts elements VISITED, not candidates, so narrowing label or role does not lower it. Try supplying occurrence FIRST (e.g. occurrence: 1): the walk only keeps going past a match in order to PROVE uniqueness, so an explicit occurrence returns the first highlightable match immediately instead of finishing the tree -- measured at 0.01-1.3s against a large DaVinci Resolve accessibility tree versus a 4.2s node-cap failure with no occurrence supplied. Then confirm the result with verify_annotation, because occurrence short-circuits uniqueness checking: you get the first highlightable match, never a guarantee that it is the only one. If ambiguity detection across the whole tree is actually required, raise max_nodes (up to \(AccessibilityElementResolver.absoluteMaxNodes)) together with timeout_seconds (up to \(Int(AccessibilityElementResolver.maxTraversalTimeoutSeconds))), since a longer walk also needs longer to run. Some applications publish hierarchies far larger than any bounded read can enumerate -- a measured DaVinci Resolve session exceeded 60,000 elements in 11 seconds without completing -- and for those, element anchoring is not available at all: measure from an uncropped full-display screenshot instead and confirm the result with verify_annotation."
        case .traversalTimedOut(let seconds):
            return "Stopped accessibility lookup after \(String(format: "%.1f", seconds)) seconds without finishing the tree. The deadline bounds the whole breadth-first walk, so narrowing label or role does not help. Try supplying occurrence FIRST (e.g. occurrence: 1): the walk only keeps going past a match in order to PROVE uniqueness, so an explicit occurrence returns the first highlightable match immediately instead of finishing the tree -- measured at 0.01-1.3s against a large DaVinci Resolve accessibility tree versus a 4.2s node-cap failure with no occurrence supplied. Then confirm the result with verify_annotation, because occurrence short-circuits uniqueness checking: you get the first highlightable match, never a guarantee that it is the only one. If ambiguity detection across the whole tree is actually required, raise timeout_seconds (up to \(Int(AccessibilityElementResolver.maxTraversalTimeoutSeconds))), and raise max_nodes with it if the walk is also hitting that cap. If the target application publishes a very large hierarchy, element anchoring may not be reachable at any allowed budget -- measure from an uncropped full-display screenshot instead and confirm the result with verify_annotation."
        case .noMatches(let label, let role, let exposedSample):
            let roleNote = role.map { " with role '\($0)'" } ?? ""
            guard !exposedSample.isEmpty else {
                return "No accessibility element matched label '\(label)'\(roleNote). The UI may not expose that control to macOS Accessibility."
            }
            // A non-empty sample proves the app DOES publish Accessibility
            // metadata -- just not under this label -- so point the caller at
            // a plausible correction instead of inviting it to give up on
            // element anchoring. Labels related to the failed query (one
            // case-insensitively contains the other) are the likeliest
            // typo/rename fix, so surface those first; `sorted` is stable
            // (Swift 5+), so ties keep their original BFS discovery order.
            let lowerQuery = label.lowercased()
            let ranked = exposedSample.sorted { lhs, rhs in
                Self.isRelatedLabel(lhs.matchedLabel, toLowercasedQuery: lowerQuery)
                    && !Self.isRelatedLabel(rhs.matchedLabel, toLowercasedQuery: lowerQuery)
            }
            let preview = ranked.prefix(8)
                .map { "'\($0.matchedLabel)' [\($0.role ?? "unknown role")]" }
                .joined(separator: ", ")
            let more = ranked.count > 8 ? " (and \(ranked.count - 8) more)" : ""
            return "No accessibility element matched label '\(label)'\(roleNote). Labels that ARE exposed here include: \(preview)\(more). Retry with one of those labels (optionally adding a role) instead of falling back to screen coordinates."
        case .labelSeenUnderOtherRoles(let label, let requestedRole, let seenRoles):
            let roleList = seenRoles.map { "'\($0)'" }.joined(separator: ", ")
            return "No accessibility element matched label '\(label)' with role '\(requestedRole)', but that label IS exposed here under \(seenRoles.count == 1 ? "role" : "roles"): \(roleList). The role argument is compared VERBATIM against the app's own AXRole string -- no case folding, no automatic 'AX' prefix -- so 'button' never matches 'AXButton'. Retry without role, or with one of the role strings listed above; do not fall back to screen coordinates, because this control is exposed to macOS Accessibility."
        case .ambiguous(let matches):
            // Each entry is prefixed with the exact `occurrence` value that
            // selects it, and carries that candidate's backing-pixel rect,
            // because without both a caller choosing between identically-
            // labelled candidates is choosing between identical STRINGS --
            // see `AccessibilityElementCandidate.backingFrame`. `; ` rather
            // than the old `, ` separator: the geometry itself contains a
            // comma ("at 4200,600"), so a comma-separated list would read as
            // twice as many entries as it has.
            let preview = matches.prefix(8).enumerated().map { index, candidate in
                "occurrence \(index + 1): '\(candidate.matchedLabel)' [\(candidate.role ?? "unknown role")] via \(candidate.matchedAttribute)\(Self.geometryNote(for: candidate))"
            }.joined(separator: "; ")
            let more = matches.count > 8 ? " (and \(matches.count - 8) more)" : ""
            return "Accessibility lookup is ambiguous across \(matches.count) elements: \(preview)\(more). Add a role or supply a one-based occurrence. OCCURRENCE INDEXES BREADTH-FIRST DISCOVERY ORDER (outermost/earliest-visited element first), not visual top-to-bottom or left-to-right order, so choose it from the numbered list above -- and from the listed geometry, not from where the control appears on screen."
        case .occurrenceOutOfRange(let requested, let available, let framelessMatchCount):
            // The frameless note is appended only when it applies: a caller
            // who requested occurrence 3 against a tree with no frameless
            // matches at all should not be told about a phenomenon that did
            // not happen here, and an empty note would just be noise ahead
            // of the trailing period.
            let framelessNote = framelessMatchCount > 0
                ? " \(framelessMatchCount) additional element(s) also matched the label but were skipped because they published no usable screen frame (no AXPosition/AXSize), so they could not be assigned an occurrence."
                : ""
            return "Requested accessibility occurrence \(requested), but only \(available) highlightable matching element(s) were found. Occurrence is one-based.\(framelessNote)"
        case .matchesHaveNoUsableFrame(let matchCount):
            return "\(matchCount) element(s) matched the label but none published a usable screen frame (no AXPosition/AXSize -- typically an off-screen, menu, or non-drawable element), so there is nothing to draw around. Try a different label or role, or fall back to screenshot-measured coordinates confirmed with verify_annotation."
        case .frameCannotBeMapped:
            return "The matched accessibility frame does not fit wholly on one connected display, so safe screen-local backing-pixel placement is impossible."
        }
    }

    /// True when `label` and `lowercasedQuery` case-insensitively relate --
    /// either contains the other.  Used only to rank a `.noMatches` preview,
    /// so a cheap two-way `contains` (rather than edit distance or any other
    /// fuzzy match) is enough: it catches the common cases of a truncated,
    /// pluralized, or prefixed/suffixed query without pulling in a matching
    /// dependency for an error-message nicety.
    private static func isRelatedLabel(_ label: String, toLowercasedQuery lowercasedQuery: String) -> Bool {
        let lowercasedLabel = label.lowercased()
        return lowercasedLabel.contains(lowercasedQuery) || lowercasedQuery.contains(lowercasedLabel)
    }

    /// Renders one ambiguity candidate's backing-pixel rect for the
    /// `.ambiguous` preview.  Internal (not private) so the exact rendering
    /// can be pinned headlessly -- the whole point of this string is that a
    /// caller reads a number out of it and passes the matching `occurrence`
    /// back, so a silent formatting regression here reintroduces blind
    /// occurrence guessing.
    ///
    /// `%.0f` on purpose: these are already whole backing pixels in practice,
    /// and "at 4200,600 240x36" is something a model can compare across eight
    /// candidates at a glance while "at 4200.0,600.0 240.0x36.0" is not.
    /// Sub-pixel precision would not change which occurrence anyone picks.
    static func geometryNote(for candidate: AccessibilityElementCandidate) -> String {
        guard let frame = candidate.backingFrame else {
            // Reachable: a match CAN publish a usable AX frame that still
            // fits on no single display (straddling, or off-desktop). Say so
            // rather than printing a gap, since selecting that occurrence
            // would go on to fail with `frameCannotBeMapped`.
            return " -- does not map onto a single display"
        }
        func px(_ value: Double) -> String { String(format: "%.0f", value) }
        return " -- screen \(frame.screenId) at \(px(frame.x)),\(px(frame.y)) \(px(frame.width))x\(px(frame.height))"
    }
}

/// Read-only bridge from a running application's AX hierarchy to Chalkboard's
/// screen-local backing pixels.  It never presses, focuses, or otherwise
/// mutates an accessibility element.
public enum AccessibilityElementResolver {
    public static let defaultMaxNodes = 3_000
    public static let absoluteMaxNodes = 10_000
    /// Cross-process AX calls can each block until their messaging timeout.
    /// Keep that wait small enough that the lookup's overall wall-clock
    /// deadline remains meaningful even for a target app with a hung element.
    static let perElementMessagingTimeout: Float = 0.20
    public static let defaultTraversalTimeoutSeconds: TimeInterval = 2.0
    public static let minTraversalTimeoutSeconds: TimeInterval = 0.5
    public static let maxTraversalTimeoutSeconds: TimeInterval = 10.0
    /// Bounds on the "labels that ARE exposed" sample attached to a
    /// `.noMatches` error.  Capped far below a typical tree's node count so a
    /// huge, entirely-unmatched hierarchy cannot inflate the error path's
    /// memory; label length is capped separately because a very long title
    /// reads as document content rather than a control name.
    static let maxExposedSampleCount = 64
    /// Bound on the distinct AXRole strings remembered for a label the
    /// caller's `role` filter rejected (see `.labelSeenUnderOtherRoles`).
    /// Small on purpose: this list is read by a human or a model choosing a
    /// replacement role string, and a label genuinely published under more
    /// than eight different roles tells that reader nothing useful -- while
    /// an unbounded list would let a pathological tree grow an error message
    /// without limit.
    static let maxRolesSeenForLabel = 8
    /// Every AX label retained in a successful match or no-match sample uses
    /// this one shared bound. AX attributes belong to another process and a
    /// title/description can be arbitrarily large, so this keeps annotation
    /// labels and subsequent MCP responses independently bounded.
    static let maxPublishedLabelCharacters = 128

    /// Checks trust without prompting by default.  macOS can display a system
    /// prompt only when the caller deliberately opts in; an MCP lookup should
    /// otherwise fail predictably and explain the required grant.
    public static func trustStatus(requestPrompt: Bool = false) -> AccessibilityTrustStatus {
        let options: CFDictionary?
        if requestPrompt {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            options = [promptKey: true] as CFDictionary
        } else {
            options = nil
        }
        let trusted = AXIsProcessTrustedWithOptions(options)
        return AccessibilityTrustStatus(
            trusted: trusted,
            promptRequested: requestPrompt,
            note: trusted
                ? "Accessibility access is available for read-only UI element lookup."
                : requestPrompt
                    ? "Accessibility access is not currently granted; macOS has been asked to present its permission prompt. Grant access in System Settings, then retry."
                    : "Accessibility access is not granted. Request the system prompt explicitly or enable AI Chalkboard in System Settings > Privacy & Security > Accessibility."
        )
    }

    /// Finds a target inside a running application identified by its PID.  The
    /// caller is responsible for resolving an MCP app name/bundle identifier to
    /// an actually-running `NSRunningApplication` before calling this method.
    public static func resolve(
        processID: pid_t,
        request: AccessibilityElementRequest,
        screens: [ScreenInfo]
    ) throws -> AccessibilityElementMatch {
        guard trustStatus().trusted else { throw AccessibilityElementResolverError.accessibilityNotTrusted }
        guard processID > 0 else { throw AccessibilityElementResolverError.invalidProcessID }
        let normalized = try validated(request)
        guard !screens.isEmpty else { throw AccessibilityElementResolverError.frameCannotBeMapped }

        let application = AXUIElementCreateApplication(processID)
        // AX is cross-process IPC.  A bounded hierarchy is not sufficient if a
        // hostile or hung target never answers one attribute request, so cap
        // each application object's message wait as well.
        configureMessagingTimeout(application)
        let startedAt = ProcessInfo.processInfo.systemUptime

        // Unlike the per-node BFS below -- where one unreadable child must
        // stay non-fatal, since a single hung grandchild cannot be allowed to
        // fail the whole lookup -- the TOP-LEVEL fetch is the one place a
        // failed AX call has historically been reported as "the app has no
        // Accessibility metadata" when the real story was "the app didn't
        // answer in time".  Use the error-preserving fetch here instead of
        // the nil-tolerant `elements`/`children` helpers.
        let initial = try resolveInitialElements(
            windows: copyElements(attribute: kAXWindowsAttribute, of: application),
            children: copyElements(attribute: kAXChildrenAttribute, of: application)
        )
        if traversalDeadlineExceeded(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime,
                                     timeout: normalized.timeoutSeconds) {
            throw AccessibilityElementResolverError.traversalTimedOut(seconds: normalized.timeoutSeconds)
        }
        guard !initial.isEmpty else {
            throw AccessibilityElementResolverError.applicationUnavailable
        }

        var queue: [AXUIElement] = []
        var nextIndex = 0
        var inspected = 0
        var matches: [InternalMatch] = []
        // Counts label matches whose element published no usable AX frame
        // (see the `matchLabel` branch below). Kept separate from `matches`
        // rather than folded into it because `highlight_element` exists to
        // draw a shape around an element's BOUNDS: an element with no bounds
        // is not a candidate result at all, only a fact worth reporting in
        // an error (`matchesHaveNoUsableFrame`, `occurrenceOutOfRange`) so a
        // caller who can see the label on screen understands why it was not
        // selectable.
        var framelessMatchCount = 0
        var exposedSample: [AccessibilityElementCandidate] = []
        var exposedSampleSeen: Set<ExposedSampleKey> = []
        // Distinct AXRole strings under which the requested LABEL was seen
        // while the caller's `role` filter rejected the node. Recorded
        // separately from `exposedSample` rather than reconstructed from it,
        // because the sample deliberately omits kAXValue content (privacy --
        // see `matchLabel`) and is capped at 64 entries, so a role-mismatch
        // deep in a large tree would be invisible in it. Insertion-ordered
        // (BFS discovery order) via a plain array plus a seen-set; the array
        // is the published order and the set only de-duplicates.
        var rolesSeenForLabel: [String] = []
        var rolesSeenForLabelSet: Set<String> = []
        var traversalWasTruncated = false
        appendBounded(
            initial,
            to: &queue,
            queuedUninspected: 0,
            inspected: 0,
            maxNodes: normalized.maxNodes,
            wasTruncated: &traversalWasTruncated
        )

        while nextIndex < queue.count {
            if traversalDeadlineExceeded(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime,
                                         timeout: normalized.timeoutSeconds) {
                throw AccessibilityElementResolverError.traversalTimedOut(seconds: normalized.timeoutSeconds)
            }
            guard inspected < normalized.maxNodes else {
                throw AccessibilityElementResolverError.traversalLimitReached(normalized.maxNodes)
            }
            let element = queue[nextIndex]
            nextIndex += 1
            inspected += 1
            // Messaging timeouts are state carried by each AXUIElement, not
            // inherited from the application element.  Configure every node
            // before any attribute (including children or frame) is read.
            configureMessagingTimeout(element)

            // ONE cross-process round trip per visited node, not five: the
            // role, all three label attributes, and the children list ride a
            // single `AXUIElementCopyMultipleAttributeValues` message. See
            // `batchedNodeAttributes` for the per-slot error contract, and
            // for why the batched call observes exactly the messaging
            // timeout `configureMessagingTimeout` just set on this element.
            let batch = batchedNodeAttributes(of: element)
            let role = batch.role
            // THE LABEL INSPECTION IS UNCONDITIONAL; ONLY MATCH SELECTION IS
            // ROLE-GATED. This inspection used to sit inside the role gate
            // together with everything below, which made a wrong or
            // mis-cased `role` silently suppress the exposed-label sample as
            // well: role comparison is verbatim `String` equality against
            // the app's own kAXRole (no case folding, no automatic "AX"
            // prefix), so `role: "button"` rejects every node against a live
            // "AXButton", `exposedSample` -- which is written nowhere else --
            // stayed empty, and the resulting `.noMatches` rendered "The UI
            // may not expose that control to macOS Accessibility". That is
            // FALSE, and it teaches a caller to abandon element anchoring
            // and eyeball a screenshot: the dominant misplacement path. The
            // sample must describe what the app actually publishes,
            // independent of the caller's role guess.
            //
            // COST. `matchLabel`'s own work (two/three string comparisons)
            // is free, and its inputs now arrive in the SAME single batched
            // round trip that fetches the role and children (see
            // `batchedNodeAttributes`), so inspecting them unconditionally
            // costs no extra IPC at all -- not even on the role-mismatch
            // paths where the old per-attribute reads could add up to three
            // additional round trips per node.
            let inspection = matchLabel(
                title: batch.title, description: batch.description, value: batch.value,
                query: normalized.label, mode: normalized.matchMode
            )
            // `inspection.sampled` is exactly the title/description values
            // the node's one batched read already fetched while looking for
            // a match on THIS node -- recording them costs no extra IPC.
            // This runs whether or not the node matched, because the overall
            // traversal's outcome (a clean match vs. eventual `.noMatches`)
            // is not yet known; if any match is found anywhere,
            // `exposedSample` is simply never read.
            for sampled in inspection.sampled {
                recordExposedSample(
                    attribute: sampled.attribute, value: sampled.value, role: role,
                    into: &exposedSample, seen: &exposedSampleSeen
                )
            }
            if let labelMatch = inspection.match {
                // The role gate sits HERE and nowhere else. It decides only
                // which matches are SELECTABLE -- never what gets inspected
                // (above) or whether this node's children get walked
                // (below); short-circuiting the loop here would silently
                // prune whole subtrees whose ancestor happened to share the
                // label under an unrequested role.
                if normalized.role == nil || normalized.role == role {
                    // A matched label is not yet a usable RESULT: this
                    // element must also publish a frame, since
                    // `highlight_element` exists to draw a shape around an
                    // element's BOUNDS, and an element with no bounds has
                    // nothing to draw around. Read that frame RIGHT HERE,
                    // the moment the label matches, rather than deferring it
                    // to `resolvedMatch` once a match has been "selected".
                    // That is deliberate for two reasons. Cost: this is one
                    // extra AX IPC per element whose LABEL ALREADY MATCHED,
                    // not per element VISITED -- matches are rare (typically
                    // a handful) while the walk visits thousands of nodes,
                    // so the added cost is negligible, and it is repaid
                    // immediately because `resolvedMatch` no longer has to
                    // re-read the frame at all. Correctness: reading it here
                    // closes a TOCTOU window the old code had -- it read the
                    // frame in `resolvedMatch`, potentially many BFS nodes
                    // (and moving-UI frames) after the element matched, so a
                    // reflowing UI could hand back a frame belonging to a
                    // different layout than the one that actually matched.
                    configureMessagingTimeout(element)
                    if let elementFrame = frame(of: element) {
                        // Convert to backing pixels HERE, once, and carry
                        // the result on the match. This is pure arithmetic
                        // against the already-captured `screens` -- no IPC,
                        // no AX call -- and it serves three call sites with
                        // ONE value: `resolvedMatch`'s published
                        // `backingFrame`, its `frameCannotBeMapped` check,
                        // and (the reason it moved here) the geometry an
                        // `.ambiguous` candidate shows so `occurrence` is
                        // chosen from real coordinates rather than guessed.
                        // Deriving it once also makes the ambiguity preview
                        // provably the same rect that would be drawn.
                        let match = InternalMatch(
                            frame: elementFrame,
                            candidate: AccessibilityElementCandidate(
                                matchedAttribute: labelMatch.attribute,
                                matchedLabel: publishedMatchLabel(
                                    attribute: labelMatch.attribute,
                                    value: labelMatch.value,
                                    query: normalized.label
                                ),
                                role: role,
                                backingFrame: backingRect(
                                    forAccessibilityFrame: elementFrame, screens: screens
                                )
                            )
                        )
                        matches.append(match)
                        // An explicit occurrence now means the Nth
                        // HIGHLIGHTABLE match: a frameless match never
                        // reaches this branch (see the `else` below), so it
                        // cannot consume an occurrence slot or shift the
                        // numbering of the highlightable matches that follow
                        // it. Later nodes cannot alter the identity of the
                        // Nth highlightable match, so end the walk -- and
                        // every remaining node's IPC -- the moment that
                        // requested match is found.
                        if let occurrence = normalized.occurrence, matches.count == occurrence {
                            return try resolvedMatch(match)
                        }
                    } else {
                        // No usable bounds: this element can never be
                        // highlighted, so it must not occupy an occurrence
                        // slot, pad an ambiguity list, or be discarded
                        // without a trace. Count it so `resolve()` can later
                        // explain, via `matchesHaveNoUsableFrame` or
                        // `occurrenceOutOfRange`, why fewer (or zero) of the
                        // on-screen labels the caller can see were
                        // selectable.
                        framelessMatchCount += 1
                    }
                } else {
                    // The label IS published here, just not under the role
                    // the caller guessed. Remember which role, so the
                    // eventual no-match error can NAME it rather than claim
                    // the control is not exposed at all.
                    //
                    // Deliberately NOT counted in `framelessMatchCount` and
                    // NOT appended to `matches`: role filtering must keep
                    // selecting exactly the elements it selected before this
                    // change. Only the ERROR MESSAGE gets richer.
                    recordRoleSeenForLabel(
                        role, into: &rolesSeenForLabel, seen: &rolesSeenForLabelSet
                    )
                }
            }

            if let children = batch.children {
                // Do not recurse: deeply nested DOM-like trees can otherwise
                // overflow the process stack before the maximum-node guard is
                // reached.
                appendBounded(
                    children,
                    to: &queue,
                    queuedUninspected: queue.count - nextIndex,
                    inspected: inspected,
                    maxNodes: normalized.maxNodes,
                    wasTruncated: &traversalWasTruncated
                )
            }
        }

        // We deliberately retain no more than `maxNodes` pending elements.
        // If a child array was clipped to enforce that memory bound, the tree
        // was incomplete and therefore cannot safely produce a unique result.
        if traversalWasTruncated {
            throw AccessibilityElementResolverError.traversalLimitReached(normalized.maxNodes)
        }

        guard !matches.isEmpty else {
            // `matches` being empty no longer means the label was never
            // seen: it also happens when every element that matched it
            // lacked a usable frame. Those two are different failures with
            // different fixes -- "no accessibility element matched" invites
            // a different label/role, while "matched but unhighlightable"
            // invites screenshot-measured coordinates instead -- so only
            // fall back to the original `.noMatches` (with its exposed-label
            // sample) when NO frameless match was seen either; otherwise
            // report the frameless count so the caller learns why the
            // labels it can plainly see on screen produced no result.
            if framelessMatchCount > 0 {
                throw AccessibilityElementResolverError.matchesHaveNoUsableFrame(matchCount: framelessMatchCount)
            }
            // Checked AFTER `framelessMatchCount`, which can only be
            // non-zero when the role filter DID match something (it is
            // incremented inside the role gate): if a role-matching element
            // was found and merely lacked bounds, "matched but
            // unhighlightable" is the accurate story, not "wrong role".
            if let requestedRole = normalized.role, !rolesSeenForLabel.isEmpty {
                throw AccessibilityElementResolverError.labelSeenUnderOtherRoles(
                    label: normalized.label, requestedRole: requestedRole, seenRoles: rolesSeenForLabel
                )
            }
            throw AccessibilityElementResolverError.noMatches(
                label: normalized.label, role: normalized.role, exposedSample: exposedSample
            )
        }

        let selected: InternalMatch
        if let occurrence = normalized.occurrence {
            guard occurrence <= matches.count else {
                throw AccessibilityElementResolverError.occurrenceOutOfRange(
                    requested: occurrence, available: matches.count, framelessMatchCount: framelessMatchCount
                )
            }
            selected = matches[occurrence - 1]
        } else {
            guard matches.count == 1 else {
                throw AccessibilityElementResolverError.ambiguous(matches: matches.map(\.candidate))
            }
            selected = matches[0]
        }

        return try resolvedMatch(selected)
    }

    /// How a frame that does not sit wholly inside a single display is
    /// mapped onto exactly one. See `backingRect(forAccessibilityFrame:
    /// screens:selection:)`'s `selection` parameter for which callers should
    /// choose which case.
    public enum AccessibilityFrameDisplaySelection {
        /// The frame must be fully contained by exactly one display. This is
        /// `backingRect`'s DEFAULT and must stay behaviourally unchanged:
        /// `highlight_element` draws around a single UI control, and a
        /// control genuinely straddling two displays cannot be represented
        /// by one Chalkboard annotation -- see this file's standing "reject
        /// rather than silently clip or choose a monitor" policy.
        case requireContainment
        /// The display with the largest intersection area wins; a frame
        /// that intersects NO display is still rejected (`nil`). Correct
        /// for a WINDOW rather than an element: a window is routinely
        /// dragged across a display boundary or pushed partly off the
        /// desktop edge, and `requireContainment` would report it
        /// unmappable on every such tick -- which a window-anchor tracker
        /// reads as the window being GONE, permanently killing tracking for
        /// the single most ordinary user action window anchoring exists to
        /// survive. Under this case the returned rect's x/y MAY be
        /// negative, or its far edge may extend past the chosen display's
        /// own extent -- that is correct and expected for a window hanging
        /// off an edge; a caller using this for anchor geometry only needs
        /// the frame as a reference for a scale/translate computation, never
        /// a rect that paints on screen by itself, so it is deliberately
        /// left unclipped.
        case largestOverlap
    }

    /// Pure AX top-left global logical-point -> local backing-pixel conversion.
    /// AppKit's desktop has a bottom-left origin, hence the explicit desktop
    /// top calculation.  This lives outside the resolver so mixed-scale and
    /// secondary-display math can be unit-tested without an AX/TCC session.
    public static func backingRect(
        forAccessibilityFrame frame: AccessibilityScreenRect,
        screens: [ScreenInfo],
        selection: AccessibilityFrameDisplaySelection = .requireContainment
    ) -> AccessibilityBackingRect? {
        // AX's global top-left origin is anchored to the ZERO-ORIGIN display
        // -- the one carrying the menu bar, whose AppKit frame origin is
        // exactly (0, 0) -- not to the topmost display in an arbitrarily
        // arranged desktop and not to whichever screen AppKit currently calls
        // `main`.  `ScreenInfo.isMain` follows the focused window, so anchoring
        // to it made every AX y-coordinate shift by the height difference the
        // moment focus moved to a shorter or taller secondary display:
        // highlights landed off their control, or the frame stopped fitting on
        // any one screen and the lookup threw `frameCannotBeMapped`, with the
        // result differing call to call for an unchanged UI.  Deliberately do
        // not route this through `windowServerFrame`: that rectangle is in
        // WindowServer's global top-left space (`CGDisplayBounds`), and only
        // degrades to a synthetic pixel rect when AppKit reports no display id;
        // this arithmetic is in AppKit bottom-left logical points.
        //
        // The zero-origin display is REQUIRED, with no `?? screens.first`
        // fallback. macOS always places one display's AppKit frame at exactly
        // (0, 0), so a snapshot without one is an invariant violation, not a
        // layout this function can serve. The old fallback silently accepted
        // it and anchored `desktopTop` to an arbitrary screen instead --
        // which does not fail, it just returns a rectangle displaced by the
        // difference between that screen's `maxY` and the real desktop top,
        // putting every highlight off its control by that amount. Returning
        // nil here surfaces the existing `frameCannotBeMapped` error instead,
        // matching this file's standing choice to "reject rather than
        // silently clip or choose a monitor" a few lines below.
        guard isUsable(frame),
              let anchor = screens.first(where: { $0.appKitFrame.x == 0 && $0.appKitFrame.y == 0 })
        else { return nil }
        let desktopTop = anchor.appKitFrame.maxY

        let appKitRect = ScreenCoordinateRect(
            x: frame.x,
            y: desktopTop - frame.y - frame.height,
            width: frame.width,
            height: frame.height
        )
        let screen: ScreenInfo?
        switch selection {
        case .requireContainment:
            // Elements which straddle displays cannot be represented by one
            // Chalkboard annotation, whose coordinates deliberately name
            // exactly one screen.  Reject rather than silently clip or
            // choose a monitor.
            screen = screens.first(where: { fullyContains($0.appKitFrame, appKitRect) })
        case .largestOverlap:
            screen = bestOverlappingScreen(appKitRect, in: screens, frame: \.appKitFrame)
        }
        guard let screen else { return nil }
        let scale = screen.backingScaleFactor
        guard scale.isFinite, scale > 0 else { return nil }
        return AccessibilityBackingRect(
            screenId: screen.id,
            x: (appKitRect.x - screen.appKitFrame.x) * scale,
            y: (screen.appKitFrame.maxY - appKitRect.maxY) * scale,
            width: appKitRect.width * scale,
            height: appKitRect.height * scale
        )
    }

    // MARK: - Pure matching helpers

    static func labelMatches(_ candidate: String, query: String, mode: AccessibilityLabelMatchMode) -> Bool {
        switch mode {
        case .exact:
            return candidate == query
        case .contains:
            return candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Produces the label that may leave the resolver in an annotation or MCP
    /// payload, after the full AX value has already been used for matching.
    ///
    /// `kAXValue` frequently contains editable document or form content. In
    /// particular, a `contains` lookup only proves that the query occurred
    /// somewhere in that value; returning the full value would disclose the
    /// surrounding user text. The caller already knows its query, so use that
    /// as the stable public description for all value matches. Titles and
    /// descriptions may also be unexpectedly large, so cap every published
    /// label to one predictable Unicode-character budget.
    static func publishedMatchLabel(attribute: String, value: String, query: String) -> String {
        let publicValue = attribute == kAXValueAttribute ? query : value
        return boundedPublishedLabel(publicValue)
    }

    /// Keeps a valid Unicode prefix within the published-label budget. The
    /// marker makes it clear that this is a display/safety summary rather than
    /// necessarily the complete AX attribute.
    static func boundedPublishedLabel(_ value: String) -> String {
        guard value.count > maxPublishedLabelCharacters else { return value }
        let prefixCount = maxPublishedLabelCharacters - 1
        return String(value.prefix(prefixCount)) + "…"
    }

    /// Pure monotonic-clock boundary helper.  Keeping it independent from AX
    /// allows the deadline policy to be tested without Accessibility consent.
    static func traversalDeadlineExceeded(startedAt: TimeInterval, now: TimeInterval,
                                          timeout: TimeInterval = defaultTraversalTimeoutSeconds) -> Bool {
        now - startedAt >= timeout
    }

    /// Prefer a populated window list but fall back to application children:
    /// several apps expose `AXWindows` as an empty array while publishing the
    /// actual hierarchy directly beneath the application element.
    static func initialElements<Element>(windows: [Element]?,
                                         children: @autoclosure () -> [Element]?) -> [Element]? {
        guard let windows, !windows.isEmpty else { return children() }
        return windows
    }

    /// The outcome of a TOP-LEVEL attribute fetch (`kAXWindows`/`kAXChildren`
    /// on the application element), which -- unlike the per-node BFS's
    /// nil-tolerant `elements`/`children` helpers -- must be able to tell a
    /// failed IPC call apart from a call that succeeded and legitimately
    /// returned nothing.  Generic over `Element` so the busy/empty decision
    /// in `resolveInitialElements` below can be unit-tested without a live
    /// AXUIElement or Accessibility consent, the same way `initialElements`
    /// above is tested with plain `Int`s.
    enum AttributeFetch<Element> {
        case values([Element])
        case unreadable(AXError)

        var values: [Element]? {
            if case .values(let list) = self { return list }
            return nil
        }

        var isTransientFailure: Bool {
            if case .unreadable(let error) = self { return isTransientAXFailure(error) }
            return false
        }
    }

    /// Classifies an `AXError` from a top-level application attribute fetch
    /// as transient-and-worth-retrying versus a genuine "nothing is
    /// published here" answer.  This split exists because of a measured,
    /// real bug: against a live DaVinci Resolve, a label that unambiguously
    /// IS exposed to Accessibility ("Tracking", an Inspector row label)
    /// still returned `.cannotComplete` on 1 of 12 lookups, purely because
    /// Resolve had not answered inside `perElementMessagingTimeout` -- not
    /// because its tree was empty.  The prior code collapsed every AXError
    /// to "empty", so that single timeout was reported to the calling agent
    /// as `applicationUnavailable` ("the app... does not expose
    /// Accessibility metadata"), which is a lie: it sent the agent off to
    /// eyeball a screenshot for placement instead of simply retrying a
    /// lookup that would very likely have succeeded moments later.
    static func isTransientAXFailure(_ error: AXError) -> Bool {
        switch error {
        case .cannotComplete, .failure:
            // The call could not get an answer at all. `.cannotComplete` is
            // precisely the code Apple documents for "messaging failed, or
            // the application is busy or unresponsive" -- the measured shape
            // above. `.failure` is a generic system error (for example a
            // failed allocation), which may equally clear on a retry.
            return true
        case .notImplemented:
            // DELIBERATELY NOT TRANSIENT, despite also being a "no answer"
            // outcome. Apple defines `kAXErrorNotImplemented` as "the process
            // does not fully support the accessibility API" -- a permanent
            // property of that application, not a momentary state. Calling it
            // transient would tell the caller to retry forever against an app
            // that will never answer, which is the same class of misleading
            // error this whole split exists to remove, merely inverted:
            // instead of telling an agent to give up on an app that would
            // have worked, it would tell an agent to keep retrying one that
            // never will. Falling through to `applicationUnavailable` is
            // correct here -- that message's advice to check whether the app
            // exposes Accessibility metadata is exactly right for this code.
            return false
        case .attributeUnsupported, .noValue, .invalidUIElement:
            // The call DID get an answer, and the answer is "there is
            // nothing here": the attribute does not exist on this element,
            // it has no value, or the element itself is already gone.
            return false
        default:
            // Every other AXError this call site can plausibly see (bad
            // arguments, AX API disabled, notification-only codes that
            // AXUIElementCopyAttributeValue cannot even return) reflects a
            // real, non-transient condition rather than a busy target, so
            // do not tell the caller to retry for those either.
            return false
        }
    }

    /// Decides the BFS's starting element list from the two top-level
    /// fetches, throwing `applicationBusy` rather than silently reporting an
    /// empty hierarchy when the fetch that would have supplied the answer
    /// never got one.  Layered around `initialElements(windows:children:)`
    /// rather than duplicating its "non-empty windows wins" contract, which
    /// several apps depend on (they expose `AXWindows` as an empty array
    /// while publishing the real hierarchy under the application element)
    /// and which is separately unit-tested.
    static func resolveInitialElements<Element>(
        windows: AttributeFetch<Element>,
        children: @autoclosure () -> AttributeFetch<Element>
    ) throws -> [Element] {
        if case .values(let windowsValues) = windows, !windowsValues.isEmpty {
            // A populated windows list is authoritative and already answers
            // the question, so this mirrors the original `@autoclosure`
            // call site's laziness: never pay for the children IPC at all.
            return windowsValues
        }

        let childrenFetch = children()
        if let resolved = initialElements(windows: windows.values, children: childrenFetch.values),
           !resolved.isEmpty {
            return resolved
        }

        // Neither fetch produced a usable, non-empty list.  Only throw
        // `applicationBusy` when the fetch that still had a chance to
        // supply elements -- children, since a non-empty windows list would
        // already have returned above -- failed to answer at all.  If
        // children instead succeeded with a definitive (if empty) answer,
        // trust it: a windows fetch that separately timed out does not
        // undo a real "there is nothing here" from children.
        if case .unreadable(let childrenError) = childrenFetch,
           isTransientAXFailure(childrenError) || windows.isTransientFailure {
            throw AccessibilityElementResolverError.applicationBusy
        }
        return []
    }

    /// Computes how many children can enter the BFS queue without retaining
    /// more candidates than the request's inspection budget can consume.
    static func boundedAppendCount(candidateCount: Int, queuedUninspected: Int,
                                   inspected: Int, maxNodes: Int) -> Int {
        let remaining = max(0, maxNodes - inspected - queuedUninspected)
        return min(max(0, candidateCount), remaining)
    }

    /// `frame` is captured at the moment the label matched (see the BFS
    /// loop in `resolve()`), not re-read later, which is why this no longer
    /// carries the live `AXUIElement` at all: `resolvedMatch` has everything
    /// it needs from `frame` and `candidate` alone. Not retaining a live
    /// `AXUIElement` past its use matches `AccessibilityElementMatch`'s
    /// existing doc comment -- "the element reference intentionally is not
    /// retained" -- and here that also removes a stale-reference risk: an
    /// `AXUIElement` kept around across the rest of the BFS walk (which can
    /// take seconds against a large tree) could otherwise go stale before
    /// `resolvedMatch` ever used it.
    ///
    /// Internal (not private) so `resolvedMatch`'s selected-match contract
    /// can be constructed and pinned headlessly -- see that function's doc
    /// comment.
    struct InternalMatch {
        let frame: AccessibilityScreenRect
        let candidate: AccessibilityElementCandidate

        /// The one backing-pixel conversion of `frame`, computed once in the
        /// BFS loop against the screen snapshot the whole lookup uses. Nil
        /// means the frame fits on no single connected display, which is
        /// `frameCannotBeMapped` if this match is SELECTED and a rendered
        /// note if it merely appears in an ambiguity list. Reading it off
        /// `candidate` rather than storing a second copy keeps the two
        /// provably identical -- the ambiguity preview a caller reads and
        /// the rect a highlight would be drawn at cannot drift apart.
        var backingFrame: AccessibilityBackingRect? { candidate.backingFrame }
    }

    /// De-duplication key for the `.noMatches` exposed-label sample.  Two
    /// elements with the same label but different roles are kept as distinct
    /// entries: a caller correcting `label` may still need the role to
    /// disambiguate, so collapsing them would throw away the information
    /// that made the sample useful in the first place.
    private struct ExposedSampleKey: Hashable {
        let label: String
        let role: String?
    }

    private static func validated(_ request: AccessibilityElementRequest) throws -> AccessibilityElementRequest {
        let label = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw AccessibilityElementResolverError.invalidRequest("label must be a non-empty string.")
        }
        guard label.count <= 1_024 else {
            throw AccessibilityElementResolverError.invalidRequest("label may contain at most 1024 characters.")
        }
        let role = request.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.role != nil, role?.isEmpty == true {
            throw AccessibilityElementResolverError.invalidRequest("role must be non-empty when supplied.")
        }
        if let occurrence = request.occurrence, occurrence < 1 {
            throw AccessibilityElementResolverError.invalidRequest("occurrence must be one-based and greater than zero when supplied.")
        }
        guard request.maxNodes > 0, request.maxNodes <= absoluteMaxNodes else {
            throw AccessibilityElementResolverError.invalidRequest("maxNodes must be between 1 and \(absoluteMaxNodes).")
        }
        guard request.timeoutSeconds.isFinite,
              request.timeoutSeconds >= minTraversalTimeoutSeconds,
              request.timeoutSeconds <= maxTraversalTimeoutSeconds else {
            throw AccessibilityElementResolverError.invalidRequest("timeoutSeconds must be between \(minTraversalTimeoutSeconds) and \(maxTraversalTimeoutSeconds).")
        }
        return AccessibilityElementRequest(label: label, role: role, matchMode: request.matchMode,
                                           occurrence: request.occurrence, maxNodes: request.maxNodes,
                                           timeoutSeconds: request.timeoutSeconds)
    }

    /// Pure title/description/value matching cascade over attribute values
    /// that have ALREADY been fetched (by `batchedNodeAttributes`' single
    /// per-node round trip). This used to take the `AXUIElement` and issue
    /// one `AXUIElementCopyAttributeValue` per attribute itself; only that
    /// IPC pattern changed -- the MATCH SEMANTICS here are deliberately
    /// byte-for-byte the old ones. In particular the cascade still runs in
    /// the same deterministic order (a single element which happens to
    /// repeat a label in multiple attributes is still one candidate, with
    /// its visible title preferred over its description/value), still skips
    /// absent attributes without ending the cascade, and still SHORT-
    /// CIRCUITS at the first matching attribute even though all three
    /// values now sit in hand -- so `sampled` keeps its exact historical
    /// contents: on a node whose title matches, the description is not
    /// sampled, exactly as when the sequential reads never reached it.
    ///
    /// `sampled` carries every kAXTitle/kAXDescription value the cascade
    /// actually considered while looking for a match, independent of whether
    /// that attribute (or any other) matched.  Reusing exactly the values
    /// the batched read was already going to fetch -- rather than issuing
    /// separate attribute requests -- is what lets the `.noMatches`
    /// exposed-label sample cost zero extra IPC: on a traversal that ends in
    /// `.noMatches`, nothing ever matched, so this loop never short-circuits
    /// early and `sampled` ends up covering every title/description this
    /// element had.
    /// kAXValue is deliberately excluded from `sampled` even though it IS
    /// used for matching purposes: an AXValue is frequently the user's own
    /// document content (e.g. text typed into a field), and echoing it back
    /// inside an MCP error message would turn a UI-discovery hint into
    /// content disclosure. A matching kAXValue is likewise published only as
    /// the caller's query via `publishedMatchLabel`, never as the raw value.
    ///
    /// Internal (not private), and pure on purpose: match PRIORITY is the
    /// one semantic the batching change could most plausibly have disturbed,
    /// so it must be pinnable headlessly, without an AX/TCC session.
    static func matchLabel(title: String?, description: String?, value: String?,
                           query: String, mode: AccessibilityLabelMatchMode)
    -> (match: (attribute: String, value: String)?, sampled: [(attribute: String, value: String)]) {
        var sampled: [(attribute: String, value: String)] = []
        let candidates: [(attribute: String, value: String?)] = [
            (kAXTitleAttribute, title),
            (kAXDescriptionAttribute, description),
            (kAXValueAttribute, value)
        ]
        for (attribute, candidate) in candidates {
            guard let candidate else { continue }
            if attribute != kAXValueAttribute {
                sampled.append((attribute, candidate))
            }
            if labelMatches(candidate, query: query, mode: mode) {
                return (match: (attribute, candidate), sampled: sampled)
            }
        }
        return (match: nil, sampled: sampled)
    }

    /// Records one exposed-label sample entry for a `.noMatches` preview,
    /// enforcing every bound in one place: the 64-entry cap (checked FIRST
    /// so a full sample does no further work at all), empty/whitespace-only
    /// labels, the 128-character content-vs-control-name cutoff, and
    /// (label, role) de-duplication.
    private static func recordExposedSample(
        attribute: String, value: String, role: String?,
        into sample: inout [AccessibilityElementCandidate],
        seen: inout Set<ExposedSampleKey>
    ) {
        guard sample.count < maxExposedSampleCount else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPublishedLabelCharacters else { return }
        guard seen.insert(ExposedSampleKey(label: trimmed, role: role)).inserted else { return }
        sample.append(AccessibilityElementCandidate(matchedAttribute: attribute, matchedLabel: trimmed, role: role))
    }

    /// Records one AXRole under which the requested LABEL was found while the
    /// caller's `role` filter rejected it, for `.labelSeenUnderOtherRoles`.
    /// Deliberately shaped like `recordExposedSample` above -- cap checked
    /// FIRST so a saturated list does no further work, de-duplicated through
    /// a companion set, insertion order (which is BFS discovery order) kept
    /// by the array. A nil role is dropped rather than rendered as "unknown":
    /// this list exists to be COPIED BACK into a retry's `role` argument, and
    /// a placeholder is not a value anyone can retry with.
    private static func recordRoleSeenForLabel(
        _ role: String?, into roles: inout [String], seen: inout Set<String>
    ) {
        guard roles.count < maxRolesSeenForLabel, let role else { return }
        guard seen.insert(role).inserted else { return }
        roles.append(role)
    }

    /// The five attributes the BFS needs from EVERY visited node, in the one
    /// fixed order `decodeBatchedNodeAttributeSlots` decodes them by index.
    /// Declared as a named constant (and internal, not private) so a test
    /// can pin that order against the decoder's indexes: the batch result
    /// array is positional, so a silent reorder here would swap, say, every
    /// node's title and role without any type system complaint.
    static let batchedNodeAttributeNames: [String] = [
        kAXRoleAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXValueAttribute,
        kAXChildrenAttribute
    ]

    /// One visited node's batch-fetched attributes, already decoded to the
    /// SAME nil-tolerant optionals the old per-attribute
    /// `AXUIElementCopyAttributeValue` reads produced: a `nil` field means
    /// exactly what a failed individual read used to mean (attribute absent,
    /// unreadable, or not the expected type), so everything downstream --
    /// the role gate, `matchLabel`'s cascade, `appendBounded`'s child
    /// handling -- consumes these without knowing the IPC pattern changed.
    struct BatchedNodeAttributes {
        let role: String?
        let title: String?
        let description: String?
        let value: String?
        /// Same shape the old `children(of:)` helper returned: `nil` when
        /// the attribute was unreadable or not an array (non-fatal in the
        /// BFS, exactly as before), otherwise the array filtered to real
        /// `AXUIElement`s -- possibly empty, which is a real "no children"
        /// answer, not a failure.
        let children: [AXUIElement]?
    }

    /// Fetches all five per-node attributes in ONE cross-process round trip
    /// via `AXUIElementCopyMultipleAttributeValues` (available since macOS
    /// 10.4), replacing what used to be up to five sequential blocking AX
    /// IPC calls per visited node: kAXRole, then `matchLabel`'s
    /// kAXTitle/kAXDescription/kAXValue cascade, then kAXChildren. At the
    /// measured ~5,200 elements/s that sequential pattern made the default
    /// 3,000-node budget cost about 0.6s and the 10,000-node ceiling about
    /// 1.9s -- almost all of it spent waiting on round trips whose payloads
    /// could have shared one message.
    ///
    /// PER-SLOT ERROR CONTRACT. The options argument deliberately does NOT
    /// set `.stopOnError`: in that mode the call reports per-attribute
    /// failures per-slot in the returned array -- a slot whose attribute
    /// could not be fetched carries an `AXValue` of type `.axError` wrapping
    /// the failing code (e.g. kAXErrorNoValue, kAXErrorAttributeUnsupported)
    /// while every other slot still carries its real value. That is exactly
    /// the old nil-tolerant per-node semantics: one absent attribute never
    /// disturbed the other four reads, and it must not disturb the other
    /// four slots now. Decoding (and its defensiveness about sentinel
    /// shapes that on-device behavior might vary -- NULL-ish slots included)
    /// lives in `decodeBatchedNodeAttributeSlots`, kept pure so it can be
    /// pinned headlessly.
    ///
    /// MESSAGING TIMEOUT. `AXUIElementSetMessagingTimeout` is state carried
    /// by the element itself (see `configureMessagingTimeout`, which
    /// `resolve()`'s loop applies to every node BEFORE any attribute is
    /// read), so this one batched message observes the same
    /// `perElementMessagingTimeout` each of the five individual calls did.
    /// The worst-case wait on a hung element actually improves: one bounded
    /// wait instead of five back-to-back ones.
    ///
    /// WHY BFS ORDER AND OCCURRENCE SEMANTICS ARE UNTOUCHED. This changes
    /// only how one node's attributes travel, never which nodes are visited
    /// or in what order: the queue, `inspected` accounting, deadline checks,
    /// and `appendBounded`'s caps all run exactly as before, and the
    /// children slot carries the same array `kAXChildren` returned to the
    /// individual copy. Match selection consumes the same values through
    /// the same `matchLabel` cascade in the same title-before-description-
    /// before-value priority, so the Nth highlightable match -- the
    /// occurrence contract -- is the same element it always was.
    ///
    /// FALLBACK. If the batched call itself is rejected as unsupported or
    /// malformed (`.notImplemented`, `.illegalArgument`) rather than merely
    /// failing to answer, fall back to the historical per-attribute reads
    /// for this node so behavior degrades to exactly the old pattern
    /// instead of silently treating the whole node as attribute-less. Any
    /// OTHER whole-call failure (timeout, dead element) decodes to all-nil,
    /// which is precisely what five individual reads against that same
    /// element would have produced.
    private static func batchedNodeAttributes(of element: AXUIElement) -> BatchedNodeAttributes {
        var rawValues: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            batchedNodeAttributeNames as CFArray,
            AXCopyMultipleAttributeOptions(),
            &rawValues
        )
        switch status {
        case .success:
            guard let slots = (rawValues as CFTypeRef?) as? [Any] else {
                // `.success` with no decodable array is not a documented
                // shape; treat it like an unanswered node rather than
                // crashing or guessing.
                return BatchedNodeAttributes(role: nil, title: nil, description: nil,
                                             value: nil, children: nil)
            }
            return decodeBatchedNodeAttributeSlots(slots)
        case .notImplemented, .illegalArgument:
            return BatchedNodeAttributes(
                role: stringAttribute(kAXRoleAttribute, of: element),
                title: stringAttribute(kAXTitleAttribute, of: element),
                description: stringAttribute(kAXDescriptionAttribute, of: element),
                value: stringAttribute(kAXValueAttribute, of: element),
                children: children(of: element)
            )
        default:
            return BatchedNodeAttributes(role: nil, title: nil, description: nil,
                                         value: nil, children: nil)
        }
    }

    /// Pure decode of one batch result array into per-attribute optionals,
    /// indexed by `batchedNodeAttributeNames`' declared order. Split out of
    /// `batchedNodeAttributes` (and internal, not private) because the AX
    /// call itself needs a live target app plus TCC consent, while THIS is
    /// the part where a mistake would silently change matching semantics --
    /// so it must be pinnable headlessly with hand-built slots.
    ///
    /// Defensive on purpose about what a slot may hold, because on-device
    /// sentinel behavior cannot be assumed uniform across apps and OS
    /// versions: a failed slot is DOCUMENTED to be an `.axError` `AXValue`,
    /// but a `kCFNull` placeholder or a short/missing array entry is decoded
    /// to the same `nil` a failed individual read produced rather than
    /// trusted to never occur. A slot holding an unexpected but real type
    /// (say, a CFNumber where a string was hoped for) also decodes to `nil`
    /// for the string fields -- identical to the old `value as? String`
    /// behavior on an individual read.
    static func decodeBatchedNodeAttributeSlots(_ slots: [Any]) -> BatchedNodeAttributes {
        func payload(_ index: Int) -> Any? {
            guard index < slots.count else { return nil }
            return batchSlotPayload(slots[index])
        }
        // Indexes 0...4 follow `batchedNodeAttributeNames`' declared order:
        // role, title, description, value, children.
        return BatchedNodeAttributes(
            role: payload(0) as? String,
            title: payload(1) as? String,
            description: payload(2) as? String,
            value: payload(3) as? String,
            children: (payload(4) as? [Any]).map { list in
                list.compactMap { object -> AXUIElement? in
                    guard CFGetTypeID(object as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
                    return (object as! AXUIElement)
                }
            }
        )
    }

    /// Unwraps one raw batch slot to its usable payload, or `nil` for every
    /// "this attribute was not fetched" sentinel: an `.axError` `AXValue`
    /// (the documented per-slot failure marker -- ANY wrapped code counts,
    /// mirroring the old "any non-`.success` status becomes nil" rule, so
    /// kAXErrorNoValue and kAXErrorAttributeUnsupported land identically)
    /// and `kCFNull` (coded for defensively; see
    /// `decodeBatchedNodeAttributeSlots`). A non-error `AXValue` (a point,
    /// size, or range in the kAXValue slot, say) is NOT a sentinel and is
    /// passed through -- the type-specific casts downstream reject it the
    /// same way `as? String` always rejected it on an individual read.
    static func batchSlotPayload(_ slot: Any) -> Any? {
        let ref = slot as CFTypeRef
        if CFGetTypeID(ref) == CFNullGetTypeID() { return nil }
        if CFGetTypeID(ref) == AXValueGetTypeID(), AXValueGetType(ref as! AXValue) == .axError {
            return nil
        }
        return slot
    }

    // Now used only by `batchedNodeAttributes`' unsupported-batch fallback
    // path -- the BFS's ordinary per-node reads all travel through the
    // batched call above.
    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // Like `stringAttribute` above, now reached only through
    // `batchedNodeAttributes`' unsupported-batch fallback path.
    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        elements(attribute: kAXChildrenAttribute, of: element)
    }

    // Nil-tolerant: used only by the per-node BFS traversal (via the
    // fallback path above), where one unreadable child (of any AXError,
    // timeout included) must stay non-fatal so a single hung grandchild
    // cannot fail the whole lookup.
    // Do NOT use this for the top-level application fetch -- see
    // `copyElements` below and `resolveInitialElements`'s call site for why
    // that fetch needs to keep the AXError instead of discarding it.
    private static func elements(attribute: String, of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? [Any])?.compactMap { object in
            guard CFGetTypeID(object as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    // Error-preserving counterpart to `elements(attribute:of:)`, used ONLY
    // for the application element's `kAXWindows`/`kAXChildren` fetch.  See
    // `AttributeFetch` and `isTransientAXFailure` for why this top-level
    // fetch cannot afford to collapse a timeout into "empty" the way the
    // per-node BFS traversal safely does.
    private static func copyElements(attribute: String, of element: AXUIElement) -> AttributeFetch<AXUIElement> {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return .unreadable(status) }
        let list = (value as? [Any])?.compactMap { object -> AXUIElement? in
            guard CFGetTypeID(object as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        } ?? []
        return .values(list)
    }

    private static func frame(of element: AXUIElement) -> AccessibilityScreenRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue,
              let sizeRef = sizeValue,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        let position = positionRef as! AXValue
        let size = sizeRef as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &cgSize) else {
            return nil
        }
        let frame = AccessibilityScreenRect(x: Double(point.x), y: Double(point.y),
                                            width: Double(cgSize.width), height: Double(cgSize.height))
        return isUsable(frame) ? frame : nil
    }

    /// Publishes an already-SELECTED match. `selected.frame` was read (and
    /// confirmed usable) back in the BFS loop, at the moment this element's
    /// label matched -- see the long comment there for why that is both
    /// cheaper (the frame IPC happens once per LABEL MATCH, not again per
    /// selection) and more correct (no TOCTOU gap between "this element
    /// matched" and "this is the frame we drew a highlight around"). There
    /// is nothing left to re-read here -- and, since the BFS loop also
    /// performs the (pure) backing-pixel conversion at the same moment so an
    /// ambiguity list can show each candidate's geometry, nothing left to
    /// re-convert either. `screens` is therefore not a parameter: there is
    /// exactly one conversion per match, at match time.
    ///
    /// THIS FUNCTION DELIBERATELY PERFORMS NO DEADLINE CHECK, which is why
    /// it no longer takes `startedAt`/`timeout` at all. It used to re-check
    /// the wall-clock deadline here and throw `traversalTimedOut`,
    /// discarding a match the walk had ALREADY finished selecting: every
    /// IPC this result depends on is complete by the time this function
    /// runs (see the paragraph above), so the only thing that re-check
    /// could ever do was convert a real, selected answer into a timeout
    /// error whenever the final node's own IPC nudged the clock past the
    /// deadline -- reporting failure to the caller while holding the
    /// correct rect in hand. Walks that truly fail to finish selecting
    /// still time out exactly as before, via `resolve()`'s check at the top
    /// of every BFS iteration (and its post-initial-fetch check); those are
    /// the checks that bound the walk, and they are untouched. Internal
    /// (not private) so this selected-match-survives contract can be pinned
    /// headlessly.
    static func resolvedMatch(_ selected: InternalMatch) throws -> AccessibilityElementMatch {
        guard let backingFrame = selected.backingFrame else {
            throw AccessibilityElementResolverError.frameCannotBeMapped
        }
        return AccessibilityElementMatch(
            matchedAttribute: selected.candidate.matchedAttribute,
            matchedLabel: selected.candidate.matchedLabel,
            role: selected.candidate.role,
            accessibilityFrame: selected.frame,
            backingFrame: backingFrame
        )
    }

    private static func configureMessagingTimeout(_ element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, perElementMessagingTimeout)
    }

    private static func appendBounded(
        _ elements: [AXUIElement],
        to queue: inout [AXUIElement],
        queuedUninspected: Int,
        inspected: Int,
        maxNodes: Int,
        wasTruncated: inout Bool
    ) {
        let count = boundedAppendCount(
            candidateCount: elements.count,
            queuedUninspected: queuedUninspected,
            inspected: inspected,
            maxNodes: maxNodes
        )
        if count < elements.count { wasTruncated = true }
        guard count > 0 else { return }
        queue.append(contentsOf: elements.prefix(count))
    }

    private static func fullyContains(_ outer: ScreenCoordinateRect, _ inner: ScreenCoordinateRect) -> Bool {
        let epsilon = 0.000_1
        return inner.x >= outer.x - epsilon && inner.y >= outer.y - epsilon
            && inner.maxX <= outer.maxX + epsilon && inner.maxY <= outer.maxY + epsilon
    }

    private static func isUsable(_ frame: AccessibilityScreenRect) -> Bool {
        [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    /// Used only by `AccessibilityFrameDisplaySelection.largestOverlap` (see
    /// `backingRect(forAccessibilityFrame:screens:selection:)`): the screen
    /// whose `frame(_:)` has the largest intersection area with `rect`, or
    /// `nil` when none overlaps at all. Ties resolve to whichever screen is
    /// encountered first in `screens` -- stable, matching this file's other
    /// selection helpers (`TargetWindowSelection.selectWindow` in
    /// `TargetWindowProbe.swift` uses the identical "strictly greater, first
    /// wins ties" rule).
    private static func bestOverlappingScreen(
        _ rect: ScreenCoordinateRect, in screens: [ScreenInfo], frame: (ScreenInfo) -> ScreenCoordinateRect
    ) -> ScreenInfo? {
        var best: ScreenInfo?
        var bestArea = 0.0
        for screen in screens {
            let area = overlapArea(rect, frame(screen))
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    private static func overlapArea(_ a: ScreenCoordinateRect, _ b: ScreenCoordinateRect) -> Double {
        let width = min(a.maxX, b.maxX) - max(a.x, b.x)
        let height = min(a.maxY, b.maxY) - max(a.y, b.y)
        guard width > 0, height > 0 else { return 0 }
        return width * height
    }
}

#elseif os(Windows)
import CChalkboardWin
import Foundation

/// The two intentionally small text matching modes supported by element
/// lookup. Mirrors `chalk_uia_find_element`'s `ChalkUiaMatchMode` exactly
/// (`CHALK_UIA_MATCH_EXACT` / `CHALK_UIA_MATCH_CONTAINS`); see this type's
/// macOS counterpart for why exact is the safe default.
public enum AccessibilityLabelMatchMode: String, Codable, Equatable {
    case exact
    case contains
}

/// Screen-space geometry, in the SAME units `chalk_uia_find_element`'s
/// `ChalkRect` and `chalk_capture_monitor` already use: virtual-desktop,
/// top-left-origin, y-down Win32 screen coordinates. Unlike the macOS
/// counterpart, no bottom-left-to-top-left flip is ever needed to interpret
/// this struct -- see `backingRect(forAccessibilityFrame:screens:)` below.
public struct AccessibilityScreenRect: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The output geometry that free-draw tools consume: top-left-origin backing
/// pixels local to one physical display. Identical shape to the macOS type.
public struct AccessibilityBackingRect: Codable, Equatable {
    public let screenId: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(screenId: String, x: Double, y: Double, width: Double, height: Double) {
        self.screenId = screenId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Result of a read-only UI Automation lookup. `matchedAttribute` is always
/// `"Name"` on Windows -- `chalk_uia_find_element` only ever matches UIA's
/// Name property, unlike macOS's title/description/value cascade -- and
/// `role` is always `nil`: the shim never reports a control type back to
/// Swift (see `AccessibilityElementResolverError.roleFilterNotSupported`).
/// `matchedLabel` is the QUERY string, not necessarily the element's actual
/// published Name: `chalk_uia_find_element` reports bounds and counts only,
/// never the matched string itself, so under `.contains` mode a caller does
/// not see back what the real Name was (only that something containing the
/// query matched). This is a genuine, disclosed reduction versus macOS,
/// where `matchedLabel` is always the real attribute value that was read.
public struct AccessibilityElementMatch: Codable, Equatable {
    public let matchedAttribute: String
    public let matchedLabel: String
    public let role: String?
    public let accessibilityFrame: AccessibilityScreenRect
    public let backingFrame: AccessibilityBackingRect

    public init(matchedAttribute: String, matchedLabel: String, role: String?,
                accessibilityFrame: AccessibilityScreenRect, backingFrame: AccessibilityBackingRect) {
        self.matchedAttribute = matchedAttribute
        self.matchedLabel = matchedLabel
        self.role = role
        self.accessibilityFrame = accessibilityFrame
        self.backingFrame = backingFrame
    }
}

/// Used only to describe the exposed-name sample `chalk_uia_sample_names`
/// collects for a `.noMatches` error (see that case below). Unlike macOS,
/// this is never used to preview an AMBIGUOUS match set: `chalk_uia_find_
/// element` reports only a count for that case (see `.ambiguous` below), not
/// per-candidate labels/roles.
public struct AccessibilityElementCandidate: Codable, Equatable {
    public let matchedAttribute: String
    public let matchedLabel: String
    public let role: String?
    /// ALWAYS NIL ON WINDOWS, and declared anyway for the same reason `role`
    /// is: this type's shape is shared API, and a caller (or a shared test)
    /// written against the macOS `AccessibilityElementCandidate` must
    /// compile and behave identically here. On macOS this carries the
    /// backing-pixel rect of each AMBIGUITY candidate so `occurrence` is
    /// chosen from real coordinates instead of guessed; on Windows this
    /// struct only ever describes `chalk_uia_sample_names` entries, which
    /// report a name and nothing else -- `chalk_uia_find_element` does not
    /// hand back a per-candidate bounding rectangle at all (see
    /// `.ambiguous`, which carries only a count). Closing that gap needs a
    /// shim change; see this port's contractChanges/followUps.
    public let backingFrame: AccessibilityBackingRect?

    public init(matchedAttribute: String, matchedLabel: String, role: String?,
                backingFrame: AccessibilityBackingRect? = nil) {
        self.matchedAttribute = matchedAttribute
        self.matchedLabel = matchedLabel
        self.role = role
        self.backingFrame = backingFrame
    }
}

public struct AccessibilityElementRequest: Equatable {
    public let label: String
    /// Always rejected with `.roleFilterNotSupported` when non-nil on
    /// Windows: `chalk_uia_find_element` has no role/control-type parameter
    /// at all (see that error case's doc comment). Kept in this struct's
    /// shape anyway so `MCPToolHandlers+Highlight.swift`'s call site does
    /// not need a platform-conditional argument list.
    public let role: String?
    public let matchMode: AccessibilityLabelMatchMode
    /// One-based match index. Omit it to require exactly one candidate.
    /// Maps directly to `chalk_uia_find_element`'s `occurrence` parameter,
    /// which uses the SAME 0-means-"require exactly one" convention.
    public let occurrence: Int?
    public let maxNodes: Int
    public let timeoutSeconds: TimeInterval

    public init(label: String, role: String? = nil,
                matchMode: AccessibilityLabelMatchMode = .exact,
                occurrence: Int? = nil, maxNodes: Int = AccessibilityElementResolver.defaultMaxNodes,
                timeoutSeconds: TimeInterval = AccessibilityElementResolver.defaultTraversalTimeoutSeconds) {
        self.label = label
        self.role = role
        self.matchMode = matchMode
        self.occurrence = occurrence
        self.maxNodes = maxNodes
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Windows has no persistent, revocable permission grant analogous to macOS
/// TCC/Accessibility trust -- see `AccessibilityElementResolver.trustStatus`
/// below for why this always reports `trusted: true` rather than performing
/// a check it has no way to make ahead of a real, per-process lookup.
public struct AccessibilityTrustStatus: Codable, Equatable {
    public let trusted: Bool
    public let promptRequested: Bool
    public let note: String

    public init(trusted: Bool, promptRequested: Bool, note: String) {
        self.trusted = trusted
        self.promptRequested = promptRequested
        self.note = note
    }
}

/// Windows counterpart of the macOS error taxonomy, matched one-for-one
/// against `chalk_uia_find_element`'s documented `ChalkErrorCode`s (see
/// chalkboard_win.h Section 3) wherever an equivalent macOS condition
/// exists, PLUS three cases with no macOS analogue at all:
/// `.roleFilterNotSupported` (the shim has no role/control-type parameter),
/// `.elevationBoundary` (UIPI has no macOS AX counterpart), and
/// `.workerPoolExhausted` (the shim's outstanding-UIA-worker-thread cap has
/// no macOS analogue: AXUIElement calls run synchronously on the caller's
/// own thread, so there is no comparable worker pool to exhaust). See each
/// case below for its exact shim mapping.
public enum AccessibilityElementResolverError: LocalizedError, Equatable {
    case invalidRequest(String)
    case invalidProcessID
    /// Maps `CHALK_ERR_UIA_UNAVAILABLE`. The header itself names this "the
    /// Windows analogue of macOS's Accessibility not trusted": the UI
    /// Automation COM service could not be reached at all (CoCreateInstance
    /// of CUIAutomation failed, or CoInitializeEx failed on the shim's
    /// worker thread), so no lookup can succeed until it clears.
    case accessibilityNotTrusted
    /// Maps `CHALK_ERR_UIA_INVALID_PROCESS` for a process ID that PASSED the
    /// `processID > 0` sanity check below but that the shim could not find a
    /// root automation element for (no visible top-level windows -- either
    /// the process is not running, or it simply has none yet). This is the
    /// Windows analogue of macOS's `applicationUnavailable`, NOT
    /// `invalidProcessID`: a live process that has not created a window yet
    /// is "running but currently exposing nothing", exactly the condition
    /// `applicationUnavailable`'s macOS wording already describes -- see
    /// `resolve(processID:request:screens:)`'s pre-check for the OTHER half
    /// of `CHALK_ERR_UIA_INVALID_PROCESS`'s documented meaning ("does not
    /// name a currently-running process"), which this file catches earlier,
    /// Swift-side, as `.invalidProcessID` instead, mirroring macOS's own
    /// `processID > 0` guard.
    case applicationUnavailable
    /// Maps `CHALK_ERR_UIA_RETRYABLE_TIMEOUT`. The header explicitly
    /// documents this as retryable "the same way the macOS resolver treats
    /// applicationBusy" -- a UIA provider call did not answer within
    /// `timeout_seconds` (COM RPC timeout, or a busy target), not a
    /// permanent absence of automation support.
    case applicationBusy
    /// Maps `CHALK_ERR_UIA_NODE_BUDGET_EXHAUSTED`. Counts elements VISITED
    /// by the shim's breadth-first ControlView walk, exactly like macOS's
    /// `traversalLimitReached` -- narrowing `label` does not lower it; only
    /// `max_nodes`/`timeout_seconds`/`occurrence` do.
    case traversalLimitReached(Int)
    /// Maps `CHALK_ERR_UIA_NO_MATCH`. `exposedSample` is collected via a
    /// SEPARATE `chalk_uia_sample_names` call (see
    /// `AccessibilityElementResolver.sampleNames`) after the primary lookup
    /// fails, since -- unlike macOS, where the sample is free (reusing reads
    /// the BFS already made) -- the shim's own manual walk is opaque to
    /// Swift and gives back no per-node data to harvest.
    case noMatches(label: String, role: String?, exposedSample: [AccessibilityElementCandidate])
    /// Maps `CHALK_ERR_UIA_AMBIGUOUS`. Carries only a COUNT, unlike macOS's
    /// `.ambiguous([AccessibilityElementCandidate])`: `chalk_uia_find_
    /// element` reports `out_match_count` for this case and nothing else --
    /// no per-candidate label/role list is available at this layer. Closing
    /// that gap would need either a shim change (a candidate-list out
    /// parameter) or a second best-effort `chalk_uia_sample_names` scan
    /// filtered client-side for names that plausibly matched; neither is
    /// implemented here (see this port's contractChanges/followUps).
    case ambiguous(matchCount: Int)
    /// Maps `CHALK_ERR_UIA_OCCURRENCE_OUT_OF_RANGE`. Same shape as macOS:
    /// `available` and `framelessMatchCount` come straight from the shim's
    /// `out_match_count`/`out_frameless_count`.
    case occurrenceOutOfRange(requested: Int, available: Int, framelessMatchCount: Int)
    /// Maps `CHALK_ERR_UIA_NO_USABLE_BOUNDS`. `matchCount` is
    /// `out_frameless_count`: elements whose Name matched but whose
    /// `BoundingRectangle` was empty/non-finite, so there was nothing to
    /// draw around -- same meaning as macOS's `matchesHaveNoUsableFrame`.
    case matchesHaveNoUsableFrame(matchCount: Int)
    case frameCannotBeMapped
    /// NO MACOS ANALOGUE. `chalk_uia_find_element` has no role/control-type
    /// parameter at all -- the header's Section 3 only ever matches on the
    /// Name property (see `ChalkUiaMatchMode`'s doc comment). Rather than
    /// silently ignore a caller-supplied `role` (which would produce
    /// results the caller reasonably believes were role-filtered but were
    /// not), `AccessibilityElementResolver.resolve` refuses up front with
    /// this case whenever `request.role` is non-nil. This is a genuine,
    /// disclosed capability gap versus macOS's native `kAXRoleAttribute`
    /// filtering -- see contractChanges.
    ///
    /// THIS IS ALSO WHY macOS's `.labelSeenUnderOtherRoles` has no Windows
    /// counterpart, and why it needs none. That case exists because a macOS
    /// `role` is compared verbatim against the app's own AXRole string, so a
    /// wrong or mis-cased guess ("button" vs. "AXButton") silently matches
    /// nothing while the label is in fact published -- a failure this
    /// platform cannot reach, because a supplied role never gets as far as
    /// filtering anything: it is refused here, up front, by name. Case-set
    /// divergence between the two branches is established practice in this
    /// file (macOS's `.traversalTimedOut` likewise has no counterpart here);
    /// the requirement is that each platform's set be complete for its own
    /// reachable failures, not that the two sets be equal.
    case roleFilterNotSupported
    /// NO MACOS ANALOGUE. Maps `CHALK_ERR_UIA_ACCESS_DENIED`: the target
    /// process is elevated (running as administrator) and AI Chalkboard is
    /// not, so User Interface Privilege Isolation (UIPI) blocks UI
    /// Automation from crossing into its tree at all. No retry, no budget
    /// change, and no macOS AX permission has ever needed to express this --
    /// macOS's Accessibility API carries no equivalent privilege-level
    /// boundary. The only fixes are running AI Chalkboard elevated too, or
    /// falling back to screenshot-measured coordinates.
    case elevationBoundary
    /// NO MACOS ANALOGUE. Maps `CHALK_ERR_UIA_TOO_MANY_PENDING`: the shim
    /// already has its cap's worth of UIA worker threads outstanding (see
    /// `kMaxOutstandingUiaWorkers` in chalk_uia.cpp) -- most of them likely
    /// permanently stuck inside a hung UI Automation provider call that
    /// classic UI Automation gives the shim no way to cancel. NOT
    /// RETRYABLE, unlike `.applicationBusy`/`CHALK_ERR_UIA_RETRYABLE_
    /// TIMEOUT`: per the header's own doc comment on this code, retrying --
    /// with the same or a different process -- only adds another stuck
    /// thread on top of an already-saturated pool. AXUIElement calls run
    /// synchronously on the caller's own thread on macOS, with no
    /// comparable worker-pool resource to exhaust, hence no analogue there.
    case workerPoolExhausted

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return "Invalid accessibility lookup request: \(message)"
        case .invalidProcessID:
            return "The target app does not have a valid running process ID, so its UI Automation tree cannot be inspected."
        case .accessibilityNotTrusted:
            return "AI Chalkboard could not reach the Windows UI Automation service (the COM UIA client could not be created). This usually clears on its own; retry the lookup. Unlike macOS, there is no permission to grant in a settings panel here."
        case .applicationUnavailable:
            return "The target app's UI Automation hierarchy is unavailable: it has no visible top-level windows yet. Ensure the app is running and has at least one window open, then retry."
        case .applicationBusy:
            return "The target app did not answer its UI Automation request within the messaging timeout. This is usually transient (the app was busy), not a missing UI Automation implementation; retry the lookup rather than assuming the UI is not exposed to UI Automation."
        case .traversalLimitReached(let limit):
            return "Stopped after inspecting \(limit) UI Automation elements without finishing the tree. This cap counts elements VISITED, not candidates, so narrowing label does not lower it. Try supplying occurrence FIRST (e.g. occurrence: 1): the walk only keeps going past a match in order to PROVE uniqueness, so an explicit occurrence returns the first highlightable match immediately instead of finishing the tree. Then confirm the result with verify_annotation, because occurrence short-circuits uniqueness checking: you get the first highlightable match, never a guarantee that it is the only one. If ambiguity detection across the whole tree is actually required, raise max_nodes (up to \(AccessibilityElementResolver.absoluteMaxNodes)) together with timeout_seconds (up to \(Int(AccessibilityElementResolver.maxTraversalTimeoutSeconds))). Some applications publish hierarchies far larger than any bounded read can enumerate; for those, element anchoring is not available at all -- measure from an uncropped full-display screenshot instead and confirm the result with verify_annotation."
        case .noMatches(let label, let role, let exposedSample):
            let roleNote = role.map { " with role '\($0)'" } ?? ""
            guard !exposedSample.isEmpty else {
                return "No UI Automation element matched name '\(label)'\(roleNote). The UI may not expose that control to Windows UI Automation."
            }
            let lowerQuery = label.lowercased()
            let ranked = exposedSample.sorted { lhs, rhs in
                Self.isRelatedLabel(lhs.matchedLabel, toLowercasedQuery: lowerQuery)
                    && !Self.isRelatedLabel(rhs.matchedLabel, toLowercasedQuery: lowerQuery)
            }
            let preview = ranked.prefix(8).map { "'\($0.matchedLabel)'" }.joined(separator: ", ")
            let more = ranked.count > 8 ? " (and \(ranked.count - 8) more)" : ""
            return "No UI Automation element matched name '\(label)'\(roleNote). Names that ARE exposed here include: \(preview)\(more). Retry with one of those names instead of falling back to screen coordinates."
        case .ambiguous(let matchCount):
            // The occurrence-ordering sentence is worded identically to the
            // macOS `.ambiguous` case on purpose: the ordering claim is a
            // property of a breadth-first walk, which BOTH platforms perform
            // (`chalk_uia_find_element` walks the ControlView breadth-first
            // shim-side), and a caller must not have to learn two different
            // rules for the same argument. What genuinely differs is that
            // there is no numbered candidate list to read it off here.
            return "UI Automation lookup is ambiguous across \(matchCount) elements. Windows UI Automation does not report a per-element preview for this case (unlike macOS); supply a one-based occurrence to disambiguate. OCCURRENCE INDEXES BREADTH-FIRST DISCOVERY ORDER (outermost/earliest-visited element first), not visual top-to-bottom or left-to-right order, so try occurrence 1 upward and confirm each placement with verify_annotation rather than inferring an index from where the control appears on screen."
        case .occurrenceOutOfRange(let requested, let available, let framelessMatchCount):
            let framelessNote = framelessMatchCount > 0
                ? " \(framelessMatchCount) additional element(s) also matched the name but were skipped because they published no usable bounding rectangle, so they could not be assigned an occurrence."
                : ""
            return "Requested accessibility occurrence \(requested), but only \(available) highlightable matching element(s) were found. Occurrence is one-based.\(framelessNote)"
        case .matchesHaveNoUsableFrame(let matchCount):
            return "\(matchCount) element(s) matched the name but none published a usable bounding rectangle, so there is nothing to draw around. Try a different name, or fall back to screenshot-measured coordinates confirmed with verify_annotation."
        case .frameCannotBeMapped:
            return "The matched element's bounding rectangle does not fit wholly on one connected display, so safe screen-local backing-pixel placement is impossible."
        case .roleFilterNotSupported:
            return "role filtering is not supported on Windows: the UI Automation lookup this build uses matches only an element's Name property and has no control-type/role parameter. Omit role, or narrow the search with occurrence instead."
        case .elevationBoundary:
            return "The target app is running elevated (as administrator) and AI Chalkboard is not, so Windows UI Privilege Isolation (UIPI) blocks UI Automation from reading its interface. Run AI Chalkboard elevated too, or fall back to screenshot-measured coordinates confirmed with verify_annotation."
        case .workerPoolExhausted:
            return "AI Chalkboard's Windows UI Automation worker pool is fully occupied, most likely by earlier lookups stuck inside an unresponsive UI Automation provider that cannot be cancelled. This is NOT a busy target worth retrying immediately: retrying now -- against this process or another one -- only queues another thread behind the ones already stuck. Fall back to screenshot-measured coordinates confirmed with verify_annotation, or wait for the wedged target app to become responsive (or restart it) before attempting another element lookup."
        }
    }

    private static func isRelatedLabel(_ label: String, toLowercasedQuery lowercasedQuery: String) -> Bool {
        let lowercasedLabel = label.lowercased()
        return lowercasedLabel.contains(lowercasedQuery) || lowercasedQuery.contains(lowercasedLabel)
    }
}

/// Read-only bridge from a running application's UI Automation tree to
/// Chalkboard's screen-local backing pixels -- the Windows counterpart of
/// the macOS `AccessibilityElementResolver` above, backed by
/// `chalk_uia_find_element`/`chalk_uia_sample_names` instead of AXUIElement.
/// Same public API surface (type names, static members, method signatures
/// modulo the `pid_t` -> `UInt32` process-id type -- see
/// `resolve(processID:request:screens:)`'s doc comment) so
/// `MCPToolCatalog.swift`/`MCPToolHandlers.swift`/`MCPToolHandlers+
/// Highlight.swift` need no platform branching of their own to call it.
public enum AccessibilityElementResolver {
    public static let defaultMaxNodes = 3_000
    public static let absoluteMaxNodes = 10_000
    public static let defaultTraversalTimeoutSeconds: TimeInterval = 2.0
    public static let minTraversalTimeoutSeconds: TimeInterval = 0.5
    public static let maxTraversalTimeoutSeconds: TimeInterval = 10.0
    /// Bounds on the `chalk_uia_sample_names` sample attached to a
    /// `.noMatches` error. Same numeric values as macOS for parity, though
    /// the mechanism differs (a real, separate shim call here vs. free reuse
    /// of reads the BFS already made on macOS -- see `.noMatches`'s doc
    /// comment on `AccessibilityElementResolverError`).
    static let maxExposedSampleCount = 64
    static let maxExposedSampleLabelCharacters = 128
    /// UTF-16 code units reserved for `chalk_uia_sample_names`'s NUL-
    /// separated output buffer. Comfortably larger than
    /// `maxExposedSampleCount` NUL-terminated short control names could ever
    /// need; `chalk_uia_sample_names` degrades gracefully (writes fewer
    /// names, never partially) if this is ever too small.
    private static let sampleNamesBufferCapacity = 8_192

    // Literal ChalkErrorCode / ChalkUiaMatchMode values from chalkboard_win.h,
    // used directly (not via the imported C enum's case names) for the same
    // reason `WindowsRasterImageError`'s shim-status mapping does this --
    // robustness to however ClangImporter happens to shape a plain
    // (non-`enum class`) C enum, independent of this file.
    private static let chalkOk: Int32 = 0
    private static let chalkErrInvalidArgument: Int32 = -1
    private static let chalkErrUiaUnavailable: Int32 = -300
    private static let chalkErrUiaNoMatch: Int32 = -301
    private static let chalkErrUiaNoUsableBounds: Int32 = -302
    private static let chalkErrUiaAmbiguous: Int32 = -303
    private static let chalkErrUiaOccurrenceOutOfRange: Int32 = -304
    private static let chalkErrUiaRetryableTimeout: Int32 = -305
    private static let chalkErrUiaNodeBudgetExhausted: Int32 = -306
    private static let chalkErrUiaAccessDenied: Int32 = -307
    private static let chalkErrUiaInvalidProcess: Int32 = -308
    private static let chalkErrUiaTooManyPending: Int32 = -309
    private static let chalkUiaMatchExact: Int32 = 0
    private static let chalkUiaMatchContains: Int32 = 1

    /// Windows UI Automation has no persistent, revocable permission grant
    /// analogous to macOS TCC/Accessibility trust -- `CHALK_ERR_UIA_
    /// UNAVAILABLE` (COM/UIA service unreachable) and `CHALK_ERR_UIA_ACCESS_
    /// DENIED` (elevation boundary) are each discovered per-call, against
    /// one specific process, by `chalk_uia_find_element`/`chalk_uia_sample_
    /// names` -- chalkboard_win.h exposes no process-independent probe this
    /// method could call instead. Reporting an honest "unknown until you
    /// try" would break `AccessibilityTrustStatus.trusted`'s `Bool` contract
    /// for every caller (`get_accessibility_status`), so this reports an
    /// OPTIMISTIC `trusted: true` unconditionally and says so in `note` --
    /// `highlight_element`'s own `accessibilityNotTrusted`/`elevationBoundary`
    /// errors are the true, per-lookup signal on this platform. This is a
    /// disclosed behavioral difference from macOS's `trustStatus()`, which
    /// performs a REAL live check (`AXIsProcessTrustedWithOptions`) that can
    /// genuinely answer `false` — see contractChanges.
    public static func trustStatus(requestPrompt: Bool = false) -> AccessibilityTrustStatus {
        var note = "Windows UI Automation has no persistent permission grant to check ahead of a lookup (unlike macOS Accessibility/TCC). Availability and elevation-boundary failures are reported per element lookup by highlight_element itself, not by this status check."
        if requestPrompt {
            note += " request_permission has no effect on Windows: there is no system prompt to trigger."
        }
        return AccessibilityTrustStatus(trusted: true, promptRequested: false, note: note)
    }

    /// Finds a target inside a running application identified by its
    /// Windows process id. `UInt32`, not `pid_t` -- `pid_t` does not exist
    /// on the Windows Swift toolchain (confirmed: it fails to compile), and
    /// `UInt32` is both what `chalk_uia_find_element`'s `process_id`
    /// parameter is declared as and what `GetProcessId`/`GetWindowThread
    /// ProcessId` naturally hand back. This is a disclosed process-id-type
    /// difference from the macOS signature -- see contractChanges. Nothing
    /// outside this file and `MCPToolHandlers+Highlight.swift` (both owned
    /// together) depends on the exact type name.
    public static func resolve(
        processID: UInt32,
        request: AccessibilityElementRequest,
        screens: [ScreenInfo]
    ) throws -> AccessibilityElementMatch {
        guard processID > 0 else { throw AccessibilityElementResolverError.invalidProcessID }
        let normalized = try validated(request)
        guard !screens.isEmpty else { throw AccessibilityElementResolverError.frameCannotBeMapped }

        var outBounds = ChalkRect(x: 0, y: 0, w: 0, h: 0)
        var outMatchCount: Int32 = 0
        var outFramelessCount: Int32 = 0
        let matchModeArg = normalized.matchMode == .contains ? chalkUiaMatchContains : chalkUiaMatchExact
        // 0 means "require exactly one" -- the SAME sentinel convention
        // `AccessibilityElementRequest.occurrence == nil` already uses on
        // macOS, so no translation beyond unwrapping is needed.
        let occurrenceArg = Int32(normalized.occurrence ?? 0)

        let status: Int32 = withWideString(normalized.label) { wname in
            chalk_uia_find_element(
                processID, wname, matchModeArg, occurrenceArg,
                Int32(normalized.maxNodes), normalized.timeoutSeconds,
                &outBounds, &outMatchCount, &outFramelessCount
            )
        }

        switch status {
        case chalkOk:
            let frame = AccessibilityScreenRect(x: outBounds.x, y: outBounds.y, width: outBounds.w, height: outBounds.h)
            guard let backingFrame = backingRect(forAccessibilityFrame: frame, screens: screens) else {
                throw AccessibilityElementResolverError.frameCannotBeMapped
            }
            return AccessibilityElementMatch(
                matchedAttribute: "Name",
                // See AccessibilityElementMatch's doc comment: the shim
                // never reports the element's actual Name back, only that
                // one matched, so this echoes the query rather than the
                // real published string.
                matchedLabel: normalized.label,
                role: nil,
                accessibilityFrame: frame,
                backingFrame: backingFrame
            )
        case chalkErrUiaNoMatch:
            throw AccessibilityElementResolverError.noMatches(
                label: normalized.label, role: nil, exposedSample: sampleNames(processID: processID)
            )
        case chalkErrUiaNoUsableBounds:
            throw AccessibilityElementResolverError.matchesHaveNoUsableFrame(matchCount: Int(outFramelessCount))
        case chalkErrUiaAmbiguous:
            throw AccessibilityElementResolverError.ambiguous(matchCount: Int(outMatchCount))
        case chalkErrUiaOccurrenceOutOfRange:
            throw AccessibilityElementResolverError.occurrenceOutOfRange(
                requested: normalized.occurrence ?? 0, available: Int(outMatchCount),
                framelessMatchCount: Int(outFramelessCount)
            )
        case chalkErrUiaRetryableTimeout:
            throw AccessibilityElementResolverError.applicationBusy
        case chalkErrUiaNodeBudgetExhausted:
            throw AccessibilityElementResolverError.traversalLimitReached(normalized.maxNodes)
        case chalkErrUiaAccessDenied:
            throw AccessibilityElementResolverError.elevationBoundary
        case chalkErrUiaInvalidProcess:
            // Reached only for a positive processID the shim itself could
            // not find a root element for -- see applicationUnavailable's
            // doc comment for why THIS is the right Swift case rather than
            // invalidProcessID (already handled by the guard above).
            throw AccessibilityElementResolverError.applicationUnavailable
        case chalkErrUiaTooManyPending:
            throw AccessibilityElementResolverError.workerPoolExhausted
        case chalkErrUiaUnavailable:
            throw AccessibilityElementResolverError.accessibilityNotTrusted
        case chalkErrInvalidArgument:
            // Defense in depth only: `validated(_:)` above should already
            // have rejected anything that would make the shim itself see an
            // invalid argument.
            throw AccessibilityElementResolverError.invalidRequest("Windows UI Automation lookup rejected its own arguments (shim status \(status)).")
        default:
            throw AccessibilityElementResolverError.invalidRequest("Windows UI Automation lookup failed with unexpected status \(status).")
        }
    }

    /// Pure AX top-left global logical-point -> local backing-pixel
    /// conversion -- the Windows counterpart of the macOS function of the
    /// same name, dramatically simpler because there is no AppKit bottom-
    /// left-origin flip to undo: `frame` (from `chalk_uia_find_element`'s
    /// `ChalkRect`) and `screen.windowServerFrame` are both already in the
    /// SAME virtual-desktop, top-left-origin, y-down Win32 screen-coordinate
    /// space (the same convention `chalk_capture_monitor` documents).
    ///
    /// ASSUMPTION, disclosed rather than silently relied upon: this treats
    /// `frame` and every screen's `windowServerFrame` as already being in
    /// the SAME physical-pixel units -- it does not multiply by `backing
    /// ScaleFactor` the way the macOS conversion (points -> pixels) must.
    /// That is correct only if (a) AI Chalkboard is Per-Monitor-V2 DPI
    /// aware, so `IUIAutomationElement.get_CurrentBoundingRectangle` hands
    /// back physical pixels rather than DIPs, and (b) the Windows
    /// `ScreenSnapshot`/`buildScreenInfos()` implementation (owned
    /// separately -- not part of this change) populates `windowServerFrame`
    /// in physical pixels too, matching `chalk_capture_monitor`'s own pixel
    /// space. If either side of that assumption changes, this conversion
    /// must change with it -- see contractChanges/followUps.
    ///
    /// WHERE (a) IS ACTUALLY VERIFIED AT RUNTIME, so this comment is not the
    /// only thing standing behind it: `OverlayWindowController.ensureProcess
    /// DpiAwareness()` sets PER_MONITOR_AWARE_V2 once per process before any
    /// window exists and, when that call fails (it legitimately does when
    /// `Launcher/main.swift` already set it), reads the real state back with
    /// `GetThreadDpiAwarenessContext()` + `AreDpiAwarenessContextsEqual` and
    /// logs an ERROR if -- and only if -- the process is genuinely NOT
    /// per-monitor-v2 aware. Every path through that function therefore ends
    /// either in the awareness this conversion needs or in a logged ERROR
    /// naming its absence, which is why no second, per-lookup DPI probe is
    /// duplicated here: it would re-ask a question already answered once,
    /// authoritatively, at the only point in the process's life where the
    /// answer can still be changed.
    /// How a frame that does not sit wholly inside a single display is
    /// mapped onto exactly one. Identical shape and identical case-by-case
    /// meaning to the macOS `AccessibilityFrameDisplaySelection` above --
    /// see that type's doc comment for the full rationale, repeated here
    /// only in brief because this file duplicates each per-platform type
    /// rather than sharing declarations across the `#if` boundary.
    public enum AccessibilityFrameDisplaySelection {
        /// The frame must be fully contained by exactly one display. This is
        /// `backingRect`'s DEFAULT and must stay behaviourally unchanged --
        /// correct for a UI ELEMENT, which cannot straddle two displays and
        /// still be represented by one Chalkboard annotation.
        case requireContainment
        /// The display with the largest intersection area wins; a frame
        /// that intersects NO display is still rejected (`nil`). Correct
        /// for a WINDOW, which is routinely dragged across a display
        /// boundary or pushed partly off the desktop edge -- see the macOS
        /// enum's doc comment for why `requireContainment` would be actively
        /// harmful there. The returned rect's x/y MAY be negative, or its
        /// far edge may extend past the chosen display's own extent under
        /// this case; that is expected and is deliberately left unclipped.
        case largestOverlap
    }

    public static func backingRect(
        forAccessibilityFrame frame: AccessibilityScreenRect,
        screens: [ScreenInfo],
        selection: AccessibilityFrameDisplaySelection = .requireContainment
    ) -> AccessibilityBackingRect? {
        guard isUsable(frame) else { return nil }
        let frameRect = ScreenCoordinateRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let screen: ScreenInfo?
        switch selection {
        case .requireContainment:
            // Elements which straddle displays cannot be represented by one
            // Chalkboard annotation, whose coordinates deliberately name
            // exactly one screen -- same "reject rather than silently clip
            // or choose a monitor" policy as the macOS branch.
            screen = screens.first(where: { fullyContains($0.windowServerFrame, frameRect) })
        case .largestOverlap:
            screen = bestOverlappingScreen(frameRect, in: screens, frame: \.windowServerFrame)
        }
        guard let screen else { return nil }
        return AccessibilityBackingRect(
            screenId: screen.id,
            x: frame.x - screen.windowServerFrame.x,
            y: frame.y - screen.windowServerFrame.y,
            width: frame.width,
            height: frame.height
        )
    }

    // MARK: - Pure matching helpers

    /// Kept for API parity with the macOS resolver even though `resolve()`
    /// never calls it here (name matching happens inside the C++ shim's own
    /// walk, invisible to Swift) -- a pure, platform-independent predicate
    /// with no reason to differ from macOS's.
    static func labelMatches(_ candidate: String, query: String, mode: AccessibilityLabelMatchMode) -> Bool {
        switch mode {
        case .exact:
            return candidate == query
        case .contains:
            return candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func validated(_ request: AccessibilityElementRequest) throws -> AccessibilityElementRequest {
        let label = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw AccessibilityElementResolverError.invalidRequest("label must be a non-empty string.")
        }
        guard label.count <= 1_024 else {
            throw AccessibilityElementResolverError.invalidRequest("label may contain at most 1024 characters.")
        }
        // See AccessibilityElementResolverError.roleFilterNotSupported: the
        // shim has no role/control-type parameter, so a supplied role is
        // refused outright rather than silently ignored (which would make
        // a caller believe results were role-filtered when they were not).
        if request.role != nil {
            throw AccessibilityElementResolverError.roleFilterNotSupported
        }
        if let occurrence = request.occurrence, occurrence < 1 {
            throw AccessibilityElementResolverError.invalidRequest("occurrence must be one-based and greater than zero when supplied.")
        }
        guard request.maxNodes > 0, request.maxNodes <= absoluteMaxNodes else {
            throw AccessibilityElementResolverError.invalidRequest("maxNodes must be between 1 and \(absoluteMaxNodes).")
        }
        guard request.timeoutSeconds.isFinite,
              request.timeoutSeconds >= minTraversalTimeoutSeconds,
              request.timeoutSeconds <= maxTraversalTimeoutSeconds else {
            throw AccessibilityElementResolverError.invalidRequest("timeoutSeconds must be between \(minTraversalTimeoutSeconds) and \(maxTraversalTimeoutSeconds).")
        }
        return AccessibilityElementRequest(label: label, role: nil, matchMode: request.matchMode,
                                           occurrence: request.occurrence, maxNodes: request.maxNodes,
                                           timeoutSeconds: request.timeoutSeconds)
    }

    /// Collects the exposed-name sample for a `.noMatches` error via
    /// `chalk_uia_sample_names`, mirroring the intent of macOS's free reuse
    /// of BFS reads -- but as a genuinely separate call, since the shim's
    /// own internal walk gives Swift no per-node data to harvest. Best-
    /// effort: any non-`CHALK_OK` status (unavailable, access denied,
    /// invalid process -- all of which `resolve()` would already have hit
    /// moments earlier via `chalk_uia_find_element` for the SAME process)
    /// degrades to an empty sample rather than throwing a second, redundant
    /// error out of an error-message-building helper.
    private static func sampleNames(processID: UInt32) -> [AccessibilityElementCandidate] {
        var buffer = [UInt16](repeating: 0, count: sampleNamesBufferCapacity)
        var outCount: Int32 = 0
        let status: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
            chalk_uia_sample_names(processID, Int32(maxExposedSampleCount), buf.baseAddress, Int32(buf.count), &outCount)
        }
        guard status == chalkOk, outCount > 0 else { return [] }

        var candidates: [AccessibilityElementCandidate] = []
        var cursor = 0
        for _ in 0..<Int(outCount) {
            guard cursor < buffer.count else { break }
            var end = cursor
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            let name = String(decoding: buffer[cursor..<end], as: UTF16.self)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= maxExposedSampleLabelCharacters {
                candidates.append(AccessibilityElementCandidate(matchedAttribute: "Name", matchedLabel: trimmed, role: nil))
            }
            cursor = end + 1 // skip the NUL separator
        }
        return candidates
    }

    /// Converts a Swift `String` to the NUL-terminated UTF-16 buffer every
    /// text-taking shim call expects -- same helper shape as
    /// `GDIPlusDrawingContext.withWideString`, duplicated locally rather
    /// than shared because these two files have no common base type to hang
    /// a shared helper on without restructuring either one.
    private static func withWideString<R>(_ text: String, _ body: (UnsafePointer<UInt16>) -> R) -> R {
        var utf16 = Array(text.utf16)
        utf16.append(0)
        return utf16.withUnsafeBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }

    private static func fullyContains(_ outer: ScreenCoordinateRect, _ inner: ScreenCoordinateRect) -> Bool {
        let epsilon = 0.000_1
        return inner.x >= outer.x - epsilon && inner.y >= outer.y - epsilon
            && inner.maxX <= outer.maxX + epsilon && inner.maxY <= outer.maxY + epsilon
    }

    private static func isUsable(_ frame: AccessibilityScreenRect) -> Bool {
        [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    /// Used only by `AccessibilityFrameDisplaySelection.largestOverlap` --
    /// identical logic to the macOS branch's helper of the same name (see
    /// its doc comment); duplicated rather than shared per this file's
    /// standing per-platform-block convention.
    private static func bestOverlappingScreen(
        _ rect: ScreenCoordinateRect, in screens: [ScreenInfo], frame: (ScreenInfo) -> ScreenCoordinateRect
    ) -> ScreenInfo? {
        var best: ScreenInfo?
        var bestArea = 0.0
        for screen in screens {
            let area = overlapArea(rect, frame(screen))
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    private static func overlapArea(_ a: ScreenCoordinateRect, _ b: ScreenCoordinateRect) -> Double {
        let width = min(a.maxX, b.maxX) - max(a.x, b.x)
        let height = min(a.maxY, b.maxY) - max(a.y, b.y)
        guard width > 0, height > 0 else { return 0 }
        return width * height
    }
}
#endif
