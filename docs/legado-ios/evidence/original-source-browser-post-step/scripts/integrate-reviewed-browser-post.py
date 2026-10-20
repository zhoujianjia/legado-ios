from pathlib import Path
import hashlib,json,subprocess
R=Path('F:/yuedu-reader');G='D:/app/Git/cmd/git.exe';S=R/'.build/consolidated-sdk-browser-post-checkpoint';SOURCE=R/'.build/ready-browser-post-source';A=R/'.build/original-source-login-browser-post-step'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
head=subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip();assert head.startswith('701ae4f')
assert all(x=='?? debug.log' for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
mp=S/'preparation/final-v1.json';rp=S/'preparation/root-review-v1.json';check(mp,{'bytes':16508,'sha256':'40265a217567e0972c6e468ce3c7780f013123a46fd41a6cd4a515172b4e54b2'});check(rp,{'bytes':2305,'sha256':'9962c74dd88ba216df625c4398cc2e702e339fecf9dd2e17a74149ad454f5514'})
m=read(mp);review=read(rp);composition=read(SOURCE/'preparation-v1.json');author=read(A/'final-v2.json');assert review['findings']==[]
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);cloud=plan['execution']['cloudTriggerPolicy'];assert [r['runID'] for r in cloud['onlyLiveSDKHandles']]==[39501414740] and all(plan[k] is False for k in FLAGS)
sources={};rows=[]
for stage,group in [(SOURCE,composition['files']),(S,m['files'])]:
 for row in group:
  p=row['path'];check(stage/'work'/p,row['candidate'])
  if row['baseline'] is None:assert not (R/p).exists()
  else:check(R/p,row['baseline'])
  assert p not in sources;sources[p]=(stage/'work'/p).read_bytes();rows.append(row)
assert len(sources)==14
recordpath=R/'docs/legado-ios/core-original-source-browser-post-step.json';base=R/'docs/legado-ios/evidence/original-source-browser-post-step';assert not recordpath.exists() and not base.exists()
items={}
def add(p,name,r=None):
 assert p.is_file(),str(p)
 if r:check(p,r)
 if name in items:assert items[name]==p
 else:items[name]=p
for p,name in [(mp,'checkpoint-preparation.json'),(rp,'root-review.json'),(SOURCE/'preparation-v1.json','source-composition.json'),(A/'final-v2.json','POST/preparation-v2.json'),(A/'final-v1.json','POST/preparation-v1.json')]:add(p,name)
for row in author['evidence']:add(A/row['path'],'POST/'+row['path'],row)
source_review=m['sourceIndependentReview'];p=R/source_review['path'];add(p,'reviews/'+p.name,source_review)
for row in read(p).get('subreviews',[]):
 q=R/row['path'];add(q,'reviews/'+q.name,row)
for row in m['sourceRosters'].values():add(R/row['path'],'checkpoint/'+Path(row['path']).name,row)
for row in m['evidence']:add(R/row['path'],'checkpoint/'+row['path'].removeprefix('.build/'),row)
for command in m['actualPortableGuards']['commands']:add(R/command['log']['path'],'checkpoint/'+Path(command['log']['path']).name,command['log'])
for row in rows:add((R if row['diff']['path'].startswith('.build/') else A)/row['diff']['path'],'diffs/'+row['path']+'.diff',row['diff'])
for name in ['compose-reviewed-browser-post-source.py','review-browser-post-checkpoint.py','integrate-reviewed-browser-post.py']:add(R/'.build'/name,'scripts/'+name)
for name in ['reproduction.json','actual-failure.log']:add(R/'.build/native-7576-portable-count-reproduction'/name,'actual-Native7576-reproduction/'+name)
normalized={}
for name,p in items.items():
 raw=p.read_bytes();encoding='utf-16' if raw[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig';text=raw.decode(encoding);text='\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n');normalized[name]=(text+'\n' if text else '').encode()
preserved=[]
for name,p in items.items():
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(R).as_posix(),**fact(dst),'originalEvidence':{'path':p.relative_to(R).as_posix(),**fact(p)},'normalization':'BOM-aware UTF8/LF and trailing horizontal/empty EOF whitespace removed; immutable originals and exact byte facts retained'})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'reviewed-original-POST-browser-and-actual-Native-stale-assertion-repair-integrated-real-SDK-JNI-pending','reviewedCanonicalParent':head,'sourceFiles':rows,'changedSourceFiles':14,'countsForNextCheckpoint':m['counts'],'scope':author['implementation'],'validation':author['validation'],'validationHistory':author['history'],'sourceIndependentReview':source_review,'rootReview':review,'controlsValidation':m['actualPortableGuards'],'actualNativeFailureRepair':m['actualFailureRepair'],'invariants':m['invariants'],'preservedEvidence':preserved,'limits':author['limits']+['Actual Native7576 failed beforeGradle/JVM/App build; its historical source23-versus22 failure is not retroactively passed.','SDK7576 source stays immutable and running; this source is a future coherent candidate, with no new tag from this integration.'],'currentSDKRequest':'docs/legado-ios/core-sdk-7576cbf-request.json','actualNativeTerminalRecord':'docs/legado-ios/core-native-7576cbf-terminal-result.json','newCloudTagCreated':False,'deliveredBuild14Unchanged':True,**{k:False for k in FLAGS}}
steps=plan['execution']['stepByStep'];steps['originalBrowserPOSTSlice']={'record':recordpath.relative_to(R).as_posix(),'actualIncrementalJVMTestsPassed':12,'outsideJavaSessions':5,'realHTTPRequests':6,'actualSwiftSDKorJNIorUIKit':0,'limitedLegacyPOSTOnly':True}
steps['queuedPOSTNextCheckpoint']={'record':recordpath.relative_to(R).as_posix(),**m['counts'],'actualAcceptancePending':True,'requiresCurrentSDKTerminalAndActualFailuresRepaired':True}
plan['activeBatchRecord']=recordpath.relative_to(R).as_posix()
c2=next(x for x in steps['steps'] if x['id']=='C2');c2['implementationEvidence'].append({'record':recordpath.relative_to(R).as_posix(),'scope':'OriginalPOST prefetch uses sole AnalyzeUrl/HTTP owner; true reuses initial body incl present-empty, false captures realDOM. JVM12/outsideJava5/HTTP6 passed; actualJNI/UIKit0, originalHeader owner ordering is next.'});c2['nextActionZh']='有限GET/POST start/await生产接线和JVM12/外Java5已完成，实际UIKit/JNI尚待下一统一批次。继续原putLoginHeader/removeLoginHeader同现Cookie/header owner顺序接线；flight/通用WebJS/v2浏览器与完整兼容继续未完成。'
c4=next(x for x in steps['steps'] if x['id']=='C4');c4['nextActionZh']='7576原生任务被旧方法数量断言拦在Gradle前，实际JVM/Native均0。本批已严格迁移未来24项并实际通过受影响检查；待当前SDK终态及真实失败修复后一并运行Native24和独立MainJS1，不能用旧8d327代替验收。'
cloud['nextPlannedCheckpoint']='OnlySDK7576 remains live. Native7576 early stale22-versus23 failure is archived/reproduced; reviewedPOST14-source/control successor now353 unique core335/Native137/Package23 withNative24+MainJS1, App463/466. Four affected portable guards passed. Wait for actual currentSDK terminal, repair confirmed causes, then one coherent future pair. No per-item, duplicate orIPA tag.'
np=R/'docs/legado-ios/core-native-7576cbf-terminal-result.json';native=read(np);native['futureRepair']={'status':'reviewed-successor-POST24-controls-integrated-not-historical-Native-acceptance','record':recordpath.relative_to(R).as_posix(),'candidateFrozen':True,'portableAffectedMethodsPassed':4,'sourceStampMethodPassed':1,'historical7576RemainsFailure':True,'newNativeOrSDKPassEstablished':False}
for p,raw in sources.items():
 dst=R/p;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(raw)
write(recordpath,record);write(pp,plan);write(np,native)
paths=[R/r['path'] for r in rows]+[base/name for name in items]+[recordpath,pp,np];assert len(paths)==len(set(paths));write(S/'canonical-roster.json',[{'path':p.relative_to(R).as_posix(),**fact(p)} for p in paths]);subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps({'reviewedPaths':len(paths),'changedSources':14,'incrementalJVM':12,'outsideJava':5,'SDKorJNI':0,'newTags':0}))
