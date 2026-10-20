from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path.cwd(); S=R/'.build/sdk-fc3b01c-terminal'; N=R/'.build/native-fc3b01c-archive-candidate'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def save(p,d):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
assert fact(N/'final-v1.json')==dict(bytes=26131,sha256='c6623dfa0de16ed85bceba676fd09915ca669150e50275015d223d4ca900af34')
native=read(N/'final-v1.json'); paths=[]
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
for row in native['files']:
    p=N/'work'/row['path']; assert fact(p)=={k:row[k] for k in ('bytes','sha256')},row['path']; assert not (R/row['path']).exists()
f=read(S/'factual-review-v1.json'); assert f['workflowRun']==39507170170 and f['testsRerun']==0 and not f['AppSDK']['completeSuiteAcceptance']
A=S/'extracted-12307712232/reader-renewal-probe'; P=S/'extracted-12307082572/reader-renewal-original-api'
producer=read(A/'sdk-produced-public/sdk-produced-fixture-manifest.json'); binding=read(A/'sdk-fixture-binding.json')
assert len(producer['commands'])==48 and len(producer['actualSDKProducedMachOs'])==4
for command in producer['commands']:
    assert command.get('exitCode',command.get('returncode'))==0,command.keys()
for name,row in binding['publicOutputs'].items():
    assert fact(A/'sdk-produced-public'/name)=={k:row[k] for k in ('bytes','sha256')},name
assert len(binding['publicOutputs'])==43
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); cloud=plan['execution']['cloudTriggerPolicy']
assert all(plan[k] is False for k in FLAGS) and {x['runID'] for x in cloud['onlyLiveSDKHandles']}=={39507170170,39507170384}
base=R/'docs/legado-ios/evidence/sdk-fc3b01c-terminal'; recordpath=R/'docs/legado-ios/core-sdk-fc3b01c-terminal-result.json'; assert not base.exists() and not recordpath.exists()
items={name:S/name for name in ['terminal-run.json','terminal-jobs.json','artifact-metadata.json','download-verification.json','extraction-resume-history.json','historical-source-binding.json','partial-native-diagnostics.json','factual-review-v1.json','factual-review-history-v1.json','factual-review.py','factual-review-resume.py','resume-factual-shape.py','download-once.py','resume-extract-longpaths.py','download-resume-derived.py','archive-preflight-history-v1.json']}
for name in ['source-inputs.json','currentcore-pipeline.json','currentcore-completion.json','currentcore-phase-native.json','currentcore-phase-export.json','currentcore-phase-cases.json','currentcore-phase-after-tests.json','currentcore-extraction.json','currentcore-native.log','currentcore-native.log.stderr.log','currentcore-export.log','currentcore-cases.log','sdk-fixture-binding.json','sdk-fixture-before-build.json','overlays.json','currentcore-producer.log','xcode-version.log']:
    if (A/name).exists(): items['native/'+name]=A/name
for p in P.iterdir():
    if p.is_file(): items['package/'+p.name]=p
items['producer/sdk-produced-fixture-manifest.json']=A/'sdk-produced-public/sdk-produced-fixture-manifest.json'
items['scripts/archive-fc3-terminal-outcomes.py']=Path(__file__)
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); text=raw.decode('utf-8-sig'); assert b'\0' not in raw
    assert not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}',raw)
    assert not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw)
    normalized[name]=('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')+'\n').encode() if text else b''
preserved=[]
for row in native['files']:
    dst=R/row['path']; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes((N/'work'/row['path']).read_bytes()); paths.append(dst)
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF and trailing whitespace only; original hashes retained.'))
record=dict(schemaVersion=1,recordedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),sourceCommit=f['sourceCommit'],workflowRun=39507170170,SDKJob=118918888695,status='completed-failure-native-timeout-with-real-runtime-failures',queryAgain=False,
    AppSDK=dict(selectedDefinitions=463,intendedLeaves=466,testTargetCompilationPassed=True,completeSuiteAcceptance=False,firstFailure=dict(phase='native',exitCode=124),processExit=-9,timedOut=True,nativeTimeoutSeconds=3720,nativeElapsedSeconds=3738.600598,summaryBytes=0,testsBytes=0,resultProduced=False,requiredSignerObserved=True,requiredSignerFailed='malformedDER',textualDiagnosticCounts='312 passed lines/21 failed lines/115 issue lines are partial records with restart and unknown-name duplicates; not accepted executed case/leaf totals.'),
    failuresObserved=['Cookie parsed response cannot be represented by native owner','AppSession fixture root names rejected by actual owner','MutualTLS/client service failures and cascading unmet transaction prerequisites','Same-job SDK-produced package signer malformedDER','Recovery fixture optional force unwrap crash and a later event wait that outlived invocation budget'],
    sourceBinding=dict(count=338,allGitBlobBytesMatched=True,proof='evidence/sdk-fc3b01c-terminal/historical-source-binding.json'),
    producer=dict(commandsSucceeded=48,actualSDKMachOs=4,publicOutputFacts=43,allPublicBytesMatched=True,requiredAppSignerPassed=False),
    Package=dict(actualXCTestMethods=24,passed=24,failed=0,skipped=0,sourceInputs=16,controls=7,XMLAndActualVerbosePassedIDsMatch=True,scope='Independent same-source macOS Package API tests only.'),
    preservedEvidence=preserved,proofLimits=f['limits']+['No 463/466 complete App suite result exists. Raw15MB App log and incomplete rawxcresult remain locally archived; canonical diagnostics bind their exact original hashes.','No cloud invocation was repeated during factual review.'],
    claims=dict(SDKPassed=False,AppTestsPassed=False,physicalDeviceValidationPassed=False,selfRenewalVerified=False,unattendedRenewalVerified=False,sourceCompatibilityComplete=False),**{k:False for k in FLAGS})
save(recordpath,record); paths.append(recordpath)
proposal=read(N/'plan-update-proposal.json')
nativeTerminal=next(x['after'] for x in proposal['nativeOnlyOperations'] if x['path'].endswith('latestOriginalNativeTerminal'))
sdkTerminal=dict(sourceCommit=f['sourceCommit'],runID=39507170170,jobID=118918888695,status='completed',conclusion='failure',queryAgain=False,record=recordpath.relative_to(R).as_posix(),failure='actual native runtime failures followed by3720s timeout; empty result exports',AppSuitePassed=False,PackageMethodsPassed=24)
cloud['onlyLiveSDKHandles']=[]; cloud['latestOriginalNativeTerminal']=nativeTerminal; cloud['latestSDKTerminal']=sdkTerminal; cloud['currentCoreLatestTerminal']=sdkTerminal
cloud['currentUnifiedCheckpoint']['nativeTerminal']=nativeTerminal; cloud['currentUnifiedCheckpoint']['sdkTerminal']=sdkTerminal; cloud['currentUnifiedCheckpoint']['actualResultAccepted']=False
cloud['alreadyRunningTasks']='No live build handles. Both immutable fc3 runs are terminal and archived; do not query again. Native passed within its finite scope; SDK App invocation failed and timed out. Actual failures must be repaired before one coherent future checkpoint.'
cloud['nextPlannedCheckpoint']='Repair actual fc3 SDK failures, compose reviewed later S4/C5/S2/WebJS/Base64 changes and exact input rosters, then run one unified SDK/Native checkpoint. No duplicate build or IPA tag during development.'
plan['existingEvidence']['original-native-fc3b01c-terminal']=dict(path='docs/legado-ios/core-native-fc3b01c-terminal-result.json',scope='Actual fc3 source140/Git; native1+26 and JVM349/52XML plus limited configuration/product/cache groups passed. No later source, device or renewal acceptance.')
plan['existingEvidence']['sdk-fc3b01c-terminal']=dict(path=recordpath.relative_to(R).as_posix(),scope='Actual source338 bound; App compiled and executed partially, but runtime failures/crash and timeout mean no suite acceptance. Independent Package24 passed.')
plan.setdefault('activeDevelopmentBatchRecords',[]).extend(['docs/legado-ios/core-native-fc3b01c-terminal-result.json',recordpath.relative_to(R).as_posix()])
for step in plan['execution']['stepByStep']['steps']:
    if step['id'] in ('S3','S4','S5','S6'):
        step.setdefault('implementationEvidence',[]).append(dict(record=recordpath.relative_to(R).as_posix(),scope='Real SDK runtime failures and timeout are now known. Repair typed TLS/signing/fixture prerequisites and rerun a coherent selected suite; no automatic renewal acceptance.'))
save(pp,plan); paths.append(pp)
assert len(paths)==len(set(paths)); save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedCanonicalPaths=len(paths),liveCloudHandles=0,sourceMutations=0,NativeActual='1+26;JVM349',SDKAppSuitePassed=False,PackageActual=24,newTags=0)))
