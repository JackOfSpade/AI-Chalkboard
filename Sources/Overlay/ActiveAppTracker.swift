import Foundation
#if os(macOS)
import AppKit
#elseif os(Windows)
import WinSDK
#endif

/// Shared conservative syntax for an exact, complete bundle identifier.
/// Three non-empty reverse-DNS components distinguish `com.apple.Safari` from
/// vague prefixes such as `com.apple`, which must still undergo ambiguity checks.
///
/// PLATFORM NOTE: this helper is used verbatim by BOTH platforms' `resolve()`
/// (below) and by the platform-neutral `DrawRequest.resolveTargetApp` (which
/// decides whether a query that matched no running app should still be
/// accepted verbatim as a future appId). Its "3+ dot-separated components"
/// shape is a macOS bundle-id convention. An ordinary Windows executable name
/// such as `"notepad.exe"` has only TWO dot-separated components and will
/// therefore almost never satisfy it -- see the Windows `ActiveAppTracker`
/// section below for exactly what that means for the `app` MCP parameter's
/// contract on Windows. This type is deliberately left unmodified (not
/// platform-forked) rather than reworked to also recognize
/// `"name.exe"`-shaped strings, because `DrawRequest.resolveTargetApp` -- a
/// file outside this one -- keys its own verbatim-acceptance branch off this
/// exact helper, and changing its behavior here would silently change that
/// unrelated file's contract without its owner's review.
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
///
/// PLATFORM NOTE: `bundleId` is a real macOS bundle identifier
/// (`"com.apple.Safari"`) on macOS, and an executable FILE NAME
/// (`"chrome.exe"`) on Windows -- see the Windows `ActiveAppTracker` section
/// below for the precise definition. The field is not renamed across
/// platforms because `Annotation.appId`, the `app` MCP parameter, and every
/// shared caller (`DrawRequest`, `MCPServer`) address it by this one name.
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

#if os(macOS)

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

    /// `currentAppId` and `currentAppName` as ONE consistent pair.
    ///
    /// Reading the two properties in turn takes the lock twice, and `adopt`
    /// writes both fields under a single acquisition between them if an app
    /// activation lands in that window -- so a caller that reports the two
    /// values as one "active app" object can publish a bundle id from one app
    /// beside the display name of another. Every diagnostic that emits both
    /// (`get_active_app`, `list_annotations`) should read them from here.
    public var currentApp: (bundleId: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_currentAppId, _currentAppName)
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

    /// `fallbackAppId` and `fallbackAppName` as ONE consistent pair, for the
    /// same reason as `currentApp`: reading the two properties in turn takes
    /// the lock twice, and `adopt` writes both fields under a single
    /// acquisition, so an app activation landing between them yields one app's
    /// bundle id beside another app's display name. Every caller that uses the
    /// two together -- to tag an annotation, to name a clear target, or to
    /// report the fallback -- should read them from here.
    public var fallbackApp: (bundleId: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_fallbackAppId, _fallbackAppName)
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

#elseif os(Windows)

/// Tracks which application is frontmost so overlay annotations can be scoped
/// to a single app: draw for DaVinci Resolve and the drawing appears only while
/// DaVinci Resolve is frontmost; switch to Terminal and Terminal's own drawings
/// appear instead.
///
/// STDOUT SAFETY: this process is an MCP stdio server speaking JSON-RPC over
/// fd 1. Every diagnostic in this file goes through `Logger.shared.log`
/// (stderr + rotating file). Never add a Swift `print` here.
///
/// ===========================================================================
/// WHY THIS IS NOT A LINE-FOR-LINE PORT OF THE macOS BRANCH ABOVE
/// ===========================================================================
///
/// This class exposes the IDENTICAL public/internal API the macOS branch
/// does -- same property names, same `resolve`/`AppResolution`/`AppRef`
/// shapes, same `currentApp`/`fallbackApp` pairing guarantee -- so every
/// shared caller (`DrawRequest`, `MCPServer`, `AppDelegate`) works unmodified
/// on both platforms. The MECHANISM underneath differs in two load-bearing
/// ways documented in full where they occur below:
///
/// 1. IDENTITY STRING. macOS has bundle identifiers (`"com.apple.Safari"`);
///    Windows has none. `AppRef.bundleId` here is the process's executable
///    FILE NAME (e.g. `"chrome.exe"`) -- see `exeFileName` below for the
///    exact definition and rationale. This is now part of the `app` MCP
///    parameter's tool contract on Windows: `Annotation.appId` persists this
///    string, and a caller's `app` argument is matched against it.
///
/// 2. EVENT GRANULARITY. `NSWorkspace.didActivateApplicationNotification` is
///    an APPLICATION-level event -- it does not fire when focus moves between
///    two windows of the SAME app. Win32's `EVENT_SYSTEM_FOREGROUND` is a
///    WINDOW-level event -- it fires on every such move, and on modal dialogs
///    stealing focus, alike. Every foreground event is therefore resolved to
///    its owning process's identity string and folded through the same
///    `adopt`-style exclusion logic the macOS branch uses, but the caller
///    (`handleForegroundChanged`) only repaints the overlay when that fold
///    reports the resolved APP IDENTITY actually changed -- never merely
///    because *a* window-level event fired. Without that de-duplication the
///    overlay would repaint on essentially every click.
public final class ActiveAppTracker {
    public static let shared = ActiveAppTracker()

    /// This app's own identity string -- see `exeFileName(forProcess:)` for
    /// exactly what that means. Hard-coded to the executable name
    /// `Package.swift`'s `.executable(name: "AIChalkboard", ...)` product
    /// always produces, mirroring the macOS branch's own hard-coded backstop
    /// (there `Bundle.main.bundleIdentifier` can be nil outside an .app
    /// bundle; here there is no bundle indirection to begin with, so the
    /// build's fixed output name is simply reliable). `isOwnApp` additionally
    /// cross-checks the CURRENT process's own live executable name
    /// (`liveOwnExeName`, computed once via `GetModuleFileNameW`), so a
    /// renamed/repackaged binary still excludes itself even if it no longer
    /// matches this constant -- the same "hard-coded constant OR a live
    /// self-identifier" shape the macOS branch uses, just with the live half
    /// sourced from the OS instead of `Bundle.main`.
    public static let ownBundleIdentifier = "AIChalkboard.exe"

    // MARK: - State
    //
    // THREADING: `_currentAppId`/`_fallbackAppId` and friends are written from
    // `WindowsUIThread` -- the process's single dedicated Win32 UI thread,
    // which is where the `SetWinEventHook` callback below is delivered (see
    // `startForegroundHook`) -- and read from the MCP server's background
    // read queue (`draw_*` tool calls) as well as from whatever thread paints
    // the overlay. Hence the same plain `NSLock` discipline the macOS branch
    // uses around the cached values -- Win32 APIs carry no main-thread
    // affinity requirement of their own (unlike AppKit), so the getters below
    // never need a thread hop, only the lock.

    private let lock = NSLock()

    private var _currentAppId: String?
    private var _currentAppName: String?
    private var _fallbackAppId: String?
    private var _fallbackAppName: String?

    /// Identity strings we have logged an exclusion for already, so a user
    /// tabbing between Claude and the overlay does not spam the log with the
    /// same line hundreds of times. Keyed lower-cased, matching every other
    /// case-insensitive identity comparison in this class.
    private var loggedExclusions: Set<String> = []

    private var isStarted = false

    /// The installed hook handle, so it could be torn down with
    /// `UnhookWinEvent` if this class ever grew a `stop()`. Currently nothing
    /// calls that -- the hook lives for the process lifetime, same as the
    /// macOS branch's NSWorkspace observer, which is likewise never removed.
    private var eventHook: HWINEVENTHOOK?

    /// See the macOS branch's identical property for the full contract this
    /// mirrors exactly (frontmost app, with AI Chalkboard's own activations
    /// ignored so the status UI never blanks every app-linked annotation
    /// while it is open).
    public var currentAppId: String? {
        lock.lock(); defer { lock.unlock() }
        return _currentAppId
    }

    /// Display name matching `currentAppId`.
    public var currentAppName: String? {
        lock.lock(); defer { lock.unlock() }
        return _currentAppName
    }

    /// `currentAppId` and `currentAppName` as ONE consistent pair -- see the
    /// macOS branch's identical property for why paired reads matter.
    public var currentApp: (bundleId: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_currentAppId, _currentAppName)
    }

    /// See the macOS branch's identical property for the full contract this
    /// mirrors exactly (the app an untagged `draw_*` call targets: the last
    /// app frontmost before Claude, never Claude itself).
    public var fallbackAppId: String? {
        lock.lock(); defer { lock.unlock() }
        return _fallbackAppId
    }

    /// Display name matching `fallbackAppId`.
    public var fallbackAppName: String? {
        lock.lock(); defer { lock.unlock() }
        return _fallbackAppName
    }

    /// `fallbackAppId` and `fallbackAppName` as ONE consistent pair -- see the
    /// macOS branch's identical property.
    public var fallbackApp: (bundleId: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_fallbackAppId, _fallbackAppName)
    }

    private init() {}

    // MARK: - Lifecycle

    /// Seeds the initial values and installs the foreground-tracking hook.
    /// Call once from wherever this process's Windows entry point stands in
    /// for `applicationDidFinishLaunching`. Safe to call from any thread --
    /// unlike the macOS branch, nothing here requires the caller's own thread
    /// to be a particular one; the hook is installed onto `WindowsUIThread`
    /// (starting it if needed) rather than run inline.
    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // ORDER MATTERS, for the same reason as the macOS branch: seed FIRST,
        // install the hook SECOND, so a foreground event delivered while the
        // hook is coming up can never be clobbered by a seed that is older by
        // construction than any event the hook could possibly deliver.
        let seededHwnd = GetForegroundWindow()
        var seedDescription = "<none>"
        if let hwnd = seededHwnd {
            var pid: DWORD = 0
            GetWindowThreadProcessId(hwnd, &pid)
            if let exeName = Self.exeFileName(forProcess: pid) {
                let title = Self.windowTitle(hwnd)
                seedDescription = "\(exeName) (\(title.isEmpty ? exeName : title))"
                _ = adopt(exeName: exeName, rawDisplayName: title, source: "startup seed")
            }
        }

        startForegroundHook()

        Logger.shared.log(
            "ActiveAppTracker: started (Windows). Installing SetWinEventHook(EVENT_SYSTEM_FOREGROUND) on WindowsUIThread, since WINEVENT_OUTOFCONTEXT delivery only happens while the installing thread calls GetMessage. Seed frontmost=\(seedDescription); current=\(currentAppId ?? "<none>"); fallback=\(fallbackAppId ?? "<none, untagged draws will be GLOBAL>").",
            level: "INFO"
        )
    }

    // MARK: - Foreground hook (WINDOW-level -> APP-level de-duplication)

    /// Installs the hook on `WindowsUIThread` -- AI Chalkboard's single
    /// dedicated Win32 UI thread (`Sources/Overlay/WindowsUIThread.swift`,
    /// owned by the overlay group) -- rather than spinning up a thread of
    /// its own.
    ///
    /// WHY IT MUST BE THAT SPECIFIC THREAD, AND WHY NOTHING ELSE HAS TO PUMP
    /// FOR IT: `SetWinEventHook` with `WINEVENT_OUTOFCONTEXT` does not invoke
    /// the callback the instant an event occurs -- per Microsoft's
    /// documentation for `WinEventProc`, the event is queued and only
    /// delivered "when the hooking application calls GetMessage or
    /// PeekMessage" ON THE THREAD THAT INSTALLED THE HOOK. `WindowsUIThread
    /// .sync` runs the installing call ON that thread (not merely from it),
    /// so the hook attaches to the OS thread id `WindowsUIThread.runLoop()`
    /// already pumps forever for its own window-message purposes -- delivery
    /// is a side effect of THAT existing `GetMessageW` loop, so this class
    /// needs no message loop, and no dispatch/filtering logic, of its own:
    /// `handleForegroundChanged` below is simply called back on whichever
    /// thread that loop is running on (`WindowsUIThread`'s), the same way any
    /// other Win32 callback registered from that thread would be.
    private func startForegroundHook() {
        WindowsUIThread.shared.start()
        WindowsUIThread.shared.sync { [weak self] in
            self?.installEventHook()
        }
    }

    private func installEventHook() {
        // WINEVENT_SKIPOWNPROCESS: our own overlay windows are non-activating
        // and should never legitimately become the foreground window, but
        // this costs nothing and mirrors the macOS branch's own note that its
        // overlay windows are "never meaningfully the app the user is looking
        // at" -- events about this process's own windows are simply not
        // interesting here even as a defensive matter.
        let hook = SetWinEventHook(
            UINT(EVENT_SYSTEM_FOREGROUND),
            UINT(EVENT_SYSTEM_FOREGROUND),
            nil,
            { _, event, hwnd, idObject, idChild, _, _ in
                // idObject/idChild filter out sub-object focus churn (e.g. a
                // title-bar control) that is not a window-level foreground
                // change at all -- OBJID_WINDOW/CHILDID_SELF is what a genuine
                // "this HWND is now the foreground window" event carries.
                guard event == UINT(EVENT_SYSTEM_FOREGROUND),
                      idObject == 0, idChild == 0,
                      let hwnd = hwnd else { return }
                ActiveAppTracker.shared.handleForegroundChanged(hwnd: hwnd, source: "EVENT_SYSTEM_FOREGROUND")
            },
            0,
            0,
            DWORD(WINEVENT_OUTOFCONTEXT) | DWORD(WINEVENT_SKIPOWNPROCESS)
        )

        lock.lock()
        eventHook = hook
        lock.unlock()

        if hook == nil {
            Logger.shared.log(
                "ActiveAppTracker: SetWinEventHook(EVENT_SYSTEM_FOREGROUND) failed (GetLastError=\(GetLastError())). Foreground-app tracking is DISABLED for the rest of this process's life -- currentAppId/fallbackAppId stay frozen at their startup-seed values, and no untagged draw_* call will ever retarget to a newly-frontmost app.",
                level: "ERROR"
            )
        }
    }

    /// Resolves one `EVENT_SYSTEM_FOREGROUND` event's HWND to an owning
    /// process identity, folds it through the same exclusion rules the macOS
    /// branch's `adopt` applies, and repaints the overlay ONLY when that fold
    /// reports the tracked identity actually changed.
    ///
    /// THE DE-DUPLICATION THIS EXISTS FOR: alt-tabbing between two windows of
    /// the SAME app (two Chrome windows, two Explorer windows), or a modal
    /// dialog taking focus within one app, fires this event with no real app
    /// switch. `adopt` below still runs the full exclusion logic every time
    /// (cheap, and it is what keeps `loggedExclusions`/timing correct), but
    /// its returned `didChange` is what gates the repaint -- unlike the macOS
    /// branch, where `appDidActivate` repaints unconditionally, because an
    /// application-level activation notification is already close to the
    /// granularity actually wanted. Gating unconditionally here is required,
    /// not optional: EVENT_SYSTEM_FOREGROUND fires far more often than macOS's
    /// notification, and repainting the overlay on every such no-op event
    /// would make the overlay redraw continuously during ordinary use of a
    /// multi-window app.
    private func handleForegroundChanged(hwnd: HWND, source: String) {
        var pid: DWORD = 0
        GetWindowThreadProcessId(hwnd, &pid)
        guard pid != 0, let exeName = Self.exeFileName(forProcess: pid) else { return }
        let title = Self.windowTitle(hwnd)
        let changed = adopt(exeName: exeName, rawDisplayName: title, source: source)
        if changed {
            // Same repaint call the macOS branch makes from `appDidActivate`,
            // and the same reason it is not routed through
            // `AnnotationStore.onStoreChanged` -- see that branch's comment.
            OverlayWindowController.shared.refreshViews()
        }
    }

    /// Folds a newly-foreground process's identity into `current` and
    /// `fallback`, applying the exclusion rules for each, exactly mirroring
    /// the macOS branch's `adopt(app:source:)` -- see its doc comment for the
    /// full "why fallback exists" rationale, which is unchanged on Windows.
    ///
    /// Returns whether the tracked state actually changed, so
    /// `handleForegroundChanged` can gate its repaint on it (see that
    /// method's doc comment for why that gate is mandatory here and was
    /// optional on macOS).
    ///
    /// UNLIKE the macOS branch, there is no `isProhibited` exclusion here:
    /// macOS's `.prohibited` activation policy identifies XPC services and
    /// faceless agents that can never legitimately become frontmost, but
    /// every call to THIS method already carries an HWND that Windows itself
    /// just reported as the foreground window -- there is no equivalent
    /// "this process could never really be frontmost" case to filter at this
    /// call site. (The analogous concern for `resolve()`'s broader candidate
    /// enumeration -- where far more processes than could ever be foreground
    /// are visible -- is handled there instead; see `runningCandidates()`.)
    @discardableResult
    private func adopt(exeName: String, rawDisplayName: String, source: String) -> Bool {
        guard !exeName.isEmpty else { return false }
        let name = rawDisplayName.isEmpty ? Self.displayNameFallback(forExeName: exeName) : rawDisplayName

        let isSelf = isOwnApp(exeName)
        let isClaude = isClaudeApp(exeName)
        let isSystemSessionApp = Self.isSystemSessionApp(exeName)

        lock.lock()
        let previousCurrentId = _currentAppId
        let previousFallbackId = _fallbackAppId
        if !isSelf {
            _currentAppId = exeName
            _currentAppName = name
        }
        if !isSelf && !isClaude && !isSystemSessionApp {
            _fallbackAppId = exeName
            _fallbackAppName = name
        }
        // Snapshot for the log line while still holding the lock -- see the
        // macOS branch's identical comment for why an unlocked read here
        // would be a real race, not just a cosmetic one.
        let didChange = (_currentAppId != previousCurrentId) || (_fallbackAppId != previousFallbackId)
        let currentForLog = _currentAppId ?? "<none>"
        let fallbackForLog = _fallbackAppId ?? "<none>"
        let shouldLogExclusion = (isSelf || isClaude || isSystemSessionApp)
            && loggedExclusions.insert(exeName.lowercased()).inserted
        lock.unlock()

        if shouldLogExclusion {
            let reason: String
            if isSelf {
                reason = "it is AI Chalkboard itself"
            } else if isClaude {
                reason = "it matched the Claude/Anthropic heuristic"
            } else {
                reason = "it is Windows session/lock-screen UI, not an app the user can annotate"
            }
            Logger.shared.log(
                "ActiveAppTracker: EXCLUDING '\(exeName)' (\(name)) from the untagged-draw fallback target because \(reason). Untagged draw_* calls will stay linked to the last app before it.",
                level: "INFO"
            )
        }

        // Only log when the tracked state ACTUALLY changed -- see the macOS
        // branch's identical comment. On Windows this matters even MORE:
        // EVENT_SYSTEM_FOREGROUND fires on every window-level focus change,
        // not just application switches, so an unconditional log line here
        // would churn the rotating log file far faster than on macOS.
        if !isSelf && didChange {
            Logger.shared.log(
                "ActiveAppTracker: frontmost app is now '\(exeName)' (\(name)) [\(source)]. current=\(currentForLog); fallback=\(fallbackForLog).",
                level: "DEBUG"
            )
        }
        return didChange
    }

    // MARK: - Identity string

    /// THE WINDOWS IDENTITY STRING -- this is now part of the `app` MCP
    /// parameter's tool contract, so its definition is precise and fixed:
    ///
    ///   The FILE NAME component (everything after the final `\` or `/`,
    ///   extension included -- e.g. `"chrome.exe"`, `"AIChalkboard.exe"`) of
    ///   the value `QueryFullProcessImageNameW` reports for the process,
    ///   compared and stored CASE-INSENSITIVELY (Windows paths are
    ///   case-insensitive, so `"Chrome.exe"` and `"chrome.exe"` must be the
    ///   same identity).
    ///
    /// WHY THE FILE NAME AND NOT THE FULL PATH: the full path
    /// (`"C:\Program Files\Google\Chrome\Application\chrome.exe"`) is more
    /// specific, but that specificity is a liability here, not an asset --
    /// an app updating itself into a new versioned directory, a user moving
    /// an install, or the same app installed per-user vs. machine-wide would
    /// all mint a NEW identity string for what is, to the user, the same
    /// application, silently orphaning every annotation stored under the old
    /// path. The file name is exactly as stable as a macOS bundle identifier
    /// -- tied to the app, not to where it happens to live on disk today --
    /// which is the property `Annotation.appId` actually needs.
    ///
    /// WHY NOT THE STEM (dropping `.exe`): the extension is part of what the
    /// file system actually calls the executable; trimming it buys nothing
    /// (Windows executables are overwhelmingly `.exe`; the rare non-`.exe`
    /// host would become ambiguous against an unrelated `.exe` of the same
    /// stem) and would only make this identity string look more like a macOS
    /// bundle id than it actually is.
    ///
    /// KNOWN CONSEQUENCE, stated precisely per this task's contract rules:
    /// several distinct running processes can legitimately share one
    /// identity string. Every Chromium-based app spawns many `chrome.exe` /
    /// `msedge.exe` helper processes, and DaVinci Resolve spawns render/
    /// worker helpers under related executable names -- `resolve()`'s
    /// candidate de-duplication (`dedupedByBundleId`, unchanged from the
    /// macOS branch) collapses same-identity processes into one candidate
    /// exactly as it collapses macOS helper `NSRunningApplication` entries,
    /// so this is not by itself a source of spurious ambiguity. It DOES mean
    /// Windows' per-process granularity is coarser than macOS's: two
    /// unrelated top-level windows of the same multi-process app are
    /// indistinguishable by this identity string, which they also are on
    /// macOS (bundle id is likewise per-app, not per-window) -- so this is a
    /// parity property, not a regression.
    private static func exeFileName(forProcess pid: DWORD) -> String? {
        guard pid != 0 else { return nil }
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else {
            return nil
        }
        defer { CloseHandle(handle) }

        var buffer = [WCHAR](repeating: 0, count: 1024)
        var size = DWORD(buffer.count)
        let ok = buffer.withUnsafeMutableBufferPointer { ptr -> Bool in
            QueryFullProcessImageNameW(handle, 0, ptr.baseAddress, &size)
        }
        guard ok, size > 0, size <= DWORD(buffer.count) else { return nil }

        let path = String(decoding: buffer[0..<Int(size)], as: UTF16.self)
        return fileName(fromWindowsPath: path)
    }

    /// This process's own executable file name, computed once via
    /// `GetModuleFileNameW(nil, ...)` -- the live half of the `isOwnApp`
    /// dual-check described on `ownBundleIdentifier` above.
    private static let liveOwnExeName: String? = {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        let length = buffer.withUnsafeMutableBufferPointer { ptr -> DWORD in
            GetModuleFileNameW(nil, ptr.baseAddress, DWORD(ptr.count))
        }
        guard length > 0, length < DWORD(buffer.count) else { return nil }
        let path = String(decoding: buffer[0..<Int(length)], as: UTF16.self)
        return fileName(fromWindowsPath: path)
    }()

    private static func fileName(fromWindowsPath path: String) -> String {
        if let idx = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(path[path.index(after: idx)...])
        }
        return path
    }

    /// Best-effort display name for an identity string that has no real
    /// window title to show (`rawDisplayName` was empty) -- the file name
    /// with its extension dropped, so `"notepad.exe"` reads as `"notepad"`
    /// rather than echoing the raw identity string back verbatim. This is
    /// NOT treated as a genuine display name by `resolve()`'s `Candidate
    /// .hasDisplayName` (see `runningCandidates()`): it exists purely for
    /// human-readable logging and `currentAppName`/`fallbackAppName`, mirroring
    /// the macOS branch's `app?.localizedName ?? bundleId` fallback.
    private static func displayNameFallback(forExeName exeName: String) -> String {
        if let dot = exeName.lastIndex(of: "."), dot != exeName.startIndex {
            return String(exeName[exeName.startIndex..<dot])
        }
        return exeName
    }

    private static func windowTitle(_ hwnd: HWND) -> String {
        let length = GetWindowTextLengthW(hwnd)
        guard length > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
        let copied = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            GetWindowTextW(hwnd, ptr.baseAddress, Int32(ptr.count))
        }
        guard copied > 0 else { return "" }
        return String(decoding: buffer[0..<Int(copied)], as: UTF16.self)
    }

    // MARK: - Exclusion rules

    private func isOwnApp(_ exeName: String) -> Bool {
        if exeName.caseInsensitiveCompare(Self.ownBundleIdentifier) == .orderedSame { return true }
        if let live = Self.liveOwnExeName, exeName.caseInsensitiveCompare(live) == .orderedSame {
            return true
        }
        return false
    }

    /// Whether `exeName` looks like a Claude / Anthropic client. Same
    /// deliberately loose substring heuristic as the macOS branch's
    /// `isClaudeApp` -- see its doc comment for the full rationale, which is
    /// unchanged here: guessing one exact executable name would silently
    /// break the day Claude's Windows client renames it, and the failure
    /// mode (every annotation quietly linked to Claude) is invisible.
    private func isClaudeApp(_ exeName: String) -> Bool {
        let lower = exeName.lowercased()
        return lower.contains("anthropic") || lower.contains("claude")
    }

    /// The Windows analogues of macOS's `loginwindow` -- session/lock-screen
    /// UI that can transiently become the foreground window while the
    /// workstation is locked and is never a usable annotation target:
    /// `LockApp.exe` (the modern lock-screen host) and `LogonUI.exe` (the
    /// secure-desktop credential prompt, still used for UAC and some sign-in
    /// flows). This is a best-effort list, not an exhaustive one -- there is
    /// no single Windows API that names "session UI" the way macOS names
    /// `loginwindow`, so this enumerates the concrete processes actually
    /// observed taking the foreground during a lock/sign-in, the same
    /// empirical spirit as the macOS branch's own comment that
    /// "activationPolicy alone cannot identify this unusable fallback
    /// target".
    static func isSystemSessionApp(_ exeName: String) -> Bool {
        exeName.caseInsensitiveCompare("LockApp.exe") == .orderedSame
            || exeName.caseInsensitiveCompare("LogonUI.exe") == .orderedSame
    }

    // MARK: - Resolution

    /// Resolves a user-supplied string against the CURRENT set of running,
    /// window-owning applications. See the macOS branch's identical entry
    /// point for why this stays a thin wrapper around the pure overload
    /// below -- `Candidate` construction differs completely (process
    /// enumeration instead of `NSWorkspace`), but the matching algorithm
    /// itself is IDENTICAL and lives in the pure `resolve(_:among:)` overload
    /// shared in spirit (duplicated in code, per this file's platform-branch
    /// rule) with the macOS one.
    public func resolve(_ raw: String?) -> AppResolution {
        guard let query = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .notFound
        }
        return resolve(query, among: runningCandidates())
    }

    /// Resolves a user-supplied string -- an executable name
    /// ("chrome.exe") or a window title ("DaVinci Resolve") -- to a
    /// concrete application, matched against `candidates`.
    ///
    /// THE ALGORITHM IS IDENTICAL to the macOS branch's `resolve(_:among:)`
    /// -- same four-pass matching order, same uniqueness requirement, same
    /// de-duplication, same `.ambiguous`/`.notFound` semantics; see that
    /// method's extensive doc comment for the full rationale, none of which
    /// is platform-specific. Duplicated here rather than shared via a common
    /// helper because the two classes are entirely separate types (this
    /// file's platform-branch rule keeps the macOS branch byte-for-byte
    /// unchanged), and `Candidate` is constructed differently on each side.
    ///
    /// ONE CONTRACT DIFFERENCE, stated precisely per this task's rules: the
    /// "a fully-qualified id that matches no running app is preserved
    /// verbatim" step below calls the SAME `BundleIdentifierSyntax
    /// .looksComplete` the macOS branch uses (shared, unmodified -- see its
    /// doc comment at the top of this file). That check requires 3+
    /// dot-separated components ("reverse-DNS shaped"), which an ordinary
    /// Windows executable name such as `"notepad.exe"` (2 components) will
    /// almost never satisfy. The PRACTICAL EFFECT: on Windows, `draw_*` with
    /// an `app` argument naming an application that is NOT currently running
    /// is rejected outright ("Could not resolve app...") rather than being
    /// accepted verbatim and left to resolve once that app launches, unlike
    /// macOS's bundle-id case. This gap is deliberately left open here (see
    /// this task's `contractChanges` for the full statement) rather than
    /// "fixed" by editing `DrawRequest.resolveTargetApp` -- a file outside
    /// this one's ownership -- to recognize `"name.exe"`-shaped strings,
    /// since that call site's verbatim-acceptance rule should be a decision
    /// its own owner makes deliberately, not an incidental side effect of
    /// this file's port.
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
        if BundleIdentifierSyntax.looksComplete(query) {
            Logger.shared.log(
                "ActiveAppTracker: '\(query)' is a complete (reverse-DNS-shaped) identifier that matched no running application. Not attempting a fuzzy match. The caller may store it verbatim, in which case the annotation stays hidden until a process reporting that exact identity is foregrounded. NOTE: an ordinary Windows executable name like 'notepad.exe' does not satisfy this shape and will instead fall through to '.notFound' below -- see this method's doc comment.",
                level: "INFO"
            )
            return .notFound
        }

        let lowered = query.lowercased()
        let fuzzyCandidates = candidates.filter { $0.canBeFrontmost }

        let bundleIdHits = dedupedByBundleId(fuzzyCandidates.filter { $0.ref.bundleId.lowercased().hasPrefix(lowered) })
        if bundleIdHits.count == 1 {
            return .resolved(bundleIdHits[0].ref)
        }

        let nameHits = dedupedByBundleId(fuzzyCandidates.filter { $0.hasDisplayName && $0.ref.name.lowercased().contains(lowered) })
        if nameHits.count == 1 {
            return .resolved(nameHits[0].ref)
        }

        var ambiguous = bundleIdHits
        for hit in nameHits where !ambiguous.contains(where: { $0.ref.bundleId.caseInsensitiveCompare(hit.ref.bundleId) == .orderedSame }) {
            ambiguous.append(hit)
        }
        if ambiguous.count > 1 {
            return ambiguousResolution(query: query, hits: ambiguous)
        }

        Logger.shared.log("ActiveAppTracker: could not resolve app '\(query)' against \(candidates.count) running, window-owning processes.", level: "WARN")
        return .notFound
    }

    private func ambiguousResolution(query: String, hits: [Candidate]) -> AppResolution {
        let ordered = hits.filter { $0.isRegularApp }.map { $0.ref }
            + hits.filter { !$0.isRegularApp }.map { $0.ref }
        Logger.shared.log("ActiveAppTracker: app query '\(query)' is AMBIGUOUS -- it matches \(ordered.count) running, window-owning processes (\(ordered.map { $0.bundleId }.joined(separator: ", "))). Refusing to guess; the caller is told to be more specific.", level: "WARN")
        return .ambiguous(ordered)
    }

    private func dedupedByBundleId(_ hits: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for hit in hits where seen.insert(hit.ref.bundleId.lowercased()).inserted {
            result.append(hit)
        }
        return result
    }

    /// Best-effort display name for an identity string, for diagnostics
    /// (`list_annotations`). `nil` when no running, window-owning process
    /// currently reports that identity.
    public func displayName(forBundleId bundleId: String?) -> String? {
        guard let bundleId = bundleId, !bundleId.isEmpty else { return nil }
        return runningAppRefs().first(where: { $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame })?.name
    }

    /// The literal current value of `GetForegroundWindow()`, with no
    /// exclusions applied at all -- the Windows analogue of the macOS
    /// branch's `rawFrontmostApp()`, used by the `get_active_app` tool so
    /// Claude can see the raw truth next to the filtered values.
    public func rawFrontmostApp() -> AppRef? {
        guard let hwnd = GetForegroundWindow() else { return nil }
        var pid: DWORD = 0
        GetWindowThreadProcessId(hwnd, &pid)
        guard pid != 0, let exeName = Self.exeFileName(forProcess: pid) else { return nil }
        let title = Self.windowTitle(hwnd)
        return AppRef(bundleId: exeName, name: title.isEmpty ? Self.displayNameFallback(forExeName: exeName) : title)
    }

    /// A running, window-owning process plus the two facts `resolve(_:)`
    /// needs about it beyond its identity -- the Windows analogue of the
    /// macOS branch's `Candidate`, same field names and roles so the shared
    /// pure-matching algorithm above reads identically on both sides.
    struct Candidate {
        let ref: AppRef
        /// False when NO window belonging to this process reported a
        /// non-empty title, so `ref.name` is a synthesized fallback (see
        /// `displayNameFallback`) rather than a real display name -- the
        /// direct analogue of the macOS branch's "no `localizedName`" case,
        /// and excluded from the name-matching passes for the identical
        /// reason (see that branch's doc comment on why a pseudo-name must
        /// not be matchable).
        let hasDisplayName: Bool
        /// Always `true` for every `Candidate` this class constructs:
        /// `runningCandidates()` only builds one for a process that owns at
        /// least one visible, top-level, non-tool window in the first place
        /// (see that method's doc comment for why that filter exists at
        /// enumeration time rather than per-pass here). Kept as a field
        /// rather than dropped so the shared matching algorithm above stays
        /// textually identical to the macOS branch's.
        let canBeFrontmost: Bool
        /// Best-effort proxy for macOS's `.regular` (an app with a Dock
        /// icon): `true` when the window this candidate's name came from is
        /// a normal, taskbar-visible top-level window (no `WS_EX_TOOLWINDOW`
        /// style, or `WS_EX_APPWINDOW` forcing it back in). Windows has no
        /// real analogue of macOS's activation-policy taxonomy; this is the
        /// closest available signal and is used only to order the candidate
        /// list shown when a query is ambiguous, exactly as on macOS.
        let isRegularApp: Bool
    }

    /// One process's aggregated window information, built while walking
    /// `EnumWindows` once (see `runningCandidates()`).
    private struct WindowAggregate {
        var bestTitle: String = ""
        var isRegularApp: Bool = false
    }

    /// Builds today's app candidate list for `resolve(_:among:)`.
    ///
    /// TWO-PASS DESIGN, mirroring this method's own doc comment on
    /// `runningCandidates()`'s job:
    ///
    ///   1. `EnumWindows` ONCE, filtered to windows that look like genuine,
    ///      user-facing top-level windows (visible, unowned, not a
    ///      `WS_EX_TOOLWINDOW` unless explicitly forced back in via
    ///      `WS_EX_APPWINDOW` -- the standard "alt-tab list" heuristic),
    ///      aggregated by owning process id into a `[DWORD: WindowAggregate]`.
    ///      This is the Windows analogue of macOS's `.prohibited` exclusion:
    ///      a raw process list (`CreateToolhelp32Snapshot`) alone is far
    ///      noisier than `NSWorkspace.runningApplications` -- it includes
    ///      every background service and helper process on the machine, none
    ///      of which can ever legitimately be "the frontmost app" an
    ///      annotation is scoped to. Filtering to window-owning processes
    ///      keeps the candidate list at roughly macOS's granularity, so
    ///      `resolve()`'s ambiguity errors do not fire on every query the way
    ///      they would against the raw process list.
    ///
    ///   2. `CreateToolhelp32Snapshot`/`Process32NextW` to enumerate all
    ///      processes and pick out their `szExeFile` (already just the base
    ///      file name -- no path to parse), keeping only those present in the
    ///      window-owning set from step 1, and excluding this process's own
    ///      pid.
    ///
    /// LIMITATION, stated precisely per this task's contract rules: this is
    /// a proxy, not an exact translation of macOS's `.regular`/`.accessory`/
    /// `.prohibited` taxonomy, which has no Windows analogue. "Owns a
    /// visible, top-level, non-tool window right now" is the closest
    /// available signal for "could plausibly be the app the user means",
    /// and it is what both `canBeFrontmost` (always true for a constructed
    /// `Candidate`) and `isRegularApp` are built from.
    private func runningCandidates() -> [Candidate] {
        let ownPid = GetCurrentProcessId()

        var windowsByPid: [DWORD: WindowAggregate] = [:]
        // `EnumWindows`' own BOOL return -- distinct from the per-window
        // callback's `Bool`, which only ever returns `true` below (this scan
        // never asks to stop early) -- is `false` only when enumeration
        // itself could not run at all (e.g. the process is out of desktop
        // heap, or another low-level USER32 failure). That is a real,
        // actionable failure this call used to discard silently: unlike a
        // callback-requested stop, it means `windowsByPid` was never
        // populated, and `resolve()` would then just see an empty candidate
        // list with no clue why -- exactly the kind of failure
        // `CreateToolhelp32Snapshot` below already logs instead of eating.
        let enumerationSucceeded: Bool = withUnsafeMutablePointer(to: &windowsByPid) { ptr in
            EnumWindows({ hwnd, lParam in
                guard let hwnd = hwnd else { return true }
                guard IsWindowVisible(hwnd) else { return true }
                guard GetWindow(hwnd, UINT(GW_OWNER)) == nil else { return true }

                let exStyle = UInt32(bitPattern: Int32(GetWindowLongW(hwnd, GWL_EXSTYLE)))
                let isToolWindow = (exStyle & UInt32(WS_EX_TOOLWINDOW)) != 0
                let isForcedAppWindow = (exStyle & UInt32(WS_EX_APPWINDOW)) != 0
                guard !isToolWindow || isForcedAppWindow else { return true }

                var pid: DWORD = 0
                GetWindowThreadProcessId(hwnd, &pid)
                guard pid != 0 else { return true }

                let title = ActiveAppTracker.windowTitle(hwnd)
                let aggregatesPtr = UnsafeMutableRawPointer(bitPattern: Int(lParam))!
                    .assumingMemoryBound(to: [DWORD: WindowAggregate].self)
                var aggregate = aggregatesPtr.pointee[pid] ?? WindowAggregate()
                if aggregate.bestTitle.isEmpty && !title.isEmpty {
                    aggregate.bestTitle = title
                }
                aggregate.isRegularApp = aggregate.isRegularApp || !isToolWindow
                aggregatesPtr.pointee[pid] = aggregate
                return true
            }, LPARAM(Int(bitPattern: ptr)))
        }
        if !enumerationSucceeded {
            Logger.shared.log("ActiveAppTracker: EnumWindows failed (GetLastError=\(GetLastError())); resolve() will see an incomplete (possibly empty) candidate list this call.", level: "WARN")
        }

        guard !windowsByPid.isEmpty else { return [] }

        var result: [Candidate] = []
        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0), snapshot != INVALID_HANDLE_VALUE else {
            Logger.shared.log("ActiveAppTracker: CreateToolhelp32Snapshot failed (GetLastError=\(GetLastError())); resolve() will see no candidates this call.", level: "WARN")
            return []
        }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snapshot, &entry) else { return [] }

        repeat {
            let pid = entry.th32ProcessID
            guard pid != ownPid, let aggregate = windowsByPid[pid] else { continue }
            let exeName = withUnsafePointer(to: entry.szExeFile) { ptr -> String in
                ptr.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) { wide in
                    String(decodingCString: wide, as: UTF16.self)
                }
            }
            guard !exeName.isEmpty else { continue }

            let hasTitle = !aggregate.bestTitle.isEmpty
            result.append(Candidate(
                ref: AppRef(bundleId: exeName, name: hasTitle ? aggregate.bestTitle : Self.displayNameFallback(forExeName: exeName)),
                hasDisplayName: hasTitle,
                canBeFrontmost: true,
                isRegularApp: aggregate.isRegularApp
            ))
        } while Process32NextW(snapshot, &entry)

        return result
    }

    private func runningAppRefs() -> [AppRef] {
        return runningCandidates().map { $0.ref }
    }
}

#endif
