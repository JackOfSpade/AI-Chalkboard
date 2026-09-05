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

    public init(matchedAttribute: String, matchedLabel: String, role: String?) {
        self.matchedAttribute = matchedAttribute
        self.matchedLabel = matchedLabel
        self.role = role
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
            return "Stopped after inspecting \(limit) accessibility elements without finishing the tree. This cap counts elements VISITED, not candidates, so narrowing label or role does not lower it. Try supplying occurrence FIRST (e.g. occurrence: 1): the walk only keeps going past a match in order to PROVE uniqueness, so an explicit occurrence returns the first highlightable match immediately instead of finishing the tree -- measured at 0.01-1.3s against a large DaVinci Resolve accessibility tree versus a 4.2s node-cap failure with no occurrence supplied. If ambiguity detection across the whole tree is actually required, raise max_nodes (up to \(AccessibilityElementResolver.absoluteMaxNodes)) together with timeout_seconds (up to \(Int(AccessibilityElementResolver.maxTraversalTimeoutSeconds))), since a longer walk also needs longer to run. Some applications publish hierarchies far larger than any bounded read can enumerate -- a measured DaVinci Resolve session exceeded 60,000 elements in 11 seconds without completing -- and for those, element anchoring is not available at all: measure from an uncropped full-display screenshot instead and confirm the result with verify_annotation."
        case .traversalTimedOut(let seconds):
            return "Stopped accessibility lookup after \(String(format: "%.1f", seconds)) seconds without finishing the tree. The deadline bounds the whole breadth-first walk, so narrowing label or role does not help. Try supplying occurrence FIRST (e.g. occurrence: 1): the walk only keeps going past a match in order to PROVE uniqueness, so an explicit occurrence returns the first highlightable match immediately instead of finishing the tree -- measured at 0.01-1.3s against a large DaVinci Resolve accessibility tree versus a 4.2s node-cap failure with no occurrence supplied. If ambiguity detection across the whole tree is actually required, raise timeout_seconds (up to \(Int(AccessibilityElementResolver.maxTraversalTimeoutSeconds))), and raise max_nodes with it if the walk is also hitting that cap. If the target application publishes a very large hierarchy, element anchoring may not be reachable at any allowed budget -- measure from an uncropped full-display screenshot instead and confirm the result with verify_annotation."
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
        case .ambiguous(let matches):
            let preview = matches.prefix(8).map { "'\($0.matchedLabel)' [\($0.role ?? "unknown role")] via \($0.matchedAttribute)" }.joined(separator: ", ")
            let more = matches.count > 8 ? " (and \(matches.count - 8) more)" : ""
            return "Accessibility lookup is ambiguous across \(matches.count) elements: \(preview)\(more). Add a role or supply a one-based occurrence."
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

            let role = stringAttribute(kAXRoleAttribute, of: element)
            if normalized.role == nil || normalized.role == role {
                let inspection = matchLabel(on: element, query: normalized.label, mode: normalized.matchMode)
                // `inspection.sampled` is exactly the title/description
                // reads `matchLabel` already performed while looking for a
                // match on THIS node -- recording them costs no extra IPC.
                // This runs whether or not the node matched, because the
                // overall traversal's outcome (a clean match vs. eventual
                // `.noMatches`) is not yet known; if any match is found
                // anywhere, `exposedSample` is simply never read.
                for sampled in inspection.sampled {
                    recordExposedSample(
                        attribute: sampled.attribute, value: sampled.value, role: role,
                        into: &exposedSample, seen: &exposedSampleSeen
                    )
                }
                if let labelMatch = inspection.match {
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
                        let match = InternalMatch(
                            frame: elementFrame,
                            candidate: AccessibilityElementCandidate(
                                matchedAttribute: labelMatch.attribute,
                                matchedLabel: publishedMatchLabel(
                                    attribute: labelMatch.attribute,
                                    value: labelMatch.value,
                                    query: normalized.label
                                ),
                                role: role
                            )
                        )
                        matches.append(match)
                        // An explicit occurrence now means the Nth
                        // HIGHLIGHTABLE match: a frameless match never
                        // reaches this branch (see the `else` below), so it
                        // cannot consume an occurrence slot or shift the
                        // numbering of the highlightable matches that follow
                        // it. Later nodes cannot alter the identity of the
                        // Nth highlightable match, so avoid needless child
                        // IPC (and a much larger traversal) once that
                        // requested match is found.
                        if let occurrence = normalized.occurrence, matches.count == occurrence {
                            return try resolvedMatch(match, screens: screens, startedAt: startedAt,
                                                         timeout: normalized.timeoutSeconds)
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
                }
            }

            if let children = children(of: element) {
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

        return try resolvedMatch(selected, screens: screens, startedAt: startedAt,
                                 timeout: normalized.timeoutSeconds)
    }

    /// Pure AX top-left global logical-point -> local backing-pixel conversion.
    /// AppKit's desktop has a bottom-left origin, hence the explicit desktop
    /// top calculation.  This lives outside the resolver so mixed-scale and
    /// secondary-display math can be unit-tested without an AX/TCC session.
    public static func backingRect(
        forAccessibilityFrame frame: AccessibilityScreenRect,
        screens: [ScreenInfo]
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
        // Elements which straddle displays cannot be represented by one
        // Chalkboard annotation, whose coordinates deliberately name exactly
        // one screen.  Reject rather than silently clip or choose a monitor.
        guard let screen = screens.first(where: { fullyContains($0.appKitFrame, appKitRect) }) else {
            return nil
        }
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
    private struct InternalMatch {
        let frame: AccessibilityScreenRect
        let candidate: AccessibilityElementCandidate
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

    /// `sampled` carries every kAXTitle/kAXDescription value this call
    /// actually read while looking for a match, independent of whether that
    /// attribute (or any other) matched.  Reusing exactly the reads this
    /// function was already going to make -- rather than issuing separate
    /// attribute requests -- is what lets the `.noMatches` exposed-label
    /// sample cost zero extra IPC: on a traversal that ends in `.noMatches`,
    /// nothing ever matched, so this loop never short-circuits early and
    /// `sampled` ends up covering every title/description this element had.
    /// kAXValue is deliberately excluded from `sampled` even though it IS
    /// read for matching purposes: an AXValue is frequently the user's own
    /// document content (e.g. text typed into a field), and echoing it back
    /// inside an MCP error message would turn a UI-discovery hint into
    /// content disclosure. A matching kAXValue is likewise published only as
    /// the caller's query via `publishedMatchLabel`, never as the raw value.
    private static func matchLabel(on element: AXUIElement, query: String,
                                   mode: AccessibilityLabelMatchMode)
    -> (match: (attribute: String, value: String)?, sampled: [(attribute: String, value: String)]) {
        var sampled: [(attribute: String, value: String)] = []
        // Keep the order deterministic.  A single element which happens to
        // repeat a label in multiple attributes is still one candidate, with
        // its visible title preferred over its description/value.
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let value = stringAttribute(attribute, of: element) else { continue }
            if attribute != kAXValueAttribute {
                sampled.append((attribute, value))
            }
            if labelMatches(value, query: query, mode: mode) {
                return (match: (attribute, value), sampled: sampled)
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

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        elements(attribute: kAXChildrenAttribute, of: element)
    }

    // Nil-tolerant: used only by the per-node BFS traversal, where one
    // unreadable child (of any AXError, timeout included) must stay
    // non-fatal so a single hung grandchild cannot fail the whole lookup.
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

    private static func resolvedMatch(_ selected: InternalMatch,
                                      screens: [ScreenInfo],
                                      startedAt: TimeInterval,
                                      timeout: TimeInterval) throws -> AccessibilityElementMatch {
        // `selected.frame` was already read (and confirmed usable) back in
        // the BFS loop, at the moment this element's label matched -- see
        // the long comment there for why that is both cheaper (the frame
        // IPC happens once per LABEL MATCH, not again per selection) and
        // more correct (no TOCTOU gap between "this element matched" and
        // "this is the frame we drew a highlight around"). There is nothing
        // left to re-read here.
        if traversalDeadlineExceeded(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime,
                                     timeout: timeout) {
            throw AccessibilityElementResolverError.traversalTimedOut(seconds: timeout)
        }
        guard let backingFrame = backingRect(forAccessibilityFrame: selected.frame, screens: screens) else {
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
}
