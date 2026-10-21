"""Root review entry. This file is prepared only; the author must not execute it.

After reviewing exact source/evidence and plan edits, Root may explicitly run:
  python .build/sdk-88c61ee-terminal-source-independent-review/archive-sdk88-terminal.py --apply-canonical

No Git mutation, network, build, test, parser or workflow invocation is performed.
cloud-validation.json is an older native-runtime history and is deliberately not
rewritten. Current SDK handle ownership lives in completion-plan.json.
"""
from pathlib import Path
import argparse
import copy
import datetime
import hashlib
import json
import re

R=Path('F:/yuedu-reader')
T=R/'.build/sdk-88c61ee-terminal'
S=R/'.build/sdk-88c61ee-terminal-source-independent-review'
A=T/'SDK/extracted/reader-renewal-probe'
P=T/'Package/extracted/reader-renewal-original-api'
COMMIT='88c61ee4b80889a617d344fda668d077f73fa95b'
RUN=39520239925
JOB=118962037971
BASE=R/'docs/legado-ios/evidence/sdk-88c61ee-terminal'
RECORD=R/'docs/legado-ios/core-sdk-88c61ee-terminal-result.json'
PLAN=R/'docs/legado-ios/completion-plan.json'
FLAGS=('allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished')

def read(p):return json.loads(p.read_bytes())
def facts(raw):return dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def fact(p):return dict(path=p.relative_to(R).as_posix(),**facts(p.read_bytes()))
def encode(d):return (json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
def require(p,size,digest):
 raw=p.read_bytes();assert facts(raw)==dict(bytes=size,sha256=digest),str(p)
 return raw
def normalized(raw):
 assert b'\0' not in raw,'Binary data is never part of this archive.'
 text=raw.decode('utf-8-sig')
 assert not re.search(r'(?i)[?&](?:X-Amz-Signature|X-Goog-Signature|sig|signature|token)=',text),'Signed/private URI parameter rejected.'
 assert not re.search(r'(?im)^-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',text),'Private-key material rejected.'
 return ('\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n')+'\n').encode('utf-8') if text else b''

def main():
 parser=argparse.ArgumentParser(description='Explicit Root-only canonical SDK88 evidence archive; never fetches/builds/tests.')
 parser.add_argument('--apply-canonical',action='store_true',help='Root explicitly approves the reviewed archive and exact one-handle plan update.')
 args=parser.parse_args()
 if not args.apply_canonical:
  raise SystemExit('Prepared helper only. Root must inspect this source and explicitly provide --apply-canonical.')

 require(T/'factual-review-v1.json',10549,'09caed66d1f659473ee1bd18094df722e6e24c97b0d7a39a96e1047b975bbefd')
 require(S/'review-v1.json',7879,'16cb29d48ab4a7603ff2837e76552bdbbc2d8b2b87e9516162c29e26337802fe')
 require(S/'historical-source-bindings-compact-v1.json',106872,'7884dba37fd10634282f4388c7f0a4c61c609bcab5576a79bf4a7c4a60fe20b8')
 require(S/'phase-source-binding-v1.json',5305,'1822bba669982add6f386cdb746e16de52f4f31ed97f31918fb89a463a99f704')
 f=read(T/'factual-review-v1.json');review=read(S/'review-v1.json')
 assert review['approved'] is True and review['failedChecks']==0 and review['remainingMismatches']==[]
 assert f['sourceCommit']==COMMIT and f['runID']==RUN and f['jobID']==JOB
 assert f['App']['actualDefinitions']==f['App']['actualLeaves']==0 and f['App']['uniqueCompilerErrors']==2
 assert f['App']['nativePhaseExitCode']==1 and f['App']['nativePhaseTimedOut'] is False
 assert review['actualPackage']['passed']==24 and review['actualPackage']['failed']==review['actualPackage']['skipped']==0
 assert review['producerScope']['commands']==48 and review['producerScope']['publicOutputs']==43 and review['producerScope']['SDKProducedMachOs']==4
 assert all(f['completionFlags'][k] is False for k in FLAGS)
 assert not BASE.exists() and not RECORD.exists(),'Do not overwrite an existing or partial canonical archive.'

 original_plan=PLAN.read_bytes();plan=read(PLAN);cloud=plan['execution']['cloudTriggerPolicy']
 assert all(plan[k] is False for k in FLAGS)
 handles=cloud['onlyLiveSDKHandles']
 assert len(handles)==1 and handles[0]['runID']==RUN and handles[0]['jobID']==JOB and handles[0]['sourceCommit']==COMMIT,'Never clear unrelated/new live handles.'
 assert cloud['currentUnifiedCheckpoint']['sourceCommit']==COMMIT
 assert cloud['latestOriginalNativeTerminal']['runID']==39520240533 and cloud['latestOriginalNativeTerminal']['conclusion']=='failure'
 assert cloud['currentUnifiedCheckpoint']['counts']['coreInputs']==346,'Historical request counters must not become future349/161 counts.'

 items={
  'factual-review-v1.json':T/'factual-review-v1.json',
  'terminal-jobs.json':T/'terminal-jobs.json',
  'archive-integrity-v1.json':T/'archive-integrity-v1.json',
  'source-independent-review.json':S/'review-v1.json',
  'historical-source-bindings.json':S/'historical-source-bindings-compact-v1.json',
  'phase-source-binding.json':S/'phase-source-binding-v1.json',
  'scripts/verify-historical-source.py':S/'verify-v1.py',
  'scripts/archive-sdk88-terminal.py':Path(__file__).resolve(),
 }
 for name in ['producer-scope.json','package-scope.json','compiler-errors.json','actual-selectors.json']:
  items['facts/'+name]=T/'factual-v1'/name
 for name in ['source-inputs.json','currentcore-pipeline.json','currentcore-completion.json','currentcore-summary.json','currentcore-tests.json','currentcore-extraction.json','sdk-fixture-binding.json','sdk-fixture-before-build.json','overlays.json','xcode-version.log','currentcore-native.log','currentcore-native.log.stderr.log','currentcore-export.log','currentcore-export.log.stderr.log','currentcore-cases.log','currentcore-cases.log.stderr.log']:
  items['native/'+name]=A/name
 for row in f['phases']:
  source=R/row['raw']['path'];assert facts(source.read_bytes())==dict(bytes=row['raw']['bytes'],sha256=row['raw']['sha256'])
  items['native/'+source.name]=source
 for name in ['source-inputs.json','result.json','execution.json','xunit.xml','tests.log','swift-executable.log','swift-version.log','swift-test-help.log']:
  items['package/'+name]=P/name
 items['producer/sdk-produced-fixture-manifest.json']=A/'sdk-produced-public/sdk-produced-fixture-manifest.json'

 # Materialize all reviewed content in memory before the first canonical write.
 payloads={};preserved=[]
 for name,source in items.items():
  assert not any(part in {'..','private'} for part in Path(name).parts)
  assert not source.name.startswith(('private-','raw-artifacts-response','raw-job-logs-response'))
  raw=source.read_bytes();assert len(raw)<300_000,'Large raw evidence stays ignored; retain byte facts instead.'
  content=normalized(raw);target=BASE/name
  payloads[target]=content
  preserved.append(dict(path=target.relative_to(R).as_posix(),**facts(content),original=fact(source),normalization='UTF8/LF; horizontal line-end and extra EOF whitespace only. Exact original byte facts retained.'))

 raw_log=(A/'currentcore-tests.log').read_text(encoding='utf-8').splitlines()
 compiler=read(T/'factual-v1/compiler-errors.json')
 indexes=set()
 for error in compiler['unique']:
  line=error['firstLogLine']
  indexes.update(range(max(1,line-2),min(len(raw_log),line+3)+1))
 excerpt='Actual production compiler diagnostics; original raw log facts are retained in large-evidence-facts.json.\n'+''.join(str(i)+': '+raw_log[i-1]+'\n' for i in sorted(indexes))
 payloads[BASE/'compiler-errors-excerpt.txt']=normalized(excerpt.encode('utf-8'))
 integrity=read(T/'archive-integrity-v1.json')
 sdk_archive=next(x for x in integrity if x['label']=='SDK')
 member=next(x for x in sdk_archive['members'] if x['path']=='reader-renewal-probe/currentcore-tests.log')
 assert member['bytes']==7055644 and member['sha256']=='edd0d1a5f47c1a4229c8aa6dc9ae8f677a26b8e2c186a84dfa580d926a4daef2'
 assert facts((A/'currentcore-tests.log').read_bytes())==dict(bytes=member['bytes'],sha256=member['sha256'])
 large=dict(scope='Original ZIPs, binary/public fixture payloads, and large logs stay ignored. No contents copied.',nativeRawLog=dict(**fact(A/'currentcore-tests.log'),archive=sdk_archive['archive'],artifactID=sdk_archive['artifactID'],member=member),decodedJobLog=fact(T/'decoded-job.log'),archives=[dict(label=x['label'],artifactID=x['artifactID'],archive=x['archive'],CRC=x['CRC'],safePaths=x['safePaths']) for x in integrity],explicitlyExcluded=['private-sdk-download.json','private-package-download.json','raw-artifacts-response.json','raw-job-logs-response.json','ZIP bytes','MachO/CMS/CD/certificate/IPA binary bytes'])
 payloads[BASE/'large-evidence-facts.json']=encode(large)

 record=dict(schemaVersion=1,recordedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),sourceCommit=COMMIT,workflowRun=RUN,SDKJob=JOB,status='completed-failure-production-compiler-block-App0',queryAgain=False,
  AppSDK=dict(selectedDefinitions=463,intendedLeaves=466,actualDefinitions=0,actualLeaves=0,actualSummaryFailedTests=0,summaryResult='unknown',compilationBlocked=True,completeSuiteAcceptance=False,uniqueCompilerErrors=2,repeatedCompilerDiagnostics=50,firstFailure=dict(phase='native',exitCode=1),nativePhaseExitCode=1,actualXcodebuildExitCode=65,timedOut=False,resultProduced=False,requiredSignerSelected=True,requiredSignerExecuted=False),
  sourceBinding=dict(coreInputs=346,PackageInputs=23,producerInputs=7,allHistoricalGitBlobBytesMatched=True,beforeAfterSourceSnapshots=22,rawPhaseLedgers=11,proof='evidence/sdk-88c61ee-terminal/historical-source-bindings.json',scope='Declared historical evidence inventories, not every transitive Xcode/SDK build dependency.'),
  producer=dict(commandsSucceeded=48,actualSDKMachOs=4,publicOutputFacts=43,allPublicBytesMatched=True,ownedKeychainCleanupRecorded=True,requiredAppSignerExecuted=False),
  Package=dict(actualXCTestMethods=24,passed=24,failed=0,skipped=0,packageSourceInputs=16,controls=7,allSourceFacts=23,XMLAndActualVerbosePassedIDsMatch=True,JVMExecuted=False,scope='Independent same-source source-only macOS API/protocol cases, not iOS App/JNI.'),
  preservedEvidence=preserved,proofLimits=review['limits']+['Later API/source fixes including9d826e7 do not modify this historical compiler failure. No later source or complete compatibility acceptance is implied.','No signed URL, private response or binary is archived. Large raw log is retained by its original ZIP/member/hash facts.'],
  claims=dict(SDKPassed=False,AppTestsPassed=False,AppLinkAndCodeSignPassed=False,physicalDeviceValidationPassed=False,selfRenewalVerified=False,unattendedRenewalVerified=False,sourceCompatibilityComplete=False),**{k:False for k in FLAGS})
 payloads[RECORD]=encode(record)
 sdk_terminal=dict(sourceCommit=COMMIT,runID=RUN,jobID=JOB,status='completed',conclusion='failure',queryAgain=False,record=RECORD.relative_to(R).as_posix(),failure='Two unique production WebKit Swift API-shape compiler errors (50 repeated diagnostics); App executed0, no native timeout.',AppDefinitionsExecuted=0,AppLeavesExecuted=0,AppSuitePassed=False,uniqueCompilerErrors=2,PackageMethodsPassed=24,producerCommandsPassed=48,producerPublicOutputs=43,producerMachOs=4)
 cloud['onlyLiveSDKHandles']=[]
 cloud['latestSDKTerminal']=copy.deepcopy(sdk_terminal)
 cloud['currentCoreLatestTerminal']=copy.deepcopy(sdk_terminal)
 cloud['currentUnifiedCheckpoint']['sdkTerminal']=copy.deepcopy(sdk_terminal)
 cloud['currentUnifiedCheckpoint']['actualResultAccepted']=False
 cloud['alreadyRunningTasks']='No live SDK handles. Both immutable88c runs are terminal and archived. Native failed five JVM expectations; SDK App executed0 tests because two production API errors blocked compilation. Do not query either handle again.'
 cloud['nextPlannedCheckpoint']='Compose reviewed API fixes, five JVM expectation repairs, and ordered/resource platform characterization with exact future349/161 controls; choose one coherent later SDK/Native cohort. No duplicate run or IPA tag during development.'
 plan['existingEvidence']['sdk-88c61ee-terminal']=dict(path=RECORD.relative_to(R).as_posix(),scope='Historical Core346/Package23/producer7 Git-bound; SDK App executed0 due two unique production compiler errors, Package24 and owned producer48/43/4 succeeded independently.')
 records=plan.setdefault('activeDevelopmentBatchRecords',[])
 if RECORD.relative_to(R).as_posix() not in records:records.append(RECORD.relative_to(R).as_posix())
 plan['updatedOn']=datetime.datetime.now(datetime.timezone.utc).date().isoformat()
 assert all(plan[k] is False for k in FLAGS) and cloud['onlyLiveSDKHandles']==[]
 assert cloud['latestOriginalNativeTerminal']['runID']==39520240533,'Only SDK terminal ownership may change here.'
 payloads[PLAN]=encode(plan)
 assert PLAN.read_bytes()==original_plan,'Plan changed during archive preparation; review current state again.'
 assert len(payloads)==len(set(payloads))
 for target,raw in payloads.items():
  assert target.resolve().is_relative_to((R/'docs/legado-ios').resolve())
  if target!=PLAN:assert not target.exists(),str(target)
 # This is the first write boundary. Only Root may reach it explicitly.
 for target,raw in payloads.items():
  target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
 roster=[dict(path=p.relative_to(R).as_posix(),**facts(b)) for p,b in payloads.items()]
 (S/'canonical-archive-roster.json').write_bytes(encode(dict(canonicalPaths=roster,onlyLiveSDKHandles=0,testsRerun=0,cloudFetches=0,GitWrites=False,completionFlags={k:False for k in FLAGS})))
 print(json.dumps(dict(canonicalPaths=len(roster),liveSDKHandles=0,AppTests=0,PackagePassed=24,producerCommands=48,newTags=0)))

if __name__=='__main__':main()
