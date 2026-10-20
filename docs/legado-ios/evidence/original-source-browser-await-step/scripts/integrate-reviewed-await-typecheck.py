from pathlib import Path
import hashlib,json,subprocess
ROOT=Path('F:/yuedu-reader');GIT='D:/app/Git/cmd/git.exe'
STAGE=ROOT/'.build/consolidated-sdk-browser-await-two-repairs-checkpoint';SOURCE=ROOT/'.build/ready-browser-await-two-compiler-repairs-source';AUTHOR=ROOT/'.build/original-source-login-browser-await-step';FIX=ROOT/'.build/sdk-8d-login-ui-form-typecheck-repair-step';FIX2=ROOT/'.build/native-8d-external-open-repair-step'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip()
assert all(x=='?? debug.log' for x in subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines())
mp=STAGE/'preparation/final-v3.json';rp=STAGE/'preparation/root-review-v1.json'
expected=read(STAGE/'preparation/root-approved-facts.json');check(mp,expected['manifest']);check(rp,expected['review'])
m=read(mp);review=read(rp);composition=read(SOURCE/'preparation-v1.json');author=read(AUTHOR/'final-v1.json');fix=read(FIX/'final-v1.json');assert review['findings']==[]
plan_path=ROOT/'docs/legado-ios/completion-plan.json';plan=read(plan_path);cloud=plan['execution']['cloudTriggerPolicy']
assert cloud['onlyLiveSDKHandles']==[] and all(plan[k] is False for k in FLAGS)
assert (ROOT/'docs/legado-ios/core-sdk-8d934dd-terminal-result.json').is_file() and (ROOT/'docs/legado-ios/core-native-8d934dd-terminal-result.json').is_file()
sources={};rows=[]
for stage,group in [(SOURCE,composition['files']),(STAGE,m['files'])]:
    for row in group:
        path=row['path'];check(stage/'work'/path,row['candidate'])
        if row['baseline'] is None:assert not (ROOT/path).exists()
        else:check(ROOT/path,row['baseline'])
        assert path not in sources;sources[path]=(stage/'work'/path).read_bytes();rows.append(row)
assert len(sources)==21 and sum(r.get('changed',True) for r in rows)==18
record_path=ROOT/'docs/legado-ios/core-original-source-browser-await-step.json';base=ROOT/'docs/legado-ios/evidence/original-source-browser-await-step';assert not record_path.exists() and not base.exists()
items={}
def add(p,name,r=None):
    assert p.is_file(),str(p)
    if r:check(p,r)
    if name in items:assert items[name]==p
    else:items[name]=p
for p,name in [(mp,'checkpoint-preparation.json'),(rp,'root-review.json'),(SOURCE/'preparation-v1.json','source-composition.json'),(AUTHOR/'final-v1.json','Await/preparation.json'),(FIX/'final-v1.json','compiler-repair/preparation.json'),(FIX2/'final-v1.json','native-compiler-repair/preparation.json')]:add(p,name)
for row in author['evidence']:add(AUTHOR/row['path'],'Await/'+row['path'],row)
for row in fix.get('evidence',[]):add(FIX/row['path'],'compiler-repair/'+row['path'],row)
for row in read(FIX2/'final-v1.json')['evidence']:add(FIX2/row['path'],'native-compiler-repair/'+row['path'],row)
for row in m['productionIndependentReviews']:
    p=ROOT/row['path'];add(p,'reviews/'+p.parent.name+'/'+p.name,row)
    for sub in read(p).get('subreviews',[]):
        q=ROOT/sub['path'];add(q,'reviews/'+q.parent.name+'/'+q.name,sub)
for row in m['sourceRosters'].values():add(ROOT/row['path'],'checkpoint/'+Path(row['path']).name,row)
for row in m['evidence']:add(ROOT/row['path'],'checkpoint/'+row['path'].removeprefix('.build/'),row)
for cmd in m['portableEvidenceReuse']['records']:add(ROOT/cmd['log']['path'],'checkpoint/'+Path(cmd['log']['path']).name,cmd['log'])
for row in rows:add(ROOT/row['diff']['path'],'diffs/'+row['path']+'.diff',row['diff'])
for name in ['compose-reviewed-await-and-compiler-repair.py','compose-reviewed-await-two-compiler-repairs.py','review-browser-await-two-repairs-checkpoint.py','integrate-reviewed-await-typecheck.py']:add(ROOT/'.build'/name,'scripts/'+name)
normalized={}
for name,p in items.items():
    b=p.read_bytes();encoding='utf-16' if b[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig';text=b.decode(encoding)
    text='\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n');normalized[name]=(text+'\n' if text else '').encode()
preserved=[]
for name,p in items.items():
    dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst),'originalEvidence':{'path':p.relative_to(ROOT).as_posix(),**fact(p)},'normalization':'BOM-aware UTF8/LF, trailing horizontal/empty EOF whitespace removed; exact original byte facts retained'})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'reviewed-original-GET-await-and-both-actual-compiler-repairs-integrated-next-real-cohort-pending','reviewedCanonicalParent':head,'sourceFiles':rows,'changedSourceFiles':18,'unchangedInheritedSources':3,'countsForNextCheckpoint':m['counts'],'scope':author['implementation'],'validation':author['actual'],'validationHistory':author['history'],'compilerRepairs':[fix,read(FIX2/'final-v1.json')],'rootReview':review,'controlsValidationReuse':m['portableEvidenceReuse'],'preservedEvidence':preserved,'invariants':m['invariants'],'limits':author['limits']+['Actual8d SDK and Native terminal facts remain historical; this changed source has no actual Swift compiler/JNI/UIKit pass.','Actual standalonePackage24 is limited to its unchanged23 source/control inputs, not changed App or signer acceptance.'],'actual8dTerminalRecords':['docs/legado-ios/core-sdk-8d934dd-terminal-result.json','docs/legado-ios/core-native-8d934dd-terminal-result.json'],'newCloudTagCreated':False,'deliveredBuild14Unchanged':True,**{k:False for k in FLAGS}}
plan['activeBatchRecord']=record_path.relative_to(ROOT).as_posix();steps=plan['execution']['stepByStep']
steps['originalBrowserAwaitSlice']={'record':record_path.relative_to(ROOT).as_posix(),'actualIncrementalJVMTestsPassed':8,'outsideJavaSessions':5,'actualSwiftSDKorJNIorUIKit':0,'limitedLegacyGETOnly':True,'confirmedInitialCookieCancellationP1Repaired':True}
steps['queuedAwaitCompilerRepairNextCheckpoint']={'record':record_path.relative_to(ROOT).as_posix(),**m['counts'],'actualAcceptancePending':True,'POSTExcluded':True}
updates={
'C1':'原规则与 AnalyzeUrl 保持原 JVM/Rhino 入口；本批有限 GET await 已接线并有实际 JVM8/外部Java5，下一统一批次必须取得实际 SDK/JNI 结果。完整书源兼容继续未完成。',
'C2':'有限 GET start/await、页面确认与默认重新取正文已合入，取消后的 Cookie 回调与旧页面加载已修。继续在独立阶段补 POST 原正文预取/复用，随后处理尚缺宿主和浏览器语义；实际 UIKit/JNI 验收仍待下一批次。',
'C3':'8d 实际编译在旧登录表单表达式中断，本批已拆分该表达式；目录/正文/离页保存与重启恢复仍须下一批实际原生结果验收。',
'C4':'8d 实际 JVM 与 Native 结果已归档；本批23个原方法及独立MainJS1必须在真实JNI/App中执行。普通JAR和独立Package通过不能替代JNI验收。',
'C5':'两章、分页、保存、离线重开和进度恢复保留原生用例；先以修复后的统一批次取得实际执行结果，再针对真实失败补齐差分覆盖。',
'S1':'8d 独立Package24通过，App因表单编译错误未执行；表达式修复后集中运行真实Bundle/IPA和材料读取用例，真实Apple材料及安装授权仍待实证。',
'S2':'材料发布后的会话重连已有生产接线；下一统一App回归验证生命周期，真实账号授权、材料发布及新的到期时间仍未验收。',
'S3':'8d 受控Mac producer实际48条命令/43项输出及4份MachO通过，App重签/独立验签用例因编译阻断执行0。本批修复后必须实际运行，不升级为Apple或设备授权。',
'S4':'认证传输与安装客户端已有生产接线；下一批实际App回归后，仍须真实配对端点验证同机认证安装权限，当前未验收。',
'S5':'持久事务、恢复与数据交接已有生产接线；本批修复后执行统一回归，实际覆盖安装后的冷启及书籍/书源/进度保留仍未验证。',
'S6':'前台及系统允许的后台触发已有生产接线与持久节流；下一批实际回归后仍需设备调度和长期无人值守证据。'}
for step in steps['steps']:
    step['nextActionZh']=updates[step['id']]
    if step['id']=='C2':step['implementationEvidence'].append({'record':record_path.relative_to(ROOT).as_posix(),'scope':'Finite originalGET await has actualJVM8/outsideJava5, real native presentation/confirmation/cancel/drain production wiring and one authored realWK/JNI method. ActualSDK/JNI/UIKit remains0.'})
cloud['nextPlannedCheckpoint']='Both8d jobs are terminal and archived. Both confirmed compiler failures and two portable assertion failures are repaired; reviewed21-file Await+two-compiler/control union is352 core334/Native136/Package23, Native23+separate1 andApp463/466. Submit one coherent SDK/Native pair after final source checks; no per-item or IPA tags. Independent POST work continues without altering this checkpoint.'
cloud['alreadyRunningTasks']='None; both8d source jobs are terminal and archived. Never poll closed runs again.'
for path,b in sources.items():
    dst=ROOT/path;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(b)
write(record_path,record);write(plan_path,plan)
paths=[ROOT/r['path'] for r in rows if r.get('changed',True)]+[base/name for name in items]+[record_path,plan_path];assert len(paths)==len(set(paths))
write(STAGE/'canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**fact(p)} for p in paths]);subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'reviewedPaths':len(paths),'changedSources':18,'boundedJVMPassed':8,'outsideJava':5,'SDKorJNI':0,'newTags':0}))
