import Foundation

/// Accepts arbitrary `Data` chunks read from a byte stream (stdin, in
/// production) and reassembles them into complete newline-terminated
/// JSON-RPC messages.
///
/// Deliberately dependency-free: no `FileHandle`, no AppKit, nothing that
/// requires a GUI session or a real stdin descriptor to exercise. Pulled out
/// of `MCPServer.readLoop()` (which used to do this inline against
/// `FileHandle.standardInput.availableData`) specifically so a unit test can
/// feed it arbitrary byte chunks -- a message split mid-line, several
/// messages arriving in one chunk, CRLF vs bare LF senders, an unterminated
/// flood -- with no process spawning and no real stdio required.
struct LineFramer {

    /// Hard cap on each inbound JSON-RPC line and on the unterminated tail
    /// while a line is still being assembled, in bytes.
    ///
    /// WHY THIS EXISTS: `feed` only ever shrinks the buffer when it finds a
    /// newline; a peer that never sends one -- a bug on the other end, or
    /// something other than line-delimited JSON-RPC writing to this stdin --
    /// would otherwise grow `buffer` without bound for the lifetime of this
    /// long-running process. 4 MB is far above any legitimate single
    /// JSON-RPC message this server accepts (the largest realistic payload is
    /// a `draw_path` call, whose SVG string has its own lower character cap),
    /// so hitting this cap means the peer is not framing messages
    /// correctly -- a protocol violation, not a slow day -- and
    /// `MCPServer.readLoop()` treats it as a fatal transport error rather
    /// than continuing to grow the buffer.
    static let maxBufferBytes = 4 * 1024 * 1024

    /// The result of feeding one chunk: zero or more complete lines (newline
    /// stripped, and a trailing `\r` stripped for CRLF senders -- matching
    /// the original inline implementation this replaced), plus whether a
    /// complete line or still-unterminated remainder exceeded
    /// `maxBufferBytes`.
    struct FeedResult {
        let lines: [Data]
        let overflow: Bool
    }

    private var buffer = Data()
    /// An oversized request is a terminal protocol violation for this input
    /// stream.  `MCPServer` tears the connection down immediately, but latching
    /// the state here keeps the boundary safe if a future caller accidentally
    /// continues feeding after receiving `overflow: true`.
    private var overflowed = false

    /// Appends `data` to the internal buffer and extracts every complete
    /// line now available. Empty lines (e.g. a bare "\n" keep-alive) are
    /// silently dropped. Once an overflow is reported, all later calls report
    /// the same terminal condition and never yield a line.
    mutating func feed(_ data: Data) -> FeedResult {
        guard !overflowed else {
            return FeedResult(lines: [], overflow: true)
        }
        buffer.append(data)

        var lines: [Data] = []
        // Indices are taken RELATIVE TO `buffer.startIndex` rather than assumed
        // to be 0-based. A `Data` built only by `append`/`removeSubrange` does
        // in fact keep `startIndex == 0` today (measured), but that is an
        // implementation detail of Foundation, not a documented guarantee --
        // `Data` slices are free to carry a non-zero `startIndex`, and the
        // previous `0..<newlineIndex` form would silently read the wrong bytes
        // (or trap) if that ever changed. Anchoring to `startIndex` makes the
        // framing correct by construction instead of by observation.
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            // Checking only the remaining tail after this loop would let one
            // complete 20 MB line bypass the intended 4 MB request limit: it
            // has already been removed from `buffer` by then. Do not hand any
            // same-chunk lines to the server when one is oversized, so a
            // preceding destructive request cannot be processed before the
            // fatal protocol violation is noticed.
            guard lineData.count <= Self.maxBufferBytes else {
                return terminalOverflow()
            }

            if lineData.last == UInt8(ascii: "\r") {
                lineData.removeLast()
            }

            if lineData.isEmpty { continue }
            lines.append(lineData)
        }

        // Treat an oversized unterminated remainder exactly like an oversized
        // complete line above: do not let a valid-looking request that arrived
        // earlier in the same read chunk reach the dispatcher before the
        // fatal framing violation is observed. Without this branch,
        // `{"method":"tools/call", ...}\n` followed by more than 4 MiB
        // without a newline would execute the tool call and only then tear the
        // transport down. That is surprising at best and unsafe for a chunk
        // containing a destructive tool call.
        guard buffer.count <= Self.maxBufferBytes else {
            return terminalOverflow()
        }
        return FeedResult(lines: lines, overflow: false)
    }

    /// Transitions into the one-way overflow state and releases any retained
    /// request bytes.  Keeping this in one helper ensures every overflow path
    /// has identical, terminal behavior.
    private mutating func terminalOverflow() -> FeedResult {
        overflowed = true
        buffer.removeAll(keepingCapacity: false)
        return FeedResult(lines: [], overflow: true)
    }
}
