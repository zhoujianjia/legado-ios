from pathlib import Path
import hashlib,json,os,subprocess,sys
S=Path(__file__).parent;R=S.parent.parent;C=S/'execution-v1/ordinary-final';C.mkdir();classes=C/'classes';classes.mkdir();J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=S/'execution-v1/legado-runtime-post-incremental.jar'
assert hashlib.sha256(jar.read_bytes()).hexdigest()=='91d337f590f6c433206747caa41c731f045dc2f3aa3d1ebbae552ff99b715a81'
commands=[]
def run(args,name):
 commands.append({'argv':list(map(str,args)),'log':name});(C/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8')
 p=subprocess.run(list(map(str,args)),capture_output=True,cwd=R);(C/name).write_bytes(p.stdout+p.stderr);print(name,p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace'));sys.exit(p.returncode)
run([J/'javac.exe','-J-Xmx64m','-J-XX:+UseSerialGC','-J-XX:CompressedClassSpaceSize=32m','-J-XX:ReservedCodeCacheSize=32m','-classpath',jar,'-d',classes,S/'OrdinaryLoginBrowserPostSmoke.java'],'compile.log')
run([J/'java.exe','-Xms16m','-Xmx160m','-XX:+UseSerialGC','-XX:ActiveProcessorCount=2','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-classpath',os.pathsep.join(map(str,[jar,classes])),'OrdinaryLoginBrowserPostSmoke'],'execute.log')
