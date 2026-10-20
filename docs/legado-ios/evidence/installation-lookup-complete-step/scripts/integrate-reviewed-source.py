from pathlib import Path
import datetime,hashlib,json,re,subprocess
R=Path('F:/yuedu-reader');S=R/'.build/s4-authenticated-installation-gap-step';G='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k]for k in ('bytes','sha256')},str(p)
def save(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
mp=S/'final-v1.json';rp=R/'.build/s4-authenticated-installation-gap-independent-review/review-v1.json'
check(mp,{'bytes':5643,'sha256':'125da7b151d0d6621f65dc56bd4d5bc9b218211c7c8636f0165db158a4fb2b1d'})
check(rp,{'bytes':21118,'sha256':'0a4cfdf76bbcf6ad478b5dc6f759897c73c8c997708edb7caa95455ab1af68fe'})
m=read(mp);review=read(rp);assert review.get('failedChecks',0)==0 and review.get('remainingConfirmedFindings',[])==[]
assert fact(mp)['sha256']in json.dumps(review) and len(m['files'])==3 and m['definitionCount']==7 and m['newDefinitions']==0
head=subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip();assert head.startswith('523817e')
assert all(x=='?? debug.log'for x in subprocess.check_output([G,'status','--porcelain'],cwd=R).decode().splitlines())
for row in m['files']:check(R/row['path'],row['baseline']);check(S/'work'/row['path'],row['candidate']);check(S/row['diff']['path'],row['diff'])
for row in m['evidence']:check(S/row['path'],row)
for row in m['primaryFiles']:check(R/row['path'],row)
old=(R/m['files'][0]['path']).read_text(encoding='utf-8');new=(S/'work'/m['files'][0]['path']).read_text(encoding='utf-8')
start='    private static func lookupOn(';end='    static func startService('
a=old.index(start);b=old.index(end,a);c=new.index(start);d=new.index(end,c);assert old[:a]+new[c:d]+old[b:]==new
assert 'while true' in new[c:d] and 'response["Status"] == .string("Complete")'in new[c:d]
assert new[c:d].index('response["Status"] == .string("Complete")')<new[c:d].index('return observation')
pp=R/'docs/legado-ios/completion-plan.json';plan=read(pp);cloud=plan['execution']['cloudTriggerPolicy'];assert {x['runID']for x in cloud['onlyLiveSDKHandles']}=={39507170170,39507170384}
assert all(plan[k]is False for k in FLAGS)
recordpath=R/'docs/legado-ios/core-installation-lookup-complete-step.json';base=R/'docs/legado-ios/evidence/installation-lookup-complete-step';assert not recordpath.exists()and not base.exists()
items={'preparation.json':mp,'independent-review.json':rp,'scripts/integrate-reviewed-source.py':R/'.build/integrate-reviewed-s4-lookup-complete.py'}
for row in m['evidence']:items[row['path']]=S/row['path']
for row in m['files']:items['diffs/'+row['path']+'.diff']=S/row['diff']['path']
normalized={}
for name,p in items.items():
 raw=p.read_bytes();text=raw.decode('utf-8-sig');assert b'\x00'not in raw and not re.search(rb'(?:[?&])X-Amz-Signature=[0-9a-fA-F]{16,}',raw) and not re.search(rb'(?m)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',raw),name
 text='\n'.join(x.rstrip(' \t')for x in text.splitlines()).rstrip('\n');normalized[name]=(text+'\n'if text else'').encode()
preserved=[]
for name,p in items.items():
 dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(R).as_posix(),**fact(dst),'original':{'path':p.relative_to(R).as_posix(),**fact(p)},'normalization':'Strict UTF8/LF and trailing horizontal/EOF whitespace; exact original facts retained'})
record={'schemaVersion':1,'recordedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'reviewed-production-lookup-terminal-completion-repair-integrated-actual-SDK-TLS-pending','reviewedCanonicalParent':head,'sourceFiles':m['files'],'scope':m['scope'],'behavior':'The same authenticated installation_proxy channel accumulates the last valid single-bundle LookupResult snapshot and returns only on terminal Status Complete. Same-frame Error is rejected first; missing result/EOF/cancel/frame-count and byte limits cannot publish a successful observation.','unchangedProduction':'Replacing only lookupOn restores the previous complete production file; TLS, StartService restrictions, safe staging cleanup and conservative verification flags are unchanged.','testDefinitions':7,'newDefinitions':0,'affectedExistingDefinitions':m['affectedExistingDefinitions'],'validation':m['validation'],'independentReview':{'path':rp.relative_to(R).as_posix(),**fact(rp)},'primarySourceFacts':m['primaryFiles'],'primaryLineCorrection':{'pinnedCommit':'fa0f79190142bc309307967c058f89c1b36eb6b8','file':'src/installation_proxy.c','lastSnapshotCallbackLines':'600-608; assignment604-606','synchronousLookupCallLines':'644-650','note':'Frozen contract-v1 used line positions from a master web cache. Independent review verified the exact pinned source bytes and corrected these locations; production source and original hashes are unaffected.'},'preservedEvidence':preserved,'liveImmutableSourceUnchanged':'fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a','newCloudTagCreated':False,'limits':m['limits']+['Current fc3 SDK/Native jobs do not contain this later repair and cannot validate it; one later unified source-bound SDK checkpoint is required.'],**{k:False for k in FLAGS}}
steps=plan['execution']['stepByStep'];steps['installationLookupTerminalSlice']={'record':recordpath.relative_to(R).as_posix(),'productionMethodsChanged':1,'testDefinitionsUnchanged':7,'actualSDKorTLSExecuted':0,'pendingUnifiedSDK':True}
for step in steps['steps']:
 if step['id']=='S4':
  step.setdefault('implementationEvidence',[]).append({'record':recordpath.relative_to(R).as_posix(),'scope':'Real production Lookup now requires terminal Complete and retains bounded same-channel result/error ordering. Independent source review passed; authored real-TLS vectors remain SDK execution0.'})
  step['nextActionZh']='已修复认证安装查询在LookupResult中间帧过早返回：同一认证连接须等最终Complete，迟到Error、EOF、取消与超限拒绝。该修改晚于当前fc3云源，须纳入下一统一SDK并实际运行受控TLS回归；真实配对同机安装权限仍未验证。'
 if step['id']=='S1':step['nextActionZh']='7576独立Package24通过且生产模块与链接输出已越过旧阻断，但测试目标编译失败使App用例执行0。当前fc3统一SDK重新验证真实Bundle/IPA及材料读取；真实Apple材料与设备安装授权仍待实证。'
plan['activeDevelopmentBatchRecord']=recordpath.relative_to(R).as_posix()
cloud['nextPlannedCheckpoint']='Only the fc3 SDK/Native pair is live. Continue C5 separate-process implementation and reviewed S4 Lookup-Complete repair without altering immutable fc3. Archive actual fc3 outcomes and fix confirmed failures before one later coherent source-bound pair; no duplicate or IPA tag.'
for row in m['files']:
 dst=R/row['path'];dst.write_bytes((S/'work'/row['path']).read_bytes())
save(recordpath,record);save(pp,plan);paths=[R/x['path']for x in m['files']]+[base/name for name in items]+[recordpath,pp]
save(S/'canonical-roster.json',[{'path':p.relative_to(R).as_posix(),**fact(p)}for p in paths]);subprocess.run([G,'diff','--check'],cwd=R,check=True)
print(json.dumps({'reviewedPaths':len(paths),'productionMethodsChanged':1,'actualSDKorTLS':0,'newTags':0}))
