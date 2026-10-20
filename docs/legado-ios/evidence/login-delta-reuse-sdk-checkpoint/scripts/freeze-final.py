from pathlib import Path
import sys,json,hashlib,difflib,subprocess,datetime
sys.dont_write_bytecode=True
s=Path(__file__).resolve().parents[1];r=s.parents[1];w=s/'work';p=s/'preparation'
def fact(path):
 path=Path(path);raw=path.read_bytes()
 return {'path':path.relative_to(r).as_posix(),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def datafact(path):
 f=fact(path);return {k:f[k] for k in ('bytes','sha256')}
def load(path):return json.loads(Path(path).read_text(encoding='utf-8'))
assert len(sys.argv)==3,'Need frozen Root repair manifest and final core portable record'
repair=r/sys.argv[1];core=r/sys.argv[2]
assert 'v2' in repair.name,'Final must include strict definitions/executions summary repair, not selector-only v1'
assert load(core)['successful'] and load(core)['failures']==load(core)['errors']==load(core)['skipped']==0
initial=load(p/'initial.json');paths=initial['candidatePaths'];assert len(paths)==9
seven=load(p/'seven-files-frozen-awaiting-root-filter.json')['files']
for row in seven:
 assert datafact(w/row['path'])=={k:row[k] for k in ('bytes','sha256')},row['path']
whole=r/initial['wholeProductionManifest']['path'];wholedata=load(whole)
assert fact(whole)==initial['wholeProductionManifest']
for row in wholedata['files']:assert datafact(w/row['path'])==row['candidate'],row['path']
assert len(wholedata['files'])==19
for row in initial['inheritedProductionInputs']:assert datafact(w/row['path'])=={k:row[k] for k in ('bytes','sha256')}
syntax=[]
for rel in paths:
 if rel.endswith('.py'):
  raw=(w/rel).read_bytes();compile(raw,str(w/rel),'exec');syntax.append({'path':rel,**datafact(w/rel),'status':'compile-only'})
assert len(syntax)==6
command=['D:/app/Git/bin/bash.exe','-n',str((w/'scripts/reader-experience/renewal-probe-tests.sh').resolve())]
bash=subprocess.run(command,capture_output=True,text=True);assert bash.returncode==0,bash.stderr
(p/'history').mkdir(exist_ok=True)
for filename in ('syntax-final.json','production-composition-final.json'):
 old=p/filename;history=p/'history'/('before-final-'+filename)
 if old.exists() and not history.exists():history.write_bytes(old.read_bytes())
(p/'syntax-final.json').write_text(json.dumps({'python':syntax,'bash':{'command':command,'exitCode':bash.returncode,'stdout':bash.stdout,'stderr':bash.stderr},'SDK':0},indent=2)+'\n',encoding='utf-8')
files=[]
for rel in paths:
 old=(s/'rawbaseline'/rel).read_text(encoding='utf-8');new=(w/rel).read_text(encoding='utf-8')
 diff=s/'diffs'/Path(rel+'.diff');diff.parent.mkdir(parents=True,exist_ok=True)
 diff.write_text(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='baseline/'+rel,tofile='candidate/'+rel)),encoding='utf-8',newline='\n')
 files.append({'path':rel,'baseline':datafact(s/'rawbaseline'/rel),'candidate':datafact(w/rel),'diff':fact(diff)})
closures=load(p/'source-closures-final.json');invariants=load(p/'selection-and-gate-invariants-final.json')
assert {k:v['count'] for k,v in closures.items()}=={'core':324,'native':115,'package':22}
allinputs={row['path']:row for value in closures.values() for row in value['sources']}
assert len(allinputs)==335 and len(set(allinputs)-set(paths))==326
delta={row['path'] for row in wholedata['files']};unaffected=[];canonicaldelta=[];pending=[]
for rel in sorted(set(allinputs)-set(paths)):
 assert datafact(w/rel)=={k:allinputs[rel][k] for k in ('bytes','sha256')},rel
 if rel in delta:
  (canonicaldelta if (r/rel).is_file() and datafact(r/rel)==datafact(w/rel) else pending).append(rel)
 else:
  assert datafact(r/rel)==datafact(w/rel),rel
  unaffected.append(rel)
assert len(unaffected)==307
def executable_lines(text):return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
shell='scripts/reader-experience/renewal-probe-tests.sh'
assert executable_lines((s/'rawbaseline'/shell).read_text(encoding='utf-8'))==executable_lines((w/shell).read_text(encoding='utf-8'))
composition={'baseline':'13a13cce0bc62dd6df82247ea5a345e7dfcfa607 controls (exact saved bytes)',
 'wholeManifest':fact(whole),'changedSources':[{'path':row['path'],**row['candidate']} for row in wholedata['files']],
 'unchangedInheritedInputs':initial['inheritedProductionInputs'],'combinedUniqueInputs':335,'noncandidateInputs':326,
 'unaffectedBoundCanonicalInputsMatched':len(unaffected),'currentCanonicalMatchesFrozenDeltaSources':len(canonicaldelta),
 'matchedDeltaSources':canonicaldelta,'pendingDeltaSources':pending,'renewalShellExecutableLinesUnchanged':True,
 'ledgerPhaseCount':10,'separatelyRequiredFinalResultGate':True,'phaseCountIncludingFinalResult':11}
(p/'production-composition-final.json').write_text(json.dumps(composition,indent=2)+'\n',encoding='utf-8')
actual=[]
for name in ('core-guards-1','native-guards-1','package-guards-1','core-selector-guards-1','core-selector-guards-2',core.stem):
 if name in [x['name'] for x in actual]:continue
 record=p/(name+'.json');d=load(record);assert d['successful'] and d['failures']==d['errors']==d['skipped']==0
 actual.append({'name':name,'actualTestsRun':d['actualTestsRun'],'record':fact(record),'log':fact(p/(name+'.log'))})
previous=r/'.build/consolidated-sdk-login-events-dismiss-lifecycle-delta/preparation/final-v1.json'
output={'schemaVersion':1,'status':'frozen-ignored-optional-unified-delta-reuse-and-actual-SDK-harness-repair-awaiting-independent-review',
 'frozenUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'baselineControlCommit':initial['baselineControlCommit'],
 'candidateRoot':w.relative_to(r).as_posix(),'files':files,'wholeProductionManifest':fact(whole),
 'wholeProductionIndependentReview':fact(r/'.build/original-source-login-delta-reuse-independent-review/review.json'),
 'rootTypedRegressionManifest':fact(r/'.build/original-source-login-delta-reuse-root-tests/v2/final-v2.json'),
 'rootActualSDKRepairManifest':fact(repair),'historicalSelectorOnlyRootRepair':fact(r/'.build/currentcore-swift-testing-filter-repair/preparation-v1.json'),
 'actualSDKTerminalIndependentReview':fact(r/'.build/consolidated-sdk-210fb05-independent-review/review-v2.json'),
 'sourceBindingEvidence':fact(p/'production-composition-final.json'),'sourceClosureEvidence':fact(p/'source-closures-final.json'),
 'invariantEvidence':fact(p/'selection-and-gate-invariants-final.json'),'sourceClosureCounts':{k:v['count'] for k,v in closures.items()},
 'combinedProductionChangedSources':19,'inheritedUnchangedSources':3,'combinedUniqueBoundInputs':335,
 'selection':{'AppQualifiedDefinitions':463,'AppArgumentLeaves':466,'SwiftTestingNoArguments':442,'SwiftTestingParameterized':3,'XCTest':18,
 'parameterCases':invariants['parameterCases'],'sameJobRequiredFixture':invariants['requiredSameJobFixture'],
 'coldInvocationSeconds':3600,'invocations':1,'xcresultBundles':1,'NativeOriginal':20,'NativeMainJS':1,
 'NativeHosts':'separate required hosts; MainJS first; both methods/exports/source-stamps/exits fail closed',
 'PackageSelectedFlag':'deltareuse','PackageSelectedMethods':23,'PackageOldMethodCounts':invariants['packageModes'],
 'PackageCompiledInputs':15,'PackageControlInputs':7,'PackageMustExecuteFresh':True,'PackageHistoricalReusePermitted':False},
 'preserved':{'allPriorCoreModeSetsAndBudgets':True,'all463AppDefinitions':True,'allThreeBoolPairsAndLabels':True,
 'NativePrior19MethodOrderAndMainJSGroup':True,'NativeProductionFunctionAST':True,'tenLedgerPhasesAndSeparateResultGate':True,
 'sameJobRequiredSDKFixture':True,'PackageOriginal10Default16Publicbatch17Effects18LoginUI22':True,
 'PackageSourceAndControlClosure':True,'futureV2Protocol':'Excluded; independent later stage does not enter these frozen inputs'},
 'actualPortableValidation':actual,'actualPortableExecutionCount':sum(x['actualTestsRun'] for x in actual),
 'portableRerunExplanation':'Initial seven passed before mandatory actual SDK repairs. Selector-only twelve passed. Summary-repaired fifteen passed. The final sixteen additionally exercise existing CLI exact-mode verification through currentcore with the real-shaped summary. All attempts are retained; unchanged Native3/Package2 and the complete historical26 are not repeated.',
 'finalDistinctAffectedPortableMethods':21,
 'composedFixtureAdditions':['Glyph alias binds the new shared summary_fixture on its existing unittest.TestCase subclass.',
 'Existing CLI exact-mode test now includes active currentcore, uses the same definitions/device-executions fixture, and retains all historical mode assertions. No new test method is added.'],
 'historicalPrior26Evidence':fact(previous),'historicalPrior26IndependentReview':fact(r/'.build/consolidated-sdk-login-events-dismiss-lifecycle-independent-review/review.json'),
 'syntax':fact(p/'syntax-final.json'),'portedSourcesVerified':56,
 'preservedAttemptHistory':[{'record':fact(p/'static-invariant-attempt1.json'),'explanation':'Preparation-only stale preceding Native+6 expectation; actual new inputs+2/115. No production/portable failure.'},
 {'record':fact(p/'composition-attempt1.json'),'explanation':'Preparation-only count incorrectly included result among ten phases. Production keeps ten ledger gates plus separate result, unchanged.'}],
 'preparationScripts':[fact(p/name) for name in ('compose-root-selector.py','compose-root-summary.py','run-portable.py','verify-final.py','freeze-final.py')],
 'notExecuted':['App SDK compilation','Native/JNI runtime tests','SwiftPM23 actual XCTest execution','Apple authority or credentials','Physical device/interactive UI','Current cloud job or tag creation'],
 'claims':{'readerRouteIntegrated':False,'iosValidationPassed':False,'deviceValidationPassed':False,'fullFeatureParityEstablished':False},
 'mutations':{'canonical':False,'Git':False,'cloud':False,'tags':False,'credentials':False}}
target=p/'final-v1.json';assert not target.exists();target.write_text(json.dumps(output,indent=2)+'\n',encoding='utf-8')
print(json.dumps(fact(target)))
