from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path.cwd();S=R/'.build/original-general-webjs-expression-result-step';G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def check(p,d):assert fact(p)=={k:d[k] for k in ['bytes','sha256']},str(p)
def save(p,d):
 p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
check(S/'review-v1.json',dict(bytes=14120,sha256='dcd6c3a84679f0cf7bccb7ea70904a956d5de47cef353415342d0d07ca354514'))
check(S/'review-v2-caller-supplement.json',dict(bytes=3292,sha256='40f85ad4f87a58fd2022bad4e993be1a86f16610b0d7090bac3a83a060c80977'))
f=read(S/'review-v1.json');c=read(S/'review-v2-caller-supplement.json')
assert f['sourceScope']['chromiumCommit']=='1b10defa68c2f01621bc3795169817d777aa714a' and c['actualCallerFlagsProven'] is True
assert f['actualJavaScriptCounterexamples']['executions']==1 and f['actualJavaScriptCounterexamples']['vectors']==6
for row in f['sourceScope']['fourSources']:check(R/row['local'],row)
check(R/c['actualCallerSource']['path'],c['actualCallerSource'])
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
base=R/'docs/legado-ios/evidence/original-webjs-android-result-contract-step';rp=R/'docs/legado-ios/core-original-webjs-android-result-contract-step.json'
assert not base.exists() and not rp.exists()
items={'primary-review.json':S/'review-v1.json','caller-supplement.json':S/'review-v2-caller-supplement.json','integration.py':Path(__file__)}
for x in [f['primaryBinding'],c['primary'],f['actualJavaScriptCounterexamples']['command'],f['actualJavaScriptCounterexamples']['source'],f['actualJavaScriptCounterexamples']['stdout']]:
 p=R/x['path'];check(p,x);items['facts/'+p.name]=p
normalized={}
for name,p in items.items():
 b=p.read_bytes();assert b'\0' not in b and not re.search(rb'[?&]X-Amz-Signature=',b)
 t=b.decode('utf-8-sig');normalized[name]=('\n'.join(x.rstrip(' \t') for x in t.splitlines()).rstrip('\n')+'\n').encode()
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);assert all(plan[x] is False for x in FLAGS)
assert {x['runID'] for x in plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']}=={39524696933,39524697051}
preserved=[];paths=[]
for name,p in items.items():
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);paths.append(dst)
 preserved.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF/trailing whitespace only'))
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='source-contract-correction-generic-captured-stringify-route-rejected-before-production',chromiumSourceContract=f['sourceScope'],ordinaryCallerFacts=c['facts'],facts=f['facts'],actualNodeExecutions=1,actualNodeVectors=6,NodeOnlyNotAndroidExecution=True,priorMAINFilesReassessment=f['priorMAINFilesReassessment'],capturedStringifyCharacterizationIsAndroidAcceptance=False,productionChanges=0,newSDK_JVM_WK_AndroidExecutions=0,currentObjectsRemainTypedUnsupported=True,preservedEvidence=preserved,limits=c['remainingBindingLimits']+['Frozen earlier insertion-order reports remain historical. Insertion order alone cannot exclude a native Program result route against the bound sorted base dictionary contract.','The running f233826 characterizations do not execute this source-derived Android converter; their results cannot establish Android parity.','Actual WK bridge information preservation and precise bounded converter/writer implementation remain unfinished.'],**{x:False for x in FLAGS})
save(rp,record);paths.append(rp)
steps=plan['execution']['stepByStep'];steps['webJSAndroidResultContract']=dict(record=rp.relative_to(R).as_posix(),productionChanges=0,sourceContractOnly=True,actualNodeOnlyVectors=6,genericCapturedStringifyRouteRejected=True,WKNativeInformationCharacterizationPending=True)
for step in steps['steps']:
 if step['id']=='C1':
  step.setdefault('implementationEvidence',[]).append(dict(record=rp.relative_to(R).as_posix(),scope='Bound Android source callback uses value conversion and default base JSON writer. Generic page stringify differs on sorted keys, omitted values, toJSON, getter failures and nonfinite/number types. No new production support or Android/WK runtime proof.'))
  step['nextActionZh']='General公开64调用与17个合成Host场景已有JVM证据，当前f233统一SDK/JNI仍待结果；对象返回必须按实际Chromium值转换器与base编码合同处理，已停用仅捕获stringify的错误候选方向，下一步真实测WK原生结果桥的信息保真。资源嗅探、外部jsLib、proxy与preUpdateJs仍分别未验收，完整兼容保持未完成。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(rp.relative_to(R).as_posix());save(pp,plan);paths.append(pp)
save(S/'canonical-contract-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
ignored=subprocess.run([G,'check-ignore','--stdin'],cwd=R,input=''.join(p.relative_to(R).as_posix()+'\n' for p in paths).encode(),capture_output=True);assert ignored.returncode==1 and not ignored.stdout
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),productionChanges=0,actualNodeVectors=6,newSDK_Android=0)))
