from pathlib import Path
import datetime,hashlib,io,json,subprocess,zipfile,xml.etree.ElementTree as E
R=Path('F:/yuedu-reader');S=Path(__file__).resolve().parent;SHA='88c61ee4b80889a617d344fda668d077f73fa95b'
def rf(b):return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def fact(p):return {'path':p.relative_to(R).as_posix(),**rf(p.read_bytes())}
def save(p,x):p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode('utf8'))
assert not(S/'factual-review-v1.json').exists()
jobs=json.loads((S/'terminal-jobs.json').read_bytes());job=jobs['jobs'][0]
assert len(jobs['jobs'])==1 and job['id']==118962039359 and job['run_id']==39520240533 and job['status']=='completed'and job['conclusion']=='failure'
artifacts=json.loads((S/'artifacts.json').read_bytes())['artifacts'];assert len(artifacts)==1;a=artifacts[0]
assert a['id']==12310602908 and a['size_in_bytes']==74979 and a['workflow_run']['head_sha']==SHA
z=S/'artifact.zip';assert rf(z.read_bytes())=={'bytes':74979,'sha256':a['digest'].split(':')[1]}
members=[];suites=[];caseids=set();failed=[];passed=0;errors=0;skipped=0
with zipfile.ZipFile(z)as archive:
 assert archive.testzip() is None
 for info in archive.infolist():
  name=info.filename;p=Path(name);assert not p.is_absolute()and'..'not in p.parts
  if info.is_dir():continue
  raw=archive.read(info);members.append({'path':name,**rf(raw)})
  if name.endswith('.xml')and'/test-results/'in name:
   doc=E.fromstring(raw);rows=doc.findall('.//testcase');suites.append({'member':name,**rf(raw),'cases':len(rows)})
   for case in rows:
    ident=case.attrib['classname']+'/'+case.attrib['name'];assert ident not in caseids;caseids.add(ident)
    f=case.find('failure');e=case.find('error');skip=case.find('skipped')
    if f is not None:failed.append({'identity':ident,'message':f.attrib.get('message'),'stack':f.text,'member':name})
    elif e is not None:errors+=1
    elif skip is not None:skipped+=1
    else:passed+=1
assert len(members)==64 and len(suites)==53 and len(caseids)==353 and len(failed)==5 and passed==348 and errors==skipped==0
save(S/'artifact-member-facts.json',members)
save(S/'junit-source-facts.json',{'suites':suites,'identities':sorted(caseids),'failures':failed})
checkpoint=json.loads((R/'docs/legado-ios/core-general-webjs-runtime-repairs-checkpoint.json').read_bytes())
native=[x for x in checkpoint['preservedEvidence']if Path(x['path']).name=='Native-source-inputs-v1.json'];assert len(native)==1
roster=json.loads((R/native[0]['path']).read_bytes());assert len(roster)==158
query=''.join(SHA+':'+row['path']+'\n'for row in roster).encode()
proc=subprocess.run(['D:/app/Git/cmd/git.exe','cat-file','--batch'],cwd=R,input=query,capture_output=True,check=True)
stream=io.BytesIO(proc.stdout);bound=[]
for row in roster:
 oid,kind,size=stream.readline().decode().strip().split();assert kind=='blob'
 raw=stream.read(int(size));assert stream.read(1)==b'\n'and rf(raw)=={k:row[k]for k in ('bytes','sha256')}
 bound.append({'path':row['path'],'gitBlob':oid,**rf(raw)})
assert not stream.read()
save(S/'historical-native158-source-binding.json',bound)
log=(S/'native-job.log').read_text('utf8');assert'353 tests completed, 5 failed'in log and'Execution failed for task' in log
failure_step=next(x for x in job['steps']if x['conclusion']=='failure');assert failure_step['number']==5
excerpts=[{'line':i+1,'text':line}for i,line in enumerate(log.splitlines())if any(t in line for t in ['FAILED','353 tests completed','Execution failed for task','Process completed with exit code'])]
save(S/'failure-excerpts.json',excerpts)
report={'schemaVersion':1,'frozenUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'Actual terminal failure; earliest failing workflow step built/tested ordinary JVM but no Simulator/native host executed. Immutable old-run facts only.',
 'sourceCommit':SHA,'runID':39520240533,'jobID':118962039359,'tag':'legado-native-reader-test-88c61ee','queryAgain':False,'jobStatus':'completed','conclusion':'failure',
 'earliestFailure':{'step':failure_step,'task':':test','processExitCode':1,'GradleBuildElapsed':'2m17s','tests':353,'passed':348,'failed':5,'errors':0,'skipped':0},
 'NativeSelectedMethodsExecuted':0,'MainJSMethodsExecuted':0,'SimulatorPayloadPrepared':False,'coldHostsExecuted':0,'AppOrJNIResultAccepted':False,
 'failedCases':failed,'ordinaryJUnit':{'XMLSuites':53,'uniqueCaseIdentities':353,'passed':348,'failed':5,'errors':0,'skipped':0},
 'artifact':{'artifactID':12310602908,**fact(z),'members':64,'CRCVerified':True,'GitHubDigestVerified':True,'downloadCount':1},
 'historicalExpectedNativeSourceClosure':{'count':158,'canonicalRoster':native[0],'gitCommit':SHA,'allGitBlobBytesMatched':True,'nativeSourceBeforeAfterWasNotProduced':True,'doesNotClaimCompleteGradleTransitiveClosure':True},
 'evidence':[fact(S/x)for x in ['terminal-jobs.json','artifacts.json','native-job.log','artifact-member-facts.json','junit-source-facts.json','historical-native158-source-binding.json','failure-excerpts.json','actual-test-failures.json']],
 'limits':['353 is actual JVM JUnit only; 348 passing cases do not validate5 failed cases or later repairs.','Restore native interpreter, simulator payload, original28/MainJS1 and cold2 phases were skipped after Gradle:test failure.','A separate later5-method repair has no effect on this terminal conclusion.','SDK39520239925 remains a separate live workflow managed by root; this review neither queried it nor states its result.'],
 'operations':{'newTags':False,'reruns':False,'productionWrites':False,'canonicalWrites':False,'oldFc3Queries':False,'SDKQueries':False}}
save(S/'factual-review-v1.json',report);print(json.dumps({'manifest':fact(S/'factual-review-v1.json'),'caseCounts':[353,348,5,0],'members':64}))
