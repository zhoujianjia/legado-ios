from pathlib import Path
import difflib
import hashlib
import json
import re
import sys

ROOT = Path('F:/yuedu-reader')
STAGE = ROOT / '.build/original-source-login-delta-reuse-step'
VERSION = sys.argv[1] if len(sys.argv) > 1 else 'v1'
assert VERSION in ('v1', 'v2')
BASE = ROOT / '.build/original-source-login-delta-reuse-root-tests'
OUT = BASE if VERSION == 'v1' else BASE / VERSION
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))


def fact(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


paths = [
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
]
expected = [
    'testLoginUIDeltaReuseRequestAndTypedControlStateKeepRawRowsSeparate',
    'testNativeOriginalDeltaLoginUIReusesPhysicalControlsThroughProductServiceWithoutCredentialWrite',
]
assert not (OUT / ('final-' + VERSION + '.json')).exists()
rows = []
syntax = []
for path, added in zip(paths, expected):
    before = STAGE / 'rawbaseline' / path
    candidate = STAGE / 'work' / path
    assert before.read_bytes() == (ROOT / path).read_bytes(), path
    old = before.read_bytes()
    raw = candidate.read_bytes()
    names = lambda data: re.findall(rb'\bfunc\s+(test\w+)\s*\(', data)
    old_names, new_names = names(old), names(raw)
    assert len(new_names) == len(set(new_names)) == len(old_names) + 1
    assert set(new_names) - set(old_names) == {added.encode()} and set(old_names) <= set(new_names)
    for label, data in [('baseline', old), ('candidate', raw)]:
        tree = parser.parse(data)
        assert not tree.root_node.has_error, (path, label)
        syntax.append({'path': path, 'version': label, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'grammarErrors': 0})
    dst = OUT / 'work' / path
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(raw)
    baseline = OUT / 'rawbaseline' / path
    baseline.parent.mkdir(parents=True, exist_ok=True)
    baseline.write_bytes(old)
    diff = OUT / 'diffs' / (path + '.diff')
    diff.parent.mkdir(parents=True, exist_ok=True)
    diff.write_bytes(''.join(difflib.unified_diff(old.decode().splitlines(keepends=True), raw.decode().splitlines(keepends=True), fromfile='baseline/' + path, tofile='candidate/' + path)).replace('\r\n', '\n').encode())
    rows.append({'path': path, 'baseline': fact(before), 'candidate': fact(candidate), 'frozenCandidatePath': dst.relative_to(ROOT).as_posix(), 'diff': {'path': diff.relative_to(ROOT).as_posix(), **fact(diff)}, 'retainedExistingMethodDefinitions': len(old_names), 'newMethod': added})
record = {
    'schemaVersion': 1,
    'status': 'two-root-authored-regression-sources-frozen-awaiting-combined-SDK-and-JNI-execution',
    'canonicalBaseline': '13a13cce0bc62dd6df82247ea5a345e7dfcfa607; these two test inputs equal af865bf production baseline',
    'files': rows,
    'changedExistingCases': [
        'Package ordered-events success/error now retains both false and true render facts.',
        'Package malformed-render rejection uses incompatible entries on a render event; true alone is no longer invalid.',
        'Native original row action now requires the accepted typed true receipt and still forbids credential-store effects.',
    ],
    'newPackageCase': 'Typed reuse request contains the current working Map, separate evaluation Map and complete stable layout/control snapshot. New raw rows and retained physical definition stay distinct; cycle, captured Map flag and caption round-trip. Initial rendering omits reuseState.',
    'newNativeCase': 'Required real ordinary JVM/JNI through current source service and App form consumes ordered update/true receipt, reorders stable controls and preserves old action/type/label/edited value. Latest raw password binding to retained Button remains a typed error and Keychain Map stays unchanged.',
    'grammarBindings': syntax,
    'actualSwiftCompilerInvocations': 0,
    'actualSDKTestExecutions': 0,
    'actualJNIExecutions': 0,
    'mutations': {'canonical': False, 'Git': False, 'cloud': False, 'tags': False},
}
if VERSION == 'v2':
    old_manifest = BASE / 'final-v1.json'
    record['previousFrozenVersion'] = {'path': old_manifest.relative_to(ROOT).as_posix(), **fact(old_manifest)}
    record['v2ExplicitInputFailureBoundary'] = 'The same two new methods also require inputBindingFailed=true request coding/defaultfalse and actual Native present-prelude typed rejection versus missing-prelude original skip; neither may store credentials. No new method identity.'
manifest_path = OUT / ('final-' + VERSION + '.json')
manifest_path.write_bytes((json.dumps(record, ensure_ascii=False, indent=2) + '\n').encode())
print(json.dumps({'files': len(rows), 'newPackageDefinitions': 1, 'newNativeDefinitions': 1, 'oldMethodIdentitiesRetained': [r['retainedExistingMethodDefinitions'] for r in rows], 'grammarBindings': len(syntax), 'actualSDKJNIExecutions': 0, 'manifestPath': manifest_path.relative_to(ROOT).as_posix(), 'manifest': fact(manifest_path)}))
