"""Submit one exact reviewed SDK/Native source checkpoint, never an IPA tag."""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,subprocess
R=Path('F:/yuedu-reader');G='D:/app/Git/cmd/git.exe'
def git(*args):return subprocess.check_output([G,*args],cwd=R)
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def put(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
p=argparse.ArgumentParser();p.add_argument('--record',required=True);p.add_argument('--closures',required=True);a=p.parse_args()
record_path=(R/a.record).resolve();closure_path=(R/a.closures).resolve()
assert record_path.is_relative_to(R/'docs/legado-ios') and closure_path.is_relative_to(R/'docs/legado-ios')
record=json.loads(record_path.read_bytes());closures=json.loads(closure_path.read_bytes())
S=R/'.build/first-registration-full-application-submission'
assert not (S/'submission.json').exists(),'Recorded submission exists: resume its exact handles, never recreate tags.'
assert all(line=='?? debug.log' for line in git('status','--porcelain').decode().splitlines())
assert record['independentSourceReviewApproved'] is True
counts=record['sourceCounts']
assert counts['currentcoreDefinitions']==475 and counts['currentcoreLeaves']==478
assert counts['originalMethods']==32 and counts['originalProduct']==29 and counts['platformCharacterization']==3
assert counts['PackageDefinitions']==24 and counts['PackageInputs']==23
assert counts['fullApplicationDefinitions']==counts['fullApplicationLeaves']==1
assert record['resourceProductionActivated'] is False and record['firstRegistrationIncluded'] is True
assert record['fullApplicationSigningIncluded'] is True
rows=closures['union'];assert len(rows)==counts['union'] and len({x['path'] for x in rows})==len(rows)
source=git('rev-parse','HEAD').decode().strip();assert len(source)==40
paths=sorted(x['path'] for x in rows);by_path={x['path']:x for x in rows}
batch=subprocess.run([G,'cat-file','--batch'],cwd=R,input=''.join(source+':'+x+'\n' for x in paths).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
offset=0
for path in paths:
 row=by_path[path];raw=(R/path).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],path
 e=batch.index(b'\n',offset);_,kind,size=batch[offset:e].split();size=int(size)
 assert kind==b'blob' and size==len(raw) and batch[e+1:e+1+size]==raw,path
 offset=e+size+2
assert offset==len(batch)
policy=json.loads((R/'docs/legado-ios/completion-plan.json').read_bytes())['execution']['cloudTriggerPolicy']
assert policy['onlyLiveSDKHandles']==[] and policy['terminalArchivesPending']==[]
assert policy['latestClosedCorePair']['sourceCommit']=='f481e89717b96df1d15d5c3f9a72c359d1fcef55'
tags=['reader-renewal-'+source[:7],'legado-native-reader-test-'+source[:7]]
assert git('tag','--list',*tags).strip()==b''
assert git('ls-remote','--tags','origin',*['refs/tags/'+t for t in tags]).strip()==b''
submission={'schemaVersion':1,'phase':'reviewed-no-tags-created-yet','preparedUTC':datetime.now(timezone.utc).isoformat(),'sourceCommit':source,'tags':tags,'checkpoint':fact(record_path),'sourceClosure':fact(closure_path),'sourceInputsBoundToWorkingTreeAndGit':len(rows),'intendedSelection':counts,'exactTargetTagsPreviouslyAbsent':True,'latestClosedPair':policy['latestClosedCorePair'],'actualNewSDKTests':0,'actualNewNativeTests':0,'actualFullApplicationSignerExecuted':0,'actualNewCloudRunsObserved':0,'IPARebuiltOrTagSubmitted':False,'automaticSelfRenewalImplemented':False,'fullLegadoCompatibilityEstablished':False}
put(S/'submission.json',submission)
for tag in tags:subprocess.run([G,'tag',tag,source],cwd=R,check=True)
submission['phase']='two-local-tags-created-push-pending';put(S/'submission.json',submission)
push=subprocess.run([G,'push','--atomic','origin',*['refs/tags/'+t+':refs/tags/'+t for t in tags]],cwd=R,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(S/'tag-push.log').write_bytes(push.stdout);submission['pushExitCode']=push.returncode;submission['pushLog']=fact(S/'tag-push.log')
if push.returncode==0:submission.update(phase='both-source-bound-tags-pushed-awaiting-initial-run-admission',pushedUTC=datetime.now(timezone.utc).isoformat())
put(S/'submission.json',submission)
assert push.returncode==0,'Push failed: use recorded phase rather than recreate tags.'
print(json.dumps({'sourceCommit':source,'tags':tags,'sourceInputs':len(rows),'pushExitCode':push.returncode,'actualNewCloudRunsObserved':0,'newIPA':False}))
