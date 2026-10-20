from pathlib import Path
import hashlib,json,os,subprocess,time
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';E=S/'compile-attempt1';E.mkdir(exist_ok=False)
base=R/'.build/consolidated-header-v2-browser-source-step/snapshot-v1/legado-runtime.jar'
def fact(p):b=p.read_bytes();return {'path':str(p),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
assert fact(base)['sha256']=='df6f572adfd6c18ca67d98573be86dcf9e65f0c0d8b603eae60f054e8c29eac3'
cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1'
def cached(g,n,v):
 ps=list((cache/g/n/v).rglob('*.jar'));assert len(ps)==1;return ps[0]
compiler=[cached('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),cached('org.jetbrains.kotlin','kotlin-build-tools-api','2.4.20'),cached('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),cached('org.jetbrains.kotlin','kotlin-script-runtime','2.4.20'),cached('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),cached('org.jetbrains.kotlin','kotlin-daemon-embeddable','2.4.20'),cached('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0'),cached('org.jetbrains','annotations','26.0.2')]
sources=sorted(W.rglob('*.kt'));assert len(sources)==7
classes=E/'classes';classes.mkdir()
jdk=R/'.tools/jdk21/jdk-21.0.12.1+1/bin/java.exe'
argv=[str(jdk),'-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21','-module-name','io.yuedu_legado-runtime','-Xfriend-paths='+str(base),'-classpath',str(base),'-d',str(classes),*map(str,sources)]
t=time.monotonic();p=subprocess.run(argv,cwd=R,capture_output=True);log=E/'compile.log';log.write_bytes(p.stdout+p.stderr)
a={'scope':'Seven-source bounded exact K2 incremental compile, not full Gradle or tests','argv':argv,'exitCode':p.returncode,'seconds':round(time.monotonic()-t,3),'log':fact(log),'base':fact(base),'sources':[fact(p)for p in sources],'compiler':[fact(p)for p in compiler],'testsExecuted':0}
(E/'commands.json').write_text(json.dumps(a,indent=2)+'\n',encoding='utf-8',newline='\n');print('COMPILE_EXIT',p.returncode,'SECONDS',a['seconds']);print(log.read_text(encoding='utf-8')[-7000:]);raise SystemExit(p.returncode)
