from pathlib import Path
import json,os,subprocess,sys
R=Path('F:/yuedu-reader');S=R/'.build/original-source-login-browser-host-step';C=S/'execution-v1';J=R/'.tools/jdk21/jdk-21.0.12.1+1/bin';p=S/'SelectedBrowserTests.java';before=p.read_bytes();assert before.startswith(b'\xef\xbb\xbf');(C/'SelectedBrowserTests-with-BOM.java').write_bytes(before);p.write_bytes(before[3:]);(C/'runner-encoding-history.json').write_text(json.dumps(dict(issue='PowerShell Set-Content UTF8 added BOM; javac rejected runner before tests. Synthetic runner only, production and Kotlin tests unchanged.',fix='Remove only leading UTF8 BOM, preserve original runner source and failed javac log.',JVMTestsExecutedAtFailure=0),indent=2)+'\n',encoding='utf-8')
commands=json.loads((C/'commands.json').read_text());javac=commands[-1]['argv'];assert commands[-1]['log']=='compile-java.log'
def run(args,name):
 commands.append(dict(argv=list(map(str,args)),log=name));(C/'commands.json').write_text(json.dumps(commands,indent=2)+'\n',encoding='utf-8')
 result=subprocess.run(list(map(str,args)),cwd=R,capture_output=True);(C/name).write_bytes(result.stdout+result.stderr);print(name,'exit',result.returncode,flush=True)
 if result.returncode:print((result.stdout+result.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-6000:]);sys.exit(result.returncode)
run(javac,'compile-java-no-bom.log')
vm=['-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:CompressedClassSpaceSize=32m','-XX:ReservedCodeCacheSize=32m','-XX:ActiveProcessorCount=2','-Xss512k','-XX:+UseSerialGC'];jar=C/'legado-runtime-browser-incremental.jar';tests=C/'test-classes';cp=javac[javac.index('-cp')+1]
run([J/'java.exe',*vm,'-cp',cp,'SelectedBrowserTests',C/'actual-tests.xml'],'junit-browser.log')
run([J/'java.exe',*vm,'-cp',os.pathsep.join(map(str,[jar,tests])),'OrdinaryLoginBrowserSmoke'],'ordinary-java.log')
print('actual bounded JVM4 and external Java5 complete',flush=True)
