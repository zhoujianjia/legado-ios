from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,subprocess

R=Path('F:/yuedu-reader'); S=R/'.build/sdk-f481e89-archive-candidate'
G='D:/app/Git/cmd/git.exe'; FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def load(p):return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
c=load(S/'final-v1.json'); rp=R/'.build/sdk-f481e89-archive-root-review/review-v1.json'; review=load(rp)
assert review['status']=='approved' and review['failedChecks']==0 and review['remainingConfirmedSourceBlockers']==[] and review['candidateFinal']==fact(S/'final-v1.json')
assert c['candidateFiles']==107 and c['sourceCommit']=='f481e89717b96df1d15d5c3f9a72c359d1fcef55'
for row in c['files']:
    p=R/c['candidateRoot']/row['path']; f=fact(p)
    assert all(f[k]==row[k] for k in ['bytes','sha256']) and not (R/row['path']).exists(),row['path']
plan_path=R/'docs/legado-ios/completion-plan.json'; plan=load(plan_path); policy=plan['execution']['cloudTriggerPolicy']
assert all(plan[k] is False for k in FLAGS) and not policy['onlyLiveSDKHandles']
assert [h['runID'] for h in policy['terminalArchivesPending']]==[39533277187]
target=plan['execution']['stepByStep']['temporaryBookSourceCompatibilityTarget']
assert target['temporaryCompatibilityTargetPercent']==90 and target['measuredCompatibilityPercent'] is None
paths=[]
for row in c['files']:
    dest=R/row['path'];dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes((R/c['candidateRoot']/row['path']).read_bytes());paths.append(dest)
base=R/'docs/legado-ios/evidence/sdk-f481e89-terminal'; extras=[]
for name,src in [('reviewed-candidate.json',S/'final-v1.json'),('root-independent-review.json',rp),('root-review.py',R/'.build/review-sdk-f481-archive-root.py'),('root-integration.py',Path(__file__))]:
    dest=base/name;dest.write_bytes(src.read_bytes().replace(b'\r\n',b'\n'));paths.append(dest);extras.append({**fact(dest),'original':fact(src),'normalization':'UTF8/LF only; original byte facts retained.'})
record_path=R/c['record']; record=load(record_path)
record['AppSDK']['rawXcresultPresent']=True
record['AppSDK']['resultProducedMeaning']='Original controller accepted-result field; raw xcresult exists, exported test tree is empty and no App test ran.'
record['separateCompilerRepair']={'record':'docs/legado-ios/core-sdk-f481-vault-value-api-repair.json','commit':'8680edc','actualPostFixSDKRuns':0,'historicalFailureUnchanged':True}
record['rootAdditionalEvidence']=extras
write(record_path,record)
sdk={'sourceCommit':c['sourceCommit'],'runID':39533277187,'jobID':119003957104,'status':'completed','conclusion':'failure','queryAgain':False,'record':c['record'],'failure':'One production Swift Value.full API-shape compiler error; App0. Exact originalDER source fix is separate and awaits SDK.','AppDefinitionsExecuted':0,'AppLeavesExecuted':0,'AppSuitePassed':False,'uniqueCompilerErrors':1,'PackageMethodsPassed':24,'producerCommandsPassed':48,'producerPublicOutputs':43,'producerMachOs':4,'separateSourceRepairRecord':'docs/legado-ios/core-sdk-f481-vault-value-api-repair.json'}
native=dict(policy['latestNativeTerminal']);native.update({'jobID':119003957102,'status':'completed','JVMMethodsPassed':377,'JVMMethodsFailed':1,'NativeMethodsExecuted':0})
policy['terminalArchivesPending']=[]
policy['latestSDKTerminal']=sdk; policy['currentCoreLatestTerminal']=dict(sdk)
policy['latestOriginalNativeTerminal']=dict(native)
policy['alreadyRunningTasks']='No live SDK/Native jobs. Both f481 failures are fully archived and must not be queried again. S3 full-application signing source/controller review continues locally before one coherent checkpoint.'
policy['nextPlannedCheckpoint']='Combine first registration, exact Vault DER API repair, stale proxy expectation repair and reviewed full-application S3 signing wiring in one necessary SDK/Native checkpoint. No per-change or IPA tags. Book-source exhaustive long-tail compatibility remains deferred at the user temporary90 target; achieved percentage is unmeasured.'
policy['latestClosedCorePair']={'sourceCommit':c['sourceCommit'],'recordedUTC':datetime.now(timezone.utc).isoformat(),'SDK':dict(sdk),'Native':dict(native),'bothActualFailures':True,'independentArchiveReview':'docs/legado-ios/evidence/sdk-f481e89-terminal/root-independent-review.json','subsequentSourceRepairsDoNotChangeHistoricalResults':True}
policy['currentUnifiedCheckpoint']={'sourceCommit':c['sourceCommit'],'requestRecord':'docs/legado-ios/core-sdk-f481e89-request.json','counts':load(R/'docs/legado-ios/core-sdk-f481e89-request.json')['intendedSelection'],'status':'both-terminal-failures-fully-archived','actualResultAccepted':False}
steps=plan['execution']['stepByStep'];steps['currentF481SDKTerminal']=dict(sdk)
steps['queuedS2PreUpdateNativeResultCheckpoint']['status']='both-f481-terminal-failures-fully-archived-source-repairs-await-next-coherent-checkpoint'
for step in steps['steps']:
    if step.get('pendingSDKRequest')=='docs/legado-ios/core-sdk-f481e89-request.json':
        step['lastClosedSDKRequest']=step.pop('pendingSDKRequest');step['lastSDKTerminalRecord']=c['record']
        step.setdefault('implementationEvidence',[]).append({'record':c['record'],'scope':'Actual App0 after one production compiler error; independent Package24 and synthetic producer48 passed within narrower scopes. Exact source repair is separate, with no post-fix SDK claim.'})
    if step['id'] in ['C1','C2','C3','C4','C5']:
        step['nextActionZh']='按用户90%阶段目标，先验证已合入的搜索、详情、目录、正文与状态保存核心链路；长尾功能暂缓。兼容率仍需代表性书源全流程样本，不能由测试数量推算。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(c['record'])
write(plan_path,plan);paths.append(plan_path)
assert len(paths)==len(set(paths));write(S/'canonical-roster.json',[fact(p) for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
print(json.dumps({'canonicalPaths':len(paths),'App':0,'PackagePassed':24,'producerPassed':48,'liveJobs':0,'pendingTerminalArchives':0,'compatibilityMeasuredPercent':None}))
