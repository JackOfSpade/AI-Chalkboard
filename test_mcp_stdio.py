#!/usr/bin/env python3
import argparse
import base64
import itertools
import math
import subprocess
import json
import os
import queue
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
    useful diagnostics before teardown. The server itself no longer depends on
    the drain for progress: macOS stderr writes are bounded and non-blocking,
    while Windows submits bounded writes to a bounded background worker. This
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
    limits every stderr attempt to 512 bytes and either writes non-blockingly
    (macOS) or submits to a bounded background worker (Windows), dropping
    records under sustained backpressure. Keep only a bounded tail so the
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
    """Deadline- and size-bound newline framing over child stdout.

    A background reader is used on every platform because Python's
    ``select()`` accepts anonymous subprocess pipes on POSIX but only sockets
    on Windows. The queue is bounded to roughly one maximum-size response, so
    a broken child still cannot turn eager stdout draining into unbounded
    harness memory.
    """

    _read_chunk_bytes = 65_536
    _eof = object()

    def __init__(self, proc, max_response_bytes=MAX_MCP_RESPONSE_BYTES):
        if proc.stdout is None:
            raise RuntimeError("MCP child was started without a stdout pipe.")
        if max_response_bytes < 1:
            raise ValueError("max_response_bytes must be greater than zero")
        self.proc = proc
        self.fd = proc.stdout.fileno()
        self.buffer = bytearray()
        self.max_response_bytes = max_response_bytes
        queue_capacity = max(2, (max_response_bytes // self._read_chunk_bytes) + 2)
        self._chunks = queue.Queue(maxsize=queue_capacity)
        self._reader_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader_thread.start()

    def _read_stdout(self):
        while True:
            try:
                chunk = os.read(self.fd, self._read_chunk_bytes)
            except OSError as error:
                self._chunks.put(error)
                return
            if not chunk:
                self._chunks.put(self._eof)
                return
            self._chunks.put(chunk)

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

            try:
                chunk = self._chunks.get(timeout=remaining)
            except queue.Empty:
                continue

            if isinstance(chunk, bytes):
                self.buffer.extend(chunk)
                continue
            if isinstance(chunk, OSError):
                partial = f" Partial response: {bytes(self.buffer)!r}." if self.buffer else ""
                raise RuntimeError(
                    f"Failed to read MCP child stdout while waiting for {method}: "
                    f"{chunk}.{partial}"
                ) from chunk

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
    normal-host behavior and bounded failure diagnostics. Logger keeps protocol
    progress independent of the drain on both platforms: direct non-blocking
    writes on macOS, a bounded writer handoff on Windows. Returns
    `(proc, reader, drain)`.

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

    THE DELIBERATE EXCEPTIONS, which are not drift and must not be "migrated":
    tests/test_suspension_two_process.py and
    tests/test_capture_visible_two_process.py hand-roll these same three keys
    because their TWO children have to SHARE one
    `AI_CHALKBOARD_SUSPENSION_NAMESPACE` -- the behaviour under test is two
    peers in the SAME isolated domain. This helper mints a fresh uuid4 on
    every call, so calling it once per child would put those peers in separate
    domains and silently defeat the only cross-process tests in the repo.
    Treat this helper as being for SINGLE-child harnesses only.

    NOT COVERED HERE: `AI_CHALKBOARD_LOG_DIR`. These keys isolate the
    suspension domain and the instance lock, but Logger still resolves to the
    user's real ~/Library/Logs/AIChalkboard unless that absolute override is
    also set, and TestHarness.isActive cannot substitute for it -- it detects
    an XCTest bundle, and a binary spawned as a plain subprocess looks exactly
    like the real app. Callers that care (see
    tests/test_capture_visible_two_process.py) set it themselves.
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
        # Pinned deliberately, like BuildMetadataTests' own assertion: a
        # version bump should be a conscious edit here too, not something that
        # silently drifts. Keep this in step with
        # BuildMetadata.productVersion.
        assert server_info["version"] == "2.2.0"
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

        print("\n2a. Testing 'get_overlay_state's anchorTracking object before any draw/suspend/resume call...", flush=True)
        # No draw_*, suspend_annotations, or resume_annotations request has
        # been sent yet, and no draw call in this whole script ever creates a
        # REAL window anchor (every anchor="window" request exercised below is
        # a deterministic rejection) -- so anchored/tracking/hidden/lost must
        # all be exactly zero for the rest of this run, and with nothing ever
        # anchored, AnchorTracker's sampling timer never starts: sampleIntervalMs
        # must stay real JSON null (parsed here to Python None, not an absent
        # key and not the string "null") for the rest of the script too -- see
        # jsonValue(_ value: Int?) in MCPToolHandlers+Payloads.swift, the one
        # place that widening happens.
        #
        # lastSampleAgeMs is deliberately NOT pinned to null here:
        # AnchorTracker.shared.kick() -- which stamps a fresh sample time even
        # when there is nothing anchored to sample, see performTick()'s early
        # `guard !snapshots.isEmpty` branch -- fires on any real
        # NSWorkspace.didActivateApplicationNotification, including one this
        # freshly-launched process can trigger for itself while creating its
        # own overlay window. That already happens before this very first
        # tools/call on some machines/timings, so both null and a small
        # non-negative age are legitimate, non-flaky observations; only the
        # TYPE is pinned here. Section 12 below separately proves the
        # populated case is real once resume_annotations' own kick() has
        # unambiguously fired.
        early_overlay_state_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_overlay_state", "arguments": {}},
        }, args.timeout)
        early_overlay_state = json.loads(early_overlay_state_res["result"]["content"][0]["text"])
        assert "anchorTracking" in early_overlay_state, early_overlay_state
        early_anchor_tracking = early_overlay_state["anchorTracking"]
        assert set(early_anchor_tracking.keys()) == {
            "anchored", "tracking", "hidden", "lost", "sampleIntervalMs", "lastSampleAgeMs",
        }, early_anchor_tracking
        assert early_anchor_tracking["anchored"] == 0, early_anchor_tracking
        assert early_anchor_tracking["tracking"] == 0, early_anchor_tracking
        assert early_anchor_tracking["hidden"] == 0, early_anchor_tracking
        assert early_anchor_tracking["lost"] == 0, early_anchor_tracking
        assert early_anchor_tracking["sampleIntervalMs"] is None, early_anchor_tracking
        early_last_sample_age = early_anchor_tracking["lastSampleAgeMs"]
        assert early_last_sample_age is None or (
            isinstance(early_last_sample_age, int) and early_last_sample_age >= 0
        ), early_anchor_tracking

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
        # `avoid` is opt-in. The ordinary label path remains a literal legacy
        # string, because existing agents parse this exact response with the
        # same bare "annotation: " split above instead of decoding JSON.
        assert text_draw_message == (
            f"Created text annotation: {text_annotation_id} "
            "(GLOBAL: visible over every app)"
        )

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

        print("\n9. Testing anchor/anchor_resize rejection paths on draw_path (deterministic, no live window needed)...", flush=True)
        # Every rejection below is pure string/appId validation that runs
        # BEFORE any process or window lookup -- see DrawRequest
        # .parseAnchorArguments's own doc comment -- so it needs no live
        # target window and is exactly as deterministic as any other
        # argument-shape rejection already covered above.
        # sendErrorResult always prepends "Error: " to the message text (see
        # MCPServer.sendErrorResult); every literal below matches the full
        # wire text, not just MCP_SURFACE.md's bare message.
        anchor_resize_reject_text = (
            "Error: anchor_resize is only valid with anchor=\"window\": it selects how a drawing reacts to "
            "its anchor window being resized, and there is no anchor window without one. Nothing was "
            "drawn; remove anchor_resize, or add anchor=\"window\"."
        )
        anchor_resize_without_anchor_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_path", "arguments": {
                "path_data": "M 10 10 L 20 20", "app": "", "anchor_resize": "pin",
            }},
        }, args.timeout)
        assert anchor_resize_without_anchor_res["result"].get("isError") is True, anchor_resize_without_anchor_res
        assert anchor_resize_without_anchor_res["result"]["content"][0]["text"] == anchor_resize_reject_text

        anchor_resize_with_none_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_path", "arguments": {
                "path_data": "M 10 10 L 20 20", "app": "", "anchor": "none", "anchor_resize": "scale",
            }},
        }, args.timeout)
        assert anchor_resize_with_none_res["result"].get("isError") is True, anchor_resize_with_none_res
        assert anchor_resize_with_none_res["result"]["content"][0]["text"] == anchor_resize_reject_text, (
            "explicit anchor=\"none\" must reject anchor_resize with the identical literal text as an absent anchor"
        )

        unknown_anchor_reject_text = "Error: anchor must be one of \"none\", \"window\" when supplied."
        unknown_anchor_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_path", "arguments": {
                "path_data": "M 10 10 L 20 20", "app": "", "anchor": "sideways",
            }},
        }, args.timeout)
        assert unknown_anchor_res["result"].get("isError") is True, unknown_anchor_res
        assert unknown_anchor_res["result"]["content"][0]["text"] == unknown_anchor_reject_text

        non_string_anchor_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_path", "arguments": {
                "path_data": "M 10 10 L 20 20", "app": "", "anchor": 42,
            }},
        }, args.timeout)
        assert non_string_anchor_res["result"].get("isError") is True, non_string_anchor_res
        assert non_string_anchor_res["result"]["content"][0]["text"] == unknown_anchor_reject_text, (
            "a non-string anchor must be rejected with the same literal text as an unrecognised string value"
        )

        # app="" is a GLOBAL/untagged drawing -- no appId at all -- so this
        # rejects before any process/window enumeration ever runs (see
        # DrawRequest.resolveWindowAnchor's `guard let appId else` branch)
        # and is therefore just as deterministic as the four checks above,
        # despite naming "a target application".
        window_anchor_on_global_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_path", "arguments": {
                "path_data": "M 10 10 L 20 20", "app": "", "anchor": "window",
            }},
        }, args.timeout)
        assert window_anchor_on_global_res["result"].get("isError") is True, window_anchor_on_global_res
        assert window_anchor_on_global_res["result"]["content"][0]["text"] == (
            "Error: anchor=\"window\" requires a target application, because it anchors the drawing to one "
            "of that application's windows. Nothing was drawn; pass app explicitly, or draw without "
            "anchor to place this at fixed display coordinates."
        )

        print("\n10. Testing highlight_element's three-value anchor validation and anchor_resize rejection...", flush=True)
        # highlight_element validates anchor/anchor_resize itself, BEFORE
        # resolving any running process or touching Accessibility (see
        # parseHighlightAnchorArguments's own doc comment) -- so, like
        # section 9 above, none of this needs a live target app.
        highlight_non_string_anchor_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "highlight_element", "arguments": {
                "label": "Anchor Validation Probe", "anchor": 7,
            }},
        }, args.timeout)
        assert highlight_non_string_anchor_res["result"].get("isError") is True, highlight_non_string_anchor_res
        highlight_unknown_anchor_reject_text = "Error: anchor must be one of \"element\", \"window\", \"none\" when supplied."
        assert highlight_non_string_anchor_res["result"]["content"][0]["text"] == highlight_unknown_anchor_reject_text

        highlight_unknown_anchor_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "highlight_element", "arguments": {
                "label": "Anchor Validation Probe", "anchor": "diagonal",
            }},
        }, args.timeout)
        assert highlight_unknown_anchor_res["result"].get("isError") is True, highlight_unknown_anchor_res
        assert highlight_unknown_anchor_res["result"]["content"][0]["text"] == highlight_unknown_anchor_reject_text

        for anchor_value in ("element", "none"):
            highlight_resize_res = send_request(proc, reader, {
                "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
                "params": {"name": "highlight_element", "arguments": {
                    "label": "Anchor Validation Probe", "anchor": anchor_value, "anchor_resize": "scale",
                }},
            }, args.timeout)
            assert highlight_resize_res["result"].get("isError") is True, (anchor_value, highlight_resize_res)
            assert highlight_resize_res["result"]["content"][0]["text"] == anchor_resize_reject_text, anchor_value

        # anchor omitted defaults to "element" (MCP_SURFACE.md's default
        # table -- the opposite default from every draw_* tool), so
        # anchor_resize must be rejected identically even with no explicit
        # anchor argument at all.
        highlight_default_anchor_resize_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "highlight_element", "arguments": {
                "label": "Anchor Validation Probe", "anchor_resize": "pin",
            }},
        }, args.timeout)
        assert highlight_default_anchor_resize_res["result"].get("isError") is True, highlight_default_anchor_resize_res
        assert highlight_default_anchor_resize_res["result"]["content"][0]["text"] == anchor_resize_reject_text

        print("\n11. Testing 'list_annotations' omits the anchor key entirely for an unanchored drawing...", flush=True)
        unanchored_probe_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_path", "arguments": {
                "path_data": "M 5 5 L 15 15", "app": "", "stroke_color": "#123456",
            }},
        }, args.timeout)
        unanchored_probe_text = unanchored_probe_res["result"]["content"][0]["text"]
        unanchored_probe_id = unanchored_probe_text.split("annotation: ", 1)[1].split()[0]
        unanchored_list_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "list_annotations", "arguments": {}},
        }, args.timeout)
        unanchored_list = json.loads(unanchored_list_res["result"]["content"][0]["text"])["annotations"]
        unanchored_entry = next((a for a in unanchored_list if a.get("id") == unanchored_probe_id), None)
        assert unanchored_entry is not None, unanchored_list
        # The contract is "omitted, never null": an agent branches on
        # presence alone, so a stray `"anchor": null` would be just as much
        # of a regression as a fabricated `{"mode": "none"}` placeholder.
        assert "anchor" not in unanchored_entry, (
            f"an ordinary unanchored annotation must OMIT the anchor key entirely: {unanchored_entry!r}"
        )

        print("\n12. Testing 'get_overlay_state' still reports anchorTracking correctly after resume_annotations' kick()...", flush=True)
        overlay_state_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_overlay_state", "arguments": {}},
        }, args.timeout)
        overlay_state = json.loads(overlay_state_res["result"]["content"][0]["text"])
        assert "anchorTracking" in overlay_state, overlay_state
        anchor_tracking = overlay_state["anchorTracking"]
        assert set(anchor_tracking.keys()) == {
            "anchored", "tracking", "hidden", "lost", "sampleIntervalMs", "lastSampleAgeMs",
        }, anchor_tracking
        # No call anywhere in this script ever creates a REAL window anchor
        # (every anchor="window" request above is a deterministic rejection),
        # so every count must still be exactly zero and no sampling timer is
        # running -- sampleIntervalMs must still serialize as real JSON null
        # (parsed here to Python None). But section 6a's resume_annotations
        # already called AnchorTracker.shared.kick() (see
        # OverlayWindowController.setAnnotationsSuspended's doc comment: every
        # resume kicks one immediate sample so a moved window is corrected
        # promptly), and performTick() records lastTickAt even when there is
        # nothing anchored to sample -- so unlike section 2a's genuinely
        # first-ever check above, lastSampleAgeMs here is a real, present,
        # non-negative JSON number, NOT null. Together, 2a and this section
        # pin BOTH serializations of the same optional field.
        assert anchor_tracking["anchored"] == 0, anchor_tracking
        assert anchor_tracking["tracking"] == 0, anchor_tracking
        assert anchor_tracking["hidden"] == 0, anchor_tracking
        assert anchor_tracking["lost"] == 0, anchor_tracking
        assert anchor_tracking["sampleIntervalMs"] is None, anchor_tracking
        assert isinstance(anchor_tracking["lastSampleAgeMs"], int) and anchor_tracking["lastSampleAgeMs"] >= 0, (
            anchor_tracking
        )

        print("\n13. Testing 'get_annotation_bounds' backing-pixel geometry, screenshot-space scaling, and the both-or-neither rejection...", flush=True)
        bounds_rect = {"x": 80, "y": 60, "width": 160, "height": 100}
        bounds_draw_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_shape", "arguments": {
                "shape": "rect",
                "x": bounds_rect["x"], "y": bounds_rect["y"],
                "width": bounds_rect["width"], "height": bounds_rect["height"],
                "stroke_width": 0, "fill_color": "#00FF00", "fill_opacity": 1,
                "app": "",
            }},
        }, args.timeout)
        bounds_draw_text = bounds_draw_res["result"]["content"][0]["text"]
        bounds_annotation_id = bounds_draw_text.split("annotation: ", 1)[1].split()[0]

        def bounds_rect_close(actual, expected, tolerance, context):
            for key in ("x", "y", "width", "height"):
                assert abs(actual[key] - expected[key]) <= tolerance, (key, actual, expected, context)

        backing_bounds_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {
                "annotation_id": bounds_annotation_id,
            }},
        }, args.timeout)
        assert not backing_bounds_res["result"].get("isError", False), backing_bounds_res
        backing_bounds = json.loads(backing_bounds_res["result"]["content"][0]["text"])
        print("get_annotation_bounds (backing only):", json.dumps(backing_bounds, sort_keys=True), flush=True)
        assert backing_bounds["annotationId"] == bounds_annotation_id
        assert backing_bounds["screenId"] == main_screen["id"]
        assert "anchor" not in backing_bounds, "a plain fill-only rect has no anchor to report"
        # A fill-only rect (stroke_width=0) painted at an integer backing-pixel
        # rect should come back matching the drawn geometry almost exactly;
        # the small tolerance only absorbs edge anti-aliasing.
        bounds_rect_close(backing_bounds["paintedBoundsBackingPx"], bounds_rect, 1.5, "fill-only rect, no stroke overflow")

        both_or_neither_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {
                "annotation_id": bounds_annotation_id, "screenshot_width": preview_width,
            }},
        }, args.timeout)
        assert both_or_neither_res["result"].get("isError") is True, both_or_neither_res
        assert both_or_neither_res["result"]["content"][0]["text"] == (
            "Error: screenshot_width and screenshot_height must be supplied together (both, or neither): "
            "one is meaningless without the other for mapping bounds into that screenshot's pixel space."
        )

        screenshot_bounds_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {
                "annotation_id": bounds_annotation_id,
                "screenshot_width": preview_width, "screenshot_height": preview_height,
            }},
        }, args.timeout)
        assert not screenshot_bounds_res["result"].get("isError", False), screenshot_bounds_res
        screenshot_bounds = json.loads(screenshot_bounds_res["result"]["content"][0]["text"])
        scale_x = preview_width / main_screen["widthPx"]
        scale_y = preview_height / main_screen["heightPx"]
        assert abs(screenshot_bounds["screenshotScale"]["x"] - scale_x) < 1e-9
        assert abs(screenshot_bounds["screenshotScale"]["y"] - scale_y) < 1e-9
        expected_screenshot_rect = {
            "x": backing_bounds["paintedBoundsBackingPx"]["x"] * scale_x,
            "y": backing_bounds["paintedBoundsBackingPx"]["y"] * scale_y,
            "width": backing_bounds["paintedBoundsBackingPx"]["width"] * scale_x,
            "height": backing_bounds["paintedBoundsBackingPx"]["height"] * scale_y,
        }
        bounds_rect_close(
            screenshot_bounds["paintedBoundsScreenshotPx"], expected_screenshot_rect, 1.5, "screenshot-space scaling"
        )

        print("\n13a. Testing the target_bounds_screenshot_px offset-correction round trip actually closes the placement loop...", flush=True)
        painted_screenshot = screenshot_bounds["paintedBoundsScreenshotPx"]
        target_bounds_screenshot_px = {
            "x": painted_screenshot["x"] + 30, "y": painted_screenshot["y"] + 20,
            "width": painted_screenshot["width"], "height": painted_screenshot["height"],
        }
        correction_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {
                "annotation_id": bounds_annotation_id,
                "screenshot_width": preview_width, "screenshot_height": preview_height,
                "target_bounds_screenshot_px": target_bounds_screenshot_px,
            }},
        }, args.timeout)
        assert not correction_res["result"].get("isError", False), correction_res
        correction_payload = json.loads(correction_res["result"]["content"][0]["text"])
        print("get_annotation_bounds correction:", json.dumps(correction_payload, sort_keys=True), flush=True)
        assert abs(correction_payload["targetDeltaScreenshotPx"]["dx"] - 30) < 0.05
        assert abs(correction_payload["targetDeltaScreenshotPx"]["dy"] - 20) < 0.05
        correction = correction_payload["correctionBackingPx"]
        assert isinstance(correction["offsetX"], (int, float))
        assert isinstance(correction["offsetY"], (int, float))

        # THE round trip: feed the ABSOLUTE offset_x/offset_y straight into
        # update_annotation exactly as an agent would (these REPLACE the
        # stored offset; they are not a delta to add), then re-query bounds
        # and confirm the painted centre actually landed on the target. This
        # is what proves the whole "verify placement without the overlay in
        # your screenshot" loop closes end to end, not just that the
        # arithmetic is self-consistent.
        apply_correction_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "update_annotation", "arguments": {
                "annotation_id": bounds_annotation_id,
                "offset_x": correction["offsetX"], "offset_y": correction["offsetY"],
            }},
        }, args.timeout)
        assert not apply_correction_res["result"].get("isError", False), apply_correction_res
        # Unanchored annotations keep update_annotation's plain-text response
        # byte-for-byte -- the same regression guard as draw_*'s own
        # unanchored response (see section 14 below).
        assert apply_correction_res["result"]["content"][0]["text"] == f"Updated annotation {bounds_annotation_id} in place."

        reverify_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {
                "annotation_id": bounds_annotation_id,
                "screenshot_width": preview_width, "screenshot_height": preview_height,
            }},
        }, args.timeout)
        assert not reverify_res["result"].get("isError", False), reverify_res
        reverified_rect = json.loads(reverify_res["result"]["content"][0]["text"])["paintedBoundsScreenshotPx"]
        reverified_center = (
            reverified_rect["x"] + reverified_rect["width"] / 2,
            reverified_rect["y"] + reverified_rect["height"] / 2,
        )
        target_center = (
            target_bounds_screenshot_px["x"] + target_bounds_screenshot_px["width"] / 2,
            target_bounds_screenshot_px["y"] + target_bounds_screenshot_px["height"] / 2,
        )
        assert abs(reverified_center[0] - target_center[0]) <= 1.5, (reverified_center, target_center)
        assert abs(reverified_center[1] - target_center[1]) <= 1.5, (reverified_center, target_center)

        print("\n13b. Testing draw-time annotation collision avoidance with exact renderer bounds...", flush=True)
        # Put an opaque, fill-only highlight at the display centre, then
        # deliberately ask a text label (with an opaque background) to begin
        # inside it. Centre placement leaves room on every side without
        # assuming a particular monitor resolution; assertions below compare
        # only rectangles returned by the live renderer, never font metrics.
        avoid_rect_width = min(140, max(80, main_screen["widthPx"] // 6))
        avoid_rect_height = min(90, max(60, main_screen["heightPx"] // 7))
        avoid_rect = {
            "x": (main_screen["widthPx"] - avoid_rect_width) / 2,
            "y": (main_screen["heightPx"] - avoid_rect_height) / 2,
            "width": avoid_rect_width,
            "height": avoid_rect_height,
        }
        avoid_shape_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_shape", "arguments": {
                "shape": "rect", **avoid_rect,
                "stroke_width": 0, "fill_color": "#4169E1", "fill_opacity": 1,
                "app": "",
            }},
        }, args.timeout)
        assert not avoid_shape_res["result"].get("isError", False), avoid_shape_res
        avoid_shape_text = avoid_shape_res["result"]["content"][0]["text"]
        avoid_shape_id = avoid_shape_text.split("annotation: ", 1)[1].split()[0]

        avoid_text_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_text", "arguments": {
                # An opaque backing rectangle makes the requested painted
                # bounds unquestionably overlap the fill-only highlight,
                # independent of glyph ascent/descent on this machine.
                "text": "Avoid", "x": avoid_rect["x"] + 4, "y": avoid_rect["y"] + 4,
                "font_size": 18, "color": "#FFFFFF",
                "background_color": "#000000", "background_opacity": 1, "padding_px": 4,
                "avoid": [avoid_shape_id], "app": "",
            }},
        }, args.timeout)
        assert not avoid_text_res["result"].get("isError", False), avoid_text_res
        avoid_text_payload = json.loads(avoid_text_res["result"]["content"][0]["text"])
        avoid_text_id = avoid_text_payload["annotationId"]
        placement = avoid_text_payload["placement"]
        assert avoid_text_payload["message"] == (
            f"Created text annotation: {avoid_text_id} (GLOBAL: visible over every app)"
        )
        assert placement["avoidedAnnotationIds"] == [avoid_shape_id]
        assert placement["moved"] is True, placement
        assert placement["placement"] in {"below", "above", "right", "left"}, placement
        assert placement["gapPx"] == 8, placement
        assert placement["scope"] == "draw_time_snapshot", placement
        assert set(placement["offsetBackingPx"]) == {"x", "y"}, placement
        assert any(abs(placement["offsetBackingPx"][axis]) > 0 for axis in ("x", "y")), placement

        avoid_shape_bounds_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {"annotation_id": avoid_shape_id}},
        }, args.timeout)
        avoid_text_bounds_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "get_annotation_bounds", "arguments": {"annotation_id": avoid_text_id}},
        }, args.timeout)
        assert not avoid_shape_bounds_res["result"].get("isError", False), avoid_shape_bounds_res
        assert not avoid_text_bounds_res["result"].get("isError", False), avoid_text_bounds_res
        avoid_shape_bounds = json.loads(avoid_shape_bounds_res["result"]["content"][0]["text"])["paintedBoundsBackingPx"]
        avoid_text_bounds = json.loads(avoid_text_bounds_res["result"]["content"][0]["text"])["paintedBoundsBackingPx"]

        def rects_intersect(first, second):
            return (
                first["x"] < second["x"] + second["width"]
                and first["x"] + first["width"] > second["x"]
                and first["y"] < second["y"] + second["height"]
                and first["y"] + first["height"] > second["y"]
            )

        assert not rects_intersect(avoid_shape_bounds, avoid_text_bounds), (
            "the final live-renderer bounds must be disjoint, regardless of font metrics",
            avoid_shape_bounds,
            avoid_text_bounds,
            placement,
        )
        for key in ("x", "y", "width", "height"):
            assert abs(placement["paintedBoundsBackingPx"][key] - avoid_text_bounds[key]) <= 1.5, (
                key,
                placement,
                avoid_text_bounds,
            )

        # A missing avoided annotation rejects before storage. Snapshot the
        # whole ID set around the request, so this proves atomicity rather
        # than merely inspecting an error string.
        before_missing_avoid_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "list_annotations", "arguments": {}},
        }, args.timeout)
        before_missing_avoid_ids = {
            annotation["id"]
            for annotation in json.loads(before_missing_avoid_res["result"]["content"][0]["text"])["annotations"]
        }
        missing_avoid_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "draw_text", "arguments": {
                "text": "Missing target", "x": avoid_rect["x"], "y": avoid_rect["y"],
                "font_size": 18, "avoid": ["does-not-exist"], "app": "",
            }},
        }, args.timeout)
        assert missing_avoid_res["result"].get("isError") is True, missing_avoid_res
        missing_avoid_text = missing_avoid_res["result"]["content"][0]["text"]
        assert "avoid" in missing_avoid_text and "do not exist" in missing_avoid_text, missing_avoid_text
        assert "Nothing was drawn" in missing_avoid_text, missing_avoid_text
        after_missing_avoid_res = send_request(proc, reader, {
            "jsonrpc": "2.0", "id": _next_id(), "method": "tools/call",
            "params": {"name": "list_annotations", "arguments": {}},
        }, args.timeout)
        after_missing_avoid_ids = {
            annotation["id"]
            for annotation in json.loads(after_missing_avoid_res["result"]["content"][0]["text"])["annotations"]
        }
        assert after_missing_avoid_ids == before_missing_avoid_ids, (
            "a missing avoid ID must reject atomically without creating a partial annotation",
            before_missing_avoid_ids,
            after_missing_avoid_ids,
        )

        print("\n14. Testing every UNANCHORED draw_*/update_annotation response stays byte-identical plain text (no JSON)...", flush=True)
        # Existing callers -- including this very script's `"annotation: "`
        # splitting above -- parse this response as a bare string, so an
        # unanchored call silently switching to a JSON payload is a real
        # regression, not a cosmetic change.
        for tool_label, response_text in [
            ("draw_path (section 3)", path_text),
            ("draw_shape (section 3a)", shape_text),
            ("draw_image (section 4)", image_res["result"]["content"][0]["text"]),
            ("draw_text (section 5)", text_draw_message),
            ("draw_path (section 11 probe)", unanchored_probe_text),
            ("draw_shape (section 13 probe)", bounds_draw_text),
        ]:
            assert isinstance(response_text, str) and response_text.startswith("Created "), (tool_label, response_text)
            try:
                json.loads(response_text)
            except json.JSONDecodeError:
                pass
            else:
                raise AssertionError(
                    f"{tool_label}'s unanchored response parsed as JSON; it must remain plain text "
                    f"since existing callers parse it with a bare string split: {response_text!r}"
                )

        print("\nAll draw, shape, collision-avoidance, suspension/resume, persistence-metadata, annotation-list, image-verification, explicit-clear, window-anchoring-validation, and annotation-bounds MCP tests PASSED!", flush=True)
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
