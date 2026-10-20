from pathlib import Path
import hashlib,json,subprocess,time
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'ordinary-v2';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=E/'legado-runtime-local-webjs.jar';classes=E/'consumer-classes';classes.mkdir(exist_ok=False)
def fact(p):b=p.read_bytes();return dict(path=str(p),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
commands=[]
def run(argv,name):
 t=time.monotonic();p=subprocess.run(list(map(str,argv)),cwd=R,capture_output=True);log=E/name;log.write_bytes(p.stdout+p.stderr);commands.append(dict(argv=list(map(str,argv)),exitCode=p.returncode,seconds=round(time.monotonic()-t,3),log=fact(log)));(E/'ordinary-commands.json').write_text(json.dumps(dict(scope='Ordinary JAR plus independent Java consumer classes only; no JUnit/test classes or UIKit',jar=fact(jar),source=fact(S/'OrdinaryLocalWebJs.java'),commands=commands),indent=2)+'\n',encoding='utf-8',newline='\n');print(name,p.returncode,flush=True);print(log.read_text(encoding='utf-8')[-9000:]);return p.returncode
assert run([J/'javac.exe','-J-Xmx64m','-classpath',jar,'-d',classes,S/'OrdinaryLocalWebJs.java'],'compile-consumer.log')==0
raise SystemExit(run([J/'java.exe','-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-cp',str(jar)+';'+str(classes),'OrdinaryLocalWebJs'],'execute-consumer.log'))
