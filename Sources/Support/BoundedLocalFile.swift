import Foundation
#if os(macOS)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

/// The two ways `BoundedLocalFile.read` can fail, prior to a call site
/// translating the failure into its own domain error.
///
/// Kept intentionally narrow: every failure this file can produce collapses
/// into exactly one of these two cases. Callers are expected to catch this
/// type and rethrow their own error so no MCP-facing error string depends on
/// a type defined here.
enum BoundedLocalFileError: Error, Equatable {
    /// `path` was not absolute for the current platform (see each
    /// `BoundedLocalFile.read(path:maxBytes:)` overload's doc comment for
    /// exactly what that means there), or did not resolve to a file URL
    /// after standardizing and resolving symlinks/reparse points.
    case invalidPath
    /// The path could not be opened, is not a regular file, exceeds
    /// `maxBytes`, or grew past `maxBytes` between the initial size check
    /// and the read.
    case unreadable
}

/// Reads a local file the way every MCP-facing raster/screenshot input in
/// this app needs to: reject anything that is not an absolute path to an
/// on-disk regular file, and never buffer more than a caller-supplied byte
/// budget -- even if the file grows after being checked.
///
/// WHY THIS EXISTS: `RasterAssetStore` and `AnnotationVerificationCompositor`
/// each grew their own copy of this exact validate-path / open / size-check /
/// read sequence. The duplication was risky, not just repetitive: the
/// grew-after-check guard below is a deliberate TOCTOU defense, and it is
/// exactly the kind of line that quietly goes missing when someone
/// copy-pastes a "quick" second implementation.
///
/// This type deliberately never retains or returns the path it was given --
/// callers pass a path in, get `Data` out, and nothing here remembers or
/// exposes where the bytes came from.
enum BoundedLocalFile {
    #if os(macOS)
    /// - Parameters:
    ///   - path: Must be an absolute path (leading "/"). Standardized and
    ///     symlink-resolved before it is ever opened.
    ///   - maxBytes: Hard cap on both the file's declared size and the
    ///     number of bytes actually read.
    static func read(path: String, maxBytes: UInt64) throws -> Data {
        guard path.hasPrefix("/") else { throw BoundedLocalFileError.invalidPath }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL else { throw BoundedLocalFileError.invalidPath }

        // BUG FIX (a FIFO path wedges the MCP read loop forever): the previous
        // implementation opened via `FileHandle(forReadingFrom:)` and only
        // THEN fstat'd for S_IFREG. Opening a FIFO for reading blocks in
        // open(2) until a writer appears, so the S_IFREG guard below never
        // got a chance to reject it -- and because the MCP server has a single
        // serial read loop, a `draw_image` / `verify_annotation` pointing at a
        // FIFO hung the whole process for its remaining life. O_NONBLOCK makes
        // the open return immediately for a FIFO with no writer (and is a
        // no-op for the regular files this type actually accepts), so the
        // S_IFREG guard gets to do its job. O_CLOEXEC keeps the descriptor out
        // of any child process this app spawns.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd != -1 else { throw BoundedLocalFileError.unreadable }
        // closeOnDealloc: false because the defer below owns the close.
        // Letting FileHandle own it too would close the same descriptor
        // twice -- and a number that has been handed back to the kernel can
        // by then name a completely unrelated open file.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }

        // fstat the descriptor already opened above, not the pathname again
        // -- validating one path and then letting a later step reopen a
        // possibly different file at the same name is its own TOCTOU bug.
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              UInt64(status.st_size) <= maxBytes,
              maxBytes <= UInt64(Int.max) else {
            throw BoundedLocalFileError.unreadable
        }

        do {
            let data = try handle.read(upToCount: Int(maxBytes)) ?? Data()
            // A file can grow after fstat. Probe one further byte rather
            // than trusting metadata or allocating an unbounded Data buffer.
            let trailingByte = try handle.read(upToCount: 1) ?? Data()
            guard trailingByte.isEmpty else { throw BoundedLocalFileError.unreadable }
            return data
        } catch let error as BoundedLocalFileError {
            throw error
        } catch {
            throw BoundedLocalFileError.unreadable
        }
    }
    #elseif os(Windows)
    /// - Parameters:
    ///   - path: Must be an absolute Windows path (a drive-letter path such
    ///     as `C:\...` / `C:/...`, or a UNC path such as
    ///     `\\server\share\...`). Standardized and symlink/reparse-point-
    ///     resolved before it is ever opened.
    ///   - maxBytes: Hard cap on both the file's declared size and the
    ///     number of bytes actually read.
    ///
    /// WINDOWS NOTE: the macOS branch's O_NONBLOCK bug fix exists because
    /// open(2) on a Unix FIFO with no writer blocks until one appears, which
    /// would wedge the MCP server's single serial read loop forever. Windows
    /// has no ordinary-path equivalent of a FIFO -- named pipes live in the
    /// separate `\\.\pipe\` namespace and are never reached by an arbitrary
    /// caller-supplied filesystem path -- so `CreateFileW` on a real disk
    /// path cannot block the way `open()` on a FIFO can. What Windows DOES
    /// have is device-namespace names (`NUL`, `CON`, `COM1`, ...) and reparse
    /// points that can be aimed at a device or a directory junction; both are
    /// rejected below the same way the macOS branch rejects anything that is
    /// not `S_IFREG`: this opens with `FILE_FLAG_OPEN_REPARSE_POINT` (so a
    /// reparse point is opened as itself rather than silently followed --
    /// the Windows analogue of O_NOFOLLOW) and then requires
    /// `GetFileInformationByHandle` to report neither
    /// `FILE_ATTRIBUTE_REPARSE_POINT` nor `FILE_ATTRIBUTE_DIRECTORY`, and
    /// `GetFileType` to report `FILE_TYPE_DISK` -- the Windows analogue of
    /// the `S_IFREG` check.
    static func read(path: String, maxBytes: UInt64) throws -> Data {
        guard isAbsoluteWindowsPath(path) else { throw BoundedLocalFileError.invalidPath }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL else { throw BoundedLocalFileError.invalidPath }

        let handle: HANDLE = url.path.withCString(encodedAs: UTF16.self) { widePath in
            CreateFileW(
                widePath,
                DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        guard handle != INVALID_HANDLE_VALUE else {
            throw BoundedLocalFileError.unreadable
        }
        defer { CloseHandle(handle) }

        // The Windows analogue of fstat()-ing the descriptor already opened
        // above, not the pathname again -- validating one path and then
        // letting a later step reopen a possibly different file at the same
        // name is its own TOCTOU bug.
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info),
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
              GetFileType(handle) == DWORD(FILE_TYPE_DISK) else {
            throw BoundedLocalFileError.unreadable
        }

        var size = LARGE_INTEGER()
        guard GetFileSizeEx(handle, &size) else { throw BoundedLocalFileError.unreadable }
        guard size.QuadPart >= 0,
              UInt64(bitPattern: size.QuadPart) <= maxBytes,
              maxBytes <= UInt64(Int.max) else {
            throw BoundedLocalFileError.unreadable
        }

        let data = try readUpTo(handle: handle, limit: Int(maxBytes))
        // A file can grow after the size check above. Probe one further
        // byte rather than trusting metadata or allocating an unbounded
        // buffer.
        let trailingByte = try readUpTo(handle: handle, limit: 1)
        guard trailingByte.isEmpty else { throw BoundedLocalFileError.unreadable }
        return data
    }

    /// Reads up to `limit` bytes from `handle` via `ReadFile`, stopping
    /// early at end-of-file exactly like Foundation's
    /// `FileHandle.read(upToCount:)` does on the macOS branch -- returning
    /// fewer bytes than `limit` is success, not an error; only a genuine
    /// `ReadFile` failure throws. Reads in bounded chunks rather than
    /// preallocating a `limit`-sized buffer up front, since `limit` here can
    /// be `maxBytes` (an external, caller-supplied budget) while the file
    /// itself may be far smaller.
    private static func readUpTo(handle: HANDLE, limit: Int) throws -> Data {
        guard limit > 0 else { return Data() }
        let chunkSize = min(limit, 1 << 16)
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var result = Data()
        while result.count < limit {
            let toRead = min(chunkSize, limit - result.count)
            var bytesRead: DWORD = 0
            let ok = chunk.withUnsafeMutableBytes { rawBuffer -> Bool in
                ReadFile(handle, rawBuffer.baseAddress, DWORD(toRead), &bytesRead, nil)
            }
            guard ok else { throw BoundedLocalFileError.unreadable }
            guard bytesRead > 0 else { break }
            result.append(chunk, count: Int(bytesRead))
        }
        return result
    }

    /// Windows equivalent of the macOS branch's `path.hasPrefix("/")` check:
    /// is `path` an absolute Windows path (a drive-letter path such as
    /// `C:\...` / `C:/...`, or a UNC path such as `\\server\share\...`)?
    private static func isAbsoluteWindowsPath(_ path: String) -> Bool {
        if path.hasPrefix("\\\\") { return true }
        let bytes = Array(path.utf8)
        guard bytes.count >= 3 else { return false }
        let drive = bytes[0]
        let isLetter = (drive >= UInt8(ascii: "A") && drive <= UInt8(ascii: "Z"))
            || (drive >= UInt8(ascii: "a") && drive <= UInt8(ascii: "z"))
        return isLetter
            && bytes[1] == UInt8(ascii: ":")
            && (bytes[2] == UInt8(ascii: "\\") || bytes[2] == UInt8(ascii: "/"))
    }
    #endif
}
