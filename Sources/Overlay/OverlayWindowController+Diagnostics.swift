import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#endif

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

#if os(macOS)
extension OverlayWindowController {
    /// Samples the actual AppKit window and its independently-maintained
    /// WindowServer registration for an annotation.  Unlike
    /// `verify_annotation`, this does not synthesize an image: it establishes
    /// that the live overlay has a retained, attached, visible on-screen
    /// window at the expected level.  It still cannot prove an individual
    /// painted pixel was not occluded or filtered from somebody else's capture.
    func presentationStatus(for annotationId: String) -> PresentationStatus {
        let suspendedWithoutAnnotation = isAnnotationsSuspended
        // A stored annotation is unconditionally live. This used to also
        // screen out an annotation whose duration had elapsed but whose
        // removal had not yet run, because a `get` could hand back something
        // already logically gone. Annotations no longer have a lifetime at
        // all -- they persist until `clear`/`remove` deletes them -- so
        // presence in the store IS liveness, and there is no longer any
        // window in which those two can disagree.
        guard let annotation = AnnotationStore.shared.get(id: annotationId) else {
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
                note: "The annotation was not found; it was cleared, or the id is wrong. No live overlay window can be expected for it."
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

            let processID = ProcessInfo.processInfo.processIdentifier
            let windowNumber = window.windowNumber
            let allEntry = matchingWindowEntry(
                options: [.optionAll, .excludeDesktopElements],
                windowNumber: windowNumber,
                processID: processID
            )
            let onScreenEntry = matchingWindowEntry(
                options: [.optionOnScreenOnly, .excludeDesktopElements],
                windowNumber: windowNumber,
                processID: processID
            )

            // Resolve the *target* screen from the annotation/view id, not
            // `window.screen`: if the window drifted onto a different monitor,
            // using its current screen would make a wrong-display window look
            // self-consistent and incorrectly ready.
            //
            // Both rectangles come from the same `buildScreenInfos()` that
            // `get_screens` reports, so a caller comparing this diagnostic
            // against `get_screens` output cannot be reading two independently
            // derived versions of the same monitor's geometry.
            let targetInfo = buildScreenInfos().first(where: { $0.id == annotation.screenId })
            let expectedFrame = targetInfo.map { presentationRect($0.appKitFrame) }
            let expectedWindowServerFrame = targetInfo.flatMap { info -> PresentationRect? in
                // `ScreenInfo.windowServerFrame` substitutes a synthetic
                // 0,0-origin pixel rect when AppKit reports no display id, and
                // that synthetic value is not a WindowServer claim -- only a
                // real `CGDirectDisplayID` makes `CGDisplayBounds` comparable
                // to `kCGWindowBounds`. The finite/positive guard stays as it
                // was: an unusable rectangle must read as "no expectation"
                // rather than as a bounds mismatch.
                guard info.displayID != nil else { return nil }
                let bounds = info.windowServerFrame
                guard bounds.width.isFinite, bounds.height.isFinite,
                      bounds.width > 0, bounds.height > 0 else {
                    return nil
                }
                return presentationRect(bounds)
            }
            let contentViewMatches = window.contentView === view
            // A window content view is normally parented by AppKit's private
            // frame view, so `superview == nil` would incorrectly report every
            // healthy overlay as detached. Identity + `view.window` are the
            // stable public attachment checks.
            let viewAttached = contentViewMatches && view.window === window
            let appKitFrameMatches = targetInfo.map {
                presentationRect(window.frame) == presentationRect($0.appKitFrame)
            } ?? false
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

    /// Finds this process's overlay window in one WindowServer list.
    ///
    /// `CGWindowListCopyWindowInfo` returns EVERY window on the desktop, and
    /// `verify_presentation` keeps exactly one entry out of each list it
    /// samples.  Decoding lazily and stopping at the first match means the
    /// decoder touches only the dictionaries up to the overlay's own entry
    /// instead of the whole system window list, twice, per call.
    private func matchingWindowEntry(options: CGWindowListOption, windowNumber: Int, processID: Int32) -> PresentationWindowServerEntry? {
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.lazy
            .map(PresentationWindowServerEntry.init(dictionary:))
            .first { $0.windowNumber == windowNumber && $0.ownerPID == Int(processID) }
    }

    private func presentationRect(_ rect: NSRect) -> PresentationRect {
        PresentationRect(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    /// The same wire shape, restated from a `ScreenInfo` rectangle.  Which
    /// coordinate space it describes is the caller's choice: `ScreenInfo`
    /// carries the AppKit point frame and the WindowServer frame separately
    /// precisely so neither is inferred from the other here.
    private func presentationRect(_ rect: ScreenCoordinateRect) -> PresentationRect {
        PresentationRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
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
#elseif os(Windows)
import CChalkboardWin

extension OverlayWindowController {
    /// Windows twin of the macOS `presentationStatus(for:)` above -- SAME
    /// return type (`PresentationStatus`, shared verbatim with macOS; MCP
    /// tool code calls this method and encodes its result with no
    /// per-platform branch of its own) and the same intent, but with a
    /// materially WEAKER evidentiary basis. Read this before trusting a
    /// `true` `presentationReady` from this branch the way you would a
    /// macOS one:
    ///
    /// On macOS, `presentationReady` is a DUAL-WITNESS proof: AppKit's own
    /// window state cross-checked against `CGWindowListCopyWindowInfo`, an
    /// INDEPENDENTLY maintained WindowServer ledger that this process does
    /// not control and cannot spoof from its own side. Windows has NO
    /// equivalent independent second source for an ordinary application
    /// window -- `EnumWindows`/`IsWindowVisible`/`GetWindowRect` all read
    /// the same user32 window-manager state this process itself just set,
    /// which is a materially weaker guarantee (it can confirm this
    /// process's OWN request was applied, but proves nothing an
    /// adversarial or merely-buggy caller couldn't also have faked by
    /// reading its own state back). The one exception folded in below is
    /// `DwmGetWindowAttribute(DWMWA_CLOAKED)`: DWM (the compositor) is a
    /// genuinely separate subsystem from user32, so its cloak bit is real,
    /// independent evidence -- just much narrower evidence than
    /// `CGWindowList` provides (cloaked-or-not only, no bounds/alpha/
    /// z-order cross-check).
    ///
    /// This method never reports the confidence the macOS branch does:
    /// `windowServerEntryInAllWindows`/`windowServerEntryInOnScreenList` are
    /// always `nil` here (there is no such independent entry to report,
    /// and fabricating one would be worse than admitting its absence), and
    /// every result's `note` says so explicitly.
    func presentationStatus(for annotationId: String) -> PresentationStatus {
        let suspendedWithoutAnnotation = isAnnotationsSuspended
        guard let annotation = AnnotationStore.shared.get(id: annotationId) else {
            return PresentationStatus(
                annotationId: annotationId,
                annotationExists: false,
                screenId: nil,
                annotationIsInCurrentVisibleSet: false,
                annotationsSuspended: suspendedWithoutAnnotation,
                expectedWindowShouldBeOnScreen: false,
                // Windows has no numeric window-level concept matching
                // macOS's `NSWindow.Level` (every overlay window here is
                // simply `WS_EX_TOPMOST`) -- `0` is a neutral placeholder,
                // not a measured or meaningful value, and `appKitLevel`
                // below is always `nil` for the same reason.
                expectedLevel: 0,
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
                failureReasons: suspendedWithoutAnnotation
                    ? ["annotation_not_found", "annotations_suspended"]
                    : ["annotation_not_found"],
                note: "The annotation was not found; it was cleared, or the id is wrong. No live overlay window can be expected for it."
            )
        }

        return WindowsUIThread.shared.sync {
            // Same reasoning as the macOS branch: make this a deterministic
            // post-draw check instead of racing the store's asynchronous
            // `onStoreChanged` repaint.
            refreshViewsNow()

            let visibleIDs = Set(currentlyVisibleAnnotations(forScreenId: annotation.screenId).map(\.id))
            let annotationIsVisible = visibleIDs.contains(annotation.id)
            let annotationsAreSuspended = annotationsSuspended
            let expectedAlpha = 1.0

            // Both rectangles come from the same `buildScreenInfos()` that
            // `get_screens` reports -- same reasoning as the macOS branch's
            // identical comment.
            let targetInfo = buildScreenInfos().first(where: { $0.id == annotation.screenId })
            let expectedFrame = targetInfo.map { presentationRect($0.appKitFrame) }

            guard let window = overlayWindows.first(where: { $0.screenId == annotation.screenId }) else {
                let failures = annotationsAreSuspended ? ["annotations_suspended"] : ["overlay_window_missing"]
                return PresentationStatus(
                    annotationId: annotation.id,
                    annotationExists: true,
                    screenId: annotation.screenId,
                    annotationIsInCurrentVisibleSet: annotationIsVisible,
                    annotationsSuspended: annotationsAreSuspended,
                    expectedWindowShouldBeOnScreen: annotationIsVisible && !annotationsAreSuspended,
                    expectedLevel: 0,
                    expectedAlpha: expectedAlpha,
                    expectedFrameAppKitPoints: expectedFrame,
                    expectedFrameWindowServerCoordinates: expectedFrame,
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

            let win32Visible = window.isWindowVisible
            let actualRect = window.windowRect
            let frameMatches: Bool = {
                guard let actualRect, let targetInfo else { return false }
                return presentationRect(actualRect) == presentationRect(targetInfo.appKitFrame)
            }()
            let styleMatches = window.extendedStyleMatchesExpected
            let cloaked = window.isCloakedByDWM

            var failures: [String] = []
            if annotationsAreSuspended {
                failures = ["annotations_suspended"]
            } else {
                if !annotationIsVisible { failures.append("annotation_not_in_current_visible_set") }
                if !win32Visible { failures.append("win32_window_not_visible") }
                if !frameMatches { failures.append("win32_window_frame_mismatch") }
                if !styleMatches { failures.append("win32_extended_style_mismatch") }
                if cloaked == true { failures.append("dwm_window_cloaked") }
            }

            return PresentationStatus(
                annotationId: annotation.id,
                annotationExists: true,
                screenId: annotation.screenId,
                annotationIsInCurrentVisibleSet: annotationIsVisible,
                annotationsSuspended: annotationsAreSuspended,
                expectedWindowShouldBeOnScreen: annotationIsVisible && !annotationsAreSuspended,
                expectedLevel: 0,
                expectedAlpha: expectedAlpha,
                expectedFrameAppKitPoints: expectedFrame,
                expectedFrameWindowServerCoordinates: expectedFrame,
                overlayWindowExists: true,
                windowNumber: windowNumber(for: window),
                appKitWindowIsVisible: win32Visible,
                // There is no separate "view" object on Windows to be
                // attached/detached from the window the way an
                // `NSView`/`NSWindow` pairing can drift on macOS -- the
                // window IS the drawing surface (see
                // `WindowsOverlayWindow`'s class doc comment). `nil` here
                // means "not an applicable concept on this platform", not
                // "unmeasured".
                contentViewIsExpectedOverlayView: nil,
                viewIsAttachedToWindow: nil,
                // Never measured: this app never calls
                // `SetLayeredWindowAttributes` (doing so would break future
                // `UpdateLayeredWindow` calls -- see
                // `WindowsOverlayWindow.wsExLayered`'s doc comment), so there
                // is no separate "window alpha" property to read back the
                // way `NSWindow.alphaValue` is on macOS; every annotation's
                // opacity is already baked into the presented pixels
                // themselves.
                appKitAlpha: nil,
                appKitLevel: nil,
                appKitFramePoints: actualRect.map(presentationRect),
                windowServerEntryInAllWindows: nil,
                windowServerEntryInOnScreenList: nil,
                presentationReady: failures.isEmpty,
                failureReasons: failures,
                note: annotationsAreSuspended
                    ? "Annotations are suspended: their store entries are retained, but every AI Chalkboard overlay window in this process is intentionally hidden (SetWindowPos SWP_HIDEWINDOW). Call resume_annotations before expecting presentationReady."
                    : "WEAKER THAN macOS -- see this method's doc comment. presentationReady here is single-source evidence from this process's OWN Win32 window state (IsWindow/IsWindowVisible/GetWindowRect/extended style), plus DWM's independently-maintained cloaking flag (DwmGetWindowAttribute(DWMWA_CLOAKED)). It is NOT cross-checked against any compositor-maintained bounds/alpha/z-order record the way macOS's windowServerEntryInAllWindows/windowServerEntryInOnScreenList are (both always nil here, on purpose), and it is not proof of unoccluded pixels or of inclusion in any external capture pipeline."
            )
        }
    }

    /// Windows twin of the macOS `overlayInputPolicySnapshot()` above --
    /// same return type, same purpose (a machine-readable description of
    /// the live overlay windows' input behavior for a click dispatcher that
    /// wants to permit click-through annotations), read from this
    /// process's own Win32 window state rather than AppKit's.
    public func overlayInputPolicySnapshot() -> [OverlayInputPolicySnapshot] {
        WindowsUIThread.shared.sync {
            let annotationsAreSuspended = annotationsSuspended
            return overlayWindows.map { window in
                OverlayInputPolicySnapshot(
                    screenId: window.screenId,
                    windowNumber: windowNumber(for: window),
                    isOnScreen: window.isWindowVisible,
                    hasVisibleContent: !currentlyVisibleAnnotations(forScreenId: window.screenId).isEmpty,
                    annotationsSuspended: annotationsAreSuspended,
                    // Constant `true`, not a per-window query: `WS_EX_TRANSPARENT`
                    // is baked into every overlay window at creation (see
                    // `WindowsOverlayWindow.wsExTransparent`'s doc comment)
                    // and this app never changes it afterward, unlike the
                    // macOS branch's `NSWindow.ignoresMouseEvents`, which is
                    // read live because AppKit exposes it as a mutable
                    // per-window property.
                    ignoresMouseEvents: true,
                    sharingType: overlayCaptureAffinityName(window)
                )
            }
        }
    }

    /// Free-form description string for `OverlayInputPolicySnapshot
    /// .sharingType` -- deliberately NOT reusing macOS's "none"/"readOnly"/
    /// "readWrite" vocabulary, since `SetWindowDisplayAffinity` is a binary
    /// excluded/not-excluded switch with no equivalent of macOS's
    /// three-state `NSWindow.SharingType` (see
    /// `setCaptureVisible(_:)`'s doc comment).
    private func overlayCaptureAffinityName(_ window: WindowsOverlayWindow) -> String {
        switch window.isExcludedFromCapture {
        case true: return "excludedFromCapture"
        case false: return "notExcludedFromCapture"
        case nil: return "unknown"
        }
    }

    private func windowNumber(for window: WindowsOverlayWindow) -> Int? {
        UnsafeMutableRawPointer(window.hwnd).map { Int(bitPattern: $0) }
    }

    private func presentationRect(_ rect: ChalkRect) -> PresentationRect {
        PresentationRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }

    private func presentationRect(_ rect: ScreenCoordinateRect) -> PresentationRect {
        PresentationRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
#endif
