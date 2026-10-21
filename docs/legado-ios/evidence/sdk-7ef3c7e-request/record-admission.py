from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,subprocess
R=Path('F:/yuedu-reader');S=R/'.build/first-registration-full-application-submission';G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def load(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def put(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
submission=load(S/'submission.json');source=submission['sourceCommit'];assert source=='7ef3c7ec1b0d37ce2b395bb897f6806f5acbafa8'
assert submission['pushExitCode']==0 and submission['sourceInputsBoundToWorkingTreeAndGit']==427
assert subprocess.check_output([G,'rev-parse','HEAD'],cwd=R,text=True).strip()==source
request=R/'docs/legado-ios/core-sdk-7ef3c7e-request.json';assert not request.exists()
handles=[]
for kind,expected_run,expected_job,workflow,tag in [('sdk',39537665728,119017948485,'.github/workflows/reader-renewal-probe.yml','reader-renewal-7ef3c7e'),('native',39537665402,119017948098,'.github/workflows/legado-native-reader-test.yml','legado-native-reader-test-7ef3c7e')]:
 run=load(S/'initial'/f'{kind}-run.json');jobs=load(S/'initial'/f'{kind}-jobs.json')['jobs'];assert len(jobs)==1;job=jobs[0]
 assert run['id']==expected_run and job['id']==expected_job and job['run_id']==expected_run
 assert run['head_sha']==source and run['head_branch']==tag and run['path']==workflow and run['event']=='push'
 assert run['status']==job['status']=='in_progress' and run['conclusion']==job['conclusion']==None
 handles.append({'runID':expected_run,'jobID':expected_job,'sourceCommit':source,'sourceTag':tag,'workflow':workflow,'url':run['html_url'],'initialStatus':'in_progress'})
plan_path=R/'docs/legado-ios/completion-plan.json';plan=load(plan_path);policy=plan['execution']['cloudTriggerPolicy']
assert all(plan[k] is False for k in FLAGS) and policy['onlyLiveSDKHandles']==[] and policy['terminalArchivesPending']==[]
base=R/'docs/legado-ios/evidence/sdk-7ef3c7e-request';paths=[];extras=[]
def archive(src,name):
 b=src.read_bytes();assert b'\0' not in b
 content=('\n'.join(x.rstrip(' \t') for x in b.decode('utf-8-sig').splitlines()).rstrip('\n')+'\n').encode()
 p=base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(content);paths.append(p)
 extras.append({**fact(p),'original':fact(src),'normalization':'Public UTF8/LF text only; original byte facts retained.'})
for src,name in [(S/'submission.json','pre-admission-submission.json'),(S/'tag-push.log','tag-push.log'),(Path(__file__),'record-admission.py'),(R/'.build/submit-first-registration-full-application-pair.py','submit-reviewed-pair.py')]:archive(src,name)
for p in sorted((S/'initial').glob('*.json')):archive(p,'initial/'+p.name)
put(request,{'schemaVersion':1,'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'both-exact-source-runs-confirmed-in-progress-initial-observation','sourceCommit':source,'checkpoint':submission['checkpoint'],'sourceInputsComparedToWorkingTreeAndCommittedGitBytes':427,'tags':submission['tags'],'actualPushedTags':2,'runs':handles,'intendedSelection':submission['intendedSelection'],'actualNewAppExecutedOrAccepted':0,'actualNewNativeExecutedOrAccepted':0,'actualNewPackageMethodsAccepted':0,'actualFullApplicationSigningAccepted':0,'initialRunAdmissionHistory':load(S/'initial/admission-history.json'),'oldTerminalRunQueries':0,'IPARebuiltOrSubmitted':False,'includedProduction':['docs/legado-ios/core-renewal-first-registration-step.json','docs/legado-ios/core-sdk-f481-vault-value-api-repair.json','docs/legado-ios/core-native-f481e89-proxy-fixture-repair.json','docs/legado-ios/core-renewal-full-application-signing-step.json'],'excludedUnfinishedWork':['Exhaustive book-source long-tail compatibility remains deferred at the user temporary90 target; achieved percentage is unmeasured.','No new IPA delivery or hardware/account requests.','Controlled signing and Simulator results do not establish same-device installation authority or unattended renewal.'],'preservedEvidence':extras,'limits':['Initial live run/job observations establish admission only; no App, JNI, full-package signing or Package pass inferred.','SDK currentcore475/478 and Native complete package1/1 are separate required selections. Existing original32 product/platform classification, MainJS and cold hosts retain their independent acceptance.','Job payloads are connector-normalized summaries with step statuses, not full REST jobs.'],**{k:False for k in FLAGS}});paths.append(request)
record=request.relative_to(R).as_posix();policy['onlyLiveSDKHandles']=[{**h,'status':'in_progress'} for h in handles]
policy['latestSubmittedCorePair']={'sourceCommit':source,'record':record,'handles':handles,'actualNewAcceptedTests':0}
policy['currentUnifiedCheckpoint']={'sourceCommit':source,'requestRecord':record,'counts':submission['intendedSelection'],'status':'both-source-runs-confirmed-in-progress','actualResultAccepted':False}
policy['alreadyRunningTasks']='Exactly two new source-bound runs are live at initial observation: SDK39537665728/job119017948485 and Native39537665402/job119017948098. Old f481/f233/88 terminals remain archived and must not be queried again.'
policy['nextPlannedCheckpoint']='Observe these exact SDK/Native handles and classify their actual results before any replacement submission. No duplicate/per-item or IPA tags. Continue only necessary independent source work; book-source long-tail stays deferred.'
steps=plan['execution']['stepByStep'];steps['firstRegistrationFullApplicationSDKRequest']={'record':record,'sourceCommit':source,'status':'both-in-progress-initial-observation','actualNewAcceptedTests':0}
steps['queuedFirstRegistrationFullApplicationCheckpoint'].update({'status':'submitted-as-one-source-bound-SDK-Native-pair','sourceCommit':source,'requestRecord':record})
steps['fullApplicationSigning'].update({'status':'submitted-to-required-same-job-Native-gate-actual-execution-pending','requestRecord':record,'sourceCommit':source})
steps['firstAppleRegistration']['includedInCurrentSourcePair']=source
for step in steps['steps']:step['pendingSDKRequest']=record
plan.setdefault('activeDevelopmentBatchRecords',[]).append(record);put(plan_path,plan);paths.append(plan_path)
put(S/'admission-roster.json',[fact(p) for p in paths])
r=subprocess.run([G,'diff','--check'],cwd=R,stdout=subprocess.PIPE,stderr=subprocess.PIPE);assert r.returncode==0,r.stdout.decode()[:1500]
print(json.dumps({'canonicalPaths':len(paths),'SDK':handles[0]['runID'],'Native':handles[1]['runID'],'bothInitiallyInProgress':True,'actualNewAcceptedTests':0}))
