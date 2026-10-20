from pathlib import Path
import json,os,subprocess,sys
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'execution-v1';C=S/'execution-repair-v2';C.mkdir(exist_ok=False);J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';cache=R/'.tools/gradle-user-home/caches/modules-2/files-2.1'
def cached(g,n,v):return next((cache/g/n/v).rglob('*.jar'))
prior=json.loads((E/'commands.json').read_text());argv=prior[1]['argv'];argv[argv.index('-d')+1]=str(C/'test-classes');Path(argv[argv.index('-d')+1]).mkdir();commands=[]
def run(a,name):
 p=subprocess.run(list(map(str,a)),cwd=R,capture_output=True);(C/name).write_bytes(p.stdout+p.stderr);commands.append(dict(argv=list(map(str,a)),exitCode=p.returncode,log=name));(C/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');print(name,p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
run(argv,'compile-tests.log')
cp=os.pathsep.join(map(str,[E/'legado-runtime-v2-browser.jar',C/'test-classes',cached('junit','junit','4.13.2'),cached('org.hamcrest','hamcrest-core','1.3')]))
run([J/'javac.exe','-J-Xmx64m','-classpath',cp,'-d',C/'test-classes',S/'SelectedV2BrowserTests.java'],'compile-runner.log')
run([J/'java.exe','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:ActiveProcessorCount=2','-XX:+UseSerialGC','-classpath',cp,'SelectedV2BrowserTests',C/'actual-tests.xml','v2UsesSameSourceApiForDefaultGetPostAndNonawaitUi'],'junit-failed-method.log')
