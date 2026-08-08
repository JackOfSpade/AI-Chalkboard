import Foundation
import AppKit

/// The stdio MCP server: owns the read loop, JSON-RPC method routing, and the
/// three response-writing primitives every handler funnels through.
///
/// The bulk of what used to live in this one 947-line file has moved out by
/// topic:
///   * `LineFramer.swift`       -- pure newline-framing of stdin bytes.
///   * `MCPToolCatalog.swift`   -- the static `tools/list` schema payload.
///   * `MCPToolHandlers.swift`  -- `tools/call` dispatch and every tool body.
///   * `DrawRequest.swift`      -- the shared pipeline behind the six
///                                 `draw_*` tools (screen resolution,
///                                 per-app link resolution, numeric coercion).
/// What remains here is the class itself: `start()`, the stdin read loop,
/// top-level JSON-RPC routing, the three `send*` primitives, and the
/// transport-failure shutdown policy they share.
public final class MCPServer: @unchecked Sendable {
    public static let shared = MCPServer()
    private var isRunning = false

    private init() {}

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
        // never flipped back to false anywhere, so today every exit from this
        // loop is one of the two `break`s below, never the `while isRunning`
        // condition itself going false.
        var terminationReason: String?

        while isRunning {
            let availableData = stdin.availableData
            if availableData.isEmpty {
                log("EOF on stdin. Exiting MCP loop.")
                terminationReason = "MCP client pipe closed (stdin EOF)"
                break
            }

            let result = framer.feed(availableData)
            for line in result.lines {
                handleMessage(line)
            }

            if result.overflow {
                log("LineFramer's unterminated buffer exceeded \(LineFramer.maxBufferBytes) bytes without a newline; the peer is not framing JSON-RPC messages correctly. Treating this as a fatal protocol error rather than growing the buffer without bound.")
                terminationReason = "MCP stdin framing overflow (peer sent \(LineFramer.maxBufferBytes)+ bytes with no newline)"
                break
            }
        }

        guard let reason = terminationReason else {
            // Unreachable today (see the comment above): `isRunning` is never
            // set false, so the loop can only end via one of the two breaks,
            // both of which set `terminationReason` first. If that ever
            // changes, falling through to a lifecycle shutdown with no known
            // cause would be worse than simply doing nothing here.
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
    private func terminateAfterTransportFailure(reason: String) {
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
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
              var jsonString = String(data: data, encoding: .utf8) else {
            log("Failed to serialize response JSON.")
            return
        }

        jsonString += "\n"

        guard let outputData = jsonString.data(using: .utf8) else { return }

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
        let params = json["params"] as? [String: Any] ?? [:]

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
            handleToolsCall(id: id, params: params)
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
                "version": "1.2.0"
            ]
        ]
        sendResponse(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func handleToolsList(id: Any?) {
        guard let id = id else { return }
        sendResponse(["jsonrpc": "2.0", "id": id, "result": ["tools": MCPToolCatalog.tools]])
    }

    func sendTextResult(id: Any, text: String) {
        sendResponse([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text
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
