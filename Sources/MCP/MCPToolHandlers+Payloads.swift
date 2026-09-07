import Foundation

/// What `get_active_app`'s `rawFrontmost` field was actually read from, named
/// per platform.
///
/// Same reasoning as `MCPToolCatalog`'s platform-split prose: these strings are
/// consumed by an AI agent reasoning about how to call the tools, so naming an
/// API the running platform does not have is a correctness problem rather than
/// a wording nit.
#if os(macOS)
private let rawFrontmostSource = "NSWorkspace"
#elseif os(Windows)
private let rawFrontmostSource = "GetForegroundWindow/QueryFullProcessImageNameW"
#endif

extension MCPServer {
    // MARK: - Diagnostic payload builders

    /// `JSONSerialization` cannot encode Swift's `nil`; it needs `NSNull`. And
    /// `optional ?? NSNull()` does not type-check (mismatched operand types), so
    /// this does the widening to `Any` explicitly. Used so that an absent app
    /// link serialises as an explicit JSON `null` -- which is meaningful here
    /// ("global, visible everywhere") -- rather than the key vanishing.
    // internal: called from handleVerifyAnnotation in MCPToolHandlers+Verification.swift.
    func jsonValue(_ value: String?) -> Any {
        guard let value = value else { return NSNull() }
        return value
    }

    /// Same `NSNull`-widening trick as `jsonValue(_ value: String?)` above,
    /// for an optional integer -- `get_overlay_state`'s new `anchorTracking`
    /// object is this file's first caller with an `Int?` that must serialize
    /// as an explicit JSON `null` (rather than an absent key) when there is
    /// no sampling timer running yet, or no sample has completed yet. See
    /// `anchorTrackingJSON(_:)`.
    func jsonValue(_ value: Int?) -> Any {
        guard let value = value else { return NSNull() }
        return value
    }

    /// Encodes a `Codable` value and immediately decodes it back through
    /// `JSONSerialization`, producing plain `[String: Any]`/`[Any]`-shaped
    /// data. Used where an `Encodable` model (`[ScreenInfo]`, an
    /// `Annotation`) needs to be embedded inside a hand-built
    /// `JSONSerialization` payload alongside sibling keys that are not
    /// themselves `Codable` -- `get_screens` and `list_annotations` both did
    /// this exact two-step conversion by hand; this is the one copy.
    // internal: called from handleToolsCall in MCPToolHandlers.swift, handleHighlightElement in
    // MCPToolHandlers+Highlight.swift, and handleVerifyAnnotation in MCPToolHandlers+Verification.swift.
    func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Serializes a `JSONSerialization`-compatible object (built from
    /// `[String: Any]`/`[Any]`/`String`/`Bool`/`NSNumber`/`NSNull`) to a
    /// UTF-8 JSON string. `get_screens`, `list_annotations`, and
    /// `get_active_app` each built and threw away this exact
    /// `data(withJSONObject:)` -> `String(data:encoding:)` pair individually;
    /// this is the one copy.
    // internal: called from handleToolsCall in MCPToolHandlers.swift, sendSuspensionLeaseResult in
    // MCPToolHandlers+Suspension.swift, handleHighlightElement in MCPToolHandlers+Highlight.swift,
    // and handleVerifyAnnotation in MCPToolHandlers+Verification.swift.
    func jsonString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Records precisely how the serialized annotation geometry should be
    /// interpreted. Vector SVG retains the caller's source-space coordinates
    /// plus a renderer scale; text/image positions have already been converted
    /// to backing pixels. Calling all of this `BackingPx` was false for paths.
    // internal: called from handleVerifyAnnotation in MCPToolHandlers+Verification.swift.
    func storedGeometryCoordinateSemantics(_ kind: AnnotationKind) -> [String: Any] {
        switch kind {
        case let .vectorPath(_, _, _, _, _, _, _, _, scaleX, scaleY):
            return [
                "storedCoordinateValues": "SVG source coordinates selected at creation time",
                "rendererScaleToBackingPixels": ["x": scaleX, "y": scaleY],
                "styleDimensions": "backing pixels"
            ]
        case .image:
            return [
                "storedCoordinateValues": "backing pixels",
                "styleDimensions": "backing pixels"
            ]
        case .text:
            return [
                "storedCoordinateValues": "backing pixels",
                "styleDimensions": "backing pixels"
            ]
        case let .batch(items):
            return [
                "storedCoordinateValues": "each item uses its own kind semantics",
                "items": items.map { storedGeometryCoordinateSemantics($0.kind) }
            ]
        }
    }

    /// `list_annotations` is deliberately paged and response-budgeted. A
    /// persistent batch can legally retain megabytes of SVG, so returning every
    /// raw annotation in one MCP text block would otherwise exceed transport
    /// limits even though storage itself is bounded.
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func buildAnnotationListJSON(args: [String: Any]) -> DrawOutcome<String> {
        if args.keys.contains("offset"), MCPArgument.integer(args["offset"]) == nil {
            return .failure("offset must be a non-negative integer when supplied.")
        }
        if args.keys.contains("limit"), MCPArgument.integer(args["limit"]) == nil {
            return .failure("limit must be an integer between 1 and \(DrawingDefaults.maxAnnotationListPageItems) when supplied.")
        }
        let requestedOffset = MCPArgument.integer(args["offset"]) ?? 0
        let requestedLimit = MCPArgument.integer(args["limit"]) ?? DrawingDefaults.maxAnnotationListPageItems
        guard requestedOffset >= 0 else {
            return .failure("offset must be a non-negative integer when supplied.")
        }
        guard requestedLimit >= 1, requestedLimit <= DrawingDefaults.maxAnnotationListPageItems else {
            return .failure("limit must be an integer between 1 and \(DrawingDefaults.maxAnnotationListPageItems) when supplied.")
        }
        let annotations = AnnotationStore.shared.getAll()
        // One paired read, not two property reads: `activeApp.bundleId` and
        // `activeApp.name` are reported together as one app in the response,
        // and every per-annotation visibility decision on this page is computed
        // against this same id. Re-reading the tracker per entry (or once per
        // field) would let one response describe two different frontmost apps.
        let activeApp = ActiveAppTracker.shared.currentApp
        let activeId = activeApp.bundleId
        let captureVisible = OverlayWindowController.shared.isCaptureVisible
        let annotationsSuspended = OverlayWindowController.shared.isAnnotationsSuspended

        // `ActiveAppTracker.displayName(forBundleId:)` is only consulted as a
        // fallback for annotations whose `appName` was never captured at
        // creation time (see `Annotation.appName`'s doc comment), but each
        // call independently hops to the main thread to enumerate
        // `NSWorkspace.runningApplications`. With N such annotations that was
        // N main-thread round trips per `list_annotations` call. This memo
        // resolves each DISTINCT bundle id at most once per call by caching
        // as it goes, rather than changing `ActiveAppTracker` itself.
        var displayNameMemo: [String: String?] = [:]
        func resolvedDisplayName(forBundleId bundleId: String) -> String? {
            if let cached = displayNameMemo[bundleId] { return cached }
            let name = ActiveAppTracker.shared.displayName(forBundleId: bundleId)
            displayNameMemo[bundleId] = name
            return name
        }

        var entries: [[String: Any]] = []
        let start = min(requestedOffset, annotations.count)
        let requestedEnd = min(annotations.count, start + requestedLimit)

        func enrichedEntry(for annotation: Annotation) -> [String: Any]? {
            // Round-tripping through the existing Codable encoding keeps the
            // `kind` payload byte-identical to its existing Codable shape.
            guard var object = jsonObject(annotation) as? [String: Any] else {
                return nil
            }
            // Optionals are omitted entirely by the synthesized encoder, so set
            // them explicitly (JSONSerialization needs NSNull, not nil).
            object["appId"] = jsonValue(annotation.appId)
            object["appName"] = jsonValue(
                annotation.appName ?? annotation.appId.flatMap(resolvedDisplayName(forBundleId:))
            )
            object["type"] = annotation.kind.typeName
            object["scope"] = annotation.appId == nil ? "global" : "app-linked"
            // Replace the raw Codable-encoded `anchor`/`staticAdjustment`/
            // `anchorProjection` keys -- `jsonObject(annotation)` above
            // already emitted all three, in `Annotation`'s own internal
            // storage shape -- with the single flat `anchor` object
            // MCP_SURFACE.md's "Success payload" section specifies, shared
            // byte-for-byte with `draw_*`/`highlight_element`/
            // `update_annotation` via `DrawRequest.anchorResponsePayload`
            // (see that function's own doc comment for why reusing it,
            // rather than re-deriving the same shape here, is what keeps
            // every tool's `anchor` object identically shaped). Unanchored
            // annotations OMIT the key entirely -- never `null`, never a
            // `{"mode":"none"}` placeholder -- so a caller can branch on
            // presence alone. `staticAdjustment` is internal frozen-adjustment
            // bookkeeping with no place in the documented wire contract, so
            // it is dropped rather than left to leak through unexplained.
            object.removeValue(forKey: "staticAdjustment")
            object.removeValue(forKey: "anchorProjection")
            object.removeValue(forKey: "anchor")
            if let anchor = annotation.anchor {
                // A REAL anchor is never observed with a nil projection --
                // see `Annotation.anchorPermitsPainting`'s doc comment -- so
                // this fallback (an identity, just-created-looking
                // projection) is unreachable outside a hand-built
                // annotation; it exists so this function never has to
                // silently drop an anchored annotation's `anchor` key.
                let projection = annotation.anchorProjection ?? AnchorProjection(
                    state: .tracking, adjustment: .identity, effectiveScreenId: annotation.screenId,
                    currentWindowFrame: nil, sampledAt: annotation.createdAt, elementResolutionIssue: nil
                )
                object["anchor"] = DrawRequest.anchorResponsePayload(
                    DrawRequest.DrawAnchorResolution(anchor: anchor, projection: projection)
                )
            }
            // Built from the hoisted page snapshot rather than re-reading
            // OverlayWindowController per entry: this is the same rule
            // verify_annotation reports, so it comes from the one shared
            // implementation instead of a second inline copy that could drift.
            let visibility = AnnotationVisibilityDiagnostic(
                annotationsSuspended: annotationsSuspended,
                captureVisible: captureVisible,
                annotationAppId: annotation.appId,
                activeAppId: activeId,
                anchorPermitsPainting: annotation.anchorPermitsPainting
            )
            object["wouldBeVisibleWithoutSuspension"] = visibility.wouldBeVisibleWithoutSuspension
            object["isVisibleNow"] = visibility.isVisibleNow
            guard let fullEntryText = jsonString(object) else { return nil }
            guard fullEntryText.lengthOfBytes(using: .utf8) <= DrawingDefaults.maxAnnotationListEntryBytes else {
                let geometry = object.removeValue(forKey: "kind")
                let geometryBytes = geometry.flatMap(jsonString)?.lengthOfBytes(using: .utf8) ?? 0
                object["geometryOmitted"] = true
                object["geometryByteCount"] = geometryBytes
                object["geometryNote"] = "Geometry was omitted from this list page to keep the bounded MCP response safe. Use verify_annotation with this ID for a rendered, bounded crop."
                return object
            }
            return object
        }

        func payload(for page: [[String: Any]], nextOffset: Int) -> [String: Any] {
            let hasMore = nextOffset < annotations.count
            return [
                "activeApp": [
                    "bundleId": jsonValue(activeId),
                    "name": jsonValue(activeApp.name)
                ] as [String: Any],
                "captureVisible": captureVisible,
                "annotationsSuspended": annotationsSuspended,
                // `count` remains the number in this response, matching the
                // old field when the entire list fits. `totalCount` exposes
                // the full store for callers that page.
                "count": page.count,
                "totalCount": annotations.count,
                "offset": start,
                "limit": requestedLimit,
                "returnedCount": page.count,
                "nextOffset": hasMore ? nextOffset : NSNull(),
                "truncated": hasMore,
                "annotations": page,
                "note": "With captureVisible=false, an annotation is drawn only when scope='global' or its appId equals activeApp.bundleId. With captureVisible=true, every annotation is drawn for capture-debug placement checks. When annotationsSuspended=true, every retained annotation has isVisibleNow=false because all overlay windows are ordered out; wouldBeVisibleWithoutSuspension reports its normal filter result. External capture filters still decide whether the overlay is included. Annotations persist until explicitly cleared (by annotation_id, by app, or scope='all'); there is no TTL. list_annotations is paged (offset/limit); oversized individual geometry is summarized so this response remains bounded."
            ]
        }

        // NOTE on what this loop still does the expensive way: each iteration
        // below re-serializes the ENTIRE growing `candidate` array through
        // `JSONSerialization` purely to size-check it against
        // maxAnnotationListTextBytes, which is O(n^2) work bounded only by
        // maxAnnotationListPageItems (100). An incremental byte-accounting
        // rewrite that tracks the running serialized size without
        // re-serializing already-included entries was deliberately NOT done
        // here: producing an exact byte count without calling
        // `JSONSerialization` again would mean manually reconstructing its
        // compact-mode output (concatenating each entry's own serialized
        // text with "," separators) and trusting that (a) `JSONSerialization`
        // never inserts incidental whitespace in non-pretty-printed mode and
        // (b) a dictionary with a fixed key set serializes its keys in the
        // same relative order every time within one process run. Both are
        // true in practice, but neither is a documented Foundation contract,
        // and this function is covered by the wire-snapshot fixtures'
        // byte-for-byte pin plus the maxAnnotationListTextBytes cutoff being
        // NON-NEGOTIABLE (same last-included item, same nextOffset). Getting
        // this wrong would be silent and hard to notice by inspection, so
        // the redundant re-serialization stays; only the PROVABLY
        // byte-identical redundancies are removed: reusing the last
        // iteration's own already-computed text instead of recomputing it
        // once more after the loop, and appending to `entries` in place
        // instead of copying the entire growing array every iteration.
        var next = start
        var lastCandidateText: String?
        while next < requestedEnd {
            guard let entry = enrichedEntry(for: annotations[next]) else {
                return .failure("Failed to encode annotation \(annotations[next].id) for list_annotations.")
            }
            // Appended in place and rolled back on overflow, rather than
            // building `entries + [entry]` -- that spelling allocated and
            // copied the whole growing array on EVERY iteration, a second
            // quadratic completely separate from the serialization one
            // discussed above. Rollback keeps the candidate semantics exactly:
            // `entries` contains the failing entry only across the size check
            // itself, and is restored before the loop exits.
            entries.append(entry)
            guard let candidateText = jsonString(payload(for: entries, nextOffset: next + 1)) else {
                return .failure("Failed to encode annotation list.")
            }
            if candidateText.lengthOfBytes(using: .utf8) > DrawingDefaults.maxAnnotationListTextBytes {
                entries.removeLast()
                // One summarized entry is always far below the cap; if even it
                // cannot fit, return a normal tool error rather than handing a
                // potentially oversized payload to the transport layer.
                if entries.isEmpty {
                    return .failure("The requested annotation summary could not fit in the bounded list response.")
                }
                break
            }
            next += 1
            lastCandidateText = candidateText
        }
        // When the loop above ran to completion by exhausting `requestedEnd`
        // (as opposed to exiting early via `break`), `lastCandidateText` was
        // already computed for this EXACT (entries, nextOffset: next) pair on
        // the final iteration -- reuse it instead of re-serializing the same
        // page a second time. `next == requestedEnd` only holds on that
        // normal-exit path: `break` always fires while `next < requestedEnd`
        // still holds, and `next` is never advanced on the failing iteration
        // that triggers it.
        if let lastCandidateText, next == requestedEnd {
            return .success(lastCandidateText)
        }
        guard let text = jsonString(payload(for: entries, nextOffset: next)) else {
            return .failure("Failed to encode annotation list.")
        }
        return .success(text)
    }

    /// The `anchorTracking` object `get_overlay_state` adds to its payload
    /// (see MCP_SURFACE.md's `get_overlay_state` section): a snapshot of
    /// whether window/element tracking is live right now, sourced from
    /// `AnchorTracker.shared.statusSummary()`.
    ///
    /// Pulled out as its own pure function -- rather than left inline in the
    /// `get_overlay_state` case body, which writes straight to stdout via
    /// `sendTextResult` and is therefore not a usable test seam (see
    /// `MCPShapeGeometryTests`' header comment on why `send*`-adjacent code
    /// stays untested directly) -- purely so this exact null-vs-value
    /// serialization is unit-testable without a live MCP round-trip.
    /// `sampleIntervalMs`/`lastSampleAgeMs` must serialize as a real JSON
    /// `null`, not an absent key or the string `"null"`, when no timer is
    /// running or no sample has completed yet -- `jsonValue(_ value: Int?)`
    /// is the one place that widening happens.
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func anchorTrackingJSON(_ status: AnchorTrackerStatus) -> [String: Any] {
        [
            "anchored": status.anchoredCount,
            "tracking": status.trackingCount,
            "hidden": status.hiddenCount,
            "lost": status.lostCount,
            "sampleIntervalMs": jsonValue(status.sampleIntervalMs),
            "lastSampleAgeMs": jsonValue(status.lastSampleAgeMs)
        ]
    }

    /// `get_active_app` output.
    // internal: called from handleToolsCall in MCPToolHandlers.swift.
    func buildActiveAppJSON() -> String {
        let tracker = ActiveAppTracker.shared
        let raw = tracker.rawFrontmostApp()
        // Paired read: the id and the name below are published as one app, so
        // they must come from a single lock acquisition. Two property reads
        // could straddle an app activation and describe two different apps.
        let frontmost = tracker.currentApp
        // Paired for the same reason -- see `ActiveAppTracker.fallbackApp`.
        let fallback = tracker.fallbackApp

        let payload: [String: Any] = [
            "frontmost": [
                "bundleId": jsonValue(frontmost.bundleId),
                "name": jsonValue(frontmost.name)
            ] as [String: Any],
            "fallback": [
                "bundleId": jsonValue(fallback.bundleId),
                "name": jsonValue(fallback.name)
            ] as [String: Any],
            "rawFrontmost": [
                "bundleId": jsonValue(raw?.bundleId),
                "name": jsonValue(raw?.name)
            ] as [String: Any],
            "captureVisible": OverlayWindowController.shared.isCaptureVisible,
            "annotationsSuspended": OverlayWindowController.shared.isAnnotationsSuspended,
            // `rawFrontmostSource` is platform-split for the same reason the
            // tool catalog's prose is: this note is read by an AI agent, and
            // naming `NSWorkspace` to a Windows caller describes an API that
            // does not exist there. The Windows tracker reads the foreground
            // window's owning process instead.
            "note": "'frontmost' is the app whose app-linked annotations would normally be eligible to appear. When annotationsSuspended=true, this process has intentionally ordered its overlay windows out, so no retained annotation is on screen from this process even if it matches frontmost. 'fallback' is what an untagged draw_* call links to: the last app that was frontmost excluding AI Chalkboard and Claude -- because when you receive a draw request, Claude's own window is frontmost, so tagging the true frontmost app would link every annotation to Claude and it would never show over the app the user meant. 'rawFrontmost' is the unfiltered \(rawFrontmostSource) value, for debugging only. A null fallback means an untagged draw becomes GLOBAL."
        ]

        guard let text = jsonString(payload) else {
            return "Error: failed to encode active app info."
        }
        return text
    }
}
