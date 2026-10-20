"""Synthetic keys/certificates only; never reads a real pairing record."""
import base64
import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('pairing_export', HERE / 'export-renewal-pairing.py')
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)
NOW = datetime(2026, 10, 21, tzinfo=timezone.utc)
PASSWORD = 'SYNTHETIC-only-password'


class PairingExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def key():
            return rsa.generate_private_key(public_exponent=65537, key_size=2048)
        def name(label):
            return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'SYNTHETIC ' + label)])
        def cert(label, public_key, issuer, signing_key, ca):
            return (x509.CertificateBuilder().subject_name(name(label)).issuer_name(issuer)
                    .public_key(public_key).serial_number(x509.random_serial_number())
                    .not_valid_before(NOW - timedelta(days=1)).not_valid_after(NOW + timedelta(days=10))
                    .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
                    .sign(signing_key, hashes.SHA256()))
        cls.root_key, cls.host_key, device_key, cls.wrong_key = key(), key(), key(), key()
        cls.root = cert('root', cls.root_key.public_key(), name('root'), cls.root_key, True)
        cls.host = cert('host', cls.host_key.public_key(), cls.root.subject, cls.root_key, False)
        cls.device = cert('device', device_key.public_key(), cls.root.subject, cls.root_key, False)

    def record(self, encoding=serialization.Encoding.PEM):
        return {'HostCertificate': self.host.public_bytes(encoding),
                'DeviceCertificate': self.device.public_bytes(encoding),
                'RootCertificate': self.root.public_bytes(encoding),
                'HostPrivateKey': self.host_key.private_bytes(encoding, serialization.PrivateFormat.PKCS8,
                                                             serialization.NoEncryption()),
                'HostID': 'SYNTHETIC-HOST-ID', 'SystemBUID': 'SYNTHETIC-SYSTEM-BUID',
                'RootPrivateKey': b'SYNTHETIC-ROOT-PRIVATE-MUST-NOT-EXPORT',
                'EscrowBag': b'SYNTHETIC-ESCROW-MUST-NOT-EXPORT'}

    def build(self, record=None, **changes):
        args = {'password': PASSWORD, 'address': '127.0.0.1', 'port': 62078, 'interface_index': 0, 'now': NOW}
        args.update(changes)
        return export.build_materials(plistlib.dumps(record or self.record()), **args)

    def test_pem_and_der_materials_match_actual_app_schema_and_decrypt_with_matching_key(self):
        for encoding in [serialization.Encoding.PEM, serialization.Encoding.DER]:
            material = self.build(self.record(encoding))
            self.assertEqual(set(material), {export.P12_NAME, export.PUBLIC_NAME})
            public = json.loads(material[export.PUBLIC_NAME])
            self.assertEqual(set(public), {'schema', 'hostCertificateDER', 'deviceCertificateDER',
                'rootCertificateDER', 'hostID', 'systemBUID', 'numericAddress', 'port', 'interfaceIndex'})
            self.assertEqual(public['schema'], 1)
            for field, certificate in [('hostCertificateDER', self.host), ('deviceCertificateDER', self.device),
                                       ('rootCertificateDER', self.root)]:
                self.assertEqual(base64.b64decode(public[field]), certificate.public_bytes(serialization.Encoding.DER))
            key, host, chain = pkcs12.load_key_and_certificates(material[export.P12_NAME], PASSWORD.encode())
            self.assertEqual(export.public_key_bytes(key.public_key()), export.public_key_bytes(self.host_key.public_key()))
            self.assertEqual(host, self.host)
            self.assertEqual(chain, [self.root])
            with self.assertRaises(ValueError):
                pkcs12.load_key_and_certificates(material[export.P12_NAME], b'wrong-password')
            for excluded in [b'PRIVATE KEY', b'SYNTHETIC-ROOT-PRIVATE', b'SYNTHETIC-ESCROW', PASSWORD.encode()]:
                self.assertNotIn(excluded, b''.join(material.values()))

    def test_wrong_key_invalid_chain_expiry_and_corrupt_input_are_rejected(self):
        record = self.record()
        record['HostPrivateKey'] = self.wrong_key.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        with self.assertRaisesRegex(export.ConversionError, 'does not match'):
            self.build(record)
        record = self.record()
        record['RootCertificate'] = record['HostCertificate']
        with self.assertRaisesRegex(export.ConversionError, 'signatures'):
            self.build(record)
        with self.assertRaisesRegex(export.ConversionError, 'validity'):
            self.build(now=NOW + timedelta(days=11))
        for raw in [b'not a plist', b'', b'a' * (export.MAX_INPUT + 1)]:
            with self.assertRaises(export.ConversionError):
                export.build_materials(raw, PASSWORD, '127.0.0.1', 62078, 0, now=NOW)

    def test_app_endpoint_password_and_existing_identifiers_are_strict(self):
        for field, values in [('password', ['', '\0', 'a' * 1025]), ('address', ['localhost', 'fe80::1%en0']),
                              ('port', [0, 65536, True]), ('interface_index', [-1, 2**32, True])]:
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(export.ConversionError):
                    self.build(**{field: value})
        for field in ['HostID', 'SystemBUID']:
            record = self.record()
            del record[field]
            with self.assertRaises(export.ConversionError):
                self.build(record)
        public = json.loads(self.build(address='fe80::1', interface_index=4)[export.PUBLIC_NAME])
        self.assertEqual((public['numericAddress'], public['interfaceIndex']), ('fe80::1', 4))

    def test_duplicate_plist_keys_are_rejected(self):
        raw = b'<?xml version="1.0"?><plist version="1.0"><dict><key>HostID</key><string>a</string><key>HostID</key><string>b</string></dict></plist>'
        with self.assertRaisesRegex(export.ConversionError, 'duplicate'):
            export.build_materials(raw, PASSWORD, '127.0.0.1', 62078, 0, now=NOW)

    def test_new_directory_publication_preserves_existing_files_and_rolls_back_owned_failures(self):
        contents = self.build()
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            existing = parent / 'existing'
            existing.mkdir()
            with self.assertRaises(export.ConversionError):
                export.publish_new_directory(existing, contents)
            marker = existing / 'keep.txt'
            marker.write_bytes(b'preserve')
            with self.assertRaises(export.ConversionError):
                export.publish_new_directory(existing, contents)
            self.assertEqual(marker.read_bytes(), b'preserve')
            target = parent / 'new'
            real_fsync = export.os.fsync
            calls = 0
            def fail_second(fd):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError('synthetic disk failure')
                real_fsync(fd)
            with patch.object(export.os, 'fsync', side_effect=fail_second), self.assertRaises(OSError):
                export.publish_new_directory(target, contents)
            self.assertFalse(target.exists())
            export.publish_new_directory(target, contents)
            self.assertEqual({p.name for p in target.iterdir()}, set(contents))
            self.assertEqual((target / export.P12_NAME).read_bytes(), contents[export.P12_NAME])

    def test_cli_refuses_redirected_password_and_never_prints_credential_values(self):
        output, errors = io.StringIO(), io.StringIO()
        args = ['--pairing', 'unused.plist', '--output', 'unused-output', '--address', '127.0.0.1',
                '--port', '62078', '--interface-index', '0']
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            with self.assertRaises(SystemExit) as stopped:
                export.main(args + ['--password', PASSWORD])
        self.assertEqual(stopped.exception.code, 2)
        self.assertNotIn(PASSWORD, output.getvalue() + errors.getvalue())
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(export.sys.stdin, 'isatty', return_value=False), patch.object(export, 'convert') as convert:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(export.main(args), 1)
            convert.assert_not_called()
        self.assertIn('interactively', errors.getvalue())
        for failure in [export.ConversionError('Host private key does not match HostCertificate.'),
                        RuntimeError(PASSWORD + ' PRIVATE KEY SYNTHETIC-SECRET')]:
            output, errors = io.StringIO(), io.StringIO()
            with patch.object(export.sys.stdin, 'isatty', return_value=True), \
                 patch.object(export.getpass, 'getpass', return_value=PASSWORD), \
                 patch.object(export, 'convert', side_effect=failure):
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    self.assertEqual(export.main(args), 1)
            self.assertNotIn(PASSWORD, output.getvalue() + errors.getvalue())
            self.assertNotIn('SYNTHETIC-SECRET', errors.getvalue())

    def test_rollback_preserves_replacement_directory_and_reports_moved_owned_output(self):
        with tempfile.TemporaryDirectory() as directory:
            target, moved = Path(directory) / 'output', Path(directory) / 'owned-renamed'
            actual_open = export.os.open
            calls = 0
            foreign_identity = None
            def replace_directory(path, *args, **kwargs):
                nonlocal calls, foreign_identity
                calls += 1
                if calls == 2:
                    target.rename(moved)
                    target.mkdir()
                    fact = target.stat()
                    foreign_identity = (fact.st_dev, fact.st_ino)
                    raise OSError('synthetic output directory replacement')
                return actual_open(path, *args, **kwargs)
            with patch.object(export.os, 'open', side_effect=replace_directory):
                with self.assertRaisesRegex(export.ConversionError, 'cleanup was incomplete'):
                    export.publish_new_directory(target, {export.P12_NAME: b'synthetic encrypted P12',
                                                          export.PUBLIC_NAME: b'{}'})
            fact = target.stat()
            self.assertEqual((fact.st_dev, fact.st_ino), foreign_identity)
            self.assertEqual(list(target.iterdir()), [])
            self.assertEqual((moved / export.P12_NAME).read_bytes(), b'synthetic encrypted P12')


if __name__ == '__main__':
    unittest.main()
