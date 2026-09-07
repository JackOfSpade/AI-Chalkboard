import Foundation

// MARK: - AnchorResizeBehavior

/// How an anchored annotation reacts to its target window changing SIZE. A
/// pure move (no size change) is handled identically by both cases -- the
/// window's new top-left corner is always followed -- so this only decides
/// what happens to the annotation's own extent.
public enum AnchorResizeBehavior: String, Codable, Sendable {
    /// Translate only: follow the window's top-left corner, keep the
    /// annotation's own size unchanged. Right for a drawing that marks a
    /// fixed-size affordance (a button, an icon) that does not itself grow
    /// when its window does.
    case pin
    /// Scale per axis by the window's current-size / reference-size ratio,
    /// then translate. Right for a drawing meant to track a region that
    /// itself grows and shrinks with the window, such as a content-area
    /// outline.
    case scale
}

// MARK: - AnchorMode

/// What kind of thing an anchor tracks. See `AnnotationAnchor.element` for
/// why `.element` carries state that `.window` does not need.
public enum AnchorMode: String, Codable, Sendable {
    /// Geometry follows the target window only. Available to every drawing
    /// tool; needs no state beyond the window target itself.
    case window
    /// Follows the target window like `.window` for immediate feedback, and
    /// additionally re-runs the element resolve once the window's geometry
    /// settles, regenerating the highlight outline around the element's true
    /// reflowed bounds. `highlight_element`-only: no other tool has an
    /// element left to re-resolve after the initial draw.
    case element
}

// MARK: - AnchorAdjustment

/// The axis-aligned scale+translate that maps stored annotation coordinates
/// (screen-local backing pixels on the anchor's reference screen) to the
/// coordinates they should paint at now (screen-local backing pixels on the
/// projection's effective screen).
///
/// Deliberately NOT a general affine like `ChalkTransform`: a window move or
/// resize is axis-aligned by construction (no rotation, no shear), so four
/// numbers carry the whole transform and every annotation kind -- path,
/// image, text -- can apply it to its own coordinates without ever handling
/// a 2x2 matrix. `p' = (p.x * scaleX + translateX, p.y * scaleY + translateY)`.
public struct AnchorAdjustment: Codable, Equatable, Sendable {
    public var scaleX: Double
    public var scaleY: Double
    public var translateX: Double
    public var translateY: Double

    /// The no-op adjustment. Unanchored annotations carry this (as
    /// `Annotation.staticAdjustment`'s default, and implicitly wherever an
    /// `anchorProjection` is absent) so every consumer can apply an
    /// adjustment unconditionally instead of branching on "is this
    /// annotation anchored at all".
    public static let identity = AnchorAdjustment(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0)

    public init(scaleX: Double, scaleY: Double, translateX: Double, translateY: Double) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.translateX = translateX
        self.translateY = translateY
    }

    /// `self` applied FIRST, then `other` -- the same ordering
    /// `ChalkTransform.concatenating(_:)` documents:
    /// `self.concatenating(other).apply(to:)` is equivalent to mapping
    /// through `self` and then through `other` in sequence, not the reverse.
    /// `Annotation.effectiveAdjustment` depends on this exact order to
    /// compose a frozen `staticAdjustment` (whatever the drawing already
    /// looked like after a previous detach/re-anchor, applied first) with
    /// the tracker's live `anchorProjection.adjustment` (applied second, on
    /// top of that) without either one drifting into the other.
    public func concatenating(_ other: AnchorAdjustment) -> AnchorAdjustment {
        AnchorAdjustment(
            scaleX: scaleX * other.scaleX,
            scaleY: scaleY * other.scaleY,
            translateX: translateX * other.scaleX + other.translateX,
            translateY: translateY * other.scaleY + other.translateY
        )
    }

    /// Maps `point` through `(x*scaleX + translateX, y*scaleY + translateY)`.
    public func apply(to point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scaleX + translateX, y: point.y * scaleY + translateY)
    }

    /// Maps `rect` corner-wise: its origin through `apply(to:)`, and its
    /// size scaled per axis. This only stays a well-formed (non-negative
    /// size, already axis-ordered) rect because `scaleX`/`scaleY` are
    /// positive by construction in every adjustment this type actually
    /// produces: `.identity` is `(1, 1, ...)`, and
    /// `mapping(reference:current:behavior:)`'s `.pin` branch hard-codes
    /// scale to 1 while its `.scale` branch divides two positive, finite
    /// sizes (see that function's own guards). A hand-built
    /// `AnchorAdjustment` with a zero or negative scale is a caller
    /// contract this function does not defend against, exactly as
    /// `CGRect`'s own arithmetic does not defend against a negative size.
    public func apply(to rect: CGRect) -> CGRect {
        let origin = apply(to: rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scaleX, height: rect.height * scaleY)
    }

    /// Exact equality against `.identity`, deliberately with no epsilon: the
    /// renderer uses this to keep an unanchored annotation's emitted
    /// geometry bit-for-bit identical to how it rendered before anchoring
    /// existed, which only holds when every field is exactly 1/1/0/0, not
    /// merely close to those values.
    public var isIdentity: Bool { self == .identity }

    /// The adjustment that maps `reference` onto `current` under `behavior`.
    ///
    /// Returns nil when the mapping is not derivable: a non-finite
    /// (NaN or infinite) value anywhere in either rect, or -- for `.scale`
    /// only, since it is the one branch that divides -- a reference
    /// width/height that is zero or negative. Callers MUST leave the
    /// previous adjustment untouched on a nil result rather than falling
    /// back to `.identity`, which would teleport the drawing back to its
    /// raw, un-adjusted stored position instead of holding its last known
    /// good placement (see the design contract's "no drift" invariant).
    public static func mapping(
        reference: CGRect,
        current: CGRect,
        behavior: AnchorResizeBehavior
    ) -> AnchorAdjustment? {
        let components = [
            reference.origin.x, reference.origin.y, reference.size.width, reference.size.height,
            current.origin.x, current.origin.y, current.size.width, current.size.height
        ]
        guard components.allSatisfy({ $0.isFinite }) else { return nil }

        switch behavior {
        case .pin:
            // Pin only ever subtracts origins -- it has no divisor -- so a
            // reference with zero, negative, or otherwise degenerate size
            // (a window frame sampled mid-resize, for instance) is still
            // perfectly mappable. Uses raw `.origin`, not `.minX`/`.minY`,
            // matching the design contract's formula exactly.
            return AnchorAdjustment(
                scaleX: 1,
                scaleY: 1,
                translateX: current.origin.x - reference.origin.x,
                translateY: current.origin.y - reference.origin.y
            )
        case .scale:
            // Reference width/height are the divisors below, so <= 0 (a
            // window this call would otherwise have to divide by zero, or
            // invert through) is unmappable. This is a stricter guard than
            // the plain finiteness check above: 0 and negative sizes are
            // still finite numbers.
            //
            // Current width/height are the numerators, and are guarded for
            // a DIFFERENT reason: they are not a divisor, so a degenerate
            // value here would not divide-by-zero, but it would still
            // produce a scale of zero (the annotation's geometry collapses
            // to a zero-width/zero-height line -- indistinguishable from
            // "the drawing was cleared" to whoever is looking at it) or
            // negative (the geometry mirrors around the axis, contradicting
            // `apply(to rect:)`'s documented "scales are positive by
            // construction" assumption). A window frame sampled mid-resize
            // can legitimately be reported this way for one tick; returning
            // nil here means the caller holds the previous, still-correct
            // adjustment instead of momentarily collapsing or mirroring the
            // drawing.
            guard reference.size.width > 0, reference.size.height > 0,
                  current.size.width > 0, current.size.height > 0
            else { return nil }
            let scaleX = current.size.width / reference.size.width
            let scaleY = current.size.height / reference.size.height
            return AnchorAdjustment(
                scaleX: scaleX,
                scaleY: scaleY,
                translateX: current.minX - reference.minX * scaleX,
                translateY: current.minY - reference.minY * scaleY
            )
        }
    }
}

// MARK: - AnchorRect

/// Codable geometry for the anchor fields that get serialised onto the MCP
/// wire (`list_annotations`'s `anchor` object, and the `anchor` object in
/// the `draw_*`/`highlight_element` success payloads).
///
/// Deliberately hand-written rather than reusing `CGRect` directly for
/// those fields, following the exact precedent `PresentationRect` in
/// `Sources/Overlay/PresentationDiagnostics.swift` already set ("Codable
/// geometry used by the presentation diagnostic"): `CGRect`'s synthesized
/// `Codable` form is an unkeyed, nested `[[x, y], [width, height]]` array
/// shape, which would put an undocumented, hard-to-read geometry encoding
/// into a tool response an AI agent has to parse -- and `CGRect` is a
/// `CoreGraphics` type the Windows build cannot lean on for wire shape
/// either way. `AnchorRect` instead always encodes as a flat,
/// self-describing `{"x":.., "y":.., "width":.., "height":..}`.
///
/// This is purely a serialisation shape. All actual geometry MATH --
/// `AnchorAdjustment.mapping(reference:current:behavior:)`,
/// `AnchorAdjustment.apply(to rect:)` -- stays on `CGRect`, which is the
/// right type for in-process computation; `init(_:)` and `cgRect` are the
/// only two crossing points between the two representations.
public struct AnchorRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Captures a `CGRect`'s four raw components as-is -- no standardization
    /// of a negative width/height -- so a round trip through `AnchorRect`
    /// never silently changes what `mapping(reference:current:behavior:)`
    /// would compute from the original rect.
    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - AnchorWindowTarget

/// Identity of one top-level window belonging to another application.
///
/// Deliberately does NOT retain any live window handle (no
/// `NSRunningApplication`, `AXUIElement`, or `HWND`) -- only the plain
/// numbers needed to look one back up through `TargetWindowSampling` -- so
/// `AnnotationAnchor` stays `Codable` and safe to persist and inspect
/// without any platform framework in scope.
public struct AnchorWindowTarget: Codable, Equatable, Sendable {
    /// `pid_t` on macOS, the Win32 process id on Windows, widened to
    /// `Int64` so this one type covers both without `#if os(...)`.
    public let processId: Int64
    /// macOS: `kCGWindowNumber`. Windows: the `HWND` bit pattern, widened to
    /// `UInt64` for the same cross-platform reason as `processId`.
    public let windowId: UInt64
    /// Bundle id (macOS) / executable file name (Windows) recorded at
    /// anchor time. Not used to look the window up -- `windowId` and
    /// `processId` do that -- only to DETECT a recycled id: an OS reuses
    /// small integer process and window ids constantly, so re-sampling
    /// `windowId` and finding it now owned by a different app than `appId`
    /// names means the original window is gone, not merely moved.
    public let appId: String?

    public init(processId: Int64, windowId: UInt64, appId: String? = nil) {
        self.processId = processId
        self.windowId = windowId
        self.appId = appId
    }
}

// MARK: - AnchorElementSpec

/// Everything needed to re-run the element resolve for `.element` mode
/// (regenerate a `highlight_element` outline once the window's geometry
/// settles) without re-issuing the original MCP call.
///
/// Held only in memory, exactly like the rest of the store, and never
/// logged: `label` in particular is caller-supplied, app-specific text, and
/// the design contract's anchor-state logging rule explicitly excludes it
/// (numeric geometry and fixed reason codes only).
public struct AnchorElementSpec: Codable, Equatable, Sendable {
    public let label: String
    public let role: String?
    /// The tool's `match` argument, verbatim (e.g. "exact", "contains",
    /// "fuzzy"). Stored as the raw caller string rather than re-parsed into
    /// an enum here so this type has zero dependency on wherever that enum
    /// lives -- matching `AnnotationKind.vectorPath`'s existing habit of
    /// keeping caller-facing vocabulary (`data`) untyped at rest.
    public let matchMode: String
    public let occurrence: Int
    public let maxNodes: Int
    public let timeoutSeconds: Double
    /// "rect" | "ellipse" | "circle" -- the shape the regenerated highlight
    /// outline is drawn as, kept as a raw string for the same reason as
    /// `matchMode`.
    public let shape: String
    public let paddingPx: Double

    public init(
        label: String,
        role: String? = nil,
        matchMode: String,
        occurrence: Int,
        maxNodes: Int,
        timeoutSeconds: Double,
        shape: String,
        paddingPx: Double
    ) {
        self.label = label
        self.role = role
        self.matchMode = matchMode
        self.occurrence = occurrence
        self.maxNodes = maxNodes
        self.timeoutSeconds = timeoutSeconds
        self.shape = shape
        self.paddingPx = paddingPx
    }
}

// MARK: - AnnotationAnchor

/// The identity of one top-level window an annotation is anchored to,
/// captured at the moment the anchor was created (or last re-baselined).
public struct AnnotationAnchor: Codable, Equatable, Sendable {
    public let mode: AnchorMode
    public let resize: AnchorResizeBehavior
    public let target: AnchorWindowTarget
    /// The target window's frame when the anchor was created (or last
    /// re-baselined by a resize-policy change or an element re-resolve), in
    /// screen-local backing pixels of `referenceScreenId`. Every projection
    /// is computed FROM this frame, never from the previous projection's
    /// frame -- see the design contract's "no drift" invariant: adjustments
    /// are never composed onto themselves per tick. Stored as `AnchorRect`
    /// (see that type's doc comment for why); convert with `.cgRect` before
    /// passing to `AnchorAdjustment.mapping(reference:current:behavior:)`.
    public let referenceWindowFrame: AnchorRect
    public let referenceScreenId: String
    /// Non-nil iff `mode == .element`. `AnchorTracker` is the only reader;
    /// `.window`-mode anchors have nothing to re-resolve.
    public let element: AnchorElementSpec?
    public let createdAt: Date

    public init(
        mode: AnchorMode,
        resize: AnchorResizeBehavior,
        target: AnchorWindowTarget,
        referenceWindowFrame: AnchorRect,
        referenceScreenId: String,
        element: AnchorElementSpec? = nil,
        createdAt: Date = Date()
    ) {
        self.mode = mode
        self.resize = resize
        self.target = target
        self.referenceWindowFrame = referenceWindowFrame
        self.referenceScreenId = referenceScreenId
        self.element = element
        self.createdAt = createdAt
    }
}

// MARK: - AnchorTrackingState

/// The tracker's assessment of whether an anchored annotation's target
/// window can currently be found and painted against.
public enum AnchorTrackingState: String, Codable, Sendable {
    /// Window found and on screen; `AnchorProjection.adjustment` is live and
    /// painting proceeds normally.
    case tracking
    /// Window exists (pid/window id/app identity still match) but is not
    /// currently on screen: minimised, its app is hidden, or it is on
    /// another Space. Painting is suppressed; the annotation is otherwise
    /// untouched and resumes painting the moment the window reappears.
    case hidden
    /// The window is gone, or a re-sampled window id now belongs to a
    /// different pid/app than `AnchorWindowTarget.appId` names (a recycled
    /// id). Painting is suppressed permanently for this anchor -- there is
    /// nothing left to reacquire -- but per the design contract's
    /// "no auto-clear" invariant the annotation itself is never deleted; it
    /// can still be listed, updated, or cleared.
    case lost
}

// MARK: - AnchorProjection

/// The tracker's latest result for one annotation's anchor. Store-managed,
/// like `Annotation.revision` -- callers never construct or edit this
/// directly, only read it.
public struct AnchorProjection: Codable, Equatable, Sendable {
    public let state: AnchorTrackingState
    public let adjustment: AnchorAdjustment
    /// The display whose backing-pixel space the ADJUSTED geometry lives in
    /// -- and therefore which overlay window paints it. Differs from
    /// `AnnotationAnchor.referenceScreenId` exactly when the tracked window
    /// has crossed onto a different display since the anchor was created.
    public let effectiveScreenId: String
    /// Latest sampled window frame, screen-local backing pixels on
    /// `effectiveScreenId`. nil when `state == .lost` -- there is no
    /// current frame left to report. Stored as `AnchorRect`; see that
    /// type's doc comment for why, and convert with `.cgRect` before
    /// passing to `AnchorAdjustment` math.
    public let currentWindowFrame: AnchorRect?
    public let sampledAt: Date
    /// Non-nil only in `.element` mode: why the last element re-resolve did
    /// not happen or did not succeed -- one of "ambiguous", "not_found",
    /// "unavailable", "permission", "timeout". nil means either `.window`
    /// mode (nothing to resolve) or that the geometry is currently
    /// element-exact.
    public let elementResolutionIssue: String?

    public init(
        state: AnchorTrackingState,
        adjustment: AnchorAdjustment,
        effectiveScreenId: String,
        currentWindowFrame: AnchorRect?,
        sampledAt: Date,
        elementResolutionIssue: String? = nil
    ) {
        self.state = state
        self.adjustment = adjustment
        self.effectiveScreenId = effectiveScreenId
        self.currentWindowFrame = currentWindowFrame
        self.sampledAt = sampledAt
        self.elementResolutionIssue = elementResolutionIssue
    }
}
