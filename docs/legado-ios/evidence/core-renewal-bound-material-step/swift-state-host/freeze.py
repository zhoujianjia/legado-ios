from datetime import datetime, timezone
import base64
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

FILES = [
    'Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift',
    'Modules/Core/RuleEngine/ModernParser/BookSourceRuntimeStateStore.swift',
    'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift',
    'Modules/Core/RuleEngine/ModernParser/JS/LegadoCacheBridge.swift',
    'Modules/Services/Online/LegadoPersistentStateHost.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Tests/iOS/yuedu appTests/LegadoPersistentStateHostTests.swift',
]

parser = Parser(Language(tree_sitter_swift.language()))
sources = []
for name in FILES:
    raw = (ROOT / name).read_bytes()
    tree = parser.parse(raw)
    errors, stack = [], [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append({'type': node.type, 'start': list(node.start_point), 'end': list(node.end_point)})
        stack.extend(node.children)
    assert not errors, (name, errors)
    copy = OUT / 'sources' / name
    copy.parent.mkdir(parents=True, exist_ok=True)
    copy.write_bytes(raw)
    sources.append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors})

test = (ROOT / FILES[-1]).read_text(encoding='utf-8')
methods = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', test)
assert len(methods) == len(set(methods)) == 9
assert 'Task.detached' in test and 'SourceScriptThread.run' in test

# These are independent protocol representation vectors, not executed Swift
# assertions and not additional native test methods. They use only owned data.
vectors = []
for text in ['', ' owned-token ', '["owned", {"n":2}]', '\u9605\u8bfb\n\U0001f4d6']:
    for deadline in [0, 2_000_000_000_000]:
        raw = json.dumps({'deadline': deadline, 'data': base64.b64encode(text.encode()).decode()}, sort_keys=True, separators=(',', ':')).encode()
        outer = base64.b64encode(raw).decode()
        decoded = json.loads(base64.b64decode(outer))
        assert decoded['deadline'] == deadline
        assert base64.b64decode(decoded['data'], validate=True).decode() == text
        vectors.append({'text': text, 'deadline': deadline, 'wireBase64': outer, 'entrySHA256': hashlib.sha256(raw).hexdigest()})
wire = {
    'schema': 1,
    'kind': 'independent-owned-wire-representation-vectors',
    'swiftExecution': False,
    'vectors': vectors,
    'commitDeletion': {'changes': {'owned-key': None}},
    'casFalseMeaning': 'The existing owner changed no values for this transaction.',
}
(OUT / 'owned-wire-vectors.json').write_text(json.dumps(wire, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

grammar = {'schema': 1, 'parser': 'tree-sitter-swift', 'fileCount': len(sources), 'errorCount': 0,
           'meaning': 'Syntax grammar only; no Swift typecheck, SDK build, simulator or device execution.', 'sources': sources}
(OUT / 'grammar.json').write_text(json.dumps(grammar, indent=2) + '\n', encoding='utf-8')

record = {
    'schema': 1,
    'stage': 'C2 explicit App-owned state HostCallback adapter',
    'frozenAtUTC': datetime.now(timezone.utc).isoformat(),
    'sourceBinding': {'files': sources, 'count': len(sources), 'snapshots': 'sources/'},
    'preparedNativeTests': {'suite': 'LegadoPersistentStateHostTests', 'methodCount': 9,
        'methods': [name + '()' for name in methods], 'executedSDKMethods': 0, 'acceptedSDKMethods': 0},
    'localValidation': {'swiftGrammarFiles': len(sources), 'swiftGrammarErrors': 0,
        'independentOwnedWireRepresentations': len(vectors), 'swiftTypecheck': False,
        'ordinarySwiftBuild': False, 'simulatorTests': False, 'deviceTests': False},
    'implemented': [
        'ModernParserBridge source.removeLoginHeader uses removeLoginHeader and retains credential ownership.',
        'One runtime process installs one actor host; only explicit options.stateOwner grants state access.',
        'Bound source revision changes revoke old owner grants and CAS proofs.',
        'Source variable raw strings, source key-values, login raw headers and generic text cache reuse existing owners and namespaces.',
        'A transaction is limited to one existing owner record/domain; stale proofs return false without mutation.',
        'Source key-values update a single existing dictionary record; malformed multi-key input is rejected before owner commit.',
        'Generic cache TTL and text share its original UserDefaults key; old String records remain readable and JSC owner sees Data records.',
        'Cancellation and remaining deadlines are checked before owner mutation; after a successful synchronous owner commit its result is acknowledged.',
        'Owned credential provider injection avoids actual Keychain access in fixtures; failed saves preserve old data and revision.',
    ],
    'limitsAndUnfinished': [
        'Product NativeLegadoMainJSExecutor still uses stateOwner=nil; explicit embedding bind/revoke lifecycle is not yet wired to the product source route.',
        'No Swift/JVM JNI or iOS App execution is accepted by this preparation record; all nine native methods are definitions only until the centralized SDK run.',
        'Complete RFC Cookie attributes are not connected; Cookie-bearing headers and Cookie+header/removal transactions fail before writes.',
        'Book/chapter variables, big-variable, TOC and content need existing App book UUID/generation mapping and are unsupported; no derived UUID or second cache directory is created.',
        'Binary values and cross-owner atomic transactions are unsupported; a matching binary null deletion companion is a no-op because this adapter owns no binary backing.',
        'Source variables and login headers support deadline zero only; generic cache text retains absolute epoch-ms expiry.',
        'UserDefaults acceptance is the existing logical owner commit; no new fsync or process-crash durability guarantee is claimed.',
        'Binding/lease/cancellation counts are bounded and the host retains source revisions only while that source has an active binding.',
        'C1, C2, S1 and whole source compatibility remain incomplete; no traditional route switch or C4 identity mapping.',
    ],
    'safety': {'privateBookSourcesRead': False, 'realCredentialsRead': False,
        'fixtureNamespace': 'Random owned.legado.state.* suites and owned-*.invalid source cache suites only.',
        'networkOrCloudQueries': 0, 'gitOperations': 0, 'selfRenewalFilesChanged': False, 'ciFilesChanged': False},
    'evidence': [],
}
for name in ['grammar.json', 'owned-wire-vectors.json', 'freeze.py']:
    raw = (OUT / name).read_bytes()
    record['evidence'].append({'path': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
raw = (json.dumps(record, ensure_ascii=False, indent=2) + '\n').encode()
(OUT / 'preparation.json').write_bytes(raw)
print(json.dumps({'status': 'prepared-not-SDK-accepted', 'sources': len(sources), 'grammarErrors': 0,
                  'nativeMethodsDefined': len(methods), 'nativeMethodsExecuted': 0,
                  'preparationBytes': len(raw), 'preparationSHA256': hashlib.sha256(raw).hexdigest(), 'methods': methods}))
