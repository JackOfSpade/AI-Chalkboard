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
}

enum PresentationReadiness {
    /// Returns machine-readable failure codes rather than one lossy boolean so
    /// an MCP caller can distinguish a hidden annotation from a genuinely
    /// missing/ordered-out overlay window.
    static func failureReasons(for input: PresentationReadinessInput) -> [String] {
        var failures: [String] = []
        if !input.annotationExists { failures.append("annotation_not_found") }
        if !input.annotationIsInCurrentVisibleSet { failures.append("annotation_not_in_current_visible_set") }
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
}
