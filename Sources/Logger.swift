import Foundation
// Foundation re-exports Darwin on Apple platforms, which is where open(2),
// flock(2), fstat(2)/stat(2), and close(2) come from below.
#if os(Windows)
// Windows has no POSIX layer for Foundation to re-export. The analogous
// file-identity, locking, and durability primitives used below
// (CreateFileW, LockFileEx/UnlockFileEx, GetFileInformationByHandle,
// GetFileAttributesExW, FlushFileBuffers, CloseHandle, GetLastError) come
// from the plain-C Win32 surface that WinSDK exposes directly.
import WinSDK
#endif

public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    #if os(macOS)
    private var fileHandle: FileHandle?
    #elseif os(Windows)
    // A raw Win32 HANDLE rather than Foundation's FileHandle: the identity
    // check in reopenIfRotatedAwayFromUnderUs() below must call
    // GetFileInformationByHandle on exactly the handle these writes go
    // through, and there is no supported way to recover the underlying
    // HANDLE from a FileHandle wrapper. NOTE: on this toolchain's WinSDK
    // overlay, `HANDLE` itself resolves to a plain non-optional
    // `UnsafeMutableRawPointer` (not already-optional, despite what an
    // earlier version of this comment claimed) -- so the property is
    // declared `HANDLE?` explicitly and stores nil to mean "no file
    // currently open", mirroring `FileHandle?` above -- there is no
    // separate "invalid" sentinel stored here (see openAppendHandle(at:),
    // which maps Win32's INVALID_HANDLE_VALUE to nil itself).
    private var fileHandle: HANDLE?
    #endif

    private let logFileURL: URL
    private let backupFileURL: URL
    private let lockFileURL: URL
    private let queue = DispatchQueue(label: "com.aichalkboard.logger", qos: .utility)
    private let dateFormatter: DateFormatter

    // Serializes each log line's format-timestamp + build-line +
    // write-to-stderr sequence (see log()/logSync()), plus every other
    // FileHandle.standardError.write below (all of which go through
    // Logger.writeStderr()).
    //
    // BUG FIX (interleaved stderr writes corrupt the diagnostic stream):
    // FileHandle.standardError.write is a raw write(2) with no serialization
    // of its own, and log()/logSync() are genuinely called concurrently from
    // multiple threads: AppDelegate/InstanceBroadcast log from the main
    // thread, MCPServer's read loop logs from a background global queue, and
    // the uncaught-exception handler in Launcher/main.swift calls logSync()
    // from its own thread. When stderr is a pipe (the normal case -- an MCP
    // host captures the child's stderr for diagnostics) and a line exceeds
    // PIPE_BUF (512 bytes on macOS), the kernel gives no atomicity guarantee
    // across concurrent writers, so two threads' writes can interleave
    // mid-line and corrupt the diagnostic stream. A long Swift debug
    // description of tool arguments easily exceeds 512 bytes. This lock
    // makes each line's stderr write atomic with respect to every other
    // line's. As a secondary, minor benefit it also serializes use of the
    // shared `dateFormatter` in log()/logSync(), though Foundation documents
    // DateFormatter as safe for concurrent formatting -- that is not why
    // this lock exists.
    //
    // Static rather than instance-scoped: it must also be reachable from the
    // `static` openAppendHandle(at:), which can run before `self` exists
    // (called from init()). Logger has exactly one instance (Logger.shared,
    // via a private init()), so a static lock is equivalent to an
    // instance-scoped one here.
    //
    // MUST be released before entering `queue.async`/`queue.sync`: logSync()
    // uses queue.sync, and holding this lock across that call while another
    // thread is blocked on this same lock waiting for its own turn on
    // `queue` would deadlock. Every acquisition of this lock spans a small,
    // synchronous block with no dispatch inside it -- see the call sites.
    private static let stderrLock = NSLock()

    // Rotates at 5 MB per file (roughly 10 MB total with one backup, plus at
    // most the bounded record that crosses the threshold).
    private let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024

    /// A single caller must not consume the whole retained history or make the
    /// synchronous stderr write arbitrarily large. The file cap controls total
    /// retention; this independent cap controls each message payload. The
    /// timestamp/PID/level framing adds a small fixed number of bytes.
    static let maxMessageBytes = 16 * 1024

    /// When an over-cap file cannot be rotated, stop appending to that file
    /// until a later rotation attempt succeeds. stderr logging continues. This
    /// keeps growth bounded near the nominal 10 MB retention budget even
    /// when rename/removal permissions are broken for an extended period.
    private var suppressFileWritesUntilRotationSucceeds = false

    // BUG FIX (failed rotation retried forever): tracks when a rotation
    // attempt last failed (e.g. permission denied, stale backup couldn't be
    // removed) so rotateIfNeeded() can back off instead of re-running the
    // failing rename + lock + handle-recycle dance on every single log()
    // call from every process sharing this file. Only ever read/written
    // from inside `queue` (see rotateIfNeeded/logSync), so no extra
    // synchronization is needed despite this class being Sendable.
    private var lastRotationFailure: Date?
    private let rotationFailureCooldown: TimeInterval = 60

    private init() {
        let fileManager = FileManager.default
        let logsDir = PlatformPaths.logDirectory

        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("ai_chalkboard.log")
        backupFileURL = logsDir.appendingPathComponent("ai_chalkboard.1.log")
        lockFileURL = logsDir.appendingPathComponent("ai_chalkboard.rotate.lock")

        dateFormatter = DateFormatter()
        // BUG FIX (timestamps vs. MCP host): this deliberately matches the MCP
        // host's own log timestamps, which are UTC (e.g. "17:47:02.468Z"). The
        // previous formatter only set `dateFormat`, so it defaulted to the
        // system's local time zone; the logger would print "13:47:02.558" for
        // the same instant the host printed "17:47:02.468Z" (a 4-hour offset in
        // this deployment), forcing manual math to correlate the two logs when
        // debugging. Forcing UTC (with a trailing "Z" in the format) means the
        // two logs can be read side by side with matching timestamps. Locale is
        // pinned to en_US_POSIX because a fixed-format DateFormatter must not be
        // allowed to vary its digit/format conventions with the user's locale.
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        fileHandle = Logger.openAppendHandle(at: logFileURL)

        log("==================================================")
        log("AI Chalkboard Logger Initialized (PID: \(ProcessInfo.processInfo.processIdentifier))")
        log("Log File: \(logFileURL.path)")
        log("Log Retention: rotates at 5 MB, keeps one backup, caps messages at 16 KiB, and pauses file writes if rotation fails")
        log("==================================================")
    }

    #if os(macOS)
    // Opens (creating if necessary) the log file with O_APPEND.
    //
    // BUG FIX (concurrent writers corrupt the log): Claude Desktop routinely
    // runs multiple instances of this MCP server process at the same time
    // (observed concurrently in production: two independent PID pairs all
    // writing to this same log file). The previous implementation opened the
    // file once via FileHandle(forWritingTo:) and called seekToEndOfFile() a
    // single time at init. Each process then tracked its own file offset
    // independently, so a later write from process B landed at B's
    // last-known offset and physically overwrote bytes process A had already
    // written (and vice versa) — real, observed corruption: an orphaned
    // fragment of one process's init banner (" Log Max Size Cap: 5 MB
    // (Auto-rotating)") landed mid-line inside another process's output, with
    // no timestamp/PID prefix of its own because it was a partial overwrite.
    // Opening with O_APPEND delegates "seek to end" to the kernel and makes it
    // part of the same atomic operation as the write (per POSIX, each
    // O_APPEND write atomically seeks to the current end-of-file first), so
    // concurrent writers from separate processes each append at the file's
    // true current end rather than at a stale, locally-cached offset.
    private static func openAppendHandle(at url: URL) -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd != -1 else {
            // A logging failure must never take down the MCP server. Report to
            // stderr only and continue with fileHandle == nil; log() already
            // writes to stderr unconditionally, so output isn't fully lost.
            let msg = "[Logger] Failed to open log file at \(url.path) (errno \(errno)). Logging to stderr only.\n"
            stderrLock.lock()
            Logger.writeStderr(msg)
            stderrLock.unlock()
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    #elseif os(Windows)
    // Opens (creating if necessary) the log file for atomic append.
    //
    // WINDOWS NOTE: this is the Windows analogue of the O_APPEND bug fix
    // documented on the macOS branch above (concurrent Claude Desktop
    // instances writing this same log file). Windows has no O_APPEND flag,
    // but the same "each write atomically seeks to EOF first" guarantee is
    // available by a different, documented route: opening the handle with
    // ONLY the FILE_APPEND_DATA right -- and deliberately withholding the
    // broader FILE_WRITE_DATA right -- makes the OS itself force every
    // WriteFile call on that handle to append at the file's current end,
    // ignoring whatever the handle's own file pointer says. This is
    // documented Win32 behavior, not an emulation layered on top of it.
    // FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE matches the
    // sharing this needs: sibling processes must still be able to open,
    // write to, and rename/delete this same path while we hold it open,
    // since rotateIfNeeded() below relies on being able to rename the live
    // file out from under any process (including this one) still holding a
    // handle to it.
    private static func openAppendHandle(at url: URL) -> HANDLE? {
        let rawHandle: HANDLE? = url.path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(
                widePath,
                DWORD(FILE_APPEND_DATA),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
            // A logging failure must never take down the MCP server. Report to
            // stderr only and continue with fileHandle == nil; log() already
            // writes to stderr unconditionally, so output isn't fully lost.
            let msg = "[Logger] Failed to open log file at \(url.path) (Win32 error \(GetLastError())). Logging to stderr only.\n"
            stderrLock.lock()
            Logger.writeStderr(msg)
            stderrLock.unlock()
            return nil
        }
        return handle
    }

    /// Best-effort analogue of `stat`/`fstat`'s (st_dev, st_ino) identity
    /// pair, used by reopenIfRotatedAwayFromUnderUs() below to detect that
    /// another process rotated the log file out from under this one.
    /// Microsoft documents the file-index portion of this as NOT guaranteed
    /// to stay constant over the life of a file on every filesystem (it can
    /// change after the file is closed and reopened on some filesystems,
    /// e.g. certain remote or FAT volumes) -- unlike a POSIX inode, which is
    /// a hard guarantee. That caveat only ever costs an unnecessary
    /// close-and-reopen against the same still-live path here (harmless);
    /// it never causes the opposite, unsafe outcome of concluding two
    /// different files are the same one and continuing to write to a
    /// detached handle.
    private static func fileInformation(ofOpenHandle handle: HANDLE) -> BY_HANDLE_FILE_INFORMATION? {
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        return info
    }

    /// Opens a short-lived, attributes-only handle purely to identify
    /// whatever file currently sits at `path` -- the Windows analogue of
    /// POSIX `stat(path)`, which needs no open file descriptor at all.
    /// `dwDesiredAccess: 0` requests no read/write rights (a documented
    /// Win32 idiom for a metadata-only handle), and the same sharing flags
    /// as openAppendHandle(at:) above mean this never contends with, or
    /// blocks, any writer -- including this same process's own append
    /// handle.
    private static func fileInformation(atPath path: String) -> BY_HANDLE_FILE_INFORMATION? {
        let rawHandle: HANDLE? = path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(
                widePath,
                0,
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let probeHandle = rawHandle, probeHandle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(probeHandle) }
        return fileInformation(ofOpenHandle: probeHandle)
    }
    #endif

    // Encodes `line` as UTF-8 and writes it to stderr, returning the encoded
    // bytes (whether or not the stderr write itself succeeded -- see the
    // write below). log()/logSync() reuse that returned Data for their
    // own (separate, async-queued) write to the log file instead of
    // re-encoding the same string a second time. Returns nil, writing
    // nothing, if UTF-8 encoding fails -- effectively impossible for a
    // native Swift String, but matches every call site's existing tolerance
    // for silently dropping a diagnostic line rather than crashing the MCP
    // server over a logging failure.
    //
    // Deliberately does NOT take stderrLock itself. log()/logSync() need the
    // lock to also cover the timestamp-format + line-build step that
    // precedes the write (see stderrLock's declaration), so the lock must be
    // acquired by the caller, before this runs -- NSLock is not reentrant,
    // so this method locking again internally would deadlock those callers.
    // Every call site in this file (including ones that ignore the return
    // value) takes stderrLock immediately around its call to this method, so
    // the "caller always locks" rule is applied uniformly rather than mixed
    // with locking inside the helper.
    @discardableResult
    private static func writeStderr(_ line: String) -> Data? {
        guard let data = line.data(using: .utf8) else { return nil }
        // Throwing `write(contentsOf:)`, never the legacy non-throwing
        // `write(_:)`, for exactly the reason spelled out on writeToFile
        // below: the legacy API raises an UNCATCHABLE Objective-C exception
        // on failure, and EPIPE here is routine rather than exotic -- the MCP
        // host closes our stderr pipe during teardown while SIGPIPE is
        // ignored (see the launcher), so a clean shutdown would abort the
        // process mid-log. Swallowing the error still returns `data`, so
        // log()/logSync() go on to write the line to the log file even when
        // stderr is dead.
        do {
            try FileHandle.standardError.write(contentsOf: data)
        } catch {
            // Nowhere left to report a stderr failure to, by definition.
        }
        return data
    }

    public func log(_ message: String, level: String = "INFO") {
        // stderrLock spans formatting the timestamp, building the line, and
        // writing it to stderr -- see the lock's declaration for why. It is
        // released before queue.async below; never hold it across a
        // dispatch onto `queue` (risk of deadlock against logSync's
        // queue.sync -- see the lock's declaration).
        //
        // NEVER write to stdout: this process is an MCP stdio server
        // speaking JSON-RPC over stdout, and any stray byte there would
        // corrupt the protocol stream. writeStderr() only ever touches
        // stderr.
        Logger.stderrLock.lock()
        let timestamp = dateFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [PID: \(pid)] [\(level)] \(Self.boundedMessage(message))\n"
        let data = Logger.writeStderr(line)
        Logger.stderrLock.unlock()
        guard let data = data else { return }

        // Write to log file asynchronously with size-cap rotation.
        queue.async { [weak self] in
            guard let self = self else { return }
            let currentSize = self.reopenIfRotatedAwayFromUnderUs()
            self.rotateIfNeeded(currentSize: currentSize)
            self.writeToFile(data)
        }
    }

    // Writes pre-encoded line data to the current file handle, degrading to
    // stderr-only on any failure rather than crashing the MCP server.
    private func writeToFile(_ data: Data) {
        guard !suppressFileWritesUntilRotationSucceeds,
              let handle = fileHandle else { return }
        #if os(macOS)
        // Using the throwing `write(contentsOf:)` API (not the legacy
        // non-throwing `write(_:)`) matters here: the legacy API can raise an
        // uncatchable Objective-C exception on failure (e.g. EPIPE), which
        // would terminate this process outright.
        do {
            try handle.write(contentsOf: data)
            // BUG FIX (fsync on every line is ~8x slower and unnecessary):
            // measured on this machine, 0.0028 ms/line without fsync vs
            // 0.0219 ms/line with it, on a hot path that runs for every MCP
            // protocol message. This is a diagnostic log, not a durability-
            // critical store: losing the last few OS-buffered lines on a
            // hard crash (kill -9, power loss, kernel panic) is acceptable,
            // and the file is opened O_APPEND so the write(2) itself still
            // reaches the OS immediately -- another process reading this
            // file (tail -f, another instance's inode self-heal stat/fstat
            // check) sees it right away with no fsync required. Do NOT add
            // synchronize() back here; it belongs only on genuinely rare,
            // high-value writes: the rotation banner (rotateIfNeeded) and
            // the synchronous FATAL path (logSync).
        } catch {
            let msg = "[Logger] File write failed: \(error). Logging to stderr only for this line.\n"
            // Safe to take stderrLock here: writeToFile() only ever runs
            // inside `queue` (from log()'s queue.async or logSync()'s
            // queue.sync), and nothing holds stderrLock while waiting on
            // `queue` (see the lock's declaration), so there is no path back
            // to a deadlock.
            Logger.stderrLock.lock()
            Logger.writeStderr(msg)
            Logger.stderrLock.unlock()
        }
        #elseif os(Windows)
        // WINDOWS NOTE: WriteFile reports failure through its BOOL return
        // value plus GetLastError(), not through a thrown/raised exception,
        // so there is no Objective-C-exception hazard here the way there is
        // with FileHandle's legacy write(_:) API on macOS (see that branch
        // above) -- checking `writeSucceeded` below is already complete
        // failure handling.
        //
        // Same non-fsync-per-line reasoning as the macOS branch above
        // applies here: this is a diagnostic log, not a durability-critical
        // store, and the handle is opened for atomic append (see
        // openAppendHandle(at:)) so the write itself still reaches the OS
        // immediately. FlushFileBuffers is reserved for the same rare,
        // high-value writes as macOS's synchronize() call: the rotation
        // banner below and the synchronous FATAL path in logSync().
        let writeSucceeded = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return true }
            var bytesWritten: DWORD = 0
            let ok = WriteFile(handle, base, DWORD(buffer.count), &bytesWritten, nil)
            return ok && bytesWritten == DWORD(buffer.count)
        }
        if !writeSucceeded {
            let msg = "[Logger] File write failed: Win32 error \(GetLastError()). Logging to stderr only for this line.\n"
            // Safe to take stderrLock here: writeToFile() only ever runs
            // inside `queue` (from log()'s queue.async or logSync()'s
            // queue.sync), and nothing holds stderrLock while waiting on
            // `queue` (see the lock's declaration), so there is no path back
            // to a deadlock.
            Logger.stderrLock.lock()
            Logger.writeStderr(msg)
            Logger.stderrLock.unlock()
        }
        #endif
    }

    // Detects that another process rotated the log out from under this one,
    // and self-heals by reopening against the path.
    //
    // Returns the live log path's size as observed by the stat this method
    // already had to perform, purely so the rotateIfNeeded() call that always
    // follows can reuse it instead of stat()ing the very same path a second
    // time on every single log line. Returns nil whenever that number would
    // be missing or stale -- no handle yet, either stat failed, or we just
    // reopened -- and rotateIfNeeded() then takes its own fresh measurement.
    #if os(macOS)
    // BUG FIX (rotation across processes silently misroutes logs): POSIX file
    // descriptors follow inodes, not paths. If process A rotates (renames the
    // current log to the backup name, then creates a fresh file at the
    // original path), process B's already-open descriptor still refers to the
    // renamed inode — B would keep appending into what is now the backup file
    // forever, and B's logs would silently vanish from the live log. We guard
    // against this on the same code path that runs before every write: fstat
    // our own descriptor and stat the current path, and if the inodes differ,
    // someone else rotated, so close and reopen against the path to land back
    // on the live file.
    @discardableResult
    private func reopenIfRotatedAwayFromUnderUs() -> UInt64? {
        guard let handle = fileHandle else {
            fileHandle = Logger.openAppendHandle(at: logFileURL)
            return nil
        }

        var handleStat = stat()
        var pathStat = stat()

        guard fstat(handle.fileDescriptor, &handleStat) == 0 else { return nil }
        guard stat(logFileURL.path, &pathStat) == 0 else {
            // Path momentarily missing (e.g. another process mid-rename);
            // leave the handle as-is and retry on the next log() call.
            return nil
        }

        if handleStat.st_ino != pathStat.st_ino {
            try? handle.close()
            fileHandle = Logger.openAppendHandle(at: logFileURL)
            // Another process is actively rotating this path right now, so
            // the size read a moment ago is exactly the kind of number that
            // goes stale between the stat and the reopen. Report nothing and
            // let rotateIfNeeded() measure the file we actually ended up on.
            return nil
        }

        return UInt64(max(pathStat.st_size, 0))
    }
    #elseif os(Windows)
    // WINDOWS NOTE (rotation across processes silently misroutes logs): the
    // same race macOS's comment above describes applies unchanged on
    // Windows -- Win32 handles, like POSIX descriptors, follow the
    // underlying file, not the path string used to open them. If process A
    // rotates (renames the current log to the backup name, then creates a
    // fresh file at the original path), process B's already-open handle
    // still refers to the renamed file — B would keep appending into what is
    // now the backup file forever. We guard against this on the same code
    // path that runs before every write: query the identity of our own open
    // handle and of whatever is currently at the path, and if they differ,
    // someone else rotated, so close and reopen against the path to land
    // back on the live file. See fileInformation(ofOpenHandle:)'s doc
    // comment above for the identity pair used and its one honest gap
    // versus the POSIX inode check.
    @discardableResult
    private func reopenIfRotatedAwayFromUnderUs() -> UInt64? {
        guard let handle = fileHandle else {
            fileHandle = Logger.openAppendHandle(at: logFileURL)
            return nil
        }

        guard let handleInfo = Logger.fileInformation(ofOpenHandle: handle) else { return nil }
        guard let pathInfo = Logger.fileInformation(atPath: logFileURL.path) else {
            // Path momentarily missing (e.g. another process mid-rename);
            // leave the handle as-is and retry on the next log() call.
            return nil
        }

        let sameFile =
            handleInfo.dwVolumeSerialNumber == pathInfo.dwVolumeSerialNumber &&
            handleInfo.nFileIndexHigh == pathInfo.nFileIndexHigh &&
            handleInfo.nFileIndexLow == pathInfo.nFileIndexLow

        guard sameFile else {
            CloseHandle(handle)
            fileHandle = Logger.openAppendHandle(at: logFileURL)
            // Another process is actively rotating this path right now, so
            // the size read a moment ago is exactly the kind of number that
            // goes stale between the stat and the reopen. Report nothing and
            // let rotateIfNeeded() measure the file we actually ended up on.
            return nil
        }

        return (UInt64(pathInfo.nFileSizeHigh) << 32) | UInt64(pathInfo.nFileSizeLow)
    }
    #endif

    // Rotates the log file when it exceeds maxFileSizeBytes.
    //
    // BUG FIX (rotation measures the wrong thing): the previous implementation
    // used `handle.offsetInFile` as a proxy for file size. That only ever
    // reflected bytes THIS process itself had written since opening its
    // handle, not the file's real size on disk — with multiple writer
    // processes it undercounts wildly and the 5 MB cap never actually
    // triggers. It's also meaningless now that O_APPEND is in play, since
    // offsetInFile no longer tracks a locally-seeked position the way it did
    // for seek-then-write. We instead stat the real path to get the true
    // on-disk size, which reflects every process's writes.
    //
    // BUG FIX (rotation race across processes): rotation is a rename +
    // recreate, which is not atomic across processes. Without coordination,
    // two processes could both observe "over cap" at once and both attempt to
    // rotate, racing each other's renames (e.g. one process's fresh file gets
    // immediately clobbered by the other's rotation, or a backup is lost). We
    // serialize rotation across processes with flock() on a dedicated lock
    // file, then re-check the size after acquiring the lock, since another
    // process may have already rotated while we were waiting for it.
    //
    // `currentSize` is the size reopenIfRotatedAwayFromUnderUs() already
    // measured on the caller's behalf (it stats this same path immediately
    // before every call to this method); nil means it had no trustworthy
    // number to hand over, so we stat the path ourselves.
    private func rotateIfNeeded(currentSize: UInt64?) {
        guard fileHandle != nil else { return }
        guard let currentSize = currentSize ?? Logger.fileSize(atPath: logFileURL.path) else {
            // If the live path cannot be measured, continuing to append would
            // make the retention limit unknowable. Keep stderr diagnostics and
            // retry the file path on a later record.
            suppressFileWritesUntilRotationSucceeds = true
            return
        }
        guard currentSize >= maxFileSizeBytes else {
            suppressFileWritesUntilRotationSucceeds = false
            return
        }

        // BUG FIX (permanent silent rotation failure spins forever): if a
        // previous attempt failed (e.g. the log directory lost write
        // permission, or a stale ai_chalkboard.1.log couldn't be removed),
        // retrying on *every single subsequent log() call*, from every
        // process sharing this file, would mean the failing rename, the
        // lock acquisition, and the handle close/reopen all run on the hot
        // path forever with nothing to show for it. Back off for a cooldown
        // window instead of hammering a condition that won't resolve itself
        // without outside intervention (e.g. a human fixing permissions).
        if let lastFailure = lastRotationFailure,
           Date().timeIntervalSince(lastFailure) < rotationFailureCooldown {
            suppressFileWritesUntilRotationSucceeds = true
            return
        }

        #if os(macOS)
        let lockFd = open(lockFileURL.path, O_WRONLY | O_CREAT, 0o644)
        guard lockFd != -1 else {
            // Can't coordinate rotation right now; skip rotating this round
            // rather than risk racing another process. We'll reassess on the
            // next log() call.
            suppressFileWritesUntilRotationSucceeds = true
            return
        }
        defer { close(lockFd) }

        // BUG FIX (blocking flock stalls the whole serial queue forever): a
        // plain LOCK_EX blocks the calling thread until the lock holder
        // releases it. If the holder is suspended mid-rotation (SIGSTOP, a
        // paused debugger, a frozen VM), this call never returns. log()
        // itself doesn't block the caller (it writes stderr synchronously
        // then queue.async's the file write), but `queue` is serial, so
        // every subsequent log() from this process piles up behind this one
        // stuck closure -- unbounded memory growth and on-disk logging
        // silently stops. LOCK_NB makes the attempt non-blocking: on
        // EWOULDBLOCK, another process is already rotating, so just skip
        // this round (mirrors the "can't coordinate right now, skip this
        // round" behavior above for the open() failure case). Either that
        // process finishes rotating -- and our next call picks up the fresh
        // file via the inode self-heal -- or it eventually releases the
        // lock and a later line retries successfully.
        guard flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
            suppressFileWritesUntilRotationSucceeds = true
            return
        }
        defer { flock(lockFd, LOCK_UN) }
        #elseif os(Windows)
        // WINDOWS NOTE: LockFileEx is the Win32 analogue of flock() used
        // above -- it locks a byte range of an open handle rather than the
        // whole file at once, so the entire practically-unbounded range
        // [0, UInt32.max] is locked here to get the same whole-file
        // advisory-lock effect flock() gives on macOS. LOCKFILE_FAIL_IMMEDIATELY
        // is the non-blocking counterpart to LOCK_NB, for the exact same
        // reason given on the macOS branch above: a blocking wait here would
        // stall this process's single serial `queue` forever if the lock
        // holder is stuck (a suspended process, a paused debugger). On
        // failure, another process is already rotating, so this round is
        // skipped and a later log() call reassesses -- either that process
        // finishes rotating (and our next call picks up the fresh file via
        // the identity self-heal above) or it eventually releases the lock
        // and a later line retries successfully.
        let lockHandle: HANDLE? = lockFileURL.path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(
                widePath,
                DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let lockHandle = lockHandle, lockHandle != INVALID_HANDLE_VALUE else {
            // Can't coordinate rotation right now; skip rotating this round
            // rather than risk racing another process. We'll reassess on the
            // next log() call.
            suppressFileWritesUntilRotationSucceeds = true
            return
        }
        defer { CloseHandle(lockHandle) }

        var lockOverlapped = OVERLAPPED()
        guard LockFileEx(
            lockHandle,
            DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY),
            0,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            &lockOverlapped
        ) else {
            suppressFileWritesUntilRotationSucceeds = true
            return
        }
        defer { UnlockFileEx(lockHandle, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &lockOverlapped) }
        #endif

        // Re-check under the lock: another process may have already rotated
        // while we were waiting to acquire it. This MUST be a fresh stat and
        // must never reuse `currentSize` -- that number was measured before
        // the lock was held, which is precisely the window this re-check
        // exists to close.
        guard let sizeAfterLock = Logger.fileSize(atPath: logFileURL.path),
              sizeAfterLock >= maxFileSizeBytes else {
            // Someone else already rotated (or the file otherwise shrank);
            // make sure our handle still points at the live file and bail.
            reopenIfRotatedAwayFromUnderUs()
            suppressFileWritesUntilRotationSucceeds = false
            return
        }

        // BUG FIX (failed rename made rotation a permanent silent no-op):
        // the previous code used `try?` for both removeItem and moveItem,
        // discarding any error, and then *unconditionally* closed/reopened
        // the handle and appended a "Log file rotated" banner regardless of
        // whether the move actually happened. If the move fails (directory
        // lost write permission, a stale backup exists and can't be
        // removed, moveItem refuses to overwrite an existing destination,
        // etc.) the oversized file was left untouched on disk, yet every
        // process would still print a FALSE "rotated" banner and keep
        // pointlessly recycling its handle -- on every single log line,
        // forever -- while the file grew without bound, with no visible
        // error. We now check each step explicitly and only perform the
        // handle swap / banner write if the move genuinely succeeded.
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: backupFileURL.path) {
                try fm.removeItem(at: backupFileURL)
            }
            try fm.moveItem(at: logFileURL, to: backupFileURL)
        } catch {
            lastRotationFailure = Date()
            suppressFileWritesUntilRotationSucceeds = true
            // Report directly to stderr, never via log(): we're running
            // inside `queue` right now, and log() would queue.async back
            // onto this same serial queue -- at best a pointless bounce,
            // and the established rule in this file is that error paths
            // inside the queue always write to stderr directly. Taking
            // stderrLock here is still safe -- we're inside `queue`, and
            // nothing holds stderrLock while waiting on `queue` (see the
            // lock's declaration) -- it just makes this write atomic with
            // respect to every other line going to stderr.
            let msg = "[Logger] Rotation failed, leaving oversized log file in place; will retry in \(Int(rotationFailureCooldown))s. Path: \(logFileURL.path) Error: \(error)\n"
            Logger.stderrLock.lock()
            Logger.writeStderr(msg)
            Logger.stderrLock.unlock()
            // The handle remains available for a later retry, but routine file
            // writes are suppressed meanwhile so this oversized file cannot
            // grow without bound. stderr remains live for every log record.
            return
        }

        #if os(macOS)
        // Close the handle on the now-renamed (backup) inode and reopen
        // against the path, which recreates the fresh file via O_CREAT. This
        // is the same self-heal used by reopenIfRotatedAwayFromUnderUs(), run
        // here directly since we're the process that performed the rotation.
        try? fileHandle?.close()
        #elseif os(Windows)
        // Close the handle on the now-renamed (backup) file and reopen
        // against the path, which recreates the fresh file via OPEN_ALWAYS
        // (see openAppendHandle(at:) above). This is the same self-heal used
        // by reopenIfRotatedAwayFromUnderUs(), run here directly since we're
        // the process that performed the rotation.
        if let handle = fileHandle {
            CloseHandle(handle)
        }
        #endif
        fileHandle = Logger.openAppendHandle(at: logFileURL)
        lastRotationFailure = nil
        suppressFileWritesUntilRotationSucceeds = false

        if let newHandle = fileHandle {
            let rotationMsg = "[\(dateFormatter.string(from: Date()))] [PID: \(ProcessInfo.processInfo.processIdentifier)] [INFO] Log file rotated: 5 MB limit reached. Oldest logs moved to ai_chalkboard.1.log\n"
            if let msgData = rotationMsg.data(using: .utf8) {
                #if os(macOS)
                try? newHandle.write(contentsOf: msgData)
                // Unlike routine per-line writes (see writeToFile), a
                // rotation is a rare, significant event worth the fsync
                // cost to make sure the banner marking the new file's start
                // is durable.
                try? newHandle.synchronize()
                #elseif os(Windows)
                _ = msgData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
                    guard let base = buffer.baseAddress, !buffer.isEmpty else { return true }
                    var bytesWritten: DWORD = 0
                    return WriteFile(newHandle, base, DWORD(buffer.count), &bytesWritten, nil)
                }
                // Same reasoning as the macOS branch above: unlike routine
                // per-line writes (see writeToFile), a rotation is a rare,
                // significant event worth the extra FlushFileBuffers cost to
                // make sure the banner marking the new file's start is
                // durable.
                FlushFileBuffers(newHandle)
                #endif
            }
        }
    }

    // Synchronously logs `message` to stderr and to the log file, bypassing
    // the normal `queue.async` path, then fsyncs. Intended for the rare
    // call sites where the process may terminate (abort(), a re-raised
    // signal, etc.) before an async closure enqueued by log() would ever
    // get a chance to run -- e.g. NSSetUncaughtExceptionHandler in
    // the launcher entry point, whose handler runs immediately before the runtime calls
    // abort(). Without this, the one log line explaining a crash could be
    // lost from the file (it would still reach stderr, since that part of
    // log()'s formatting is already synchronous).
    //
    // MUST NOT be called from a closure already running on `queue` (i.e.
    // from within rotateIfNeeded/writeToFile/reopenIfRotatedAwayFromUnderUs,
    // or a closure passed to queue.async by log()) -- queue.sync from
    // inside the queue it targets deadlocks. All current call sites (the
    // uncaught-exception handler) run on their own thread outside the
    // logger's queue, so this is safe.
    public func logSync(_ message: String, level: String = "FATAL") {
        // Same stderrLock discipline as log(): span format-timestamp +
        // build-line + write-to-stderr, then release the lock before
        // entering queue.sync below. Holding it across queue.sync would
        // deadlock against any other thread blocked on stderrLock while
        // waiting for its own turn on `queue` -- see the lock's declaration.
        Logger.stderrLock.lock()
        let timestamp = dateFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [PID: \(pid)] [\(level)] \(Self.boundedMessage(message))\n"
        let data = Logger.writeStderr(line)
        Logger.stderrLock.unlock()
        guard let data = data else { return }

        queue.sync { [weak self] in
            guard let self = self else { return }
            let currentSize = self.reopenIfRotatedAwayFromUnderUs()
            self.rotateIfNeeded(currentSize: currentSize)
            self.writeToFile(data)
            // Durability matters here specifically: the process is about to
            // abort()/exit and this may be the only record of why. This is
            // the other genuinely-rare, high-value write alongside the
            // rotation banner that justifies paying for fsync.
            #if os(macOS)
            try? self.fileHandle?.synchronize()
            #elseif os(Windows)
            if let handle = self.fileHandle {
                FlushFileBuffers(handle)
            }
            #endif
        }
    }

    #if os(macOS)
    private static func fileSize(atPath path: String) -> UInt64? {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        return UInt64(s.st_size)
    }
    #elseif os(Windows)
    // Windows analogue of stat()'s size read: GetFileAttributesExW needs no
    // open handle at all, matching stat()'s zero-handle simplicity (unlike
    // fileInformation(atPath:) above, which genuinely needs a handle to read
    // GetFileInformationByHandle's volume/index identity fields).
    private static func fileSize(atPath path: String) -> UInt64? {
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        let ok = path.withCString(encodedAs: UTF16.self) { widePath in
            GetFileAttributesExW(widePath, GetFileExInfoStandard, &data)
        }
        guard ok else { return nil }
        return (UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow)
    }
    #endif

    /// Returns a valid-Unicode diagnostic message within `maxMessageBytes`.
    /// Internal so the byte-boundary behavior can be tested without opening a
    /// real log file in the user's Library directory.
    static func boundedMessage(_ message: String) -> String {
        guard message.utf8.count > maxMessageBytes else { return message }
        let suffix = "... <truncated to \(maxMessageBytes) bytes>"
        let prefixBudget = max(0, maxMessageBytes - suffix.utf8.count)
        var used = 0
        var end = message.startIndex
        while end < message.endIndex {
            let next = message.index(after: end)
            let count = message[end..<next].utf8.count
            guard used + count <= prefixBudget else { break }
            used += count
            end = next
        }
        return String(message[..<end]) + suffix
    }
}
