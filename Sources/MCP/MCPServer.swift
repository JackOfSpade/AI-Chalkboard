import Foundation
import AppKit

/// Validates the portion of a JSON-RPC request that is specific to MCP tool
/// calls before any tool handler receives it. Keeping this pure makes the
/// destructive-input boundary independently testable without writing to the
/// server's real stdout singleton.
enum MCPProtocolValidation {
    static func toolCallParameters(_ rawParams: Any?) -> DrawOutcome<[String: Any]> {
        guard let params = rawParams as? [String: Any] else {
            return .failure("tools/call params must be an object.")
        }
        if let arguments = params["arguments"], !(arguments is [String: Any]) {
            return .failure("tools/call arguments must be an object when supplied.")
        }
        return .success(params)
    }
}

/// The final authority for outbound MCP response size. Tool-specific guards
/// (notably verification PNG budgeting and list pagination) make normal
/// results comfortably smaller, but every response still funnels through this
/// serializer so metadata or a future tool cannot accidentally write an
/// unbounded JSON-RPC line.
enum MCPResponseTransport {
    static let responseTooLargeMessage = "Error: The requested result exceeds AI Chalkboard's 8 MiB MCP response limit. Reduce the requested page/crop and retry."

    static func serializedLine(_ response: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return nil
        }
        // Include the newline framing byte in the declared response limit.
        guard body.count < DrawingDefaults.maxMCPResponseBytes else { return nil }
        var line = body
        line.append(0x0A)
        return line.count <= DrawingDefaults.maxMCPResponseBytes ? line : nil
    }

    /// Deliberately does not call back into `sendResponse`: an oversized
    /// result must not recurse through the same failure path. Request IDs are
    /// bounded by the inbound line cap; a null-ID fallback covers the
    /// theoretical case that even echoing the id cannot fit.
    static func compactOversizeErrorLine(id: Any?) -> Data? {
        func response(id: Any) -> [String: Any] {
            [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "content": [["type": "text", "text": responseTooLargeMessage]],
                    "isError": true
                ]
            ]
        }
        return serializedLine(response(id: id ?? NSNull()))
            ?? serializedLine(response(id: NSNull()))
    }
}

/// The stdio MCP server: owns the read loop, JSON-RPC method routing, and the
/// three response-writing primitives every handler funnels through.
///
/// The bulk of what used to live in this one 947-line file has moved out by
/// topic:
///   * `LineFramer.swift`       -- pure newline-framing of stdin bytes.
///   * `MCPToolCatalog.swift`   -- the static `tools/list` schema payload.
///   * `MCPToolHandlers.swift`  -- `tools/call` dispatch and every tool body.
///   * `DrawRequest.swift`      -- the shared pipeline behind the free-draw
///                                 tools (screen resolution,
///                                 per-app link resolution, numeric coercion).
/// What remains here is the class itself: `start()`, the stdin read loop,
/// top-level JSON-RPC routing, the three `send*` primitives, and the
/// transport-failure shutdown policy they share.
public final class MCPServer: @unchecked Sendable {
    public static let shared = MCPServer()
    private var isRunning = false

    /// Guards `transportFailureFired` below. `readLoop` runs on the
    /// background `DispatchQueue.global` queue started by `start()`, while
    /// `terminateAfterTransportFailure` hops to the MAIN queue partway
    /// through its own body (see that method) to call `NSApp.terminate`; the
    /// flag itself, though, has to be safe to set and read from either queue,
    /// since `readLoop` polls it from the background queue while a write
    /// failure detected inside `sendResponse` -- also on the background
    /// queue, but logically a separate event from `readLoop`'s own EOF/
    /// overflow checks -- can set it at effectively any point in that same
    /// loop's iteration.
    private let transportFailureLock = NSLock()

    /// Set exactly once, by whichever of `terminateAfterTransportFailure`'s
    /// three call sites (stdin EOF, LineFramer overflow, failed stdout
    /// write) gets there first. See `terminateAfterTransportFailure` and
    /// `hasTransportFailed` for what this guards against.
    private var transportFailureFired = false

    private init() {}

    /// Whether `terminateAfterTransportFailure` has already fired, from any
    /// cause. `readLoop` polls this after handling each line and after each
    /// chunk so that once ONE bad write has already kicked off shutdown, it
    /// stops draining the rest of whatever chunk it is holding instead of
    /// continuing to hand doomed lines to `handleMessage` (each of which
    /// would attempt -- and log -- another write into the same dead pipe),
    /// and stops blocking on `stdin.availableData` for more input from a
    /// peer that already has no reader on the other end of this process's
    /// replies.
    private func hasTransportFailed() -> Bool {
        transportFailureLock.lock()
        defer { transportFailureLock.unlock() }
        return transportFailureFired
    }

    public func log(_ message: String) {
        Logger.shared.log(message, level: "MCP")
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        log("Starting stdio MCP Server loop...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        let stdin = FileHandle.standardInput
        var framer = LineFramer()

        // Set immediately before `break`ing out of the loop below, naming WHY
        // the loop ended, so the shared shutdown logic after it does not have
        // to guess. `isRunning` is only ever set to `true` (in start()); it is
        // never flipped back to false anywhere, so every exit from this loop
        // is one of the three `break`s below, never the `while isRunning`
        // condition itself going false. Two of those three (stdin EOF,
        // LineFramer overflow) set `terminationReason` and let the `guard`
        // below call `terminateAfterTransportFailure` exactly once. The third
        // -- noticing mid-loop that a write already failed inside
        // `handleMessage` -- deliberately leaves it `nil`: that failure
        // already called `terminateAfterTransportFailure` itself from inside
        // `sendResponse`, so calling it again here would only be caught by
        // that method's own idempotency guard, not prevented at the source.
        var terminationReason: String?

        outer: while isRunning {
            let availableData = stdin.availableData
            if availableData.isEmpty {
                log("EOF on stdin. Exiting MCP loop.")
                terminationReason = "MCP client pipe closed (stdin EOF)"
                break
            }

            let result = framer.feed(availableData)
            for line in result.lines {
                handleMessage(line)
                if hasTransportFailed() {
                    // A write inside this `handleMessage` call (or an earlier
                    // one in this same chunk) failed and already triggered
                    // shutdown. Stop feeding the rest of this chunk's lines
                    // to a transport that is already gone -- each would
                    // otherwise attempt, and log, another doomed write.
                    break outer
                }
            }

            if result.overflow {
                log("LineFramer's unterminated buffer exceeded \(LineFramer.maxBufferBytes) bytes without a newline; the peer is not framing JSON-RPC messages correctly. Treating this as a fatal protocol error rather than growing the buffer without bound.")
                terminationReason = "MCP stdin framing overflow (peer sent \(LineFramer.maxBufferBytes)+ bytes with no newline)"
                break
            }

            if hasTransportFailed() {
                // Every line in this chunk parsed fine individually, but a
                // write still failed (e.g. the very last line's response),
                // so there is nothing left to read for. Do not loop back
                // around to `stdin.availableData`, which would block waiting
                // for more input from a peer whose reply pipe we already
                // know is dead.
                break
            }
        }

        guard let reason = terminationReason else {
            // Reached both in the (currently unreachable) case of
            // `isRunning` itself going false, and, deliberately, whenever
            // this loop broke out because `hasTransportFailed()` was already
            // true -- see that branch above for why no second call belongs
            // here.
            return
        }

        terminateAfterTransportFailure(reason: reason)
    }

    /// Shared shutdown path for every condition that means "the MCP transport
    /// is gone": stdin EOF and a stdin framing overflow (both from
    /// `readLoop`), and a failed stdout write (from `sendResponse`) -- a dead
    /// pipe on either end of this process's stdio leaves nothing left to
    /// serve.
    ///
    /// CRITICAL GATING -- do not remove or "simplify" this check.
    /// `MCPServer.shared.start()` (and therefore `readLoop`/`sendResponse`)
    /// runs unconditionally in BOTH launch modes -- see
    /// `AppDelegate.applicationDidFinishLaunching`. In real MCP mode (launched
    /// as `AIChalkboard --mcp` by an MCP host such as Claude Desktop),
    /// stdin/stdout ARE the client's pipes, and either one breaking means the
    /// client process died or disconnected -- there is nothing left to serve,
    /// so this process should exit rather than linger as an orphaned overlay
    /// window (and Dock entry, in GUI mode) forever.
    ///
    /// But in normal GUI mode (user double-clicks AIChalkboard.app from
    /// Finder/Dock), stdin/stdout are NOT client pipes at all -- stdin is
    /// typically /dev/null or simply closed, so stdin.availableData returns
    /// empty essentially IMMEDIATELY on launch. If we terminated
    /// unconditionally here, double-clicking the app would cause it to quit
    /// itself almost instantly, making the GUI completely unusable. Gating on
    /// `LaunchMode.isMCPMode` is what makes transport-failure-triggered
    /// shutdown safe: it only fires when a broken pipe actually means "the
    /// MCP client hung up or disappeared", never when it just means "nobody
    /// ever wired a real client up to this stdio."
    ///
    /// IDEMPOTENCY GUARD -- do not remove. Before `hasTransportFailed()`
    /// existed for `readLoop` to poll, a single bad chunk of stdin could
    /// reach this function more than once: `readLoop` had no way to learn
    /// that a write inside `handleMessage` had already failed, so it kept
    /// handing the chunk's remaining lines to `handleMessage`, each of which
    /// produced another failed write and therefore another call here -- N
    /// separate `DispatchQueue.main.async { markInternalTermination;
    /// NSApp.terminate }` closures instead of one. `readLoop` breaking out
    /// promptly (above) now makes that pile-up far less likely, but this
    /// guard is what actually GUARANTEES this function's effects happen at
    /// most once, regardless of how many times, or from which of its three
    /// call sites (stdin EOF, LineFramer overflow, failed stdout write), it
    /// gets invoked.
    private func terminateAfterTransportFailure(reason: String) {
        transportFailureLock.lock()
        let alreadyFired = transportFailureFired
        transportFailureFired = true
        transportFailureLock.unlock()
        guard !alreadyFired else { return }

        guard LaunchMode.isMCPMode else {
            log("Not in MCP mode; leaving app running after \(reason) (expected for a normal GUI launch, where stdin/stdout are not client pipes).")
            return
        }

        log("\(reason) while in MCP mode. Terminating process to avoid leaving an orphaned background instance.")

        // NSApp.terminate(_:) must be called on the main thread. readLoop()
        // runs on a background DispatchQueue.global() queue (see start()) and
        // sendResponse() is called from that same queue's call stack, so we
        // hop to the main queue rather than calling it directly here. Routing
        // through NSApp.terminate(nil) (instead of a bare exit(0)) keeps this
        // symmetric with the SIGTERM/SIGINT/SIGHUP shutdown path in the
        // launcher entry point, and ensures
        // AppDelegate.applicationWillTerminate's clean-shutdown log line still
        // fires.
        DispatchQueue.main.async {
            // LIFECYCLE shutdown, NOT a user quit. Claude Desktop gives each of
            // the two processes it spawns its own stdin/stdout pipes, so one
            // pipe breaking says nothing about the sibling's -- the sibling may
            // still be serving its client perfectly well. Marking the
            // termination internal is what stops
            // AppDelegate.applicationShouldTerminate from broadcasting a quit
            // that would take that healthy sibling down with us.
            AppDelegate.markInternalTermination(reason: reason)
            NSApp.terminate(nil)
        }
    }

    /// Writes one JSON-RPC response line to stdout, degrading to a logged
    /// failure (and, in MCP mode, the same graceful shutdown stdin EOF uses)
    /// rather than crashing.
    ///
    /// Uses the throwing `write(contentsOf:)` API, NOT the legacy
    /// non-throwing `write(_:)`. `Sources/Logger.swift`'s `writeToFile`
    /// documents exactly why that matters and this mirrors it: the legacy API
    /// raises an UNCATCHABLE Objective-C exception on failure (e.g. EPIPE,
    /// when the MCP client on the other end of stdout has gone away), which
    /// would abort this process outright with no chance to log anything or
    /// shut down cleanly -- and would bypass `NSSetUncaughtExceptionHandler`
    /// too, since that only catches Objective-C exceptions raised through the
    /// normal propagation path, not ones the runtime turns straight into
    /// `abort()`. `signal(SIGPIPE, SIG_IGN)` in the launcher entry point is
    /// the other half of this fix: without it, the write that would raise
    /// EPIPE here never gets the chance, because the default SIGPIPE
    /// disposition kills the process first. This is reachable in practice
    /// specifically because this process's stdout IS the MCP client's pipe,
    /// which the client can close at any time.
    private func sendResponse(_ jsonObject: [String: Any]) {
        let outputData: Data
        if let encoded = MCPResponseTransport.serializedLine(jsonObject) {
            outputData = encoded
        } else {
            log("Refusing to write an MCP response larger than \(DrawingDefaults.maxMCPResponseBytes) bytes or one that cannot be serialized; sending a compact error response instead.")
            guard let fallback = MCPResponseTransport.compactOversizeErrorLine(id: jsonObject["id"]) else {
                // This is not expected: the fallback has fixed, small content
                // and a null ID retry. Do not recurse if the runtime itself
                // cannot serialize it.
                log("Failed to serialize compact MCP oversize-response error.")
                return
            }
            outputData = fallback
        }

        do {
            try FileHandle.standardOutput.write(contentsOf: outputData)
        } catch {
            log("Failed to write MCP response to stdout: \(error). The client pipe is presumably gone; treating this like stdin EOF.")
            terminateAfterTransportFailure(reason: "MCP stdout write failed (client pipe closed)")
        }
    }

    private func handleMessage(_ data: Data) {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            // Malformed JSON. A single guard used to swallow this silently --
            // no reply at all -- leaving a conforming JSON-RPC client to hang
            // until its own request timeout instead of seeing a standard
            // Parse error. `"id": NSNull()` because there is no candidate id
            // to echo back; that is JSON-RPC's own convention for "the id
            // could not even be determined."
            log("Invalid JSON payload received: \(error)")
            sendResponse([
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error"]
            ])
            return
        }

        guard let json = parsed as? [String: Any] else {
            // Valid JSON that is not a single JSON-RPC request object -- most
            // notably a BATCH array, which this server does not support, or a
            // bare scalar. Previously swallowed by the same guard as the
            // parse-error case above; split out so each gets its own,
            // correct JSON-RPC error code instead of both getting silence.
            log("Parsed JSON payload is not a JSON-RPC request object (e.g. a batch array); rejecting as Invalid Request.")
            sendResponse([
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32600, "message": "Invalid Request"]
            ])
            return
        }

        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let rawParams = json["params"]

        log("Received message method: \(method)")

        switch method {
        case "initialize":
            handleInitialize(id: id)
        case "notifications/initialized":
            log("Client completed initialization handshake.")
        case "ping":
            if let id = id {
                sendResponse(["jsonrpc": "2.0", "id": id, "result": [:]])
            }
        case "tools/list":
            handleToolsList(id: id)
        case "tools/call":
            guard let id else { return }
            switch MCPProtocolValidation.toolCallParameters(rawParams) {
            case .success(let validatedParams):
                handleToolsCall(id: id, params: validatedParams)
            case .failure(let message):
                // Do not coerce malformed arguments to `{}`: `clear` treats
                // an omitted annotation_id as a request to clear the active
                // screen, so that fallback would turn invalid input into a
                // destructive operation.
                sendErrorResult(id: id, text: message)
            }
        default:
            if let id = id {
                sendResponse([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": [
                        "code": -32601,
                        "message": "Method not found: \(method)"
                    ]
                ])
            }
        }
    }

    private func handleInitialize(id: Any?) {
        guard let id = id else { return }
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "ai-chalkboard",
                "version": BuildMetadata.productVersion,
                "buildIdentifier": BuildMetadata.buildIdentifier
            ]
        ]
        sendResponse(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func handleToolsList(id: Any?) {
        guard let id = id else { return }
        sendResponse(["jsonrpc": "2.0", "id": id, "result": ["tools": MCPToolCatalog.tools]])
    }

    func sendTextResult(id: Any, text: String, isError: Bool = false) {
        var result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ]
        ]
        if isError {
            result["isError"] = true
        }
        sendResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    /// Returns a human/model-readable metadata block followed by a native MCP
    /// image content block. MCP image data is raw standard base64 -- no data-URL
    /// prefix -- and `mimeType` uses the protocol's camel-case spelling.
    func sendImageResult(id: Any, metadataText: String, imageData: Data, mimeType: String = "image/png") {
        sendResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": metadataText
                    ],
                    [
                        "type": "image",
                        "data": imageData.base64EncodedString(),
                        "mimeType": mimeType
                    ]
                ]
            ]
        ])
    }

    func sendErrorResult(id: Any, text: String) {
        sendResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "Error: \(text)"
                    ]
                ],
                "isError": true
            ]
        ])
    }
}
