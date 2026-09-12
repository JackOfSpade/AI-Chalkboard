import Foundation

/// Static MCP catalog. Drawing is built on three universal primitives --
/// arbitrary SVG paths, caller-rendered raster images, and first-class system
/// text -- plus draw_shape, a thin geometric convenience over the path
/// primitive for the one case (a circle/ellipse/rect specified by centre and
/// radius) common enough, and error-prone enough to hand-assemble as raw arc
/// commands, to be worth a dedicated tool. Anything more complex --
/// arrows, callouts, handwriting, grids -- still goes directly through
/// path_data; there is no canned tool for those.
enum MCPToolCatalog {
    // PLATFORM-ACCURATE TOOL PROSE. These strings are not documentation for a
    // human reader -- they are the catalog an AI agent reads to decide how to
    // CALL these tools, so naming the wrong platform's API is a correctness
    // problem rather than a wording nit. Telling a Windows caller to "ask macOS
    // to show its permission prompt" describes a prompt that cannot exist
    // there, and telling it to pass a "bundle id" names an identifier Windows
    // has no concept of. The underlying capability is the same on both
    // platforms; only the mechanism and its identifiers differ.
    #if os(macOS)
    /// macOS identifies applications by bundle identifier.
    static let appParamDescription = "Optional app to LINK this drawing to: bundle id or display name. It is visible only while that app is frontmost. If omitted, the previous non-Claude app is used. Pass an empty string for GLOBAL visibility."

    static let accessibilityStatusDescription = "Reports whether macOS Accessibility permission is available for element lookup. Set request_permission=true only to explicitly ask macOS to show its permission prompt; false/default never prompts."

    static let requestPermissionDescription = "Explicitly request the macOS Accessibility permission prompt when access is not granted; default false."

    static let captureBackendName = "ScreenCaptureKit"

    /// Distinct from `appParamDescription`: `highlight_element` must resolve
    /// the argument to a LIVE PROCESS to walk its element hierarchy, so unlike
    /// the drawing tools' visibility linkage there is no meaningful "global"
    /// value to accept.
    static let highlightAppParamDescription = "Running target app bundle id or display name. Omit for the normal fallback app; empty/global is invalid because a PID is required."

    /// The macOS ambiguity error renders a numbered per-candidate list with
    /// each candidate's role and resolved backing-pixel bounds (see
    /// AccessibilityElementResolver's `.ambiguous`). Windows UI Automation
    /// reports only a match COUNT at that layer, so this sentence is
    /// platform-split: promising a Windows caller a list that never arrives
    /// would leave it waiting for output that cannot exist and then guessing
    /// occurrence blind -- the exact failure the list exists to prevent.
    static let highlightAmbiguityDescription = "ambiguous labels are rejected with a numbered candidate list carrying each candidate's role and resolved on-screen bounds, so the right occurrence can be chosen by geometry instead of guessed"

    /// Platform-split for the same reason as `highlightAmbiguityDescription`.
    static let occurrenceAmbiguityDetail = "the ambiguity error numbers its candidates with the occurrence that selects each"

    static let captureRequestPermissionDescription = "For capture_source=chalkboard only: explicitly request Screen Recording permission if absent; default false."

    static let presentationCheckDescription = "Checks the retained overlay/view pair and WindowServer registration/on-screen state for one drawing, including bounded WindowServer-display-bounds alignment. presentationReady catches missing, hidden, detached, transparent, wrong-level/frame/display, or unregistered windows. It is drawable-state evidence, not raw framebuffer or occlusion proof."

    /// `verify_annotation`'s `capture_source` used to offer only
    /// "chalkboard", so the ONLY way to verify a drawing's placement without
    /// a caller-supplied screenshot was a path gated on Screen Recording
    /// permission -- and a caller that permission was denied to had no
    /// listed way to ask for anything weaker. "none" is a renderer-geometry
    /// verdict (the exact call `get_annotation_bounds` makes) that needs no
    /// capture at all, so it needed no Screen Recording grant either; it
    /// existed as a DIFFERENT tool the whole time, but nothing on
    /// `verify_annotation` itself said so. This description exists to fix
    /// that discoverability gap directly in the one place an agent that
    /// just got a permission-denied error is already reading.
    static let captureSourceDescription = "How to obtain the image this call verifies against; required when screenshot_path is omitted, and rejected together with it. 'chalkboard': Chalkboard's own in-memory \(captureBackendName) capture -- needs the macOS Screen Recording permission (see request_permission below). 'none': a permission-free GEOMETRY verdict that needs NO Screen Recording permission at all -- it renders the annotation ALONE with the exact live renderer (the same call get_annotation_bounds makes) instead of capturing anything, and is the path to reach for, together with expect_element/expect_window/target_bounds_screenshot_px below, whenever Screen Recording permission is not granted."

    /// Platform-split because the underlying resolver is: `expect_element`
    /// is answered by `AccessibilityElementResolver`, the exact walk
    /// `highlight_element` already performs, which needs the macOS
    /// Accessibility grant and nothing else -- naming Screen Recording here
    /// at all would wrongly suggest this expectation is blocked by the same
    /// permission `capture_source='chalkboard'` needs.
    static let expectElementDescription = "At most one of expect_element/expect_window/target_bounds_screenshot_px may be supplied. Resolves {app, label, role?, match?, occurrence?} through the SAME Accessibility element lookup highlight_element uses, then reports how the annotation's painted bounds compare to that element's live bounds. Needs the macOS Accessibility permission grant -- NOT Screen Recording -- so this comparison still works when Screen Recording has never been granted; check get_accessibility_status first if unsure."

    /// Platform-split for the same reason: `expect_window` is answered by
    /// `TargetWindowProbe`, which on macOS reads only window-list BOUNDS
    /// (`CGWindowListCopyWindowInfo`, never `kCGWindowName`, the one field
    /// Screen Recording actually gates) -- so it needs NO permission at all,
    /// not even Accessibility, and that must be said plainly rather than
    /// left to be inferred.
    static let expectWindowDescription = "At most one of expect_element/expect_window/target_bounds_screenshot_px may be supplied. Resolves {app} to its most-overlapping window's bounds via CGWindowListCopyWindowInfo bounds only -- never kCGWindowName, the one field Screen Recording actually gates -- so this needs NO permission at all on macOS, not even Accessibility."

    /// `calibrate_screenshot_space action='elements'`'s `app` argument.
    ///
    /// Split for the same reason as `highlightAppParamDescription` (macOS
    /// names applications by bundle identifier) but written out separately
    /// rather than reused, because the two arguments have OPPOSITE
    /// optionality and reusing the sentence would advertise the wrong one.
    /// `highlight_element` may omit `app` and fall back to the previously
    /// active application; this route may not. The caller measured specific
    /// elements of ONE specific application in its own screenshot, so
    /// silently resolving a different app's hierarchy would solve a mapping
    /// between points nobody ever observed and register it as `observed` --
    /// a wrong space carrying the strongest provenance this route can grant.
    static let calibrationElementsAppDescription = "elements only, and REQUIRED there: the running application whose own UI elements are the fiducials -- bundle id or display name, resolved exactly as highlight_element resolves its app. There is NO fallback here, unlike highlight_element: omitting it, or passing an empty string for global, is rejected and registers nothing, because a PID is required to walk an element hierarchy and because the elements you measured belong to one specific app. Name the app your own capture tool can actually see in its screenshots -- being able to see that app while Chalkboard's overlay stays invisible is the entire reason this route exists."

    /// The permission sentence for `action='elements'`, split for the same
    /// reason as `expectElementDescription`: this route is answered by
    /// `AccessibilityElementResolver` and captures NOTHING, so it is gated by
    /// the Accessibility grant and by nothing else. Saying "Screen Recording"
    /// anywhere near it would send an agent that already failed to see
    /// Chalkboard's fiducials off to grant the one permission that has no
    /// bearing on whether this call works -- and this route exists precisely
    /// for callers whose capture path is out of Chalkboard's reach.
    static let calibrationElementsPermissionDescription = "PERMISSION: this route needs the macOS Accessibility grant -- NOT Screen Recording. It resolves the elements through the same Accessibility lookup highlight_element performs and captures no pixels of its own at all, so it still works on a machine where Screen Recording has never been granted; call get_accessibility_status first if unsure."

    /// The accuracy caveat a BOUNDS-observed WINDOW fiducial needs, split
    /// because it names a platform-specific rect. macOS Accessibility
    /// reports a window's FRAME: the title bar is inside it and the drop
    /// shadow is outside it.
    ///
    /// THE CONCRETE MISREADING THIS PREVENTS: an agent calibrating from a
    /// remote-desktop window measures the video surface it actually cares
    /// about -- the content area -- and so omits a ~28 px title bar from the
    /// top edge. On a 3024x1964 display with a 2000x1200 window captured at
    /// exactly 0.5x, that gives a y-scale of 0.48833 against an x-scale of
    /// 0.5 and an origin residual of 14.58 against a 9.59 tolerance. The
    /// existing origin-residual check therefore REJECTS it instead of
    /// registering a space whose every vertical coordinate is ~2% short, but
    /// that rejection only helps a caller who knows what it means -- hence
    /// naming the diagnosis here, in the description the agent reads before
    /// it measures anything.
    static let calibrationWindowFrameCaveat = "ACCURACY, when the fiducial IS the window: the rect Chalkboard resolves for a window is that window's ACCESSIBILITY FRAME, which normally INCLUDES the title bar and EXCLUDES the drop shadow. Report the bounding box of that same FRAME -- top edge at the TOP OF THE TITLE BAR, left/right/bottom at the window's own edges with the shadow NOT counted -- and not the bounding box of the content area inside it. Measuring the content area instead removes roughly a title bar's height from ONE axis only, so the vertical scale silently disagrees with the horizontal one. That is not left to slip through: it lands as an ORIGIN-RESIDUAL rejection -- the same check both routes already run -- which registers NOTHING rather than mis-scaling the space. So read a residual rejection on a single-window calibration as 'I probably measured the content area', re-measure from the top of the title bar, and call again."
    #elseif os(Windows)
    /// Windows has no bundle-identifier concept; `ActiveAppTracker` identifies
    /// an application by its executable name, matched case-insensitively.
    static let appParamDescription = "Optional app to LINK this drawing to: executable name (for example \"chrome.exe\", matched case-insensitively) or window/display name. It is visible only while that app is frontmost. If omitted, the previous non-Claude app is used. Pass an empty string for GLOBAL visibility."

    /// UI Automation needs no persistent grant to check ahead of time, so this
    /// reports reachability rather than a permission state, and
    /// `request_permission` has nothing to request. Said plainly so a caller
    /// does not wait for a prompt that will never appear.
    static let accessibilityStatusDescription = "Reports whether UI Automation is reachable for element lookup. Windows has no Accessibility permission to grant or prompt for, so this reports availability, not a permission state, and request_permission has no effect."

    static let requestPermissionDescription = "Accepted for cross-platform compatibility but has NO EFFECT on Windows: there is no Accessibility permission prompt to request."

    static let captureBackendName = "GDI BitBlt"

    /// See the macOS counterpart: `highlight_element` resolves this to a live
    /// process, so "global" is not a valid value here either.
    static let highlightAppParamDescription = "Running target app executable name (for example \"chrome.exe\", matched case-insensitively) or window/display name. Omit for the normal fallback app; empty/global is invalid because a PID is required."

    /// See the macOS counterpart: the Windows resolver's `.ambiguous` carries
    /// only a match COUNT (`chalk_uia_find_element` hands back no
    /// per-candidate preview), so this variant tells the caller the truth --
    /// iterate occurrence and verify -- instead of promising a list that
    /// never arrives.
    static let highlightAmbiguityDescription = "an ambiguous label is rejected with a match COUNT only -- Windows UI Automation reports no per-candidate preview -- so try occurrence from 1 upward and confirm each placement with verify_annotation"

    /// Platform-split for the same reason as `highlightAmbiguityDescription`.
    static let occurrenceAmbiguityDetail = "the ambiguity error reports a match count only (no per-candidate preview), so try occurrence from 1 upward"

    /// Windows has no capture-permission model to request: any process that
    /// can run code in this session can already capture the screen (see
    /// ScreenCaptureProvider's Windows permissionStatus() doc comment).
    static let captureRequestPermissionDescription = "For capture_source=chalkboard only: accepted for cross-platform compatibility but has NO EFFECT on Windows, which has no screen-capture permission to request; default false."

    /// Windows twin of the macOS description: there is no WindowServer here,
    /// only this process's own Win32 window state plus DWM's cloaking flag
    /// (see OverlayWindowController+Diagnostics.swift's Windows
    /// presentationStatus() note for the same "WEAKER THAN macOS" caveat).
    static let presentationCheckDescription = "Checks the retained overlay window's own Win32 state (IsWindow/IsWindowVisible/GetWindowRect/extended style) plus DWM's cloaking flag for one drawing, including bounded display-bounds alignment. presentationReady catches missing, hidden, detached, transparent, or wrong-level/frame/display windows. This is single-source evidence from this process's own window state, not a compositor-maintained record the way macOS's WindowServer check is, and it is not raw framebuffer or occlusion proof."

    /// Windows twin of the macOS `captureSourceDescription`: Windows has no
    /// Screen Recording permission concept at all (see
    /// `captureRequestPermissionDescription` above), so `capture_source`'s
    /// two values differ only in cost/fidelity here, never in what
    /// permission either one needs -- and that absence must be stated
    /// plainly rather than left for a caller to assume from the macOS-shaped
    /// wording.
    static let captureSourceDescription = "How to obtain the image this call verifies against; required when screenshot_path is omitted, and rejected together with it. 'chalkboard': Chalkboard's own in-memory \(captureBackendName) capture -- Windows has no screen-capture permission to grant, so this always works. 'none': a permission-free GEOMETRY verdict -- it renders the annotation ALONE with the exact live renderer (the same call get_annotation_bounds makes) instead of capturing anything, useful whenever you want renderer-geometry evidence together with expect_element/expect_window/target_bounds_screenshot_px below without paying for a capture."

    /// Windows twin of the macOS `expectElementDescription`: the resolver is
    /// UI Automation, not Accessibility, and Windows has neither an
    /// Accessibility permission nor a Screen Recording permission to grant
    /// for it -- see `accessibilityStatusDescription` above for the same
    /// "reachability, not a permission state" distinction.
    static let expectElementDescription = "At most one of expect_element/expect_window/target_bounds_screenshot_px may be supplied. Resolves {app, label, role?, match?, occurrence?} through the SAME UI Automation element lookup highlight_element uses, then reports how the annotation's painted bounds compare to that element's live bounds. Windows has no Accessibility permission to grant and no Screen Recording permission either -- get_accessibility_status reports UI Automation reachability, not a permission state, and this comparison needs no prompt at all."

    /// Windows twin of the macOS `expectWindowDescription`: `TargetWindowProbe`
    /// needs no permission on either platform, but macOS's wording names a
    /// specific gated API (`kCGWindowName`) that has no Windows analogue, so
    /// telling a Windows caller the SAME reason would name a concept that
    /// does not exist there.
    static let expectWindowDescription = "At most one of expect_element/expect_window/target_bounds_screenshot_px may be supplied. Resolves {app} to its most-overlapping window's bounds. Windows has no Screen Recording permission and no Accessibility permission to grant either, so this needs NO permission at all."

    /// Windows twin of the macOS `calibrationElementsAppDescription`: the
    /// same "no fallback" rule, but Windows has no bundle-identifier concept
    /// to name (see `appParamDescription` above).
    static let calibrationElementsAppDescription = "elements only, and REQUIRED there: the running application whose own UI elements are the fiducials -- executable name (for example \"chrome.exe\", matched case-insensitively) or window/display name, resolved exactly as highlight_element resolves its app. There is NO fallback here, unlike highlight_element: omitting it, or passing an empty string for global, is rejected and registers nothing, because a PID is required to walk an element hierarchy and because the elements you measured belong to one specific app. Name the app your own capture tool can actually see in its screenshots -- being able to see that app while Chalkboard's overlay stays invisible is the entire reason this route exists."

    /// Windows twin of the macOS `calibrationElementsPermissionDescription`:
    /// there is no Accessibility permission and no Screen Recording
    /// permission here, so the macOS sentence's whole point ("this one, not
    /// that one") would describe a choice that does not exist. Stating the
    /// absence plainly stops a caller waiting for a prompt that never
    /// appears -- the same reason `accessibilityStatusDescription` is split.
    static let calibrationElementsPermissionDescription = "PERMISSION: none. The elements are resolved through UI Automation, and Windows has no Accessibility permission to grant and no screen-capture permission either, so nothing prompts and nothing has to be granted first. get_accessibility_status reports UI Automation REACHABILITY, not a permission state; check it if elements fail to resolve."

    /// Windows twin of the macOS `calibrationWindowFrameCaveat`. The rect is
    /// UI Automation's BoundingRectangle -- what `GetWindowRect` reports --
    /// so the part that must be INCLUDED is the caption bar rather than a
    /// macOS title bar, and the part a caller cannot see is different in
    /// kind: Windows 10/11 pad a window's reported rect with a few pixels of
    /// INVISIBLE DWM resize border outside the painted edge. Naming macOS's
    /// "drop shadow" here would describe a boundary that is not the one
    /// Windows actually reports, and staying silent about the invisible
    /// border would leave a caller hunting a real few-pixel discrepancy it
    /// has no way to see. The failure mode being prevented is identical:
    /// measuring the CLIENT area omits the caption bar from one axis only
    /// and shows up as an origin-residual rejection, not as a silently
    /// mis-scaled space.
    static let calibrationWindowFrameCaveat = "ACCURACY, when the fiducial IS the window: the rect Chalkboard resolves for a window is that window's UI AUTOMATION BOUNDING RECTANGLE -- the rect Windows itself reports for the window -- which normally INCLUDES the caption bar and, on Windows 10/11, the few pixels of INVISIBLE DWM resize border just outside the painted edge, and excludes the drop shadow drawn beyond that. Report the bounding box of that same WINDOW rect, caption bar included -- not the bounding box of the client area inside it. Measuring the client area instead removes roughly a caption bar's height from ONE axis only, so the vertical scale silently disagrees with the horizontal one. That is not left to slip through: it lands as an ORIGIN-RESIDUAL rejection -- the same check both routes already run -- which registers NOTHING rather than mis-scaling the space. So read a residual rejection on a single-window calibration as 'I probably measured the client area', re-measure from the top of the caption bar, and call again. The invisible resize border is a pixel-or-two effect of exactly the kind the PRECISION note below already covers; the caption bar is not."
    #endif

    /// Shared verbatim by every `draw_*` tool AND `get_annotation_bounds`/
    /// `verify_annotation` -- see `Sources/Support/ScreenshotSpace.swift`'s
    /// doc comment for the concrete bug this property exists to prevent: a
    /// caller who re-declares `coordinate_space='screenshot_pixels'` +
    /// `screenshot_width`/`screenshot_height` on every call is re-guessing
    /// those numbers every time, and a same-aspect-ratio WRONG guess (the
    /// display's native size instead of a client-downsampled image's actual
    /// size) passes every existing guard and still lands every coordinate at
    /// the wrong scale. Referencing a space registered ONCE by
    /// `register_screenshot_space`/`calibrate_screenshot_space` replaces
    /// that per-call guess with a fact checked once, at registration time.
    ///
    /// REJECT RATHER THAN RECONCILE: `ScreenshotSpaceExpansion` runs BEFORE
    /// the ordinary `coordinate_space`/`screenshot_width`/`screenshot_height`
    /// validation, so a space and a hand-declared value that disagree are
    /// two different claims about where this drawing goes -- silently
    /// preferring one would leave the caller believing the other took
    /// effect, which is exactly the class of silent misplacement this whole
    /// feature exists to eliminate.
    private static let screenshotSpaceDescription = "Names a screenshot space registered by register_screenshot_space or calibrate_screenshot_space. Supplying it REPLACES coordinate_space/screenshot_width/screenshot_height/screen_id for this call -- the space already carries all four, resolved from that one registration instead of re-declared here. Supplying it together with screenshot_width/screenshot_height, or together with a screen_id that contradicts the space's own display, or together with a coordinate_space other than 'screenshot_pixels', is REJECTED rather than reconciled: two disagreeing claims about where this drawing goes cannot be silently resolved in one's favor without the caller wrongly believing the other took effect. Nothing is drawn/computed when rejected. A space that has gone stale -- its display disconnected, or its resolution/HiDPI mode changed since registration -- is also rejected; register or calibrate again for that display."

    /// `calibrate_screenshot_space`'s `markers` argument -- the
    /// DRAWN-FIDUCIAL route's observations. `action='elements'` reports its
    /// own observations through `elements` instead and never touches this.
    ///
    /// THE CONCRETE BUG THIS WORDING (and the `minItems: 4` beside it) FIXES:
    /// this schema used to advertise `minItems: 1` and this description used
    /// to say "up to four" observations, while
    /// `ScreenshotCalibration.solve` has always required the COMPLETE
    /// TL/TR/BL/BR set and rejected anything less ("Calibration is missing
    /// marker(s) ...; all four of TL, TR, BL, BR are required"). An agent
    /// that could only read two crosshairs therefore did exactly what the
    /// catalog told it was legal -- sent two -- and was rejected by the
    /// solver.
    ///
    /// WHY THAT WAS WORSE THAN AN ORDINARY ARGUMENT REJECTION: the solve runs
    /// AFTER `handleCalibrateScreenshotSpaceResolve` has looked the session
    /// up, and a solver rejection CONSUMES that session -- the fiducials are
    /// cleared and the calibration id retired. So the agent that trusted
    /// `minItems: 1`, sent a short set, and read "retry" had nothing left to
    /// retry against: the markers it was being told to re-measure were gone
    /// from the screen, and only a fresh `action="begin"` could get them
    /// back. An advertised contract that is both wrong AND destructive to
    /// obey is the worst shape a tool description can take, which is why
    /// this description states the arity requirement three ways (exactly
    /// four, one per label, all in a single call) instead of leaving the
    /// schema's `minItems` to carry it alone.
    ///
    /// WHY FOUR AND NOT TWO, stated here rather than left as an arbitrary
    /// rule: two diagonal markers always "solve" some width and height with
    /// zero residual, because no second observation of either axis exists to
    /// disagree with them. Four markers measure each axis twice, and it is
    /// that disagreement check -- `solve`'s step (c) -- that catches a
    /// misread or a transposed label at all. An agent that understands this
    /// will re-take its screenshot instead of reaching for a partial set.
    private static let calibrationMarkersDescription = "resolve only: your observations of where each fiducial's centre landed in YOUR OWN screenshot's pixels. EXACTLY FOUR entries -- one for each of begin's TL, TR, BL and BR markers, each label reported exactly once, and all four supplied together in this single resolve call. The complete set is required, not preferred: a missing label, a duplicate label, or an unknown one is REJECTED and registers nothing, because the solver measures each axis twice (the two markers sharing a normalized coordinate) and comparing those two independent readings is what catches a misread -- three markers do not produce a less certain answer, they produce no answer. Observations are not accumulated across calls, so a follow-up resolve cannot supply a marker an earlier one omitted; if you cannot read one crosshair, re-take the screenshot, or cancel and begin again. Distinguish that from crosshairs that are not in your screenshot AT ALL: no retake fixes an absent fiducial, because that capture path is not showing Chalkboard's own pixels -- cancel and use action='elements', whose fiducials are the target app's own UI elements, or register_screenshot_space with screenshot_path. Solves the image's true pixel dimensions from the observed spread between them (provenance 'observed'); see the tool description for the solver's blind spot and how observed_width/observed_height can cross-check it."

    /// The `{label, role?, match?, occurrence?}` element QUERY shape, shared
    /// field-for-field by `verify_annotation`'s `expect_element` and by
    /// `calibrate_screenshot_space action='elements'`'s per-element items.
    ///
    /// Shared for the same reason as `targetBoundsScreenshotPxShape`: both
    /// name the exact same thing (one element to find) and are answered by
    /// the exact same call -- `AccessibilityElementResolver.resolve` -- so a
    /// second, independently maintained copy is how the two would drift on
    /// which fields exist, what `match` accepts, or whether `occurrence` is
    /// one-based. Drift there is not cosmetic: a caller that pins an
    /// ambiguous label with `occurrence` on one tool and finds the argument
    /// missing (or zero-based) on the other picks the WRONG element, and on
    /// this new calibration route the wrong element is a wrong true point
    /// fed straight into the solve.
    ///
    /// `highlight_element` deliberately does NOT share this: its own
    /// `occurrence` wording carries the extra short-circuit warning that
    /// applies only to a tool that draws from the walk, and `label` is
    /// required there with its own length bounds.
    private static let elementQueryShape: [String: Any] = [
        "label": ["type": "string", "description": "Accessibility title, description, or value to match -- same semantics as highlight_element's label."],
        "role": ["type": "string", "description": "Optional raw Accessibility role, for example AXButton."],
        "match": ["type": "string", "enum": ["exact", "contains"], "description": "Label matching mode; exact is the default."],
        "occurrence": ["type": "integer", "minimum": 1, "description": "One-based match index in breadth-first discovery order, required when the label is ambiguous; \(occurrenceAmbiguityDetail)."]
    ]

    /// The BOUNDS observation form of a `calibrate_screenshot_space
    /// action='elements'` item -- `observed_left`/`observed_top`/
    /// `observed_right`/`observed_bottom` -- which is the alternative to
    /// `observed_x`/`observed_y`, never a supplement to it.
    ///
    /// THE FIELD FAILURE IT EXISTS FOR, named: driving DaVinci Resolve
    /// running inside the Shadow PC remote-desktop client
    /// (`ShadowPCDisplay`), the ENTIRE application exposed exactly ONE
    /// labelled Accessibility element -- the window itself,
    /// `'Shadow PC - Display' [AXWindow]`. No buttons, no child controls
    /// resolvable by label. With centre-only observations that app yields
    /// ONE correspondence while the route needs two, so element calibration
    /// was unsatisfiable there no matter how the baseline gate was tuned,
    /// and the caller was pushed back to a `declared` space -- a bare
    /// assertion -- for an app whose geometry was perfectly measurable. This
    /// generalises to a whole class: a remote-desktop or VNC client, a media
    /// player, a game, anything painting one video/canvas surface is, to
    /// Accessibility, a window containing nothing.
    ///
    /// A RECT IS TWO POINTS, which is the entire idea. Observing that one
    /// window's bounding box hands the solver the resolved rect's top-left
    /// and bottom-right corners, whose TRUE separation is known on BOTH
    /// axes -- exactly what `observed = scale * true + origin` needs -- and
    /// such a window is large, so the 25%-of-axis baseline gate is cleared
    /// comfortably rather than scraped past. Window edges are also
    /// high-contrast and unambiguous in a screenshot, so reading them is if
    /// anything easier than judging a control's painted centre.
    ///
    /// WHY ALL FOUR PROPERTIES ARE OPTIONAL HERE AND `required` IS JUST
    /// `["label"]`: JSON Schema cannot express "exactly one of these two
    /// GROUPS", and the arity lesson of `calibrationMarkersDescription` says
    /// a schema must advertise only what it can actually enforce. So the
    /// schema states the one field that is unconditionally required, and the
    /// handler enforces the real rule with prose no schema keyword could
    /// produce: both forms on one element, a partial box naming exactly
    /// which of the four are missing, neither form, and an inverted or
    /// zero-area box are each rejected by name, each saying what was NOT
    /// done and the one fix.
    private static let calibrationBoundsObservationShape: [String: Any] = [
        "observed_left": ["type": "number", "description": "BOUNDS observation -- the alternative to observed_x/observed_y, and the route for an app whose only resolvable element is its own window. All FOUR of observed_left/observed_top/observed_right/observed_bottom are supplied together or not at all. This one is the LEFT edge of this element's bounding box in YOUR OWN screenshot's pixels -- that image's coordinates, never the display's -- and it must be SMALLER than observed_right. Observing an element this way gives the solver TWO points (the resolved rect's top-left and bottom-right corners) instead of one, so a SINGLE bounds-observed element is a complete calibration by itself, while a single centre-observed element is not. Supplying both forms for the same element, or only some of the four, is REJECTED by name and nothing is registered."],
        "observed_top": ["type": "number", "description": "BOUNDS observation, all four of observed_left/observed_top/observed_right/observed_bottom supplied together or not at all: the TOP edge of this element's bounding box in YOUR OWN screenshot's pixels, and it must be SMALLER than observed_bottom. When the element IS the application's own window, this is the top of the window FRAME -- title bar included -- not the top of the content area below it; see the tool description's ACCURACY paragraph for why measuring the content area is rejected rather than silently mis-scaled. See observed_left for the rest."],
        "observed_right": ["type": "number", "description": "BOUNDS observation, all four of observed_left/observed_top/observed_right/observed_bottom supplied together or not at all: the RIGHT edge of this element's bounding box in YOUR OWN screenshot's pixels, and it must be LARGER than observed_left -- an inverted or zero-width box is rejected, not silently normalised. See observed_left."],
        "observed_bottom": ["type": "number", "description": "BOUNDS observation, all four of observed_left/observed_top/observed_right/observed_bottom supplied together or not at all: the BOTTOM edge of this element's bounding box in YOUR OWN screenshot's pixels, and it must be LARGER than observed_top -- an inverted or zero-height box is rejected, not silently normalised. See observed_left."]
    ]

    /// `calibrate_screenshot_space action='elements'`'s `elements` argument.
    ///
    /// WHAT THIS ARGUMENT IS FOR, since it is unlike anything else in this
    /// catalog: each entry is a CORRESPONDENCE (or two), not a request. It
    /// pairs points Chalkboard can establish independently -- from the rect
    /// the application reports for that element -- with the same points as
    /// the caller sees them in its own image. A CENTRE observation pairs one
    /// point (the rect's centre); a BOUNDS observation pairs two (the rect's
    /// top-left and bottom-right corners). Two such pairs per axis are what
    /// solve `observed = scale * true + origin`, which is the whole
    /// calibration -- so the real requirement is two POINTS, not two
    /// ELEMENTS, and that distinction is what lets a one-element app
    /// calibrate at all (see `calibrationBoundsObservationShape`).
    ///
    /// WHY THE PROSE SHOUTS ABOUT SPREADING THEM OUT: the scale comes from
    /// dividing an observed separation by a true separation, so the reading
    /// error in the numerator is divided by that same baseline. Two elements
    /// 40 px apart on a 3024 px-wide display -- or, equally, ONE small
    /// control whose observed BOX is only 40 px wide, since its two corners
    /// are the same short baseline -- turn a 2 px misjudgement of a point
    /// into a 5% scale error -- a space that is wrong by 150 px at
    /// the far edge while every individual number in the call looked
    /// reasonable. That is exactly the silent-misplacement class this whole
    /// feature exists to eliminate, so the 25%-of-axis baseline gate rejects
    /// it outright rather than solving it, and the description states the
    /// gate in the same terms the rejection does.
    ///
    /// WHY IT ALSO ASKS FOR A THIRD POINT THE SCHEMA DOES NOT REQUIRE:
    /// with exactly two correspondences on an axis the fit is exact BY
    /// CONSTRUCTION -- a line through two points always passes through both
    /// -- so a transposed pair or a misread centre produces zero residual
    /// and sails through. The third point is the first one that can
    /// disagree, which is the identical argument
    /// `calibrationMarkersDescription` makes for demanding all four drawn
    /// markers instead of two diagonals. `minItems` is 1 because the solver
    /// genuinely accepts one BOUNDS-observed element (see the arity lesson
    /// in `calibrationMarkersDescription`: the advertised arity must equal
    /// the enforced one, and advertising 2 here would reject the
    /// single-window call this route was extended to answer), while the
    /// prose carries both the "3 points is much better" advice and the
    /// "one centre element alone is NOT enough" warning that a schema number
    /// cannot express in either direction.
    private static let calibrationElementsDescription = "elements only, and REQUIRED there: 1-8 of {app}'s own UI elements to use as fiducials. Each entry is one element both NAMED (label, plus role/match/occurrence when the label alone is ambiguous -- resolved exactly as highlight_element resolves them) and OBSERVED, in EXACTLY ONE of two ways: by CENTRE (observed_x/observed_y -- that element's centre in YOUR OWN screenshot's pixels, ONE point) or by BOUNDS (observed_left/observed_top/observed_right/observed_bottom -- that element's bounding box in your own screenshot's pixels, TWO points, its top-left and bottom-right corners). That pairing is the measurement: 'this control really is here on the display, and I can see it there in my image'. WHAT THE SOLVER NEEDS IS TWO POINTS, NOT TWO ELEMENTS: one bounds-observed element supplies both and is a complete calibration on its own, while one centre-observed element supplies one and is rejected. So, when {app} exposes nameable inner controls, PICK 3 OR MORE AND SPREAD THEM WIDELY ACROSS THE DISPLAY -- opposite corners of a window, or a toolbar item and a status-bar item; and when it exposes NOTHING BUT ITS OWN WINDOW (a remote-desktop or VNC client, a media player, a game, any canvas/video surface with no labelled child controls), pass THAT WINDOW as a single bounds-observed entry, which is the intended call for those apps rather than a fallback. The gate is concrete and applies to POINTS however they were observed: on each axis, the widest TRUE separation between two of them must be at least 25% of the display's size on that axis, so two elements sitting next to each other -- or one SMALL control observed by bounds -- are REJECTED and nothing is registered; a short baseline divides your reading error by a small number and multiplies it into the solved scale, which is the same reason the drawn markers sit at 10%/90% insets instead of side by side. Two points is the bare minimum the solver accepts, but at two the fit is exact by construction on each axis: nothing disagrees with it, so a mislabelled or misread point cannot be caught at all. A third and later widely separated point -- another element, or a centre observation alongside a bounds one -- is the only thing that turns this into a CHECKED solve, exactly as the fourth drawn marker does. Ambiguity is handled the familiar way -- \(highlightAmbiguityDescription) -- so pin the element down with role/match/occurrence instead of hoping the first match is the one you measured. Every element must resolve to the SAME display, because a screenshot is of one display; elements landing on different displays are rejected by name, and so is any element that resolves to a display other than an explicitly supplied screen_id. Nothing is registered when any of these checks fails."

    private static let sharedDrawProperties: [String: Any] = [
        "screen_id": ["type": "string", "maxLength": 128, "description": "Current screen ID/index from get_screens; omitted/blank defaults to main, while an unknown explicit value is rejected instead of falling back to another display."],
        "screenshot_space": ["type": "string", "minLength": 1, "maxLength": 64, "description": screenshotSpaceDescription],
        "app": ["type": "string", "description": appParamDescription],
        "coordinate_space": ["type": "string", "enum": ["backing_pixels", "normalized", "screenshot_pixels"], "description": "Position/geometry space. When coordinates were measured from a screenshot, use screenshot_pixels with the exact dimensions of that same image version (after any model/client resize). It must be an uncropped full-display image; a detectable crop/window aspect mismatch is rejected because it has no safe display origin. A same-aspect crop is inherently indistinguishable from a downsampled full-display image, so callers remain responsible for full-display provenance. backing_pixels is the default, normalized is 0...1 of the selected display. NOTE for normalized specifically: unlike screenshot_pixels it carries no evidence of WHICH display it was measured against, so nothing can detect a mismatch on your behalf -- pass screen_id explicitly whenever you measured a display other than the main one. Style dimensions stay in backing pixels. In EVERY space, coordinates are relative to the SELECTED display's own top-left corner -- (0,0) is that display's top-left, never the virtual desktop -- so never add get_screens' appKitFrame/windowServerFrame desktop offsets to any coordinate."],
        "screenshot_width": ["type": "integer", "minimum": 1, "description": "Exact integer pixel width of the uncropped full-display image version used to measure coordinates when coordinate_space=screenshot_pixels; do not use its pre-resize/original width if the measured image was resized. Only valid with coordinate_space='screenshot_pixels': supplying it under any other coordinate_space is rejected rather than silently ignored."],
        "screenshot_height": ["type": "integer", "minimum": 1, "description": "Exact integer pixel height of the uncropped full-display image version used to measure coordinates when coordinate_space=screenshot_pixels; do not use its pre-resize/original height if the measured image was resized. Only valid with coordinate_space='screenshot_pixels': supplying it under any other coordinate_space is rejected rather than silently ignored."],
        "z_index": ["type": "integer", "description": "Paint order; higher values appear above lower values. Default 0; equal values retain creation order."],
        "anchor": ["type": "string", "enum": ["none", "window"], "description": "Anchors this drawing to one of app's windows so it follows that window as it moves and resizes, instead of staying at fixed display coordinates forever. \"window\" requires app to resolve to exactly one RUNNING process -- a global/untagged drawing (no app, or app='') has no window to anchor to and is rejected -- and picks whichever of that process's windows overlaps this drawing's own geometry the most (front-most breaks ties, including \"nothing overlaps\"). Default \"none\": today's fixed-coordinate behavior, completely unaffected. Tracking is SAMPLED, not event-driven, so the drawing trails the window by up to one sample interval while it is actively being dragged or resized, and lands exactly once the window settles. Check the response's anchor.state (and, later, list_annotations) to see whether the window is still being tracked. See anchor_resize for how the window's own resizing affects this drawing's geometry."],
        "anchor_resize": ["type": "string", "enum": ["pin", "scale"], "description": "Only meaningful together with anchor=\"window\" -- REJECTED when anchor is absent or \"none\", since there is no anchor window to react to. \"pin\" (default): follow only the window's top-left corner; this drawing keeps its own size while the window resizes. Choose pin for anything anchored to window CHROME -- a toolbar button, a tab, a sidebar item -- which is the common case, hence the default. \"scale\": scale this drawing's positions and geometry lengths (path coordinates, image width/height) per axis by the window's current-size/reference-size ratio. Choose scale only when the drawing's geometry was measured against CONTENT that itself scales with the window, such as a canvas, an image, or a video frame. Under BOTH policies, stroke width, font size, and padding stay fixed backing pixels -- only positions and geometry lengths scale."],
        "report_placement": ["type": "boolean", "description": "Adds a 'painted' object to the success response: the exact painted bounds from the live renderer (paintedBoundsBackingPx), onScreenClipped, and isVisibleNow/wouldBeVisibleWithoutSuspension -- the same renderer-geometry answer get_annotation_bounds gives, with no extra round trip and no capture or permission. Screenshot-mapped calls (a screenshot_space, or coordinate_space='screenshot_pixels') get this AUTOMATICALLY, plus paintedBoundsScreenshotPx/screenshotScale in the screenshot's own pixels; report_placement=true opts other calls in. Note: any call carrying placement feedback returns the structured JSON response instead of the legacy plain-text line."],
        "expect_element": ["type": "object", "description": "Draw-time verification: after the drawing is stored, resolves this UI element through the same Accessibility lookup highlight_element/verify_annotation use ({label, app?, role?, match?, occurrence?}) and reports an 'expect' verdict in the response -- coverageOfTarget, intersectionOverUnion, containsTarget, centerDeltaX/Y (backing px), verdict ('on_target'/'partial'/'off_target'), and correctionBackingPx, the exact update_annotation offsets that would center the drawing on the element. At most one of expect_element/expect_window/target_bounds_screenshot_px per call. If the expectation fails to RESOLVE (app not running, no match), the drawing is kept and the failure is reported inside expect.error -- fix the expectation and re-check with verify_annotation."],
        "expect_window": ["type": "object", "description": "Draw-time verification against a window instead of an element: {app?} resolves the app's window most overlapping this drawing, and the response's 'expect' object reports the same verdict/correction fields expect_element documents. At most one of expect_element/expect_window/target_bounds_screenshot_px per call."],
        "target_bounds_screenshot_px": ["type": "object", "description": "Draw-time verification against a rectangle you measured yourself: {x, y, width, height} in the SAME screenshot pixel grid this call's coordinates use (requires a screenshot_space or coordinate_space='screenshot_pixels' with dimensions). The response's 'expect' object reports the same verdict/correction fields expect_element documents. Prefer expect_element when the target has an accessible label -- the element's true bounds beat a hand-measured rectangle. At most one of the three expectation forms per call."],
        "apply_correction": ["type": "boolean", "description": "Only with one of expect_element/expect_window/target_bounds_screenshot_px: when the verdict computes correctionBackingPx, immediately applies it server-side (centering the painted bounds on the target's centre) and reports expect.appliedCorrection with the re-measured bounds and a verdictAfter. Draw + verify + fix in ONE call. Centre-alignment is right for rings/boxes ON a target; it is WRONG for an arrow or label that deliberately points at the target from beside it -- leave this off there and use the reported correction yourself if needed."]
    ]

    private static let pathProperties: [String: Any] = [
        "path_data": ["type": "string", "maxLength": DrawingDefaults.maxSVGPathCharacters, "description": "SVG path data in the selected top-left-origin coordinate_space. Supports absolute/relative M L H V C S Q T A Z, implicit repeats, curves, arcs, and closed subpaths. The source values are stored with a scale-to-backing-pixels transform."],
        "stroke_color": ["type": "string", "description": "Stroke color name or hex. Defaults to orange when no fill-only intent is expressed."],
        "stroke_width": ["type": "number", "minimum": 0, "description": "Stroke width in backing pixels. Set 0 for fill-only art."],
        "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Stroke opacity; default 1."],
        "fill_color": ["type": "string", "description": "Optional fill color name or hex."],
        "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Fill opacity; default 1."],
        "fill_rule": ["type": "string", "enum": ["nonzero", "evenodd"], "description": "SVG fill rule; default nonzero."],
        "dash": ["type": "array", "maxItems": DrawingDefaults.maxDashElements, "items": ["type": "number", "exclusiveMinimum": 0], "description": "Optional repeating dash lengths in backing pixels."]
    ]

    private static let imageProperties: [String: Any] = [
        "image_path": ["type": "string", "description": "Absolute path to a PNG/JPEG/HEIC/TIFF raster. Alpha is preserved; pixels are decoded into memory once and the path is not retained."],
        "x": ["type": "number", "description": "Top-left X in the selected coordinate_space."],
        "y": ["type": "number", "description": "Top-left Y in the selected coordinate_space."],
        "width": ["type": "number", "exclusiveMinimum": 0, "description": "Optional output width in the selected coordinate_space. Omit one dimension and it is derived from the raster's true pixel aspect ratio in backing pixels, for every coordinate_space -- so a normalized width on a non-square display still yields an unstretched image, and the derived dimension may exceed the display. Omit both for intrinsic backing-pixel size."],
        "height": ["type": "number", "exclusiveMinimum": 0, "description": "Optional output height in the selected coordinate_space. Omitting it derives the height from width and the raster's true pixel aspect ratio; see width."],
        "rotation_degrees": ["type": "number", "description": "Clockwise rotation around image center; default 0."],
        "opacity": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Overall opacity; default 1. Fully transparent images are rejected because they cannot be shown or verified."]
    ]

    private static let textProperties: [String: Any] = [
        "text": ["type": "string", "minLength": 1, "maxLength": DrawingDefaults.maxTextCharacters, "description": "Text to draw; line breaks are supported. The combined text length, font_size, and padding_px must fit the renderer's conservative layout budget."],
        "x": ["type": "number", "description": "Top-left X in the selected coordinate space."],
        "y": ["type": "number", "description": "Top-left Y in the selected coordinate space."],
        "font_size": ["type": "number", "exclusiveMinimum": 0, "description": "System font size in backing pixels. Combined with text length and padding_px, it must fit the renderer's layout budget."],
        "color": ["type": "string", "description": "Text color name or hex; defaults to white."],
        "background_color": ["type": "string", "description": "Optional background color name or hex."],
        "background_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Background opacity; default 1."],
        "padding_px": ["type": "number", "minimum": 0, "description": "Padding around the text in backing pixels; default 0. Combined with text length and font_size, it must fit the renderer's layout budget."],
        "opacity": ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Text opacity; default 1."]
    ]

    private static let shapeProperties: [String: Any] = [
        "shape": ["type": "string", "enum": ["circle", "ellipse", "rect"], "description": "Which shape to draw. circle requires center_x/center_y/radius; ellipse requires center_x/center_y/radius_x/radius_y; rect requires width/height plus EITHER x/y (top-left corner) OR center_x/center_y (centre) -- supplying both position forms, or neither, is rejected."],
        "center_x": ["type": "number", "description": "Centre X in the selected coordinate_space. Required for circle/ellipse; for rect it is an alternative to x/y (top-left corner) -- supply one position pair, not both."],
        "center_y": ["type": "number", "description": "Centre Y in the selected coordinate_space. Required for circle/ellipse; for rect it is an alternative to x/y (top-left corner) -- supply one position pair, not both."],
        "radius": ["type": "number", "exclusiveMinimum": 0, "description": "circle only: radius in the selected coordinate_space. Radius is scaled per axis, not as a point, so under coordinate_space='normalized' on a non-square display a single radius yields an ELLIPSE whose radius is that fraction of each axis; under backing_pixels/screenshot_pixels it stays a true circle."],
        "radius_x": ["type": "number", "exclusiveMinimum": 0, "description": "ellipse only: X radius in the selected coordinate_space."],
        "radius_y": ["type": "number", "exclusiveMinimum": 0, "description": "ellipse only: Y radius in the selected coordinate_space."],
        "width": ["type": "number", "exclusiveMinimum": 0, "description": "rect only: width in the selected coordinate_space."],
        "height": ["type": "number", "exclusiveMinimum": 0, "description": "rect only: height in the selected coordinate_space."],
        "x": ["type": "number", "description": "rect only: top-left X in the selected coordinate_space; alternative to center_x/center_y (supply one position pair, not both)."],
        "y": ["type": "number", "description": "rect only: top-left Y in the selected coordinate_space; alternative to center_x/center_y (supply one position pair, not both)."]
    ]

    /// The `{x, y, width, height}` rect shape shared, field-for-field
    /// identical, by `get_annotation_bounds`'s `target_bounds_screenshot_px`
    /// and `verify_annotation`'s new `target_bounds_screenshot_px` -- both
    /// name the exact same thing (a UI element's bounds, measured in one
    /// screenshot's own pixels) and are compared against the exact same kind
    /// of painted-bounds rectangle, so a second, independently maintained
    /// copy of this shape is how the two tools would eventually drift apart
    /// on which fields are required or how `width`/`height` are bounded.
    private static let targetBoundsScreenshotPxShape: [String: Any] = [
        "x": ["type": "number"], "y": ["type": "number"],
        "width": ["type": "number", "minimum": 0], "height": ["type": "number", "minimum": 0]
    ]

    /// Opt-in collision avoidance is intentionally exposed only on the three
    /// tools used for the common highlight-plus-label workflow. It is not part
    /// of `sharedDrawProperties`: keeping it separate preserves draw_path and
    /// draw_image as unrestricted stacking primitives, and keeps per-item batch
    /// placement impossible (a batch moves as one annotation).
    private static let avoidanceProperties: [String: Any] = [
        "avoid": [
            "type": "array",
            "minItems": 1,
            "maxItems": DrawingDefaults.maxAvoidedAnnotations,
            "uniqueItems": true,
            "items": ["type": "string", "minLength": 1, "maxLength": 128],
            "description": "Existing annotation IDs this new annotation must not overlap. At draw-time, Chalkboard measures exact painted bounds with the live renderer, keeps the requested placement when already clear, or searches nearby for a clear on-screen position and moves the whole new annotation there with an 8 backing-pixel gap. If its bounded search cannot find one, nothing is drawn. The response reports the exact final placement and offset used. This is a one-time draw-time layout decision, not a persistent constraint: later update_annotation calls or independently moving/resizing anchors can introduce overlap again. Omit avoid to retain unrestricted intentional stacking and the legacy response."
        ]
    ]

    /// `draw_shape` reuses `pathProperties` for its stroke/fill/opacity/dash/
    /// fill_rule styling -- every one of those arguments passes straight
    /// through to the same vector renderer draw_path uses. `path_data` itself
    /// is deliberately excluded: draw_shape always computes its own path from
    /// `shape`'s geometry, so advertising `path_data` as a usable parameter
    /// here would imply a caller-supplied path is honoured when it is in fact
    /// always overwritten.
    private static let pathStyleProperties: [String: Any] = {
        var properties = pathProperties
        properties.removeValue(forKey: "path_data")
        return properties
    }()

    private static func merged(_ dictionaries: [[String: Any]]) -> [String: Any] {
        dictionaries.reduce(into: [:]) { result, dictionary in
            for (key, value) in dictionary { result[key] = value }
        }
    }

    /// `draw_batch`'s per-item schema, where EVERY item type's properties
    /// share one flat object because JSON Schema cannot express "these fields
    /// depend on `type`" without a oneOf the MCP clients here do not reliably
    /// honour.
    ///
    /// WHY THIS EXISTS RATHER THAN A BARE `merged([...])`: `merged` is
    /// last-writer-wins, and four keys are claimed by more than one item type
    /// -- `x`/`y` by image, text, AND rect shapes; `width`/`height` by image
    /// AND rect shapes. A bare merge therefore silently published ONE type's
    /// wording as if it were the whole story. That is not cosmetic: adding
    /// `shapeProperties` to this merge made the batch schema describe `x` as
    /// "rect only", which tells a model that an `image` or `text` batch item
    /// must not pass `x` -- when both in fact REQUIRE it. A schema that
    /// misdescribes a required coordinate is precisely the kind of thing that
    /// puts a drawing in the wrong place, which is the bug class this tool
    /// exists to eliminate.
    ///
    /// So the shared keys are rewritten here, after the merge, with wording
    /// that names each item type that uses them. `MCPToolCatalogTests` pins
    /// that: if a future item type claims one of these keys, the test fails
    /// rather than letting the description quietly narrow again.
    /// The four per-item property dictionaries, paired with the `type` value
    /// each one belongs to, so the collision set below can be DERIVED rather
    /// than hand-listed. Hand-listing it was itself the bug: the first
    /// version of this guard enumerated x/y/width/height and silently missed
    /// `opacity`, which image and text both claim.
    private static let batchItemContributors: [(type: String, properties: [String: Any])] = [
        ("path", pathProperties), ("image", imageProperties),
        ("text", textProperties), ("shape", shapeProperties)
    ]

    /// Every key claimed by more than one item type, together with the types
    /// claiming it -- computed from the dictionaries themselves, so adding a
    /// property to any of them cannot quietly create an undescribed collision.
    /// `MCPToolCatalogTests` asserts each of these keys' published description
    /// names every type listed here, which fails the build for a new collision
    /// nobody wrote a union description for.
    static let batchItemSharedKeyContributors: [String: [String]] = {
        var claims: [String: [String]] = [:]
        for (type, properties) in batchItemContributors {
            for key in properties.keys { claims[key, default: []].append(type) }
        }
        return claims.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }()

    static var batchItemSharedKeys: [String] { batchItemSharedKeyContributors.keys.sorted() }

    /// `draw_batch` publishes ONE flat property object covering every item
    /// type, because JSON Schema cannot express "these fields depend on
    /// `type`" without a oneOf the MCP clients here do not reliably honour.
    ///
    /// WHY THIS EXISTS RATHER THAN A BARE `merged([...])`: `merged` is
    /// last-writer-wins, so for every key in `batchItemSharedKeyContributors`
    /// a bare merge publishes ONE type's wording as if it were the whole
    /// story. That is not cosmetic -- it is a schema that misdescribes a
    /// required field, which is exactly how a drawing ends up in the wrong
    /// place or omitted. Adding shape properties made `x` read "rect only",
    /// telling a model that an `image` or `text` item must not send `x` when
    /// both require it; `opacity` separately read "Text opacity" for image
    /// items, whose opacity has different semantics (a fully transparent
    /// image is rejected outright). Each shared key is therefore rewritten
    /// below with wording that names every type that uses it.
    static let batchItemProperties: [String: Any] = {
        var properties = merged(batchItemContributors.map(\.properties) + [
            ["type": ["type": "string", "enum": ["path", "image", "text", "shape"]]]
        ])
        properties["x"] = ["type": "number", "description": "image/text items: top-left X in the selected coordinate_space (required). shape items with shape='rect': top-left X, as the alternative to center_x/center_y -- supply one position pair, not both. Unused by path items, whose coordinates live inside path_data."]
        properties["y"] = ["type": "number", "description": "image/text items: top-left Y in the selected coordinate_space (required). shape items with shape='rect': top-left Y, as the alternative to center_x/center_y -- supply one position pair, not both. Unused by path items, whose coordinates live inside path_data."]
        properties["width"] = ["type": "number", "exclusiveMinimum": 0, "description": "image items: optional output width in the selected coordinate_space; omit one dimension and it is derived from the raster's true pixel aspect ratio in backing pixels, and omit both for intrinsic backing-pixel size. shape items with shape='rect': required width in the selected coordinate_space."]
        properties["height"] = ["type": "number", "exclusiveMinimum": 0, "description": "image items: optional output height in the selected coordinate_space; omitting it derives the height from width and the raster's true pixel aspect ratio. shape items with shape='rect': required height in the selected coordinate_space."]
        properties["opacity"] = ["type": "number", "exclusiveMinimum": 0, "maximum": 1, "description": "Overall opacity of this item; default 1. image items: a fully transparent image is rejected outright, because it can neither be shown nor verified. text items: applies to the glyphs and compounds with background_opacity for the label's backing rectangle."]
        return properties
    }()

    /// The catalog is the one source of truth for the public argument
    /// surface.  Keep the runtime boundary derived from it too: maintaining a
    /// second hand-written allow-list next to these schemas is how a newly
    /// documented argument would eventually be rejected (or, worse, a removed
    /// argument silently accepted) by the server.
    static func validateArguments(toolName: String, args: [String: Any]) -> String? {
        guard let allowed = allowedArgumentKeys(for: toolName) else {
            // Preserve the normal dispatcher's more useful unknown-tool error.
            return nil
        }

        // This parameter was deliberately retired rather than ignored. Check
        // it before generic unknown-key validation so existing callers retain
        // the actionable migration error that says nothing was drawn.
        if toolsRejectingRetiredDuration.contains(toolName),
           let message = DrawRequest.rejectDurationSecondsIfSupplied(args: args) {
            return message
        }

        if let message = unknownArgumentMessage(
            unknownKeys: Set(args.keys).subtracting(allowed),
            context: toolName,
            allowedKeys: allowed
        ) {
            return message
        }

        // Validate the cheap, structural part of collision avoidance at the
        // protocol boundary. In particular, draw_batch may otherwise decode
        // raster items and build every primitive before DrawRequest.finish
        // sees a malformed top-level `avoid` value.
        if toolsSupportingAvoidance.contains(toolName) {
            switch DrawRequest.parseAvoidanceArguments(args) {
            case .failure(let message): return message
            case .success: break
            }
        }

        guard toolName == "draw_batch",
              let items = args["items"] as? [[String: Any]] else {
            // The handler supplies the established type/size error for an
            // absent or malformed items value.
            return nil
        }
        for (index, item) in items.enumerated() {
            if let message = DrawRequest.rejectDurationSecondsIfSupplied(args: item) {
                return "items[\(index)]: \(message)"
            }
            guard let type = (item["type"] as? String)?.lowercased(),
                  let itemAllowed = batchItemAllowedKeysByType[type] else {
                // The handler retains responsibility for the established
                // missing/invalid type error.
                continue
            }
            if let message = unknownArgumentMessage(
                unknownKeys: Set(item.keys).subtracting(itemAllowed),
                context: "items[\(index)] (type '\(type)')",
                allowedKeys: itemAllowed
            ) {
                return message
            }
        }
        return nil
    }

    private static let toolsRejectingRetiredDuration: Set<String> = [
        "draw_path", "draw_shape", "draw_image", "draw_text", "draw_batch", "highlight_element"
    ]

    private static let toolsSupportingAvoidance: Set<String> = [
        "draw_shape", "draw_text", "draw_batch"
    ]

    private static let batchItemAllowedKeysByType: [String: Set<String>] = [
        "path": Set(pathProperties.keys).union(["type"]),
        "image": Set(imageProperties.keys).union(["type"]),
        "text": Set(textProperties.keys).union(["type"]),
        "shape": Set(pathStyleProperties.keys).union(shapeProperties.keys).union(["type"])
    ]

    private static func allowedArgumentKeys(for toolName: String) -> Set<String>? {
        guard let tool = tools.first(where: { $0["name"] as? String == toolName }),
              let schema = tool["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            return nil
        }
        return Set(properties.keys)
    }

    private static func unknownArgumentMessage(unknownKeys: Set<String>,
                                               context: String,
                                               allowedKeys: Set<String>) -> String? {
        guard !unknownKeys.isEmpty else { return nil }
        let unknown = unknownKeys.sorted().map { "'\($0)'" }.joined(separator: ", ")
        guard !allowedKeys.isEmpty else {
            return "\(context) accepts no arguments; remove \(unknown)."
        }
        return "Unknown argument(s) for \(context): \(unknown). Allowed arguments: \(allowedKeys.sorted().joined(separator: ", "))."
    }

    static let tools: [[String: Any]] = {
        let definitions: [[String: Any]] = [
        [
            "name": "get_screens",
            "description": "Returns current display IDs and exact backing-pixel geometry. Call before drawing. If measuring from an uncropped full-display screenshot, use coordinate_space=screenshot_pixels with that exact measured image version's dimensions; do not copy resized-image coordinates into backing_pixels. Drawing coordinates are always relative to the selected display's OWN top-left corner; the returned appKitFrame/windowServerFrame describe only where a display sits on the desktop and must never be added to drawing coordinates.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "get_overlay_state",
            "description": "Reports Chalkboard's per-screen input policy and window state. A visible overlay is self-attested as click-through when ignoresMouseEvents is true, but an external click dispatcher must explicitly honor that state; this does not prove raw framebuffer pixels or occlusion. Also returns screenshotSpaces, every space register_screenshot_space/calibrate_screenshot_space has registered (each entry the same payload those tools return), so a caller can see what is already registered instead of guessing an id -- a space whose display no longer matches its recorded configuration is still listed, marked stale: true with the reason, rather than silently omitted.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "get_accessibility_status",
            "description": accessibilityStatusDescription,
            "inputSchema": ["type": "object", "properties": [
                "request_permission": ["type": "boolean", "description": requestPermissionDescription]
            ]]
        ],
        [
            "name": "register_screenshot_space",
            "description": "Registers a named screenshot space -- a mapping between one display's backing pixels and one screenshot's pixel grid -- that screenshot_space (on every draw_* tool, get_annotation_bounds, and verify_annotation) can then reference instead of re-declaring coordinate_space/screenshot_width/screenshot_height/screen_id on every single call. Supply EXACTLY ONE dimension source: screenshot_path (Chalkboard decodes the file and MEASURES its real pixel size -- provenance 'measured', the strongest evidence a space can carry) OR screenshot_width together with screenshot_height (you DECLARE them -- provenance 'declared', no stronger than today's per-call screenshot_width/screenshot_height guess). Supplying both screenshot_path and screenshot_width/screenshot_height is rejected, naming which to drop; supplying neither is rejected, listing the ways to get a space -- screenshot_path here, screenshot_width/screenshot_height here, or calibrate_screenshot_space when neither a file nor a confident declaration is available: its drawn-fiducial handshake when Chalkboard's own pixels reach your screenshots, or its action='elements' route, which measures the TARGET APP's own UI elements through the same element lookup highlight_element uses and so still works when they never do. The resulting dimensions must describe a plausible full-display capture of the resolved display (matching its aspect ratio within rounding tolerance, never larger than it) or the call is rejected. screen_id names which display this is a screenshot of; when the dimensions could plausibly be a full-display capture of MORE than one connected display and screen_id is omitted, the call is rejected for ambiguity, listing the candidate displays, exactly as an unqualified screenshot_pixels draw call already is. On success, returns the registered space's payload (screenshotSpace id, screenId, screenshotPx, screenBackingPx, scaleToBackingPx, provenance) plus a note explaining what the id is for and that a later display-configuration change -- a resolution or HiDPI-scale change, or a disconnect -- invalidates it; register again for that display when it does.",
            "inputSchema": ["type": "object", "properties": [
                "screen_id": ["type": "string", "maxLength": 128, "description": "The display this is a screenshot of, from get_screens (exact id or positional index, resolved the same way screen_id is everywhere else). Optional when the dimensions can only plausibly describe one currently connected display; required -- and its absence rejected with a candidate list -- when they could plausibly describe more than one."],
                "screenshot_path": ["type": "string", "description": "Absolute path to the exact screenshot image file (PNG/JPEG/HEIC/TIFF) to measure. Chalkboard decodes it and reads its REAL pixel dimensions -- provenance 'measured'. Mutually exclusive with screenshot_width/screenshot_height; supplying both is rejected, naming which one to drop."],
                "screenshot_width": ["type": "integer", "minimum": 1, "description": "The screenshot's pixel width, DECLARED rather than measured -- provenance 'declared', exactly as strong as today's per-call screenshot_width guess and no stronger. Must be supplied together with screenshot_height; supplying only one of the pair is rejected. Mutually exclusive with screenshot_path."],
                "screenshot_height": ["type": "integer", "minimum": 1, "description": "The screenshot's pixel height, paired with screenshot_width; see that field. Mutually exclusive with screenshot_path."]
            ]]
        ],
        [
            "name": "calibrate_screenshot_space",
            "description": "Solves a screenshot space BY MEASUREMENT, for the case register_screenshot_space cannot help with: you have neither a screenshot file to decode nor confident, exact pixel dimensions to declare. This exists because a caller generally cannot learn its own screenshot's true pixel dimensions any other way -- the capture tool that produced it may not report them, and a client in the middle may have downsampled the image before the model ever saw it.\n\nTWO ROUTES, and one question decides which you need: do CHALKBOARD'S OWN drawn pixels reach your screenshots?\n- YES, or you have not found out yet: take the DRAWN-FIDUCIAL route, steps 1-3 below -- a three-step handshake (action='begin', then action='resolve' or action='cancel'), one MCP call per step, driven entirely by this description and each step's own response.\n- NO -- your screenshots are of THIS display (this machine's own menu bar and Dock are visible in them) and yet Chalkboard's fiducials never appear in them, even with capture-debug on: take the ELEMENT route, action='elements', step 4 below. It is a single stateless call and needs NO Chalkboard pixels to be visible to anybody.\n\n1. action='begin' (screen_id optional; set_capture_visible defaults true): paints four high-contrast crosshair-in-a-circle fiducial markers -- labelled TL, TR, BL, BR at each corner's 10%/90% inset -- as ordinary global annotations on the chosen display, plus a short random verification token at its centre, through the SAME drawing pipeline draw_batch uses. Returns the calibration id (spelled calibrationId in the response payload; pass it back as the snake_case calibration_id ARGUMENT -- this tool rejects undocumented argument names, so the response spelling is not accepted as one), the token, a table of each marker's label and normalized position, and the drawn annotation ids. Take a screenshot of that display with your OWN screenshot tool; confirm the token you read there matches (proof this is THIS calibration, not a stale image); read each marker's CENTRE in that screenshot's own pixels; then call action='resolve'. If the markers do not appear in your screenshot at all -- absent, as opposed to blurry or hard to read -- that capture path is not showing this app's pixels and no retake will change that, so this handshake cannot work for it: switch to action='elements' (step 4), which measures the TARGET APP's own elements and needs nothing of Chalkboard's to be visible, or to register_screenshot_space with screenshot_path if you hold the screenshot as a FILE. When set_capture_visible is true (the default), this also turns capture-debug on exactly as set_capture_visible(true) does -- turning the menu-bar icon orange and auto-reverting after five minutes -- and records the value that preceded the handshake so the end of the handshake can restore it. That restore is REFERENCE-COUNTED across displays: capture-debug goes back to the recorded value only when the LAST outstanding calibration resolves or cancels, so a calibration still running on another display deliberately keeps it ON rather than having it switched off underneath the screenshot that handshake is still waiting for. Every resolve/cancel response states which of the two happened, so never infer it. Only one calibration may be outstanding per display; a second begin for the same display clears the first and says so.\n\n2. action='resolve' (calibration_id required): report markers, ALL FOUR {label, x, y} observations -- TL, TR, BL and BR, each exactly once, all of them in this ONE call -- of where you saw each fiducial's centre in your own screenshot's pixels, and/or observed_width/observed_height if the dimensions are already known some other way. The complete set is MANDATORY, not a target: three markers are not a weaker solve, they are a rejected call. Each axis is deliberately measured TWICE, by two markers that share a normalized coordinate, and comparing those two independent readings is the only thing that can catch a misread -- a partial set removes exactly that check. Observations are never accumulated across calls either: a second resolve cannot add the marker a first one left out. If you cannot read one of the four crosshairs in your screenshot, do not send a short set -- re-take the screenshot, or call action='cancel' and begin again. markers alone solves the dimensions from the observed marker spread (provenance 'observed'), and that solve is validated against the calibrated display's own geometry -- it must match its aspect ratio within rounding tolerance and must not be larger than it -- before anything is registered. observed_width/observed_height alone DECLARES them outright (provenance 'declared' -- no stronger than a manual guess). Supplying BOTH is a CROSS-CHECK, not a contradiction: the marker-solved and declared values are compared, and disagreement beyond the solver's own tolerance is REJECTED, naming both numbers -- that exact disagreement is the signature of a top-left-anchored, aspect-preserving crop, which marker geometry alone cannot see (marker geometry can only observe the region BETWEEN the markers, never the image's extent beyond them). If they agree, provenance stays 'observed' and the response says the cross-check passed. Supplying neither is rejected -- there is nothing to resolve from. EVERY resolve call clears this calibration's fiducials, a rejected one exactly as much as a successful one, so a failed reading never leaves markers stranded on your screen; capture-visible then follows the last-one-out rule described in step 1. Because a rejection consumes the calibration this way, every rejection message states explicitly whether this calibration_id is still usable or a fresh action='begin' is required -- read that sentence rather than assuming either.\n\n3. action='cancel' (calibration_id required): clears the fiducials without registering anything, and restores capture-visible under the same last-one-out rule as resolve.\n\n4. action='elements' (app and elements required; screen_id optional; single call -- nothing is painted, no calibration is left outstanding, and there is nothing to cancel afterwards): calibrates from the TARGET APPLICATION's own on-screen UI elements instead of Chalkboard's drawn crosshairs. Name 1-8 of them by label exactly as highlight_element does, and observe each one in EXACTLY ONE of two ways: by CENTRE (observed_x/observed_y, where you see that element's centre in your own screenshot) or by BOUNDS (observed_left/observed_top/observed_right/observed_bottom, where you see that element's bounding box in your own screenshot). Chalkboard resolves each label to that element's live on-screen rect and turns it into correspondences -- a CENTRE observation pairs the rect's centre with your point and contributes ONE; a BOUNDS observation pairs the rect's top-left corner with your observed left/top and its bottom-right corner with your observed right/bottom, contributing TWO -- then solves observed = scale * true + origin from all of them and registers the space with provenance 'observed', the same provenance the marker route earns, because this is equally a measurement, just of somebody else's pixels. WHAT THE SOLVE NEEDS IS TWO POINTS, NOT TWO ELEMENTS: ONE BOUNDS-OBSERVED ELEMENT IS A COMPLETE CALIBRATION ON ITS OWN, while a single centre-observed element supplies one point and is rejected. Mixing the forms across elements is fine and is the cheapest way to earn the third point that cross-checks the fit; supplying BOTH forms for the SAME element, only SOME of the four bounds fields, neither form, or a box whose right/bottom is not past its left/top, is rejected by name and registers nothing. The response names this route in its method field, so a later reader can tell WHICH kind of 'observed' a space is, and reports every element it resolved (label, role, which observation form you used, and the resolved-versus-observed points -- both corners for a bounds element) alongside the solver's residuals -- read those residuals before trusting the space, since they are the only visible measure of how well your readings agreed.\n\nWHEN TO REACH FOR IT: Chalkboard's drawn fiducials do NOT appear in your screenshots, yet those screenshots ARE of this same display -- this machine's own menu bar and Dock are visible in them, so this is not a remote desktop or some other framebuffer. A capture tool that composites only the windows of the applications IT was granted will never show Chalkboard's overlay no matter what set_capture_visible does: that filtering happens inside that tool, above the OS-level window-sharing flag set_capture_visible toggles, so there is nothing left at the OS level for Chalkboard to switch on for you. This route steps around that completely because it needs NO Chalkboard pixels in anybody's capture -- its fiducials belong to the app your capture tool WAS granted, which is precisely the app whose pixels you can already see.\n\n\(calibrationElementsPermissionDescription)\n\nWHICH SHAPE OF CALL TO MAKE is decided by what the app actually exposes to element lookup, so establish that FIRST -- the two cases need different calls, and the wrong one is unsatisfiable rather than merely worse.\n\nAPPS WITH NAMEABLE INNER CONTROLS (buttons, toolbar items, fields you can both name and see in your screenshot): PICK 3 OR MORE ELEMENTS SPREAD WIDELY ACROSS THE DISPLAY -- opposite corners of a window, or a toolbar item and a status-bar item -- and observe each one's centre. Points sitting near each other are REJECTED and nothing is registered: the short baseline between them divides your reading error by a small number and multiplies it into the solved scale, which is the same reason the drawn markers sit at the 10%/90% insets instead of side by side. The gate is concrete -- on each axis, the widest TRUE separation between any two of your points must be at least 25% of the display's size on that axis. Two points is the bare minimum the solver accepts, and at exactly two the fit is exact by construction on each axis: nothing disagrees with it, so a mislabelled or misread point cannot be caught. The third widely separated point is the first one that can disagree, which is the identical reason the marker route demands all four markers rather than two diagonals.\n\nAPPS THAT EXPOSE NOTHING BUT THEIR OWN WINDOW -- a remote-desktop or VNC client, a media player, a game, any canvas/video surface that paints one picture and publishes no labelled child controls: element lookup finds exactly ONE thing in such an app, the window itself, and no amount of re-searching will produce a second fiducial there. THAT ONE WINDOW IS STILL ENOUGH. Pass it as a SINGLE element observed by BOUNDS (observed_left/observed_top/observed_right/observed_bottom): a rect is TWO points -- its top-left and bottom-right corners -- whose true separation is known on both axes, which is exactly what the solve needs, and a window of that kind is large, so the 25% baseline gate is cleared comfortably rather than scraped past. Window edges are high-contrast and unambiguous in a screenshot, so reading them is if anything easier than judging a control's painted centre. This is the INTENDED call for those applications, not a degraded fallback: do not hunt for a second fiducial in an app that has none, and do not fall back to a 'declared' space -- a bare assertion -- when the window in front of you is a perfectly good ruler.\n\n\(calibrationWindowFrameCaveat)\n\nPRECISION, stated plainly: an element's bounds are the frame the application REPORTS for it, which can differ by a pixel or two from the pixels it actually paints (padding, focus rings, shadows), so this route is typically SLIGHTLY LESS precise than reading a purpose-drawn crosshair and its residuals are usually larger. Reach for it when the drawn route cannot work at all, not in preference to a crosshair you can actually see.\n\nLIMIT (read before trusting ANY calibrated space over a measured file): both routes prove the mapping between their fiducials' spacing and the display's geometry, and both run the same origin-residual check, which catches a crop that shifts the image's own origin -- but NEITHER can detect a crop anchored at the image's own top-left corner that also happens to preserve the display's aspect ratio, because that shape is invisible to fiducial positions alone (drawn markers and app elements alike witness only the region BETWEEN themselves, never the image's extent beyond them). The element route does spread that origin check wider, since its fiducials can sit anywhere on the display rather than at four fixed insets, but it does not close the blind spot. register_screenshot_space with screenshot_path is STRICTLY STRONGER than either whenever a screenshot file is available, because decoding the file measures the image's true extent directly instead of extrapolating it from fiducial spacing.",
            "inputSchema": ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["begin", "resolve", "cancel", "elements"], "description": "Which route, and which step of it, to run. The first three are the DRAWN-FIDUCIAL handshake: 'begin' paints the fiducials and starts a calibration, 'resolve' reports observations and, on success, registers the resulting screenshot space, 'cancel' discards an outstanding calibration without registering anything. 'elements' is the SEPARATE, single-call ELEMENT route: it uses the target app's own UI elements as the fiducials, paints nothing, leaves no calibration outstanding, and so has nothing to cancel -- reach for it when Chalkboard's own drawn pixels never show up in your screenshots even though those screenshots are of this display. See the tool description for both routes and what each step requires."],
                "screen_id": ["type": "string", "maxLength": 128, "description": "begin and elements, with DIFFERENT defaults. begin: the display to calibrate, from get_screens (exact id or positional index); omitted defaults the same way screen_id does elsewhere. elements: omitting it DERIVES the display from the resolved elements themselves -- they must all land on one display -- instead of defaulting to main, because the elements are better evidence of which display the screenshot is of than a default could be; supply it only to ASSERT which display you expect, and any element resolving elsewhere is then rejected by name. Ignored for resolve/cancel, which are scoped by calibration_id instead."],
                "set_capture_visible": ["type": "boolean", "description": "begin only; default true. When true, turns capture-debug on exactly as set_capture_visible(true) does, so an external screenshot tool that omits Chalkboard's own overlay by default can still see the fiducials, and records the value that preceded the handshake. Restoring it is reference-counted, not per-call: the LAST outstanding calibration to resolve/cancel (this one, or a concurrent one on another display) is the one that restores it, and each of those responses says whether it restored the flag or deliberately left it on for a handshake still in flight. Turning it on also turns the menu-bar icon orange and arms a five-minute auto-revert to OFF, which fires if resolve/cancel is never called. action='elements' paints nothing at all, so it has no fiducials to reveal and never touches this flag -- an element calibration works with capture-debug off."],
                "calibration_id": ["type": "string", "description": "resolve/cancel only (required for both): the id begin returned, identifying which outstanding calibration this call resolves or cancels. action='elements' is stateless and single-shot -- it issues no calibration id and leaves nothing outstanding -- so it neither takes nor needs this."],
                "observed_width": ["type": "integer", "minimum": 1, "description": "resolve only: the screenshot's pixel width, if already known some other way. Supplied alone, DECLARES it outright (provenance 'declared'). Supplied together with markers, cross-checks the marker solve instead of replacing it -- disagreement beyond tolerance is rejected, naming both numbers. Must be supplied together with observed_height."],
                "observed_height": ["type": "integer", "minimum": 1, "description": "resolve only: paired with observed_width; see that field."],
                "app": ["type": "string", "description": calibrationElementsAppDescription],
                // minItems is 1 because the solver accepts 1 -- the arity
                // lesson of `calibrationMarkersDescription` cuts both ways,
                // and one BOUNDS-observed element already carries the two
                // points the solve needs, so advertising 2 here would
                // reject the single-window call this route exists to answer
                // (the Shadow PC remote-desktop client exposes exactly one
                // labelled element; see `calibrationBoundsObservationShape`).
                // The reason 3 points is still much better (at 2 the
                // per-axis fit is exact by construction and no reading can
                // be cross-checked), and the reason ONE CENTRE element is
                // still not enough, both live in the prose -- neither a
                // "prefer more" argument nor a "these two groups are
                // exclusive" rule is expressible as a schema number.
                //
                // `required` is therefore just ["label"]: every observation
                // property is optional at the JSON-Schema level because a
                // schema cannot say "exactly one of these two GROUPS", and
                // advertising a requirement the handler does not enforce is
                // the same defect as advertising an arity the solver does
                // not accept. The handler rejects both forms, a partial
                // box, neither form, and an inverted/zero-area box with
                // prose naming the fix.
                "elements": ["type": "array", "minItems": 1, "maxItems": 8, "description": calibrationElementsDescription, "items": [
                    "type": "object",
                    "properties": merged([elementQueryShape, calibrationBoundsObservationShape, [
                        "observed_x": ["type": "number", "description": "CENTRE observation -- the alternative to the observed_left/observed_top/observed_right/observed_bottom box, and supplied together with observed_y or not at all. Where this element's CENTRE appears in YOUR OWN screenshot's pixels, horizontally -- that image's coordinates, never the display's. Read the centre of the control as PAINTED; it is compared against the centre of the rect the application reports for the same element. A centre observation is ONE point, so an element observed this way cannot calibrate on its own: pair it with another element, or observe a large element by BOUNDS instead, which is two points."],
                        "observed_y": ["type": "number", "description": "Where this element's CENTRE appears in YOUR OWN screenshot's pixels, vertically; see observed_x."]
                    ]]),
                    "required": ["label"],
                    "additionalProperties": false
                ]],
                // minItems MUST equal maxItems here: `ScreenshotCalibration.solve`
                // requires the complete TL/TR/BL/BR set and rejects anything
                // else. See `calibrationMarkersDescription` for the bug an
                // advertised `minItems: 1` caused.
                "markers": ["type": "array", "maxItems": 4, "minItems": 4, "description": calibrationMarkersDescription, "items": [
                    "type": "object",
                    "properties": [
                        "label": ["type": "string", "description": "Which fiducial this observation is for: TL, TR, BL, or BR, matching begin's marker table."],
                        "x": ["type": "number", "description": "The marker's centre X in your screenshot's own pixel coordinates."],
                        "y": ["type": "number", "description": "The marker's centre Y in your screenshot's own pixel coordinates."]
                    ],
                    "required": ["label", "x", "y"],
                    "additionalProperties": false
                ]]
            ], "required": ["action"]]
        ],
        [
            "name": "draw_path",
            "description": "The vector free-draw primitive. Renders arbitrary SVG path geometry with independent stroke, fill, opacity, dash, and fill rule. Construct arrows, callouts, handwriting, diagrams, and arbitrary complex shapes through path_data. For a plain circle, ellipse, or rectangle, prefer draw_shape's center/radius parameters over hand-written arc commands -- every hand-written arc is a chance to mis-center it.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, pathProperties]),
                "required": ["path_data"]
            ]
        ],
        [
            "name": "draw_shape",
            "description": "Draws a circle, ellipse, or rectangle by centre and radius (or corner), instead of hand-assembling draw_path's raw SVG arc commands. Emits the identical closed-path vector geometry draw_path would, with the same stroke/fill/opacity/dash/fill_rule styling. See shape for the required fields per shape.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, pathStyleProperties, shapeProperties, avoidanceProperties]),
                "required": ["shape"]
            ]
        ],
        [
            "name": "draw_image",
            "description": "The raster free-draw primitive. Places arbitrary caller-rendered artwork with alpha, scale, rotation, and opacity. Use this for custom text, brushes, gradients, textures, heatmaps, or anything more naturally produced as pixels.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, imageProperties]),
                "required": ["image_path", "x", "y"]
            ]
        ],
        [
            "name": "draw_text",
            "description": "Draws first-class system text at a top-left coordinate with optional background, padding, and opacity. No caller-rendered bitmap is required.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, textProperties, avoidanceProperties]),
                "required": ["text", "x", "y", "font_size"]
            ]
        ],
        [
            "name": "highlight_element",
            "description": "Finds one running app's Accessibility element by label and draws a vector highlight around its live bounds -- rect (default), ellipse, or circle; see shape. This is the most accurate way to ring a UI element: the bounds come from the app itself, not from coordinates measured off a screenshot. Matching is exact by default; \(highlightAmbiguityDescription). By DEFAULT the highlight now tracks the element: see anchor.",
            "inputSchema": ["type": "object", "properties": [
                "label": ["type": "string", "minLength": 1, "maxLength": DrawingDefaults.maxHighlightLabelCharacters, "description": "Accessibility title, description, or value to match."],
                "app": ["type": "string", "description": highlightAppParamDescription],
                "role": ["type": "string", "description": "Optional raw Accessibility role, for example AXButton."],
                "match": ["type": "string", "enum": ["exact", "contains"], "description": "Label matching mode; exact is the default."],
                "occurrence": ["type": "integer", "minimum": 1, "description": "One-based match index in breadth-first discovery order (outermost elements first, NOT visual order), required when a label is ambiguous; \(occurrenceAmbiguityDetail). Supplying it short-circuits the walk at the Nth match and disables whole-tree ambiguity detection -- the result never proves the label was unique (the response says so via searchWasShortCircuited: true), so confirm placement with verify_annotation."],
                "max_nodes": ["type": "integer", "minimum": 1, "maximum": AccessibilityElementResolver.absoluteMaxNodes, "description": "Accessibility elements to visit before giving up; default \(AccessibilityElementResolver.defaultMaxNodes). The search is breadth-first and visits every element regardless of label/role, so this -- not a narrower query -- is what makes a large hierarchy reachable. Raise it together with timeout_seconds."],
                "timeout_seconds": ["type": "number", "minimum": AccessibilityElementResolver.minTraversalTimeoutSeconds, "maximum": AccessibilityElementResolver.maxTraversalTimeoutSeconds, "description": "Wall-clock budget for the whole traversal; default \(AccessibilityElementResolver.defaultTraversalTimeoutSeconds). A large app walks roughly 5,000 elements per second, so raising max_nodes without raising this just trades a node-cap error for a timeout."],
                "shape": ["type": "string", "enum": ["rect", "ellipse", "circle"], "description": "Highlight outline shape; default rect. ellipse is inscribed in the padded bounds (tangent to all four padded edges), so it traces a round or pill-shaped control's silhouette -- on a RECTANGULAR element it clips the corners, so use rect or circle when the whole element must be enclosed. circle FULLY ENCLOSES the element: it is concentric with it and its radius is half the element's diagonal plus padding_px, so no corner of the element sticks out of the ring."],
                "padding_px": ["type": "number", "minimum": 0, "description": "Outward rectangle padding in backing pixels; default 8. The stroke is centered on the outline, so ink extends stroke_width/2 INSIDE the traced path; keep padding_px at or above stroke_width/2 when the ink must not touch the element."],
                "anchor": ["type": "string", "enum": ["element", "window", "none"], "description": "How this highlight keeps up with the UI. \"element\" (DEFAULT): follow the element's window as it moves and resizes, AND re-run this same element lookup once the window settles, so the ring stays on the control even when the app REFLOWS its layout instead of scaling it -- this is the only mode that survives a reflow, and it is only as reliable as repeating this lookup (watch anchor.elementResolutionIssue). \"window\": follow the window's geometry only, never re-resolving the element; cheaper, but it drifts the moment the app reflows. \"none\": the pre-anchoring behavior -- resolve once at draw time and never move again; call highlight_element again yourself after the UI changes. Tracking is SAMPLED, not event-driven, so the ring trails the window slightly during an active drag and lands when it stops. If no window can be resolved for the element the highlight is still drawn, unanchored, and the response says so via anchor.reason -- the element itself resolved fine, so this never fails the call. Check anchor.state in list_annotations: \"hidden\" means the window is minimised, on another Space, or its app is hidden; \"lost\" means the window is gone. Neither deletes the annotation."],
                "anchor_resize": ["type": "string", "enum": ["pin", "scale"], "description": "Only meaningful with anchor=\"window\" -- REJECTED with anchor=\"element\" (which re-resolves the element's true bounds, so no resize policy applies) and with anchor=\"none\". See draw_path's anchor_resize for what pin and scale do."],
                "stroke_color": ["type": "string", "description": "Rectangle stroke color; color is accepted as an alias. Defaults to orange."],
                "color": ["type": "string", "description": "Alias for stroke_color; do not supply conflicting values."],
                "stroke_width": ["type": "number", "exclusiveMinimum": 0, "description": "Rectangle stroke width in backing pixels; default 4."],
                "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Stroke opacity; default 1."],
                "fill_color": ["type": "string", "description": "Optional rectangle fill color."],
                "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "Fill opacity; default 0.15 when fill_color is supplied."],
                "z": ["type": "integer", "description": "Paint order; higher values appear above lower values. Alias for z_index."],
                "z_index": ["type": "integer", "description": "Paint order alias; do not supply a conflicting z value."]
            ], "required": ["label"]]
        ],
        [
            "name": "draw_batch",
            "description": "Atomically adds 1–100 mixed free-draw path/image/text/shape primitives under one annotation ID (maximum \(DrawingDefaults.maxRasterImagesPerBatch) raster items / \(DrawingDefaults.maxRasterDecodedBytesPerBatch / (1_024 * 1_024)) MiB decoded raster data). All items appear, verify, and clear together; if any item is invalid, nothing is added.",
            "inputSchema": [
                "type": "object",
                "properties": merged([sharedDrawProperties, avoidanceProperties, [
                    "items": [
                        "type": "array", "minItems": 1, "maxItems": DrawingDefaults.maxBatchItems,
                        "items": [
                            "type": "object",
                            "properties": batchItemProperties,
                            "required": ["type"],
                            // The published flat schema admits the union of
                            // all item keys; validateArguments further
                            // narrows that union by each item's type before
                            // any raster decoding or annotation mutation.
                            "additionalProperties": false
                        ]
                    ]
                ]]),
                "required": ["items"]
            ]
        ],
        [
            "name": "update_annotation",
            "description": "Moves/restyles a live annotation without changing its ID. offset_x/offset_y are absolute backing-pixel offsets; supply at least one patch field. Text-only and path-only style fields are rejected for image/batch annotations rather than silently ignored. EVERY positional patch field is absolute BACKING PIXELS on the annotation's own display, regardless of the coordinate_space the original draw call used -- coordinates measured on a screenshot must be converted (multiply by the display's widthPx/screenshot_width) before patching, or the annotation teleports to the raw values.",
            "inputSchema": ["type": "object", "properties": merged([[
                "annotation_id": ["type": "string"],
                "offset_x": ["type": "number"], "offset_y": ["type": "number"],
                "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "z_index": ["type": "integer"],
                "anchor": ["type": "string", "enum": ["none", "window"], "description": "Changes what this annotation is anchored to. \"none\" DETACHES it and freezes it exactly where it is now -- it does not snap back to where it was originally drawn, and it stops following the window. \"window\" (re-)anchors it to whichever window of its own linked app it currently sits over, baselining from its present position so it does not jump; a global annotation with no app link is rejected, since there is no window to anchor to. Omit this to leave the existing anchor untouched."],
                "anchor_resize": ["type": "string", "enum": ["pin", "scale"], "description": "Changes the resize policy of an anchored annotation, re-baselining the reference frame to the window's current size so the drawing does not jump. REJECTED on an unanchored annotation, and with anchor=\"none\". See draw_path's anchor_resize for what pin and scale do."],
                "text": ["type": "string"],
                "x": ["type": "number", "description": "Text annotations only: new top-left X in absolute backing pixels on the annotation's own display -- NOT in the coordinate_space the original draw call used."],
                "y": ["type": "number", "description": "Text annotations only: new top-left Y in absolute backing pixels on the annotation's own display -- NOT in the coordinate_space the original draw call used."],
                "font_size": ["type": "number", "exclusiveMinimum": 0], "color": ["type": "string"],
                "background_color": ["type": "string"], "background_opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "padding_px": ["type": "number", "minimum": 0],
                "stroke_color": ["type": "string"], "stroke_width": ["type": "number", "minimum": 0],
                "stroke_opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "fill_color": ["type": "string"], "fill_opacity": ["type": "number", "minimum": 0, "maximum": 1]
            ]]), "required": ["annotation_id"]]
        ],
        [
            "name": "suspend_annotations",
            "description": "Acquires a short-lived suspension lease, ordering AI Chalkboard overlays out without clearing annotations or IDs. lease_seconds is 1...60 (default 15). Save the returned secret leaseToken and pass exactly it to resume_annotations. An optional fresh lowercase canonical UUID idempotency_key makes a retry from the same MCP server process instance return the same active lease. It is secret; reuse from another instance is rejected without revealing another lease token. clickSafeAtObservation is true only for the current live generation after bounded peer presentation settlement. This is a temporary click workaround, not true simultaneous highlight-and-click.",
            "inputSchema": ["type": "object", "properties": [
                "lease_seconds": ["type": "integer", "minimum": 1, "maximum": 60, "description": "Lease lifetime in seconds; default 15. It expires automatically if not released."],
                "idempotency_key": ["type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", "description": "Optional fresh lowercase canonical UUID capability, scoped to its creator MCP server process instance while active. Retry only from that instance; reuse elsewhere errors without returning a token. Do not log or reuse it across callers." ]
            ], "additionalProperties": false]
        ],
        [
            "name": "resume_annotations",
            "description": "Releases exactly one secret suspension lease token returned by suspend_annotations. If another lease remains, success requires bounded confirmation that the current generation's peer presentation settled off screen; otherwise the token is released but the tool result is an error. If no lease remains, the response is only a linearized registry snapshot plus a restoration request, not proof of global window convergence. Releasing an already-released or expired token succeeds only during the 120-second cleanup tombstone; an unknown/old token is an error.",
            "inputSchema": ["type": "object", "properties": [
                "lease_token": ["type": "string", "minLength": 43, "maxLength": 43, "pattern": "^[A-Za-z0-9_-]{43}$", "description": "The exact secret leaseToken returned by suspend_annotations. Do not log it." ]
            ], "required": ["lease_token"], "additionalProperties": false]
        ],
        [
            "name": "clear",
            "description": "Clears by exact annotation_id, explicit app, fallback active app, or scope='all'. Prefer annotation_id for exact undo.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "scope": ["type": "string", "enum": ["active", "all"]],
                "app": ["type": "string", "description": "Explicit app target for active scope; empty string means globals only."]
            ]]
        ],
        [
            "name": "list_annotations",
            "description": "Lists a bounded page of live drawings with IDs, geometry (or an explicit oversized-geometry summary), app linkage, and visibility. Use nextOffset to page.",
            "inputSchema": ["type": "object", "properties": [
                "offset": ["type": "integer", "minimum": 0, "description": "Zero-based page offset; default 0."],
                "limit": ["type": "integer", "minimum": 1, "maximum": DrawingDefaults.maxAnnotationListPageItems, "description": "Maximum entries to return; default and maximum \(DrawingDefaults.maxAnnotationListPageItems)."]
            ]]
        ],
        [
            "name": "verify_annotation",
            "description": "Uses the exact live renderer to composite one drawing into either a supplied clean screenshot or a Chalkboard-owned \(captureBackendName) image, returning a tight PNG crop. The metadata's paintedBoundsScreenshotPx is the painted annotation's top-left-origin bounds in the FULL screenshot's pixels -- compare it against where the target element sits in that same screenshot to measure placement error, then correct with update_annotation in backing pixels. The returned image is a CROP: never reuse the crop's own dimensions as screenshot_width/height on a later draw call; only full-display image dimensions are valid there. Chalkboard capture is single-flight and times out after 30 seconds. screenshot_path and capture_source are mutually exclusive. capture_source='none' and get_annotation_bounds are the paths that need NO Screen Recording permission at all -- reach for one of those, never screenshot_path/capture_source='chalkboard', whenever that permission is not granted. Optionally supply AT MOST ONE of expect_element, expect_window, or target_bounds_screenshot_px for an automatic target comparison (coverage, intersection-over-union, containment, centre delta, verdict) alongside whichever image or geometry this call produced; each names the exact permission it needs, and none of the three needs Screen Recording. This verifies placement against UI pixels, not raw framebuffer presentation or occlusion.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "screenshot_space": ["type": "string", "minLength": 1, "maxLength": 64, "description": "\(screenshotSpaceDescription) On this tool specifically, the space's screenId supplies screenshot_screen_id when this is used together with screenshot_path; an explicitly supplied screenshot_screen_id that disagrees with the space's own screenId is rejected rather than reconciled."],
                "screenshot_path": ["type": "string", "description": "Absolute path to a clean uncropped full-display raster screenshot."],
                "screenshot_screen_id": ["type": "string", "description": "Display the screenshot_path image was captured from; required when the image could plausibly be a full-display capture (native or downsampled -- never upscaled) of MORE THAN ONE connected display, unless screenshot_space already supplies it. Must match the annotation's own display. Supplying it with capture_source is rejected rather than silently ignored, because Chalkboard capture always photographs the annotation's own display."],
                "capture_source": ["type": "string", "enum": ["chalkboard", "none"], "description": captureSourceDescription],
                "request_permission": ["type": "boolean", "description": captureRequestPermissionDescription],
                "padding_px": ["type": "number", "minimum": 0, "maximum": AnnotationVerificationCompositor.maxPaddingPx],
                "expect_element": ["type": "object", "description": expectElementDescription, "properties": merged([
                    ["app": ["type": "string", "description": highlightAppParamDescription]], elementQueryShape
                ]), "required": ["app", "label"], "additionalProperties": false],
                "expect_window": ["type": "object", "description": expectWindowDescription, "properties": [
                    "app": ["type": "string", "description": highlightAppParamDescription]
                ], "required": ["app"], "additionalProperties": false],
                "target_bounds_screenshot_px": ["type": "object", "description": "At most one of expect_element/expect_window/target_bounds_screenshot_px may be supplied. The bounds of the UI element you actually wanted annotated, in the SAME screenshot pixels as the image being verified. Requires a screenshot_space or explicit screenshot dimensions for that same screenshot, exactly as get_annotation_bounds already enforces for its own target_bounds_screenshot_px.", "properties": targetBoundsScreenshotPxShape, "required": ["x", "y", "width", "height"], "additionalProperties": false],
                "apply_correction": ["type": "boolean", "description": "Only with one of expect_element/expect_window/target_bounds_screenshot_px: when the expect verdict computes correctionBackingPx, immediately applies it server-side (compare-and-swap against the annotation's revision, so a concurrent change reports applied=false instead of moving stale state) and adds expect.appliedCorrection with the re-measured painted bounds and a verdictAfter. Verify + fix in one call, with no offset arithmetic on your side."]
            ], "required": ["annotation_id"]]
        ],
        [
            "name": "verify_presentation",
            "description": presentationCheckDescription,
            "inputSchema": ["type": "object", "properties": ["annotation_id": ["type": "string"]], "required": ["annotation_id"]]
        ],
        [
            "name": "get_annotation_bounds",
            "description": "Reports WHERE a drawing is painted, without capturing anything. Use this when your own screenshot tool does not show the overlay: it needs no screen capture, no Screen Recording permission, and never requires the annotation to appear in anybody's image. Bounds come from the exact live renderer (real glyph metrics, rotation, offsets, and any live window anchor included), reported in the annotation's current display's backing pixels and -- when you pass screenshot_width/screenshot_height, or reference a screenshot_space -- in that screenshot's own pixels. Pass target_bounds_screenshot_px with the rect you measured for the UI element you meant to annotate and the result also returns the centre-to-centre gap plus correctionBackingPx, the ABSOLUTE offset_x/offset_y to hand straight to update_annotation; that conversion already accounts for the screenshot scale and for an anchor's own scaling, which is the step to get wrong by hand. This is renderer geometry, NOT proof that any pixel reached a framebuffer or any capture: verify_presentation remains the window-state check and verify_annotation the composited-image check.",
            "inputSchema": ["type": "object", "properties": [
                "annotation_id": ["type": "string"],
                "screenshot_space": ["type": "string", "minLength": 1, "maxLength": 64, "description": screenshotSpaceDescription],
                "screenshot_width": ["type": "integer", "minimum": 1, "description": "Exact pixel width of the uncropped full-display screenshot you want bounds expressed in. Must be supplied together with screenshot_height; a detectable aspect-ratio mismatch against the display is rejected rather than silently stretched, exactly as for screenshot_pixels drawing coordinates. Rejected together with screenshot_space, which already carries this."],
                "screenshot_height": ["type": "integer", "minimum": 1, "description": "Exact pixel height of that same screenshot. Must be supplied together with screenshot_width. Rejected together with screenshot_space, which already carries this."],
                "target_bounds_screenshot_px": ["type": "object", "description": "Optional: the bounds of the UI element you actually wanted annotated, in the SAME screenshot pixels as screenshot_width/screenshot_height or screenshot_space (one of which is then required). Returns the placement gap and the absolute offset_x/offset_y correction to apply with update_annotation.", "properties": targetBoundsScreenshotPxShape, "required": ["x", "y", "width", "height"], "additionalProperties": false],
                "apply_correction": ["type": "boolean", "description": "Only with target_bounds_screenshot_px: when correctionBackingPx is computed, immediately applies it server-side (compare-and-swap against the annotation's revision, so a concurrent change reports applied=false instead of moving stale state) and adds appliedCorrection with the re-measured painted bounds and a verdictAfter. Measure + fix in one call, with no offset arithmetic on your side."]
            ], "required": ["annotation_id"]]
        ],
        [
            "name": "get_active_app",
            "description": "Reports the frontmost app, the fallback app an untagged draw call would link to, and this process's annotationsSuspended presentation state.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": "set_capture_visible",
            "description": "Applies legacy capture eligibility/exclusion and per-app debug filtering locally before responding, then broadcasts the request to sibling instances. External capture programs retain independent filters; this flag auto-reverts after five minutes. Setting it false restores per-app filtering but does not by itself re-apply capture exclusion: on a session detected as remote or streamed the exclusion stays off. The response, get_screens, and get_overlay_state all report the resulting captureExclusion decision.",
            "inputSchema": ["type": "object", "properties": ["visible": ["type": "boolean"]], "required": ["visible"]]
        ]
        ]
        return definitions.map { tool in
            var strictTool = tool
            var schema = strictTool["inputSchema"] as? [String: Any] ?? [:]
            schema["additionalProperties"] = false
            strictTool["inputSchema"] = schema
            return strictTool
        }
    }()
}
