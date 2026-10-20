from pathlib import Path
import ast,datetime,difflib,hashlib,importlib.util,json,os,re,subprocess,sys,time
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;P=S/'preparation';W=P/'work-v3';B=S/'rawbaseline';V=S/'validation-root';assert not V.exists()
def rf(b):return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def fact(p):return dict(path=p.relative_to(R).as_posix(),**rf(p.read_bytes()))
def write(p,b):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
def save(p,v):write(p,(json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
def load(p):return json.loads(p.read_text(encoding='utf-8'))
def module(p,name):
 spec=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
controls=[r['path']for r in load(P/'controls-draft-v3.json')['files']]
backend=R/'.build/original-local-html-webjs-step/implementation-v1/backend-final-v2.json';swift=R/'.build/original-local-html-webjs-swift-step/final-v1.json'
assert rf(backend.read_bytes())==dict(bytes=34731,sha256='3ce8c092ce65acf3e38e136cf6b81070a7e1df96ebc8184a4d1266fd4e816854')
assert rf(swift.read_bytes())==dict(bytes=11850,sha256='e2fbf3c0091ff1f74869120f32f33d4a0e8c5c22bc700e39bbb1eb2667092fd0')
prod={};parents=[]
for mp in (backend,swift):
 m=load(mp);base=R/m['candidateRoot']if m['candidateRoot'].startswith('.build/')else mp.parent/m['candidateRoot'];parents.append(fact(mp))
 for row in m['files']:
  rel=row['path'];b=(base/rel).read_bytes();assert rf(b)==row['candidate'];assert rel not in prod
  if row['baseline']is None:assert not(R/rel).exists()
  else:assert rf((R/rel).read_bytes())==row['baseline'],rel
  prod[rel]=b;write(S/'source-snapshot'/rel,b)
assert len(prod)==15
canonicalGroups=[];known=[]
for p in ['docs/legado-ios/core-installation-lookup-complete-step.json','docs/legado-ios/core-original-reader-cold-process-step.json']:
 mp=R/p;doc=load(mp);rows=[]
 for row in doc['sourceFiles']:
  rel=row['path'];assert rf((R/rel).read_bytes())==row['candidate'];known.append(rel);rows.append(dict(path=rel,**rf((R/rel).read_bytes())))
 canonicalGroups.append(dict(manifest=fact(mp),sourceFiles=rows))
spd=R/'.build/s2-authenticated-spd-challenge-step/final-v1.json';rows=[]
for row in load(spd)['sourceFiles']:
 rel=row['baseline']['path'];assert rf((R/rel).read_bytes())=={k:row['candidate'][k]for k in ('bytes','sha256')};known.append(rel);rows.append(dict(path=rel,**rf((R/rel).read_bytes())))
canonicalGroups.append(dict(manifest=fact(spd),sourceFiles=rows));known=list(dict.fromkeys((*known,*prod)))
inventory=load(P/'controls-draft-v3.json');assert set(known)==set(inventory['knownSourcePaths'])
for row in inventory['files']:
 rel=row['path'];assert rf((R/rel).read_bytes())==row['baseline']and rf((W/rel).read_bytes())==row['draft'];write(B/rel,(R/rel).read_bytes())
core='scripts/reader-experience/renewal-probe-tools.py';native='scripts/reader-experience/native-smoke-tools.py';ct='scripts/reader-experience/test-renewal-probe-tools.py';nt='scripts/reader-experience/test-native-smoke-tools.py';wf='.github/workflows/legado-native-reader-test.yml'
oldcore=module(R/core,'webjs_cohort_oldcore');oldnative=module(R/native,'webjs_cohort_oldnative');oldapi=module(R/'scripts/reader-experience/original-api-package-tools.py','webjs_cohort_oldapi');oldcold=module(R/'scripts/reader-experience/original-cold-process-tools.py','webjs_cohort_oldcold')
allpaths=list(dict.fromkeys((*oldcore.SOURCE_INPUTS,*oldnative.SOURCE_INPUTS,*oldapi.SOURCE_INPUTS,*known,*controls,'scripts/legado-ios/verify-native-reuse.py','scripts/legado-ios/verify-runtime-reuse.py')))
for rel in allpaths:write(V/rel,(W/rel).read_bytes()if rel in controls else prod[rel]if rel in prod else(R/rel).read_bytes())
newcore=module(V/core,'webjs_cohort_newcore');newnative=module(V/native,'webjs_cohort_newnative');newapi=module(V/'scripts/reader-experience/original-api-package-tools.py','webjs_cohort_newapi');newcold=module(V/'scripts/reader-experience/original-cold-process-tools.py','webjs_cohort_newcold')
assert set(prod)<=set(newcore.SOURCE_INPUTS)and set(prod)<=set(newnative.SOURCE_INPUTS)
assert set(known)<=set(newcore.SOURCE_INPUTS)and set(known)<=set(newnative.SOURCE_INPUTS)
assert set(newcore.SOURCE_INPUTS)==set(oldcore.SOURCE_INPUTS)|set(known);assert set(newnative.SOURCE_INPUTS)==set(oldnative.SOURCE_INPUTS)|set(known)
assert len(newcore.SOURCE_INPUTS)==len(set(newcore.SOURCE_INPUTS))==343
assert len(newnative.SOURCE_INPUTS)==len(set(newnative.SOURCE_INPUTS))==148
assert newcore.EXPECTED_CASES==oldcore.EXPECTED_CASES and newcore.PARAMETER_CASES==oldcore.PARAMETER_CASES
assert len(newcore.EXPECTED_CASES['currentcore'])==463 and newcore.expected_leaf_count('currentcore')==466 and len(newcore.parameter_cases('currentcore'))==3
selector='LegadoNativeOriginalLoginInfoTests/testNativeOriginalLocalHTMLWebJSKeepsSameSessionAfterProducerAndDrainsAwaitCancellation'
assert newnative.NATIVE_GROUPS['original']['methods']==(*oldnative.NATIVE_GROUPS['original']['methods'],selector)
assert len(newnative.NATIVE_GROUPS['original']['methods'])==27 and newnative.NATIVE_GROUPS['original']['seconds']==1800
assert newnative.NATIVE_GROUPS['mainjs']==oldnative.NATIVE_GROUPS['mainjs']and len(newnative.NATIVE_GROUPS['mainjs']['methods'])==1 and newnative.NATIVE_GROUPS['mainjs']['seconds']==2700
assert newcold.METHODS==oldcold.METHODS and len(newcold.METHODS)==2
assert set(newcold.METHODS.values()).isdisjoint(newnative.NATIVE_GROUPS['original']['methods'])
assert (W/wf).read_text(encoding='utf-8').replace('Execute1 MainJS and27 original methods in separate required hosts','Execute1 MainJS and26 original methods in separate required hosts')==(B/wf).read_text(encoding='utf-8')
assert newapi.SOURCE_INPUTS==oldapi.SOURCE_INPUTS and len(newapi.SOURCE_INPUTS)==23 and newapi.PACKAGE_INPUTS==oldapi.PACKAGE_INPUTS and len(newapi.PACKAGE_INPUTS)==16 and len(newapi.LOGINV2_EXPECTED)==24
for rel in newapi.SOURCE_INPUTS:assert(V/rel).read_bytes()==(R/rel).read_bytes()
def functions(p):return{n.name:ast.dump(n,include_attributes=False)for n in ast.parse(p.read_text(encoding='utf-8')).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
for rel in(core,native):assert functions(B/rel)==functions(W/rel)
for rel in controls:
 if rel.endswith('.py'):ast.parse((W/rel).read_bytes())
nativeSource=prod['Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'].decode('utf-8');assert len(re.findall(r'(?m)^\s+func (test\w+)\s*\(',nativeSource))==16 and nativeSource.count('try await requireNativeRuntime()')==16
commands=[]
def run(name,args,methods):
 started=time.monotonic();env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1','LEGADO_RUNTIME_SOURCE_ONLY':'1','YUEDU_RENEWAL_SELECTION':'currentcore'};result=subprocess.run(args,cwd=V,env=env,capture_output=True);log=S/(name+'.log');log.write_bytes(result.stdout+result.stderr);commands.append(dict(argv=args,methods=methods,exitCode=result.returncode,seconds=round(time.monotonic()-started,3),log=fact(log)));save(S/'validation-v1.json',commands)
 assert result.returncode==0,(name,(result.stdout+result.stderr).decode('utf-8',errors='replace')[-6000:])
py='C:/Python312/python.exe'
run('affected-core-v1',[py,'-B',ct,'DeltaReuseCheckpointSelectionTests','-v'],2)
run('affected-native-v1',[py,'-B',nt,'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging','NativeSmokeProvenanceTests.test_result_requires_exact_built_app_source_stamp','-v'],2)
files=[]
for rel in controls:
 before=(B/rel).read_bytes();after=(W/rel).read_bytes();assert before==(R/rel).read_bytes();diff=S/'diffs'/(rel+'.diff');write(diff,''.join(difflib.unified_diff(before.decode('utf-8').splitlines(True),after.decode('utf-8').splitlines(True),fromfile='a/'+rel,tofile='b/'+rel)).encode('utf-8'));files.append(dict(path=rel,baseline=rf(before),candidate=rf(after),diff=fact(diff)))
rosters={};union={}
for name,paths in [('core',newcore.SOURCE_INPUTS),('Native',newnative.SOURCE_INPUTS),('Package',newapi.SOURCE_INPUTS)]:
 rows=[dict(path=rel,**rf((V/rel).read_bytes()))for rel in paths];union.update({row['path']:row for row in rows});p=S/(name+'-source-inputs.json');save(p,rows);rosters[name]=fact(p)
assert len(union)==359
unchanged=0
for rel,row in union.items():
 if rel in controls or rel in prod:continue
 assert rf((R/rel).read_bytes())=={k:row[k]for k in ('bytes','sha256')};unchanged+=1
save(S/'union-source-inputs.json',list(union.values()))
facts=dict(status='15 frozen WebJS source files plus canonical S4/C5/S2 and5 controls; actual affected portable guards completed; final review pending',sourceComposition=parents,canonicalGroups=canonicalGroups,files=files,productionSources=[dict(path=rel,candidate=rf(b),snapshot=fact(S/'source-snapshot'/rel))for rel,b in prod.items()],counts=dict(AppDefinitions=463,AppLeaves=466,BoolParameterPairs=3,coreInputs=len(newcore.SOURCE_INPUTS),nativeInputs=len(newnative.SOURCE_INPUTS),uniqueInputUnion=len(union),NativeOriginalDefinitions=27,NativeLoginInfoDefinitions=16,NativeMainJSDefinitions=1,NativeIndependentColdHosts=2,PackageMethods=24,PackageCompilationInputs=16,PackageControls=7,PackageAllInputs=23,unchangedCanonicalNoncandidateInputs=unchanged),sourceRosters=rosters,newNativeSelector=selector,coldMethods=newcold.METHODS,actualPortableGuards=dict(distinctMethods=4,executions=4,passed=4,failed=0,commands=commands,otherOldSuccessfulSuitesRepeated=False,SwiftSDK=0,JVM=0,JNI=0,UIKit=0),invariants=dict(allCoreAndNativeProductionFunctionASTsUnchanged=True,allOldAppModesAndThreeBoolPairsUnchanged=True,old26NativeSelectorsPreservedInOrder=True,separateMainJSHostUnchanged=True,twoColdProcessSelectorsRemainIndependent=True,workflowOnlyLabelChange=True,requiredSameJobSignedSDKFixture=True,AppSingleColdSeconds=3600,NativeOriginalSeconds=1800,NativeMainJSSeconds=2700,Package24SelectionAnd23SourceBytesUnchanged=True,allPhaseArgvRawExitSourceSdkGatesUnchanged=True),preparedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
save(S/'validation-facts-v1.json',facts)
print(json.dumps(dict(manifest=fact(S/'validation-facts-v1.json'),counts=facts['counts'],passed=4)))
