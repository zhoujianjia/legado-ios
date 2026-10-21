from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

R = Path('F:/yuedu-reader')
S = R / '.build/original-proxy-remote-union-step'
GIT = 'D:/app/Git/cmd/git.exe'
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

candidate = read(S / 'final-v1.json')
review_path = R / '.build/original-proxy-remote-union-independent-review/review-v1.json'
review = read(review_path)
assert fact(S / 'final-v1.json')['sha256'] == '3147d15ae0094fbcee2218656d2584f29fb18cb04f1e2d6b52f73d883941b4ac'
assert fact(review_path)['sha256'] == '68263f3b3c3f5efc3b4f5cb67b8e0880df078f124d0e5de5baf36c5aed426c9c'
assert review['approved'] and not review['failedChecks'] and not review['unresolvedFindings']
assert len(candidate['files']) == 22 and candidate['sourceCounts']['compiledKotlinMainRoots'] == 11
assert candidate['actualTests']['distinctMethodsWithSuccessEvidence'] == 23
assert candidate['mainCompileExecutions'] == 1 and candidate['productionChangesAfterMainCompile'] == 0
assert all(candidate[key] is False for key in FLAGS)
assert all(line == '?? debug.log' for line in subprocess.check_output([GIT, 'status', '--porcelain'], cwd=R).decode().splitlines())

for row in candidate['files']:
    check(row['candidate']); check(row['diff'])
    if row['baseline']:
        check(row['baseline'])
        assert all(fact(R / row['path'])[key] == row['baseline'][key] for key in ['bytes', 'sha256']), row['path']
    else: assert not (R / row['path']).exists(), row['path']

items = {
    'reviewed-candidate.json': S / 'final-v1.json',
    'independent-review.json': review_path,
    'root-integration.py': Path(__file__),
}
for key in ['sourceComposition', 'finalCompilationInputs', 'compiler', 'productionClassBinding', 'binaryABIClosure']:
    row = candidate[key]; check(row); items[key + '.json'] = R / row['path']
compile_data = read(R / candidate['compiler']['path'])
assert compile_data['exitCode'] == 0
check(compile_data['log']); items['compiler.log'] = R / compile_data['log']['path']
check(candidate['ordinaryJar'])
for label in ['first', 'onlyFailedRerun']:
    row = candidate['actualTests'][label]['XML']; check(row); items['test-results/' + label + '.xml'] = R / row['path']
for key in ['transitiveInputReuse', 'firstSourceSnapshots']:
    row = candidate['actualTests'][key]; check(row); items[key + '.json'] = R / row['path']
for index, row in enumerate(candidate['testCommands']):
    check(row); items[f'test-command-{index + 1}.json'] = R / row['path']
for index, row in enumerate(candidate['parents']):
    check(row); items[f'parent-{index + 1}.json'] = R / row['path']
for index, row in enumerate(review['reusedIndependentReviews']):
    check(row); items[f'parent-independent-review-{index + 1}.json'] = R / row['path']
for index, row in enumerate(candidate['lockedConnectErrorContract']):
    check(row['source']); items[f'primary-connect-contract/{index + 1}-' + Path(row['source']['path']).name] = R / row['source']['path']
for index, row in enumerate(candidate['history'][:2]):
    binding = row.get('facts', row.get('log')); check(binding)
    items[f'history/pretest-{index + 1}-' + Path(binding['path']).name] = R / binding['path']

base = R / 'docs/legado-ios/evidence/original-proxy-remote-jslib-step'
record_path = R / 'docs/legado-ios/core-original-proxy-remote-jslib-step.json'
assert not base.exists() and not record_path.exists()
normalized = {}
for name, path in items.items():
    raw = path.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&](?:X-Amz-Signature|sig)=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n') + '\n').encode()

plan_path = R / 'docs/legado-ios/completion-plan.json'
plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
paths = []
for row in candidate['files']:
    path = R / row['path']; path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((R / row['candidate']['path']).read_bytes())
    assert all(fact(path)[key] == row['candidate'][key] for key in ['bytes', 'sha256'])
    paths.append(path)
preserved = []
for name, path in items.items():
    target = base / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(normalized[name]); paths.append(target)
    preserved.append({**fact(target), 'original': fact(path), 'normalization': 'UTF8/LF and line-end whitespace only. Original exact byte facts retained.'})
record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'proxy-and-map-remote-jslib-production-connected-joint-JVM-regressions-passed-Swift-JNI-pending',
    'baselineCommit': subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=R).decode().strip(),
    'canonicalSources': [fact(R / row['path']) for row in candidate['files']],
    'behavior': [
        'Capture lowercase source/default proxy routing before URL-option literal headers; reuse the existing HTTP/Cookie/cancellation owner for original and finite mainJs entry points.',
        'Use the locked original HTTP/SOCKS parser and authenticated SOCKS5 protocol. Bound HTTP proxy challenges and avoid inherited proxy routing for later direct requests.',
        'Load ordered HTTP(S) values from map jsLib through the existing plain library downloader, one Rhino library scope and the source-scoped MD5 text cache namespace. Bare URL strings remain authored inline JavaScript.',
        'Refresh deletes library text and invalidates its library scope using the same owner, preserving original operation order and checked failure facts.',
        'Keep the previous RuleScopes constructor/remove JVM signatures while requiring an explicit production cache/network owner.',
    ],
    'sourceCounts': candidate['sourceCounts'], 'ordinaryJar': candidate['ordinaryJar'], 'jarCounts': candidate['jarCounts'],
    'actualTests': candidate['actualTests'], 'exactRequiredMethods': candidate['exactRequiredMethods'],
    'actualMainCompileExecutions': 1, 'actualSwiftSDK_JNI_Native': 0, 'newCloudRunsOrTags': 0,
    'preservedEvidence': preserved, 'limits': candidate['remainingLimits'],
    **{key: False for key in FLAGS},
}
write(record_path, record); paths.append(record_path)
steps = plan['execution']['stepByStep']
steps['proxyAndRemoteJsLib'] = {'record': record_path.relative_to(R).as_posix(), 'canonicalFiles': 22, 'jointMainRootsCompiled': 11, 'distinctMethodsWithSuccessEvidence': 23, 'actualExecutions': 28, 'firstFailedExecutionsPreserved': 5, 'SwiftSDK_JNI_NativeAccepted': False}
for step in steps['steps']:
    if step['id'] in ['C1', 'C2', 'C4', 'C5']:
        step.setdefault('implementationEvidence', []).append({'record': record_path.relative_to(R).as_posix(), 'scope': 'Actual production proxy/remote-map-jslib wiring and coherent JVM 11-root compilation; 23 distinct methods have passing evidence over first23 plus failed-only5. App/JNI validation still pending.'})
    if step['id'] == 'C1':
        step['nextActionZh'] = '代理和map远程jsLib已合入并有联合JVM证据；继续完整preUpdateJs刷新与书籍身份回写、原WebJS对象返回的Android值转换合同。资源嗅探公共WK平台尚未实际执行，保持未启用；完整书源兼容仍未完成。'
    if step['id'] == 'S2':
        step['nextActionZh'] = '按续签可行性复核补证书身份复用、额度及首次账号/设备/AppID登记缺口；保留同team、原主App与扩展身份及未知CSR恢复，真实Apple授权仍未验证。'
    if step['id'] == 'S4':
        step['nextActionZh'] = '当前仅strict DirectLockdown TLS子集；先补认证provider与协议/服务模式适配，保持同机可达性、安装授权、无VPN无伴侣条件未验证，不能删除认证检查或把TCP成功当作安装通道。'
steps['renewalFeasibilityReassessment'] = {'record': 'docs/legado-ios/self-renewal-feasibility-reassessment-20261021.json', 'strictStandaloneRouteProven': False, 'actualImplementationGapsRemain': True}
policy = plan['execution']['cloudTriggerPolicy']
policy['onlyLiveSDKHandles'] = []
policy['alreadyRunningTasks'] = 'No live SDK/Native tasks. Both f233826 runs completed failure at the same two test compiler calls; exact source repairs committed at0bee509. Terminal archives are being prepared; do not query these terminal jobs again.'
policy['nextPlannedCheckpoint'] = 'Finish both f233826 terminal archives and compose reviewed production changes plus exact compiler repairs into one source-bound SDK/Native pair. No per-change tags or IPA tag.'
policy['terminalArchivesPending'] = [{'runID': 39524696933, 'jobID': 118976499912, 'queryAgain': False}, {'runID': 39524697051, 'jobID': 118976500962, 'queryAgain': False}]
plan.setdefault('activeDevelopmentBatchRecords', []).extend([record_path.relative_to(R).as_posix(), 'docs/legado-ios/self-renewal-feasibility-reassessment-20261021.json', 'docs/legado-ios/core-native-f233826-test-compiler-repair.json'])
write(plan_path, plan); paths.append(plan_path)
write(S / 'canonical-integration-roster.json', [fact(path) for path in paths])
ignored = subprocess.run([GIT, 'check-ignore', '--stdin'], cwd=R, input=''.join(path.relative_to(R).as_posix() + '\n' for path in paths).encode(), capture_output=True)
assert ignored.returncode == 1 and not ignored.stdout
subprocess.run([GIT, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'productionAndTestSourceFiles': 22, 'compiledMainRoots': 11, 'distinctPassingMethods': 23, 'newTestExecutions': 0, 'newCloudRuns': 0}))
