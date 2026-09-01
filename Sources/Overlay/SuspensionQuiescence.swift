import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
#elseif os(Windows)
import WinSDK
#endif

/// Conservative evidence used after a lease acquisition, taken by reading
/// this platform's own window-presentation state rather than trusting a
/// timer.  It is intentionally a snapshot, not a promise: another process can
/// create a window immediately afterward and only a click dispatcher that
/// participates in this protocol can close that remaining race.
///
/// WHAT "quiescent" MEANS IS PLATFORM-DEPENDENT, AND THAT DIFFERENCE IS
/// LOAD-BEARING -- see the doc comments on the macOS and Windows
/// `observeQuiescence()` implementations below (and, for the precise
/// end-to-end honesty statement, this port's contractChanges) before reusing
/// `quiescent`/`scope` for anything beyond what `SuspensionLeaseCoordinator`
/// already does with them. In short: on macOS this is a read of WindowServer
/// -- the compositor's own registration of what it is currently presenting.
/// On Windows there is no equivalent single ground-truth read, so this is
/// instead two Win32/DWM window-STATE samples (`IsWindowVisible` plus
/// `DWMWA_CLOAKED`) taken 50ms apart, corroborated by a `DwmFlush()` proving
/// a real compositor frame boundary was crossed during the observation. That
/// is a meaningfully weaker guarantee than a compositor registration read,
/// and `SuspensionQuiescenceObservation.scope`'s Windows text says so
/// explicitly rather than reusing the macOS wording.
public struct SuspensionQuiescenceObservation: Equatable {
    public let quiescent: Bool
    // `Int32`, not `pid_t`: `pid_t` is a Darwin-only typealias (itself just
    // `Int32`), and this struct is shared, unmodified source between the
    // macOS and Windows implementations below. Spelling it as `Int32`
    // directly changes nothing about macOS behavior or its ABI -- `pid_t` IS
    // `Int32` -- and it is also exactly the type `GetWindowThreadProcessId`'s
    // `DWORD` process id narrows to on Windows, so one struct definition
    // serves both platforms without an `#if` of its own.
    public let candidatePIDs: [Int32]
    public let candidatePIDsTruncated: Bool
    public let visibleOwnerPIDs: [Int32]
    public let visibleWindowNumbers: [Int]
    public let discoveryErrors: [String]
    public let sampleCount: Int
    public let scope: String
}

#if os(macOS)
public extension SuspensionLeaseCoordinator {
    /// Takes two WindowServer samples about 50ms apart.  It only returns true
    /// when both are empty for every conservatively discovered Chalkboard PID.
    /// Candidate discovery is repeated for *each* sample: a process that
    /// starts after the first discovery must not be omitted from the final
    /// point-in-time claim. Discovery uncertainty itself is fail-closed.
    func observeQuiescence(timeout: TimeInterval = 1.0) -> SuspensionQuiescenceObservation {
        let started = DispatchTime.now().uptimeNanoseconds
        let first = Self.sample()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        guard elapsed + 0.05 <= max(0, timeout) else {
            return Self.observation(first: first, second: first, sampleCount: 1)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let second = Self.sample()
        return Self.observation(first: first, second: second, sampleCount: 2)
    }

    private static let discoveryScope = "same-UID Chalkboard executables discovered by NSWorkspace/libproc plus currently on-screen Chalkboard-owned WindowServer windows"

    private static let maximumEvidenceEntries = 128
    private typealias Sample = (pids: [pid_t], truncated: Bool, errors: [String], visible: [(pid_t, Int)], visibleTruncated: Bool)

    private static func sample() -> Sample {
        // One WindowServer list per sample, shared by both halves. Taking two
        // independent snapshots meant the candidate PIDs were matched against
        // a window list that never contained them (or vice versa), so a single
        // "sample" was really a torn pair -- and a suspend/resume made up to
        // twelve of these list calls.
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        let discovery = discoverCandidateProcesses(windowList: windowList)
        // When discovery itself is incomplete do not infer absence from an
        // arbitrary partial PID list. The result remains unsafe either way.
        let visible = visibleWindows(ownedBy: Set(discovery.pids), in: windowList)
        let visibleTruncated = visible.count > maximumEvidenceEntries
        return (discovery.pids, discovery.truncated, discovery.errors,
                Array(visible.prefix(maximumEvidenceEntries)), visibleTruncated)
    }

    private static func observation(first: Sample, second: Sample,
                                    sampleCount: Int) -> SuspensionQuiescenceObservation {
        let all = first.visible + second.visible
        let allCandidates = Array(Set(first.pids + second.pids)).sorted()
        let candidatesTruncated = first.truncated || second.truncated || allCandidates.count > maximumEvidenceEntries || first.visibleTruncated || second.visibleTruncated
        let candidates = Array(allCandidates.prefix(maximumEvidenceEntries))
        let errors = Array(Set(first.errors + second.errors)).sorted()
        return SuspensionQuiescenceObservation(
            quiescent: sampleCount == 2 && all.isEmpty && errors.isEmpty && !candidatesTruncated,
            candidatePIDs: candidates, candidatePIDsTruncated: candidatesTruncated,
            visibleOwnerPIDs: Array(Set(all.map(\.0))).sorted(),
            visibleWindowNumbers: Array(Set(all.map(\.1))).sorted(),
            discoveryErrors: errors, sampleCount: sampleCount, scope: discoveryScope
        )
    }

    /// `windowList` is this sample's single on-screen snapshot, or nil when
    /// WindowServer refused to produce one.
    private static func discoverCandidateProcesses(windowList: [[String: Any]]?) -> (pids: [pid_t], truncated: Bool, errors: [String]) {
        var pids: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        var errors: [String] = []
        let identity = currentExecutableIdentity()
        if identity.executablePath == nil && identity.bundleIdentifier == nil {
            errors.append("Unable to identify this Chalkboard executable for cross-process quiescence discovery.")
        }

        // LaunchServices is best at bundled app identity and is safe only on
        // AppKit's main thread.
        let workspacePIDs: [pid_t] = MainThread.sync {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.processIdentifier > 0, !app.isTerminated else { return nil }
                let candidate = (bundleIdentifier: app.bundleIdentifier,
                                 executablePath: normalizedPath(app.executableURL))
                return identitiesMatch(candidate, identity) ? app.processIdentifier : nil
            }
        }
        pids.formUnion(workspacePIDs)

        // Raw `swift run`/development instances may have no NSWorkspace entry.
        // libproc lets us include only processes owned by our UID whose
        // executable path is exactly the resolved Chalkboard executable.
        if let ownPath = identity.executablePath {
            let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            if bytes <= 0 {
                errors.append("libproc could not enumerate same-UID processes for quiescence discovery.")
            } else {
                var raw = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
                let actual = raw.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
                if actual < 0 {
                    errors.append("libproc failed while enumerating same-UID processes for quiescence discovery.")
                } else {
                    for pid in raw where pid > 0 {
                        guard processUID(pid) == getuid(), processPath(pid) == ownPath else { continue }
                        pids.insert(pid)
                    }
                }
            }
        }

        // A process missing from both discovery paths can still leave a visible
        // overlay. Treat its on-screen Chalkboard-owned window as a candidate
        // based on owner name, which is deliberately conservative.
        let names = Set(["aichalkboard", "AI Chalkboard", Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String]
            .compactMap { $0 }.map(normalizedOwnerName))
        if let infos = windowList {
            for info in infos {
                guard let rawName = info[kCGWindowOwnerName as String] as? String,
                      names.contains(normalizedOwnerName(rawName)),
                      let rawPID = info[kCGWindowOwnerPID as String] as? Int, rawPID > 0 else { continue }
                pids.insert(pid_t(rawPID))
            }
        } else {
            errors.append("WindowServer did not return an on-screen window list.")
        }

        let sorted = pids.sorted()
        let limit = 128
        return (Array(sorted.prefix(limit)), sorted.count > limit, errors)
    }

    private static func visibleWindows(ownedBy candidates: Set<pid_t>,
                                       in windowList: [[String: Any]]?) -> [(pid_t, Int)] {
        guard let infos = windowList else {
            // A missing list is unsafe. Use an impossible sentinel PID/window
            // so the caller produces quiescent=false without inventing a real
            // process identity.
            return [(-1, -1)]
        }
        return infos.compactMap { info in
            guard (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let rawPID = info[kCGWindowOwnerPID as String] as? Int,
                  candidates.contains(pid_t(rawPID)),
                  let number = info[kCGWindowNumber as String] as? Int else { return nil }
            return (pid_t(rawPID), number)
        }
    }

    private static func normalizedOwnerName(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func currentExecutableIdentity() -> (bundleIdentifier: String?, executablePath: String?) {
        let url: URL?
        if let bundle = Bundle.main.executableURL { url = bundle }
        else if let first = CommandLine.arguments.first {
            url = first.hasPrefix("/") ? URL(fileURLWithPath: first) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(first)
        } else { url = nil }
        return (Bundle.main.bundleIdentifier, normalizedPath(url))
    }

    private static func identitiesMatch(_ lhs: (bundleIdentifier: String?, executablePath: String?),
                                        _ rhs: (bundleIdentifier: String?, executablePath: String?)) -> Bool {
        if let left = lhs.executablePath, let right = rhs.executablePath, left == right { return true }
        if let left = lhs.bundleIdentifier, let right = rhs.bundleIdentifier,
           left.caseInsensitiveCompare(right) == .orderedSame { return true }
        return false
    }

    private static func normalizedPath(_ url: URL?) -> String? {
        url?.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func processUID(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return info.pbi_uid
    }
}

#elseif os(Windows)

/// WINDOWS QUIESCENCE EVIDENCE -- read this before trusting or relaxing
/// `quiescent` on this platform.
///
/// macOS's `observeQuiescence()` above reads `CGWindowListCopyWindowInfo`:
/// WindowServer -- the actual compositor process that owns final on-screen
/// presentation -- enumerating what IT is currently compositing. That is a
/// read of the compositor's own registration, about as close to ground
/// truth as a userspace API gets.
///
/// Windows has no single equivalent call. There is no "ask the DWM
/// compositor what it is presenting right now" API this shim can reach from
/// documented, stable Win32/DWM surfaces. What IS available, and what this
/// implementation uses, is two separate and complementary pieces of
/// evidence:
///
///   1. Win32/DWM WINDOW STATE: `IsWindowVisible` (a window's own visibility
///      flag) plus `DwmGetWindowAttribute(..., DWMWA_CLOAKED, ...)` (whether
///      DWM has cloaked it -- a window can be Win32-visible yet invisible on
///      screen, most commonly a suspended UWP app or a window parked on an
///      inactive virtual desktop; skipping cloaked windows avoids a false
///      "not quiescent", and a FAILED cloaked-attribute read is treated as
///      "assume visible", i.e. fails closed rather than assuming uncloaked).
///      This is bookkeeping Win32/DWM maintain ABOUT windows, not a read of
///      what the compositor has actually painted into the current frame.
///
///   2. `DwmFlush()`: blocks the calling thread until the DWM compositor has
///      produced (or is guaranteed to imminently produce) its next composed
///      frame. This proves a real compositor frame boundary was crossed
///      during the observation -- but it does NOT prove which windows were
///      included in that frame, only that the compositor is alive and did
///      real work while this sample was taken. Its failure (no DWM
///      composition active -- some remote-desktop configurations, or
///      composition forcibly disabled) is recorded as a discovery error and
///      forces `quiescent = false`, the same fail-closed treatment macOS
///      gives a missing WindowServer window list.
///
/// Combining "no candidate-owned window reports itself visible-and-uncloaked"
/// (sampled twice, 50ms apart, exactly like the macOS branch) with "a real
/// compositor frame boundary was observed to pass" is the closest honest
/// equivalent this file can build. It is NOT the same claim as macOS's: it
/// is possible, in principle, for Win32/DWM's tracked window state to
/// briefly disagree with what is actually composited on screen in a way a
/// direct compositor-registration read would not. Any `clickSafeAtObservation
/// : true` an MCP caller sees that was derived from this branch (see
/// `MCPToolHandlers+Suspension.swift`, unchanged and shared) means "no
/// evidence of an on-screen Chalkboard window survived two Win32/DWM state
/// samples plus a real compositor frame boundary" -- not "the compositor has
/// confirmed nothing is on screen", which is what the same field honestly
/// means on macOS. This distinction is recorded verbatim in this port's
/// contractChanges; do not quietly reuse the macOS wording anywhere this
/// value is surfaced.
public extension SuspensionLeaseCoordinator {
    /// Windows twin of the macOS branch's `observeQuiescence(timeout:)`:
    /// same two-samples-50ms-apart timing harness (kept textually parallel
    /// to the macOS version on purpose, so the two are easy to compare),
    /// different evidence underneath -- see the WINDOWS QUIESCENCE EVIDENCE
    /// comment above.
    func observeQuiescence(timeout: TimeInterval = 1.0) -> SuspensionQuiescenceObservation {
        let started = DispatchTime.now().uptimeNanoseconds
        let first = Self.sample()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        guard elapsed + 0.05 <= max(0, timeout) else {
            return Self.observation(first: first, second: first, sampleCount: 1)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let second = Self.sample()
        return Self.observation(first: first, second: second, sampleCount: 2)
    }

    private static let discoveryScope = "same-session Chalkboard executables discovered by Toolhelp32 process enumeration plus currently visible (IsWindowVisible, not DWM-cloaked) on-screen windows owned by those processes, corroborated by a DwmFlush()-observed compositor frame boundary -- Win32/DWM WINDOW STATE, not a read of the compositor's own presentation ledger; see this file's WINDOWS QUIESCENCE EVIDENCE comment above"

    private static let maximumEvidenceEntries = 128
    private typealias Sample = (pids: [Int32], truncated: Bool, errors: [String], visible: [(Int32, Int)], visibleTruncated: Bool)

    private static func sample() -> Sample {
        let discovery = discoverCandidateProcesses()
        let visible = visibleWindows(ownedBy: Set(discovery.pids))
        let visibleTruncated = visible.count > maximumEvidenceEntries

        var errors = discovery.errors
        // See WINDOWS QUIESCENCE EVIDENCE point 2 above: this is the second,
        // complementary half of this platform's evidence, not an incidental
        // side effect. A failure here means this sample has NO compositor-
        // frame-boundary evidence at all, so it is recorded as a discovery
        // error -- which the `quiescent` formula in `observation(...)` below
        // already treats as fail-closed, exactly like a missing WindowServer
        // window list does on macOS.
        let flushResult = DwmFlush()
        if flushResult != S_OK {
            errors.append("DwmFlush failed (HRESULT \(flushResult)); this sample has no compositor-frame-boundary evidence.")
        }

        return (discovery.pids, discovery.truncated, errors,
                Array(visible.prefix(maximumEvidenceEntries)), visibleTruncated)
    }

    private static func observation(first: Sample, second: Sample,
                                    sampleCount: Int) -> SuspensionQuiescenceObservation {
        let all = first.visible + second.visible
        let allCandidates = Array(Set(first.pids + second.pids)).sorted()
        let candidatesTruncated = first.truncated || second.truncated || allCandidates.count > maximumEvidenceEntries || first.visibleTruncated || second.visibleTruncated
        let candidates = Array(allCandidates.prefix(maximumEvidenceEntries))
        let errors = Array(Set(first.errors + second.errors)).sorted()
        return SuspensionQuiescenceObservation(
            quiescent: sampleCount == 2 && all.isEmpty && errors.isEmpty && !candidatesTruncated,
            candidatePIDs: candidates, candidatePIDsTruncated: candidatesTruncated,
            visibleOwnerPIDs: Array(Set(all.map(\.0))).sorted(),
            visibleWindowNumbers: Array(Set(all.map(\.1))).sorted(),
            discoveryErrors: errors, sampleCount: sampleCount, scope: discoveryScope
        )
    }

    /// Same-executable discovery, Windows twin of the macOS branch's libproc
    /// scan: this process itself, plus every OTHER same-session process
    /// (Toolhelp32 enumeration is already scoped to processes this account
    /// can inspect, and a foreign-session process's window/security
    /// boundary makes it unopenable for `QueryFullProcessImageNameW` in the
    /// ordinary case) whose full executable path matches this process's own.
    /// A process this account cannot open (a different user, an elevated
    /// process from a standard-integrity caller) is silently skipped, not
    /// treated as a match -- mirroring the macOS branch's libproc loop,
    /// which only inserts a PID on a confirmed UID+path match and otherwise
    /// just continues.
    private static func discoverCandidateProcesses() -> (pids: [Int32], truncated: Bool, errors: [String]) {
        var pids: Set<Int32> = [Int32(bitPattern: GetCurrentProcessId())]
        var errors: [String] = []

        guard let ownPath = currentExecutablePath() else {
            errors.append("Unable to determine this Chalkboard executable's path for cross-process quiescence discovery.")
            return (Array(pids), false, errors)
        }

        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0), snapshot != INVALID_HANDLE_VALUE else {
            errors.append("CreateToolhelp32Snapshot failed (Win32 error \(GetLastError())) while enumerating same-session processes for quiescence discovery.")
            return (Array(pids), false, errors)
        }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var hasNext = Process32FirstW(snapshot, &entry)
        var scanned = 0
        // A generous scan budget, not an expected limit: degrades to a
        // discoveryError (fail-closed via the `quiescent` formula) rather
        // than looping indefinitely against a pathological process table.
        let scanBudget = 8192
        while hasNext {
            scanned += 1
            guard scanned <= scanBudget else {
                errors.append("Process enumeration exceeded its scan budget while looking for same-executable Chalkboard processes; the candidate list may be incomplete.")
                break
            }
            if let path = processImagePath(pid: entry.th32ProcessID), path == ownPath {
                pids.insert(Int32(bitPattern: entry.th32ProcessID))
            }
            entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
            hasNext = Process32NextW(snapshot, &entry)
        }

        let sorted = pids.sorted()
        let limit = 128
        return (Array(sorted.prefix(limit)), sorted.count > limit, errors)
    }

    /// `candidates` is this sample's own discovered PID set (see
    /// `discoverCandidateProcesses()`); a window owned by a process outside
    /// it is not this app's concern. Returns `[(-1, -1)]` -- an impossible
    /// sentinel PID/window -- when `EnumWindows` itself fails, mirroring the
    /// macOS branch's identical fail-closed sentinel for a missing
    /// WindowServer window list: an enumeration failure is unsafe, not
    /// evidence of absence.
    private static func visibleWindows(ownedBy candidates: Set<Int32>) -> [(Int32, Int)] {
        final class EnumContext {
            let candidates: Set<Int32>
            var results: [(Int32, Int)] = []
            init(candidates: Set<Int32>) { self.candidates = candidates }
        }
        let context = EnumContext(candidates: candidates)
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        let lparam = LPARAM(bitPattern: UInt64(UInt(bitPattern: contextPointer)))

        let callback: WNDENUMPROC = { hwnd, callbackParam in
            guard let hwnd,
                  let raw = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(callbackParam))) else { return true }
            let context = Unmanaged<EnumContext>.fromOpaque(raw).takeUnretainedValue()

            var ownerPID: DWORD = 0
            _ = GetWindowThreadProcessId(hwnd, &ownerPID)
            let candidatePID = Int32(bitPattern: ownerPID)
            guard context.candidates.contains(candidatePID) else { return true }
            guard IsWindowVisible(hwnd) else { return true }

            var cloaked: DWORD = 0
            let attributeResult = DwmGetWindowAttribute(hwnd, DWORD(DWMWA_CLOAKED.rawValue), &cloaked, DWORD(MemoryLayout<DWORD>.size))
            // A failed attribute read fails closed as "assume visible" (i.e.
            // does NOT skip the window here) -- the opposite assumption
            // would let an unreadable cloak state silently manufacture
            // quiescence. See the WINDOWS QUIESCENCE EVIDENCE comment above.
            if attributeResult == S_OK && cloaked != 0 { return true }

            context.results.append((candidatePID, Int(bitPattern: UInt(bitPattern: hwnd))))
            return true
        }

        guard EnumWindows(callback, lparam) else {
            return [(-1, -1)]
        }
        return context.results
    }

    private static func processImagePath(pid: DWORD) -> String? {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(handle) }
        var buffer = [UInt16](repeating: 0, count: 1024)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(handle, 0, &buffer, &size) else { return nil }
        return normalizedPath(String(decoding: buffer[0..<Int(size)], as: UTF16.self))
    }

    private static func currentExecutablePath() -> String? {
        var buffer = [UInt16](repeating: 0, count: 1024)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0 else { return nil }
        return normalizedPath(String(decoding: buffer[0..<Int(length)], as: UTF16.self))
    }

    /// Windows paths are case-insensitive; a plain lowercase compare is
    /// enough here since both sides of every comparison this file makes come
    /// from the same API family (`GetModuleFileNameW`/
    /// `QueryFullProcessImageNameW`), unlike the macOS branch's
    /// `resolvingSymlinksInPath().standardizedFileURL`, which also resolves
    /// symlinks -- Windows reparse points are rare enough for an installed
    /// executable that this file does not chase them.
    private static func normalizedPath(_ raw: String) -> String {
        raw.lowercased()
    }
}

#endif
