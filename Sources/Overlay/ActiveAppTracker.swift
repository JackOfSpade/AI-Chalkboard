import Foundation
import AppKit

/// Shared conservative syntax for an exact, complete bundle identifier.
/// Three non-empty reverse-DNS components distinguish `com.apple.Safari` from
/// vague prefixes such as `com.apple`, which must still undergo ambiguity checks.
enum BundleIdentifierSyntax {
    static func looksComplete(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3
            && parts.allSatisfy { !$0.isEmpty }
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}

/// A resolved application: a bundle identifier plus the human-readable name we
/// found it under. Returned by `ActiveAppTracker.resolve(_:)` and embedded in
/// `Annotation.appId` / `Annotation.appName`.
public struct AppRef {
    public let bundleId: String
    public let name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// The outcome of `ActiveAppTracker.resolve(_:)`.
///
/// `ambiguous` exists because the old `AppRef?` return type could not express
/// "several running apps match this string". With only two outcomes, a fuzzy
/// query such as "Google" (Chrome? Drive? Docs?) or "com" (every reverse-DNS
/// bundle id on the machine) had to pick SOMETHING, and the pick came from
/// `NSWorkspace.runningApplications`, whose order is unspecified -- so the same
/// request could link an annotation to a different app on the next run, and the
/// caller was told it had succeeded. Surfacing the ambiguity instead lets the
/// tool answer "which of these did you mean?" and be retried precisely.
public enum AppResolution {
    /// Exactly one running application matched.
    case resolved(AppRef)
    /// Several running applications matched and there is no principled way to
    /// choose between them. Carries the (bundle-id-deduplicated) candidates so
    /// the caller can list them back rather than guess.
    case ambiguous([AppRef])
    /// Nothing matched.
    case notFound
}

/// Tracks which application is frontmost so overlay annotations can be scoped
/// to a single app: draw for DaVinci Resolve and the drawing appears only while
/// DaVinci Resolve is frontmost; switch to Terminal and Terminal's own drawings
/// appear instead.
///
/// STDOUT SAFETY: this process is an MCP stdio server speaking JSON-RPC over
/// fd 1. Every diagnostic in this file goes through `Logger.shared.log`
/// (stderr + rotating file). Never add a Swift `print` here.
public final class ActiveAppTracker: NSObject {
    public static let shared = ActiveAppTracker()

    /// This app's own bundle identifier, as set by build_app.sh's Info.plist.
    /// Hard-coded as a backstop because `Bundle.main.bundleIdentifier` is `nil`
    /// when the raw `swift build` binary is run outside an .app bundle (a
    /// perfectly normal way to debug this server), and a nil self-identifier
    /// would silently disable every self-exclusion rule below.
    public static let ownBundleIdentifier = "com.aichalkboard.overlay"

    // MARK: - State
    //
    // THREADING: these are written on the main thread (NSWorkspace delivers its
    // activation notifications there) but read from the MCP server's background
    // read queue (`draw_*` tool calls) AND from `OverlayView.draw(_:)` on the
    // main thread. Hence a plain NSLock around cached values.
    //
    // The public getters must remain pure lock-protected reads of these cached
    // values -- they must NEVER hop to the main queue with `DispatchQueue.main
    // .sync`, because `OverlayView.draw(_:)` calls `currentAppId` while already
    // ON the main thread and that would deadlock instantly.

    private let lock = NSLock()

    private var _currentAppId: String?
    private var _currentAppName: String?
    private var _fallbackAppId: String?
    private var _fallbackAppName: String?

    /// Bundle identifiers we have logged an exclusion for already, so a user
    /// tabbing between Claude and the overlay does not spam the log with the
    /// same line hundreds of times.
    private var loggedExclusions: Set<String> = []

    private var isStarted = false

    /// Bundle id of the app whose annotations should currently be on screen.
    ///
    /// This is the *frontmost* application, with ONE exception: activations of
    /// AI Chalkboard itself are ignored and this keeps its previous value. That
    /// is not cosmetic -- in MCP mode the status-bar menu is this app's only UI,
    /// and clicking a status item activates the owning app. Without the
    /// exception, opening our own menu would make "the frontmost app" become
    /// AI Chalkboard, every app-linked annotation on every screen would blink
    /// out of existence for as long as the menu was open, and the menu item
    /// that is supposed to read "Clear Annotations for DaVinci Resolve" would
    /// read "Clear Annotations for AI Chalkboard" and clear nothing. Our own
    /// overlay windows are non-activating and click-through, so this app is
    /// never meaningfully "the app the user is looking at".
    public var currentAppId: String? {
        lock.lock(); defer { lock.unlock() }
        return _currentAppId
    }

    /// Display name matching `currentAppId`.
    public var currentAppName: String? {
        lock.lock(); defer { lock.unlock() }
        return _currentAppName
    }

    /// The app an UNTAGGED `draw_*` call gets linked to: the most recent
    /// frontmost application excluding AI Chalkboard itself, Claude, and
    /// prohibited/background-only processes and macOS session UI such as
    /// `loginwindow`, none of which is a usable annotation destination.
    ///
    /// WHY THIS EXISTS -- the whole feature is broken without it:
    ///
    /// The draw calls arrive over an MCP pipe from Claude. At the instant
    /// a draw tool executes, the app the user is actually looking at is *Claude
    /// Desktop* -- they just typed "circle the render button in DaVinci" into
    /// it and hit send. If an untagged draw were tagged with the TRUE frontmost
    /// app, every annotation would be linked to Claude: it would show up over
    /// the chat window and, the moment the user switched to DaVinci to look at
    /// what Claude drew, it would vanish. The annotation would be visible only
    /// in the one place it is useless.
    ///
    /// So the default target is the last app that was frontmost *before* Claude
    /// (and before us) -- i.e. the app the user switched away from to go ask
    /// Claude the question. That is essentially always the app they meant.
    ///
    /// `nil` when no such app has been seen yet (e.g. Claude was already
    /// frontmost at launch and nothing else has been activated since). A nil
    /// target means GLOBAL, so an untagged draw in that situation shows up over
    /// every app rather than nowhere -- degrading to "too visible" rather than
    /// "invisible and inexplicable".
    public var fallbackAppId: String? {
        lock.lock(); defer { lock.unlock() }
        return _fallbackAppId
    }

    /// Display name matching `fallbackAppId`.
    public var fallbackAppName: String? {
        lock.lock(); defer { lock.unlock() }
        return _fallbackAppName
    }

    override private init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Seeds the initial values and subscribes to app-activation events.
    /// Call once from `applicationDidFinishLaunching`, on the main thread.
    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // ORDER MATTERS: seed FIRST, register SECOND.
        //
        // The seed reads a value that is already stale by definition (whatever
        // was frontmost a moment ago), while a notification carries a strictly
        // newer one. With the observer installed first, an activation delivered
        // between the two statements would be immediately overwritten by the
        // older seed -- `currentAppId` would then point at the wrong app until
        // the next app switch. Seeding first makes the seed the oldest write by
        // construction, so no ordering hazard exists regardless of timing.
        // (Both statements run on the main thread inside one call today, so
        // nothing can interleave in practice; this ordering is what keeps that
        // true if `start()` is ever called from somewhere less serialized.)
        let seeded = NSWorkspace.shared.frontmostApplication
        adopt(app: seeded, source: "startup seed")

        // CRITICAL: app-activation notifications are posted on NSWorkspace's
        // OWN notification centre, NOT `NotificationCenter.default`. Registering
        // `NSWorkspace.didActivateApplicationNotification` on the default centre
        // compiles perfectly, runs perfectly, and silently never fires -- which
        // would leave `currentAppId` frozen at whatever it was at launch and
        // make per-app filtering look like it "randomly doesn't work". This is
        // the single classic bug in this API; do not "simplify" the receiver
        // below to `NotificationCenter.default`.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        Logger.shared.log(
            "ActiveAppTracker: started. Observing NSWorkspace.shared.notificationCenter (NOT NotificationCenter.default) for didActivateApplicationNotification. Seed frontmost=\(describe(seeded)); current=\(currentAppId ?? "<none>"); fallback=\(fallbackAppId ?? "<none, untagged draws will be GLOBAL>").",
            level: "INFO"
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        adopt(app: app, source: "didActivateApplicationNotification")

        // Repaint every overlay: the visible set is a function of the frontmost
        // app, so an app switch changes what should be on screen even though no
        // annotation was added or removed. `refreshViews()` only sets
        // `needsDisplay`, so this is cheap.
        //
        // NOTE: this deliberately does NOT touch `AnnotationStore.onStoreChanged`
        // -- that is a single optional closure owned by
        // `OverlayWindowController.setup()`, and assigning it here would clobber
        // the repaint-on-mutation path. We call the controller directly instead.
        OverlayWindowController.shared.refreshViews()
    }

    /// Folds a newly-frontmost app into `current` and `fallback`, applying the
    /// exclusion rules for each.
    private func adopt(app: NSRunningApplication?, source: String) {
        guard let bundleId = app?.bundleIdentifier, !bundleId.isEmpty else {
            // Apps without a bundle identifier (raw command-line binaries) can
            // never be matched by an annotation's appId, so there is nothing
            // useful to record. Leave both values at their previous state.
            return
        }
        let name = app?.localizedName ?? bundleId

        let isSelf = isOwnApp(bundleId)
        let isClaude = isClaudeApp(bundleId)
        let isProhibited = app?.activationPolicy == .prohibited
        let isSystemSessionApp = Self.isSystemSessionApp(bundleId)

        lock.lock()
        let previousCurrentId = _currentAppId
        let previousFallbackId = _fallbackAppId
        if !isSelf {
            _currentAppId = bundleId
            _currentAppName = name
        }
        if !isSelf && !isClaude && !isProhibited && !isSystemSessionApp {
            _fallbackAppId = bundleId
            _fallbackAppName = name
        }
        // Snapshot for the log line while still holding the lock, instead of
        // re-reading the fields afterwards: the values are read from the MCP
        // server's background queue too, so an unlocked read here was a race
        // (harmless in a diagnostic string, but a race the compiler is entitled
        // to reason about).
        let didChange = (_currentAppId != previousCurrentId) || (_fallbackAppId != previousFallbackId)
        let currentForLog = _currentAppId ?? "<none>"
        let fallbackForLog = _fallbackAppId ?? "<none>"
        let shouldLogExclusion = (isSelf || isClaude || isProhibited || isSystemSessionApp)
            && loggedExclusions.insert(bundleId).inserted
        lock.unlock()

        if shouldLogExclusion {
            // Log every excluded id ONCE so that "why did my drawing get tagged
            // to the wrong app" is answerable from the log alone.
            let reason: String
            if isSelf {
                reason = "it is AI Chalkboard itself"
            } else if isClaude {
                reason = "it matched the Claude/Anthropic heuristic"
            } else if isSystemSessionApp {
                reason = "it is macOS session UI, not an app the user can annotate"
            } else {
                reason = "its activation policy is prohibited, so it cannot be a usable annotation target"
            }
            Logger.shared.log(
                "ActiveAppTracker: EXCLUDING '\(bundleId)' (\(name)) from the untagged-draw fallback target because \(reason). Untagged draw_* calls will stay linked to the last app before it.",
                level: "INFO"
            )
        }

        // Only log when the tracked state ACTUALLY changed. This fires on every
        // app activation -- i.e. on every alt-tab, every click into another
        // window, for the whole life of a long-running MCP server -- and Logger
        // has no level filtering, so an unconditional line here wrote to the
        // rotating log file continuously and could churn it out of usefulness on
        // its own. Re-activating the app that is already current (alt-tab out to
        // Claude and straight back, clicking between windows of the same app) is
        // by far the common case and now costs nothing.
        if !isSelf && didChange {
            Logger.shared.log(
                "ActiveAppTracker: frontmost app is now '\(bundleId)' (\(name)) [\(source)]. current=\(currentForLog); fallback=\(fallbackForLog).",
                level: "DEBUG"
            )
        }
    }

    // MARK: - Exclusion rules

    private func isOwnApp(_ bundleId: String) -> Bool {
        if bundleId.caseInsensitiveCompare(Self.ownBundleIdentifier) == .orderedSame { return true }
        if let own = Bundle.main.bundleIdentifier,
           bundleId.caseInsensitiveCompare(own) == .orderedSame {
            return true
        }
        return false
    }

    /// Whether `bundleId` looks like a Claude / Anthropic client.
    ///
    /// Deliberately a runtime substring heuristic rather than a hard-coded
    /// literal: Claude ships under more than one identifier (desktop app, dev
    /// builds, Claude Code's host) and guessing one exact string would silently
    /// fail the day it changes -- and the failure mode is invisible (every
    /// annotation quietly linked to Claude and therefore never displayed over
    /// the app the user meant). Matching "anthropic" or "claude" anywhere in the
    /// identifier is loose on purpose; the cost of a false positive is only that
    /// an app is skipped as an untagged-draw *default*, which the explicit `app`
    /// parameter always overrides.
    private func isClaudeApp(_ bundleId: String) -> Bool {
        let lower = bundleId.lowercased()
        return lower.contains("anthropic") || lower.contains("claude")
    }

    /// Session/login UI can temporarily become frontmost while the screen is
    /// locked. macOS reports loginwindow as activatable on some releases, so
    /// activationPolicy alone cannot identify this unusable fallback target.
    static func isSystemSessionApp(_ bundleId: String) -> Bool {
        bundleId.caseInsensitiveCompare("com.apple.loginwindow") == .orderedSame
    }

    // MARK: - Resolution

    /// Resolves a user-supplied string against the CURRENT set of running
    /// applications. Fetches that set from `NSWorkspace` (a main-thread hop --
    /// see `runningCandidates()`) and delegates all matching logic to the pure
    /// overload below, which carries the full doc comment for this method's
    /// contract and history. Kept as the public entry point solely so callers
    /// (`DrawRequest`) do not need to know `Candidate` exists.
    public func resolve(_ raw: String?) -> AppResolution {
        // Answer the empty query BEFORE enumerating anything. `runningCandidates()`
        // costs a synchronous hop to the main thread (NSWorkspace is AppKit), and
        // this method is called from the MCP server's background read queue, so
        // paying for that hop only to hand the same `.notFound` back would be a
        // needless main-thread round trip on a request that cannot succeed.
        guard let query = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .notFound
        }
        return resolve(query, among: runningCandidates())
    }

    /// Resolves a user-supplied string -- which may be a bundle identifier
    /// ("com.apple.Terminal") or a display name ("DaVinci Resolve") -- to a
    /// concrete application, matched against `candidates`.
    ///
    /// Matching order, all case-insensitive:
    ///   1. exact bundle id                  -- unambiguous by definition
    ///   2. exact display name, if exactly one activatable bundle id matches
    ///   3. bundle-id PREFIX, but only if exactly ONE running app matches
    ///   4. display-name SUBSTRING, but only if exactly ONE running app matches
    /// Anything else is `.ambiguous` (several candidates) or `.notFound`.
    ///
    /// WHY UNIQUENESS IS REQUIRED, and why step 4 is `contains` not `hasPrefix`
    /// -- the previous "first match wins over `NSWorkspace.runningApplications`"
    /// version got the common cases exactly backwards:
    ///   * `"com"` prefix-matched EVERY reverse-DNS bundle id on the machine and
    ///     silently linked the annotation to an arbitrary one of them, reporting
    ///     success. `runningApplications` has no documented order, so which one
    ///     could differ between two identical calls.
    ///   * `"Google"` picked Chrome or Drive nondeterministically.
    ///   * `"Chrome"` FAILED outright -- the bundle id is `com.google.Chrome`
    ///     (no `chrome` prefix) and the display name is "Google Chrome" (no
    ///     `Chrome` prefix) -- and was then rejected downstream for having no
    ///     dot. So the friendly, obviously-intended form failed while the
    ///     dangerous vague form quietly "worked".
    /// Requiring uniqueness kills the silent-wrong-app class outright, and the
    /// substring pass makes "Chrome", "Resolve" and "Code" resolve the way a
    /// human means them.
    ///
    /// Candidates are de-duplicated by bundle id first: one app can own several
    /// `NSRunningApplication` entries (helper processes, `open -n`), and those
    /// duplicates must not be mistaken for genuine ambiguity.
    ///
    /// TWO EXCLUSIONS ON TOP OF PLAIN UNIQUENESS, both derived from the real
    /// process list on this machine rather than assumed. Neither can discard a
    /// legitimate answer, and both exist to stop a fuzzy pass "succeeding" with
    /// something the user could never have meant:
    ///
    ///   * Both name passes ignore apps with NO `localizedName`. For those,
    ///     `AppRef.name` is just the bundle id echoed back, and matching a
    ///     "display name" that is really a bundle id is how the dangerous vague
    ///     query survives uniqueness: `"com"` matched dozens of bundle ids
    ///     (correctly ambiguous) but then matched exactly ONE pseudo-name --
    ///     `com.apple.PressAndHold`, a nameless `.prohibited` input agent -- and
    ///     was "resolved" to it. Bundle ids get exactly one pass, the prefix one.
    ///
    ///   * Exact-name and both fuzzy passes ignore `.prohibited` processes (XPC services and
    ///     the like: `AutoFill (Google Chrome)`, `Open and Save Panel Service`).
    ///     Such a process CANNOT be activated, so it can never be the frontmost
    ///     app, so an annotation linked to it is unconditionally invisible --
    ///     resolving to one is always wrong, never merely unlucky. It also
    ///     restores the intended behaviour for a complete bundle id whose app is
    ///     not running: `"com.apple.Safari"` with Safari closed used to
    ///     prefix-match `com.apple.SafariPlatformSupport.Helper` and link the
    ///     annotation to Apple's AutoFill service; now that pass finds nothing,
    ///     so the caller's bundle id is accepted verbatim and the annotation
    ///     appears when Safari is opened.
    ///     `.accessory` apps are deliberately KEPT: menu-bar utilities (Google
    ///     Drive) and app helpers (Google Chrome Helper) can be activated, so
    ///     they are legitimate targets -- and legitimate sources of genuine
    ///     ambiguity, which is reported rather than resolved.
    ///
    ///     THE EXACT-BUNDLE-ID PASS IS DELIBERATELY EXEMPT from that exclusion,
    ///     and this has now been re-raised as a suspected bug twice, so:
    ///     adding `canBeFrontmost` to the first pass would change NOTHING that
    ///     is observable. A complete bundle id that fails to resolve is accepted
    ///     verbatim by `MCPServer.resolveTargetApp`'s `.notFound` branch anyway,
    ///     so the annotation ends up carrying the SAME `appId` either way, and
    ///     is equally invisible either way (a `.prohibited` process can never be
    ///     frontmost, so the render-time comparison against that id never
    ///     matches). The only difference is that the exempt version can still
    ///     report the process's real display name in the tool result instead of
    ///     echoing the raw id back -- strictly better diagnostics for identical
    ///     behaviour. The exclusion exists to stop a FUZZY pass landing on
    ///     something the user did not mean; an exact, complete id is by
    ///     construction not an accidental fuzzy hit.
    ///
    /// LIMITATION, by design: only RUNNING applications are searched, because
    /// `NSWorkspace` is the only name->bundle-id mapping available without
    /// crawling /Applications. Callers handle the "not running yet" case by
    /// accepting a string that already looks like a bundle identifier verbatim
    /// -- but ONLY on `.notFound`, never on `.ambiguous`: storing the vague
    /// query itself ("com.google") as an appId would produce an annotation that
    /// can never match any app and therefore can never be seen.
    ///
    /// PURE ON PURPOSE: this overload touches no AppKit API at all -- it only
    /// reads `candidates`, the array `runningCandidates()` built by querying
    /// `NSWorkspace` -- specifically so it can be exercised in a unit test with
    /// a hand-built candidate list instead of whatever happens to be running on
    /// the machine the tests execute on.
    func resolve(_ raw: String?, among candidates: [Candidate]) -> AppResolution {
        guard let query = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .notFound
        }

        if let hit = candidates.first(where: { $0.ref.bundleId.caseInsensitiveCompare(query) == .orderedSame }) {
            return .resolved(hit.ref)
        }
        let exactNameHits = dedupedByBundleId(candidates.filter {
            $0.canBeFrontmost
                && $0.hasDisplayName
                && $0.ref.name.caseInsensitiveCompare(query) == .orderedSame
        })
        if exactNameHits.count == 1 {
            return .resolved(exactNameHits[0].ref)
        }
        if exactNameHits.count > 1 {
            return ambiguousResolution(query: query, hits: exactNameHits)
        }
        // A fully qualified bundle identifier is more specific than a prefix
        // match. If it is not running, preserve it verbatim so it can become
        // visible when launched; do this before fuzzy passes whose helpers may
        // share its prefix.
        if BundleIdentifierSyntax.looksComplete(query) {
            // Logged, because this early return is otherwise INVISIBLE in the
            // log: the plain fall-through `.notFound` at the end of this method
            // WARNs, but this path returned silently, so "I passed a bundle id
            // and my annotation never appeared" could not be diagnosed from the
            // log alone. The outcome is legitimate (the caller accepts the id
            // verbatim and the annotation appears once that app launches), but
            // it is also what a typo'd bundle id looks like, so say which.
            Logger.shared.log(
                "ActiveAppTracker: '\(query)' is a complete bundle identifier that matched no running application. Not attempting a fuzzy match -- a complete id must not be prefix-matched onto a different app that happens to share its prefix. The caller may store it verbatim, in which case the annotation stays hidden until that app is launched and brought to the front.",
                level: "INFO"
            )
            return .notFound
        }

        let lowered = query.lowercased()

        // Only apps that can actually be brought to the front take part in the
        // fuzzy passes -- see this method's doc comment.
        let fuzzyCandidates = candidates.filter { $0.canBeFrontmost }

        let bundleIdHits = dedupedByBundleId(fuzzyCandidates.filter { $0.ref.bundleId.lowercased().hasPrefix(lowered) })
        if bundleIdHits.count == 1 {
            return .resolved(bundleIdHits[0].ref)
        }

        let nameHits = dedupedByBundleId(fuzzyCandidates.filter { $0.hasDisplayName && $0.ref.name.lowercased().contains(lowered) })
        if nameHits.count == 1 {
            return .resolved(nameHits[0].ref)
        }

        // Neither pass produced exactly one app. Report every candidate either
        // pass found, so the caller can name one precisely instead of retrying
        // blind. (Both counts are now 0 or >= 2, so the union is never 1.)
        // Ordinary `.regular` apps are listed first: the caller truncates this
        // list, and a background helper is rarely the intended answer.
        var ambiguous = bundleIdHits
        for hit in nameHits where !ambiguous.contains(where: { $0.ref.bundleId.caseInsensitiveCompare(hit.ref.bundleId) == .orderedSame }) {
            ambiguous.append(hit)
        }
        if ambiguous.count > 1 {
            return ambiguousResolution(query: query, hits: ambiguous)
        }

        Logger.shared.log("ActiveAppTracker: could not resolve app '\(query)' against \(candidates.count) running applications.", level: "WARN")
        return .notFound
    }

    private func ambiguousResolution(query: String, hits: [Candidate]) -> AppResolution {
        let ordered = hits.filter { $0.isRegularApp }.map { $0.ref }
            + hits.filter { !$0.isRegularApp }.map { $0.ref }
        Logger.shared.log("ActiveAppTracker: app query '\(query)' is AMBIGUOUS -- it matches \(ordered.count) running applications (\(ordered.map { $0.bundleId }.joined(separator: ", "))). Refusing to guess; the caller is told to be more specific.", level: "WARN")
        return .ambiguous(ordered)
    }

    /// Collapses several `NSRunningApplication` entries that share one bundle id
    /// down to a single candidate, preserving order. Without this, an app with
    /// helper processes would look "ambiguous" against itself.
    private func dedupedByBundleId(_ hits: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for hit in hits where seen.insert(hit.ref.bundleId.lowercased()).inserted {
            result.append(hit)
        }
        return result
    }

    /// Best-effort display name for a bundle id, for diagnostics
    /// (`list_annotations`). `nil` when the app is not running.
    public func displayName(forBundleId bundleId: String?) -> String? {
        guard let bundleId = bundleId, !bundleId.isEmpty else { return nil }
        return runningAppRefs().first(where: { $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame })?.name
    }

    /// The literal current value of `NSWorkspace.shared.frontmostApplication`,
    /// with no exclusions applied at all. Used by the `get_active_app` tool so
    /// Claude can see the raw truth (including "AI Chalkboard's own menu is
    /// open" or "Claude itself is frontmost") next to the filtered values.
    public func rawFrontmostApp() -> AppRef? {
        var result: AppRef?
        MainThread.sync {
            if let app = NSWorkspace.shared.frontmostApplication,
               let bundleId = app.bundleIdentifier, !bundleId.isEmpty {
                result = AppRef(bundleId: bundleId, name: app.localizedName ?? bundleId)
            }
        }
        return result
    }

    /// A running application plus the two facts `resolve(_:)` needs about it
    /// beyond its identity. Internal rather than private -- not public: `AppRef`
    /// is what leaves this class and gets stored on annotations and should stay
    /// a plain identity pair, but the test target needs `@testable import`
    /// visibility into `Candidate` (and its synthesized memberwise init) to feed
    /// hand-built candidate lists to `resolve(_:among:)`.
    struct Candidate {
        let ref: AppRef
        /// False when `NSRunningApplication.localizedName` was nil and
        /// `ref.name` is therefore just the bundle id echoed back -- i.e. this
        /// app has no display name to match against.
        let hasDisplayName: Bool
        /// False only for `.prohibited` processes (XPC services, faceless
        /// agents), which cannot be activated and therefore can never be the
        /// frontmost app an annotation is scoped to. `.regular` AND `.accessory`
        /// are both true: menu-bar-only utilities are perfectly valid targets.
        let canBeFrontmost: Bool
        /// `.regular` specifically -- an app with a Dock icon. Used only to
        /// order the candidate list shown when a query is ambiguous.
        let isRegularApp: Bool
    }

    private func runningCandidates() -> [Candidate] {
        var result: [Candidate] = []
        MainThread.sync {
            result = NSWorkspace.shared.runningApplications.compactMap { app in
                guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { return nil }
                let localizedName = app.localizedName
                return Candidate(
                    ref: AppRef(bundleId: bundleId, name: localizedName ?? bundleId),
                    hasDisplayName: localizedName != nil,
                    canBeFrontmost: app.activationPolicy != .prohibited,
                    isRegularApp: app.activationPolicy == .regular
                )
            }
        }
        return result
    }

    private func runningAppRefs() -> [AppRef] {
        return runningCandidates().map { $0.ref }
    }

    private func describe(_ app: NSRunningApplication?) -> String {
        guard let app = app else { return "<none>" }
        let bundleId = app.bundleIdentifier ?? "<no bundle id>"
        return "\(bundleId) (\(app.localizedName ?? "?"))"
    }
}
