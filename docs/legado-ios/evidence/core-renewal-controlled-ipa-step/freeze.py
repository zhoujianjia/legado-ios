from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift
parser = Parser(Language(tree_sitter_swift.language()))

mapping = {
    'SelfRenewalIPAArchiveValidator.swift': 'Modules/Services/SelfRenewal/SelfRenewalIPAArchiveValidator.swift',
    'SelfRenewalIPAUnpacker.swift': 'Modules/Services/SelfRenewal/SelfRenewalIPAUnpacker.swift',
    'SelfRenewalIPAArchiveFixture.swift': 'Tests/iOS/yuedu appTests/SelfRenewalIPAArchiveFixture.swift',
    'SelfRenewalIPAUnpackerTests.swift': 'Tests/iOS/yuedu appTests/SelfRenewalIPAUnpackerTests.swift',
}
sources = []
for source, target in mapping.items():
    raw = (OUT / 'work' / source).read_bytes()
    tree = parser.parse(raw)
    stack, errors = [tree.root_node], []
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append({'kind': node.type, 'start': list(node.start_point), 'end': list(node.end_point)})
        stack.extend(node.children)
    assert not errors, (source, errors)
    destination = ROOT / target
    if destination.exists():
        assert destination.read_bytes() == raw, 'Refuse to replace a separately modified source: ' + target
    else:
        destination.write_bytes(raw)
    snapshot = OUT / 'sources' / target
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_bytes(raw)
    sources.append({'path': target, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors})

test_source = (OUT / 'work/SelfRenewalIPAUnpackerTests.swift').read_text()
methods = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', test_source)
assert len(methods) == len(set(methods)) == 9
fixtures = json.loads((OUT / 'fixture-generation.json').read_text())
assert len(fixtures['archives']) == 3 and fixtures['sdkTestsExecuted'] == 0
for item in fixtures['archives']:
    raw = (OUT / item['path']).read_bytes()
    assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']

dependency = json.loads((ROOT / 'Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
pin = next(pin for pin in dependency['pins'] if pin['identity'] == 'zipfoundation')
assert pin['state'] == {'revision': 'adb49c8bfe060cc187370b12fa081012a6440b86', 'version': '3.0.1'}
primary = json.loads((OUT / 'primary/sources.json').read_text())
for item in primary:
    assert 'error' not in item
    raw = (OUT / 'primary' / item['path']).read_bytes()
    assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']
reuse = []
for path in ['Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift',
             'Modules/Services/SelfRenewal/SelfRenewalApplicationMaterialVerifier.swift',
             'Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift',
             'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift']:
    raw = (ROOT / path).read_bytes()
    reuse.append({'path': path, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'modifiedInThisStep': False})

grammar = {'schema': 1, 'files': sources, 'sourceCount': 4, 'errors': 0,
           'meaning': 'Syntax grammar only; no Swift typecheck or SDK execution.'}
(OUT / 'grammar.json').write_text(json.dumps(grammar, indent=2) + '\n')
record = {
    'schema': 1, 'stage': 'S1 controlled IPA bounded snapshot and extraction to existing sealed application materials',
    'frozenAtUTC': datetime.now(timezone.utc).isoformat(),
    'earlierSDKSourceExcludesTheseFiles': '478b69d6a1074e9a1d82c2b55e522b0d39e23f8a',
    'sourceBinding': {'files': sources, 'count': 4, 'snapshots': 'sources/'},
    'unchangedReusedMaterialsAndFixtureSources': reuse,
    'dependency': {'identity': pin['identity'], 'location': pin['location'], **pin['state'], 'module': 'ReadiumZIPFoundation',
                   'otherExistingModule': 'zlib', 'newDependencies': 0, 'primarySources': primary},
    'preparedNativeTests': {'suite': 'SelfRenewalIPAUnpackerTests', 'methodCount': 9,
                           'methods': [name + '()' for name in methods], 'executedSDKMethods': 0, 'acceptedSDKMethods': 0},
    'localValidation': {'swiftGrammarFiles': 4, 'swiftGrammarErrors': 0, 'swiftTypecheck': False,
        'ownedIPAsActuallyReadWithPythonZipfileAndRawZlib': 3, 'membersPerIPA': 15,
        'negativeRawDeflateBoundariesActuallyCheckedWithPython': 2,
        'swiftBuildOrExecution': False, 'simulatorTests': False, 'deviceTests': False},
    'limits': {'archiveBytes': 268435456, 'entries': 8192, 'heldDirectoryDescriptorsIncludingStagingRoot': 128,
        'centralDirectoryBytes': 8388608, 'compressedEntryBytes': 67108864, 'expandedEntryBytes': 134217728,
        'totalExpandedBytes': 536870912, 'pathBytes': 1024, 'pathDepth': 24, 'pathComponentBytes': 255,
        'extraBytes': 4096, 'entryAndArchiveCommentBytes': 4096, 'chunkBytes': 65536,
        'compressionRatio': 'expanded <= max(1,compressed)*200 + 65536', 'snapshotReadCalls': 500000,
        'snapshotReadBytes': 'archiveBytes*4 + centralDirectoryByteLimit*8 + chunkByteLimit*2'},
    'implemented': [
        'Read-only O_NOFOLLOW source FD, single-link regular file, stable device/inode/size/mode/mtime/ctime before and after copy and path identity comparison.',
        'Fresh private 0700 staging directory; archive copied once, hashed, reopened read-only and unlinked, then accessed through pinned custom Readium DataSource.',
        'Classic EOCD, central and local fields, descriptors, unique raw paths, normalized/casefold collision and parent-file conflict checks precede entry extraction.',
        'All compressed entry streams are independently checked for exact raw-deflate end/no tail, declared output size and CRC before creating extracted files.',
        'Readium entries must exactly match the preflight plan; only its consumer API is used, never extract(to:). Returned extraction CRC and actual sink length are compared.',
        'Directories and files use parent FDs plus mkdirat/openat/O_EXCL/O_NOFOLLOW and fixed private modes. Archive owner/permissions/timestamps are never applied.',
        'Explicit cancellation propagation, bounded reader operations/bytes and actual output checks, worker execution and SourcePerfTrace bytes/main details.',
        'Actual SelfRenewalApplicationMaterialVerifier.read calls the existing inventory, CMS, resources, nested requirements and modern profile identity path.',
        'Success returns a fileprivate-initialized result containing real sealed materials plus source archive digest. No mutable staging URL is exported.',
        'Success and failure clean only recorded owned names/inodes using pinned parent FDs and unlinkat, never caller directories or recursive arbitrary paths.',
    ],
    'unsupportedAndUnfinished': [
        'Only one Payload/<name>.app subtree is accepted; unrelated IPA roots, ZIP64, split archives, encryption, other compression methods and unknown creator OS are rejected.',
        'Non-ASCII names require UTF-8 flag; CP437 non-ASCII, alternate path extra fields, special files, links and unselected extra fields are rejected.',
        'Accepted extras are only 0x5455, 0x7875, 0x5855 and 0x000a; ignored metadata never affects the output tree.',
        'Directory count is deliberately limited to 127 archive directories plus staging root, rather than holding an unbounded number of FDs.',
        'Four new files are not in earlier 478b69d source or its pending 78-method SDK result. All nine new native methods remain definitions pending a later centralized SDK run.',
        'Python fixture checks prove only their own ZIP bytes/decompression; they do not run the Swift implementation or repeat cryptographic verifier acceptance.',
        'This endpoint returns checked read-only materials and removes staging. No signing mutation, transport, installation, account, device eligibility or replacement authorization is established.',
        'No integration or changes to existing verifier interfaces, CI, canonical docs or Git were made in this stage.',
    ],
    'authorizationClaims': {'appleSigningAuthorityEstablished': False, 'accountIdentityEstablished': False,
                            'deviceEligibilityEstablished': False, 'replacementAuthorized': False},
    'privateData': {'actualUserIPARead': False, 'realCredentialsRead': False, 'privateBookSourcesRead': False, 'privateKeysGeneratedOrRead': False},
    'evidence': [],
}
for name in ['grammar.json', 'fixture-generation.json', 'generate-owned-fixtures.py', 'freeze.py', 'primary/sources.json']:
    raw = (OUT / name).read_bytes()
    record['evidence'].append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
raw = json.dumps(record, indent=2).encode() + b'\n'
(OUT / 'preparation.json').write_bytes(raw)
print(json.dumps({'status': 'new-stage-prepared-not-SDK-accepted', 'newSources': len(sources), 'grammarErrors': 0,
    'nativeMethodsDefined': len(methods), 'nativeMethodsExecuted': 0, 'ownedPythonIPAsVerified': len(fixtures['archives']),
    'preparationBytes': len(raw), 'preparationSHA256': hashlib.sha256(raw).hexdigest(), 'methods': methods}))
