from pathlib import Path
import json,os,subprocess,sys
R=Path('F:/yuedu-reader');S=R/'.build/original-source-login-browser-await-step';C=S/'execution-v1';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';jar=C/'legado-runtime-await-incremental.jar';out=C/'ordinary-final-v2';out.mkdir();classes=out/'classes';classes.mkdir();commands=[]
for args,name in [([J/'javac.exe','-J-Xmx64m','-J-XX:+UseSerialGC','-J-XX:CompressedClassSpaceSize=32m','-J-XX:ReservedCodeCacheSize=32m','-cp',jar,'-d',classes,S/'OrdinaryLoginBrowserAwaitSmoke.java'],'compile.log'),([J/'java.exe','-Xms16m','-Xmx128m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC','-cp',str(jar)+os.pathsep+str(classes),'OrdinaryLoginBrowserAwaitSmoke'],'execute.log')]:
 args=list(map(str,args));commands.append(dict(argv=args,log=name));(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8')
 p=subprocess.run(args,cwd=R,capture_output=True);(out/name).write_bytes(p.stdout+p.stderr);print(name,'exit',p.returncode,flush=True)
 if p.returncode:print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-5000:]);sys.exit(p.returncode)
print((out/'execute.log').read_text(encoding='utf-8').strip(),flush=True)
