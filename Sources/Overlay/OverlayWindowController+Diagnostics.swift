import Foundation
import AppKit
import CoreGraphics

/// AppKit-only observation of the overlay's input policy.  This is an
/// attestation from Chalkboard itself, not a capability exposed through
/// `CGWindowList`; a click dispatcher must explicitly choose to trust it.
public struct OverlayInputPolicySnapshot: Codable, Equatable {
    public let screenId: String
    public let windowNumber: Int?
    public let isOnScreen: Bool
    public let hasVisibleContent: Bool
    /// Whether annotations are intentionally hidden while retained in the
    /// store. When true every process-local overlay window is ordered out, so
    /// WindowServer ownership scans do not find an AI Chalkboard window.
    public let annotationsSuspended: Bool
    public let ignoresMouseEvents: Bool
    public let sharingType: String

    public init(screenId: String, windowNumber: Int?, isOnScreen: Bool,
                hasVisibleContent: Bool, annotationsSuspended: Bool,
                ignoresMouseEvents: Bool, sharingType: String) {
        self.screenId = screenId
        self.windowNumber = windowNumber
        self.isOnScreen = isOnScreen
        self.hasVisibleContent = hasVisibleContent
        self.annotationsSuspended = annotationsSuspended
        self.ignoresMouseEvents = ignoresMouseEvents
        self.sharingType = sharingType
    }
}

extension OverlayWindowController {
    /// Samples the actual AppKit window and its independently-maintained
    /// WindowServer registration for an annotation.  Unlike
    /// `verify_annotation`, this does not synthesize an image: it establishes
    /// that the live overlay has a retained, attached, visible on-screen
    /// window at the expected level.  It still cannot prove an individual
    /// painted pixel was not occluded or filtered from somebody else's capture.
    func presentationStatus(for annotationId: String) -> PresentationStatus {
        let suspendedWithoutAnnotation = isAnnotationsSuspended
        guard let annotation = AnnotationStore.shared.get(id: annotationId),
              !annotation.hasExpired(now: Date(), uptime: ProcessInfo.processInfo.systemUptime) else {
            let input = PresentationReadinessInput(
                annotationExists: false,
                annotationIsInCurrentVisibleSet: false,
                annotationsSuspended: suspendedWithoutAnnotation,
                overlayWindowExists: false,
                contentViewIsExpectedOverlayView: false,
                viewIsAttachedToWindow: false,
                appKitWindowIsVisible: false,
                appKitFrameMatchesExpectedScreen: false,
                windowServerEntryFoundInAllWindows: false,
                windowServerEntryFoundInOnScreenList: false,
                windowServerBoundsMatchExpectedDisplay: false,
                appKitAlpha: nil,
                windowServerAlpha: nil,
                appKitLevel: nil,
                windowServerLayer: nil,
                expectedAlpha: 1,
                expectedLevel: NSWindow.Level.statusBar.rawValue
            )
            let failures = PresentationReadiness.failureReasons(for: input)
            return PresentationStatus(
                annotationId: annotationId,
                annotationExists: false,
                screenId: nil,
                annotationIsInCurrentVisibleSet: false,
                annotationsSuspended: suspendedWithoutAnnotation,
                expectedWindowShouldBeOnScreen: false,
                expectedLevel: NSWindow.Level.statusBar.rawValue,
                expectedAlpha: 1,
                expectedFrameAppKitPoints: nil,
                expectedFrameWindowServerCoordinates: nil,
                overlayWindowExists: false,
                windowNumber: nil,
                appKitWindowIsVisible: nil,
                contentViewIsExpectedOverlayView: nil,
                viewIsAttachedToWindow: nil,
                appKitAlpha: nil,
                appKitLevel: nil,
                appKitFramePoints: nil,
                windowServerEntryInAllWindows: nil,
                windowServerEntryInOnScreenList: nil,
                presentationReady: false,
                failureReasons: failures,
                note: "The annotation was not found or has expired; no live overlay window can be expected for it."
            )
        }

        return MainThread.sync {
            // Make this a deterministic post-draw check instead of racing the
            // store's intentionally asynchronous onStoreChanged repaint.
            refreshViewsNow()

            let visibleIDs = Set(currentlyVisibleAnnotations(forScreenId: annotation.screenId).map(\.id))
            let annotationIsVisible = visibleIDs.contains(annotation.id)
            let annotationsAreSuspended = annotationsSuspended
            let expectedLevel = NSWindow.Level.statusBar.rawValue
            let expectedAlpha = 1.0

            guard let index = overlayViews.firstIndex(where: { $0.screenId == annotation.screenId }),
                  index < overlayWindows.count else {
                let input = PresentationReadinessInput(
                    annotationExists: true,
                    annotationIsInCurrentVisibleSet: annotationIsVisible,
                    annotationsSuspended: annotationsAreSuspended,
                    overlayWindowExists: false,
                    contentViewIsExpectedOverlayView: false,
                    viewIsAttachedToWindow: false,
                    appKitWindowIsVisible: false,
                    appKitFrameMatchesExpectedScreen: false,
                    windowServerEntryFoundInAllWindows: false,
                    windowServerEntryFoundInOnScreenList: false,
                    windowServerBoundsMatchExpectedDisplay: false,
                    appKitAlpha: nil,
                    windowServerAlpha: nil,
                    appKitLevel: nil,
                    windowServerLayer: nil,
                    expectedAlpha: expectedAlpha,
                    expectedLevel: expectedLevel
                )
                let failures = PresentationReadiness.failureReasons(for: input)
                return PresentationStatus(
                    annotationId: annotation.id,
                    annotationExists: true,
                    screenId: annotation.screenId,
                    annotationIsInCurrentVisibleSet: annotationIsVisible,
                    annotationsSuspended: annotationsAreSuspended,
                    expectedWindowShouldBeOnScreen: annotationIsVisible && !annotationsAreSuspended,
                    expectedLevel: expectedLevel,
                    expectedAlpha: expectedAlpha,
                    expectedFrameAppKitPoints: nil,
                    expectedFrameWindowServerCoordinates: nil,
                    overlayWindowExists: false,
                    windowNumber: nil,
                    appKitWindowIsVisible: nil,
                    contentViewIsExpectedOverlayView: nil,
                    viewIsAttachedToWindow: nil,
                    appKitAlpha: nil,
                    appKitLevel: nil,
                    appKitFramePoints: nil,
                    windowServerEntryInAllWindows: nil,
                    windowServerEntryInOnScreenList: nil,
                    presentationReady: false,
                    failureReasons: failures,
                    note: "The annotation's display no longer has a retained overlay window."
                )
            }

            let window = overlayWindows[index]
            let view = overlayViews[index]
            // `displayIfNeeded` forces the same view drawing path used by the
            // live overlay before sampling registration.  It is deliberately
            // evidence of a drawable/committed view, not a claim about pixels.
            view.displayIfNeeded()
            window.displayIfNeeded()

            let allWindows = cgWindowEntries(options: [.optionAll, .excludeDesktopElements])
            let onScreenWindows = cgWindowEntries(options: [.optionOnScreenOnly, .excludeDesktopElements])
            let processID = ProcessInfo.processInfo.processIdentifier
            let windowNumber = window.windowNumber
            let allEntry = matchingWindowEntry(in: allWindows, windowNumber: windowNumber, processID: processID)
            let onScreenEntry = matchingWindowEntry(in: onScreenWindows, windowNumber: windowNumber, processID: processID)

            // Resolve the *target* screen from the annotation/view id, not
            // `window.screen`: if the window drifted onto a different monitor,
            // using its current screen would make a wrong-display window look
            // self-consistent and incorrectly ready.
            let targetScreen = NSScreen.screens.enumerated().compactMap { index, screen -> NSScreen? in
                getScreenId(screen: screen, index: index) == annotation.screenId ? screen : nil
            }.first
            let expectedFrame = targetScreen.map { presentationRect($0.frame) }
            let expectedWindowServerFrame = targetScreen.flatMap { windowServerDisplayBounds(for: $0) }
            let contentViewMatches = window.contentView === view
            // A window content view is normally parented by AppKit's private
            // frame view, so `superview == nil` would incorrectly report every
            // healthy overlay as detached. Identity + `view.window` are the
            // stable public attachment checks.
            let viewAttached = contentViewMatches && view.window === window
            let appKitFrameMatches = targetScreen.map { window.frame == $0.frame } ?? false
            let input = PresentationReadinessInput(
                annotationExists: true,
                annotationIsInCurrentVisibleSet: annotationIsVisible,
                annotationsSuspended: annotationsAreSuspended,
                overlayWindowExists: true,
                contentViewIsExpectedOverlayView: contentViewMatches,
                viewIsAttachedToWindow: viewAttached,
                appKitWindowIsVisible: window.isVisible,
                appKitFrameMatchesExpectedScreen: appKitFrameMatches,
                windowServerEntryFoundInAllWindows: allEntry != nil,
                windowServerEntryFoundInOnScreenList: onScreenEntry != nil,
                windowServerBoundsMatchExpectedDisplay: WindowServerBoundsMatcher.matchesExpectedDisplay(
                    actual: allEntry?.bounds,
                    expected: expectedWindowServerFrame
                ),
                appKitAlpha: Double(window.alphaValue),
                windowServerAlpha: allEntry?.alpha,
                appKitLevel: window.level.rawValue,
                windowServerLayer: allEntry?.layer,
                expectedAlpha: expectedAlpha,
                expectedLevel: expectedLevel
            )
            let failures = PresentationReadiness.failureReasons(for: input)
            return PresentationStatus(
                annotationId: annotation.id,
                annotationExists: true,
                screenId: annotation.screenId,
                annotationIsInCurrentVisibleSet: annotationIsVisible,
                annotationsSuspended: annotationsAreSuspended,
                expectedWindowShouldBeOnScreen: annotationIsVisible && !annotationsAreSuspended,
                expectedLevel: expectedLevel,
                expectedAlpha: expectedAlpha,
                expectedFrameAppKitPoints: expectedFrame,
                expectedFrameWindowServerCoordinates: expectedWindowServerFrame,
                overlayWindowExists: true,
                windowNumber: windowNumber,
                appKitWindowIsVisible: window.isVisible,
                contentViewIsExpectedOverlayView: contentViewMatches,
                viewIsAttachedToWindow: viewAttached,
                appKitAlpha: Double(window.alphaValue),
                appKitLevel: window.level.rawValue,
                appKitFramePoints: presentationRect(window.frame),
                windowServerEntryInAllWindows: allEntry,
                windowServerEntryInOnScreenList: onScreenEntry,
                presentationReady: failures.isEmpty,
                failureReasons: failures,
                note: annotationsAreSuspended
                    ? "Annotations are suspended: their store entries are retained, but every AI Chalkboard overlay window in this process is intentionally ordered out. Call resume_annotations before expecting presentationReady."
                    : "presentationReady is WindowServer/AppKit registration and drawable-state evidence, including a bounded WindowServer-bounds check against the target display. It is not proof of unoccluded pixels or inclusion in an independent capture pipeline."
            )
        }
    }

    private func cgWindowEntries(options: CGWindowListOption) -> [PresentationWindowServerEntry] {
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.map { dictionary in
            // CGWindow key constants bridge to their documented String values;
            // normalize them here so the pure decoder does not depend on Quartz.
            var normalized: [String: Any] = [:]
            for (key, value) in dictionary {
                normalized[key] = value
            }
            return PresentationWindowServerEntry(dictionary: normalized)
        }
    }

    private func matchingWindowEntry(in entries: [PresentationWindowServerEntry], windowNumber: Int, processID: Int32) -> PresentationWindowServerEntry? {
        entries.first { entry in
            entry.windowNumber == windowNumber && entry.ownerPID == Int(processID)
        }
    }

    private func presentationRect(_ rect: NSRect) -> PresentationRect {
        PresentationRect(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    /// `CGDisplayBounds` is expressed in the same global WindowServer
    /// coordinate system as `kCGWindowBounds`, unlike `NSScreen.frame` which
    /// is AppKit points with a different vertical-axis convention.
    private func windowServerDisplayBounds(for screen: NSScreen) -> PresentationRect? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        return PresentationRect(
            x: Double(bounds.origin.x),
            y: Double(bounds.origin.y),
            width: Double(bounds.width),
            height: Double(bounds.height)
        )
    }

    /// A machine-readable description of the live overlay windows' input
    /// behavior. `NSWindow.ignoresMouseEvents` is not represented in public
    /// `CGWindowList` metadata, so a computer-use implementation that wants to
    /// permit click-through annotations needs an explicit integration point
    /// such as this one rather than inferring ownership from window presence.
    public func overlayInputPolicySnapshot() -> [OverlayInputPolicySnapshot] {
        MainThread.sync {
            let annotationsAreSuspended = annotationsSuspended
            return zip(overlayWindows, overlayViews).map { window, view in
                OverlayInputPolicySnapshot(
                    screenId: view.screenId,
                    windowNumber: window.windowNumber > 0 ? window.windowNumber : nil,
                    isOnScreen: window.isVisible,
                    hasVisibleContent: !currentlyVisibleAnnotations(forScreenId: view.screenId).isEmpty,
                    annotationsSuspended: annotationsAreSuspended,
                    ignoresMouseEvents: window.ignoresMouseEvents,
                    sharingType: overlaySharingTypeName(window.sharingType)
                )
            }
        }
    }

    private func overlaySharingTypeName(_ sharingType: NSWindow.SharingType) -> String {
        switch sharingType {
        case .none: return "none"
        case .readOnly: return "readOnly"
        case .readWrite: return "readWrite"
        @unknown default: return "unknown"
        }
    }
}
