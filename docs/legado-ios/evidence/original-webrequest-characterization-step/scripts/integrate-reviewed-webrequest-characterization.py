from pathlib import Path
import datetime, hashlib, json, re, subprocess

R = Path.cwd()
S = R / '.build/original-webrequest-native-characterization-step'
V = R / '.build/original-webrequest-native-characterization-independent-review'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b = p.read_bytes()
    return dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest())
def check(p, row): assert fact(p) == {k: row[k] for k in ('bytes', 'sha256')}, str(p)
def save(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())

f = read(S / 'final-v1.json')
v = read(V / 'review-v1.json')
assert fact(V / 'review-v1.json') == dict(bytes=16444, sha256='1e288a11f18e343bfec5f916c7c30cd3c3a0b6d2841a4f4c234f1b312cc1afea')
check(S / 'final-v1.json', v['parent'])
assert v['unresolvedFindings'] == [] and v['productionChanges'] == 0 and v['newDefinitions'] == 1
assert f['productionChanged'] == 0 and f['NativeDefinitionsAdded'] == 1
assert all(x == '?? debug.log' for x in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
assert len(f['files']) == 1
for row in f['files']:
    assert not (R / row['path']).exists() and row['baseline'] is None
    check(R / f['sourceRoot'] / row['path'], row['candidate'])
check(R / v['targetMembershipClarification']['project']['path'], v['targetMembershipClarification']['project'])
base = R / 'docs/legado-ios/evidence/original-webrequest-characterization-step'
rp = R / 'docs/legado-ios/core-original-webrequest-characterization-step.json'
assert not base.exists() and not rp.exists()
items = {'preparation.json': S / 'final-v1.json', 'independent-review.json': V / 'review-v1.json',
         'scripts/integrate-reviewed-webrequest-characterization.py': Path(__file__)}
for row in f['evidence']:
    p = R / row['path']; check(p, row); items['author/' + p.relative_to(S).as_posix()] = p
p = R / f['primaryParent']['path']; check(p, f['primaryParent']); items['parent-primary-binding.json'] = p
normalized = {}
for name, p in items.items():
    raw = p.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode() if text else b''
pp = R / 'docs/legado-ios/completion-plan.json'
plan = read(pp)
assert all(plan[k] is False for k in FLAGS)
assert {x['runID'] for x in plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']} <= {39520239925}
paths, preserved = [], []
for name, p in items.items():
    dst = base / name; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(), **fact(dst),
        original=dict(path=p.relative_to(R).as_posix(), **fact(p)),
        normalization='UTF8/LF/trailing whitespace only; raw original facts retained'))
for row in f['files']:
    dst = R / row['path']; dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes((R / f['sourceRoot'] / row['path']).read_bytes()); paths.append(dst)
record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='reviewed-test-only-public-WebRequest-characterization-integrated-actual-SDK-pending',
    sourceFiles=f['files'], productionChanges=0, newTestDefinitions=1,
    method=v['newNativeSelector'], actual=f['actual'], preservedEvidence=preserved,
    targetMembershipClarification=v['targetMembershipClarification'],
    compiledByExistingSynchronizedTestGroup=True, explicitFutureSelectorAndRosterPending=True,
    minimumOS='iOS18.4', oldOSSkipIsNotAcceptance=True, extraExtensionBackgroundWK=True,
    currentRunningSourceContainsThisDelta=False, sourceRegexImplementedByThisChange=False,
    fullResourceInterceptionEstablished=False, proofLimits=f['proofLimits'], newCloudTags=0,
    **{k: False for k in FLAGS})
save(rp, record); paths.append(rp)
steps = plan['execution']['stepByStep']
steps['publicWebRequestCharacterization'] = dict(record=rp.relative_to(R).as_posix(),
    productionChanges=0, authoredTests=1, actualSwiftCompiler_SDK_WK_HTTP=0,
    addedToExistingSynchronizedTestTarget=True, requiresExplicitFutureSelectorAndRoster=True,
    extraExtensionBackgroundWK=True, minimumOS='iOS18.4', fullResourceInterceptionEstablished=False)
for step in steps['steps']:
    if step['id'] == 'C3':
        step.setdefault('implementationEvidence', []).append(dict(record=rp.relative_to(R).as_posix(),
            scope='Reviewed one owned public WKWebExtension resource-event/cleanup test. Actual SDK/WK/HTTP0; additional background context and OS18.4 floor explicit. No sourceRegex production support.'))
plan.setdefault('activeDevelopmentBatchRecords', []).append(rp.relative_to(R).as_posix())
save(pp, plan); paths.append(pp)
save(S / 'canonical-roster.json', [dict(path=p.relative_to(R).as_posix(), **fact(p)) for p in paths])
ignored = subprocess.run([G, 'check-ignore', '--stdin'], cwd=R,
    input=''.join(p.relative_to(R).as_posix()+'\n' for p in paths).encode(), capture_output=True)
assert ignored.returncode == 1 and not ignored.stdout
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps(dict(reviewedPaths=len(paths), newNativeDefinitions=1, productionChanges=0, actualSDK_WK=0, tags=0)))
