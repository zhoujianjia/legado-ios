import difflib
import hashlib
import json
from pathlib import Path
from datetime import datetime, timezone

R = Path('F:/yuedu-reader')
S = R / '.build/original-preupdate-native-result-union'
P = 'Tests/iOS/LegadoNativeOriginalReaderTests.swift'
A = R / '.build/original-preupdate-app-step'
I = R / '.build/original-general-webjs-native-result-characterization-step'

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def check(p, size, digest):
    f = fact(p)
    assert f['bytes'] == size and f['sha256'] == digest, f

def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, indent=2, ensure_ascii=False) + '\n').encode())

check(R / P, 109194, 'ddf09646d1221b8bf659cb8311d814278a521bb97a44e09917d61e94397ab8c1')
check(I / 'rawbaseline' / P, 109133, '97a04aaf65d117e5f677f87b53cc2d3b15dcc7985a0f66ed4a8570a275f15810')
check(I / 'snapshot-v1/work' / P, 131508, 'a42b8780591dae689eb91fd5665625942e92bbbe51d8f7f276ba7084147bb21a')
check(A / 'test-snapshot-v1/work' / P, 116776, '6c790fe4d691aa52a84a8250136736a4ee6b4adb9bcb59f6fbb9c8348b07b19f')
assert not (S / 'composition-v1.json').exists()
ib = (I / 'rawbaseline' / P).read_bytes()
ic = (I / 'snapshot-v1/work' / P).read_bytes()
app = (A / 'test-snapshot-v1/work' / P).read_bytes()
canonical = (R / P).read_bytes()
bl = ib.splitlines(keepends=True)
cl = ic.splitlines(keepends=True)
ops = [o for o in difflib.SequenceMatcher(None, bl, cl, autojunk=False).get_opcodes() if o[0] != 'equal']
assert [(o[0], o[1], o[2]) for o in ops] == [('insert', 0, 0), ('insert', 12, 12), ('insert', len(bl), len(bl))]
prefix, method, suffix = [b''.join(cl[k:l]) for _, _, _, k, l in ops]
anchor = b'final class LegadoNativeOriginalReaderTests: XCTestCase {\n'
assert ib.count(anchor) == app.count(anchor) == canonical.count(anchor) == 1

def add_info(raw):
    return prefix + raw.replace(anchor, anchor + method, 1) + suffix

def remove_info(raw):
    assert raw.startswith(prefix) and raw.endswith(suffix)
    value = raw[len(prefix):-len(suffix)]
    assert value.count(method) == 1
    return value.replace(method, b'', 1)

assert add_info(ib) == ic
union = add_info(app)
assert remove_info(union) == app
info_on_compiler_fixed = add_info(canonical)
assert remove_info(info_on_compiler_fixed) == canonical
patches = []
for op, i, j, k, l in difflib.SequenceMatcher(None, canonical.splitlines(keepends=True), app.splitlines(keepends=True), autojunk=False).get_opcodes():
    if op == 'equal':
        continue
    assert op == 'insert', (op, i, j, k, l)
    inserted = b''.join(app.splitlines(keepends=True)[k:l])
    assert union.count(inserted) == 1
    patches.append(inserted)
back = union
for inserted in patches:
    back = back.replace(inserted, b'', 1)
assert back == info_on_compiler_fixed
assert remove_info(back) == canonical
assert union.count(b'func testNativeOriginal') == canonical.count(b'func testNativeOriginal') + 2
assert b'testNativeOriginalWebJSResourceSniff' not in union
out = S / 'snapshot-v1/work' / P
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(union)
diff = S / 'Reader-union.diff'
diff.write_bytes(''.join(difflib.unified_diff(canonical.decode().splitlines(True), union.decode().splitlines(True), fromfile='a/' + P, tofile='b/' + P)).encode())
record = {
    'schemaVersion': 1, 'frozenUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'exact insertion union of two reviewed authored tests; no Swift execution',
    'canonicalBaseline': fact(R / P),
    'preUpdateSource': fact(A / 'test-snapshot-v1/work' / P),
    'nativeResultSource': fact(I / 'snapshot-v1/work' / P),
    'sourceRoot': '.build/original-preupdate-native-result-union/snapshot-v1/work',
    'candidate': fact(out), 'diff': fact(diff),
    'compositionChecks': {
        'nativeResultCandidateReconstructedFromOriginalInserts': True,
        'removingNativeResultRestoresPreUpdateCandidateExactly': True,
        'removingPreUpdateAndNativeResultRestoresCurrentCanonicalExactly': True,
        'compilerRepairKept': True,
        'allFifteenExistingMethodBodiesUnchanged': True,
        'resourceProductionAndTestExcluded': True,
    },
    'newSelectors': [
        'LegadoNativeOriginalReaderTests/testNativeOriginalPreUpdateRefreshKeepsPublicBookIdentityAndProgressWithNewURLContext',
        'LegadoNativeOriginalReaderTests/testNativeOriginalWebJSNativeResultBridgeCharacterizesAndroidConversionInformation',
    ],
    'methodDefinitions': {'old': 15, 'candidate': 17, 'productAdded': 1, 'platformCharacterizationAdded': 1},
    'actualSwiftCompilerExecutions': 0, 'actualSDKExecutions': 0,
    'actualNativeTestExecutions': 0, 'canonicalChanges': 0,
}
write(S / 'composition-v1.json', record)
print(json.dumps({'composition': fact(S / 'composition-v1.json'), 'candidate': fact(out)}))
