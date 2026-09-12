import Foundation
#if os(Windows)
import WinSDK
#endif

/// A rectangle in one named desktop coordinate space.  `ScreenInfo` carries
/// both the AppKit point-space rectangle and the WindowServer rectangle so a
/// caller that starts with another global API (Accessibility, ScreenCaptureKit
/// diagnostics, …) never has to guess a monitor's origin from its size alone.
public struct ScreenCoordinateRect: Codable, Equatable {
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

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct ScreenInfo: Codable {
    public let id: String
    public let index: Int
    public let name: String
    public let widthPx: Int
    public let heightPx: Int
    public let widthPt: Double
    public let heightPt: Double
    public let backingScaleFactor: Double
    public let isMain: Bool
    /// Global logical-point rectangle returned by `NSScreen.frame` (AppKit's
    /// bottom-left desktop coordinate system).
    public let appKitFrame: ScreenCoordinateRect
    /// Global WindowServer rectangle returned by `CGDisplayBounds`.  It is
    /// intentionally reported separately rather than assumed equivalent to
    /// AppKit's coordinate system.
    public let windowServerFrame: ScreenCoordinateRect
    /// The `CGDirectDisplayID` used by ScreenCaptureKit.  It is optional only
    /// for the old fallback case where AppKit cannot provide a screen number.
    public let displayID: UInt32?

    public init(
        id: String,
        index: Int,
        name: String,
        widthPx: Int,
        heightPx: Int,
        widthPt: Double,
        heightPt: Double,
        backingScaleFactor: Double,
        isMain: Bool,
        appKitFrame: ScreenCoordinateRect? = nil,
        windowServerFrame: ScreenCoordinateRect? = nil,
        displayID: UInt32? = nil
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.backingScaleFactor = backingScaleFactor
        self.isMain = isMain
        self.appKitFrame = appKitFrame ?? ScreenCoordinateRect(x: 0, y: 0, width: widthPt, height: heightPt)
        self.windowServerFrame = windowServerFrame ?? ScreenCoordinateRect(x: 0, y: 0, width: Double(widthPx), height: Double(heightPx))
        self.displayID = displayID
    }
}

/// An immutable picture of the display layout, taken once and then used for
/// every screen question a single MCP tool call needs to ask.
///
/// See `OverlayWindowController.screenSnapshot()` for why a single snapshot
/// replaced two separate per-call main-thread reads.
public struct ScreenSnapshot {
    public let screens: [ScreenInfo]

    /// Resolves a caller-supplied `screen_id` against THIS snapshot.
    /// Returns nil when there are no screens or an explicit id/index does not
    /// resolve against this snapshot.
    /// Order: omitted/blank -> main screen, otherwise exact id match ->
    /// in-bounds integer index. An explicit unknown id returns nil rather than
    /// silently drawing on a different display.
    ///
    /// WHY THE EXACT ID GOES FIRST: `getScreenId` reports a display's real
    /// `CGDirectDisplayID`, and nothing stops that id from being a small
    /// integer that also happens to be a valid positional index -- which is
    /// exactly the id `get_screens` just handed the caller. With the index
    /// checked first, such a display was unreachable BY ITS OWN REPORTED ID:
    /// the request silently landed on whichever monitor occupied that
    /// position instead. An id a screen actually reports must always win over
    /// the positional convenience alias.
    public func resolve(_ rawId: String?) -> ScreenInfo? {
        guard !screens.isEmpty else { return nil }

        guard let trimmed = rawId?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            // No id supplied: default to the main screen.
            return screens.first(where: { $0.isMain }) ?? screens.first
        }

        // 1. Does rawId match an exact display id string?
        if let match = screens.first(where: { $0.id == trimmed }) {
            return match
        }

        // 2. Does rawId match an integer index in bounds 0..<screens.count?
        if let idx = Int(trimmed), idx >= 0 && idx < screens.count {
            return screens[idx]
        }

        // An explicit id is a placement constraint, not a hint. Falling back
        // here made a stale/typoed display id report success while drawing on
        // the main display, which is substantially worse than a retryable
        // error from the draw call.
        return nil
    }
}

/// Which reading of the display layout `screenSnapshot(freshness:)` serves.
///
/// `.cached` is the default and what every ordinary per-call consumer wants:
/// one coherent, immutable snapshot with no presentation-thread hop. `.live`
/// exists for exactly one caller shape -- a change-DETECTION re-read taken
/// after a long-running operation (the post-walk guards in
/// `MCPToolHandlers+Highlight.swift`, `MCPToolHandlers+Verification.swift`,
/// and `MCPToolHandlers+ScreenshotSpace.swift`'s calibrate-from-elements
/// path), whose entire purpose is to observe a layout DIFFERENT from the one
/// an earlier read returned. Serving both reads from the same cached value
/// would make such a guard pass trivially whenever the reconfiguration's
/// notification has not yet been processed; `.live` restores the pre-cache
/// semantics those guards were written against.
public enum ScreenSnapshotFreshness {
    /// Serve the notification-invalidated cached snapshot when one exists;
    /// build fresh (with a presentation-thread hop) only before the first
    /// display-change/startup rebuild has populated the cache.
    case cached
    /// Always rebuild on the presentation thread, bypassing the cache. Costs
    /// the main-thread hop the cache exists to avoid -- reach for this only
    /// when observing a layout CHANGE is the point of the read.
    case live
}

/// The lock box behind `OverlayWindowController.screenSnapshot(freshness:)`
/// on macOS: at most one immutable `ScreenSnapshot`, replaced wholesale by
/// its single writer and read under a lock from any thread.
///
/// SINGLE-WRITER DISCIPLINE, deliberately: `store(_:)` is called from exactly
/// one place -- the display-change handler that also rebuilds the overlay
/// windows (`rebuildOverlayWindows()`, reached from `setup()` and from
/// `NSApplication.didChangeScreenParametersNotification`). `read` never
/// writes back, even on a `.live` rebuild or a cold-start fallback build.
/// Two reasons:
///
///   1. A fallback build can run mid-reconfiguration, exactly when
///      `NSScreen.screens` can be momentarily empty (see
///      `screenSnapshot(freshness:)`'s doc comment). Writing that reading
///      into the cache would poison every subsequent call until the next
///      notification; NOT writing it means a degenerate reading is consumed
///      once, by the one call that was unlucky, and nobody else.
///   2. It keeps "the cache is exactly as old as the overlay windows" a true
///      statement -- both are rebuilt by the same handler, from the same
///      main-thread turn -- which is the honesty claim the staleness story in
///      `screenSnapshot(freshness:)` rests on.
///
/// `read` releases the lock BEFORE invoking `rebuild`: the rebuild closure
/// hops to the presentation thread, and the presentation thread is also
/// where `store(_:)` runs, so holding the lock across the hop would be a
/// deadlock waiting for a display change to trigger it.
final class ScreenSnapshotCache {
    private let lock = NSLock()
    private var value: ScreenSnapshot?

    init() {}

    /// Replaces the cached snapshot. Single caller: the display-change
    /// handler that rebuilds the overlay windows (see the class doc comment).
    func store(_ snapshot: ScreenSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    /// Serves the cached snapshot for `.cached` reads when populated;
    /// otherwise (cold start, or `.live`) returns `rebuild()`'s result
    /// WITHOUT caching it -- see the class doc comment for why the fallback
    /// build must not become the cached value.
    func read(freshness: ScreenSnapshotFreshness, rebuild: () -> ScreenSnapshot) -> ScreenSnapshot {
        if freshness == .cached {
            lock.lock()
            let cached = value
            lock.unlock()
            if let cached {
                return cached
            }
        }
        return rebuild()
    }
}

#if os(macOS)
import AppKit

extension OverlayWindowController {
    public func getScreenId(screen: NSScreen, index: Int) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return String(screenNumber)
        }
        return String(index)
    }

    /// Takes one snapshot of the display layout -- served from the
    /// notification-invalidated cache with NO main-thread hop in the steady
    /// state -- then answers every screen question a single MCP tool call
    /// needs to ask against that same snapshot.
    ///
    /// WHY ONE SNAPSHOT PER CALL (unchanged from the pre-cache design): the
    /// old shape -- `resolveScreenId(_:)` and `getScreenInfos()` called
    /// separately per tool call -- did two independent
    /// `DispatchQueue.main.sync` + `NSScreen.screens` reads per draw call, and
    /// those two reads were not atomic with each other: the display layout can
    /// change in the gap between them (display reconfiguration/wake is
    /// exactly when `NSScreen.screens` can be momentarily empty). In that gap,
    /// `resolveScreenId` would fall back to the synthetic id "0" while a
    /// dimension lookup against the SECOND, now-empty read found nothing and
    /// returned nil -- producing an annotation permanently orphaned on a
    /// screen id no view will ever match, because the id and its dimensions
    /// were resolved against two different readings of the screen list.
    /// A single snapshot per call closes that TOCTOU gap, and a cached
    /// IMMUTABLE value preserves it BY CONSTRUCTION: whichever
    /// `ScreenSnapshot` a call gets handed, every question that call asks is
    /// answered against that one value -- there is no second read left to
    /// disagree with the first. The TOCTOU the one-hop design fixed was two
    /// INDEPENDENT reads straddling a reconfiguration; a
    /// notification-invalidated cache still has exactly one source.
    ///
    /// WHY IT IS NOW CACHED: the per-call `MainThread.sync` rebuild
    /// (`NSScreen.screens` walk + `localizedName` + `CGDisplayBounds` per
    /// display) ran on EVERY MCP call that touches geometry -- every draw,
    /// `get_screens`, `get_overlay_state`, `update_annotation`, and up to
    /// three times per screenshot_space-referencing call through expansion +
    /// resolve -- plus `AnchorTracker`'s sampling loop at up to 30Hz. Each
    /// hop queues behind whatever the main thread is doing; during draw
    /// bursts that is the previous draw's full-view repaint, so call N's
    /// repaint sat directly in call N+1's response path. The cache is
    /// populated on the main thread at startup and re-populated by
    /// `rebuildOverlayWindows()` from the SAME
    /// `NSApplication.didChangeScreenParametersNotification` handler that
    /// rebuilds the overlay windows, so the cache and the windows change
    /// together, in the same main-thread turn.
    ///
    /// STALENESS, HONESTLY: between an actual hardware change and that
    /// notification's delivery there is a window where the cache is stale.
    /// But the notification is the SAME signal the overlay windows themselves
    /// rebuild on -- until it lands, the live windows are sized and
    /// positioned for the OLD layout too -- so a stale cached read is exactly
    /// as stale as the windows every annotation is actually painted into.
    /// (AppKit's own `NSScreen` list is likewise refreshed as the app
    /// processes the same reconfiguration event, so even a forced rebuild in
    /// that window is not a hotline to the hardware.) What the cache DOES
    /// give up is change DETECTION: a deliberate re-read taken to notice a
    /// mid-operation reconfiguration would, served from the cache, compare a
    /// value against itself whenever the notification has not yet been
    /// processed. Callers whose second read exists to detect change --
    /// the post-walk guards named on `ScreenSnapshotFreshness` -- must pass
    /// `.live`, which forces the pre-cache presentation-thread rebuild.
    ///
    /// THREADING: callable both off the main thread and on it. The cached
    /// path takes only an `NSLock` (no hop, no deadlock either way); the
    /// `.live`/cold-start path goes through `MainThread.sync`, which runs the
    /// work inline when already on main rather than re-dispatching.
    public func screenSnapshot(freshness: ScreenSnapshotFreshness = .cached) -> ScreenSnapshot {
        screenSnapshotCache.read(freshness: freshness) {
            MainThread.sync {
                ScreenSnapshot(screens: buildScreenInfos())
            }
        }
    }

    /// MAIN-THREAD-ONLY (`NSScreen`): every caller must already be inside a
    /// `MainThread.sync` block.
    // internal (not private): OverlayWindowController+Diagnostics.swift's
    // presentationStatus(for:) derives its expected geometry from these same
    // ScreenInfos rather than re-deriving a third copy from NSScreen itself.
    func buildScreenInfos() -> [ScreenInfo] {
        var infos: [ScreenInfo] = []
        let screens = NSScreen.screens
        let mainScreen = NSScreen.main

        for (idx, screen) in screens.enumerated() {
            let idStr = getScreenId(screen: screen, index: idx)
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let windowServerBounds = displayID.map(CGDisplayBounds)

            let widthPx = Int(round(frame.width * scale))
            let heightPx = Int(round(frame.height * scale))

            infos.append(ScreenInfo(
                id: idStr,
                index: idx,
                name: screen.localizedName,
                widthPx: widthPx,
                heightPx: heightPx,
                widthPt: Double(frame.width),
                heightPt: Double(frame.height),
                backingScaleFactor: Double(scale),
                isMain: (screen == mainScreen),
                appKitFrame: ScreenCoordinateRect(
                    x: Double(frame.origin.x), y: Double(frame.origin.y),
                    width: Double(frame.width), height: Double(frame.height)
                ),
                windowServerFrame: windowServerBounds.map {
                    ScreenCoordinateRect(
                        x: Double($0.origin.x), y: Double($0.origin.y),
                        width: Double($0.width), height: Double($0.height)
                    )
                } ?? ScreenCoordinateRect(
                    x: 0, y: 0, width: Double(widthPx), height: Double(heightPx)
                ),
                displayID: displayID
            ))
        }
        return infos
    }
}
#elseif os(Windows)
import WinSDK

extension OverlayWindowController {
    /// Takes one snapshot of the Windows display layout and answers every
    /// screen question a single MCP tool call needs to ask against it -- the
    /// same contract `screenSnapshot(freshness:)` documents on macOS above,
    /// minus that branch's specific TOCTOU story (`EnumDisplayMonitors` plus
    /// one `GetMonitorInfoW`/`GetDpiForMonitor` pair per handle is a
    /// synchronous, single-threaded walk on the UI thread, not two
    /// independently-timed reads of a value that can change out from under
    /// them).
    ///
    /// `freshness` is accepted for signature parity with the macOS overload
    /// -- shared MCP code passes `.live` at its post-walk change-detection
    /// sites and must compile identically on both platforms -- but there is
    /// NO cache behind it here: both values build live on the UI thread,
    /// exactly as this method always has. That makes `.live`'s
    /// change-detection contract trivially satisfied on this platform rather
    /// than silently weaker. If the macOS branch's cache is ever wanted here
    /// too, `handleDisplayOrDpiChange()`/`rebuildOverlayWindows()` is the
    /// invalidation hook that plays the role
    /// `didChangeScreenParametersNotification` plays there.
    public func screenSnapshot(freshness: ScreenSnapshotFreshness = .cached) -> ScreenSnapshot {
        _ = freshness
        return WindowsUIThread.shared.sync {
            ScreenSnapshot(screens: self.buildScreenInfos())
        }
    }

    /// UI-THREAD-ONLY by convention, mirroring the macOS `buildScreenInfos()`
    /// doc comment's MAIN-THREAD-ONLY contract: every caller here already
    /// runs inside a `WindowsUIThread.sync`/`.async` block. Nothing about
    /// `EnumDisplayMonitors`/`GetMonitorInfoW`/`GetDpiForMonitor` actually
    /// requires that specific thread (unlike `NSScreen`, these are plain
    /// synchronous Win32 queries with no AppKit-style thread affinity), but
    /// keeping this call site on the same thread that owns window
    /// creation/destruction avoids a second concurrency story existing only
    /// for screen enumeration.
    // internal (not private): OverlayWindowController+Diagnostics.swift's
    // presentationStatus(for:) derives its expected geometry from these same
    // ScreenInfos, exactly as it does on macOS.
    func buildScreenInfos() -> [ScreenInfo] {
        final class MonitorBox {
            var handles: [HMONITOR] = []
        }
        let box = MonitorBox()
        let boxPointer = Unmanaged.passUnretained(box).toOpaque()
        _ = EnumDisplayMonitors(nil, nil, { hMonitor, _, _, lParam in
            guard let hMonitor, let raw = UnsafeRawPointer(bitPattern: Int(lParam)) else { return true }
            Unmanaged<MonitorBox>.fromOpaque(raw).takeUnretainedValue().handles.append(hMonitor)
            return true
        }, LPARAM(Int(bitPattern: boxPointer)))

        var infos: [ScreenInfo] = []
        infos.reserveCapacity(box.handles.count)

        for (idx, hMonitor) in box.handles.enumerated() {
            var infoEx = MONITORINFOEXW()
            infoEx.cbSize = UInt32(MemoryLayout<MONITORINFOEXW>.size)
            // MONITORINFOEXW is binary-compatible with MONITORINFO for its
            // first four fields (cbSize, rcMonitor, rcWork, dwFlags) --
            // `szDevice` is appended after them, which is exactly the C
            // idiom GetMonitorInfoW's documentation relies on: pass the
            // larger struct's address, sized correctly via `cbSize`, and the
            // extended fields come back filled in too.
            let gotInfo = withUnsafeMutablePointer(to: &infoEx) { exPtr -> Bool in
                exPtr.withMemoryRebound(to: MONITORINFO.self, capacity: 1) { miPtr in
                    GetMonitorInfoW(hMonitor, miPtr)
                }
            }
            guard gotInfo else {
                Logger.shared.log("OverlayWindowController: GetMonitorInfoW failed for monitor index \(idx); skipping it.", level: "ERROR")
                continue
            }

            let rect = infoEx.rcMonitor
            let widthPx = Int(rect.right - rect.left)
            let heightPx = Int(rect.bottom - rect.top)
            guard widthPx > 0, heightPx > 0 else { continue }

            var dpiX: UInt32 = 96
            var dpiY: UInt32 = 96
            let dpiStatus = GetDpiForMonitor(hMonitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)
            if dpiStatus != S_OK {
                Logger.shared.log("OverlayWindowController: GetDpiForMonitor failed (hresult=\(dpiStatus)) for monitor index \(idx); defaulting to 96 DPI (scale 1.0).", level: "WARN")
                dpiX = 96
            }
            let scale = Double(dpiX) / 96.0

            // Microsoft documents HMONITOR as potentially REASSIGNED across a
            // display-configuration change (unplugging one monitor and
            // plugging in a different one can hand the new one the same
            // handle value within this process's lifetime) -- see
            // `ScreenSnapshot.resolve(_:)`'s doc comment above for why an id
            // that can silently start meaning a different physical display
            // is unacceptable here. The device name (`\\.\DISPLAYn`)
            // `GetMonitorInfoW`'s extended struct reports is the OS's own
            // stable-per-session label for the physical output -- the
            // closest Windows analogue of the macOS branch's
            // `CGDirectDisplayID`-derived id -- so that, not the raw
            // `HMONITOR`, is what this reports as `id`.
            let deviceName = withUnsafePointer(to: infoEx.szDevice) { namePtr -> String in
                namePtr.withMemoryRebound(to: UInt16.self, capacity: Int(CCHDEVICENAME)) { wide in
                    String(decodingCString: wide, as: UTF16.self)
                }
            }
            let isMain = (infoEx.dwFlags & DWORD(MONITORINFOF_PRIMARY)) != 0

            // Windows' virtual desktop is already top-left-origin, physical
            // pixels once this process is Per-Monitor-v2 DPI aware (see
            // `OverlayWindowController.setup()`'s one-time
            // `SetProcessDpiAwarenessContext` call) -- there is no second,
            // independently-maintained coordinate space the way AppKit's
            // point-space `appKitFrame` and WindowServer's pixel-space
            // `windowServerFrame` genuinely are two different systems on
            // macOS. Reporting the SAME rect under both field names here is
            // deliberate: it tells a caller written against the macOS shape
            // of `ScreenInfo` that these two fields are NOT independent
            // evidence of anything on this platform, rather than silently
            // leaving `windowServerFrame` looking like a real second source
            // the way a fabricated synthetic 0,0-origin rect would.
            let deviceRect = ScreenCoordinateRect(
                x: Double(rect.left), y: Double(rect.top),
                width: Double(widthPx), height: Double(heightPx)
            )

            infos.append(ScreenInfo(
                id: deviceName,
                index: idx,
                name: deviceName,
                widthPx: widthPx,
                heightPx: heightPx,
                // "Points" on Windows ARE physical pixels: the Windows paint
                // path (`OverlayWindowController+Presentation.swift`) feeds
                // `AnnotationRenderer.drawAnnotations` a `scaleFactor` of
                // exactly `1.0` against a physical-pixel-sized canvas, rather
                // than converting through `backingScaleFactor` the way the
                // macOS `OverlayView` does -- `GDIPlusDrawingContext`'s base
                // coordinate flip has no DPI-scale term of its own to
                // compose with (see that file's coordinate-contract doc
                // comment), so a physical-pixel render target is what stays
                // correct without touching that file. `widthPt`/`heightPt`
                // are reported here purely for API-shape parity with the
                // macOS `ScreenInfo`; no drawing-path code on either platform
                // actually reads them (grepped to confirm: only
                // `widthPx`/`heightPx` feed real coordinate math).
                widthPt: Double(widthPx),
                heightPt: Double(heightPx),
                backingScaleFactor: scale,
                isMain: isMain,
                appKitFrame: deviceRect,
                windowServerFrame: deviceRect,
                displayID: nil
            ))
        }
        return infos
    }
}
#endif
