from pathlib import Path
import datetime
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET

R=Path('F:/yuedu-reader');T=R/'.build/sdk-88c61ee-terminal';S=R/'.build/sdk-88c61ee-terminal-source-independent-review';S.mkdir(exist_ok=True)
A=T/'SDK/extracted/reader-renewal-probe';P=T/'Package/extracted/reader-renewal-original-api'
COMMIT='88c61ee4b80889a617d344fda668d077f73fa95b'
def load(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(b):return hashlib.sha256(b).hexdigest()
def fact(p):
 b=p.read_bytes();return dict(path=p.relative_to(R).as_posix(),bytes=len(b),sha256=sha(b))
def write(p,d):p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
checks=[]
def check(name,ok):checks.append(dict(name=name,passed=bool(ok)))
def bind(d,base=R):
 f=fact(base/d['path']);check('raw binding:'+d['path'],f['bytes']==d['bytes'] and f['sha256']==d['sha256']);return f
author_path=T/'factual-review-v1.json';author_fact=fact(author_path)
check('exact author final',author_fact['bytes']==10549 and author_fact['sha256']=='09caed66d1f659473ee1bd18094df722e6e24c97b0d7a39a96e1047b975bbefd')
author=load(author_path);check('exact historical source',author['sourceCommit']==COMMIT)
core=load(A/'source-inputs.json');package=load(P/'source-inputs.json');pkg_result=load(P/'result.json');pkg_execution=load(P/'execution.json')
producer=load(A/'sdk-produced-public/sdk-produced-fixture-manifest.json')
check('core source346 unique',len(core['sourceInputs'])==346 and len({x['path'] for x in core['sourceInputs']})==346)
check('package source23 unique and16 package inputs',len(package['sourceInputs'])==23 and len({x['path'] for x in package['sourceInputs']})==23 and package['packageSourceInputCount']==16)
check('core and Package prep source identity',core['sourceCommit']==package['sourceCommit']==pkg_result['sourceCommit']==COMMIT)
producer_inputs=[dict(x,path='scripts/reader-experience/owned-package-fixture/'+x['path']) for x in producer['sourceInputs']]
inputs={}
for group,rows in [('core346',core['sourceInputs']),('Package23',package['sourceInputs']),('producer7',producer_inputs)]:
 for row in rows:
  if row['path'] in inputs:
   check('overlap agrees:'+row['path'],inputs[row['path']]['bytes']==row['bytes'] and inputs[row['path']]['sha256']==row['sha256'])
   inputs[row['path']]['groups'].append(group)
  else:inputs[row['path']]={**row,'groups':[group]}

# Exactly one read-only Git batch for all distinct historical source bytes.
paths=sorted(inputs)
source_fact_path=S/'historical-source-bindings-v1.json'
if source_fact_path.exists():
 cached=load(source_fact_path)
 check('reuse completed single historical Git batch',cached['sourceCommit']==COMMIT and cached['readOnlyGitBatchProcesses']==1 and cached['uniquePaths']==len(paths))
 source_records=cached['files']
 for row in source_records:
  expected=inputs[row['path']]
  check('historical Git blob:'+row['path'],row['exact'] and row['bytes']==expected['bytes'] and row['sha256']==expected['sha256'] and row['groups']==expected['groups'])
else:
 request=''.join(COMMIT+':'+p+'\n' for p in paths).encode('utf-8')
 done=subprocess.run(['git','cat-file','--batch'],cwd=R,input=request,capture_output=True)
 check('single batch Git read successful',done.returncode==0)
 cursor=0;source_records=[]
 for rel in paths:
  stop=done.stdout.index(b'\n',cursor);header=done.stdout[cursor:stop].decode('ascii');parts=header.split();cursor=stop+1
  assert len(parts)==3 and parts[1]=='blob',header
  oid,_,size=parts;size=int(size);raw=done.stdout[cursor:cursor+size];cursor+=size
  assert done.stdout[cursor:cursor+1]==b'\n';cursor+=1
  expected=inputs[rel];observed=sha(raw);git_oid=hashlib.sha1(b'blob '+str(size).encode()+b'\0'+raw).hexdigest()
  ok=size==expected['bytes'] and observed==expected['sha256'] and oid==git_oid
  check('historical Git blob:'+rel,ok)
  source_records.append(dict(path=rel,bytes=size,sha256=observed,gitBlobOID=oid,expectedBytes=expected['bytes'],expectedSHA256=expected['sha256'],exact=ok,groups=expected['groups']))
 check('complete Git batch consumed',cursor==len(done.stdout))
 write(source_fact_path,dict(sourceCommit=COMMIT,readOnlyGitBatchProcesses=1,coreCount=346,PackageCount=23,producerCount=7,uniquePaths=len(paths),files=source_records))

closure=sha(json.dumps(core['sourceInputs'],sort_keys=True,separators=(',',':')).encode())
historical_tool=(R/'.build/consolidated-sdk-native-characterization-jvm-fixtures-checkpoint/rawbaseline/scripts/reader-experience/renewal-probe-tools.py').read_bytes()
check('historical closure hash source algorithm unchanged',sha(historical_tool)==inputs['scripts/reader-experience/renewal-probe-tools.py']['sha256'] and b'json.dumps(records, sort_keys=True, separators=(",", ":"))' in historical_tool)
pipeline=load(A/'currentcore-pipeline.json');completion=load(A/'currentcore-completion.json')
phase_names=['producer','stage','before-build','boot','native','export','cases','test-settings','after-tests','build-settings','result']
check('ten original pipeline phases plus one terminal result',pipeline['phaseOrder']==phase_names[:-1] and len(author['phases'])==11)
phases={};ledger=[]
for name in phase_names:
 p=A/('currentcore-phase-'+name+'.json');phase=load(p);phases[name]=phase
 check('phase identity:'+name,phase['phase']==name)
 for side in ['sourceBefore','sourceAfter']:
  state=phase[side]
  check('historical source state:'+name+':'+side,state['sourceCommit']==COMMIT and state['sourceInputCount']==346 and state['sourceInputsSHA256']==closure and state['runtimeSourceOnly'] is True and state['requiredPortableGuardsOutcome']=='success')
  for key in ['preparation','overlays','xcodeVersion']:bind(state[key],A)
 check('before after same source:'+name,phase['sourceBefore']==phase['sourceAfter'])
 if phase.get('command'):
  cmd=phase['command'];check('intended actual argv exact:'+name,phase['intendedArgv']==cmd['argv'])
  for path,size,digest in [('output','bytes','sha256'),('stderr','stderrBytes','stderrSHA256')]:
   bind(dict(path=cmd[path],bytes=cmd[size],sha256=cmd[digest]),A)
  check('no phase command timeout:'+name,cmd['timedOut'] is False and cmd['oversized'] is False)
 ledger.append(dict(phase=name,state=phase['state'],exitCode=(phase.get('command') or {}).get('exitCode'),timedOut=(phase.get('command') or {}).get('timedOut'),timeoutSeconds=phase['timeoutSeconds'],blockedBy=phase['blockedBy'],raw=fact(p),sourceSnapshotsExact=True))
for phase,raw_record in zip(pipeline['phases'],pipeline['phaseRecords']):
 check('pipeline exact raw phase:'+phase['phase'],phase==phases[phase['phase']]);bind(raw_record,A)
check('pipeline and completion source exact',pipeline['source']==completion['source']==phases['native']['sourceBefore'])
check('completion terminal result exact',completion['resultPhase']==phases['result'] and completion['ledgerSHA256']==fact(A/'currentcore-pipeline.json')['sha256'])
check('native is actual first failure',pipeline['firstFailure']==completion['firstFailure']==dict(phase='native',exitCode=1) and completion['exitCode']==1 and completion['resultProduced'] is False)
write(S/'phase-source-binding-v1.json',dict(sourceCommit=COMMIT,sourceInputCount=346,sourceInputsSHA256=closure,rawPhaseLedgers=11,sourceSnapshots=22,phases=ledger))

native=phases['native'];argv=native['command']['argv'];selectors=[a for a in argv if a.startswith('-only-testing:')]
intended=core['intendedTests']['currentcore'];matrices=core['intendedArgumentCases']
xctest_suites={'ReadingPositionStorePersistenceTests','ReaderViewportSizeObserverHostingTests'}
check('historical XCTest selector exception preserved',all(('"'+suite+'"').encode() in historical_tool for suite in xctest_suites) and b'if case.split("/", 1)[0] in CURRENTCORE_XCTEST_SUITES:\n        return case' in historical_tool)
expected=['-only-testing:yuedu appTests/'+case+('('+matrices[case]['parameter']+':)' if case in matrices else '' if case.split('/')[0] in xctest_suites else '()') for case in intended]
signer='-only-testing:yuedu appTests/SelfRenewalControlledPackageSignerTests/signsSDKProducedMainExtensionsAndFrameworkInSameJob()'
check('one native argv exact463 selectors and mandatory signer',len(selectors)==len(set(selectors))==463 and selectors==expected and signer in selectors)
check('three Bool matrices and intended466 leaves',len(matrices)==3 and all(x['values']==[False,True] for x in matrices.values()) and core['intendedQualifiedMethodDefinitions']==463 and core['intendedArgumentLeafCount']==466 and pipeline['qualifiedMethodDefinitions']==463 and pipeline['argumentLeaves']==466)
check('native original wrapper3600 parent3720',argv.count('-resultBundlePath')==1 and argv[argv.index('-t')+1]=='3600' and native['timeoutSeconds']==3720)
check('actual native phase1 xcode65 no timeout',native['command']['exitCode']==1 and native['reportedXcodebuildStatuses']==[dict(exitCode=65,wrapperVerdictStop=False)] and native['wrapperReportedBudgetTimeout'] is False and native['command']['timedOut'] is False)
summary=load(A/'currentcore-summary.json');tree=load(A/'currentcore-tests.json')
check('zero actual App tests rather than463 failures',summary['totalTestCount']==summary['passedTests']==summary['failedTests']==summary['skippedTests']==0 and summary['result']=='unknown' and tree['testNodes']==[])
log=(A/'currentcore-tests.log').read_text(encoding='utf-8')
errors=[]
for match in re.finditer(r'(?m)^([^\r\n]*\.swift):(\d+):(\d+): error: ([^\r\n]+)',log):
 path=match.group(1);path=path[path.index('Modules/'):] if 'Modules/' in path else path
 errors.append((path,int(match.group(2)),int(match.group(3)),match.group(4)))
unique=sorted(set(errors));compiler=load(T/'factual-v1/compiler-errors.json')
expected_errors=sorted((x['source'],x['sourceLine'],x['sourceColumn'],x['diagnostic']) for x in compiler['unique'])
check('exact two production compiler errors50 repeated',unique==expected_errors and len(unique)==2 and len(errors)==50)

check('Package before and after source lists exact',package['sourceInputs']==pkg_result['sourceInputs'])
xunit=ET.fromstring((P/'xunit.xml').read_bytes());cases=list(xunit.iter('testcase'))
package_ids=sorted(x.get('classname')+'/'+x.get('name') for x in cases)
check('actual Package24 XML no failures/skips',len(cases)==24 and all(not list(c.iter('failure')) and not list(c.iter('error')) and not list(c.iter('skipped')) for c in cases))
check('four Package identity rosters exact',package_ids==sorted(package['qualifiedXCTestMethods'])==sorted(pkg_result['qualifiedXCTestMethods'])==sorted(pkg_result['passedCaseIdentifiers'])==sorted(pkg_result['verbosePassedCaseIdentifiers']))
check('Package24 real macOS only no JVM or App',pkg_result['status']=='passed' and pkg_result['totalTestCount']==24 and pkg_result['failedTests']==pkg_result['skippedTests']==pkg_result['appSimulatorCaseCount']==0 and pkg_result['jvmExecuted'] is False and pkg_execution['exitCode']==0 and pkg_execution['completed'] is True and pkg_execution['timedOut'] is False and pkg_execution['runtimeSourceOnly'] is True)
check('Package execution actual24 selector regex same',pkg_execution['arguments'][pkg_execution['arguments'].index('--filter')+1]==package['filter'] and '--disable-swift-testing' in pkg_execution['arguments'])
for name,digest in pkg_result['evidenceSHA256'].items():check('Package raw execution evidence:'+name,fact(P/name)['sha256']==digest)

check('producer48 owned commands complete',len(producer['commands'])==48 and all(x['exitCode']==0 and x['timedOut'] is False and x['processCleanup']['drained'] and x['processCleanup']['childReaped'] and x['processCleanup']['pipesClosed'] and not x['processCleanup']['issues'] for x in producer['commands']))
check('producer43 public outputs4 MachO',len(producer['publicOutputs'])==43 and len(producer['actualSDKProducedMachOs'])==4)
check('producer cleanup no real Apple authority',producer['temporaryOwnedKeychainDeleted'] is True and producer['temporaryUserSearchListRestoredAndOwnedAbsent'] is True and producer['userAdminSystemTrustChanged'] is False and producer['privateKeyFilesOutsideKeychain']==producer['privateMaterialArtifacts']==0 and producer['realAppleAccountUsed'] is False)
binding=load(A/'sdk-fixture-binding.json');before=load(A/'sdk-fixture-before-build.json')
check('required SDK fixture bound before actual build',binding['sourceCommit']==before['sourceCommit']==COMMIT and before['bindingSHA256']==fact(A/'sdk-fixture-binding.json')['sha256'] and binding['manifest']=={k:v for k,v in fact(A/'sdk-produced-public/sdk-produced-fixture-manifest.json').items() if k!='path'} and before['resourceBytes']==binding['resource']['bytes'] and before['resourceSHA256']==binding['resource']['sha256'])
for row in author['phases']:bind(row['raw'])
for row in author['rawGates']:bind(row)
bind(author['producer']);bind(author['Package']);bind(author['compiler']);bind(author['selection'])
failed=[c for c in checks if not c['passed']]
write(S/'verification-v1.json',dict(checks=checks,remainingMismatches=failed))
compact_source_path=S/'historical-source-bindings-compact-v1.json'
write(compact_source_path,dict(sourceCommit=COMMIT,readOnlyGitBatchProcesses=1,core346Exact=True,Package23Exact=True,producer7Exact=True,uniquePaths=len(paths),files=[{k:v for k,v in row.items() if k in ['path','bytes','sha256','gitBlobOID','groups']} for row in source_records]))
review=dict(schemaVersion=1,frozenUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),reviewer='/root/login_info_v2_review',approved=not failed,final=author_fact,sourceCommit=COMMIT,failedChecks=len(failed),remainingConfirmedFindings=[],remainingMismatches=failed,
 status='Independent historical source binding supplement completed; actual App compiler block and zero executed App cases preserved.' if not failed else 'Source binding supplement contains mismatches; do not promote source claims.',
 sourceFacts=fact(compact_source_path),originalBatchFacts=fact(source_fact_path),phaseFacts=fact(S/'phase-source-binding-v1.json'),verification=fact(S/'verification-v1.json'),verifier=fact(Path(__file__).resolve()),
 historicalSourceBinding=dict(core346Exact=True,Package23Exact=True,PackageBeforeAfterExact=True,producer7Exact=True,uniqueHistoricalGitPaths=len(paths),readOnlyGitBatchProcesses=1,allElevenPhaseBeforeAfterSourceFactsExact=True,sourceSnapshots=22,sourceInputsSHA256=closure),
 actualApp=dict(executedDefinitions=0,executedLeaves=0,summaryResult='unknown',summaryTestCount=0,uniqueCompileErrors=[dict(source=p,line=l,column=c,diagnostic=e) for p,l,c,e in unique],repeatedCompileDiagnostics=len(errors),intendedDefinitions=463,intendedLeaves=466,XCTestBareSelectors=sum(case.split('/')[0] in xctest_suites for case in intended),SwiftTestingDefinitions=sum(case.split('/')[0] not in xctest_suites for case in intended),BoolMatrices=3,requiredSignerSelected=True,nativePhaseExit=1,xcodebuildExit=65,nativeTimeout=False,resultProduced=False),
 actualPackage=dict(methods=24,passed=24,failed=0,skipped=0,sourceFacts=23,packageSourceInputs=16,mode=package['selectionMode'],JVMExecuted=False,AppMethods=0),
 producerScope=dict(commands=48,publicOutputs=43,SDKProducedMachOs=4,sourceInputs=7,allCommandsExitZeroNoTimeoutDrained=True,cleanupRecorded=True,realAppleAccountUsed=False),
 rawEvidence=[fact(A/'source-inputs.json'),fact(P/'source-inputs.json'),fact(P/'result.json'),fact(P/'xunit.xml'),fact(P/'execution.json'),fact(A/'currentcore-pipeline.json'),fact(A/'currentcore-completion.json'),fact(A/'currentcore-tests.log'),fact(A/'currentcore-summary.json'),fact(A/'currentcore-tests.json'),fact(A/'sdk-produced-public/sdk-produced-fixture-manifest.json'),fact(A/'sdk-fixture-binding.json'),fact(A/'sdk-fixture-before-build.json')],
 limits=['Core346 and Package23 are the historically declared evidence inventories, not an assertion that they cover every transitive Xcode/SwiftPM/SDK dependency or all files Xcode may compile.','These facts bind historical88c Git blobs. Later test fixes, Ordered/Resource characterization and future349/161 controls were not executed by this historical job.','No App cases executed. The two production compiler errors blocked compilation; it is incorrect to describe all463 selected methods as failed tests. No App signing test, App linking/CodeSign, JNI or physical-device renewal pass is established.','Package24 is actual macOS source-only protocol/API execution and producer48/43/4 is actual synthetic fixture production. Neither is App signer acceptance or Apple-account/device renewal.','This review checked raw source/provenance/exit facts. It did not rerun Swift tests, a compiler, a parser, a cryptographic verifier, producer commands or any cloud fetch.','Original factual-review file and large raw logs remain unchanged. Raw/private download responses and URLs are not copied into this supplement.'],
 operations=dict(canonicalWrites=False,peerEvidenceWrites=False,GitWrites=False,GitReadBatches=1,cloudFetches=0,testsRerun=0,parserRuns=0,compilerRuns=0))
rp=S/'review-v1.json';write(rp,review)
print(json.dumps(dict(review=fact(rp),sourceFacts=fact(source_fact_path),failedChecks=len(failed),mismatches=failed),ensure_ascii=False))
if failed:raise SystemExit(1)
