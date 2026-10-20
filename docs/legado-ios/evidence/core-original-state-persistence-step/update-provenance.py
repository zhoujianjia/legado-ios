import copy, hashlib, json, zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
target = root / 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
assert not (out / 'manifest.before.json').exists()
before = target.read_bytes()
(out / 'manifest.before.json').write_bytes(before)
value = json.loads(before)
focused = json.loads((out / 'focused-final.json').read_bytes())
assert focused['exitCode'] == 0
assert all(x['failures'] == x['errors'] == x['skipped'] == 0 for x in focused['junitSuites'])

def metadata(name):
    data = (root / name).read_bytes()
    return dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

for item in focused['sourceBinding']:
    assert metadata(item['path']) == item
archive = Path('F:/legado-master.zip')
assert hashlib.sha256(archive.read_bytes()).hexdigest() == value['originalArchiveSHA256']
added = []
with zipfile.ZipFile(archive) as original:
    entries = [
        ('main/java/io/legado/app/help/http/CookieStore.kt', 'sources/help/http/CookieStore.kt'),
        ('test/java/io/legado/app/help/CacheManagerTtlContractTest.kt', 'sources/tests/help/CacheManagerTtlContractTest.kt'),
        ('test/java/io/legado/app/help/book/ContentSaveFenceTest.kt', 'sources/tests/help/book/ContentSaveFenceTest.kt'),
    ]
    for relative, vendor in entries:
        name = 'legado-master/app/src/' + relative
        data = original.read(name)
        destination = target.parent / vendor
        if destination.exists():
            assert destination.read_bytes() == data
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        if name not in {item['archivePath'] for item in value['sourceProvenance']}:
            item = dict(archivePath=name, vendorPath=vendor, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            value['sourceProvenance'].append(item)
            added.append(item)
    for item in value['sourceProvenance']:
        data = original.read(item['archivePath'])
        assert (target.parent / item['vendorPath']).read_bytes() == data
        assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']

for item in value['portedSources']:
    item.update(metadata(item['path']))
new_port = 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePersistence.kt'
assert new_port not in {item['path'] for item in value['portedSources']}
value['portedSources'].append(metadata(new_port))
for group in ['urlExpansionIntegration', 'webBookIntegration']:
    for item in value[group]['integrationSources']:
        item.update(metadata(item['path']))
# historicalURLExpansionFirstSegment intentionally retains its original snapshot hashes.
value['scope'] = ('Retained original AnalyzeRule/finite AnalyzeUrl/text WebBook await chain with explicit embedding-owned state.read/state.commit persistence. '
    'Same RuntimeSession HTTP/cookie/task/deadline; default isolated memory remains. Android Room/full content resource fence, '
    'Swift book/chapter identity mapping, media/browser/batch/explore UI and App traditional-source route remain unfinished. '
    'Windows evidence is not Android/iOS/device/full-source acceptance.')
url = value['urlExpansionIntegration']
url['remainingUnsupportedOrUnfinished'] = [line.replace(
    'Source variable/login/cache persistence still needs explicit session/store integration.',
    'Explicit stateOwner session injection now routes source variable/login/cache through state.read/commit; actual host capability remains authoritative, with no credentials persisted in JSON.')
    for line in url['remainingUnsupportedOrUnfinished']]
web = value['webBookIntegration']
web['scope'] = 'Retained locked-ZIP text await orchestration with finite embedding-owned TOC/content persistence when explicitly injected; not complete Android WebBook ABI or App route'
web['explicitPlatformSeams'][0] = ('RuleEnvironment.webBook uses isolated transient state by default; an explicit stateOwner stores finite TOC/content records through the same host owner. '
    'Next-chapter lookup remains index+1 then index0 in that state. This is not a second App file database or an Android Room adapter.')
web['remainingUnsupportedOrUnfinished'][0] = ('Outer WebBook.getContentAwait needSave=true now saves through the injected owner; the direct BookContent.analyzeContent needSave=true helper, '
    'full Android failed-edit/delete/resource/folder generation fencing, contentBatch/BatchContentContext/java.cacheContent and App reader publication remain unsupported/unintegrated.')
web['remainingUnsupportedOrUnfinished'][2] = web['remainingUnsupportedOrUnfinished'][2].replace(
    'and persistent source/login/cache stores remain unported or explicit unsupported at their invocation boundary.',
    'remain unported or explicit unsupported at their invocation boundary. Persistent state capabilities are listed separately below.')
web['validation']['historicalRecordNotRecounted'] = True
web['currentPersistenceValidation'] = '.build/original-state-persistence/focused-final.json'

code = [
    'io/yuedu/legado/originalrule/RulePersistence.kt', 'io/yuedu/legado/originalrule/RuleStateStore.kt',
    'io/yuedu/legado/originalrule/RuleWebBookState.kt', 'io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'io/yuedu/legado/originalrule/RulePlatform.kt', 'io/yuedu/legado/LegadoRuntime.kt',
    'io/yuedu/legado/RuntimeSessionOptions.kt', 'io/yuedu/legado/SourceHosts.kt',
    'io/yuedu/legado/ProductionHttpTransport.kt', 'io/yuedu/legado/RuntimeHttpRequestExecutor.kt',
    'io/legado/app/data/entities/RuleModels.kt', 'io/legado/app/model/webBook/WebBook.kt',
]
state = dict(
    scope='Explicit owner adapter wired into real rule/mainJs state and retained WebBook; default isolated memory unchanged. Concrete file backend is test-only.',
    integrationSources=[metadata('Packages/LegadoRuntime/jvm/src/main/kotlin/' + path) for path in code],
    protocol=dict(read='state.read {owner,keys} -> {revision,values:base64}',
        commit='state.commit {owner,revision,changes:base64|null} -> {committed}; false commits nothing',
        key='JSON array string [sourceURL,area,...identityParts], owner only from embedding RuntimeSessionOptions.stateOwner',
        timeout='Existing host request carries taskId/deadlineEpochMs/remainingTimeoutMs; same cancellation and absolute deadline',
        atomicity='Read snapshot plus up to 32 CAS retries. Multi-key mutation is one owner commit. Unsupported capabilities must reject before any writes.'),
    implemented=[
        'Book/source/chapter variables preserve original short JSON vs >=10000 UTF-16 large-value storage, null/delete and exact Java return types; book/chapter keys include URL identities.',
        'Separate text/binary cache records and seconds-to-absolute-epoch TTL (zero means forever); transient typed memory remains session-local. Persistent auto-memory views re-read owner, explicit putMemory shadows stay local.',
        'Verbatim source variables/login headers restore across sessions. Login header plus Cookie merge/remove uses a single owner CAS, then publishes live state. No plaintext credentials are introduced.',
        'The existing single SessionCookies HTTP jar restores full cookie attributes and expiry through the owner; no replacement transport/jar. Malformed backing is typed STATE_IO and failed commits preserve old live/durable state.',
        'Finite TOC DTOs restore actual environment-owned BookChapter entities. Outer WebBook needSave=true saves body+TOC title/image metadata atomically; current TOC book/index/chapterURL gates stale downloads. Empty body only reuses a fully matching content identity.',
        'Normal downloads do not advance the edit generation. Successful atomic replace increments it and rejects older tokens. Closed/cancelled host-read results cannot commit or publish after return guards.',
    ],
    validation=dict(platform='Actual Windows JDK21 JVM', runRecord='.build/original-state-persistence/focused-final.json',
        uniqueMethods=sum(item['tests'] for item in focused['junitSuites']), suites=len(focused['junitSuites']),
        originalPublicStatefulCalls=47, originalStatefulScenarios=14, originalStatefulJUnitMethods=1,
        referenceScope='Existing pinned original Android 47 public-call observations reused twice against memory and injected persistent owners. Exact public return descriptors and effective state compared; not 94 methods or new Android execution.',
        newPersistenceMethods=11, failures=0, errors=0, skipped=0,
        actualPersistence='Controlled temporary directory, atomic staged file failure and corrupted disk; two separate Java processes; real loopback header/cookie/WebBook body requests.',
        notAddedToHistoricalCounts=True),
    remainingUnsupportedOrUnfinished=[
        'Swift host capabilities/owner mappings remain explicit: current App host supports source raw variables/key-values, no-Cookie login headers and generic text cache; binary values, full Cookie snapshots, book/chapter variables, TOC/content and cross-owner atomic combinations are rejected until C4 mapping.',
        'Swift UUID to original bookUrl/chapter URL identity, existing BookStore/ChapterCacheRepository generation publication and traditional-source App route are not connected. No second user file database is created.',
        'Full Android ContentSaveFence semantics for failed edits, delete/resource invalidation, files/folders and all Room prior-metadata merging are not ported; successful replacement and current TOC URL identity are the finite implemented fences.',
        'Direct BookContent.analyzeContent needSave=true, cache.putFile/getFile, credential/keychain methods, content batch/media/browser and full original public API remain typed unsupported or unfinished.',
        'Already-running synchronous host callbacks cannot be forcibly rolled back after the host commits; owner must enforce task/deadline/atomic CAS before writes. Runtime return boundaries reject cancelled/expired publication.',
    ],
    appTraditionalRouteIntegrated=False, fullC2Complete=False, fullOriginalStateCompatibilityEstablished=False,
    androidExecuted=False, iosExecuted=False, deviceExecuted=False,
)
value['statePersistenceIntegration'] = state
for name in ['RulePersistenceAdapter', 'RulePersistenceBinding', 'RulePersistenceHost']:
    path = 'io/yuedu/legado/originalrule/' + name + '.class'
    if path not in {item['path'] for item in value['requiredRuntimeClasses']}:
        value['requiredRuntimeClasses'].append(dict(path=path))
assert value['sourceProvenance'][:len(json.loads(before)['sourceProvenance'])] == json.loads(before)['sourceProvenance']
target.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
(out / 'manifest.after.json').write_bytes(target.read_bytes())
record = dict(manifest=metadata(target.relative_to(root).as_posix()), newOriginalEntries=added,
    newPortedFiles=1, oldOriginalEntriesUnchanged=True, oldHistoricalURLExpansionSnapshotUnchanged=value['historicalURLExpansionFirstSegment']==json.loads(before)['historicalURLExpansionFirstSegment'],
    allOriginalBytesMatchLockedZIP=True, finalFocusedSourcesMatchCurrent=True)
(out / 'provenance-update.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
print(json.dumps(record))
