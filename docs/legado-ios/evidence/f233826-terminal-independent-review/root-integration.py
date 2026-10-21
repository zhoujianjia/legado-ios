from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader'); S = R / '.build/f233826-terminal-archive-candidate'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

f = read(S / 'final-v1.json')
review_path = R / '.build/f233826-terminal-archive-independent-review/final-review-v1.json'
review = read(review_path)
assert fact(S / 'final-v1.json')['sha256'] == '66861c4665a2e579c10b60feb43ce01c308c98cb89983457bfb1e4780bb4a7aa'
assert fact(review_path)['sha256'] == '16f10130c5bd734b665655acf6de3fbd28e593f70a124c025dd738add6530517'
assert review['approved'] and review['failedChecks'] == 0 and not review['unresolvedFindings']
assert len(f['files']) == f['candidateFiles'] == 136
assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
source_root = R / f['candidateRoot']
sdk_record = next(path for path in f['records'] if '/core-sdk-' in path)
native_record = next(path for path in f['records'] if '/core-native-' in path)
for row in f['files']:
    candidate = source_root / row['path']; target = R / row['path']
    assert candidate.resolve().is_relative_to(source_root.resolve()) and target.resolve().is_relative_to(R / 'docs/legado-ios')
    actual = fact(candidate)
    assert all(actual[key] == row[key] for key in ['bytes', 'sha256'])
    raw = candidate.read_bytes(); assert b'\0' not in raw and not target.exists()
    raw.decode('utf-8')

plan_path = R / 'docs/legado-ios/completion-plan.json'; plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
paths = []
for row in f['files']:
    path = R / row['path']; path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((source_root / row['path']).read_bytes()); paths.append(path)
base = R / 'docs/legado-ios/evidence/f233826-terminal-independent-review'
for name, original in [('candidate-inputs.json', S / 'final-v1.json'), ('independent-review.json', review_path), ('root-integration.py', Path(__file__))]:
    target = base / name; target.parent.mkdir(parents=True, exist_ok=True)
    raw = original.read_bytes(); text = raw.decode('utf-8-sig')
    target.write_bytes(('\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n') + '\n').encode()); paths.append(target)
policy = plan['execution']['cloudTriggerPolicy']
policy['onlyLiveSDKHandles'] = []
policy['terminalArchivesPending'] = []
policy['alreadyRunningTasks'] = 'No live SDK/Native tasks. Both f233826 terminal failures are fully archived and must not be queried again.'
policy['nextPlannedCheckpoint'] = 'Compose the reviewed proxy/remote-jslib wiring, S2 certificate reuse, exact test compiler repairs and remaining ready original-core changes into one source-bound SDK/Native pair. No per-change tags or IPA tag.'
policy['latestClosedCorePair'] = {
    'sourceCommit': f['sourceCommit'], 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'SDK': {'runID': 39524696933, 'jobID': 118976499912, 'status': 'completed', 'conclusion': 'failure', 'queryAgain': False, 'record': sdk_record, 'AppDefinitionsExecuted': 0, 'AppLeavesExecuted': 0, 'PackageMethodsPassed': 24},
    'Native': {'runID': 39524697051, 'jobID': 118976500962, 'status': 'completed', 'conclusion': 'failure', 'queryAgain': False, 'record': native_record, 'JVMMethodsPassed': 353, 'NativeMethodsExecuted': 0, 'diagnosticPackageMethodsPassed': 17},
    'uniqueTestCompilerErrorsInEach': 2,
    'sourceRepairRecord': 'docs/legado-ios/core-native-f233826-test-compiler-repair.json',
    'independentArchiveReview': (base / 'independent-review.json').relative_to(R).as_posix(),
}
for step in plan['execution']['stepByStep']['steps']:
    if step['id'] in ['C4', 'C5', 'S1', 'S2', 'S3', 'S4', 'S5', 'S6']:
        step.setdefault('implementationEvidence', []).append({'record': sdk_record, 'scope': 'Actual f233826 terminal compiler block: App0; independent Package24 passed. Owned producer success does not execute the App signer. Exact two-call repairs await later coherent SDK validation.'})
    if step['id'] in ['C1', 'C2', 'C3', 'C4', 'C5']:
        step.setdefault('implementationEvidence', []).append({'record': native_record, 'scope': 'Actual f233826 ordinary JVM353 passed; Native/App execution0 due two test compiler errors. Original30 selection is28 product plus2 platform cases, not executed acceptance.'})
plan.setdefault('activeDevelopmentBatchRecords', []).extend(f['records'])
write(plan_path, plan); paths.append(plan_path)
write(S / 'canonical-roster.json', [fact(path) for path in paths])
ignored = subprocess.run([G, 'check-ignore', '--stdin'], cwd=R, input=''.join(path.relative_to(R).as_posix() + '\n' for path in paths).encode(), capture_output=True)
assert ignored.returncode == 1 and not ignored.stdout
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'terminalJobsClosed': 2, 'newTestExecutions': 0, 'newCloudOperations': 0, 'productionChanges': 0}))
