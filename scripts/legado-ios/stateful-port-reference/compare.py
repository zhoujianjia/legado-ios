"""Full-tree raw comparison for the fixed stateful corpus; no value normalization."""
from pathlib import Path
import argparse,hashlib,json,collections,subprocess,sys
if sys.flags.optimize:
    print("ValueError: Optimized Python disables required input assertions; use Python without -O/PYTHONOPTIMIZE", file=sys.stderr)
    sys.exit(1)
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime-jar",type=Path,required=True)
parser.add_argument("--runtime-jar-sha256",required=True)
parser.add_argument("--output-dir",type=Path,required=True)
args=parser.parse_args()
ROOT=Path(__file__).resolve().parents[3]
OUT=args.output_dir.resolve()
for name in ("full-raw-differences.json", "measurement-result.json"):
    if (OUT/name).exists():
        raise SystemExit("Output report already exists; refusing to overwrite evidence: " + name)
REFERENCE=ROOT/'docs/legado-ios/fixtures/android-traditional-stateful-golden.json'
FIXTURE=ROOT/'Packages/LegadoRuntime/jvm/src/test/resources/fixtures/traditional-stateful-cases.json'
JAR=args.runtime_jar.resolve()
PINS={REFERENCE:'339802f01476cc61a004617bc8d14996c3eb0140fbdb1ea73ee05d56be6cdf38',FIXTURE:'a7e0b23bc73c1a32c6d99466aebad25eee8e3c227e12e4d98efccb53d0008ddf',JAR:args.runtime_jar_sha256}
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
for path,pin in PINS.items(): assert sha(path)==pin,(str(path),'pin differs')
reference=json.loads(REFERENCE.read_text(encoding='utf-8'))
port=json.loads((OUT/'port-observed.json').read_text(encoding='utf-8'))
fixture=json.loads(FIXTURE.read_text(encoding='utf-8'))
assert reference['inputFixture']==port['inputFixture']==fixture
assert reference['referenceRunId']==port['referenceRunId']=='f3c545ac-e702-4409-ac99-61a90db617a0'

def diffs(left,right,path=''):
    if type(left)!=type(right):
        yield {'path':path,'reference':left,'port':right,'difference':'json-type-or-null'}
    elif isinstance(left,dict):
        for key in sorted(left.keys()|right.keys()):
            child=path+'/'+str(key)
            if key not in left: yield {'path':child,'referenceMissing':True,'port':right[key],'difference':'missing-field'}
            elif key not in right: yield {'path':child,'reference':left[key],'portMissing':True,'difference':'missing-field'}
            else: yield from diffs(left[key],right[key],child)
    elif isinstance(left,list):
        if len(left)!=len(right): yield {'path':path+'/length','reference':len(left),'port':len(right),'difference':'array-length'}
        for index,(a,b) in enumerate(zip(left,right)): yield from diffs(a,b,path+'/'+str(index))
    elif left!=right: yield {'path':path,'reference':left,'port':right,'difference':'raw-value'}

raw=list(diffs(reference,port))
for item in raw:
    path=item['path']
    if '/identityHashCodes/' in path: item['classification']='per-process-identity-hash-diagnostic'
    elif not path.startswith('/scenarios/'): item['classification']='execution-platform-report-metadata'
    else: item['classification']='scenario-semantic-raw-difference'
(OUT/'full-raw-differences.json').write_text(json.dumps({'schemaVersion':1,'referenceSHA256':sha(REFERENCE),'portSHA256':sha(OUT/'port-observed.json'),'rawStringsNormalized':False,'missingFieldsSynthesized':False,'differenceCount':len(raw),'differences':raw},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

# Exact comparisons below are explicitly named subcontracts; the full report
# differences remain above, including every raw identity and platform value.
scenarios=[]; api_exact=0; api_different=0; returns_exact=0; setups_exact=0; state_exact=0
all_identity=True
assert len(reference['scenarios'])==len(port['scenarios'])==len(fixture['scenarios'])
for index,(expected,observed) in enumerate(zip(reference['scenarios'],port['scenarios'])):
    assert len(expected['steps'])==len(observed['steps'])==len(fixture['scenarios'][index]['steps'])
    assert expected['input']==observed['input']==fixture['scenarios'][index]
    assert expected['scenarioId']==observed['scenarioId']
    sid=expected['scenarioId']; steps=[]
    graphs=[]
    if observed.get('resolvedSetup'): graphs.append(observed['resolvedSetup']['runtimeIdentity'])
    for step in observed['steps']:
        graphs.extend(step['runtimeIdentity'][phase] for phase in ('before','after'))
    baseline=graphs[0]['identityHashCodes']
    identity_ok=all(g['identityHashCodes']==baseline and all(v is True for group in g['referenceEqualityToSetup'].values() for v in group.values()) for g in graphs)
    all_identity &= identity_ok
    for e,o in zip(expected['steps'],observed['steps']):
        assert e['input']==o['input'] and e['stepId']==o['stepId']
        fields=('outcome','actual','exception','observationFailure','setupCompleted','apiInvoked','completed')
        exact=all(e[k]==o[k] for k in fields)
        before_equal=e['before']==o['before'];after_equal=e['after']==o['after']
        state_exact+=int(before_equal)+int(after_equal)
        if e['input']['kind']=='call':
            api_exact+=int(exact); api_different+=int(not exact)
            returns_exact+=int(e['outcome']=='return' and o['outcome']=='return' and e['actual']==o['actual'])
        else: setups_exact+=int(exact)
        step_diff=[x for x in raw if x['path'].startswith(f'/scenarios/{index}/steps/{len(steps)}/') and x['classification']=='scenario-semantic-raw-difference']
        steps.append({'stepId':e['stepId'],'kind':e['input']['kind'],'api':e['input'].get('api'),'apiInvoked':o['apiInvoked'],'completed':o['completed'],'rawOutcomeActualExceptionExactlyMatch':exact,'beforeStateExactlyMatches':before_equal,'afterStateExactlyMatches':after_equal,'rawSemanticDifferences':step_diff})
    scenario_diffs=[x for x in raw if x['path'].startswith(f'/scenarios/{index}/') and x['classification']=='scenario-semantic-raw-difference']
    scenarios.append({'scenarioId':sid,'observationCompleted':observed['completed'],'setupCompleted':observed['setupCompleted'],'cleanupCompleted':observed['cleanup']['completed'],'retainsSameDeclaredObjectsAcrossOrderedSteps':identity_ok,'initialSemanticStateExactlyMatches':expected['resolvedSetup']['initialState']==observed['resolvedSetup']['initialState'],'initialPutReturnsExactlyMatch':expected['resolvedSetup']['initialPutReturns']==observed['resolvedSetup']['initialPutReturns'],'rawSemanticDifferenceCount':len(scenario_diffs),'steps':steps})

counts=collections.Counter(x['classification'] for x in raw)
semantic=[x for x in raw if x['classification']=='scenario-semantic-raw-difference']
report={'schemaVersion':1,'measurementKind':'frozen-JAR-stateful-port-desktop-JVM-replay','originalReferenceRunId':reference['referenceRunId'],'ordinaryRuntimeJarSHA256':sha(JAR),'inputFixtureSHA256':sha(FIXTURE),'referenceSHA256':sha(REFERENCE),'portObservedSHA256':sha(OUT/'port-observed.json'),'fullRawDifferencesSHA256':sha(OUT/'full-raw-differences.json'),'executed':{'scenarioCount':len(port['scenarios']),'orderedSteps':port['completedSteps'],'apiCalls':port['executed'],'returnObservations':port['returnedObservations'],'ordinaryExceptionObservations':port['exceptionObservations'],'allDeclaredStepsObserved':port['passed'],'observationFailures':port['failed']},'comparison':{'fullRawTreeExactlyMatches':not raw,'fullRawDifferenceCount':len(raw),'differenceClassifications':dict(counts),'rawScenarioSemanticDifferenceCount':len(semantic),'apiOutcomeActualExceptionExactlyMatching':api_exact,'apiOutcomeActualExceptionDifferent':api_different,'returnedTypedValuesExactlyMatching':returns_exact,'setupMutationStepsExactlyMatching':setups_exact,'beforeAndAfterStateSnapshotsExactlyMatching':state_exact,'beforeAndAfterStateSnapshotCount':2*port['completedSteps'],'declaredObjectIdentityStableWithinEveryScenario':all_identity,'rawScenarioSemanticDifferences':semantic},'method':{'runsOnlyFixedPublicFixture':True,'usesFrozenOrdinaryJarWithoutProductCodeRecompilation':True,'originalRulesOrStepOrderModified':False,'separateGradleProjectAndBuildDirectory':True,'AndroidEntryAndCleanupAdaptationsDocumented':'harness-adaptations.diff','oneRuleEnvironmentPerScenarioExplicitlyInjectedAtPortConstructors':True,'sameOriginalReferenceRunIdRetainedForLiteralURLComparison':True,'allRawDifferencesRetained':True,'stringsTrimmedOrNormalized':False,'exceptionMessagesNormalized':False,'missingFieldsSynthesized':False,'identityHashCodesRetainedAndComparedAsPerProcessDiagnostics':True,'identityHashesExcludedFromNamedSemanticCountsOnlyPerOriginalHarnessContract':True,'platformMetadataExcludedFromNamedScenarioSemanticCounts':True},'limitations':['Desktop JDK21 observation, not iOS/Zero/device validation.','The port has finite entity/host ABI; no Room/persistent cache/network/browser/batch or product reading route is covered by this fixture.','Any raw exception-message difference remains a failing exact comparison, including a dynamic script identifier; no normalization is applied.','Same object references are checked throughout each process; identityHashCode integers necessarily belong to different Android/JVM processes and are not semantic compatibility values.','This observation tool is not a full-feature, iOS, device or G4 compatibility result.'],'acceptance':{'observationComplete':port['passed'],'allDeclaredAPICallsRawMatch':api_different==0 and api_exact==reference['total'],'compatibilityValidationPassed':False,'iosValidationPassed':False,'deviceValidationPassed':False,'g4ValidationPassed':False,'fullFeatureParityEstablished':False},'scenarios':scenarios}
files=['src/main/kotlin/io/legado/app/reference/TraditionalStatefulGoldenTest.kt','src/main/java/RuntimeClassOrigins.java','settings.gradle.kts','build.gradle.kts','harness-adaptations.diff','measurement-preparation.json','compile.log','run.log','port-observed.json','full-raw-differences.json','class-origins.json','class-origins.log','execution-environment.json']
report['evidenceFiles']={name:{'bytes':(OUT/name).stat().st_size,'sha256':sha(OUT/name)} for name in files}
(OUT/'measurement-result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:report[k] for k in ('executed','acceptance')},ensure_ascii=False,indent=2))
print('measurement-result.json SHA256',sha(OUT/'measurement-result.json'))
