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

    /// Internal so tests and in-process simulations can own isolated stores;
    /// production continues to use `shared`.
    init() {}

    /// Runs `body` with `lock` held, releasing it via `defer` no matter how
    /// `body` returns.
    ///
    /// Every locking method in this class used to pair `lock.lock()` /
    /// `lock.unlock()` by hand, which deadlocks the whole process the moment
    /// any future edit adds an early `return` between the two calls. Routing
    /// everything through here makes that class of bug impossible instead of
    /// merely avoided-by-convention.
    ///
    /// Deliberately does NOT call `notifyChange()` -- callers that need to
    /// notify must do so AFTER `withLock` returns, once the lock is released.
    /// `notifyChange()` hops to the main thread and invokes
    /// `onStoreChanged`, which repaints; doing that while still holding
    /// `lock` would risk a reentrant call back into this store (e.g. from a
    /// repaint that reads annotations) blocking on a lock this same thread
    /// already holds.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Appends `annotation`, evicting the oldest stored annotations first if
    /// doing so would exceed `DrawingDefaults.maxStoredAnnotations`.
    ///
    /// Returns the number of annotations evicted to enforce that cap (0 in
    /// the normal case) so the MCP layer can report it back to the caller.
    ///
    /// WHY THE CAP EXISTS: five of the six draw tools deliberately create
    /// annotations that persist until explicitly cleared -- that is
    /// documented design intent (see `ClearScope`'s doc comment) and this
    /// change does not touch it -- but this is a long-lived background
    /// server, so a caller that never passes `duration_seconds` and never
    /// calls `clear` grows this store without bound, and every repaint's
    /// O(n) filter (`getForScreen`) gets steadily more expensive as it does.
    /// Eviction is reported rather than silent -- logged at WARN and handed
    /// back as a return value -- specifically so a runaway caller is visible
    /// instead of just slowly degrading.
    @discardableResult
    public func add(_ annotation: Annotation, durationSeconds: Double? = nil) -> Int {
        let evicted: Int = withLock {
            annotations.append(annotation)
            let overflow = annotations.count - DrawingDefaults.maxStoredAnnotations
            guard overflow > 0 else { return 0 }
            annotations.removeFirst(overflow)
            return overflow
        }

        if evicted > 0 {
            Logger.shared.log(
                "AnnotationStore: exceeded maxStoredAnnotations cap (\(DrawingDefaults.maxStoredAnnotations)); evicted \(evicted) oldest annotation(s) to stay under it.",
                level: "WARN"
            )
        }

        notifyChange()

        if let duration = durationSeconds, duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                _ = self?.remove(id: annotation.id)
            }
        }

        return evicted
    }

    public func remove(id: String) -> Bool {
        let removed: Bool = withLock {
            let initialCount = annotations.count
            annotations.removeAll { $0.id == id }
            return annotations.count < initialCount
        }
        if removed {
            notifyChange()
        }
        return removed
    }

    @discardableResult
    public func clearAll() -> Int {
        let removed: Int = withLock {
            let count = annotations.count
            annotations.removeAll()
            return count
        }
        if removed > 0 {
            notifyChange()
        }
        return removed
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
        let removed: Int = withLock {
            let before = annotations.count
            annotations.removeAll { $0.appId == nil || $0.appId == activeAppId }
            return before - annotations.count
        }
        if removed > 0 {
            notifyChange()
        }
        return removed
    }

    public func getAll() -> [Annotation] {
        return withLock { annotations }
    }

    /// Every annotation on `screenId`, with NO per-app filtering.
    ///
    /// Its one caller is `OverlayView.draw(_:)` while capture visibility is ON:
    /// that debug mode must render everything, because the app whose
    /// annotations are being verified is by definition NOT the frontmost one at
    /// the moment Claude takes the screenshot. Filtering here would prevent the
    /// overlay from drawing them even on compatible capture paths. Normal
    /// painting uses `getForScreen(_:visibleForApp:)`.
    public func getForScreen(_ screenId: String) -> [Annotation] {
        return withLock { annotations.filter { $0.screenId == screenId } }
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
        return withLock {
            annotations.filter { annotation in
                guard annotation.screenId == screenId else { return false }
                guard let annotationAppId = annotation.appId else { return true } // global
                return annotationAppId == activeAppId
            }
        }
    }

    /// Notifies `onStoreChanged`, always via `MainThread.enqueue` -- NOT
    /// `MainThread.async`.
    ///
    /// The difference matters here specifically: `MainThread.async` runs
    /// inline when already on the main thread, but every mutating method
    /// above (`add`, `remove`, `clearAll`, `clearVisible`) can itself be
    /// called FROM the main thread (e.g. the status-bar menu's "Clear"
    /// action), and `onStoreChanged` repaints the overlay. Running that
    /// repaint inline, re-entrantly, from inside the very call stack that is
    /// still mutating `annotations` is exactly what `enqueue`'s unconditional
    /// hop avoids: it always schedules the repaint as a NEW main-thread turn,
    /// after the mutating call has fully returned, never nested inside it.
    private func notifyChange() {
        MainThread.enqueue { [weak self] in
            self?.onStoreChanged?()
        }
    }
}
