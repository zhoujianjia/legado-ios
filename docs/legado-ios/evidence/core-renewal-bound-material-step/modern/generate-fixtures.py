import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
OWNED = OUT / 'owned'
PKI = ROOT / '.build/renewal-discovery/cms-profile-step/owned'
OPENSSL = 'D:/app/Git/usr/bin/openssl.exe'
SWIFT = ROOT / 'Tests/iOS/yuedu appTests/SelfRenewalModernProfileFixture.swift'
assert not OWNED.exists() and not SWIFT.exists()
OWNED.mkdir()
verify_at = int(re.search(r'Date\(timeIntervalSince1970: (\d+)\)', (ROOT / 'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift').read_text(encoding='utf-8'))[1])
commands = []
def run(*args, success=True):
    result = subprocess.run([OPENSSL, *map(str, args)], capture_output=True)
    record = {'arguments': list(map(str, args)), 'exitCode': result.returncode,
              'stdout': result.stdout.decode('utf-8', errors='replace'), 'stderr': result.stderr.decode('utf-8', errors='replace')}
    commands.append(record)
    assert (result.returncode == 0) == success, record
    return result
def tlv(tag, body):
    count = len(body)
    length = bytes([count]) if count < 128 else bytes([0x80 + (count.bit_length() + 7)//8]) + count.to_bytes((count.bit_length() + 7)//8, 'big')
    return bytes([tag]) + length + body
def encode(value, *, entitlements=False):
    if isinstance(value, dict):
        parts = [(key, tlv(0x30, encode(key) + encode(item))) for key, item in value.items()]
        if entitlements:
            return tlv(0x70, encode(1) + tlv(0xb0, b''.join(part for key, part in sorted(parts))))
        return tlv(0x31, b''.join(sorted(part for _, part in parts)))
    if isinstance(value, list): return tlv(0x30, b''.join(encode(item) for item in value))
    if isinstance(value, bool): return tlv(1, b'\xff' if value else b'\0')
    if isinstance(value, int):
        length = max(1, (value.bit_length() + 8)//8)
        body = value.to_bytes(length, 'big', signed=True)
        while len(body) > 1 and ((body[0] == 0 and body[1] < 128) or (body[0] == 255 and body[1] >= 128)): body = body[1:]
        return tlv(2, body)
    if isinstance(value, datetime): return tlv(0x17, value.strftime('%y%m%d%H%M%SZ').encode('ascii'))
    if isinstance(value, str): return tlv(0x0c, value.encode('utf-8'))
    if isinstance(value, bytes): return tlv(4, value)
    if value is None: return tlv(5, b'')
    raise TypeError(type(value))
def properties(*, created=datetime(2026,10,19), expires=datetime(2031,1,1), certificate_hash=None):
    values = {'UUID': '11111111-2222-3333-4444-555555555555', 'CreationDate': created, 'ExpirationDate': expires,
              'TeamIdentifier': ['FIXTURE123'], 'ApplicationIdentifierPrefix': ['OLDPREFIX'],
              'DeveloperCertificates': [certificate_hash or hashlib.sha256((PKI / 'leaf.der').read_bytes()).digest()],
              'Platform': ['iOS'], 'ProvisionedDevices': ['OWNED-FIXTURE-DEVICE'], 'TimeToLive': 7}
    entitlements = {'application-identifier': 'OLDPREFIX.test.owned.reader',
                    'com.apple.developer.team-identifier': 'FIXTURE123', 'keychain-access-groups': ['OLDPREFIX.*'],
                    'com.apple.security.application-groups': ['group.test.owned.reader'], 'get-task-allow': True}
    pairs = [tlv(0x30, encode(key) + encode(value)) for key, value in values.items()]
    pairs.append(tlv(0x30, encode('Entitlements') + encode(entitlements, entitlements=True)))
    return tlv(0x31, b''.join(sorted(pairs)))
def sign(name, content, *, untrusted=False):
    path = OWNED / (name + '.payload')
    path.write_bytes(content)
    cms = OWNED / (name + '.cms')
    signer, key = ((OWNED / 'untrusted.pem', OWNED / 'untrusted.key') if untrusted else (PKI / 'leaf.pem', PKI / 'leaf.key'))
    run('cms', '-sign', '-binary', '-nodetach', '-in', path, '-signer', signer, '-inkey', key,
        '-certfile', PKI / 'root.pem', '-md', 'sha256', '-outform', 'DER', '-out', cms)
    run('cms', '-verify', '-binary', '-inform', 'DER', '-in', cms, '-CAfile', PKI / 'root.pem',
        '-purpose', 'any', '-attime', str(verify_at), '-out', OWNED / (name + '.verified'), success=not untrusted)
    if not untrusted: assert (OWNED / (name + '.verified')).read_bytes() == content
    return cms.read_bytes()
run('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-x509', '-sha256', '-days', '3650',
    '-subj', '/CN=Owned Untrusted Profile Fixture', '-keyout', OWNED / 'untrusted.key', '-out', OWNED / 'untrusted.pem')
fixtures = {}
for name, der in [('modern', properties()), ('expired', properties(created=datetime(2019,1,1), expires=datetime(2020,1,1))),
                  ('future', properties(created=datetime(2030,1,1))), ('wrongCertificateHash', properties(certificate_hash=bytes([0x44])*32))]:
    inner = sign(name + '-inner', der)
    # Inert outer XML deliberately disagrees with DER. Modern verification must
    # resolve the inner source of truth, not silently authorize the XML fields.
    outer = plistlib.dumps({'UUID': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        'CreationDate': datetime(1999,1,1), 'ExpirationDate': datetime(2000,1,1),
        'TeamIdentifier': ['XML-ONLY'], 'DER-Encoded-Profile': inner}, fmt=plistlib.FMT_XML)
    fixtures[name] = sign(name + '-outer', outer)
fixtures['derPayload'] = properties()
inner = (OWNED / 'modern-inner.cms').read_bytes()
tampered = bytearray(inner)
at = tampered.index(fixtures['derPayload'])
tampered[at + len(fixtures['derPayload']) - 1] ^= 1
outer = plistlib.dumps({'DER-Encoded-Profile': bytes(tampered)}, fmt=plistlib.FMT_XML)
fixtures['badInner'] = sign('bad-inner-outer', outer)
run('cms', '-verify', '-binary', '-inform', 'DER', '-in', OWNED / 'bad-inner-outer.cms', '-CAfile', PKI / 'root.pem',
    '-purpose', 'any', '-attime', str(verify_at), '-out', OWNED / 'bad-inner-outer-verified')
(OWNED / 'changed-inner.cms').write_bytes(tampered)
run('cms', '-verify', '-binary', '-inform', 'DER', '-in', OWNED / 'changed-inner.cms', '-CAfile', PKI / 'root.pem',
    '-purpose', 'any', '-attime', str(verify_at), '-out', OWNED / 'changed-inner-rejected', success=False)
untrusted = sign('untrusted-inner', properties(), untrusted=True)
fixtures['untrustedInner'] = sign('untrusted-inner-outer', plistlib.dumps({'DER-Encoded-Profile': untrusted}, fmt=plistlib.FMT_XML))
fixtures['entitlements'] = encode({'identifier':'owned.reader', 'enabled': True, 'groups':['a','b'], 'count': -129}, entitlements=True)
fixtures['propertyValues'] = encode({'array':[True, False, 0, -1, -129, 128, 'text', b'\0\xff', None],
                                    'utc': datetime(2031,1,1), 'nested': {'key':'value'}})
lines = ['import Foundation', '', '// Public owned CMS/DER fixtures, generated with independent Python/OpenSSL; no private keys.', 'enum SelfRenewalModernProfileFixture {']
for name, value in fixtures.items():
    lines += [f'    static let {name}: Data = {{', '        let encoded = """']
    lines += ['        ' + line for line in textwrap.wrap(base64.b64encode(value).decode(), 100)]
    lines += ['        """', '        return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)!', '    }()']
lines += ['}', '']
SWIFT.write_text('\n'.join(lines), encoding='utf-8', newline='\n')
record = {'status': 'owned-CMS-and-DER-fixtures-independently-generated-no-Swift-execution',
          'validationUnixTime': verify_at, 'commands': commands,
          'fixtures': [{'name': name, 'bytes': len(value), 'sha256': hashlib.sha256(value).hexdigest()} for name, value in fixtures.items()],
          'privateKeysNotShipped': True, 'outerAndInnerPolicy': 'Modern verified DER is authoritative; unrelated legacy XML is inert',
          'signatureTrustIsGenericExplicitAnchorsOnly': True}
(OUT / 'independent-vectors.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8', newline='\n')
print(json.dumps({'fixtures': len(fixtures), 'opensslCommands': len(commands), 'swiftExecuted': False}))
