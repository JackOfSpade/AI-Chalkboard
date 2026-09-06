import Foundation
#if os(Windows)
import WinSDK
#elseif os(macOS)
import AppKit
#endif

/// Gathers the environment facts `CaptureExclusionPolicy` decides from: does
/// this desktop look like it is being captured and streamed to a human
/// somewhere else?
///
/// Split from the policy on purpose. Everything here touches the live OS and so
/// cannot be unit-tested; everything the policy does is pure and is. The seam
/// between them is a plain `[String]` of signals, which is also exactly what
/// gets logged and reported, so there is no third representation to keep in
/// sync.
///
/// CACHING: the answer is cached for a few seconds rather than computed per
/// call. Enumerating processes is a syscall-heavy snapshot, and the callers are
/// presentation-path code that can ask several times in a burst (once per
/// monitor during a rebuild, once per foreground change). A short TTL rather
/// than a permanent memo is deliberate: a user can start Parsec, or connect to
/// an already-running remote-access daemon, long after this process launched,
/// and the whole point is to notice.
enum RemoteSessionProbe {

    /// Long enough that a burst of presentation-path calls costs one snapshot,
    /// short enough that starting a streaming host mid-session is picked up
    /// before the user has finished wondering why nothing happened.
    private static let cacheLifetimeSeconds: Double = 5

    private static let cacheLock = NSLock()
    private static var cachedSignals: [String]?
    /// Monotonic, from `DispatchTime` -- never `Date`, which jumps when the
    /// clock is corrected and would either freeze or thrash the cache.
    private static var cachedAtUptimeNanos: UInt64 = 0

    /// Human-readable reasons this session looks remote/streamed. Empty means
    /// it looks like an ordinary local desktop.
    static func currentSignals() -> [String] {
        let now = DispatchTime.now().uptimeNanoseconds
        cacheLock.lock()
        if let cached = cachedSignals,
           now >= cachedAtUptimeNanos,
           Double(now - cachedAtUptimeNanos) / 1_000_000_000 < cacheLifetimeSeconds {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Probed OUTSIDE the lock: this walks the process table, and holding a
        // lock across that would serialise every caller behind the slowest
        // snapshot for no benefit. Two callers racing here both do the work and
        // both store an equally fresh answer, which is harmless.
        let signals = probeNow()

        cacheLock.lock()
        cachedSignals = signals
        cachedAtUptimeNanos = DispatchTime.now().uptimeNanoseconds
        cacheLock.unlock()
        return signals
    }

    /// Drops the memo so the next `currentSignals()` re-probes. Exists for
    /// tests, and for callers that have just been told the environment changed.
    static func invalidateCache() {
        cacheLock.lock()
        cachedSignals = nil
        cachedAtUptimeNanos = 0
        cacheLock.unlock()
    }

#if os(Windows)

    private static func probeNow() -> [String] {
        CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: runningProcessNames(),
            isTerminalServicesSession: isTerminalServicesSession()
        )
    }

    /// `GetSystemMetrics(SM_REMOTESESSION)`: nonzero when this process is
    /// running in a Terminal Services / Remote Desktop client session.
    ///
    /// This is necessary but nowhere near sufficient, and the gap is the whole
    /// reason `runningProcessNames()` exists next to it: a cloud PC such as
    /// Shadow runs in the CONSOLE session against a virtual display adapter, so
    /// it reports 0 here while being just as streamed as any RDP session.
    /// Microsoft's own "Detecting the Terminal Services Environment" guidance
    /// makes the same point from the other side -- this metric answers "is this
    /// a TS session", not "is anyone watching remotely".
    private static func isTerminalServicesSession() -> Bool {
        // SM_REMOTESESSION = 0x1000 (winuser.h). Spelled as the literal with
        // the name in the comment because the constant's Swift binding is not
        // dependable across WinSDK overlay versions, and a missing symbol here
        // would be a build break in a file the macOS side never compiles.
        return GetSystemMetrics(0x1000) != 0
    }

    /// Every running process's executable name.
    ///
    /// Same `CreateToolhelp32Snapshot` + `PROCESSENTRY32W` walk (and the same
    /// `szExeFile` fixed-tuple decode) that `ActiveAppTracker.runningCandidates()`
    /// already uses -- see that function for the shape. This one keeps no PID
    /// and filters nothing: the policy's table does the matching, and handing it
    /// the raw list keeps the platform layer free of product knowledge.
    ///
    /// A failure returns an empty list, which resolves to "no remote session
    /// detected" and therefore to today's behaviour. That is the right way to
    /// fail for a probe whose job is to relax a restriction: never invent a
    /// signal we could not actually observe.
    private static func runningProcessNames() -> [String] {
        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0),
              snapshot != INVALID_HANDLE_VALUE else {
            Logger.shared.log("RemoteSessionProbe: CreateToolhelp32Snapshot failed (GetLastError=\(GetLastError())); this call sees no processes, so capture exclusion falls back to its ordinary-desktop default.", level: "WARN")
            return []
        }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snapshot, &entry) else { return [] }

        var names: [String] = []
        repeat {
            let exeName = withUnsafePointer(to: entry.szExeFile) { ptr -> String in
                ptr.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) { wide in
                    String(decodingCString: wide, as: UTF16.self)
                }
            }
            if !exeName.isEmpty {
                names.append(exeName)
            }
        } while Process32NextW(snapshot, &entry)

        return names
    }

#elseif os(macOS)

    private static func probeNow() -> [String] {
        // No Terminal Services equivalent on macOS, and deliberately no
        // invented stand-in: `false` here means "this platform has nothing to
        // report for that signal", not "checked and negative".
        CaptureExclusionPolicy.remoteSessionSignals(
            runningProcessNames: runningProcessNames(),
            isTerminalServicesSession: false
        )
    }

    /// Running applications, by executable name.
    ///
    /// THREADING: `NSWorkspace.runningApplications` is AppKit, and this is
    /// reached from the MCP server's background read queue (`get_screens`,
    /// `get_overlay_state`, `set_capture_visible` all read
    /// `captureExclusionDecision`), so it takes the same main-thread hop every
    /// other `NSWorkspace` query in this package takes -- see
    /// `MCPToolHandlers+Highlight.swift`, whose identical hop names this exact
    /// API. `MainThread.sync` runs inline when already on the UI thread, so the
    /// presentation path (`refreshViewsNow` -> `reconcileCaptureAffinity`)
    /// re-enters it safely rather than deadlocking.
    ///
    /// Strings are extracted INSIDE the hop for the same reason that file
    /// gives: no `NSRunningApplication` -- a live, main-thread-owned object --
    /// escapes back to the read queue. A `String` is just bytes.
    ///
    /// KNOWN GAPS, stated rather than papered over. There are TWO, and an
    /// earlier version of this comment claimed only the first while asserting
    /// that "Parsec, AnyDesk, TeamViewer, RustDesk are covered" -- which was
    /// not true of TeamViewer, and is the kind of confident wrong sentence
    /// that stops anyone from checking.
    ///
    ///   1. `NSWorkspace` enumerates launched applications, not daemons, so
    ///      macOS's own Screen Sharing (`screensharingd`) and other
    ///      launchd-only remote-access services are invisible here. Closing
    ///      this properly needs a `sysctl(KERN_PROC_ALL)` walk.
    ///   2. Even for applications it DOES see, matching depends on the name
    ///      lining up with `CaptureExclusionPolicy.knownStreamingHosts`, whose
    ///      entries are mostly Windows service binaries -- see that table's
    ///      own "MACOS NAMING" note. Product-name aliases are listed for the
    ///      vendors that ship a macOS host, but macOS detection is
    ///      structurally thinner than Windows', where the full process table
    ///      is walked.
    ///
    /// Until both are closed, README's "Remote and streamed sessions" section
    /// states the shortfall plainly and
    /// `AI_CHALKBOARD_CAPTURE_EXCLUSION=never` covers the case by hand.
    private static func runningProcessNames() -> [String] {
        MainThread.sync {
            NSWorkspace.shared.runningApplications.compactMap { app -> String? in
                app.executableURL?.lastPathComponent ?? app.bundleURL?.lastPathComponent
            }
        }
    }

#else

    private static func probeNow() -> [String] { [] }

#endif
}
