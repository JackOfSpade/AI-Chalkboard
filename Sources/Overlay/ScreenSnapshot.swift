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

extension OverlayWindowController {
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
