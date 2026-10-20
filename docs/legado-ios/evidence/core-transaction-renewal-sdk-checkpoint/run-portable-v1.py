from pathlib import Path
import subprocess,sys,time,json,hashlib,os
root=Path.cwd();base=root/'.build/renewal-discovery/transaction-renewal-selection-gates'
files=['.github/workflows/reader-renewal-probe.yml','scripts/reader-experience/renewal-probe-tools.py','scripts/reader-experience/renewal-probe-tests.sh','scripts/reader-experience/test-renewal-probe-tools.py']
sources=[]
for name in files:
 raw=(root/name).read_bytes();dst=base/'portable-v1-sources'/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(raw)
 sources.append({'path':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
commands=[('renewal-guards',[sys.executable,'-B','scripts/reader-experience/test-renewal-probe-tools.py','-v']),('existing-smoke-guards',[sys.executable,'-B','scripts/reader-experience/test-smoke-tools.py','-v']),('report-inspector-guards',[sys.executable,'-B','scripts/reader-experience/test-inspect-renewal-report.py','-v']),('original-api-guards',[sys.executable,'-B','scripts/reader-experience/test-original-api-package-tools.py','-v']),('bash-syntax',['D:/app/Git/bin/bash.exe','-n','scripts/reader-experience/renewal-probe-tests.sh']),('workflow-actionlint',[str(root/'.tools/actionlint/actionlint.exe'),'-color','.github/workflows/reader-renewal-probe.yml'])]
rows=[]
for name,argv in commands:
 start=time.monotonic();p=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,cwd=root)
 log=base/(name+'-v1.log');log.write_bytes(p.stdout)
 row={'name':name,'argv':argv,'exitCode':p.returncode,'elapsedSeconds':round(time.monotonic()-start,3),'log':log.relative_to(root).as_posix(),'bytes':len(p.stdout),'sha256':hashlib.sha256(p.stdout).hexdigest()};rows.append(row)
 print(json.dumps({k:row[k] for k in ['name','exitCode','elapsedSeconds','bytes']}),flush=True)
unchanged=all((root/row['path']).read_bytes()==(base/'portable-v1-sources'/row['path']).read_bytes() for row in sources)
record={'schemaVersion':1,'sourceBinding':sources,'commands':rows,'sourceUnchangedDuringExecution':unchanged,'SDKExecuted':False,'JVMExecuted':False,'cloudQueried':False}
(base/'portable-v1.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
sys.exit(0 if unchanged and all(row['exitCode']==0 for row in rows) else 1)
