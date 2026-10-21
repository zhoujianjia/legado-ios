from pathlib import Path
import ast,hashlib,json,re,shutil,subprocess
ROOT=Path('F:/yuedu-reader');ST=ROOT/'.build/consolidated-sdk-s2-preupdate-native-result-checkpoint'
def fact(p):
 raw=p.read_bytes();return {'path':p.relative_to(ROOT).as_posix(),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def load(p):return json.loads(p.read_bytes())
d=load(ST/'draft-v1.json');rosters=load(ST/'source-rosters-draft-v1.json')
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()=='fd74d9588662a77b37504ea04e4804cd8dbb113b'
files=[]
for row in d['controls']:
 rel=row['path'];p=ST/'work'/rel;before=ST/'rawbaseline'/rel
 assert before.read_bytes()==(ROOT/rel).read_bytes()
 dest=ST/'snapshot-v1/work'/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
 files.append({**row,'candidate':fact(dest)})
for row in rosters['union']:
 p=ST/'validation-root'/row['path'];f=fact(p)
 assert all(f[k]==row[k]for k in ['bytes','sha256'])
 if row['path']not in {f['path']for f in files}:assert p.read_bytes()==(ROOT/row['path']).read_bytes(),row['path']
for rel in d['productionOwnerPaths']:assert (ST/'validation-root'/rel).read_bytes()==(ROOT/rel).read_bytes(),rel

oldlabel='Execute463 current-core definitions with466 exact native argument leaves';newlabel='Execute471 current-core definitions with474 exact native argument leaves'
history=ST/'history-first-guards-v1/test-renewal-probe-tools.py';final=ST/'work/scripts/reader-experience/test-renewal-probe-tools.py'
assert final.read_text(encoding='utf-8').count(newlabel)==3
assert final.read_text(encoding='utf-8').replace(newlabel,oldlabel)==history.read_text(encoding='utf-8')
changes={}
for name in ['renewal-probe-tools.py','native-smoke-tools.py']:
 rel='scripts/reader-experience/'+name
 a=ast.parse((ST/'rawbaseline'/rel).read_text(encoding='utf-8'));b=ast.parse((ST/'work'/rel).read_text(encoding='utf-8'))
 old={x.name:ast.dump(x,include_attributes=False)for x in a.body if isinstance(x,(ast.FunctionDef,ast.AsyncFunctionDef))}
 new={x.name:ast.dump(x,include_attributes=False)for x in b.body if isinstance(x,(ast.FunctionDef,ast.AsyncFunctionDef))}
 assert old.keys()==new.keys()
 changes[name]=[name for name in old if old[name]!=new[name]]
assert changes['native-smoke-tools.py']==[]
assert set(changes['renewal-probe-tools.py'])=={'_currentcore_source_state','run_currentcore','verify_currentcore_pipeline'}
first=load(ST/'affected-validation-v1.json');supplement=load(ST/'affected-workflow-label-v2.json')
assert [x['exitCode']for x in first['executions']]==[1,0]and supplement['exitCode']==0
allmethods=[n for x in first['executions']for n in x['methods']]+supplement['methods'];assert len(allmethods)==7 and len(set(allmethods))==6
assert 'Ran 2 tests' in (ST/'affected-core-v1.log').read_text(encoding='utf-8') and 'FAILED (failures=1)'in(ST/'affected-core-v1.log').read_text(encoding='utf-8')
assert 'Ran 2 tests'in(ST/'affected-native-v1.log').read_text(encoding='utf-8')and'OK'in(ST/'affected-native-v1.log').read_text(encoding='utf-8')
assert 'Ran 3 tests'in(ST/'affected-workflow-label-v2.log').read_text(encoding='utf-8')and'OK'in(ST/'affected-workflow-label-v2.log').read_text(encoding='utf-8')
assert 'Modules/Core/RuleEngine/ModernParser/JS/LegadoOriginalResourceObserver.swift'not in {r['path']for r in rosters['union']}
reader=(ST/'validation-root/Tests/iOS/LegadoNativeOriginalReaderTests.swift').read_text(encoding='utf-8')
assert len(re.findall(r'(?m)^\s+func (test\w+)\s*\(',reader))==17
assert 'testNativeOriginalResourceSnifferUsesOwnedFramesAuthoredJSAndCancellation'not in reader
assert hashlib.sha256(reader.encode()).hexdigest()=='93b99960f1239b785098a6393d9d31a786380210bb48de502aaad43a775b6b1b'
rosterfile=ST/'source-closures-final-v1.json';rosterfile.write_bytes((json.dumps(rosters,indent=2)+'\n').encode())
report={
 'schemaVersion':1,'status':'frozen-controls-awaiting-independent-review-and-next-unified-SDK-Native-checkpoint',
 'baselineCanonicalCommit':d['baselineCommit'],'sourceRoot':(ST/'snapshot-v1/work').relative_to(ROOT).as_posix(),
 'files':files,'changedControls':7,'parents':d['parents'],'productionOwnerPaths':d['productionOwnerPaths'],
 'productionSourceBindings':[{'path':rel,**{k:fact(ROOT/rel)[k]for k in ['bytes','sha256']}}for rel in d['productionOwnerPaths']],
 'sourceClosures':fact(rosterfile),'countsForNextCheckpoint':d['counts'],'selectorsAdded':d['selectorsAdded'],
 'byteBinding':{'productionOwnersExactCanonical':35,'uniqueInputs':380,'unchangedCanonicalNonControlInputs':373,'controlCandidates':7,'coreUnique':364,'nativeUnique':180,'sourceMismatch':0,'ReaderUnionBytes':139151,'ReaderUnionSHA256':'93b99960f1239b785098a6393d9d31a786380210bb48de502aaad43a775b6b1b'},
 'preservedControls':d['preserved'],
 'productionFunctionAST':{'changedFunctions':changes,'newOrRemovedFunctions':[],'nativeAllFunctionsExact':True,'coreChanges':'Only currentcore source state, phase-run ledger definition/leaf constants and pipeline validation constants463/466 become471/474. No command, budget, exit/error or fixture logic changes.'},
 'actualPortableValidation':{
  'firstExecution':fact(ST/'affected-validation-v1.json'),'firstCoreLog':fact(ST/'affected-core-v1.log'),'firstNativeLog':fact(ST/'affected-native-v1.log'),
  'supplement':fact(ST/'affected-workflow-label-v2.json'),'supplementLog':fact(ST/'affected-workflow-label-v2.log'),
  'distinctMethods':6,'methodExecutions':7,'passedExecutions':6,'failedExecutions':1,'distinctMethodsWithPassingEvidence':6,
  'initialResult':'Four methods executed: core1 pass+1 failure; Native2 pass. The exact failure was a stale old workflow-label assertion.',
  'localCorrection':'Exactly three existing workflow-label expectations changed from Execute463/466 to Execute471/474. The three affected methods then ran once and passed; one was the initial failed method, two had not run in this checkpoint. No previously passed method was repeated.',
  'transitiveEvidenceReuse':'Replacing only the three new label literals with their old values reconstructs the entire first-execution test file byte-for-byte. Core production tools, fake fixture helpers, source snapshot and all other methods remain exact; the earlier passed core method and both Native methods are reused.',
  'methodNamesInExecutionOrder':allmethods,'notASingleFreshGreenSuite':True},
 'preparationHistory':d['preparationHistory'],
 'historicalEvidence':[fact(ST/'history-first-guards-v1'/p)for p in ['draft-v1.json','source-rosters-draft-v1.json','test-renewal-probe-tools.py','affected-validation-v1.json','affected-core-v1.log','affected-native-v1.log']],
 'tools':[fact(ST/p)for p in ['prepare.py','run-affected.py','run-workflow-label-affected.py','freeze.py']],
 'sourceReviewFindings':[],
 'scopeLimits':[
  'Portable guards exercise synthetic evidence gates and source identities. They are not Swift compilation, actual App/Native/WK tests, Apple account or device renewal proof.',
  'No Swift/JVM compilation, native parser, cloud query, tag, push, canonical source write or canonical Git write occurred. Existing portable tests create their own temporary test repositories as part of source-stamp fixtures.',
  'The previously closed f233 SDK/Native terminal failures remain failures. The next source snapshot changes are not retroactive passes.',
  'S2 first-use registration remains in another ignored development slice and is excluded. Resource sniffer v3 remains unactivated and absent from production inputs/method selection.',
  'Package loginv2 selection remains24 methods/23 source facts. Old modes10/16/17/18/22/23/24, SDK mandatory producer, exact Bool false/true identities, single3600-second App invocation, independent Native hosts and two cold-process hosts remain unchanged.'
 ],
 'actualExecutions':{'SwiftSDK':0,'JVMCompile':0,'AppTests':0,'NativeTests':0,'WKPlatformTests':0,'AppleAccountRequests':0,'cloudQueries':0,'newTags':0},
 'allNonDeviceWorkComplete':False,'automaticSelfRenewalImplemented':False,'fullLegadoCompatibilityEstablished':False,'legalRedistributionClearanceEstablished':False
}
p=ST/'final-v1.json';p.write_bytes((json.dumps(report,ensure_ascii=False,indent=2)+'\n').encode());print(json.dumps(fact(p)));print(changes)
