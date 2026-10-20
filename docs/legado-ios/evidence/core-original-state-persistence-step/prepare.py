import datetime, hashlib, json, subprocess, xml.etree.ElementTree as ET, zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
assert not (out / 'preparation.json').exists()
def meta(path):
    path = Path(path)
    if not path.is_absolute(): path = root / path
    data = path.read_bytes()
    return dict(path=path.relative_to(root).as_posix(), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
def data(name): return json.loads((out / name).read_bytes())
focused = data('focused-final.json')
ordinary = data('ordinary-v1.json')
assert focused['exitCode'] == ordinary['exitCode'] == 0
for item in focused['sourceBinding']:
    assert meta(item['path']) == item
    assert (out / 'focused-final-sources' / item['path']).read_bytes() == (root / item['path']).read_bytes()
xmls = sorted((out / 'focused-final-xml').glob('*.xml'))
leaves = []
for xml in xmls:
    suite = ET.parse(xml).getroot()
    assert suite.attrib['failures'] == suite.attrib['errors'] == suite.attrib['skipped'] == '0'
    leaves += [(leaf.attrib['classname'], leaf.attrib['name']) for leaf in suite.findall('testcase')]
assert len(leaves) == len(set(leaves)) == 165 and len(xmls) == 16
assert sum(x['tests'] for x in focused['junitSuites']) == len(leaves)
jar = meta(ordinary['ordinaryJar']['path'])
assert {k:ordinary['ordinaryJar'][k] for k in ['path','bytes','sha256']} == jar
assert (root / 'Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar').read_bytes() == (root / jar['path']).read_bytes()
git = 'D:/app/Git/cmd/git.exe'
prefixes = ['Packages/LegadoRuntime/jvm', 'Packages/LegadoRuntime/vendor/original-rule']
changed = subprocess.check_output([git, 'diff', '--name-only', 'bd9c506', '--'] + prefixes, cwd=root).decode().splitlines()
changed += subprocess.check_output([git, 'ls-files', '--others', '--exclude-standard', '--'] + prefixes, cwd=root).decode().splitlines()
paths = sorted(set(changed))
final = []
for name in paths:
    item = meta(name)
    target = out / 'final-sources' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((root / name).read_bytes())
    assert target.read_bytes() == (root / name).read_bytes()
    final.append(item)
assert len(final) == 20
manifest = root / 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
current = json.loads(manifest.read_bytes())
prior = data('manifest.before.json')
assert current['sourceProvenance'][:len(prior['sourceProvenance'])] == prior['sourceProvenance']
archive = Path('F:/legado-master.zip')
assert hashlib.sha256(archive.read_bytes()).hexdigest() == current['originalArchiveSHA256']
with zipfile.ZipFile(archive) as original:
    for item in current['sourceProvenance']:
        raw = original.read(item['archivePath'])
        assert raw == (manifest.parent / item['vendorPath']).read_bytes()
        assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']
for group in [current['portedSources'], current['urlExpansionIntegration']['integrationSources'], current['webBookIntegration']['integrationSources'], current['statePersistenceIntegration']['integrationSources']]:
    for item in group: assert meta(item['path']) == item
gold = root / 'Packages/LegadoRuntime/jvm/src/test/resources/fixtures/android-traditional-stateful-golden.json'
gold_reference = root / 'docs/legado-ios/fixtures/android-traditional-stateful-golden.json'
assert gold.read_bytes() == gold_reference.read_bytes()
notes = {
    'v1': 'Development run: initial file-owned variables/cache/TTL/atomic write tests plus original AnalyzeRule group passed; superseded by final exact-source run.',
    'v2': 'One fixture failure: actual original RFC2965 CookieManager renders version-1 server cookie as quoted value plus $Path; assertion incorrectly expected unquoted server=updated. Fixture corrected to retained rendering; production rendering unchanged.',
    'v3': 'Test compilation failure: new stateful fixture called nonexistent setLocalVariable instead of retained AnalyzeRule.setLocal. Fixed fixture API; zero tests executed.',
    'v4': 'Development run passed including existing 47-call Android stateful reference in memory and persistent modes. These are 1 JUnit method, not 94 new methods or new Android execution.',
    'v5': 'One actual integration gap: persistent mainJs state used HTTP-only originalRuleEnvironment, rejecting default platformHost sessions. Split state-only environment construction from original JVM-HTTP-only factory; default old factory rejection contract kept. Cached closures now resolve current task per invocation.',
    'v6': 'Development run passed current-task persistent facade and existing scope/HTTP groups.',
    'v7': 'Development run passed finite TOC/body persistence and real needSave=true WebBook, restored in fresh session and separate process.',
    'v8': 'Development run passed added cancel-after-host-read no commit and malformed backing state regressions.',
    'v9': 'Development run passed confirmed TOC index-reuse identity fix and malformed stored-cookie typed failure. Not the final accepted byte snapshot.',
    'v10': 'One fixture setup failure: new two-live-session fixture omitted required mainJs source route and dereferenced missing sessionId. Added real mainJs fixture and asserted create result before access; production adapter behavior unchanged for this correction.',
    'v11': 'Development run passed cross-live-session owner/cache/source/raw-login-header visibility. Ordinary auto-memory views re-read owner; explicit typed/string putMemory shadow remains session-local.',
    'v12': 'Development run passed second confirmed production identity fix: empty new chapter body cannot inherit a previous different chapter/book/title/author record.',
    'final': 'Final accepted exact-source run: 16 suites/165 unique JUnit methods, zero failures/errors/skips. Includes previous 138 affected methods plus 11 persistence, 1 existing 47-call reference method, 4 mainJs scope and 11 Runtime lifecycle methods.',
}
attempts = []
for version, note in notes.items():
    name = f'focused-{version}.json'
    attempt = data(name)
    attempts.append(dict(version=version, record=meta(out/name), log=meta(out/f'focused-{version}.log'),
        exitCode=attempt['exitCode'], tests=sum(x['tests'] for x in attempt['junitSuites']),
        failures=sum(x['failures'] for x in attempt['junitSuites']), note=note, notAddedTogether=True))
record = dict(
    schemaVersion=1, stage='C2 explicit same-owner persistent original state and finite WebBook content seam',
    status='in_progress', frozenAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    baseCommit='bd9c506', currentCommitAtFreeze=subprocess.check_output([git,'rev-parse','HEAD'],cwd=root).decode().strip(),
    scope='Actual Windows JDK21 controlled JVM execution only. No Android/iOS/Zero/JNI/App route/real-device acceptance. No private source or real credentials read.',
    sourceBinding=dict(acceptedExecutionInputs=focused['sourceBinding'], acceptedExecutionInputSnapshot='.build/original-state-persistence/focused-final-sources/',
        changedCodeTestsAndProvenance=final, finalSnapshot='.build/original-state-persistence/final-sources/',
        acceptedInputsEqualCurrentAndExecutionBeforeSnapshot=True, changedFinalSourcesEqualCurrent=True),
    validation=dict(focusedRecord=meta(out/'focused-final.json'), focusedLog=meta(out/'focused-final.log'), testXML=[meta(p) for p in xmls],
        suites=16, actualUniqueMethods=165, failures=0, errors=0, skipped=0,
        previousAffectedMethodsRevalidated=138, newPersistenceMethods=11, originalStatefulReferenceMethods=1,
        additionalScopeMethods=4, additionalRuntimeLifecycleMethods=11,
        originalStatefulPublicCalls=47, originalStatefulScenarios=14, originalReferenceExecutionsPerVector=2,
        statefulReference=meta(gold), statefulReferenceByteEqualCanonicalFixture=meta(gold_reference),
        statefulScope='Original retained AnalyzeRule public descriptors/effective state compared to existing 47 frozen Android observations in default memory and persistent owners; no new Android observations, not 94 unique methods.',
        actualChildProcesses=dict(writePID=85352, readPID=69740, stdoutEvidence=meta(out/'focused-final-xml/TEST-io.yuedu.legado.OriginalStatePersistenceTest.xml'), testOnlyBackend=True)),
    ordinary=ordinary, ordinaryRecord=meta(out/'ordinary-v1.json'), ordinaryLog=meta(out/'ordinary-v1.log'),
    provenance=dict(manifest=meta(manifest), updateRecord=meta(out/'provenance-update.json'), priorManifest=meta(out/'manifest.before.json'),
        currentManifest=meta(out/'manifest.after.json'), archive=dict(path='F:/legado-master.zip', bytes=archive.stat().st_size, sha256=current['originalArchiveSHA256']),
        previousOriginalEntriesUnchanged=len(prior['sourceProvenance']), addedOriginalEntries=len(current['sourceProvenance'])-len(prior['sourceProvenance']),
        allOriginalEntriesByteEqualLockedZIP=True, currentPortAndIntegrationHashesVerified=True, previousHistoricalURLSnapshotUnchanged=True,
        existingNoticeFilesUnchanged=ordinary['ordinaryJar']['byteEqualProvenanceAndNotices'], licenseClearanceNotEstablished=True),
    protocol=current['statePersistenceIntegration']['protocol'],
    implementation=current['statePersistenceIntegration']['implemented'],
    confirmedReviewFixes=[
        'Same CAS checks current durable TOC book/index/chapterURL before body or title/image write; stale A token cannot overwrite B at reused index.',
        'Empty body may reuse old body only for complete matching book/index/chapterURL/name/author/title identity.',
        'Persistent auto-memory text cache refreshes from shared owner across live sessions; explicit putMemory shadow/typed values stay local.',
        'Malformed stored cache/cookies/TOC payloads preserve typed persistence failure and old state. Cancelled read result cannot proceed to CAS.'
    ],
    remaining=current['statePersistenceIntegration']['remainingUnsupportedOrUnfinished'],
    attemptNotes=attempts,
    preparationAuthoringIssue='Before the single ordinary Gradle run, inline Python quoting failed and the copied old ordinary script preflight referenced a historical source snapshot, so no Gradle/JAR/smoke executed. Corrected ignored script with apply_patch, then ordinary-v1 ran once successfully. No failed runtime execution is omitted.',
    boundaries=dict(defaultMemoryIsolated=True, productionPersistenceRequiresExplicitEmbeddingOwner=True, fileBackendOnlyInTestSources=True,
        sameHttpAndCookieOwner=True, credentialsWrittenToJSON=False, appTraditionalSourceRouteIntegrated=False,
        swiftBookChapterContentIdentityMappingIntegrated=False, fullAndroidContentSaveFenceImplemented=False,
        allNonDeviceWorkComplete=False, automaticSelfRenewalImplemented=False, fullLegadoCompatibilityEstablished=False,
        legalRedistributionClearanceEstablished=False, androidExecuted=False, iosExecuted=False, deviceExecuted=False))
(out/'preparation.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(dict(preparation=meta(out/'preparation.json'), acceptedExecutionInputs=len(focused['sourceBinding']),
    changedCodeTestsAndProvenance=len(final), uniqueMethods=len(leaves), ordinaryJar=jar)))
