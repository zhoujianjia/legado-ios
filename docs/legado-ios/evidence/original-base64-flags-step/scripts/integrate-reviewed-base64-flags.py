from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path.cwd(); S=R/'.build/original-base64-flags-step'; V=R/'.build/original-base64-flags-independent-review'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def save(p,d):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
f=read(S/'final-v1.json'); review=read(V/'review-v1.json')
assert review['frozenInput']==fact(S/'final-v1.json') and review['checksPassed']==1457 and review['testsRerun']==0
assert review['decision']=='accepted at ordinary JVM Base64 signature scope'
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
for row in f['files']:
    assert fact(R/row['path'])=={k:row['baseline'][k] for k in ('bytes','sha256')}
    assert fact(S/row['candidate']['path'])=={k:row['candidate'][k] for k in ('bytes','sha256')}
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); assert all(plan[k] is False for k in FLAGS)
assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[]
base=R/'docs/legado-ios/evidence/original-base64-flags-step'; recordpath=R/'docs/legado-ios/core-original-base64-flags-step.json'
assert not base.exists() and not recordpath.exists()
items={'preparation.json':S/'final-v1.json','independent-review.json':V/'review-v1.json','independent-initial-review-shape-failure.json':V/'initial-review-shape-failure.json','scripts/independent-review.py':V/'review.py','scripts/resume-body-comparison.py':V/'resume-body-comparison.py','scripts/independent-review-resume.py':V/'review-resume.py','scripts/integrate-reviewed-base64-flags.py':Path(__file__)}
binary=[]
for row in f['evidence']:
    p=S/row['path']; assert fact(p)=={k:row[k] for k in ('bytes','sha256')}
    if p.suffix in ('.class','.kotlin_module'):
        binary.append(row); continue
    items['actual/'+p.relative_to(S/'snapshot-v1/evidence').as_posix()]=p
for row in f['files']: items['diffs/'+Path(row['diff']['path']).name]=S/row['diff']['path']
primary=read(S/'snapshot-v1/evidence/primary-binding.json')
for row in primary['lockedOriginal']:
    p=R/row['path']; items['primary/'+p.name]=p
for label,row in [('Base64.java',primary['androidPrimary']['source']),('LICENSE-2.0.txt',primary['androidPrimary']['license'])]: items['primary/android/'+label]=R/row['path']
items['primary/android/Base64-oracle.java']=R/read(S/'snapshot-v1/evidence/oracle-transformation.json')['compiledOracle']['path']
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); text=raw.decode('utf-8-sig'); assert b'\0' not in raw and not re.search(rb'(?m)^-----BEGIN (?:RSA |EC )?PRIVATE KEY-----',raw)
    normalized[name]=('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')+'\n').encode() if text else b''
paths=[]; evidence=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    evidence.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF/trailing whitespace only; raw hash preserved'))
record=dict(schemaVersion=1,recordedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='integrated-reviewed-ordinary-JVM-Base64-signatures-SDK-pending',sourceFiles=f['files'],scope=f['scope'],implementation=f['implementation'],actualOrdinaryJVM=f['actual'],compilation=f['compilation'],runtimeClasses=f['runtimeClasses'],primary=f['primary'],ordinaryJar=f['ordinaryJar'],executedOrdinaryJar=f['executedOrdinaryJar'],postExecutionMetadataOnly=f['postExecutionMetadataOnly'],executionHistory=f['executionHistory'],binaryEvidenceOnlyHashed=binary,preservedEvidence=evidence,limits=f['proofLimits']+['Future ordinary JVM/JNI compilation must combine later generalWebJS ABI changes with these Base64 return descriptors. No previous immutable SDK outcome accepts this later source.'],newSwiftDefinitions=0,newSourcePaths=0,newCloudTags=0,**{k:False for k in FLAGS})
for row in f['files']:
    dst=R/row['path']; dst.write_bytes((S/row['candidate']['path']).read_bytes()); paths.append(dst)
save(recordpath,record); paths.append(recordpath)
steps=plan['execution']['stepByStep']; steps['base64FlagsSlice']=dict(record=recordpath.relative_to(R).as_posix(),productionSources=2,manifestFiles=1,actualOrdinaryCalls=117,independentAndroidOracleChecks=5108,SDK_JNI=0,pendingUnifiedSDK=True)
for step in steps['steps']:
    if step['id']=='C1':
        step.setdefault('implementationEvidence',[]).append(dict(record=recordpath.relative_to(R).as_posix(),scope='Existing Base64 flags and nullable byte-array overloads implemented; actual ordinary117 public/AnalyzeRule calls and5108 pinned Android oracle checks passed. Full compatibility and SDK/JNI remain pending.'))
        step['nextActionZh']='Base64既有参数和字节数组接口已补齐，普通JVM原入口117次调用及5108份Android参考对照通过；继续合并一般网页脚本执行、完整必要宿主与书源差分，保持同一原规则和状态所有权。新增网页脚本/ABI须统一SDK复验，完整兼容未完成。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(recordpath.relative_to(R).as_posix())
save(pp,plan); paths.append(pp)
assert len(paths)==len(set(paths)); save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedCanonicalPaths=len(paths),productionSources=2,manifestFiles=1,actualOrdinaryCalls=117,oracleChecks=5108,SDK_JNI=0,newTags=0)))
