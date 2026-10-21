from pathlib import Path
import datetime, hashlib, json, re, subprocess

R=Path.cwd(); G='D:/app/Git/cmd/git.exe'
S=R/'.build/sdk-88c61ee-headless-api-repair-step'
V=R/'.build/sdk-88c61ee-headless-api-independent-review/review-v1.json'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def check(p,x): assert fact(p)=={k:x[k] for k in ('bytes','sha256')},str(p)
def save(p,x):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
f=read(S/'final-v1.json'); v=read(V)
check(V,dict(bytes=5189,sha256='6994389f5da38c61c36855d7c394222a2b779220ffa4ba6ede47155dd146f29e'))
check(S/'final-v1.json',v['parent'])
assert v['final'] is True and v['approved'] is True and v['failedChecks']==[] and v['findings']==[]
assert len(f['files'])==1 and f['actual']['SDK']==0 and f['actualFailure']['AppCases']==0
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
row=f['files'][0]; target=R/row['path']; candidate=R/f['sourceRoot']/row['path']
check(target,row['baseline']); check(candidate,row['candidate'])
old=target.read_bytes(); new=candidate.read_bytes()
assert old.replace(b'wk.code == .javaScriptException {',b'wk.code == .javaScriptExceptionOccurred {').replace(b'in: nil, contentWorld: .defaultClient) { result in',b'in: nil, in: .defaultClient) { result in')==new
base=R/'docs/legado-ios/evidence/sdk88-headless-api-repair-step'
rp=R/'docs/legado-ios/core-sdk88-headless-api-repair-step.json'
assert not base.exists() and not rp.exists()
items={'preparation.json':S/'final-v1.json','independent-review.json':V,'integration.py':Path(__file__)}
for x in f['primary']+[f['sourceVerification'],f['actualFailure']['diagnostics'],row['diff']]:
    p=R/x['path']; check(p,x); items['evidence/'+p.name]=p
normalized={}
for name,p in items.items():
    b=p.read_bytes(); assert b'\0' not in b and not re.search(rb'[?&]X-Amz-Signature=',b)
    t=b.decode('utf-8-sig'); normalized[name]=('\n'.join(x.rstrip(' \t') for x in t.splitlines()).rstrip('\n')+'\n').encode()
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp)
assert all(plan[x] is False for x in FLAGS)
paths=[]; preserved=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='UTF8/LF/trailing whitespace only'))
target.write_bytes(new); paths.append(target)
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='reviewed-two-token-API-repair-integrated-Apple-SDK-recompile-pending',sourceFiles=f['files'],changes=f['changes'],invariants=f['invariants'],actual=f['actual'],historicalSDK88=f['actualFailure'],preservedEvidence=preserved,proofLimits=f['proofLimits'],integrationHistory=['First preflight rejected an incorrect helper assertion expecting rawValue; stopped before canonical writes. Corrected assertion to the actual frozen diff and resumed integration only.'],newCloudTags=0,**{x:False for x in FLAGS})
save(rp,record); paths.append(rp)
plan['execution']['stepByStep']['SDK88HeadlessAPIRepair']=dict(record=rp.relative_to(R).as_posix(),productionFiles=1,tokenReplacements=2,actualNewSDKCases=0,historicalSDK88AppCases=0,AppleSDKRecompilePending=True)
plan.setdefault('activeDevelopmentBatchRecords',[]).append(rp.relative_to(R).as_posix())
save(pp,plan); paths.append(pp)
save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
ignored=subprocess.run([G,'check-ignore','--stdin'],cwd=R,input=''.join(p.relative_to(R).as_posix()+'\n' for p in paths).encode(),capture_output=True)
assert ignored.returncode==1 and not ignored.stdout
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),productionFiles=1,tokenReplacements=2,actualNewSDK=0)))
