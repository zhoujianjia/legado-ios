from pathlib import Path
import hashlib,json,os,subprocess,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'execution-v1';C=S/'execution-test-closure-repair';C.mkdir(exist_ok=False);J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin'
prior=json.loads((E/'commands.json').read_text(encoding='utf-8'));assert len(prior)==2 and prior[0]['exitCode']==0 and prior[1]['exitCode']!=0
argv=prior[1]['argv']+[str(R/'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalCookieTextOracle.kt')];argv[argv.index('-d')+1]=str(C/'test-classes');(C/'test-classes').mkdir();commands=[]
def run(a,name):
 p=subprocess.run(list(map(str,a)),cwd=R,capture_output=True);(C/name).write_bytes(p.stdout+p.stderr);commands.append(dict(argv=list(map(str,a)),exitCode=p.returncode,log=name));(C/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8');print(name,p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-7000:]);sys.exit(p.returncode)
run(argv,'compile-tests.log')
cp=argv[argv.index('-classpath')+1].split(os.pathsep);cp.insert(1,str(C/'test-classes'));cp=os.pathsep.join(cp)
run([J/'javac.exe','-J-Xmx64m','-classpath',cp,'-d',C/'test-classes',S/'SelectedUnionTests.java'],'compile-runner.log')
run([J/'java.exe','-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-classpath',cp,'SelectedUnionTests',C/'actual-tests.xml'],'junit-union.log')
