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

    /// Raster assets owned by this kind. AnnotationStore releases these when
    /// the containing annotation is removed, replaced, or cleared -- there is
    /// no other way for a raster-owning annotation to go away.
    ///
    /// This deliberately walks batches iteratively. AnnotationStore rejects
    /// retained trees deeper than `maxAnnotationBatchNestingDepth`, but this
    /// helper also runs while rejecting or cleaning up caller-owned candidates;
    /// it must remain safe for arbitrary programmatic input on its own.
    var rasterAssetIds: [String] {
        var assetIDs: [String] = []
        var stack = [self]
        while let kind = stack.popLast() {
            switch kind {
            case .image(let assetId, _, _, _, _, _, _):
                assetIDs.append(assetId)
            case .batch(let items):
                // LIFO stack: reverse before pushing to retain the source
                // order callers received from the former recursive flatMap.
                stack.append(contentsOf: items.reversed().map(\.kind))
            case .vectorPath, .text:
                break
            }
        }
        return assetIDs
    }
}

/// One independently styled element inside a batch annotation. Screen, app,
/// and identity belong to the containing Annotation so a multi-part
/// diagram is added, verified, and cleared atomically under one ID.
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

    /// Bundle identifier of the application this annotation is LINKED to, e.g.
    /// "com.blackmagic-design.DaVinciResolve".
    ///
    /// `nil` means GLOBAL: the annotation is drawn over every application, no
    /// matter which one is frontmost.
    ///
    /// A non-nil value means the annotation is only rendered while that app is
    /// the frontmost application -- switch to another app and it disappears,
    /// switch back and it returns. It is NOT deleted while hidden; it stays in
    /// the store until it is cleared or the process exits. The filter
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

    /// Revision is server-side concurrency state, deliberately excluded from
    /// MCP's durable/public annotation shape. Older list payloads also remain
    /// decodable because this default is used when the key is absent.
    private enum CodingKeys: String, CodingKey {
        case id, screenId, kind, colorHex, label, createdAt
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
        self.appId = appId
        self.appName = appName
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.zIndex = zIndex
        self.revision = revision
    }
}
