from pathlib import Path
import hashlib,json,subprocess,sys
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'ordinary-final';E.mkdir(exist_ok=False);J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=S/'execution-v1/legado-runtime-v2-browser.jar';commands=[]
for name,argv in [('compile.log',[J/'javac.exe','-J-Xmx64m','-classpath',jar,'-d',E,S/'OrdinaryV2BrowserSmoke.java']),('execute.log',[J/'java.exe','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:ActiveProcessorCount=2','-XX:+UseSerialGC','-classpath',str(jar)+';'+str(E),'OrdinaryV2BrowserSmoke'])]:
 p=subprocess.run(list(map(str,argv)),cwd=R,capture_output=True);(E/name).write_bytes(p.stdout+p.stderr);commands.append(dict(argv=list(map(str,argv)),exitCode=p.returncode,log=name));(E/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8');print(name,p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
print((E/'execute.log').read_text(encoding='utf-8'))
