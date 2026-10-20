from pathlib import Path
import hashlib
import json
import subprocess

ROOT=Path('F:/yuedu-reader')
STAGE=ROOT/'.build/consolidated-sdk-v2-native-repair-checkpoint'
READER=ROOT/'.build/native-210-reader-repair-step'
COMPOSE=ROOT/'.build/ready-v2-native-reader-final-source'
COUNT=ROOT/'.build/native-210-count-gate-repair-step'
GIT='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']

def read(p):return json.loads(p.read_bytes())
def fact(p):
    raw=p.read_bytes();return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())

status=subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines()
assert all(line in ('?? debug.log','?? docs/legado-ios/evidence/native-reader-v2-sdk-checkpoint/') for line in status),status
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip()
assert head=='8cebe2023d0f3b9b3d8143d964b0c9bb2a6e7978'
mp=STAGE/'preparation/final-v1.json';rp=STAGE/'preparation/root-final-review.json'
check(mp,{'bytes':19814,'sha256':'2f1a17e2a176a0021bf81ca9db069a9b4f535cf9154c346efffdea1e4dbef1fe'})
check(rp,{'bytes':2914,'sha256':'b9d5f6b2bf439396a820ef3c06f0e2e4e89ab5adb852c20427307ee77cfbbd91'})
m,review,reader,composition=read(mp),read(rp),read(READER/'final-v1.json'),read(COMPOSE/'preparation-v1.json')
assert review['findings']==[] and review['counts']==m['exactCounts']
sources={};source_rows=[]
for stage,rows in [(COMPOSE,composition['files']),(STAGE,m['files'])]:
    for row in rows:
        path=row['path'];check(stage/'work'/path,row['candidate']);check(ROOT/path,row['baseline'])
        check(ROOT/row['diff']['path'],row['diff'])
        sources[path]=(stage/'work'/path).read_bytes();source_rows.append(row)
assert len(sources)==13 and len(source_rows)==13
base=ROOT/'docs/legado-ios/evidence/native-reader-v2-sdk-checkpoint'
record_path=ROOT/'docs/legado-ios/core-native-reader-v2-sdk-checkpoint.json'
assert not record_path.exists()
items={}
def add(src,name,expected=None):
    assert src.is_file(),str(src)
    if expected:check(src,expected)
    if name in items:assert items[name]==src
    else:items[name]=src
for src,name in [(mp,'unified-preparation.json'),(rp,'root-final-review.json'),(READER/'final-v1.json','Reader/preparation.json'),(COMPOSE/'preparation-v1.json','Reader/root58-composition.json'),(ROOT/'.build/native-210-reader-independent-review/review-v2.json','Reader/independent-review.json'),(COUNT/'preparation/final-v1.json','countgate/preparation.json'),(COUNT/'preparation/root-review.json','countgate/root-review.json')]:add(src,name)
for row in reader['evidence']:add(READER/row['path'],'Reader/'+row['path'],row)
for row in m['evidence']:add(ROOT/row['path'],'controls/'+row['path'].removeprefix('.build/'),row)
for row in read(COUNT/'preparation/final-v1.json')['evidence']:add(ROOT/row['path'],'countgate/'+Path(row['path']).name,row)
for stage,rows,label in [(COMPOSE,composition['files'],'Reader'),(STAGE,m['files'],'controls')]:
    for row in rows:add(ROOT/row['diff']['path'],label+'/diffs/'+row['path']+'.diff',row['diff'])
for name in ['compose-ready-v2-native-reader-final-source.py','review-final-v2-native-reader-checkpoint.py','integrate-final-v2-native-reader-checkpoint.py']:add(ROOT/'.build'/name,'scripts/'+name)
preserved=[]
expected_destinations={base/name for name in items}
if base.exists():assert all(p in expected_destinations for p in base.rglob('*') if p.is_file()),'Unexpected partial archive file'
for name,src in items.items():
    raw=src.read_bytes();encoding='utf-16' if raw[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig'
    if src in (READER/'incremental/history/attempt1/junit-selected.log',READER/'incremental/junit-selected.log'):
        encoding='gb18030'
        assert raw.decode(encoding).encode(encoding)==raw and raw.decode(encoding).count('\u3000')==8
    text=raw.decode(encoding)
    normalized='\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n')
    dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);output=(normalized+'\n' if normalized else '').encode()
    if dst.exists():assert dst.read_bytes()==output,'Unexpected previous archive bytes: '+str(dst)
    else:dst.write_bytes(output)
    preserved.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst),'originalEvidence':{'path':src.relative_to(ROOT).as_posix(),**fact(src)},'originalEncoding':encoding,'normalization':'BOM-aware UTF8/LF with exact round-trip GB18030 decoding for the two Windows JUnit console logs; trailing horizontal/empty EOF whitespace removed; original exact byte facts retained'})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'reviewed-Native210-production-and-fixture-repairs-integrated-with-ready-V2-one-unified-cohort-pending','reviewedCanonicalParent':head,'sourceFiles':source_rows,'changedSourceFiles':12,'retainedControlShell':1,'sourceOwnerUnion':m['sourceClosure']['productionOwners'],'counts':m['exactCounts'],'uniqueSourceInputs':348,'nonControlInputs':339,'ReaderRootCausesAndFixes':reader['rootCauses'],'ReaderValidation':reader['validation'],'controlsValidation':m['actualPortableValidation'],'failClosedInvariants':m['failClosedInvariants'],'review':review,'preservedEvidence':preserved,'productionOwnerRecord':'docs/legado-ios/core-original-source-login-v2-step.json','terminalNativeRecord':'docs/legado-ios/core-native-210fb05-terminal-result.json','terminalSDKRecord':'docs/legado-ios/core-sdk-210fb05-terminal-result.json','scope':'Ready V2 and single-process login/accepted-effect ordering are canonical8ce; this checkpoint adds actual cold TOC metadata authorization repair, exact Native HTTP/HTML/InfoMap fixture corrections, required real local/cache result gates and final exact source inventories.','cohortPolicy':'Submit exactly one reader-renewal and one legado-native-reader-test tag at the immutable next reviewed Git commit. App463 definitions/466 execution leaves in one required cold invocation, Native21 original and separateMainJS1, fresh explicit independent Package loginv224. All old mode sets and mandatory SDK-produced fixture remain; no IPA tag.','limits':['The Reader337-class incremental f1 payload and V2 standalone346-class44 payload validate their own source closures. Neither is a fresh combined payload; the next cloud producer must freshly compile the combined source.','Reader3 distinct JVM methods finally passed via initial2pass/1fail then only corrected1pass, with baseline foreign-grant counterfactual and ordinary3-session/2HTTP checks. No claim of a fresh full Gradle or actual repaired Native run.','Browser host work is independently staged and excluded from this cohort. Full source compatibility, account authority, authenticated installation, expiry extension, relaunch and data retention remain incomplete.'],'deliveredBuild14Unchanged':True,'newCloudTagsYet':False,'untrackedDebugLogUntouched':True,**{k:False for k in FLAGS}}
plan_path=ROOT/'docs/legado-ios/completion-plan.json';plan=read(plan_path);cloud=plan['execution']['cloudTriggerPolicy']
record['integrationHistory']={'initialAttempt':'Stopped during archive decoding at the first of two GB18030 JUnit console logs. No production/control source, plan or final record had been written. Existing partial UTF8 evidence files were revalidated byte-for-byte before resuming.','encodingCorrection':'Both exact known console logs round-trip through GB18030 and each preserves eight U+3000 characters; no replacement decoding or dropped text.'}
assert cloud['onlyLiveSDKHandles']==[] and all(plan[k] is False for k in FLAGS)
plan['activeBatchRecord']=record_path.relative_to(ROOT).as_posix()
steps=plan['execution']['stepByStep']
steps['native210ProductionFixtureAndGateRepairs']={'record':record_path.relative_to(ROOT).as_posix(),'sourceReviewApproved':True,'actualReaderIncrementalDistinctJVMPassed':3,'outsideJavaSessions':3,'sameOwnerGrantRetained':True,'freshCombinedSDKOrJNIYet':False}
steps['queuedReadyProductionForNextUnifiedCheckpoint']={'record':record_path.relative_to(ROOT).as_posix(),**m['exactCounts'],'sourceCountsPendingNativeReaderAndControls':False,'actualAcceptancePending':True,'BrowserIncluded':False}
for step_id in ['C2','C3']:
    step=next(s for s in steps['steps'] if s['id']==step_id)
    step['implementationEvidence'].append({'record':record_path.relative_to(ROOT).as_posix(),'scope':'Actual Native210 failures repaired at the production cold TOC metadata boundary and real Native fixtures; exact grants/current variables preserved. Final App/Native/Package source closure reviewed, fresh combined SDK/JNI pending.'})
cloud['nextPlannedCheckpoint']='Final reviewed V2 plus Native210 production/fixture/countgate repairs are ready: App463/466 and330 inputs, Native21+separateMainJS1 and131 inputs, fresh explicit independent Package loginv224 and23 inputs. Submit one immutable source tag pair, retain every required phase and signer fixture, and record only newly created actual handles. Browser and new IPA excluded; terminal210 jobs remain archived and are not repolled.'
for path,raw in sources.items():
    dst=ROOT/path;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(raw)
write(record_path,record);write(plan_path,plan)
paths=[ROOT/r['path'] for r in source_rows if r.get('changed',True)]+[base/name for name in items]+[record_path,plan_path]
assert len(paths)==len(set(paths))
write(STAGE/'canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**fact(p)} for p in paths])
subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'reviewedPaths':len(paths),'changedSources':12,'boundSourceUnion':348,'counts':m['exactCounts'],'newTags':0}))
