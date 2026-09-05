import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

# test_mcp_stdio.py lives at the repo root, one level above this file. Running
# this module as `python3 -m unittest tests/test_mcp_stdio_harness.py` from the
# repo root already puts the root on sys.path, but running it directly
# (`python3 tests/test_mcp_stdio_harness.py`) sets sys.path[0] to tests/ and
# the import below dies with ModuleNotFoundError. Insert the repo root
# explicitly so both entry points work, exactly as
# tests/test_suspension_two_process.py does.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_mcp_stdio as harness  # noqa: E402


# These tests spawn a fresh Python interpreter for each framing fixture. Its
# startup is unrelated to the behavior under test and can be slow on a loaded
# macOS worker, so keep a comfortably bounded startup-inclusive deadline.
CHILD_FIXTURE_TIMEOUT_SECONDS = 5


class MCPLineReaderTests(unittest.TestCase):
    def start_child(self, source):
        return subprocess.Popen(
            [sys.executable, "-c", source],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def stop_child(self, proc):
        harness.terminate_child(proc)
        if proc.stdout is not None:
            proc.stdout.close()
        if proc.stderr is not None:
            proc.stderr.close()

    def test_reads_fragmented_line_and_preserves_buffered_followup(self):
        proc = self.start_child(
            "import os, time; "
            "os.write(1, b'{\\\"id\\\":'); "
            "time.sleep(0.02); "
            "os.write(1, b'1}\\n{\\\"id\\\":2}\\n'); "
            "time.sleep(2)"
        )
        try:
            reader = harness.MCPLineReader(proc)
            self.assertEqual(reader.read_line("first", CHILD_FIXTURE_TIMEOUT_SECONDS), '{"id":1}')
            self.assertEqual(reader.read_line("second", CHILD_FIXTURE_TIMEOUT_SECONDS), '{"id":2}')
        finally:
            self.stop_child(proc)

    def test_partial_line_obeys_deadline(self):
        proc = self.start_child(
            "import os, time; "
            "os.write(1, b'{\\\"jsonrpc\\\":'); "
            "time.sleep(2)"
        )
        started = time.monotonic()
        try:
            reader = harness.MCPLineReader(proc)
            with self.assertRaisesRegex(TimeoutError, "complete newline-terminated MCP response"):
                reader.read_line("initialize", 0.05)
            self.assertLess(time.monotonic() - started, 0.5)
        finally:
            self.stop_child(proc)

    def test_eof_reports_partial_response(self):
        proc = self.start_child("import os; os.write(1, b'{partial')")
        try:
            reader = harness.MCPLineReader(proc)
            with self.assertRaisesRegex(RuntimeError, "Partial response"):
                reader.read_line("tools/list", CHILD_FIXTURE_TIMEOUT_SECONDS)
        finally:
            self.stop_child(proc)

    def test_newline_free_stdout_flood_fails_at_the_transport_size_limit(self):
        # Use a small injected cap so this regression test stays fast while
        # exercising the same branch the 8 MiB production cap uses.
        proc = self.start_child("import os, time; os.write(1, b'x' * 16); time.sleep(2)")
        try:
            reader = harness.MCPLineReader(proc, max_response_bytes=16)
            with self.assertRaisesRegex(RuntimeError, "transport limit without a newline"):
                # Process startup can exceed the former half-second budget on
                # a loaded macOS CI worker; the assertion is about framing,
                # not startup latency.
                reader.read_line("tools/list", CHILD_FIXTURE_TIMEOUT_SECONDS)
        finally:
            self.stop_child(proc)

    def test_response_at_the_inclusive_transport_limit_is_accepted(self):
        # The server's budget includes the newline framing byte, so 15 bytes
        # of JSON-ish payload plus '\\n' is valid under a 16-byte cap.
        proc = self.start_child("import os, time; os.write(1, b'123456789012345\\n'); time.sleep(2)")
        try:
            reader = harness.MCPLineReader(proc, max_response_bytes=16)
            self.assertEqual(reader.read_line("tools/list", CHILD_FIXTURE_TIMEOUT_SECONDS), "123456789012345")
        finally:
            self.stop_child(proc)

    def test_oversized_buffered_tail_is_rejected_before_the_first_response_is_returned(self):
        # A response can be followed by the start of another stdout line in
        # the same OS read. The first response must not make the harness send
        # a new request if the tail has already violated the transport cap.
        proc = self.start_child(
            "import os, time; os.write(1, b'{\"id\":1}\\n' + b'x' * 16); time.sleep(2)"
        )
        try:
            reader = harness.MCPLineReader(proc, max_response_bytes=16)
            with self.assertRaisesRegex(RuntimeError, "transport limit without a newline"):
                reader.read_line("tools/list", CHILD_FIXTURE_TIMEOUT_SECONDS)
        finally:
            self.stop_child(proc)

    def test_nonpositive_response_size_limit_is_rejected_at_construction(self):
        proc = self.start_child("import time; time.sleep(2)")
        try:
            with self.assertRaisesRegex(ValueError, "greater than zero"):
                harness.MCPLineReader(proc, max_response_bytes=0)
        finally:
            self.stop_child(proc)


class MCPHarnessHelperTests(unittest.TestCase):
    def test_nonfinite_cli_timeout_is_rejected(self):
        with mock.patch.object(sys, "argv", ["test_mcp_stdio.py", "--timeout", "nan"]):
            with self.assertRaises(SystemExit) as raised:
                harness.parse_args()
        self.assertNotEqual(raised.exception.code, 0)

    def test_resume_cleanup_retries_timeout_and_error_result(self):
        successful_response = {"result": {"content": []}}
        with mock.patch.object(
            harness,
            "send_request",
            side_effect=[
                TimeoutError("first resume timed out"),
                {"result": {"isError": True, "content": []}},
                successful_response,
            ],
        ) as send_request:
            actual = harness.resume_annotations_with_retry(
                proc=object(), reader=object(), timeout_seconds=0.1, request_id=90,
                lease_token="A" * 43,
            )

        self.assertIs(actual, successful_response)
        self.assertEqual(send_request.call_count, 3)
        self.assertEqual(
            [call.args[2]["id"] for call in send_request.call_args_list],
            [90, 91, 92],
        )
        self.assertTrue(all(
            call.args[2]["params"] == {
                "name": "resume_annotations", "arguments": {"lease_token": "A" * 43}
            }
            for call in send_request.call_args_list
        ))

    @staticmethod
    def presentation_response(ready, reasons):
        import json
        return {"result": {"content": [{"text": json.dumps({
            "annotationId": "annotation-1",
            "presentationReady": ready,
            "failureReasons": reasons,
        })}]}}

    def test_presentation_poll_samples_immediately_and_retains_first_transient(self):
        transient = self.presentation_response(False, ["windowserver_window_not_on_screen"])
        settled = self.presentation_response(True, [])
        with mock.patch.object(
            harness, "send_request", side_effect=[transient, settled]
        ) as send_request, mock.patch.object(harness.time, "sleep") as sleep:
            actual, first_transient = harness.verify_presentation_until_settled(
                proc=object(), reader=object(), timeout_seconds=0.1,
                request_id=400, annotation_id="annotation-1",
            )

        self.assertIs(actual, settled)
        self.assertEqual(first_transient["failureReasons"], ["windowserver_window_not_on_screen"])
        self.assertEqual(send_request.call_count, 2)
        self.assertEqual([call.args[2]["id"] for call in send_request.call_args_list], [400, 401])
        sleep.assert_called_once()

    def test_presentation_poll_does_not_retry_non_windowserver_failure(self):
        detached = self.presentation_response(False, ["overlay_view_detached"])
        with mock.patch.object(
            harness, "send_request", return_value=detached
        ) as send_request, mock.patch.object(harness.time, "sleep") as sleep:
            actual, first_transient = harness.verify_presentation_until_settled(
                proc=object(), reader=object(), timeout_seconds=0.1,
                request_id=500, annotation_id="annotation-1",
            )

        self.assertIs(actual, detached)
        self.assertIsNone(first_transient)
        send_request.assert_called_once()
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
