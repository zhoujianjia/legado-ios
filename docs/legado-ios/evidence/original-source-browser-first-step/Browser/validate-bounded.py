from pathlib import Path
import hashlib,json,os,struct,subprocess,sys,zipfile
R=Path('F:/yuedu-reader');S=R/'.build/original-source-login-browser-host-step';W=S/'work';V=S/'validation-root';C=S/('execution-'+(sys.argv[1]if len(sys.argv)>1 else'v1'));resume='--resume-production' in sys.argv
if resume:assert C.exists()
else:assert not C.exists();C.mkdir()
baseStage=R/'.build/original-source-login-v2-protocol-step';base=baseStage/'backend-snapshot-v3/legado-runtime.jar'
assert hashlib.sha256(base.read_bytes()).hexdigest()=='44b8d573a52b4f33dd2a3fd6df845ac6cb6f13d1c148e169eef1f80f6d51a8f7'
cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin'
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def cached(g,n,v):
 p=list((cache/g/n/v).rglob('*.jar'));assert len(p)==1,(g,n,v);return p[0]
compiler=[cached('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),cached('org.jetbrains.kotlin','kotlin-build-tools-api','2.4.20'),cached('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),cached('org.jetbrains.kotlin','kotlin-script-runtime','2.4.20'),cached('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),cached('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.4.20'),cached('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),cached('org.jetbrains','annotations','26.0.2')]
junit=cached('junit','junit','4.13.2');hamcrest=cached('org.hamcrest','hamcrest-core','1.3')
changed=['Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',*['Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/'+n+'.kt'for n in ['OriginalSourceLoginHost','ProductionRulePlatform','RulePlatform']]]
prior=json.loads((baseStage/'actual-jvm-compilation-inputs.json').read_text())['inputs'];matched=[]
for row in prior:
 rel=row['path']
 if '/src/main/'not in rel:continue
 expected={k:row[k]for k in ('bytes','sha256')}
 assert fact(S/'rawbaseline'/rel if rel in changed else V/rel)==expected,rel
 matched.append(row)
assert len(matched)==124
binding=json.loads((baseStage/'ordinary-jar-production-class-binding.json').read_text())['classes']
assert len(binding)==346
with zipfile.ZipFile(base)as z:
 assert z.testzip()is None
 for item in binding:
  b=z.read(item['path']);assert len(b)==item['bytes']and hashlib.sha256(b).hexdigest()==item['sha256']
commands=json.loads((C/'commands.json').read_text())if resume else[]
def run(args,name):
 commands.append(dict(argv=list(map(str,args)),log=name));write(C/'commands.json',commands)
 p=subprocess.run(list(map(str,args)),cwd=R,capture_output=True);(C/name).write_bytes(p.stdout+p.stderr)
 print(name,'exit',p.returncode,flush=True)
 if p.returncode:
  print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-5000:]);sys.exit(p.returncode)
vm=['-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC']
common=[J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21','-module-name','io.yuedu_legado-runtime']
classes=C/'main-classes'
if resume:
 assert classes.exists()and(C/'compile-production.log').exists()
 for rel in changed:assert(W/rel).read_bytes()==(S/'source-snapshot-v1/work'/rel).read_bytes(),rel
 write(C/'validation-inspection-history.json',dict(initialFailure='Validation-only SourceFile ownership assertion rejected7 inlined nested classes whose SourceFile names RuleCompat.kt.',productionCompileExit=0,productionRecompiled=False,correction='Bind all emitted classes to their declared top-level outer class roots, and retain SourceFile including inline utility origin. Check exact old/new outer ownership sets. No source/JAR behavior changed.'))
else:
 classes.mkdir()
 run([*common,'-Xfriend-paths='+str(base),'-classpath',str(base),'-d',str(classes),*[W/rel for rel in changed]],'compile-production.log')
# Read the real class SourceFile attribute. Replace/remove exactly every old
# class produced by the four recompiled files; no stale nested class is retained.
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
owners={Path(p).name for p in changed};newClasses={p.relative_to(classes).as_posix():p.read_bytes()for p in classes.rglob('*.class')};assert newClasses
outerRoots={n for n,b in newClasses.items()if '$'not in n and source_file(b)in owners}
assert len(outerRoots)==8,sorted(outerRoots)
def owner_root(n):
 root=n.split('$',1)[0]+'.class'if '$'in n else n
 return root if root in outerRoots else None
assert all(owner_root(n)is not None for n in newClasses)
assert all(source_file(b)in owners or('$'in n and '$inlined$'in n and source_file(b)=='RuleCompat.kt')for n,b in newClasses.items())
with zipfile.ZipFile(base)as z:
 oldOwned={x['path']for x in binding if owner_root(x['path'])is not None}
 for root in outerRoots:assert source_file(z.read(root))in owners
assert oldOwned and set(newClasses)==oldOwned,(sorted(set(newClasses)-oldOwned),sorted(oldOwned-set(newClasses)))
replacements={**newClasses,'META-INF/legado-provenance/original-rule/manifest.json':(W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes()}
jar=C/'legado-runtime-browser-incremental.jar'
with zipfile.ZipFile(base)as src,zipfile.ZipFile(jar,'w',compression=zipfile.ZIP_DEFLATED)as dst:
 for entry in src.infolist():dst.writestr(entry,replacements.get(entry.filename,src.read(entry.filename)))
with zipfile.ZipFile(base)as src,zipfile.ZipFile(jar)as dst:
 assert dst.testzip()is None
 actualChanged=[n for n in src.namelist()if src.read(n)!=dst.read(n)];assert set(actualChanged)<=set(replacements)
 assert dst.read('META-INF/io.yuedu_legado-runtime.kotlin_module')==src.read('META-INF/io.yuedu_legado-runtime.kotlin_module')
write(C/'production-binding.json',dict(kind='Exact4 source Kotlin2.4.20 friend/module incremental overlay. Fresh ordinary incremental payload, NOT full Gradle build.',baseJar=dict(path=str(base),**fact(base)),jar=fact(jar),compiler=[dict(path=str(p),**fact(p))for p in compiler],sourceInputs=[dict(path=rel,**fact(W/rel))for rel in changed],unchangedMainInputs=120,matchedMainInputs=124,baselineProductionClassCount=346,recompiledClasses=[dict(path=n,bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),sourceFile=source_file(b))for n,b in sorted(newClasses.items())],preservedOtherProductionClasses=346-len(newClasses),changedJarEntries=actualChanged,moduleMetadata='Existing base module metadata preserved; only class member declarations change, no new package top-level declarations.'))
tests=C/'test-classes';tests.mkdir()
test='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserTest.kt';adapter='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/FileRulePersistenceAdapter.kt'
run([*common,'-Xfriend-paths='+str(jar),'-classpath',os.pathsep.join(map(str,[jar,junit,hamcrest])),'-d',str(tests),W/test,V/adapter],'compile-tests.log')
cp=os.pathsep.join(map(str,[jar,tests,junit,hamcrest]))
run([J/'javac.exe','-J-Xmx64m','-J-XX:+UseSerialGC','-J-XX:CompressedClassSpaceSize=32m','-J-XX:ReservedCodeCacheSize=32m','-cp',cp,'-d',str(tests),S/'SelectedBrowserTests.java',S/'OrdinaryLoginBrowserSmoke.java'],'compile-java.log')
run([J/'java.exe',*vm,'-cp',cp,'SelectedBrowserTests',C/'actual-tests.xml'],'junit-browser.log')
run([J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,[jar,tests])),'OrdinaryLoginBrowserSmoke'],'ordinary-java.log')
print(json.dumps(dict(ordinaryIncrementalJar=fact(jar),JUnit=4,externalJavaSessions=5,kind='exact incremental, not full Gradle')),flush=True)
