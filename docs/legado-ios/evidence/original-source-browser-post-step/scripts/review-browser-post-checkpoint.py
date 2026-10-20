from pathlib import Path
import ast,hashlib,importlib.util,json,sys,xml.etree.ElementTree as ET
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=R/'.build/consolidated-sdk-browser-post-checkpoint';SOURCE=R/'.build/ready-browser-post-source';A=R/'.build/original-source-login-browser-post-step';O=S/'preparation/root-review-v1.json'
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def funcs(p):return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(p.read_text(encoding='utf-8-sig')).body if isinstance(n,ast.FunctionDef)}
def load(p,name):
 spec=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
assert not O.exists();mp=S/'preparation/final-v1.json';check(mp,{'bytes':16508,'sha256':'40265a217567e0972c6e468ce3c7780f013123a46fd41a6cd4a515172b4e54b2'});m=read(mp)
check(R/m['sourceComposition']['path'],m['sourceComposition']);composition=read(R/m['sourceComposition']['path']);assert [(x['path'],x['candidate']) for x in m['productionSources']]==[(x['path'],x['candidate']) for x in composition['files']];check(R/m['sourceIndependentReview']['path'],m['sourceIndependentReview'])
for r in m['evidence']:check(R/r['path'],r)
sources={}
for stage,rows in [(SOURCE,composition['files']),(S,m['files'])]:
 for row in rows:
  p=row['path'];check(stage/'work'/p,row['candidate']);check((R if row['diff']['path'].startswith('.build/') else A)/row['diff']['path'],row['diff'])
  if row['baseline'] is None:assert not (R/p).exists()
  else:check(R/p,row['baseline'])
  assert p not in sources;sources[p]=(stage/'work'/p).read_bytes()
assert len(sources)==14 and len(m['files'])==5
for row in m['productionSources']:check(R/row['snapshot']['path'],row['candidate']);assert (R/row['snapshot']['path']).read_bytes()==sources[row['path']]
for p in ['scripts/reader-experience/native-smoke-tools.py','scripts/reader-experience/renewal-probe-tools.py']:assert funcs(R/p)==funcs(S/'work'/p)
union={};rosters={}
for name,count in [('core',335),('Native',137),('Package',23)]:
 r=m['sourceRosters'][name];check(R/r['path'],r);rows=read(R/r['path']);assert len(rows)==len({x['path'] for x in rows})==count;rosters[name]={x['path'] for x in rows}
 for x in rows:
  raw=sources[x['path']] if x['path'] in sources else (R/x['path']).read_bytes();v={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()};assert v=={k:x[k] for k in ('bytes','sha256')},x['path']
  if x['path'] in union:assert union[x['path']]==v
  union[x['path']]=v
assert len(union)==353
v=S/'validation-root';core='scripts/reader-experience/renewal-probe-tools.py';native='scripts/reader-experience/native-smoke-tools.py';old=load(R/core,'postRootOldCore');new=load(v/core,'postRootNewCore');assert old.EXPECTED_CASES==new.EXPECTED_CASES and old.parameter_cases('currentcore')==new.parameter_cases('currentcore')
assert len(new.EXPECTED_CASES['currentcore'])==463 and new.expected_leaf_count('currentcore')==466 and len(new.parameter_cases('currentcore'))==3 and set(new.SOURCE_INPUTS)==rosters['core']
oldn=load(R/native,'postRootOldNative');newn=load(v/native,'postRootNewNative');assert oldn.NATIVE_GROUPS['mainjs']==newn.NATIVE_GROUPS['mainjs'] and set(newn.SOURCE_INPUTS)==rosters['Native']
a,b=oldn.NATIVE_GROUPS['original'],newn.NATIVE_GROUPS['original'];assert {k:v for k,v in a.items() if k!='methods'}=={k:v for k,v in b.items() if k!='methods'};assert len(a['methods'])==23 and len(b['methods'])==24 and b['methods'][:-1]==a['methods'] and b['methods'][-1]==m['newNativeSelector']
wf='.github/workflows/legado-native-reader-test.yml';assert sources[wf].decode()==(R/wf).read_text(encoding='utf-8').replace('Execute1 MainJS and23 original methods','Execute1 MainJS and24 original methods')
ported='Packages/LegadoRuntime/vendor/original-rule/manifest.json';before=read(R/ported);after=json.loads(sources[ported]);assert len(after['portedSources'])==58 and sum(a!=b for a,b in zip(before['portedSources'],after['portedSources']))==1
for row in after['portedSources']:
 raw=sources[row['path']] if row['path'] in sources else (R/row['path']).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
for p in ['.build/sdk-8d-login-ui-form-typecheck-repair-step/final-v1.json','.build/native-8d-external-open-repair-step/final-v1.json']:
 fix=read(R/p)['file'];check(R/fix['path'],fix['candidate'])
for command in m['actualPortableGuards']['commands']:assert command['exitCode']==0;check(R/command['log']['path'],command['log'])
assert m['actualPortableGuards']['distinctMethods']==4 and m['actualPortableGuards']['executions']==4
testsource=sources['scripts/reader-experience/test-native-smoke-tools.py'].decode();assert 'self.assertEqual(result["originalReaderTests"]["expectedTests"], 24)' in testsource and 'self.assertEqual(result["originalReaderTests"]["expectedTests"], 22)' not in testsource
author=read(A/'final-v2.json')
for row in author['evidence']:check(A/row['path'],row)
xmls=[A/r['path'] for r in author['evidence'] if r['path'].endswith('.xml')];assert len(xmls)==1
xml=ET.parse(xmls[0]).getroot();cases=xml.findall('testcase');assert len(cases)==int(xml.attrib['tests'])==12 and len({(c.attrib['classname'],c.attrib['name']) for c in cases})==12 and not xml.findall('.//failure')+xml.findall('.//error')+xml.findall('.//skipped')
record={'schemaVersion':1,'status':'root-independent-POST9-plus-actual-Native-stale-guard-repair5-controls-approved','manifest':{'path':mp.relative_to(R).as_posix(),**fact(mp)},'sourceInputsVerified':353,'sourceFiles':14,'changedSources':14,'counts':m['counts'],'findings':[],'checks':['All14 source/control candidates/baselines/diffs and353 unique335/137/23 bindings verified.','Every core/Native production function AST unchanged; old23 Native methods retained in order, only approvedPOST selector appended, budgets/requiredNative flags/phase-exit-source gates preserved.','All App modes/463definitions/466leaves/threeBoolpairs unchanged; Package24/23inputs remain exact.','Actual7576 failed stale assertion22 migrates strictly to future actual24; no result verifier or failure requirement weakened. Exact current source local23!=22 reproduction remains historical failure.','All58 ported rows hash-match candidate/current source, precisely onePlatform row changed; both8d compiler repairs remain exact inherited source.','POSTv2 independent source review and XML12 unique cases verified; affected four portable guards actually passed once, no old passing suites repeated.'],'validationLimits':['POST ordinary JAR evidence is1-source incremental K2 plus bound classes, not freshGradle.','Native7576 ended beforeGradle; its JVM/App/Native executed0 cannot accept this changed successor.','Current SDK7576 is separate immutable source; no polling or acceptance inferred here.','Swift SDK/JNI/UIKit/device actual0 for POST; full browser/source compatibility and automatic renewal remain unfinished.'],'repeatedTests':0,'actualSDKOrJNI':0}
O.write_bytes((json.dumps(record,ensure_ascii=False,indent=2)+'\n').encode());print(json.dumps({'review':fact(O),'sourceFiles':14,'uniqueInputs':353,'findings':0}))
