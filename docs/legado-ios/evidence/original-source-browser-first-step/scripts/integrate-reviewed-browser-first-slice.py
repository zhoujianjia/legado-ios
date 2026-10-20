from pathlib import Path
import hashlib,json,subprocess
ROOT=Path('F:/yuedu-reader');GIT='D:/app/Git/cmd/git.exe'
STAGE=ROOT/'.build/consolidated-sdk-browser-start-checkpoint';SOURCE=ROOT/'.build/ready-browser-host-final-source';AUTHOR=ROOT/'.build/original-source-login-browser-host-step'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip();assert head.startswith('46123fb')
status=subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines();assert all(x=='?? debug.log' for x in status),status
mp=STAGE/'preparation/final-v1.json';rp=STAGE/'preparation/root-review.json'
check(mp,{'bytes':17220,'sha256':'74c16d29a43f2624864d2b10b5e5578debd72802630623c72815aca515a59204'});check(rp,{'bytes':2443,'sha256':'f856d8ebe43cb0a5c125124ddd054e69838f2a703f093bf0b177daa52bef590c'})
m=read(mp);review=read(rp);author=read(AUTHOR/'final-v1.json');assert review['findings']==[]
sources={};rows=[]
for stage,group in [(SOURCE,m['productionSources']),(STAGE,m['files'])]:
    for row in group:
        path=row['path'];check(stage/'work'/path,row['candidate'])
        if row['baseline'] is None:assert not (ROOT/path).exists()
        else:check(ROOT/path,row['baseline'])
        sources[path]=(stage/'work'/path).read_bytes();rows.append(row)
assert len(sources)==16
record_path=ROOT/'docs/legado-ios/core-original-source-browser-first-step.json';base=ROOT/'docs/legado-ios/evidence/original-source-browser-first-step';assert not record_path.exists() and not base.exists()
items={}
def add(p,name,r=None):
    assert p.is_file(),str(p)
    if r:check(p,r)
    if name in items:assert items[name]==p
    else:items[name]=p
for p,name in [(mp,'checkpoint-preparation.json'),(rp,'root-review.json'),(AUTHOR/'final-v1.json','Browser/preparation.json')]:add(p,name)
for row in author['evidence']:add(AUTHOR/row['path'],'Browser/'+row['path'],row)
for row in m['evidence']:add(ROOT/row['path'],'checkpoint/'+row['path'].removeprefix('.build/'),row)
for cmd in m['actualPortableGuards']['commands']:add(ROOT/cmd['log']['path'],'checkpoint/'+Path(cmd['log']['path']).name,cmd['log'])
for row in rows:add(ROOT/row['diff']['path'],'diffs/'+row['path']+'.diff',row['diff'])
for name in ['compose-reviewed-browser-host-source.py','review-browser-first-slice-checkpoint.py','integrate-reviewed-browser-first-slice.py']:add(ROOT/'.build'/name,'scripts/'+name)
normalized={};preserved=[]
for name,p in items.items():
    b=p.read_bytes();encoding='utf-16' if b[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig'
    if p==AUTHOR/'execution-v1/compile-java.log':
        encoding='gb18030';assert b.decode(encoding).encode(encoding)==b
    text=b.decode(encoding);text='\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n');normalized[name]=(text+'\n' if text else '').encode()
for name,p in items.items():
    dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst),'originalEvidence':{'path':p.relative_to(ROOT).as_posix(),**fact(p)},'normalization':'BOM-aware UTF8/LF; trailing horizontal/empty EOF whitespace removed; exact original byte facts retained'})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'reviewed-first-nonawait-original-GET-browser-consumer-integrated-await-and-real-UIKit-pending','reviewedCanonicalParent':head,'sourceFiles':rows,'changedSourceFiles':14,'unchangedInheritedSources':2,'countsForNextCheckpoint':m['counts'],'scope':author['implementation'],'validation':author['actual'],'validationHistory':author['validationHistory'],'sourceAndRuntimeIndependentReviews':m['sourceReviews'],'productionManifestCompositionReview':m['productionCompositionReview'],'rootReview':review,'controlsValidation':m['actualPortableGuards'],'preservedEvidence':preserved,'invariants':m['invariants'],'limits':author['limits']+m['limits'],'currentLiveCheckpoint':'docs/legado-ios/core-sdk-8d934dd-request.json','current8dSourceUnchanged':True,'newCloudTagCreated':False,'deliveredBuild14Unchanged':True,**{k:False for k in FLAGS}}
plan_path=ROOT/'docs/legado-ios/completion-plan.json';plan=read(plan_path);cloud=plan['execution']['cloudTriggerPolicy'];assert {r['runID'] for r in cloud['onlyLiveSDKHandles']}=={39495414820,39495414773}
record['integrationHistory']='Initial preflight stopped before any archive/source/plan writes on the Windows GB18030 compiler diagnostic for the preserved first BOM runner attempt. The exact known log round-trips GB18030; normalized UTF8 retains every character and original byte facts. No production or regression failure was introduced.'
assert all(plan[k] is False for k in FLAGS)
plan['activeBatchRecord']=record_path.relative_to(ROOT).as_posix();steps=plan['execution']['stepByStep']
steps['originalBrowserFirstSlice']={'record':record_path.relative_to(ROOT).as_posix(),'actualIncrementalJVMTestsPassed':4,'outsideJavaSessions':5,'actualSwiftSDKorJNIorUIKit':0,'limitedNonawaitGETOnly':True}
steps['queuedBrowserFirstSliceNextCheckpoint']={'record':record_path.relative_to(ROOT).as_posix(),**m['counts'],'actualAcceptancePending':True,'awaitFurtherWorkExcluded':True,'requiresLive8dTerminalFirst':True}
c2=next(s for s in steps['steps'] if s['id']=='C2');c2['implementationEvidence'].append({'record':record_path.relative_to(ROOT).as_posix(),'scope':'Actual original startBrowser nonawait GET uses existing Host authorization, Presenter queue and browser/Cookie owner, with real UIKit completion ACK and explicit cancellation drainage. Exact incremental JVM4/outsideJava5 passed; real SDK/JNI/UIKit remains pending.'})
c2['nextActionZh']='继续补齐原 awaitBrowser 的真实完成结果、默认重新取正文和页面关闭语义；保留唯一原 JVM/HTTP/Cookie/界面宿主。当前只完成有限非等待 GET 打开页面片段，完整书源兼容仍未完成。'
cloud['nextPlannedCheckpoint']='Only immutable8d SDK/Native handles are live. Browser first nonawaitGET slice and reviewed5-control successor are integrated for a later coherent source; its332/134/23 inputs andNative22+1 are not8d execution evidence. Continue Await independently, archive actual8d terminal outcomes and fix real failures before another combined pair. No duplicate, per-item or IPA tag.'
for path,b in sources.items():
    dst=ROOT/path;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(b)
write(record_path,record);write(plan_path,plan)
paths=[ROOT/r['path'] for r in rows if r.get('changed',True)]+[base/name for name in items]+[record_path,plan_path];assert len(paths)==len(set(paths))
write(STAGE/'canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**fact(p)} for p in paths]);subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'reviewedPaths':len(paths),'changedSources':14,'boundedJVMPassed':4,'SDKorJNI':0,'newTags':0}))
