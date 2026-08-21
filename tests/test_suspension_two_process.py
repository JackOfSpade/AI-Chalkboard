#!/usr/bin/env python3
"""Opt-in, real-process coverage for the suspension lease protocol.

This is deliberately *not* part of the ordinary unit-test run.  It creates
two actual AppKit/MCP processes, which means it needs an Aqua WindowServer and
would otherwise be far too easy to aim at a person's live Chalkboard setup.
The explicit environment gate also prevents this test from ever using the
production DistributedNotificationCenter name or Application Support state.

Run only against an expendable build, for example:

  AI_CHALKBOARD_RUN_TWO_PROCESS_TEST=1 \\
  AI_CHALKBOARD_SUSPENSION_TWO_PROCESS_BINARY="$PWD/.build/debug/AIChalkboard" \\
  python3 -m unittest tests/test_suspension_two_process.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_mcp_stdio as mcp  # noqa: E402


RUN_GATE = "AI_CHALKBOARD_RUN_TWO_PROCESS_TEST"
BINARY_ENV = "AI_CHALKBOARD_SUSPENSION_TWO_PROCESS_BINARY"


@unittest.skipUnless(
    os.environ.get(RUN_GATE) == "1" and os.environ.get(BINARY_ENV),
    "requires explicit two-process opt-in and disposable MCP binary",
)
class SuspensionTwoProcessIntegrationTests(unittest.TestCase):
    """Uses only randomized test state/transport and only kills its children."""

    timeout = 10.0

    def setUp(self):
        binary = Path(os.environ[BINARY_ENV]).resolve()
        if not binary.is_file() or not os.access(binary, os.X_OK):
            self.fail(f"{BINARY_ENV} is not an executable file: {binary}")

        self.tempdir = tempfile.mkdtemp(prefix="ai-chalkboard-suspension-it-")
        # Reproduce the production directory left by InstanceLock's ordinary
        # FileManager creation path. The lease coordinator must safely tighten
        # this same-user, non-writable-by-others directory before bootstrap.
        os.chmod(self.tempdir, 0o755)
        self.namespace = f"it-{uuid.uuid4()}"
        self.children = []
        self.readers = []
        self.drains = []
        self.live_tokens = set()

        # The core deliberately reads these test-only seams before registering
        # its DNC observers.  A randomized pair guarantees this test cannot
        # signal a production Cowork process even when one happens to be open.
        # Both children below intentionally share this exact same env (same
        # namespace, same coordinator root): the two-process behavior under
        # test is two peers in the SAME isolated domain, not two isolated
        # domains.
        extra_env = {
            "AI_CHALKBOARD_SUSPENSION_ROOT": self.tempdir,
            "AI_CHALKBOARD_SUSPENSION_NAMESPACE": self.namespace,
            # A test invocation must not accidentally make a process eligible
            # to become the user's regular menu-bar instance through a shared
            # lock.
            "AI_CHALKBOARD_INSTANCE_LOCK_PATH": os.path.join(self.tempdir, "instance.lock"),
        }

        for _ in range(2):
            proc, reader, drain = mcp.spawn_mcp_child(str(binary), extra_env=extra_env)
            self.children.append(proc)
            self.readers.append(reader)
            self.drains.append(drain)

        for index in range(2):
            response = self.call(index, "initialize", {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "suspension-two-process-test", "version": "1"},
            }, request_id=10 + index, raw_method=True)
            self.assertIn("result", response, self.child_diagnostics())

        self.assertEqual(os.stat(self.tempdir).st_mode & 0o777, 0o700)
        for index in range(2):
            state = self.payload(index, "get_overlay_state", {}, 20 + index)
            self.assertTrue(state["suspensionRegistryBootstrapped"], state)
            self.assertIsNone(state["suspensionRegistryError"], state)

    def tearDown(self):
        # Leases are global to the isolated coordinator.  Release every token
        # from a surviving child before termination, including a token returned
        # by an operation whose subsequent assertion failed.  The handler's
        # idempotent release makes bounded retries safe.
        if self.children:
            for token in list(self.live_tokens):
                for attempt in range(3):
                    if self.children[0].poll() is not None:
                        break
                    try:
                        response = self.call(0, "resume_annotations", {"lease_token": token},
                                             request_id=800 + attempt)
                        result = response.get("result", {})
                        if not result.get("isError", False):
                            break
                    except (RuntimeError, TimeoutError, BrokenPipeError) as error:
                        # Best-effort cleanup: still swallowed so one flaky
                        # release attempt cannot fail an otherwise-passing
                        # test, but printed so a real regression here (e.g.
                        # the release call consistently failing, not just a
                        # single transient timeout) is visible in the test
                        # log instead of vanishing silently.
                        print(
                            f"warning: resume_annotations cleanup attempt {attempt + 1} "
                            f"for token {token!r} failed: {error}",
                            file=sys.stderr,
                            flush=True,
                        )
            self.live_tokens.clear()

        for proc in self.children:
            mcp.terminate_child(proc)
        for proc in self.children:
            if proc.stdin:
                proc.stdin.close()
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()
        shutil.rmtree(self.tempdir, ignore_errors=True)

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

    def child_diagnostics(self):
        # Do not call .read while a child is alive (it would block); failure
        # output is obtained after mcp.terminate_child in tearDown instead.
        return "; ".join(f"pid={proc.pid} status={proc.poll()}" for proc in self.children)

    @staticmethod
    def windowserver_on_screen(pid, window_number):
        """Ask Quartz for this exact test child PID/window-number pair.

        The test passes neither Chalkboard's name nor a broad owner match to
        WindowServer, so an unrelated live process cannot satisfy this check.
        A short Swift one-liner is used instead of PyObjC (not a project
        dependency).  Its sole output is a JSON boolean.
        """
        source = r'''
import ApplicationServices
import Foundation
let pid = Int(CommandLine.arguments[1])!
let number = Int(CommandLine.arguments[2])!
let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let found = entries.contains { entry in
    (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid &&
    (entry[kCGWindowNumber as String] as? NSNumber)?.intValue == number
}
print(found ? "true" : "false")
'''
        completed = subprocess.run(
            ["/usr/bin/swift", "-e", source, str(pid), str(window_number)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        if completed.returncode:
            raise AssertionError(f"Quartz probe failed: {completed.stderr.strip()}")
        return completed.stdout.strip() == "true"

    def assert_windows_match_windowserver(self, child, expected_on_screen):
        state = self.payload(child, "get_overlay_state", {}, 300 + child)
        for overlay in state["overlays"]:
            number = overlay.get("windowNumber")
            if number is None:
                continue
            observed = self.windowserver_on_screen(self.children[child].pid, number)
            self.assertEqual(
                observed, expected_on_screen,
                f"PID {self.children[child].pid}, window {number}: state={state}",
            )

    def test_overlapping_leases_idempotency_and_real_windowserver_quiescence(self):
        # Give each raw executable process an annotation so it owns at least
        # one overlay, then capture actual PID/window-number WindowServer
        # evidence before and after the lease transitions.
        for child in range(2):
            result = self.call(child, "draw_path", {
                "path_data": f"M {20 + child * 30} 20 L {80 + child * 30} 80",
                "stroke_color": "#ff9500", "app": "",
                "duration_seconds": 45,
            }, 100 + child)
            self.assertFalse(result.get("result", {}).get("isError", False), result)

        # AppKit registration is asynchronous.  Poll only the test-owned
        # windows, with a bounded deadline, rather than sleeping blindly.
        visible_deadline = time.monotonic() + 3
        while time.monotonic() < visible_deadline:
            states = [self.payload(i, "get_overlay_state", {}, 200 + i) for i in range(2)]
            if all(any(o.get("windowNumber") for o in state["overlays"]) for state in states):
                break
            time.sleep(0.05)
        self.assert_windows_match_windowserver(0, True)
        self.assert_windows_match_windowserver(1, True)

        key_a = str(uuid.uuid4())
        first = self.payload(0, "suspend_annotations", {
            "lease_seconds": 30, "idempotency_key": key_a,
        }, 400)
        token_a = first["leaseToken"]
        self.live_tokens.add(token_a)
        self.assertFalse(first["leaseReused"])
        self.assertTrue(first["annotationsSuspended"])
        self.assertIsInstance(first["clickSafeAtObservation"], bool)
        self.assertIsInstance(first["peerPresentationSettled"], bool)
        self.assertFalse(first["clickSafeAtObservation"] and not first["peerPresentationSettled"])
        self.assertIsInstance(first["candidatePids"], list)
        self.assertIsInstance(first["candidatePidsTruncated"], bool)
        self.assertIsInstance(first["visibleOwnerPids"], list)
        self.assertIsInstance(first["visibleWindowNumbers"], list)
        self.assertIsInstance(first["discoveryErrors"], list)

        retry = self.payload(0, "suspend_annotations", {
            "lease_seconds": 30, "idempotency_key": key_a,
        }, 401)
        self.assertEqual(retry["leaseToken"], token_a)
        self.assertTrue(retry["leaseReused"])
        self.assertEqual(retry["activeLeaseCount"], 1)

        # A retry key is scoped to the process that created it. Another MCP
        # process must neither receive its bearer token nor create a second
        # lease under the colliding key. Use the raw result because `payload`
        # intentionally rejects MCP errors.
        cross_process = self.call(1, "suspend_annotations", {
            "lease_seconds": 30, "idempotency_key": key_a,
        }, 402)
        cross_result = cross_process.get("result", {})
        self.assertTrue(cross_result.get("isError", False), cross_process)
        cross_payload = json.loads(cross_result["content"][0]["text"])
        self.assertNotIn("leaseToken", cross_payload)
        self.assertIn("another Chalkboard process", cross_payload.get("error", ""))

        # The creator's retry is still the one original lease. This confirms
        # the rejected cross-process call left the durable active count alone.
        after_cross_process_retry = self.payload(0, "suspend_annotations", {
            "lease_seconds": 30, "idempotency_key": key_a,
        }, 403)
        self.assertEqual(after_cross_process_retry["leaseToken"], token_a)
        self.assertTrue(after_cross_process_retry["leaseReused"])
        self.assertEqual(after_cross_process_retry["activeLeaseCount"], 1)

        second = self.payload(1, "suspend_annotations", {"lease_seconds": 30}, 404)
        token_b = second["leaseToken"]
        self.live_tokens.add(token_b)
        self.assertNotEqual(token_b, token_a)
        self.assertEqual(second["activeLeaseCount"], 2)
        self.assert_windows_match_windowserver(0, False)
        self.assert_windows_match_windowserver(1, False)

        released_a = self.payload(0, "resume_annotations", {"lease_token": token_a}, 405)
        self.live_tokens.discard(token_a)
        self.assertTrue(released_a["alreadyReleased"] is False)
        self.assertTrue(released_a["annotationsSuspended"], "B's lease must keep both processes hidden")
        self.assertTrue(released_a["peerPresentationSettled"])
        self.assertEqual(released_a["activeLeaseCount"], 1)
        self.assert_windows_match_windowserver(0, False)
        self.assert_windows_match_windowserver(1, False)

        released_b = self.payload(1, "resume_annotations", {"lease_token": token_b}, 406)
        self.live_tokens.discard(token_b)
        self.assertFalse(released_b["annotationsSuspended"])
        self.assertFalse(released_b["peerPresentationSettled"])
        self.assertIn("does not prove global peer/window convergence", released_b["note"])
        self.assertEqual(released_b["activeLeaseCount"], 0)
        self.assert_windows_match_windowserver(0, True)
        self.assert_windows_match_windowserver(1, True)


if __name__ == "__main__":
    unittest.main()
