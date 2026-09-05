#!/usr/bin/env python3
"""Regression coverage for MCP progress with an intentionally undrained stderr.

The production MCP transport must not depend on a parent consuming its
diagnostics.  This launches the actual Swift executable with stderr=PIPE and
never reads that pipe, then sends far more ping requests than any supported
pipe capacity can hold as log lines.  Before Logger made stderr non-blocking,
the child stopped replying as soon as that pipe filled.
"""

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT))
import test_mcp_stdio as harness  # noqa: E402


class LoggerStderrBackpressureTests(unittest.TestCase):
    # 1,024 complete request logs exceed even a generously-sized 64 KiB pipe,
    # while remaining quick enough to run as an ordinary native integration
    # test. Each response gets its own tight deadline so this fails promptly
    # at the first blocked diagnostic rather than waiting for the full loop.
    request_count = 1_024
    response_timeout_seconds = 1.0
    whole_test_deadline_seconds = 12.0

    def test_undrained_stderr_never_stalls_mcp_responses(self):
        binary_path = Path(
            os.environ.get(
                "AI_CHALKBOARD_LOGGER_TEST_BINARY",
                REPOSITORY_ROOT
                / ".test-dist"
                / "AIChalkboard.app"
                / "Contents"
                / "MacOS"
                / "AIChalkboard",
            )
        )
        if not binary_path.is_file():
            self.skipTest(
                f"test MCP bundle is unavailable at {binary_path}; run "
                "bash build_app.sh --test-ad-hoc-signing first"
            )

        with tempfile.TemporaryDirectory(prefix="ai-chalkboard-logger-test-") as temporary_root:
            environment = os.environ.copy()
            environment.update(harness.isolated_suspension_env(temporary_root, "logger"))
            environment["AI_CHALKBOARD_LOG_DIR"] = temporary_root
            proc = subprocess.Popen(
                [str(binary_path), "--mcp"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                env=environment,
            )
            try:
                reader = harness.MCPLineReader(proc)
                # AppKit startup can take longer than the per-request
                # backpressure deadline on a cold machine. Establish that the
                # child is ready before beginning the timed logging flood so a
                # startup delay cannot masquerade as a full-stderr deadlock.
                ready = harness.send_request(
                    proc,
                    reader,
                    {"jsonrpc": "2.0", "id": 0, "method": "ping"},
                    5.0,
                )
                self.assertEqual(ready.get("result"), {})
                started = time.monotonic()
                for request_id in range(1, self.request_count + 1):
                    try:
                        response = harness.send_request(
                            proc,
                            reader,
                            {"jsonrpc": "2.0", "id": request_id, "method": "ping"},
                            self.response_timeout_seconds,
                        )
                    except TimeoutError as error:
                        self.fail(f"ping {request_id} stalled with stderr undrained: {error}")
                    self.assertEqual(response.get("result"), {})
                self.assertLess(
                    time.monotonic() - started,
                    self.whole_test_deadline_seconds,
                    "MCP pings became unexpectedly slow while stderr was undrained",
                )
            finally:
                # Intentionally do not inspect or drain proc.stderr: consuming
                # it here would invalidate the regression's backpressure
                # condition. Closing happens only after the child is stopped.
                harness.terminate_child(proc)
                if proc.stdin is not None:
                    proc.stdin.close()
                if proc.stdout is not None:
                    proc.stdout.close()
                if proc.stderr is not None:
                    proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
