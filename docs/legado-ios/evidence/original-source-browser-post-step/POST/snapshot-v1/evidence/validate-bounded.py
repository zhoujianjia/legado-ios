from pathlib import Path
import hashlib,json,os,struct,subprocess,sys,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';V=S/'validation-root';A=R/'.build/original-source-login-browser-await-step';C=S/'execution-v1';C.mkdir()
base=A/'snapshot-v1/legado-runtime.jar';assert hashlib.sha256(base.read_bytes()).hexdigest()=='8c1b27e315cf4cf5779a83b97e45149d698a1d96d8b0332d4ddbb5281cdb7972'
cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin'
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def cached(g,n,v):
 p=list((cache/g/n/v).rglob('*.jar'));assert len(p)==1,(g,n,v);return p[0]
compiler=[cached('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),cached('org.jetbrains.kotlin','kotlin-build-tools-api','2.4.20'),cached('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),cached('org.jetbrains.kotlin','kotlin-script-runtime','2.4.20'),cached('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),cached('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.4.20'),cached('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),cached('org.jetbrains','annotations','26.0.2')]
junit=cached('junit','junit','4.13.2');hamcrest=cached('org.hamcrest','hamcrest-core','1.3')
changed='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt'
prior=json.loads((A/'actual-jvm-compilation-inputs.json').read_text(encoding='utf-8'))['inputs'];matched=[]
for row in prior:
 rel=row['path']
 if '/src/main/'not in rel:continue
 p=S/'rawbaseline'/rel if rel==changed else V/rel
 assert fact(p)=={k:row[k]for k in ('bytes','sha256')},rel
 matched.append(row)
assert len(matched)==124
binding=json.loads((A/'snapshot-v1/evidence/ordinary-jar-production-class-binding.json').read_text(encoding='utf-8'))['classes'];assert len(binding)==347
with zipfile.ZipFile(base)as z:
 assert z.testzip()is None
 for row in binding:
  b=z.read(row['path']);assert len(b)==row['bytes']and hashlib.sha256(b).hexdigest()==row['sha256']
commands=[]
def run(args,name):
 commands.append(dict(argv=list(map(str,args)),log=name));write(C/'commands.json',commands)
 p=subprocess.run(list(map(str,args)),cwd=R,capture_output=True);(C/name).write_bytes(p.stdout+p.stderr)
 print(name,'exit',p.returncode,flush=True)
 if p.returncode:
  print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-6000:]);sys.exit(p.returncode)
vm=['-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC']
common=[J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21','-module-name','io.yuedu_legado-runtime']
classes=C/'main-classes';classes.mkdir()
run([*common,'-Xfriend-paths='+str(base),'-classpath',str(base),'-d',str(classes),W/changed],'compile-production.log')
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
 for group in range(2):
  n=struct.unpack_from('>H',data,pos)[0];pos+=2
  for _ in range(n):
   pos+=6;a=struct.unpack_from('>H',data,pos)[0];pos+=2
   for _ in range(a):
    size=struct.unpack_from('>I',data,pos+2)[0];pos+=6+size
 n=struct.unpack_from('>H',data,pos)[0];pos+=2
 for _ in range(n):
  name,size=struct.unpack_from('>HI',data,pos);pos+=6
  if cp.get(name)=='SourceFile':return cp[struct.unpack_from('>H',data,pos)[0]]
  pos+=size
 return None
root='io/yuedu/legado/originalrule/ProductionRulePlatform'
owned=lambda n:n==root+'.class'or n.startswith(root+'$')
new={p.relative_to(classes).as_posix():p.read_bytes()for p in classes.rglob('*.class')};assert new and all(owned(n)for n in new)
assert all(source_file(b)=='ProductionRulePlatform.kt'or('$inlined$'in n and source_file(b)=='RuleCompat.kt')for n,b in new.items())
oldOwned={r['path']for r in binding if owned(r['path'])};assert oldOwned
with zipfile.ZipFile(base)as src,zipfile.ZipFile(C/'legado-runtime-post-incremental.jar','w',compression=zipfile.ZIP_DEFLATED)as dst:
 for entry in src.infolist():
  if entry.filename in oldOwned:continue
  b=(W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes()if entry.filename=='META-INF/legado-provenance/original-rule/manifest.json'else src.read(entry.filename)
  dst.writestr(entry,b)
 for name,b in new.items():dst.writestr(name,b)
jar=C/'legado-runtime-post-incremental.jar'
with zipfile.ZipFile(base)as src,zipfile.ZipFile(jar)as dst:
 assert dst.testzip()is None
 retained=[r for r in binding if r['path']not in oldOwned]
 for row in retained:assert dst.read(row['path'])==src.read(row['path'])
 assert dst.read('META-INF/io.yuedu_legado-runtime.kotlin_module')==src.read('META-INF/io.yuedu_legado-runtime.kotlin_module')
write(C/'production-binding.json',dict(kind='Exact one-source K2 overlay on immutable Await8c1b ordinary JAR; NOT full fresh Gradle',baseJar=dict(path=str(base),**fact(base)),jar=fact(jar),compiler=[dict(path=str(p),**fact(p))for p in compiler],sourceInputs=[dict(path=changed,**fact(W/changed))],unchangedMainInputs=123,matchedMainInputs=124,baselineProductionClassCount=347,oldOwnedClasses=sorted(oldOwned),recompiledClasses=[dict(path=n,bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),sourceFile=source_file(b))for n,b in sorted(new.items())],retainedClasses=retained,removedNestedClasses=sorted(oldOwned-set(new)),newNestedClasses=sorted(set(new)-oldOwned),moduleMetadata='Base module metadata retained; private nested data class only, no new package top-level declarations'))
tests=C/'test-classes';tests.mkdir();tr='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/'
testRoots=[W/(tr+n)for n in ['OriginalSourceLoginBrowserPostTest.kt','OriginalSourceLoginBrowserAwaitTest.kt','OriginalSourceLoginBrowserTest.kt']]+[V/(tr+'FileRulePersistenceAdapter.kt')]
run([*common,'-Xfriend-paths='+str(jar),'-classpath',os.pathsep.join(map(str,[jar,junit,hamcrest])),'-d',str(tests),*testRoots],'compile-tests.log')
cp=os.pathsep.join(map(str,[jar,tests,junit,hamcrest]))
run([J/'javac.exe','-J-Xmx64m','-J-XX:+UseSerialGC','-J-XX:CompressedClassSpaceSize=32m','-J-XX:ReservedCodeCacheSize=32m','-cp',cp,'-d',str(tests),S/'SelectedPostTests.java'],'compile-junit-runner.log')
run([J/'java.exe',*vm,'-cp',cp,'SelectedPostTests',C/'actual-tests.xml'],'junit-post-and-get.log')
print(json.dumps(dict(ordinaryIncrementalJar=fact(jar),JUnit=12,kind='exact1 current-source incremental, not full Gradle')),flush=True)
