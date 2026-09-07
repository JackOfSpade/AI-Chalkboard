import Foundation

/// Codable geometry used by the presentation diagnostic.  WindowServer reports
/// its bounds in its own global screen coordinate space, so this deliberately
/// does not pretend that these values are backing-pixel annotation coordinates.
struct PresentationRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// The small, platform-independent input to the readiness decision.  Keeping
/// the decision separate from AppKit/CGWindowList reads makes every failure
/// mode testable without attempting to create WindowServer windows in XCTest.
struct PresentationReadinessInput: Equatable {
    let annotationExists: Bool
    let annotationIsInCurrentVisibleSet: Bool
    /// The annotation can still be in the current app/capture-visible set
    /// while presentation is deliberately suppressed. This is kept separate
    /// so diagnostics can distinguish a retained suspended drawing from one
    /// that is filtered by app linkage or missing entirely.
    let annotationsSuspended: Bool
    let overlayWindowExists: Bool
    let contentViewIsExpectedOverlayView: Bool
    let viewIsAttachedToWindow: Bool
    let appKitWindowIsVisible: Bool
    let appKitFrameMatchesExpectedScreen: Bool
    let windowServerEntryFoundInAllWindows: Bool
    let windowServerEntryFoundInOnScreenList: Bool
    /// `CGWindowList` and `CGDisplayBounds` use the same WindowServer global
    /// coordinate space.  This must be checked independently of the AppKit
    /// frame: a matching window number alone does not prove the window still
    /// covers the display that owns the annotation.
    let windowServerBoundsMatchExpectedDisplay: Bool
    let appKitAlpha: Double?
    let windowServerAlpha: Double?
    let appKitLevel: Int?
    let windowServerLayer: Int?
    let expectedAlpha: Double
    let expectedLevel: Int
    /// The anchor tracker's last known state for this annotation, or `nil`
    /// for an unanchored one. Read here -- rather than re-derived from
    /// `annotationIsInCurrentVisibleSet` -- because `.hidden`/`.lost` is the
    /// ACTIONABLE reason an anchored annotation dropped out of the visible
    /// set (see `failureReasons(for:)`'s "do not emit a second, misleading
    /// geometry failure" layering, just like `windowserver_bounds_mismatch`
    /// already does for a missing WindowServer entry): a caller told
    /// `anchor_window_hidden` knows to wait for the target window to
    /// reappear, while a bare `annotation_not_in_current_visible_set` gives
    /// no hint that an anchor -- not app linkage, not suspension -- is why.
    let anchorState: AnchorTrackingState?

    init(
        annotationExists: Bool,
        annotationIsInCurrentVisibleSet: Bool,
        annotationsSuspended: Bool,
        overlayWindowExists: Bool,
        contentViewIsExpectedOverlayView: Bool,
        viewIsAttachedToWindow: Bool,
        appKitWindowIsVisible: Bool,
        appKitFrameMatchesExpectedScreen: Bool,
        windowServerEntryFoundInAllWindows: Bool,
        windowServerEntryFoundInOnScreenList: Bool,
        windowServerBoundsMatchExpectedDisplay: Bool,
        appKitAlpha: Double?,
        windowServerAlpha: Double?,
        appKitLevel: Int?,
        windowServerLayer: Int?,
        expectedAlpha: Double,
        expectedLevel: Int,
        anchorState: AnchorTrackingState? = nil
    ) {
        self.annotationExists = annotationExists
        self.annotationIsInCurrentVisibleSet = annotationIsInCurrentVisibleSet
        self.annotationsSuspended = annotationsSuspended
        self.overlayWindowExists = overlayWindowExists
        self.contentViewIsExpectedOverlayView = contentViewIsExpectedOverlayView
        self.viewIsAttachedToWindow = viewIsAttachedToWindow
        self.appKitWindowIsVisible = appKitWindowIsVisible
        self.appKitFrameMatchesExpectedScreen = appKitFrameMatchesExpectedScreen
        self.windowServerEntryFoundInAllWindows = windowServerEntryFoundInAllWindows
        self.windowServerEntryFoundInOnScreenList = windowServerEntryFoundInOnScreenList
        self.windowServerBoundsMatchExpectedDisplay = windowServerBoundsMatchExpectedDisplay
        self.appKitAlpha = appKitAlpha
        self.windowServerAlpha = windowServerAlpha
        self.appKitLevel = appKitLevel
        self.windowServerLayer = windowServerLayer
        self.expectedAlpha = expectedAlpha
        self.expectedLevel = expectedLevel
        self.anchorState = anchorState
    }
}

enum PresentationReadiness {
    /// Returns machine-readable failure codes rather than one lossy boolean so
    /// an MCP caller can distinguish a hidden annotation from a genuinely
    /// missing/ordered-out overlay window.
    static func failureReasons(for input: PresentationReadinessInput) -> [String] {
        // Suspension deliberately orders the window out and makes the
        // renderer-visible set empty while preserving the annotation itself.
        // Reporting the resulting AppKit/WindowServer absences as ordinary
        // presentation faults is noisy and misleading: the actionable state
        // is simply that the caller must resume before asking for readiness.
        // Keep a genuine missing annotation distinguishable, since suspension
        // cannot explain its absence.
        if input.annotationsSuspended {
            return input.annotationExists
                ? ["annotations_suspended"]
                : ["annotation_not_found", "annotations_suspended"]
        }

        var failures: [String] = []
        if !input.annotationExists { failures.append("annotation_not_found") }
        if !input.annotationIsInCurrentVisibleSet {
            failures.append(visibilityAbsenceReason(anchorState: input.anchorState))
        }
        if !input.overlayWindowExists { failures.append("overlay_window_missing") }
        if !input.contentViewIsExpectedOverlayView { failures.append("overlay_content_view_mismatch") }
        if !input.viewIsAttachedToWindow { failures.append("overlay_view_detached") }
        if !input.appKitWindowIsVisible { failures.append("appkit_window_not_visible") }
        if !input.appKitFrameMatchesExpectedScreen { failures.append("appkit_window_frame_mismatch") }
        if !input.windowServerEntryFoundInAllWindows { failures.append("windowserver_entry_missing") }
        if !input.windowServerEntryFoundInOnScreenList { failures.append("windowserver_window_not_on_screen") }
        // Do not emit a second, misleading geometry failure when the entry is
        // absent altogether.  Once an entry exists, however, bounds are
        // required evidence; an entry without usable bounds is not enough to
        // claim that this full-display overlay targets the right monitor.
        if input.windowServerEntryFoundInAllWindows && !input.windowServerBoundsMatchExpectedDisplay {
            failures.append("windowserver_bounds_mismatch")
        }
        if input.appKitAlpha == nil || input.appKitAlpha! < input.expectedAlpha { failures.append("appkit_window_alpha_below_expected") }
        if input.windowServerAlpha == nil || input.windowServerAlpha! < input.expectedAlpha { failures.append("windowserver_alpha_below_expected") }
        if input.appKitLevel != input.expectedLevel { failures.append("appkit_window_level_mismatch") }
        if input.windowServerLayer != input.expectedLevel { failures.append("windowserver_layer_mismatch") }
        return failures
    }

    /// Chooses the failure code for an annotation missing from the current
    /// visible set. `anchor_window_hidden`/`anchor_window_lost` are emitted
    /// INSTEAD OF the bare `annotation_not_in_current_visible_set` whenever an
    /// anchor's tracked window explains the absence -- the SAME "do not emit
    /// a second, misleading failure" layering `failureReasons(for:)` already
    /// applies to `windowserver_bounds_mismatch` above: the anchor reason is
    /// the ACTIONABLE one (the target window is minimised/hidden/gone), and
    /// the visible-set absence is merely its consequence. A `nil`/`.tracking`
    /// anchor state falls back to the original, unanchored-annotation code.
    ///
    /// Pulled out as its own pure function -- rather than inlined at
    /// `failureReasons(for:)`'s one call site -- so the Windows branch of
    /// `OverlayWindowController+Diagnostics.swift` (which builds its failure
    /// list by hand instead of going through `PresentationReadinessInput`)
    /// can share the exact same decision instead of restating it.
    static func visibilityAbsenceReason(anchorState: AnchorTrackingState?) -> String {
        switch anchorState {
        case .some(.hidden): return "anchor_window_hidden"
        case .some(.lost): return "anchor_window_lost"
        case .some(.tracking), .none: return "annotation_not_in_current_visible_set"
        }
    }

    /// Fixed, factual prose distinguishing what `presentationReady` DOES
    /// prove (this window's own registration/drawable state) from what it
    /// says NOTHING about (whether an independent capture pipeline -- another
    /// application's screenshot tool -- composites these annotations into its
    /// own output). This is the user-facing half of the fix for the reported
    /// bug in CAPTURE_GAP.md: `verify_presentation` used to report
    /// `presentationReady: true` while saying nothing about capture
    /// exclusion, which is exactly how an agent burned an afternoon
    /// confidently annotating a window whose pixels a DIFFERENT capture tool
    /// was never going to see.
    ///
    /// Conditioned only on whether exclusion is CURRENTLY in force
    /// (`excludesFromCapture`, from the same `CaptureExclusionPolicy.Decision`
    /// `captureExclusion` is built from -- see `PresentationCaptureExclusionSummary`)
    /// so the two fields cannot describe two different states.
    static func captureHonestyNote(excludesFromCapture: Bool) -> String {
        excludesFromCapture
            ? "presentationReady describes this window's own registration/drawable state and says NOTHING about what an independent capture pipeline composites. Exclusion is currently in force (see captureExclusion): another application's screenshot will NOT contain these annotations even while presentationReady is true. Call set_capture_visible(true) to lift it, or use get_annotation_bounds to answer a placement question without needing the overlay in anyone's pixels."
            : "presentationReady describes this window's own registration/drawable state and says NOTHING about what an independent capture pipeline composites. Exclusion is not currently in force (see captureExclusion), but any capture path may still filter this window on its own criteria -- presentationReady is not proof of inclusion in one. get_annotation_bounds answers a placement question without needing the overlay in anyone's pixels."
    }
}

/// `verify_presentation`'s capture-honesty block: the SAME capture-exclusion
/// decision the app already computes for `get_screens`/`get_overlay_state`/
/// `set_capture_visible` (`OverlayWindowController.captureExclusionDecision`,
/// backed by `CaptureExclusionPolicy`), restated here in the identical shape
/// those tools already emit under their own `captureExclusion` key so a
/// caller reading several tools' output sees one consistent field, not a
/// second independently-shaped summary of the same fact.
public struct PresentationCaptureExclusionSummary: Codable, Equatable {
    public let excludesFromCapture: Bool
    public let reasonCode: String
    public let signals: [String]
    public let environmentVariable: String
    public let note: String

    public init(excludesFromCapture: Bool, reasonCode: String, signals: [String], environmentVariable: String, note: String) {
        self.excludesFromCapture = excludesFromCapture
        self.reasonCode = reasonCode
        self.signals = signals
        self.environmentVariable = environmentVariable
        self.note = note
    }

    /// Restates a live `CaptureExclusionPolicy.Decision` -- the app's ONE
    /// computation of this decision, already used by `get_screens`/
    /// `get_overlay_state`/`set_capture_visible` -- in this wire shape.
    /// `OverlayWindowController+Diagnostics.swift`'s `presentationStatus(for:)`
    /// is the one caller, and it passes `OverlayWindowController.shared
    /// .captureExclusionDecision` straight through rather than recomputing
    /// anything.
    public init(decision: CaptureExclusionPolicy.Decision) {
        self.excludesFromCapture = decision.excludesFromCapture
        self.reasonCode = decision.reasonCode
        self.signals = decision.signals
        self.environmentVariable = CaptureExclusionPolicy.environmentVariableName
        self.note = decision.explanation
    }
}

/// Compares a WindowServer window rectangle to the display rectangle it is
/// meant to cover.  Full-screen transparent windows can be reported with a
/// small symmetric inset by WindowServer on some macOS/display combinations,
/// so exact equality would turn healthy overlays into false failures.  The
/// tolerance is deliberately bounded: it accepts a small clipped edge but
/// rejects a window shifted to another display or materially shrunk.
enum WindowServerBoundsMatcher {
    static let coordinateTolerance: Double = 2
    static let maximumPerEdgeInset: Double = 64

    static func matchesExpectedDisplay(
        actual: PresentationRect?,
        expected: PresentationRect?
    ) -> Bool {
        guard let actual, let expected,
              isUsable(actual), isUsable(expected)
        else { return false }

        let leftInset = actual.x - expected.x
        let topInset = actual.y - expected.y
        let rightInset = (expected.x + expected.width) - (actual.x + actual.width)
        let bottomInset = (expected.y + expected.height) - (actual.y + actual.height)

        return [leftInset, topInset, rightInset, bottomInset].allSatisfy {
            $0 >= -coordinateTolerance && $0 <= maximumPerEdgeInset
        }
    }

    private static func isUsable(_ rect: PresentationRect) -> Bool {
        [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0
            && rect.height > 0
    }
}

/// A normalized copy of just the WindowServer fields relevant to overlay
/// presentation.  The initializer deliberately accepts an untyped dictionary
/// so CGWindowList plumbing stays at the AppKit boundary and this type remains
/// directly unit-testable.
struct PresentationWindowServerEntry: Codable, Equatable {
    let windowNumber: Int?
    let ownerPID: Int?
    let ownerName: String?
    let layer: Int?
    let alpha: Double?
    let sharingState: Int?
    let isOnScreen: Bool?
    let bounds: PresentationRect?

    init(dictionary: [String: Any]) {
        windowNumber = Self.int(dictionary["kCGWindowNumber"])
        ownerPID = Self.int(dictionary["kCGWindowOwnerPID"])
        ownerName = dictionary["kCGWindowOwnerName"] as? String
        layer = Self.int(dictionary["kCGWindowLayer"])
        alpha = Self.double(dictionary["kCGWindowAlpha"])
        sharingState = Self.int(dictionary["kCGWindowSharingState"])
        isOnScreen = Self.bool(dictionary["kCGWindowIsOnscreen"])
        bounds = Self.rect(dictionary["kCGWindowBounds"])
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func rect(_ value: Any?) -> PresentationRect? {
        guard let dictionary = value as? [String: Any],
              let x = double(dictionary["X"] ?? dictionary["x"]),
              let y = double(dictionary["Y"] ?? dictionary["y"]),
              let width = double(dictionary["Width"] ?? dictionary["width"]),
              let height = double(dictionary["Height"] ?? dictionary["height"])
        else { return nil }
        return PresentationRect(x: x, y: y, width: width, height: height)
    }
}

/// Actual registration/drawable-state evidence for a requested annotation.
/// This proves that the retained AppKit window is attached, ordered on screen,
/// and present in WindowServer's own list.  It cannot prove individual pixels
/// were unobscured or included by an independent capture tool.
struct PresentationStatus: Codable, Equatable {
    let annotationId: String
    let annotationExists: Bool
    let screenId: String?
    let annotationIsInCurrentVisibleSet: Bool
    let annotationsSuspended: Bool
    let expectedWindowShouldBeOnScreen: Bool
    let expectedLevel: Int
    let expectedAlpha: Double
    let expectedFrameAppKitPoints: PresentationRect?
    let expectedFrameWindowServerCoordinates: PresentationRect?
    let overlayWindowExists: Bool
    let windowNumber: Int?
    let appKitWindowIsVisible: Bool?
    let contentViewIsExpectedOverlayView: Bool?
    let viewIsAttachedToWindow: Bool?
    let appKitAlpha: Double?
    let appKitLevel: Int?
    let appKitFramePoints: PresentationRect?
    let windowServerEntryInAllWindows: PresentationWindowServerEntry?
    let windowServerEntryInOnScreenList: PresentationWindowServerEntry?
    let presentationReady: Bool
    let failureReasons: [String]
    let note: String
    /// The SAME capture-exclusion decision `get_screens`/`get_overlay_state`/
    /// `set_capture_visible` already report -- restated here, not
    /// recomputed, via `PresentationCaptureExclusionSummary.init(decision:)` --
    /// so a caller reading only `verify_presentation` still learns whether an
    /// independent capture pipeline (another application's screenshot tool)
    /// would composite these annotations at all. Always present: this
    /// decision is a live, global process state, not something that depends
    /// on whether `annotationId` resolved.
    let captureExclusion: PresentationCaptureExclusionSummary
    /// See `PresentationReadiness.captureHonestyNote(excludesFromCapture:)`.
    /// Spelled out as its own field, separate from `note` above (which is
    /// about THIS window's registration evidence), because the two say
    /// different things: `note` explains what evidence backs
    /// `presentationReady`; `captureHonestyNote` explains what
    /// `presentationReady` does NOT tell you about a capture pipeline it
    /// never consults.
    let captureHonestyNote: String
}
