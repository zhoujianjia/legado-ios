#!/usr/bin/env python3
"""Explicit, offline conversion of an existing pairing plist; never discovery.

Private keys stay in memory. The only key output is a password-protected PKCS12.
Its password is read from an interactive terminal, never argv or environment.
The App remains responsible for SecTrust, Keychain and installation authority.
"""
import argparse
import base64
from datetime import datetime, timezone
import getpass
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import warnings

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
except ImportError:
    sys.exit('Missing dependency: install cryptography>=42 in this Python environment.')

MAX_INPUT = 4 * 1024 * 1024
MAX_OUTPUT = 524_288  # Exact App configuration/P12 limit.
P12_NAME = 'yuedu-pairing-host.p12'
PUBLIC_NAME = 'yuedu-pairing-public.json'


class ConversionError(ValueError):
    """Only these fixed messages may cross the console boundary."""


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes unknown arguments and invalid values. Even an
        # accidentally supplied --password must not be copied into console logs.
        self.print_usage(sys.stderr)
        self.exit(2, 'Invalid arguments; use --help. Passwords are prompted, never arguments.\n')


class UniqueDictionary(dict):
    def __setitem__(self, key, value):
        if key in self:
            raise ConversionError('Pairing file contains duplicate keys.')
        super().__setitem__(key, value)


def required_bytes(record, name):
    value = record.get(name)
    if not isinstance(value, bytes) or not 0 < len(value) <= 65_536:
        raise ConversionError('Pairing certificate/key fields are missing or invalid.')
    return value


def required_string(record, name):
    value = record.get(name)
    if not isinstance(value, str) or not value or '\0' in value or len(value.encode('utf-8')) > 256:
        raise ConversionError('Existing HostID/SystemBUID is missing or invalid.')
    return value


def certificate(raw):
    try:
        if raw.lstrip().startswith(b'-----BEGIN'):
            if raw.count(b'-----BEGIN CERTIFICATE-----') != 1:
                raise ValueError('one certificate required')
            value = x509.load_pem_x509_certificate(raw)
        else:
            value = x509.load_der_x509_certificate(raw)
        return value
    except (ValueError, TypeError) as error:
        raise ConversionError('Pairing certificate cannot be decoded.') from error


def public_key_bytes(key):
    return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def build_materials(raw, password, address, port, interface_index, *, now=None):
    if not isinstance(raw, bytes) or not 0 < len(raw) <= MAX_INPUT:
        raise ConversionError('Pairing input is empty or exceeds the size limit.')
    try:
        record = plistlib.loads(raw, dict_type=UniqueDictionary)
    except ConversionError:
        raise
    except Exception as error:
        raise ConversionError('Pairing input is not a readable plist.') from error
    if not isinstance(record, dict):
        raise ConversionError('Pairing input must be a plist dictionary.')
    if not isinstance(password, str) or not password or '\0' in password or len(password.encode('utf-8')) > 1_024:
        raise ConversionError('PKCS12 password must contain 1 to 1024 UTF-8 bytes without NUL.')
    try:
        if not isinstance(address, str) or '%' in address:
            raise ValueError('numeric address required')
        numeric = str(ipaddress.ip_address(address))
    except ValueError as error:
        raise ConversionError('Supply the actual numeric IPv4/IPv6 endpoint address.') from error
    if type(port) is not int or not 1 <= port <= 65_535 or type(interface_index) is not int or not 0 <= interface_index <= 0xFFFFFFFF:
        raise ConversionError('Port or interface index is outside the App input range.')
    host_id = required_string(record, 'HostID')
    system_buid = required_string(record, 'SystemBUID')
    host = certificate(required_bytes(record, 'HostCertificate'))
    device = certificate(required_bytes(record, 'DeviceCertificate'))
    root = certificate(required_bytes(record, 'RootCertificate'))
    key_raw = required_bytes(record, 'HostPrivateKey')
    try:
        key = (serialization.load_pem_private_key(key_raw, None) if key_raw.lstrip().startswith(b'-----BEGIN')
               else serialization.load_der_private_key(key_raw, None))
    except (ValueError, TypeError) as error:
        raise ConversionError('Host private key cannot be decoded; encrypted input keys are not supported.') from error
    if not isinstance(key, (rsa.RSAPrivateKey, ec.EllipticCurvePrivateKey)):
        raise ConversionError('Host key must support the App RSA/ECDSA possession check.')
    if public_key_bytes(key.public_key()) != public_key_bytes(host.public_key()):
        raise ConversionError('Host private key does not match HostCertificate.')
    at = now or datetime.now(timezone.utc)
    if at.tzinfo is None:
        raise ConversionError('Certificate validation requires a timezone-aware date.')
    try:
        for item in [host, device, root]:
            if not item.not_valid_before_utc <= at <= item.not_valid_after_utc:
                raise ValueError('certificate date')
        root.verify_directly_issued_by(root)
        host.verify_directly_issued_by(root)
        device.verify_directly_issued_by(root)
        if not root.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise ValueError('root is not CA')
    except Exception as error:
        raise ConversionError('Pairing certificate signatures, root or validity dates are invalid.') from error
    ders = [item.public_bytes(serialization.Encoding.DER) for item in [host, device, root]]
    if len(set(ders)) != 3 or any(len(item) > 65_536 for item in ders):
        raise ConversionError('Host, device and root must be distinct bounded certificates.')
    # Explicit compatibility profile for Apple's existing PKCS12 importer, also
    # used by the owned App fixture. Keep these transfer files private; a P12
    # password does not replace file protection. Primary API documentation:
    # https://cryptography.io/en/latest/hazmat/primitives/asymmetric/serialization/#pkcs12
    encryption = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50_000)
                  .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
                  .hmac_hash(hashes.SHA1()).build(password.encode('utf-8')))
    protected = pkcs12.serialize_key_and_certificates(b'Yuedu pairing host', key, host, [root], encryption)
    public = {'schema': 1, 'hostCertificateDER': base64.b64encode(ders[0]).decode('ascii'),
              'deviceCertificateDER': base64.b64encode(ders[1]).decode('ascii'),
              'rootCertificateDER': base64.b64encode(ders[2]).decode('ascii'),
              'hostID': host_id, 'systemBUID': system_buid, 'numericAddress': numeric,
              'port': port, 'interfaceIndex': interface_index}
    public_raw = (json.dumps(public, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    if max(len(protected), len(public_raw)) > MAX_OUTPUT:
        raise ConversionError('Converted material exceeds the App input limit.')
    return {P12_NAME: protected, PUBLIC_NAME: public_raw}


def publish_new_directory(destination, contents):
    """Create one new directory; rollback only files created by this invocation."""
    destination = Path(destination)
    if set(contents) != {P12_NAME, PUBLIC_NAME}:
        raise ConversionError('Unexpected output names.')
    try:
        destination.mkdir(mode=0o700)  # No exist_ok: even an empty existing directory is preserved.
    except OSError as error:
        raise ConversionError('Output directory must be new, with an existing writable parent.') from error
    directory_fact = destination.stat(follow_symlinks=False)
    directory_identity = (directory_fact.st_dev, directory_fact.st_ino)
    def owns_directory():
        try:
            fact = destination.stat(follow_symlinks=False)
            return stat.S_ISDIR(fact.st_mode) and (fact.st_dev, fact.st_ino) == directory_identity
        except OSError:
            return False
    created = []
    try:
        for name, raw in contents.items():
            if not owns_directory():
                raise ConversionError('The selected output directory changed during conversion.')
            path = destination / name
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_BINARY', 0), 0o600)
            with os.fdopen(descriptor, 'wb') as stream:
                fact = os.fstat(stream.fileno())
                created.append((path, fact.st_dev, fact.st_ino))
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            if not owns_directory():
                raise ConversionError('The selected output directory changed during conversion.')
    except BaseException as original:
        if not owns_directory():
            # Never clean a replacement directory or search for a renamed one.
            raise ConversionError('Output failed and partial-output cleanup was incomplete; keep the selected directory private and inspect it locally.') from original
        incomplete = False
        for path, device, inode in reversed(created):
            if not owns_directory():
                incomplete = True
                break
            try:
                fact = path.stat(follow_symlinks=False)
                if (fact.st_dev, fact.st_ino) == (device, inode):
                    path.unlink()
                else:
                    incomplete = True
            except FileNotFoundError:
                continue
            except OSError:
                incomplete = True
        try:
            if owns_directory():
                destination.rmdir()  # An unexpected third-party file is preserved.
            else:
                incomplete = True
        except FileNotFoundError:
            pass
        except OSError:
            incomplete = True
        if incomplete:
            raise ConversionError('Output failed and partial-output cleanup was incomplete; keep the selected directory private and inspect it locally.') from original
        raise


def convert(source, destination, password, address, port, interface_index):
    try:
        with Path(source).open('rb') as stream:
            raw = stream.read(MAX_INPUT + 1)
    except OSError as error:
        raise ConversionError('The explicitly selected pairing file cannot be read.') from error
    contents = build_materials(raw, password, address, port, interface_index)
    try:
        publish_new_directory(destination, contents)
    except ConversionError:
        raise
    except OSError as error:
        raise ConversionError('Output could not be written; no existing files were replaced.') from error


def main(argv=None):
    parser = PrivateArgumentParser(description='Offline conversion of an explicitly selected existing pairing plist. No USB discovery, network, VPN or installation.')
    parser.add_argument('--pairing', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='A NEW directory; its parent must already exist.')
    parser.add_argument('--address', required=True, help='Actual numeric paired-service endpoint; never guessed.')
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--interface-index', required=True, type=int, help='Actual interface index, or 0 for an endpoint requiring none.')
    args = parser.parse_args(argv)
    try:
        if not sys.stdin.isatty():
            raise ConversionError('Run interactively in a terminal; passwords are not accepted from argv, environment or redirected input.')
        with warnings.catch_warnings():
            warnings.simplefilter('error', getpass.GetPassWarning)
            password = getpass.getpass('New PKCS12 password: ')
            confirmation = getpass.getpass('Repeat password: ')
        if password != confirmation:
            raise ConversionError('Passwords do not match.')
        convert(args.pairing, args.output, password, args.address, args.port, args.interface_index)
        password = confirmation = None
    except (ConversionError, getpass.GetPassWarning) as error:
        print(str(error) if isinstance(error, ConversionError) else 'Terminal password echo could not be disabled.', file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print('Cancelled.', file=sys.stderr)
        return 1
    except Exception:
        print('Conversion failed. No credential details are logged.', file=sys.stderr)
        return 1
    print('Created encrypted PKCS12 and the nine-field public JSON. App import and installation remain unverified.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
