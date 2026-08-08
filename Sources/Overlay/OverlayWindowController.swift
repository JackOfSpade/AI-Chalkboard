import Foundation
import AppKit

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
}

/// An immutable picture of the display layout, taken once and then used for
/// every screen question a single MCP tool call needs to ask.
///
/// See `OverlayWindowController.screenSnapshot()` for why a single snapshot
/// replaced two separate per-call main-thread reads.
public struct ScreenSnapshot {
    public let screens: [ScreenInfo]

    public var isEmpty: Bool { screens.isEmpty }

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
    public func setCaptureVisible(_ visible: Bool) {
        captureLock.lock()
        let changed = (_captureVisible != visible)
        _captureVisible = visible
        captureLock.unlock()

        guard changed else { return }

        MainThread.async { [weak self] in
            guard let self = self else { return }
            let sharingType: NSWindow.SharingType = visible ? .readOnly : .none
            // `overlayWindows` is a flat array now (one entry per real
            // display), so each window is visited exactly once here --
            // unlike the old `windowsByScreenId` dictionary, which stored
            // every window under both its real CGDirectDisplayID and a
            // positional index alias ("0"/"1"), visiting it twice per pass.
            for window in self.overlayWindows {
                window.sharingType = sharingType
            }

            // REQUIRED, not cosmetic: `OverlayView.draw(_:)` branches on
            // `isCaptureVisible` to decide whether to apply the per-app filter
            // (capture-visible mode renders every annotation so a placement
            // check cannot come back blank -- see that method). Flipping the
            // flag therefore changes what should be on screen even though no
            // annotation was added or removed, and nothing else would repaint:
            // the store did not mutate, so `onStoreChanged` never fires, and an
            // app switch may not happen before the next screenshot. Without
            // this the toggle would appear to do nothing until the user
            // happened to alt-tab. `refreshViews()` only sets `needsDisplay`.
            self.refreshViews()

            Logger.shared.log(
                "OverlayWindowController: capture-debug request set to \(visible) (sharingType = \(visible ? ".readOnly" : ".none")) on \(self.overlayWindows.count) window reference(s), applied live without rebuilding. External capture tools retain independent app/window filters, so final inclusion is not guaranteed.",
                level: "INFO"
            )
        }
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
        window.orderFrontRegardless()

        return window
    }

    public func refreshViews() {
        MainThread.async { [weak self] in
            guard let self = self else { return }
            for view in self.overlayViews {
                view.needsDisplay = true
            }
        }
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

    private func buildScreenInfos() -> [ScreenInfo] {
        var infos: [ScreenInfo] = []
        let screens = NSScreen.screens
        let mainScreen = NSScreen.main

        for (idx, screen) in screens.enumerated() {
            let idStr = getScreenId(screen: screen, index: idx)
            let frame = screen.frame
            let scale = screen.backingScaleFactor

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
                isMain: (screen == mainScreen)
            ))
        }
        return infos
    }
}
