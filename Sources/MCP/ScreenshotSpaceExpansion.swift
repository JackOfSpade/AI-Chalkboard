import Foundation

/// PURE argument rewriting for the `screenshot_space` convenience argument:
/// turns `screenshot_space: "space-ab12cd34"` into the exact `screen_id` /
/// `coordinate_space` / `screenshot_width` / `screenshot_height` arguments
/// the EXISTING validation pipeline (`DrawRequest.resolveScreen(args:)` then
/// `coordinateTransform(args:)`) already knows how to check.
///
/// WHY EXPANSION RATHER THAN A SECOND CODE PATH: a referenced
/// `ScreenshotSpace` must get byte-for-byte the same aspect-ratio guard,
/// ambiguous-display guard, and coordinate transform a hand-declared
/// `screenshot_pixels` call already gets from `DrawRequest.coordinateTransform`
/// -- not a second, parallel implementation of those same checks that could
/// silently drift from them over time as one is edited and the other is not.
/// Rewriting the arguments BEFORE `DrawRequest` ever sees them means there is
/// exactly one place those checks live, and a `screenshot_space` call and an
/// equivalent hand-declared call are, from `DrawRequest`'s point of view,
/// indistinguishable.
///
/// This file is pure argument validation and rewriting only: no screen
/// snapshot is taken here, no registry singleton is touched directly (both
/// are supplied as closures), and nothing here does any drawing. That keeps
/// every rejection below directly unit-testable against hand-built
/// `ScreenshotSpace`/`ScreenInfo` fixtures.
enum ScreenshotSpaceExpansion {
    /// Rewrites `args` if `screenshot_space` was supplied, or returns `args`
    /// completely unchanged otherwise.
    ///
    /// - Parameters:
    ///   - lookup: Resolves a `screenshot_space` id to its registered
    ///     `ScreenshotSpace`, or `nil` if unknown/forgotten/evicted. Injected
    ///     rather than reaching for `ScreenshotSpaceRegistry.shared` directly
    ///     so this stays testable with hand-built fixtures and no singleton.
    ///   - currentScreen: Resolves a `screen_id`-shaped string (an exact
    ///     display id OR a positional index, exactly like
    ///     `ScreenSnapshot.resolve(_:)`) against the CURRENT display list.
    ///     Used both for the staleness check (rule 4) and for comparing a
    ///     caller-supplied `screen_id` against the space's recorded one
    ///     (rule 6).
    static func expand(
        args: [String: Any],
        lookup: (String) -> ScreenshotSpace?,
        currentScreen: (String) -> ScreenInfo?
    ) -> DrawOutcome<[String: Any]> {
        // A JSON `null` does NOT count as supplied. Copied in spirit (not
        // just by convention) from `DrawRequest.coordinateTransform`'s
        // identical `isSupplied` helper: `JSONSerialization` materializes an
        // explicit JSON null as a real `NSNull` entry, and a schema-driven
        // client that serializes every declared property -- nulling the ones
        // it is not using for THIS call -- is an entirely ordinary way to
        // build a request. Treating that null as "supplied" would reject a
        // caller for an argument it never meaningfully sent.
        func isSupplied(_ key: String) -> Bool {
            guard let value = args[key] else { return false }
            return !(value is NSNull)
        }

        // Rule 1: absent or JSON-null -- this call does not use a
        // screenshot_space at all. Return the arguments completely
        // unchanged, success, so every existing draw call that has never
        // heard of screenshot_space keeps working byte-for-byte as before.
        guard isSupplied("screenshot_space") else {
            return .success(args)
        }

        // Rule 2: present but not a String, or empty/whitespace after
        // trimming.
        guard let rawSpaceId = args["screenshot_space"] as? String else {
            return .failure("screenshot_space must be a string id (as returned by register_screenshot_space or calibrate_screenshot_space, for example \"space-ab12cd34\") when supplied. Nothing was done; pass screenshot_space as a string id, or omit it entirely.")
        }
        let spaceId = rawSpaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaceId.isEmpty else {
            return .failure("screenshot_space must not be empty or whitespace-only when supplied. Nothing was done; pass a registered space id, or omit screenshot_space.")
        }

        // Rule 3: unknown id.
        guard let space = lookup(spaceId) else {
            return .failure("Unknown screenshot_space '\(spaceId)'. It may never have been registered, may already have been forgotten, or may have been evicted to make room for newer registrations. Nothing was done; call register_screenshot_space or calibrate_screenshot_space to establish it.")
        }

        // Rule 4: staleness. Resolved against a FRESH lookup of the space's
        // OWN recorded screenId, never against the space's own recorded
        // numbers -- those are exactly the thing under suspicion.
        if let staleness = ScreenshotSpace.stalenessRejection(space: space, currentScreen: currentScreen(space.screenId)) {
            return .failure(staleness)
        }

        // Rule 5: screenshot_width/screenshot_height supplied on top of a
        // referenced space is a contradiction, not a preference to resolve
        // silently. This mirrors exactly the rule
        // `DrawRequest.coordinateTransform` already applies to
        // screenshot_width/screenshot_height under the wrong
        // coordinate_space (see that method's own doc comment): supplying
        // BOTH the space and hand-declared dimensions is unambiguous
        // evidence the caller believes something specific is about to
        // happen, and silently preferring one over the other would leave the
        // caller believing the other took effect.
        if isSupplied("screenshot_width") || isSupplied("screenshot_height") {
            return .failure("screenshot_space '\(spaceId)' already carries its own dimensions (\(space.widthPx)x\(space.heightPx)); screenshot_width/screenshot_height were ALSO supplied, which is a contradiction -- silently preferring one would leave you believing the other took effect. Nothing was done; remove screenshot_width/screenshot_height and let the space supply them, or omit screenshot_space and supply the dimensions yourself.")
        }

        // Rule 6: screen_id supplied on top of a referenced space. A value
        // EQUAL to the space's own screenId is accepted as a harmless
        // restatement -- an agent that already knows which display it is
        // targeting should not be punished for saying so again. The
        // comparison is resolved through the supplied `currentScreen`
        // closure (not a bare string compare alone) because a POSITIONAL
        // index such as "0" is a perfectly ordinary way to name a display
        // (see `ScreenSnapshot.resolve(_:)`), and "0" happening to resolve to
        // the exact same physical display the space was registered against
        // must be treated as the same harmless restatement, not as a
        // fabricated conflict between a literal string and an id. The
        // literal-string compare is tried FIRST, both as a fast path and so
        // a `currentScreen` closure that cannot resolve a given string (a
        // display that briefly vanished from the snapshot) does not turn an
        // exact, honest restatement into a spurious rejection.
        //
        // A BLANK (empty or whitespace-only) screen_id IS NOT AN ASSERTION
        // ABOUT A DISPLAY AT ALL, and treating it as one was a real bug this
        // conjunct exists to prevent. Everywhere else in this repo, blank is
        // the documented "default to the main display" fallback, not a caller
        // decision: `ScreenSnapshot.resolve(_:)` returns the MAIN screen for a
        // blank id exactly as it does for an omitted one, and
        // `DrawRequest.resolveScreen` records precisely that distinction as
        // `screenIsDetermined: !(suppliedScreenId?.isEmpty ?? true)`. The
        // schema description for `screen_id` states the same contract
        // ("omitted/blank defaults to main"). Without the emptiness conjunct,
        // a schema-driven client that serializes every declared property and
        // sends `screen_id: ""` alongside `screenshot_space: "space-ab12cd34"`
        // had its call REJECTED whenever the space was registered for any
        // display other than the main one -- blank resolved through
        // `currentScreen("")` to main ("1"), which did not equal the space's
        // "2", producing the nonsense message "screen_id '' conflicts with
        // screenshot_space '...', which is registered for display 2" for a
        // value the caller never meaningfully supplied. The identical call
        // with `screen_id` omitted entirely drew fine. Skipping the check for
        // blank costs nothing: rule 8 below overwrites `screen_id` with the
        // space's own `screenId` regardless, so a blank id can never survive
        // to reach `DrawRequest.resolveScreen` and pick up the main display.
        if isSupplied("screen_id") {
            guard let suppliedScreenId = args["screen_id"] as? String else {
                return .failure("screen_id must be a string when supplied.")
            }
            let trimmedSuppliedScreenId = suppliedScreenId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSuppliedScreenId.isEmpty, trimmedSuppliedScreenId != space.screenId {
                let resolvedId = currentScreen(trimmedSuppliedScreenId)?.id
                guard resolvedId == space.screenId else {
                    return .failure("screen_id '\(trimmedSuppliedScreenId)' conflicts with screenshot_space '\(spaceId)', which is registered for display \(space.screenId). Nothing was done; omit screen_id (the space already names its display), or pass screen_id='\(space.screenId)' to match it.")
                }
            }
        }

        // Rule 7: an explicit, non-"screenshot_pixels" coordinate_space
        // supplied on top of a referenced space would discard the very
        // mapping the caller just asked for by naming the space.
        if isSupplied("coordinate_space") {
            guard let suppliedCoordinateSpace = args["coordinate_space"] as? String else {
                return .failure("coordinate_space must be a string when supplied.")
            }
            guard suppliedCoordinateSpace.lowercased() == "screenshot_pixels" else {
                return .failure("screenshot_space '\(spaceId)' defines a screenshot pixel grid, but coordinate_space='\(suppliedCoordinateSpace)' was also supplied; interpreting your coordinates as \(suppliedCoordinateSpace) would discard the mapping screenshot_space just established. Nothing was done; remove coordinate_space (screenshot_pixels is implied by screenshot_space), or set it to 'screenshot_pixels' explicitly.")
            }
        }

        // Rule 8: expand. A COPY of args -- the caller's own dictionary is
        // never mutated -- with screenshot_space removed and the four
        // equivalent hand-declared arguments injected so
        // DrawRequest.resolveDrawContext sees an ordinary, fully-specified
        // screenshot_pixels call.
        var expanded = args
        expanded.removeValue(forKey: "screenshot_space")
        expanded["coordinate_space"] = "screenshot_pixels"
        expanded["screenshot_width"] = space.widthPx
        expanded["screenshot_height"] = space.heightPx
        expanded["screen_id"] = space.screenId
        return .success(expanded)
    }
}
