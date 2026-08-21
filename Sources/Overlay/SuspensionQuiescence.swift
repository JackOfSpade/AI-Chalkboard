import Foundation
import AppKit
import CoreGraphics
import Darwin

/// Conservative WindowServer evidence used after a lease acquisition.  It is
/// intentionally a snapshot, not a promise: another process can create a
/// window immediately afterward and only a click dispatcher that participates
/// in this protocol can close that remaining race.
public struct SuspensionQuiescenceObservation: Equatable {
    public let quiescent: Bool
    public let candidatePIDs: [pid_t]
    public let candidatePIDsTruncated: Bool
    public let visibleOwnerPIDs: [pid_t]
    public let visibleWindowNumbers: [Int]
    public let discoveryErrors: [String]
    public let sampleCount: Int
    public let scope: String
}

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
