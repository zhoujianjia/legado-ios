from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader'); S = R / '.build/s2-certificate-reuse-step'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def check(row):
    actual = fact(R / row['path'])
    assert all(actual[key] == row[key] for key in ['bytes', 'sha256']), row['path']
def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

f = read(S / 'final-v1.json')
rp = R / '.build/s2-certificate-reuse-independent-review/review-v1.json'; review = read(rp)
assert fact(S / 'final-v1.json')['sha256'] == 'ceba566ec8a2859b77aa0480b8aada02f4c8ceb882efd3e0ba91b1851583a474'
assert fact(rp)['sha256'] == '9cd520785a596210f627779ad7c0fd1c7241400df86a1b49c3d89c6040299dc0'
assert review['approved'] and not review['failedChecks'] and not review['remainingConfirmedSourceBlockers']
assert f['sourceCounts']['changedSources'] == 3 and f['sourceCounts']['productionSources'] == 2
assert len(f['authoredRegressions']['newNoArgumentDefinitions']) == 4
assert f['authoredRegressions']['candidateDefinitions'] == 19
assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
for row in f['files']:
    for key in ['baseline', 'candidate', 'diff']: check(row[key])
    assert all(fact(R / row['path'])[key] == row['baseline'][key] for key in ['bytes', 'sha256'])
for key in ['sourceValidation', 'validationTool']: check(f[key])
base = R / 'docs/legado-ios/evidence/renewal-certificate-reuse-step'
record_path = R / 'docs/legado-ios/core-renewal-certificate-reuse-step.json'
assert not base.exists() and not record_path.exists()
items = {'reviewed-candidate.json': S / 'final-v1.json', 'independent-review.json': rp,
    'source-validation.json': R / f['sourceValidation']['path'], 'source-validation.py': R / f['validationTool']['path'],
    'root-integration.py': Path(__file__)}
plan_path = R / 'docs/legado-ios/completion-plan.json'; plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
paths = []; evidence = []
for row in f['files']:
    canonical = R / row['path']; canonical.write_bytes((R / row['candidate']['path']).read_bytes()); paths.append(canonical)
    before = (R / row['baseline']['path']).read_text(encoding='utf-8')
    after = canonical.read_text(encoding='utf-8')
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='a/' + row['path'], tofile='b/' + row['path'], n=0))
    target = base / 'diffs' / (Path(row['path']).name + '.diff')
    target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(patch.encode()); paths.append(target)
for name, original in items.items():
    raw = original.read_bytes(); assert b'\0' not in raw
    normalized = ('\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8-sig').splitlines()).rstrip('\n') + '\n').encode()
    target = base / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(normalized); paths.append(target)
    evidence.append({**fact(target), 'original': fact(original), 'normalization': 'UTF8/LF and line-end whitespace only; original facts retained'})
record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'same-key-certificate-reuse-and-profile-renewal-connected-SwiftSDK-pending',
    'baselineCommit': f['baselineCommit'], 'canonicalSources': [fact(R / row['path']) for row in f['files']],
    'productionBoundary': f['productionBoundary'], 'authoredRegressions': f['authoredRegressions'],
    'actualSwiftCompilerExecutions': 0, 'actualSwiftTestExecutions': 0, 'actualAppleAccountRequests': 0,
    'newCloudRunsOrTags': 0, 'preservedEvidence': evidence,
    'limits': [
        'Authored regressions and source review only. Actual target compiler/runtime validation is pending.',
        'Current trusted identity, exact remote certificate match and later component expiries are mandatory; historical profiles grant no current signing permission.',
        'An explicitly different requested key retains the existing deliberate issuance path. No unknown certificate is revoked.',
        'Device/App ID/App Group initial registration, real Apple authorization, the actual complete JVM IPA and authenticated same-device installation remain separately unfinished.',
        'No cryptographic or controlled-peer result establishes computer independence, no-VPN routing, actual replacement, cold launch or unattended renewal.',
    ], **{key: False for key in FLAGS},
}
write(record_path, record); paths.append(record_path)
steps = plan['execution']['stepByStep']
steps['certificateReuse'] = {'record': record_path.relative_to(R).as_posix(), 'productionFiles': 2, 'newAuthoredAppDefinitions': 4, 'newAuthoredAppArgumentLeaves': 4, 'actualSDKExecutions': 0}
for step in steps['steps']:
    if step['id'] == 'S2':
        step.setdefault('implementationEvidence', []).append({'record': record_path.relative_to(R).as_posix(), 'scope': 'Same-key certificate reuse through the real account/Keychain/Vault owners; current certificate trust, exact remote leaf and per-component profile expiry advance enforced. New four regressions await SDK.'})
        step['nextActionZh'] = '同key有效证书复用与逐包profile延期验证已接线，待统一SDK执行4项新回归；继续首次设备/AppID登记与真实Apple授权缺口，严格同机安装通道仍未验证。'
plan.setdefault('activeDevelopmentBatchRecords', []).append(record_path.relative_to(R).as_posix())
write(plan_path, plan); paths.append(plan_path)
write(S / 'canonical-roster.json', [fact(path) for path in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'productionFiles': 2, 'testFiles': 1, 'newAuthoredDefinitions': 4, 'actualNewSDKExecutions': 0}))
