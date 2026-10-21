from pathlib import Path, PurePosixPath
import datetime, hashlib, json, re, subprocess, xml.etree.ElementTree as ET

R = Path.cwd()
S = R / '.build/native-88c61ee-terminal'
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

f = read(S / 'factual-review-v1.json')
assert fact(S / 'factual-review-v1.json') == dict(bytes=17060, sha256='350dfd71166b733c79abc98b48f7df03046c182f87b0f279c594486fde8053aa')
assert f['sourceCommit'] == '88c61ee4b80889a617d344fda668d077f73fa95b'
assert f['runID'] == 39520240533 and f['jobID'] == 118962039359
assert f['jobStatus'] == 'completed' and f['conclusion'] == 'failure' and f['queryAgain'] is False
assert f['ordinaryJUnit'] == dict(XMLSuites=53, uniqueCaseIdentities=353, passed=348, failed=5, errors=0, skipped=0)
assert all(x == '?? debug.log' for x in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
items = {'factual-review.json': S / 'factual-review-v1.json',
         'scripts/archive-native-88c61ee-terminal.py': Path(__file__),
         'scripts/freeze-facts.py': S / 'freeze-facts.py'}
for row in f['evidence']:
    p = R / row['path']; check(p, row); items['facts/' + p.name] = p
members = read(S / 'artifact-member-facts.json')
assert len(members) == 64
cases, failed, general, suites = [], [], [], 0
excluded_binary = []
for row in members:
    relative = PurePosixPath(row['path'])
    assert not relative.is_absolute() and '..' not in relative.parts
    p = S / 'extracted' / relative
    check(p, row)
    name = relative.as_posix().removeprefix('.build/')
    if relative.parent.name == 'binary':
        excluded_binary.append(row)
    else:
        items['raw-artifact/' + name] = p
    if p.suffix == '.xml':
        suites += 1
        root = ET.fromstring(p.read_bytes())
        for node in root.iter('testcase'):
            identity = node.attrib['classname'] + '/' + node.attrib['name']
            cases.append(identity)
            assert node.find('error') is None and node.find('skipped') is None
            if node.find('failure') is not None: failed.append(identity)
            if node.attrib['classname'] == 'io.yuedu.legado.OriginalGeneralWebJsTest':
                assert node.find('failure') is None
                general.append(identity)
assert suites == 53 and len(cases) == len(set(cases)) == 353
assert len(failed) == 5 and set(failed) == {x['identity'] for x in f['failedCases']}
assert len(general) == 4
assert len(excluded_binary) == 3
job = read(S / 'terminal-jobs.json')['jobs'][0]
assert job['id'] == f['jobID'] and job['status'] == 'completed' and job['conclusion'] == 'failure'
assert job['steps'][4]['conclusion'] == 'failure'
assert all(x['conclusion'] == 'skipped' for x in job['steps'][5:9])
save(S / 'root-archive-check.json', dict(actualXMLSuites=suites, uniqueActualJVMCases=353,
    actualPassed=348, actualFailed=5, actualSkipped=0, generalFourActualPassed=general,
    nativeMethodsExecuted=0, rootTestsRerun=0, cloudQueries=0))
items['root-archive-check.json'] = S / 'root-archive-check.json'
normalized = {}
for name, p in items.items():
    raw = p.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode() if text else b''
base = R / 'docs/legado-ios/evidence/native-88c61ee-terminal'
rp = R / 'docs/legado-ios/core-native-88c61ee-terminal-result.json'
assert not base.exists() and not rp.exists()
pp = R / 'docs/legado-ios/completion-plan.json'
plan = read(pp)
assert all(plan[k] is False for k in FLAGS)
cloud = plan['execution']['cloudTriggerPolicy']
assert {x['runID'] for x in cloud['onlyLiveSDKHandles']} == {39520239925, 39520240533}
paths, preserved = [], []
for name, p in items.items():
    dst = base / name; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(), **fact(dst),
        original=dict(path=p.relative_to(R).as_posix(), **fact(p)),
        normalization='UTF8/LF/trailing whitespace only; exact original facts retained'))
record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='actual-Native88-terminal-failure-Gradle-JUnit-five-no-iOS-execution',
    sourceCommit=f['sourceCommit'], sourceTag=f['tag'], runID=f['runID'], jobID=f['jobID'],
    workflowURL='https://github.com/zhoujianjia/legado-ios/actions/runs/39520240533',
    workflowStatus='completed', conclusion='failure', queryAgain=False,
    earliestFailure=f['earliestFailure'], ordinaryJUnit=f['ordinaryJUnit'], failedCases=f['failedCases'],
    actualGeneralFourPassed=general, actualNativeOriginalMethodsExecuted=0,
    actualMainJSMethodsExecuted=0, actualColdHostsExecuted=0, actualSDK_JNI_UIKitAccepted=False,
    artifact=f['artifact'], historicalNative158Binding=f['historicalExpectedNativeSourceClosure'],
    binaryResultFilesRetainedInOriginalZIP=excluded_binary,
    archivePreparationHistory='Initial text-only archive preflight refused three Gradle binary result files before canonical writes. Resume preserves them in the original ZIP/member hashes; archives complete authoritative53 XML and text logs. No test/cloud rerun.',
    preservedEvidence=preserved, laterRepairDoesNotChangeThisFailure=True,
    limits=f['limits'], **{k: False for k in FLAGS})
save(rp, record); paths.append(rp)
terminal = dict(sourceCommit=f['sourceCommit'], runID=f['runID'], jobID=f['jobID'],
    status='completed', conclusion='failure', queryAgain=False, record=rp.relative_to(R).as_posix(),
    actualOrdinaryJVMPassed=348, actualOrdinaryJVMFailed=5, actualOrdinaryJVMSkipped=0,
    actualNativeSelectedMethodsExecuted=0, actualColdHostsExecuted=0,
    failure='Gradle:test five old expectation failures; later native phases skipped')
cloud['latestOriginalNativeTerminal'] = terminal
cloud['currentUnifiedCheckpoint']['nativeTerminal'] = terminal
cloud['onlyLiveSDKHandles'] = [x for x in cloud['onlyLiveSDKHandles'] if x['runID'] == 39520239925]
cloud['alreadyRunningTasks'] = ('Only SDK39520239925/job118962037971 at88c61ee remains live. '
    'Native39520240533 is terminal and archived; never query it or older terminal handles again.')
cloud['nextPlannedCheckpoint'] = ('Finish actual SDK88 observation/terminal archive and the five confirmed JVM expectation repairs. '
    'Then compose ordered/resource characterization and exact controls at one future checkpoint; no new tag before current SDK terminal.')
steps = plan['execution']['stepByStep']
steps['current88NativeTerminal'] = dict(record=rp.relative_to(R).as_posix(), actualJVMPassed=348,
    actualJVMFailed=5, actualNativeExecuted=0, actualColdHostsExecuted=0, queryAgain=False)
steps['queuedGeneralWebJSRuntimeRepairsNextCheckpoint']['nativeTerminalRecord'] = rp.relative_to(R).as_posix()
for step in steps['steps']:
    if step['id'] in ['C1', 'C4', 'C5']:
        step.setdefault('implementationEvidence', []).append(dict(record=rp.relative_to(R).as_posix(),
            scope='Actual353 JVM cases:348pass/5fail/0skip, including four new General tests passed. Gradle failure prevented all native/JNI/cold-host execution. Five affected expectation repairs remain separate and pending.'))
    if step['id'] in ['C4', 'C5']:
        step['nextActionZh'] = ('88c实际JVM353项中348通过、5失败、0跳过，iOS/JNI/MainJS与两个冷进程宿主均未执行；'
            '先按原语义修正5项过时拒绝预期并最小复验，保留权限、取消、副作用与请求次数门禁。'
            'SDK88仍独立运行；其终态归档后再合并下一组改动和明确选择项，不能据旧通过宣称当前完整验收。')
plan.setdefault('activeDevelopmentBatchRecords', []).append(rp.relative_to(R).as_posix())
save(pp, plan); paths.append(pp)
save(S / 'canonical-roster.json', [dict(path=p.relative_to(R).as_posix(), **fact(p)) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps(dict(reviewedPaths=len(paths), JVM=[353,348,5,0], actualNativeExecuted=0,
                      remainingLiveSDK=39520239925, newTags=0)))
