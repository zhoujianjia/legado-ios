from pathlib import Path
from datetime import datetime,timezone
import difflib,hashlib,json,shutil,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;S.mkdir(exist_ok=True);W=S/'work';B=S/'rawbaseline'
H=R/'.build/original-source-login-header-step';V=R/'.build/original-source-login-v2-browser-step';F=R/'.build/sdk-7576-native-login-fixture-repair-step'
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8',newline='\n')
parents=[];data=[]
for p,sha in [(H/'final-v1.json','3bacfc477d55578e949ae79424db4d0e31b01c6bbdc90218090e464ecd9dd4e2'),(V/'final-v1.json','8d89d80884d8cdd68c00a1b83a8bb8d51c0f3889375f08902b90e10618049d8f'),(F/'final-v1.json','3b92f35e')]:
 assert fact(p)['sha256'].startswith(sha),(p,fact(p));d=json.loads(p.read_text(encoding='utf-8'));parents.append(dict(path=str(p),**fact(p)));data.append(d)
sources={};baselines={}
for stage,d in [(H,data[0]),(V,data[1])]:
 for row in d['files']:
  rel=row['path'];p=stage/'snapshot-v1/work'/rel;assert fact(p)==row['candidate'],rel;sources.setdefault(rel,[]).append(p)
  if row['baseline'] is not None:
   b=stage/'rawbaseline'/rel;assert fact(b)==row['baseline'];assert (R/rel).read_bytes()==b.read_bytes(),rel
   if rel in baselines:assert baselines[rel].read_bytes()==b.read_bytes()
   baselines[rel]=b
  else:assert not(R/rel).exists()
assert len(sources)==10
for rel,p in baselines.items():dst=B/rel;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dst)
for rel,paths in sources.items():
 if len(paths)==1:
  dst=W/rel;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(paths[0],dst)
platform='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt'
h=(H/'snapshot-v1/work'/platform).read_text(encoding='utf-8');old='if (!task.sensitiveSourceOperation) unsupportedRule("original browser requires an explicit login task")';new='if (!task.sourceBrowserAllowed) unsupportedRule("original browser requires an explicit login task")';assert h.count(old)==1
p=W/platform;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(h.replace(old,new),encoding='utf-8',newline='\n');assert p.read_text(encoding='utf-8').replace(new,old)==h
native='Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift';f=F/'snapshot-v1'/native
if not f.exists():f=F/'snapshot-v1/work'/native
assert fact(f)==data[2]['file']['candidate'];assert fact(B/native)==data[2]['file']['baseline']
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
def funcs(b):
 tree=parser.parse(b);out={}
 def visit(n):
  assert n.type!='ERROR'and not n.is_missing,(n.type,n.start_point)
  if n.type=='function_declaration':
   name=n.child_by_field_name('name')
   if name and b[name.start_byte:name.end_byte].decode().startswith('testNative'):out[b[name.start_byte:name.end_byte].decode()]=(n.start_byte,n.end_byte,b[n.start_byte:n.end_byte])
  for c in n.children:visit(c)
 visit(tree.root_node);return out
base=(B/native).read_bytes();v=(V/'snapshot-v1/work'/native).read_bytes();hb=(H/'snapshot-v1/work'/native).read_bytes();fb=f.read_bytes();bm,vm,hm,fm=map(funcs,[base,v,hb,fb]);assert len(bm)==13 and len(vm)==14 and len(hm)==14 and len(fm)==13
rep=data[2]['changedNativeMethods'];assert len(rep)==2
for name in rep:assert bm[name][2]!=fm[name][2]
assert all(fm[n][2]==bm[n][2]for n in bm if n not in rep)
merged=v
for name in sorted(rep,key=lambda n:vm[n][0],reverse=True):a,z,_=vm[name];merged=merged[:a]+fm[name][2]+merged[z:]
newHeader=set(hm)-set(bm);assert len(newHeader)==1;headerName=next(iter(newHeader));block=b'    '+hm[headerName][2]+b'\n\n';marker=b'    func testNativeOriginalPostBrowserDisplaysPrefetchedHtmlAndReusesSingleHttpBody()';assert merged.count(marker)==1;merged=merged.replace(marker,block+marker)
p=W/native;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(merged);mm=funcs(merged);assert len(mm)==15
for name in bm:assert mm[name][2]==(fm[name][2]if name in rep else bm[name][2])
assert mm[headerName][2]==hm[headerName][2]
newV2=next(iter(set(vm)-set(bm)));assert mm[newV2][2]==vm[newV2][2]
manifest='Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads((B/manifest).read_text(encoding='utf-8'));original=json.loads((B/manifest).read_text(encoding='utf-8'));rows=[]
changed=['Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt','Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',platform]
for row in m['portedSources']:
 if row['path']in changed:row.update(fact(W/row['path']));rows.append(row['path'])
assert len(rows)==3;write(W/manifest,m);original['portedSources']=m['portedSources'];assert original==m
roster=[]
for rel in sorted(sources):
 p=W/rel;baseline=B/rel;assert p.exists();a=baseline.read_text(encoding='utf-8')if baseline.exists()else '';b=p.read_text(encoding='utf-8');diff=''.join(difflib.unified_diff(a.splitlines(True),b.splitlines(True),fromfile='a/'+rel,tofile='b/'+rel));dp=S/'diffs'/(rel+'.diff');dp.parent.mkdir(parents=True,exist_ok=True);dp.write_text(diff,encoding='utf-8',newline='\n');roster.append(dict(path=rel,baseline=fact(baseline)if baseline.exists()else None,candidate=fact(p),parents=[str(x)for x in sources[rel]],diff=dict(path=dp.relative_to(S).as_posix(),**fact(dp))))
review=R/'.build/original-source-login-header-independent-review/review-v1.json';assert fact(review)['sha256'].startswith('8f95bc')
out=dict(version=1,frozenUTC=datetime.now(timezone.utc).isoformat(),scope='Coherent Header7 + V2Browser6 + actualSDK7576 two inherited Native fixture method repairs; source composition only before shared production compile',parents=parents,headerIndependentReview=dict(path=str(review),**fact(review)),files=roster,compositions=dict(platform='Header candidate exact except one V2 browser admission gate; reversing line reproduces exact Header bytes',manifest='Baseline58 rows; only3 bytes/SHA records changed, all original/required/resources/licenses/metadata unchanged',native=dict(baselineDefinitions=13,mergedDefinitions=15,rootRepairedMethods=rep,other11OriginalMethodsByteExact=True,headerNewMethod=headerName,V2NewMethod=newV2,bothNewMethodASTBytesExact=True)),plannedAffectedJUnit=23,plannedCompile='Single K2 three-main-source compile on immutable POST91d JAR; no classfile mix',operations=dict(canonical=False,Git=False,cloud=False,tags=False),SDK='Not run; both historical7576 tasks terminal failure')
write(S/'preparation-v1.json',out);print(json.dumps(dict(path=str(S/'preparation-v1.json'),**fact(S/'preparation-v1.json'),sources=len(roster),platform=fact(W/platform),native=fact(W/native),manifest=fact(W/manifest))))
