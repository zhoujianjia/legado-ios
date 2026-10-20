"""Actual bounded owned child processes; no macOS/code-sign execution is claimed."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import math
from pathlib import Path
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('sdk_producer_timeouts', Path(__file__).with_name('generate-sdk-owned-package.py'))
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)

class ProducerToolTimeoutTests(unittest.TestCase):
    def setUp(self):
        producer.RECORDS.clear()
        producer.PRIVATE_LITERALS.clear()
        producer.PRODUCER_DEADLINE = None
    def tearDown(self):
        producer.PRODUCER_DEADLINE = None
    def test_actual_public_timeout_terminates_child_and_retains_failure_log(self):
        with tempfile.TemporaryDirectory(prefix='owned-timeout-') as directory:
            log = Path(directory) / 'owned-tool.log'
            output = io.StringIO()
            start = time.monotonic()
            with redirect_stdout(output), self.assertRaises(producer.ToolTimeout) as failure:
                producer.run([sys.executable, '-c', 'import sys,time;print("owned-public-started",flush=True);time.sleep(30)'],
                             timeout_seconds=0.8, public_log=log)
            self.assertLess(time.monotonic() - start, 5)
            self.assertEqual(failure.exception.code, 124)
            self.assertIsNotNone(failure.exception.returncode)
            label, raw = output.getvalue().strip().split(' ', 1)
            self.assertEqual(label, 'OWNED_TOOL_TIMEOUT')
            value = json.loads(raw)
            self.assertEqual(value['status'], 'timeout')
            self.assertNotEqual(value['processReturnCode'], 0)
            self.assertTrue(value['processStarted'])
            self.assertIn('owned-public-started', value['stdout'])
            self.assertIn('owned-public-started', log.read_text())
            self.assertFalse(value['codesignSuccessEstablishedByThisFailureRecord'])
            self.assertEqual(value['nativeTestsExecuted'], 0)
            self.assertTrue(producer.RECORDS[-1]['timedOut'])
    def test_actual_private_timeout_never_forwards_partial_status_or_secret(self):
        output = io.StringIO()
        secret = b'owned-private-timeout-P12-canary'
        with redirect_stdout(output), self.assertRaises(producer.ToolTimeout):
            producer.run([sys.executable, '-c', 'import sys,time;b=sys.stdin.buffer.read();sys.stdout.buffer.write(b);sys.stdout.flush();sys.stderr.buffer.write(b);sys.stderr.flush();time.sleep(30)'],
                         input=secret, private=True, public_status=True, timeout_seconds=0.8)
        self.assertNotIn(secret.decode(), output.getvalue())
        self.assertNotIn('OWNED_IDENTITY_STATUS', output.getvalue())
        value = json.loads(output.getvalue().split(' ', 1)[1])
        self.assertFalse(value['privateCommandPublished'])
        self.assertFalse(value['privateStreamsPublished'])
        self.assertNotIn('argv', value)
        self.assertNotIn('stdout', value)
        self.assertNotIn('stderr', value)
    def test_exhausted_producer_deadline_does_not_start_another_tool(self):
        with tempfile.TemporaryDirectory(prefix='owned-expired-') as directory:
            marker = Path(directory) / 'must-not-exist'
            producer.PRODUCER_DEADLINE = time.monotonic() - 1
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaises(producer.ToolTimeout) as failure:
                producer.run([sys.executable, '-c', 'from pathlib import Path;Path(' + repr(str(marker)) + ').touch()'])
            self.assertFalse(marker.exists())
            self.assertFalse(failure.exception.started)
            value = json.loads(output.getvalue().split(' ', 1)[1])
            self.assertFalse(value['processStarted'])
            self.assertIsNone(value['processReturnCode'])
    def test_cleanup_has_a_separate_real_child_budget_after_producer_expiry(self):
        producer.PRODUCER_DEADLINE = time.monotonic() - 1
        self.assertEqual(producer.run([sys.executable, '-c', 'print("owned-cleanup-ran")'],
                                    private=True, timeout_seconds=producer.CLEANUP_TIMEOUT_SECONDS, cleanup=True).strip(), b'owned-cleanup-ran')
        self.assertFalse(producer.RECORDS[-1]['timedOut'])
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolTimeout):
            producer.run([sys.executable, '-c', 'import time;time.sleep(30)'], private=True, timeout_seconds=0.8, cleanup=True)
        self.assertFalse(json.loads(output.getvalue().split(' ', 1)[1])['privateStreamsPublished'])
    def test_actual_remaining_producer_budget_caps_a_longer_tool_budget(self):
        producer.PRODUCER_DEADLINE = time.monotonic() + 0.8
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolTimeout) as failure:
            producer.run([sys.executable, '-c', 'import time;time.sleep(30)'], timeout_seconds=120)
        self.assertGreater(failure.exception.seconds, 0)
        self.assertLessEqual(failure.exception.seconds, 0.8 + 2 * math.ulp(producer.PRODUCER_DEADLINE))
        self.assertFalse(json.loads(output.getvalue().split(' ', 1)[1])['failedToolSucceeded'])
    def test_each_producer_tool_has_an_explicit_budget_and_invalid_values_never_spawn(self):
        for name in ('openssl','xcodebuild','xcrun','security','codesign','import-owned-identity'):
            self.assertGreater(producer.TOOL_TIMEOUT_SECONDS[name], 0)
            self.assertLessEqual(producer.TOOL_TIMEOUT_SECONDS[name], 120)
        self.assertEqual(producer.tool_timeout(['codesign'], 120), 45)
        self.assertEqual(producer.tool_timeout(['security'], 120), 15)
        for value in (0, -1, True, float('inf'), float('nan')):
            with self.assertRaises(ValueError):producer.run([sys.executable, '-c', 'raise RuntimeError("must-not-run")'], timeout_seconds=value)
        self.assertEqual(producer.RECORDS, [])

if __name__ == '__main__':unittest.main(verbosity=2)
