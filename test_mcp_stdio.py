#!/usr/bin/env python3
import argparse
import base64
import itertools
import math
import subprocess
import json
import os
import select
import shutil
import struct
import sys
import tempfile
import threading
import time
import uuid
import zlib

# The signed deployable bundle intentionally lives outside SwiftPM's `.build`
# directory: a later `swift build -c release` is allowed to replace that
# directory wholesale, but must never make the MCP host's configured command
# disappear.  `build_app.sh` creates this path after copying the compiled
# `.build/release/AIChalkboard` source executable into the bundle.
DEFAULT_BINARY_PATH = "./dist/AIChalkboard.app/Contents/MacOS/AIChalkboard"
DEFAULT_RESPONSE_TIMEOUT_SECONDS = 15.0
SHUTDOWN_TIMEOUT_SECONDS = 2.0
RESUME_CLEANUP_ATTEMPTS = 3
PRESENTATION_SETTLE_TIMEOUT_SECONDS = 2.0
PRESENTATION_POLL_INTERVAL_SECONDS = 0.025
TRANSIENT_WINDOWSERVER_PRESENTATION_FAILURES = frozenset({
    "windowserver_entry_missing",
    "windowserver_window_not_on_screen",
    "windowserver_bounds_mismatch",
    "windowserver_alpha_below_expected",
})

# verify_presentation_until_settled may send more than one request while it
# polls for WindowServer convergence (see its own docstring below); reserve
# a block of ids comfortably larger than PRESENTATION_SETTLE_TIMEOUT_SECONDS
# / PRESENTATION_POLL_INTERVAL_SECONDS could ever consume, so a slow test
# environment cannot exhaust the reservation and spill an id into one
# already handed to some unrelated request (see `_next_id_block`).
_PRESENTATION_POLL_ID_RESERVATION = 1000

# Bounded tail kept from the child's stderr for failure diagnostics. Bounded
# deliberately -- see `StderrDrain`'s doc comment for why an UNBOUNDED read
# is exactly the bug this class exists to avoid. Public (no leading
# underscore): tests/mcp_wire_snapshot.py's own diagnostics message reports
# this same bound, since it shares this same drain.
STDERR_TAIL_BYTES = 16_000

# Keep the harness aligned with the server's final transport boundary: every
# MCP response line, including its terminating newline, is capped at 8 MiB in
# `MCPResponseTransport`. The real server should therefore never approach an
# unbounded reader buffer, but enforcing the same limit here makes a broken or
# substituted child fail promptly instead of letting a newline-free stdout
# flood consume arbitrary harness memory until its request deadline expires.
MAX_MCP_RESPONSE_BYTES = 8 * 1024 * 1024

# JSON-RPC ids only need to be unique per in-flight request on this
# synchronous stdio transport (each request's response is read before the
# next request is sent, so nothing is ever actually ambiguous at the wire
# level) -- but reusing a literal across two logically different requests is
# still a latent bug, and hand-numbered literals rot the moment a call is
# added, removed, or reordered. (This replaced a real instance of exactly
# that: resume_annotations_with_retry's retry ids and the very next
# hardcoded call both used id 47.) Draw every id in this script from one
# monotonic counter instead so a collision is structurally impossible.
_id_counter = itertools.count(1)


def _next_id():
    """Returns a fresh, script-wide-unique JSON-RPC request id."""
    return next(_id_counter)


def _next_id_block(count):
    """Reserves `count` consecutive ids and returns the first.

    For callers like `resume_annotations_with_retry` and
    `verify_presentation_until_settled`, which take a single base id and
    derive each retry/poll attempt's id as `base + attempt` internally (see
    their own docstrings -- and see tests/test_mcp_stdio_harness.py, which
    pins that exact `base + attempt` behavior via mock assertions, so it is
    not something this allocator can change from the outside). Reserving the
    whole block up front guarantees none of those derived ids can ever
    collide with an id handed to an unrelated request in between, no matter
    how many attempts actually fire.
    """
    first = next(_id_counter)
    for _ in range(count - 1):
        next(_id_counter)
    return first


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
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a finite number greater than zero")
    return args


def stderr_diagnostics(drain):
    """Returns any stderr this harness's `StderrDrain` has collected from the
    child, formatted for appending to a failure message -- or "" if there is
    none. Draining continuously gives ordinary host-like behavior and captures
    useful diagnostics before teardown; the server itself no longer depends on
    it for progress because stderr attempts are bounded and non-blocking. This
    function only formats the bounded tail already collected by `drain`.
    """
    output = drain.join_and_get_tail(timeout=SHUTDOWN_TIMEOUT_SECONDS).strip()
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
        try:
            proc.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            # A process that survives SIGKILL is (almost always) stuck in
            # uninterruptible kernel sleep, not something this harness can
            # fix by waiting longer. Warn loudly instead of letting
            # TimeoutExpired escape a cleanup path and mask whatever real
            # exception this was already handling (this is typically called
            # from a `finally` block).
            print(
                f"warning: child PID {proc.pid} did not exit within "
                f"{SHUTDOWN_TIMEOUT_SECONDS:g}s of SIGKILL; giving up on it.",
                file=sys.stderr,
                flush=True,
            )


class StderrDrain:
    """Continuously drains a child process's stderr on a background thread.

    This mirrors an ordinary MCP host and retains a useful diagnostic tail
    during a long run. It is not a transport-progress requirement: Logger
    limits every stderr attempt to 512 bytes, writes non-blockingly, and drops
    complete records under backpressure. Keep only a bounded tail so the
    harness's diagnostics collection cannot become unbounded memory itself.
    Every harness in this repo that spawns an MCP child uses this helper (see
    `spawn_mcp_child`) for consistent failure reporting.
    """

    def __init__(self, proc):
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, args=(proc,), daemon=True)
        self._thread.start()

    def _run(self, proc):
        stream = proc.stderr
        if stream is None:
            return
        fd = stream.fileno()
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self._lock:
                self._buffer.extend(chunk)
                overflow = len(self._buffer) - STDERR_TAIL_BYTES
                if overflow > 0:
                    del self._buffer[:overflow]

    def join_and_get_tail(self, timeout):
        """Waits (briefly) for the drain thread to observe EOF -- which
        `terminate_child` causes by the time this is called -- then returns
        whatever tail it collected."""
        self._thread.join(timeout)
        with self._lock:
            return bytes(self._buffer).decode("utf-8", errors="replace")


def write_solid_png(path, width, height, rgba=(36, 42, 52, 255)):
    """Writes a deterministic RGBA PNG using only the Python standard library."""
    def chunk(kind, payload):
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    row = b"\x00" + bytes(rgba) * width
    raw = row * height
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, level=9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(png)


class MCPLineReader:
    """Deadline- and size-bound newline framing over child stdout."""

    def __init__(self, proc, max_response_bytes=MAX_MCP_RESPONSE_BYTES):
        if proc.stdout is None:
            raise RuntimeError("MCP child was started without a stdout pipe.")
        if max_response_bytes < 1:
            raise ValueError("max_response_bytes must be greater than zero")
        self.proc = proc
        self.fd = proc.stdout.fileno()
        self.buffer = bytearray()
        self.max_response_bytes = max_response_bytes

    def _ensure_buffer_within_transport_limit(self, method):
        """Rejects any complete or partial buffered line beyond the wire cap.

        A single `os.read` can contain a valid response followed by bytes for
        the next response. Checking only the line about to be returned would
        accept that first response while quietly retaining an oversized tail,
        then let the harness send another request before it discovers the
        child already violated framing. Scan all complete buffered lines plus
        the final partial line so a bad tail is reported at the request whose
        output carried it.
        """
        start = 0
        while True:
            newline_index = self.buffer.find(b"\n", start)
            if newline_index < 0:
                if len(self.buffer) - start >= self.max_response_bytes:
                    raise RuntimeError(
                        f"MCP child exceeded the {self.max_response_bytes}-byte "
                        f"transport limit without a newline while responding to {method}."
                    )
                return
            if newline_index - start + 1 > self.max_response_bytes:
                raise RuntimeError(
                    f"MCP child returned a response larger than the "
                    f"{self.max_response_bytes}-byte transport limit for {method}."
                )
            start = newline_index + 1

    def read_line(self, method, timeout_seconds):
        deadline = time.monotonic() + timeout_seconds

        while True:
            self._ensure_buffer_within_transport_limit(method)
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
                "MCP child closed stdout before completing its response to "
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
        response = json.loads(line)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"MCP child returned invalid JSON for {method}: {line!r}"
        ) from error

    # A JSON-RPC response must echo the request's id so a caller can match
    # them up; on this synchronous transport (one response read per request
    # sent, never pipelined) a mismatch here cannot be ordinary races or
    # reordering -- it means the child sent something this harness did not
    # expect for this call, which is exactly the kind of transport-level bug
    # a silently-returned, unchecked response would let slip through every
    # assertion downstream that only inspects `result`.
    request_id = request.get("id")
    response_id = response.get("id") if isinstance(response, dict) else None
    if response_id != request_id:
        raise RuntimeError(
            f"MCP child echoed id {response_id!r} for {method}, expected "
            f"{request_id!r} (response: {response!r})."
        )
    return response


def spawn_mcp_child(binary_path, extra_env=None):
    """Launches `binary_path --mcp` with stdio pipes, wraps its stdout in an
    MCPLineReader, and starts a StderrDrain before returning. The drain keeps
    normal-host behavior and bounded failure diagnostics; Logger itself makes
    stderr attempts non-blocking, so a child remains responsive even without
    a drain. Returns `(proc, reader, drain)`.

    This same ~10-line Popen call was duplicated three times across this
    repo's MCP harnesses and had already drifted (only one of the three
    started its stderr drain immediately); `extra_env`, when given, is
    merged over a fresh copy of the current process's environment (never
    mutating os.environ itself) so each caller can still set up its own
    isolated suspension namespace the way it already did.
    """
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    proc = subprocess.Popen(
        [binary_path, "--mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    reader = MCPLineReader(proc)
    drain = StderrDrain(proc)
    return proc, reader, drain


def isolated_suspension_env(suspension_root, namespace_prefix):
    """Returns the env overrides that put an MCP child in a private, disposable
    suspension domain rooted at `suspension_root`.

    Every harness in this repo that spawns an MCP child needs exactly this set,
    for two separate reasons, and had drifted into either hand-rolling it or
    (tests/mcp_wire_snapshot.py) omitting it entirely:

      * ISOLATION. Without these, the child joins the USER'S PRODUCTION
        suspension domain: it reconciles against (and writes) the real lease
        registry under Application Support, observes and posts on the
        production DistributedNotificationCenter suspension-invalidation
        channel, and competes for the real instance lock -- i.e. a test can
        reach into a live Claude Desktop/Cowork session.
      * DETERMINISM. A production-domain child's `get_overlay_state` reports
        whatever the machine's live suspension state happens to be
        (`annotationsSuspended`, `activeLeaseCount`,
        `suspensionRegistryBootstrapped`), so a real session merely holding a
        lease while a capture runs changes the captured bytes.

    `suspension_root` must be a caller-owned temp directory the caller also
    removes; the lock file inside it must be named exactly "instance.lock",
    because InstanceLock.testLockURLFromEnvironment rejects (silently, falling
    back to the production path) any override whose last path component differs
    or whose parent is not under the temporary directory. `namespace_prefix`
    only labels the randomized DNC namespace for readability in logs -- the
    fresh UUID is what actually guarantees no sibling process can hear it.

    ONE DELIBERATE EXCEPTION, which is not drift and must not be "migrated":
    tests/test_suspension_two_process.py hand-rolls these same three keys
    because its TWO children have to SHARE one
    `AI_CHALKBOARD_SUSPENSION_NAMESPACE` -- the behaviour under test is two
    peers in the SAME isolated domain. This helper mints a fresh uuid4 on
    every call, so calling it once per child would put those peers in separate
    domains and silently defeat the only cross-process suspension test in the
    repo. Treat this helper as being for SINGLE-child harnesses only.
    """
    return {
        "AI_CHALKBOARD_SUSPENSION_ROOT": suspension_root,
        "AI_CHALKBOARD_SUSPENSION_NAMESPACE": f"{namespace_prefix}-{uuid.uuid4()}",
        "AI_CHALKBOARD_INSTANCE_LOCK_PATH": os.path.join(suspension_root, "instance.lock"),
    }


def resume_annotations_with_retry(proc, reader, timeout_seconds, request_id, lease_token):
    """Best-effort compensating cleanup for a completed or timed-out suspend.

    A suspension request can affect overlays before its bounded quiescence and
    final-state checks respond. Retry the idempotent release on an MCP error or transport timeout
    so this smoke test does not retain its own isolated lease. The caller must
    pass the exact token returned by suspend_annotations; no broad "resume all"
    cleanup exists, by design.
    """
    failures = []
    for attempt in range(RESUME_CLEANUP_ATTEMPTS):
        try:
            response = send_request(proc, reader, {
                "jsonrpc": "2.0",
                "id": request_id + attempt,
                "method": "tools/call",
                "params": {"name": "resume_annotations", "arguments": {"lease_token": lease_token}},
            }, timeout_seconds)
        except (RuntimeError, TimeoutError) as error:
            failures.append(f"attempt {attempt + 1}: {error}")
            continue

        result = response.get("result")
        if isinstance(result, dict) and not result.get("isError", False):
            return response
        failures.append(f"attempt {attempt + 1}: {response!r}")

    raise AssertionError(
        "resume_annotations did not confirm cleanup after "
        f"{RESUME_CLEANUP_ATTEMPTS} monotonic-deadline attempt(s): "
        + "; ".join(failures)
    )


def verify_presentation_until_settled(
    proc, reader, timeout_seconds, request_id, annotation_id,
    settle_timeout_seconds=PRESENTATION_SETTLE_TIMEOUT_SECONDS,
):
    """Poll only transient WindowServer convergence after a linearized resume.

    The first request is immediate: there is no fixed grace-period sleep that
    could conceal a regression. `resume_annotations` makes the durable lease
    transition and local AppKit ordering synchronous, but macOS can publish
    the corresponding on-screen WindowServer entry on a later compositor
    turn. Preserve that first observation for diagnostics, then retry only
    WindowServer registration/geometry/alpha failures against a monotonic
    deadline. AppKit, annotation, level, or other failures return immediately.
    """
    deadline = time.monotonic() + max(0.0, settle_timeout_seconds)
    first_transient = None
    attempt = 0

    while True:
        response = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": request_id + attempt,
            "method": "tools/call",
            "params": {
                "name": "verify_presentation",
                "arguments": {"annotation_id": annotation_id},
            },
        }, timeout_seconds)
        result = response.get("result", {})
        if result.get("isError", False):
            return response, first_transient

        presentation = json.loads(result["content"][0]["text"])
        if presentation.get("presentationReady") is True:
            return response, first_transient

        failure_reasons = set(presentation.get("failureReasons", []))
        if not failure_reasons or not failure_reasons.issubset(
            TRANSIENT_WINDOWSERVER_PRESENTATION_FAILURES
        ):
            return response, first_transient
        if first_transient is None:
            first_transient = presentation

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return response, first_transient
        time.sleep(min(PRESENTATION_POLL_INTERVAL_SECONDS, remaining))
        attempt += 1


def main():
    args = parse_args()
    # An explicit path lets CI/local verification exercise an isolated scratch
    # build without replacing the .app bundle used by live Claude sessions.
    binary_path = args.binary_path
    print(f"Launching MCP process: {binary_path}", flush=True)

    # The smoke process must never address an existing Cowork/Claude instance.
    # Suspension now has a coordinator root and DNC namespace specifically so
    # tests can use a random, disposable domain even on a developer desktop.
    suspension_root = tempfile.mkdtemp(prefix="ai-chalkboard-stdio-suspension-")
    proc, reader, stderr_drain = spawn_mcp_child(
        binary_path, extra_env=isolated_suspension_env(suspension_root, "stdio")
    )

    failed = False
    temporary_paths = []
    try:
        print("\n1. Testing 'initialize'...", flush=True)
        init_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "test-client", "version": "1.0"}
            }
        }, args.timeout)
        print("Initialize response:", json.dumps(init_res, indent=2), flush=True)
        server_info = init_res["result"]["serverInfo"]
        assert server_info["version"] == "2.1.0"
        assert isinstance(server_info["buildIdentifier"], str) and server_info["buildIdentifier"]

        print("\n2. Testing 'tools/list'...", flush=True)
        list_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/list"
        }, args.timeout)
        tools = [t["name"] for t in list_res["result"]["tools"]]
        print("Available tools:", tools, flush=True)
        assert {"draw_path", "draw_shape", "draw_image", "draw_text", "draw_batch", "suspend_annotations", "resume_annotations", "verify_annotation", "verify_presentation"}.issubset(tools)
        assert not {"draw_circle", "draw_arrow", "draw_box", "draw_label", "draw_grid"}.intersection(tools)

        print("\n3. Testing SVG 'draw_path' for a free-drawn circle...", flush=True)
        path_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {
                "name": "draw_path",
                "arguments": {
                    "path_data": "M 450 300 A 50 50 0 1 1 350 300 A 50 50 0 1 1 450 300 Z",
                    "stroke_color": "#FF9500",
                    "stroke_width": 4.0,
                    "fill_color": "#FF9500",
                    "fill_opacity": 0.15,
                    "app": ""
                }
            }
        }, args.timeout)
        print("draw_path response:", path_res["result"]["content"][0]["text"], flush=True)
        path_text = path_res["result"]["content"][0]["text"]
        path_annotation_id = path_text.split("annotation: ", 1)[1].split()[0]

        print("\n3a. Testing first-class 'draw_shape' storage and permanent-annotation rejection...", flush=True)
        shape_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {
                "name": "draw_shape",
                "arguments": {
                    "shape": "circle", "center_x": 240, "center_y": 160, "radius": 36,
                    "stroke_color": "#FF00FF", "stroke_width": 3,
                    "fill_color": "#00FFFF", "fill_opacity": 0.25,
                    "dash": [6, 3], "app": "",
                },
            },
        }, args.timeout)
        shape_text = shape_res["result"]["content"][0]["text"]
        print("draw_shape response:", shape_text, flush=True)
        shape_annotation_id = shape_text.split("annotation: ", 1)[1].split()[0]

        retired_duration_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_shape", "arguments": {
                "shape": "circle", "center_x": 320, "center_y": 160, "radius": 24,
                "app": "", "duration_seconds": 1,
            }},
        }, args.timeout)
        assert retired_duration_res["result"].get("isError") is True
        assert "duration_seconds is no longer supported" in retired_duration_res["result"]["content"][0]["text"]

        print("\n4. Testing arbitrary raster 'draw_image'...", flush=True)
        asset_png = tempfile.NamedTemporaryFile(prefix="ai-chalkboard-asset-", suffix=".png", delete=False)
        asset_png.close()
        temporary_paths.append(asset_png.name)
        write_solid_png(asset_png.name, 24, 16, rgba=(0, 224, 255, 180))
        image_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {
                "name": "draw_image",
                "arguments": {
                    "image_path": asset_png.name,
                    "x": 520, "y": 260, "width": 96,
                    "rotation_degrees": 12,
                    "opacity": 0.8,
                    "app": "",
                }
            }
        }, args.timeout)
        print("draw_image response:", image_res["result"]["content"][0]["text"], flush=True)

        print("\n5. Testing first-class 'draw_text' rendering...", flush=True)
        text_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_text", "arguments": {
                "text": "Fusion text smoke test",
                "x": 120, "y": 80, "font_size": 22,
                "color": "#FFFFFF", "background_color": "#000000",
                "background_opacity": 0.7, "padding_px": 4, "opacity": 0.9,
                "app": "",
            }},
        }, args.timeout)
        text_draw_message = text_res["result"]["content"][0]["text"]
        print("draw_text response:", text_draw_message, flush=True)
        text_annotation_id = text_draw_message.split("annotation: ", 1)[1].split()[0]

        # Validation is intentionally before AppKit layout. This request is
        # syntactically valid but would otherwise ask the unwrapped renderer
        # for a pathological text/background surface.
        excessive_text_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_text", "arguments": {
                "text": "x", "x": 120, "y": 80,
                "font_size": 100000, "padding_px": 100000, "app": "",
            }},
        }, args.timeout)
        assert excessive_text_res["result"].get("isError") is True, excessive_text_res
        assert "Text render extent exceeds the safe layout budget" in excessive_text_res["result"]["content"][0]["text"]

        # Updates rebuild text independently of draw_text, so pin the same
        # budget gate there and ensure a rejected patch leaves the existing
        # normal-size annotation available for later verification.
        excessive_text_update_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "update_annotation", "arguments": {
                "annotation_id": text_annotation_id,
                "font_size": 100000, "padding_px": 100000,
            }},
        }, args.timeout)
        assert excessive_text_update_res["result"].get("isError") is True, excessive_text_update_res
        assert "Text render extent exceeds the safe layout budget" in excessive_text_update_res["result"]["content"][0]["text"]

        batch_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_batch", "arguments": {
                "app": "",
                "items": [
                    {"type": "path", "path_data": "M 40 40 C 80 0 120 80 160 40", "stroke_color": "cyan", "stroke_width": 5},
                    {"type": "image", "image_path": asset_png.name, "x": 170, "y": 20, "width": 72, "opacity": 0.7},
                ],
            }},
        }, args.timeout)
        assert "atomic free-draw batch (2 items)" in batch_res["result"]["content"][0]["text"]

        excessive_batch_text_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_batch", "arguments": {
                "app": "",
                "items": [{
                    "type": "text", "text": "x", "x": 10, "y": 20,
                    "font_size": 100000, "padding_px": 100000,
                }],
            }},
        }, args.timeout)
        assert excessive_batch_text_res["result"].get("isError") is True, excessive_batch_text_res
        assert "Text render extent exceeds the safe layout budget" in excessive_batch_text_res["result"]["content"][0]["text"]

        print("\n6. Testing 'list_annotations'...", flush=True)
        ann_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {
                "name": "list_annotations",
                "arguments": {}
            }
        }, args.timeout)
        annotations_text = ann_res["result"]["content"][0]["text"]
        print("list_annotations response:", annotations_text, flush=True)
        annotations = json.loads(annotations_text)["annotations"]
        image_annotation = next((a for a in annotations if a.get("type") == "image"), None)
        assert image_annotation is not None
        # Annotations persist until an explicit clear, so their public wire
        # representation must not revive the removed expiry/TTL fields.
        assert "expiresAt" not in image_annotation
        assert "remainingSeconds" not in image_annotation
        text_annotation = next((a for a in annotations if a.get("id") == text_annotation_id), None)
        assert text_annotation is not None
        assert text_annotation.get("type") == "text"
        assert any(a.get("type") == "batch" for a in annotations)
        shape_annotation = next((a for a in annotations if a.get("id") == shape_annotation_id), None)
        assert shape_annotation is not None, "a successful draw_shape must be retained until clear"
        assert shape_annotation.get("type") == "path"
        assert shape_annotation.get("scope") == "global"
        assert shape_annotation.get("appId") is None
        assert "expiresAt" not in shape_annotation
        assert "remainingSeconds" not in shape_annotation
        shape_vector = shape_annotation.get("kind", {}).get("vectorPath")
        assert isinstance(shape_vector, dict), shape_annotation
        assert shape_vector.get("data") == (
            "M 204.0 160.0 A 36.0 36.0 0 1 0 276.0 160.0 "
            "A 36.0 36.0 0 1 0 204.0 160.0 Z"
        )
        assert shape_vector.get("strokeColorHex") == "#FF00FF"
        assert shape_vector.get("strokeWidth") == 3
        assert shape_vector.get("fillColorHex") == "#00FFFF"
        assert shape_vector.get("fillOpacity") == 0.25
        assert shape_vector.get("dash") == [6, 3]
        assert shape_vector.get("usesEvenOddFillRule") is False
        assert shape_vector.get("coordinateScaleX") == 1
        assert shape_vector.get("coordinateScaleY") == 1

        print("\n6a. Testing temporary annotation suspension preserves the draw state...", flush=True)
        # The implementation broadcasts suspension to sibling Chalkboard
        # processes, so a lease left behind hides a running desktop session.
        # The try/finally below is opened BEFORE the suspend request is sent,
        # which guarantees a compensating resume on every path -- assertion
        # failure, transport error, KeyboardInterrupt -- once a lease token has
        # been OBSERVED.
        #
        # What it deliberately does NOT cover: a suspend whose RESPONSE is lost
        # (timeout after the server already took the lease and posted its
        # distributed notification). There is no token to release in that case,
        # and no broad "resume all" exists by design -- see
        # resume_annotations_with_retry's docstring. Recovery there relies on
        # the bounded `lease_seconds: 30` this request asks for: the lease
        # expires on its own.
        suspension_token = None
        try:
            suspend_res = send_request(proc, reader, {
                "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
                "params": {"name": "suspend_annotations", "arguments": {
                    "lease_seconds": 30,
                    "idempotency_key": str(uuid.uuid4()),
                }},
            }, args.timeout)
            assert "result" in suspend_res, suspend_res
            assert not suspend_res["result"].get("isError", False), suspend_res
            suspension_payload = json.loads(suspend_res["result"]["content"][0]["text"])
            suspension_token = suspension_payload["leaseToken"]
            assert isinstance(suspension_token, str) and len(suspension_token) == 43
            assert suspension_payload["protocolVersion"] == 2
            assert suspension_payload["annotationsSuspended"] is True
            assert isinstance(suspension_payload["clickSafeAtObservation"], bool)
            assert isinstance(suspension_payload["peerPresentationSettled"], bool)
            assert suspension_payload["clickSafeAtObservation"] is False or suspension_payload["peerPresentationSettled"] is True
            assert isinstance(suspension_payload["candidatePids"], list)
            assert isinstance(suspension_payload["candidatePidsTruncated"], bool)
            assert isinstance(suspension_payload["visibleOwnerPids"], list)
            assert isinstance(suspension_payload["visibleOwnerPidsTruncated"], bool)
            assert isinstance(suspension_payload["visibleWindowNumbers"], list)
            assert isinstance(suspension_payload["visibleWindowNumbersTruncated"], bool)
            assert isinstance(suspension_payload["discoveryErrors"], list)
            assert isinstance(suspension_payload["discoveryErrorsTruncated"], bool)
            assert isinstance(suspension_payload["evidenceTruncated"], bool)
            assert len(suspension_payload["candidatePids"]) <= 64
            assert len(suspension_payload["visibleOwnerPids"]) <= 64
            assert len(suspension_payload["visibleWindowNumbers"]) <= 64
            assert len(suspension_payload["discoveryErrors"]) <= 64
            assert all(len(message.encode("utf-8")) <= 512 for message in suspension_payload["discoveryErrors"])

            suspended_state_res = send_request(proc, reader, {
                "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
                "params": {"name": "get_overlay_state", "arguments": {}},
            }, args.timeout)
            suspended_state = json.loads(suspended_state_res["result"]["content"][0]["text"])
            assert suspended_state["annotationsSuspended"] is True
            assert suspended_state["suspensionProtocolVersion"] == 2
            assert suspended_state["activeLeaseCount"] == 1
            assert suspended_state["suspensionRegistryBootstrapped"] is True

            suspended_list_res = send_request(proc, reader, {
                "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
                "params": {"name": "list_annotations", "arguments": {}},
            }, args.timeout)
            suspended_list_payload = json.loads(suspended_list_res["result"]["content"][0]["text"])
            assert suspended_list_payload["annotationsSuspended"] is True
            suspended_annotations = suspended_list_payload["annotations"]
            suspended_text = next((a for a in suspended_annotations if a.get("id") == text_annotation_id), None)
            assert suspended_text is not None, "suspension must not clear an annotation or mint it a new ID"
            assert suspended_text.get("type") == "text"
            assert "remainingSeconds" not in suspended_text, "annotations have no TTL to preserve during suspension"
        finally:
            if suspension_token is not None:
                resume_res = resume_annotations_with_retry(
                    proc, reader, args.timeout, _next_id_block(RESUME_CLEANUP_ATTEMPTS), suspension_token
                )
                assert "result" in resume_res, resume_res
                assert not resume_res["result"].get("isError", False), resume_res

        resumed_state_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_overlay_state", "arguments": {}},
        }, args.timeout)
        resumed_state = json.loads(resumed_state_res["result"]["content"][0]["text"])
        assert resumed_state["annotationsSuspended"] is False
        assert resumed_state["activeLeaseCount"] == 0
        assert resumed_state["suspensionProtocolVersion"] == 2
        assert resumed_state["suspensionRegistryBootstrapped"] is True
        assert resumed_state["version"] == server_info["version"]
        assert resumed_state["buildIdentifier"] == server_info["buildIdentifier"]

        presentation_res, first_transient_presentation = verify_presentation_until_settled(
            proc, reader, args.timeout, _next_id_block(_PRESENTATION_POLL_ID_RESERVATION), path_annotation_id
        )
        presentation = json.loads(presentation_res["result"]["content"][0]["text"])
        assert presentation["annotationId"] == path_annotation_id
        assert "presentationReady" in presentation and "failureReasons" in presentation
        if first_transient_presentation is not None:
            print(
                "verify_presentation first transient status:",
                json.dumps(first_transient_presentation, sort_keys=True),
                flush=True,
            )
        print("verify_presentation status:", json.dumps(presentation, sort_keys=True), flush=True)
        assert presentation["presentationReady"] is True, presentation["failureReasons"]

        print("\n7. Testing explicit-app clear without fallback drift...", flush=True)
        for app_id, x in [
            ("com.example.ClearTarget", 0.4),
            ("com.example.PreserveTarget", 0.6),
        ]:
            send_request(proc, reader, {
                "jsonrpc": "2.0",
                "id": _next_id(),
                "method": "tools/call",
                "params": {
                    "name": "draw_path",
                    "arguments": {
                        "path_data": f"M {int(x * 1000)} 360 a 40 40 0 1 0 80 0 a 40 40 0 1 0 -80 0 Z",
                        "stroke_color": "#FF0000", "stroke_width": 4,
                        "app": app_id,
                    },
                },
            }, args.timeout)

        print("\n8. Testing draw_text verify_annotation image response...", flush=True)
        screen_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {"name": "get_screens", "arguments": {}},
        }, args.timeout)
        screen_payload = json.loads(screen_res["result"]["content"][0]["text"])
        main_screen = next(
            (screen for screen in screen_payload["screens"] if screen.get("isMain")),
            screen_payload["screens"][0],
        )
        assert screen_payload["annotationsSuspended"] is False
        preview_width = 500
        preview_height = max(1, round(preview_width * main_screen["heightPx"] / main_screen["widthPx"]))
        temp_png = tempfile.NamedTemporaryFile(prefix="ai-chalkboard-clean-", suffix=".png", delete=False)
        temp_png.close()
        temporary_paths.append(temp_png.name)
        write_solid_png(temp_png.name, preview_width, preview_height)

        verify_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {
                "name": "verify_annotation",
                "arguments": {
                    "annotation_id": text_annotation_id,
                    "screenshot_path": temp_png.name,
                    "padding_px": 40,
                },
            },
        }, args.timeout)
        verify_content = verify_res["result"]["content"]
        assert [block["type"] for block in verify_content] == ["text", "image"]
        verify_metadata = json.loads(verify_content[0]["text"])
        verify_png = base64.b64decode(verify_content[1]["data"], validate=True)
        assert verify_content[1]["mimeType"] == "image/png"
        assert verify_png.startswith(b"\x89PNG\r\n\x1a\n")
        assert verify_metadata["annotationId"] == text_annotation_id
        assert verify_metadata["annotationType"] == "text"
        assert verify_metadata["verificationKind"] == "synthetic-composite"
        assert verify_metadata["screenshotPixels"] == {"width": preview_width, "height": preview_height}
        print("verify_annotation metadata:", json.dumps(verify_metadata, sort_keys=True), flush=True)

        # A misspelled exact-ID selector used to be ignored, causing `clear`
        # to fall back to its active-app/default behavior. The durable global
        # shape is a deliberately visible sentinel: if the malformed request
        # ever reaches that fallback, it is deleted. This is an end-to-end
        # proof that protocol validation runs before annotation mutation.
        typo_clear_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "clear", "arguments": {"annotation_iid": shape_annotation_id}},
        }, args.timeout)
        assert typo_clear_res["result"].get("isError") is True, typo_clear_res
        assert "annotation_iid" in typo_clear_res["result"]["content"][0]["text"]
        after_typo_clear_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "list_annotations", "arguments": {}},
        }, args.timeout)
        after_typo_clear = json.loads(after_typo_clear_res["result"]["content"][0]["text"])["annotations"]
        assert any(annotation.get("id") == shape_annotation_id for annotation in after_typo_clear), (
            "a malformed clear request must not delete its sentinel annotation"
        )

        # Clear the confirmed-live sentinel by exact ID before the following
        # app-target clear, which intentionally also clears global drawings.
        # Doing this afterwards could only prove that clear tolerates an
        # already-missing ID, not that exact undo removed this shape.
        shape_clear_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "clear", "arguments": {"annotation_id": shape_annotation_id}},
        }, args.timeout)
        assert not shape_clear_res["result"].get("isError", False), shape_clear_res
        assert shape_clear_res["result"]["content"][0]["text"] == f"Cleared annotation {shape_annotation_id}"
        shape_after_clear_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "list_annotations", "arguments": {}},
        }, args.timeout)
        shape_after_clear = json.loads(shape_after_clear_res["result"]["content"][0]["text"])["annotations"]
        assert not any(annotation.get("id") == shape_annotation_id for annotation in shape_after_clear)

        clear_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {
                "name": "clear",
                "arguments": {"app": "com.example.ClearTarget"},
            },
        }, args.timeout)
        clear_text = clear_res["result"]["content"][0]["text"]
        print("explicit clear response:", clear_text, flush=True)
        assert "targetSource=explicit-app" in clear_text
        assert "appId=com.example.ClearTarget" in clear_text

        after_clear_res = send_request(proc, reader, {
            "jsonrpc": "2.0",
            "id": _next_id(),
            "method": "tools/call",
            "params": {"name": "list_annotations", "arguments": {}},
        }, args.timeout)
        after_clear = json.loads(after_clear_res["result"]["content"][0]["text"])["annotations"]
        assert not any(annotation.get("appId") == "com.example.ClearTarget" for annotation in after_clear)
        assert any(annotation.get("appId") == "com.example.PreserveTarget" for annotation in after_clear)

        print("\nAll draw, shape, suspension/resume, persistence-metadata, annotation-list, image-verification, and explicit-clear MCP tests PASSED!", flush=True)
    except Exception:
        failed = True
        raise
    finally:
        terminate_child(proc)
        for path in temporary_paths:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        shutil.rmtree(suspension_root, ignore_errors=True)
        diagnostics = stderr_diagnostics(stderr_drain)
        if failed and diagnostics:
            print(diagnostics, file=sys.stderr, flush=True)

if __name__ == "__main__":
    main()
