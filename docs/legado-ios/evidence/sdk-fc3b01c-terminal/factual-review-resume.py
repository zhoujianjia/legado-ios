from pathlib import Path
import hashlib,json,re,subprocess,xml.etree.ElementTree as ET,zipfile
R=Path.cwd(); S=Path(__file__).parent; G='D:/app/Git/cmd/git.exe'
A=S/'extracted-12307712232/reader-renewal-probe'; P=S/'extracted-12307082572/reader-renewal-original-api'
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def save(p,v): p.write_text(json.dumps(v,indent=2,ensure_ascii=False)+'\n',encoding='utf-8',newline='\n')
run=read(S/'terminal-run.json'); assert run['status']=='completed' and run['conclusion']=='failure'
source=run['head_sha']; assert source=='fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a'
inputs=read(A/'source-inputs.json'); pkg=read(P/'result.json'); pipeline=read(A/'currentcore-pipeline.json'); completion=read(A/'currentcore-completion.json')
roster={r['path']:r for r in inputs['sourceInputs']+pkg['sourceInputs']}; assert len(inputs['sourceInputs'])==338 and len(pkg['sourceInputs'])==23
names=list(roster); batch=subprocess.run([G,'cat-file','--batch'],input=''.join(source+':'+n+'\n' for n in names).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
offset=0; bindings=[]
for name in names:
    end=batch.index(b'\n',offset); header=batch[offset:end].decode().split(); assert header[1]=='blob',name
    count=int(header[2]); data=batch[end+1:end+1+count]; offset=end+count+2
    row=roster[name]; assert len(data)==row['bytes'] and hashlib.sha256(data).hexdigest()==row['sha256'],name
    bindings.append(dict(path=name,gitBlob=header[0],**{k:row[k] for k in ('bytes','sha256')}))
assert offset==len(batch)
save(S/'historical-source-binding.json',dict(sourceCommit=source,AppInputs=338,PackageInputs=23,uniqueInputs=len(bindings),gitCatFileBatchProcesses=1,allGitBlobBytesMatched=True,inputs=bindings))
phaseRows=[]
for phase in pipeline['phases']:
    assert phase['sourceBefore']==phase['sourceAfter']==pipeline['source']
    command=phase['command']
    if command:
        for pathKey,bytesKey,hashKey in [('output','bytes','sha256'),('stderr','stderrBytes','stderrSHA256')]:
            path=A/Path(command[pathKey]).name; assert fact(path)==dict(bytes=command[bytesKey],sha256=command[hashKey]),str(path)
    phaseRows.append(dict(phase=phase['phase'],state=phase['state'],elapsedSeconds=phase['elapsedSeconds'],command=command))
assert completion['firstFailure']==dict(phase='native',exitCode=124) and not completion['resultProduced']
assert (A/'currentcore-summary.json').stat().st_size==(A/'currentcore-tests.json').stat().st_size==0
assert pipeline['source']['sourceInputCount']==338 and pipeline['qualifiedMethodDefinitions']==463 and pipeline['argumentLeaves']==466
log=(A/'currentcore-tests.log').read_text(encoding='utf-8'); lines=log.splitlines()
issues=[dict(line=i+1,text=line) for i,line in enumerate(lines) if 'recorded an issue at' in line]
failures=[dict(line=i+1,text=line) for i,line in enumerate(lines) if re.match(r'^✘ Test .* failed after ',line)]
passes=[dict(line=i+1,text=line) for i,line in enumerate(lines) if re.match(r'^✔ Test .* passed after ',line)]
starts=[dict(line=i+1,text=line) for i,line in enumerate(lines) if re.match(r'^◇ Test .* started\.',line)]
crashes=[dict(line=i+1,text=line) for i,line in enumerate(lines) if 'Fatal error:' in line or 'Restarting after unexpected exit' in line]
partial=dict(completeSuiteAcceptance=False,reason='Invocation exceeded3720 second budget; result exports empty; textual records are partial diagnostics, including restart/unknown-name duplicates.',log=fact(A/'currentcore-tests.log'),observedStartLines=len(starts),observedPassedLines=len(passes),observedFailedLines=len(failures),issueLines=len(issues),starts=starts,passes=passes,failures=failures,issues=issues,crashOrRestartLines=crashes,lastLines=lines[-22:])
save(S/'partial-native-diagnostics.json',partial)
assert pkg['status']=='passed' and (pkg['totalTestCount'],pkg['failedTests'],pkg['skippedTests'])==(24,0,0)
for name,digest in pkg['evidenceSHA256'].items(): assert fact(P/name)['sha256']==digest,name
execution=read(P/'execution.json'); assert execution['exitCode']==0 and not execution['timedOut'] and execution['completed']
root=ET.parse(P/'xunit.xml').getroot(); cases=root.findall('.//testcase'); assert len(cases)==24 and not root.findall('.//failure') and not root.findall('.//error') and not root.findall('.//skipped')
xmlIDs={c.attrib['classname']+'/'+c.attrib['name'] for c in cases}; assert xmlIDs==set(pkg['qualifiedXCTestMethods'])==set(pkg['passedCaseIdentifiers'])==set(pkg['verbosePassedCaseIdentifiers'])
producer=S/'extracted-12307712232/reader-renewal-sdk-produced-public'
files=[p.relative_to(S/'extracted-12307712232').as_posix() for p in (S/'extracted-12307712232').rglob('*') if p.is_file() and 'xcresult' not in p.as_posix()]
report=dict(version=1,sourceCommit=source,workflowRun=run['id'],SDKJob=118918888695,status='completed-failure-native-timeout-with-real-runtime-failures',sourceBinding=dict(path='historical-source-binding.json',**fact(S/'historical-source-binding.json')),AppSDK=dict(selectedDefinitions=463,intendedLeaves=466,testTargetCompilationPassed=True,completeSuiteAcceptance=False,firstFailure=completion['firstFailure'],nativeTimeoutSeconds=3720,phases=phaseRows,summaryBytes=0,testsBytes=0,resultProduced=False,partialDiagnostics=dict(path='partial-native-diagnostics.json',**fact(S/'partial-native-diagnostics.json')),requiredSignerObserved=True,requiredSignerFailed='malformedDER'),Package=dict(passed=24,failed=0,skipped=0,sourceInputs=23,XMLAndVerboseIDsMatch=True,execution=execution),publicArtifactNonXCResultMembers=files,testsRerun=0,limits=['No complete App case/leaf total or suite pass is established.','Runtime failures are actual evidence requiring repairs, not a compiler-only failure.','Independent Package24 and Native349/27 passes do not accept the App renewal suite.','No later S4/C5/S2/WebJS/Base64 source, physical device, actual Apple authorization, replacement install or unattended expiry extension accepted.'])
save(S/'factual-review-v1.json',report)
print(json.dumps(dict(sourceBindings=len(bindings),AppSuite='incomplete timeout',Package=24,partialIssueLines=len(issues),partialPassedLines=len(passes),partialFailedLines=len(failures),testsRerun=0)))
