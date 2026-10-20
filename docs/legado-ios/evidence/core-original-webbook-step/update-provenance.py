import copy,hashlib,json,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent
target=root/'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
before=target.read_bytes();assert not (out/'manifest.before.json').exists()
(out/'manifest.before.json').write_bytes(before);value=json.loads(before)
focused=json.loads((out/'focused-v7.json').read_bytes())
assert focused['exitCode']==0 and sum(x['tests'] for x in focused['junitSuites'])==138
def metadata(name):
 data=(root/name).read_bytes();return dict(path=name,bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
archive=Path('F:/legado-master.zip');assert hashlib.sha256(archive.read_bytes()).hexdigest()==value['originalArchiveSHA256']
originals=['model/webBook/'+n+'.kt' for n in ['WebBook','BookList','BookInfo','BookChapterList','BookContent']]
originals+=['data/entities/SearchBook.kt']+['data/entities/rule/'+n+'.kt' for n in ['BookListRule','SearchRule','ExploreRule','BookInfoRule','TocRule','ContentRule']]
originals+=['utils/HtmlFormatter.kt','utils/FlowExtensions.kt','utils/StringUtils.kt','utils/StringExtensions.kt','help/book/BookHelp.kt','help/source/BookSourceExtensions.kt','constant/AppPattern.kt','constant/BookType.kt','help/config/AppConfig.kt']
originals+=['exception/'+n+'.kt' for n in ['NoStackTraceException','TocEmptyException','ContentEmptyException']]
added=[]
with zipfile.ZipFile(archive) as zipped:
 for name in originals:
  entry='legado-master/app/src/main/java/io/legado/app/'+name;data=zipped.read(entry);p=target.parent/'sources'/name
  if p.exists():assert p.read_bytes()==data
  else:p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
  if entry not in {i['archivePath'] for i in value['sourceProvenance']}:
   item=dict(archivePath=entry,vendorPath='sources/'+name,bytes=len(data),sha256=hashlib.sha256(data).hexdigest());value['sourceProvenance'].append(item);added.append(item)
new_paths=['io/legado/app/model/webBook/'+n+'.kt' for n in ['WebBook','BookList','BookInfo','BookChapterList','BookContent','WebBookCompat']]
new_paths+=['io/legado/app/data/entities/SearchBook.kt']+['io/legado/app/data/entities/rule/'+n+'.kt' for n in ['BookListRule','SearchRule','ExploreRule','BookInfoRule','TocRule','ContentRule']]
new_paths+=['io/legado/app/exception/'+n+'.kt' for n in ['NoStackTraceException','TocEmptyException','ContentEmptyException']]
new_paths+=['io/legado/app/utils/HtmlFormatter.kt','io/legado/app/utils/OriginalMapAsync.kt','io/yuedu/legado/originalrule/RuleWebBookState.kt','io/yuedu/legado/originalrule/OriginalWebBookSession.kt']
for item in value['portedSources']:item.update(metadata(item['path']))
for name in new_paths:
 path='Packages/LegadoRuntime/jvm/src/main/kotlin/'+name
 assert path not in {i['path'] for i in value['portedSources']};value['portedSources'].append(metadata(path))
for item in value['urlExpansionIntegration']['integrationSources']:item.update(metadata(item['path']))
value['urlExpansionIntegration']['remainingUnsupportedOrUnfinished']=[s.replace('Full WebBook search/detail/TOC/content/loginCheckJs orchestration, pagination/batch, JNI/App traditional-source routing, persistent source/login/cache stores and full original model API are unfinished.','A retained text-only transient WebBook await chain with loginCheckJs and serial/fanout pagination is now integrated below. Durable content saving, contentBatch, media/file/explore UI, JNI/App traditional-source routing, persistent source/login/cache and full model API remain unfinished.') for s in value['urlExpansionIntegration']['remainingUnsupportedOrUnfinished']]
value['scope']='Retained original AnalyzeRule/finite AnalyzeUrl and original text-only transient WebBook await orchestration in the ordinary JVM module. Same RuntimeSession HTTP/cookie/task/deadline; Android durable stores, media/browser/batch/explore UI and App route are unfinished. Windows evidence is not Android/iOS/device/full-source acceptance.'
value['webBookIntegration']={
 'scope':'Retained locked-ZIP await orchestration for text search, detail, TOC and no-save content, not complete Android WebBook ABI or App route',
 'integrationSources':[metadata('Packages/LegadoRuntime/jvm/src/main/kotlin/'+name) for name in new_paths]+[metadata('Packages/LegadoRuntime/jvm/src/main/kotlin/'+name) for name in ['io/yuedu/legado/LegadoRuntime.kt','io/yuedu/legado/originalrule/ProductionRulePlatform.kt','io/yuedu/legado/originalrule/RulePlatform.kt','io/yuedu/legado/originalrule/RuleStateStore.kt','io/legado/app/data/entities/RuleModels.kt','io/legado/app/model/analyzeRule/AnalyzeUrl.kt']],
 'implemented':[
  'WebBook.searchBookAwait/getBookInfoAwait/getChapterListAwait/getContentAwait/preciseSearchAwait and preUpdateJs call retained BookList/BookInfo/BookChapterList/BookContent and original AnalyzeRule. No new selector/parser or Swift fallback.',
  'BookList reversal, source rule split, per-item state/filter/break, URL-only deduplication and detail-page fallback; original BookInfo field order/init/canReName and tocHtml caching; actual SearchBook toBook conversion and same Book/BookChapter object identity.',
  'TOC single-next-page loop versus multi-URL ordered mapAsync branches, original redirect/base distinctions, reverse/deduplicate/reverse/index order, shared formatJs bindings/gInt and original boolean classification. Original pure formatter and empty-content/TOC exception FQNs retained.',
  'Content single-page continuation stops at the next chapter and cycles; multi-URL branch fetches once in declared order. Homepage AnalyzeRule remains authoritative for replacement/title; original HtmlFormatter/usehtml protection/HTML unescape and relative-image order.',
  'AnalyzeUrl construction is outside WebBook loginCheck execution recovery. Ordinary execution failures provide original synthetic 500 raw/body to loginCheckJs; constructor errors escape; capability/cancellation wrappers preserve typed control failures at both normal and recovery script exits.',
  'Entire await operation uses existing RuntimeTask Job, absolute deadline, ScriptExecutionGuard and shared RuntimeHttpRequestExecutor/ProductionHttpTransport/session cookies. Close rejects late publication; no timer/thread/second transport or standalone helper execution claim.',
 ],
 'explicitPlatformSeams':[
  'RuleEnvironment.webBook is transient chapter lookup/state only, not Room or filesystem. The next-chapter default lookup is index+1 then index0 within this explicitly published state; persistent Android DB lookup is not claimed.',
  'TOC metadata uses original ordering/timestamps/count with raw chapter titles. Android ContentProcessor title replacement rules and simulated chapter count/read configuration are not supplied; durable prior metadata merging is unported.',
  'threadCount=32, tocCountWords=true and adaptSpecialStyle=true are explicit mutable transient runtime options matching locked Android defaults, not a preference-store adapter.',
  'Original source rule DTO fields/getters/toString are retained; Parcelable/Room and Android Gson registration are replaced by a finite explicit snapshot decoder supporting object or legacy JSON-string rules.',
  'StrResponse remains the existing io.yuedu.legado adapter around actual OkHttp raw response, not full original io.legado.app.help.http.StrResponse ABI. Java method access is retained; Android/UI coroutine launch wrappers are not installed.',
 ],
 'remainingUnsupportedOrUnfinished':[
  'needSave=true durable content generation/cache tokens and persistence, contentBatch/BatchContentContext/java.cacheContent and App reader publication remain typed unsupported/unintegrated.',
  'mainJs WebBook delegation remains its separate retained route; this finite await entry explicitly rejects mainJs, non-text/media/file sources and explore navigation/infoMap rather than substituting a simplified parser.',
  'Browser/webJs/sourceRegex, configured proxy, media payload/decode/upload/rate limiting, subContent side channels, image/pay/callback/full model APIs and persistent source/login/cache stores remain unported or explicit unsupported at their invocation boundary.',
  'Arbitrary already-running Java host callbacks cannot be forcibly interrupted; existing task/guard/return boundaries reject cancelled/closed results.',
 ],
 'validation':dict(platform='Windows JDK21',actualFocusedUniqueMethods=138,newWebBookMethods=13,existingMethodsRevalidated=125,failures=0,errors=0,skipped=0,runRecord='.build/original-webbook-execution/focused-v7.json',goldenBoundary='Existing 28 scalar/36 JSONPath original Android observations reused in affected original parser tests; new loopback WebBook methods are JVM behavioral regressions against retained ZIP algorithms, not new Android observations.',notAddedToHistoricalCounts=True),
 'readerRouteIntegrated':False,'completeWebBookPort':False,'fullSourceCompatibilityEstablished':False,'androidExecuted':False,'iosExecuted':False,'deviceExecuted':False,
}
for name in ['WebBook','BookList','BookInfo','BookChapterList','BookContent']:
 value['retainedAlgorithms'][name+'.kt']=['Retained original algorithmic method bodies/ordering; explicit environment/task/response/transient-state seams and finite unsupported boundaries are listed in webBookIntegration.']
value['modelBoundary']['io.legado.app.data.entities.Book']['fields']+=['originName','originOrder','type','coverUrl','intro','latestChapterTitle','latestChapterTime','lastCheckTime','lastCheckCount','totalChapterNum','durChapterTitle','durChapterIndex']
value['modelBoundary']['io.legado.app.data.entities.Book']['methods']=['setReverseToc','getReverseToc','removeAllBookType','addType','toSearchBook']
value['modelBoundary']['io.legado.app.data.entities.BookChapter']['fields'].append('titleMD5')
value['modelBoundary']['io.legado.app.data.entities.BookChapter']['methods'].append('getAbsoluteURL')
source=value['modelBoundary']['io.legado.app.data.entities.BookSource'];source['fields']+=['bookSourceType','bookUrlPattern','customOrder','searchUrl','exploreUrl','loginCheckJs','mainJs','ruleSearch','ruleExplore','ruleBookInfo','ruleToc','ruleContent'];source['methods']+=['getSearchRule','getExploreRule','getBookInfoRule','getTocRule','getContentRule','isJsSource'];source['omitted']='Remaining full BookSource login/UI/media/review/config APIs and Android persistence remain unported; see finite WebBook integration.'
value['modelBoundary']['io.legado.app.data.entities.SearchBook']={'identity':'bookUrl equals/hashCode; original source fields, BaseBook variables, compareTo and toBook identity conversion retained','omitted':'Parcelable/Room/Android Context UI methods; environment parameter is port-only'}
for name in ['WebBook','BookList','BookInfo','BookChapterList','BookContent']:
 value['requiredRuntimeClasses'].append(dict(path='io/legado/app/model/webBook/'+name+'.class'))
value['requiredRuntimeClasses'].append(dict(path='io/legado/app/data/entities/SearchBook.class'))
target.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n');(out/'manifest.after.json').write_bytes(target.read_bytes())
for item in value['sourceProvenance']:
 data=(target.parent/item['vendorPath']).read_bytes();assert len(data)==item['bytes'] and hashlib.sha256(data).hexdigest()==item['sha256']
for item in value['portedSources']+value['urlExpansionIntegration']['integrationSources']+value['webBookIntegration']['integrationSources']:assert metadata(item['path'])==item
assert value['sourceProvenance'][:len(json.loads(before)['sourceProvenance'])]==json.loads(before)['sourceProvenance']
record=dict(manifest=metadata(target.relative_to(root).as_posix()),newOriginalEntries=added,newPortedFiles=len(new_paths),oldOriginalEntriesUnchanged=True,allOriginalAndCurrentPortedHashesVerified=True)
(out/'provenance-update.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record['manifest']))
