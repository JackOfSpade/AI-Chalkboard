#!/usr/bin/env python3
import argparse
import subprocess
import json
import os
import select
import sys
import time

DEFAULT_BINARY_PATH = "./.build/release/AIChalkboard.app/Contents/MacOS/AIChalkboard"
DEFAULT_RESPONSE_TIMEOUT_SECONDS = 15.0
SHUTDOWN_TIMEOUT_SECONDS = 2.0


def parse_args():
    parser = argparse.ArgumentParser(
        description="Exercise the AI Chalkboard MCP stdio protocol."
    )
    parser.add_argument(
        "binary_path",
        nargs="?",
        default=DEFAULT_BINARY_PATH,
        help="MCP executable to launch (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_RESPONSE_TIMEOUT_SECONDS,
        metavar="SECONDS",
        help="maximum time to wait for each MCP response (default: %(default)s)",
    )
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    return args


def stderr_diagnostics(proc):
    if proc.stderr is None:
        return ""
    output = proc.stderr.read().strip()
    if not output:
        return ""
    return f"\nChild stderr:\n{output}"


def terminate_child(proc):
    """Stop only the child started by this harness, escalating if needed."""
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)


class MCPLineReader:
    """Deadline-bound newline framing over a child process's stdout pipe."""

    def __init__(self, proc):
        if proc.stdout is None:
            raise RuntimeError("MCP child was started without a stdout pipe.")
        self.proc = proc
        self.fd = proc.stdout.fileno()
        self.buffer = bytearray()

    def read_line(self, method, timeout_seconds):
        deadline = time.monotonic() + timeout_seconds

        while True:
            newline_index = self.buffer.find(b"\n")
            if newline_index >= 0:
                line = bytes(self.buffer[:newline_index])
                del self.buffer[:newline_index + 1]
                try:
                    return line.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise RuntimeError(
                        f"MCP child returned non-UTF-8 data for {method}: {line!r}"
                    ) from error

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                partial = f" Partial response: {bytes(self.buffer)!r}." if self.buffer else ""
                raise TimeoutError(
                    f"Timed out after {timeout_seconds:g}s waiting for a complete "
                    f"newline-terminated MCP response to {method} (child PID "
                    f"{self.proc.pid}).{partial}"
                )

            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                continue

            chunk = os.read(self.fd, 65536)
            if chunk:
                self.buffer.extend(chunk)
                continue

            exit_code = self.proc.poll()
            status = f"exit code {exit_code}" if exit_code is not None else "stdout EOF"
            partial = f" Partial response: {bytes(self.buffer)!r}." if self.buffer else ""
            raise RuntimeError(
                f"MCP child closed stdout before completing its response to "
                f"{method} ({status}).{partial}"
            )


def send_request(proc, reader, request, timeout_seconds):
    if proc.stdin is None or proc.stdout is None:
        raise RuntimeError("MCP child was started without stdio pipes.")

    payload = json.dumps(request) + "\n"
    proc.stdin.write(payload)
    proc.stdin.flush()

    method = request.get("method", "<unknown method>")
    line = reader.read_line(method, timeout_seconds)

    try:
        return json.loads(line)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"MCP child returned invalid JSON for {method}: {line!r}"
        ) from error


def main():
    args = parse_args()
    # An explicit path lets CI/local verification exercise an isolated scratch
    # build without replacing the .app bundle used by live Claude sessions.
    binary_path = args.binary_path
    print(f"Launching MCP process: {binary_path}", flush=True)

    proc = subprocess.Popen(
        [binary_path, "--mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1
    )
    reader = MCPLineReader(proc)

    failed = False
    try:
        print("\n1. Testing 'initialize'...", flush=True)
        init_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "test-client", "version": "1.0"}
            }
        }, args.timeout)
        print("Initialize response:", json.dumps(init_res, indent=2), flush=True)

        print("\n2. Testing 'tools/list'...", flush=True)
        list_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        }, args.timeout)
        tools = [t["name"] for t in list_res["result"]["tools"]]
        print("Available tools:", tools, flush=True)
        assert "draw_path" in tools
        grid_tool = next(t for t in list_res["result"]["tools"] if t["name"] == "draw_grid")
        assert "label" in grid_tool["inputSchema"]["properties"]

        print("\n3. Testing 'draw_path' for freehand organic circle...", flush=True)
        path_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "draw_path",
                "arguments": {
                    "points": [
                        [400, 300], [420, 295], [450, 310], [445, 340], [410, 350], [390, 320], [400, 300]
                    ],
                    "color": "#FF9500",
                    "stroke_width": 4.0,
                    "is_closed": True,
                    "label": "Freehand Circle Spot"
                }
            }
        }, args.timeout)
        print("draw_path response:", path_res["result"]["content"][0]["text"], flush=True)

        print("\n4. Testing labeled 'draw_grid'...", flush=True)
        grid_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "draw_grid",
                "arguments": {
                    "step_px": 120,
                    "label": "MCP Grid Test",
                    "duration_seconds": 60
                }
            }
        }, args.timeout)
        print("draw_grid response:", grid_res["result"]["content"][0]["text"], flush=True)

        print("\n5. Testing 'list_annotations'...", flush=True)
        ann_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "list_annotations",
                "arguments": {}
            }
        }, args.timeout)
        annotations_text = ann_res["result"]["content"][0]["text"]
        print("list_annotations response:", annotations_text, flush=True)
        annotations = json.loads(annotations_text)["annotations"]
        assert any(
            annotation.get("type") == "grid" and annotation.get("label") == "MCP Grid Test"
            for annotation in annotations
        )

        print("\nAll draw_path, labeled draw_grid, and annotation-list MCP tests PASSED!", flush=True)
    except Exception:
        failed = True
        raise
    finally:
        terminate_child(proc)
        diagnostics = stderr_diagnostics(proc)
        if failed and diagnostics:
            print(diagnostics, file=sys.stderr, flush=True)

if __name__ == "__main__":
    main()
