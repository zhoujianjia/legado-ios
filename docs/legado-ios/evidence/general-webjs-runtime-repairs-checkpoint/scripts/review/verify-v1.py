"""Read-only final5 control audit. No test/compiler/Git/cloud invocation."""
import ast,collections,hashlib,json,pathlib,re,sys,types
sys.dont_write_bytecode=True
R=pathlib.Path(__file__).resolve().parents[2];S=pathlib.Path(__file__).resolve().parent
U=R/'.build/consolidated-sdk-general-webjs-runtime-repairs-checkpoint';F=U/'preparation/final-v1.json';checks=[]
helper=R/'.build/original-general-webjs-backend-independent-review/verify-v1.py';tree=ast.parse(helper.read_text(encoding='utf-8'))
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name in {'digest','path','fact','check','binding','walk'}],type_ignores=[]),str(helper),'exec'))
check('final5 exact',F.stat().st_size==22325 and digest(F.read_bytes())=='37213734806c8a49cb469de7771ff531677bfd4e639021a2496b3b94d1264ef3')
f=json.loads(F.read_text());root=R/f['candidateRoot'];baseline=R/f['baselineRoot'];V=U/'validation-root'
for key in ['sourceParents','blankRegexSuccessor','sourceRosters','unionRoster','evidence','productionSources']:walk(f[key])
check('canonical source metadata exact',f['canonicalSource']=='54cab1ab501e83de0e9fdb0e829f871ed245058b')
controls={r['path']for r in f['files']}
check('only5ownedcontrols',len(controls)==5)
for row in f['files']:
 for name,p in [('candidate',root/row['path']),('baseline',baseline/row['path'])]:
  d=p.read_bytes();check(name+' '+row['path'],len(d)==row[name]['bytes']and digest(d)==row[name]['sha256'])
 check('baseline currentcanonical '+row['path'],(baseline/row['path']).read_bytes()==(R/row['path']).read_bytes())
 check('actual guard used exactcandidate '+row['path'],(root/row['path']).read_bytes()==(V/row['path']).read_bytes())
 binding(row['diff'])
def module(relative,version):
 p=(baseline if version=='old'else root)/relative
 # Use actual validation-root dependencies; execute only unchanged module setup,
 # never any test, CLI entry point or source/git/SDK audit operation.
 ns={'__name__':'control_review_'+version+'_'+p.stem.replace('-','_'),'__file__':str(V/relative)}
 exec(compile(p.read_bytes(),str(p),'exec'),ns)
 return types.SimpleNamespace(**ns)
corepath='scripts/reader-experience/renewal-probe-tools.py';nativepath='scripts/reader-experience/native-smoke-tools.py'
oldc=module(corepath,'old');newc=module(corepath,'new');oldn=module(nativepath,'old');newn=module(nativepath,'new')
def functionAST(p):
 t=ast.parse(p.read_text(encoding='utf-8'));return [ast.dump(n,include_attributes=False)for n in ast.walk(t)if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))]
for rel,n in [(corepath,59),(nativepath,20)]:
 a=functionAST(baseline/rel);b=functionAST(root/rel)
 check('all productionfunction AST exact '+rel,len(a)==len(b)==n and a==b)
check('all old14core modes exact',len(oldc.EXPECTED_CASES)==14 and newc.EXPECTED_CASES==oldc.EXPECTED_CASES)
check('463definitions466leaves3Boolpairs',len(newc.EXPECTED_CASES['currentcore'])==463 and newc.expected_leaf_count('currentcore')==466 and len(newc.parameter_cases('currentcore'))==3 and newc.parameter_cases('currentcore')==oldc.parameter_cases('currentcore'))
check('historical parameter maps exact',newc.PARAMETER_CASES==oldc.PARAMETER_CASES)
check('mandatory actual SDK samejob signer stillselected',newc.SDK_REQUIRED_CASE==oldc.SDK_REQUIRED_CASE=='SelfRenewalControlledPackageSignerTests/signsSDKProducedMainExtensionsAndFrameworkInSameJob' and newc.SDK_REQUIRED_CASE in newc.EXPECTED_CASES['currentcore'])
check('core phase order/timeouts exact',newc.CURRENTCORE_PHASES==oldc.CURRENTCORE_PHASES and newc.CURRENTCORE_TIMEOUTS==oldc.CURRENTCORE_TIMEOUTS)
check('old27Native order preserved new appendedonce',newn.NATIVE_GROUPS['original']['methods']==(*oldn.NATIVE_GROUPS['original']['methods'],f['newNativeSelector']) and len(oldn.NATIVE_GROUPS['original']['methods'])==27 and len(newn.NATIVE_GROUPS['original']['methods'])==28)
check('NativeOriginal budget1800 exact',newn.NATIVE_GROUPS['original']['seconds']==oldn.NATIVE_GROUPS['original']['seconds']==1800)
check('NativeMainJS group1budget2700 exact',newn.NATIVE_GROUPS['mainjs']==oldn.NATIVE_GROUPS['mainjs'] and len(newn.NATIVE_GROUPS['mainjs']['methods'])==1 and newn.NATIVE_GROUPS['mainjs']['seconds']==2700)
workflow='.github/workflows/legado-native-reader-test.yml';a=(baseline/workflow).read_bytes();b=(root/workflow).read_bytes()
check('workflow only label27to28 no gate/argv/env/budget changes',b.replace(b'Execute1 MainJS and28 original methods',b'Execute1 MainJS and27 original methods')==a and b.count(b'Execute1 MainJS and28 original methods')==1)
roster={r['path']:r for r in f['productionSources']}
check('exact30production roster dedup',len(roster)==30)
for row in f['productionSources']:
 for label,p in [('current',R/row['path']),('actualguard',V/row['path'])]:
  d=p.read_bytes();check('production '+label+' '+row['path'],len(d)==row['bytes']and digest(d)==row['sha256'])
check('source unions and preservation',set(newc.SOURCE_INPUTS)==set(oldc.SOURCE_INPUTS)|set(roster)and set(newn.SOURCE_INPUTS)==set(oldn.SOURCE_INPUTS)|set(roster))
check('core343plus3new346 unique',len(oldc.SOURCE_INPUTS)==343 and len(newc.SOURCE_INPUTS)==len(set(newc.SOURCE_INPUTS))==346 and set(newc.SOURCE_INPUTS)-set(oldc.SOURCE_INPUTS)==set(f['newBoundCorePaths']))
check('Native148plus10new158 unique',len(oldn.SOURCE_INPUTS)==148 and len(newn.SOURCE_INPUTS)==len(set(newn.SOURCE_INPUTS))==158 and set(newn.SOURCE_INPUTS)-set(oldn.SOURCE_INPUTS)==set(f['newBoundNativePaths']))
check('both closures30source tuple exact',tuple(newc.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS)==tuple(newn.ORIGINAL_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS) and set(newc.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS)==set(roster))
check('RuleBase64 existed but was previously unbound',str(R/'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt')and 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt'not in oldc.SOURCE_INPUTS and 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt'not in oldn.SOURCE_INPUTS)
rosters={k:json.loads(path(v['path']).read_text())for k,v in f['sourceRosters'].items()}
for k,rows in rosters.items():
 check('unique source roster '+k,len(rows)==len({r['path']for r in rows}))
 for row in rows:
  p=(root if row['path']in controls else R)/row['path'];d=p.read_bytes()
  check('actual source bytes '+k+' '+row['path'],len(d)==row['bytes']and digest(d)==row['sha256'])
  check('actual guard bytes '+k+' '+row['path'],d==(V/row['path']).read_bytes())
check('reported core roster exact computed', [r['path']for r in rosters['core']]==list(newc.SOURCE_INPUTS))
check('reported Native roster exact computed',[r['path']for r in rosters['Native']]==list(newn.SOURCE_INPUTS))
union=json.loads(path(f['unionRoster']['path']).read_text());unionmap={r['path']:r for r in union}
expected={}
for rows in rosters.values():
 for row in rows:
  if row['path']in expected:check('crossroster samebyte '+row['path'],expected[row['path']]==row)
  expected[row['path']]=row
check('union362 recomputed exact includingPackage',len(union)==len(unionmap)==362 and unionmap==expected and len(set(newc.SOURCE_INPUTS)|set(newn.SOURCE_INPUTS))==362)
check('357noncontrols canonical exact',len([r for r in union if r['path']not in controls])==357)
packagepath='scripts/reader-experience/original-api-package-tools.py';pkg=module(packagepath,'new')if(root/packagepath).exists()else None
if pkg is None:
 ns={'__name__':'review_package','__file__':str(V/packagepath)};exec(compile((R/packagepath).read_bytes(),str(R/packagepath),'exec'),ns);pkg=types.SimpleNamespace(**ns)
oldfacts=json.loads((U/'preparation/baseline-invariants-v1.json').read_text())
check('Package24 selected methods exact',len(pkg.LOGINV2_EXPECTED)==24 and sorted(pkg.LOGINV2_EXPECTED)==oldfacts['PackageSelectedMethods'])
priorPackage=R/'.build/consolidated-sdk-spd-webjs-cold-process-checkpoint/Package-source-inputs.json'
check('Package23 exact oldroster paths',len(pkg.SOURCE_INPUTS)==23 and [r['path']for r in rosters['Package']]==oldfacts['PackageSourceInputs']==list(pkg.SOURCE_INPUTS))
check('Package23 exact previously frozen bytefacts',rosters['Package']==json.loads(priorPackage.read_text()))
check('Package allsource controls unchanged',[fact(V/row['path'])['sha256']for row in rosters['Package']]==[fact(R/row['path'])['sha256']for row in rosters['Package']])
coldpath='scripts/reader-experience/original-cold-process-tools.py';ns={'__name__':'review_cold','__file__':str(V/coldpath)};exec(compile((R/coldpath).read_bytes(),str(R/coldpath),'exec'),ns)
check('cold2 host methods exact disjointordinary',ns['METHODS']==oldfacts['coldMethods']and len(ns['METHODS'])==2 and set(ns['METHODS'].values()).isdisjoint(newn.NATIVE_GROUPS['original']['methods']))
reader='Tests/iOS/LegadoNativeOriginalReaderTests.swift';login='Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'
readerMethods=re.findall(r'\bfunc\s+(testNative\w+)\s*\(',(R/reader).read_text());loginMethods=re.findall(r'\bfunc\s+(testNative\w+)\s*\(',(R/login).read_text())
check('Reader14 including cold2 and LoginInfo16 actualdefs',len(readerMethods)==14 and len(set(readerMethods))==14 and len(loginMethods)==len(set(loginMethods))==16 and all(v.split('/')[1]in readerMethods for v in ns['METHODS'].values()))
check('all28 selectors actual namedfunctions',all((v.split('/')[1]in(readerMethods if v.startswith('LegadoNativeOriginalReaderTests/')else loginMethods))for v in newn.NATIVE_GROUPS['original']['methods']))
for row in f['actualPortableGuards']['commands']:
 check('actual guard commandexit0',row['exitCode']==0 and row['methods']==row['observedMethods']==2)
 p=binding(row['log']);log=p.read_text();check('actual guard log2pass',log.count('... ok')==2 and 'Ran 2 tests'in log and log.strip().endswith('OK'))
check('actualguards4distinctonce only',f['actualPortableGuards']['distinctMethods']==f['actualPortableGuards']['executions']==f['actualPortableGuards']['passed']==4 and f['actualPortableGuards']['failed']==0 and len(f['actualPortableGuards']['commands'])==2)
g64=json.loads((R/'.build/original-general-webjs-blank-regex-step/final-v1.json').read_text())
b78=json.loads((R/'.build/original-general-webjs-base64-union-step/snapshot-v1/actual-results.json').read_text())['base64']
check('counts clarification General64 vs Base6478 incl39',g64['counts']['generalPublicExecuteCalls']==64 and g64['counts']['syntheticBrowserHostCalls']==17 and g64['counts']['realHTTP']==7 and b78['publicLoginActionCalls']==78 and b78['originalAnalyzeRuleCalls']==39)
report=dict(schema=1,final=fact(F),status='approved control-only final5 with explicit count wording clarification',approved=True,failedChecks=0,remainingConfirmedFindings=[],actualReadOnlyChecks=len(checks),counts=dict(coreInputs=346,nativeInputs=158,uniqueUnion=362,noncontrolCanonicalExact=357,productionSources=30,AppDefinitions=463,AppArgumentLeaves=466,BoolPairs=3,NativeOriginal=28,MainJS=1,separateColdHosts=2,ReaderDefinitionsIncludingCold=14,LoginInfoDefinitions=16,PackageSelectedCases=24,PackageSourceInputs=23,actualPortableMethodsRead=4,reviewerTestsRerun=0),gateFacts=dict(allCore53andNative17FunctionASTExact=True,allOld14CoreModesExact=True,old27NativeOrderExact=True,mandatorySDKSameJobSignerRetained=True,workflowOnlyLabel27to28=True,currentcoreWrapperSeconds=3600,currentcoreParentSeconds=3720,originalHostSeconds=1800,mainjsHostSeconds=2700,phaseArgvRawSourceExitGatesUnchanged=True),metadataClarification=dict(field='proofLimits[1]',original=f['proofLimits'][1],correct='Base64 has78 public calls including39 nested AnalyzeRule paths. General successor separately has64 public calls/17 synthetic browser Host calls/JVMHTTP7. Do not label78 as a joint General+Base64 total or add39 again.',resolution='Root will clarify canonical record; immutable candidate bytes/logs preserved; no source/test change required'),checks=checks,sourceStamp=f['canonicalSource'],limits=f['proofLimits']+['This independent review only imported module setup/pure selector metadata and read frozen source/hash/logs. It did not invoke the four tests, compilers, SDK/JNI/WK, Git or cloud.','Source-input rosters bind evidence; they are not a whitelist of all files compiled by Xcode.','No older terminal SDK/Native results are promoted to this new control/source snapshot.'],operations=dict(canonicalWrites=False,GitMutations=False,cloudQueries=False,peerCandidateMutations=False,testsRerun=False))
(S/'review-v1.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(dict(checks=len(checks),failedChecks=0,report=fact(S/'review-v1.json')),indent=2))
