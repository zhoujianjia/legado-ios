from datetime import datetime, timezone
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import sys
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

files = ['Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift',
         'Modules/Services/SelfRenewal/SelfRenewalCodeDirectoryHashVerifier.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests.swift']
parser = Parser(Language(tree_sitter_swift.language()))
sources = []
for name in files:
    raw = (ROOT / name).read_bytes()
    tree = parser.parse(raw)
    errors = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing: errors.append([node.type, list(node.start_point), list(node.end_point)])
        stack.extend(node.children)
    assert not errors, (name, errors)
    snapshot = OUT / 'sources' / name
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_bytes(raw)
    sources.append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors})
tests = (ROOT / files[-1]).read_text(encoding='utf-8')
methods = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', tests)
assert len(set(methods)) == len(methods) == 7
vectors = json.loads((OUT / 'independent-digest-vectors.json').read_text(encoding='utf-8'))
declarations = {name: (int(limit), prefix, signature) for name,limit,prefix,signature in
    re.findall(r'"(\w+)": Fixture\(limit: (\d+), prefix: "([^"]+)",\s+signature: "([^"]+)"\)', tests)}
assert set(declarations) == set(vectors['fixtures'])
def be32(data, offset): return struct.unpack_from('>I', data, offset)[0]
def digest(kind, data):
    if kind == 1: return hashlib.sha1(data).digest()
    if kind == 2: return hashlib.sha256(data).digest()
    if kind == 3: return hashlib.sha256(data).digest()[:20]
    if kind == 4: return hashlib.sha384(data).digest()
    raise AssertionError(kind)
audited = []
for name, (limit, prefix, signature) in declarations.items():
    code = bytearray((index * 17 + 3) % 256 for index in range(limit))
    code[:64] = base64.b64decode(prefix)
    signature = base64.b64decode(signature)
    whole = code + signature
    expected = vectors['fixtures'][name]
    assert hashlib.sha256(whole).hexdigest() == expected['fileSHA256']
    assert struct.unpack_from('<II', code, 40) == (limit, len(signature))
    assert be32(signature, 4) == len(signature)
    members = {}
    for index in range(be32(signature, 8)):
        slot, offset = struct.unpack_from('>II', signature, 12 + index * 8)
        size = be32(signature, offset + 4)
        members[slot] = signature[offset:offset + size]
    materials = {1: base64.b64decode(vectors['infoBase64']), 3: base64.b64decode(vectors['resourcesBase64'])}
    materials.update({slot: blob for slot, blob in members.items() if slot in (2,5,7,8,9,10,11)})
    checked_pages = checked_special = 0
    for facts in expected['directories']:
        directory = members[facts['slot']]
        offset, _, specials, slots, signed_limit = struct.unpack_from('>IIIII', directory, 16)
        length, kind, _, log = directory[36:40]
        page_size = signed_limit if log == 0 else 1 << log
        assert signed_limit == limit and slots == len(facts['codePageDigests'])
        for index in range(slots):
            page = code[index * page_size:min(signed_limit, (index + 1) * page_size)]
            actual = digest(kind, page)
            assert actual == directory[offset + index * length:offset + (index + 1) * length]
            assert actual.hex() == facts['codePageDigests'][index]
            checked_pages += 1
        for slot in range(1, specials + 1):
            actual = directory[offset - slot * length:offset - (slot - 1) * length]
            if slot in facts['specialSlotDigests'] or str(slot) in facts['specialSlotDigests']:
                assert actual == digest(kind, materials[slot])
                assert actual.hex() == facts['specialSlotDigests'][str(slot)]
                checked_special += 1
            else: assert actual == bytes(length)
    audited.append({'fixture': name, 'fileSHA256': expected['fileSHA256'],
                    'checkedCodePageDigests': checked_pages, 'checkedNonzeroSpecialDigests': checked_special})
(OUT / 'independent-fixture-audit.json').write_text(json.dumps({'status':'passed',
    'scope':'Fixture reconstruction and Python hashlib expectations only, not Swift execution', 'fixtures':audited},indent=2)+'\n',encoding='utf-8',newline='\n')
references = []
for filename, url in {
    'codedirectory.cpp': 'https://raw.githubusercontent.com/apple-oss-distributions/Security/main/OSX/libsecurity_codesigning/lib/codedirectory.cpp',
    'codedirectory.h': 'https://raw.githubusercontent.com/apple-oss-distributions/Security/main/OSX/libsecurity_codesigning/lib/codedirectory.h',
    'StaticCode.cpp': 'https://raw.githubusercontent.com/apple-oss-distributions/Security/main/OSX/libsecurity_codesigning/lib/StaticCode.cpp',
}.items():
    destination = OUT / 'primary' / filename
    destination.parent.mkdir(parents=True,exist_ok=True)
    if not destination.exists():
        with urlopen(Request(url,headers={'User-Agent':'Yuedu-owned-content-hash-review'}),timeout=30) as response:
            raw = response.read(1048577)
            assert len(raw) <= 1048576
        destination.write_bytes(raw)
    raw=destination.read_bytes()
    references.append({'url':url,'path':str(destination.relative_to(ROOT)).replace('\\','/'),
                       'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
result = {'recordedAtUTC':datetime.now(timezone.utc).isoformat(), 'status':'prepared_not_sdk_executed',
          'sourceInputs':sources,'grammarParsedFiles':4,'preparedNewSwiftMethods':methods,
          'preparedNewSwiftTests':7,'existingStructureTestsUnchanged':9,
          'actualSwiftSDKBuilds':0,'actualSwiftTestExecutions':0,
          'fixtureAudit':{'fixtures':len(audited),'producer':'independent Python hashlib, no Swift verifier used'},
          'productionConnection':'SelfRenewalCodeDirectoryHashVerifier.read -> original inventory -> same reader worker/openat code FD -> parse + page/special digests -> fstat recheck',
          'algorithms':['SHA1','SHA256','first 20 bytes of SHA256','SHA384'],
          'bounds':{'contentReadBytes':268435456,'hashOperations':262144,'chunkBytes':65536,
                    'specialMaterialBytes':2097152,'knownSpecialSlots':11},
          'originalStructureBudgetIncreased':False,'originalInventoryBudgetIncreased':False,
          'callerOwnedQuiescentUnpackedApplicationRequired':True,'atomicSealingClaimed':False,
          'realAccountsIPAsOrDeviceMaterialsUsed':False,
          'remainingUnverified':['CMS authentication and certificate trust','Apple provisioning authority and entitlement/device eligibility',
                                 'CodeResources rules and actual resource-tree seals','scatter/pre-encrypted/linkage formats',
                                 'signer/installer/replacement/automatic renewal'],
          'replacementTrustedAdapterConstructed':False,'primaryReferences':references}
(OUT / 'preparation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps({'status':result['status'],'grammarParsedFiles':4,'preparedNewSwiftTests':7,
                  'actualSwiftTestExecutions':0,'independentFixturesAudited':len(audited),'sourceInputs':sources}))
