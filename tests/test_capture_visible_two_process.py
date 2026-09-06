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

On Windows both the product name and the layout differ: SwiftPM writes the
triple-qualified directory and cannot create the `.build/debug` convenience
symlink, so the path above simply does not exist there. Use:

  .build/x86_64-unknown-windows-msvc/debug/AIChalkboard.exe

A Windows run still covers the broadcast and the flag, but not the applied
window state -- the sharingType read-back below is darwin-only.
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
# Mirrors CaptureExclusionPolicy.Decision.excludesFromCapture (:322-328) on the
# wire. This is the INDEPENDENT anchor that keeps the sharingType check below
# honest. That check compares overlays[].sharingType against
# captureExclusion.excludesFromCapture, and both would move together if the
# switch itself were broken -- e.g. `.exclude` wrongly returning false would
# leave overlays capturable on an ordinary desktop while baseline expected and
# observed both read "readOnly", passing green. Pinning what each REASON CODE
# implies catches that, because the reason code comes from a different arm of
# the same enum than the boolean does.
EXCLUDES_FOR_REASON = {
    "excluded": True,
    "excluded-forced-by-environment": True,
    "included-capture-debug": False,
    "included-suppressed-by-environment": False,
    "included-suppressed-remote-session": False,
}

# Derived rather than repeated, so the two cannot drift apart.
KNOWN_REASON_CODES = frozenset(EXCLUDES_FOR_REASON)

# The one assertion in this file that a flag cannot fake: `overlays[].sharingType`
# in `get_overlay_state` is a live read-back of what the OS reports for each
# overlay window, so it shows the broadcast actually reconciled window capture
# affinity rather than merely setting a boolean a sibling echoed back. These are
# the macOS NSWindow.sharingType spellings, which is why the check is applied on
# darwin only -- the Windows port reconciles the same state through a different
# primitive and does not report these names.
#
# Keyed on `captureExclusion.excludesFromCapture`, NOT on capture-debug. Those
# are different questions, and conflating them was a live false failure rather
# than a hypothetical one:
#
#     sharingType      = includeInCapture ? .readOnly : .none   (Presentation:621)
#     includeInCapture = !decision.excludesFromCapture          (Presentation:146)
#     excludesFromCapture == false for .includeForCaptureDebug,
#         .includeSuppressedByEnvironment, .includeSuppressedForRemoteSession
#                                                 (CaptureExclusionPolicy:322-328)
#
# Capture-debug is therefore only ONE of three ways a window stays capturable.
# With capture-debug OFF but exclusion SUPPRESSED -- a Mac running any host in
# `knownStreamingHosts`, which the policy itself notes "CAN produce a false
# positive" when merely idling as a background service, or a shell exporting
# AI_CHALKBOARD_CAPTURE_EXCLUSION=never -- the window reports "readOnly" while a
# capture-debug-keyed table demands "none". That fired on the FIRST baseline
# assertion, so the broadcast under test was never reached at all and the message
# blamed the wrong subsystem. The decision is read from the same response now.
SHARING_TYPE_FOR_EXCLUDED = {True: "none", False: "readOnly"}


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
        if not binary.is_file():
            self.fail(f"{BINARY_ENV} is not a file: {binary}")
        # os.X_OK is meaningful only where POSIX permission bits are. On Windows
        # it returns True for any readable file, so folding both checks into one
        # condition left half this guard dead there while still reporting "not an
        # executable file" for either cause. Split, and skipped where it cannot
        # mean anything.
        if os.name != "nt" and not os.access(binary, os.X_OK):
            self.fail(f"{BINARY_ENV} is not executable: {binary}")

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
            # Pinned so the developer's shell cannot steer the very decision
            # under test: spawn_mcp_child starts from os.environ.copy(), and
            # `never` is the workaround the docs tell a remote-Mac user to
            # export, which would silently exercise a different policy branch
            # than an ordinary run. "auto" is the default spelling.
            #
            # This does NOT make the sharingType expectation constant, and is
            # not an alternative to deriving it: under "auto" a detected
            # streaming host still suppresses the exclusion, which is precisely
            # why SHARING_TYPE_FOR_EXCLUDED is keyed on the decision.
            "AI_CHALKBOARD_CAPTURE_EXCLUSION": "auto",
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

        excluded = exclusion.get("excludesFromCapture")
        self.assertIsInstance(
            excluded, bool,
            f"captureExclusion.excludesFromCapture is not a boolean: {state}",
        )
        self.assertEqual(
            excluded, EXCLUDES_FOR_REASON[reason],
            f"child {child} reports excludesFromCapture={excluded} under reason code "
            f"{reason!r}, which implies {EXCLUDES_FOR_REASON[reason]}. "
            f"CaptureExclusionPolicy.Decision.excludesFromCapture no longer agrees "
            f"with reasonCode, and the overlay sharingType check derives its "
            f"expectation from that boolean: {state}",
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

    def _wait_overlay_sharing(self, child, timeout):
        """Waits until every overlay window's live sharingType matches the exclusion decision.

        Polls rather than asserting once because this reads a SECOND tool call:
        a one-shot check could straddle the asynchronous self-echo of a broadcast
        and see the two calls' states disagree for reasons that are not defects.
        Requires at least one overlay so a process reporting no windows fails
        here instead of passing this check vacuously.

        The expectation is read from `captureExclusion.excludesFromCapture` in the
        SAME response as the windows it is compared against. That keeps this a
        real check rather than a tautology, because the two sides come from
        different places: the field is a projection of the in-memory Decision,
        while `sharingType` is a live per-window read-back of what the OS reports.
        Requiring them to agree IS the evidence that the decision reached the
        windows. Reading them together also matters -- an expectation carried over
        from an earlier call could straddle a broadcast echo, which is the same
        reason this polls at all.

        Takes no expected-visibility argument, because it asks a narrower
        question than its caller does: not "is capture-debug in the state we
        asked for" -- `_wait_capture_visible` has already established that, and
        pins reasonCode against the flag on every poll -- but "did whatever
        decision is now in force actually reach the windows". Passing the flag in
        would only invite re-deriving the expectation from it, which is the bug
        this function was fixed for.
        """
        if sys.platform != "darwin":
            return
        deadline = time.monotonic() + timeout
        last = None
        expected = None
        observed = None
        while True:
            last = self.payload(child, "get_overlay_state", {}, self._next_request_id())
            # Asserted, not tolerated: if this key ever disappears, the fallback
            # would be to guess an expectation, and a guessed expectation that
            # happens to match is exactly the silent no-op this file exists to
            # avoid. Mirrors the captureExclusion handling in _capture_visible.
            exclusion = last.get("captureExclusion")
            self.assertIsInstance(
                exclusion, dict,
                f"get_overlay_state no longer reports a captureExclusion object, so the "
                f"expected sharingType can no longer be derived: {last}",
            )
            excluded = exclusion.get("excludesFromCapture")
            self.assertIsInstance(
                excluded, bool,
                f"captureExclusion.excludesFromCapture is not a boolean: {last}",
            )
            expected = SHARING_TYPE_FOR_EXCLUDED[excluded]
            observed = [overlay.get("sharingType") for overlay in last.get("overlays") or []]
            if observed and all(value == expected for value in observed):
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        self.fail(
            f"overlay sharingType did not become {expected!r} (the exclusion decision "
            f"in the same response) on child {child} within {timeout}s "
            f"({self.child_diagnostics()}); observed={observed}; last state={last}"
        )

    def _assert_capture_visible_everywhere(self, expected):
        """Asserts both peers agree, flag and applied window state alike."""
        for child in range(len(self.children)):
            self._wait_capture_visible(child, expected, self.settle_timeout)
            self._wait_overlay_sharing(child, self.settle_timeout)

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
