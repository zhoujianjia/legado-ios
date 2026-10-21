from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,subprocess
R=Path('F:/yuedu-reader');S=R/'.build/s3-full-application-signing-step';G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def load(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(row,p=None):
 f=fact(p or R/row['path']);assert all(f[k]==row[k] for k in ['bytes','sha256']),row['path']
def put(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
fp=S/'final-v2.json';c=load(fp);check({'path':fp.relative_to(R).as_posix(),'bytes':11431,'sha256':'b7f18927b30064716402cfc0ff19882d5ac0e9b54c5c799de77480cce151510e'})
producer_review=R/'.build/s3-full-application-signing-producer-independent-review/review-v1.json';pr=load(producer_review)
swift_review=R/'.build/s3-full-application-signing-swift-independent-review/review-v1.json';sr=load(swift_review)
assert pr['approved'] and pr['failedChecks']==0 and pr['remainingConfirmedSourceBlockers']==[] and pr['final']==fact(fp)
assert sr['approved'] and sr['failedChecks']==0 and sr['unresolvedFindings']==[] and sr['parent']==fact(S/'swift-consumer-final-v1.json')
assert pr['separateSwiftIndependentReview']==fact(swift_review)
for row in c['files']:
 check(row['candidate']);check(row['diff'])
 if row['baseline']:check(row['baseline'],R/row['path'])
 else:assert not (R/row['path']).exists()
for row in c['evidence']:check(row)
check(c['sourceInputs']);inputs=load(R/c['sourceInputs']['path'])['files'];assert len(inputs)==106
for row in inputs:check(row['fact'])
for row in sr['existingAPISourceFacts']+sr['additionalReadSourceFacts']:check(row)
plan_path=R/'docs/legado-ios/completion-plan.json';plan=load(plan_path);assert all(plan[k] is False for k in FLAGS)
assert plan['execution']['stepByStep']['temporaryBookSourceCompatibilityTarget']['temporaryCompatibilityTargetPercent']==90
paths=[]
for row in c['files']:
 p=R/row['path'];p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((R/row['candidate']['path']).read_bytes());check(row['candidate'],p);paths.append(p)
base=R/'docs/legado-ios/evidence/renewal-full-application-signing-step';extras=[]
def archive(src,name):
 b=src.read_bytes();assert b'\0' not in b
 content=('\n'.join(x.rstrip(' \t') for x in b.decode('utf-8-sig').splitlines()).rstrip('\n')+'\n').encode()
 p=base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(content);paths.append(p)
 extras.append({**fact(p),'original':fact(src),'normalization':'Public UTF8/LF; only trailing horizontal whitespace and extra EOF blank lines normalized; original facts retained.'})
archive(fp,'reviewed-candidate.json');archive(producer_review,'producer-independent-review.json');archive(swift_review,'swift-independent-review.json')
archive(S/'source-inputs-v2.json','source-inputs.json')
archive(S/'validation/portable-guards-tool-output.txt','portable-guards.log')
archive(S/'validation/portable-guards-tool-result.json','portable-guards-result.json')
archive(S/'validation/python-source-compile.json','python-source-compile.json')
archive(S/'validation/workflow-source-check.json','workflow-source-check.json')
archive(Path(__file__),'root-integration.py')
record_path=R/'docs/legado-ios/core-renewal-full-application-signing-step.json'
put(record_path,{'schemaVersion':1,'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'source-integrated-independent-reviews-approved-actual-Apple-execution-pending','reviewedCandidate':fact(fp),'canonicalSources':[fact(R/r['path']) for r in c['files']],'sourceInputCount':106,'sourceInputs':fact(base/'source-inputs.json'),'productionPath':c['productionPath'],'newDefinitions':c['newDefinitions'],'actualExecutions':c['actualExecutions'],'independentSourceReviews':[fact(base/'producer-independent-review.json'),fact(base/'swift-independent-review.json')],'preservedBoundaries':c['preservedBoundaries'],'proofLimits':c['proofLimits'],'rootAdditionalSourceReview':['Current controlled producer intentionally uses leaf=root; original profile DeveloperCertificates hash(root) therefore matches its actual codesign identity. Production signer still enforces signer-in-profile.','Actual S3 test is selected only by the same Native job holding the complete package resource; currentcore has no resource fallback or extra selected case.'],'evidence':extras,**{k:False for k in FLAGS}});paths.append(record_path)
steps=plan['execution']['stepByStep'];record=record_path.relative_to(R).as_posix()
steps['fullApplicationSigning']={'record':record,'status':'source-integrated-actual-Apple-build-sign-stream-independent-verify-pending','newMandatorySameJobNativeDefinitions':1,'newMandatorySameJobNativeLeaves':1,'currentcoreSelectionChanged':False,'actualPortablePassed':4,'actualSDKBuild':0,'actualFullPackageSignerExecuted':0}
for step in steps['steps']:
 if step['id']=='S3':
  step.setdefault('implementationEvidence',[]).append({'record':record,'scope':'Real full current-source device build input routed to existing production signing/stream/independent verifier owners in one required same-job case. Local protocol4pass/source review only; Apple actual execution0.'})
  step['nextActionZh']='统一checkpoint实际构建当前iPhoneOS/JVM完整应用，运行同job必需1项完整包重签、流式输出和独立验签；遇到真实签名布局或编译失败按事实修复，不能以源码独审或4项便携检查认定跑通。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(record)
plan['execution']['cloudTriggerPolicy']['nextPlannedCheckpoint']='Full-application S3 source is integrated. Finish derived first-registration/S3 source and selection controls, independently review, then submit one coherent SDK/Native pair. No IPA or per-item tags; temporary90 book-source target remains unmeasured and long-tail deferred.'
put(plan_path,plan);paths.append(plan_path)
assert len(paths)==len(set(paths));put(S/'canonical-roster.json',[fact(p) for p in paths])
r=subprocess.run([G,'diff','--check'],cwd=R,stdout=subprocess.PIPE,stderr=subprocess.PIPE);assert r.returncode==0,r.stdout.decode()[:1500]
print(json.dumps({'canonicalPaths':len(paths),'sourcePaths':6,'actualPortablePassed':4,'actualAppleBuildAndSignerExecuted':0,'currentcoreUnchanged':True}))
