from pathlib import Path
import ast,hashlib,importlib.util,json,sys,xml.etree.ElementTree as ET
sys.dont_write_bytecode=True
ROOT=Path('F:/yuedu-reader');STAGE=ROOT/'.build/consolidated-sdk-browser-start-checkpoint';SOURCE=ROOT/'.build/ready-browser-host-final-source'
OUT=STAGE/'preparation/root-review.json'
def read(p):return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def funcs(p):return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(p.read_text(encoding='utf-8-sig')).body if isinstance(n,ast.FunctionDef)}
def load(p,name):
    s=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
assert not OUT.exists()
mp=STAGE/'preparation/final-v1.json';check(mp,{'bytes':17220,'sha256':'74c16d29a43f2624864d2b10b5e5578debd72802630623c72815aca515a59204'})
m=read(mp);production=read(SOURCE/'preparation-v1.json');assert m['productionSources']==production['files']
for row in m['evidence']+[m['productionCompositionReview']]+m['sourceReviews']:check(ROOT/row['path'],row)
sources={}
for stage,rows in [(SOURCE,m['productionSources']),(STAGE,m['files'])]:
    for row in rows:
        path=row['path'];check(stage/'work'/path,row['candidate'])
        if row['baseline'] is None:assert not (ROOT/path).exists()
        else:check(ROOT/path,row['baseline'])
        check(ROOT/row['diff']['path'],row['diff']);sources[path]=(stage/'work'/path).read_bytes()
assert len(sources)==16 and len(m['files'])==5
for p in ['scripts/reader-experience/native-smoke-tools.py','scripts/reader-experience/renewal-probe-tools.py']:assert funcs(ROOT/p)==funcs(STAGE/'work'/p)
union={};rosters={}
for name,count in [('core',332),('Native',134),('Package',23)]:
    r=m['sourceRosters'][name];check(ROOT/r['path'],r);rows=read(ROOT/r['path']);assert len(rows)==len({x['path'] for x in rows})==count
    rosters[name]={x['path'] for x in rows}
    for x in rows:
        raw=sources[x['path']] if x['path'] in sources else (ROOT/x['path']).read_bytes();v={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()};assert v=={k:x[k] for k in ('bytes','sha256')},x['path']
        if x['path'] in union:assert union[x['path']]==v
        union[x['path']]=v
assert len(union)==350
valid=STAGE/'validation-root';core='scripts/reader-experience/renewal-probe-tools.py';native='scripts/reader-experience/native-smoke-tools.py'
old=load(ROOT/core,'browserRootOldCore');new=load(valid/core,'browserRootNewCore');assert old.EXPECTED_CASES==new.EXPECTED_CASES
assert len(new.EXPECTED_CASES['currentcore'])==463 and new.expected_leaf_count('currentcore')==466 and set(new.SOURCE_INPUTS)==rosters['core']
oldn=load(ROOT/native,'browserRootOldNative');newn=load(valid/native,'browserRootNewNative')
assert oldn.NATIVE_GROUPS['mainjs']==newn.NATIVE_GROUPS['mainjs'] and set(newn.SOURCE_INPUTS)==rosters['Native']
a,b=oldn.NATIVE_GROUPS['original'],newn.NATIVE_GROUPS['original'];assert {k:v for k,v in a.items() if k!='methods'}=={k:v for k,v in b.items() if k!='methods'}
assert len(a['methods'])==21 and len(b['methods'])==22 and b['methods'][:-1]==a['methods'] and b['methods'][-1]==m['newNativeSelector']
ported='Packages/LegadoRuntime/vendor/original-rule/manifest.json';before=read(ROOT/ported);after=json.loads(sources[ported]);assert len(after['portedSources'])==58
assert sum(a!=b for a,b in zip(before['portedSources'],after['portedSources']))==4
for row in after['portedSources']:
    raw=sources[row['path']] if row['path'] in sources else (ROOT/row['path']).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
auth=ROOT/'.build/original-source-login-browser-host-step';manifest=read(auth/'final-v1.json')
for row in manifest['evidence']:check(auth/row['path'],row)
xml=ET.parse(auth/'execution-v1/actual-tests.xml').getroot();cases=xml.findall('testcase');assert len(cases)==int(xml.attrib['tests'])==4
assert len({c.attrib['name'] for c in cases})==4 and all(int(xml.attrib[k])==0 for k in ('failures','errors','skipped'))
assert not xml.findall('.//failure')+xml.findall('.//error')+xml.findall('.//skipped')
for command in m['actualPortableGuards']['commands']:assert command['exitCode']==0;check(ROOT/command['log']['path'],command['log'])
record={'schemaVersion':1,'status':'root-independent-Browser-first-slice16-source-next-controls-approved-current8d-execution-unchanged','manifest':{'path':mp.relative_to(ROOT).as_posix(),**fact(mp)},'sourceInputsVerified':350,'sourceFiles':16,'changedSources':14,'counts':m['counts'],'findings':[],'checks':['All16 baselines/candidates/diffs and full350 unique332/134/23 input byte bindings verified.','All core/Native functions unchanged from8d; original21 method tuple retained in order with only the one actual Browser method appended, preserving original1800/MainJS2700 budgets.','All prior App modes and463/466 identities retained; required same-job fixture and Package24/23 inputs unchanged.','Exact current58 manifest four-row composition retains Reader repair and original metadata; every ported production source hash verified.','Source and incremental runtime independent reviews verified at fixed hashes; actual4-method XML is unique with zero failures/errors/skips.','Three affected portable guards passed before freeze; no tests rerun byroot.'],'validationLimits':['Incremental ordinaryBrowser payload is346 classes bound to standaloneV2, including25 recompiled and321 retained; it does not establish a fresh combinedReader payload.','Java5 sessions use synthetic Host presentation ACK; actual SDK/JNI/UIKit remains0. Native definition is selected for a later real run.','Only nonawait legacy GET browser first slice. Await,POST,WebJS and further original Browser behaviors remain incomplete.','Current live8d cloud pair stays immutable; no new tag or device package.'],'repeatedTests':0,'actualSDKOrJNI':0}
record['reviewHistory']='Initial read-only attempt eagerly evaluated a dict.get default for the new, intentionally not-yet-canonical Browser test file. Corrected to conditional overlay lookup; no source/test/cloud operation or approved-review output occurred in that attempt.'
OUT.write_bytes((json.dumps(record,ensure_ascii=False,indent=2)+'\n').encode())
print(json.dumps({'review':fact(OUT),'sourceFiles':16,'changedSources':14,'uniqueInputs':350,'findings':0}))
