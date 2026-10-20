import ast
import base64
from datetime import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
OWNED = OUT / 'application-owned'
PKI = ROOT / '.build/renewal-discovery/cms-profile-step/owned'
OPENSSL = 'D:/app/Git/usr/bin/openssl.exe'
SWIFT = ROOT / 'Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift'
assert not OWNED.exists() and not SWIFT.exists()
OWNED.mkdir()
producer = OUT / 'generate-fixtures.py'
tree = ast.parse(producer.read_text(encoding='utf-8'))
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ('tlv', 'encode')]
assert len(functions) == 2
exec(compile(ast.Module(body=functions, type_ignores=[]), str(producer), 'exec'))
verify_at = int(re.search(r'Date\(timeIntervalSince1970: (\d+)\)', (ROOT / 'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift').read_text(encoding='utf-8'))[1])
commands = []
def run(*args):
    result = subprocess.run([OPENSSL, *map(str, args)], capture_output=True)
    record = {'arguments': list(map(str, args)), 'exitCode': result.returncode,
              'stdout': result.stdout.decode('utf-8', errors='replace'), 'stderr': result.stderr.decode('utf-8', errors='replace')}
    commands.append(record)
    assert result.returncode == 0, record
def sign(name, content, *, detached=False):
    payload = OWNED / (name + '.payload')
    destination = OWNED / (name + '.cms')
    payload.write_bytes(content)
    args = ['cms', '-sign', '-binary', '-in', payload, '-signer', PKI / 'leaf.pem', '-inkey', PKI / 'leaf.key',
            '-certfile', PKI / 'root.pem', '-md', 'sha256', '-outform', 'DER', '-out', destination]
    if not detached: args.append('-nodetach')
    run(*args)
    args = ['cms', '-verify', '-binary', '-inform', 'DER', '-in', destination, '-CAfile', PKI / 'root.pem',
            '-purpose', 'any', '-attime', str(verify_at), '-out', OWNED / (name + '.verified')]
    if detached: args += ['-content', payload]
    run(*args)
    assert (OWNED / (name + '.verified')).read_bytes() == content
    return destination.read_bytes()
def wrap(magic, data): return struct.pack('>II', magic, len(data) + 8) + data
def profile(name, identifier, *, wrong_hash=False, changed_uuid=False):
    entitlements = {'application-identifier': 'OLDPREFIX.' + identifier, 'com.apple.developer.team-identifier': 'FIXTURE123',
                    'keychain-access-groups': ['OLDPREFIX.*'], 'com.apple.security.application-groups': ['group.test.owned.reader'], 'get-task-allow': True}
    values = {'UUID': 'b1111111-2222-3333-4444-555555555555' if changed_uuid else '11111111-2222-3333-4444-555555555555',
              'CreationDate': datetime(2026,10,19), 'ExpirationDate': datetime(2031,1,1),
              'TeamIdentifier': ['FIXTURE123'], 'ApplicationIdentifierPrefix': ['OLDPREFIX'],
              'DeveloperCertificates': [bytes([0x44])*32 if wrong_hash else hashlib.sha256((PKI / 'leaf.der').read_bytes()).digest()],
              'Platform': ['iOS'], 'ProvisionedDevices': ['OWNED-FIXTURE-DEVICE']}
    pairs = [tlv(0x30, encode(key) + encode(value)) for key, value in values.items()]
    pairs.append(tlv(0x30, encode('Entitlements') + encode(entitlements, entitlements=True)))
    inner = sign(name + '-profile-inner', tlv(0x31, b''.join(sorted(pairs))))
    return sign(name + '-profile-outer', plistlib.dumps({'DER-Encoded-Profile': inner}, fmt=plistlib.FMT_XML))
def bundle(name, identifier, path='.', point=None, *, wrong_hash=False, wrong_team=False, wrong_app=False, wrong_group=False, changed_uuid=False):
    metadata = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Owned', 'CFBundleShortVersionString': '1.0',
                'CFBundleVersion': '12', 'CFBundlePackageType': 'APPL' if point is None else 'XPC!'}
    if point: metadata['NSExtension'] = {'NSExtensionPointIdentifier': point}
    info = plistlib.dumps(metadata, fmt=plistlib.FMT_XML, sort_keys=True)
    mobile = profile(name, identifier, wrong_hash=wrong_hash, changed_uuid=changed_uuid)
    claims = {'application-identifier': ('BADPREFIX.' if wrong_app else 'OLDPREFIX.') + identifier,
              'com.apple.developer.team-identifier': 'OTHERTEAM' if wrong_team else 'FIXTURE123',
              'keychain-access-groups': ['OLDPREFIX.' + identifier, 'OLDPREFIX.shared'],
              'com.apple.security.application-groups': ['group.other' if wrong_group else 'group.test.owned.reader'], 'get-task-allow': True}
    xml = wrap(0xfade7171, plistlib.dumps(claims, fmt=plistlib.FMT_XML, sort_keys=True))
    der = wrap(0xfade7172, encode(claims, entitlements=True))
    requirements = wrap(0xfade0c01, struct.pack('>I', 0))
    files = {'embedded.mobileprovision': {'hash2': hashlib.sha256(mobile).digest()}, 'chapter.txt': {'hash2': hashlib.sha256(b'abc').digest()}}
    rules = {'^.*': True, '^Info[.]plist$': {'omit': True, 'weight': 20}}
    if path == '.':
        rules['^PlugIns/[^/]+[.]appex$'] = {'nested': True, 'weight': 10}
        files.update({'PlugIns/W.appex': {'requirement': 'identifier "test.owned.reader.widget"'},
                      'PlugIns/S.appex': {'requirement': 'identifier "test.owned.reader.share"'}})
    resources = plistlib.dumps({'files': {}, 'rules': {}, 'files2': files, 'rules2': rules}, fmt=plistlib.FMT_XML, sort_keys=True)
    identity = identifier.encode() + b'\0FIXTURE123\0'
    cd_size = 52 + len(identity) + 10*32
    predicted = sign(name + '-size-prediction', bytes(cd_size), detached=True)
    signature_size = 12 + 5*8 + cd_size + len(requirements) + len(xml) + len(der) + 8 + len(predicted)
    code = bytearray((i*17 + 3)%256 for i in range(173))
    code[:64] = bytes(64)
    struct.pack_into('<IIIIIIII', code, 0, 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0)
    struct.pack_into('<IIII', code, 32, 0x1d, 16, 173, signature_size)
    cd = bytearray(52)
    cd.extend(identity)
    hash_offset = len(cd) + 7*32
    struct.pack_into('>IIIIIIIII', cd, 0, 0xfade0c02, cd_size, 0x20200, 0, hash_offset, 52, 7, 3, 173)
    cd[36:40] = bytes([32, 2, 0, 6])
    struct.pack_into('>I', cd, 48, 52 + len(identifier.encode()) + 1)
    special = {1: info, 2: requirements, 3: resources, 5: xml, 7: der}
    for slot in range(7, 0, -1): cd.extend(hashlib.sha256(special[slot]).digest() if slot in special else bytes(32))
    for offset in range(0,173,64): cd.extend(hashlib.sha256(code[offset:min(173,offset+64)]).digest())
    assert len(cd) == cd_size
    cms = sign(name + '-code', bytes(cd), detached=True)
    assert len(cms) == len(predicted)
    parts = [(0, bytes(cd)), (2, requirements), (5, xml), (7, der), (0x10000, wrap(0xfade0b01, cms))]
    signature = bytearray(struct.pack('>III', 0xfade0cc0, signature_size, len(parts)))
    offset = 12 + 8*len(parts)
    for slot, part in parts: signature.extend(struct.pack('>II', slot, offset)); offset += len(part)
    for _, part in parts: signature.extend(part)
    assert len(signature) == signature_size
    result = {'relativePath': path, 'identifier': identifier, 'info': info, 'profile': mobile, 'resources': resources, 'code': bytes(code)+signature}
    for key in ('info', 'profile', 'resources', 'code'): (OWNED / (name + '.' + key)).write_bytes(result[key])
    return result
bundles = [bundle('main', 'test.owned.reader'),
           bundle('widget', 'test.owned.reader.widget', 'PlugIns/W.appex', 'com.apple.widgetkit-extension'),
           bundle('share', 'test.owned.reader.share', 'PlugIns/S.appex', 'com.apple.share-services')]
variants = {'wrongSigner': bundle('wrong-signer', 'test.owned.reader', wrong_hash=True),
            'wrongTeam': bundle('wrong-team', 'test.owned.reader', wrong_team=True),
            'wrongApplication': bundle('wrong-app', 'test.owned.reader', wrong_app=True),
            'wrongGroup': bundle('wrong-group', 'test.owned.reader', wrong_group=True),
            'changedProfile': bundle('changed-profile', 'test.owned.reader', changed_uuid=True)}
lines = ['import Foundation', '', '// Independently signed owned app and two extensions; public materials only.', 'enum SelfRenewalApplicationMaterialFixture {',
         '    struct Bundle {', '        let relativePath: String', '        let identifier: String']
for key in ('info', 'profile', 'resources', 'code'): lines.append(f'        let {key}Base64: String')
lines += ['    }', '    static let bundles: [Bundle] = [']
def declaration(value):
    result = [f'Bundle(relativePath: "{value["relativePath"]}", identifier: "{value["identifier"]}",']
    for key in ('info', 'profile', 'resources', 'code'):
        result += [f'    {key}Base64: """']
        result += ['    ' + part for part in textwrap.wrap(base64.b64encode(value[key]).decode(), 100)]
        result += ['    """' + (')' if key == 'code' else ',')]
    return '\n'.join(result)
for value in bundles: lines += ['        ' + line for line in (declaration(value) + ',').splitlines()]
lines += ['    ]']
for key, value in variants.items():
    parts = declaration(value).splitlines()
    lines.append(f'    static let {key} = ' + parts[0])
    lines += ['    ' + part for part in parts[1:]]
lines += ['}', '']
SWIFT.write_text('\n'.join(lines), encoding='utf-8', newline='\n')
record = {'producer': 'independent Python stdlib wire layouts + OpenSSL actual CMS; no Swift executed',
          'pureDEREncoderProducer': {'path': producer.relative_to(ROOT).as_posix(), 'sha256': hashlib.sha256(producer.read_bytes()).hexdigest()},
          'validationUnixTime': verify_at, 'commands': commands,
          'bundles': [{k: (v if isinstance(v,str) else {'bytes': len(v), 'sha256': hashlib.sha256(v).hexdigest()}) for k,v in b.items()} for b in bundles],
          'variants': {name: {k: (v if isinstance(v,str) else {'bytes': len(v), 'sha256': hashlib.sha256(v).hexdigest()}) for k,v in b.items()} for name,b in variants.items()},
          'realCodeCMSVerified': 8, 'realProfileCMSLayersVerified': 16, 'dummySizePredictionSignaturesNotCountedAsCode': 8,
          'rawPrivateKeysCopied': False}
(OUT / 'independent-application-vectors.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8', newline='\n')
print(json.dumps({'bundles': 3, 'variants': 5, 'actualCodeCMS': 8, 'actualProfileCMSLayers': 16, 'swiftExecuted': False}))
