from pathlib import Path
import hashlib,json,subprocess
R=Path('F:/yuedu-reader');S=R/'.build/consolidated-sdk-browser-await-two-repairs-checkpoint';G='D:/app/Git/cmd/git.exe';SOURCE='7576cbf91fa7448eff4160f1bf040159d3cd6a23'
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
assert subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip()==SOURCE
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
observed=read(S/'initial-cloud-observation.json');submission=read(S/'submission-v1.json');assert submission['sourceCommit']==SOURCE and len(observed['runs'])==2
handles=[]
for run in observed['runs']:
 assert run['sourceCommit']==SOURCE and len(run['jobs'])==1 and run['conclusion'] is None
 job=run['jobs'][0];assert job['conclusion'] is None
 handles.append({'workflow':run['name'],'runID':run['runID'],'jobID':job['jobID'],'tag':run['tag'],'sourceCommit':SOURCE,'statusAtObservation':job['status'],'url':run['url']})
assert {x['runID'] for x in handles}=={39501414740,39501416076}
p=R/'docs/legado-ios/core-sdk-7576cbf-request.json';base=R/'docs/legado-ios/evidence/sdk-7576cbf-request';assert not p.exists() and not base.exists()
preserved=[]
for src,name in [(S/'submission-v1.json','submission.json'),(S/'initial-cloud-observation.json','initial-cloud-observation.json'),(R/'.build/submit-reviewed-await-two-repairs-checkpoint.py','submit-source.py'),(R/'.build/record-await-two-repairs-checkpoint-submission.py','record-submission.py')]:
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);text=src.read_text(encoding='utf-8-sig');dst.write_bytes(('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')+'\n').encode());preserved.append({'path':dst.relative_to(R).as_posix(),**fact(dst),'original':{'path':src.relative_to(R).as_posix(),**fact(src)}})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'actual-unified-Await-and-both-compiler-repair-pair-submitted-no-terminal-acceptance','sourceCommit':SOURCE,'sourceCheckpoint':'docs/legado-ios/core-original-source-browser-await-step.json','observedUTC':observed['observedUTC'],'handles':handles,'counts':submission['counts'],'GETAwaitIncluded':True,'POSTIncluded':False,'bothActual8dCompilerRepairsIncluded':True,'newIPATag':False,'noOldTerminalJobsRepolled':True,'actualResultAccepted':False,'preservedEvidence':preserved,'limits':'Running jobs establish workflow admission only. Actual compiler/App signer, JNI/UIKit and renewal acceptance remain pending; historical8d results stay unchanged.'}
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);cloud=plan['execution']['cloudTriggerPolicy'];assert cloud['onlyLiveSDKHandles']==[]
cloud['onlyLiveSDKHandles']=handles;cloud['currentUnifiedCheckpoint']={'sourceCommit':SOURCE,'requestRecord':p.relative_to(R).as_posix(),'observedUTC':observed['observedUTC'],'counts':submission['counts'],'actualResultAccepted':False}
cloud['alreadyRunningTasks']='Exactly the7576cbf SDK/Native pair below; no IPA/device tag. Earlier8d and all older jobs are terminal/archived and must never be polled again.'
cloud['nextPlannedCheckpoint']='Preserve actual terminal logs/artifacts for only these two7576cbf handles; fix real failures before any next pair. Continue independently reviewed POST development without changing this immutable running source. Do not restart for elapsed time or repeat unchanged passing suites.'
plan['execution']['stepByStep']['queuedAwaitCompilerRepairNextCheckpoint']['submittedRequest']=p.relative_to(R).as_posix()
for k in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']:assert plan[k] is False
write(p,record);write(pp,plan)
paths=[p,pp]+[R/x['path'] for x in preserved];write(S/'submission-canonical-roster.json',[{'path':x.relative_to(R).as_posix(),**fact(x)} for x in paths]);subprocess.run([G,'diff','--check'],cwd=R,check=True);print(json.dumps({'reviewedPaths':len(paths),'handles':handles,'newIPATag':False}))
