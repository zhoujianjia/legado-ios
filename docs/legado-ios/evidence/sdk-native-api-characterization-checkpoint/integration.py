from pathlib import Path
import datetime, hashlib, json, re, subprocess, sys

R=Path.cwd(); G='D:/app/Git/cmd/git.exe'
S=R/'.build/sdk-native-api-coherent-checkpoint-composition'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def check(p,x): assert fact(p)=={k:x[k] for k in ('bytes','sha256')},str(p)
def save(p,x):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
f=read(S/'final-v1.json'); V=Path(sys.argv[1]).resolve(); v=read(V)
check(V,dict(bytes=5372,sha256='ac37ad3c65571ebea9dee6ff03e7b451093bdf7072086664c66a5c01b81e8a68'))
check(S/'final-v1.json',dict(bytes=15599,sha256='2e0d6a792052278b600d54fcb732202409efa0e7fbfb0312ad157423a2bd1b4b'))
check(S/'final-v1.json',v['parent'])
assert v['approved'] is True and v['failedChecks']==0 and v['unresolvedFindings']==[]
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
for x in ['parent','parentIndependentReview','sourceRosters','integratedChangedSources','PackageSourceRoster','relatedResearch','currentPrerequisites']:
    check(R/f[x]['path'],f[x])
parent=read(R/f['parent']['path'])
assert len(f['files'])==5 and f['counts']['core']==349 and f['counts']['native']==161 and f['counts']['uniqueUnion']==365
assert f['actualPortableGuards']['newExecutions']==0 and f['actualPortableGuards']['passed']==4
assert all(x==0 for x in f['actual'].values())
for row in f['files']:
    check(R/row['path'],row['baseline']); check(R/f['candidateRoot']/row['path'],row['candidate'])
union=read(R/f['sourceRosters']['path']); assert len(union['files'])==365
controls={x['path'] for x in f['files']}
for row in union['files']:
    check((R/f['candidateRoot']/row['path']) if row['path'] in controls else R/row['path'],row)
changed=read(R/f['integratedChangedSources']['path']); assert len(changed)==8
for row in changed: check(R/row['path'],row)
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); cloud=plan['execution']['cloudTriggerPolicy']
assert all(plan[x] is False for x in FLAGS) and cloud['onlyLiveSDKHandles']==[]
for key,run,job in [('latestSDKTerminal',39520239925,118962037971),('latestOriginalNativeTerminal',39520240533,118962039359)]:
    t=cloud[key]; assert t['runID']==run and t['jobID']==job and t['status']=='completed' and t['conclusion']=='failure' and t['queryAgain'] is False
    assert (R/t['record']).is_file()
assert cloud['latestSDKTerminal']['AppDefinitionsExecuted']==0
base=R/'docs/legado-ios/evidence/sdk-native-api-characterization-checkpoint'
rp=R/'docs/legado-ios/core-sdk-native-api-characterization-checkpoint.json'
assert not base.exists() and not rp.exists()
items={'composition.json':S/'final-v1.json','independent-review.json':V,'integration.py':Path(__file__)}
for key in ['parent','parentIndependentReview','sourceRosters','integratedChangedSources','PackageSourceRoster','relatedResearch','currentPrerequisites']:
    x=f[key]; items[key+'/'+Path(x['path']).name]=R/x['path']
for x in parent['evidence']:
    p=R/x['path']; check(p,x); items['inherited-portable/'+p.name]=p
for row in f['files']:
    x=row['diff']; p=R/x['path']; check(p,x); items['diffs/'+row['path']+'.patch']=p
normalized={}
for name,p in items.items():
    b=p.read_bytes(); assert b'\0' not in b and not re.search(rb'[?&]X-Amz-Signature=',b)
    text=b.decode('utf-8-sig'); normalized[name]=('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')+'\n').encode()
paths=[]; preserved=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF/trailing whitespace only'))
for row in f['files']:
    dst=R/row['path']; dst.write_bytes((R/f['candidateRoot']/row['path']).read_bytes()); paths.append(dst)
for row in union['files']: check(R/row['path'],row)
counts=dict(AppDefinitions=463,AppLeaves=466,BoolParameterPairs=3,coreInputs=349,nativeInputs=161,uniqueInputUnion=365,unchangedCanonicalNoncandidateInputs=360,NativeOriginalDefinitions=30,NativeProductDefinitions=28,NativePlatformCharacterizations=2,NativeLoginInfoDefinitions=16,NativeMainJSDefinitions=1,NativeIndependentColdHosts=2,PackageMethods=24,PackageCompilationInputs=16,PackageControls=7,PackageAllInputs=23)
canonicalUnion=next(x for x in preserved if x['path'].endswith('/sourceRosters/source-rosters-v1.json'))
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='reviewed-coherent-API-repair-JVM-fixtures-and-platform-characterization-controls-integrated-actual-new-SDK-pending',sourceFiles=f['files'],changedControls=5,integratedChangedSources=changed,countsForNextCheckpoint=counts,sourceReviewFindings=[],sourceRoster=canonicalUnion,sourceComposition=f['sourceComposition'],selectorComposition=f['selectorComposition'],invariants=f['invariants'],actualPortableValidation=f['actualPortableGuards'],preservedEvidence=preserved,actualNewSDK_JNI_WK=0,actualResultAccepted=False,priorSDK88Terminal=cloud['latestSDKTerminal'],priorNative88Terminal=cloud['latestOriginalNativeTerminal'],historicalPreparationPendingArchiveNowSatisfied=True,proofLimits=f['proofLimits'],newCloudTags=0,newIPATag=False,**{x:False for x in FLAGS})
save(rp,record); paths.append(rp)
steps=plan['execution']['stepByStep']
steps['queuedAPICharacterizationCheckpoint']=dict(record=rp.relative_to(R).as_posix(),**counts,actualAcceptancePending=True,priorPairTerminalAndArchived=True)
for key in ['queuedGeneralWebJSRuntimeRepairsNextCheckpoint','SDK88HeadlessAPIRepair','publicWebRequestCharacterization']:
    if key in steps: steps[key]['nextUnifiedCheckpoint']=rp.relative_to(R).as_posix()
for step in steps['steps']:
    if step['id'] in ['C3','C4','C5']:
        step.setdefault('implementationEvidence',[]).append(dict(record=rp.relative_to(R).as_posix(),scope='Both88 failures archived; two SDK API tokens and five JVM expectations repaired. Exact349/161/365 controls retain28 product cases plus2 explicit WK platform characterizations. Actual new SDK/JNI/WK and cold hosts pending.'))
        step['nextActionZh']='已修复88轮的两处SDK API编译错误及5项JVM旧预期；下一份统一源码为core349、Native161、去重365。只启动同一源码的一组SDK/Native，App463定义466叶、Native28产品加2平台验证、MainJS1及两个独立冷宿主；实际结果仍待取得，平台验证不等于生产书源兼容完成。'
cloud['nextPlannedCheckpoint']='Submit exactly one coherent349/161/365 SDK and Native pair after reviewed control integration. Both88 terminal failures are archived and must never be queried again. No IPA tag.'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(rp.relative_to(R).as_posix())
save(pp,plan); paths.append(pp)
save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
ignored=subprocess.run([G,'check-ignore','--stdin'],cwd=R,input=''.join(p.relative_to(R).as_posix()+'\n' for p in paths).encode(),capture_output=True)
assert ignored.returncode==1 and not ignored.stdout
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),changedControls=5,counts=counts,newTestsExecuted=0,newTags=0)))
