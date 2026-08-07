import subprocess
import sys
import time
import unittest

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


if __name__ == "__main__":
    unittest.main()
