from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader')
G = 'D:/app/Git/cmd/git.exe'
J = R / '.build/original-preupdate-refresh-step'
A = R / '.build/original-preupdate-app-step'
I = R / '.build/original-general-webjs-native-result-characterization-step'
U = R / '.build/original-preupdate-native-result-union'
REVIEW = R / '.build/original-preupdate-cross-independent-review/review-v1.json'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(p):
    return json.loads(p.read_bytes())

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def verify(row):
    f = fact(R / row['path'])
    assert f['bytes'] == row['bytes'] and f['sha256'] == row['sha256'], f

def write(p, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode())

assert all(line in ['?? debug.log', '?? docs/legado-ios/evidence/original-preupdate-refresh-step/'] for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
assert fact(J / 'backend-final-v1.json')['sha256'] == '9bbff85345d1d0cead95a16fce1dd322d0e8406788ae624cbd5b4c5cd7afb7a1'
assert fact(A / 'app-native-tests-final-v1.json')['sha256'] == '503542211a64a63370a9bb39594c0578f9a61b31ea201c7d1aa9154373799e27'
assert fact(U / 'composition-v1.json')['sha256'] == 'e4fe7cbdbc06e3ac8e2fbcbf56822298bc26b30919f443f231e65e27b3514b47'
j = read(J / 'backend-final-v1.json')
a = read(A / 'app-native-tests-final-v1.json')
prod = read(A / 'production-draft-v1.json')
union = read(U / 'composition-v1.json')
review = read(REVIEW)
assert fact(REVIEW)['sha256'] == 'd83ea12854873580371796e28a6c06a05334be6b89a01891cb9932cac4a152b8'
assert review['approved'] is True and not review['remainingConfirmedSourceBlockers']
assert review['failedChecks'] == 0
old_info_review_path = R / '.build/native-result-and-remote-jslib-independent-review/review-v1.json'
old_info_review = read(old_info_review_path)
assert fact(old_info_review_path)['sha256'] == 'fbed7ae60b6a68d3c9f8216bc299f6602765e3575795e259333e4a41bfbb651d'
assert old_info_review['A']['approved'] and not old_info_review['A']['unresolvedFindings']
assert j['actualExecution']['distinctMethodsWithFinalSuccessfulEvidence'] == 4
assert j['actualExecution']['totalJUnitExecutions'] == 11
verify(j['actualExecution']['finalJar'])
assert j['actualExecution']['SDK'] == j['actualExecution']['JNI'] == 0
assert len(j['files']) == 8 and len(prod['files']) == 5 and len(a['files']) == 2
assert a['actualValidation']['SwiftTestExecutions'] == 0
assert union['methodDefinitions'] == {'old': 15, 'candidate': 17, 'productAdded': 1, 'platformCharacterizationAdded': 1}

sources = []
for row in j['files']:
    verify(row['candidate']); verify(row['diff'])
    if row['baseline']:
        verify(row['baseline'])
        actual = fact(R / row['path'])
        assert all(actual[key] == row['baseline'][key] for key in ['bytes', 'sha256'])
    else:
        assert not (R / row['path']).exists()
    sources.append((row['path'], R / row['candidate']['path']))
baseline = {row['path']: row for row in read(A / 'baseline.json')['files']}
for row in prod['files']:
    original = R / row['path']
    assert all(fact(original)[key] == baseline[row['path']][key] for key in ['bytes', 'sha256'])
    candidate = R / prod['sourceRoot'] / row['path']
    assert all(fact(candidate)[key] == row[key] for key in ['bytes', 'sha256'])
    sources.append((row['path'], candidate))
for row in a['files']:
    verify(row['candidate']); verify(row['baseline']); verify(row['diff'])
    if row['path'].endswith('LegadoNativeOriginalReaderTests.swift'):
        verify(union['candidate']); verify(union['canonicalBaseline'])
        assert all(fact(R / row['path'])[key] == union['canonicalBaseline'][key] for key in ['bytes', 'sha256'])
        sources.append((row['path'], R / union['candidate']['path']))
    else:
        assert all(fact(R / row['path'])[key] == row['baseline'][key] for key in ['bytes', 'sha256'])
        sources.append((row['path'], R / row['candidate']['path']))
assert len(sources) == len({p for p, _ in sources}) == 15

plan_path = R / 'docs/legado-ios/completion-plan.json'
plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
base = R / 'docs/legado-ios/evidence/original-preupdate-refresh-step'
record_path = R / 'docs/legado-ios/core-original-preupdate-refresh-step.json'
assert not record_path.exists()
paths = []
evidence = []
def archive(origin, name):
    raw = origin.read_bytes()
    assert b'\0' not in raw and origin.suffix.lower() not in ['.jar', '.class', '.zip', '.ipa']
    # One preserved Windows JVM stderr log was emitted in the local CP936 code
    # page. Decode that exact known log only, after a byte-for-byte round trip.
    # The original raw bytes/hash remain recorded; no execution result changes.
    encoding = 'utf-8-sig'
    if origin == J / 'test-execution-v1/junit-selected.log':
        encoding = 'cp936'
        decoded = raw.decode(encoding)
        assert decoded.encode(encoding) == raw
    else:
        decoded = raw.decode(encoding)
    normalized = ('\n'.join(line.rstrip(' \t') for line in decoded.splitlines()).rstrip('\n') + '\n').encode()
    target = base / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        assert target.read_bytes() == normalized, target
    else:
        target.write_bytes(normalized)
    paths.append(target)
    evidence.append({**fact(target), 'original': fact(origin), 'originalTextEncoding': encoding, 'normalization': 'UTF8/LF and trailing whitespace only; original facts retained'})

for row in j['evidence']:
    verify(row)
    origin = R / row['path']
    archive(origin, 'jvm/' + origin.relative_to(J).as_posix())
archive(J / 'backend-final-v1.json', 'jvm/reviewed-backend.json')
archive(A / 'baseline.json', 'app/baseline.json')
archive(A / 'production-draft-v1.json', 'app/reviewed-production.json')
archive(A / 'app-native-tests-final-v1.json', 'app/authored-regressions.json')
archive(U / 'composition-v1.json', 'reader/composition.json')
archive(U / 'Reader-union.diff', 'reader/Reader-union.diff')
archive(R / '.build/compose-preupdate-native-result-union.py', 'reader/compose-union.py')
archive(I / 'final-v1.json', 'reader/native-result-reviewed-candidate.json')
for row in read(I / 'final-v1.json')['evidence']:
    verify(row)
    origin = R / row['path']
    archive(origin, 'reader/native-result/' + origin.relative_to(I).as_posix())
archive(old_info_review_path, 'reader/native-result-independent-review.json')
archive(REVIEW, 'cross-independent-review.json')
archive(Path(__file__), 'root-integration.py')
for rel, candidate in sources:
    target = R / rel
    before = target.read_text(encoding='utf-8') if target.exists() else ''
    after_raw = candidate.read_bytes()
    assert b'\r' not in after_raw
    after = after_raw.decode('utf-8')
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='a/' + rel, tofile='b/' + rel, n=0))
    diffpath = base / 'source-diffs' / (rel + '.diff')
    diffpath.parent.mkdir(parents=True, exist_ok=True)
    diffpath.write_bytes(patch.encode())
    paths.append(diffpath)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(after_raw)
    paths.append(target)
    assert target.read_bytes() == candidate.read_bytes()

record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'original-preUpdate-two-public-APIs-and-App-identity-handoff-connected-actual-JVM-checked-SDK-pending',
    'canonicalSources': [fact(R / rel) for rel, _ in sources],
    'sourceCounts': {'changedOrNewCanonicalFiles': 15, 'productionJVM': 6, 'productionSwift': 5, 'originalSourceManifest': 1, 'JVMTestFiles': 1, 'AppTestFiles': 1, 'NativeTestFiles': 1},
    'productionBehavior': j['scope'] + [
        'Same task opt-in TOC grant accepts exact owner/source/revision/current URL and invalidates stale entity/TOC leases. It grants no library or body write permission.',
        'The same durable preview record keeps its original logical identity and URL-specific large/chapter/TOC state. The RAM/global short map follows original puts; new URL does not inherit the old URL large bucket.',
        'Only a sealed successful TOC publishes the new book URL and context reference. Failure retains old active identity and accepted partial state facts.',
        'The actual returned URL crosses TOCPackage to BookStore old-identity CAS. It preserves App UUID/reading position/chapter ownership and persists URL-only changes through existing metadata owner.',
    ],
    'actualJVMValidation': j['actualExecution'],
    'authoredAppRegressions': a['AppRegressions'],
    'authoredNativeProductRegression': a['NativeRegression'],
    'authoredNativePlatformCharacterization': {
        'selector': read(I / 'final-v1.json')['newSelector'],
        'mechanism': 'Direct WK native Program result and primitive post-callback observation. No stringify/conversion production is enabled.',
        'programRecords': 14, 'plannedCallbacks': 28,
        'actualWKExecutions': 0,
    },
    'newAppDefinitions': 4, 'newAppArgumentLeaves': 4,
    'newNativeProductDefinitions': 1, 'newNativePlatformDefinitions': 1,
    'actualSwiftCompilerExecutions': 0, 'actualSwiftTestExecutions': 0,
    'actualNativeJNIExecutions': 0, 'newCloudRunsOrTags': 0,
    'resourceProductionActivated': False,
    'independentSourceReviewApproved': True,
    'preservedEvidence': evidence,
    'limits': j['knownLimits'] + [
        'The two public original APIs are connected; separate no-argument RuleJsExtensions helpers remain explicitly unsupported.',
        'New Swift/App/Native tests are authored source, awaiting actual SDK execution in a single coherent checkpoint.',
        'Native platform observations do not establish Android parity and do not enable object-result or resource-sniff compatibility.',
        'No renewal account registration, authenticated installation, device replacement or unattended execution result is established by this reader change.',
    ], **{key: False for key in FLAGS},
}
write(record_path, record)
paths.append(record_path)
steps = plan['execution']['stepByStep']
rel_record = record_path.relative_to(R).as_posix()
steps['originalPreUpdateRefresh'] = {
    'record': rel_record, 'productionJVMFiles': 6, 'productionSwiftFiles': 5,
    'actualDistinctJVMMethodsWithFinalSuccessfulEvidence': 4,
    'actualHistoricalJVMExecutions': 11,
    'actualOutsideJavaSessions': 2,
    'newAuthoredAppDefinitions': 4, 'newAuthoredNativeProductDefinitions': 1,
    'newAuthoredNativePlatformDefinitions': 1, 'actualSDKExecutions': 0,
}
for step in steps['steps']:
    if step['id'] in ['C1', 'C2', 'C3', 'C4', 'C5']:
        step.setdefault('implementationEvidence', []).append({'record': rel_record, 'scope': 'Original preUpdate reGetBook/refreshTocUrl to same Host and App URL handoff; four actual JVM methods and external Java public consumer. App/Native authored regressions await SDK.'})
        if step['id'] == 'C3':
            step['nextActionZh'] = '原版刷新两入口及App书籍URL交接已接线，JVM四方法与外部Java消费者已有真实成功证据；统一SDK执行新增Host与JNI/书库回归，资源嗅探及对象结果兼容继续未完成。'
plan.setdefault('activeDevelopmentBatchRecords', []).append(rel_record)
write(plan_path, plan)
paths.append(plan_path)
write(A / 'canonical-roster.json', [fact(p) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'canonicalSourceFiles': len(sources), 'actualDistinctJVMMethods': 4, 'newSwiftDefinitions': 6, 'actualSwiftExecutions': 0}))
