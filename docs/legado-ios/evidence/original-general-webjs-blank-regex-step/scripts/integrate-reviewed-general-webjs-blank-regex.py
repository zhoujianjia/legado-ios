from pathlib import Path
import datetime, hashlib, json, re, subprocess

R = Path.cwd()
S = R / '.build/original-general-webjs-blank-regex-step'
V = R / '.build/original-general-webjs-blank-regex-independent-review'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(p): return json.loads(p.read_bytes())
def fact(p):
    b = p.read_bytes()
    return dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest())
def save(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')

f = read(S / 'final-v1.json')
v = read(V / 'review-v1.json')
assert v['final'] == dict(path=(S / 'final-v1.json').relative_to(R).as_posix(), **fact(S / 'final-v1.json'))
assert v['approved'] and v['actualReadOnlyChecks'] == 1804 and v['failedChecks'] == 0
assert v['remainingConfirmedFindings'] == []
assert all(x == '?? debug.log' for x in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
for row in f['files']:
    assert fact(R / row['path']) == row['baseline'], row['path']
    assert fact(R / f['candidateRoot'] / row['path']) == row['candidate'], row['path']

base = R / 'docs/legado-ios/evidence/original-general-webjs-blank-regex-step'
rp = R / 'docs/legado-ios/core-original-general-webjs-blank-regex-step.json'
assert not base.exists() and not rp.exists()
items = {'preparation.json': S / 'final-v1.json', 'independent-review.json': V / 'review-v1.json',
         'scripts/integrate-reviewed-general-webjs-blank-regex.py': Path(__file__)}
for p in V.glob('*.py'):
    items['scripts/' + p.name] = p
for row in f['evidence']:
    p = R / row['path']
    assert fact(p) == {k: row[k] for k in ('bytes', 'sha256')}
    items['actual/' + p.relative_to(S).as_posix()] = p
for row in f['files']:
    p = R / row['diff']['path']
    assert fact(p) == {k: row['diff'][k] for k in ('bytes', 'sha256')}
    items['diffs/' + p.relative_to(S / 'snapshot-v1/diffs').as_posix() + '.patch'] = p
normalized = {}
for name, p in items.items():
    raw = p.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode() if text else b''

pp = R / 'docs/legado-ios/completion-plan.json'
plan = read(pp)
assert all(plan[k] is False for k in FLAGS)
assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles'] == []
paths, evidence = [], []
for name, p in items.items():
    dst = base / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(normalized[name])
    paths.append(dst)
    evidence.append(dict(path=dst.relative_to(R).as_posix(), **fact(dst),
                         original=dict(path=p.relative_to(R).as_posix(), **fact(p)),
                         normalization='UTF8/LF/trailing whitespace only; raw facts retained'))
for row in f['files']:
    dst = R / row['path']
    dst.write_bytes((R / f['candidateRoot'] / row['path']).read_bytes())
    paths.append(dst)
record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              status='reviewed-Kotlin-blank-regex-wire-successor-integrated-Apple-SDK-pending',
              parentRecord='docs/legado-ios/core-original-general-webjs-step.json',
              closedFinding=v['closedFinding'], sourceBindings=f['files'],
              implementation=f['implementation'], actualValidation=f['counts'],
              ordinaryJar=f['ordinaryJar'], actualVectors=f['actualVectors'],
              independentReadOnlyChecks=1804, preservedEvidence=evidence,
              newDefinitions=0, newSourcePaths=0,
              limits=f['proofLimits'], newCloudTags=0, **{k: False for k in FLAGS})
save(rp, record)
paths.append(rp)
oldp = R / 'docs/legado-ios/core-original-general-webjs-step.json'
old = read(oldp)
old['currentWireSuccessor'] = dict(record=rp.relative_to(R).as_posix(),
                                 closedFinding='P2-KOTLIN-BLANK-REGEX-WIRE',
                                 oldActualGeneralPublicCalls=46, successorActualGeneralPublicCalls=64,
                                 historicalEvidencePreserved=True, actualAppleSDKExecuted=0)
save(oldp, old)
paths.append(oldp)
steps = plan['execution']['stepByStep']
steps['generalWebJSBlankRegexRepair'] = dict(record=rp.relative_to(R).as_posix(),
    sourceFiles=3, productionSources=1, newDefinitions=0, actualChangedJUnitPassed=1,
    GeneralPublicCalls=64, syntheticBrowserHostCalls=17, SDK_JNI_WK=0, pendingUnifiedSDK=True)
steps['generalWebJSSlice']['currentWireSuccessor'] = rp.relative_to(R).as_posix()
for step in steps['steps']:
    if step['id'] in ['C1', 'C3', 'C4']:
        step.setdefault('implementationEvidence', []).append(dict(record=rp.relative_to(R).as_posix(),
            scope='Normalize both blank browser regex wire fields through original Kotlin String.isBlank; exact emitted public API packets and changed existing method pass. Apple SDK/WK pending.'))
plan.setdefault('activeDevelopmentBatchRecords', []).append(rp.relative_to(R).as_posix())
save(pp, plan)
paths.append(pp)
save(S / 'canonical-roster.json', [dict(path=p.relative_to(R).as_posix(), **fact(p)) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps(dict(reviewedPaths=len(paths), productionSources=1, newDefinitions=0, GeneralPublicCalls=64, SDK=0, newTags=0)))
