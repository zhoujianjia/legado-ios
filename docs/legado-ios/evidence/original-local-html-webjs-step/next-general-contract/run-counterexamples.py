from pathlib import Path
import datetime, hashlib, json, subprocess, time
R=Path('F:/yuedu-reader'); S=R/'.build/original-general-webjs-step'
jar=R/'.build/consolidated-header-v2-browser-source-step/snapshot-v1/legado-runtime.jar'
def fact(p):
    b=p.read_bytes(); return dict(path=p.relative_to(R).as_posix(),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
assert fact(jar)['sha256']=='df6f572adfd6c18ca67d98573be86dcf9e65f0c0d8b603eae60f054e8c29eac3'
out=S/'ordinary'; out.mkdir(exist_ok=False)
jdk=R/'.tools/jdk21/jdk-21.0.12.1+1/bin'
commands=[([str(jdk/'javac.exe'),'-J-Xmx64m','-classpath',str(jar),'-d',str(out),str(S/'GeneralWebJSUnsupported.java')],'compile'),
          ([str(jdk/'java.exe'),'-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:ActiveProcessorCount=2','-XX:+UseSerialGC','-classpath',str(jar)+';'+str(out),'GeneralWebJSUnsupported'],'execute')]
rows=[]
for argv,name in commands:
    started=time.monotonic(); run=subprocess.run(argv,cwd=R,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log=out/(name+'.log'); log.write_bytes(run.stdout)
    rows.append(dict(argv=argv,exitCode=run.returncode,seconds=round(time.monotonic()-started,3),log=fact(log)))
    if run.returncode:
        (S/'failed-command-v1.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
        print(run.stdout.decode('utf-8')); raise SystemExit(run.returncode)
text=(out/'execute.log').read_text(encoding='utf-8'); assert 'calls=3 unsupported=3' in text
result=dict(recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    scope='New ordinary public-boundary counterexamples on the unchanged coherent fc3 JAR only; not a new implementation.',
    jar=fact(jar),consumer=fact(S/'GeneralWebJSUnsupported.java'),commands=rows,
    counts=dict(sessions=1,publicCalls=3,unsupported=3,network=0,JUnit=0,JNI=0,SwiftSDK=0,WK=0),
    limitations=['Explicit local-HTML login pages and these three general browser operations are separate original contracts.',
      'No private source, account or externally reachable site used. No current WebJS candidate or existing passing suite rerun.'])
(S/'counterexamples-v1.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(text.strip())
