from pathlib import Path
import hashlib,json,subprocess
ROOT=Path('F:/yuedu-reader');GIT='D:/app/Git/cmd/git.exe';STAGE=ROOT/'.build/sdk-8d-portable-guard-expectations-repair-step';REPRO=ROOT/'.build/sdk-8d-portable-failure-reproduction'
def read(p):return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip();assert head.startswith('547ed4e')
status=subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines();assert all(x=='?? debug.log' for x in status),status
mp=STAGE/'preparation/final-v1.json';check(mp,{'bytes':4210,'sha256':'23a54c81c18a88ec3a90c089fc78cf398f6692a8ed70cea03f6e44be6dd63978'})
m=read(mp);assert len(m['files'])==1;row=m['files'][0];src=STAGE/'work'/row['path'];check(src,row['candidate']);check(ROOT/row['path'],row['baseline']);check(ROOT/row['diff']['path'],row['diff'])
before=(ROOT/row['path']).read_bytes();after=src.read_bytes()
oldlabel=b"'Package source-only selection is23'";newlabel=b"'Package source-only selection is24 exact XCTest methods with16 compilation inputs plus7 controls'"
oldmethod=b"re.findall(r'func blankLoginFieldIsRequired\\s*\\(([^)]*)\\)\\s*throws', caller)"
newmethod=b"re.findall(r'func blankLoginFieldIsRequired\\s*\\(([^)]*)\\)\\s+async\\s+throws', caller)"
assert before.count(oldlabel)==before.count(oldmethod)==1
assert after==before.replace(oldlabel,newlabel).replace(oldmethod,newmethod)
compile(after,src.as_posix(),'exec')
for cmd in m['validation']:assert cmd['exitCode']==0;check(ROOT/cmd['log']['path'],cmd['log'])
for key in ['sourceBinding','execution','rawFailedLog']:check(ROOT/m['exact8dReproduction'][key]['path'],m['exact8dReproduction'][key])
check(ROOT/m['sourceBinding']['path'],m['sourceBinding'])
binding=read(ROOT/m['sourceBinding']['path'])
for r in binding['files']:
    p=src if r['path']==row['path'] else ROOT/r['path'];check(p,r)
oldbinding=read(ROOT/m['exact8dReproduction']['sourceBinding']['path']);assert oldbinding['source']=='8d934dd5311f73cddd5a88e3085f06fa15fc0ae1'
query=''.join(oldbinding['source']+':'+r['path']+'\n' for r in oldbinding['files']).encode();raw=subprocess.run([GIT,'cat-file','--batch'],cwd=ROOT,input=query,capture_output=True,check=True).stdout;cursor=0
for r in oldbinding['files']:
    end=raw.index(b'\n',cursor);h=raw[cursor:end].split();assert h[1]==b'blob';size=int(h[2]);blob=raw[end+1:end+1+size]
    assert size==r['bytes'] and hashlib.sha256(blob).hexdigest()==r['sha256'] and h[0].decode()==r['gitBlob'],r['path'];cursor=end+size+2
assert cursor==len(raw)
base=ROOT/'docs/legado-ios/evidence/sdk-8d-portable-expectations-repair';path=ROOT/'docs/legado-ios/core-sdk-8d-portable-expectations-repair.json';assert not base.exists() and not path.exists()
items={mp:'preparation.json',ROOT/row['diff']['path']:'source.diff',ROOT/m['sourceBinding']['path']:'corrected-source-binding.json',ROOT/m['exact8dReproduction']['sourceBinding']['path']:'exact8d-source-binding.json',ROOT/m['exact8dReproduction']['execution']['path']:'exact8d-execution.json',ROOT/m['exact8dReproduction']['rawFailedLog']['path']:'exact8d-core-failures.log',ROOT/'.build/integrate-reviewed-portable-expectations-repair.py':'review-and-integrate.py'}
for cmd in m['validation']:items[ROOT/cmd['log']['path']]=Path(cmd['log']['path']).name
preserved=[];normalized={}
for p,name in items.items():
    b=p.read_bytes();s=b.decode('utf-16' if b[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig');s='\n'.join(line.rstrip(' \t') for line in s.splitlines()).rstrip('\n');normalized[name]=(s+'\n' if s else '').encode()
for p,name in items.items():
    dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(normalized[name]);preserved.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst),'originalEvidence':{'path':p.relative_to(ROOT).as_posix(),**fact(p)}})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'two-precise-stale-portable-assertions-repaired-after-exact8d-local-reproduction','canonicalParent':head,'sourceFiles':m['files'],'changes':m['changes'],'review':'Root verified exact baseline/candidate/diff and only two literal replacements, current corrected source-binding and every exact8d Git blob. Matching active async method and24/16+7 workflow wording remain strict; no production/selector/budget/permission gate changes. Actual targeted2/2 and affectedPackage22/22 logs/command hashes verified without repeating them.','exact8dReproduction':m['exact8dReproduction'],'validation':m['validation'],'cloudBoundary':m['actualCloudBoundary'],'preservedEvidence':preserved,'actualNewSDKOrJNI':0,'cloudExactFailingMethodsConfirmed':False,'old8dResultUpgradedToPass':False,'newTagCreated':False,'flags':{'allNonDeviceWorkComplete':False,'automaticSelfRenewalImplemented':False,'fullLegadoCompatibilityEstablished':False,'legalRedistributionClearanceEstablished':False}}
plan_path=ROOT/'docs/legado-ios/completion-plan.json';plan=read(plan_path);cloud=plan['execution']['cloudTriggerPolicy'];assert {h['runID'] for h in cloud['onlyLiveSDKHandles']}=={39495414773,39495414820}
cloud['live8dPortableFailureRepair']={'record':path.relative_to(ROOT).as_posix(),'phaseObservedFailed':True,'exactCloudMethodsConfirmed':False,'localExact8dMethodsFailed':2,'correctedTargetedPassed':2,'affectedPackageGuardsPassed':22,'live8dSourceChanged':False}
cloud['nextPlannedCheckpoint']='Preserve only the two live8d handles until actual terminal outcomes. Its portable phase is already failed; exact8d local source reproduces two stale assertions now corrected for current async login andPackage24. This does not repair or promote the immutable8d run. Browser first slice is integrated; Await remains isolated. Finish coherent new source/rosters and actual failure repairs before any later single SDK/Native pair; no per-item or IPA tag.'
for k in record['flags']:assert plan[k] is False
(ROOT/row['path']).write_bytes(after);write(path,record);write(plan_path,plan)
paths=[ROOT/row['path'],path,plan_path]+[base/name for name in items.values()];write(STAGE/'canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**fact(p)} for p in paths]);subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'reviewedPaths':len(paths),'changedFiles':1,'preciseAssertions':2,'rootRepeatedTests':0,'newTags':0}))
