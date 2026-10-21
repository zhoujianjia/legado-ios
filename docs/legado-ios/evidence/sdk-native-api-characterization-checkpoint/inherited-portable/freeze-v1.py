from pathlib import Path
import ast
import datetime
import hashlib
import json
import re
import subprocess

R=Path('F:/yuedu-reader');S=R/'.build/consolidated-sdk-native-characterization-jvm-fixtures-checkpoint'
def load(p):return json.loads(p.read_text(encoding='utf-8'))
def fact(p):
 b=p.read_bytes();return dict(path=p.relative_to(R).as_posix(),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def write(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def ast_functions(p):return [ast.dump(n,include_attributes=False) for n in ast.parse(p.read_text(encoding='utf-8')).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))]
out=S/'preparation/final-v1.json'
assert not out.exists(),'Final already frozen; no overwrite.'
draft=load(S/'draft-v1.json');controls={f['path'] for f in draft['files']}
source=load(S/'validation-inputs-v1.json')
assert len(source['files'])==365
roster=[]
for row in source['files']:
 rel=row['path'];canonical=R/rel;v=S/'validation-root'/rel
 assert v.read_bytes()==(S/'work'/rel if rel in controls else canonical).read_bytes(),rel
 f=fact(v);assert (f['bytes'],f['sha256'])==(row['bytes'],row['sha256'])
 if rel in controls:assert canonical.read_bytes()==(S/'rawbaseline'/rel).read_bytes()
 roster.append(dict(path=rel,bytes=f['bytes'],sha256=f['sha256'],core=rel in draft['sourceROSTERS']['core'],native=rel in draft['sourceROSTERS']['native'],candidateControl=rel in controls))
assert (sum(r['core'] for r in roster),sum(r['native'] for r in roster),len(roster))==(349,161,365)
write(S/'source-rosters-v1.json',dict(coreCount=349,nativeCount=161,unionCount=365,files=roster))
parents=[
 R/'.build/native-88c61ee-stale-expectation-repair-step/final-v1.json',
 R/'.build/original-general-webjs-ordered-result-step/final-v1.json',
 R/'.build/original-webrequest-native-characterization-step/final-v1.json',
]
reviews=[R/'.build/native-88c61ee-stale-expectation-independent-review/review-v1.json',R/'.build/original-general-webjs-ordered-result-independent-review/review-v1.json',R/'.build/original-webrequest-native-characterization-independent-review/review-v1.json']
changed=[]
for parent in parents:
 p=load(parent);root=R/(p.get('candidateRoot') or p['sourceRoot'])
 for f in p['files']:
  cp=R/f['path'];expected=root/f['path']
  assert cp.read_bytes()==expected.read_bytes(),f['path']
  assert any(r['path']==f['path'] for r in roster)
  changed.append(fact(cp))
assert len(changed)==7 and len({f['path'] for f in changed})==7
write(S/'changed-source-bindings-v1.json',changed)

old_parent=R/'.build/consolidated-sdk-general-webjs-runtime-repairs-checkpoint/preparation/final-v1.json'
old_final=load(old_parent)
package=load(R/old_final['sourceRosters']['Package']['path'])
assert len(package)==23
for f in package:
 b=(R/f['path']).read_bytes();assert len(b)==f['bytes'] and hashlib.sha256(b).hexdigest()==f['sha256'],f['path']
write(S/'Package-source-inputs-v1.json',package)
function_facts=[]
for rel in ['scripts/reader-experience/renewal-probe-tools.py','scripts/reader-experience/native-smoke-tools.py']:
 old=ast_functions(S/'rawbaseline'/rel);new=ast_functions(S/'work'/rel);assert old==new
 function_facts.append(dict(path=rel,topLevelFunctionCount=len(old),allOldFunctionASTExact=True,astSHA256=hashlib.sha256(json.dumps(old,separators=(',',':')).encode()).hexdigest()))
write(S/'production-function-ast-v1.json',function_facts)

commands=[load(S/'affected-core-v1.json'),load(S/'affected-native-v2.json')]
for c in commands:
 assert c['exitCode']==0
 text=(R/c['log']['path']).read_text(encoding='utf-8')
 assert re.search(r'Ran 2 tests? in ',text) and text.rstrip().endswith('OK')
 c['observedMethods']=2
early=load(S/'affected-native-v1.json');assert early['exitCode']!=0
early_log=(R/early['log']['path']).read_text(encoding='utf-8')
assert 'FileNotFoundError' in early_log and 'Ran ' not in early_log
guards=dict(distinctMethods=4,executions=4,passed=4,failed=0,commands=commands,preMethodImportFailure=dict(command=early,actualMethods=0,resolvedBy='Two exact unchanged transitive imports copied into the same validation tree; no source-list or control changes.'),oldPassingMethodsRepeated=False,validationTreeCopies=1,SwiftSDK=0,JNI=0,WK=0,JVM=0)
write(S/'validation-facts-v1.json',guards)
write(S/'source-preparation-history-v1.json',dict(scope='Preparation-script omissions only, not guard/test failures.',attempts=[dict(failure='Static roster evaluation omitted LANGUAGES dependency',actualGuards=0,validationTrees=0),dict(failure='Static roster evaluation omitted CURRENTCORE_TRUST_GUARD_SOURCE dependency',actualGuards=0,validationTrees=0)],resolution='General constant dependency traversal; exact roster sizes then computed. Same five control candidate logic was not changed by those evaluator corrections.'))

core=ast.parse((S/'work/scripts/reader-experience/renewal-probe-tools.py').read_text(encoding='utf-8'))
base=ast.parse((S/'rawbaseline/scripts/reader-experience/renewal-probe-tools.py').read_text(encoding='utf-8'))
for name in ['SELECTION_GROUPS','EXPECTED_CASES']:
 nodes=lambda t:[ast.dump(n,include_attributes=False) for n in t.body if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id==name for x in n.targets)]
 assert nodes(core)==nodes(base)
commit=subprocess.run(['git','rev-parse','HEAD'],cwd=R,capture_output=True,text=True,check=True).stdout.strip()
assert commit=='74d6b3f3ee02b04528c68338764f9604803034c0',commit
evidence=[S/'validation-facts-v1.json',S/'validation-inputs-v1.json',S/'validation-ancillary-inputs-v1.json',S/'production-function-ast-v1.json',S/'source-preparation-history-v1.json',S/'affected-core-v1.json',S/'affected-core-v1.log',S/'affected-native-v1.json',S/'affected-native-v1.log',S/'affected-native-v2.json',S/'affected-native-v2.log',S/'prepare-draft-v1.py',S/'prepare-validation-once.py',S/'run-guard-once.py',S/'freeze-v1.py']
result=dict(schemaVersion=1,frozenUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='Frozen five-control candidate only, pending independent review. No canonical writes, tags, cloud queries or SDK execution.',canonicalSource=commit,baselineControlsUnchangedSince='88c61ee4b80889a617d344fda668d077f73fa95b',candidateRoot=(S/'work').relative_to(R).as_posix(),baselineRoot=(S/'rawbaseline').relative_to(R).as_posix(),files=draft['files'],counts={**draft['counts'],**dict(unchangedCanonicalNonControlInputs=360,ReaderMethodsIncludingCold=15,LoginInfoMethods=16,ResourceCharacterizationMethods=1)},sourceParents=[fact(p) for p in parents],sourceIndependentReviews=[fact(p) for p in reviews],changedSources=fact(S/'changed-source-bindings-v1.json'),sourceRosters=fact(S/'source-rosters-v1.json'),PackageSourceRoster=fact(S/'Package-source-inputs-v1.json'),actualPortableGuards=guards,
 selectorComposition=dict(oldProductMethodsOrdered=draft['groupMethods'][:28],newPlatformCharacterizations=draft['characterizations'],originalGroupTotal=30,MainJSIndependent=1,coldIndependent=2),
 invariants=dict(allOldProduct28SelectorsOrderedExact=True,platformCharacterizationsNotCountedAsProductionOriginalRuleCases=True,productionCoreAndNativeFunctionsASTExact=True,allOldModesAndBool3App463_466Unchanged=True,package24MethodsAnd23InputsBytesUnchanged=True,sourcePhaseRawArgvExitExportGatesUnchanged=True,requiredSameJobSignedSDKFixtureUnchanged=True,oneCurrentcoreInvocation=True,currentcoreWrapperSeconds=3600,currentcoreParentSeconds=3720,originalSeconds=1800,mainjsSeconds=2700,coldTwoHostProtocolUnchanged=True,oldJNIRequirementsRemainForOldSuites=True,ResourceGuardExceptionOnlyNewNamedPublicWKClass=True),
 relatedResearch=fact(R/'.build/original-scripting-ordered-result-primary-step/review-v1.json'),
 proofLimits=['The two appended cases are pending public-WK platform characterizations, not two additional production original-rule compatibility cases. Their behavioral assertions have not run here.','The resource characterization may require iOS18.4, framework permissions and additional WebKit extension background context. The unchanged result gate rejects skipped methods; unsupported is not a pass.','Scripting.files/MAIN source research explains the evaluated Program route but returned values still pass through native result extraction. It is not Apple runtime evidence or a proof of platform-wide impossibility.','These four synthetic portable guards validate control contracts only, not SDK/JNI/WK/JVM/Apple/device renewal. Original Native88c actual353/348pass/5fail remains unchanged; the five-method JVM repair is separate targeted evidence.','The source input lists are evidence inventories, not Xcode compilation whitelists. Two unchanged transitive Python imports are separately recorded as ancillary validation inputs.','Current live SDK88/source88 is unchanged; this future candidate creates no tag or workflow execution. Subsequent production-only repairs require a precise source-stamp update; unchanged passing control guards can be reused.'],evidence=[fact(p) for p in evidence],operations=dict(canonicalWrites=False,GitWrites=False,cloudQueries=False,tagsCreated=False,SDKInvocations=0))
write(out,result)
print(json.dumps(dict(final=fact(out),counts=result['counts'],actualPortableGuards=dict(distinctMethods=4,executions=4,passed=4,failed=0)),ensure_ascii=False))
