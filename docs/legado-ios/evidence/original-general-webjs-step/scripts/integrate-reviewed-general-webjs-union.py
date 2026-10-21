from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path.cwd(); B=R/'.build'; J=B/'original-general-webjs-base64-union-step'; S=B/'original-general-webjs-coherent-swift-step'; P=B/'original-general-webjs-swift-implementation-step'; G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def save(p,d):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
j=read(J/'final-v1.json'); s=read(S/'final-v1.json'); parentSwift=read(P/'final-v1.json')
jrp=B/'original-general-webjs-base64-union-independent-review/review-v1.json'; srp=B/'original-general-webjs-coherent-swift-independent-review/review-v1.json'
assert fact(J/'final-v1.json')==dict(bytes=31155,sha256='b303167f8fad29eab53fcdc37feb9999410f3c41436afdaea55fb60fa56108ab')
assert fact(jrp)==dict(bytes=304216,sha256='aa6b45d83e5fe238bde4b80ef1a70819845afba4acf4ff507b3668044cc284b9')
assert fact(S/'final-v1.json')==dict(bytes=7730,sha256='da5edd97893e3a210278200a938e44e727d64e4458fa3783a6d717af4bcb7b59')
assert fact(srp)==dict(bytes=12420,sha256='42fdfd778f94c8fa6ba5cea39982198a8de28ff3c052270b5016b415bf89a059')
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
sources=[]; bindings=[]
for row in j['files']:
    path=row['path']; old=R/path; new=R/j['candidateRoot']/path
    assert fact(new)==row['candidate']
    if row['baseline'] is None: assert not old.exists(),path
    else: assert fact(old)==row['baseline'],path
    bindings.append(dict(path=path,baseline=row['baseline'],candidate=dict(path=new.relative_to(R).as_posix(),**fact(new)),changed=row['changed']))
    if row['changed']: sources.append((path,new))
for row in s['files']:
    path=row['path']; assert fact(R/path)==row['baseline'] and fact(R/row['candidate']['path'])=={k:row['candidate'][k] for k in ('bytes','sha256')}
    bindings.append(dict(path=path,baseline=row['baseline'],candidate=row['candidate'],changed=True)); sources.append((path,R/row['candidate']['path']))
assert len(sources)==16 and len({x[0] for x in sources})==16
base=R/'docs/legado-ios/evidence/original-general-webjs-step'; rp=R/'docs/legado-ios/core-original-general-webjs-step.json'; assert not base.exists() and not rp.exists()
items={'JVM/preparation.json':J/'final-v1.json','JVM/independent-review.json':jrp,'Swift/preparation.json':S/'final-v1.json','Swift/independent-composition-review.json':srp,'Swift/parent-preparation.json':P/'final-v1.json','Swift/parent-independent-review.json':B/'original-general-webjs-swift-independent-review/review-v1.json','Swift/scripts/prepare-coherent-source.py':S/'prepare.py','scripts/integrate-reviewed-general-webjs-union.py':Path(__file__),'Swift/Native-successor.json':B/'original-general-webjs-swift-native-successor/candidate-v1.json','Swift/scripts/Native-successor.py':B/'original-general-webjs-swift-native-successor/prepare.py','JVM/known-P2-parent-preparation.json':B/'original-general-webjs-step/implementation-v1/backend-final-v1.json','JVM/known-P2-parent-review.json':B/'original-general-webjs-backend-independent-review/review-v1.json'}
binary=[]
for label,rows,origin in [('JVM',j['evidence'],J),('Swift',parentSwift['evidence'],P)]:
    for row in rows:
        p=R/row['path']; assert fact(p)=={k:row[k] for k in ('bytes','sha256')},row['path']
        if p.suffix in ('.class','.jar','.kotlin_module','.zip','.cms','.der','.cd'): binary.append(row); continue
        assert p.is_relative_to(origin),str(p)
        items[label+'/actual/'+p.relative_to(origin).as_posix()]=p
for row in j['files']: items['JVM/diffs/'+Path(row['diff']['path']).name]=R/row['diff']['path']
for row in parentSwift['files']: items['Swift/parent-diffs/'+Path(row['diff']['path']).name]=R/row['diff']['path']
for name in ('wire-v1.json','extra-primary-binding-v2.json'):
    p=B/'original-general-webjs-step/implementation-v1'/name; assert p.exists(); items['protocol/'+name]=p
items['primary/locked-members-binding.json']=B/'original-general-webjs-step/primary-binding-v1.json'
normalized={}
for name,p in items.items():
    raw=p.read_bytes(); text=raw.decode('utf-8-sig'); assert b'\0' not in raw
    assert not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw)
    assert not re.search(rb'[?&]X-Amz-Signature=',raw)
    text='\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n')
    text=re.sub(r'(?m)^[ \t]* [ \t]*\t[ \t]*',lambda m:m.group().expandtabs(8),text)
    normalized[name]=(text+'\n').encode() if text else b''
pp=R/'docs/legado-ios/completion-plan.json'; plan=read(pp); assert all(plan[k] is False for k in FLAGS) and plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[]
paths=[]; evidence=[]
for name,p in items.items():
    dst=base/name; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    evidence.append(dict(path=dst.relative_to(R).as_posix(),**fact(dst),original=dict(path=p.relative_to(R).as_posix(),**fact(p)),normalization='Documentation UTF8/LF/trailing whitespace; mixed leading whitespace expanded to8columns only where required. Original raw hashes retained.'))
for path,new in sources:
    dst=R/path; dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(new.read_bytes()); paths.append(dst)
actual=read(R/j['actualResults']['path'])
record=dict(schemaVersion=1,recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='reviewed-coherent-general-webjs-core-integrated-Apple-SDK-pending',sourceBindings=bindings,changedFiles=16,newFiles=2,scope='Same original JVM/Rhino parser, existing session/page leases, original HTTP and existing native Cookie/state owners. Real Preview/ContentBatch/BookCallback attach and finish the same runtime invocation.',behavior=['Existing java.webView overloads, @webjs String-prior result and URL webView/webJs options route to the existing native headless runner; no local-HTML compatibility flag required.','Native configure/evaluation/navigation/Cookie policy uses an independent JVM operation and is unreachable through browser page requests. Source/java interfaces require actual admitted stored source; cache stays existing original owner.','Actual same-owner HTTP executes POST once before WK; protected300–399 no-follow response bypasses browser. URL negative delay clamps as locked original; direct API delays unchanged.','Page execution/cancellation/source revision/children and callbacks drain before lease cleanup. Raw null/empty retries follow original policy; typed unsupported branches remain explicit.'],actualOrdinaryJVM=actual,ordinaryJar=j['ordinaryJar'],compilation=j['counts'],negativeURLDelayFinding=j['P2'],Swift=dict(changedSources=6,newNativeMethods=1,oldReaderMethodsByteExact=13,newGrammarRoots=2,actualSDK=0,actualWK=0,actualJNI=0,CookieResponseMethod='Exact already-reviewed81c6c9b implementation preserved'),remainingCompatibility=s['remainingCompatibility'],preservedEvidence=evidence,binaryEvidenceOnlyHashed=binary,limits=j['limits']+['4 fresh targeted JUnit and ordinary combined consumers are not a full Gradle run.','No previous immutable SDK run accepts this later source; one final exact cohort is required.','Ordered object results, complete resource sniff, WK/CSP/interruption and platform cache/trust differences remain unfinished as declared.'],newCloudTags=0,**{k:False for k in FLAGS})
save(rp,record); paths.append(rp)
steps=plan['execution']['stepByStep']; steps['generalWebJSSlice']=dict(record=rp.relative_to(R).as_posix(),changedFiles=16,newFiles=2,newNativeMethods=1,actualJUnit=4,GeneralPublicCalls=46,Base64PublicCalls=78,Base64AnalyzeRuleSubset=39,pendingUnifiedSDK=True,remainingBranchesUnfinished=True)
base64=steps['base64FlagsSlice']; assert base64['actualOrdinaryCalls']==117; base64['actualOrdinaryCalls']=78; base64['originalAnalyzeRuleCallsWithinPublic']=39; base64['countCorrection']='39 AnalyzeRule paths are nested inside78 public execute calls; former117 aggregate mixed two API layers and was not117 independent public executions.'
base64Record=R/'docs/legado-ios/core-original-base64-flags-step.json'; b=read(base64Record); b['countClarification']=dict(publicExecuteCalls=78,AnalyzeRuleSubset=39,subsetIsAdditionalPublicExecutions=False,proof='Same original OrdinaryBase64Flags execute() counter increments78; analyzer branch inside39 of those calls. Raw frozen evidence and source execution unchanged.',supersedesFormerPlanAggregate=117); save(base64Record,b); paths.append(base64Record)
for step in steps['steps']:
    if step['id']=='C1':
        for item in step.get('implementationEvidence',[]):
            if isinstance(item,dict) and item.get('record')=='docs/legado-ios/core-original-base64-flags-step.json': item['scope']=item['scope'].replace('actual ordinary117 public/AnalyzeRule calls','actual78 public calls including39 nested AnalyzeRule paths')
    if step['id'] in ('C1','C2','C3','C4','C5'):
        step.setdefault('implementationEvidence',[]).append(dict(record=rp.relative_to(R).as_posix(),scope='Actual coherent original general-WebJS JVM and all3 native owner consumers integrated with current Base64/Cookie repairs. Targeted ordinary/JUnit evidence only; full compatibility and Apple SDK/WK pending.'))
    if step['id']=='C1': step['nextActionZh']='一般网页脚本、URL webView与@webjs String前项已接原规则链，原URL负延迟边界已修；联合12源ABI重编及4新JUnit、46次General公开调用、78次Base64公开调用（内含39条AnalyzeRule子路径）通过。对象结果与完整资源嗅探等仍未完成；下一统一SDK实际复验。'
plan.setdefault('activeDevelopmentBatchRecords',[]).append(rp.relative_to(R).as_posix()); save(pp,plan); paths.append(pp)
save(J/'canonical-roster.json',[dict(path=p.relative_to(R).as_posix(),**fact(p)) for p in paths]); subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps(dict(reviewedPaths=len(paths),changedFiles=16,newFiles=2,actualJUnit=4,GeneralPublicCalls=46,Base64PublicCalls=78,Base64AnalyzeSubset=39,SDK=0,newTags=0)))
