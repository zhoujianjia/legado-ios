from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

R = Path('F:/yuedu-reader')
G = 'D:/app/Git/cmd/git.exe'
S = R / '.build/native-f481e89-archive-candidate'
F = R / '.build/native-f481e89-proxy-fixture-repair-step'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(p): return json.loads(p.read_bytes())
def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def check(row, p=None):
    actual = fact(p or R / row['path'])
    assert all(actual[k] == row[k] for k in ['bytes', 'sha256']), actual
def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
assert fact(S / 'final-v1.json')['sha256'] == '5c253d1e87eaf8730c76444503023de14096dd957e1da2bb5b418d195ff7be70'
review_path = R / '.build/native-f481e89-archive-independent-review/review-v1.json'
assert fact(review_path)['sha256'] == '0b60f13a37843eac38ee765df1eee5ac0d35a49a410c301a2a426001c6ec39cd'
review = read(review_path)
assert review['approved'] is True and review['failedChecks'] == 0 and not review['remainingConfirmedSourceBlockers']
f_review_path = R / '.build/native-f481e89-proxy-fixture-independent-review/review-v1.json'
assert fact(f_review_path)['sha256'] == '7f1cb4c01f60b09c8faad4b493c6a80cd1a0d02cfefb11618d5930291338ca21'
f_review = read(f_review_path)
assert f_review['approved'] is True and f_review['failedChecks'] == 0 and not f_review['unresolvedFindings']
assert fact(F / 'final-v1.json')['sha256'] == 'e7d976ac0dec4c2becc315b27c79ca64843e87696549557632fcf67a732dea84'
c = read(S / 'final-v1.json'); fix = read(F / 'final-v1.json')
assert c['fileCount'] == len(c['files']) == 82 and c['actualNativeExecutions'] == 0
assert c['actualJUnit']['passed'] == 377 and c['actualJUnit']['failed'] == 1
assert fix['productionChanges'] == fix['newDefinitions'] == 0
assert fix['actualJVMExecutions'] == fix['actualDistinctJVMMethodsPassed'] == 1
for row in c['files']:
    source = R / c['candidateRoot'] / row['path']
    check(row, source)
    assert not (R / row['path']).exists()
check(c['rawZIP']); check(c['planUpdateProposal'])
for row in fix['files']:
    check(row['baseline']); check(row['candidate']); check(row['diff'])
    check(row['baseline'], R / row['path'])
check(fix['commands']); check(fix['actualXML'])
assert len(ET.parse(R / fix['actualXML']['path']).getroot().findall('.//testcase')) == 1
plan_path = R / 'docs/legado-ios/completion-plan.json'; plan = read(plan_path)
assert all(plan[k] is False for k in FLAGS)
policy = plan['execution']['cloudTriggerPolicy']
assert {h['runID'] for h in policy['onlyLiveSDKHandles']} == {39533277157, 39533277187}
paths = []; transforms = []
for row in c['files']:
    origin = R / c['candidateRoot'] / row['path']
    raw = origin.read_bytes(); assert b'\0' not in raw
    normalized = ('\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8').splitlines()).rstrip('\n') + '\n').encode()
    target = R / row['path']; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(normalized)
    paths.append(target)
    if raw != normalized:
        transforms.append({'originalCandidate': row, 'archived': fact(target), 'transformation': 'Trailing whitespace only; original raw remains in the CRC/hash-bound ZIP or original terminal tool log.'})
assert len(transforms) == 2 and all(t['archived']['path'].endswith('.log') for t in transforms)
base = R / 'docs/legado-ios/evidence/native-f481e89-terminal'
extras = []
def archive(origin, name):
    raw = origin.read_bytes(); assert b'\0' not in raw
    normalized = ('\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8-sig').splitlines()).rstrip('\n') + '\n').encode()
    target = base / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(normalized)
    paths.append(target)
    extras.append({**fact(target), 'original': fact(origin), 'normalization': 'UTF8/LF and trailing whitespace only; original facts preserved'})
archive(S / 'final-v1.json', 'reviewed-candidate.json')
archive(review_path, 'independent-review.json')
archive(R / c['planUpdateProposal']['path'], 'reviewed-plan-proposal.json')
archive(Path(__file__), 'root-integration.py')

repair_base = 'proxy-fixture-repair/'
for name, origin in [
    ('reviewed-candidate.json', F / 'final-v1.json'),
    ('independent-review.json', f_review_path),
    ('commands.json', R / fix['commands']['path']),
    ('actual-tests.xml', R / fix['actualXML']['path']),
    ('compile-test.log', F / 'compile-test.log'),
    ('junit-selected.log', F / 'junit-selected.log'),
    ('test-only.diff', F / 'test-only.diff'),
    ('repair-and-execute.py', R / '.build/repair-native-f481e89-proxy-fixture.py'),
]: archive(origin, repair_base + name)
for row in fix['files']:
    target = R / row['path']; target.write_bytes((R / row['candidate']['path']).read_bytes()); paths.append(target)
    check(row['candidate'], target)
repair_path = R / 'docs/legado-ios/core-native-f481e89-proxy-fixture-repair.json'
write(repair_path, {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': fix['status'], 'canonicalSources': [fact(R / row['path']) for row in fix['files']],
    'failedCloudRecord': c['record'], 'reason': fix['reason'],
    'retainedAssertions': fix['retainedAssertions'],
    'productionChanges': 0, 'newDefinitions': 0, 'actualRelevantJVMMethodsPassed': 1,
    'actualMainK2Compiles': 0, 'actualTestK2Compiles': 1, 'actualFull378Reruns': 0,
    'actualSDKExecutions': 0, 'actualNativeJNIExecutions': 0,
    'reusedExactProductionJar': fix['reusedProductionJar'],
    'productionInputsCheckedExactCanonical': 133,
    'newCloudRunsOrTags': 0,
    'evidence': [e for e in extras if repair_base in e['path']],
    'limits': fix['limits'], **{k: False for k in FLAGS},
})
paths.append(repair_path)
record_path = R / c['record']; record = read(record_path)
assert record['runID'] == 39533277157 and record['conclusion'] == 'failure' and record['queryAgain'] is False
record['laterRepairDoesNotChangeThisFailure'] = repair_path.relative_to(R).as_posix()
record['archiveTextNormalizations'] = transforms
for row in record['preservedEvidence']:
    actual = fact(R / row['path'])
    if any(actual[k] != row[k] for k in ['bytes', 'sha256']):
        row['originalCandidateFact'] = dict(row)
        row.update(actual)
        row['transformation'] = 'Trailing whitespace only; exact original facts retained in originalCandidateFact.'
record['rootAdditionalEvidence'] = extras
write(record_path, record)

native_record = record_path.relative_to(R).as_posix()
policy['onlyLiveSDKHandles'] = [h for h in policy['onlyLiveSDKHandles'] if h['runID'] != 39533277157]
assert len(policy['onlyLiveSDKHandles']) == 1 and policy['onlyLiveSDKHandles'][0]['runID'] == 39533277187
policy['alreadyRunningTasks'] = 'Only SDK39533277187/job119003957104 remains live at its latest actual observation. Native f48139533277157/job119003957102 is terminal failure and fully archived; never query it or the f233 terminals again.'
policy['latestNativeTerminal'] = {'sourceCommit': c['sourceCommit'], 'record': native_record, 'runID': 39533277157, 'conclusion': 'failure', 'queryAgain': False, 'actualJVM': c['actualJUnit'], 'actualNativeExecuted': 0, 'separateSourceRepairRecord': repair_path.relative_to(R).as_posix()}
steps = plan['execution']['stepByStep']
steps['currentF481NativeTerminal'] = policy['latestNativeTerminal']
steps['queuedS2PreUpdateNativeResultCheckpoint']['status'] = 'SDK-last-observed-live-Native-terminal-failure-archived'
for step in steps['steps']:
    if step['id'] in ['C1', 'C2', 'C3', 'C4', 'C5']:
        step.setdefault('implementationEvidence', []).append({'record': native_record, 'scope': 'Actual full Gradle378:377 pass/1 stale proxy expectation failure. Native0. The one affected method is separately repaired and passed on the exact unchanged production Jar; no fresh378 or iOS pass inferred.'})
plan.setdefault('activeDevelopmentBatchRecords', []).extend([native_record, repair_path.relative_to(R).as_posix()])
write(plan_path, plan); paths.append(plan_path)
assert len(paths) == len({p.as_posix() for p in paths})
roster = [fact(p) for p in paths]
write(S / 'canonical-roster.json', roster)
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)

# These exact, independently reviewed public XML/log files intentionally live
# under raw/.build and raw/.../build. Force-add only this explicit text roster;
# never include an ignored directory, binary ZIP, or private download metadata.
spec = S / 'reviewed-text-paths.nul'
spec.write_bytes(b''.join(row['path'].encode() + b'\0' for row in roster))
subprocess.run([G, '-c', 'core.autocrlf=false', 'add', '-f', '--pathspec-from-file=' + str(spec), '--pathspec-file-nul'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'archiveCandidateFiles': 82, 'normalizedLogs': 2, 'actualCloudJVM': '377pass/1fail', 'actualSeparateRepairedMethodPass': 1, 'actualNativeExecutions': 0, 'remainingLiveRun': 39533277187}))
