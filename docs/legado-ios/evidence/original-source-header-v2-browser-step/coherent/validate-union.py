from pathlib import Path
import hashlib,json,os,struct,subprocess,sys,zipfile
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';B=S/'rawbaseline';P=R/'.build/original-source-login-browser-post-step';E=S/'execution-v1';resume=False;E.mkdir(exist_ok=False)
base=P/'snapshot-v1/legado-runtime.jar';assert hashlib.sha256(base.read_bytes()).hexdigest()=='91d337f590f6c433206747caa41c731f045dc2f3aa3d1ebbae552ff99b715a81'
cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin'
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8',newline='\n')
def cached(g,n,v):
 p=list((cache/g/n/v).rglob('*.jar'));assert len(p)==1,(g,n,v);return p[0]
compiler=[cached('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),cached('org.jetbrains.kotlin','kotlin-build-tools-api','2.4.20'),cached('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),cached('org.jetbrains.kotlin','kotlin-script-runtime','2.4.20'),cached('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),cached('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.4.20'),cached('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),cached('org.jetbrains','annotations','26.0.2')]
junit=cached('junit','junit','4.13.2');hamcrest=cached('org.hamcrest','hamcrest-core','1.3')
changed=['Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt','Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt','Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt']
prior=json.loads((P/'actual-jvm-compilation-inputs.json').read_text(encoding='utf-8'))['inputs'];inputs=[]
for row in prior:
 p=B/row['path'] if row['path']in changed else R/row['path'];assert fact(p)=={k:row[k]for k in ('bytes','sha256')},row['path']
 inputs.append(dict(path=row['path'],**fact(W/row['path'] if row['path']in changed else p)))
assert len(inputs)==127 and sum('/src/main/'in x['path']for x in inputs)==124
write(S/'actual-jvm-compilation-inputs.json',dict(kind='Three-source K2 incremental overlay,121 exact retained main inputs;3 build-control facts retained, no Gradle execution',inputs=inputs))
manifest=W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads(manifest.read_text(encoding='utf-8'));count=0
for row in m['portedSources']:
 if row.get('path')in changed:
  assert fact(W/row['path'])=={k:row[k]for k in ('bytes','sha256')};count+=1
assert count==3
commands=json.loads((E/'commands.json').read_text())if resume else []
def run(argv,name):
 p=subprocess.run(list(map(str,argv)),cwd=R,capture_output=True);(E/name).write_bytes(p.stdout+p.stderr)
 commands.append(dict(argv=list(map(str,argv)),exitCode=p.returncode,log=name));write(E/'commands.json',commands);print(name,'exit',p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-7000:]);sys.exit(p.returncode)
vm=['-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC']
common=[J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21','-module-name','io.yuedu_legado-runtime']
classes=E/'main-classes';classes.mkdir(exist_ok=resume)
if resume:assert len(commands)==1 and commands[0]['exitCode']==0
else:run([*common,'-Xfriend-paths='+str(base),'-classpath',str(base),'-d',str(classes),*[W/p for p in changed]],'compile-production.log')
def source_file(data):
 pos=8;count=struct.unpack_from('>H',data,pos)[0];pos+=2;cp={};i=1
 while i<count:
  tag=data[pos];pos+=1
  if tag==1:
   n=struct.unpack_from('>H',data,pos)[0];pos+=2;cp[i]=data[pos:pos+n].decode('utf-8',errors='replace');pos+=n
  elif tag in (3,4,9,10,11,12,17,18):pos+=4
  elif tag in (5,6):pos+=8;i+=1
  elif tag in (7,8,16,19,20):pos+=2
  elif tag==15:pos+=3
  else:raise AssertionError(('constant tag',tag))
  i+=1
 pos+=6;n=struct.unpack_from('>H',data,pos)[0];pos+=2+2*n
 for _ in range(2):
  n=struct.unpack_from('>H',data,pos)[0];pos+=2
  for _ in range(n):
   pos+=6;a=struct.unpack_from('>H',data,pos)[0];pos+=2
   for _ in range(a):size=struct.unpack_from('>I',data,pos+2)[0];pos+=6+size
 n=struct.unpack_from('>H',data,pos)[0];pos+=2
 for _ in range(n):
  name,size=struct.unpack_from('>HI',data,pos);pos+=6
  if cp.get(name)=='SourceFile':return cp[struct.unpack_from('>H',data,pos)[0]]
  pos+=size
 return None
owned_sources={'RuleModels.kt','LegadoRuntime.kt','ProductionRulePlatform.kt'}
new={p.relative_to(classes).as_posix():p.read_bytes()for p in classes.rglob('*.class')};assert new
with zipfile.ZipFile(base)as src:
 assert src.testzip()is None
 binding=[dict(path=n,bytes=len(src.read(n)),sha256=hashlib.sha256(src.read(n)).hexdigest(),sourceFile=source_file(src.read(n)))for n in src.namelist()if n.startswith(('io/yuedu/legado/','io/legado/app/','com/script/'))and n.endswith('.class')]
 # Inline RuleCompat metadata records the source of the inlined body, so
 # owning outer class, not SourceFile alone, decides those generated classes.
 outer_prefixes={n.split('$')[0].removesuffix('.class')for n,b in new.items()if source_file(b)in owned_sources}
 owned=lambda n:n.removesuffix('.class').split('$')[0]in outer_prefixes
 oldOwned={r['path']for r in binding if owned(r['path'])}
 assert all(owned(n)for n in new)
 assert all(source_file(b)in owned_sources or ('$inlined$'in n and source_file(b)in {'RuleCompat.kt','_Sequences.kt'})for n,b in new.items())
 jar=E/'legado-runtime-header-v2-browser.jar'
 with zipfile.ZipFile(jar,'w',compression=zipfile.ZIP_DEFLATED)as dst:
  for entry in src.infolist():
   if entry.filename in oldOwned:continue
   dst.writestr(entry,manifest.read_bytes()if entry.filename=='META-INF/legado-provenance/original-rule/manifest.json'else src.read(entry.filename))
  for name,b in new.items():dst.writestr(name,b)
 with zipfile.ZipFile(base)as verifiedBase,zipfile.ZipFile(jar)as dst:
  assert dst.testzip()is None
  retained=[r for r in binding if r['path']not in oldOwned]
  for row in retained:assert dst.read(row['path'])==verifiedBase.read(row['path'])
  assert dst.read('META-INF/io.yuedu_legado-runtime.kotlin_module')==verifiedBase.read('META-INF/io.yuedu_legado-runtime.kotlin_module')
write(E/'production-binding.json',dict(kind='Coherent Header+V2Browser three-source exact K2 overlay on POST91d3 ordinaryJAR; NOT fresh Gradle',baseJar=dict(path=str(base),**fact(base)),jar=fact(jar),compiler=[dict(path=str(p),**fact(p))for p in compiler],sourceInputs=[dict(path=p,**fact(W/p))for p in changed],matchedMainInputs=124,unchangedMainInputs=121,baselineProductionClassCount=len(binding),oldOwnedClasses=sorted(oldOwned),recompiledClasses=[dict(path=n,bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),sourceFile=source_file(b))for n,b in sorted(new.items())],retainedClasses=retained,newNestedClasses=sorted(set(new)-oldOwned),removedNestedClasses=sorted(oldOwned-set(new)),moduleMetadata='Unchanged base module metadata; no new top-level declaration or constructor ABI'))
tests=E/'test-classes';tests.mkdir();tr='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/'
testRoots=[W/(tr+n)for n in ['OriginalSourceLoginHeaderTest.kt','AppCookieOwnerTextTest.kt','OriginalSourceLoginV2BrowserTest.kt']]+[R/(tr+n)for n in ['OriginalSourceLoginBrowserPostTest.kt','OriginalSourceLoginBrowserAwaitTest.kt','OriginalSourceLoginBrowserTest.kt','FileRulePersistenceAdapter.kt']]
run([*common,'-Xfriend-paths='+str(jar),'-classpath',os.pathsep.join(map(str,[jar,junit,hamcrest])),'-d',str(tests),*testRoots],'compile-tests.log')
cp=os.pathsep.join(map(str,[jar,tests,junit,hamcrest]))
run([J/'javac.exe','-J-Xmx64m','-classpath',cp,'-d',str(tests),S/'SelectedUnionTests.java'],'compile-runner.log')
run([J/'java.exe',*vm,'-cp',cp,'SelectedUnionTests',E/'actual-tests.xml'],'junit-union.log')
print(json.dumps(dict(jar=fact(jar),freshClasses=len(new),retainedClasses=len(retained),tests=23)),flush=True)
