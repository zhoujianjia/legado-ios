from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

R = Path('F:/yuedu-reader')
S = R / '.build/consolidated-sdk-s2-preupdate-native-result-checkpoint'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(p):
    return json.loads(p.read_bytes())

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def check(row, at=None):
    actual = fact(at or R / row['path'])
    assert all(actual[k] == row[k] for k in ['bytes', 'sha256']), actual

def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert len(sys.argv) == 3, 'Pass exact independent-review path and SHA256'
rp = R / sys.argv[1]
assert fact(rp)['sha256'] == sys.argv[2]
review = read(rp)
assert review['approved'] is True and review['failedChecks'] == 0
assert not review['remainingConfirmedSourceBlockers']
assert fact(S / 'final-v1.json')['sha256'] == 'f3bd2df4aad8eb2148763abd9c5dde8a62b5f7894ccaa59fbd7b7dc35cf6110b'
f = read(S / 'final-v1.json')
assert subprocess.check_output([G, 'rev-parse', 'HEAD'], cwd=R).decode().strip() == f['baselineCanonicalCommit']
assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
assert len(f['files']) == 7
controls = {row['path']: row for row in f['files']}
for row in f['files']:
    check(row['baseline']); check(row['candidate']); check(row['diff'])
    check(row['baseline'], R / row['path'])
for row in f['productionSourceBindings']:
    check(row)
check(f['sourceClosures'])
closure = read(R / f['sourceClosures']['path'])
assert [len(closure[k]) for k in ['core', 'native', 'union']] == [364, 180, 380]
assert len({row['path'] for row in closure['union']}) == 380
for row in closure['union']:
    target = R / controls[row['path']]['candidate']['path'] if row['path'] in controls else R / row['path']
    check(row, target)
assert f['actualPortableValidation']['distinctMethodsWithPassingEvidence'] == 6
assert f['actualPortableValidation']['methodExecutions'] == 7
assert f['actualPortableValidation']['failedExecutions'] == 1
assert not any(f['actualExecutions'].values())
base = R / 'docs/legado-ios/evidence/sdk-s2-preupdate-native-result-checkpoint'
record_path = R / 'docs/legado-ios/core-sdk-s2-preupdate-native-result-checkpoint.json'
assert not base.exists() and not record_path.exists()
plan_path = R / 'docs/legado-ios/completion-plan.json'
plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles'] == []

paths = []
evidence = []
done = set()
def archive(origin, name):
    if name in done:
        return
    done.add(name)
    raw = origin.read_bytes()
    assert b'\0' not in raw
    normalized = ('\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8-sig').splitlines()).rstrip('\n') + '\n').encode()
    target = base / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(normalized)
    paths.append(target)
    evidence.append({**fact(target), 'original': fact(origin), 'normalization': 'UTF8/LF and line-end whitespace only; original facts preserved'})

archive(S / 'final-v1.json', 'reviewed-candidate.json')
archive(rp, 'independent-review.json')
archive(Path(__file__), 'root-integration.py')
archive(R / f['sourceClosures']['path'], 'source-closures.json')
for obj in list(f['actualPortableValidation'].values()) + f['historicalEvidence'] + f['tools']:
    if not isinstance(obj, dict) or not all(key in obj for key in ['path', 'bytes', 'sha256']):
        continue
    check(obj)
    origin = R / obj['path']
    archive(origin, 'validation/' + origin.relative_to(S).as_posix())
for row in f['files']:
    archive(R / row['diff']['path'], 'diffs/' + row['path'] + '.diff')
    target = R / row['path']
    target.write_bytes((R / row['candidate']['path']).read_bytes())
    paths.append(target)
for row in closure['union']:
    check(row)
record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'reviewed-coherent-seven-control-checkpoint-ready-for-one-SDK-Native-pair-not-execution-acceptance',
    'productionBaseline': f['baselineCanonicalCommit'],
    'canonicalControls': [fact(R / row['path']) for row in f['files']],
    'includedProductionRecords': [
        'docs/legado-ios/core-original-proxy-remote-jslib-step.json',
        'docs/legado-ios/core-renewal-certificate-reuse-step.json',
        'docs/legado-ios/core-original-preupdate-refresh-step.json',
        'docs/legado-ios/core-native-f233826-test-compiler-repair.json',
    ],
    'sourceCounts': f['countsForNextCheckpoint'],
    'sourceByteBinding': f['byteBinding'],
    'newSelectors': f['selectorsAdded'],
    'preservedControls': f['preservedControls'],
    'productionFunctionAST': f['productionFunctionAST'],
    'actualPortableValidation': f['actualPortableValidation'],
    'actualSwiftSDKExecutions': 0, 'actualNativeJNIExecutions': 0,
    'newCloudRunsOrTags': 0, 'resourceProductionActivated': False,
    'firstRegistrationDraftIncluded': False,
    'independentSourceReviewApproved': True,
    'preservedEvidence': evidence,
    'limits': f['scopeLimits'], **{key: False for key in FLAGS},
}
write(record_path, record)
paths.append(record_path)
rel = record_path.relative_to(R).as_posix()
steps = plan['execution']['stepByStep']
steps['queuedS2PreUpdateNativeResultCheckpoint'] = {
    'record': rel, 'status': 'ready-for-one-coherent-SDK-Native-pair',
    'sourceCounts': f['countsForNextCheckpoint'],
    'newCloudRunsOrTags': 0, 'actualSDKExecutions': 0,
}
policy = plan['execution']['cloudTriggerPolicy']
policy['nextPlannedCheckpoint'] = 'Submit this exact reviewed seven-control checkpoint as one source-bound SDK/Native pair. It includes proxy/remote-jslib, certificate reuse, original preUpdate identity handoff and exact f233 test compiler repairs. Resource activation and the separate first-registration draft remain excluded; no IPA tag.'
plan.setdefault('activeDevelopmentBatchRecords', []).append(rel)
write(plan_path, plan)
paths.append(plan_path)
write(S / 'canonical-roster.json', [fact(p) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'controls': 7, 'sourceUnionBound': 380, 'AppDefinitions': 471, 'AppLeaves': 474, 'originalMethods': 32, 'newSwiftExecutions': 0}))
