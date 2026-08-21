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

/// A compact candidate description returned in an ambiguity error.  It gives
/// an MCP caller enough information to add a role or occurrence without
/// leaking an entire application's accessibility tree.
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

    public init(label: String, role: String? = nil,
                matchMode: AccessibilityLabelMatchMode = .exact,
                occurrence: Int? = nil, maxNodes: Int = AccessibilityElementResolver.defaultMaxNodes) {
        self.label = label
        self.role = role
        self.matchMode = matchMode
        self.occurrence = occurrence
        self.maxNodes = maxNodes
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
    case traversalLimitReached(Int)
    case traversalTimedOut(seconds: Double)
    case noMatches(label: String, role: String?)
    case ambiguous(matches: [AccessibilityElementCandidate])
    case occurrenceOutOfRange(requested: Int, available: Int)
    case selectedElementHasNoFrame
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
        case .traversalLimitReached(let limit):
            return "Stopped after inspecting \(limit) accessibility elements. Refine the app, label, or role and retry rather than accepting an incomplete tree."
        case .traversalTimedOut(let seconds):
            return "Stopped accessibility lookup after \(String(format: "%.1f", seconds)) seconds. Refine the app, label, or role and retry rather than accepting an incomplete tree."
        case .noMatches(let label, let role):
            let roleNote = role.map { " with role '\($0)'" } ?? ""
            return "No accessibility element matched label '\(label)'\(roleNote). The UI may not expose that control to macOS Accessibility."
        case .ambiguous(let matches):
            let preview = matches.prefix(8).map { "'\($0.matchedLabel)' [\($0.role ?? "unknown role")] via \($0.matchedAttribute)" }.joined(separator: ", ")
            let more = matches.count > 8 ? " (and \(matches.count - 8) more)" : ""
            return "Accessibility lookup is ambiguous across \(matches.count) elements: \(preview)\(more). Add a role or supply a one-based occurrence."
        case .occurrenceOutOfRange(let requested, let available):
            return "Requested accessibility occurrence \(requested), but only \(available) matching element(s) were found. Occurrence is one-based."
        case .selectedElementHasNoFrame:
            return "The matched accessibility element has no usable screen frame, so it cannot be highlighted."
        case .frameCannotBeMapped:
            return "The matched accessibility frame does not fit wholly on one connected display, so safe screen-local backing-pixel placement is impossible."
        }
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
    static let traversalTimeoutSeconds: TimeInterval = 2.0

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

        let initial = initialElements(
            windows: elements(attribute: kAXWindowsAttribute, of: application),
            children: children(of: application)
        )
        if traversalDeadlineExceeded(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime) {
            throw AccessibilityElementResolverError.traversalTimedOut(seconds: traversalTimeoutSeconds)
        }
        guard let initial, !initial.isEmpty else {
            throw AccessibilityElementResolverError.applicationUnavailable
        }

        var queue: [AXUIElement] = []
        var nextIndex = 0
        var inspected = 0
        var matches: [InternalMatch] = []
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
            if traversalDeadlineExceeded(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime) {
                throw AccessibilityElementResolverError.traversalTimedOut(seconds: traversalTimeoutSeconds)
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
            if normalized.role == nil || normalized.role == role,
               let labelMatch = matchLabel(on: element, query: normalized.label, mode: normalized.matchMode) {
                let match = InternalMatch(
                    element: element,
                    candidate: AccessibilityElementCandidate(
                        matchedAttribute: labelMatch.attribute,
                        matchedLabel: labelMatch.value,
                        role: role
                    )
                )
                matches.append(match)
                // An explicit occurrence has deterministic BFS semantics.
                // Later nodes cannot alter the identity of the Nth match, so
                // avoid needless child IPC (and a much larger traversal) once
                // that requested match is found.
                if let occurrence = normalized.occurrence, matches.count == occurrence {
                    return try resolvedMatch(match, screens: screens, startedAt: startedAt)
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
            throw AccessibilityElementResolverError.noMatches(label: normalized.label, role: normalized.role)
        }

        let selected: InternalMatch
        if let occurrence = normalized.occurrence {
            guard occurrence <= matches.count else {
                throw AccessibilityElementResolverError.occurrenceOutOfRange(requested: occurrence, available: matches.count)
            }
            selected = matches[occurrence - 1]
        } else {
            guard matches.count == 1 else {
                throw AccessibilityElementResolverError.ambiguous(matches: matches.map(\.candidate))
            }
            selected = matches[0]
        }

        return try resolvedMatch(selected, screens: screens, startedAt: startedAt)
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
        guard isUsable(frame),
              let anchor = (screens.first(where: { $0.appKitFrame.x == 0 && $0.appKitFrame.y == 0 })
                  ?? screens.first)
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

    /// Pure monotonic-clock boundary helper.  Keeping it independent from AX
    /// allows the deadline policy to be tested without Accessibility consent.
    static func traversalDeadlineExceeded(startedAt: TimeInterval, now: TimeInterval,
                                          timeout: TimeInterval = traversalTimeoutSeconds) -> Bool {
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

    /// Computes how many children can enter the BFS queue without retaining
    /// more candidates than the request's inspection budget can consume.
    static func boundedAppendCount(candidateCount: Int, queuedUninspected: Int,
                                   inspected: Int, maxNodes: Int) -> Int {
        let remaining = max(0, maxNodes - inspected - queuedUninspected)
        return min(max(0, candidateCount), remaining)
    }

    private struct InternalMatch {
        let element: AXUIElement
        let candidate: AccessibilityElementCandidate
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
        return AccessibilityElementRequest(label: label, role: role, matchMode: request.matchMode,
                                           occurrence: request.occurrence, maxNodes: request.maxNodes)
    }

    private static func matchLabel(on element: AXUIElement, query: String,
                                   mode: AccessibilityLabelMatchMode) -> (attribute: String, value: String)? {
        // Keep the order deterministic.  A single element which happens to
        // repeat a label in multiple attributes is still one candidate, with
        // its visible title preferred over its description/value.
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let value = stringAttribute(attribute, of: element), labelMatches(value, query: query, mode: mode) else {
                continue
            }
            return (attribute, value)
        }
        return nil
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        elements(attribute: kAXChildrenAttribute, of: element)
    }

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
                                      startedAt: TimeInterval) throws -> AccessibilityElementMatch {
        // The selected element may have been retained while resolving a
        // different occurrence.  Reapply the timeout immediately before the
        // frame IPC rather than assuming an earlier configuration survives.
        configureMessagingTimeout(selected.element)
        guard let frame = frame(of: selected.element) else {
            throw AccessibilityElementResolverError.selectedElementHasNoFrame
        }
        if traversalDeadlineExceeded(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime) {
            throw AccessibilityElementResolverError.traversalTimedOut(seconds: traversalTimeoutSeconds)
        }
        guard let backingFrame = backingRect(forAccessibilityFrame: frame, screens: screens) else {
            throw AccessibilityElementResolverError.frameCannotBeMapped
        }
        return AccessibilityElementMatch(
            matchedAttribute: selected.candidate.matchedAttribute,
            matchedLabel: selected.candidate.matchedLabel,
            role: selected.candidate.role,
            accessibilityFrame: frame,
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
