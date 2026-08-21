import Foundation
import AppKit

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

/// An immutable picture of the display layout, taken once and then used for
/// every screen question a single MCP tool call needs to ask.
///
/// See `OverlayWindowController.screenSnapshot()` for why a single snapshot
/// replaced two separate per-call main-thread reads.
public struct ScreenSnapshot {
    public let screens: [ScreenInfo]

    /// Resolves a caller-supplied `screen_id` against THIS snapshot.
    /// Returns nil only when the snapshot contains no screens at all.
    /// Order: in-bounds integer index -> exact id match -> main screen -> first screen.
    public func resolve(_ rawId: String?) -> ScreenInfo? {
        guard !screens.isEmpty else { return nil }

        guard let trimmed = rawId?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            // No id supplied: default to the main screen.
            return screens.first(where: { $0.isMain }) ?? screens.first
        }

        // 1. Does rawId match an integer index in bounds 0..<screens.count?
        if let idx = Int(trimmed), idx >= 0 && idx < screens.count {
            return screens[idx]
        }

        // 2. Does rawId match an exact display id string?
        if let match = screens.first(where: { $0.id == trimmed }) {
            return match
        }

        // Unrecognized id: default to the main screen.
        return screens.first(where: { $0.isMain }) ?? screens.first
    }
}

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()

    /// Ordering a transparent, full-display overlay back in must be
    /// immediate. AppKit's default window transform animation leaves a
    /// short-lived WindowServer entry with an interpolated alpha and inset
    /// bounds after `orderFrontRegardless()`. That makes an acknowledged
    /// resume look visibly/readiness-incomplete even though the AppKit window
    /// itself already reports alpha 1. Disabling the transition gives both
    /// click-workflow resume and `verify_presentation` a single, stable
    /// postcondition rather than making callers guess a delay.
    static let overlayWindowAnimationBehavior: NSWindow.AnimationBehavior = .none

    /// One entry per real on-screen display, in the order `NSScreen.screens`
    /// produced them at the last rebuild.
    ///
    /// Plain arrays, not dictionaries keyed by screen id: nothing in this
    /// codebase ever looks a window or view up BY screen id (grepped to
    /// confirm before making this change) -- both were only ever iterated via
    /// `.values`. The prior `windowsByScreenId`/`viewsByScreenId` dictionaries
    /// also stored every window/view TWICE -- once under its real
    /// `CGDirectDisplayID` and once under a positional index alias ("0", "1",
    /// ...) -- so a display whose real id happened to equal another display's
    /// index string would silently clobber that entry. A flat array can't
    /// collide, costs one insert instead of two per screen, and matches how
    /// these are actually consumed.
    private var overlayWindows: [NSWindow] = []
    private var overlayViews: [OverlayView] = []

    /// MAIN-THREAD-ONLY. Suspension is deliberately presentation state, not
    /// store state: annotations, their stable IDs, creation dates, and TTLs
    /// remain untouched so resume can make the exact still-live set visible
    /// again. Every mutation goes through `setAnnotationsSuspended(_:)`, which
    /// synchronously hops to AppKit's main thread before acknowledging an MCP
    /// request or a broadcast.
    // Fail closed until `SuspensionLeaseCoordinator.bootstrapAndReconcile()`
    // synchronously reads the shared lease registry during launch. A new MCP
    // process must never flash an overlay while another process owns a lease.
    private var annotationsSuspended = true

    /// The durable suspension-registry generation which produced the current
    /// presentation decision.  `nil` means this process has not completed its
    /// startup reconciliation yet.  Keeping the generation beside the AppKit
    /// state is important: two background reconciliations can reach the main
    /// queue in the opposite order, and an older resume must never order a
    /// newer suspension back on screen.
    private var annotationsSuspensionGeneration: UInt64?

    /// Whether this process has temporarily ordered all overlay windows out.
    /// Kept as a synchronous query because MCP diagnostics must describe the
    /// state that is already in effect, not a pending main-queue mutation.
    public var isAnnotationsSuspended: Bool {
        MainThread.sync { annotationsSuspended }
    }

    // MARK: - Capture visibility
    //
    // WHY THE DEFAULT IS `false` (i.e. NSWindowSharingType.none):
    //
    // `.readOnly` makes the windows eligible to legacy capture paths; `.none`
    // requests exclusion. Modern capture APIs can apply their own app/window
    // filters and Apple now treats `.none` as a legacy hint, so neither value can
    // guarantee what an independent capture program composites. The default is
    // still false to minimize feedback loops on capture paths that honor it.
    //
    // The toggle exists because the loop is exactly what you WANT when
    // debugging placement: flipping this on is the only way for Claude to
    // verify that a box landed where intended on compatible full-display capture
    // paths. `get_screens` reports the requested mode so it can be restored.

    /// Guards `_captureVisible` only. The flag is written from the main thread
    /// (menu / broadcast handler) and read from the MCP server's background read
    /// queue (`get_screens`), so it cannot be plain unsynchronized state like
    /// the window arrays above.
    private let captureLock = NSLock()
    private var _captureVisible = false

    /// How long capture-debug mode may stay on with no renewal before it
    /// reverts to OFF on its own.
    ///
    /// WHY: `set_capture_visible(true)` is meant to last for one placement
    /// check (draw, screenshot, verify), not become a persistent mode -- but
    /// nothing forces whoever turned it on to ever call
    /// `set_capture_visible(false)` afterward. An LLM agent mid-conversation
    /// can get interrupted, decide the debugging session is over without
    /// remembering the toggle, or simply move on. Left on, it silently
    /// defeats `OverlayView.draw`'s per-app filter for EVERY annotation on
    /// EVERY screen indefinitely -- which looks exactly like a rendering bug
    /// ("I switched apps and the annotation is still there") to whoever is
    /// watching the screen next, with no obvious cause. Five minutes covers
    /// a realistic screenshot-and-check loop but is short enough that a
    /// forgotten toggle self-heals well within one human work session.
    public static let captureAutoRevertInterval: TimeInterval = 5 * 60

    /// MAIN-THREAD-ONLY, like the `Timer` API it wraps. Every read/write
    /// happens inside `scheduleCaptureAutoRevert(visible:)`, itself only ever
    /// called from the main-thread transaction in `setCaptureVisible`.
    private var captureAutoRevertTimer: Timer?

    /// Single optional observer, invoked on the main thread whenever
    /// `isCaptureVisible` actually changes (not on a same-value renewal).
    /// Exists so `AppDelegate` can keep the status-bar icon's "debug mode is
    /// on" indicator in sync without polling. A single slot, not a list, for
    /// the same reason as `AnnotationStore.onStoreChanged`: there is exactly
    /// one process-wide subscriber (this process's `AppDelegate`), so a list
    /// would be unused generality.
    public var onCaptureVisibleChanged: ((Bool) -> Void)?

    /// Requested capture-debug mode. This controls rendering and the legacy
    /// NSWindow sharing preference, not an external capture tool's filters.
    public var isCaptureVisible: Bool {
        captureLock.lock(); defer { captureLock.unlock() }
        return _captureVisible
    }

    /// The `sharingType` newly created windows must be born with, so that a
    /// `rebuildOverlayWindows()` triggered by anything else (display connected,
    /// resolution change) does not silently revert the user's choice.
    private var desiredSharingType: NSWindow.SharingType {
        return isCaptureVisible ? .readOnly : .none
    }

    /// Turns the capture-debug request on/off across every overlay window.
    ///
    /// APPROACH: assigns `sharingType` on the LIVE windows -- no teardown, no
    /// `rebuildOverlayWindows()`. This was verified empirically rather than
    /// assumed (see the probe in this change's notes): a window was created with
    /// `.none`, ordered onto the window server, then flipped at runtime, and the
    /// WINDOW SERVER'S OWN copy of the flag -- `kCGWindowSharingState` read back
    /// via `CGWindowListCopyWindowInfo`, not just the Cocoa-side property --
    /// tracked every flip within one run-loop turn (0 -> 1 -> 0 -> 1). So the
    /// value is not latched at window-creation time and recreation is
    /// unnecessary. Avoiding the rebuild matters: a rebuild closes and reopens
    /// every overlay, which flickers and briefly drops the annotations off
    /// screen, on what is meant to be an instant debugging toggle.
    ///
    /// The early return when the value is unchanged is load-bearing: this is
    /// driven by a distributed notification that is also delivered back to the
    /// process that posted it, so the no-op guard is what keeps the echo free.
    @discardableResult
    public func setCaptureVisible(_ visible: Bool) -> Bool {
        // MCP success must mean the local AppKit state has already changed.
        // `MainThread.sync` executes inline for menu/broadcast delivery and
        // otherwise waits for the main run loop; it therefore avoids both the
        // old acknowledgement race and a main-thread self-deadlock.
        MainThread.sync {
            captureLock.lock()
            let changed = (_captureVisible != visible)
            _captureVisible = visible
            captureLock.unlock()

            // Renewed on EVERY request for `true`, including a same-value
            // renewal where the mode was already on -- not gated behind
            // `changed` below. A caller re-requesting capture-debug mode
            // mid-session means "I'm still debugging, push the deadline out".
            scheduleCaptureAutoRevert(visible: visible)

            guard changed else { return changed }

            let sharingType: NSWindow.SharingType = visible ? .readOnly : .none
            // `overlayWindows` is a flat array now (one entry per real
            // display), so each window is visited exactly once here.
            for window in overlayWindows {
                window.sharingType = sharingType
            }

            // This intentionally runs synchronously with the sharing-type
            // mutation. A caller may safely inspect capture/debug state after
            // this method returns; no extra main-run-loop turn is required.
            refreshViewsNow()

            Logger.shared.log(
                "OverlayWindowController: capture-debug request set to \(visible) (sharingType = \(visible ? ".readOnly" : ".none")) on \(overlayWindows.count) window reference(s), applied live without rebuilding. External capture tools retain independent app/window filters, so final inclusion is not guaranteed.",
                level: "INFO"
            )

            onCaptureVisibleChanged?(visible)
            return changed
        }
    }

    /// Temporarily removes or restores this process's overlay windows without
    /// mutating `AnnotationStore`. Suspending makes every full-screen overlay
    /// disappear from WindowServer's on-screen list, which is a practical
    /// workaround for click dispatchers that reject a point merely because an
    /// overlay window is present. It is not simultaneous visual click-through:
    /// annotations are absent until a later resume.
    ///
    /// This intentionally reapplies the requested ordering even on a same
    /// value call. The state transition is idempotent, while re-ordering makes
    /// a repeated suspend/resume self-heal after a display rebuild or another
    /// AppKit ordering event.
    ///
    /// Delegates to the generation-aware overload rather than hand-rolling the
    /// transition. Doing it by hand set `annotationsSuspended = false` and then
    /// called the private no-arg `refreshViewsNow()`, which fails CLOSED (orders
    /// every window out) while `annotationsSuspensionGeneration` is still nil --
    /// so a caller arriving before the first durable generation was applied
    /// would be told "resumed" while every overlay stayed off screen. Reusing
    /// the one real implementation makes that divergence unrepresentable.
    @discardableResult
    public func setAnnotationsSuspended(_ suspended: Bool) -> Bool {
        MainThread.sync {
            setAnnotationsSuspended(suspended, generation: annotationsSuspensionGeneration ?? 0)
        }
    }

    /// Applies the only authoritative presentation decision: one read from
    /// the durable lease registry.  This is intentionally separate from the
    /// unversioned compatibility method above, which is used only by older
    /// in-process tests.  Calls with an older generation are ignored on the
    /// main thread, where window ordering occurs, so queue reordering cannot
    /// resurrect an overlay after a later suspension.
    @discardableResult
    public func setAnnotationsSuspended(_ suspended: Bool, generation: UInt64) -> Bool {
        MainThread.sync {
            if let applied = annotationsSuspensionGeneration, generation < applied {
                return false
            }
            annotationsSuspensionGeneration = generation
            let changed = annotationsSuspended != suspended
            annotationsSuspended = suspended

            if suspended {
                orderAllOverlayWindowsOut()
            } else {
                refreshViewsNow()
            }

            Logger.shared.log(
                "OverlayWindowController: applied durable annotations suspension generation=\(generation) suspended=\(suspended) on \(overlayWindows.count) overlay window reference(s).",
                level: "INFO"
            )
            return changed
        }
    }

    /// Storage/lock failures are deliberately more conservative than ordinary
    /// generation changes: the only safe action is to remove our windows.
    /// This does not advance the durable generation, so the next successful
    /// reconciliation (including one with the same generation) can restore
    /// the registry's actual decision.
    public func forceAnnotationsSuspendedFailClosed() {
        MainThread.sync {
            annotationsSuspended = true
            orderAllOverlayWindowsOut()
            Logger.shared.log("OverlayWindowController: suspension registry unavailable; ordered overlays out fail-closed.", level: "ERROR")
        }
    }

    /// Invalidates any pending auto-revert timer and, if `visible` is true,
    /// starts a fresh one. MAIN-THREAD-ONLY (see `captureAutoRevertTimer`'s
    /// doc comment).
    ///
    /// On fire, this BROADCASTS the revert (`InstanceBroadcast
    /// .postSetCaptureVisible(false)`) rather than flipping `_captureVisible`
    /// locally, matching every other state change in this app ("every
    /// instance owns its own overlay windows" -- see `AppDelegate`'s menu
    /// actions). Claude Desktop runs two `AIChalkboard --mcp` processes per
    /// config entry, each with its own timer started from the same broadcast
    /// that turned capture-debug mode on, so both fire within moments of each
    /// other regardless -- but broadcasting keeps that synchronization exact
    /// instead of relying on the coincidence, and reuses the same code path
    /// (and log line) as a manual toggle-off.
    private func scheduleCaptureAutoRevert(visible: Bool) {
        captureAutoRevertTimer?.invalidate()
        captureAutoRevertTimer = nil

        guard visible else { return }

        let interval = Self.captureAutoRevertInterval
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Logger.shared.log(
                "OverlayWindowController: capture-debug mode auto-reverting to OFF after \(Int(interval))s with no renewal (call set_capture_visible(true) again if still debugging).",
                level: "WARN"
            )
            InstanceBroadcast.shared.postSetCaptureVisible(false)
        }
        // `.common` keeps the timer firing while a menu is tracking or a
        // window is being live-resized, matching the other main-run-loop
        // timers in this app (see `AppDelegate`'s election/watchdog timers).
        RunLoop.main.add(timer, forMode: .common)
        captureAutoRevertTimer = timer
    }

    override private init() {
        super.init()
    }

    public func setup() {
        MainThread.async { [weak self] in
            self?.rebuildOverlayWindows()
            self?.observeScreenChanges()

            // NOTE: `onStoreChanged` is a SINGLE optional closure, not a list of
            // observers, and this is the only place it is ever assigned. Anything
            // else that assigns it would silently clobber the repaint below --
            // which is the only thing that redraws the overlays after a mutation.
            // Compose into this closure instead of reassigning the property.
            AnnotationStore.shared.onStoreChanged = { [weak self] in
                self?.refreshViews()
            }
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        MainThread.async { [weak self] in
            self?.rebuildOverlayWindows()
        }
    }

    /// Tears down and recreates one overlay window/view per `NSScreen.screens`
    /// entry.
    ///
    /// PRIVATE and MAIN-THREAD-ONLY, unlike every sibling method in this
    /// class: it mutates `overlayWindows`/`overlayViews` with no lock and
    /// closes/creates live `NSWindow`s, so calling it off-main would race
    /// AppKit's own main-thread affinity assumptions. Both call sites
    /// (`setup()` and `screenParametersChanged()`) already hop onto main via
    /// `MainThread.async` before calling this, and there is no third caller --
    /// grepped to confirm before narrowing this from `public` to `private`.
    private func rebuildOverlayWindows() {
        // Close existing windows
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
        overlayViews.removeAll()

        let screens = NSScreen.screens
        for (idx, screen) in screens.enumerated() {
            let screenId = getScreenId(screen: screen, index: idx)
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            Logger.shared.log(
                "OverlayWindowController: configuring screen id=\(screenId) name='\(screen.localizedName)' points=\(Int(frame.width))x\(Int(frame.height)) backingScaleFactor=\(scale) physicalPixels=\(Int(round(frame.width * scale)))x\(Int(round(frame.height * scale))).",
                level: "INFO"
            )
            let window = createOverlayWindow(for: screen, screenId: screenId)
            overlayWindows.append(window)
        }

        refreshViews()
    }

    private func createOverlayWindow(for screen: NSScreen, screenId: String) -> NSWindow {
        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // CRASH FIX: `NSWindow.isReleasedWhenClosed` defaults to `true` for
        // windows created programmatically (as opposed to ones unarchived
        // from a nib). `overlayWindows` in this class holds this window via a
        // strong ARC reference, and `rebuildOverlayWindows()` calls
        // `window.close()` on every rebuild (screen configuration changes,
        // e.g. a display is connected/disconnected/sleeps). With the default
        // left in place, `close()` ALSO releases the window at the AppKit
        // level, so the window gets released twice: once by AppKit inside
        // `close()`, and once by ARC when `overlayWindows.removeAll()` drops
        // the array's reference right after. That double-release corrupts
        // the object and crashes later, asynchronously, when AppKit's
        // window-close animation machinery tears itself down -- this is the
        // exact `EXC_BAD_ACCESS` in `objc_release` /
        // `-[_NSWindowTransformAnimation dealloc]` /
        // `CA::Transaction::flush_as_runloop_observer` seen in
        // AIChalkboard-2026-08-06-192840.ips. Setting this to `false` makes
        // ARC (via `overlayWindows`) the window's ONLY owner, so `close()`
        // just orders it out/tears down its AppKit-side state without also
        // releasing it.
        window.isReleasedWhenClosed = false

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = Self.overlayWindowAnimationBehavior

        // Born with whatever the user last requested (default `.none`; see the
        // `desiredSharingType` doc comment for the legacy-sharing caveat).
        // Reading it from the stored value rather than
        // hard-coding `.none` is what makes the setting survive a
        // `rebuildOverlayWindows()` caused by a display being plugged in.
        window.sharingType = desiredSharingType

        // Window level: must render above BOTH the Dock and the menu bar, not
        // just "above normal app windows" -- annotating Dock icons and
        // menu-bar items (Wi-Fi, Control Center, the clock, ...) is a primary
        // use case for this app, and `.floating` loses to both.
        //
        // MEASURED, NOT ASSUMED (a prior version of this comment claimed
        // `.floating` was "above ... fullscreen apps", which is true for
        // fullscreen APP content but says nothing about the Dock/menu bar --
        // that claim was never actually checked against them):
        //
        //   * The Dock's real on-screen window level, read back at runtime via
        //     `CGWindowListCopyWindowInfo` / `kCGWindowLayer` for the process
        //     named "Dock": 20 (matches `kCGDockWindowLevel`, but this was
        //     confirmed empirically rather than trusted from the header).
        //   * The menu bar is TWO separate pieces at TWO separate levels, also
        //     read back the same way: the "Menubar" window owned by
        //     WindowServer sits at level 24 (`kCGMainMenuWindowLevel`), but the
        //     status-item glyphs on the right -- Wi-Fi, battery, clock, every
        //     Control Center extra -- are owned by a SEPARATE "Control Center"
        //     process sitting at level 25 (`kCGStatusWindowLevel`).
        //
        // A standalone probe (borderless bright-color window at a candidate
        // level, `screencapture -x -C`, then a PIL pixel check of exactly the
        // Dock's icon pixels and the menu bar's glyph pixels, not just the
        // background band) measured pass/fail per candidate:
        //
        //     .floating (3)      -- FAIL Dock, FAIL menu bar (today's bug)
        //     .modalPanel (8)    -- FAIL Dock, FAIL menu bar
        //     .mainMenu (24)     -- PASS Dock, FAIL menu bar: beats the
        //                           Menubar window's tinted background (tied
        //                           level, order-of-creation win) but loses
        //                           outright to Control Center's status icons
        //                           AND to the app-menu title text, which sit
        //                           at 25 -- only ~47% of real menu-bar glyph
        //                           pixels were actually covered, so this
        //                           level is NOT reliable despite "passing" a
        //                           naive whole-band pixel-area check.
        //     .statusBar (25)    -- PASS Dock, PASS menu bar (100% of Dock
        //                           icon pixels and 100% of menu-bar glyph
        //                           pixels covered, reproduced across 3
        //                           independent trials). Exactly ties
        //                           Control Center's own level, but AppKit
        //                           orders a newly-front window ahead of
        //                           existing windows at the same level, which
        //                           is why this consistently won in every
        //                           trial.
        //     .popUpMenu (101), CGWindowLevelForKey(.overlayWindow) (102) --
        //                           also PASS both, with a non-tied margin,
        //                           but `.statusBar` is already sufficient and
        //                           the brief is to use the LOWEST level that
        //                           solves the occlusion, not the highest
        //                           available.
        //
        // CHOSEN: `.statusBar` (25) -- the lowest of the above that measured
        // as fully sufficient against both the Dock and the real (glyph-level,
        // not just background-tint) menu bar content. If Control Center ever
        // starts winning that same-level tie in practice (there is no
        // documented guarantee, only the observed AppKit ordering behavior),
        // the next step up is `.popUpMenu` (101), which passed with a clean,
        // non-tied margin above every measured piece of system chrome.
        //
        // DO NOT quietly revert this to `.floating` (3) -- that is the
        // regression this comment exists to prevent. `.floating` sits below
        // the Dock (20) and the menu bar (24/25), so annotations placed over
        // either are silently occluded; see the OverlayWindowController.swift
        // change notes for the empirical probe that reproduced this.
        window.level = .statusBar
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        // CRITICAL: Mouse & keyboard input passes 100% straight through to underlying applications
        window.ignoresMouseEvents = true

        let overlayView = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
        overlayView.screenId = screenId
        overlayView.scaleFactor = screen.backingScaleFactor

        window.contentView = overlayView
        overlayViews.append(overlayView)

        window.setFrame(frame, display: true)
        // NOT ordered on screen here. `NSWindow` starts off-screen by
        // construction; the trailing `refreshViews()` call in
        // `rebuildOverlayWindows()` (which runs immediately after every
        // window/view pair for every screen has been appended) is what
        // decides whether THIS window belongs on screen right now, based on
        // whether this screen actually has anything to paint. See
        // `refreshViews()`'s doc comment for why "created" and "on screen"
        // must not be the same thing for this window.

        return window
    }

    /// Single source of truth for "what should currently be painted on
    /// `screenId`" -- shared by `OverlayView.draw(_:)` (what to paint) and
    /// `refreshViews()` (whether the window itself belongs on screen at
    /// all). Keeping one definition is what makes those two questions
    /// impossible to answer inconsistently with each other.
    public func currentlyVisibleAnnotations(forScreenId screenId: String) -> [Annotation] {
        // Suspension is an explicit presentation override. Returning no
        // visible annotations here keeps OverlayView, input-policy diagnostics,
        // and presentation checks truthful while the retained store remains
        // completely unchanged for resume.
        if isAnnotationsSuspended {
            return []
        }
        if isCaptureVisible {
            return AnnotationStore.shared.getForScreen(screenId)
        }
        return AnnotationStore.shared.getForScreen(screenId, visibleForApp: ActiveAppTracker.shared.currentAppId)
    }

    /// Repaints every overlay AND decides, per screen, whether its window
    /// belongs on screen at all.
    ///
    /// WHY THE WINDOW ITSELF MUST BE ORDERED OUT WHEN THERE IS NOTHING TO
    /// PAINT, not merely left on screen and transparent -- this used to
    /// unconditionally `orderFrontRegardless()` every overlay window at
    /// creation and leave it there for the rest of the process's life,
    /// regardless of whether anything was ever drawn:
    ///
    /// `ignoresMouseEvents = true` (set once, at window creation -- see
    /// `createOverlayWindow`) only affects REAL OS mouse-event delivery: the
    /// window server correctly skips this window and hands a genuine click to
    /// whatever is underneath it. It does nothing for a DIFFERENT class of
    /// query -- "which app's window is topmost at this point" -- answered by
    /// walking the on-screen window list (what `CGWindowListCopyWindowInfo`
    /// reports, and almost certainly what any tool doing its own
    /// click-safety/ownership pre-check against an app allowlist is really
    /// asking, since `ignoresMouseEvents` is not exposed by that API at all).
    /// A window is either on that list or it is not; there is no
    /// "on the list but see-through" state to ask for.
    ///
    /// This app's overlay windows are, by design, full-screen and at
    /// `.statusBar` level specifically so an annotation can sit above the
    /// Dock and the menu bar (see `createOverlayWindow`'s window-level
    /// comment). That means an always-on-screen overlay window is ALWAYS the
    /// topmost thing at every point on every screen -- so a caller doing that
    /// kind of ownership check would conclude every single point on screen
    /// belongs to AI Chalkboard, forever, whether or not an annotation was
    /// ever drawn. That is exactly the bug this fixes: computer-use refused
    /// to click ANYWHERE, including with zero annotations on screen, because
    /// the overlay window was on screen (and therefore "topmost everywhere")
    /// even though it was painting nothing.
    ///
    /// Ordering the window fully off screen when `currentlyVisibleAnnotations`
    /// is empty removes it from that window list too, so an idle AI
    /// Chalkboard -- the common case between draws -- is invisible to that
    /// kind of check, not just harmlessly click-through to it. This does NOT
    /// fix the remaining case where an annotation genuinely IS on screen: the
    /// window still has to cover the full screen to be positionable anywhere
    /// on it, so a topmost-window ownership check still finds AI Chalkboard
    /// covering the whole screen, not just the annotated region, for as long
    /// as that annotation is visible. Shrinking the window to each
    /// annotation's bounding box would be a materially bigger redesign (it
    /// would break screen-spanning free-draw paths/images, and every
    /// draw/move/clear would need its own window resize) and is out of scope
    /// here.
    public func refreshViews() {
        MainThread.async { [weak self] in
            self?.refreshViewsNow()
        }
    }

    /// Main-thread half of `refreshViews()`.  Kept separate so
    /// `presentationStatus(for:)` can synchronously settle the app's own
    /// ordering/repaint work before asking WindowServer what it registered.
    /// This is intentionally not public: callers outside this controller must
    /// retain the ordinary asynchronous repaint behaviour.
    private func refreshViewsNow() {
        precondition(Thread.isMainThread, "Overlay window ordering is AppKit-main-thread-only")
        // No state read is sufficient on its own: a concurrent acquire could
        // persist after the read but before `orderFrontRegardless()`.  The
        // coordinator keeps the registry operation lock across the short
        // AppKit closure below, so an acquire cannot cross that gap.  Before
        // launch reconciliation has installed a durable generation we fail
        // closed and never order a newly-created overlay on screen.
        guard annotationsSuspensionGeneration != nil else {
            orderAllOverlayWindowsOut()
            return
        }
        _ = SuspensionLeaseCoordinator.shared.withPresentationPermit { [weak self] permit in
            self?.refreshViewsNow(under: permit)
        }
    }

    /// Runs only from `withPresentationPermit`, while its durable flock is
    /// held.  Keep this limited to immediate AppKit ordering and invalidation:
    /// calling back into the coordinator here would self-contend on flock.
    private func refreshViewsNow(under permit: SuspensionLeaseSnapshot) {
        precondition(Thread.isMainThread, "Overlay window ordering is AppKit-main-thread-only")
        if permit.error != nil || permit.annotationsSuspended {
            // A failed durable read is deliberately indistinguishable from a
            // live lease at presentation time: both leave every local overlay
            // absent from WindowServer ownership scans.
            if permit.error == nil {
                if let applied = annotationsSuspensionGeneration {
                    if permit.generation >= applied {
                        annotationsSuspensionGeneration = permit.generation
                    }
                } else {
                    annotationsSuspensionGeneration = permit.generation
                }
            }
            annotationsSuspended = true
            orderAllOverlayWindowsOut()
            return
        }

        // A permit that is older than the state this process already applied
        // must not resurrect a window. This should be unreachable for a valid
        // registry, but failing closed is the correct response to a replaced
        // or otherwise non-monotonic state file.
        if let applied = annotationsSuspensionGeneration, permit.generation < applied {
            annotationsSuspended = true
            orderAllOverlayWindowsOut()
            return
        }
        annotationsSuspensionGeneration = permit.generation
        annotationsSuspended = false

        for (window, view) in zip(overlayWindows, overlayViews) {
            let hasContent = !currentlyVisibleAnnotations(forScreenId: view.screenId).isEmpty
            if hasContent {
                window.orderFrontRegardless()
            } else {
                window.orderOut(nil)
            }
            view.needsDisplay = true
        }
    }

    private func orderAllOverlayWindowsOut() {
        precondition(Thread.isMainThread, "Overlay window ordering is AppKit-main-thread-only")
        // An externally implemented ownership heuristic can only see an
        // absent overlay when *every* process-local window is fully ordered
        // out. Do this before consulting per-app/capture filters: suspension
        // is an absolute presentation override.
        for (window, view) in zip(overlayWindows, overlayViews) {
            window.orderOut(nil)
            view.needsDisplay = true
        }
    }

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

    public func getScreenId(screen: NSScreen, index: Int) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return String(screenNumber)
        }
        return String(index)
    }

    /// Takes one snapshot of the display layout with a single main-thread hop,
    /// then answers every screen question a single MCP tool call needs to ask
    /// against that same snapshot.
    ///
    /// WHY: the old shape -- `resolveScreenId(_:)` and `getScreenInfos()`
    /// called separately per tool call -- did two independent
    /// `DispatchQueue.main.sync` + `NSScreen.screens` reads per draw call, and
    /// those two reads were not atomic with each other: the display layout can
    /// change in the gap between them (display reconfiguration/wake is
    /// exactly when `NSScreen.screens` can be momentarily empty). In that gap,
    /// `resolveScreenId` would fall back to the synthetic id "0" while a
    /// dimension lookup against the SECOND, now-empty read found nothing and
    /// returned nil -- producing an annotation permanently orphaned on a
    /// screen id no view will ever match, because the id and its dimensions
    /// were resolved against two different readings of the screen list.
    /// Taking one snapshot up front and answering every question against THAT
    /// snapshot closes both the double-hop cost and this TOCTOU gap.
    public func screenSnapshot() -> ScreenSnapshot {
        return MainThread.sync {
            ScreenSnapshot(screens: buildScreenInfos())
        }
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

    private func buildScreenInfos() -> [ScreenInfo] {
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
