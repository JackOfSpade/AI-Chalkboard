import Foundation

/// Memoises `SVGPathParser.parse(_:)` results so a stored annotation's path
/// data is tokenised at most once per distinct path string, instead of once
/// per repaint.
///
/// WHY THIS EXISTS: `OverlayView.drawVectorPath` used to call
/// `SVGPathParser.parse(data)` inside `draw(_:)`. That is full tokenisation
/// plus, for any `A` command, trig-heavy arc-to-Bézier conversion -- for path
/// strings up to `DrawingDefaults.maxSVGPathCharacters` (200,000) characters.
/// `draw(_:)` runs on every store mutation, every app activation, every
/// capture-debug toggle, every suspend/resume, and every display
/// reconfiguration, for EVERY vector path on screen (including every vector
/// item nested inside a batch). A screen holding a handful of detailed
/// drawings therefore re-derived identical geometry continuously.
///
/// WHY CACHING IS SAFE (and pixel-identical): `SVGPathParser.parse` is a pure
/// function of its input string, and `ChalkPath` is an immutable value type
/// (every stored property is a `let`, and mutating operations like
/// `transformed(by:)` return a new value rather than modifying one in place).
/// Two calls with the same path data are therefore interchangeable. Critically, only the
/// UNTRANSFORMED source path is cached here -- callers still apply their own
/// per-draw `CGAffineTransform` (which varies with the screen's backing scale
/// and view height) to a copy, exactly as before. Caching the transformed
/// result instead would be wrong the moment the same annotation is drawn on a
/// second display or after a resolution change.
///
/// WHY IT IS BOUNDED: the store permits up to
/// `DrawingDefaults.maxStoredAnnotations` (2,000) annotations whose path data
/// may each approach the 200,000-character cap, and the cache is keyed by
/// content, so an unbounded cache is just a memory leak wearing a hat. Entries
/// are evicted least-recently-used once the retained key bytes exceed
/// `maximumRetainedBytes`.
///
/// Keying on content means there is nothing to invalidate: an edited or
/// re-added annotation simply presents a different key, and a stale entry can
/// only ever be an exact re-parse of the same string.
enum SVGPathCache {
    /// Retained budget for cached path-data keys.
    ///
    /// Sized well under the store's own 16 MiB retained-vector-payload cap so
    /// this cache can never be the component that exhausts memory: in the
    /// worst case it holds a second copy of a subset of the path strings the
    /// store is already retaining, plus their parsed `ChalkPath`s.
    static let maximumRetainedBytes = 4 * 1024 * 1024

    private static let lock = NSLock()
    /// Each entry carries the `useCounter` value at its most recent hit, so
    /// recency is stored WITH the entry rather than in a parallel array.
    ///
    /// It used to be a parallel `[String]` in least-recently-used order, which
    /// made every cache HIT a linear scan (`firstIndex(of:)`) doing full string
    /// comparisons against keys up to `DrawingDefaults.maxSVGPathCharacters`
    /// long -- on the render hot path this cache exists to keep cheap. A
    /// per-entry stamp turns a hit into one dictionary lookup plus one in-place
    /// write; only eviction has to consider every entry, and it does so once
    /// per CALL (one ordering pass, then victims taken from the front) rather
    /// than once per evicted entry.
    private static var entries: [String: (path: ChalkPath, lastUsed: UInt64)] = [:]
    /// Logical clock for recency ordering: the entry with the smallest
    /// `lastUsed` is the least recently used one. Wrapping would need 2^64
    /// lookups in one process lifetime, which no repaint rate reaches.
    private static var useCounter: UInt64 = 0
    private static var retainedBytes = 0

    /// Returns the parsed, untransformed path for `pathData`, parsing only on
    /// a miss. Rethrows the parser's error unchanged so callers keep their
    /// existing failure behaviour.
    ///
    /// Thread-safe: today every caller renders on the main thread (the live
    /// overlay through `draw(_:)`, verification through `MainThread.sync`),
    /// but this type must not silently become a data race if that ever
    /// changes, so it does not rely on that.
    static func path(for pathData: String) throws -> ChalkPath {
        lock.lock()
        if let cached = entries[pathData] {
            touch(pathData)
            lock.unlock()
            return cached.path
        }
        lock.unlock()

        // Parse OUTSIDE the lock: parsing is the expensive part, and holding
        // the lock across it would serialise every concurrent renderer behind
        // the slowest path. A duplicate concurrent parse of the same string is
        // harmless -- both produce equal immutable paths and the second store
        // simply replaces the first.
        let parsed = try SVGPathParser.parse(pathData)

        lock.lock()
        defer { lock.unlock() }
        if entries[pathData] == nil {
            useCounter &+= 1
            entries[pathData] = (path: parsed, lastUsed: useCounter)
            retainedBytes += pathData.utf8.count
            evictIfNeeded()
        } else {
            touch(pathData)
        }
        return parsed
    }

    /// Drops every cached entry. Exists for tests; production code never needs
    /// it because entries are content-keyed and bounded.
    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        retainedBytes = 0
    }

    /// Retained key bytes, for tests asserting that the bound is enforced.
    static var currentRetainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedBytes
    }

    /// Number of cached entries, for tests asserting reuse and eviction.
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Private (all callers already hold `lock`)

    private static func touch(_ key: String) {
        useCounter &+= 1
        entries[key]?.lastUsed = useCounter
    }

    private static func evictIfNeeded() {
        guard retainedBytes > maximumRetainedBytes, entries.count > 1 else { return }
        // One ordering pass for the whole eviction, rather than a fresh
        // `entries.min(by:)` full scan per victim: inserting one path near the
        // 200,000-character cap into a cache holding tens of thousands of small
        // ones evicts thousands of entries, and a scan each made that O(entries
        // x evicted) on the main-thread render path this cache exists to keep
        // cheap.
        let leastRecentlyUsedFirst = entries.map { (key: $0.key, lastUsed: $0.value.lastUsed) }
            .sorted { $0.lastUsed < $1.lastUsed }
        // `entries.count > 1` is load-bearing, not a micro-optimisation: a
        // single path bigger than the entire budget must stay cached. Without
        // this guard the loop would evict the entry it was just handed, so the
        // most expensive path imaginable -- the one whose re-parse cost most
        // justifies caching -- would be the one path re-parsed on every single
        // frame. Overshooting the budget by one outsized entry is the strictly
        // cheaper failure.
        for victim in leastRecentlyUsedFirst {
            guard retainedBytes > maximumRetainedBytes, entries.count > 1 else { return }
            if entries.removeValue(forKey: victim.key) != nil {
                retainedBytes -= victim.key.utf8.count
            }
        }
    }
}
