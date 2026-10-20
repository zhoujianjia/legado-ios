from pathlib import Path
import json,hashlib,difflib,shutil,re,sys,datetime,xml.etree.ElementTree as E
R=Path('F:/yuedu-reader');S=R/'.build/native-210-reader-repair-step';W=S/'work';C=S/'incremental'
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def save(p,o):p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()));grammar=[];files=[]
paths=sorted(p.relative_to(W).as_posix()for p in W.rglob('*')if p.is_file());assert len(paths)==4
snapshot=S/'snapshot-v1';assert not snapshot.exists();snapshot.mkdir()
for path in paths:
 old=S/'rawbaseline'/path;new=W/path
 if path.endswith('.swift'):
  for version,p in [('rawbaseline',old),('work',new)]:
   tree=parser.parse(p.read_bytes());stack=[tree.root_node];errors=[]
   while stack:
    n=stack.pop()
    if n.is_error or n.is_missing:errors.append({'type':n.type,'start':list(n.start_point)})
    stack.extend(n.children)
   assert not errors,(path,version,errors)
   grammar.append({'path':path,'version':version,**fact(p),'grammarErrors':0})
  names=lambda p:re.findall(r'\bfunc\s+(test\w+)\s*\(',p.read_text(encoding='utf-8'))
  assert names(old)==names(new)and len(names(new))==11
  native_names=names(new)
 dst=snapshot/path;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(new,dst)
 diff=S/'diffs'/Path(path+'.diff');diff.parent.mkdir(parents=True,exist_ok=True)
 diff.write_text(''.join(difflib.unified_diff(old.read_text(encoding='utf-8').splitlines(True),new.read_text(encoding='utf-8').splitlines(True),fromfile='baseline/'+path,tofile='candidate/'+path)),encoding='utf-8',newline='\n')
 files.append({'path':path,'baseline':fact(old),'candidate':fact(new),'snapshot':fact(dst),'diff':{'path':diff.relative_to(S).as_posix(),**fact(diff)}})
save(S/'swift-grammar.json',{'limits':'Source grammar only, not Apple SDK typechecking or XCTest execution.','files':grammar})
mp='Packages/LegadoRuntime/vendor/original-rule/manifest.json';old=json.loads((S/'rawbaseline'/mp).read_text(encoding='utf-8'));new=json.loads((W/mp).read_text(encoding='utf-8'))
main='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt'
assert len(new['portedSources'])==56
changed=[]
for a,b in zip(old['portedSources'],new['portedSources']):
 assert a['path']==b['path']
 if a!=b:changed.append(a['path']);assert b['bytes']==fact(W/main)['bytes'] and b['sha256']==fact(W/main)['sha256']
assert changed==[main]
old['portedSources']=new['portedSources'];assert old==new
first=E.parse(C/'history/attempt1/actual-tests.xml').getroot();retry=E.parse(C/'retry/actual-tests.xml').getroot();counter=E.parse(C/'baseline-counterfactual/actual-tests.xml').getroot()
assert (first.get('tests'),first.get('failures'))==('3','1')and(retry.get('tests'),retry.get('failures'))==('1','0')and(counter.get('tests'),counter.get('failures'))==('1','1')
first_methods=[x.get('name')for x in first.findall('testcase')];assert retry.find('testcase').get('name')==first_methods[0]
assert 'ORDINARY_READER_REPAIR_OK sessions=3 HTTP=2'in(C/'ordinary-final/execute.log').read_text(encoding='utf-8')
assert 'Ran 6 tests'in(S/'packaging-tests.log').read_text(encoding='utf-8')and'OK'in(S/'packaging-tests.log').read_text(encoding='utf-8')
art=R/'.build/consolidated-native-210fb05/extracted/.build/native-reader-test'
raw_summary=art/'original-summary.json'
evidence=[]
for p in sorted(S.rglob('*')):
 if not p.is_file()or any(x in p.relative_to(S).parts for x in ['validation-root','work','rawbaseline','snapshot-v1','diffs','raw-crash-diagnostics','main-classes','test-classes','classes']):continue
 if p.suffix in ('.log','.json','.xml','.java','.py') and p.name!='final-v1.json':evidence.append({'path':p.relative_to(S).as_posix(),**fact(p)})
save(S/'final-v1.json',{
 'version':1,'stage':'native-210-reader-repair-step','frozenUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'baseline':{'source':'Canonical55a trueDelta snapshot; Reader bytes also matched actual Native210 execution source-input row. Later canonical V2 files are excluded from this incremental test closure.','actualNativeSummary':{'path':str(raw_summary.relative_to(R)),**fact(raw_summary)}},
 'files':files,'evidence':evidence,
 'rootCauses':[
  {'kind':'production P1','cause':'Cold TOC metadata construction eagerly restored variables on every stored chapter; last-chapter next=nil boundary lookup accessed foreign chapters outside a single-current-chapter grant.','fix':'StoredChapter.restore passes restorePersistentVariables=false only for TOC metadata; explicit OriginalRuleDto.chapter still restores variables and retains existing host rejection.'},
  {'kind':'fixture','cause':'readyBaseURL already includes the run namespace; nine call sites duplicated it.','fix':'Use baseURL plus only route suffix, assert baseURL.path and /held target identity; retain all real HTTP, cancellation, held socket and request assertions.'},
  {'kind':'fixture','cause':'Three batch expectations omitted original two U+3000 indentation characters.','fix':'Exact original output expectations; no trimming or formatter change.'},
  {'kind':'fixture','cause':'Original InfoMap.get returns a Rhino Java string whose JS strict identity differs from a JS string literal.','fix':'Explicit String(infoMap.get(...)) strict value assertion plus separate original two-source map value checks. Actual original-Rhino vector [false,true] confirmed; no context/permission production change.'}
 ],
 'validation':{
  'JVM':{'kind':'Exact one-source Kotlin2.4.20 incremental friend/module overlay over bound c26 ordinary337-class JAR, with all121 unchanged main roots byte-matched; not fresh full Gradle.','firstCandidateActual':{'tests':3,'pass':2,'failure':1,'reason':'New synthetic #text@html expectation omitted retained outer-element/paragraph whitespace.'},'correctedOnlyFailedActual':{'tests':1,'pass':1,'failure':0},'finalDistinctMethods':first_methods,'finalDistinctPassing':3,'baselineCounterfactual':{'tests':1,'expectedFailure':1,'confirmed':'Original c26 fails on foreign chapter variables during cold TOC metadata restoration.'},'compiler':'Kotlin2.4.20 / target21 / module io.yuedu_legado-runtime / explicit friend bound ordinary JAR / 128MiB SerialGC; exact argv and compiler dependency bytes recorded.'},
  'ordinaryJava':{'finalActualSessions':3,'sources':1,'realLoopbackHTTP':2,'foreignChapterDenied':True,'currentChapterVariablesRetained':True,'originalMapStrictIdentityVector':'[false,true]','classpath':'Final compile/execute only incremental production JAR and separately compiled outside consumer classes, no JUnit or test classes.','priorFailureHistory':'Two earlier outside-consumer attempts omitted public content needSave=false; existing guard rejected both. Corrected explicit false follows the unchanged public API contract; all logs retained.'},
  'packaging':{'actualGuardsPassed':6,'jar':'incremental/legado-runtime-incremental.jar','jarFacts':fact(C/'legado-runtime-incremental.jar'),'ordinaryTestPayload':False,'note':'CRC, provenance/resources, class major and test-exclusion guards passed for the precise incremental overlay; no fresh whole Gradle producer claim.'},
  'Swift':{'grammarFiles':2,'errors':0,'nativeReaderMethodIdentities':native_names,'newNativeMethods':0,'actualAppleSDK':0,'actualJNI':0,'actualDevice':0},
  'preTestFailures':[{'log':'jvm-targeted-v1.log','actualJUnit':0,'reason':'Windows commit/pagefile exhausted before daemon startup, 768MiB G1 allocation failure.'},{'log':'jvm-targeted-v2.log','actualJUnit':0,'reason':'512MiB Serial daemon native malloc failure at configuration.'},{'log':'jvm-targeted-v3.log','actualJUnit':0,'reason':'384MiB Serial daemon native malloc failure at compileKotlin.'}]
 },
 'integration':{'portedManifestCandidateCount':56,'mergeRule':'Root must apply ONLY RuleWebBookState portedSources bytes/SHA row to current58-entry V2 manifest; do not overwrite current archive/resources/license or newer ported rows.','requiresNextCohort':'Fresh combined production JAR/SDK/JNI and actual NativeReader11 methods under the existing mandatory fixture and strict gates. This stage does not execute or pass them.'},
 'nonChanges':['No host grant expansion, no new store/owner/engine/HTTP stack, no fabricated nextChapterUrl, no content trimming.','No canonical/Git/cloud/tag mutation.'],
 'flags':{'fullBookSourceCompatibility':False,'deviceValidationComplete':False,'automaticRenewalComplete':False,'selfSigningComplete':False}
})
print(json.dumps({'final':fact(S/'final-v1.json'),'files':[{ 'path':f['path'],**f['candidate']}for f in files],'actualDistinctJVMPass':3,'packagingPass':6,'grammarPass':2}))
