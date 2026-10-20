import hashlib,json,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent
target=root/'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
assert not (out/'manifest.before.json').exists()
before=target.read_bytes();(out/'manifest.before.json').write_bytes(before);value=json.loads(before)
focused=json.loads((out/'focused-final.json').read_bytes());assert focused['exitCode']==0 and sum(x['tests'] for x in focused['junitSuites'])==171
def meta(name):
 data=(root/name).read_bytes();return dict(path=name,bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
for item in focused['sourceBinding']:assert meta(item['path'])==item
with zipfile.ZipFile('F:/legado-master.zip') as original:
 for item in value['sourceProvenance']:
  raw=original.read(item['archivePath']);assert (target.parent/item['vendorPath']).read_bytes()==raw
  assert len(raw)==item['bytes'] and hashlib.sha256(raw).hexdigest()==item['sha256']
for item in value['portedSources']:item.update(meta(item['path']))
for group in ['urlExpansionIntegration','webBookIntegration','statePersistenceIntegration']:
 for item in value[group]['integrationSources']:item.update(meta(item['path']))
value['scope']='Retained original AnalyzeRule/finite AnalyzeUrl/text WebBook await chain now has an opt-in public business JSON facade and Swift Package API. Explicit embedding original-traditional + jvm-okhttp + persistent stateOwner required. Same task/HTTP/cookie owner; App traditional-source route, full App book/chapter/Cookie mapping and final native product-chain acceptance remain unfinished. Windows JVM evidence does not establish Android/iOS/device/full compatibility.'
value['statePersistenceIntegration']['validation']['historicalRecordNotRecounted']=True
value['statePersistenceIntegration']['currentPublicRuntimeValidation']='.build/original-public-runtime/focused-final.json'
value['publicTraditionalRuntimeIntegration']=dict(
 scope='Explicitly selected production JSON facade into retained four-stage WebBook, plus typed Swift Package business API. No new parser/transport/App UUID or production route switch.',
 integrationSources=[meta('Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/'+n+'.kt') for n in ['OriginalTraditionalRuntime','OriginalRuleDto','LegadoRuntime','RuntimeSessionOptions']],
 apiSources=[meta('Packages/LegadoRuntime/Sources/LegadoRuntime/'+n+'.swift') for n in ['LegadoRuntime','LegadoOriginalModels']],
 sourceMode=dict(option='sourceMode=original-traditional',default='existing (unchanged source selection)',requires=['httpTransport=jvm-okhttp','embedding stateOwner','traditional text source without mainJs']),
 actions={'search':'{key,page?} -> {books:[finite Book]}','details|getBookInfo':'{book,canReName?} -> {book}',
  'toc|getChapters':'{book,runPreUpdateJs?,isFromBookInfo?} -> {book,chapters}',
  'content|getContent':'{book,chapter,nextChapterUrl?,needSave:false} -> {book,chapter,content}'},
 identity='Original bookUrl/origin and chapter bookUrl/url/index remain explicit; no App UUID is inferred. Only whitelisted finite model fields, raw variable JSON and HTML caches cross as business DTOs. Environment/delegates are never reflected over JNI.',
 budgets=dict(sourceAndRequestUTF8Bytes=4194304,businessResultUTF8Bytes=8388608,errorEnvelopeUTF8Bytes=8388608,swiftResponseEnvelopeAllowanceBytes=65536,overflow='PAYLOAD_TOO_LARGE; no truncation'),
 errors=['INVALID_ARGUMENT for absent/incompatible identity or primitive DTO fields','UNSUPPORTED_OPERATION for unported actions',
  'UNSUPPORTED_CAPABILITY for missing owner/transport/host mapping, media/mainJs and missing/true public needSave',
  'TOC_EMPTY,CONTENT_EMPTY,RULE_ERROR,HTTP_ERROR preserve original ordinary action boundaries',
  'Existing STATE_IO,CANCELLED,TIMEOUT and owner host failures remain typed; no successful error body substitution'],
 implemented=['Public execute routes only explicitly configured original sessions into retained WebBook, using actual Book/Chapter objects in the same original environment/task/HTTP/Cookie and host owner.',
  'All four results include mutated business entities, so variables/title/HTML state are not discarded at the bridge. Persistent large values use existing C2 owner keys across tasks.',
  'Swift typed calls reuse existing execute cancellation/close/transport. DTO encoding/decoding and new-mode JSON validation run on the existing regular worker; size/main diagnostics are logged.',
  'Assembled ordinary JAR smoke calls public four-stage chain with owned loopback, two chapters/TOC and content next pages and the same Cookie. Smoke fixture is not packaged and is not durability acceptance.'],
 validation=dict(platform='Actual Windows JDK21 JVM',runRecord='.build/original-public-runtime/focused-final.json',suites=17,actualUniqueMethods=171,
  newPublicMethods=6,existingAffectedMethodsRevalidated=165,failures=0,errors=0,skipped=0,
  existingOriginalStatefulPublicCalls=47,originalStatefulJUnitMethods=1,newAndroidObservations=0,
  swiftGrammar='.build/original-public-runtime/swift-grammar.json',preparedSwiftPackageMethods=5,swiftCompilerOrTestsExecutedHere=False,notAddedToHistoricalCounts=True),
 remainingUnsupportedOrUnfinished=['Actual App source revision/book UUID/chapter URL/generation grants and full shared Cookie owner mapping are unfinished; current host capabilities reject unsupported keys/atomic combinations before writes.',
  'Public needSave=true is blocked until App reader generation publication is mapped. Existing OnlineReadingPipeline/ChapterCacheRepository remains the intended saving owner; no JVM App file library is added.',
  'Original browser/media/explore/batch, Android full entity ABI and remaining C2 ContentSaveFence failures/delete/resources are not made compatible by this public wrapper.',
  'Normal-JAR to JNI to native product route still requires separate native/SDK/actual final-chain evidence. Package fake-transport tests are prepared separately; Windows grammar is not Swift compilation.'],
 publicJVMJsonFacadeIntegrated=True,jniSignaturesChanged=False,jniExecuted=False,appTraditionalRouteIntegrated=False,nativeProductChainEstablished=False,fullC3OrC4Complete=False,
 androidExecuted=False,iosExecuted=False,deviceExecuted=False)
for name in ['OriginalTraditionalRuntime','OriginalRuleDto']:
 path='io/yuedu/legado/'+name+'.class'
 if path not in {x['path'] for x in value['requiredRuntimeClasses']}:value['requiredRuntimeClasses'].append(dict(path=path))
assert value['sourceProvenance']==json.loads(before)['sourceProvenance']
target.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n');(out/'manifest.after.json').write_bytes(target.read_bytes())
record=dict(manifest=meta(target.relative_to(root).as_posix()),originalEntriesUnchanged=len(value['sourceProvenance']),newOriginalEntries=[],
 allOriginalBytesMatchLockedZIP=True,finalExecutionInputsMatchCurrent=True,oldHistoricalURLSnapshotUnchanged=value['historicalURLExpansionFirstSegment']==json.loads(before)['historicalURLExpansionFirstSegment'])
(out/'provenance-update.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record))
