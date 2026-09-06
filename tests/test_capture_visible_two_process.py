#!/usr/bin/env python3
"""Opt-in, real-process coverage for set_capture_visible fan-out.

This test spawns two real MCP server processes sharing one suspension namespace
so they observe each other's broadcasts. It verifies the one call that matters
for split-brain safety: a `set_capture_visible(true)` sent by one process is seen
by the other, and that both return to capture-hidden afterwards.

The environment gate prevents accidental interference with a user's live Chalkboard
session, because broadcast channels are intentionally session-wide:

  AI_CHALKBOARD_RUN_CAPTURE_VISIBLE_TWO_PROCESS_TEST=1 \
  AI_CHALKBOARD_CAPTURE_VISIBLE_TWO_PROCESS_BINARY="$PWD/.build/debug/AIChalkboard" \
  python3 -m unittest tests/test_capture_visible_two_process.py
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_mcp_stdio as mcp  # noqa: E402


RUN_GATE = "AI_CHALKBOARD_RUN_CAPTURE_VISIBLE_TWO_PROCESS_TEST"
BINARY_ENV = "AI_CHALKBOARD_CAPTURE_VISIBLE_TWO_PROCESS_BINARY"

# The capture-debug flag is read from `get_screens`, NOT from
# `get_overlay_state`. `get_overlay_state` reports the per-screen input policy
# and window state and has never carried a `captureVisible` key; reading it
# there yields None forever, which a polling loop cannot distinguish from
# "the broadcast never arrived". `get_screens` publishes the boolean directly
# (Sources/MCP/MCPToolHandlers.swift, "captureVisible": captureVisible).
STATE_TOOL = "get_screens"

# `get_screens` also carries the CaptureExclusionPolicy decision. Asserting the
# two agree is NOT proof that any window was reconciled -- `captureVisible` and
# `reasonCode` are both projections of the same in-memory Decision enum, so they
# cannot disagree within one response. What it does buy is a contract check on
# the wire strings: it catches the reason-code constant being renamed on the
# Swift side without this file being updated. The genuine "the broadcast was
# APPLIED" evidence is the per-window sharingType read-back asserted separately
# below. The equivalence is exact, not approximate, because
# CaptureExclusionPolicy.decide (Sources/Support/CaptureExclusionPolicy.swift)
# short-circuits on capture-debug ABOVE every other input:
#
#     if captureDebugVisible { return .includeForCaptureDebug }   // outranks all
#     switch override { .never -> includeSuppressedByEnvironment
#                       .always -> exclude / excludeForcedByEnvironment
#                       .auto   -> exclude / includeSuppressedForRemoteSession }
#
# so `.includeForCaptureDebug` appears if and only if capture-debug is on --
# regardless of AI_CHALKBOARD_CAPTURE_EXCLUSION or remote-session detection.
CAPTURE_DEBUG_REASON_CODE = "included-capture-debug"

# Asserting membership rather than just inequality means a renamed or newly
# added reason code fails loudly here instead of being silently read as
# "capture-debug is off", which would let this test pass while measuring nothing.
KNOWN_REASON_CODES = frozenset({
    "excluded",
    "excluded-forced-by-environment",
    "included-capture-debug",
    "included-suppressed-by-environment",
    "included-suppressed-remote-session",
})

# The one assertion in this file that a flag cannot fake: `overlays[].sharingType`
# in `get_overlay_state` is a live read-back of what the OS reports for each
# overlay window, so it shows the broadcast actually reconciled window capture
# affinity rather than merely setting a boolean a sibling echoed back. These are
# the macOS NSWindow.sharingType spellings, which is why the check is applied on
# darwin only -- the Windows port reconciles the same state through a different
# primitive and does not report these names.
SHARING_TYPE_FOR_VISIBLE = {True: "readOnly", False: "none"}


@unittest.skipUnless(
    os.environ.get(RUN_GATE) == "1" and os.environ.get(BINARY_ENV),
    "requires explicit capture-visible two-process opt-in and disposable MCP binary",
)
class CaptureVisibleTwoProcessIntegrationTests(unittest.TestCase):
    timeout = 10.0
    # Fan-out rides DistributedNotificationCenter, not a poll: measured
    # sibling-visible latency is ~25ms here and InstanceBroadcast documents
    # ~1.4-2.6ms delivery. This ceiling therefore has ~100x headroom, and keeps
    # a genuine propagation failure a fast, deterministic assertion failure
    # rather than a hang.
    settle_timeout = 2.5

    def setUp(self):
        binary = Path(os.environ[BINARY_ENV]).resolve()
        if not binary.is_file() or not os.access(binary, os.X_OK):
            self.fail(f"{BINARY_ENV} is not an executable file: {binary}")

        self.tempdir = tempfile.mkdtemp(prefix="ai-chalkboard-capture-visible-it-")
        # Registered IMMEDIATELY, and likewise for each child below, because
        # tearDown does not run when setUp itself fails -- and setUp asserts on
        # the initialize result AFTER spawning two real AppKit processes.
        # Without addCleanup, one failed assertion here would leak both children
        # and this directory for the rest of the session. This mirrors
        # tests/test_suspension_two_process.py.
        self.addCleanup(shutil.rmtree, self.tempdir, ignore_errors=True)

        self.namespace = f"it-{uuid.uuid4()}"
        self.children = []
        self.readers = []
        self.drains = []
        # Which drains have already had their tail reported, so the cleanup
        # path and tearDown -- which both cover every drain on an ordinary
        # passing run -- do not print the same child's stderr twice.
        self.reported_drains = set()
        self._request_id = 1_000

        # Both children intentionally share this exact env: the behaviour under
        # test is two peers in the SAME isolated broadcast domain. This is the
        # documented reason two-process tests hand-roll these keys instead of
        # calling mcp.isolated_suspension_env, which mints a fresh uuid4 per call
        # and would put the peers in separate domains. The lock file must be
        # named exactly "instance.lock" under a temp directory or InstanceLock
        # silently falls back to the production path -- i.e. to the user's live
        # session.
        extra_env = {
            "AI_CHALKBOARD_SUSPENSION_ROOT": self.tempdir,
            "AI_CHALKBOARD_SUSPENSION_NAMESPACE": self.namespace,
            "AI_CHALKBOARD_INSTANCE_LOCK_PATH": os.path.join(self.tempdir, "instance.lock"),
            # Without this, both children write into the user's REAL
            # ~/Library/Logs/AIChalkboard/ai_chalkboard.log and consume its
            # rotation budget: Logger falls back to the production directory
            # unless this absolute override is set, and TestHarness.isActive
            # cannot help here because it detects an XCTest bundle -- a binary
            # spawned as a plain subprocess looks exactly like the real app.
            "AI_CHALKBOARD_LOG_DIR": os.path.join(self.tempdir, "logs"),
        }

        for _ in range(2):
            proc, reader, drain = mcp.spawn_mcp_child(str(binary), extra_env=extra_env)
            index = len(self.children)
            # Registered in the reverse of the order they must run, because
            # addCleanup fires LIFO: terminate -> report stderr -> close.
            # Close must come last: closing proc.stderr while the drain thread
            # is still inside os.read on that fd races the close, and reporting
            # must follow terminate because terminate is what makes the drain
            # see EOF. All three are idempotent, so tearDown's own pass over the
            # same children on the success path stays correct.
            self.addCleanup(self.close_child_pipes, proc)
            self.addCleanup(self._report_child_stderr, index, drain)
            self.addCleanup(mcp.terminate_child, proc)
            self.children.append(proc)
            self.readers.append(reader)
            self.drains.append(drain)

        for index in range(len(self.children)):
            # `initialize` is a TOP-LEVEL JSON-RPC method, not a tool. Sent
            # through the tools/call envelope it lands in the tool dispatcher's
            # default branch and comes back as `Unknown tool: initialize` with
            # isError -- a handshake that never happened, silently.
            response = self.call(
                index, "initialize", {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "capture-visible-two-process-test", "version": "1"},
                }, request_id=self._next_request_id(), raw_method=True,
            )
            self.assertIn("result", response, self.child_diagnostics())

    def tearDown(self):
        for child in range(len(self.children)):
            if self.children[child].poll() is not None:
                continue
            try:
                self._set_capture_visible(child, False)
            except (RuntimeError, TimeoutError, OSError, ValueError) as error:
                # Best-effort: swallowed so one flaky reset cannot fail an
                # otherwise-passing test, but printed so a consistently failing
                # reset is visible instead of vanishing. Deliberately NOT a bare
                # `except Exception`, which would also swallow the AssertionError
                # _set_capture_visible raises on a genuine isError response.
                # OSError covers BrokenPipeError; ValueError covers a write to an
                # already-closed stdin, which the ordering here should prevent but
                # which must not be able to mask a real failure if it ever does.
                print(
                    f"warning: capture-visible two-process cleanup "
                    f"set_capture_visible(false) failed for child {child}: {error}",
                    file=sys.stderr,
                    flush=True,
                )
        for proc in self.children:
            mcp.terminate_child(proc)
        # Between terminate and close, deliberately -- see _report_child_stderr.
        for index, drain in enumerate(self.drains):
            self._report_child_stderr(index, drain)
        for proc in self.children:
            self.close_child_pipes(proc)

    def _report_child_stderr(self, index, drain):
        """Joins one child's drain thread and prints whatever tail it collected.

        Shared by tearDown and by the per-child cleanup setUp registers, so the
        two teardown paths cannot drift: both must run this AFTER terminate_child
        (which is what makes the drain thread see EOF) and BEFORE
        close_child_pipes. Idempotent, because on a passing run both paths cover
        every drain.
        """
        if drain in self.reported_drains:
            return
        self.reported_drains.add(drain)
        tail = drain.join_and_get_tail(timeout=mcp.SHUTDOWN_TIMEOUT_SECONDS).strip()
        if tail:
            print(f"child {index} stderr:\n{tail}", file=sys.stderr, flush=True)

    @staticmethod
    def close_child_pipes(proc):
        for pipe in (proc.stdin, proc.stdout, proc.stderr):
            if pipe:
                pipe.close()

    def child_diagnostics(self):
        # PID and exit status only. Each child's stderr is collected
        # continuously by its StderrDrain and printed by _report_child_stderr
        # once the children have been terminated.
        return "; ".join(f"pid={proc.pid} status={proc.poll()}" for proc in self.children)

    def call(self, child, name, arguments, request_id, raw_method=False):
        if raw_method:
            request = {"jsonrpc": "2.0", "id": request_id, "method": name, "params": arguments}
        else:
            request = {
                "jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }
        return mcp.send_request(self.children[child], self.readers[child], request, self.timeout)

    def payload(self, child, name, arguments, request_id):
        response = self.call(child, name, arguments, request_id)
        result = response.get("result", {})
        self.assertFalse(result.get("isError", False), response)
        return json.loads(result["content"][0]["text"])

    def _next_request_id(self):
        request_id = self._request_id
        self._request_id += 1
        return request_id

    def _set_capture_visible(self, child, visible):
        response = self.call(
            child, "set_capture_visible", {"visible": visible}, self._next_request_id()
        )
        result = response.get("result", {})
        self.assertFalse(result.get("isError", False), response)
        self.assertIn("content", result, response)

    def _capture_visible(self, child):
        """Reads one child's live capture-debug state, returning (visible, state)."""
        state = self.payload(child, STATE_TOOL, {}, self._next_request_id())
        visible = state.get("captureVisible")
        self.assertIsInstance(
            visible, bool,
            f"{STATE_TOOL} no longer reports a boolean captureVisible; this test "
            f"can no longer observe capture-debug state: {state}",
        )

        # Asserted, not skipped when absent: a conditional cross-check would
        # silently stop checking anything the day the field is renamed, which is
        # the exact failure mode KNOWN_REASON_CODES exists to prevent.
        exclusion = state.get("captureExclusion")
        self.assertIsInstance(
            exclusion, dict,
            f"{STATE_TOOL} no longer reports a captureExclusion object: {state}",
        )
        reason = exclusion.get("reasonCode")
        self.assertIn(
            reason, KNOWN_REASON_CODES,
            f"unrecognised captureExclusion.reasonCode {reason!r}; "
            f"CaptureExclusionPolicy.Decision.reasonCode changed: {state}",
        )
        self.assertEqual(
            reason == CAPTURE_DEBUG_REASON_CODE, visible,
            f"child {child} reports captureVisible={visible} but its capture-exclusion "
            f"reason code is {reason!r}: the two projections of one Decision "
            f"disagree, so the wire contract has changed: {state}",
        )
        return visible, state

    def _wait_capture_visible(self, child, expected, timeout):
        deadline = time.monotonic() + timeout
        last = None
        while True:
            visible, last = self._capture_visible(child)
            if visible == expected:
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        self.fail(
            f"captureVisible did not become {expected} on child {child} within "
            f"{timeout}s ({self.child_diagnostics()}); last state={last}"
        )

    def _wait_overlay_sharing(self, child, expected_visible, timeout):
        """Waits until every overlay window's live sharingType matches capture-debug.

        Polls rather than asserting once because this reads a SECOND tool call:
        a one-shot check could straddle the asynchronous self-echo of a broadcast
        and see the two calls' states disagree for reasons that are not defects.
        Requires at least one overlay so a process reporting no windows fails
        here instead of passing this check vacuously.
        """
        if sys.platform != "darwin":
            return
        expected = SHARING_TYPE_FOR_VISIBLE[expected_visible]
        deadline = time.monotonic() + timeout
        last = None
        while True:
            last = self.payload(child, "get_overlay_state", {}, self._next_request_id())
            observed = [overlay.get("sharingType") for overlay in last.get("overlays") or []]
            if observed and all(value == expected for value in observed):
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        self.fail(
            f"overlay sharingType did not become {expected!r} on child {child} within "
            f"{timeout}s ({self.child_diagnostics()}); observed={observed}; last state={last}"
        )

    def _assert_capture_visible_everywhere(self, expected):
        """Asserts both peers agree, flag and applied window state alike."""
        for child in range(len(self.children)):
            self._wait_capture_visible(child, expected, self.settle_timeout)
            self._wait_overlay_sharing(child, expected, self.settle_timeout)

    def test_set_capture_visible_broadcast_reaches_sibling(self):
        # Baseline. This also proves the assertion below is not vacuous: if
        # capture-debug were somehow already on, a later "it is on" check would
        # prove nothing about the broadcast.
        self._assert_capture_visible_everywhere(False)

        # Child 0 applies locally before responding; child 1 can only learn
        # through the broadcast, which is the property under test.
        self._set_capture_visible(0, True)
        self._assert_capture_visible_everywhere(True)

        # Waiting for the SIBLING to observe True before sending False matters:
        # a process also receives its own broadcast echo asynchronously, and
        # sending both edges back-to-back lets the earlier `visible=true` echo
        # land after `false` was already applied locally and revert it.
        self._set_capture_visible(0, False)
        self._assert_capture_visible_everywhere(False)
