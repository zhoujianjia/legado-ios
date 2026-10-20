from pathlib import Path
import hashlib,json,subprocess,time
R=Path('F:/yuedu-reader');S=Path(__file__).parent;E=S/'ordinary-v1';E.mkdir(exist_ok=False);J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';commands=[]
jar=S/'legado-runtime-base64.jar';base=R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/legado-runtime.jar'
def run(name,argv):
 argv=list(map(str,argv));t=time.monotonic();p=subprocess.run(argv,cwd=R,capture_output=True);log=E/(name+'.log');log.write_bytes(p.stdout+p.stderr);commands.append({'name':name,'argv':argv,'exitCode':p.returncode,'seconds':round(time.monotonic()-t,3),'log':{'path':str(log.relative_to(S)),'bytes':log.stat().st_size,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()}});(E/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8',newline='\n');print(name,p.returncode,commands[-1]['seconds'],flush=True);print((p.stdout+p.stderr).decode('utf-8',errors='replace')[-6000:]);return p.returncode
assert run('compile',[J/'javac.exe','-J-Xmx64m','-encoding','UTF-8','-classpath',jar,'-d',E,S/'oracle-source/android/util/Base64.java',S/'OrdinaryBase64Flags.java'])==0
common=[J/'java.exe','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:ActiveProcessorCount=2','-XX:+UseSerialGC','-Dfile.encoding=UTF-8','-classpath']
assert run('baseline-public',[*common,str(base)+';'+str(E),'OrdinaryBase64Flags','baseline'])==0
raise SystemExit(run('candidate-public',[*common,str(jar)+';'+str(E),'OrdinaryBase64Flags']))
