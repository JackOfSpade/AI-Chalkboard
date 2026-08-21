import Foundation
import AppKit

public enum AnnotationKind: Codable {
    case vectorPath(
        data: String,
        strokeColorHex: String?,
        strokeWidth: Double,
        strokeOpacity: Double,
        fillColorHex: String?,
        fillOpacity: Double,
        dash: [Double],
        usesEvenOddFillRule: Bool,
        coordinateScaleX: Double,
        coordinateScaleY: Double
    )
    case image(
        assetId: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        rotationDegrees: Double,
        opacity: Double
    )
    case text(
        text: String,
        x: Double,
        y: Double,
        fontSize: Double,
        textColorHex: String,
        backgroundColorHex: String?,
        backgroundOpacity: Double,
        paddingPx: Double,
        opacity: Double
    )
    indirect case batch(items: [AnnotationComponent])

    /// Stable, flat discriminator for MCP clients. Swift's synthesized Codable
    /// representation nests the case name under `kind` (for example
    /// `{"kind":{"vectorPath":...}}`), which is useful for round-tripping but
    /// awkward for clients that only need to branch on the primitive type.
    var typeName: String {
        switch self {
        case .vectorPath: return "path"
        case .image: return "image"
        case .text: return "text"
        case .batch: return "batch"
        }
    }

    /// Raster assets recursively owned by this kind. AnnotationStore releases
    /// these when the containing annotation expires, is cleared, or is evicted.
    var rasterAssetIds: [String] {
        switch self {
        case .image(let assetId, _, _, _, _, _, _):
            return [assetId]
        case .batch(let items):
            return items.flatMap { $0.kind.rasterAssetIds }
        default:
            return []
        }
    }
}

/// One independently styled element inside a batch annotation. Screen, app,
/// lifetime, and identity belong to the containing Annotation so a multi-part
/// diagram is added, verified, expired, and cleared atomically under one ID.
public struct AnnotationComponent: Codable {
    public let kind: AnnotationKind
    public let colorHex: String
    public let label: String?

    public init(kind: AnnotationKind, colorHex: String = "#FF0000", label: String? = nil) {
        self.kind = kind
        self.colorHex = colorHex
        self.label = label
    }
}

public struct Annotation: Identifiable, Codable {
    public let id: String
    public let screenId: String
    public let kind: AnnotationKind
    public let colorHex: String
    public let label: String?
    public let createdAt: Date

    /// Absolute expiry time for temporary annotations. `nil` means the
    /// annotation persists until it is explicitly cleared or evicted.
    ///
    /// This belongs on the model (rather than existing only as an anonymous
    /// `asyncAfter` closure in AnnotationStore) so `list_annotations` can tell
    /// MCP callers whether a supposedly missing annotation simply expired.
    public var expiresAt: Date?

    /// Bundle identifier of the application this annotation is LINKED to, e.g.
    /// "com.blackmagic-design.DaVinciResolve".
    ///
    /// `nil` means GLOBAL: the annotation is drawn over every application, no
    /// matter which one is frontmost.
    ///
    /// A non-nil value means the annotation is only rendered while that app is
    /// the frontmost application -- switch to another app and it disappears,
    /// switch back and it returns. It is NOT deleted while hidden; it stays in
    /// the store until it expires, is cleared, or the process exits. The filter
    /// lives in `AnnotationStore.getForScreen(_:visibleForApp:)`, which
    /// `OverlayView.draw(_:)` calls with `ActiveAppTracker.shared.currentAppId`.
    public let appId: String?

    /// Human-readable name of `appId` ("DaVinci Resolve") captured at creation
    /// time. It is nil when a non-running app was targeted by bundle id because
    /// `NSWorkspace.runningApplications` has no display name to resolve then.
    /// Once captured it remains readable after that app quits.
    public let appName: String?

    /// An annotation-wide, multiplicative alpha.  Keeping this on the
    /// container lets `update_annotation` fade any primitive (including a
    /// complete batch) without rebuilding its media payload.
    public let opacity: Double

    /// Backing-pixel translation applied to every primitive in this
    /// annotation.  It is deliberately stored separately from individual
    /// geometry so a path, image, text item, or complete batch can move in
    /// place while retaining its stable annotation id.
    public let offsetX: Double
    public let offsetY: Double

    /// Higher annotations are painted later. Ties retain store insertion
    /// order, making the default zero backward compatible.
    public let zIndex: Int

    /// Monotonically assigned by `AnnotationStore` whenever this annotation
    /// is inserted or replaced. It is a compare-and-swap token for in-place
    /// updates, not a user-editable drawing property.
    public var revision: UInt64 = 0

    /// The same deadline as `expiresAt`, expressed on the MONOTONIC clock
    /// (`ProcessInfo.processInfo.systemUptime`) instead of the wall clock.
    ///
    /// WHY BOTH EXIST: `expiresAt` is what MCP callers see -- `list_annotations`
    /// reports it as an RFC 3339 timestamp, which only a wall-clock date can
    /// express. But deciding whether an annotation is still live must NOT
    /// depend on the wall clock, because that clock can jump: an NTP
    /// correction or a user changing the system time would make live
    /// annotations vanish from every read (or linger past their duration)
    /// even though the removal timer -- `asyncAfter`, which is monotonic --
    /// had not fired. That split is exactly the hazard
    /// `SuspensionLeaseCoordinator` already avoids by keeping lease deadlines
    /// on `systemUptime` (see its `expiresAtUptime`); annotations now agree
    /// with it.
    ///
    /// So: monotonic for DECISIONS, wall clock for REPORTING.
    ///
    /// Deliberately excluded from `CodingKeys`, like `revision` above: it is
    /// process-local state (uptime is meaningless across processes and
    /// reboots), and keeping it off the wire leaves the public annotation
    /// shape unchanged. A decoded annotation therefore has `nil` here and
    /// falls back to the wall-clock comparison, which is exactly the previous
    /// behaviour.
    public var expiresAtUptime: Double?

    /// Whether this annotation's deadline has elapsed.
    ///
    /// Prefers the monotonic deadline and falls back to the wall clock only
    /// when it is absent. Every liveness check in the store routes through
    /// here rather than re-deriving the comparison -- it was open-coded as
    /// `expiresAt.map { $0 <= now } ?? false` in sixteen places, which is how
    /// the clock-source inconsistency went unnoticed.
    public func hasExpired(now: Date, uptime: Double) -> Bool {
        if let deadline = expiresAtUptime { return deadline <= uptime }
        return expiresAt.map { $0 <= now } ?? false
    }

    /// Seconds until this annotation expires, or nil when it persists.
    /// Monotonic when available, for the same reason as `hasExpired`.
    public func remainingSeconds(now: Date, uptime: Double) -> Double? {
        if let deadline = expiresAtUptime { return max(0, deadline - uptime) }
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    /// Revision is server-side concurrency state, deliberately excluded from
    /// MCP's durable/public annotation shape. Older list payloads also remain
    /// decodable because this default is used when the key is absent.
    private enum CodingKeys: String, CodingKey {
        case id, screenId, kind, colorHex, label, createdAt, expiresAt
        case appId, appName, opacity, offsetX, offsetY, zIndex
    }

    public init(
        id: String = UUID().uuidString,
        screenId: String,
        kind: AnnotationKind,
        colorHex: String = "#FF0000",
        label: String? = nil,
        appId: String? = nil,
        appName: String? = nil,
        expiresAt: Date? = nil,
        opacity: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0,
        zIndex: Int = 0,
        revision: UInt64 = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.screenId = screenId
        self.kind = kind
        self.colorHex = colorHex
        self.label = label
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.appId = appId
        self.appName = appName
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.zIndex = zIndex
        self.revision = revision
    }
}
