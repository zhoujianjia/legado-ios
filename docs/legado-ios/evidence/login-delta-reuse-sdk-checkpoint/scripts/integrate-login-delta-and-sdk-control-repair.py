from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path('F:/yuedu-reader')
PROD = ROOT / '.build/original-source-login-delta-reuse-step'
HARNESS = ROOT / '.build/consolidated-sdk-login-delta-reuse-checkpoint'
GIT = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']


def read(path): return json.loads(path.read_bytes())
def fact(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def verify(path, row):
    assert fact(path) == {k: row[k] for k in ['bytes', 'sha256']}, str(path)
def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())


assert not subprocess.check_output([GIT, 'status', '--porcelain'], cwd=ROOT)
head = subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
assert head == 'bfe619e0ff7e48251ec1970604d7457263f7c6e1', head
pm = PROD / 'final-v1.json'
hm = HARNESS / 'preparation/final-v1.json'
pr = ROOT / '.build/original-source-login-delta-reuse-independent-review/review.json'
hr = ROOT / '.build/consolidated-sdk-login-delta-reuse-independent-review/review.json'
verify(pm, {'bytes': 23939, 'sha256': '8166369634a9e4b4b71330174ac60a915bb8843c18f502b7718a17e451f72a77'})
verify(hm, {'bytes': 17907, 'sha256': 'c0d8638aef739dfc34d5f42aaf7984041e2ec83e0ccf062d62e1938e6307c672'})
verify(pr, {'bytes': 36006, 'sha256': '0ccfd5d7709a4c3e6e6e7a938f301ab65bec16a77a06ddf092c38bc5a2750d71'})
verify(hr, {'bytes': 17457, 'sha256': '0a341239ac9541d75eed4919dfc6c607e83c35468c969ce260d04c1a8706fe66'})
prod, harness = read(pm), read(hm)
assert read(pr)['findings'] == read(hr)['findings'] == []
assert read(hr)['status'] == 'independent-frozen-unified-harness-review-approved-no-definite-P1-P2'
root_review_path = HARNESS / 'preparation/root-combined-review.json'
root_review = read(root_review_path)
assert root_review['canonicalParent'] == head
assert root_review['changedProductionFiles'] == 19 and root_review['changedHarnessFiles'] == 9
assert root_review['uniqueBoundInputs'] == 335 and root_review['unchangedCanonicalInputsVerified'] == 307
assert root_review['actualJVMTests']['uniqueActualMethods'] == 16
assert root_review['actualSwiftCompilerSDKOrJNIExecutionsDuringRootReview'] == 0

candidates = {}
for stage, manifest, count in [(PROD, prod, 19), (HARNESS, harness, 9)]:
    assert len(manifest['files']) == count
    for row in manifest['files']:
        path = row['path']
        if row['baseline'] is None: assert not (ROOT / path).exists(), path
        else: verify(ROOT / path, row['baseline'])
        verify(stage / 'work' / path, row['candidate'])
        diff = Path(row['diff']['path'])
        verify(ROOT / diff if str(diff).startswith('.build') else stage / diff, row['diff'])
        assert path not in candidates
        candidates[path] = (stage / 'work' / path).read_bytes()
assert len(candidates) == 28
for row in prod['unchangedInheritedInputs'] + prod['references']:
    verify(ROOT / row['path'], row)
for row in prod['evidence']: verify(PROD / row['path'], row)
for key in ['wholeProductionManifest', 'wholeProductionIndependentReview', 'rootTypedRegressionManifest', 'rootActualSDKRepairManifest', 'historicalSelectorOnlyRootRepair', 'actualSDKTerminalIndependentReview', 'sourceBindingEvidence', 'sourceClosureEvidence', 'invariantEvidence', 'syntax', 'historicalPrior26Evidence', 'historicalPrior26IndependentReview']:
    verify(ROOT / harness[key]['path'], harness[key])

closures = read(ROOT / harness['sourceClosureEvidence']['path'])
bound = {}
for kind, count in [('core', 324), ('native', 115), ('package', 22)]:
    assert closures[kind]['count'] == len(closures[kind]['sources']) == count
    for row in closures[kind]['sources']:
        path = row['path']
        raw = candidates[path] if path in candidates else (ROOT / path).read_bytes()
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256'], path
        assert path not in bound or bound[path] == row
        bound[path] = row
assert len(bound) == 335 and sum(path not in candidates for path in bound) == 307
for validation in harness['actualPortableValidation']:
    for key in ['record', 'log']: verify(ROOT / validation[key]['path'], validation[key])
    actual = read(ROOT / validation['record']['path'])
    assert actual['successful'] is True and actual['actualTestsRun'] == validation['actualTestsRun']
    assert actual['failures'] == actual['errors'] == actual['skipped'] == 0
assert sum(v['actualTestsRun'] for v in harness['actualPortableValidation']) == 50
assert harness['finalDistinctAffectedPortableMethods'] == 21
assert harness['selection']['PackageMustExecuteFresh'] is True
assert harness['selection']['PackageHistoricalReusePermitted'] is False

prod_base = ROOT / 'docs/legado-ios/evidence/original-source-login-delta-reuse'
harness_base = ROOT / 'docs/legado-ios/evidence/login-delta-reuse-sdk-checkpoint'
prod_record_path = ROOT / 'docs/legado-ios/core-original-source-login-delta-reuse-step.json'
harness_record_path = ROOT / 'docs/legado-ios/core-login-delta-reuse-sdk-checkpoint.json'
assert all(not p.exists() for p in [prod_base, harness_base, prod_record_path, harness_record_path])
items = []


def add(base, src, name, expected=None):
    if expected is not None: verify(src, expected)
    assert src.is_file()
    items.append((src, base / name))


for src, name in [(pm, 'preparation.json'), (pr, 'independent-review.json')]: add(prod_base, src, name)
for row in prod['evidence']: add(prod_base, PROD / row['path'], row['path'], row)
for suite in prod['validation']['JVM']['suites']:
    row = suite['xml']; add(prod_base, PROD / row['path'], row['path'], row)
for version, name in [('final-v1.json', 'root-regressions-v1.json'), ('v2/final-v2.json', 'root-regressions-v2.json')]:
    add(prod_base, ROOT / '.build/original-source-login-delta-reuse-root-tests' / version, name)
add(prod_base, ROOT / '.build/freeze-login-delta-reuse-root-tests.py', 'freeze-root-regressions.py')
for src, name in [(hm, 'preparation.json'), (hr, 'independent-review.json'), (root_review_path, 'root-combined-review.json')]: add(harness_base, src, name)
for key, name in [('sourceBindingEvidence', 'production-composition.json'), ('sourceClosureEvidence', 'source-closures.json'), ('invariantEvidence', 'selection-and-gate-invariants.json'), ('syntax', 'syntax.json'), ('historicalSelectorOnlyRootRepair', 'root-selector-repair-v1.json'), ('rootActualSDKRepairManifest', 'root-selector-summary-repair-v2.json')]:
    row = harness[key]; add(harness_base, ROOT / row['path'], name, row)
for validation in harness['actualPortableValidation'] + harness['preservedAttemptHistory']:
    for key in ['record', 'log']:
        if key in validation:
            row = validation[key]; src = ROOT / row['path']; add(harness_base, src, src.name, row)
for row in harness['preparationScripts']: add(harness_base, ROOT / row['path'], 'scripts/' + Path(row['path']).name, row)
for name in ['review-combined-login-delta-sdk-repair.py', 'prepare-currentcore-swift-filter-fix.py', 'prepare-currentcore-summary-count-fix.py', 'integrate-login-delta-and-sdk-control-repair.py']:
    add(harness_base, ROOT / '.build' / name, 'scripts/' + name)
for row in read(ROOT / harness['rootActualSDKRepairManifest']['path'])['files']:
    add(harness_base, ROOT / row['incrementalDiff']['path'], 'summary-repair-diffs/' + Path(row['incrementalDiff']['path']).name, row['incrementalDiff'])
assert len(items) == len({dst for _, dst in items})
evidence = {prod_base: [], harness_base: []}
for src, dst in items:
    raw = src.read_bytes()
    decoded = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig')
    normalized = '\n'.join(line.rstrip(' \t') for line in decoded.splitlines()).rstrip('\n')
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes((normalized + '\n' if normalized else '').encode())
    base = prod_base if dst.is_relative_to(prod_base) else harness_base
    evidence[base].append({'path': dst.relative_to(ROOT).as_posix(), **fact(dst), 'originalEvidence': {'path': src.relative_to(ROOT).as_posix(), **fact(src)}, 'normalization': 'BOM-aware text decoding, UTF-8/LF, trailing horizontal whitespace and empty EOF lines removed; raw byte facts retained'})

prod_record = {
    'schemaVersion': 1, 'recordedOn': '2026-10-21',
    'status': 'original-true-delta-physical-control-reuse-integrated-JVM-proven-SDK-and-JNI-pending',
    'reviewedCanonicalParent': head, 'sourcePreparation': fact(pm), 'sourceFiles': prod['files'],
    'inheritedSources': prod['unchangedInheritedInputs'], 'scope': prod['scope'],
    'validation': prod['validation'], 'newTestDefinitions': prod['newTestDefinitions'],
    'independentReview': {'record': 'docs/legado-ios/evidence/original-source-login-delta-reuse/independent-review.json', 'originalBytes': fact(pr), 'status': read(pr)['status'], 'remainingFindings': []},
    'rootReview': 'Verified the original name-slot/-2 append/duplicate/physical-child algorithm, retained captured definitions and Map identities, raw-row versus physical-state separation, same Service/actor/JVM request and existing UI consumer. Authored the actual Package/native regressions and explicit inputBindingFailed boundary: only UI_BINDING_ERROR sets unavailable input, nil action/getLoginJs skips before rejection, nonempty prelude rejects before source eval. Independently byte-checked all19 changed and3 inherited sources,56 production provenance entries,125 actual compilation inputs with one validation-only heap stanza,16 unique JVM XML methods over12+4 invocations,337 compiled/JAR classes, ZIP CRC and embedded manifest. Actual ordinary Java5 sessions/2 sources and packaging6 passed. Grammar is not Swift typechecking or JNI/UI execution.',
    'actualJVMSelectionCorrection': {'firstInvocationActualMethods': 12, 'firstInvocationWrongFilter': 'OriginalSourceLoginUiTest', 'correctClass': 'OriginalSourceLoginUITest', 'correctedOnlyMissingInvocationMethods': 4, 'uniqueActualMethods': 16, 'bothRawInvocationsPreserved': True, 'existing12OrJarRepeatedForCorrection': False},
    'preservedEvidence': evidence[prod_base], 'limits': prod['limits'],
    'nextCheckpoint': {'record': harness_record_path.relative_to(ROOT).as_posix(), 'NativeOriginal': 20, 'NativeMainJS': 1, 'freshPackageMethods': 23, 'actualSDKOrJNIExecuted': False},
    'deliveredIPAUnchanged': 'Build14 source44f125b predates this source change; glyph fix already delivered separately.',
    **{key: False for key in FLAGS},
}
harness_record = {
    'schemaVersion': 1, 'recordedOn': '2026-10-21',
    'status': 'independently-reviewed-delta-reuse-and-two-actual-SDK-control-repairs-integrated-awaiting-Native210-terminal',
    'reviewedCanonicalParent': head, 'productionRecord': prod_record_path.relative_to(ROOT).as_posix(),
    'productionPreparation': fact(pm), 'harnessPreparation': fact(hm), 'harnessFiles': harness['files'],
    'independentReview': {'record': 'docs/legado-ios/evidence/login-delta-reuse-sdk-checkpoint/independent-review.json', 'originalBytes': fact(hr), 'status': read(hr)['status'], 'remainingFindings': []},
    'sourceClosureCounts': harness['sourceClosureCounts'], 'uniqueBoundInputs': 335, 'unchangedCanonicalInputs': 307,
    'selection': harness['selection'], 'actualPortableValidation': harness['actualPortableValidation'],
    'portableHistory': {'actualMethodExecutionsAcrossStagedRuns': 50, 'finalDistinctAffectedMethods': 21, 'finalCore': 16, 'unchangedNative': 3, 'unchangedPackage': 2, 'prior26AlreadyBoundNotRepeated': True},
    'actualSDKDefectsRepaired': [
        {'cause': '438 of459 selected zero-argument Swift Testing methods in source210 were omitted by bare only-testing filters.', 'repair': 'Use exact currentcore framework syntax:442 zero-argument Swift Testing selectors append(),3 parameterized methods retain their real named signatures,18 XCTest selectors stay bare. Unknown methods fail closed; old modes unchanged.'},
        {'cause': 'All three active currentcore summary callers supplied execution-leaf counts as top-level definition counts.', 'repair': 'One currentcore helper passes463 definitions and466 device executions to the existing strict verifier. Fix after-tests SDK fixture verification, full result(group) and CLI verify-tests; retain exact cases/Bool arguments/required App signer and all fixture/code/source gates.'},
    ],
    'actualSDKFailureRecord': 'docs/legado-ios/core-sdk-210fb05-terminal-result.json',
    'rootReview': 'Checked the exact frozen19+9 composition and335 unique input bytes. Independent9 review confirms production AST and old mode sets retained, root selector+summary repairs composed exactly, Native old19 order plus new1 with separate required MainJS, explicit new deltareuse23 plus all historical Package sets unchanged, one3600-second cold invocation/one xcresult, ten ledger gates plus separate result, and mandatory same-job Swift signer. Actual raw21 definitions/24 executions still fail the full currentcore scope; synthetic463/466 count acceptance is not actual SDK execution. Preserved50 actual staged method executions with21 distinct final affected methods; no redundant reruns of unchanged Native/Package or earlier26.',
    'preservedEvidence': evidence[harness_base], 'actualNewSDKOrJNIAccepted': False,
    'freshPackage23Required': True, 'laterV2ProtocolExcluded': True,
    'submissionPolicy': 'Only currentNative210fb05 remains live. Collect and review its complete terminal evidence, address any concrete failures, then submit one coherent SDK/Native source pair. No per-item/device tags or restarts for elapsed observation.',
    'deliveredIPAUnchanged': 'Build14 remains the delivered device package; this source-only checkpoint creates no device-package tag.',
    **{key: False for key in FLAGS},
}
plan_path = ROOT / 'docs/legado-ios/completion-plan.json'
plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
cloud = plan['execution']['cloudTriggerPolicy']
assert {(v['runID'], v['jobID']) for v in cloud['onlyLiveSDKHandles']} == {(39476534384, 118813819896)}
steps = plan['execution']['stepByStep']
checkpoint = {'record': harness_record_path.relative_to(ROOT).as_posix(), 'status': harness_record['status'], 'currentcoreDefinitions': 463, 'currentcoreLeaves': 466, 'currentcoreInputs': 324, 'nativeOriginal': 20, 'nativeMainJS': 1, 'nativeInputs': 115, 'freshIndependentPackageMethods': 23, 'reviewedParentCommit': head, 'actualAccepted': False, 'deliveredDevicePackageSource': '44f125b73c06bf95637765ab58e65f41d0651b44', 'deviceBuild': 14}
steps['currentReviewedConsolidatedCheckpoint'] = checkpoint
steps['loginDeltaReuseAndSDKControlRepairCheckpoint'] = checkpoint.copy()
steps['originalTraditionalLoginDeltaReuse'] = {'record': prod_record_path.relative_to(ROOT).as_posix(), 'actualJVMMethodsPassed': 16, 'ordinaryJavaSessionsPassed': 5, 'newAppDefinitions': 0, 'newNativeDefinition': 1, 'newPackageDefinition': 1, 'actualSDKOrJNIExecuted': False}
steps['loginEventsDismissLifecycleSDKCheckpoint']['supersededBy'] = harness_record_path.relative_to(ROOT).as_posix()
c2 = next(v for v in steps['steps'] if v['id'] == 'C2')
c2['implementationEvidence'].append({'record': prod_record_path.relative_to(ROOT).as_posix(), 'scope': 'Original reLoginView(true) physical-control reuse now flows through the same JVM/service and actual existing View, preserving duplicate-name movements, captured controls/Map/watchers and typed binding failure. Real JVM16 and ordinary Java5 passed; new Package23/App463/466/Native20+1 require fresh unified SDK execution.'})
c2['nextActionZh'] = '统一验证已合入的动态表单复用、有序回调、退出保存和续签生命周期；V2 登录协议在独立目录继续开发，浏览器、WebView/JS 与完整书源兼容仍未完成。'
plan['activeBatchRecord'] = harness_record_path.relative_to(ROOT).as_posix()
cloud['nextPlannedCheckpoint'] = 'The reviewed true-delta19 plus9 controls, including both actualSDK selector/count defects, are integrated. Next source is App463 definitions/466 executions/core324, Native20+separateMainJS1/native115 and mandatory fresh independentPackage deltareuse23. First archive and review the only live Native210fb05 terminal and fix concrete failures. Later V2 stays isolated and does not delay this cohort. No per-item/device tags.'
for path, raw in candidates.items():
    out = ROOT / path; out.parent.mkdir(parents=True, exist_ok=True); out.write_bytes(raw)
write(prod_record_path, prod_record)
write(harness_record_path, harness_record)
write(plan_path, plan)
paths = [ROOT / path for path in candidates] + [dst for _, dst in items] + [prod_record_path, harness_record_path, plan_path]
assert len(paths) == len(set(paths))
write(HARNESS / 'canonical-roster.json', [{'path': p.relative_to(ROOT).as_posix(), **fact(p)} for p in paths])
subprocess.run([GIT, 'diff', '--check'], cwd=ROOT, check=True)
print(json.dumps({'reviewedPaths': len(paths), 'productionFiles': 19, 'harnessFiles': 9, 'boundInputs': 335, 'actualJVMMethods': 16, 'finalDistinctPortableMethods': 21, 'actualNewSDKOrJNI': 0, 'freshPackageRequired': 23, 'newCloudTags': 0}))
