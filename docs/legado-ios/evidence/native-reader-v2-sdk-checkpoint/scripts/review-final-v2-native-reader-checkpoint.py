from pathlib import Path
import ast
import hashlib
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True
ROOT=Path('F:/yuedu-reader')
STAGE=ROOT/'.build/consolidated-sdk-v2-native-repair-checkpoint'
READER=ROOT/'.build/ready-v2-native-reader-final-source'
OUT=STAGE/'preparation/root-final-review.json'

def fact(p):
    raw=p.read_bytes()
    return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}

def read(p):return json.loads(p.read_bytes())
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def functions(p):return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(p.read_text(encoding='utf-8-sig')).body if isinstance(n,ast.FunctionDef)}
def load(p,name):
    spec=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

assert not OUT.exists()
fp=STAGE/'preparation/final-v1.json'
check(fp,{'bytes':19814,'sha256':'2f1a17e2a176a0021bf81ca9db069a9b4f535cf9154c346efffdea1e4dbef1fe'})
rp=ROOT/'.build/native-210-reader-independent-review/review-v2.json'
check(rp,{'bytes':18671,'sha256':'56ffe1b7aafa37b44582fb0707923fa99476e0221cae09ca526eb9c476856424'})
assert read(rp)['findings']==[]
m=read(fp);reader=read(READER/'preparation-v1.json');fixed=read(STAGE/'preparation/fixed-v1.json')
sources={}
for stage,rows in [(READER,reader['files']),(STAGE,m['files'])]:
    for row in rows:
        path=row['path'];check(stage/'work'/path,row['candidate']);check(ROOT/path,row['baseline'])
        check(ROOT/row['diff']['path'],row['diff'])
        sources[path]=(stage/'work'/path).read_bytes()
assert len(sources)==13 and sum(r['changed'] for r in m['files'])==8
for row in m['evidence']:check(ROOT/row['path'],row)
ported=json.loads(sources['Packages/LegadoRuntime/vendor/original-rule/manifest.json'])
assert len(ported['portedSources'])==58
for row in ported['portedSources']:
    raw=sources.get(row['path'],(ROOT/row['path']).read_bytes())
    assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
rosters={};union={}
for name,count in [('core',330),('Native',131),('Package',23)]:
    binding=m['sourceClosure'][name];check(ROOT/binding['path'],binding);rows=read(ROOT/binding['path'])
    assert len(rows)==len({r['path'] for r in rows})==count
    for row in rows:
        path=row['path'];raw=sources.get(path,(ROOT/path).read_bytes());actual={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
        assert actual=={k:row[k] for k in ('bytes','sha256')},path
        if path in union:assert union[path]==actual
        union[path]=actual
    rosters[name]={r['path'] for r in rows}
assert len(union)==348 and len(set(union)-{r['path'] for r in m['files']})==339
owners=m['sourceClosure']['productionOwners'];assert len(owners)==24
for row in owners:
    assert row['path'] in union
    assert {k:row[k] for k in ('bytes','sha256')}==union[row['path']]
assert all(p in rosters['core'] and p in rosters['Native'] for p in [r['path'] for r in reader['files']])
for relative in ['scripts/reader-experience/renewal-probe-tools.py','scripts/reader-experience/native-smoke-tools.py']:
    assert functions(STAGE/'history/fixed-v1/work'/relative)==functions(STAGE/'work'/relative),relative
for row in fixed['files']:
    check(STAGE/'history/fixed-v1/work'/row['path'],row['candidate'])
native='scripts/reader-experience/native-smoke-tools.py'
assert functions(STAGE/'work'/native)==functions(ROOT/'.build/native-210-count-gate-repair-step/work'/native)
core='scripts/reader-experience/renewal-probe-tools.py'
oldfunctions=functions(ROOT/core);newfunctions=functions(STAGE/'work'/core)
assert [k for k in oldfunctions if oldfunctions[k]!=newfunctions[k]]==['result']
oldtext=(ROOT/core).read_text(encoding='utf-8-sig');newtext=(STAGE/'work'/core).read_text(encoding='utf-8-sig')
def function(text,name):return ast.get_source_segment(text,next(n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name==name))
assert function(oldtext,'result').replace('SwiftPM deltareuse selection is23 methods with15 actual compilation inputs plus7 controls','SwiftPM loginv2 selection is24 methods with16 actual compilation inputs plus7 controls').replace('historical10/default16/publicbatch17/effects18/loginui22 modes','historical10/default16/publicbatch17/effects18/loginui22/deltareuse23 modes')==function(newtext,'result')
valid=STAGE/'validation-root'
core_old=load(ROOT/core,'rootOldCore')
core_new=load(valid/core,'rootNewCore')
native_new=load(valid/native,'rootNewNative')
api='scripts/reader-experience/original-api-package-tools.py'
api_old=load(ROOT/api,'rootOldAPI');api_new=load(valid/api,'rootNewAPI')
assert core_old.EXPECTED_CASES==core_new.EXPECTED_CASES
assert len(core_new.EXPECTED_CASES['currentcore'])==463 and core_new.expected_leaf_count('currentcore')==466
assert set(core_new.SOURCE_INPUTS)==rosters['core'] and set(native_new.SOURCE_INPUTS)==rosters['Native'] and set(api_new.SOURCE_INPUTS)==rosters['Package']
for name in vars(api_old):
    if name.endswith('_EXPECTED') or name=='EXPECTED':assert getattr(api_old,name)==getattr(api_new,name),name
assert len(api_new.LOGINV2_EXPECTED)==24 and api_new.LOGINV2_EXPECTED==api_new.DELTAREUSE_EXPECTED|api_new.LOGINV2_EXTRA
native_old=load(ROOT/native,'rootOldNative')
assert native_new.NATIVE_GROUPS['mainjs']==native_old.NATIVE_GROUPS['mainjs']
oldorig=native_old.NATIVE_GROUPS['original']['methods'];neworig=native_new.NATIVE_GROUPS['original']['methods']
assert len(oldorig)==20 and len(neworig)==21 and set(oldorig)<set(neworig)
assert set(neworig)-set(oldorig)=={m['selections']['newNative']}
assert m['actualPortableValidation']['newBindingGuard']['exitCode']==0
check(ROOT/m['actualPortableValidation']['newBindingGuard']['log']['path'],m['actualPortableValidation']['newBindingGuard']['log'])
assert m['exactCounts']=={'AppDefinitions':463,'AppLeaves':466,'coreInputs':330,'NativeOriginalDefinitions':21,'NativeMainJSDefinitions':1,'nativeInputs':131,'PackageMethods':24,'PackageCompileInputs':16,'PackageControls':7,'PackageAllInputs':23}
record={'schemaVersion':1,'status':'root-independent-final13-source-and-coherent-controls-approved-fresh-combined-execution-required','reviewedManifest':{'path':fp.relative_to(ROOT).as_posix(),**fact(fp)},'reviewedReader':{'path':rp.relative_to(ROOT).as_posix(),**fact(rp)},'sourceFiles':13,'changedSourceFiles':12,'portedSources':58,'verifiedUniqueSourceInputs':348,'nonControlInputs':339,'productionOwners':24,'counts':m['exactCounts'],'checks':['Exact baselines,13 candidates and all source/diff/evidence hashes verified against canonical8ce and final Reader58 row merge.','All330/131/23 source rosters verified against the final13 overlays plus unchanged canonical bytes.','All old App mode identities unchanged,463 definitions/466 leaves retained; Native old20 plus one V2 and independentMainJS1 retained.','All existing core producer,fixture,phase,selector,timeout and command functions unchanged; result differs only in reviewed Package limitations strings.','All Native functions exactly equal independently reviewed strict countgate3; fresh local-product50/68 and cache6/8 gates remain in required final status.','Old Package expected sets unchanged; new explicit loginv2 adds only its one typed request method; closure16+7 verified.','Reader metadata restore retains inlineTOC attributes while explicit current/foreign chapter variable restore still uses the existing authorization owner.'], 'validationReuse':{'fixedPortableMethodExecutions':7,'ReaderRebindingMethodExecutions':1,'distinctMethods':7,'ReaderIncrementalDistinctJVMPassed':3,'ReaderBaselineCounterfactualFailedAsExpected':1,'ReaderOutsideJavaSessions':3,'ReaderPackagingGuards':6,'rootRepeatedTests':0,'actualNewSDKorJNI':0},'findings':[],'limits':['Fresh combined V2+Reader production JAR,Swift compilation,JNI and required selected methods have not executed.','Browser remains excluded; no device package tag or acceptance.']}
record['reviewPreparationHistory']={'initialAttempt':'Read-only source review stopped on KeyError after assuming the Native selection key was cases. Corrected to the actual existing methods key; no production changes, test commands, cloud actions or output review occurred in that failed attempt.'}
OUT.write_bytes((json.dumps(record,ensure_ascii=False,indent=2)+'\n').encode())
print(json.dumps({'review':fact(OUT),'counts':m['exactCounts'],'findings':0,'repeatedTests':0}))
