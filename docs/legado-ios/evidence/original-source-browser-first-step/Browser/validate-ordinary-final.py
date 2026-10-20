from pathlib import Path
import hashlib,importlib.util,json,os,subprocess,sys,zipfile
R=Path('F:/yuedu-reader');S=R/'.build/original-source-login-browser-host-step';C=S/'execution-v1';V=S/'validation-root';W=S/'work';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=C/'legado-runtime-browser-incremental.jar'
p=S/'OrdinaryLoginBrowserSmoke.java';(C/'OrdinaryLoginBrowserSmoke-before-admission-fixture-fix.java').write_bytes(p.read_bytes());s=p.read_text(encoding='utf-8');old='''            var unowned=call(a,"java.startBrowser('https://synthetic-browser.invalid/page','Unowned');",false,false);
            if(!unowned.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("Unowned presentation accepted");''';new='''            var awaited=call(a,"java.startBrowserAwait('https://synthetic-browser.invalid/page','Awaited');",true,false);
            if(!awaited.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("Awaited browser pretended plain page");''';assert old in s;s=s.replace(old,new,1);p.write_text(s,encoding='utf-8',newline='\n')
out=C/'ordinary-final';out.mkdir();classes=out/'classes';classes.mkdir();commands=[]
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8',newline='\n')
def run(args,name):
 commands.append(dict(argv=list(map(str,args)),log=name));write(out/'commands.json',commands)
 result=subprocess.run(list(map(str,args)),cwd=R,capture_output=True);(out/name).write_bytes(result.stdout+result.stderr);print(name,'exit',result.returncode,flush=True)
 assert result.returncode==0,(name,(result.stdout+result.stderr).decode(errors='replace')[-4000:])
run([J/'javac.exe','-J-Xmx64m','-J-XX:+UseSerialGC','-J-XX:CompressedClassSpaceSize=32m','-J-XX:ReservedCodeCacheSize=32m','-cp',str(jar),'-d',str(classes),p],'compile.log')
run([J/'java.exe','-Xms16m','-Xmx128m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-cp',str(jar)+os.pathsep+str(classes),'OrdinaryLoginBrowserSmoke'],'execute.log')
print((out/'execute.log').read_text(encoding='utf-8').strip())
write(C/'ordinary-fixture-history.json',dict(priorFailure='Initial external consumer tried to create an original-traditional session without stateOwner, but the existing admission rejects that before creation. No production bug or failed JVM test.',correction='Fifth actual created session uses explicit owner and exercises typed unsupported Await. First4 prior sessions ran; final isolated consumer reran5 fresh sessions. No Kotlin source/test suite rerun.',classpath='Final Java compilation uses ONLY ordinary production JAR; execution uses JAR plus external consumer classes, no JUnit/test-classpath.',priorJavaSource=fact(C/'OrdinaryLoginBrowserSmoke-before-admission-fixture-fix.java'),finalJavaSource=fact(p)))
spec=importlib.util.spec_from_file_location('browser_ordinary_packaging',R/'scripts/reader-experience/runtime-packaging.py');pack=importlib.util.module_from_spec(spec);sys.modules[spec.name]=pack;spec.loader.exec_module(pack);pack.REPO=V;details=pack.inspect_jar(jar);write(S/'ordinary-jar-inspected.json',details)
base=R/'.build/original-source-login-v2-protocol-step/backend-snapshot-v3/legado-runtime.jar';old=json.loads((R/'.build/original-source-login-v2-protocol-step/ordinary-jar-production-class-binding.json').read_text())['classes'];compiled=C/'main-classes';new={p.relative_to(compiled).as_posix():p for p in compiled.rglob('*.class')};rows=[]
with zipfile.ZipFile(base)as src,zipfile.ZipFile(jar)as dst:
 assert dst.testzip()is None
 assert dst.read('META-INF/legado-provenance/original-rule/manifest.json')==(W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes()
 for row in old:
  n=row['path'];data=dst.read(n)
  if n in new:assert data==new[n].read_bytes()
  else:assert data==src.read(n)
  rows.append(dict(path=n,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),validation='actual4source recompilation'if n in new else'exact unchanged V2 compiled class'))
 assert not any(n.startswith('org/junit/')or'OriginalSourceLoginBrowserTest'in n or'OrdinaryLoginBrowserSmoke'in n for n in dst.namelist())
write(S/'ordinary-jar-production-class-binding.json',dict(kind='Ordinary exact incremental production payload; not a fresh full Gradle build',jar=fact(jar),matchedProductionKotlinClasses=len(rows),freshlyRecompiledClasses=len(new),preservedUnchangedV2Classes=len(rows)-len(new),CRCValid=True,classes=rows))
inputs=[]
for p in sorted((V/'Packages/LegadoRuntime/jvm/src/main').rglob('*')):
 if p.is_file():inputs.append(dict(path=p.relative_to(V).as_posix(),**fact(p)))
for n in ['build.gradle.kts','settings.gradle.kts','gradle.properties','gradle.lockfile']:
 p=V/'Packages/LegadoRuntime/jvm'/n
 if p.exists():inputs.append(dict(path=p.relative_to(V).as_posix(),**fact(p)))
write(S/'actual-jvm-compilation-inputs.json',dict(kind='124 main roots:4 exact current Kotlin roots recompiled;120 unchanged roots proven against final V2 44b8 base actual compilation. All127 source/build inputs recorded; no whole-project Gradle rebuild claimed.',inputs=inputs,actualMainRootsRecompiled=[dict(path=p.relative_to(W).as_posix(),**fact(p))for p in sorted((W/'Packages/LegadoRuntime/jvm/src/main').rglob('*.kt'))],testRoots=[dict(path=n,**fact(W/n if(W/n).exists()else V/n))for n in ['Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginBrowserTest.kt','Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/FileRulePersistenceAdapter.kt']],validationBuildStanza='Inherited V2 validation-only128MiB/SerialGC testworker stanza is not used by this direct K2/JUnit route and is not a canonical build change.'))
print(json.dumps(dict(finalJar=fact(jar),productionClassCount=len(rows),recompiledClasses=len(new),preservedV2Classes=len(rows)-len(new),recordedMainAndBuildInputs=len(inputs),externalSessions=5,JUnitRerun=False)))
