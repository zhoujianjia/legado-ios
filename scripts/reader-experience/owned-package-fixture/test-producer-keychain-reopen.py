"""Real portable child/report boundaries only; no macOS Keychain/codesign execution."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location('owned_reopen_producer', Path(__file__).with_name('generate-sdk-owned-package.py'))
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


class OwnedKeychainReopenReportTests(unittest.TestCase):
    def setUp(self):
        producer.RECORDS.clear()
        producer.PRIVATE_LITERALS.clear()
        producer.PRODUCER_DEADLINE = None

    def passed(self):
        # Synthetic reporter data test strict forwarding only. This cannot
        # stand in for actual Swift lookup, signing or a real codesign result.
        return {'schemaVersion': 2, 'operation': 'reopenIdentity', 'stage': 'complete', 'status': 'passed', 'osStatus': 0,
                'storedIdentityCount': 1, 'legacySigningIdentityCount': 1,
                'leafSHA256': '1' * 64, 'rootSHA256': '2' * 64,
                'privateKeySignatureVerified': True, 'codesignACLExecutionVerified': False,
                'keychainUnlockedBeforeRequest': False, 'keychainUnlocked': True, 'keychainReadable': True, 'keychainWritable': True}

    def child(self, status, code=0):
        return [sys.executable, '-c', 'import sys;sys.stdin.buffer.read();sys.stdout.write(' + repr(json.dumps(status)) + ');sys.exit(' + str(code) + ')']

    def test_actual_private_reporter_has_separate_reopen_schema_and_no_codesign_claim(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = producer.run(self.child(self.passed()), input=b'owned-private-password-canary', private=True, public_status='reopen')
        label, raw = output.getvalue().strip().split(' ', 1)
        self.assertEqual(label, 'OWNED_KEYCHAIN_REOPEN_STATUS')
        self.assertEqual(json.loads(raw), self.passed())
        self.assertEqual(producer.reopened_identity_status(result), self.passed())
        self.assertNotIn('owned-private-password-canary', output.getvalue())
        self.assertFalse(producer.RECORDS[-1]['privateInputBytesRetained'])

    def test_reopen_success_rejects_missing_extra_ambiguous_and_false_proof_fields(self):
        valid = self.passed()
        missing = dict(valid); missing.pop('legacySigningIdentityCount')
        cases = [missing, dict(valid, privateData='secret-canary'), dict(valid, operation='importIdentity'),
                 dict(valid, schemaVersion=True), dict(valid, storedIdentityCount=True),
                 dict(valid, legacySigningIdentityCount=0), dict(valid, legacySigningIdentityCount=2),
                 dict(valid, osStatus=True), dict(valid, leafSHA256='bad-fingerprint'),
                 dict(valid, privateKeySignatureVerified=1), dict(valid, keychainUnlocked=False),
                 dict(valid, keychainUnlockedBeforeRequest=1),
                 dict(valid, keychainReadable=False), dict(valid, keychainWritable=False),
                 dict(valid, codesignACLExecutionVerified=True)]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                producer.reopened_identity_status(json.dumps(value).encode())
        with self.assertRaises(ValueError):
            producer.identity_status(json.dumps(valid).encode())
        with self.assertRaises(ValueError):
            producer.reopened_identity_status(b' ' * 4097)

    def test_actual_malformed_private_report_suppresses_all_unknown_data(self):
        output = io.StringIO()
        status = dict(self.passed(), privateData='owned-secret-status-canary')
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure):
            producer.run(self.child(status), input=b'owned-p12-canary', private=True, public_status='reopen')
        self.assertNotIn('owned-secret', output.getvalue())
        self.assertNotIn('owned-p12', output.getvalue())
        self.assertEqual(json.loads(output.getvalue().split(' ', 1)[1]),
                         {'schemaVersion': 2, 'operation': 'reopenIdentity', 'stage': 'readInput', 'status': 'failed', 'osStatus': -1})

    def test_actual_child_failure_cannot_be_accepted_from_a_passed_report(self):
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure) as failed:
            producer.run(self.child(self.passed(), 7), input=b'owned-private-canary', private=True, public_status='reopen')
        self.assertEqual(failed.exception.code, 7)
        self.assertEqual(producer.RECORDS[-1]['exitCode'], 7)
        self.assertFalse(json.loads(output.getvalue().split(' ', 1)[1])['codesignACLExecutionVerified'])

    def test_actual_unlock_failure_retains_only_the_typed_osstatus(self):
        status = {'schemaVersion': 2, 'operation': 'reopenIdentity', 'stage': 'unlockKeychain', 'status': 'failed', 'osStatus': -25293}
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure) as failed:
            producer.run(self.child(status, 1), input=b'owned-password-canary', private=True, public_status='reopen')
        self.assertEqual(failed.exception.code, 1)
        self.assertEqual(json.loads(output.getvalue().split(' ', 1)[1]), status)
        for changed in [dict(status, osStatus=0), dict(status, errorDescription='private-canary'), dict(status, stage='unknown')]:
            with self.assertRaises(ValueError):
                producer.reopened_identity_status(json.dumps(changed).encode())


if __name__ == '__main__':
    unittest.main(verbosity=2)
