import Foundation
import AppKit

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

    public func getAll() -> [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return annotations
    }

    public func getForScreen(_ screenId: String) -> [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return annotations.filter { $0.screenId == screenId }
    }

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onStoreChanged?()
        }
    }
}
