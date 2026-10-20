from pathlib import Path
import datetime, hashlib, json, re, subprocess, sys
R=Path('F:/yuedu-reader'); S=R/'.build/s2-authenticated-spd-challenge-step'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def check(p,b): assert fact(p)=={k:b[k] for k in ('bytes','sha256')}, str(p)
def save(p,x):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
mp=S/'final-v1.json'; rp=Path(sys.argv[1]).resolve(); assert rp.is_relative_to(R/'.build/s2-authenticated-spd-challenge-independent-review')
check(mp,dict(bytes=3887,sha256='b9c1b3bf8fe49ef180c458be2d541da1d9fa71eea80daf77e514c6741ce8dd4b'))
check(rp,dict(bytes=int(sys.argv[2]),sha256=sys.argv[3]))
m=read(mp); review=read(rp)
assert fact(mp)['sha256'] in json.dumps(review)
assert review.get('failedChecks',0)==0 and review.get('remainingConfirmedFindings',[])==[] and review.get('findings',[])==[]
assert review['mismatches']==[] and review['verdict']=='approved-source-and-independent-public-fixture-math-pending-SwiftSDK'
head=subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip(); assert head.startswith('f3e055b')
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
for row in m['sourceFiles']:
    check(R/row['baseline']['path'],row['baseline']); check(R/row['candidate']['path'],row['candidate'])
for row in read(S/'diffs-v1.json'): check(R/row['path'],row)
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp)
cloud=plan['execution']['cloudTriggerPolicy']
assert {x['runID'] for x in cloud['onlyLiveSDKHandles']}=={39507170170,39507170384}
assert all(plan[k] is False for k in FLAGS)
recordpath=R/'docs/legado-ios/core-renewal-authenticated-spd-challenge-step.json'
base=R/'docs/legado-ios/evidence/renewal-authenticated-spd-challenge-step'
assert not recordpath.exists() and not base.exists()
items={'preparation.json':mp,'independent-review.json':rp,
    'independent-pre-review.json':R/'.build/s2-authenticated-spd-challenge-independent-review/pre-review-v1.json',
    'primary-binding.json':S/'primary-binding-v1.json',
    'owned-fixtures-reference.json':S/'owned-spd-fixtures-reference-v1.json',
    'independent-fixture-math.json':R/'.build/s2-authenticated-spd-challenge-independent-review/fixture-math-v1.json',
    'scripts/prepare-owned-fixtures.py':S/'prepare-owned-fixtures.py',
    'scripts/verify-and-freeze.py':S/'verify-and-freeze.py',
    'scripts/integrate-reviewed-source.py':R/'.build/integrate-reviewed-s2-spd-challenge.py'}
for row in read(S/'diffs-v1.json'):
    p=R/row['path']; items['diffs/'+p.relative_to(S/'diffs').as_posix()]=p
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); t=raw.decode('utf-8-sig')
    assert b'\0' not in raw and not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}',raw)
    assert not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw)
    t='\n'.join(x.rstrip(' \t') for x in t.splitlines()).rstrip('\n')
    normalized[name]=(t+'\n' if t else '').encode()
preserved=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name])
    preserved.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),
        original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='Strict UTF8/LF and trailing horizontal/EOF whitespace; original byte facts retained.'))
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='reviewed-authenticated-SPD-secondary-authentication-integrated-SDK-pending',reviewedCanonicalParent=head,
    sourceFiles=m['sourceFiles'],scope='Same GSA authentication actor and actual URLSession/account/Vault path; no new endpoints or credential owner.',
    behavior='After outer error, M2 and negotiation MAC validation and SPD decryption, authenticated status-code409 selects an existing single-use five-minute challenge before app-token work. Absent mode with no conflicting outer marker does not request another push. Explicit trusted-device mode uses only the existing fixed endpoint. Legacy SPD without status/url preserves the existing outer trusted-device marker.',
    localAdmissionPolicy='Explicit unknown, mistyped and conflicting status/mode signals reject. SPD200 requires no mode/outer secondary marker. These strict conflict rules are local policy; the pinned upstream does not define conflict precedence.',
    authoredRegression=m['authoredRegression'],authoredScenarioProtocol='The17 synthetic URLSession scenarios use only Vectors.first(s2k); the22 crypto-loop variants cover both protocols. No actual runtime execution is claimed.',
    validation=dict(independentPythonPublicFixtureVariants=22,syntaxRoots=2,actualSwiftSDK=0,actualURLSessionCases=0,actualApple=0),
    primaryFacts=read(S/'primary-binding-v1.json'),independentReview=dict(path=rp.relative_to(R).as_posix(),**fact(rp)),
    preservedEvidence=preserved,limits=m['limits']+['Current immutable fc3 SDK/Native runs do not contain this later change. Future unified SDK must execute the existing11 definitions with the new scenarios.'],
    liveImmutableSourceUnchanged='fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a',newCloudTagCreated=False,**{k:False for k in FLAGS})
steps=plan['execution']['stepByStep']
steps['authenticatedSPDChallengeSlice']=dict(record=recordpath.relative_to(R).as_posix(),
    publicSealedVariants=22,authoredURLSessionScenarios=17,unchangedTestDefinitions=11,actualSDKExecuted=0,pendingUnifiedSDK=True)
for step in steps['steps']:
    if step['id']=='S2':
        step.setdefault('implementationEvidence',[]).append(dict(record=recordpath.relative_to(R).as_posix(),scope='Authenticated SPD409 now enters the existing one-use challenge; automatic/manual and explicit trusted-device routes remain distinct. Same account/material validation still precedes storage. Source review and fixture math only; actual SDK/Apple execution pending.'))
        step['nextActionZh']='已补M2与协商MAC验证后的加密SPD二次认证分支；验证码已触发时不重复请求，可信设备模式沿固定路由，冲突与未知模式拒绝。22份公开重封向量离线校验通过，原11个回归新增场景仍待下一统一SDK实际执行；真实Apple授权、材料及到期延长尚未验收。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(recordpath.relative_to(R).as_posix())
cloud['nextPlannedCheckpoint']='Only fc3 SDK/Native is live. Later reviewed S4 Lookup, C5 independent hosts and S2 authenticated SPD challenge require one coherent final roster with forthcoming WebJS and any actual fc3 failure repairs. Archive both current outcomes before another pair; no duplicate or IPA tag.'
for row in m['sourceFiles']:
    (R/row['baseline']['path']).write_bytes((R/row['candidate']['path']).read_bytes())
save(recordpath,record); save(pp,plan)
paths=[R/row['baseline']['path'] for row in m['sourceFiles']]+[base/n for n in items]+[recordpath,pp]
assert len(paths)==len(set(paths))
save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),newDefinitions=0,actualSwiftSDK=0,newTags=0)))
