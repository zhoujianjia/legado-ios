from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader')
S = R / '.build/s2-first-registration-step'
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(p):
    return json.loads(p.read_bytes())

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def check(row, at=None):
    actual = fact(at or R / row['path'])
    assert all(actual[key] == row[key] for key in ['bytes', 'sha256']), actual

def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
assert fact(S / 'final-v1.json')['sha256'] == 'b6c52da211bbab7289cab08744bee628c6be1625d873328bbe7009fa9743ab1e'
f = read(S / 'final-v1.json')
whole_path = R / '.build/s2-first-registration-independent-review/review-v1.json'
device_path = R / '.build/s2-first-registration-device-independent-review/review-v1.json'
assert fact(whole_path)['sha256'] == '1a58d4596fe7ce215b1af3354cb2d07132f9fcc4aaca14a8ea7e5854cd2da811'
assert fact(device_path)['sha256'] == 'd495dc377439b267e024d7c3716c812de6e88a50ec1c8d3c082ab8e885a8c464'
whole = read(whole_path)
device = read(device_path)
assert whole['approved'] is True and whole['failedChecks'] == 0 and not whole['remainingConfirmedSourceBlockers']
assert device['approved'] is True and device['failedChecks'] == 0
assert len(f['files']) == 9 and f['productionSources'] == 5 and f['testSources'] == 4
assert len(f['newAppTestDefinitions']) == 4
assert not any(f['actualExecution'].values())
for row in f['files']:
    check(row['baseline']); check(row['candidate']); check(row['diff'])
    check(row['baseline'], R / row['path'])
check(f['protocolBinding']); check(f['sourceChecks']); check(f['history']['sourceCheckV1'])
plan_path = R / 'docs/legado-ios/completion-plan.json'
plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
base = R / 'docs/legado-ios/evidence/renewal-first-registration-step'
record_path = R / 'docs/legado-ios/core-renewal-first-registration-step.json'
assert not base.exists() and not record_path.exists()
paths = []
evidence = []
def archive(origin, name):
    raw = origin.read_bytes()
    assert b'\0' not in raw
    normalized = ('\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8-sig').splitlines()).rstrip('\n') + '\n').encode()
    target = base / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(normalized)
    paths.append(target)
    evidence.append({**fact(target), 'original': fact(origin), 'normalization': 'UTF8/LF and trailing whitespace only; original facts preserved'})

for name, origin in [
    ('reviewed-candidate.json', S / 'final-v1.json'),
    ('independent-review.json', whole_path),
    ('device-independent-review.json', device_path),
    ('primary-binding.json', R / f['protocolBinding']['path']),
    ('source-checks.json', R / f['sourceChecks']['path']),
    ('historical-source-checks-v1.json', R / f['history']['sourceCheckV1']['path']),
    ('source-checker.py', S / 'final-source-check.py'),
    ('freeze.py', S / 'freeze.py'),
    ('root-integration.py', Path(__file__)),
]:
    archive(origin, name)
for row in f['files']:
    archive(R / row['diff']['path'], 'diffs/' + row['path'] + '.diff')
    target = R / row['path']
    target.write_bytes((R / row['candidate']['path']).read_bytes())
    check(row['candidate'], target)
    paths.append(target)

record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'first-registration-and-authenticated-paired-target-profile-gates-connected-source-reviewed-SDK-pending',
    'canonicalSources': [fact(R / row['path']) for row in f['files']],
    'productionFiles': 5, 'testFiles': 4, 'newAppDefinitions': f['newAppTestDefinitions'],
    'newAppArgumentLeaves': 4, 'newNativeDefinitions': 0, 'newPackageDefinitions': 0,
    'productionBehavior': f['scope'],
    'actualValidation': f['actualExecution'],
    'independentWholeSourceReviewApproved': True, 'independentDeviceSubscopeReviewApproved': True,
    'closedSourceFindings': [
        'New paired-registration cleanup wrapper preserves the original cancellation/session/storage classification in the existing App consumers.',
        'All three profiles must contain the exact paired-target identifier in authenticated inner-DER ProvisionedDevices before existing Vault publication; registration ACK alone is insufficient.',
    ],
    'requiredSDKRegression': f['necessaryFutureValidation'],
    'notIncludedInRunningSourcePair': 'f481e89717b96df1d15d5c3f9a72c359d1fcef55',
    'newCloudRunsOrTags': 0,
    'preservedEvidence': evidence,
    'limits': f['knownLimits'] + [
        'Source integration and authored URLProtocol/TLS/App tests are not executed Apple SDK acceptance.',
        'Authenticated paired target is not proof that it is the same physical device executing the app; no-VPN, replacement, cold launch and unattended renewal remain unverified.',
        'The existing strict service TLS gate and installation provider support are unchanged; registration does not manufacture an installation route.',
    ], **{key: False for key in FLAGS},
}
write(record_path, record)
paths.append(record_path)
rel = record_path.relative_to(R).as_posix()
steps = plan['execution']['stepByStep']
steps['firstAppleRegistration'] = {
    'record': rel, 'productionFiles': 5, 'testFiles': 4,
    'newAuthoredAppDefinitions': 4, 'newAuthoredAppLeaves': 4,
    'actualSDKExecutions': 0, 'actualAppleRequests': 0,
    'notIncludedInRunningSourcePair': 'f481e89717b96df1d15d5c3f9a72c359d1fcef55',
}
for step in steps['steps']:
    if step['id'] in ['S1', 'S2', 'S4']:
        step.setdefault('implementationEvidence', []).append({'record': rel, 'scope': 'Exact original registration scope; paired-target identifier observed only in authenticated Lockdown session and checked against all three CMS-verified profiles before publication. Five production files and four authored App regressions; SDK and real Apple requests0.'})
    if step['id'] == 'S2':
        step['nextActionZh'] = '证书复用与首用设备/AppID/AppGroup登记已接入既有owner；新4项App回归需下一次必要统一SDK验证，真实Apple账户授权及安装权限继续未验证。'

# Latest explicit user steering changes the temporary compatibility target;
# no test count is converted into a book-source compatibility percentage.
adjustment = {
    'requestedLocalDate': '2026-10-21',
    'instructionZh': '完整书源兼容，如果已能够达到90的书源兼容，已经暂时可以了',
    'temporaryCompatibilityTargetPercent': 90,
    'measuredCompatibilityPercent': None,
    'representativeSourcePopulationEstablished': False,
    'ninetyPercentAlreadyEstablished': False,
    'priorityZh': '优先自签和核心阅读流程；暂不以全部长尾兼容作为本阶段交付前提。',
    'acceptanceBoundaryZh': '兼容率须基于明确书源样本的搜索、详情、目录、正文完整流程；源码覆盖、JVM通过数和测试定义数不能折算为90%。',
    'fullCompatibilityFlagRemainsFalse': True,
    'otherSeventeenItemsRemainDeferred': True,
}
plan.setdefault('userScopeAdjustments', []).append(adjustment)
steps['temporaryBookSourceCompatibilityTarget'] = adjustment
for step in steps['steps']:
    if step['id'] in ['C1', 'C2', 'C3', 'C4', 'C5']:
        step['temporaryTargetFromUser'] = {'percent': 90, 'measuredPercent': None, 'exhaustiveLongTailRequiredForThisStage': False}
plan.setdefault('activeDevelopmentBatchRecords', []).append(rel)
write(plan_path, plan)
paths.append(plan_path)
write(S / 'canonical-roster.json', [fact(p) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'productionFiles': 5, 'testFiles': 4, 'newAuthoredAppDefinitions': 4, 'actualNewSDKExecutions': 0, 'temporaryCompatibilityTargetPercent': 90, 'measuredCompatibilityPercent': None}))
