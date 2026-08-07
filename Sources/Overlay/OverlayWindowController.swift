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

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var windowsByScreenId: [String: NSWindow] = [:]
    private var viewsByScreenId: [String: OverlayView] = [:]

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
    /// the window dictionaries above.
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

        onMain { [weak self] in
            guard let self = self else { return }
            let sharingType: NSWindow.SharingType = visible ? .readOnly : .none
            // `windowsByScreenId` holds each window twice (display id + index
            // alias), so some windows get assigned twice here. Assigning the
            // same value twice is a no-op.
            for window in self.windowsByScreenId.values {
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
                "OverlayWindowController: capture-debug request set to \(visible) (sharingType = \(visible ? ".readOnly" : ".none")) on \(self.windowsByScreenId.count) window reference(s), applied live without rebuilding. External capture tools retain independent app/window filters, so final inclusion is not guaranteed.",
                level: "INFO"
            )
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    override private init() {
        super.init()
    }
    
    public func setup() {
        DispatchQueue.main.async { [weak self] in
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
        DispatchQueue.main.async { [weak self] in
            self?.rebuildOverlayWindows()
        }
    }
    
    public func rebuildOverlayWindows() {
        // Close existing windows
        for window in windowsByScreenId.values {
            window.orderOut(nil)
            window.close()
        }
        windowsByScreenId.removeAll()
        viewsByScreenId.removeAll()
        
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
            windowsByScreenId[screenId] = window
            
            // Also alias by index string e.g. "0", "1" if screenId is displayID
            let indexStr = String(idx)
            windowsByScreenId[indexStr] = window
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
        // from a nib). `windowsByScreenId` in this class holds this window
        // via a strong ARC reference, and `rebuildOverlayWindows()` calls
        // `window.close()` on every rebuild (screen configuration changes,
        // e.g. a display is connected/disconnected/sleeps). With the default
        // left in place, `close()` ALSO releases the window at the AppKit
        // level, so the window gets released twice: once by AppKit inside
        // `close()`, and once by ARC when `windowsByScreenId.removeAll()`
        // drops the dictionary's reference right after. That double-release
        // corrupts the object and crashes later, asynchronously, when
        // AppKit's window-close animation machinery tears itself down --
        // this is the exact `EXC_BAD_ACCESS` in `objc_release` /
        // `-[_NSWindowTransformAnimation dealloc]` /
        // `CA::Transaction::flush_as_runloop_observer` seen in
        // AIChalkboard-2026-08-06-192840.ips. Setting this to `false` makes
        // ARC (via `windowsByScreenId`) the window's ONLY owner, so `close()`
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
        viewsByScreenId[screenId] = overlayView
        
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        
        return window
    }
    
    public func refreshViews() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for view in self.viewsByScreenId.values {
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
    
    public func getScreenInfos() -> [ScreenInfo] {
        if Thread.isMainThread {
            return getScreenInfosInternal()
        } else {
            var infos: [ScreenInfo] = []
            DispatchQueue.main.sync {
                infos = self.getScreenInfosInternal()
            }
            return infos
        }
    }
    
    private func getScreenInfosInternal() -> [ScreenInfo] {
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
    
    public func resolveScreenId(_ rawId: String?) -> String {
        let screens = getScreenInfos()
        guard let rawId = rawId?.trimmingCharacters(in: .whitespacesAndNewlines), !rawId.isEmpty else {
            // Default to main screen
            return screens.first(where: { $0.isMain })?.id ?? screens.first?.id ?? "0"
        }
        
        // 1. Check if rawId matches an integer index in bounds 0..<screens.count
        if let idx = Int(rawId), idx >= 0 && idx < screens.count {
            return screens[idx].id
        }
        
        // 2. Check if rawId matches exact display ID string
        if let match = screens.first(where: { $0.id == rawId }) {
            return match.id
        }
        
        // Default to main screen
        return screens.first(where: { $0.isMain })?.id ?? screens.first?.id ?? "0"
    }
}
