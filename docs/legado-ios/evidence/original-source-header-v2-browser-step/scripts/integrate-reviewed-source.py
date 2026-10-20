from pathlib import Path
import datetime,hashlib,json,re,subprocess,sys,xml.etree.ElementTree as ET
R=Path('F:/yuedu-reader');G='D:/app/Git/cmd/git.exe';SOURCE=R/'.build/consolidated-header-v2-browser-source-step'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k]for k in ('bytes','sha256')},str(p)
def save(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
mp=Path(sys.argv[1]).resolve();rp=Path(sys.argv[2]).resolve();S=mp.parent.parent
assert mp.is_relative_to(R/'.build')and rp.is_relative_to(R/'.build')
check(mp,{'bytes':17729,'sha256':'a4ab79c1428426797bed6a1a8f316179d9852f34cf690d27865b3cb9a000c649'})
check(rp,{'bytes':21295,'sha256':'1a7c79ac27d6acc7acd308ebd7ff4bba6c5ccf7a9fbb25a52f036206c9f67df2'})
head=subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip();assert head.startswith('ab32203')
assert all(x=='?? debug.log'for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
sm=SOURCE/'final-v1.json';check(sm,{'bytes':30709,'sha256':'deb31b5e7a4784869f2e0580402c611ab363dcdc31ae7844715baa6ebec65d4c'})
sr=R/'.build/consolidated-header-v2-browser-independent-review/review-v1.json';check(sr,{'bytes':22548,'sha256':'cae00e84fd0e07ebaf898a8969fa9d9c3e2cf030d3ee6b4a3d776a9513927dec'})
source=read(sm);review=read(sr);m=read(mp);controlsreview=read(rp)
assert review['failedChecks']==0 and review['remainingConfirmedFindings']==[]
assert controlsreview.get('failedChecks',0)==0 and controlsreview.get('findings',[])==[] and controlsreview.get('remainingConfirmedFindings',[])==[]
assert fact(mp)['sha256']in json.dumps(controlsreview),'Independent controls review must bind exact manifest'
counts=m['counts'];assert counts['coreInputs']==338 and counts['nativeInputs']==140 and counts['uniqueInputUnion']==356 and counts['NativeOriginalDefinitions']==26 and counts['NativeLoginInfoDefinitions']==15
assert counts['AppDefinitions']==463 and counts['AppLeaves']==466 and counts['BoolParameterPairs']==3 and counts['PackageMethods']==24 and counts['PackageAllInputs']==23
assert source['actual']['JUnitDistinct']==23 and source['actual']['JUnitExecutions']==23 and source['actual']['failed']==source['actual']['skipped']==0
xml=ET.parse(SOURCE/source['actual']['XML']['path']).getroot();cases=xml.findall('.//testcase');assert len(cases)==len({(x.attrib['classname'],x.attrib['name'])for x in cases})==23
assert not xml.findall('.//failure')+xml.findall('.//error')+xml.findall('.//skipped')
check(SOURCE/source['actual']['production']['jar']['path'],source['actual']['production']['jar'])
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);cloud=plan['execution']['cloudTriggerPolicy'];assert cloud['onlyLiveSDKHandles']==[] and all(plan[k]is False for k in FLAGS)
sources={};rows=[]
for stage,files in [(SOURCE,source['files']),(S,m['files'])]:
 for row in files:
  p=row['path'];check(stage/'work'/p,row['candidate'])
  if row['baseline']is None:assert not(R/p).exists()
  else:check(R/p,row['baseline'])
  assert p not in sources;sources[p]=(stage/'work'/p).read_bytes();rows.append(row)
assert len(sources)==15 and len(m['files'])==5
rosters={};union={}
for name,expected in [('core',338),('Native',140),('Package',23)]:
 row=m['sourceRosters'][name];path=R/row['path'];check(path,row);rs=read(path);assert len(rs)==len({r['path']for r in rs})==expected;rosters[name]=rs
 for x in rs:
  raw=sources[x['path']]if x['path']in sources else(R/x['path']).read_bytes();f={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()};assert f=={k:x[k]for k in ('bytes','sha256')},x['path']
  if x['path']in union:assert union[x['path']]==f
  union[x['path']]=f
assert len(union)==356 and set(sources)<=set(union)
for x in rosters['Package']:check(R/x['path'],x)
assert m['actualPortableGuards']['distinctMethods']==4 and m['actualPortableGuards']['passed']==4
for c in m['actualPortableGuards']['commands']:assert c['exitCode']==0;check(R/c['log']['path'],c['log'])
recordpath=R/'docs/legado-ios/core-original-source-header-v2-browser-step.json';base=R/'docs/legado-ios/evidence/original-source-header-v2-browser-step';assert not recordpath.exists()and not base.exists()
items={};excluded=[]
def add(p,name,row=None):
 p=Path(p);assert p.is_file(),str(p)
 if row:check(p,row)
 if p.suffix in ('.class','.kotlin_module','.jar','.zip','.ipa'):
  excluded.append({'path':p.relative_to(R).as_posix(),**fact(p),'reason':'Immutable binary remains ignored; source/class/input bindings retained in text evidence'});return
 assert name not in items or items[name]==p;items[name]=p
for p,name in [(sm,'source-composition.json'),(sr,'reviews/source-union-review.json'),(mp,'checkpoint-preparation.json'),(rp,'reviews/controls-review.json')]:add(p,name)
for row in source['evidence']:add(SOURCE/row.get('snapshotPath',row['path']),'coherent/'+row['path'],row)
for row in source['files']:add(SOURCE/row['diff']['path'],'diffs/'+row['path']+'.diff',row['diff'])
parentreviews=[sr]
for parent in source['parents']:
 p=Path(parent['path']);check(p,parent);author=read(p);prefix=p.parent.name;add(p,'parents/'+prefix+'/preparation.json')
 for row in author['evidence']:add(p.parent/row.get('snapshotPath',row['path']),'parents/'+prefix+'/'+row['path'],row)
 for row in author.get('files',[]):add(p.parent/row['diff']['path'],'parents/'+prefix+'/diffs/'+row['path']+'.diff',row['diff'])
for path in ['.build/original-source-login-header-independent-review/review-v1.json','.build/original-source-login-v2-browser-independent-review/review-v1.json','.build/sdk-7576-native-login-fixture-independent-review/review-v1.json']:
 p=R/path;add(p,'reviews/'+p.parent.name+'.json')
for row in m.get('evidence',[]):add(R/row['path'],'checkpoint/'+row['path'].removeprefix('.build/'),row)
for row in m['files']:add(R/row['diff']['path'],'diffs/'+row['path']+'.diff',row['diff'])
for name,row in m['sourceRosters'].items():add(R/row['path'],'checkpoint/'+name+'-source-inputs.json',row)
for c in m['actualPortableGuards']['commands']:add(R/c['log']['path'],'checkpoint/'+Path(c['log']['path']).name,c['log'])
add(R/'.build/integrate-reviewed-header-v2-browser.py','scripts/integrate-reviewed-source.py')
normalized={}
for name,p in items.items():
 raw=p.read_bytes();enc='utf-16'if raw[:2]in(b'\xff\xfe',b'\xfe\xff')else'utf-8-sig';text=raw.decode(enc)
 assert b'\x00'not in raw and not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}',raw) and not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw),name
 text='\n'.join(x.rstrip(' \t')for x in text.splitlines()).rstrip('\n');normalized[name]=(text+'\n'if text else'').encode()
preserved=[]
for name,p in items.items():
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(R).as_posix(),**fact(dst),'originalEvidence':{'path':p.relative_to(R).as_posix(),**fact(p)},'normalization':'BOM-aware UTF8/LF and trailing horizontal/empty EOF whitespace removed; exact original byte facts retained'})
record={'schemaVersion':1,'recordedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'reviewed-coherent-Header-V2-browser-and-actual-test-target-API-repair-integrated-SDK-JNI-pending','reviewedCanonicalParent':head,'sourceFiles':rows,'changedSourceFiles':15,'countsForNextCheckpoint':counts,'scope':source['scope'],'sourceComposition':source['compositions'],'actualIncrementalEvidence':source['actual'],'validationHistory':source['history'],'sourceIndependentReview':{'path':sr.relative_to(R).as_posix(),**fact(sr)},'sourceReviewFindings':review['remainingConfirmedFindings'],'controlsIndependentReview':{'path':rp.relative_to(R).as_posix(),**fact(rp)},'controlsValidation':m['actualPortableGuards'],'invariants':m['invariants'],'preservedEvidence':preserved,'excludedBinaryEvidence':excluded,'actualPriorFailures':['SDK7576 App0/test-target compilation25 errors; two inherited methods repaired, not retroactive acceptance.','Native7576 Gradle/JVM/Native0 because stale expected22/actual23; successor strict future26 includesPOST/Header/V2.'],'limits':['Actual common direct3-source Kotlin compile,23distinct JVM and ordinary JAR-only consumer passed; not fresh fullGradle, SwiftSDK/JNI/UIKit/device acceptance.','Browser authority is finite explicit original login task admission; no full generalWebJS/non-nullHTML/flight/general-search browser compatibility.','Header owner ACK is accepted memory/UserDefaults state, not fsync/disk durability; existing first-party producer trust boundary is retained.','Raw credential/revision checks cannot prove no MayCommit attempt or same-value call.','Real same-device authenticated overwrite, profile expiry extension, cold relaunch/data preservation and unattended renewal remain unverified.'],'actual7576SDKTerminal':'docs/legado-ios/core-sdk-7576cbf-terminal-result.json','actual7576NativeTerminal':'docs/legado-ios/core-native-7576cbf-terminal-result.json','newCloudTagCreated':False,'deliveredBuild14Unchanged':True,**{k:False for k in FLAGS}}
steps=plan['execution']['stepByStep'];steps['originalHeaderV2BrowserSlice']={'record':recordpath.relative_to(R).as_posix(),'actualCommonJVMMethodsPassed':23,'ordinaryJARConsumerSessions':1,'ordinaryJARConsumerCalls':3,'realHTTPRequests':2,'NativeDefinitions':26,'SwiftSDKorJNIorUIKitExecuted':0}
steps['queuedHeaderV2BrowserNextCheckpoint']={'record':recordpath.relative_to(R).as_posix(),**counts,'actualAcceptancePending':True,'allPriorJobsTerminalAndArchived':True}
for step in steps['steps']:
 if step['id']=='C2':
  step['implementationEvidence'].append({'record':recordpath.relative_to(R).as_posix(),'scope':'Same existing rawHeader/Cookie owners and original V2 source browser APIs combined; actual commonJVM23 and ordinaryJava same-session3calls/2HTTP passed. Native/JNI/UI0; full compatibility pending.'})
  step['nextActionZh']='原登录头顺序与有限V2浏览器已合并，复用同一JVM、HTTP、Cookie和持久化owner。共同23项JVM及普通JAR连续调用通过；下一统一批次运行真实原生26项及MainJS1。通用WebJS、非空HTML和flight等未完成，不标完整书源兼容。'
 if step['id']=='C3':step['nextActionZh']='公开原WebBook四段与同owner正文链保持既有接线；先取得本批实际SDK/JNI结果。完整WebBook能力和默认产品入口验收继续未完成，不能用局部登录浏览器结果代替。'
 if step['id']=='C4':step['nextActionZh']='两个7576任务已终态归档；本批合并原登录头、有限V2浏览器、实际测试API修复和严格26项数量控制，提交一次SDK/App463定义466叶及原生26+MainJS1统一验证。只有实际结果可升级验收。'
 if step['id']=='C5':
  step['nextActionZh']='现有App离线重开测试只是在同进程创建新BookStore，不能当作进程重启证据。继续实现独立producer/consumer测试宿主、同自有文件位置及source/PID/进度收据，并实际执行跨进程离线恢复；当前批次不冒充该验收。'
 if step['id']=='S3':step['nextActionZh']='7576材料生产48命令及独立Package24通过，App签名用例执行0；两处测试API错误已合入本批，在同作业SDK材料约束下实际执行App签名和独立验签。真实账号与设备续签仍未验证。'
plan['activeBatchRecord']=recordpath.relative_to(R).as_posix()
cloud['currentCoreLatestTerminal']={**cloud['latestSDKTerminal'],'sourceTag':'reader-renewal-7576cbf','AppDefinitionsPassed':0,'AppExecutionLeavesPassed':0,'unexecutedSelectedDefinitions':463,'independentPackageMethodsPassed':24}
cloud['nextPlannedCheckpoint']='No live cloud jobs. Header/V2browser/rootCompilerRepair10 plus strict5controls are reviewed and integrated:338core/140Native/23Package/356union, original26+MainJS1, App463/466. Submit one coherentSDK/Native pair; no per-item/duplicate/IPA tag. Never repoll historical failures.'
for p,raw in sources.items():dst=R/p;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(raw)
save(recordpath,record);save(pp,plan)
paths=[R/x['path']for x in rows]+[base/name for name in items]+[recordpath,pp];assert len(paths)==len(set(paths));save(S/'canonical-roster.json',[{'path':p.relative_to(R).as_posix(),**fact(p)}for p in paths])
subprocess.run([G,'diff','--check'],cwd=R,check=True);print(json.dumps({'reviewedPaths':len(paths),'changedSources':15,'actualCommonJVM':23,'ordinaryJARCalls':3,'SDKorJNI':0,'newTags':0}))
