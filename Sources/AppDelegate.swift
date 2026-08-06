import Foundation
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Show icon in macOS Dock so user can right-click -> Quit
        NSApp.setActivationPolicy(.regular)
        
        setupStatusMenu()
        OverlayWindowController.shared.setup()
        MCPServer.shared.start()
        
        MCPServer.shared.log("AI Chalkboard background agent initialized.")
    }

    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "AI Chalkboard Overlay")
            } else {
                button.title = "🎨"
            }
            button.toolTip = "AI Chalkboard (MCP Overlay Agent)"
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Clear All Annotations", action: #selector(clearAllAnnotations), keyEquivalent: "k"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit AI Chalkboard", action: #selector(quitApp), keyEquivalent: "q"))
        
        for item in menu.items {
            item.target = self
        }
        
        statusItem?.menu = menu
    }

    @objc private func clearAllAnnotations() {
        AnnotationStore.shared.clearAll()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
