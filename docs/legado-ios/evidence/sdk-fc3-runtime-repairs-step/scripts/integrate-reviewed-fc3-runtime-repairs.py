from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path.cwd(); B=R/'.build'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def save(p,d):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
T=B/'renewal-fc3-tls-recovery-repair-step'; F=B/'sdk-fc3b01c-fixture-repairs'; C=B/'sdk-fc3-cms-ber-envelope-repair-step'
tf=read(T/'final-v1.json'); cf=read(C/'final-v1.json'); fr=read(B/'sdk-fc3b01c-fixture-independent-review/review-v1.json')
tr=read(B/'renewal-fc3-tls-recovery-independent-review/review-v1.json'); cr=read(B/'sdk-fc3-cms-ber-envelope-independent-review/review-v1.json')
assert tr['input']['sha256']==fact(T/'final-v1.json')['sha256'] and cr['input']['sha256']==fact(C/'final-v1.json')['sha256']
assert fr['authorCandidate']['sha256']==fact(F/'candidate-v2.json')['sha256']
assert tr['findings']==cr['findings']==[] and fr['status']=='approved-minimal-three-fixture-successor'
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
sources=[]
for kind,rows in [('TLS',tf['files']),('fixtures',fr['files']),('CMS',cf['files'])]:
    for row in rows:
        path=row.get('source',row.get('path')); old=R/path; new=R/row['candidate']['path']
        assert fact(old)=={k:row['baseline'][k] for k in ('bytes','sha256')},path
        assert fact(new)=={k:row['candidate'][k] for k in ('bytes','sha256')},path
        sources.append(dict(path=path,kind=kind,baseline=fact(old),candidate=dict(path=new.relative_to(R).as_posix(),**fact(new))))
assert len(sources)==9 and len({x['path'] for x in sources})==9
base=R/'docs/legado-ios/evidence/sdk-fc3-runtime-repairs-step'; rp=R/'docs/legado-ios/core-sdk-fc3-runtime-repairs-step.json'; assert not base.exists() and not rp.exists()
items={'TLS/preparation.json':T/'final-v1.json','TLS/independent-review.json':B/'renewal-fc3-tls-recovery-independent-review/review-v1.json','TLS/scripts/independent-review.py':B/'renewal-fc3-tls-recovery-independent-review/review.py','TLS/primary-binding.json':T/'snapshot-v1/primary-binding.json','fixtures/preparation-v1.json':F/'candidate-v1.json','fixtures/preparation-v2.json':F/'candidate-v2.json','fixtures/scripts/prepare.py':F/'prepare.py','fixtures/scripts/correct-metadata-v2.py':F/'correct-metadata-v2.py','CMS/preparation.json':C/'final-v1.json','CMS/independent-review.json':B/'sdk-fc3-cms-ber-envelope-independent-review/review-v1.json','CMS/scripts/independent-review.py':B/'sdk-fc3-cms-ber-envelope-independent-review/review.py','scripts/integrate-reviewed-fc3-runtime-repairs.py':Path(__file__)}
for row in tf['evidence']+cf['evidence']:
    p=R/row['path']; assert fact(p)=={k:row[k] for k in ('bytes','sha256')}; label='TLS' if p.is_relative_to(T) else 'CMS'
    items[label+'/actual/'+p.name]=p
for row in tf['files']: items['TLS/diffs/'+Path(row['diff']['path']).name]=R/row['diff']['path']
for row in read(T/'snapshot-v1/primary-binding.json')['files']:
    p=T/'snapshot-v1'/row['path']; items['TLS/'+row['path']]=p
reviewRoot=B/'sdk-fc3b01c-fixture-independent-review'
for p in reviewRoot.rglob('*'):
    if p.is_file() and p.suffix in ('.json','.py','.log','.txt','.diff'):
        items['fixtures/review/'+p.relative_to(reviewRoot).as_posix()]=p
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); text=raw.decode('utf-8-sig'); assert b'\0' not in raw
    assert not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw)
    assert not re.search(rb'[?&]X-Amz-Signature=[0-9a-fA-F]{16,}',raw)
    normalized[name]=('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')+'\n').encode() if text else b''
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); assert all(plan[k] is False for k in FLAGS)
assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[]
paths=[]; evidence=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    evidence.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF/trailing whitespace only; raw hashes retained'))
for row in sources:
    dst=R/row['path']; dst.write_bytes((R/row['candidate']['path']).read_bytes()); paths.append(dst)
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='nine-reviewed-source-repairs-integrated-actual-SDK-pending',actualFailureRecord='docs/legado-ios/core-sdk-fc3b01c-terminal-result.json',sourceFiles=sources,
    TLS=dict(change='Client remains strict certificate-Sent; server peer uses mandatory client auth, fresh auth break, exact CA/DER/date trust and completed TLS1.2 handshake. Socket/deadline/verification functions unchanged.',confidence='Pinned official legacy implementation supports role-state hypothesis. Historic failure omitted raw role/state; not a locally reproduced or SDK-proven fix.',fixtureChange='Each actual peer producer now finishes its event stream. Recovery requires real uploadIntent/submission; nil assertion replaces crash. Failed event prerequisites cancel and drain.'),
    CMS=dict(change='Bounded constructed indefinite BER envelopes accepted; ordinary DER, mandatory signedAttrs canonical encoding and original signature/trust/chain checks remain strict.',actualCounterexample='All4 actual1798B CI-produced CMS start3080; old DER reader rejects at offset0 before signature work.',independentPublicFixtureMathChecks=26,actualSwiftSecurityExecuted=0),
    fixtures=dict(change='Two explicit test roots now use required SelfRenewalApp basename; upload barrier test requires real precondition before enrollment work.',baselineScope=read(F/'candidate-v2.json')['baselineScope'],newDefinitions=0),
    unchangedSelection=dict(AppDefinitions=463,AppExpectedLeaves=466,PackageMethods=24,NativeOrdinaryMethods=27,NativeMainJSMethods=1,independentColdHosts=2),
    preservedEvidence=evidence,SDKTestsExecutedAfterRepair=0,newCloudTags=0,
    limits=['GeneralWebJS and Cookie follow-up repairs are separate and must be composed before a single coherent SDK checkpoint.','No old immutable run accepts these later source changes.','No actual Apple authorization, paired physical device, overwrite install, signed expiry extension, user-data cold restart or unattended renewal acceptance.'],**{k:False for k in FLAGS})
save(rp,record); paths.append(rp)
steps=plan['execution']['stepByStep']; steps['fc3RuntimeRepairs']=dict(record=rp.relative_to(R).as_posix(),sourceFiles=9,newDefinitions=0,actualSDKExecuted=0,pendingUnifiedSDK=True)
for step in steps['steps']:
    if step['id'] in ('S2','S3','S4','S5'):
        step.setdefault('implementationEvidence',[]).append(dict(record=rp.relative_to(R).as_posix(),scope='Actual fc3 runtime failures now have reviewed minimal code/fixture repairs; actual unified Swift/Security/TLS execution remains pending.'))
    if step['id']=='S3': step['nextActionZh']='已按真实SDK产物3080反例补有界CMS BER包络解析，保持signedAttrs DER、签名与证书链门禁；4份公开CMS及恶意边界26项离线校验通过。原同job整包签名回归须下一统一SDK实际通过，仍未验收真实Apple材料/覆盖安装。'
    if step['id']=='S4': step['nextActionZh']='已补Lookup终态Complete，并按官方主源修TLS服务端状态判定候选；保留客户端Sent、强制双向认证和完整CA/DER/date门禁。测试peer事件退出与恢复前置已修，实际SDK握手与安装客户端仍待复验。'
    if step['id']=='S5': step['nextActionZh']='真实SDK暴露的恢复测试事件等待环、缺失uploadIntent后继续恢复、强解包崩溃已修；持久事务/恢复/覆盖后数据交接须统一SDK与随后设备证据确认。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(rp.relative_to(R).as_posix()); save(pp,plan); paths.append(pp)
save(B/'fc3-runtime-repairs-canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True); print(json.dumps(dict(reviewedPaths=len(paths),sourceFiles=9,newDefinitions=0,SDKExecuted=0,newCloudTags=0)))
