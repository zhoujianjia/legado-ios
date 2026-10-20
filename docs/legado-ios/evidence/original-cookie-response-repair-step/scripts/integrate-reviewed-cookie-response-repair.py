from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path.cwd(); S=R/'.build/sdk-fc3-cookie-response-repair-step'; V=R/'.build/sdk-fc3-cookie-response-independent-review'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def save(p,d):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
f=read(S/'final-v1.json'); review=read(V/'review-v1.json'); assert review['input']['sha256']==fact(S/'final-v1.json')['sha256'] and review['checksPassed']==26 and review['findings']==[]
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
for row in f['files']:
    assert fact(R/row['path'])==row['baseline'] and fact(R/f['candidateRoot']/row['path'])==row['candidate']
base=R/'docs/legado-ios/evidence/original-cookie-response-repair-step'; rp=R/'docs/legado-ios/core-original-cookie-response-repair-step.json'; assert not base.exists() and not rp.exists()
items={'preparation.json':S/'final-v1.json','independent-review.json':V/'review-v1.json','scripts/independent-review.py':V/'review.py','scripts/integrate-reviewed-cookie-response-repair.py':Path(__file__),'primary-binding.json':R/f['primaryBinding']['path']}
for row in f['evidence']:
    p=R/row['path']; assert fact(p)=={k:row[k] for k in ('bytes','sha256')}; items['actual/'+p.relative_to(S).as_posix()]=p
for row in f['files']: items['diffs/'+Path(row['diff']['path']).name]=R/row['diff']['path']
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); text=raw.decode('utf-8-sig'); assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=',raw)
    normalized[name]=('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')+'\n').encode() if text else b''
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); assert all(plan[k] is False for k in FLAGS) and plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[]
paths=[]; evidence=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    evidence.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF/trailing whitespace only; original facts retained'))
for row in f['files']:
    dst=R/row['path']; dst.write_bytes((R/f['candidateRoot']/row['path']).read_bytes()); paths.append(dst)
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='reviewed-same-owner-response-cookie-construction-integrated-SDK-pending',sourceFiles=f['files'],rootCause=f['rootCause'],implementation=f['implementation'],validation=f['counts'],preservedEvidence=evidence,newDefinitions=0,newSourcePaths=0,limits=['Actual failing property was not measured by fc3; the production conversion guard failed. New fixed field-name diagnostic does not disclose Cookie bytes.','Same-run existing parser/properties/Record restoration succeeded; new two-source repair still requires actual Darwin SDK execution.','General headless Host successor must preserve this one-function change when composed. No source-owner, Cookie-owner, network engine or scope fallback added.'],newCloudTags=0,**{k:False for k in FLAGS})
save(rp,record); paths.append(rp)
steps=plan['execution']['stepByStep']; steps['cookieResponseConversionRepair']=dict(record=rp.relative_to(R).as_posix(),sourceFiles=2,newDefinitions=0,SDKExecuted=0,pendingUnifiedSDK=True)
for step in steps['steps']:
    if step['id']=='C2':
        step.setdefault('implementationEvidence',[]).append(dict(record=rp.relative_to(R).as_posix(),scope='Actual SDK response-Cookie guard failure receives same-owner native property construction repair with strict metadata gates and redacted diagnostics; new SDK execution pending.'))
        step['nextActionZh']='按真实SDK响应Cookie转换失败，改用系统真实响应属性构造并保留原HttpOnly、secure、session、绝对expiry等精确门禁；同一owner与原毫秒期限不变。现5方法中2项补强场景待统一SDK执行，具体旧失败字段未测，不提前宣称已修复验证。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(rp.relative_to(R).as_posix()); save(pp,plan); paths.append(pp)
save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths]); subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),sourceFiles=2,newDefinitions=0,SDK=0,newTags=0)))
