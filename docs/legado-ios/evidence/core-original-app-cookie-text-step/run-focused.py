import datetime,hashlib,json,os,subprocess,sys,xml.etree.ElementTree as ET
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[1];jvm=base/'jvm-work';version=sys.argv[1]
classes=sys.argv[2:] or ['AppCookieOwnerTextTest'];classes=['io.yuedu.legado.'+n for n in classes]
recordPath=base/f'focused-{version}.json';assert not recordPath.exists()
command=[str(root/'.tools/gradle-8.14.3/bin/gradle.bat'),'-p',str(jvm),'--offline','--no-daemon','--console=plain','test','--rerun']
for name in classes:command+=['--tests',name]
env=os.environ.copy();env['JAVA_HOME']=str(root/'.tools/jdk21/jdk-21.0.12.1+1');env['GRADLE_USER_HOME']=str(root/'.tools/gradle-user-home')
inputs=[];paths=list((jvm/'src').rglob('*.kt'))+list((jvm/'src').rglob('*.java'))+[jvm/'build.gradle.kts']
for p in sorted(paths):
 rel=p.relative_to(jvm);raw=p.read_bytes();snap=base/f'focused-{version}-sources'/rel;snap.parent.mkdir(parents=True,exist_ok=True);snap.write_bytes(raw)
 origin=base/'work/Packages/LegadoRuntime/jvm'/rel
 if not origin.exists():origin=root/'Packages/LegadoRuntime/jvm'/rel
 assert origin.read_bytes()==raw
 inputs.append(dict(path='Packages/LegadoRuntime/jvm/'+rel.as_posix(),actualExecutionPath=p.as_posix(),sourcePath=origin.as_posix(),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
start=datetime.datetime.now(datetime.timezone.utc).isoformat();print(json.dumps(dict(startedAtUTC=start,command=command,sourceInputs=len(inputs),log=str(base/f'focused-{version}.log'))),flush=True)
with (base/f'focused-{version}.log').open('wb') as log:result=subprocess.run(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
finish=datetime.datetime.now(datetime.timezone.utc).isoformat();log=(base/f'focused-{version}.log').read_bytes();suites=[]
for name in classes:
 p=jvm/f'build/test-results/test/TEST-{name}.xml'
 if p.exists() and datetime.datetime.fromtimestamp(p.stat().st_mtime,datetime.timezone.utc)>=datetime.datetime.fromisoformat(start):
  raw=p.read_bytes();dest=base/f'focused-{version}-xml'/p.name;dest.parent.mkdir(exist_ok=True);dest.write_bytes(raw);suite=ET.fromstring(raw)
  suites.append(dict(name=name,tests=int(suite.attrib['tests']),failures=int(suite.attrib['failures']),errors=int(suite.attrib['errors']),skipped=int(suite.attrib['skipped']),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
unchanged=all(Path(item['actualExecutionPath']).read_bytes()==(base/f'focused-{version}-sources'/item['path'].removeprefix('Packages/LegadoRuntime/jvm/')).read_bytes() for item in inputs)
record=dict(command=command,startedAtUTC=start,finishedAtUTC=finish,exitCode=result.returncode,sourceBinding=inputs,executionSourcesUnchanged=unchanged,logBytes=len(log),logSHA256=hashlib.sha256(log).hexdigest(),junitSuites=suites,scope='Actual Windows JDK21 JVM on isolated ignored source copy and controlled temporary state/loopback host; no native/Swift/device/App route acceptance')
recordPath.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8',newline='\n');print(json.dumps({k:v for k,v in record.items() if k!='sourceBinding'}));print(log.decode('utf-8',errors='replace')[-8000:]);raise SystemExit(result.returncode)
