import datetime,hashlib,json,subprocess,xml.etree.ElementTree as ET,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
assert not(out/'preparation.json').exists()
def meta(path):
 p=Path(path);p=p if p.is_absolute() else root/p;b=p.read_bytes()
 return dict(path=p.relative_to(root).as_posix(),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
focused=json.loads((out.parent/'focused-search-boundary.json').read_bytes())
ordinary=json.loads((out/'ordinary-v1.json').read_bytes())
assert focused['exitCode']==ordinary['exitCode']==0
for item in focused['sourceBinding']:assert meta(item['path'])==item
changed=[
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalRuleDto.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalTraditionalRuntimeTest.kt',
 'Packages/LegadoRuntime/vendor/original-rule/manifest.json']
snap=out/'final-sources';snap.mkdir()
for name in changed:
 p=snap/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((root/name).read_bytes())
xmls=[];methods=[]
for path in sorted((out.parent/'focused-search-boundary-xml').glob('*.xml')):
 tree=ET.parse(path).getroot();assert int(tree.attrib['failures'])==int(tree.attrib['errors'])==int(tree.attrib.get('skipped',0))==0
 for case in tree.findall('testcase'):methods.append(case.attrib['classname']+'.'+case.attrib['name'])
 xmls.append(meta(path))
assert len(xmls)==3 and len(methods)==len(set(methods))==31
manifest=json.loads((root/changed[-1]).read_bytes());before=json.loads((out/'manifest.before.json').read_bytes())
assert manifest['sourceProvenance']==before['sourceProvenance'] and len(manifest['sourceProvenance'])==48
with zipfile.ZipFile('F:/legado-master.zip') as archive:
 for item in manifest['sourceProvenance']:
  original=archive.read(item['archivePath']);assert len(original)==item['bytes'] and hashlib.sha256(original).hexdigest()==item['sha256']
  assert (root/'Packages/LegadoRuntime/vendor/original-rule'/item['vendorPath']).read_bytes()==original
jar=ordinary['ordinaryJar'];assert meta(jar['path'])['sha256']==jar['sha256']
assert len(jar['byteEqualProvenanceAndNotices'])==21 and not jar['junitOrProjectTestClasses']
record=dict(schemaVersion=1,stage='C3/C4 search result owner boundary correction',status='in_progress',
 frozenAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),baseCommit='15d23826bcaf62f88397da6bdb741209082d5c02',
 currentCommitAtFreeze=subprocess.check_output(['D:/app/Git/cmd/git.exe','rev-parse','HEAD'],cwd=root,text=True).strip(),
 scope='Independent four-file search owner correction. JVM public execute and ordinary JAR only. Uncommitted Swift App owner work is excluded. Historical 171 evidence is preserved unchanged.',
 sourceBinding=dict(acceptedExecutionInputs=focused['sourceBinding'],acceptedExecutionInputSnapshot='.build/original-app-owner/focused-search-boundary-sources',
 changedCodeTestsAndProvenance=[meta(name) for name in changed],finalSnapshot=snap.relative_to(root).as_posix(),allCurrentBytesEqualAcceptedSnapshots=True),
 validation=dict(focusedRecord=meta(out.parent/'focused-search-boundary.json'),focusedLog=meta(out.parent/'focused-search-boundary.log'),testXML=xmls,suites=focused['junitSuites'],
 actualUniqueMethods=31,newSearchOwnerMethod=1,previousPublicMethodsRevalidated=6,retainedWebBookMethodsRevalidated=13,persistenceMethodsRevalidated=11,
 failures=0,errors=0,skipped=0,uniqueMethods=methods,notAddedToHistoricalCounts=True,originalStatefulPublicCalls=0,originalStatefulJUnitMethods=0,newAndroidObservations=0),
 ordinary=ordinary,ordinaryRecord=meta(out/'ordinary-v1.json'),ordinaryLog=meta(out/'ordinary-v1.log'),
 ordinaryPublicChain='PACKAGED_ORIGINAL_TRADITIONAL_OK books=1 chapters=2 tocPages=2 firstChapterPages=2 sameCookie=true',
 provenance=dict(manifest=meta(changed[-1]),updateRecord=meta(out/'provenance-update.json'),priorManifest=meta(out/'manifest.before.json'),currentManifest=meta(out/'manifest.after.json'),
 sourceArchiveSHA256=manifest['originalArchiveSHA256'],originalEntriesUnchanged=48,newOriginalEntries=0,allOriginalBytesMatchLockedZIP=True,existing21NoticesUnchanged=True),
 implemented='Public search projects the retained SearchBook directly without constructing a persistent Book or requesting an invented shelf UUID. An owner denying Book variable reads can execute search; details correctly remains typed unsupported until it receives a granted Book owner.',
 attemptNotes=['The accepted focused search-boundary run passed on its first execution. The ordinary JAR build and both actual smoke programs passed on their first execution. No historical failed or successful records were overwritten.'],
 boundaries=dict(defaultAppRouteUnchanged=True,appPreviewOwnerIntegrated=False,appShelfOwnerIntegrated=False,appOwnerBookChapterCookieMappingComplete=False,
 noAppUUIDSynthesized=True,requiresEmbeddingPersistentOwnerAndJvmHttp=True,normalJarContainsProjectTestOrJUnitClasses=False,JNIExecuted=False,
 nativeProductChainEstablished=False,fullC3Complete=False,fullC4Complete=False,fullLegadoCompatibilityEstablished=False,deviceExecuted=False))
(out/'preparation.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(meta(out/'preparation.json')));print(json.dumps(record['sourceBinding']['changedCodeTestsAndProvenance']));print(json.dumps(meta(jar['path'])))
