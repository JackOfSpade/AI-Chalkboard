import Darwin
import Foundation

/// The two ways `BoundedLocalFile.read` can fail, prior to a call site
/// translating the failure into its own domain error.
///
/// Kept intentionally narrow: every failure this file can produce collapses
/// into exactly one of these two cases. Callers are expected to catch this
/// type and rethrow their own error so no MCP-facing error string depends on
/// a type defined here.
enum BoundedLocalFileError: Error, Equatable {
    /// `path` was not absolute (no leading "/"), or did not resolve to a
    /// file URL after standardizing and resolving symlinks.
    case invalidPath
    /// The path could not be opened, is not a regular file, exceeds
    /// `maxBytes`, or grew past `maxBytes` between `fstat` and the read.
    case unreadable
}

/// Reads a local file the way every MCP-facing raster/screenshot input in
/// this app needs to: reject anything that is not an absolute path to an
/// on-disk regular file, and never buffer more than a caller-supplied byte
/// budget -- even if the file grows after being checked.
///
/// WHY THIS EXISTS: `RasterAssetStore` and `AnnotationVerificationCompositor`
/// each grew their own copy of this exact validate-path / open / fstat / read
/// sequence. The duplication was risky, not just repetitive: the
/// grew-after-`fstat` guard below is a deliberate TOCTOU defense, and it is
/// exactly the kind of line that quietly goes missing when someone
/// copy-pastes a "quick" second implementation.
///
/// This type deliberately never retains or returns the path it was given --
/// callers pass a path in, get `Data` out, and nothing here remembers or
/// exposes where the bytes came from.
enum BoundedLocalFile {
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
}
