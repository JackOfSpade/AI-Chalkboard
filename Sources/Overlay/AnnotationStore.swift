import Foundation
import AppKit

/// How wide a "clear" reaches.
///
/// WHY `.active` IS THE DEFAULT everywhere (the MCP `clear` tool, the status
/// menu's first item): annotations are now per-app, so the store routinely
/// holds drawings for apps that are not on screen right now -- notes left on
/// DaVinci Resolve while the user is reading a Terminal window. A blanket
/// "clear everything" as the default would silently destroy work the user
/// cannot even see, with no undo, every time they only meant "get this off my
/// current screen". Defaulting to `.active` makes the destructive blast radius
/// equal to the visible blast radius: you can only clear what you are looking
/// at. `.all` remains one explicit argument (or one extra menu item) away.
public enum ClearScope: String {
    /// Clear only what is currently VISIBLE: annotations linked to the
    /// frontmost app, plus global (`appId == nil`) ones, which are on screen
    /// over that app too. "Clear what I can see."
    case active
    /// Clear every annotation for every app, visible or not.
    case all
}

public final class AnnotationStore: @unchecked Sendable {
    public static let shared = AnnotationStore()
    
    private let lock = NSLock()
    private var annotations: [Annotation] = []
    
    public var onStoreChanged: (() -> Void)?

    private init() {}

    public func add(_ annotation: Annotation, durationSeconds: Double? = nil) {
        lock.lock()
        annotations.append(annotation)
        lock.unlock()
        notifyChange()
        
        if let duration = durationSeconds, duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                _ = self?.remove(id: annotation.id)
            }
        }
    }

    public func remove(id: String) -> Bool {
        lock.lock()
        let initialCount = annotations.count
        annotations.removeAll { $0.id == id }
        let removed = annotations.count < initialCount
        lock.unlock()
        if removed {
            notifyChange()
        }
        return removed
    }

    public func clearAll() {
        lock.lock()
        annotations.removeAll()
        lock.unlock()
        notifyChange()
    }

    /// Removes exactly the annotations that are currently VISIBLE over
    /// `activeAppId`: the ones linked to it, plus the global ones (`appId ==
    /// nil`), which are drawn over every app and are therefore on screen too.
    ///
    /// The predicate is deliberately identical to
    /// `getForScreen(_:visibleForApp:)`'s, minus the screen filter -- "clear"
    /// removes what the user can see, on every screen. Anything linked to a
    /// DIFFERENT app is left untouched: that is the whole point of scoping.
    ///
    /// Returns the number of annotations removed, for the tool/menu log line.
    @discardableResult
    public func clearVisible(forApp activeAppId: String?) -> Int {
        lock.lock()
        let before = annotations.count
        annotations.removeAll { $0.appId == nil || $0.appId == activeAppId }
        let removed = before - annotations.count
        lock.unlock()
        if removed > 0 {
            notifyChange()
        }
        return removed
    }

    public func getAll() -> [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return annotations
    }

    /// Every annotation on `screenId`, with NO per-app filtering.
    ///
    /// Its one caller is `OverlayView.draw(_:)` while capture visibility is ON:
    /// that debug mode must render everything, because the app whose
    /// annotations are being verified is by definition NOT the frontmost one at
    /// the moment Claude takes the screenshot, and filtering would hand back an
    /// empty capture. Normal painting uses `getForScreen(_:visibleForApp:)`.
    public func getForScreen(_ screenId: String) -> [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return annotations.filter { $0.screenId == screenId }
    }

    /// The annotations that should actually be painted on `screenId` right now:
    /// those on that screen AND (global OR linked to `activeAppId`).
    ///
    /// This is the single definition of "visible". `OverlayView.draw(_:)` calls
    /// it with the CURRENT frontmost app -- never the untagged-draw fallback --
    /// because display must follow what is genuinely on screen this instant,
    /// whereas the fallback is a guess about what the user *meant* when they
    /// asked Claude to draw.
    ///
    /// A `nil` `activeAppId` (nothing frontmost is known yet) shows only the
    /// global annotations, never everything: showing every app's annotations at
    /// once would be worse than showing none.
    public func getForScreen(_ screenId: String, visibleForApp activeAppId: String?) -> [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return annotations.filter { annotation in
            guard annotation.screenId == screenId else { return false }
            guard let annotationAppId = annotation.appId else { return true } // global
            return annotationAppId == activeAppId
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onStoreChanged?()
        }
    }
}
