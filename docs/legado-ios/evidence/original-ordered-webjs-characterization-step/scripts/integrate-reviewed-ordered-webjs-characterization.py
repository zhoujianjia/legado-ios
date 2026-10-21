from pathlib import Path
import datetime, hashlib, json, re, subprocess

R = Path.cwd()
S = R / '.build/original-general-webjs-ordered-result-step'
V = R / '.build/original-general-webjs-ordered-result-independent-review'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b = p.read_bytes()
    return dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest())
def check(p, expected): assert fact(p) == {k: expected[k] for k in ('bytes', 'sha256')}, str(p)
def save(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())

f = read(S / 'final-v1.json')
v = read(V / 'review-v1.json')
check(S / 'final-v1.json', v['final'])
assert v['totalChecks'] == 282 and v['failedChecks'] == 0 and v['remainingConfirmedFindings'] == []
assert f['changes']['production'] == 0 and f['changes']['newNativeDefinitions'] == 1
assert all(x == '?? debug.log' for x in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
for row in f['files']:
    check(R / row['path'], row['baseline'])
    check(R / f['sourceRoot'] / row['path'], row['candidate'])
rp = R / 'docs/legado-ios/core-original-ordered-webjs-characterization-step.json'
base = R / 'docs/legado-ios/evidence/original-ordered-webjs-characterization-step'
assert not rp.exists() and not base.exists()
items = {'preparation.json': S / 'final-v1.json', 'independent-review.json': V / 'review-v1.json',
         'scripts/integrate-reviewed-ordered-webjs-characterization.py': Path(__file__)}
for key in ['verification', 'verifier', 'independentToolHistory']:
    p = R / v[key]['path']; check(p, v[key]); items['review/' + p.name] = p
for row in f['evidence']:
    p = R / row['path']; check(p, row); items['author/' + p.name] = p
for row in f['files']:
    p = R / row['diff']['path']; check(p, row['diff']); items['diffs/' + p.name] = p
normalized = {}
for name, p in items.items():
    raw = p.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode() if text else b''
pp = R / 'docs/legado-ios/completion-plan.json'
plan = read(pp)
assert all(plan[k] is False for k in FLAGS)
live = plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']
assert {x['runID'] for x in live} <= {39520239925, 39520240533}
paths, preserved = [], []
for name, p in items.items():
    dst = base / name; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(), **fact(dst),
        original=dict(path=p.relative_to(R).as_posix(), **fact(p)),
        normalization='UTF8/LF/trailing whitespace only; original facts retained'))
for row in f['files']:
    dst = R / row['path']; dst.write_bytes((R / f['sourceRoot'] / row['path']).read_bytes()); paths.append(dst)
record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='reviewed-test-only-ordered-WebJS-characterization-integrated-behavior-unexecuted',
    sourceFiles=f['files'], changes=f['changes'], actual=f['actual'], independentReviewChecks=282,
    independentParserFailureRetained=True, independentGrammarPassed=False,
    method='LegadoNativeOriginalReaderTests/testNativeOriginalOrderedWebJSCharacterizesCSPAndOriginalJSONInSamePageWorld',
    scope='One test-owned WK instance and two CSP documents characterize native Program globals, captured eval scope/CSP rejection and single-expression original JSON encoding. No production rule or Host changes.',
    preservedEvidence=preserved, selectedByCurrentCloud=False,
    runningSourceCommit='88c61ee4b80889a617d344fda668d077f73fa95b',
    futureExplicitSDKSelectionRequired=True, productionOrderedObjectsSupported=False,
    proofLimits=v['limits'], newCloudTags=0, **{k: False for k in FLAGS})
save(rp, record); paths.append(rp)
steps = plan['execution']['stepByStep']
steps['orderedWebJSCharacterization'] = dict(record=rp.relative_to(R).as_posix(),
    productionSourcesChanged=0, newTestDefinitions=1, existingReaderMethodsPreserved=14,
    actualSwiftCompiler_SDK_WK=0, currentControlsChanged=False, currentCloudContainsDelta=False,
    requiresFutureExplicitSelection=True, productionOrderedObjectsSupported=False)
for step in steps['steps']:
    if step['id'] == 'C3':
        step.setdefault('implementationEvidence', []).append(dict(record=rp.relative_to(R).as_posix(),
            scope='One reviewed test-only owned WK characterization for the still-unsupported ordered-object branch. All behaviors and Apple compilation pending; no compatibility acceptance.'))
plan.setdefault('activeDevelopmentBatchRecords', []).append(rp.relative_to(R).as_posix())
save(pp, plan); paths.append(pp)
save(S / 'canonical-roster.json', [dict(path=p.relative_to(R).as_posix(), **fact(p)) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps(dict(reviewedPaths=len(paths), productionChanges=0, authoredNativeTests=1, actualSDK_WK=0, tags=0)))
