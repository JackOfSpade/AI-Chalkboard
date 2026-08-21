import Foundation
import AppKit

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
    ///
    /// INVARIANT -- THE TWO ARRAYS ARE INDEX-ALIGNED: `overlayWindows[i]` is
    /// the window whose `contentView` is `overlayViews[i]`, and both describe
    /// the same display. Consumers rely on this directly: `presentationStatus`
    /// finds an index by matching `overlayViews[i].screenId` and then reads
    /// `overlayWindows[i]`, and `overlayInputPolicySnapshot` `zip`s the pair.
    /// A window appended without its view (or in a different order) would
    /// silently report one display's window under another display's id, so
    /// `rebuildOverlayWindows()` is the ONLY place that appends, and it
    /// appends both halves together.
    // internal (not private): OverlayWindowController+Presentation.swift and
    // OverlayWindowController+Diagnostics.swift read and mutate these arrays.
    var overlayWindows: [NSWindow] = []
    var overlayViews: [OverlayView] = []

    /// MAIN-THREAD-ONLY. Suspension is deliberately presentation state, not
    /// store state: annotations, their stable IDs, creation dates, and TTLs
    /// remain untouched so resume can make the exact still-live set visible
    /// again. Every mutation goes through `setAnnotationsSuspended(_:)`, which
    /// synchronously hops to AppKit's main thread before acknowledging an MCP
    /// request or a broadcast.
    // Fail closed until `SuspensionLeaseCoordinator.bootstrapAndReconcile()`
    // synchronously reads the shared lease registry during launch. A new MCP
    // process must never flash an overlay while another process owns a lease.
    // internal (not private): read/written from OverlayWindowController+Presentation.swift
    // and OverlayWindowController+Diagnostics.swift.
    var annotationsSuspended = true

    /// The durable suspension-registry generation which produced the current
    /// presentation decision.  `nil` means this process has not completed its
    /// startup reconciliation yet.  Keeping the generation beside the AppKit
    /// state is important: two background reconciliations can reach the main
    /// queue in the opposite order, and an older resume must never order a
    /// newer suspension back on screen.
    // internal (not private): OverlayWindowController+Presentation.swift reads
    // and mutates this generation as part of the suspension state machine.
    var annotationsSuspensionGeneration: UInt64?

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
    // internal (not private): OverlayWindowController+Presentation.swift
    // (isCaptureVisible, setCaptureVisible) locks/reads this pair directly.
    let captureLock = NSLock()
    var _captureVisible = false

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
    // internal (not private): OverlayWindowController+Presentation.swift's
    // scheduleCaptureAutoRevert(visible:) invalidates/replaces this timer.
    var captureAutoRevertTimer: Timer?

    /// Single optional observer, invoked on the main thread whenever
    /// `isCaptureVisible` actually changes (not on a same-value renewal).
    /// Exists so `AppDelegate` can keep the status-bar icon's "debug mode is
    /// on" indicator in sync without polling. A single slot, not a list, for
    /// the same reason as `AnnotationStore.onStoreChanged`: there is exactly
    /// one process-wide subscriber (this process's `AppDelegate`), so a list
    /// would be unused generality.
    public var onCaptureVisibleChanged: ((Bool) -> Void)?

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
            // Both halves are appended here, together, so the index-alignment
            // invariant documented on the arrays is visible in one place.
            let pair = createOverlayWindow(for: screen, screenId: screenId)
            overlayWindows.append(pair.window)
            overlayViews.append(pair.view)
        }

        refreshViews()
    }

    /// Builds one overlay window and its content view for a single display.
    ///
    /// Deliberately returns BOTH halves and registers neither: this function
    /// used to append the view to `overlayViews` itself while its caller
    /// appended the window to `overlayWindows`, which split the arrays'
    /// index-alignment invariant across two functions where neither one could
    /// be read as upholding it. Registration is the caller's job; this is a
    /// pure factory.
    private func createOverlayWindow(for screen: NSScreen, screenId: String) -> (window: NSWindow, view: OverlayView) {
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

        window.setFrame(frame, display: true)
        // NOT ordered on screen here. `NSWindow` starts off-screen by
        // construction; the trailing `refreshViews()` call in
        // `rebuildOverlayWindows()` (which runs immediately after every
        // window/view pair for every screen has been appended) is what
        // decides whether THIS window belongs on screen right now, based on
        // whether this screen actually has anything to paint. See
        // `refreshViews()`'s doc comment for why "created" and "on screen"
        // must not be the same thing for this window.

        return (window: window, view: overlayView)
    }
}
