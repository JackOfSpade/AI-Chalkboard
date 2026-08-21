#!/usr/bin/env python3
import argparse
import base64
import itertools
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

DEFAULT_BINARY_PATH = "./.build/release/AIChalkboard.app/Contents/MacOS/AIChalkboard"
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
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    return args


def stderr_diagnostics(drain):
    """Returns any stderr this harness's `StderrDrain` has collected from the
    child, formatted for appending to a failure message -- or "" if there is
    none. This used to read the child's stderr pipe directly, once, after the
    process had already exited; that is exactly the post-mortem-only read
    `StderrDrain`'s own doc comment explains is unsafe (a large enough
    synchronous log line can wedge the child on a full pipe before it ever
    gets that far). Draining continuously throughout the run instead, via
    `drain`, is the fix; this function's job is now just formatting whatever
    tail `drain` already collected.
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

    WHY THIS EXISTS: `MCPServer.handleToolsCall` logs one line per call,
    including a Swift debug description of the entire `arguments` value --
    and tests/mcp_wire_snapshot.py's `call_path_over_cap` fixture
    deliberately sends 10,001 points, which turns that single log line into
    several hundred KB. This harness used to read the child's stderr only
    once, at the very end, after the process had already exited (the old
    `stderr_diagnostics`) -- which was fine for fixtures that never logged
    anywhere near that much, but is exactly wrong once one does: nobody
    draining stderr while the process is still running means the child's
    write(2) into a full pipe (64 KB on macOS) blocks indefinitely, and
    since that logging call happens synchronously BEFORE the tool body
    runs, it wedges the JSON-RPC response too -- indistinguishable, from
    this script's side, from the server simply hanging. Continuously
    draining stderr throughout the run, as any reasonable MCP host's stdio
    transport would, is the actual fix; keeping only a bounded tail (not an
    unbounded read) keeps the fix itself from becoming an unbounded-memory
    version of the same problem. Every harness in this repo that spawns an
    MCP child uses this same drain now (see `spawn_mcp_child`), not just the
    fixture where the bug was first noticed.
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
    MCPLineReader, and starts a StderrDrain on it immediately -- before this
    function returns, and therefore before any request is ever sent -- so a
    large synchronous log line (see StderrDrain's doc comment) can never
    wedge the child while nothing is listening to its stderr. Returns
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
    proc, reader, stderr_drain = spawn_mcp_child(binary_path, extra_env={
        "AI_CHALKBOARD_SUSPENSION_ROOT": suspension_root,
        "AI_CHALKBOARD_SUSPENSION_NAMESPACE": f"stdio-{uuid.uuid4()}",
        "AI_CHALKBOARD_INSTANCE_LOCK_PATH": os.path.join(suspension_root, "instance.lock"),
    })

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
        assert {"draw_path", "draw_image", "draw_text", "draw_batch", "suspend_annotations", "resume_annotations", "verify_annotation", "verify_presentation"}.issubset(tools)
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
                    "duration_seconds": 60,
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
                "app": "", "duration_seconds": 60,
            }},
        }, args.timeout)
        text_draw_message = text_res["result"]["content"][0]["text"]
        print("draw_text response:", text_draw_message, flush=True)
        text_annotation_id = text_draw_message.split("annotation: ", 1)[1].split()[0]

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
        assert isinstance(image_annotation.get("expiresAt"), str)
        assert image_annotation.get("remainingSeconds", 0) > 0
        text_annotation = next((a for a in annotations if a.get("id") == text_annotation_id), None)
        assert text_annotation is not None
        assert text_annotation.get("type") == "text"
        assert any(a.get("type") == "batch" for a in annotations)

        print("\n6a. Testing temporary annotation suspension preserves the draw state...", flush=True)
        # The implementation broadcasts suspension to sibling Chalkboard
        # processes. Always send the compensating resume before continuing,
        # including when the suspend request itself times out *after* posting
        # its distributed notification. Start try/finally before sending it,
        # so this smoke test cannot leave a running desktop session hidden.
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
            assert suspended_text.get("remainingSeconds", 0) > 0, "suspension must not discard a live annotation's TTL"
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
        verification_annotation_id = None
        for app_id, x in [
            ("com.example.ClearTarget", 0.4),
            ("com.example.PreserveTarget", 0.6),
        ]:
            draw_res = send_request(proc, reader, {
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
            if app_id == "com.example.ClearTarget":
                draw_text = draw_res["result"]["content"][0]["text"]
                verification_annotation_id = draw_text.split("annotation: ", 1)[1].split()[0]

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

        print("\nAll draw, suspension/resume, expiry-metadata, annotation-list, image-verification, and explicit-clear MCP tests PASSED!", flush=True)
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
