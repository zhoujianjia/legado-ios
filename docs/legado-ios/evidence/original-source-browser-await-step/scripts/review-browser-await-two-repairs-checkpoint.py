from pathlib import Path
import hashlib,json,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=R/'.build/consolidated-sdk-browser-await-two-repairs-checkpoint';P=R/'.build/consolidated-sdk-browser-await-checkpoint';SOURCE=R/'.build/ready-browser-await-two-compiler-repairs-source'
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
out=S/'preparation/root-review-v1.json';assert not out.exists()
mp=S/'preparation/final-v3.json';check(mp,{'bytes':26668,'sha256':'5b106d7e368ffd477c748dab14c24b5eae51a59ff1d2b2b8b9da185bc95c7d6f'});m=read(mp)
previous=P/'preparation/final-v2.json';check(previous,{'bytes':21374,'sha256':'69569742869c0ebeee765b0f8f08f67166a770875b585a767c31825a8c923330'});old=read(previous)
pr=P/'preparation/root-review-v2.json';check(pr,{'bytes':2270,'sha256':'86ae4801d24667d85e60745e7c23e833b995e2cae7a04e8337cf35a895cc4888'});assert read(pr)['findings']==[]
check(R/m['productionComposition']['path'],m['productionComposition']);composition=read(R/m['productionComposition']['path']);assert m['productionSources']==composition['files']
for row in m['productionIndependentReviews']+m['evidence']:check(R/row['path'],row)
assert len(m['files'])==5 and len(m['productionSources'])==16
sources={}
for stage,rows in [(SOURCE,m['productionSources']),(S,m['files'])]:
 for row in rows:
  p=row['path'];check(stage/'work'/p,row['candidate']);check(R/row['diff']['path'],row['diff'])
  if row['baseline'] is None:assert not (R/p).exists()
  else:check(R/p,row['baseline'])
  assert p not in sources;sources[p]=(stage/'work'/p).read_bytes()
assert len(sources)==21
for a,b in zip(old['files'],m['files']):
 assert a['path']==b['path'] and a['baseline']==b['baseline'] and a['candidate']==b['candidate'];assert (P/'work'/a['path']).read_bytes()==sources[b['path']]
for k,v in old['counts'].items():
 if k!='noncandidateUnchangedCanonicalInputs':assert m['counts'][k]==v
union={};oldunion={}
for name,count in [('core',334),('Native',136),('Package',23)]:
 r=m['sourceRosters'][name];check(R/r['path'],r);rows=read(R/r['path']);assert len(rows)==len({x['path'] for x in rows})==count
 for x in rows:
  raw=sources[x['path']] if x['path'] in sources else (R/x['path']).read_bytes();f={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()};assert f=={k:x[k] for k in ('bytes','sha256')},x['path']
  if x['path'] in union:assert union[x['path']]==f
  union[x['path']]=f
 for x in read(R/old['sourceRosters'][name]['path']):oldunion[x['path']]={k:x[k] for k in ('bytes','sha256')}
assert len(union)==len(oldunion)==352 and union.keys()==oldunion.keys()
delta=[p for p in union if union[p]!=oldunion[p]];assert delta==['Modules/Features/BookSource/BookSourceFormLoginView.swift']
assert m['sourceRosters']['Package']['sha256']==old['sourceRosters']['Package']['sha256']
assert m['portableEvidenceReuse']['records']==old['actualPortableGuards']['commands']
for c in m['portableEvidenceReuse']['records']:check(R/c['log']['path'],c['log'])
record={'schemaVersion':1,'status':'root-independent-Await-plus-both-actual-compiler-repairs21-source-controls-approved','manifest':{'path':mp.relative_to(R).as_posix(),**fact(mp)},'sourceInputsVerified':352,'sourceFiles':21,'changedSources':18,'counts':m['counts'],'findings':[],'checks':['All21 exact candidate/baseline/diff bindings and reviewed16-source composition verified.','All5 control candidate/baseline bytes equal root-approved v2; all selectors, App modes/463-466/threeBoolpairs, required fixture, budgets, source/phase/exit gates inherit unchanged approved ASTs.','All352 raw core334/Native136/Package23 bindings rebuilt; exactly one existing View source fact differs from previous352. Package23 roster is byte-identical.','The only extra source change is the independently approved actualNative8d overload call fix; actualSDK8d typed-array repair and Await sources keep their reviewed bytes.','Prior core2pass/Native initial1fail-repaired1pass logs and argv verified, accurately reused only for unchanged control behaviors.'],'validationLimits':['This review executes no tests, Swift compiler, SDK, JNI, UIKit or device. New Native realWK method remains unexecuted.','Two actual8d compiler failures and portable assertions are accounted for by reviewed repairs, not retroactively changed historical runs.','JVM8/ordinaryJava5 and Package24 retain their stated source-only/incremental boundaries; full source compatibility and automatic renewal remain incomplete.'],'repeatedTests':0,'actualSDKOrJNI':0}
write(out,record);write(S/'preparation/root-approved-facts.json',{'manifest':fact(mp),'review':fact(out)})
print(json.dumps({'review':fact(out),'sourceFiles':21,'changedSources':18,'uniqueInputs':352,'findings':0}))
