import Foundation
#if os(macOS)
import CoreGraphics
#elseif os(Windows)
import WinSDK
#endif

/// The only place in AI Chalkboard that reads another application's window
/// geometry. `AnchorTracker` (owned separately) polls it to keep a
/// `window`/`element`-anchored annotation glued to its target window as that
/// window moves, resizes, hides, or closes; the MCP draw-request anchor
/// resolution (owned separately) uses it to pick which of a target app's
/// windows a NEW annotation should follow.
///
/// PERMISSION STORY (macOS) -- this is the reason the file is shaped the way
/// it is. `CGWindowListCopyWindowInfo` needs NO Screen Recording grant to
/// report `kCGWindowBounds`/`kCGWindowNumber`/`kCGWindowOwnerPID`/
/// `kCGWindowLayer`/`kCGWindowIsOnscreen` -- only `kCGWindowName` (the
/// window's title) is gated behind Screen Recording. This file therefore
/// NEVER reads `kCGWindowName`, on either the multi-window or single-window
/// path below. Window-anchored (`.window` mode) tracking therefore needs NO
/// new permission at all; only `highlight_element`'s `.element` mode needs
/// Accessibility, and that need comes entirely from the element resolver,
/// not from this file.
///
/// COORDINATE REUSE -- `kCGWindowBounds` is documented by Apple in the SAME
/// global top-left-origin point space `AccessibilityScreenRect` already
/// uses for an AX element frame (see `AccessibilityElementResolver`'s
/// header and its `backingRect(forAccessibilityFrame:screens:selection:)`).
/// This file therefore performs NO independent screen-local backing-pixel
/// conversion of its own on either platform: every sample's bounds are
/// converted through that SAME function, which was already `public` on
/// both platforms -- no access level needed widening to reuse it here. On
/// Windows, `GetWindowRect` returns the same physical-pixel, virtual-
/// desktop-space rectangle the Windows `backingRect` already expects (see
/// that function's doc comment), so the same reuse holds there too.
///
/// The one addition this file needed to `backingRect` itself was a new
/// `selection: .largestOverlap` policy (added to `AccessibilityElementResolver`
/// on BOTH platforms, alongside the pre-existing `.requireContainment`
/// default every other caller keeps using unchanged): a WINDOW, unlike a UI
/// element, is routinely dragged across a display boundary or pushed partly
/// off the desktop edge, and demanding full containment would report an
/// ordinary cross-display drag as unmappable on every tick -- which reads
/// as "window gone" to a tracker. See `TargetWindowAssembly.sample(from:...)`'s
/// doc comment and `AccessibilityFrameDisplaySelection.largestOverlap`'s own
/// doc comment for the full rationale.
///
/// STRUCTURE -- `TargetWindowAssembly` and `TargetWindowSelection` below
/// hold every actual SELECTION DECISION (pid match, "normal window"
/// filtering, degenerate/unmappable geometry rejection, largest-intersection
/// choice) and are completely independent of `CGWindowListCopyWindowInfo`/
/// `EnumWindows`. This is the same "decision separate from the platform
/// read" split `PresentationDiagnostics.swift` uses for
/// `PresentationReadiness` versus `OverlayWindowController+Diagnostics.swift`'s
/// WindowServer reads -- see `TargetWindowProbeTests.swift`, which exercises
/// all of it with hand-built `Candidate`/`TargetWindowSample` values and no
/// live foreign window.
public struct TargetWindowSample: Equatable, Sendable {
    public let windowId: UInt64
    public let processId: Int64
    /// Screen-local backing pixels, top-left origin, on `screenId`.
    public let frame: CGRect
    public let screenId: String
    /// Composited and on a visible Space (macOS) / not minimised or hidden
    /// (Windows). `false` for minimised/hidden/other-Space.
    public let isOnScreen: Bool

    public init(windowId: UInt64, processId: Int64, frame: CGRect, screenId: String, isOnScreen: Bool) {
        self.windowId = windowId
        self.processId = processId
        self.frame = frame
        self.screenId = screenId
        self.isOnScreen = isOnScreen
    }
}

public protocol TargetWindowSampling: Sendable {
    /// Candidate top-level windows of `processId`, ordered front to back.
    /// Only windows that are actually on screen right now are returned (a
    /// minimised/hidden one is simply absent from this list, mirroring
    /// macOS's `.optionOnScreenOnly`); use `window(id:processId:screens:)`
    /// to learn the live state of ONE specific window, on- or off-screen.
    func windows(forProcessId processId: Int64, screens: [ScreenInfo]) -> [TargetWindowSample]

    /// One specific window. `nil` means it no longer exists, its pid no
    /// longer matches (the id was recycled -- see the Windows conformance's
    /// doc comment), or its geometry can no longer be mapped onto exactly
    /// one connected display.
    func window(id: UInt64, processId: Int64, screens: [ScreenInfo]) -> TargetWindowSample?
}

// MARK: - Pure selection/conversion logic (platform-neutral, unit-testable)

/// Pure selection and coordinate-conversion logic shared by BOTH platforms'
/// `windows(forProcessId:screens:)`/`window(id:processId:screens:)`, kept
/// independent of `CGWindowListCopyWindowInfo`/`EnumWindows` so it can be
/// exercised directly in `TargetWindowProbeTests.swift` with no live foreign
/// window, no Screen Recording permission, and no Windows machine at all.
enum TargetWindowAssembly {
    /// One raw top-level-window candidate, already reduced to primitive,
    /// platform-neutral values by each platform's OWN reader
    /// (`CGWindowListCopyWindowInfo` dictionary decoding on macOS;
    /// `EnumWindows`/`GetWindowThreadProcessId`/`GetWindowRect` on Windows).
    /// Carries no platform import of its own.
    struct Candidate: Equatable {
        let windowId: UInt64
        let ownerPID: Int64
        /// macOS `kCGWindowLayer` (`0` means "normal window": excludes
        /// menus, tooltips, panels). Always `nil` on Windows, which has no
        /// equivalent z-order-plane concept -- see `requireLayerZero` below,
        /// which the Windows conformance always passes `false`.
        let layer: Int?
        /// Global top-left window bounds, in the SAME units
        /// `AccessibilityElementResolver.backingRect(forAccessibilityFrame:
        /// screens:)` already accepts on this platform (points on macOS,
        /// physical pixels on Windows) -- see that function's per-platform
        /// doc comment. Reusing it is why this file writes no second
        /// coordinate conversion.
        let bounds: AccessibilityScreenRect
        /// Best-available liveness signal: composited and not
        /// minimised/hidden/on-another-Space (macOS), or Win32-visible and
        /// not iconic (Windows).
        let isOnScreen: Bool

        init(windowId: UInt64, ownerPID: Int64, layer: Int?, bounds: AccessibilityScreenRect, isOnScreen: Bool) {
            self.windowId = windowId
            self.ownerPID = ownerPID
            self.layer = layer
            self.bounds = bounds
            self.isOnScreen = isOnScreen
        }
    }

    /// Filters and converts ONE candidate. `nil` when: the candidate does
    /// not belong to `processId` (a stale caller-supplied id, or -- on
    /// Windows -- a recycled `HWND` now owned by a different process);
    /// `requireLayerZero` is set and the candidate is not a normal window;
    /// its bounds are degenerate (zero, negative, or non-finite area -- a
    /// torn-down or not-yet-laid-out window); or its bounds overlap NO
    /// connected display at all (entirely off the desktop). Unlike an AX
    /// element lookup, a window's bounds do NOT need to be fully contained
    /// by one display to be mapped: a window is routinely dragged across a
    /// display boundary or pushed partly off the desktop edge, and both are
    /// ordinary, everyday positions, not pathological ones. Converting via
    /// `AccessibilityElementResolver.backingRect(..., selection:
    /// .largestOverlap)` picks the display with the largest overlap instead
    /// of demanding full containment (see that selection case's doc comment)
    /// -- treating an ordinary cross-display drag as "window gone" would
    /// permanently kill tracking for the single most common user action
    /// window anchoring exists to survive.
    static func sample(
        from candidate: Candidate,
        matchingProcessId processId: Int64,
        requireLayerZero: Bool,
        screens: [ScreenInfo]
    ) -> TargetWindowSample? {
        guard candidate.ownerPID == processId else { return nil }
        // Only reject when there IS layer information proving this is not a
        // normal window. A candidate with no layer information at all (the
        // Windows path never has one) must not be silently excluded just
        // because `requireLayerZero` happens to be true -- that would make
        // this filter fail closed against platforms/paths that have no way
        // to satisfy it, rather than against windows it actually identifies.
        if requireLayerZero, let layer = candidate.layer, layer != 0 { return nil }
        guard candidate.bounds.width.isFinite, candidate.bounds.height.isFinite,
              candidate.bounds.width > 0, candidate.bounds.height > 0 else { return nil }
        guard let backing = AccessibilityElementResolver.backingRect(
            forAccessibilityFrame: candidate.bounds, screens: screens, selection: .largestOverlap
        ) else { return nil }
        return TargetWindowSample(
            windowId: candidate.windowId,
            processId: candidate.ownerPID,
            frame: CGRect(x: backing.x, y: backing.y, width: backing.width, height: backing.height),
            screenId: backing.screenId,
            isOnScreen: candidate.isOnScreen
        )
    }

    /// Same filter as `sample(from:matchingProcessId:requireLayerZero:
    /// screens:)`, applied to a front-to-back-ordered candidate list. Order
    /// is preserved (`compactMap` never reorders), which is what lets
    /// `windows(forProcessId:screens:)` promise CGWindowList's/EnumWindows's
    /// own front-to-back ordering with no extra sort step of its own.
    static func samples(
        from candidates: [Candidate],
        matchingProcessId processId: Int64,
        requireLayerZero: Bool,
        screens: [ScreenInfo]
    ) -> [TargetWindowSample] {
        candidates.compactMap {
            sample(from: $0, matchingProcessId: processId, requireLayerZero: requireLayerZero, screens: screens)
        }
    }
}

/// Pure geometry used when anchoring a NEW drawing to a window (the design
/// contract's draw-request anchor resolution, owned by a later change):
/// picks the candidate whose FRAME has the largest intersection area with
/// `rect` (the annotation's painted bounds). Lives here, next to
/// `TargetWindowSample`, because it is pure geometry over this file's own
/// public type with no MCP/store/AnchorTracker dependency of its own.
public enum TargetWindowSelection {
    /// Ties -- including "nothing intersects at all", where every candidate's
    /// intersection area is zero -- resolve to the FRONT-MOST candidate,
    /// i.e. `candidates[0]`, matching `TargetWindowSampling.windows
    /// (forProcessId:screens:)`'s documented front-to-back ordering. `nil`
    /// only when `candidates` is empty.
    public static func selectWindow(forRect rect: CGRect, among candidates: [TargetWindowSample]) -> TargetWindowSample? {
        guard let first = candidates.first else { return nil }
        var best = first
        var bestArea = intersectionArea(rect, first.frame)
        for candidate in candidates.dropFirst() {
            let area = intersectionArea(rect, candidate.frame)
            // Strictly greater, not >=: the first (front-most) candidate to
            // reach a given area keeps its slot, which is exactly the
            // "break ties by front-most" rule and also the "nothing
            // intersects" fallback (every area is 0, so `best` never changes
            // away from `candidates[0]`).
            if area > bestArea {
                best = candidate
                bestArea = area
            }
        }
        return best
    }

    static func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return Double(intersection.width) * Double(intersection.height)
    }
}

// MARK: - macOS conformance

#if os(macOS)

/// `CGWindowListCopyWindowInfo`-backed conformance. See this file's header
/// for the Screen Recording permission story and the coordinate-reuse
/// rationale.
struct CGWindowListTargetWindowSampling: TargetWindowSampling {
    func windows(forProcessId processId: Int64, screens: [ScreenInfo]) -> [TargetWindowSample] {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let candidates = raw.compactMap(TargetWindowAssembly.Candidate.init(cgWindowListEntry:))
        return TargetWindowAssembly.samples(
            from: candidates, matchingProcessId: processId, requireLayerZero: true, screens: screens
        )
    }

    func window(id: UInt64, processId: Int64, screens: [ScreenInfo]) -> TargetWindowSample? {
        // `kCGWindowNumber` is a real `CGWindowID` (`UInt32`) on macOS; `id`
        // is widened to `UInt64` only for cross-platform (HWND) storage. An
        // `id` that does not fit cannot possibly name a macOS window, so
        // fail closed rather than trapping `CGWindowID(id)`.
        guard let cgWindowId = UInt32(exactly: id) else { return nil }
        let raw = CGWindowListCopyWindowInfo(
            .optionIncludingWindow, CGWindowID(cgWindowId)
        ) as? [[String: Any]] ?? []
        // `.optionIncludingWindow` with a specific window id returns at most
        // one dictionary. Re-verify the window id anyway (cheap, and matches
        // this method's obligation to re-verify identity rather than trust
        // the option's documented behaviour blindly) before also re-checking
        // the pid in `TargetWindowAssembly.sample`.
        guard let candidate = raw.first.flatMap(TargetWindowAssembly.Candidate.init(cgWindowListEntry:)),
              candidate.windowId == id
        else { return nil }
        return TargetWindowAssembly.sample(
            from: candidate, matchingProcessId: processId, requireLayerZero: false, screens: screens
        )
    }
}

private extension TargetWindowAssembly.Candidate {
    /// Decodes one `CGWindowListCopyWindowInfo` dictionary entry. `nil` when
    /// a required field (`kCGWindowNumber`, `kCGWindowOwnerPID`, or a usable
    /// `kCGWindowBounds`) is missing or malformed; `TargetWindowAssembly`'s
    /// `compactMap`/`flatMap` call sites simply drop such an entry --
    /// tolerant decoding in the same spirit as
    /// `PresentationWindowServerEntry.init(dictionary:)`.
    ///
    /// NEVER reads `kCGWindowName` -- see this file's header comment.
    init?(cgWindowListEntry dictionary: [String: Any]) {
        guard let number = Self.int(dictionary["kCGWindowNumber"]), number >= 0,
              let pid = Self.int(dictionary["kCGWindowOwnerPID"]),
              let bounds = Self.rect(dictionary["kCGWindowBounds"])
        else { return nil }
        self.init(
            windowId: UInt64(number),
            ownerPID: Int64(pid),
            layer: Self.int(dictionary["kCGWindowLayer"]),
            bounds: bounds,
            isOnScreen: Self.bool(dictionary["kCGWindowIsOnscreen"]) ?? false
        )
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

    private static func rect(_ value: Any?) -> AccessibilityScreenRect? {
        guard let dictionary = value as? [String: Any],
              let x = double(dictionary["X"] ?? dictionary["x"]),
              let y = double(dictionary["Y"] ?? dictionary["y"]),
              let width = double(dictionary["Width"] ?? dictionary["width"]),
              let height = double(dictionary["Height"] ?? dictionary["height"])
        else { return nil }
        return AccessibilityScreenRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Windows conformance

#elseif os(Windows)

/// `EnumWindows`/`GetWindowRect`-backed conformance -- the Windows twin of
/// the macOS `CGWindowListTargetWindowSampling` above. Mirrors the existing
/// `EnumWindows` idioms in `OverlayWindowController+Diagnostics.swift`'s
/// Windows `presentationStatus(for:)`, `ActiveAppTracker.runningCandidates()`,
/// and `SuspensionQuiescence.swift`'s Windows `visibleWindows(ownedBy:)`
/// exactly: a `guard let hwnd`, an `Unmanaged`-boxed context threaded through
/// `LPARAM`, and a logged (not thrown) warning when `EnumWindows` itself
/// fails outright.
///
/// NOT COMPILED OR RUN ON THIS DEVELOPMENT MACHINE (macOS). Written by close
/// analogy to the existing Windows branches named above and reviewed by
/// reading, per this port's contract -- see the implementing report for
/// exactly what was checked.
struct Win32TargetWindowSampling: TargetWindowSampling {
    func windows(forProcessId processId: Int64, screens: [ScreenInfo]) -> [TargetWindowSample] {
        let candidates = Self.topLevelOnScreenCandidates(matchingProcessId: processId)
        return TargetWindowAssembly.samples(
            from: candidates, matchingProcessId: processId, requireLayerZero: false, screens: screens
        )
    }

    func window(id: UInt64, processId: Int64, screens: [ScreenInfo]) -> TargetWindowSample? {
        // Win32 recycles HWND values: once a window is destroyed, a LATER,
        // completely unrelated window (possibly owned by a different
        // process) can be assigned the exact same handle value within this
        // process's lifetime. `IsWindow` plus the pid re-check below are the
        // two checks that close that hole -- a recycled handle must report
        // nil ("lost"), never a different app's window.
        guard let hwnd = HWND(bitPattern: Int(bitPattern: UInt(id))), IsWindow(hwnd) else { return nil }
        var ownerPID: DWORD = 0
        _ = GetWindowThreadProcessId(hwnd, &ownerPID)
        guard ownerPID != 0, Int64(ownerPID) == processId else { return nil }
        guard let bounds = Self.windowRect(hwnd) else { return nil }
        let visible = IsWindowVisible(hwnd)
        let iconic = IsIconic(hwnd)
        let candidate = TargetWindowAssembly.Candidate(
            windowId: id, ownerPID: Int64(ownerPID), layer: nil,
            bounds: bounds, isOnScreen: visible && !iconic
        )
        return TargetWindowAssembly.sample(
            from: candidate, matchingProcessId: processId, requireLayerZero: false, screens: screens
        )
    }

    /// `RECT` (physical pixels, virtual-desktop space) -> `AccessibilityScreenRect`,
    /// the SAME units the Windows
    /// `AccessibilityElementResolver.backingRect(forAccessibilityFrame:
    /// screens:)` already expects (see that function's doc comment on
    /// `IUIAutomationElement.CurrentBoundingRectangle` sharing this exact
    /// pixel space) -- reused here rather than writing a second conversion.
    private static func windowRect(_ hwnd: HWND) -> AccessibilityScreenRect? {
        var rect = RECT()
        guard GetWindowRect(hwnd, &rect) else { return nil }
        return AccessibilityScreenRect(
            x: Double(rect.left), y: Double(rect.top),
            width: Double(rect.right - rect.left), height: Double(rect.bottom - rect.top)
        )
    }

    /// One `EnumWindows` pass, filtered to VISIBLE, NON-MINIMISED top-level
    /// windows owned by `processId` -- the Windows analogue of macOS's
    /// `.optionOnScreenOnly`: only genuinely on-screen windows become
    /// candidates here at all. A minimised or hidden window is reported only
    /// through `window(id:processId:screens:)`'s honest `isOnScreen: false`,
    /// exactly like a macOS window `.optionOnScreenOnly` would also omit
    /// from `windows(forProcessId:screens:)`.
    ///
    /// `GetAncestor(hwnd, GA_ROOT) == hwnd` is a defensive top-level check:
    /// `EnumWindows` itself only ever visits windows with no PARENT, so this
    /// is normally a no-op, but it costs one extra call and guards against a
    /// pathological window that reports itself top-level to `EnumWindows`
    /// while still nesting under a chain `GA_ROOT` would unwind. Windows has
    /// no direct equivalent of macOS's `kCGWindowLayer == 0` (menus/
    /// tooltips/panels excluded by one explicit plane number); this check,
    /// together with the visible/non-iconic/non-zero-area filters, is the
    /// closest available approximation -- not an exact translation, and
    /// `requireLayerZero: false` above records that honestly rather than
    /// pretending an equivalent filter ran.
    private static func topLevelOnScreenCandidates(matchingProcessId processId: Int64) -> [TargetWindowAssembly.Candidate] {
        // `WNDENUMPROC` is `@convention(c)`: the callback below must capture
        // NOTHING from the enclosing scope (a C function pointer cannot be
        // formed from a closure that captures context -- this is a hard
        // compile error on Windows, invisible on macOS since this branch
        // never compiles there). `processId` is therefore threaded through
        // the SAME `Unmanaged`-boxed context as the result array, recovered
        // from `lParam` FIRST thing in the callback, exactly like
        // `SuspensionQuiescence.swift`'s Windows `visibleWindows(ownedBy:)`
        // threads its candidate-pid set through `EnumContext` for the
        // identical reason. `Win32TargetWindowSampling.windowRect(_:)` is a
        // static type reference, not a capture, so it stays fine to call
        // here.
        final class EnumContext {
            let processId: Int64
            var candidates: [TargetWindowAssembly.Candidate] = []
            init(processId: Int64) { self.processId = processId }
        }
        let context = EnumContext(processId: processId)
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        let succeeded = EnumWindows({ hwnd, lParam in
            guard let hwnd,
                  let raw = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam)))
            else { return true }
            let context = Unmanaged<EnumContext>.fromOpaque(raw).takeUnretainedValue()
            guard GetAncestor(hwnd, UINT(GA_ROOT)) == hwnd else { return true }
            var ownerPID: DWORD = 0
            GetWindowThreadProcessId(hwnd, &ownerPID)
            guard ownerPID != 0, Int64(ownerPID) == context.processId else { return true }
            guard IsWindowVisible(hwnd), !IsIconic(hwnd) else { return true }
            guard let bounds = Win32TargetWindowSampling.windowRect(hwnd),
                  bounds.width > 0, bounds.height > 0 else { return true }
            let windowId = UInt64(UInt(bitPattern: hwnd))
            context.candidates.append(TargetWindowAssembly.Candidate(
                windowId: windowId, ownerPID: Int64(ownerPID), layer: nil,
                bounds: bounds, isOnScreen: true
            ))
            return true
        }, LPARAM(bitPattern: UInt64(UInt(bitPattern: contextPointer))))
        if !succeeded {
            Logger.shared.log("TargetWindowProbe: EnumWindows failed (GetLastError=\(GetLastError())); windows(forProcessId:screens:) sees an incomplete (possibly empty) list this call.", level: "WARN")
        }
        return context.candidates
    }
}

#endif

// MARK: - Platform-forked entry point

public enum TargetWindowProbe {
    #if os(macOS)
    public static let shared: TargetWindowSampling = CGWindowListTargetWindowSampling()
    #elseif os(Windows)
    public static let shared: TargetWindowSampling = Win32TargetWindowSampling()
    #endif
}
