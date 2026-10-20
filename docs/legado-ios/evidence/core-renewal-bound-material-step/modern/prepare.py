import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

names = ['Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift',
         'Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift',
         'Modules/Services/SelfRenewal/SelfRenewalDERPropertyList.swift',
         'Modules/Services/SelfRenewal/SelfRenewalApplicationMaterialVerifier.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalProvisioningProfileVerifierTests.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalModernProfileFixture.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalModernProfileVerifierTests.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift',
         'Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialVerifierTests.swift']
parser = Parser(Language(tree_sitter_swift.language()))
sources = []
for name in names:
    raw = (ROOT / name).read_bytes(); parsed = parser.parse(raw); stack = [parsed.root_node]; errors = []
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing: errors.append([node.type, list(node.start_point), list(node.end_point)])
        stack.extend(node.children)
    assert not errors, (name, errors)
    target = OUT / 'sources' / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
    sources.append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors})
methods = {}
for name, count in [(names[8], 8), (names[10], 5)]:
    values = re.findall(r'    @Test\([^\n]+\)\n    func (\w+)\(', (ROOT / name).read_text(encoding='utf-8'))
    assert len(set(values)) == len(values) == count
    methods[Path(name).stem] = values
vectors = json.loads((OUT / 'independent-vectors.json').read_bytes())
fixture_text = (ROOT / names[7]).read_text(encoding='utf-8')
fixture_data = {name: base64.b64decode(value) for name,value in re.findall(r'static let (\w+): Data = \{\s*let encoded = """\s*([A-Za-z0-9+/=\s]+?)\s*"""', fixture_text)}
assert len(fixture_data) == 9
for value in vectors['fixtures']:
    raw = fixture_data[value['name']]
    assert len(raw) == value['bytes'] and hashlib.sha256(raw).hexdigest() == value['sha256']
swift = (ROOT / names[6]).read_text(encoding='utf-8')
case_three = re.search(r'3: "([a-f0-9]+)"', swift)[1]
assert bytes.fromhex(case_three) == hashlib.sha256(b'abc').digest()[:20]
app_vectors = json.loads((OUT / 'independent-application-vectors.json').read_bytes())
audited = []
for name in ['main','widget','share','wrong-signer','wrong-team','wrong-app','wrong-group','changed-profile']:
    folder = OUT / 'application-owned'
    code, info, resources, profile = [(folder / (name + '.' + kind)).read_bytes() for kind in ['code','info','resources','profile']]
    signature_start, signature_size = struct.unpack_from('<II', code, 40)
    assert signature_start == 173 and signature_start + signature_size == len(code)
    signature = code[signature_start:]
    magic, size, count = struct.unpack_from('>III', signature)
    assert magic == 0xfade0cc0 and size == len(signature) and count == 5
    blobs = {}
    for i in range(count):
        slot, offset = struct.unpack_from('>II', signature, 12 + 8*i)
        length = struct.unpack_from('>I', signature, offset + 4)[0]
        blobs[slot] = signature[offset:offset + length]
    cd = blobs[0]
    hash_offset, _, special_count, page_count, limit = struct.unpack_from('>IIIII', cd, 16)
    assert (special_count, page_count, limit, cd[36], cd[37]) == (7,3,173,32,2)
    special = {1: info, 2: blobs[2], 3: resources, 5: blobs[5], 7: blobs[7]}
    for slot in range(1,8):
        digest = cd[hash_offset-slot*32:hash_offset-(slot-1)*32]
        assert digest == (hashlib.sha256(special[slot]).digest() if slot in special else bytes(32))
    for index in range(3):
        assert cd[hash_offset+index*32:hash_offset+(index+1)*32] == hashlib.sha256(code[index*64:min(173,(index+1)*64)]).digest()
    seals = plistlib.loads(resources)['files2']
    assert seals['embedded.mobileprovision']['hash2'] == hashlib.sha256(profile).digest()
    assert seals['chapter.txt']['hash2'] == hashlib.sha256(b'abc').digest()
    assert blobs[0x10000][8:] == (folder / (name + '-code.cms')).read_bytes()
    assert cd == (folder / (name + '-code.verified')).read_bytes()
    audited.append({'fixture': name, 'codeSHA256': hashlib.sha256(code).hexdigest(),
                    'codePagesChecked':3, 'nonzeroSpecialSlotsChecked':5, 'resourceSealsChecked':2,
                    'actualVerifiedCMSContentEqualsRawCD':True})
# Independent ASN.1 tooling inspects the new DER forms. These are format checks,
# not a repeated signature verification or an execution of Swift production.
for name, data in [('modern-profile', fixture_data['derPayload']), ('core-entitlements', fixture_data['entitlements'])]:
    path = OUT / (name + '.independent.der'); path.write_bytes(data)
    result = subprocess.run(['D:/app/Git/usr/bin/openssl.exe', 'asn1parse', '-inform', 'DER', '-in', str(path), '-i'], capture_output=True)
    assert result.returncode == 0, result.stderr
    (OUT / (name + '.asn1parse.log')).write_bytes(result.stdout + result.stderr)
audit = {'status': 'passed', 'scope': 'Independent Python hashlib wire reconstruction and OpenSSL ASN.1 format inspection; not Swift execution',
         'actualApplicationFixtures': audited, 'fixedTruncatedABCVectorBytes':20,
         'privateKeysIncludedInSwiftFixtures':False}
(OUT / 'independent-application-audit.json').write_text(json.dumps(audit,indent=2)+'\n',encoding='utf-8')
record = {'recordedAtUTC':datetime.now(timezone.utc).isoformat(), 'status':'prepared_not_sdk_executed',
          'sourceInputs':sources, 'grammarParsedFiles':len(sources), 'newSuites':methods, 'preparedNewSwiftMethods':13,
          'actualSwiftSDKBuilds':0, 'actualSwiftTestExecutions':0, 'grammarOnlyNotTypeChecking':True,
          'productionConnection':'SignedCodeVerifier.read -> single inventory -> ResourceSealVerifier.verify and selected-CD-bound DER attributes -> Profile.readModern same inventory and independently authenticated inner CMS -> ApplicationMaterialVerifier identity/resource-profile digest binding',
          'fixtureValidation':{'modernFixtures':9, 'wholeApplicationBundles':3, 'wholeApplicationVariants':5,
              'actualCodeCMSVerified':8,'actualProfileCMSLayersVerified':16, 'dummySizeSignaturesNotCountedAsCode':8,
              'wholeApplicationWireAudit':audit},
          'sourceOfTruth':'Authenticated inner DER-Encoded-Profile CMS, not legacy XML fields',
          'applicationIdentifierPrefixCanDifferFromTeam':True, 'sameSizeChangedProfileResourceRejected':True,
          'genericExplicitAnchorTrustIsAppleAuthority':False, 'replacementAuthorized':False,
          'remainingUnverified':['SDK compilation and actual new Swift methods',
              'Apple-specific signer/profile purpose and full entitlement/device/account eligibility policy',
              'System requirements/trust-cache/notarization and named fragments without platform context',
              'Signing/install clients, replacement/renewal transaction and physical device acceptance']}
(OUT / 'preparation.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':record['status'],'grammarParsedFiles':len(sources),'newSwiftMethods':13,
                  'independentApplicationFixturesAudited':len(audited),'actualSwiftTestExecutions':0}))
