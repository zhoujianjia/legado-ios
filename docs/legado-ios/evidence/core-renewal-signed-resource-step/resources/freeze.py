import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

names = ['Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift',
         'Modules/Services/SelfRenewal/SelfRenewalResourceSealVerifier.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalMaterialInventoryTests.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalResourceFixture.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalResourceSealVerifierTests.swift']
parser = Parser(Language(tree_sitter_swift.language()))
sources = []
for name in names:
    raw = (ROOT / name).read_bytes()
    tree = parser.parse(raw)
    errors = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append([node.type, list(node.start_point), list(node.end_point)])
        stack.extend(node.children)
    assert not errors, (name, errors)
    target = OUT / 'sources' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw)
    sources.append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors})
swift = (ROOT / names[-1]).read_text(encoding='utf-8')
methods = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', swift)
assert len(set(methods)) == len(methods) == 10
fixture = (ROOT / names[-2]).read_text(encoding='utf-8')
parts = {name: base64.b64decode(value) for name, value in re.findall(r'static let (\w+)Base64 = "([^"]+)"', fixture)}
record = json.loads((OUT / 'independent-fixture.json').read_text(encoding='utf-8'))
assert hashlib.sha256(parts['info']).hexdigest() == record['infoSHA256']
assert hashlib.sha256(parts['envelope']).hexdigest() == record['envelopeSHA256']
assert hashlib.sha256(parts['machO']).hexdigest() == record['machOSHA256']
envelope = plistlib.loads(parts['envelope'])
contents = {'chapter.txt': b'abc', 'empty.dat': b'', 'Resources/large.dat': bytes((i * 13 + 7) % 256 for i in range(131_077))}
assert set(contents) == set(envelope['files2'])
for name, content in contents.items():
    assert hashlib.sha256(content).digest() == envelope['files2'][name]['hash2']
code = parts['machO']
sig_start, sig_size = struct.unpack_from('<II', code, 40)
assert sig_start == 173 and sig_start + sig_size == len(code)
magic, total, count = struct.unpack_from('>III', code, sig_start)
assert (magic, total, count) == (0xfade0cc0, sig_size, 2)
slot, offset = struct.unpack_from('>II', code, sig_start + 12)
assert slot == 0
cd = code[sig_start + offset:]
length = struct.unpack_from('>I', cd, 4)[0]
cd = cd[:length]
assert hashlib.sha256(cd).hexdigest() == record['codeDirectorySHA256']
hash_offset, _, specials, slots, limit = struct.unpack_from('>IIIII', cd, 16)
assert (specials, slots, limit) == (3, 3, 173)
for slot, data in {1: parts['info'], 3: parts['envelope']}.items():
    assert cd[hash_offset - slot * 32:hash_offset - (slot - 1) * 32] == hashlib.sha256(data).digest()
assert cd[hash_offset - 64:hash_offset - 32] == bytes(32)
for index in range(slots):
    assert cd[hash_offset + index * 32:hash_offset + (index + 1) * 32] == hashlib.sha256(code[index * 64:min(limit, (index + 1) * 64)]).digest()
for name, data in [('abc', b'abc'), ('empty', b''), ('large', contents['Resources/large.dat'])]:
    expected = record['vectors'][name]
    actual = {'1': hashlib.sha1(data).hexdigest(), '2': hashlib.sha256(data).hexdigest(),
              '3': hashlib.sha256(data).digest()[:20].hex(), '4': hashlib.sha384(data).hexdigest()}
    assert actual == expected
references = []
for name in ('resources.cpp', 'StaticCode.cpp', 'bundlediskrep.cpp'):
    url = 'https://raw.githubusercontent.com/apple-oss-distributions/Security/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_codesigning/lib/' + name
    target = OUT / 'primary' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        with urlopen(Request(url, headers={'User-Agent': 'Yuedu-owned-resource-review'}), timeout=30) as response:
            raw = response.read(1_048_577)
        assert len(raw) <= 1_048_576
        target.write_bytes(raw)
    raw = target.read_bytes()
    references.append({'url': url, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
result = {'recordedAtUTC': datetime.now(timezone.utc).isoformat(), 'status': 'prepared_not_sdk_executed',
          'sourceInputs': sources, 'preparedNewSwiftMethods': methods, 'preparedNewSwiftTests': 10,
          'existingInventoryMethodIdentitiesRevalidatedOnNextSDK': 6, 'actualSwiftSDKBuilds': 0, 'actualSwiftTestExecutions': 0,
          'grammarOnlyNotTypeChecking': True, 'independentPythonFixtureAudit': {'passed': True, 'digestVectors': 12,
          'actualResourceSeals': 3, 'actualCodePages': 3, 'actualExternalSpecialSlots': [1, 3]},
          'productionConnection': 'Existing content-hash inventory -> same nofollow owned-file helper -> exact CodeDirectory SHA256 re-read and actual envelope slot3 -> original POSIX weighted traversal -> streamed real resource digests',
          'chunkBytes': 65_536, 'resourceAndEnvelopeReadBudgetBytes': 2_147_483_648, 'codeDirectoryReadBudgetBytes': 67_108_864,
          'quiescentOwnedStagingRequired': True, 'atomicConcurrentMutationSealClaimed': False,
          'primaryReferences': references, 'remainingUnverified': ['Nested code designated-requirement evaluation and nested authority',
          'Strict Apple resource policy and signature-metadata directory policy', 'Apple provisioning/entitlement/account authorization',
          'Signer/installer/automatic renewal and real-device acceptance']}
(OUT / 'preparation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'status': result['status'], 'parsedFiles': len(sources), 'preparedMethods': len(methods),
                  'independentFixtureAuditPassed': True, 'actualSwiftTestExecutions': 0}))
