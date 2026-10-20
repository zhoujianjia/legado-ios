from pathlib import Path
import datetime,hashlib,json,subprocess
R=Path('F:/yuedu-reader');G='D:/app/Git/cmd/git.exe';S=R/'.build/consolidated-sdk-header-v2-browser-checkpoint'
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return{'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def write(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
submission=read(S/'submission-v1.json');source=submission['sourceCommit'];observed=read(S/'initial-cloud-observation.json')
assert subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip()==source
assert all(x=='?? debug.log'for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
assert len(observed['runs'])==2 and {x['tag']for x in observed['runs']}==set(submission['tags'])
handles=[]
for run in observed['runs']:
 assert run['sourceCommit']==source and len(run['jobs'])==1 and run['conclusion']is None
 job=run['jobs'][0];assert job['conclusion']is None
 handles.append({'workflow':run['name'],'runID':run['runID'],'jobID':job['jobID'],'tag':run['tag'],'sourceCommit':source,'statusAtObservation':job['status'],'url':run['url']})
recordpath=R/('docs/legado-ios/core-sdk-'+source[:7]+'-request.json');base=R/('docs/legado-ios/evidence/sdk-'+source[:7]+'-request');assert not recordpath.exists()and not base.exists()
preserved=[]
for src,name in [(S/'submission-v1.json','submission.json'),(S/'initial-cloud-observation.json','initial-cloud-observation.json'),(R/'.build/submit-reviewed-header-v2-browser-checkpoint.py','submit-source.py'),(R/'.build/record-header-v2-browser-checkpoint-submission.py','record-submission.py')]:
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);text=src.read_text(encoding='utf-8-sig');dst.write_bytes(('\n'.join(x.rstrip(' \t')for x in text.splitlines()).rstrip('\n')+'\n').encode());preserved.append({'path':dst.relative_to(R).as_posix(),**fact(dst),'original':{'path':src.relative_to(R).as_posix(),**fact(src)}})
record={'schemaVersion':1,'recordedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'actual-unified-Header-V2-browser-and-both7576-failure-repairs-submitted-no-terminal-acceptance','sourceCommit':source,'sourceCheckpoint':'docs/legado-ios/core-original-source-header-v2-browser-step.json','observedUTC':observed['observedUTC'],'handles':handles,'counts':submission['counts'],'POSTHeaderV2BrowserIncluded':True,'bothActual7576FailureRepairsIncluded':True,'newIPATag':False,'noOldTerminalJobsRepolled':True,'actualResultAccepted':False,'preservedEvidence':preserved,'limits':'Workflow admission only. Actual compiler/App signer, JNI/UIKit and renewal acceptance remain pending. Historical failed7576 results stay immutable; unchanged Package24 may be reused only for its exact23 source/control bytes.'}
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);cloud=plan['execution']['cloudTriggerPolicy'];assert cloud['onlyLiveSDKHandles']==[]
cloud['onlyLiveSDKHandles']=handles;cloud['currentUnifiedCheckpoint']={'sourceCommit':source,'requestRecord':recordpath.relative_to(R).as_posix(),'observedUTC':observed['observedUTC'],'counts':submission['counts'],'actualResultAccepted':False}
cloud['alreadyRunningTasks']='Exactly the'+source[:7]+' SDK/Native pair below; no IPA/device tag. Both7576 and earlier jobs are terminal/archived and must never be polled again.'
cloud['nextPlannedCheckpoint']='Preserve actual terminal logs/artifacts only for these two new handles. Repair actual failures before a next pair. Continue C5 independent-process implementation without changing this immutable running source. Do not restart for elapsed time or repeat unchanged passing suites.'
plan['execution']['stepByStep']['queuedHeaderV2BrowserNextCheckpoint']['submittedRequest']=recordpath.relative_to(R).as_posix()
for k in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']:assert plan[k]is False
write(recordpath,record);write(pp,plan);paths=[recordpath,pp]+[R/x['path']for x in preserved];write(S/'submission-canonical-roster.json',[{'path':p.relative_to(R).as_posix(),**fact(p)}for p in paths]);print(json.dumps({'reviewedPaths':len(paths),'handles':handles,'newIPATag':False}))
