from pathlib import Path
import hashlib,json,os,subprocess,sys,zipfile

R=Path('F:/yuedu-reader');S=R/'.build/native-210-reader-repair-step';W=S/'work';B=R/'.build/original-source-login-delta-reuse-step';V=S/'validation-root';C=S/'incremental';C.mkdir(exist_ok=True)
cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin'
base=B/'validation-root/Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar'
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def cached(g,n,v):
 p=list((cache/g/n/v).rglob('*.jar'));assert len(p)==1,(g,n,v);return p[0]
compiler=[cached('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),cached('org.jetbrains.kotlin','kotlin-build-tools-api','2.4.20'),cached('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),cached('org.jetbrains.kotlin','kotlin-script-runtime','2.4.20'),cached('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),cached('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.4.20'),cached('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),cached('org.jetbrains','annotations','26.0.2')]
junit=cached('junit','junit','4.13.2');hamcrest=cached('org.hamcrest','hamcrest-core','1.3')
main='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt'
baseline=json.loads((B/'actual-jvm-compilation-inputs.json').read_text(encoding='utf-8'))['inputs']
matched=[]
for row in baseline:
 p=row['path']
 if '/src/main/' not in p:continue
 if p==main:assert fact(S/'rawbaseline'/p)=={k:row[k]for k in ('bytes','sha256')}
 else:assert fact(V/p)=={k:row[k]for k in ('bytes','sha256')},p
 matched.append(row)
assert len(matched)==122
basebinding=json.loads((B/'ordinary-jar-production-class-binding.json').read_text(encoding='utf-8'))
with zipfile.ZipFile(base)as z:
 assert z.testzip()is None
 for row in basebinding['classes']:
  b=z.read(row['path']);assert len(b)==row['bytes']and hashlib.sha256(b).hexdigest()==row['sha256']
assert len(basebinding['classes'])==337
commands=[]
def run(args,name):
 commands.append({'log':name,'argv':list(map(str,args))})
 (C/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8')
 p=subprocess.run(list(map(str,args)),cwd=R,capture_output=True)
 (C/name).write_bytes(p.stdout+p.stderr)
 print(name,'exit',p.returncode,flush=True)
 if p.returncode:
  print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-7000:]);sys.exit(p.returncode)
vm=['-Xms16m','-Xmx128m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC']
common=[J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21','-module-name','io.yuedu_legado-runtime','-Xfriend-paths='+str(base)]
out=C/'main-classes';out.mkdir(exist_ok=True)
run([*common,'-classpath',str(base),'-d',str(out),str(W/main)],'compile-production.log')
newclasses=sorted(out.rglob('*.class'))
assert newclasses and all(p.name.startswith('RuleWebBookState')for p in newclasses)
with zipfile.ZipFile(base)as z:
 expected={n for n in z.namelist()if n.startswith('io/yuedu/legado/originalrule/RuleWebBookState')and n.endswith('.class')}
assert {p.relative_to(out).as_posix()for p in newclasses}==expected
jar=C/'legado-runtime-incremental.jar'
replacements={p.relative_to(out).as_posix():p.read_bytes()for p in newclasses}
replacements['META-INF/legado-provenance/original-rule/manifest.json']=(W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes()
with zipfile.ZipFile(base)as src,zipfile.ZipFile(jar,'w',compression=zipfile.ZIP_DEFLATED)as dst:
 for entry in src.infolist():dst.writestr(entry,replacements.get(entry.filename,src.read(entry.filename)))
with zipfile.ZipFile(base)as src,zipfile.ZipFile(jar)as dst:
 assert dst.testzip()is None
 changed=[n for n in src.namelist()if src.read(n)!=dst.read(n)]
 assert set(changed)<=set(replacements)
 assert 'io/yuedu/legado/originalrule/RuleWebBookState$StoredChapter.class'in changed
 (C/'binding.json').write_text(json.dumps({'validationKind':'Exact single-source Kotlin 2.4.20 friend/module incremental overlay; not a fresh full Gradle build.','baseJar':{'path':str(base),**fact(base)},'jar':fact(jar),'compilerInputs':[{'path':str(p),**fact(p)}for p in compiler],'matchedUnchangedMainRoots':len(matched)-1,'baselineClassCount':337,'recompiledClasses':[{'path':p.relative_to(out).as_posix(),**fact(p)}for p in newclasses],'changedJarEntries':changed,'preservedModuleMetadata':'META-INF/io.yuedu_legado-runtime.kotlin_module (no package-level declarations changed)'},indent=2)+'\n',encoding='utf-8')
tests=C/'test-classes';tests.mkdir(exist_ok=True)
testsource='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalWebBookExecutionTest.kt'
adapter=R/'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/FileRulePersistenceAdapter.kt'
run([*common,'-Xfriend-paths='+str(jar),'-classpath',os.pathsep.join(map(str,[jar,junit,hamcrest])),'-d',str(tests),str(W/testsource),str(adapter)],'compile-tests.log')
runtime=os.pathsep.join(map(str,[jar,tests,junit,hamcrest]))
run([J/'javac.exe','-J-Xmx64m','-J-XX:+UseSerialGC','-cp',runtime,'-d',str(tests),str(S/'SelectedReaderRepairTests.java'),str(S/'OrdinaryReaderRepairSmoke.java')],'compile-java.log')
run([J/'java.exe',*vm,'-cp',runtime,'SelectedReaderRepairTests',str(C/'actual-tests.xml')],'junit-selected.log')
run([J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,[jar,tests])),'OrdinaryReaderRepairSmoke'],'ordinary-java.log')
print(json.dumps({'incrementalJar':fact(jar),'matchedUnchangedMainRoots':121,'actualSelectedTests':3,'ordinaryJava':True}),flush=True)
