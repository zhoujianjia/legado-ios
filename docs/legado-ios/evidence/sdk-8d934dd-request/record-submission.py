from pathlib import Path
import hashlib,json,subprocess
ROOT=Path('F:/yuedu-reader');STAGE=ROOT/'.build/consolidated-sdk-v2-native-repair-checkpoint';GIT='D:/app/Git/cmd/git.exe'
SOURCE='8d934dd5311f73cddd5a88e3085f06fa15fc0ae1'
def read(p):return json.loads(p.read_bytes())
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
def facts(p):
    raw=p.read_bytes();return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
assert subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip()==SOURCE
observed=read(STAGE/'initial-cloud-observation.json');submission=read(STAGE/'submission-v1.json')
assert submission['sourceCommit']==SOURCE and len(observed['runs'])==2
handles=[]
for run in observed['runs']:
    assert run['sourceCommit']==SOURCE and len(run['jobs'])==1 and run['conclusion'] is None
    job=run['jobs'][0];assert job['conclusion'] is None
    handles.append({'workflow':run['name'],'runID':run['runID'],'jobID':job['jobID'],'tag':run['tag'],'sourceCommit':SOURCE,'statusAtObservation':job['status'],'url':run['url']})
assert {h['runID'] for h in handles}=={39495414820,39495414773}
path=ROOT/'docs/legado-ios/core-sdk-8d934dd-request.json';assert not path.exists()
base=ROOT/'docs/legado-ios/evidence/sdk-8d934dd-request';assert not base.exists()
preserved=[]
for src,name in [(STAGE/'submission-v1.json','submission.json'),(STAGE/'initial-cloud-observation.json','initial-cloud-observation.json'),(ROOT/'.build/submit-final-v2-native-reader-checkpoint.py','submit-source.py'),(ROOT/'.build/record-8d934dd-checkpoint-submission.py','record-submission.py')]:
    dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);raw=src.read_bytes();normalized='\n'.join(x.rstrip(' \t') for x in raw.decode('utf-8-sig').splitlines()).rstrip('\n')+'\n';dst.write_bytes(normalized.encode());preserved.append({'path':dst.relative_to(ROOT).as_posix(),**facts(dst),'original':{'path':src.relative_to(ROOT).as_posix(),**facts(src)}})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'actual-new-tag-pair-submitted-running-or-queued-no-terminal-acceptance','sourceCommit':SOURCE,'sourceCheckpoint':'docs/legado-ios/core-native-reader-v2-sdk-checkpoint.json','observedUTC':observed['observedUTC'],'handles':handles,'counts':submission['counts'],'browserIncluded':False,'newIPATag':False,'noOldTerminalJobsRepolled':True,'actualResultAccepted':False,'preservedEvidence':preserved,'limits':'Workflow admission and running/queued jobs do not establish compiler,JVM,JNI,Package,App signer,Apple/device installation or renewal success.'}
plan_path=ROOT/'docs/legado-ios/completion-plan.json';plan=read(plan_path);cloud=plan['execution']['cloudTriggerPolicy'];assert cloud['onlyLiveSDKHandles']==[]
cloud['onlyLiveSDKHandles']=handles
cloud['currentUnifiedCheckpoint']={'sourceCommit':SOURCE,'requestRecord':path.relative_to(ROOT).as_posix(),'observedUTC':observed['observedUTC'],'counts':submission['counts'],'actualResultAccepted':False}
cloud['nextPlannedCheckpoint']='Only these two new8d934dd handles are live. Preserve their actual terminal logs/artifacts and fix concrete failures before any next pair; never repoll archived210 jobs or restart for elapsed observation. Browser first slice and subsequent Await development remain independent and must not change the immutable running source. No device/IPA tag.'
plan['execution']['stepByStep']['queuedReadyProductionForNextUnifiedCheckpoint']['submittedRequest']=path.relative_to(ROOT).as_posix()
for key in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']:assert plan[key] is False
write(path,record);write(plan_path,plan)
paths=[path,plan_path]+[base/name for name in ['submission.json','initial-cloud-observation.json','submit-source.py','record-submission.py']]
write(STAGE/'submission-canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**facts(p)} for p in paths])
subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'handles':handles,'reviewedPaths':len(paths),'newIPATag':False}))
