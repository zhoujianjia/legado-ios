from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader'); G = 'D:/app/Git/cmd/git.exe'
S = R / '.build/f481-sdk-vault-value-api-repair'
P = 'Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift'
OWNER = R / 'Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']
def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def read(p): return json.loads(p.read_bytes())
def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
target = R / P
assert fact(target)['bytes'] == 61420 and fact(target)['sha256'] == '74261b3b4c13e266d6dadbe8882ed9620c7ff9a716fee2d67e8547d4ac45202b'
raw = target.read_bytes()
old = b'SelfRenewalDERPropertyList.decode(tbs[start + 3].full)'
new = b'SelfRenewalDERPropertyList.decode(tbs[start + 3].originalDER)'
assert raw.count(old) == 1
fixed = raw.replace(old, new, 1)
assert fixed.replace(new, old, 1) == raw
api = OWNER.read_text(encoding='utf-8')
assert 'let originalDER: Data' in api and 'originalDER = node.full' in api
assert 'static func children(of value: SignedAttribute.Value)' in api
run = read(R / '.build/sdk-f481e89-terminal/run.json')
jobs = read(R / '.build/sdk-f481e89-terminal/jobs.json')['jobs']
assert run['id'] == 39533277187 and run['head_sha'] == 'f481e89717b96df1d15d5c3f9a72c359d1fcef55'
assert run['status'] == 'completed' and run['conclusion'] == 'failure'
assert len(jobs) == 1 and jobs[0]['id'] == 119003957104 and jobs[0]['status'] == 'completed'
log = R / '.build/sdk-f481e89-terminal/unpacked/evidence/reader-renewal-probe/currentcore-native.log'
diagnostic = log.read_text(encoding='utf-8')
assert 'error:' in diagnostic and "has no member 'full'" in diagnostic
baseline = S / 'baseline' / P; baseline.parent.mkdir(parents=True, exist_ok=True); baseline.write_bytes(raw)
base = R / 'docs/legado-ios/evidence/sdk-f481-vault-value-api-repair'
record_path = R / 'docs/legado-ios/core-sdk-f481-vault-value-api-repair.json'
assert not base.exists() and not record_path.exists()
base.mkdir(parents=True)
paths = []
def archive(origin, name):
    body = origin.read_bytes(); assert b'\0' not in body
    normalized = ('\n'.join(s.rstrip(' \t') for s in body.decode('utf-8-sig').splitlines()).rstrip('\n') + '\n').encode()
    p = base / name; p.write_bytes(normalized); paths.append(p)
    return {**fact(p), 'original': fact(origin), 'normalization': 'UTF8/LF and trailing whitespace only; original facts retained'}
evidence = [archive(log, 'actual-native-compiler-diagnostic.log'), archive(Path(__file__), 'repair.py')]
diff = base / 'Vault-value-api.diff'
diff.write_bytes(''.join(difflib.unified_diff(raw.decode().splitlines(True), fixed.decode().splitlines(True), fromfile='a/' + P, tofile='b/' + P, n=2)).encode())
paths.append(diff)
target.write_bytes(fixed); paths.append(target)
record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'exact-existing-DER-value-API-repair-applied-target-SDK-rerun-pending',
    'failedSourceCommit': run['head_sha'], 'runID': run['id'], 'jobID': jobs[0]['id'],
    'actualFailure': 'The public SignedAttribute.Value returned by parseDER/children owns originalDER, not the private Node.full property.',
    'currentCanonicalBaseline': fact(baseline), 'fixedCanonicalSource': fact(target),
    'APIImplementationOwner': fact(OWNER),
    'meaning': 'originalDER is assigned verbatim from Node.full by the same bounded DER parser. This fixes the member reference without re-encoding certificate validity or changing trust/date semantics.',
    'oneExpressionChangedRestOf61420ByteBaselineExact': True,
    'firstRegistrationAndPairedTargetProfileGuardsPreserved': True,
    'newDefinitions': 0, 'actualNewSwiftCompilerRuns': 0, 'actualNewTests': 0,
    'newCloudRunsOrTags': 0,
    'confirmedTerminalSourceAppTestsExecuted': 0,
    'confirmedTerminalIndependentPackagePassed': 24,
    'SDKTerminalArchiveStatus': 'Downloaded, CRC/hash verified and independently being classified; full archive pending.',
    'evidence': evidence,
    'limits': ['This exact source fix is not a new Apple SDK compile/test pass.', 'Do not reuse the failed f481 run as acceptance of first registration or the API repair.'],
    **{k: False for k in FLAGS},
}
write(record_path, record); paths.append(record_path)
plan_path = R / 'docs/legado-ios/completion-plan.json'; plan = read(plan_path)
assert all(plan[k] is False for k in FLAGS)
policy = plan['execution']['cloudTriggerPolicy']
assert len(policy['onlyLiveSDKHandles']) == 1 and policy['onlyLiveSDKHandles'][0]['runID'] == 39533277187
policy['onlyLiveSDKHandles'] = []
policy['terminalArchivesPending'] = [{'runID': 39533277187, 'jobID': 119003957104, 'sourceCommit': run['head_sha'], 'status': 'confirmed-terminal-failure-artifacts-downloaded-full-archive-in-review', 'queryAgain': False}]
policy['alreadyRunningTasks'] = 'No live SDK/Native tasks. Both f481 runs are confirmed terminal failures and must not be queried again. Native is fully archived; SDK artifacts are downloaded and its archive is being independently classified.'
policy['nextPlannedCheckpoint'] = 'Classify and archive this SDK terminal, then compose first registration, the exact Vault API repair, stale proxy fixture repair and ready full-application signing wiring into one necessary coherent checkpoint. No per-change or IPA tags; book-source long-tail work remains deferred by the user temporary90 target.'
steps = plan['execution']['stepByStep']
rel = record_path.relative_to(R).as_posix()
steps['SDKF481VaultValueAPIRepair'] = {'record': rel, 'actualTargetCompilerRuns': 0, 'newDefinitions': 0, 'SDKTerminalAppMethods': 0}
for step in steps['steps']:
    if step['id'] in ['S1', 'S2', 'S3']:
        step.setdefault('implementationEvidence', []).append({'record': rel, 'scope': 'Actual SDK compiler found one invalid public DER Value member. Exact originalDER API repair applied on top of first-registration source; actual target rerun pending.'})
plan.setdefault('activeDevelopmentBatchRecords', []).append(rel)
write(plan_path, plan); paths.append(plan_path)
write(S / 'canonical-roster.json', [fact(p) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'productionExpressionsChanged': 1, 'newCompilerRuns': 0, 'liveRuns': 0, 'terminalSDKArchivePending': 39533277187}))
