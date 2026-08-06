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
    
    override private init() {
        super.init()
    }
    
    public func setup() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildOverlayWindows()
            self?.observeScreenChanges()
            ClearButtonWindowController.shared.setup()
            
            AnnotationStore.shared.onStoreChanged = { [weak self] in
                self?.refreshViews()
                ClearButtonWindowController.shared.updateVisibility()
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
            ClearButtonWindowController.shared.createWindow()
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
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.sharingType = .none
        
        // Window level: Above normal app windows and over fullscreen apps
        window.level = .floating
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
