from pathlib import Path
import hashlib,json,os,subprocess,time,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'compile-v1';E.mkdir(exist_ok=False)
base=R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/legado-runtime.jar'
def fact(p):
 b=p.read_bytes();return {'path':str(p.relative_to(R)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
assert fact(base)['sha256']=='89f77040ea6a0f4592ca00a059c25da76cece9d1520b541e144588e6b4c5003b'
prefix='Packages/LegadoRuntime/jvm/src/main/kotlin/'
unchanged=['io/legado/app/model/analyzeRule/AnalyzeRule.kt','io/legado/app/model/analyzeRule/AnalyzeUrl.kt','io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt','io/legado/app/data/entities/RuleModels.kt','io/legado/app/data/entities/BaseSource.kt']
sources=[S/'work'/(prefix+p)for p in ['io/yuedu/legado/originalrule/RulePlatform.kt','io/yuedu/legado/originalrule/RuleBase64.kt']]
manifest=json.loads((S/'rawbaseline/Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_text(encoding='utf-8'));rows={v['path']:v for v in manifest['portedSources']}
for p in unchanged:
 src=R/(prefix+p);b=src.read_bytes()
 assert fact(src)['sha256']==rows[prefix+p]['sha256']
 dest=S/'unchanged-compile-inputs'/(prefix+p);dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(b);sources.append(dest)
cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1'
def cached(g,n,v):
 ps=list((cache/g/n/v).rglob('*.jar'));assert len(ps)==1;return ps[0]
compiler=[cached('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),cached('org.jetbrains.kotlin','kotlin-build-tools-api','2.4.20'),cached('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),cached('org.jetbrains.kotlin','kotlin-script-runtime','2.4.20'),cached('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),cached('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.4.20'),cached('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),cached('org.jetbrains','annotations','26.0.2')]
classes=E/'classes';classes.mkdir();jdk=R/'.tools/jdk21/jdk-21.0.12.1+1/bin/java.exe'
argv=[str(jdk),'-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21','-module-name','io.yuedu_legado-runtime','-Xfriend-paths='+str(base),'-classpath',str(base),'-d',str(classes),*map(str,sources)]
t=time.monotonic();p=subprocess.run(argv,cwd=R,capture_output=True);log=E/'compile.log';log.write_bytes(p.stdout+p.stderr)
a={'scope':'Seven precise sources, two changed and five identical ABI implementor inputs, bounded incremental K2; no full Gradle/JUnit/SDK','argv':argv,'exitCode':p.returncode,'seconds':round(time.monotonic()-t,3),'log':fact(log),'base':fact(base),'sources':list(map(fact,sources)),'compiler':list(map(fact,compiler)),'testsExecuted':0}
(E/'commands.json').write_text(json.dumps(a,indent=2)+'\n',encoding='utf-8',newline='\n');print('COMPILE_EXIT',p.returncode,'SECONDS',a['seconds']);print(log.read_text(encoding='utf-8')[-6000:]);raise SystemExit(p.returncode)
