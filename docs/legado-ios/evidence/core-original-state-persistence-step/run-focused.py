import datetime,hashlib,json,os,subprocess,sys,xml.etree.ElementTree as ET
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent;version=sys.argv[1]
classes=['io.yuedu.legado.'+n for n in (sys.argv[2:] or ['OriginalUrlRequestOptionsTest'])]
classes=[n.replace('io.yuedu.legado.io.legado.app.','io.legado.app.') for n in classes]
assert not (out/f'focused-{version}.json').exists()
command=[str(root/'.tools/gradle-8.14.3/bin/gradle.bat'),'-p',str(root/'Packages/LegadoRuntime/jvm'),'--offline','--no-daemon','--console=plain','test']
for name in classes:command+=['--tests',name]
env=os.environ.copy();env['JAVA_HOME']=str(root/'.tools/jdk21/jdk-21.0.12.1+1');env['GRADLE_USER_HOME']=str(root/'.tools/gradle-user-home')
paths=list((root/'Packages/LegadoRuntime/jvm/src/main').rglob('*.kt'))
paths+=list((root/'Packages/LegadoRuntime/jvm/src/test').rglob('*.kt'))
paths+=list((root/'Packages/LegadoRuntime/jvm/src/test').rglob('*.java'))
paths+=list(p for p in (root/'Packages/LegadoRuntime/jvm/src/test/resources').rglob('*') if p.is_file())
paths.append(root/'Packages/LegadoRuntime/jvm/build.gradle.kts')
binding=[]
for path in sorted(paths):
 data=path.read_bytes();name=path.relative_to(root).as_posix();target=out/f'focused-{version}-sources'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);binding.append(dict(path=name,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
result=subprocess.run(command,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
finish=datetime.datetime.now(datetime.timezone.utc).isoformat();log=result.stdout;(out/f'focused-{version}.log').write_bytes(log)
record=dict(command=command,startedAtUTC=start,finishedAtUTC=finish,exitCode=result.returncode,sourceBinding=binding,logBytes=len(log),logSHA256=hashlib.sha256(log).hexdigest(),junitSuites=[],scope='Actual Windows JDK21 JVM; injected persistent owner with controlled temporary files, separate child JVM recovery and owned loopback. No Android/iOS/real-device/App-route acceptance.')
for name in classes:
 p=root/f'Packages/LegadoRuntime/jvm/build/test-results/test/TEST-{name}.xml'
 if p.exists() and datetime.datetime.fromtimestamp(p.stat().st_mtime,datetime.timezone.utc)>=datetime.datetime.fromisoformat(start):
  data=p.read_bytes();dest=out/f'focused-{version}-xml'/p.name;dest.parent.mkdir(exist_ok=True);dest.write_bytes(data);suite=ET.fromstring(data);record['junitSuites'].append(dict(name=name,tests=int(suite.attrib['tests']),failures=int(suite.attrib['failures']),errors=int(suite.attrib['errors']),skipped=int(suite.attrib['skipped']),bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
(out/f'focused-{version}.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in record.items() if k!='sourceBinding'}));print(log.decode('utf-8',errors='replace')[-9000:]);raise SystemExit(result.returncode)
