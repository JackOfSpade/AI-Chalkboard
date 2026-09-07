import Foundation

/// `Sendable` because an annotation's geometry genuinely crosses threads:
/// `AnchorTracker` re-resolves an `.element`-anchored highlight on its own
/// element queue and hands the rebuilt kind back for the store to install,
/// and the store itself is read from the MCP background queue and the
/// main-thread paint path at the same time. The conformance is sound rather
/// than merely asserted: every payload here is an immutable value type
/// (`String`, `Double`, `Bool`, `[Double]`), and the `indirect .batch` case
/// nests only `AnnotationComponent`, which is `Sendable` for the same reason.
/// Without this, `AnchorElementReresolution` was a `Sendable` enum carrying a
/// non-`Sendable` payload -- a warning today and an error in the Swift 6
/// language mode.
public enum AnnotationKind: Codable, Sendable {
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
public struct AnnotationComponent: Codable, Sendable {
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

    /// The identity of the window this annotation follows, or nil for an
    /// unanchored annotation drawn once at its stored coordinates forever
    /// (today's only behavior before anchoring existed). Replaced wholesale,
    /// never mutated in place, by `update_annotation`'s `anchor` argument --
    /// same pattern as every other caller-supplied drawing property.
    public let anchor: AnnotationAnchor?

    /// An adjustment frozen into place by a previous detach or re-anchor,
    /// applied BEFORE the live `anchorProjection` one (see
    /// `effectiveAdjustment`). It changes only on an explicit caller action
    /// (`update_annotation` folding a live adjustment into it), never per
    /// tracker tick, so composing it with the live adjustment every frame
    /// cannot accumulate drift the way repeatedly composing a per-tick delta
    /// onto itself would.
    public let staticAdjustment: AnchorAdjustment

    /// The tracker's latest result for `anchor`, or nil when unanchored or
    /// not yet sampled. Store-managed, like `revision`: no caller sets this
    /// directly, and `AnnotationStore.applyAnchorProjections` is the only
    /// writer. Unlike `revision` this IS caller-meaningful state --
    /// `list_annotations` must surface it -- so it is `var`, not excluded
    /// from `CodingKeys`.
    public var anchorProjection: AnchorProjection?

    /// The display whose backing-pixel space this annotation's ADJUSTED
    /// geometry lives in. This -- not `screenId` -- decides which overlay
    /// window paints it, because an anchored annotation whose window has
    /// moved to another display must now paint there instead of on the
    /// display it was originally drawn on.
    public var effectiveScreenId: String { anchorProjection?.effectiveScreenId ?? screenId }

    /// static ∘ live: `staticAdjustment` applied first, then the tracker's
    /// live `anchorProjection.adjustment` (or `.identity` when there isn't
    /// one) on top. This is the single transform the renderer applies to
    /// every stored coordinate -- see `AnchorAdjustment.concatenating(_:)`'s
    /// doc comment for why this exact order matters.
    public var effectiveAdjustment: AnchorAdjustment {
        staticAdjustment.concatenating(anchorProjection?.adjustment ?? .identity)
    }

    /// False only when this annotation is anchored AND its last known
    /// tracking state is `.hidden` or `.lost`. An anchor with no projection
    /// yet (the tracker has not ticked since the anchor was created)
    /// permits painting: the design contract requires the store's
    /// anchor-creation path to install an identity `.tracking` projection in
    /// the SAME update as the anchor itself, so a "real" anchor is never
    /// observed sitting at `anchorProjection == nil` -- this only reads that
    /// way for a hand-built `Annotation` (e.g. in a test) that skipped that
    /// step, and fails open rather than suppressing painting for a state
    /// this type never actually produces on its own.
    public var anchorPermitsPainting: Bool {
        switch anchorProjection?.state {
        case .some(.hidden), .some(.lost):
            return false
        case .some(.tracking), .none:
            return true
        }
    }

    /// Monotonically assigned by `AnnotationStore` whenever this annotation
    /// is inserted or replaced. It is a compare-and-swap token for in-place
    /// updates, not a user-editable drawing property.
    public var revision: UInt64 = 0

    /// Revision is server-side concurrency state, deliberately excluded from
    /// MCP's durable/public annotation shape. Older list payloads also remain
    /// decodable because this default is used when the key is absent.
    ///
    /// `anchor`, `staticAdjustment`, and `anchorProjection` are the opposite
    /// of `revision`: caller-meaningful anchor state that `list_annotations`
    /// must surface, so they ARE included here despite `anchorProjection`
    /// being store-written rather than caller-supplied. Decoding a payload
    /// from before anchoring existed must still succeed, so `init(from:)`
    /// below decodes all three with an explicit default rather than relying
    /// on `decode(forKey:)`, which would throw on a missing key.
    private enum CodingKeys: String, CodingKey {
        case id, screenId, kind, colorHex, label, createdAt
        case appId, appName, opacity, offsetX, offsetY, zIndex
        case anchor, staticAdjustment, anchorProjection
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
        anchor: AnnotationAnchor? = nil,
        staticAdjustment: AnchorAdjustment = .identity,
        anchorProjection: AnchorProjection? = nil,
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
        self.anchor = anchor
        self.staticAdjustment = staticAdjustment
        self.anchorProjection = anchorProjection
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        screenId = try container.decode(String.self, forKey: .screenId)
        kind = try container.decode(AnnotationKind.self, forKey: .kind)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appId = try container.decodeIfPresent(String.self, forKey: .appId)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        opacity = try container.decode(Double.self, forKey: .opacity)
        offsetX = try container.decode(Double.self, forKey: .offsetX)
        offsetY = try container.decode(Double.self, forKey: .offsetY)
        zIndex = try container.decode(Int.self, forKey: .zIndex)
        // All three are optional-with-default on decode so a payload
        // written before anchoring existed keeps decoding unchanged: an
        // absent `anchor`/`anchorProjection` means "unanchored" (nil), and
        // an absent `staticAdjustment` means "no frozen adjustment yet"
        // (`.identity`), exactly the values a freshly created unanchored
        // `Annotation` already carries via `init(...)`'s own defaults.
        anchor = try container.decodeIfPresent(AnnotationAnchor.self, forKey: .anchor)
        staticAdjustment = try container.decodeIfPresent(AnchorAdjustment.self, forKey: .staticAdjustment) ?? .identity
        anchorProjection = try container.decodeIfPresent(AnchorProjection.self, forKey: .anchorProjection)
        // `revision` is deliberately absent from `CodingKeys` (see the
        // comment above it) and keeps its `= 0` property-declaration
        // default here, exactly as it did under the compiler-synthesized
        // initializer this one replaces.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(screenId, forKey: .screenId)
        try container.encode(kind, forKey: .kind)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(appId, forKey: .appId)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(offsetX, forKey: .offsetX)
        try container.encode(offsetY, forKey: .offsetY)
        try container.encode(zIndex, forKey: .zIndex)
        try container.encodeIfPresent(anchor, forKey: .anchor)
        // Always written, even at `.identity`: unlike `revision` this is
        // caller-meaningful state (see the `CodingKeys` comment above), and
        // `offsetX`/`offsetY` set the precedent of always encoding a
        // drawing-placement field even at its default value.
        try container.encode(staticAdjustment, forKey: .staticAdjustment)
        try container.encodeIfPresent(anchorProjection, forKey: .anchorProjection)
    }
}
