import subprocess
import sys
import time
import unittest
from unittest import mock

import test_mcp_stdio as harness


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
            self.assertEqual(reader.read_line("first", 0.5), '{"id":1}')
            self.assertEqual(reader.read_line("second", 0.5), '{"id":2}')
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
                reader.read_line("tools/list", 0.5)
        finally:
            self.stop_child(proc)

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
