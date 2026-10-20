from pathlib import Path
import ast,datetime,hashlib,json,re,shutil
R=Path('F:/yuedu-reader');S=Path(__file__).parent;P=S/'preparation';W=P/'work-v3';B=S/'rawbaseline'
def rf(b):return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def fact(p):return dict(path=p.relative_to(R).as_posix(),**rf(p.read_bytes()))
def save(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
f=json.loads((S/'validation-facts-v1.json').read_text(encoding='utf-8'));assert f['actualPortableGuards']['passed']==4
for row in f['files']:assert rf((W/row['path']).read_bytes())==row['candidate']and rf((R/row['path']).read_bytes())==row['baseline']
functions={}
for rel in ['scripts/reader-experience/renewal-probe-tools.py','scripts/reader-experience/native-smoke-tools.py']:
 rows={}
 for side,root in [('baseline',B),('candidate',W)]:
  rows[side]={n.name:rf(ast.dump(n,include_attributes=False).encode('utf-8'))for n in ast.parse((root/rel).read_text(encoding='utf-8')).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
 assert rows['baseline']==rows['candidate'];functions[rel]=dict(wholeFileBaseline=fact(B/rel),wholeFileCandidate=fact(W/rel),functions=rows)
save(S/'production-function-ast-facts.json',functions)
def counts(root):return{row['path']:[dict(line=i+1,text=line)for i,line in enumerate((root/row['path']).read_text(encoding='utf-8').splitlines())if re.search(r'\b(?:22|23|24|26|27|140|148|338|343)\b|and26|and27|requireNativeRuntime',line)]for row in f['files']}
save(S/'baseline-related-count-search.json',counts(B));save(S/'candidate-related-count-search.json',counts(W))
evidence=[S/n for n in ['prepare-successor.py','prepare-validation.py','freeze-controls.py','validation-v1.json','validation-facts-v1.json','affected-core-v1.log','affected-native-v1.log','core-source-inputs.json','Native-source-inputs.json','Package-source-inputs.json','union-source-inputs.json','production-function-ast-facts.json','baseline-related-count-search.json','candidate-related-count-search.json']]+[P/n for n in ['inventory-draft-v1.json','controls-draft-v1.json','controls-draft-v2.json','controls-draft-v3.json']]
parents=f.pop('sourceComposition');f['sourceComposition']=dict(JVMBackend=parents[0],SwiftPageOwner=parents[1],canonicalS4C5S2=f['canonicalGroups'])
final=dict(schemaVersion=1,frozenUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='Frozen five controls over exact reviewed-candidate WebJS backend/Swift plus canonical S4/C5/S2; independent source/control review and actual SDK/Native pending',candidateRoot='preparation/work-v3',baselineRoot='rawbaseline',**f)
final['status']='Frozen five controls over exact WebJS backend/Swift plus canonical S4/C5/S2; independent source/control review and actual SDK/Native pending'
final['sourceIndependentReview']=dict(status='Full combined WebJS source review in progress by login_info_v2_review; no source acceptance inferred here',contractPreRead=fact(R/'.build/original-local-html-webjs-independent-pre-review/pre-review-v1.json'),preReadScope='Locked contract/counterexample only, not final production review')
final['newDefinitions']=dict(App=0,Package=0,NativeOriginal=1,NativeIndependentCold=2,notes='Two C5 cold methods already canonical; kept in distinct required hosts, not appended to original27.')
final['onlyNewBoundPaths']=dict(core=[p for p in json.loads((P/'controls-draft-v3.json').read_text())['groups']['core']['added']],native=[p for p in json.loads((P/'controls-draft-v3.json').read_text())['groups']['native']['added']])
final['evidence']=[fact(p)for p in evidence]
final['proofLimits']=['Only four affected portable guard methods executed, in two real Python processes; no App/Package/JVM/Native/UIKit suite execution in this controls task. Earlier unchanged portable pass records are inherited evidence, not rerun.', 'Backend candidate separately records bounded K2/ordinaryJava and packaging execution. Swift candidate separately records grammar/Node contract/Native definition only; neither establishes SDK/JNI/UIKit/device success.', 'Package24 method selection and all23 input bytes exact current canonical. Original26 selectors preserved in order plus WebJS1; MainJS1 and two C5 cold hosts stay separate.', 'Active source stamp/result expected original count27 and requireNativeRuntime calls16 agree with final Native source. App463/466/three Bool matrices, required samejob signed SDK fixture, single3600 invocation, raw-details/phase/exit/source gates remain unchanged.', 'The incorrect draft originalrule/Page path was corrected before any tests; root draft versions and raw22/23 historical failures were not edited. fc3 cloud runs are outside this task; no cloud status queried or restart/tag performed.']
final['preparationHistory']=dict(testFailures=0,preTestCorrections=[dict(kind='Inventory path correction before test execution',old='.../io/yuedu/legado/originalrule/OriginalWebJsPageRuntime.kt',actual='.../io/yuedu/legado/OriginalWebJsPageRuntime.kt',testsExecuted=0)],rootDraftV1V2Preserved=True,sourceTamperLoopIncludesAllCohortInputs=True)
final['flags']=dict(controlsPrepared=True,independentSourceReviewPassed=False,independentControlsReviewPassed=False,SDKValidated=False,NativeValidated=False,deviceValidated=False)
final['operations']=dict(canonical=False,GitMutation=False,cloud=False,tags=False)
out=P/'final-v1.json';assert not out.exists();save(out,final);print(json.dumps(fact(out)))
