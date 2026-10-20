from datetime import datetime, timezone
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

files = ['Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift',
         'Modules/Services/SelfRenewal/SelfRenewalCodeDirectoryHashVerifier.swift',
         'Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift',
         'Modules/Services/SelfRenewal/SelfRenewalSignedCodeVerifier.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalSignedCodeFixture.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalSignedCodeVerifierTests.swift']
regression_files = ['Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift',
                    'Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift',
                    'Tests/iOS/yuedu appTests/SelfRenewalProvisioningProfileVerifierTests.swift',
                    'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift',
                    'Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift']
parser = Parser(Language(tree_sitter_swift.language()))
sources = []
for name in files + regression_files:
    raw = (ROOT / name).read_bytes()
    tree = parser.parse(raw)
    errors, stack = [], [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing: errors.append([node.type, list(node.start_point), list(node.end_point)])
        stack.extend(node.children)
    assert not errors, (name, errors)
    target = OUT / 'sources' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(raw)
    sources.append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors,
                    'modifiedInThisStep': name in files})
test = (ROOT / files[-1]).read_text(encoding='utf-8')
methods = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', test)
assert len(methods) == len(set(methods)) == 7
old_counts = {}
for name, count in [(files[4], 7), (regression_files[0], 9), (regression_files[1], 7), (regression_files[2], 2)]:
    definitions = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', (ROOT / name).read_text(encoding='utf-8'))
    assert len(definitions) == count
    old_counts[Path(name).stem] = count

vectors = json.loads((OUT / 'independent-owned-vectors.json').read_text(encoding='utf-8'))
fixture_source = (ROOT / files[5]).read_text(encoding='utf-8')
declarations = {name: (prefix, signature) for name, prefix, signature in re.findall(r'"(\w+)": \("([^"]+)",\s+"([^"]+)"\)', fixture_source)}
assert set(declarations) == set(vectors['fixtures'])
def u32(data, offset): return struct.unpack_from('>I', data, offset)[0]
def digest(kind, data):
    if kind == 1: return hashlib.sha1(data).digest()
    if kind == 2: return hashlib.sha256(data).digest()
    if kind == 3: return hashlib.sha256(data).digest()[:20]
    if kind == 4: return hashlib.sha384(data).digest()
    raise AssertionError(kind)
INFO = b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>owned.reader</string><key>CFBundleExecutable</key><string>Owned</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>'
RESOURCES = b'owned raw CodeResources bytes; resource envelope intentionally unverified'
audited = []
for name, (prefix, signature) in declarations.items():
    code = bytearray((index * 17 + 3) % 256 for index in range(173))
    code[:64] = base64.b64decode(prefix)
    signature = base64.b64decode(signature)
    whole = code + signature
    facts = vectors['fixtures'][name]
    assert hashlib.sha256(whole).hexdigest() == facts['fileSHA256']
    assert whole == (OUT / 'owned' / f'{name}.macho').read_bytes()
    assert struct.unpack_from('<II', code, 40) == (173, len(signature))
    assert u32(signature, 4) == len(signature)
    members = {}
    for index in range(u32(signature, 8)):
        slot, offset = struct.unpack_from('>II', signature, 12 + index * 8)
        size = u32(signature, offset + 4)
        members[slot] = signature[offset:offset + size]
    materials = {1: INFO, 3: RESOURCES, **{slot: value for slot, value in members.items() if slot in (2,5,7)}}
    pages = specials = 0
    for directory in facts['directories']:
        raw = members[directory['slot']]
        assert hashlib.sha256(raw).hexdigest() == directory['rawCodeDirectorySHA256']
        kind = raw[37]
        assert kind == directory['hashType']
        assert digest(kind, raw).hex() == directory['fullCDHash']
        assert digest(kind, raw)[:20].hex() == directory['cdhash']
        hashes, _, special_count, page_count, limit = struct.unpack_from('>IIIII', raw, 16)
        width, _, _, page = raw[36:40]
        assert page_count == 3 and limit == 173 and page == 6
        for slot in range(page_count):
            actual = digest(kind, code[slot*64:min(173,(slot+1)*64)])
            assert actual == raw[hashes+slot*width:hashes+(slot+1)*width]
            pages += 1
        for slot in range(1, special_count + 1):
            expected = raw[hashes-slot*width:hashes-(slot-1)*width]
            assert expected == (digest(kind, materials[slot]) if slot in materials else bytes(width))
            if slot in materials: specials += 1
    if name != 'adHoc':
        assert members[0x10000][8:] == (OUT/'owned'/f'{name}.cms').read_bytes()
        assert members[0] == (OUT/'owned'/f'{name}.primary.cd').read_bytes()
        assert members[0] == (OUT/'owned'/f'{name}.verified.cd').read_bytes()
        assert facts['opensslChangedPrimaryRejected'] is True
    audited.append({'fixture': name, 'fileSHA256': facts['fileSHA256'], 'independentPageDigestsChecked': pages,
                    'independentNonzeroSpecialDigestsChecked': specials,
                    'opensslDetachedCMSVerified': name != 'adHoc', 'swiftExecuted': False})

result = {
    'recordedAtUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'prepared_not_sdk_executed',
    'sourceInputs': sources, 'grammarParsedFiles': len(sources),
    'newSwiftSuite': 'SelfRenewalSignedCodeVerifierTests', 'preparedNewSwiftMethods': methods,
    'preparedNewSwiftTests': len(methods), 'preservedOriginalSwiftSuites': old_counts,
    'actualSwiftSDKBuilds': 0, 'actualSwiftTestExecutions': 0,
    'fixtureAudit': audited, 'opensslValidDetachedSignatures': 11, 'opensslChangedRawPrimaryRejections': 11,
    'productionConnection': 'SignedCodeVerifier.read -> Inventory -> cancellable detached reader worker -> same checked executable FD -> structure+all page/special digests -> raw CD SHA256 recheck -> exact raw primary detached CMS+signedAttrs -> final fstat -> publish',
    'genericExplicitAnchorsOnly': True, 'appleSigningAuthorityEstablished': False,
    'provisioningProfileAuthorized': False, 'resourceTreeVerified': False, 'replacementAuthorized': False,
    'acceptanceContract': {
        'primaryRawSlotZero': True, 'firstSignerAgility': True, 'alternateStopFirstMissing': True,
        'duplicateLoadedHashTypesRejected': True, 'bestHashPriority': [4,2,3,1],
        'adHocSelectedDirectorySkipsCMSButNeverClaimsAuthentication': True,
        'missingAgilityPreservesPrimaryOnlyAuthentication': True,
        'v1': 'one OCTET STRING containing plist dictionary cdhashes; exact ascending loaded hashType array of canonical <=20-byte digests; unknown plist keys accepted',
        'v2': 'SET values SEQUENCE(OID,OCTET STRING); no AlgorithmIdentifier wrapper; duplicate algorithm OIDs/count mismatch reject; all full actual CD hasher outputs match',
        'hashTypeThreeFullCDHashBytes': 20,
        'hashTypesTwoAndThreeV2OIDCollision': 'actual original dictionary collision rejected, not blanket rejection of hashType3',
    },
    'sharedOwnedFileIO': {'zeroBudgetAllowed': True, 'perReadBytes': 65536, 'maximumTotalReadBytes': 1073741824,
                           'readOwnedMaterialHardCapBytes': 2097152, 'openatNoFollow': True, 'regularWithoutHardLinks': True,
                           'beforeAfterFDIdentityRecheck': True, 'callerOwnedQuiescentRequired': True, 'atomicSealClaimed': False},
    'originalInventoryOrStructureBudgetsIncreased': False,
    'realAccountsIPAsOrDeviceMaterialsUsed': False,
    'primaryReferences': json.loads((OUT/'primary/references.json').read_text(encoding='utf-8')),
    'remainingUnverified': ['Apple-specific signing/provisioning policy, profile DER/entitlement/device/application matching',
                            'CodeResources resource tree authorization and nested-code requirements (separate root work)',
                            'timestamp/revocation authority and unsupported CMS encodings or algorithms',
                            'scatter/pre-encrypted/linkage code directory formats',
                            'actual SDK build/tests and installer/replacement/automatic-renewal integration'],
    'ciOrGitTouchedInThisStep': False,
}
(OUT/'preparation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps({'status':result['status'], 'grammarParsedFiles':len(sources), 'newMethods':len(methods),
                  'fixtureAuditCount':len(audited), 'opensslVerified':11, 'opensslChangedPrimaryRejected':11,
                  'swiftOrSDKExecution':0, 'modifiedSources': [x for x in sources if x['modifiedInThisStep']]}))
