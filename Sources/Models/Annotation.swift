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

public struct ColorParser {
    public static func parse(_ colorString: String?) -> NSColor {
        guard let colorString = colorString?.trimmingCharacters(in: .whitespacesAndNewlines), !colorString.isEmpty else {
            return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9) // Default bright red
        }
        
        let lower = colorString.lowercased()
        switch lower {
        case "red": return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        case "green": return NSColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 0.9)
        case "blue": return NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.9)
        case "yellow": return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.9)
        case "orange": return NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.9)
        case "purple": return NSColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 0.9)
        case "pink": return NSColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 0.9)
        case "cyan": return NSColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 0.9)
        case "white": return NSColor(white: 1.0, alpha: 0.9)
        case "black": return NSColor(white: 0.1, alpha: 0.9)
        default: break
        }
        
        var hex = lower
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        // Validate BEFORE trusting Scanner's parse. `scanHexInt64` stops at the
        // first character it can't consume and still reports success with
        // whatever prefix it DID consume -- `intVal` is pre-initialised to 0,
        // so an all-invalid string like "GGGGGG" silently parses to 0 instead
        // of failing. Branching on `hex.count` alone (below) would then treat
        // a garbage string as a well-formed value purely because it happened
        // to have the right length, e.g. "12GG56" is 6 characters and would be
        // read as a legitimate 6-digit RGB value despite only "12" of it ever
        // having been parsed.
        //
        // Requiring every remaining character to be an ASCII hex digit also
        // incidentally rejects a "0x"/"0X" prefix (Scanner's `scanHexInt64`
        // recognizes and skips one): "0xff0000" is 8 characters, which without
        // this check would be misrouted into the 8-digit RGBA branch below
        // reading only "ff0000" -- 'x' is not a hex digit, so it now correctly
        // falls through to the same red fallback other malformed strings get.
        let isPureHexDigits = !hex.isEmpty && hex.allSatisfy { "0123456789abcdef".contains($0) }
        guard isPureHexDigits, [3, 6, 8].contains(hex.count) else {
            return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9) // Invalid colour: same red fallback as wrong-length strings
        }

        var intVal: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&intVal)

        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (intVal >> 8) * 17, (intVal >> 4 & 0xF) * 17, (intVal & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, intVal >> 16, intVal >> 8 & 0xFF, intVal & 0xFF)
        case 8: // ARGB or RGBA (32-bit) -> assume RGBA
            (r, g, b, a) = (intVal >> 24, intVal >> 16 & 0xFF, intVal >> 8 & 0xFF, intVal & 0xFF)
        default:
            return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        }

        return NSColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}
