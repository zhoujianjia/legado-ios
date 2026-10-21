from pathlib import Path
import datetime, hashlib, json, re, subprocess, sys

R = Path.cwd()
S = R / '.build/native-88c61ee-stale-expectation-repair-step'
VP = Path(sys.argv[1]).resolve()
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
v = read(VP)
assert fact(S / 'final-v1.json') == dict(bytes=16995, sha256='6bd803439b17bb992fce15aec522e1cabf4580679e787de3efcbf73df48a568f')
check(S / 'final-v1.json', v['final'])
assert v['approved'] and v['failedChecks'] == 0 and v['remainingConfirmedFindings'] == []
assert f['definitionIdentities']['newDefinitions'] == 0
assert f['actualValidation']['finalDistinctPassedMethods'] == 5
assert f['actualValidation']['actualMethodExecutions'] == 6
assert len(f['files']) == 5
assert all(x == '?? debug.log' for x in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
for row in f['files']:
    check(R / row['path'], row['baseline'])
    check(R / f['candidateRoot'] / row['path'], row['candidate'])
check(R / f['runtimeJar']['path'], f['runtimeJar'])
base = R / 'docs/legado-ios/evidence/native88-jvm-expectation-repairs'
rp = R / 'docs/legado-ios/core-native88-jvm-expectation-repairs-step.json'
assert not base.exists() and not rp.exists()
items = {'preparation.json': S / 'final-v1.json', 'independent-review.json': VP,
         'scripts/integrate-reviewed-native88-expectation-repairs.py': Path(__file__)}
for p in VP.parent.glob('*.py'): items['scripts/review/' + p.name] = p
for row in f['historyEvidence']:
    p = R / row['path']; check(p, row)
    items['actual/' + p.relative_to(S).as_posix()] = p
for row in f['files']:
    p = R / row['diff']['path']; check(p, row['diff'])
    items['diffs/' + p.name] = p
normalized = {}
for name, p in items.items():
    raw = p.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode() if text else b''
pp = R / 'docs/legado-ios/completion-plan.json'
plan = read(pp)
assert all(plan[k] is False for k in FLAGS)
cloud = plan['execution']['cloudTriggerPolicy']
assert cloud['latestOriginalNativeTerminal']['runID'] == 39520240533
assert cloud['latestOriginalNativeTerminal']['queryAgain'] is False
assert {x['runID'] for x in cloud['onlyLiveSDKHandles']} <= {39520239925}
paths, preserved = [], []
for name, p in items.items():
    dst = base / name; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(), **fact(dst),
        original=dict(path=p.relative_to(R).as_posix(), **fact(p)),
        normalization='UTF8/LF/trailing whitespace only; raw original facts retained'))
for row in f['files']:
    dst = R / row['path']; dst.write_bytes((R / f['candidateRoot'] / row['path']).read_bytes()); paths.append(dst)
record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='reviewed-five-existing-JVM-expectation-repairs-integrated-targeted-final-five-pass',
    sourceFiles=f['files'], productionSourceChanges=0, newDefinitions=0,
    oldTerminalRecord='docs/legado-ios/core-native-88c61ee-terminal-result.json',
    oldTerminalRemainsFailure=True, actualValidation=f['actualValidation'],
    runtimeJar=f['runtimeJar'], definitionIdentities=f['definitionIdentities'],
    contracts=f['contracts'], preservedEvidence=preserved, proofLimits=f['remainingBoundaries'],
    currentRunningSourceContainsRepair=False, newCloudTags=0, **{k: False for k in FLAGS})
save(rp, record); paths.append(rp)
steps = plan['execution']['stepByStep']
steps['native88JVMExpectationRepairs'] = dict(record=rp.relative_to(R).as_posix(), changedExistingMethods=5,
    newDefinitions=0, finalDistinctMethodsPassed=5, historicalExecutions=6,
    firstLocalFixtureFailuresRetained=True, full353SuiteRerun=False,
    actualSwiftSDK_JNI_WK=0, futureControlRebindRequired=True)
for step in steps['steps']:
    if step['id'] in ['C1', 'C2', 'C4']:
        step.setdefault('implementationEvidence', []).append(dict(record=rp.relative_to(R).as_posix(),
            scope='Five old rejection expectations migrated to the implemented Base64/HTML/URL behavior while preserving actual permission/error/effect guards. Five distinct targeted methods pass; no production change or full353 rerun.'))
    if step['id'] in ['C4', 'C5']:
        step['nextActionZh'] = ('88c原云端JVM353/348通过/5失败保持终态；5项过时预期已按原语义修正，最小复验5个不同方法最终通过，'
            '保留中间新增fixture误用失败与仅重测1项的历史。SDK88仍独立运行；终态归档后，将本修复和已审WK验证输入绑定到一组新清单，实际执行原生与冷进程链路。')
plan.setdefault('activeDevelopmentBatchRecords', []).append(rp.relative_to(R).as_posix())
save(pp, plan); paths.append(pp)
save(S / 'canonical-roster.json', [dict(path=p.relative_to(R).as_posix(), **fact(p)) for p in paths])
ignored = subprocess.run([G, 'check-ignore', '--stdin'], cwd=R,
    input=''.join(p.relative_to(R).as_posix()+'\n' for p in paths).encode(), capture_output=True)
assert ignored.returncode == 1 and not ignored.stdout
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps(dict(reviewedPaths=len(paths), productionChanges=0, finalDistinctMethodsPassed=5, actualSDK_JNI_WK=0, tags=0)))
