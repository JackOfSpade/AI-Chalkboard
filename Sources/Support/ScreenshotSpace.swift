import Foundation

/// Establishes, ONCE, the fact an agent otherwise has to re-guess on every
/// single `draw_*` call: "these pixel dimensions are what THIS screenshot of
/// THIS display looks like."
///
/// WHY THIS EXISTS: an agent driving a separate screen-control tool and this
/// drawing tool has no shared coordinate authority between the two. It reads
/// coordinates off a screenshot image whose true pixel dimensions it very
/// often does not actually know -- the capture tool it used may not report
/// them at all, and a client in the middle (the chat UI, an image-resizing
/// proxy) may have downsampled the screenshot before the model ever saw its
/// bytes. Lacking that fact, the agent's only option today is to RE-DECLARE
/// a guessed `screenshot_width`/`screenshot_height` on every draw call that
/// needs `coordinate_space='screenshot_pixels'` -- and a guess made once per
/// call is a guess that can silently drift, be misremembered, or simply be
/// wrong from the very first call.
///
/// THE DANGEROUS FAILURE IS SILENT. Take a 2940x1912 physical display shown
/// to the model as a 1470x956 downsampled image (a common "the client halved
/// the screenshot before sending it to the model" scenario). If the agent
/// declares the DISPLAY's own native 2940x1912 as `screenshot_width`/
/// `screenshot_height` -- a completely natural mistake when it never learned
/// the image was downsampled -- `DrawRequest.coordinateTransform`'s existing
/// aspect-ratio guard (`ScreenshotGeometry.fullDisplayScale`) PASSES
/// PERFECTLY: 2940x1912 and 1470x956 share the exact same aspect ratio, so
/// nothing about the numbers looks contradictory. The call succeeds. Every
/// coordinate the agent measured on the 1470x956 image it actually looked at
/// lands at exactly half its intended position on the real display. No guard
/// inside this process can catch that after the fact, because both numbers
/// the caller supplied are internally self-consistent -- the mistake is not
/// in the ratio, it is in which absolute pair of numbers was true.
///
/// THE FIX: turn the screenshot-to-display mapping into a REGISTERED, NAMED
/// FACT, established once -- ideally by measurement (decoding the actual
/// screenshot file: see `Provenance.measured`) rather than by assertion --
/// and referenced afterward by a short opaque id. That changes the failure
/// mode in two ways: the guess, if one must be made at all, is made AT MOST
/// ONCE per screenshot rather than once per `draw_*` call, and a mapping that
/// has gone stale (the display was reconfigured or disconnected since
/// registration) becomes a LOUD, actionable rejection via
/// `stalenessRejection(space:currentScreen:)` instead of a silently
/// misplaced drawing.
///
/// This file intentionally contains PURE, platform-neutral logic only: no
/// AppKit, no Win32, no screen capture, no singleton state beyond the
/// injectable registry below. `ScreenInfo`/`CGRect`/`CGPoint` are already
/// available on both platforms through Foundation (see `ChalkGeometry.swift`),
/// so nothing here needs a platform branch.
struct ScreenshotSpace: Equatable {
    /// How strongly a `ScreenshotSpace`'s dimensions are actually known to be
    /// true, from strongest to weakest evidence.
    enum Provenance: String, Equatable {
        /// Decoded from an actual image file on disk: the pixel dimensions
        /// are FACT, read straight from the file's own header/pixel buffer,
        /// not asserted by anyone.
        case measured
        /// Solved from a calibration fiducial the agent reported seeing back
        /// in its own screenshot -- weaker than `measured` (it depends on the
        /// agent's report being accurate), but still MEASURED INDIRECTLY
        /// against a real, independently-placed on-screen reference rather
        /// than simply asserted.
        case observed
        /// The caller simply stated the dimensions outright. This carries
        /// exactly the evidentiary weight of today's per-call
        /// `screenshot_width`/`screenshot_height` guess -- no stronger --
        /// because that is exactly what it is: the same guess, just made
        /// once and named instead of repeated on every call.
        case declared
    }

    /// Opaque handle a `draw_*` call names later via `screenshot_space`.
    /// Minted by `ScreenshotSpaceRegistry`, never by a caller.
    let id: String
    /// The display this mapping was registered against, in the same id-space
    /// `ScreenInfo.id`/`ScreenSnapshot.resolve(_:)` use.
    let screenId: String
    /// The screenshot image's own pixel width/height -- what the agent
    /// actually measured coordinates against.
    let widthPx: Int
    let heightPx: Int
    /// The display's backing pixel dimensions AS OF REGISTRATION. Recorded
    /// (not re-read live) so a later resolution change can be detected by
    /// comparison rather than assumed away -- see `stalenessRejection`.
    let screenWidthPx: Int
    let screenHeightPx: Int
    let provenance: Provenance
    /// Only meaningful for `.measured`: the absolute path the dimensions
    /// were decoded from. Included solely so a caller inspecting
    /// `list_screenshot_spaces`-style output can tell two `.measured` spaces
    /// apart by their source file. `nil` for every other provenance, and
    /// `nil` is never itself evidence of anything -- a `.measured` space is
    /// free to omit it too (for example when the decoded bytes came from
    /// something other than a named file).
    let sourcePath: String?

    init(
        id: String,
        screenId: String,
        widthPx: Int,
        heightPx: Int,
        screenWidthPx: Int,
        screenHeightPx: Int,
        provenance: Provenance,
        sourcePath: String? = nil
    ) {
        self.id = id
        self.screenId = screenId
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.screenWidthPx = screenWidthPx
        self.screenHeightPx = screenHeightPx
        self.provenance = provenance
        self.sourcePath = sourcePath
    }

    /// The SCREENSHOT-TO-BACKING scale -- `screenWidthPx / widthPx`, matching
    /// `DrawRequest.coordinateTransform`'s `screenshot_pixels` branch, which
    /// computes `Double(screen.widthPx) / width` from the same two
    /// quantities under the same names. Kept as the identical ratio,
    /// identical direction, so a caller reading both this type and that
    /// method side by side never has to reconcile two different scale
    /// conventions.
    var scaleX: Double { Double(screenWidthPx) / Double(widthPx) }
    var scaleY: Double { Double(screenHeightPx) / Double(heightPx) }

    /// The MCP wire shape for one registered space. A plain dictionary
    /// (rather than `Codable`) because this is assembled alongside other
    /// hand-built `[String: Any]` tool-response payloads throughout
    /// `Sources/MCP` (see `DrawRequest.avoidanceResponsePayload`,
    /// `anchorResponsePayload`) and must compose with them the same way.
    var payload: [String: Any] {
        var dict: [String: Any] = [
            "screenshotSpace": id,
            "screenId": screenId,
            "screenshotPx": ["width": widthPx, "height": heightPx],
            "screenBackingPx": ["width": screenWidthPx, "height": screenHeightPx],
            "scaleToBackingPx": ["x": scaleX, "y": scaleY],
            "provenance": provenance.rawValue
        ]
        if let sourcePath {
            dict["sourcePath"] = sourcePath
        }
        return dict
    }

    /// Whether a registered space is still safe to expand into a draw call,
    /// checked against a FRESH, just-taken `ScreenInfo` for the space's
    /// `screenId` -- never against the space's own recorded numbers, which
    /// are exactly the thing under suspicion.
    ///
    /// A PURE static function on purpose: it takes every fact it needs as a
    /// parameter (the space, and the caller's current look-up of that
    /// space's display) so it is directly unit-testable with hand-built
    /// fixtures, no `ScreenshotSpaceRegistry`, and no live display anywhere
    /// in the test.
    ///
    /// Returns `nil` when the space is still usable. Otherwise returns the
    /// exact rejection prose an MCP caller should see -- naming the recorded
    /// vs. current numbers and telling the caller to re-register or
    /// re-calibrate, and stating plainly that nothing was drawn/computed, so
    /// an agent reading only this string can self-correct without any other
    /// context.
    ///
    /// Two distinct staleness causes are distinguished, because they call for
    /// different agent action:
    ///   (a) `currentScreen == nil` -- the display this space was registered
    ///       against is no longer present in the current snapshot at all
    ///       (disconnected, or its reported id changed across a
    ///       reconfiguration/sleep-wake cycle). There is no display left to
    ///       compare dimensions against, so this is checked first.
    ///   (b) `currentScreen` exists but its `widthPx`/`heightPx` no longer
    ///       match the space's recorded `screenWidthPx`/`screenHeightPx` --
    ///       the display's resolution changed, or its Retina/HiDPI scale
    ///       mode changed, since registration. The recorded screenshot-to-
    ///       backing-pixel mapping describes a display configuration that no
    ///       longer exists; continuing to use it would silently reintroduce
    ///       exactly the "self-consistent but wrong" failure this type
    ///       exists to prevent, just recorded once instead of asserted once.
    static func stalenessRejection(space: ScreenshotSpace, currentScreen: ScreenInfo?) -> String? {
        guard let currentScreen else {
            return "screenshot_space '\(space.id)' was registered against display \(space.screenId), which is no longer present in the current display list -- it may have been disconnected, or its reported id changed across a display reconfiguration or sleep/wake cycle. Nothing was drawn/computed; call get_screens for the current display list, then register_screenshot_space or calibrate_screenshot_space again for the display you intend to draw on."
        }
        guard currentScreen.widthPx == space.screenWidthPx, currentScreen.heightPx == space.screenHeightPx else {
            return "screenshot_space '\(space.id)' was registered when display \(space.screenId) reported \(space.screenWidthPx)x\(space.screenHeightPx) backing pixels, but it now reports \(currentScreen.widthPx)x\(currentScreen.heightPx) -- its resolution or HiDPI scale mode changed since registration, so the recorded screenshot-to-backing-pixel mapping describes a display configuration that no longer exists. Nothing was drawn/computed; call register_screenshot_space or calibrate_screenshot_space again to establish a fresh mapping for the display's current configuration."
        }
        return nil
    }
}

/// Process-wide store of registered `ScreenshotSpace`s.
///
/// `final class ... @unchecked Sendable` guarded by a plain `NSLock`, the
/// same discipline `RasterAssetStore`, `SVGPathCache`, and `AnnotationStore`
/// already use in this package for small, frequently-read, occasionally-
/// mutated shared state: `@unchecked` is sound here NOT because nothing ever
/// mutates concurrently, but because every mutation and every read is
/// serialized through `lock` below, so the compiler's automatic Sendable
/// checking (which cannot see through that discipline) is simply stricter
/// than the code needs.
///
/// BOUNDED ON PURPOSE: this is a long-lived background server, and nothing
/// about an agent session guarantees it ever calls a "forget this space"
/// tool. Without a cap, an agent that re-registers a fresh space on every
/// screenshot over a long session would grow this store without bound --
/// the same "long-lived background server + caller-driven growth" hazard
/// `DrawingDefaults.maxStoredAnnotations` and `RasterAssetStore
/// .defaultMaxStoredAssets` already guard against elsewhere in this package.
/// `maxEntries` keeps the bound small and explicit: 16 concurrently
/// registered display mappings is already generous for any real multi-
/// monitor agent workflow, and evicting the least-recently-REGISTERED entry
/// (a plain FIFO by insertion order, not an LRU-by-use scheme) keeps the
/// eviction rule itself simple enough to state in one sentence and verify
/// with one test.
final class ScreenshotSpaceRegistry: @unchecked Sendable {
    static let shared = ScreenshotSpaceRegistry()

    /// See the class doc comment's "BOUNDED ON PURPOSE" paragraph.
    static let maxEntries = 16

    private let lock = NSLock()
    /// Oldest-registered first. Both the eviction victim (`removeFirst()`)
    /// and iteration order for `all()` fall out of this single ordering, so
    /// there is no separate recency structure to keep in sync the way
    /// `SVGPathCache` needs one for its LRU (registration order here never
    /// changes after insertion, unlike that cache's per-entry "last used").
    private var order: [ScreenshotSpace] = []
    private var byId: [String: ScreenshotSpace] = [:]
    /// Separated from `register(...)` itself so a test can inject a
    /// deterministic sequence (e.g. a fixed list of ids consumed in order)
    /// without needing to control `SystemRandomNumberGenerator`, and so a
    /// forced id COLLISION can be exercised as a scripted sequence instead
    /// of hoping real randomness produces one.
    private let makeId: () -> String

    init(idGenerator: @escaping () -> String = ScreenshotSpaceRegistry.randomId) {
        self.makeId = idGenerator
    }

    /// Mints one candidate id: `"space-"` followed by 8 lowercase hex
    /// characters. Not guaranteed collision-free by itself -- `register`
    /// retries this against the live entry set until it finds an id no
    /// current entry holds.
    static func randomId() -> String {
        let hexDigits = Array("0123456789abcdef")
        var suffix = ""
        suffix.reserveCapacity(8)
        for _ in 0..<8 {
            suffix.append(hexDigits[Int.random(in: 0..<hexDigits.count)])
        }
        return "space-" + suffix
    }

    /// The most attempts `register` will make to mint a non-colliding id
    /// before giving up. See "BOUNDED ON PURPOSE" below for why this exists
    /// at all: with real randomness over at most `maxEntries` (16) live
    /// entries, a collision on the FIRST attempt is already astronomically
    /// unlikely, and a second consecutive collision is not a number worth
    /// naming -- 1000 attempts is generous headroom above that, not a budget
    /// anyone should expect to need.
    private static let maxIdMintAttempts = 1_000

    /// Registers a new space, evicting the least-recently-registered entry
    /// first if the store is already at `maxEntries`, and retrying id
    /// minting if `makeId()` happens to collide with a still-live entry.
    @discardableResult
    func register(
        screenId: String,
        widthPx: Int,
        heightPx: Int,
        screenWidthPx: Int,
        screenHeightPx: Int,
        provenance: ScreenshotSpace.Provenance,
        sourcePath: String? = nil
    ) -> ScreenshotSpace {
        lock.lock()
        defer { lock.unlock() }

        var id = makeId()
        // A collision here means `makeId()` produced an id some OTHER live
        // entry already holds -- vanishingly unlikely for real randomness
        // over 16 entries, but a test-injected generator can force it
        // deliberately, and production code must not silently overwrite a
        // different caller's space if it ever did happen.
        //
        // BOUNDED ON PURPOSE: this loop used to retry unconditionally, which
        // is correct against real randomness but turns into an INFINITE LOOP
        // -- held under `lock`, so it hangs every other caller of this
        // registry too -- the instant an injected `idGenerator` returns an
        // id that collides unconditionally (a broken generator, or a test
        // fixture with a bug of its own). A generator that behaves that
        // badly is a defect in the generator, not a transient condition
        // retrying more would fix, so this caps the retry count and fails
        // LOUDLY instead of hanging the process.
        var mintAttempts = 1
        while byId[id] != nil {
            mintAttempts += 1
            guard mintAttempts <= Self.maxIdMintAttempts else {
                fatalError("ScreenshotSpaceRegistry.register could not mint a non-colliding id after \(Self.maxIdMintAttempts) attempts against \(order.count) live entries. The injected idGenerator is returning ids that always collide with a still-live entry -- real randomness over at most \(Self.maxEntries) entries would never need anywhere close to this many retries. Fix the generator passed to ScreenshotSpaceRegistry.init(idGenerator:); this is a programming defect in that generator, not a condition retrying further would resolve.")
            }
            id = makeId()
        }

        if order.count >= Self.maxEntries {
            let evicted = order.removeFirst()
            byId.removeValue(forKey: evicted.id)
        }

        let space = ScreenshotSpace(
            id: id,
            screenId: screenId,
            widthPx: widthPx,
            heightPx: heightPx,
            screenWidthPx: screenWidthPx,
            screenHeightPx: screenHeightPx,
            provenance: provenance,
            sourcePath: sourcePath
        )
        order.append(space)
        byId[id] = space
        return space
    }

    /// Looks up one space by id, or `nil` if it was never registered, has
    /// been forgotten, or was evicted to make room for newer registrations.
    func lookup(id: String) -> ScreenshotSpace? {
        lock.lock()
        defer { lock.unlock() }
        return byId[id]
    }

    /// Every currently registered space, oldest-registered first.
    func all() -> [ScreenshotSpace] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    /// Explicitly removes one space. Returns `false` if it was not present
    /// (never registered, already forgotten, or already evicted) rather than
    /// treating that as an error -- forgetting an already-gone id achieves
    /// the caller's goal either way.
    @discardableResult
    func forget(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard byId.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0.id == id }
        return true
    }

    /// Removes every registered space. Exists for tests and for a broader
    /// session-reset path; production code has no standing reason to call
    /// this on its own, mirroring `RasterAssetStore.removeAll()`'s and
    /// `SVGPathCache.removeAll()`'s equivalent "tests plus explicit reset
    /// only" role.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        order.removeAll()
        byId.removeAll()
    }
}
