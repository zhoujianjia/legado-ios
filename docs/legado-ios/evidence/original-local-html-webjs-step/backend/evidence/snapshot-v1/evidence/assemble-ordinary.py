from pathlib import Path
import ast,hashlib,json,struct,zipfile
R=Path('F:/yuedu-reader'); S=Path(__file__).parent; W=S/'work'; B=S/'rawbaseline'; E=S/'ordinary-v2'; E.mkdir(exist_ok=False)
base=R/'.build/consolidated-header-v2-browser-source-step/snapshot-v1/legado-runtime.jar'
classes=S/'compile-attempt3/classes'
def fact(p):
 b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def hashed(b):return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
assert fact(base)['sha256']=='df6f572adfd6c18ca67d98573be86dcf9e65f0c0d8b603eae60f054e8c29eac3'
compiled=json.loads((S/'compile-attempt3/commands.json').read_text());assert compiled['exitCode']==0
sources={p.relative_to(W).as_posix():p for p in W.rglob('*.kt')};assert len(sources)==7
for row in compiled['sources']:assert fact(Path(row['path']))=={k:row[k]for k in ('bytes','sha256')}
manifest=W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
m=json.loads((B/manifest.relative_to(W)).read_text(encoding='utf-8'))
seen=set()
for row in m['portedSources']:
 if row['path']in sources:row.update(fact(sources[row['path']]));seen.add(row['path'])
assert len(seen)==6
newpath=next(p for p in sources if p not in seen)
m['portedSources'].append(dict(path=newpath,**fact(sources[newpath])))
assert len(m['portedSources'])==59
write(manifest,m)
prior=json.loads((R/'.build/consolidated-header-v2-browser-source-step/actual-jvm-compilation-inputs.json').read_text())['inputs']
inputs=[]
for row in prior:
 p=B/row['path'] if row['path']in sources else R/row['path']
 assert fact(p)=={k:row[k]for k in ('bytes','sha256')},row['path']
 inputs.append(dict(path=row['path'],**fact(sources.get(row['path'],p))))
inputs.append(dict(path=newpath,**fact(sources[newpath])))
assert len(inputs)==128 and sum('/src/main/'in x['path']for x in inputs)==125
write(S/'actual-jvm-compilation-inputs.json',dict(kind='Seven-source precise K2 incremental overlay on coherent df6f ordinary JAR;118 retained main source inputs,3 retained build controls; NOT full Gradle',inputs=inputs))
ref=ast.parse((R/'.build/consolidated-header-v2-browser-source-step/validate-union.py').read_text())
f=next(n for n in ref.body if isinstance(n,ast.FunctionDef)and n.name=='source_file')
exec(compile(ast.Module(body=[f],type_ignores=[]),'<frozen SourceFile reader>','exec'))
owned_sources={p.name for p in sources.values()}
new={p.relative_to(classes).as_posix():p.read_bytes()for p in classes.rglob('*.class')};assert new
with zipfile.ZipFile(base)as src:
 assert src.testzip()is None
 binding=[dict(path=n,**hashed(src.read(n)),sourceFile=source_file(src.read(n)))for n in src.namelist()if n.startswith(('io/yuedu/legado/','io/legado/app/','com/script/'))and n.endswith('.class')]
 outer={n.split('$')[0].removesuffix('.class')for n,b in new.items()if source_file(b)in owned_sources}
 owned=lambda n:n.removesuffix('.class').split('$')[0]in outer
 old_owned={r['path']for r in binding if owned(r['path'])}
 assert all(owned(n)for n in new)
 for n,b in new.items():assert source_file(b)in owned_sources or('$inlined$'in n and source_file(b)in {'RuleCompat.kt','_Sequences.kt'}),(n,source_file(b))
 jar=E/'legado-runtime-local-webjs.jar'
 with zipfile.ZipFile(jar,'w',compression=zipfile.ZIP_DEFLATED)as dst:
  for entry in src.infolist():
   if entry.filename in old_owned:continue
   dst.writestr(entry,manifest.read_bytes()if entry.filename=='META-INF/legado-provenance/original-rule/manifest.json'else src.read(entry.filename))
  for name,b in new.items():dst.writestr(name,b)
 with zipfile.ZipFile(jar)as dst, zipfile.ZipFile(base)as verified_base:
  assert dst.testzip()is None
  retained=[r for r in binding if r['path']not in old_owned]
  for row in retained:assert dst.read(row['path'])==verified_base.read(row['path'])
  assert dst.read('META-INF/io.yuedu_legado-runtime.kotlin_module')==verified_base.read('META-INF/io.yuedu_legado-runtime.kotlin_module')
  resources=[]
  for n in verified_base.namelist():
   if n.endswith('.class')or n=='META-INF/legado-provenance/original-rule/manifest.json':continue
   assert dst.read(n)==verified_base.read(n);resources.append(dict(path=n,**hashed(verified_base.read(n))))
write(E/'production-binding.json',dict(kind='Precise seven-source bounded K2 overlay, not full Gradle; no new top-level declaration, unchanged existing module metadata retained',baseJar=dict(path=str(base),**fact(base)),jar=dict(path=str(jar),**fact(jar)),compiledInputs=compiled['sources'],compiler=compiled['compiler'],baselineProductionClassCount=len(binding),oldOwnedClasses=sorted(old_owned),recompiledClasses=[dict(path=n,**hashed(b),sourceFile=source_file(b))for n,b in sorted(new.items())],retainedClasses=retained,newNestedClasses=sorted(set(new)-old_owned),removedNestedClasses=sorted(old_owned-set(new)),unchangedResources=resources,portedSources=59,totalCompilationInputs=128,mainCompilationInputs=125,retainedMainInputs=118))
print(json.dumps(dict(jar=fact(jar),freshClasses=len(new),retainedClasses=len(retained),resources=len(resources))))
