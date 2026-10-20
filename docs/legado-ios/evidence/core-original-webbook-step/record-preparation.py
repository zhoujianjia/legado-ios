import datetime,hashlib,json,subprocess,xml.etree.ElementTree as ET
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent
def metadata(path):
 p=root/path;data=p.read_bytes();return dict(path=path,bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
focused=json.loads((out/'focused-v7.json').read_bytes());ordinary=json.loads((out/'ordinary-v1.json').read_bytes());provenance=json.loads((out/'provenance-update.json').read_bytes())
assert focused['exitCode']==ordinary['exitCode']==0
unique=set();totals=dict(tests=0,failures=0,errors=0,skipped=0)
for p in sorted((out/'focused-v7-xml').glob('TEST-*.xml')):
 suite=ET.fromstring(p.read_bytes())
 for key in totals:totals[key]+=int(suite.attrib[key])
 for case in suite.findall('testcase'):
  key=(case.attrib['classname'],case.attrib['name']);assert key not in unique;unique.add(key)
assert len(unique)==totals['tests']==138 and totals['failures']==totals['errors']==totals['skipped']==0
for item in focused['sourceBinding']:assert metadata(item['path'])==item
git=Path('D:/app/Git/cmd/git.exe')
base='392d8ee'
changed=subprocess.check_output([str(git),'diff','--name-only',base,'--','Packages/LegadoRuntime/jvm','Packages/LegadoRuntime/vendor/original-rule'],cwd=root,text=True).splitlines()
untracked=subprocess.check_output([str(git),'ls-files','--others','--exclude-standard','--','Packages/LegadoRuntime/jvm','Packages/LegadoRuntime/vendor/original-rule'],cwd=root,text=True).splitlines()
names=sorted(set(changed+untracked));binding=[metadata(name) for name in names]
for item in binding:
 p=out/'final-sources'/item['path'];p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((root/item['path']).read_bytes())
attempts=[]
for version in range(1,8):
 path=out/f'focused-v{version}.json';record=json.loads(path.read_bytes());attempts.append(dict(record=metadata(path.relative_to(root).as_posix()),exitCode=record['exitCode'],actualMethods=sum(s['tests'] for s in record['junitSuites']),failures=sum(s['failures'] for s in record['junitSuites'])))
record={
 'schemaVersion':1,'recordedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'baseCommit':base,
 'originalArchive':dict(path='F:/legado-master.zip',bytes=11178463,sha256='724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd'),
 'scope':'Actual retained original text-only transient WebBook await chain, bound to the existing RuntimeTask/JVM HTTP/Cookie/deadline. Internal caller interface; not selected by LegadoRuntime.execute or Swift App routing.',
 'sourceBinding':dict(acceptedExecutionInputs=focused['sourceBinding'],changedCodeTestsAndProvenance=binding,currentInputsEqualFinalExecutionSnapshot=True,allChangedFilesFrozenUnder='.build/original-webbook-execution/final-sources/'),
 'validation':dict(actualFocusedUniqueMethods=138,newWebBookMethods=13,existingMethodsRevalidated=125,junitSuites=12,uniqueTestcaseLeaves=len(unique),failures=0,errors=0,skipped=0,focusedRecord=metadata('.build/original-webbook-execution/focused-v7.json'),ordinaryRecord=metadata('.build/original-webbook-execution/ordinary-v1.json'),actualAttempts=attempts,notSummedAcrossAttemptsOrHistoricalGroups=True,originalAndroidGoldenVectorsWithinExistingMethods=dict(scalar=28,jsonPath=36),newAndroidObservations=False),
 'implemented':[
  'Locked-ZIP WebBook await search/detail/TOC/no-save content/precise-search and preUpdateJs dispatch into retained original BookList/BookInfo/BookChapterList/BookContent and AnalyzeRule; no parallel simplified parser.',
  'Real owned loopback CSS search to XPath details to two JSON TOC pages to two content pages and separate second chapter; regex-group search, filter/break, conversion and same mutable Book/Chapter identity/state, shared real JVM cookies and dynamic headers.',
  'Original TOC reverse-deduplicate-reverse-index, duplicate URL winning metadata, serial/fanout redirect base differences and ordered mapAsync; content homepage replacement/title, next chapter/cycle stop, first-next versus multi-URL strategy, original HTML formatting/usehtml/image resolution.',
  'Original loginCheck execution error flow and synthetic code500 raw/body, constructor exceptions escape, typed unsupported/cancellation preserved even through login recovery; actual CPU caller cancellation/deadline and environment/session close reject late publication.',
 ],
 'remainingUnsupportedOrUnfinished':[
  'Only text sources and explicit needSave=false content. Durable contentSaveToken/generation/cache persistence, contentBatch/BatchContentContext/cacheContent and App publication remain unfinished/typed unsupported.',
  'Environment chapter store is transient in-memory lookup/published entity state, not Room. Android title replacement/config/simulated count and durable prior chapter metadata adapters remain unfinished.',
  'mainJs remains separate existing route; media/file/explore navigation/infoMap, browser/webJs/sourceRegex, configured proxy, upload/rate limiting, subContent side channels and complete model/source APIs remain unported or typed unsupported at invocation.',
  'Source/login/cache state remains finite environment-owned memory; Android app-global persistence and full original StrResponse FQN/ABI are not claimed.',
  'Current awaited Java callback is not forcibly interrupted by close; late output is rejected by original owner/task/guard boundaries. No new timer/thread/transport.',
  'No Android, iOS, Zero/JNI, App traditional route, private source, live website, real-device, CI or full compatibility validation was run here.',
 ],
 'retainedProvenance':provenance,
 'attemptNotes':[
  'v1 and v2 production compile failures, zero tests: finite AnalyzeUrl companion visibility/typealias/import corrections.',
  'v3 test fixture missing closing lambda brace caused compile failure, zero tests.',
  'v4 actual9 methods/3 failures: fixtures assumed non-original formatter spacing/newlines and attempted getClass blocked by existing Rhino wrapper. Production formatter semantics retained; exact formatted expectation and independent fanout ordering assertions corrected; actual Java type checked via instanceof.',
  'v5 actual74 pass then superseded by narrower login recovery typed-control handling and expanded boundary regressions.',
  'v6 actual138 pass then superseded only by same owner session.closed guard and one existing close method checking both environment/session combinations. No added method count.',
  'v7 final actual138 pass; no production/test changes after its source snapshot. Vendor source/port manifest subsequently updated and ordinary JAR/smoke executed once.',
  'An ordinary-runner authoring inline Python shell quoting command failed before producing/running the runner; corrected by exact file copy plus apply_patch. This was not a build/test attempt.',
 ],
 'globalCompletionFlags':dict(allNonDeviceWorkComplete=False,automaticSelfRenewalImplemented=False,fullLegadoCompatibilityEstablished=False,legalRedistributionClearanceEstablished=False),
}
(out/'preparation.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(preparation=metadata('.build/original-webbook-execution/preparation.json'),frozenChangedFiles=len(binding),executionInputs=len(focused['sourceBinding']),uniqueMethods=len(unique),ordinaryJar={k:v for k,v in ordinary['ordinaryJar'].items() if k in ['bytes','sha256','projectCompiledTestClassesChecked','junitOrProjectTestClasses']})))
