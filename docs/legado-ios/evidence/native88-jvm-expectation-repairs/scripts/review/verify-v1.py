from pathlib import Path
import datetime
import difflib
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile

R = Path('F:/yuedu-reader')
P = R / '.build/native-88c61ee-stale-expectation-repair-step'
S = R / '.build/native-88c61ee-stale-expectation-independent-review'
S.mkdir(parents=True, exist_ok=True)
checks = []
def sha(b): return hashlib.sha256(b).hexdigest()
def fact(p):
    b=p.read_bytes()
    return dict(path=p.relative_to(R).as_posix(),bytes=len(b),sha256=sha(b))
def check(name,ok,actual=None): checks.append(dict(name=name,passed=bool(ok),actual=actual))
def bind(d, actual_path=None):
    p=actual_path or R/d['path']
    f=fact(p)
    check('binding:'+str(d['path']),f['bytes']==d['bytes'] and f['sha256']==d['sha256'],f)
    return f
def bind_nested(d):
    if isinstance(d,dict):
        if {'path','bytes','sha256'} <= d.keys(): bind(d)
        for v in d.values(): bind_nested(v)
    elif isinstance(d,list):
        for v in d: bind_nested(v)
def load(p): return json.loads(p.read_text(encoding='utf-8'))

final_path=P/'final-v1.json'
ff=fact(final_path)
check('exact frozen final',ff['bytes']==16995 and ff['sha256']=='6bd803439b17bb992fce15aec522e1cabf4580679e787de3efcbf73df48a568f',ff)
d=load(final_path)
check('five existing test-only source files',len(d['files'])==5 and all('/src/test/' in x['path'] for x in d['files']))
bind(d['actualTerminal']); bind(d['runtimeJar'])
for x in d['historyEvidence']: bind(x)
bind(d['compiledClassBindings'])
pre=load(S/'pre-review-v1.json')
check('pre-review terminal actual totals',pre['totals']==dict(tests=353,failures=5,errors=0,skipped=0) and pre['xmlSuites']==53)

old_by_class={};new_by_class={};source_details=[]
for f in d['files']:
    bp=R/d['baselineRoot']/f['path'];cp=R/d['candidateRoot']/f['path']
    old=bp.read_bytes();new=cp.read_bytes()
    check('baseline:'+f['path'],len(old)==f['baseline']['bytes'] and sha(old)==f['baseline']['sha256'])
    check('candidate:'+f['path'],len(new)==f['candidate']['bytes'] and sha(new)==f['candidate']['sha256'])
    check('current canonical baseline:'+f['path'],(R/f['path']).read_bytes()==old)
    result=subprocess.run(['git','cat-file','blob',d['sourceCommit']+':'+f['path']],cwd=R,capture_output=True)
    check('actual source commit blob:'+f['path'],result.returncode==0 and result.stdout==old)
    classname,method=f['changedMethod'].split('/')
    token=('fun '+method+'(').encode()
    start_old=old.index(token);start_new=new.index(token)
    end_old=old.index(b'\n    @Test',start_old+1);end_new=new.index(b'\n    @Test',start_new+1)
    check('all source bytes outside target method unchanged:'+classname,old[:start_old]==new[:start_new] and old[end_old:]==new[end_new:])
    names=lambda b:re.findall(rb'@Test(?:\([^)]*\))?\s+fun\s+(\w+)',b)
    check('all test identities and order exact:'+classname,names(old)==names(new) and len(names(new))==d['definitionIdentities']['perRootCounts'][classname],dict(count=len(names(new))))
    bind(f['diff'])
    diff=''.join(difflib.unified_diff(old.decode('utf-8').splitlines(True),new.decode('utf-8').splitlines(True),fromfile='a/'+f['path'],tofile='b/'+f['path'])).encode()
    check('actual unified diff exact:'+classname,diff==(R/f['diff']['path']).read_bytes())
    old_by_class[classname]=old.decode('utf-8');new_by_class[classname]=new.decode('utf-8')
    source_details.append(dict(path=f['path'],baseline=fact(bp),candidate=fact(cp),target=f['changedMethod'],oldTargetBytes=end_old-start_old,newTargetBytes=end_new-start_new))
check('source root inventory exact',sorted(p.relative_to(R/d['candidateRoot']).as_posix() for p in (R/d['candidateRoot']).rglob('*') if p.is_file())==sorted(f['path'] for f in d['files']))

# Re-read raw terminal XML rather than treating a summarized failure count as a pass.
artifact=R/'.build/native-88c61ee-terminal/artifact.zip'
terminal=[];terminal_failures=[]
with zipfile.ZipFile(artifact) as z:
    check('terminal ZIP CRC and members',z.testzip() is None and len(z.infolist())==64)
    for name in z.namelist():
        if name.endswith('.xml') and '/test-results/test/' in name:
            raw=z.read(name);root=ET.fromstring(raw)
            terminal.append(dict(member=name,bytes=len(raw),sha256=sha(raw),**{k:int(root.get(k,'0')) for k in ['tests','failures','errors','skipped']}))
            for case in root.findall('testcase'):
                for error in list(case.findall('failure'))+list(case.findall('error')):
                    terminal_failures.append(dict(identity=case.get('classname')+'/'+case.get('name'),message=error.get('message'),member=name))
check('actual terminal remains 353 with five failures',len(terminal)==53 and {k:sum(x[k] for x in terminal) for k in ['tests','failures','errors','skipped']}==dict(tests=353,failures=5,errors=0,skipped=0))
targets=d['actualValidation']['exactFinalSuccessfulIdentities']
check('changed targets exactly original actual failed methods',sorted(f['identity'] for f in terminal_failures)==sorted(targets))

v1=load(P/'execution-v1/commands.json');v2=load(P/'execution-v2/commands.json');v3=load(P/'execution-v3/commands.json')
for version,commands in [('v1',v1),('v2',v2),('v3',v3)]:
    for command in commands['commands']: bind(command['log'])
check('first compile failed and no JUnit phase',len(v1['commands'])==1 and v1['commands'][0]['exitCode']!=0 and not (P/'execution-v1/actual-tests.xml').exists())
check('v2 compile and runner successful, actual target test phase failed',[x['exitCode'] for x in v2['commands']]==[0,0,1])
check('v3 all affected steps successful',[x['exitCode'] for x in v3['commands']]==[0,0,0])
check('no production compile roots',all('/src/main/' not in a.replace('\\','/') for version in [v1,v2,v3] for command in version['commands'] for a in command['argv'] if a.endswith(('.kt','.java'))))
for version,commands,count in [('v2',v2,8),('v3',v3,2)]:
    compile_cmd=commands['commands'][0]['argv']
    roots=[a for a in compile_cmd if a.endswith('.kt')]
    check('bounded test root count:'+version,len(roots)==count,roots)
    check('bounded small heap:'+version,'-Xmx160m' in compile_cmd and '-XX:+UseSerialGC' in compile_cmd)
    run=commands['commands'][2]['argv'];cp=run[run.index('-cp')+1].split(';')
    jar_abs=str(R/d['runtimeJar']['path'])
    check('fresh test classes first and same ordinary production JAR:'+version,cp[0]==str(P/('execution-'+version)/'classes') and cp[1]==jar_abs and len(cp)==4 and 'junit-4.13.2.jar' in cp[2] and 'hamcrest-core-1.3.jar' in cp[3],cp)
    selected=[a for a in run if a.startswith('io.yuedu.legado.') and '/' in a]
    check('exact selected methods:'+version,selected==(targets if version=='v2' else [targets[3]]),selected)

for captured in v2['sources']:
    # v2 deliberately captured the prior V2 test. Its immutable historical
    # copy, not successor work bytes, binds that compilation input.
    historical=P/'history-v2'/'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginV2BrowserTest.kt'
    if captured['path'].endswith('/OriginalSourceLoginV2BrowserTest.kt'): bind(captured,historical)
    else: bind(captured)
bind_nested(load(P/'execution-v3/source-binding.json'))
bind_nested(load(P/'compiled-test-class-bindings.json'))
for helper in load(P/'test-helper-facts.json'):
    bind(helper['original']);bind(helper['copy'])
    raw=(R/helper['original']['path']).read_bytes();copied=(R/helper['copy']['path']).read_bytes()
    if helper['extraction'] is False: check('unchanged helper exact:'+helper['copy']['path'],raw==copied)
    else:
        tail=raw[helper['objectByteOffset']:]
        check('exact existing Gate object extracted without behavior change',len(tail)==helper['originalObject']['bytes'] and sha(tail)==helper['originalObject']['sha256'] and copied.endswith(tail))

def xml_result(p):
    root=ET.fromstring(p.read_bytes());cases=root.findall('testcase')
    return dict(file=fact(p),tests=int(root.get('tests','0')),failures=int(root.get('failures','0')),skipped=int(root.get('skipped','0')),cases=[dict(identity=c.get('classname')+'/'+c.get('name'),failed=bool(c.findall('failure')+c.findall('error'))) for c in cases])
x2=xml_result(P/'execution-v2/actual-tests.xml');x3=xml_result(P/'execution-v3/actual-tests.xml')
check('five actual methods first round exact',x2['tests']==5 and x2['failures']==1 and x2['skipped']==0 and [c['identity'] for c in x2['cases']]==targets and [c['identity'] for c in x2['cases'] if c['failed']]==[targets[3]])
check('one actual method successor exact',x3['tests']==1 and x3['failures']==0 and x3['skipped']==0 and [c['identity'] for c in x3['cases']]==[targets[3]])
check('five final distinct successes and six executions',len({c['identity'] for c in x2['cases']+x3['cases'] if not c['failed']})==5 and x2['tests']+x3['tests']==6)
for classname in new_by_class:
    if classname!='OriginalSourceLoginV2BrowserTest':
        record=next(f for f in v2['sources'] if f['path'].endswith('/'+classname+'.kt'))
        check('prior passing source exactly final:'+classname,sha(new_by_class[classname].encode())==record['sha256'])
for runner,count in [('FiveMethodsRunner.java',5),('OneMethodRunner.java',1)]:
    body=(P/runner).read_text(encoding='utf-8')
    check('runner executes JUnit Request.method only:'+runner,'core.run(Request.method(Class.forName(target[0]),target[1]))' in body and f'count!={count}||failed!=0||ignored!=0' in body)

def has(cls,*tokens): return all(t in new_by_class[cls] for t in tokens)
guard_checks=[
 ('Base64 separate flags0 is hello and malformed rejects',has('OriginalAnalyzeRuleTest','assertEquals("hello", rule.evalJS("java.base64Decode(\'aGVsbG8=\',0)"))','java.base64Decode(\'A\',0)','aG Vs','ISO-8859-1')),
 ('Await invalid presentation empty result wrong mode and cancel remain',has('OriginalSourceLoginBrowserAwaitTest','Triple("presented","DOM","INVALID_BROWSER_RESULT")','Triple("response","","BROWSER_EMPTY_RESULT")','Triple("refetchConfirmed","DOM","INVALID_BROWSER_RESULT")','"BROWSER_CANCELLED"','assertFalse(cancelled.toString().contains("SYNTHETIC-AWAIT-PRIVATE"))')),
 ('Await local HTML true receipt false response no implicit credentials or generic HTTP',has('OriginalSourceLoginBrowserAwaitTest','owned.mode="response";owned.body="<html>local-dom</html>"','page.has("localPage")','assertFalse(page["refetchAfterSuccess"].asBoolean)','sourceBrowserCookieCaptureCompleted','assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpHostCalls)')),
 ('Legacy showBrowser file guards retained and new nonawait flag absence correct',has('OriginalSourceLoginBrowserTest','java.showBrowser(','file:///private/synthetic','assertTrue(owned.pages.isEmpty())','assertFalse(page.has("awaitsResult"))','sourceBrowserPresented','assertEquals(0,owned.httpCalls);assertEquals(0,owned.credentialCalls)')),
 ('V2 accepted failure effects and secret redaction retained',has('OriginalSourceLoginV2BrowserTest','assertEquals("SCRIPT_ERROR",failed["error"].asJsonObject["code"].asString)','contains("sourceBrowserPresented")','assertFalse(failed.toString().contains("SYNTHETIC-V2-PRIVATE"))','file:///private/synthetic','assertEquals(0,owned.nativeHTTP)')),
 ('V2 local HTML metadata actual DOM false mode assertions',has('OriginalSourceLoginV2BrowserTest','owned.mode="response"','<html>dom</html>','prefetchedHTML','it.has("localPage")','assertFalse(owned.pages.last()["refetchAfterSuccess"].asBoolean)','assertEquals(3,owned.pages.size);assertTrue(peer.routes.isEmpty());assertEquals(0,owned.credentials)')),
 ('URL denied browser owner type unknown proxy dynamic hidden API guards retained',has('OriginalUrlExecutionTest','listOf("webView", "type", "unknown")','http://owned.invalid','Must not dispatch','Dynamic URL rules are not migrated','assertTrue(peer.requests.isEmpty())','connectExpandedOriginalUrl')),
 ('URL webJs-only uses two real HTTP calls and zero browser host',has('OriginalUrlExecutionTest','throw Error(\'must not run\')','assertEquals("unexpected",rule.connect(url).body())','assertEquals("unexpected",rule.ajax(url))','assertEquals(listOf("/script-only","/script-only"),peer.requests.map{it.path})','assertEquals(0,browserCalls.get())')),
]
for name,ok in guard_checks: check(name,ok)

verification=dict(checks=checks,sourceDetails=source_details,actualTerminalXML=terminal,actualOriginalFailures=terminal_failures,localResults=[x2,x3])
vp=S/'verification-v1.json';vp.write_text(json.dumps(verification,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
failed=[c for c in checks if not c['passed']]
report=dict(schemaVersion=1,frozenUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),reviewer='/root/login_info_v2_review',approved=not failed,
 status='Approved as a five-method test expectation repair; no production change and no Apple execution claimed.' if not failed else 'Not approved: review checks failed.',
 final=ff,verification=fact(vp),verifier=fact(Path(__file__).resolve()),preReview=fact(S/'pre-review-v1.json'),
 totalChecks=len(checks),failedChecks=len(failed),failedCheckDetails=failed,remainingConfirmedFindings=[],
 files=source_details,
 actualTerminal=dict(artifact=fact(artifact),members=64,xmlSuites=53,tests=353,passed=348,failures=5,errors=0,skipped=0,NativeMethodsExecuted=0),
 actualCandidate=dict(testRootsCompiled=5,unchangedFullHelpers=2,unchangedObjectHelper=1,productionRootsCompiled=0,distinctFinalPassedMethods=5,methodExecutions=6,passedExecutions=5,failedHistoricalExecutions=1,full353SuiteRerun=False,SwiftSDK=0,JNI=0,WK=0),
 runtimeJar=d['runtimeJar'],
 semanticAssessment=[
  dict(target=targets[0],result='The separately implemented Android flags0 overload decodes hello; existing Hutool whitespace/charset/URL-safe vectors stay. Added malformed one-symbol rejection retains negative behavior.'),
  dict(target=targets[1],result='Existing presented/empty/wrong-refetch/cancel/privacy guards stay. Explicit HTML is now supported and false mode consumes exact synthetic DOM without refetch; file URL still rejects and credential/generic HTTP counts remain zero.'),
  dict(target=targets[2],result='Legacy showBrowser and non-web scheme continue to reject without presentation. Only explicit local HTML now accepts the receipt and carries localPage/prepared HTML; asserts nonawait flag absent and no credentials/generic HTTP.'),
  dict(target=targets[3],result='Accepted presentation followed by script failure still fails with retained Presented effect and redacted secret. Local HTML nonawait and awaited false DOM now succeed, preserve page metadata and no HTTP/credential write; file scheme remains rejected. No nonexistent V2 showBrowser API added.'),
  dict(target=targets[4],result='webView unported remains truthy and denied here for lack of checked owner; type/unknown/proxy/legacy SourceJavaHost protections remain before HTTP. A webJs option alone does not enable webView: real connect/ajax perform exactly two loopback HTTP requests and no source.webview dispatch.'),
 ],
 closedReviewFindings=[
  dict(id='draft-missing-nonawait-key',resolution='Before any JUnit execution, direct missing awaitsResult.asBoolean was replaced with assertFalse(page.has("awaitsResult")); draft1 and source preserved.'),
  dict(id='new-v2-showBrowser-fixture',resolution='First actual five-method run correctly exposed nonexistent BaseSource.showBrowser as SCRIPT_ERROR. Removed only that newly introduced mistaken vector; kept legacy showBrowser and V2 file protections; reran only affected V2 method successfully. The original failure remains archived.'),
 ],
 evidenceHistory=[dict(phase='execution-v1',result='Test-only compiler failed due omitted helpers; zero JUnit methods.'),dict(phase='execution-v2',result='Five methods executed: four pass, one added V2 fixture expectation failed.'),dict(phase='execution-v3',result='Only affected V2 root recompiled with unchanged FileAdapter, one method passed. Prior four exact final sources reuse their actual pass evidence.')],
 limits=['Original terminal result remains failure with 353/348/5; the local five-target repair does not turn the original run or all 353 tests into a new pass.','Browser Host receipts are synthetic wire fixtures; no actual UIKit, WK, CookieStore acceptance, Apple signing, SDK or JNI execution was performed.','The same frozen ordinary production JAR is reused unmodified; only test roots/helpers were compiled. Production compatibility is not broadened by these assertion changes.','Future source evidence controls must bind the previously unlisted OriginalAnalyzeRuleTest.kt and OriginalUrlExecutionTest.kt. No control was changed by this review.'],
 mutations=dict(ownIgnoredOnly=True,peerSources=False,canonical=False,GitWrites=False,readOnlyGitBlobChecks=5,cloud=False,newTestsRunByReviewer=0,nativeParserInvocations=0))
rp=S/'review-v1.json';rp.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(review=fact(rp),totalChecks=len(checks),failedChecks=len(failed),failedNames=[c['name'] for c in failed]),ensure_ascii=False))
if failed: raise SystemExit(1)
