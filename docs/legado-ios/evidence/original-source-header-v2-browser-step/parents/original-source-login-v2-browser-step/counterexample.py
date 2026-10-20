from pathlib import Path
import hashlib,json,subprocess,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'counterexample';E.mkdir(exist_ok=True)
J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=R/'.build/original-source-login-browser-post-step/snapshot-v1/legado-runtime.jar'
assert hashlib.sha256(jar.read_bytes()).hexdigest()=='91d337f590f6c433206747caa41c731f045dc2f3aa3d1ebbae552ff99b715a81'
commands=[]
for name,argv in [('compile.log',[J/'javac.exe','-J-Xmx64m','-classpath',jar,'-d',E,S/'PublicV2BrowserCounterexample.java']),('execute.log',[J/'java.exe','-Xmx160m','-XX:ActiveProcessorCount=2','-classpath',str(jar)+';'+str(E),'PublicV2BrowserCounterexample'])]:
 p=subprocess.run(list(map(str,argv)),cwd=R,capture_output=True);(E/name).write_bytes(p.stdout+p.stderr)
 commands.append(dict(argv=list(map(str,argv)),exitCode=p.returncode,log=name));print(name,p.returncode,flush=True)
 (E/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8')
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
print((E/'execute.log').read_text(encoding='utf-8'))
