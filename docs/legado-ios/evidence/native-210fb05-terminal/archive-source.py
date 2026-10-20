from pathlib import Path
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path('F:/yuedu-reader')
STAGE = ROOT / '.build/consolidated-native-210fb05'
DATA = STAGE / 'extracted/.build/native-reader-test'
GIT = 'D:/app/Git/cmd/git.exe'
SOURCE = '210fb0597dcc4081db9324876c4be922ba186367'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(path): return json.loads(path.read_bytes())
def digest(raw): return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def fact(path): return digest(path.read_bytes())
def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())
def verify(path, row): assert fact(path) == {k: row[k] for k in ['bytes', 'sha256']}, str(path)
def cases(tree):
    found = []
    def walk(node):
        if isinstance(node, dict):
            if node.get('nodeType') == 'Test Case': found.append(node)
            for value in node.values(): walk(value)
        elif isinstance(node, list):
            for value in node: walk(value)
    walk(tree)
    return found

assert not subprocess.check_output([GIT, 'status', '--porcelain'], cwd=ROOT)
head = subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
assert head == '55a41b59a8a74e3cf0f8c08178e2a429cd2ccc1a'
review_path = ROOT / '.build/consolidated-native-210fb05-independent-review/review.json'
verify(review_path, {'bytes': 87283, 'sha256': '42eb0d23306af098fc7c47f971322db2c8ab5b52dee28cdbd387d17111d1dcb6'})
review = read(review_path)
assert review['status'] == 'actual-terminal-failure-source-and-evidence-confirmed'
job = read(STAGE / 'workflow-job.json')['jobs'][0]
assert job['id'] == 118813819896 and job['status'] == 'completed' and job['conclusion'] == 'failure'
assert next(v for v in job['steps'] if v['number'] == 8)['conclusion'] == 'failure'
verify(STAGE / 'artifact.zip', {'bytes': 3261447, 'sha256': '2333e5beb000c416fb81584696d009bcd46955e9f28de46fcedd296f992a319e'})
with zipfile.ZipFile(STAGE / 'artifact.zip') as archive:
    assert archive.testzip() is None
    members = [{'path': v.filename, **digest(archive.read(v.filename))} for v in archive.infolist() if not v.is_dir()]
    assert len(members) == 482
source = read(DATA / 'native-source-inputs.json')
assert source['sourceCommit'] == SOURCE and len(source['sourceInputs']) == 107
for row in source['sourceInputs']:
    raw = subprocess.check_output([GIT, 'show', SOURCE + ':' + row['path']], cwd=ROOT)
    assert digest(raw) == {k: row[k] for k in ['bytes', 'sha256']}, row['path']
for name, expected_code, count in [('native-product-chain-execution.json', 0, 1), ('original-product-chain-execution.json', 1, 17)]:
    ledger = read(DATA / name)
    assert ledger['sourceBefore'] == ledger['sourceAfter'] == source
    assert len(ledger['expectedMethods']) == count and len(ledger['commands']) == 3
    assert ledger['commands'][0]['exitCode'] == expected_code and ledger['commands'][0]['timedOut'] is False
    for command in ledger['commands']:
        verify(DATA / command['output'], command['stdout'])
        verify(DATA / command['stderr'], command['stderrFact'])
groups = []
for name, summary_name, tests_name, defs, runs, failed in [
    ('configuration','configuration-summary.json','configuration-tests.json',9,9,0),
    ('localproduct','local-product-summary.json','local-product-tests.json',50,68,0),
    ('cache','cache-summary.json','cache-tests.json',6,8,0),
    ('mainjs','summary.json','native-tests.json',1,1,0),
    ('original','original-summary.json','original-tests.json',17,17,13),
]:
    summary = read(DATA / summary_name); methods = cases(read(DATA / tests_name))
    assert summary['totalTestCount'] == len(methods) == defs
    assert summary['failedTests'] == failed and summary['passedTests'] == defs - failed
    assert summary['skippedTests'] == summary['expectedFailures'] == 0
    assert len(summary['devicesAndConfigurations']) == 1
    device = summary['devicesAndConfigurations'][0]
    assert device['passedTests'] == runs - failed and device['failedTests'] == failed
    assert device['skippedTests'] == device['expectedFailures'] == 0
    assert sum(m['result'] == 'Passed' for m in methods) == defs - failed
    assert sum(m['result'] == 'Failed' for m in methods) == failed
    if name in ['mainjs','original']:
        ledger_name = 'native-product-chain-execution.json' if name == 'mainjs' else 'original-product-chain-execution.json'
        assert {m['nodeIdentifier'].removesuffix('()') for m in methods} == set(read(DATA / ledger_name)['expectedMethods'])
    groups.append({'group': name, 'definitions': defs, 'executionLeaves': runs, 'passedDefinitions': defs-failed, 'failedDefinitions': failed, 'cases': [{'identity': m['nodeIdentifier'], 'result': m['result']} for m in methods]})
xmls = sorted((STAGE / 'extracted/Packages/LegadoRuntime/jvm/build/test-results').rglob('TEST-*.xml'))
assert len(xmls) == 43
jvm_suites = []
for xml in xmls:
    suite = ET.parse(xml).getroot(); entries = suite.findall('testcase')
    assert len(entries) == int(suite.attrib['tests'])
    assert all(int(suite.attrib[k]) == 0 for k in ['failures','errors','skipped'])
    assert not suite.findall('.//failure') + suite.findall('.//error') + suite.findall('.//skipped')
    jvm_suites.append({'member': xml.relative_to(STAGE / 'extracted').as_posix(), **fact(xml), 'suite': suite.attrib['name'], 'tests': len(entries), 'methods': [v.attrib['name'] for v in entries]})
assert sum(r['tests'] for r in jvm_suites) == 309
build = (DATA / 'native-build.log').read_text(encoding='utf-8')
assert ': error:' not in build and '** TEST BUILD SUCCEEDED **' in build
exports = read(DATA / 'native-exports.json')
assert exports['requiredDynamicExportsPresent'] is True and exports['missingExports'] == []
assert 'BUILD SUCCESSFUL' in (STAGE / 'extracted/.build/ci-logs/native-reader-jvm.log').read_text(encoding='utf-8')
base = ROOT / 'docs/legado-ios/evidence/native-210fb05-terminal'
record_path = ROOT / 'docs/legado-ios/core-native-210fb05-terminal-result.json'
assert not base.exists() and not record_path.exists()
values = {'artifact-members.json': {'artifactID': 12293848839, **fact(STAGE/'artifact.zip'), 'crcPassed': True, 'members': members}, 'actual-groups.json': groups, 'jvm-results.json': {'suites': jvm_suites, 'methodsPassed': 309, 'failures': 0, 'errors': 0, 'skipped': 0}, 'complete-log-facts.json': {name: fact(DATA/name) for name in ['native-build.log','configuration.log','local-product-regressions.log','cache-regressions.log','native-product-chain.log','original-product-chain.log','native-exports.log']}}
items = [(STAGE/'workflow-job.json','workflow-job.json'), (STAGE/'artifacts.json','artifacts.json'), (review_path,'independent-review.json'), (review_path.parent/'original-failure-lines.txt','original-failure-lines.txt')]
for name in ['native-source-inputs.json','native-product-chain-execution.json','original-product-chain-execution.json','native-exports.json','native-restore.json','ordinary-jar.json','configuration-summary.json','configuration-tests.json','local-product-summary.json','local-product-tests.json','cache-summary.json','cache-tests.json','summary.json','native-tests.json','original-summary.json','original-tests.json','diagnostics/collection.json']:
    items.append((DATA/name, name))
items.append((ROOT/'.build/archive-native-210-terminal.py','archive-source.py'))
evidence = []
for name, value in values.items():
    dst=base/name; write(dst,value); evidence.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst)})
for src,name in items:
    raw=src.read_bytes(); text=raw.decode('utf-16' if raw[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig')
    normalized='\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n')
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes((normalized+'\n').encode())
    evidence.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst),'rawEvidence':{'path':src.relative_to(ROOT).as_posix(),**fact(src)},'normalization':'UTF8/LF, horizontal trailing whitespace and empty EOF lines removed; raw facts retained'})
record = {'schemaVersion':1,'recordedOn':'2026-10-21','status':'terminal-native-original-runtime-and-fixture-failures-with-stale-localproduct-gate','sourceCommit':SOURCE,'runID':39476534384,'jobID':118813819896,'runURL':'https://github.com/zhoujianjia/legado-ios/actions/runs/39476534384','queryAgain':False,'artifact':{'id':12293848839,**fact(STAGE/'artifact.zip'),'CRC':True,'members':482},'sourceInputsVerifiedAgainstFrozenGit':107,'ordinaryJVM':{'suites':43,'methodsPassed':309,'failures':0,'errors':0,'skipped':0},'actualIOSGroups':[{k:v for k,v in row.items() if k!='cases'} for row in groups],'actualNativeMainJSPassed':True,'actualOriginalNativeComplete':False,'actualNew463SDKOrDeviceAccepted':False,'actualTimeout':False,'SwiftCompilerErrors':0,'requiredNativeExportsPassed':True,'confirmedFailures':['Three direct fixture Runtime/Host instances violate the single process-scoped JVM host-context configuration.','Original-reader13 failed methods include duplicate namespace URLs, original content formatter indentation expectations, source-context values and unauthorized eager chapter-variable reads. Each causal fix must preserve exact host grants and real HTTP cancellation.','The workflow local-product --expected41 is stale; actual50 definitions/68 executions are green. Correct the source-based dual-count/identity gate, retaining original13 failures as failures.'],'diagnosticsScope':'Collection partial: linked CrashReporter path was rejected safely; absence of crash artifact members is not evidence of no crash. Complete runtime/current and previous stage files remain in ignored actual ZIP.','rootReview':'Read complete summaries, actual method tree identities and failure lines; independently verified all107 Git source bytes, both before/after command ledgers and output/error hashes, all43 raw XML suites309 methods, full build success and required exports. Archive is a genuine terminal failure, with MainJS1 and four original methods passing, not whole source compatibility. The two control defects from the separate SDK terminal remain independently repaired in55a. No new tag or retry is created by this archive.','preservedEvidence':evidence,'nextAction':'Repair all confirmed Native production/fixture and stale gate causes, bind their actual affected inputs with the already reviewed55a cohort, and independently review before one fresh SDK/Native pair. Later V2/browser work remains isolated.','deliveredBuild14Unchanged':True,**{key:False for key in FLAGS}}
write(record_path,record)
request_path=ROOT/'docs/legado-ios/core-sdk-210fb05-request.json'; request=read(request_path)
for handle in request['handles']:
    if handle['runID']==39476534384: handle.update(status='completed',conclusion='failure',queryAgain=False,terminalRecord=record_path.relative_to(ROOT).as_posix(),actualSelectedMethods=17,passedSelectedMethods=4,current=[])
request.update(status='both-terminal-failure-actual-causes-reviewed-repair-before-next-coherent-pair',NativeTerminalRecord=record_path.relative_to(ROOT).as_posix(),actualSDKOrJNIResultYet=False)
write(request_path,request)
plan_path=ROOT/'docs/legado-ios/completion-plan.json'; plan=read(plan_path); cloud=plan['execution']['cloudTriggerPolicy']
assert [(v['runID'],v['jobID']) for v in cloud['onlyLiveSDKHandles']]==[(39476534384,118813819896)]
cloud['onlyLiveSDKHandles']=[]
cloud['latestOriginalNativeTerminal']={'sourceCommit':SOURCE,'runID':39476534384,'jobID':118813819896,'status':'completed','conclusion':'failure','queryAgain':False,'record':record_path.relative_to(ROOT).as_posix(),'actualNativeSelectedMethodsExecuted':17,'actualNativeSelectedMethodsPassed':4,'MainJSMethodsPassed':1,'ordinaryJVMMethodsPassed':309}
cloud['alreadyRunningTasks']='None. Both source210fb05 SDK and Native are terminal and archived. Never poll them or earlier closed runs again; no new source pair is submitted until concrete failures are repaired.'
cloud['nextPlannedCheckpoint']='Repair the actualNative210 single-JVM fixture, duplicate URL/content expectations, eager metadata chapter-variable reads and stale localproduct gate first. Bind these fixes with reviewed55a delta19+control9 and all actual changed inputs; preserve App463/466 and required signer, Native20+separateMainJS1, and fresh Package23 unless a separately reviewed later source cohort changes the explicit inventory. No restart for elapsed observation and no per-item/device tag.'
plan['activeBatchRecord']=record_path.relative_to(ROOT).as_posix()
steps=plan['execution']['stepByStep']; steps['current210NativeTerminal']={'record':record_path.relative_to(ROOT).as_posix(),'actualOriginalMethodsExecuted':17,'actualOriginalMethodsPassed':4,'actualMainJSPassed':1,'ordinaryJVMPassed':309,'requiresConfirmedFailureRepairs':True}
steps['currentReviewedConsolidatedCheckpoint']['status']='requires-confirmed-Native210-production-fixture-and-localproduct-gate-repair-before-submission'
for key in FLAGS: assert plan[key] is False
write(plan_path,plan)
paths=[base/name for name in values]+[base/name for _,name in items]+[record_path,request_path,plan_path]
assert len(paths)==len(set(paths))
write(STAGE/'canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**fact(p)} for p in paths])
subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'reviewedPaths':len(paths),'sourceInputs':107,'JVMTestsPassed':309,'actualOriginalMethodsExecuted':17,'actualOriginalMethodsPassed':4,'actualMainJSPassed':1,'liveHandles':0,'newTags':0}))
