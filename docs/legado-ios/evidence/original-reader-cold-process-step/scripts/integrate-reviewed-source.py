from pathlib import Path
import datetime,hashlib,json,re,subprocess,sys
R=Path('F:/yuedu-reader');S=R/'.build/c5-original-cold-process-step';G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k]for k in ('bytes','sha256')},str(p)
def save(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
mp=S/'final-v2.json';rp=Path(sys.argv[1]).resolve();assert rp.is_relative_to(R/'.build')
check(mp,{'bytes':18808,'sha256':'8f1cfdb07da216ba920b87f1bd76bb8238da0dba62308d1622bf5d9795ca386a'})
check(rp,{'bytes':92808,'sha256':'afb2f194edbcab6c931fb5d50569f34113491c6cf3302f55bf820c5caaa6b30f'})
m=read(mp);review=read(rp);assert fact(mp)['sha256']in json.dumps(review)
assert review.get('failedChecks',0)==0 and review.get('remainingConfirmedFindings',[])==[] and review.get('findings',[])==[]
head=subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip();assert head.startswith('1777179')
assert all(x=='?? debug.log'for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
assert len(m['files'])==6 and m['frozenSourcesRoot']=='snapshot-v2/work'
for row in m['files']:
 if row['baseline']is None:assert not(R/row['path']).exists()
 else:check(R/row['path'],row['baseline'])
 check(S/row['sourcePath'],row['candidate']);check(S/row['diff']['path'],row['diff'])
for row in m['evidence']:check(S/row.get('snapshotPath',row['path']),row)
for row in m['successorChanges']:check(S/row['incrementalDiff']['path'],row['incrementalDiff'])
check(S/m['parentFinal']['path'],m['parentFinal'])
controller=(S/m['frozenSourcesRoot']/'scripts/reader-experience/original-cold-process-tools.py').read_text(encoding='utf-8')
entry=controller[controller.index('def run(work, udid):'):controller.index('\ndef main():')]
assert entry.index('terminate_producer(')<entry.index("commit_marker(owned / 'producer.json'")<entry.index("run_host(work, 'consumer'")
assert "'producer-process-exit.json'"in entry
assert m['inventory']['originalSelectedMethods']==26 and m['inventory']['AppSelectedDefinitions']==463 and m['inventory']['AppArgumentLeaves']==466 and m['actualValidation']['coldAppHosts']==m['actualValidation']['AppleSDK']==0
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);cloud=plan['execution']['cloudTriggerPolicy'];assert {x['runID']for x in cloud['onlyLiveSDKHandles']}=={39507170170,39507170384}
assert all(plan[k]is False for k in FLAGS)
recordpath=R/'docs/legado-ios/core-original-reader-cold-process-step.json';base=R/'docs/legado-ios/evidence/original-reader-cold-process-step';assert not recordpath.exists()and not base.exists()
items={'preparation-v2.json':mp,'preparation-v1.json':S/'final-v1.json','independent-review.json':rp,'scripts/integrate-reviewed-source.py':R/'.build/integrate-reviewed-c5-cold-process.py'}
for row in m['evidence']:items[row['path']]=S/row.get('snapshotPath',row['path'])
for row in m['files']:items['diffs/'+row['path']+'.diff']=S/row['diff']['path']
for row in m['successorChanges']:items['incremental-diffs/'+row['path']+'.diff']=S/row['incrementalDiff']['path']
for path in ['.build/c5-original-cold-process-independent-review/pre-review-v1.json','.build/c5-original-cold-process-independent-review/pre-review-closure-v1.json']:
 p=R/path;assert p.is_file();items['reviews/'+p.name]=p
normalized={}
for name,p in items.items():
 raw=p.read_bytes();text=raw.decode('utf-8-sig');assert b'\x00'not in raw and not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}',raw) and not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw),name
 text='\n'.join(x.rstrip(' \t')for x in text.splitlines()).rstrip('\n');normalized[name]=(text+'\n'if text else'').encode()
preserved=[]
for name,p in items.items():
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(R).as_posix(),**fact(dst),'original':{'path':p.relative_to(R).as_posix(),**fact(p)},'normalization':'Strict UTF8/LF and trailing horizontal/EOF whitespace; immutable original facts retained'})
record={'schemaVersion':1,'recordedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'reviewed-production-CI-cross-process-original-reader-fixture-integrated-actual-two-hosts-pending','reviewedCanonicalParent':head,'sourceFiles':m['files'],'scope':m['scope'],'ownedRoutes':m['ownedRoutes'],'selectors':m['selectors'],'inventory':m['inventory'],'workflowGates':m['workflowGates'],'validation':{'distinctPortableDefinitions':6,'totalExecutionsIncludingOneFixtureFailure':11,'actualColdAppHosts':0,'actualSwiftSDK':0,'v1':m['actualValidation'],'v2':m['v2Validation'],'historyV2':m['historyV2']},'v2Semantics':m['v2Semantics'],'sourceChecksV2':m['sourceChecksV2'],'independentReview':{'path':rp.relative_to(R).as_posix(),**fact(rp)},'preservedEvidence':preserved,'limits':m['limits']+['The separate cold producer/consumer hosts are authored and CI-wired only; no process restart acceptance is established until both actually execute and all bound receipts pass.','The current fc3 cloud source does not contain these changes or later S4 Lookup-Complete repair. A future coherent source roster must bind final v2 plus current S4 bytes; no v1 shadow stamp is future acceptance.'],'liveImmutableSourceUnchanged':'fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a','newCloudTagCreated':False,**{k:False for k in FLAGS}}
steps=plan['execution']['stepByStep'];steps['originalReaderColdProcessSlice']={'record':recordpath.relative_to(R).as_posix(),'actualPortableDistinctPassed':6,'authoredSeparateColdHostMethods':2,'actualColdHostMethodsExecuted':0,'oldOriginal26SelectionUnchanged':True,'requiresFutureSourceRosterRebind':True}
steps['queuedColdProcessLookupNextCheckpoint']={'sourceRecords':['docs/legado-ios/core-installation-lookup-complete-step.json',recordpath.relative_to(R).as_posix()],'futureAppDefinitions':463,'futureAppLeaves':466,'futureOriginalGroup':26,'futureSeparateMainJSGroup':1,'futureSeparateColdHosts':2,'finalCoreNativeUnionCounts':'pending exact combined-roster calculation','actualAcceptancePending':True}
for step in steps['steps']:
 if step['id']=='C5':
  step.setdefault('implementationEvidence',[]).append({'record':recordpath.relative_to(R).as_posix(),'scope':'Two independent source-bound XCTest hosts now drive the actual owned public reader/files/cache/position chain. Portable protocol checks6 passed, actual AppleSDK cold hosts0; in-process reopen is not cross-process acceptance.'})
  step['nextActionZh']='已接线两次独立测试宿主：实际公开原书源链写入目录、正文与进度；确认生产者进程退出后，消费者核对同容器、不同PID和离线缓存。6项协议检查通过，真实SDK两宿主执行仍0。下一统一批次绑定最终v2和S4源码后实际运行，不能标C5已验证。'
plan['activeDevelopmentBatchRecords']=['docs/legado-ios/core-installation-lookup-complete-step.json',recordpath.relative_to(R).as_posix()]
cloud['nextPlannedCheckpoint']='Only fc3 SDK/Native is live. Reviewed S4 terminal-Lookup and C5 real two-host protocol are integrated for a later coherent checkpoint; rebind finalv2 source/controls with S4 and actual forthcoming failure repairs. No new tag before both current jobs terminal/archived, no duplicate or IPA tag.'
for row in m['files']:
 dst=R/row['path'];dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes((S/row['sourcePath']).read_bytes())
save(recordpath,record);save(pp,plan);paths=[R/x['path']for x in m['files']]+[base/name for name in items]+[recordpath,pp]
assert len(paths)==len(set(paths));save(S/'canonical-roster.json',[{'path':p.relative_to(R).as_posix(),**fact(p)}for p in paths]);subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps({'reviewedPaths':len(paths),'newColdMethods':2,'actualColdHosts':0,'newTags':0}))
