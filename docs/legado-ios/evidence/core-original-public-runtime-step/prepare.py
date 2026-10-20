import datetime,hashlib,json,re,subprocess,xml.etree.ElementTree as ET,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent
assert not (out/'preparation.json').exists()
def meta(path):
 path=Path(path)
 if not path.is_absolute():path=root/path
 raw=path.read_bytes();return dict(path=path.relative_to(root).as_posix(),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def data(name):return json.loads((out/name).read_bytes())
focused=data('focused-final.json');ordinary=data('ordinary-v1.json');grammar=data('swift-grammar.json')
assert focused['exitCode']==ordinary['exitCode']==0
for item in focused['sourceBinding']:
 assert meta(item['path'])==item
 assert (out/'focused-final-sources'/item['path']).read_bytes()==(root/item['path']).read_bytes()
for item in grammar['files']:
 assert not item['grammarErrors'] and meta(item['path'])=={k:item[k] for k in ['path','bytes','sha256']}
 assert (out/'swift-sources'/item['path']).read_bytes()==(root/item['path']).read_bytes()
xmls=sorted((out/'focused-final-xml').glob('*.xml'));leaves=[]
for xml in xmls:
 suite=ET.parse(xml).getroot();assert suite.attrib['failures']==suite.attrib['errors']==suite.attrib['skipped']=='0'
 leaves += [(x.attrib['classname'],x.attrib['name']) for x in suite.findall('testcase')]
assert len(xmls)==17 and len(leaves)==len(set(leaves))==171
assert sum(x['tests'] for x in focused['junitSuites'])==171
jar=meta(ordinary['ordinaryJar']['path']);assert jar=={k:ordinary['ordinaryJar'][k] for k in ['path','bytes','sha256']}
assert (root/'Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar').read_bytes()==(root/jar['path']).read_bytes()
assert len(ordinary['ordinaryJar']['byteEqualProvenanceAndNotices'])==21
assert b'PACKAGED_ORIGINAL_TRADITIONAL_OK' in (out/'ordinary-v1.log').read_bytes()
manifest=root/'Packages/LegadoRuntime/vendor/original-rule/manifest.json';value=json.loads(manifest.read_bytes());prior=data('manifest.before.json')
assert value['sourceProvenance']==prior['sourceProvenance']
archive=Path('F:/legado-master.zip');assert hashlib.sha256(archive.read_bytes()).hexdigest()==value['originalArchiveSHA256']
with zipfile.ZipFile(archive) as original:
 for item in value['sourceProvenance']:
  raw=original.read(item['archivePath']);assert (manifest.parent/item['vendorPath']).read_bytes()==raw
  assert len(raw)==item['bytes'] and hashlib.sha256(raw).hexdigest()==item['sha256']
for group in [value['portedSources']]+[value[k]['integrationSources'] for k in ['urlExpansionIntegration','webBookIntegration','statePersistenceIntegration','publicTraditionalRuntimeIntegration']]+[value['publicTraditionalRuntimeIntegration']['apiSources']]:
 for item in group:assert meta(item['path'])==item
git='D:/app/Git/cmd/git.exe'
prefixes=['Packages/LegadoRuntime/jvm','Packages/LegadoRuntime/Sources/LegadoRuntime','Packages/LegadoRuntime/Tests/LegadoRuntimeTests','Packages/LegadoRuntime/vendor/original-rule']
names=subprocess.check_output([git,'diff','--name-only','5d158a27','--']+prefixes,cwd=root).decode().splitlines()
names+=subprocess.check_output([git,'ls-files','--others','--exclude-standard','--']+prefixes,cwd=root).decode().splitlines()
final=[]
for name in sorted(set(names)):
 item=meta(name);target=out/'final-sources'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((root/name).read_bytes());final.append(item)
assert len(final)==10
testpath='Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift'
swiftmethods=re.findall(r'    func (test\w+)\(', (root/testpath).read_text(encoding='utf-8'))
assert len(swiftmethods)==len(set(swiftmethods))==5
oldswift=['testSessionAndUnicodeRequestRoundTrip','testConfiguredSessionKeepsTransportOptionsOutsideSourceData',
 'testConfiguredSessionCannotSilentlyUseLegacyTransport','testRuntimeOperationsRunOnSignalableBackgroundThreads','testCancelReachesRuntimeWhileExecuteWorkerIsBlocked']
oldfile=root/'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoRuntimeTests.swift'
assert all('func '+name+'(' in oldfile.read_text(encoding='utf-8') for name in oldswift)
notes={
 'v1':'Two fixture errors: Java String returned by original java.get retains Java method semantics, so String(value).length is required rather than value.length. A valid Book construction may read owned variables before rejecting a mismatched Chapter; invalid requests still must perform no state commits/HTTP. Corrected those fixture assumptions without changing original Java types or relaxing production identity checks.',
 'v2':'35 methods passed, including six actual public business facade methods, thirteen retained WebBook, eleven persistent-owner and five old mainJs facade methods.',
 'v3':'35 passed after extending actual output/error budget coverage and rejecting non-text Book DTO; no silent output/error-message truncation.',
 'final':'Final accepted 17 XML/171 unique methods: six new public business facade regressions plus 165 affected existing methods. All zero fail/error/skip; repeated development runs are not added together.'}
attempts=[]
for version,note in notes.items():
 run=data('focused-'+version+'.json');attempts.append(dict(version=version,record=meta(out/('focused-'+version+'.json')),log=meta(out/('focused-'+version+'.log')),
  exitCode=run['exitCode'],tests=sum(x['tests'] for x in run['junitSuites']),failures=sum(x['failures'] for x in run['junitSuites']),note=note,notAddedTogether=True))
record=dict(schemaVersion=1,stage='C3/C4 opt-in public original WebBook business JSON and Swift Package API foundation',status='in_progress',
 frozenAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),baseCommit='5d158a27',currentCommitAtFreeze=subprocess.check_output([git,'rev-parse','HEAD'],cwd=root).decode().strip(),
 scope='Actual Windows JDK21 JVM public facade plus assembled ordinary JAR only. Swift grammar/fixtures are prepared, not compiled or executed here. No JNI/native/App traditional route/device acceptance.',
 sourceBinding=dict(acceptedExecutionInputs=focused['sourceBinding'],acceptedExecutionInputSnapshot='.build/original-public-runtime/focused-final-sources/',
  preparedSwiftInputs=grammar['files'],preparedSwiftSnapshot='.build/original-public-runtime/swift-sources/',changedCodeTestsAndProvenance=final,
  finalSnapshot='.build/original-public-runtime/final-sources/',allCurrentBytesEqualAcceptedSnapshots=True),
 validation=dict(focusedRecord=meta(out/'focused-final.json'),focusedLog=meta(out/'focused-final.log'),testXML=[meta(p) for p in xmls],
  suites=17,actualUniqueMethods=171,newPublicFacadeMethods=6,existingAffectedMethodsRevalidated=165,failures=0,errors=0,skipped=0,
  actualPublicChain='createSession/execute through same state.read/commit host and JVM HTTP: CSS search, XPath details, JSON TOC next page, two chapters and first chapter next page; original regex search/replace and large variables, raw source arrays, chapter vars and Cookies across tasks.',
  actualTypedFailures='Explicit gates/DTO identity/type, unsupported owner, empty TOC/content, input UTF8/business result/error envelope budgets, public cancellation/close/deadline.',
  originalStatefulPublicCalls=47,originalStatefulJUnitMethods=1,newAndroidObservations=0,notAddedToHistoricalCounts=True),
 swift=dict(grammar=meta(out/'swift-grammar.json'),preparedPackageMethods=['LegadoOriginalAPITests/'+name for name in swiftmethods],
  relatedExistingPackageMethods=['LegadoRuntimeTests/'+name for name in oldswift],relatedExistingPackageSource=meta(oldfile),
  SDKRequirement='Parent will run relevant Package tests with LEGADO_RUNTIME_SOURCE_ONLY=1 on actual macOS Swift6 SDK; App compilation alone does not execute SPM tests.',
  compilerExecuted=False,testsExecuted=False),
 ordinary=ordinary,ordinaryRecord=meta(out/'ordinary-v1.json'),ordinaryLog=meta(out/'ordinary-v1.log'),
 ordinaryPublicChain='PACKAGED_ORIGINAL_TRADITIONAL_OK books=1 chapters=2 tocPages=2 firstChapterPages=2 sameCookie=true. Controlled in-memory host fixture is smoke-only and not a persistence acceptance substitute.',
 provenance=dict(manifest=meta(manifest),updateRecord=meta(out/'provenance-update.json'),priorManifest=meta(out/'manifest.before.json'),currentManifest=meta(out/'manifest.after.json'),
  sourceArchiveSHA256=value['originalArchiveSHA256'],originalEntriesUnchanged=len(value['sourceProvenance']),newOriginalEntries=0,allOriginalBytesMatchLockedZIP=True,
  existing21NoticesUnchanged=ordinary['ordinaryJar']['byteEqualProvenanceAndNotices'],currentPortAndIntegrationHashesVerified=True,legalRedistributionClearanceEstablished=False),
 publicContract=value['publicTraditionalRuntimeIntegration'],attemptNotes=attempts,
 boundaries=dict(defaultAppRouteUnchanged=True,requiresEmbeddingPersistentOwnerAndJvmHttp=True,publicNeedSaveTrueUnsupported=True,
  noAppUUIDSynthesized=True,originalHTTPAndCookieOwnerReused=True,newParserOrTransportAdded=False,normalJarContainsProjectTestOrJUnitClasses=False,
  JNIExecuted=False,nativeProductChainEstablished=False,appOwnerBookChapterCookieMappingComplete=False,fullC3Complete=False,fullC4Complete=False,
  allNonDeviceWorkComplete=False,automaticSelfRenewalImplemented=False,fullLegadoCompatibilityEstablished=False,legalRedistributionClearanceEstablished=False,deviceExecuted=False))
(out/'preparation.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(dict(preparation=meta(out/'preparation.json'),acceptedExecutionInputs=len(focused['sourceBinding']),changedFiles=len(final),uniqueMethods=len(leaves),jar=jar)))
