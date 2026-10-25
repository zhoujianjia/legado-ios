"""Portable actual-child-process diagnostics checks; never executes codesign."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

PATH = Path(__file__).with_name('generate-sdk-owned-package.py')
spec = importlib.util.spec_from_file_location('sdk_producer_delta', PATH)
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


class ProducerDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        producer.RECORDS.clear()
        producer.PRIVATE_LITERALS.clear()

    def test_actual_public_child_failure_reaches_existing_uploaded_stdout(self):
        with tempfile.TemporaryDirectory(prefix='owned-producer-diagnostic-') as directory:
            log = Path(directory) / 'owned.public.log'
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaises(producer.ToolFailure) as failure:
                producer.run([sys.executable, '-c', 'import sys;sys.stderr.write("owned-public-failure-17");sys.exit(7)'], public_log=log)
            self.assertEqual(failure.exception.code, 7)
            marker, raw = output.getvalue().strip().split(' ', 1)
            value = json.loads(raw)
            self.assertEqual(marker, 'OWNED_PUBLIC_TOOL_FAILURE')
            self.assertEqual(value['stderr'], 'owned-public-failure-17')
            self.assertEqual(value['exitCode'], 7)
            self.assertEqual(value['publicLog'], log.name)
            self.assertFalse(value['failedToolSucceeded'])
            self.assertEqual(value['nativeTestsExecuted'], 0)
            self.assertEqual(log.read_text(), 'owned-public-failure-17')

    def test_actual_private_child_failure_publishes_no_stream_or_command(self):
        output = io.StringIO()
        secret = b'owned-private-P12-canary\n-----BEGIN PRIVATE KEY-----\nowned-key-canary'
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure):
            producer.run([sys.executable, '-c', 'import sys;b=sys.stdin.buffer.read();sys.stdout.buffer.write(b);sys.stderr.buffer.write(b);sys.exit(8)'], input=secret, private=True)
        self.assertEqual(output.getvalue(), '')
        self.assertEqual(producer.RECORDS[-1]['exitCode'], 8)
        self.assertFalse(producer.RECORDS[-1]['privateInputBytesRetained'])

    def test_private_public_log_request_is_rejected_before_child_executes(self):
        with tempfile.TemporaryDirectory(prefix='owned-producer-diagnostic-') as directory:
            unexpected = Path(directory) / 'unexpected'
            command = [sys.executable, '-c', 'from pathlib import Path;Path(' + repr(str(unexpected)) + ').touch()']
            with self.assertRaises(ValueError):
                producer.run(command, private=True, public_log=Path(directory) / 'private.log')
            self.assertFalse(unexpected.exists())
            self.assertEqual(producer.RECORDS, [])

    def test_malformed_private_import_status_is_suppressed_not_echoed(self):
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure):
            producer.run([sys.executable, '-c', 'import sys;sys.stdout.write("owned-P12-secret-without-schema");sys.stderr.write("owned-secret-stderr");sys.exit(9)'], private=True, public_status=True)
        text = output.getvalue()
        self.assertNotIn('owned-P12', text)
        self.assertNotIn('owned-secret', text)
        marker, raw = text.strip().split(' ', 1)
        self.assertEqual(marker, 'OWNED_IDENTITY_STATUS')
        self.assertEqual(json.loads(raw), {'schemaVersion': 1, 'stage': 'readInput', 'status': 'failed', 'osStatus': -1})

    def test_typed_public_import_facts_keep_other_process_acl_unverified(self):
        status = {'schemaVersion': 1, 'stage': 'complete', 'status': 'passed', 'osStatus': 0,
                  'importedItemCount': 1, 'storedIdentityCount': 1, 'leafSHA256': '1' * 64, 'rootSHA256': '2' * 64,
                  'privateKeySignatureVerified': True, 'codesignACLExecutionVerified': False}
        # These child JSON values test the reporter, never stand in for a real
        # Swift importer or another process's codesign/Keychain acceptance.
        output = io.StringIO()
        with redirect_stdout(output):
            producer.run([sys.executable, '-c', 'import sys;sys.stdout.write(' + repr(json.dumps(status)) + ')'], private=True, public_status=True)
        self.assertEqual(json.loads(output.getvalue().split(' ', 1)[1]), status)
        missing=dict(status);missing.pop('leafSHA256')
        for changed in [dict(status, schemaVersion=True), dict(status, unexpected='private-canary'), missing]:
            with self.assertRaises(ValueError):
                producer.identity_status(json.dumps(changed).encode())
        with redirect_stdout(io.StringIO()), self.assertRaises(producer.ToolFailure):
            producer.run([sys.executable, '-c', 'import sys;sys.stdout.write(' + repr(json.dumps(dict(status, codesignACLExecutionVerified=True))) + ')'], private=True, public_status=True)

    def test_public_capture_is_bounded_and_redacts_secrets_before_truncation(self):
        secret = 'b' * 48
        producer.PRIVATE_LITERALS.append(secret)
        before = b'a' * (producer.PUBLIC_DIAGNOSTIC_BYTES - 12)
        actual = producer.public_text(before + secret.encode() + b'after')
        self.assertNotIn('b' * 12, actual)
        self.assertLessEqual(len(actual.encode()), producer.PUBLIC_DIAGNOSTIC_BYTES)
        self.assertIn('<private-material-suppressed>', producer.public_text(b'public\n-----BEGIN RSA PRIVATE KEY-----\nowned-private-canary'))
        self.assertNotIn('owned-private-canary', producer.public_text(b'public\n-----BEGIN RSA PRIVATE KEY-----\nowned-private-canary'))
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure):
            producer.run([sys.executable, '-c', 'import sys;sys.stderr.buffer.write(b"x"*70000);sys.exit(3)'])
        value = json.loads(output.getvalue().split(' ', 1)[1])
        self.assertTrue(value['truncated'])
        self.assertEqual(len(value['stderr']), producer.PUBLIC_DIAGNOSTIC_BYTES)


if __name__ == '__main__':
    unittest.main(verbosity=2)
