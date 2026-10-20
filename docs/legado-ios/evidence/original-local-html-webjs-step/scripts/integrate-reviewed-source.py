from pathlib import Path
import datetime, hashlib, json, re, subprocess, sys
R=Path('F:/yuedu-reader'); B=R/'.build/original-local-html-webjs-step/implementation-v1'; S=R/'.build/original-local-html-webjs-swift-step'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def check(p,f): assert fact(p)=={k:f[k] for k in ('bytes','sha256')}, str(p)
def resolve(base,s):
    p=Path(s)
    p=p if p.is_absolute() else R/p if s.startswith('.build/') else base/p
    assert p.resolve().is_relative_to(R/'.build'); return p
def save(p,x):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
bp=B/'backend-final-v2.json'; sp=S/'final-v1.json'; rp=Path(sys.argv[1]).resolve()
assert rp.is_relative_to(R/'.build')
check(bp,dict(bytes=34731,sha256='3ce8c092ce65acf3e38e136cf6b81070a7e1df96ebc8184a4d1266fd4e816854'))
check(sp,dict(bytes=11850,sha256='e2fbf3c0091ff1f74869120f32f33d4a0e8c5c22bc700e39bbb1eb2667092fd0'))
check(rp,dict(bytes=int(sys.argv[2]),sha256=sys.argv[3]))
b=read(bp); s=read(sp); review=read(rp)
assert fact(bp)['sha256'] in json.dumps(review) and fact(sp)['sha256'] in json.dumps(review)
assert 'approved' in json.dumps(review).lower()
assert review.get('mismatches',[])==[] and review.get('failedChecks',0)==0 and review.get('findings',[])==[] and review.get('remainingConfirmedFindings',[])==[]
head=subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip(); assert head.startswith('59ad5db')
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
assert len(b['files'])==8 and len(s['files'])==7
files=[]
for base,m in [(B,b),(S,s)]:
    root=resolve(base,m['candidateRoot'])
    for row in m['files']:
        if row['baseline'] is None: assert not (R/row['path']).exists()
        else: check(R/row['path'],row['baseline'])
        check(root/row['path'],row['candidate']); check(resolve(base,row['diff']['path']),row['diff'])
        files.append((root/row['path'],row))
assert len({row['path'] for _,row in files})==15
check(resolve(S,s['backendParent']['path']),s['backendParent']); check(resolve(S,s['interface']['path']),s['interface'])
assert s['backendParent']['sha256']==fact(bp)['sha256']
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); cloud=plan['execution']['cloudTriggerPolicy']
assert all(plan[k] is False for k in FLAGS)
assert {x['runID'] for x in cloud['onlyLiveSDKHandles']}=={39507170170,39507170384}
recordpath=R/'docs/legado-ios/core-original-local-html-webjs-step.json'
archive=R/'docs/legado-ios/evidence/original-local-html-webjs-step'; assert not archive.exists() and not recordpath.exists()
items={'backend-preparation-v2.json':bp,'swift-preparation.json':sp,'independent-review.json':rp,
       'backend-preparation-v1.json':resolve(B,b['supersedes']['path']),
       'scripts/integrate-reviewed-source.py':R/'.build/integrate-reviewed-local-html-webjs.py'}
for label,base,m in [('backend',B,b),('swift',S,s)]:
    for row in m['evidence']:
        p=resolve(base,row['path']); check(p,row)
        name=label+'/evidence/'+p.relative_to(base).as_posix()
        assert name not in items; items[name]=p
    for row in m['files']:
        items[label+'/diffs/'+row['path']+'.diff']=resolve(base,row['diff']['path'])
general=R/'.build/original-general-webjs-step'
for name in ['counterexamples-v1.json','primary-binding-v1.json','GeneralWebJSUnsupported.java','run-counterexamples.py','pin-primary.py','ordinary/compile.log','ordinary/execute.log']:
    items['next-general-contract/'+name]=general/name
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); t=raw.decode('utf-8-sig')
    assert b'\0' not in raw and not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}',raw),name
    assert not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw),name
    t='\n'.join(x.rstrip(' \t') for x in t.splitlines()).rstrip('\n')
    normalized[name]=(t+'\n' if t else '').encode()
preserved=[]
for name,p in items.items():
    dst=archive/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name])
    preserved.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='Strict UTF8/LF and trailing horizontal/EOF whitespace; original facts retained.'))
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='reviewed-explicit-HTML-login-WebJS-same-session-production-integrated-SDK-JNI-WK-pending',reviewedCanonicalParent=head,
    sourceFiles=[row for _,row in files],scope='Explicit HTML legacy/V2 login browser pages and their retained original AnalyzeRule JS_INJECTION2 bridge; same session, task-local child operations, HTTP/state/cache/Cookie owners.',
    interface=s['interface'],backendOrdinaryJar=s['backendOrdinaryJar'],backendCounts=b['counts'],
    backendValidationScope=b['limits'],swiftNewDefinitions=s['newDefinitions'],
    regression=dict(actualOrdinaryJavaSessions=3,actualOrdinaryPublicCalls=81,actualHTTP=5,syntheticSourceBrowserHostCalls=11,
      independentOriginalJS2NodeCases=6,actualJVMJUnit=0,actualSwiftSDK=0,actualJNI=0,actualWK=0),
    implementation=b['implementation'],newNativeSelector='LegadoNativeOriginalLoginInfoTests/testNativeOriginalLocalHTMLWebJSKeepsSameSessionAfterProducerAndDrainsAwaitCancellation',
    ownership='Page lifetime retains its existing RuntimeSession after a nonawait producer returns. Close, producer cancellation and source edits seal/cancel/drain the actual owned children. Same indexed BookSourceStore verifies initial presence and later one-source revisions; no new persistent store or index.',
    uncompletedGeneralContracts=dict(record=read(general/'counterexamples-v1.json'),primaryBinding=read(general/'primary-binding-v1.json'),
      note='These3 actual old ordinary-JAR counterexamples prove a separate missing contract; this local-HTML bridge does not implement java.webView, AnalyzeRule @webjs, AnalyzeUrl webView options or verification flights.'),
    independentReview=dict(path=rp.relative_to(R).as_posix(),**fact(rp)),preservedEvidence=preserved,
    limits=b['limits']+s['limits']+['Current immutable fc3 jobs do not contain this later source; a later exact common roster must bind all15 sources plus S4/C5/S2 and strict Native27/MainJS1/cold2 controls.'],
    liveImmutableSourceUnchanged='fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a',newCloudTagCreated=False,**{k:False for k in FLAGS})
steps=plan['execution']['stepByStep']
steps['originalLocalHTMLWebJSSlice']=dict(record=recordpath.relative_to(R).as_posix(),
    actualOrdinaryPublicCalls=81,authoredNativeIncrement=1,actualNativeExecuted=0,pendingUnifiedSDK=True)
for step in steps['steps']:
    if step['id']=='C2':
        step.setdefault('implementationEvidence',[]).append(dict(record=recordpath.relative_to(R).as_posix(),scope='Real same-session retained local-page AnalyzeRule and JS2 bridge, ordinary JAR81 calls and Node6 passed within their limited boundaries; actual SDK/JNI/WK still0.'))
        step['nextActionZh']='显式HTML登录页已接原AnalyzeRule/JS2与同会话子任务，关闭、父取消和书源编辑会撤销并排空。普通JAR81调用/5真实HTTP及Node6检查通过；下一统一批次须实际执行原生27+MainJS1和独立冷进程2。通用java.webView、@webjs、URL WebView选项及flight仍未完成。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(recordpath.relative_to(R).as_posix())
cloud['nextPlannedCheckpoint']='Only fc3 SDK/Native handles remain the current cloud pair. Reviewed S4/C5/S2 and explicitHTML WebJS require the next exact coherent controls and source roster; archive actual current outcomes and fix confirmed failures before one later pair. No duplicate or IPA tag.'
for source,row in files:
    target=R/row['path']; target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(source.read_bytes())
save(recordpath,record); save(pp,plan)
paths=[R/row['path'] for _,row in files]+[archive/name for name in items]+[recordpath,pp]
assert len(paths)==len(set(paths))
save(S/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),productionAndManifestFiles=14,authoredNativeIncrement=1,actualSwiftSDK=0,newTags=0)))
