from pathlib import Path
import datetime,hashlib,json,re,shutil,xml.etree.ElementTree as E
R=Path('F:/yuedu-reader');S=Path(__file__).resolve().parent;OUT=S/'final-v1.json';assert not OUT.exists()
def rf(b):return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def fact(p):return {'path':p.relative_to(R).as_posix(),**rf(p.read_bytes())}
def save(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
draft=json.loads((S/'draft-v3.json').read_bytes())
methods={
'OriginalAnalyzeRuleTest':'hutoolStringBase64OverloadsKeepWhitespaceUrlSafeAndCharsetBehavior',
'OriginalSourceLoginBrowserAwaitTest':'presentationEmptyWrongModeAndExplicitUnsupportedNeverBecomeSuccessfulAwait',
'OriginalSourceLoginBrowserTest':'unsupportedHtmlPostAndNonWebSchemesDoNotFakePresentation',
'OriginalSourceLoginV2BrowserTest':'acceptedBrowserEffectsSurviveScriptFailureAndHtmlRemainsUnsupported',
'OriginalUrlExecutionTest':'unsupportedOptionsHeadersAndUnmigratedMainJsStayTypedBeforeHttp'}
sourcefacts=[];definitioncounts={}
for row in draft['files']:
 rel=row['path'];before=(S/'rawbaseline'/rel).read_bytes();after=(S/'work'/rel).read_bytes();assert rf(after)==row['candidate'];assert before==(R/rel).read_bytes()
 name=Path(rel).stem;target=methods[name]
 def bounds(raw):
  text=raw.decode('utf8');needle='fun '+target+'(';loc=text.index(needle);start=text.rfind('    @Test',0,loc);end=text.find('\n    @Test',loc);assert start>=0 and end>=0;return start,end,text
 a,b,old=bounds(before);c,d,new=bounds(after);assert old[:a]==new[:c]and old[b:]==new[d:]
 olddefs=re.findall(r'@Test(?:\([^\n]*\))?\s+fun\s+(\w+)',old);newdefs=re.findall(r'@Test(?:\([^\n]*\))?\s+fun\s+(\w+)',new);assert olddefs==newdefs;definitioncounts[name]=len(olddefs)
 for folder,data in [('work',after),('rawbaseline',before)]:
  p=S/'snapshot-v1'/folder/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
 dp=S/'snapshot-v1/diffs'/(rel+'.diff');dp.parent.mkdir(parents=True,exist_ok=True);dp.write_bytes((R/row['diff']['path']).read_bytes())
 sourcefacts.append({'path':rel,'baseline':rf(before),'candidate':rf(after),'changedMethod':name+'/'+target,'allOtherSourceBytesUnchanged':True,'diff':fact(dp)})

v2=json.loads((S/'execution-v2/commands.json').read_bytes());v3=json.loads((S/'execution-v3/commands.json').read_bytes())
x2=E.fromstring((S/'execution-v2/actual-tests.xml').read_bytes());x3=E.fromstring((S/'execution-v3/actual-tests.xml').read_bytes())
assert x2.attrib=={'tests':'5','failures':'1','skipped':'0'}and x3.attrib=={'tests':'1','failures':'0','skipped':'0'}
passed={c.attrib['classname']+'/'+c.attrib['name']for c in x2.findall('testcase')if c.find('failure')is None}
rerun={c.attrib['classname']+'/'+c.attrib['name']for c in x3.findall('testcase')};assert passed.isdisjoint(rerun)and len(passed|rerun)==5
for row in sourcefacts:
 if Path(row['path']).stem!='OriginalSourceLoginV2BrowserTest':
  prior=next(x for x in v2['sources']if x['path'].endswith('/'+row['path']));assert {k:prior[k]for k in ('bytes','sha256')}==row['candidate']
jar=R/v2['runtimeJar']['path'];assert rf(jar.read_bytes())=={k:v2['runtimeJar'][k]for k in ('bytes','sha256')}
classbindings=[]
for phase in ['execution-v2','execution-v3']:
 for p in sorted((S/phase/'classes').rglob('*.class')):classbindings.append(fact(p))
save(S/'compiled-test-class-bindings.json',classbindings)
save(S/'execution-v3/source-binding.json',{'scope':'Exact final candidate and unchanged helper observed after bounded affected rerun; source remained unchanged through freeze','sources':[fact(S/'work'/row['path'])for row in sourcefacts if Path(row['path']).stem=='OriginalSourceLoginV2BrowserTest']+[fact(S/'test-helper-source/FileRulePersistenceAdapter.kt')],'runtimeJar':fact(jar),'classes': [x for x in classbindings if '/execution-v3/'in x['path']]})
ev=[]
for p in sorted(S.rglob('*')):
 if not p.is_file()or'classes'in p.parts or any(x in p.parts for x in ['work','rawbaseline','diffs','snapshot-v1']):continue
 if p==OUT:continue
 ev.append(fact(p))
report={'schemaVersion':1,'frozenUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'Five existing stale expectations updated against actual original implemented branches; exact five targeted methods now pass with preserved first local fixture failures. No production code changes, no new tests, no fullGradle/native SDK rerun.',
 'sourceCommit':draft['sourceCommit'],'candidateRoot':'.build/native-88c61ee-stale-expectation-repair-step/snapshot-v1/work','baselineRoot':'.build/native-88c61ee-stale-expectation-repair-step/snapshot-v1/rawbaseline','files':sourcefacts,
 'actualTerminal':fact(R/'.build/native-88c61ee-terminal/factual-review-v1.json'),'runtimeJar':fact(jar),
 'definitionIdentities':{'sameAllExistingDefinitions':True,'perRootCounts':definitioncounts,'changedMethods':list(methods.values()),'newDefinitions':0},
 'actualValidation':{'changedTestRoots':5,'unchangedPureHelperRoots':2,'originalObjectOnlyHelperRoots':1,'productionRootsCompiled':0,'uniqueTargetMethods':5,'actualMethodExecutions':6,'actualPassedExecutions':5,'actualFailedExecutions':1,'finalDistinctPassedMethods':5,'full353SuiteRerun':False,'executionHistory':[{'phase':'execution-v1','kind':'test compiler failed before any method due omitted test-only dependencies','JUnitMethods':0},{'phase':'execution-v2','kind':'five exact methods, four pass and one new mistaken V2 showBrowser error-code fixture fail','methods':5,'passed':4,'failed':1},{'phase':'execution-v3','kind':'only affected V2 method after removing that newly added invalid-member expectation','methods':1,'passed':1,'failed':0,'fourPassingMethodsRepeated':False}],'exactFinalSuccessfulIdentities':sorted(passed|rerun),'testClassPathBeforeProductionJar':True,'sameFrozenOrdinaryProductionJarOnly':True,'maxHeapMiB':160,'fullGradle':False,'SwiftSDK':0,'JNI':0,'WK':0},
 'contracts':[
  'Original no-flags Hutool success/whitespace/URL-safe/charset vectors unchanged; separate implemented Android flags0 is hello, malformed one-symbol A still rejected.',
  'Legacy showBrowser and file scheme remain typed unsupported before any page; localHTML now requires actual source.browser presentation receipt, page metadata and no implicit credentials/HTTP host.',
  'Await presented/empty/wrong-refetch/cancel/secret redaction guards retained; localHTML false consumes exact synthetic atomic DOM mode without refetch and with actual completed-effect contract.',
  'V2 first accepted browser followed by script error retains Presented/secret redaction; localHTML now accepted with metadata/body, false uses DOM; file scheme still rejects. V2 BaseSource has no showBrowser; no fake API was added.',
  'URL option webView:unported enables browser but is denied here by missing checked owner. type/unknown/proxy and legacy SourceJavaHost dynamic URL/hidden extension protections remain. Only webJs without webView is HTTP, two loopback requests and zero source.webview host calls; no claim that unported converts to false.'
 ],
 'remainingBoundaries':['The old Native88c terminal stays failure353/348pass/5fail; these local targeted results do not rewrite it.','Synthetic browser Host receipts test the wire only, never actual UIKit/WK presentation.','Only current App snapshot/ordinary Jar used for test execution; no Mac raw Jar/App binary was present in this early-failure artifact.','Future controls must bind previously unlisted OriginalAnalyzeRuleTest.kt and OriginalUrlExecutionTest.kt; unchanged helper inputs have separate exact source facts, not new production paths.'],
 'historyEvidence':ev,'compiledClassBindings':fact(S/'compiled-test-class-bindings.json'),
 'mutations':{'production':False,'canonical':False,'Git':False,'cloud':False,'tags':False,'privateBookSources':False}}
save(OUT,report);print(json.dumps({'manifest':fact(OUT),'changedSources':5,'distinctFinalPassed':5,'actualExecutions':6,'newDefinitions':0}))
