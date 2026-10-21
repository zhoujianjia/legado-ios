from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,subprocess
R=Path('F:/yuedu-reader');S=R/'.build/consolidated-sdk-first-registration-full-application-checkpoint';G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def load(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(row,p=None):
 f=fact(p or R/row['path']);assert all(f[k]==row[k] for k in ['bytes','sha256']),row['path']
def put(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
args=argparse.ArgumentParser();args.add_argument('--review',required=True);a=args.parse_args();rp=R/a.review;review=load(rp)
fp=S/'final-v2.json';c=load(fp)
assert review['approved'] is True and review['failedChecks']==0 and review['unresolvedFindings']==[]
assert review['parent']==fact(fp)
assert c['reviewedControlRows']==7 and c['changedControls']==6
for row in c['files']:check(row['candidate']);check(row['baseline'],R/row['path']);check(row['diff'])
for row in c['parents'].values():check(row)
for row in c['evidence']:check(row)
check(c['sourceClosures']);check(c['packageSourceInputs']);closures=load(R/c['sourceClosures']['path'])
controls={r['path']:r for r in c['files']};assert len(closures['union'])==427
by_path={r['path']:r for r in closures['union']}
for row in c['productionSourceBindings']:assert row==by_path[row['path']],row['path']
for row in closures['union']:check(row,R/controls[row['path']]['candidate']['path'] if row['path'] in controls else R/row['path'])
plan_path=R/'docs/legado-ios/completion-plan.json';plan=load(plan_path);assert all(plan[k] is False for k in FLAGS)
assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[] and plan['execution']['cloudTriggerPolicy']['terminalArchivesPending']==[]
assert plan['execution']['stepByStep']['temporaryBookSourceCompatibilityTarget']['temporaryCompatibilityTargetPercent']==90
paths=[]
for row in c['files']:
 if not row['changed']:assert (R/row['path']).read_bytes()==(R/row['candidate']['path']).read_bytes();continue
 p=R/row['path'];p.write_bytes((R/row['candidate']['path']).read_bytes());check(row['candidate'],p);paths.append(p)
assert len(paths)==6
for row in closures['union']:check(row)
base=R/'docs/legado-ios/evidence/sdk-first-registration-full-application-checkpoint';extras=[]
def archive(src,name):
 b=src.read_bytes();assert b'\0' not in b
 normalized=('\n'.join(x.rstrip(' \t') for x in b.decode('utf-8-sig').splitlines()).rstrip('\n')+'\n').encode()
 p=base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(normalized);paths.append(p)
 extras.append({**fact(p),'original':fact(src),'normalization':'UTF8/LF and trailing whitespace only; original byte facts retained.'})
for src,name in [(fp,'reviewed-candidate.json'),(rp,'independent-review.json'),(R/c['sourceClosures']['path'],'source-closures.json'),(R/c['packageSourceInputs']['path'],'package-source-inputs.json'),(S/'affected-validation-v1.json','actual-portable-validation.json'),(S/'affected-core-v1.log','actual-core-guards.log'),(S/'affected-native-v1.log','actual-native-guards.log'),(S/'preparation-history-v1.json','preparation-history.json'),(Path(__file__),'root-integration.py')]:archive(src,name)
counts=dict(c['countsForNextCheckpoint']);counts['fullApplicationDefinitions']=counts['S3Definitions'];counts['fullApplicationLeaves']=counts['S3Leaves']
record_path=R/'docs/legado-ios/core-sdk-first-registration-full-application-checkpoint.json';record=record_path.relative_to(R).as_posix()
put(record_path,{'schemaVersion':1,'recordedUTC':datetime.now(timezone.utc).isoformat(),'status':'reviewed-source-bound-ready-for-one-coherent-SDK-Native-checkpoint','independentSourceReviewApproved':True,'independentReview':fact(base/'independent-review.json'),'sourceCounts':counts,'sourceByteBinding':c['byteBinding'],'canonicalControlSources':[fact(R/r['path']) for r in c['files']],'actualChangedControlPaths':c['changedControlPaths'],'sourceClosures':fact(base/'source-closures.json'),'productionParents':c['parents'],'selectorsAdded':c['selectorsAdded'],'preservedControls':c['preservedControls'],'fullApplicationRequiredGate':c['fullApplicationRequiredGate'],'actualPortableValidation':c['actualPortableValidation'],'actualNewSDKTests':0,'actualNewNativeTests':0,'actualFullApplicationSigningTests':0,'sourceAuthoredFirstRegistrationTests':4,'firstRegistrationIncluded':True,'fullApplicationSigningIncluded':True,'resourceProductionActivated':False,'longTailBookSourceWorkDeferred':True,'compatibilityTargetPercent':90,'measuredCompatibilityPercent':None,'scopeLimits':c['scopeLimits'],'evidence':extras,**{k:False for k in FLAGS}});paths.append(record_path)
steps=plan['execution']['stepByStep'];steps['queuedFirstRegistrationFullApplicationCheckpoint']={'record':record,'status':'reviewed-and-source-bound-ready-for-one-unified-submission','counts':counts,'actualNewSDKTests':0,'actualNewNativeTests':0,'actualFullApplicationSigningTests':0}
for step in steps['steps']:
 step.setdefault('implementationEvidence',[]).append({'record':record,'scope':'Reviewed coherent source checkpoint: first registration4 definitions, exact DER API fix, stale proxy test repair and required complete package1/1 gate. Actual affected portable5 passed; Apple SDK/JNI/full signing not yet executed.'})
 if step['id'] in ['S1','S2','S3','S4','S5','S6']:
  step['nextActionZh']='提交同一源码的集中SDK/模拟器验证，实际执行已选续签、认证安装、事务恢复和触发回归；完整应用包重签另以同job必需1项验签。不以便携检查或源码审查代替真实执行。'
first=steps.get('firstAppleRegistration',{})
if 'notIncludedInRunningSourcePair' in first:first['notIncludedInPriorSourcePair']=first.pop('notIncludedInRunningSourcePair')
policy=plan['execution']['cloudTriggerPolicy'];policy['nextPlannedCheckpoint']='Reviewed first-registration/full-application checkpoint is source-bound and ready for one SDK/Native pair. No IPA or per-item tags; user temporary90 target remains unmeasured and exhaustive book-source long-tail deferred.'
policy['alreadyRunningTasks']='No live SDK/Native jobs. Both f481 terminal failures fully archived. The reviewed coherent successor is ready to commit and submit once.'
plan['简体中文执行说明']['当前状态']='当前优先自签和核心阅读，书源兼容按90%阶段目标推进，实际兼容率尚未测定，长尾功能暂缓。首次登记、证书复用修复和完整iPhoneOS/JVM包重签验签链路已合入，集中SDK/模拟器验证尚未执行；真实自动续签仍未跑通。其他17项保持未完成、暂缓。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(record);put(plan_path,plan);paths.append(plan_path)
assert len(paths)==len(set(paths));put(S/'canonical-roster.json',[fact(p) for p in paths])
r=subprocess.run([G,'diff','--check'],cwd=R,stdout=subprocess.PIPE,stderr=subprocess.PIPE);assert r.returncode==0,r.stdout.decode()[:1500]
print(json.dumps({'canonicalPaths':len(paths),'actualChangedControls':6,'reviewedControls':7,'sourceCounts':counts,'actualPortablePassed':5,'actualNewSDK':0}))
