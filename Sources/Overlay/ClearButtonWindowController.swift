import Foundation
import AppKit

public final class ClearButtonWindowController: NSObject {
    public static let shared = ClearButtonWindowController()
    
    private var window: NSWindow?
    private var view: ClearButtonView?
    
    override private init() {
        super.init()
    }
    
    public func setup() {
        DispatchQueue.main.async { [weak self] in
            self?.createWindow()
        }
    }
    
    public func createWindow() {
        if window != nil {
            window?.orderOut(nil)
            window?.close()
            window = nil
        }
        
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        
        let width: CGFloat = 170.0
        let height: CGFloat = 40.0
        let paddingRight: CGFloat = 24.0
        let paddingBottom: CGFloat = 24.0
        
        let windowFrame = NSRect(
            x: screenFrame.maxX - width - paddingRight,
            y: screenFrame.minY + paddingBottom,
            width: width,
            height: height
        )
        
        let win = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.sharingType = .none
        win.level = .floating
        win.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        
        // Interactive window for Clear/Quit controls
        win.ignoresMouseEvents = false
        
        let btnView = ClearButtonView(frame: NSRect(origin: .zero, size: windowFrame.size))
        win.contentView = btnView
        self.view = btnView
        self.window = win
        
        updateVisibility()
    }
    
    public func updateVisibility() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let hasAnnotations = !AnnotationStore.shared.getAll().isEmpty
            if hasAnnotations {
                self.window?.orderFrontRegardless()
                self.view?.needsDisplay = true
                Logger.shared.log("ClearButtonWindow ordered front (annotations active)")
            } else {
                self.window?.orderOut(nil)
                Logger.shared.log("ClearButtonWindow ordered out (no annotations)")
            }
        }
    }
}

public final class ClearButtonView: NSView {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }
    
    private func getClearRect() -> CGRect {
        return CGRect(x: 0, y: 0, width: 105, height: bounds.height)
    }
    
    private func getQuitRect() -> CGRect {
        return CGRect(x: 110, y: 0, width: 55, height: bounds.height)
    }
    
    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        
        let clearFrame = getClearRect()
        let quitFrame = getQuitRect()
        
        // Render Clear Button Pill
        let clearPath = CGPath(roundedRect: clearFrame, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.setFillColor(NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.92).cgColor)
        context.addPath(clearPath)
        context.fillPath()
        
        context.setStrokeColor(NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.25, alpha: 0.90).cgColor)
        context.setLineWidth(1.5)
        context.addPath(clearPath)
        context.strokePath()
        
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let clearText = "🗑️ Clear"
        let clearSize = (clearText as NSString).size(withAttributes: textAttrs)
        let clearTextRect = CGRect(
            x: clearFrame.origin.x + (clearFrame.width - clearSize.width) / 2,
            y: clearFrame.origin.y + (clearFrame.height - clearSize.height) / 2,
            width: clearSize.width,
            height: clearSize.height
        )
        (clearText as NSString).draw(in: clearTextRect, withAttributes: textAttrs)
        
        // Render Quit Button Pill
        let quitPath = CGPath(roundedRect: quitFrame, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.setFillColor(NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 0.92).cgColor)
        context.addPath(quitPath)
        context.fillPath()
        
        context.setStrokeColor(NSColor(white: 0.6, alpha: 0.8).cgColor)
        context.setLineWidth(1.5)
        context.addPath(quitPath)
        context.strokePath()
        
        let quitText = "❌ Quit"
        let quitSize = (quitText as NSString).size(withAttributes: textAttrs)
        let quitTextRect = CGRect(
            x: quitFrame.origin.x + (quitFrame.width - quitSize.width) / 2,
            y: quitFrame.origin.y + (quitFrame.height - quitSize.height) / 2,
            width: quitSize.width,
            height: quitSize.height
        )
        (quitText as NSString).draw(in: quitTextRect, withAttributes: textAttrs)
    }
    
    override public func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if getClearRect().contains(location) {
            Logger.shared.log("Clear button clicked in ClearButtonWindow")
            AnnotationStore.shared.clearAll()
        } else if getQuitRect().contains(location) {
            Logger.shared.log("Quit button clicked in ClearButtonWindow. Terminating app...")
            NSApp.terminate(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}
